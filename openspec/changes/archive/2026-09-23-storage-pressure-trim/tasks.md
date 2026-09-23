## 1. Specification

- [x] 1.1 Define trim mode as worktree-preserving and report-only by default.
- [x] 1.2 Require holder, live-session, recent-session, git-state and credential vetoes.
- [x] 1.3 Define decimal elapsed parsing for zero-padded `ps` fields.

## 2. Red tests

- [x] 2.1 Prove report mode names ignored `node_modules` and `.next` without deleting them.
- [x] 2.2 Prove an active holder prevents trimming and leaves both directories intact.
- [x] 2.3 Prove apply mode removes only regenerable directories and retains worktree, branch and
  authored files.
- [x] 2.4 Prove `08`, `09`, and day-prefixed elapsed values parse as decimal.

## 3. Implementation

- [x] 3.1 Add `--trim-regenerable` and safe per-directory rechecks.
- [x] 3.2 Fix `etime_to_seconds` arithmetic.
- [x] 3.3 Invoke trim from disk-janitor only under the existing low-disk threshold.

## 4. Verification

- [x] 4.1 Run the full cc-reaper shell suite from a clean process table.
- [x] 4.2 Validate the OpenSpec change and review the diff for destructive scope.
