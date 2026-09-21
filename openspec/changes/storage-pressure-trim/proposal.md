# Why

The shared worktree janitor safely removes an entire landed worktree only after a 48-hour
settlement window and live Claude/Codex claim checks. That protects authored work, but it also
keeps several gigabytes of rebuildable `node_modules`, `.next`, and virtualenv output attached to
worktrees that cannot yet be removed. With frequent pull requests, the generated directories grow
faster than whole-worktree reclamation can keep up.

The orphan monitor also has a decimal parsing defect: zero-padded `08` and `09` elapsed fields from
`ps` are treated as octal by Bash arithmetic. The monitor then emits an error instead of making a
stale-process decision.

# What Changes

- Add a report-only-by-default `--trim-regenerable` janitor mode.
- Run the worktree-preserving trim from disk-janitor only when the measured host free-space
  percentage is below the existing pressure threshold; direct janitor runs remain dry-run by
  default.
- In apply mode, remove only ignored built-in regenerable directories from a worktree; retain the
  worktree, branch, tracked files, untracked authored files, and all non-regenerable ignored files.
- Require the existing process-holder, live-session, recent-session, git-state, and credential
  safety checks, and repeat the holder/session checks immediately before each directory removal.
- Keep trimming disabled for locked or unreadable worktrees and fail closed when status or activity
  evidence cannot be read.
- Parse monitor elapsed fields as decimal and cover `08`, `09`, and day-prefixed values in tests.

# Capabilities

## Modified Capabilities

- `worktree-janitor`: pressure trimming of rebuildable output without worktree removal.
- `cc-monitor`: decimal elapsed-time parsing for zero-padded `ps` values.

# Impact

- `shell/worktree-janitor.sh`: new opt-in trim mode and per-directory rechecks.
- `launchd/cc-reaper-monitor.sh`: safe elapsed parser.
- `tests/worktree-janitor.sh` and `tests/launchd-process-rules.sh`: safety and regression coverage.
