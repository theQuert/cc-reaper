#!/bin/bash
# Back up the work in progress of Claude Code worktrees to the remote, every 10 minutes.
#
# When the Mac mini is down, or its disk dies, uncommitted and unpushed work in its
# worktrees exists nowhere else, and whoever takes over an issue (docs/OPERATING-MODEL.md
# in stima-api: the outage protocol) starts from the last push. This keeps a snapshot of
# each active worktree on its own `origin` at refs/wip/<label>/<branch> (label `macmini`).
#
# A worktree is active when a live `claude` process has its cwd in it (lsof), or when a
# file in it changed in the last WIP_RECENT_MINUTES (360). For each one:
#   - the snapshot is HEAD plus staged, unstaged and untracked non-ignored files, built in
#     a temporary GIT_INDEX_FILE: read-tree HEAD (reusing the real index's stat data, so
#     unchanged files are not rehashed), add -A, write-tree, commit-tree -p HEAD. The
#     worktree, its index, its stash and its branches are never touched;
#   - a file over WIP_MAX_MB (20) is left out of the snapshot and logged;
#   - it is pushed only when it differs from the remote ref (tree or parent), and the push
#     force-updates that one ref, refs/wip/<label>/<branch>, nothing else. A clean worktree
#     whose HEAD is already the remote branch has nothing to back up and pushes nothing.
# One `git ls-remote` per repository per run reads the branches and this label's WIP refs.
#
# A WIP ref is deleted (the ref only; no branch is ever deleted, local or remote) when no
# worktree of the repository has that branch checked out and no live session is in one,
# and either the remote branch is merged into the remote's default branch, or the branch is
# gone from both the remote and the local repository and the snapshot is older than
# WIP_GONE_GRACE_HOURS (72). The grace keeps a never-pushed branch that was deleted by
# mistake recoverable for three days.
#
# Session scratchpads under /private/tmp/claude-<uid> are NOT pruned here:
# reclaim-byproducts.sh already does that under this repository's rules (idle 24h, the
# path-in-use liveness gate, no --force). See the README's "WIP backup" section.
#
# macOS stock tools and bash 3.2 only. Opt-in: install.sh does not enable it, because the
# label is host-specific. Install and uninstall: README, "WIP backup".
#
# Usage: wip-backup.sh [--dry-run]     one pass over every repository; --dry-run pushes and
#                                      deletes nothing and says what it would do
# Config (environment, or ~/.cc-reaper/wip-backup.conf, sourced when present):
#   WIP_REPOS            primary checkouts to scan, space-separated globs ($HOME/GitHub/*)
#   WIP_LABEL            the ref namespace under refs/wip/ (macmini)
#   WIP_REMOTE           the remote (origin)
#   WIP_RECENT_MINUTES   activity window (360)       WIP_MAX_MB  largest file kept (20)
#   WIP_GONE_GRACE_HOURS (72)                        WIP_SKIP_BRANCHES  ("main master")
# Log: one line per action, appended by the LaunchAgent to ~/.cc-reaper/logs/wip-backup.log
set -u

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  "") ;;
  -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
  *) echo "usage: wip-backup.sh [--dry-run]" >&2; exit 2 ;;
esac

CONF="${WIP_CONF:-$HOME/.cc-reaper/wip-backup.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
WIP_REPOS="${WIP_REPOS:-$HOME/GitHub/*}"
LABEL="${WIP_LABEL:-macmini}"
REMOTE="${WIP_REMOTE:-origin}"
RECENT="${WIP_RECENT_MINUTES:-360}"
MAX_BYTES=$(( ${WIP_MAX_MB:-20} * 1024 * 1024 ))
GRACE=$(( ${WIP_GONE_GRACE_HOURS:-72} * 3600 ))
SKIP=" ${WIP_SKIP_BRANCHES:-main master} "
LSOF="${WIP_LSOF:-lsof}"

# launchd gives no terminal: never wait on a prompt, never hang on a dead network.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=20}"
NET="-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wip-backup.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILED=0; PUSHED=0; SAME=0; DELETED=0

log() { echo "$(date +%Y-%m-%dT%H:%M:%S%z) wip-backup: $*"; }

size_of() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0; }

# The cwd of every live `claude` process, one canonical path per line.
"$LSOF" -nP -a -c claude -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u > "$TMP/live"

is_live() {  # $1 = canonical worktree path
  local cwd
  while IFS= read -r cwd; do
    case "$cwd" in "$1"|"$1"/*) return 0 ;; esac
  done < "$TMP/live"
  return 1
}

is_recent() {  # $1 = worktree path: any file changed inside the window, .git and deps aside
  [ -n "$(find "$1" \( -name .git -o -name node_modules \) -prune -o -type f -mmin "-$RECENT" -print 2>/dev/null | head -n 1)" ]
}

# Build the snapshot of worktree $1 (HEAD $2); prints the tree id.
snapshot_tree() {
  local wt="$1" head="$2" idx="$TMP/index" real list="$TMP/paths" kept="$TMP/kept" f
  rm -f "$idx" "$list" "$kept"
  real="$(git -C "$wt" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
  # read-tree -m with one tree is read-tree HEAD that keeps the stat data of entries whose
  # content matches, so only what changed is hashed below. Any trouble: a plain read-tree.
  if ! { [ -f "$real" ] && cp "$real" "$idx" 2>/dev/null &&
         GIT_INDEX_FILE="$idx" git -C "$wt" read-tree -m "$head" 2>/dev/null; }; then
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git -C "$wt" read-tree "$head" || return 1
  fi
  GIT_INDEX_FILE="$idx" git -C "$wt" ls-files -z -m -o --exclude-standard > "$list" || return 1
  : > "$kept"
  while IFS= read -r -d '' f; do
    if [ -f "$wt/$f" ] && [ ! -L "$wt/$f" ] && [ "$(size_of "$wt/$f")" -gt "$MAX_BYTES" ]; then
      log "skip file over ${WIP_MAX_MB:-20} MB: $wt/$f" >&2  # stdout is the tree id
      continue
    fi
    printf '%s\0' "$f" >> "$kept"
  done < "$list"
  if [ -s "$kept" ]; then
    GIT_INDEX_FILE="$idx" git -C "$wt" --literal-pathspecs add -A \
      --pathspec-from-file="$kept" --pathspec-file-nul 2>"$TMP/add.err" || {
      log "add failed in $wt: $(tr '\n' ' ' < "$TMP/add.err" | cut -c1-200)" >&2; return 1; }
  fi
  GIT_INDEX_FILE="$idx" git -C "$wt" write-tree
}

remote_sha() {  # $1 = full ref name; from this repository's ls-remote listing
  awk -v r="$1" '$2 == r { print $1; exit }' "$TMP/remote"
}

backup_worktree() {  # $1 = repo, $2 = worktree, $3 = branch, $4 = why
  local repo="$1" wt="$2" branch="$3" why="$4" head tree ref rsha commit
  ref="refs/wip/$LABEL/$branch"
  head="$(git -C "$wt" rev-parse -q --verify 'HEAD^{commit}')" || { log "skip $wt: no HEAD"; return 0; }
  tree="$(snapshot_tree "$wt" "$head")" || { log "FAIL snapshot $wt"; FAILED=1; return 0; }
  if [ "$tree" = "$(git -C "$wt" rev-parse "$head^{tree}")" ] &&
     [ "$(remote_sha "refs/heads/$branch")" = "$head" ]; then
    SAME=$((SAME + 1)); return 0  # clean and pushed: the branch itself is the backup
  fi
  rsha="$(remote_sha "$ref")"
  if [ -n "$rsha" ] && [ "$(git -C "$wt" rev-parse -q --verify "$rsha^{tree}" 2>/dev/null)" = "$tree" ] &&
     [ "$(git -C "$wt" rev-parse -q --verify "$rsha^1" 2>/dev/null)" = "$head" ]; then
    SAME=$((SAME + 1)); return 0
  fi
  if [ -z "$(git -C "$wt" config user.email)" ]; then
    export GIT_AUTHOR_NAME=wip-backup GIT_COMMITTER_NAME=wip-backup
    export GIT_AUTHOR_EMAIL="wip-backup@$(hostname -s 2>/dev/null || echo localhost)"
    export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  fi
  commit="$(git -C "$wt" commit-tree "$tree" -p "$head" \
    -m "wip($LABEL): $branch" -m "Snapshot of $wt ($why), HEAD $head, $(date +%Y-%m-%dT%H:%M:%S%z) on $(hostname -s 2>/dev/null)." )" ||
    { log "FAIL commit-tree $wt"; FAILED=1; return 0; }
  if [ "$DRY" = 1 ]; then
    log "would push $(basename "$repo") $ref ${commit:0:12} ($why)"; return 0
  fi
  # shellcheck disable=SC2086
  if git -C "$repo" $NET push -q --no-progress "$REMOTE" "+$commit:$ref" 2>"$TMP/push.err"; then
    log "pushed $(basename "$repo") $ref ${commit:0:12} ($why)"; PUSHED=$((PUSHED + 1))
  else
    log "FAIL push $(basename "$repo") $ref: $(tr '\n' ' ' < "$TMP/push.err" | cut -c1-200)"; FAILED=1
  fi
}

cleanup_refs() {  # $1 = repo; $TMP/held lists every branch checked out in it, $TMP/livebr the live ones
  local repo="$1" sha ref branch tip default ct now
  default="$(git -C "$repo" symbolic-ref -q "refs/remotes/$REMOTE/HEAD" 2>/dev/null || echo "refs/remotes/$REMOTE/main")"
  now="$(date +%s)"
  grep "	refs/wip/$LABEL/" "$TMP/remote" | while IFS="	" read -r sha ref; do
    branch="${ref#refs/wip/$LABEL/}"
    grep -qxF -- "$branch" "$TMP/held" && continue     # a worktree still has it: keep
    grep -qxF -- "$branch" "$TMP/livebr" && continue
    tip="$(remote_sha "refs/heads/$branch")"
    if [ -n "$tip" ]; then
      git -C "$repo" merge-base --is-ancestor "$tip" "$default" 2>/dev/null || continue
      why="merged into ${default#refs/remotes/}"
    else
      git -C "$repo" show-ref -q --verify "refs/heads/$branch" && continue
      ct="$(git -C "$repo" log -1 --format=%ct "$sha" 2>/dev/null)" || continue  # unknown age: keep
      [ -n "$ct" ] && [ $((now - ct)) -ge "$GRACE" ] || continue
      why="branch gone, snapshot $(( (now - ct) / 3600 ))h old"
    fi
    if [ "$DRY" = 1 ]; then log "would delete $(basename "$repo") $ref ($why)"; continue; fi
    # shellcheck disable=SC2086
    if git -C "$repo" $NET push -q --no-progress "$REMOTE" ":$ref" 2>"$TMP/del.err"; then
      log "deleted $(basename "$repo") $ref ($why)"
    else
      log "FAIL delete $(basename "$repo") $ref: $(tr '\n' ' ' < "$TMP/del.err" | cut -c1-200)"
      echo 1 > "$TMP/del.failed"
    fi
  done
}

backup_repo() {  # $1 = a primary checkout
  local repo="$1" line wt="" branch="" real why n=0
  git -C "$repo" remote get-url "$REMOTE" >/dev/null 2>&1 || return 0
  : > "$TMP/held"; : > "$TMP/livebr"; : > "$TMP/todo"
  git -C "$repo" worktree list --porcelain > "$TMP/wts" 2>/dev/null || return 0
  echo >> "$TMP/wts"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }"; branch="" ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      "")
        if [ -n "$wt" ] && [ -n "$branch" ] && [ -d "$wt" ]; then
          echo "$branch" >> "$TMP/held"
          real="$(cd "$wt" && pwd -P)"
          why=""
          if is_live "$real"; then why="live session"; echo "$branch" >> "$TMP/livebr"
          elif is_recent "$wt"; then why="changed in ${RECENT}m"
          fi
          case "$SKIP" in *" $branch "*) why="" ;; esac
          [ -n "$why" ] && printf '%s\t%s\t%s\n' "$wt" "$branch" "$why" >> "$TMP/todo"
        fi
        wt=""; branch="" ;;
    esac
  done < "$TMP/wts"
  # One listing per repository; none at all when nothing is active and the hourly cleanup
  # is not due, so an idle machine costs the remote nothing.
  local stamp="$STATE/$(printf '%s' "$repo" | cksum | cut -d' ' -f1).cleanup"
  if [ ! -s "$TMP/todo" ] && [ -n "$(find "$stamp" -mmin -60 2>/dev/null)" ]; then return 0; fi
  # shellcheck disable=SC2086
  if ! git -C "$repo" $NET ls-remote "$REMOTE" 'refs/heads/*' "refs/wip/$LABEL/*" > "$TMP/remote" 2>"$TMP/ls.err"; then
    log "FAIL ls-remote $(basename "$repo"): $(tr '\n' ' ' < "$TMP/ls.err" | cut -c1-200)"; FAILED=1; return 0
  fi
  while IFS="	" read -r wt branch why; do
    backup_worktree "$repo" "$wt" "$branch" "$why"
  done < "$TMP/todo"
  rm -f "$TMP/del.failed"
  cleanup_refs "$repo"
  [ -f "$TMP/del.failed" ] && FAILED=1
  [ "$DRY" = 1 ] || touch "$stamp"
}

STATE="${WIP_STATE_DIR:-$HOME/.cc-reaper/state/wip-backup}"
mkdir -p "$STATE"
for pattern in $WIP_REPOS; do
  for repo in $pattern; do
    [ -d "$repo/.git" ] || continue  # a primary checkout; its linked worktrees come from it
    backup_repo "$repo"
  done
done
log "done: pushed=$PUSHED unchanged=$SAME failed=$FAILED$([ "$DRY" = 1 ] && echo ' (dry run)')"
exit "$FAILED"
