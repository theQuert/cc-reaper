## 1. Specification

- [x] 1.1 Validate this change strictly; delete the superseded `lifecycle-adapters` change; move the
  `disk-janitor` spec's misplaced requirement under `## Requirements` and delete the superseded
  drain-proof one; reconcile the pending `janitors-that-can-see` and `coexist-with-dev-workflow`
  disk-janitor deltas; `openspec validate --all --strict` passes.

## 2. Worktree janitor

- [x] 2.1 Red then green: an executed run whose PATH lacks the tool directory still resolves `gh`
  from the appended directories and proves `landed=pr`; a run where `gh` resolves nowhere prints
  the degraded line once; sourcing leaves PATH unchanged.
- [x] 2.2 Red then green: an apply sweep that finds a live holder logs the deferral and exits 0;
  a lock that cannot be taken still exits non-zero.

## 3. Disk janitor

- [x] 3.1 `--clean` runs exactly `docker builder prune --force --filter until=168h` when the daemon
  is reachable; the docker allowlist test admits that one command and nothing else; an unreachable
  daemon skips it and counts the skip.
- [x] 3.2 Remove `--orbstack-clean`, drain-proof validation, protected-container filters,
  `hooks/lifecycle-reclaim.sh`, its installer entry, docs and tests; the config template keeps only
  generic overrides; the installer deletes a deployed `lifecycle-reclaim.sh`.

## 4. Resource watch

- [x] 4.1 A drop of at least 10 GB against a 25 to 45 minute old sample logs `ALERT:disk-drop` and
  notifies once per cooldown; a smaller drop, no comparable sample, and `CC_RW_DISK_DROP_GB=0`
  raise nothing; the sample file keeps at most 12 lines.

## 5. Folded storage-hardening work

- [x] 5.1 Isolate the absent-root janitor tests from real harness roots (552ea76); document
  `--trim-regenerable` in the README and installer banner (591b83f); ignore `__pycache__/`.

## 6. Verification and delivery

- [ ] 6.1 Full shell suite, `bash -n` and `zsh -n`, `openspec validate --all --strict`; independent
  review of the exact head.
- [ ] 6.2 Deploy by rename with a rollback manifest; live digests equal main; smoke `--check`, a
  report-only janitor run under launchd's PATH, and a resource-watch run; no LaunchAgent reload and
  no active session restarted.
