# Reclaim an accepted task's worktree without the idle and session windows

## Why

A finished task's worktree waits out two 48-hour windows before a sweep may remove it: the
idle window (nothing in it modified within `CC_WJ_IDLE_HOURS`) and the recent-session lease
(no Claude or Codex activity mapped to it within `CC_WJ_SESSION_GRACE_HOURS`). Both exist
because the janitor cannot tell finished work from paused work. The dev loop in the stima-api
repository can: it knows when a task was accepted and is live. The founder asked that such a
worktree be reclaimed promptly and safely instead of sitting out both windows. The loop will
record acceptance as an annotation file beside the worktree's `claude-task-worktree` marker.

## What Changes

- The janitor reads `<the worktree's absolute git dir>/claude-task-done`, key=value lines of
  which only `head=` matters. A worktree is *done* when it is clean, the file has exactly one
  well-formed `head=<40 lowercase hex>` line, that value is the worktree's current HEAD, and
  HEAD is on a branch. Anything else is not done and changes nothing.
- For a done worktree only: the recent-session lease is not asked, before landing, before
  classification or before a removal; a lease answer from the live-claim check is not a keep
  reason; and the idle window is 0 hours, at classification and before a removal.
- Unchanged: missing directory, lock, submodule and git state; the holder scans and their
  failure modes; dirty and unrebuildable content; live Claude and Codex claims, including a
  live claim read after a lease answer; the landed proofs, or the abandoned path; the
  detached-HEAD rule; `KEEP(this-session)`; the HEAD, holder and content rechecks before a
  removal. Branches are never deleted.
- Before a removal the annotation is read again, so a waiver it no longer supports is
  withdrawn.
- The inventory prints `    done: claude-task-done at HEAD <12-char sha>` for a done worktree.
  No existing line changes.

## Impact

- `shell/worktree-janitor.sh`: `_cc_wj_done`, `_cc_wj_live_claim` and the inventory loop.
  `_cc_wj_classify` does not change. `--trim-regenerable` ignores the annotation.
- Tests: new cases in `tests/worktree-janitor.sh` and `tests/worktree-active-sessions.sh`;
  no existing case changes.
- Docs: `docs/worktree-reclamation.md`, `CHANGELOG.md`.
- Rollback: revert the commit. Annotation files are then inert.
