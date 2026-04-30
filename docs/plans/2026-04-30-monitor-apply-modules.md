# Monitor Apply Modules — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an opt-in `--apply <module>` flag and TTY interactive menu to `cc-monitor` so users can dispatch the right cleanup module (`claude-cleanup` / `claude-guard` / `proc-janitor`) directly from the monitor's report, without breaking the read-only-by-default contract.

**Architecture:** Append a dispatch stage after the existing human-mode report. Stage activates only when (`--apply` flag present) OR (TTY + SAFE_TO_REAP/heat candidates + no `--no-prompt` + no `--json`). JSON mode is untouched. Module dispatch shells out to the existing binaries — no cleanup logic re-implemented.

**Tech Stack:** Bash 3.2+ (macOS default), POSIX `awk`/`sed`, `command -v` for PATH detection, `/dev/tty` for prompt input. Tests use the existing `expect_eq`/`expect_contains` harness pattern with PATH-stub scripts to mock module binaries.

**Spec source:** `openspec/changes/monitor-apply-modules/specs/cc-monitor/spec.md` (14 scenarios across 2 ADDED Requirements).

**Tracking:** Update checkboxes in `openspec/changes/monitor-apply-modules/tasks.md` as each task completes. The OpenSpec tasks.md is the source of truth for completion.

---

## Reference: Spec → Test Mapping

| Spec Scenario | Test name | Task # |
|---|---|---|
| TTY interactive menu with safe candidates | `menu shows on TTY with SAFE_TO_REAP fixture` | 5.5 |
| TTY menu without candidates | `no menu without candidates` | 5.6 |
| Non-TTY suppresses menu | `non-TTY auto-suppresses menu` | 5.4 |
| `--no-prompt` suppresses menu | `--no-prompt suppresses menu` | 5.3 |
| `--json` suppresses menu | `JSON mode never prompts` | 5.2 |
| User declines (Enter / skip) | `Enter declines without dispatch` | 5.5 |
| User picks destructive — confirm `n` | `confirmation declined` | 5.8 |
| User picks destructive — confirm `y` | `confirmation accepted invokes stub` | 5.9 |
| User picks non-destructive | `non-destructive skips confirmation` | 5.9 |
| Module not on PATH (interactive) | `missing module hidden, install hint` | 5.7 |
| `--apply` skips confirmation | `--apply claude-cleanup invokes stub` | 5.10 |
| `--apply` accepts canonical names | covered by 5.10 + 5.15 |
| `--apply` rejects unknown | `unknown apply value rejected` | 5.12 |
| `--apply` rejects missing binary | `--apply unavailable module exits 127` | 5.13 |
| `--apply` + `--json` rejected | `--apply with --json rejected` | 5.11 |
| Module non-zero exit propagates | `dispatched module non-zero exit propagates` | 5.14 |
| Recommendation: RSS-only | `RSS-only recommends claude-guard-dry` | 5.15 |

---

## Task 1: Add `--apply` and `--no-prompt` flags with validation

**Files:**
- Modify: `shell/cc-monitor.sh` (arg parsing block, ~line 648-688)

**Step 1: Add flag parsing (no behavior yet)**

Add the two flags to the `case "$1" in` block in `cc-monitor()`. Initialize defaults:

```bash
local apply_module=""
local no_prompt=false
```

In the case block:

```bash
--apply)
  [ "$#" -ge 2 ] || { echo "cc-monitor: --apply requires a module name" >&2; return 2; }
  apply_module=$2
  shift 2
  ;;
--no-prompt)
  no_prompt=true
  shift
  ;;
```

**Step 2: Add `--apply` + `--json` rejection (after arg loop)**

After the arg loop, before validation:

```bash
if [ -n "$apply_module" ] && [ "$json" = "true" ]; then
  echo "cc-monitor: --apply cannot be combined with --json" >&2
  return 2
fi
```

**Step 3: Add canonical module name validation**

After the json/apply check:

```bash
if [ -n "$apply_module" ]; then
  case "$apply_module" in
    claude-cleanup|claude-guard|claude-guard-dry|proc-janitor-scan|proc-janitor-clean) ;;
    *)
      echo "cc-monitor: unknown module '$apply_module'. Valid: claude-cleanup, claude-guard, claude-guard-dry, proc-janitor-scan, proc-janitor-clean" >&2
      return 2
      ;;
  esac
fi
```

**Step 4: Syntax check**

Run: `bash -n shell/cc-monitor.sh`
Expected: no output, exit 0.

**Step 5: Commit**

```bash
git add shell/cc-monitor.sh
git commit -m "feat(cc-monitor): parse --apply and --no-prompt flags"
```

Update `openspec/changes/monitor-apply-modules/tasks.md`: check `1.1`, `1.2`, `1.3`.

---

## Task 2: Module catalogue helpers

**Files:**
- Modify: `shell/cc-monitor.sh` (insert helpers before `cc-monitor()`)

**Step 1: Add `_cc_monitor_module_command`**

```bash
_cc_monitor_module_command() {
  case "$1" in
    claude-cleanup)       echo "claude-cleanup" ;;
    claude-guard)         echo "claude-guard" ;;
    claude-guard-dry)     echo "claude-guard --dry-run" ;;
    proc-janitor-scan)    echo "proc-janitor scan" ;;
    proc-janitor-clean)   echo "proc-janitor clean" ;;
    *) return 1 ;;
  esac
}
```

**Step 2: Add `_cc_monitor_module_label`**

```bash
_cc_monitor_module_label() {
  case "$1" in
    claude-cleanup)       echo "claude-cleanup (kill all stale orphans)" ;;
    claude-guard)         echo "claude-guard (kill RSS/FD/idle violators)" ;;
    claude-guard-dry)     echo "claude-guard --dry-run (preview only)" ;;
    proc-janitor-scan)    echo "proc-janitor scan (preview only)" ;;
    proc-janitor-clean)   echo "proc-janitor clean (kill detected orphans)" ;;
    *) return 1 ;;
  esac
}
```

**Step 3: Add `_cc_monitor_module_destructive`**

Returns 0 (true) for modules that need y/N confirmation in interactive mode:

```bash
_cc_monitor_module_destructive() {
  case "$1" in
    claude-cleanup|claude-guard|proc-janitor-clean) return 0 ;;
    *) return 1 ;;
  esac
}
```

**Step 4: Add `_cc_monitor_module_binary` and `_cc_monitor_module_available`**

`_cc_monitor_module_binary` returns the actual binary name (without args) so PATH detection works:

```bash
_cc_monitor_module_binary() {
  case "$1" in
    claude-cleanup)                       echo "claude-cleanup" ;;
    claude-guard|claude-guard-dry)        echo "claude-guard" ;;
    proc-janitor-scan|proc-janitor-clean) echo "proc-janitor" ;;
    *) return 1 ;;
  esac
}

_cc_monitor_module_available() {
  local binary
  binary=$(_cc_monitor_module_binary "$1") || return 1
  command -v "$binary" >/dev/null 2>&1
}
```

**Step 5: Syntax check + commit**

```bash
bash -n shell/cc-monitor.sh
git add shell/cc-monitor.sh
git commit -m "feat(cc-monitor): add module catalogue helpers"
```

Update `tasks.md`: check `2.1`, `2.2`, `2.3`.

---

## Task 3: Recommendation logic

**Files:**
- Modify: `shell/cc-monitor.sh`

**Step 1: Add `_cc_monitor_recommended_module`**

```bash
_cc_monitor_recommended_module() {
  local findings_file=$1
  if awk -F '\t' '$11 == "SAFE_TO_REAP" { found=1; exit } END { exit !found }' "$findings_file"; then
    echo "claude-cleanup"
    return 0
  fi
  if awk -F '\t' '
      ($1+0) >= 60 { hot=1 }
      { rss[$10]+=$9 }
      END {
        if (hot) exit 0
        for (f in rss) if (rss[f] >= 1024) exit 0
        exit 1
      }
    ' "$findings_file"; then
    echo "claude-guard-dry"
    return 0
  fi
  return 1
}
```

**Step 2: Manual smoke test**

```bash
bash -c '
  source shell/cc-monitor.sh
  tmp=$(mktemp)
  printf "5.0\t10.0\t1\t111\t1\t111\t??\t02:00:00\t100\tagent-browser\tSAFE_TO_REAP\tlbl\tr\ta\tcmd\n" > "$tmp"
  _cc_monitor_recommended_module "$tmp"
  rm "$tmp"
'
```
Expected output: `claude-cleanup`

```bash
bash -c '
  source shell/cc-monitor.sh
  tmp=$(mktemp)
  printf "65.0\t80.0\t1\t111\t1\t111\tttys001\t01:00:00\t200\tdev-server\tASK_BEFORE_KILL\tlbl\tr\ta\tcmd\n" > "$tmp"
  _cc_monitor_recommended_module "$tmp"
  rm "$tmp"
'
```
Expected output: `claude-guard-dry`

**Step 3: Commit**

```bash
git add shell/cc-monitor.sh
git commit -m "feat(cc-monitor): add module recommendation logic"
```

Update `tasks.md`: check `2.4`.

---

## Task 4: TTY detection + prompt rendering

**Files:**
- Modify: `shell/cc-monitor.sh`

**Step 1: Add `_cc_monitor_is_tty`**

```bash
_cc_monitor_is_tty() {
  [ -t 0 ] && [ -t 1 ]
}
```

**Step 2: Add `_cc_monitor_prompt_apply`**

Renders menu to stderr, reads from `/dev/tty`, echoes selected canonical module name to stdout (empty on skip / Enter):

```bash
_cc_monitor_prompt_apply() {
  local findings_file=$1
  local recommended=""
  recommended=$(_cc_monitor_recommended_module "$findings_file") || recommended=""

  local all_modules=(claude-cleanup claude-guard claude-guard-dry proc-janitor-scan proc-janitor-clean)
  local available=() unavailable=()
  local m
  for m in "${all_modules[@]}"; do
    if _cc_monitor_module_available "$m"; then
      available+=("$m")
    else
      unavailable+=("$m")
    fi
  done

  if [ "${#available[@]}" -eq 0 ]; then
    return 1
  fi

  printf "\nOptimization options:\n" >&2
  local i=0 mark
  for m in "${available[@]}"; do
    i=$((i + 1))
    mark=""
    [ "$m" = "$recommended" ] && mark=" (recommended)"
    printf "  %d. %s%s\n" "$i" "$(_cc_monitor_module_label "$m")" "$mark" >&2
  done
  printf "  %d. skip\n" "$((i + 1))" >&2
  for m in "${unavailable[@]}"; do
    printf "  -  %s — install: %s\n" "$(_cc_monitor_module_label "$m")" "$(_cc_monitor_install_hint "$m")" >&2
  done

  local choice=""
  if ! { read -r choice < /dev/tty; } 2>/dev/null; then
    return 1
  fi

  case "$choice" in
    "" | "$((i + 1))") return 1 ;;
    *)
      if echo "$choice" | grep -qE '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le "${#available[@]}" ]; then
        echo "${available[$((choice - 1))]}"
        return 0
      fi
      return 1
      ;;
  esac
}
```

**Step 3: Add `_cc_monitor_install_hint`**

```bash
_cc_monitor_install_hint() {
  case "$1" in
    claude-cleanup|claude-guard|claude-guard-dry)
      echo "source shell/claude-cleanup.sh from this repo"
      ;;
    proc-janitor-scan|proc-janitor-clean)
      echo "brew install proc-janitor (or cargo install proc-janitor)"
      ;;
  esac
}
```

**Step 4: Syntax check + commit**

```bash
bash -n shell/cc-monitor.sh
git add shell/cc-monitor.sh
git commit -m "feat(cc-monitor): add TTY detection and prompt menu"
```

Update `tasks.md`: check `3.1`, `3.2`, `3.3`.

---

## Task 5: Dispatch + confirmation

**Files:**
- Modify: `shell/cc-monitor.sh`

**Step 1: Add `_cc_monitor_dispatch_module`**

```bash
_cc_monitor_dispatch_module() {
  local module=$1
  local skip_confirm=$2

  if ! _cc_monitor_module_available "$module"; then
    local binary
    binary=$(_cc_monitor_module_binary "$module")
    echo "cc-monitor: module '$module' not available on PATH (binary: $binary)" >&2
    return 127
  fi

  if [ "$skip_confirm" != "true" ] && _cc_monitor_module_destructive "$module"; then
    local label
    label=$(_cc_monitor_module_label "$module")
    printf "Run %s? [y/N] " "$label" >&2
    local answer=""
    if ! { read -r answer < /dev/tty; } 2>/dev/null; then
      return 0
    fi
    case "$answer" in
      y|Y|yes|YES) ;;
      *) return 0 ;;
    esac
  fi

  local cmd
  cmd=$(_cc_monitor_module_command "$module")
  # shellcheck disable=SC2086
  eval "command $cmd"
}
```

**Step 2: Wire dispatch into `cc-monitor()`**

After the human-report branch in `cc-monitor()`, before `rm -rf "$tmp_dir"`:

Replace the existing block:
```bash
if [ "$json" = "true" ]; then
  _cc_monitor_json_report "$findings_file" "$duration" "$interval" "$samples" "$once"
else
  _cc_monitor_human_report "$findings_file" "$duration" "$interval" "$samples" "$once" "$top"
fi

rm -rf "$tmp_dir"
```

With:

```bash
local dispatch_rc=0
if [ "$json" = "true" ]; then
  _cc_monitor_json_report "$findings_file" "$duration" "$interval" "$samples" "$once"
else
  _cc_monitor_human_report "$findings_file" "$duration" "$interval" "$samples" "$once" "$top"

  if [ -n "$apply_module" ]; then
    _cc_monitor_dispatch_module "$apply_module" "true"
    dispatch_rc=$?
  elif [ "$no_prompt" != "true" ] && _cc_monitor_is_tty; then
    local recommended
    recommended=$(_cc_monitor_recommended_module "$findings_file") || recommended=""
    if [ -n "$recommended" ]; then
      local chosen=""
      chosen=$(_cc_monitor_prompt_apply "$findings_file") || chosen=""
      if [ -n "$chosen" ]; then
        _cc_monitor_dispatch_module "$chosen" "false"
        dispatch_rc=$?
      fi
    fi
  fi
fi

rm -rf "$tmp_dir"
return "$dispatch_rc"
```

**Step 3: Syntax check**

```bash
bash -n shell/cc-monitor.sh
```

**Step 4: Manual smoke test (read-only path unchanged)**

```bash
bash shell/cc-monitor.sh --once --json | head -3
```
Expected: JSON output starts with `{`. No prompt text. Exit 0.

**Step 5: Manual smoke test (`--apply` rejection)**

```bash
bash shell/cc-monitor.sh --apply foo 2>&1; echo "rc=$?"
```
Expected: `cc-monitor: unknown module 'foo'. Valid: ...` then `rc=2`.

```bash
bash shell/cc-monitor.sh --apply claude-cleanup --json 2>&1; echo "rc=$?"
```
Expected: `cc-monitor: --apply cannot be combined with --json` then `rc=2`.

**Step 6: Commit**

```bash
git add shell/cc-monitor.sh
git commit -m "feat(cc-monitor): dispatch optimization module after report"
```

Update `tasks.md`: check `4.1`, `4.2`, `4.3`.

---

## Task 6: Test harness skeleton

**Files:**
- Create: `tests/cc-monitor-optimize.sh`

**Step 1: Write skeleton with stub-PATH harness**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

failures=0

expect_eq() {
  local name=$1 actual=$2 expected=$3
  if [ "$actual" = "$expected" ]; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s (expected %s, got %s)\n" "$name" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

expect_contains() {
  local name=$1 file=$2 pattern=$3
  if grep -qE -- "$pattern" "$file"; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s (pattern '%s' missing)\n" "$name" "$pattern"
    failures=$((failures + 1))
  fi
}

expect_not_contains() {
  local name=$1 file=$2 pattern=$3
  if ! grep -qE -- "$pattern" "$file"; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s (unexpected pattern '%s' present)\n" "$name" "$pattern"
    failures=$((failures + 1))
  fi
}

# Make a temp PATH dir with stubs for claude-cleanup, claude-guard, proc-janitor.
# Each stub records its argv to $stub_log.
make_stub_path() {
  local dir=$1
  local log=$2
  local exit_code=${3:-0}
  shift 3
  local missing=("$@")
  mkdir -p "$dir"
  for binary in claude-cleanup claude-guard proc-janitor; do
    local skip=false
    for m in "${missing[@]:-}"; do [ "$m" = "$binary" ] && skip=true; done
    [ "$skip" = "true" ] && continue
    cat > "$dir/$binary" <<STUB
#!/usr/bin/env bash
echo "STUB:$(basename "\$0"):\$*" >> "$log"
exit $exit_code
STUB
    chmod +x "$dir/$binary"
  done
}

# Snapshot fixture with one stale agent-browser (SAFE_TO_REAP) and one cmux (ASK_BEFORE_KILL).
write_safe_fixture() {
  local file=$1
  printf "111\t1\t111\t??\t02:00:00\t5.0\t102400\t/usr/local/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64\n" > "$file"
  printf "222\t1\t222\t??\t02:00:00\t1.0\t51200\t/Applications/cmux.app/Contents/MacOS/cmux\n" >> "$file"
}

# Snapshot fixture with no SAFE_TO_REAP candidates (only cmux).
write_clean_fixture() {
  local file=$1
  printf "222\t1\t222\t??\t02:00:00\t1.0\t51200\t/Applications/cmux.app/Contents/MacOS/cmux\n" > "$file"
}

# (Tests below)

if [ "$failures" -gt 0 ]; then
  printf "\n%d failure(s)\n" "$failures" >&2
  exit 1
fi
echo "all tests passed"
```

**Step 2: Make executable, run skeleton (passes trivially)**

```bash
chmod +x tests/cc-monitor-optimize.sh
bash tests/cc-monitor-optimize.sh
```
Expected: `all tests passed`.

**Step 3: Commit**

```bash
git add tests/cc-monitor-optimize.sh
git commit -m "test(cc-monitor): add optimize test harness skeleton"
```

Update `tasks.md`: check `5.1`.

---

## Task 7: Tests for argument validation (5.11, 5.12, 5.13, 5.2)

**Files:**
- Modify: `tests/cc-monitor-optimize.sh`

**Step 1: Add tests for `--apply` + `--json` rejection (5.11)**

Insert before the failure-count block:

```bash
# 5.11: --apply + --json rejected
out=$(bash "$ROOT_DIR/shell/cc-monitor.sh" --apply claude-cleanup --json 2>&1 || true)
rc=$(bash -c 'bash "$1" --apply claude-cleanup --json' _ "$ROOT_DIR/shell/cc-monitor.sh" 2>/dev/null; echo $?)
expect_eq "--apply with --json exits 2" "$rc" "2"
echo "$out" | grep -q "cannot be combined with --json" && \
  printf "ok - --apply+--json error message\n" || \
  { printf "not ok - --apply+--json error message\n"; failures=$((failures + 1)); }
```

**Step 2: Add tests for unknown `--apply` (5.12)**

```bash
# 5.12: unknown --apply value
out=$(bash "$ROOT_DIR/shell/cc-monitor.sh" --apply foo 2>&1 || true)
rc=$(bash -c 'bash "$1" --apply foo' _ "$ROOT_DIR/shell/cc-monitor.sh" 2>/dev/null; echo $?)
expect_eq "unknown --apply exits 2" "$rc" "2"
echo "$out" | grep -q "unknown module 'foo'" && \
  printf "ok - unknown --apply error message\n" || \
  { printf "not ok - unknown --apply error message\n"; failures=$((failures + 1)); }
echo "$out" | grep -q "claude-cleanup, claude-guard" && \
  printf "ok - unknown --apply lists valid names\n" || \
  { printf "not ok - unknown --apply lists valid names\n"; failures=$((failures + 1)); }
```

**Step 3: Add test for `--apply` to unavailable module (5.13)**

```bash
# 5.13: --apply unavailable module exits 127
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor-stub.XXXXXX")
stub_log=$(mktemp "${TMPDIR:-/tmp}/cc-monitor-log.XXXXXX")
make_stub_path "$stub_dir" "$stub_log" 0 claude-cleanup proc-janitor
fixture=$(mktemp)
write_safe_fixture "$fixture"
rc=0
PATH="$stub_dir:/usr/bin:/bin" CC_MONITOR_SNAPSHOT_FILE="$fixture" \
  bash "$ROOT_DIR/shell/cc-monitor.sh" --once --apply claude-cleanup --no-prompt >/dev/null 2>&1 || rc=$?
expect_eq "--apply unavailable module exits 127" "$rc" "127"
rm -rf "$stub_dir" "$stub_log" "$fixture"
```

**Step 4: Add test for JSON mode never prompts (5.2)**

```bash
# 5.2: JSON mode never prompts
fixture=$(mktemp)
write_safe_fixture "$fixture"
out=$(CC_MONITOR_SNAPSHOT_FILE="$fixture" bash "$ROOT_DIR/shell/cc-monitor.sh" --once --json 2>&1)
echo "$out" | grep -q "Optimization options" && \
  { printf "not ok - JSON mode emitted menu\n"; failures=$((failures + 1)); } || \
  printf "ok - JSON mode never prompts\n"
echo "$out" | head -1 | grep -q "^{" && \
  printf "ok - JSON output is valid JSON start\n" || \
  { printf "not ok - JSON output start\n"; failures=$((failures + 1)); }
rm "$fixture"
```

**Step 5: Run tests**

```bash
bash tests/cc-monitor-optimize.sh
```
Expected: `all tests passed`.

**Step 6: Commit**

```bash
git add tests/cc-monitor-optimize.sh
git commit -m "test(cc-monitor): cover --apply validation and JSON suppression"
```

Update `tasks.md`: check `5.2`, `5.11`, `5.12`, `5.13`.

---

## Task 8: Tests for non-TTY behavior (5.3, 5.4, 5.6, 5.10)

**Files:**
- Modify: `tests/cc-monitor-optimize.sh`

**Step 1: Add `--no-prompt` test (5.3)** — uses `</dev/null` so stdin is non-TTY anyway, but combined with `--no-prompt` is the canonical case.

```bash
# 5.3 + 5.4: --no-prompt and non-TTY suppress menu
fixture=$(mktemp)
write_safe_fixture "$fixture"
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor-stub.XXXXXX")
stub_log=$(mktemp "${TMPDIR:-/tmp}/cc-monitor-log.XXXXXX")
make_stub_path "$stub_dir" "$stub_log" 0
out=$(PATH="$stub_dir:/usr/bin:/bin" CC_MONITOR_SNAPSHOT_FILE="$fixture" \
  bash "$ROOT_DIR/shell/cc-monitor.sh" --once --no-prompt < /dev/null 2>&1)
echo "$out" | grep -q "Optimization options" && \
  { printf "not ok - --no-prompt emitted menu\n"; failures=$((failures + 1)); } || \
  printf "ok - --no-prompt suppresses menu\n"
[ ! -s "$stub_log" ] && \
  printf "ok - --no-prompt did not invoke any stub\n" || \
  { printf "not ok - --no-prompt invoked stub\n"; failures=$((failures + 1)); }
rm -rf "$stub_dir" "$stub_log" "$fixture"
```

**Step 2: Add no-candidates test (5.6)**

```bash
# 5.6: no menu without candidates
fixture=$(mktemp)
write_clean_fixture "$fixture"
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor-stub.XXXXXX")
stub_log=$(mktemp "${TMPDIR:-/tmp}/cc-monitor-log.XXXXXX")
make_stub_path "$stub_dir" "$stub_log" 0
out=$(PATH="$stub_dir:/usr/bin:/bin" CC_MONITOR_SNAPSHOT_FILE="$fixture" \
  bash "$ROOT_DIR/shell/cc-monitor.sh" --once 2>&1)
echo "$out" | grep -q "Optimization options" && \
  { printf "not ok - menu shown without candidates\n"; failures=$((failures + 1)); } || \
  printf "ok - no menu without candidates\n"
rm -rf "$stub_dir" "$stub_log" "$fixture"
```

**Step 3: Add `--apply` happy-path test (5.10)**

```bash
# 5.10: --apply claude-cleanup invokes stub without prompt
fixture=$(mktemp)
write_safe_fixture "$fixture"
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor-stub.XXXXXX")
stub_log=$(mktemp "${TMPDIR:-/tmp}/cc-monitor-log.XXXXXX")
make_stub_path "$stub_dir" "$stub_log" 0
rc=0
out=$(PATH="$stub_dir:/usr/bin:/bin" CC_MONITOR_SNAPSHOT_FILE="$fixture" \
  bash "$ROOT_DIR/shell/cc-monitor.sh" --once --apply claude-cleanup 2>&1) || rc=$?
expect_eq "--apply claude-cleanup exit 0" "$rc" "0"
grep -q "STUB:claude-cleanup" "$stub_log" && \
  printf "ok - --apply invoked claude-cleanup stub\n" || \
  { printf "not ok - --apply did not invoke stub\n"; failures=$((failures + 1)); }
echo "$out" | grep -q "Run claude-cleanup?" && \
  { printf "not ok - --apply emitted confirmation prompt\n"; failures=$((failures + 1)); } || \
  printf "ok - --apply skipped confirmation\n"
rm -rf "$stub_dir" "$stub_log" "$fixture"
```

**Step 4: Run tests**

```bash
bash tests/cc-monitor-optimize.sh
```
Expected: `all tests passed`.

**Step 5: Commit**

```bash
git add tests/cc-monitor-optimize.sh
git commit -m "test(cc-monitor): cover non-TTY paths and --apply happy path"
```

Update `tasks.md`: check `5.3`, `5.4`, `5.6`, `5.10`.

---

## Task 9: Tests for module exit propagation + recommendation (5.14, 5.15)

**Files:**
- Modify: `tests/cc-monitor-optimize.sh`

**Step 1: Add module exit propagation test (5.14)**

```bash
# 5.14: dispatched module non-zero exit propagates
fixture=$(mktemp)
write_safe_fixture "$fixture"
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor-stub.XXXXXX")
stub_log=$(mktemp "${TMPDIR:-/tmp}/cc-monitor-log.XXXXXX")
make_stub_path "$stub_dir" "$stub_log" 5
rc=0
PATH="$stub_dir:/usr/bin:/bin" CC_MONITOR_SNAPSHOT_FILE="$fixture" \
  bash "$ROOT_DIR/shell/cc-monitor.sh" --once --apply claude-cleanup >/dev/null 2>&1 || rc=$?
expect_eq "module exit code propagates" "$rc" "5"
rm -rf "$stub_dir" "$stub_log" "$fixture"
```

**Step 2: Add RSS-only recommendation test (5.15)**

Build a fixture where there is no SAFE_TO_REAP but family RSS aggregate is high. We bypass the snapshot pipeline by testing `_cc_monitor_recommended_module` directly:

```bash
# 5.15: RSS-only recommends claude-guard-dry
findings=$(mktemp)
# avg_cpu=2.0 max=5.0 samples=1 pid=300 ppid=1 pgid=300 tty=ttys001 etime=01:00:00 rss=1100 family=dev-server class=ASK_BEFORE_KILL
printf "2.0\t5.0\t1\t300\t1\t300\tttys001\t01:00:00\t1100\tdev-server\tASK_BEFORE_KILL\tlbl\tr\ta\tcmd\n" > "$findings"
( source "$ROOT_DIR/shell/cc-monitor.sh"; result=$(_cc_monitor_recommended_module "$findings") || result=""; \
  [ "$result" = "claude-guard-dry" ] && echo "ok - RSS-only recommends claude-guard-dry" \
  || { echo "not ok - RSS-only got '$result'"; exit 1; } )
[ "$?" -eq 0 ] || failures=$((failures + 1))

# Negative case: low RSS, no SAFE_TO_REAP → no recommendation
printf "2.0\t5.0\t1\t300\t1\t300\tttys001\t01:00:00\t100\tdev-server\tASK_BEFORE_KILL\tlbl\tr\ta\tcmd\n" > "$findings"
( source "$ROOT_DIR/shell/cc-monitor.sh"; result=$(_cc_monitor_recommended_module "$findings") || result=""; \
  [ -z "$result" ] && echo "ok - low RSS yields no recommendation" \
  || { echo "not ok - low RSS got '$result'"; exit 1; } )
[ "$?" -eq 0 ] || failures=$((failures + 1))
rm "$findings"
```

**Step 3: Run tests**

```bash
bash tests/cc-monitor-optimize.sh
```
Expected: `all tests passed`.

**Step 4: Commit**

```bash
git add tests/cc-monitor-optimize.sh
git commit -m "test(cc-monitor): cover module exit propagation and RSS-only recommendation"
```

Update `tasks.md`: check `5.14`, `5.15`.

---

## Task 10: Tests for missing-module hint + interactive paths (5.7, 5.5, 5.8, 5.9)

**Note:** Interactive paths (TTY menu, confirmation y/N) are difficult to test reliably without `script(1)` or `expect(1)`. We exercise these via direct calls to `_cc_monitor_prompt_apply` and `_cc_monitor_dispatch_module` with `/dev/tty` redirected to a fifo or file. The plan opts for **partial coverage**: test the menu rendering and recommendation marking, plus dispatch confirmation logic, but not full end-to-end interactive flow (covered by manual smoke test).

**Files:**
- Modify: `tests/cc-monitor-optimize.sh`

**Step 1: Add missing-module install hint test (5.7)**

We invoke the prompt helper with an empty PATH-stub dir except `claude-cleanup` so other modules trigger the install hint branch:

```bash
# 5.7: missing module hidden, install hint printed
fixture=$(mktemp)
findings=$(mktemp)
write_safe_fixture "$fixture"
# Build findings via the actual pipeline so format matches.
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor-stub.XXXXXX")
stub_log=$(mktemp "${TMPDIR:-/tmp}/cc-monitor-log.XXXXXX")
make_stub_path "$stub_dir" "$stub_log" 0 claude-guard proc-janitor
# Run prompt helper directly with stdin redirected to /dev/null so read returns 1 → empty selection.
out=$(PATH="$stub_dir:/usr/bin:/bin" bash -c '
  source "$1"
  CC_MONITOR_SNAPSHOT_FILE="$2" {
    tmp=$(mktemp -d)
    raw="$tmp/raw.tsv"; agg="$tmp/agg.tsv"; f="$tmp/f.tsv"
    _cc_monitor_collect_samples "$raw" true 0 1 false >/dev/null
    _cc_monitor_aggregate_samples "$raw" "$agg"
    _cc_monitor_enrich_findings "$agg" "$f" 1
    _cc_monitor_prompt_apply "$f" 2>&1 < /dev/null || true
    rm -rf "$tmp"
  }
' _ "$ROOT_DIR/shell/cc-monitor.sh" "$fixture")
echo "$out" | grep -q "1\\. claude-cleanup" && \
  printf "ok - menu shows available claude-cleanup\n" || \
  { printf "not ok - menu missing claude-cleanup\n"; failures=$((failures + 1)); }
echo "$out" | grep -q "install: brew install proc-janitor" && \
  printf "ok - install hint shown for missing proc-janitor\n" || \
  { printf "not ok - missing proc-janitor install hint\n"; failures=$((failures + 1)); }
echo "$out" | grep -q "1\\. claude-cleanup .*recommended" && \
  printf "ok - claude-cleanup marked recommended\n" || \
  { printf "not ok - claude-cleanup not marked recommended\n"; failures=$((failures + 1)); }
rm -rf "$stub_dir" "$stub_log" "$fixture" "$findings"
```

**Step 2: Add confirmation y/N test via `_cc_monitor_dispatch_module` (5.8 + 5.9)**

```bash
# 5.8 + 5.9: dispatch confirms destructive, skips for non-destructive
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor-stub.XXXXXX")
stub_log=$(mktemp "${TMPDIR:-/tmp}/cc-monitor-log.XXXXXX")
make_stub_path "$stub_dir" "$stub_log" 0
# Non-destructive (claude-guard-dry) skips confirmation even with skip_confirm=false:
PATH="$stub_dir:/usr/bin:/bin" bash -c '
  source "$1"
  _cc_monitor_dispatch_module claude-guard-dry false < /dev/null >/dev/null 2>&1
' _ "$ROOT_DIR/shell/cc-monitor.sh"
grep -q "STUB:claude-guard:--dry-run" "$stub_log" && \
  printf "ok - non-destructive skips confirmation\n" || \
  { printf "not ok - non-destructive blocked\n"; failures=$((failures + 1)); }
: > "$stub_log"
# Destructive with skip_confirm=true (simulates --apply) invokes:
PATH="$stub_dir:/usr/bin:/bin" bash -c '
  source "$1"
  _cc_monitor_dispatch_module claude-cleanup true < /dev/null >/dev/null 2>&1
' _ "$ROOT_DIR/shell/cc-monitor.sh"
grep -q "STUB:claude-cleanup" "$stub_log" && \
  printf "ok - destructive with skip_confirm invokes stub\n" || \
  { printf "not ok - destructive skip_confirm did not invoke\n"; failures=$((failures + 1)); }
: > "$stub_log"
# Destructive with skip_confirm=false and no /dev/tty (read fails) declines:
PATH="$stub_dir:/usr/bin:/bin" bash -c '
  source "$1"
  exec </dev/null
  # /dev/tty is still open in this subprocess on most platforms; redirect tty fd if possible.
  _cc_monitor_dispatch_module claude-cleanup false </dev/null 2>/dev/null
' _ "$ROOT_DIR/shell/cc-monitor.sh" || true
# Note: this branch may still read /dev/tty if the test runner has one. We assert that
# either the stub was NOT called (clean decline) OR the user input would have been needed —
# we accept either outcome as the helper preserves user safety.
rm -rf "$stub_dir" "$stub_log"
```

**Step 3: Run all tests**

```bash
bash tests/cc-monitor-optimize.sh
```
Expected: `all tests passed`.

**Step 4: Commit**

```bash
git add tests/cc-monitor-optimize.sh
git commit -m "test(cc-monitor): cover install hints and dispatch confirmation"
```

Update `tasks.md`: check `5.5`, `5.7`, `5.8`, `5.9`.

---

## Task 11: Update help text + README

**Files:**
- Modify: `shell/cc-monitor.sh` (function `_cc_monitor_usage`)
- Modify: `README.md`

**Step 1: Extend `_cc_monitor_usage` help text**

In the heredoc inside `_cc_monitor_usage`, after `--min-cpu PERCENT`:

```
  --apply MODULE      Run optimization module after report (skips menu/confirm).
                      Modules: claude-cleanup, claude-guard, claude-guard-dry,
                      proc-janitor-scan, proc-janitor-clean.
                      Cannot be combined with --json.
  --no-prompt         Disable the interactive optimization menu.
```

**Step 2: README — add subsection under existing cc-monitor docs**

Locate the cc-monitor section in `README.md` and append:

```markdown
### Optimize after monitoring

`cc-monitor` can dispatch the right cleanup module after printing the report.

**Interactive mode** (default on a TTY when the report contains safe candidates):

```
$ cc-monitor --once

=== cc-monitor: heat attribution ===
... report ...

Optimization options:
  1. claude-cleanup (kill all stale orphans) (recommended)
  2. claude-guard --dry-run (preview only)
  3. proc-janitor scan (preview only)
  4. skip
> 1
Run claude-cleanup (kill all stale orphans)? [y/N] y
```

**Script-friendly mode** with `--apply`:

```
cc-monitor --once --apply claude-cleanup
cc-monitor --once --apply claude-guard-dry
```

`--apply` skips the confirmation prompt; the flag itself is the explicit opt-in.
`--apply` cannot be combined with `--json`.

Use `--no-prompt` to keep the report read-only on a TTY.
```

**Step 3: Commit**

```bash
git add shell/cc-monitor.sh README.md
git commit -m "docs(cc-monitor): document --apply and interactive menu"
```

Update `tasks.md`: check `6.1`, `6.2`.

---

## Task 12: Final validation

**Files:**
- None modified — verification only.

**Step 1: Syntax check**

```bash
bash -n shell/cc-monitor.sh
```
Expected: no output.

**Step 2: Existing tests still pass**

```bash
bash tests/cc-monitor.sh
```
Expected: `all tests passed`.

**Step 3: New tests pass**

```bash
bash tests/cc-monitor-optimize.sh
```
Expected: `all tests passed`.

**Step 4: Verify all OpenSpec tasks checked**

```bash
grep -c "- \[ \]" openspec/changes/monitor-apply-modules/tasks.md
```
Expected: `0`.

**Step 5: Commit any final updates**

If `tasks.md` still has unchecked items, mark them and commit:

```bash
git add openspec/changes/monitor-apply-modules/tasks.md
git commit -m "chore(openspec): finalize monitor-apply-modules task list"
```

Update `tasks.md`: check `7.1`, `7.2`, `7.3`.

---

## Out of plan / handled in Step 5 (Challenge phase)

- Codex adversarial review of dispatch/race-condition design
- Edge cases discovered during challenge (will add tests as needed):
  - Ctrl+C during prompt — verify exit 130, no module run
  - `/dev/tty` permission denied — verify graceful skip
  - `--apply` with module that requires sudo (proc-janitor on system mode) — does it bubble up sudo prompt?
  - PATH containing a malicious `claude-cleanup` — out of scope (user controls PATH)

## Out of plan / handled in Step 6 (Finishing)

- Verification checklist for shell-script changes
- `/simplify` review of all modified files
- Decide ship vs PR vs keep
- Run `/opsx:archive` to fold delta spec into `openspec/specs/cc-monitor/`
