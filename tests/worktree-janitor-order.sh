#!/usr/bin/env bash
# worktree-janitor: largest first (stima-api#5886).
#   CC_WJ_ORDER=largest (default) examines a repository's worktrees by last known size, from
#   growth-watch's samples and the janitor's own size cache, newest measurement winning; trees
#   of unknown size go last, in path order. A budget-cut apply run examined the largest first,
#   and the next one starts with those this cycle has not examined yet.
#   CC_WJ_ORDER=path is the old path order. Neither order loosens a gate.
# Real git repositories and a local bare "origin"; lsof and gh are stubs.
# TAP-style; set WJ_SCRIPT to test another copy of the janitor.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WJ="${WJ_SCRIPT:-$ROOT_DIR/shell/worktree-janitor.sh}"
failures=0
ok() { printf 'ok - %s\n' "$1"; }
nok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (got '$2', want '$3')"; fi; }

T="$(cd "$(mktemp -d)" && pwd -P)"
[ -n "${WJ_KEEP_TMP:-}" ] || trap 'rm -rf "$T"' EXIT
[ -z "${WJ_KEEP_TMP:-}" ] || echo "# kept: $T"
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
G() { git -c user.name=Fixture -c user.email=fixture@example.com "$@"; }

ORIGIN="$T/origin.git"; PRIMARY="$T/primary"; WTS="$HOME/wts"; mkdir -p "$WTS"
G init -q --bare "$ORIGIN" -b main
G clone -q "$ORIGIN" "$PRIMARY" 2>/dev/null
printf 'node_modules/\n' > "$PRIMARY/.gitignore"
echo init > "$PRIMARY/README.md"
G -C "$PRIMARY" add README.md .gitignore
G -C "$PRIMARY" commit -qm init
G -C "$PRIMARY" push -q origin main

# A worktree at main (landed), or with an unpushed commit of its own (unlanded).
mkwt() { # <name> [unlanded]
  G -C "$PRIMARY" worktree add -q -b "$1" "$WTS/wt-$1" main
  if [ "${2:-}" = unlanded ]; then
    echo "$1" > "$WTS/wt-$1/$1.txt"
    G -C "$WTS/wt-$1" add "$1.txt"
    G -C "$WTS/wt-$1" commit -qm "work on $1"
  fi
}
for n in a b c d e f; do mkwt "$n" unlanded; done
mkwt zbig;        echo "notes" > "$WTS/wt-zbig/notes.txt"   # landed, but an untracked file
mkwt homepage-x                                             # landed and clean, but deny-listed
mkwt rm1                                                    # landed and clean: removable

# ─── Sizes ───────────────────────────────────────────────────────────────────

STATE="$T/state"; mkdir -p "$STATE"
now="$(date +%s)"
# The janitor's own cache: path<TAB>bytes<TAB>measured_at.
{
  printf '%s\t%s\t%s\n' "$WTS/wt-zbig" 9000000000 "$now"
  printf '%s\t%s\t%s\n' "$WTS/wt-homepage-x" 8000000000 "$now"
  printf '%s\t%s\t%s\n' "$WTS/wt-c" 5000000 "$now"
  printf '%s\t%s\t%s\n' "$WTS/wt-a" 3000000 "$now"
  printf '%s\t%s\t%s\n' "$WTS/wt-d" 100 "$((now - 1000))"        # older than its growth sample
} > "$STATE/worktree-sizes.tsv"
# growth-watch's: one glob row under ~, and samples in KiB keyed <label>/<name>.
GT="$T/growth-targets.tsv"; GS="$T/growth-samples.tsv"
printf '# targets\nfx\t~/wts/*\tsessions/test\t20\ndocker-images\tdocker:Images\tdocker\n' > "$GT"
{
  printf '%s\t%s\t%s\n' "$now" "fx/wt-d" 10000                     # 10240000 bytes, newest for d
  printf '%s\t%s\t%s\n' "$((now - 50))" "fx/wt-e" 4000             # 4096000 bytes
  printf '%s\t%s\t%s\n' "$now" "fx/wt-b" denied                    # a status is not a size
  printf '%s\t%s\t%s\n' "$((now - 9000))" "fx/wt-a" 999999999      # older than the cache: loses
  printf '%s\t%s\t%s\n' "$now" "fx" 123                            # a label total, no path
} > "$GS"

# ─── Stubs and env ────────────────────────────────────────────────────────────

STUBS="$T/stubs"; SLOW="$T/stubs-slow"; mkdir -p "$STUBS" "$SLOW"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/osascript"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gh"
printf '#!/usr/bin/env bash\nprintf "p1\\nn/\\n"\n' > "$STUBS/lsof"
# 1.2 s a holder scan outlasts a 1 s budget, so every budgeted apply run examines exactly one
# worktree, the progress floor, and yields on the next.
printf '#!/usr/bin/env bash\nsleep 1.2\nexec "%s/lsof" "$@"\n' "$STUBS" > "$SLOW/lsof"
chmod +x "$STUBS"/* "$SLOW"/*

export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T/no-root" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$STATE"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$T/no-sessions" CC_WJ_CLAUDE_PROJECTS="$T/no-projects"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/no-archive" CC_WJ_RECLAIM_PUSHED=0
export CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents" CC_WJ_SPOTCHECK_LOG="$T/spot.log"
export CC_WJ_DENY_NAMES="homepage" CC_WJ_GROWTH_TARGETS="$GT" CC_WJ_GROWTH_SAMPLES="$GS"
unset CC_WJ_ORDER CC_WJ_NEW_RULES_MODE CC_WJ_SWEEP_BUDGET_SECONDS CC_DJ_STATE_DIR CC_DJ_GROWTH_TARGETS
wj() { PATH="$STUBS:$PATH" bash "$WJ" --repo "$PRIMARY" "$@" 2>&1; }
wj_budget() { CC_WJ_SWEEP_BUDGET_SECONDS="${BUDGET:-1}" PATH="$SLOW:$STUBS:$PATH" bash "$WJ" --repo "$PRIMARY" "$@" 2>&1; }

# The worktrees a run examined, by name, in order.
examined() { sed -n 's|^  WORKTREE  .*/wt-\(.*\)$|\1|p' "$1" | paste -sd' ' -; }
block() { awk -v tail="/wt-$2" '/^  WORKTREE  / { on = (substr($0, length($0) - length(tail) + 1) == tail) } on' "$1"; }
judged() { block "$1" "$2" | grep -qF -- "    classification: $3"; }
cached() { awk -F'\t' -v p="$WTS/wt-$1" '$1 == p { print $2 }' "$STATE/worktree-sizes.tsv"; }
cursor() { cat "$STATE"/worktree-cursor-removal-* 2>/dev/null; }

# ─── Report order ────────────────────────────────────────────────────────────

wj > "$T/report-largest.txt"
same "largest (default): known sizes first, largest first; the newest measurement wins; unknown last in path order" \
  "$(examined "$T/report-largest.txt")" "zbig homepage-x d c e a b f rm1"
check "  a report writes no cursor" bash -c '! ls "$1" | grep -q cursor' _ "$STATE"
check "  a report records the size it measured for a removal candidate" test -n "$(cached rm1)"
check "  and keeps the seeded rows" test "$(cached zbig)" = 9000000000

CC_WJ_ORDER=path wj > "$T/report-path.txt"
same "path: the old path order" "$(examined "$T/report-path.txt")" "a b c d e f homepage-x rm1 zbig"

rc=0; CC_WJ_ORDER=biggest wj > "$T/report-bad.txt" || rc=$?
check "an unknown CC_WJ_ORDER fails the run and judges nothing" \
  bash -c '[ "$1" -eq 2 ] && grep -q "CC_WJ_ORDER=biggest is neither largest nor path" "$2" && ! grep -q "^  WORKTREE" "$2"' _ "$rc" "$T/report-bad.txt"

# ─── Gates do not move with the order ────────────────────────────────────────

check "first in line, an untracked file still keeps a landed tree" judged "$T/report-largest.txt" zbig "KEEP("
check "first in line, a deny-listed tree is still kept" judged "$T/report-largest.txt" homepage-x "KEEP(deny-listed:homepage)"
check "first in line, unpushed commits still keep a tree" judged "$T/report-largest.txt" d "KEEP(unlanded)"
check "the clean landed tree last in line is the one removable" judged "$T/report-largest.txt" rm1 "REMOVABLE"

# ─── Budget-cut apply runs ───────────────────────────────────────────────────

# The report measured rm1, a few KB, so it now sorts after the seeded sizes and before the unknown.
for want in zbig homepage-x d; do
  out="$T/budget-$want.txt"; rc=0
  wj_budget --apply > "$out" || rc=$?
  same "budget: a cut sweep examined the largest not yet examined in this cycle ($want)" "$(examined "$out")" "$want"
  check "  yielded on budget and exited 0 ($want)" bash -c '[ "$1" -eq 0 ] && grep -q "budget exhausted: budget=1s .*starts with those not yet examined" "$2"' _ "$rc" "$out"
done
check "budget: the cursor lists this cycle's examined trees" \
  test "$(cursor | paste -sd' ' -)" = "$WTS/wt-zbig $WTS/wt-homepage-x $WTS/wt-d"
check "budget: the kept trees are all still there" \
  bash -c 'for n in zbig homepage-x d; do [ -d "$1/wt-$n" ] || exit 1; done' _ "$WTS"

out="$T/budget-unbounded.txt"
BUDGET=0 wj_budget --apply > "$out"
same "unbounded: the rest of the cycle first, largest first, then those already examined" \
  "$(examined "$out")" "c e a rm1 b f zbig homepage-x d"
check "  the removable tree was removed" test ! -e "$WTS/wt-rm1"
check "  and its size row forgotten" test -z "$(cached rm1)"
check "  and nothing a gate keeps was removed" \
  bash -c 'for n in a b c d e f zbig homepage-x; do [ -d "$1/wt-$n" ] || exit 1; done' _ "$WTS"

out="$T/budget-newcycle.txt"
wj_budget --apply > "$out"
same "budget: once every tree was examined a new cycle starts with the largest" "$(examined "$out")" "zbig"
check "  and the cursor holds only it" test "$(cursor)" = "$WTS/wt-zbig"

chmod 000 "$STATE"/worktree-cursor-removal-*
out="$T/budget-unreadable.txt"; rc=0
wj_budget --apply > "$out" || rc=$?
chmod 644 "$STATE"/worktree-cursor-removal-* 2>/dev/null
same "budget: an unreadable cursor is an empty cycle, largest first" "$(examined "$out")" "zbig"
check "  and fails nothing" test "$rc" -eq 0

CC_WJ_ORDER=path wj --apply > "$T/apply-path.txt"
same "path --apply: the old order, from the start of the path list" "$(examined "$T/apply-path.txt")" "a b c d e f homepage-x zbig"

# ─── A trim subtracts what it freed ──────────────────────────────────────────

mkdir -p "$WTS/wt-a/node_modules/pkg"; head -c 200000 /dev/zero > "$WTS/wt-a/node_modules/pkg/blob"
before_a="$(cached a)"
wj --trim-regenerable --apply > "$T/trim.txt"
check "trim: the cache was trimmed" test ! -e "$WTS/wt-a/node_modules"
check "  and its tree's known size dropped by what it freed" \
  bash -c '[ -n "$1" ] && [ "$1" -lt "$2" ] && [ "$1" -gt $(( $2 - 1000000 )) ]' _ "$(cached a)" "$before_a"
check "  a tree of unknown size gets no row from a trim" test -z "$(cached b)"

if [ "$failures" -eq 0 ]; then echo "# all passed"; else echo "# $failures failed"; fi
[ "$failures" -eq 0 ]
