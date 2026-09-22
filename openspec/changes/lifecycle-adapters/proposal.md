# Lifecycle adapters for general storage reclamation

## Why

Worktree-preserving trim and builder-cache cleanup now exist, but a project-specific CI
runner drain flag and container name are not a reusable CC Reaper contract. A generic
installation needs an explicit lifecycle adapter while the janitor keeps ownership of
all destructive safety gates.

## What changes

- Add a short-lived, host/context-bound builder drain proof.
- Replace the hard-coded CI runner name check with configurable protected-container filters.
- Add a lifecycle hook for session, PR, merge-gate and staging completion events.
- Preserve fail-closed behavior for missing, stale, malformed or foreign proofs.

## Out of scope

CC Reaper does not infer GitHub event semantics, delete arbitrary project caches, prune
volumes, or encode stima-api-specific paths in the shared tool.
