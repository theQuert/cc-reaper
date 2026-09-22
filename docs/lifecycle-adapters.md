# Lifecycle adapters

cc-reaper owns safety decisions; a project owns when a cleanup opportunity exists.
This separation keeps the installed tool general while allowing a CI-heavy repository to
connect its own PR, merge-gate and staging events.

## Stages

Call `~/.cc-reaper/lifecycle-reclaim.sh` after a stage completes:

```sh
~/.cc-reaper/lifecycle-reclaim.sh \
  --stage staging-complete \
  --repo "$GITHUB_WORKSPACE"
```

Supported stages are `session-end`, `pr-merged`, `merge-gate-complete`, and
`staging-complete`. The worktree janitor remains the only component allowed to remove a
worktree, and it repeats holder, claim, idle, content, lock and landed checks immediately
before removal. A lifecycle event is only a trigger; it is not permission to bypass those
gates.

## Builder cache

An adapter may produce a short-lived drain proof after it has stopped or drained its own
builder consumers. The proof is line-oriented and must contain:

```text
schema=1
scope=builder-cache
host=<current host>
context=<current docker context>
issued_at=<unix seconds>
expires_at=<unix seconds, at most 900 seconds after issued_at>
drained=1
```

Then pass it to the lifecycle hook:

```sh
~/.cc-reaper/lifecycle-reclaim.sh \
  --stage staging-complete \
  --repo "$GITHUB_WORKSPACE" \
  --drain-proof "$RUNNER_TEMP/cc-reaper-drain-proof"
```

cc-reaper binds the proof to the current host and Docker context, rejects stale proofs,
enforces a hard 900-second lifetime cap (a local adapter may choose a shorter value),
and checks configurable protected-container filters again immediately before pruning.
It never prunes volumes, running containers, or tagged images. The generic default filter
is `label=cc.reaper.protect=true`; a local adapter may add a runtime-specific filter in
`~/.cc-reaper/disk-janitor.conf`.

Missing, malformed, stale, foreign, or unverified proof is a no-op with an observable log
entry. This is intentional: a lifecycle integration failure must reduce cleanup, never
increase deletion scope.
