#!/usr/bin/env bash
# The shell rc lines install.sh writes must outlive the checkout it ran from.
#
# Measured 2026-09-15: ~/.zshrc sourced claude-cleanup.sh and cc-monitor.sh from a task
# worktree that reclamation had removed. Every interactive shell printed two
# "no such file or directory" errors, the commands were gone, and re-running the
# installer changed nothing because the rc file already mentioned claude-cleanup.sh.
#
# Everything runs against a sandbox HOME with launchctl stubbed.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
ok()  { printf "ok - %s\n" "$1"; }
bad() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

STUBS="$(mktemp -d)"
for c in launchctl brew cargo osascript; do
  printf '#!/bin/sh\nexit 0\n' > "$STUBS/$c"; chmod +x "$STUBS/$c"
done

sandbox_home() {
  local h; h="$(mktemp -d)" || return 1
  mkdir -p "$h/Library/LaunchAgents" "$h/.claude/hooks" "$h/.cc-reaper/logs"
  printf '%s' "$h"
}

install_into() {
  HOME="$1" CC_REAPER_DAEMON=b PATH="$STUBS:$PATH" bash "$ROOT_DIR/install.sh" < /dev/null > "$1/install.out" 2>&1
}

want_cleanup='[ -r "$HOME/.cc-reaper/claude-cleanup.sh" ] && source "$HOME/.cc-reaper/claude-cleanup.sh"'
want_monitor='[ -r "$HOME/.cc-reaper/cc-monitor.sh" ] && source "$HOME/.cc-reaper/cc-monitor.sh"'
count_line() { grep -cxF -- "$2" "$1" 2>/dev/null; }

# ─── Fresh install ────────────────────────────────────────────────────────────
H="$(sandbox_home)"
: > "$H/.zshrc"
install_into "$H"
[ "$(count_line "$H/.zshrc" "$want_cleanup")" = 1 ]; check "a fresh install sources the deployed claude-cleanup.sh, guarded" $?
[ "$(count_line "$H/.zshrc" "$want_monitor")" = 1 ]; check "a fresh install sources the deployed cc-monitor.sh, guarded" $?
! grep -qF "$ROOT_DIR" "$H/.zshrc"; check "no rc line names the checkout the installer ran from" $?

# ─── Repeated install ─────────────────────────────────────────────────────────
install_into "$H"
[ "$(count_line "$H/.zshrc" "$want_cleanup")" = 1 ] && [ "$(count_line "$H/.zshrc" "$want_monitor")" = 1 ]
check "a second install adds no second line" $?
[ -z "$(ls "$H"/.zshrc.cc-reaper-backup-* 2>/dev/null)" ]; check "an rc file with nothing to repair gets no backup" $?

# ─── Stale lines from a removed checkout ──────────────────────────────────────
H2="$(sandbox_home)"
cat > "$H2/.zshrc" <<'EOF'
export EDITOR=vim
# Claude Code cleanup functions
source "/Users/me/GitHub/cc-reaper-worktrees/janitor-blindspots/shell/claude-cleanup.sh"
source "/Users/me/GitHub/cc-reaper-worktrees/janitor-blindspots/shell/cc-monitor.sh"
alias ll='ls -l'
EOF
cp "$H2/.zshrc" "$H2/original"
install_into "$H2"
[ "$(count_line "$H2/.zshrc" "$want_cleanup")" = 1 ] && [ "$(count_line "$H2/.zshrc" "$want_monitor")" = 1 ]
check "stale installer lines are replaced by the deployed-copy lines" $?
! grep -q 'janitor-blindspots' "$H2/.zshrc"; check "no line still names the removed checkout" $?
grep -qxF 'export EDITOR=vim' "$H2/.zshrc" && grep -qxF "alias ll='ls -l'" "$H2/.zshrc" &&
  [ "$(wc -l < "$H2/.zshrc")" -eq "$(wc -l < "$H2/original")" ]
check "every other line is left as it was" $?
backup="$(ls "$H2"/.zshrc.cc-reaper-backup-* 2>/dev/null | head -1)"
[ -n "$backup" ] && cmp -s "$backup" "$H2/original"; check "the rc file is backed up before it is changed" $?

# ─── A line the installer did not write ───────────────────────────────────────
H3="$(sandbox_home)"
cat > "$H3/.zshrc" <<'EOF'
[ -f ~/work/cc-reaper/shell/claude-cleanup.sh ] && . ~/work/cc-reaper/shell/claude-cleanup.sh
EOF
cp "$H3/.zshrc" "$H3/original"
install_into "$H3"
grep -qxF '[ -f ~/work/cc-reaper/shell/claude-cleanup.sh ] && . ~/work/cc-reaper/shell/claude-cleanup.sh' "$H3/.zshrc"
check "a hand-written line is left unchanged" $?
[ "$(grep -c 'claude-cleanup.sh' "$H3/.zshrc")" = 1 ]; check "and no second claude-cleanup line is added beside it" $?
grep -q 'left unchanged' "$H3/install.out" && grep -qF '~/work/cc-reaper/shell/claude-cleanup.sh' "$H3/install.out"
check "and the installer names the line it left alone" $?

# ─── A symlinked rc file ──────────────────────────────────────────────────────
# A dotfiles checkout owns the target; renaming a rewritten copy over the link would
# silently turn it into a detached file.
H4="$(sandbox_home)"
mkdir -p "$H4/dotfiles"
printf 'source "/gone/worktree/shell/claude-cleanup.sh"\n' > "$H4/dotfiles/zshrc"
cp "$H4/dotfiles/zshrc" "$H4/original"
ln -s "$H4/dotfiles/zshrc" "$H4/.zshrc"
install_into "$H4"
[ -L "$H4/.zshrc" ]; check "a symlinked rc file stays a symlink" $?
grep -qxF 'source "/gone/worktree/shell/claude-cleanup.sh"' "$H4/dotfiles/zshrc"
check "and its stale line is not rewritten through the link" $?
grep -q 'is a symlink; left unchanged' "$H4/install.out" && grep -qF "$want_cleanup" "$H4/install.out"
check "and the installer prints the replacement to make by hand" $?

# ─── The functions load in a new shell ────────────────────────────────────────
if command -v zsh >/dev/null 2>&1; then
  err="$H2/zsh.err"
  HOME="$H2" ZDOTDIR="$H2" zsh -ic 'whence -w claude-cleanup cc-monitor' > "$H2/zsh.out" 2> "$err" < /dev/null
  grep -q 'claude-cleanup: function' "$H2/zsh.out" && grep -q 'cc-monitor: function' "$H2/zsh.out"
  check "an interactive zsh with the repaired rc defines claude-cleanup and cc-monitor" $?
  ! grep -q 'no such file' "$err"; check "and prints no missing-file error" $?

  mv "$H2/.cc-reaper" "$H2/.cc-reaper.gone"
  HOME="$H2" ZDOTDIR="$H2" zsh -ic 'true' > /dev/null 2> "$err" < /dev/null
  ! grep -q 'no such file' "$err"; check "with the deployed copies missing, a new shell prints nothing" $?
fi

if [ "$failures" -eq 0 ]; then
  echo "install-rc-source: all tests passed"
else
  echo "install-rc-source: $failures failure(s)"
  exit 1
fi
