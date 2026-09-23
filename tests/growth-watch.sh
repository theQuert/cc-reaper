#!/usr/bin/env bash
# growth-watch.py: rotating, budgeted sampling and growth alerts. `du` and `docker` are
# stubs, and time is pinned with CC_DJ_GROWTH_NOW, so every case is deterministic.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GW="$ROOT_DIR/shell/growth-watch.py"

failures=0
expect_yes() {
  local name=$1; shift
  if "$@"; then printf "ok - %s\n" "$name"; else printf "not ok - %s\n" "$name"; failures=$((failures + 1)); fi
}
expect_no() {
  local name=$1; shift
  if "$@"; then printf "not ok - %s\n" "$name"; failures=$((failures + 1)); else printf "ok - %s\n" "$name"; fi
}

T=$(mktemp -d "${TMPDIR:-/tmp}/growth-watch-test.XXXXXX")
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
export GW_DU_MAP="$T/du-map" GW_DU_LOG="$T/du-log" GW_DOCKER_LOG="$T/docker-log"
: > "$GW_DU_MAP"

# du: the size comes from the map, keyed by path; an unmapped path fails like an I/O error.
cat > "$BIN/du" <<'STUB'
#!/usr/bin/env bash
path="${!#}"
printf '%s\n' "$path" >> "$GW_DU_LOG"
[ -n "${GW_DU_SLEEP:-}" ] && sleep "$GW_DU_SLEEP"
size=$(awk -F '\t' -v p="$path" '$1 == p {print $2}' "$GW_DU_MAP")
[ -n "$size" ] || exit 1
printf '%s\t%s\n' "$size" "$path"
STUB
cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GW_DOCKER_LOG"
case "$*" in
  "system df --format {{json .}}")
    printf '%s\n' '{"Type":"Images","Size":"6.889GB"}' '{"Type":"Local Volumes","Size":"33.88GB"}' '{"Type":"Build Cache","Size":"4.802GB"}' ;;
  "system df -v --format {{json .}}")
    printf '%s\n' '{"Images":[],"Volumes":[{"Name":"stima-ci-cache","Size":"22.57GB"},{"Name":"stima-ci-work-1","Size":"3.432GB"},{"Name":"other","Size":"1GB"}]}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/du" "$BIN/docker"

NOW=2000000000
GiB=1048576   # KiB per GiB
run_gw() {  # <state dir> <targets file> [VAR=value ...]
  local state=$1 targets=$2; shift 2
  env PATH="$BIN:$PATH" CC_DJ_STATE_DIR="$state" CC_DJ_GROWTH_TARGETS="$targets" \
    CC_DJ_GROWTH_NOW="${GW_NOW:-$NOW}" "$@" python3 "$GW"
}
map() { printf '%s\t%s\n' "$1" "$2" >> "$GW_DU_MAP"; }
mkcase() { local d="$T/$1"; mkdir -p "$d/state" "$d/data"; echo "$d"; }

# ─── Sampling order, interval and budget ─────────────────────────────────────
C=$(mkcase order)
mkdir -p "$C/data/a" "$C/data/b" "$C/data/c"
map "$C/data/a" 100; map "$C/data/b" 200; map "$C/data/c" 300
printf 'a\t%s\to\nb\t%s\to\nc\t%s\to\n' "$C/data/a" "$C/data/b" "$C/data/c" > "$C/targets"
printf '%s\ta\t90\n%s\tb\t190\n' "$((NOW - 7 * 3600))" "$((NOW - 3600))" > "$C/state/growth-samples.tsv"
: > "$GW_DU_LOG"
out=$(GW_DU_SLEEP=1.2 run_gw "$C/state" "$C/targets" CC_DJ_GROWTH_BUDGET_SECONDS=1)
expect_yes "the never-measured key is measured first" test "$(head -1 "$GW_DU_LOG")" = "$C/data/c"
expect_yes "the budget stops further measurements" test "$(wc -l < "$GW_DU_LOG" | tr -d ' ')" = 1
expect_yes "and says how many wait" bash -c 'printf "%s" "$1" | grep -q "1 due target(s) wait for a later run"' _ "$out"
: > "$GW_DU_LOG"
run_gw "$C/state" "$C/targets" > /dev/null
expect_yes "the next run measures the oldest due key" grep -qx "$C/data/a" "$GW_DU_LOG"
expect_no "a key inside its interval is not measured" grep -qx "$C/data/b" "$GW_DU_LOG"

# ─── Glob targets become one key per directory, and a total ──────────────────
C=$(mkcase glob)
mkdir -p "$C/data/root/x" "$C/data/root/y"; : > "$C/data/root/file"
map "$C/data/root/x" $((2 * GiB)); map "$C/data/root/y" $((1 * GiB))
printf 'wt\t%s/data/root/*\tdev\n' "$C" > "$C/targets"
run_gw "$C/state" "$C/targets" > /dev/null
expect_yes "each matching directory is its own key" \
  bash -c 'grep -q "	wt/x	" "$1" && grep -q "	wt/y	" "$1" && ! grep -q "wt/file" "$1"' _ "$C/state/growth-samples.tsv"
expect_yes "the label total is their sum" grep -q "	wt	$((3 * GiB))\$" "$C/state/growth-samples.tsv"

# ─── Statuses are never sizes ───────────────────────────────────────────────
C=$(mkcase status)
mkdir -p "$C/data/denied" "$C/data/slow"; chmod 000 "$C/data/denied"
map "$C/data/slow" 5
printf 'gone\t%s/data/missing\to\nlocked\t%s/data/denied\to\nslow\t%s/data/slow\to\n' "$C" "$C" "$C" > "$C/targets"
out=$(GW_DU_SLEEP=3 run_gw "$C/state" "$C/targets" CC_DJ_GROWTH_KEY_TIMEOUT=1)
chmod 755 "$C/data/denied"
expect_yes "a vanished path records absent" grep -q "	gone	absent\$" "$C/state/growth-samples.tsv"
expect_yes "an unreadable path records denied" grep -q "	locked	denied\$" "$C/state/growth-samples.tsv"
expect_yes "a measurement past its timeout records timeout" grep -q "	slow	timeout\$" "$C/state/growth-samples.tsv"
expect_no "no status is recorded as zero" grep -q "	0\$" "$C/state/growth-samples.tsv"
expect_yes "each is reported" bash -c 'printf "%s" "$1" | grep -q "slow could not be measured (timeout)"' _ "$out"

C=$(mkcase globdenied)
mkdir -p "$C/data/locked/x"; chmod 000 "$C/data/locked"
printf 'app\t%s/data/locked/*\to\nnone\t%s/data/missing/*\to\n' "$C" "$C" > "$C/targets"
run_gw "$C/state" "$C/targets" > /dev/null
chmod 755 "$C/data/locked"
expect_yes "a glob under an unreadable directory records denied, not nothing" grep -q "	app	denied\$" "$C/state/growth-samples.tsv"
expect_yes "a glob under a missing directory records absent" grep -q "	none	absent\$" "$C/state/growth-samples.tsv"

# ─── Docker: one call per source ────────────────────────────────────────────
C=$(mkcase docker)
printf 'img\tdocker:Images\tdocker\nvol\tdocker:Local Volumes\tdocker\nci\tdocker:volumes/stima-ci-*\tci\n' > "$C/targets"
: > "$GW_DOCKER_LOG"
run_gw "$C/state" "$C/targets" > /dev/null
expect_yes "categories come from one docker system df" test "$(grep -c '^system df --format' "$GW_DOCKER_LOG")" = 1
expect_yes "volumes come from one docker system df -v" test "$(grep -c '^system df -v' "$GW_DOCKER_LOG")" = 1
expect_yes "a category is recorded in KiB" grep -q "	img	$((6889000000 / 1024))\$" "$C/state/growth-samples.tsv"
expect_yes "matching volumes are keys, others are not" \
  bash -c 'grep -q "	ci/stima-ci-cache	" "$1" && grep -q "	ci/stima-ci-work-1	" "$1" && ! grep -q "ci/other" "$1"' _ "$C/state/growth-samples.tsv"

# ─── Retention ──────────────────────────────────────────────────────────────
C=$(mkcase retention)
mkdir -p "$C/data/a"; map "$C/data/a" 10
printf 'a\t%s\to\n' "$C/data/a" > "$C/targets"
printf '%s\ta\t5\n%s\tgone\t7\n' "$((NOW - 15 * 86400))" "$((NOW - 15 * 86400))" > "$C/state/growth-samples.tsv"
run_gw "$C/state" "$C/targets" > /dev/null
expect_no "samples older than 14 days are dropped" grep -q "^$((NOW - 15 * 86400))	" "$C/state/growth-samples.tsv"

# ─── Growth ─────────────────────────────────────────────────────────────────
C=$(mkcase growth)
mkdir -p "$C/data/wt"; map "$C/data/wt" $((8 * GiB))
printf 'wt\t%s/data/wt\tdev-workflow\n' "$C" > "$C/targets"
printf '%s\twt\t%s\n' "$((NOW - 24 * 3600))" "$((2 * GiB))" > "$C/state/growth-samples.tsv"
out=$(run_gw "$C/state" "$C/targets")
expect_yes "six gigabytes in a day raise ALERT:growth with owner, growth, hours and size" \
  bash -c 'printf "%s" "$1" | grep -qx "ALERT:growth key=wt owner=dev-workflow +6.0GB in 24.0h now=8.0GB"' _ "$out"
expect_yes "and the top growers name it" bash -c 'printf "%s" "$1" | grep -q "^growth: top +6.0GB wt (dev-workflow) in 24.0h"' _ "$out"

C=$(mkcase small)
mkdir -p "$C/data/wt"; map "$C/data/wt" $((3 * GiB))
printf 'wt\t%s/data/wt\tdev\n' "$C" > "$C/targets"
printf '%s\twt\t%s\n' "$((NOW - 24 * 3600))" "$((2 * GiB))" > "$C/state/growth-samples.tsv"
out=$(run_gw "$C/state" "$C/targets")
expect_no "growth under the threshold raises nothing" bash -c 'printf "%s" "$1" | grep -q ALERT' _ "$out"
expect_yes "but is still among the top growers" bash -c 'printf "%s" "$1" | grep -q "top +1.0GB wt"' _ "$out"

C=$(mkcase recent)
mkdir -p "$C/data/wt"; map "$C/data/wt" $((20 * GiB))
printf 'wt\t%s/data/wt\tdev\n' "$C" > "$C/targets"
printf '%s\twt\t%s\n' "$((NOW - 3600))" "$((2 * GiB))" > "$C/state/growth-samples.tsv"
out=$(run_gw "$C/state" "$C/targets" CC_DJ_GROWTH_INTERVAL_HOURS=0)
expect_no "no baseline at least 3 hours old raises nothing" bash -c 'printf "%s" "$1" | grep -q ALERT' _ "$out"

C=$(mkcase statusbase)
mkdir -p "$C/data/wt"; map "$C/data/wt" $((20 * GiB))
printf 'wt\t%s/data/wt\tdev\n' "$C" > "$C/targets"
printf '%s\twt\ttimeout\n' "$((NOW - 24 * 3600))" > "$C/state/growth-samples.tsv"
out=$(run_gw "$C/state" "$C/targets")
expect_no "a status baseline carries no growth" bash -c 'printf "%s" "$1" | grep -q ALERT' _ "$out"

C=$(mkcase disabled)
mkdir -p "$C/data/wt"; map "$C/data/wt" $((20 * GiB))
printf 'wt\t%s/data/wt\tdev\t0\n' "$C" > "$C/targets"
printf '%s\twt\t%s\n' "$((NOW - 24 * 3600))" "$((2 * GiB))" > "$C/state/growth-samples.tsv"
out=$(run_gw "$C/state" "$C/targets")
expect_no "an alert GB of 0 disables the row's alert" bash -c 'printf "%s" "$1" | grep -q ALERT' _ "$out"

# ─── Totals ─────────────────────────────────────────────────────────────────
C=$(mkcase partial)
mkdir -p "$C/data/root/x" "$C/data/root/y"; map "$C/data/root/x" 100
printf 'wt\t%s/data/root/*\tdev\n' "$C" > "$C/targets"
partial_rc=0
run_gw "$C/state" "$C/targets" > /dev/null || partial_rc=$?
expect_yes "a member without a number does not stop the run" test "$partial_rc" -eq 0
expect_yes "the measured member is still recorded" grep -q "	wt/x	100\$" "$C/state/growth-samples.tsv"
expect_no "no total while a member has no number" grep -q "	wt	[0-9]*\$" "$C/state/growth-samples.tsv"

C=$(mkcase total)
mkdir -p "$C/data/root/x" "$C/data/root/y" "$C/data/root/z"
map "$C/data/root/x" $((3 * GiB)); map "$C/data/root/y" $((3 * GiB)); map "$C/data/root/z" $((3 * GiB))
printf 'wt\t%s/data/root/*\tdev\n' "$C" > "$C/targets"
printf '%s\twt\t%s\n%s\twt/x\t%s\n%s\twt/y\t%s\n' "$((NOW - 24 * 3600))" "$((3 * GiB))" \
  "$((NOW - 24 * 3600))" "$((2 * GiB))" "$((NOW - 24 * 3600))" "$((1 * GiB))" > "$C/state/growth-samples.tsv"
out=$(run_gw "$C/state" "$C/targets")
expect_yes "members that each grew less than the threshold still alert as a total" \
  bash -c 'printf "%s" "$1" | grep -qx "ALERT:growth key=wt owner=dev +6.0GB in 24.0h now=9.0GB"' _ "$out"
expect_no "and no member alerts on its own" bash -c 'printf "%s" "$1" | grep -q "ALERT:growth key=wt/"' _ "$out"

C=$(mkcase none)
out=$(run_gw "$C/state" "$C/missing-targets")
expect_yes "no targets configured says so" bash -c 'printf "%s" "$1" | grep -q "no growth targets configured"' _ "$out"

if [ "$failures" -gt 0 ]; then
  printf "%s test failure(s)\n" "$failures"
  exit 1
fi
printf "growth-watch validation passed\n"
