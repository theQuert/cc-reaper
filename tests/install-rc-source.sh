#!/usr/bin/env bash
# The shell rc lines install.sh writes must outlive the checkout it ran from, and nothing
# about the rc file may stop the install.
#
# Measured 2026-09-15: ~/.zshrc sourced claude-cleanup.sh and cc-monitor.sh from a task
# worktree that reclamation had removed. Every interactive shell printed two
# "no such file or directory" errors, the commands were gone, and re-running the
# installer changed nothing. Review of the first repair then found it aborting the whole
# install on a read-only rc file, breaking hard links, backing up after its own append,
# and never converging when a stale line was commented out or sat beside the new one.
#
# Everything runs against sandbox HOMEs with launchctl stubbed, removed on exit.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
ok()  { printf "ok - %s\n" "$1"; }
bad() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-install-rc.XXXXXX")"
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
for c in launchctl brew cargo osascript; do
  printf '#!/bin/sh\nexit 0\n' > "$STUBS/$c"; chmod +x "$STUBS/$c"
done
# A cp that cannot write an rc backup, and copies everything else.
NOBACKUP="$WORK/nobackup"
mkdir -p "$NOBACKUP"
printf '#!/bin/sh\ncase "$*" in *cc-reaper-backup-*) exit 1 ;; esac\nexec /bin/cp "$@"\n' > "$NOBACKUP/cp"
chmod +x "$NOBACKUP/cp"

# Called as $(sandbox_home): a counter bumped in here would be lost with the subshell, and
# every scenario would share one home - which made this suite pass and fail for the wrong
# reasons until the name came from mktemp.
sandbox_home() {
  local h
  h="$(mktemp -d "$WORK/home.XXXXXX")"
  mkdir -p "$h/Library/LaunchAgents" "$h/.claude/hooks" "$h/.cc-reaper/logs"
  printf '%s' "$h"
}

# Every scenario checks the installer finished: a repair that aborts step 1 leaves the
# hook, the monitor and every janitor undeployed.
install_into() {
  # /bin/bash, the shebang's shell: with a newer bash first in PATH, `bash` would not run 3.2.
  HOME="$1" CC_REAPER_DAEMON=b PATH="${EXTRA_PATH:+$EXTRA_PATH:}$STUBS:$PATH" /bin/bash "$ROOT_DIR/install.sh" < /dev/null > "$1/install.out" 2>&1
  echo "$?" > "$1/install.rc"
}
completed() {
  [ "$(cat "$1/install.rc")" = 0 ] && ! grep -q 'INSTALL DID NOT COMPLETE' "$1/install.out" &&
    [ -f "$1/.cc-reaper/claude-cleanup.sh" ] && [ -f "$1/.cc-reaper/cc-monitor.sh" ]
}

want_cleanup='[ -r "$HOME/.cc-reaper/claude-cleanup.sh" ] && source "$HOME/.cc-reaper/claude-cleanup.sh"'
want_monitor='[ -r "$HOME/.cc-reaper/cc-monitor.sh" ] && source "$HOME/.cc-reaper/cc-monitor.sh"'
count_line() { grep -cxF -- "$2" "$1" 2>/dev/null; }
backups() { ls "$1"/.zshrc.cc-reaper-backup-* 2>/dev/null | wc -l | tr -d ' '; }

# ─── Fresh install ────────────────────────────────────────────────────────────
H="$(sandbox_home)"
: > "$H/.zshrc"
install_into "$H"
completed "$H"; check "a fresh install completes" $?
[ "$(count_line "$H/.zshrc" "$want_cleanup")" = 1 ]; check "a fresh install sources the deployed claude-cleanup.sh, guarded" $?
[ "$(count_line "$H/.zshrc" "$want_monitor")" = 1 ]; check "a fresh install sources the deployed cc-monitor.sh, guarded" $?
! grep -qF "$ROOT_DIR" "$H/.zshrc"; check "no rc line names the checkout the installer ran from" $?

# ─── Repeated install, and deploy by rename ───────────────────────────────────
before_backups="$(backups "$H")"
inode_cleanup="$(stat -f %i "$H/.cc-reaper/claude-cleanup.sh")"
inode_hook="$(stat -f %i "$H/.claude/hooks/stop-cleanup-orphans.sh")"
install_into "$H"
completed "$H"; check "a repeated install completes" $?
[ "$(count_line "$H/.zshrc" "$want_cleanup")" = 1 ] && [ "$(count_line "$H/.zshrc" "$want_monitor")" = 1 ]
check "a second install adds no second line" $?
[ "$(backups "$H")" = "$before_backups" ]; check "an rc file with nothing to change gets no backup" $?
[ "$(stat -f %i "$H/.cc-reaper/claude-cleanup.sh")" != "$inode_cleanup" ] &&
  cmp -s "$H/.cc-reaper/claude-cleanup.sh" "$ROOT_DIR/shell/claude-cleanup.sh"
check "a deployed script is replaced by rename, with the repository's content" $?
[ "$(stat -f %i "$H/.claude/hooks/stop-cleanup-orphans.sh")" != "$inode_hook" ]
check "the stop hook is replaced by rename" $?
[ -z "$(ls -A "$H/.cc-reaper" | grep '^\.')" ] && [ -z "$(ls -A "$H/.claude/hooks" | grep '^\.')" ]
check "no temporary file is left beside a deployed script" $?

# ─── Stale lines from a removed checkout ──────────────────────────────────────
H="$(sandbox_home)"
cat > "$H/.zshrc" <<'EOF'
export EDITOR=vim
# Claude Code cleanup functions
source "/Users/me/GitHub/cc-reaper-worktrees/janitor-blindspots/shell/claude-cleanup.sh"
source "/Users/me/GitHub/cc-reaper-worktrees/janitor-blindspots/shell/cc-monitor.sh"
alias ll='ls -l'
EOF
# 640, not mktemp's 600: a rewrite that dropped the mode would still pass at 600.
chmod 640 "$H/.zshrc"
xattr -w com.cc-reaper.test kept "$H/.zshrc"
cp -p "$H/.zshrc" "$H/original"
install_into "$H"
completed "$H"; check "an install over stale lines completes" $?
[ "$(count_line "$H/.zshrc" "$want_cleanup")" = 1 ] && [ "$(count_line "$H/.zshrc" "$want_monitor")" = 1 ]
check "stale installer lines are replaced by the deployed-copy lines" $?
! grep -q 'janitor-blindspots' "$H/.zshrc"; check "no line still names the removed checkout" $?
grep -qxF 'export EDITOR=vim' "$H/.zshrc" && grep -qxF "alias ll='ls -l'" "$H/.zshrc" &&
  [ "$(wc -l < "$H/.zshrc")" -eq "$(wc -l < "$H/original")" ]
check "every other line is left as it was" $?
[ "$(stat -f %Lp "$H/.zshrc")" = 640 ]; check "the rewritten rc file keeps its mode" $?
[ "$(xattr -p com.cc-reaper.test "$H/.zshrc" 2>/dev/null)" = kept ]; check "and its extended attributes" $?
backup="$(ls "$H"/.zshrc.cc-reaper-backup-* 2>/dev/null | head -1)"
[ -n "$backup" ] && cmp -s "$backup" "$H/original"; check "the rc file is backed up before it is changed" $?
grep -qF 'janitor-blindspots/shell/claude-cleanup.sh' "$H/install.out"
check "the installer prints the line it replaced" $?
STALE_HOME="$H"

# ─── The backup is the file as it was, even when an append comes first ───────
H="$(sandbox_home)"
printf 'source "/gone/worktree/shell/cc-monitor.sh"\n' > "$H/.zshrc"
cp "$H/.zshrc" "$H/original"
install_into "$H"
completed "$H"; check "an append-then-repair install completes" $?
backup="$(ls "$H"/.zshrc.cc-reaper-backup-* 2>/dev/null | head -1)"
[ "$(backups "$H")" = 1 ] && cmp -s "$backup" "$H/original"
check "one backup, identical to the rc file before the run" $?

# ─── Stale and current lines together ─────────────────────────────────────────
H="$(sandbox_home)"
printf '%s\n%s\n%s\n' "$want_cleanup" 'source "/gone/worktree/shell/claude-cleanup.sh"' "$want_monitor" > "$H/.zshrc"
install_into "$H"
completed "$H"; check "an install over mixed lines completes" $?
[ "$(count_line "$H/.zshrc" "$want_cleanup")" = 1 ] && ! grep -q '/gone/worktree' "$H/.zshrc"
check "a stale line beside the current one is removed" $?

# ─── A commented-out stale line ───────────────────────────────────────────────
H="$(sandbox_home)"
printf '# source "/gone/worktree/shell/claude-cleanup.sh"\n' > "$H/.zshrc"
install_into "$H"
completed "$H"; check "an install over a commented line completes" $?
[ "$(count_line "$H/.zshrc" "$want_cleanup")" = 1 ]; check "a commented-out line does not stop the current line being added" $?
grep -qxF '# source "/gone/worktree/shell/claude-cleanup.sh"' "$H/.zshrc"; check "and the comment is left as it was" $?

# ─── A line the installer did not write ───────────────────────────────────────
H="$(sandbox_home)"
printf '%s\n' '[ -f ~/work/cc-reaper/shell/claude-cleanup.sh ] && . ~/work/cc-reaper/shell/claude-cleanup.sh' > "$H/.zshrc"
install_into "$H"
completed "$H"; check "an install over a hand-written line completes" $?
grep -qxF '[ -f ~/work/cc-reaper/shell/claude-cleanup.sh ] && . ~/work/cc-reaper/shell/claude-cleanup.sh' "$H/.zshrc"
check "a hand-written line is left unchanged" $?
[ "$(grep -c 'claude-cleanup.sh' "$H/.zshrc")" = 1 ]; check "and no second claude-cleanup line is added beside it" $?
grep -q 'left unchanged' "$H/install.out" && grep -qF '~/work/cc-reaper/shell/claude-cleanup.sh' "$H/install.out"
check "and the installer names the line it left alone" $?

# ─── An append after a last line with no newline ──────────────────────────────
# The header is already there, so only the newline check starts the appended line.
H="$(sandbox_home)"
printf '# Claude Code cleanup functions\n%s' "$want_cleanup" > "$H/.zshrc"
install_into "$H"
completed "$H"; check "an install over an rc file without a final newline completes" $?
[ "$(count_line "$H/.zshrc" "$want_cleanup")" = 1 ] && [ "$(count_line "$H/.zshrc" "$want_monitor")" = 1 ]
check "an appended line starts on its own line" $?

# ─── A stale line beside a line the installer did not write ───────────────────
H="$(sandbox_home)"
printf '%s\n' 'source "/gone/worktree/shell/claude-cleanup.sh"' '. /gone/other/shell/claude-cleanup.sh' > "$H/.zshrc"
install_into "$H"
completed "$H"; check "an install over a stale line beside a hand-written one completes" $?
! grep -q '/gone/worktree' "$H/.zshrc" && grep -qxF '. /gone/other/shell/claude-cleanup.sh' "$H/.zshrc" &&
  [ "$(count_line "$H/.zshrc" "$want_cleanup")" = 0 ]
check "the stale line is removed, the hand-written one kept, and nothing added beside it" $?
grep -q 'left unchanged' "$H/install.out" && grep -qF '. /gone/other/shell/claude-cleanup.sh' "$H/install.out"
check "and the installer names the hand-written line" $?

# ─── No rc file yet ───────────────────────────────────────────────────────────
H="$(sandbox_home)"
install_into "$H"
completed "$H"; check "an install with no rc file completes" $?
[ "$(count_line "$H/.zshrc" "$want_cleanup")" = 1 ] && [ "$(count_line "$H/.zshrc" "$want_monitor")" = 1 ]
check "a missing rc file is created with both lines" $?
[ "$(backups "$H")" = 0 ]; check "and no backup is taken of the file the run created" $?

# ─── rc files that must not be changed ────────────────────────────────────────
H="$(sandbox_home)"
mkdir -p "$H/dotfiles"
printf 'source "/gone/worktree/shell/claude-cleanup.sh"\n' > "$H/dotfiles/zshrc"
cp "$H/dotfiles/zshrc" "$H/original"
ln -s "$H/dotfiles/zshrc" "$H/.zshrc"
install_into "$H"
completed "$H"; check "an install with a symlinked rc file completes" $?
[ -L "$H/.zshrc" ] && cmp -s "$H/dotfiles/zshrc" "$H/original"; check "a symlinked rc file stays a symlink, its target unchanged" $?
grep -qF "$want_cleanup" "$H/install.out"; check "and the installer prints the replacement to make by hand" $?

H="$(sandbox_home)"
mkdir -p "$H/dotfiles"
printf 'source "/gone/worktree/shell/claude-cleanup.sh"\n' > "$H/dotfiles/zshrc"
cp "$H/dotfiles/zshrc" "$H/original"
ln "$H/dotfiles/zshrc" "$H/.zshrc"
install_into "$H"
completed "$H"; check "an install with a hard-linked rc file completes" $?
[ "$(stat -f %l "$H/.zshrc")" = 2 ] && cmp -s "$H/dotfiles/zshrc" "$H/original"
check "a hard-linked rc file keeps both links, unchanged" $?
grep -qF "$want_cleanup" "$H/install.out"; check "and the installer prints the replacement for it" $?

H="$(sandbox_home)"
printf 'source "/gone/worktree/shell/claude-cleanup.sh"\n' > "$H/.zshrc"
cp "$H/.zshrc" "$H/original"
chmod 444 "$H/.zshrc"
install_into "$H"
completed "$H"; check "an install with a read-only rc file completes and deploys everything" $?
cmp -s "$H/.zshrc" "$H/original"; check "a read-only rc file is left unchanged" $?
grep -qF "$want_cleanup" "$H/install.out"; check "and the installer prints the replacement for it" $?
# Refused up front, not by a rewrite that happens to fail: nothing to back up, and the reason named.
[ "$(backups "$H")" = 0 ] && grep -q 'is not writable' "$H/install.out"
check "and it is refused as not writable, with no backup taken" $?

H="$(sandbox_home)"
printf 'source "/gone/worktree/shell/claude-cleanup.sh"\n' > "$H/.zshrc"
chmod 000 "$H/.zshrc"
install_into "$H"
completed "$H"; check "an install with an unreadable rc file completes and deploys everything" $?
grep -q 'cannot be read' "$H/install.out"; check "and the installer says the rc file cannot be read" $?

# A change is never made without the backup that undoes it.
H="$(sandbox_home)"
printf 'source "/gone/worktree/shell/claude-cleanup.sh"\n' > "$H/.zshrc"
cp "$H/.zshrc" "$H/original"
EXTRA_PATH="$NOBACKUP" install_into "$H"
completed "$H"; check "an install whose rc backup fails completes" $?
cmp -s "$H/.zshrc" "$H/original"; check "an rc file that could not be backed up is left unchanged" $?
grep -qF "$want_cleanup" "$H/install.out"; check "and the installer prints the change to make by hand" $?

# ─── The functions load in a new shell ────────────────────────────────────────
if command -v zsh >/dev/null 2>&1; then
  H="$STALE_HOME"
  HOME="$H" ZDOTDIR="$H" zsh -ic 'whence -w claude-cleanup cc-monitor' > "$H/zsh.out" 2> "$H/zsh.err" < /dev/null
  grep -q 'claude-cleanup: function' "$H/zsh.out" && grep -q 'cc-monitor: function' "$H/zsh.out"
  check "an interactive zsh with the repaired rc defines claude-cleanup and cc-monitor" $?
  [ ! -s "$H/zsh.err" ]; check "and prints nothing to stderr" $?

  mv "$H/.cc-reaper" "$H/.cc-reaper.gone"
  HOME="$H" ZDOTDIR="$H" zsh -ic 'true' > /dev/null 2> "$H/zsh.err" < /dev/null
  [ ! -s "$H/zsh.err" ]; check "with the deployed copies missing, a new shell prints nothing" $?
fi

if [ "$failures" -eq 0 ]; then
  echo "install-rc-source: all tests passed"
else
  echo "install-rc-source: $failures failure(s)"
  exit 1
fi
