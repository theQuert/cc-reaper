## 1. Specify the shared policy

- [x] 1.1 Record cc-reaper as the policy owner and Claude/Codex hooks as triggers.
- [x] 1.2 Specify the 48-hour gate, six-hour cadence, and fail-closed active claims.

## 2. Red tests

- [x] 2.1 Prove the default settlement window is 48 hours.
- [x] 2.2 Prove verified-live Claude cwd and structured tool workdir claims keep a worktree.
- [x] 2.3 Prove open Codex writer-lock cwd and structured tool workdir claims keep a worktree.
- [x] 2.4 Prove stale Claude PID records and unopened Codex locks do not pin worktrees.
- [x] 2.5 Prove an unmappable live claim fails closed and a claim appearing before removal wins.
- [x] 2.6 Prove scheduled apply is config-gated and installer deployment is idempotent.
- [x] 2.7 Prove the installed fixed interval is operator-configurable within safe bounds.
- [x] 2.8 Prove a fresh Codex archive and recent inactive Claude transcript keep an otherwise removable worktree.
- [x] 2.9 Prove expired leases stop pinning worktrees and `--claims` exposes the same lease evidence read-only.
- [x] 2.10 Prove an archive-during-scan remaps to the archived rollout without claiming unrelated worktrees.
- [x] 2.11 Prove one activity snapshot indexes a large transcript once across multiple candidate paths.
- [x] 2.12 Prove the actual LaunchAgent logs are bounded and scheduled runs have start/end evidence.
- [x] 2.13 Prove unchanged transcript indexes persist across scheduled snapshots and a changed transcript invalidates them.
- [x] 2.14 Prove multiple candidate paths start at most one transcript-query interpreter per activity snapshot without weakening malformed-record fail-closed behavior.

## 3. Implementation

- [x] 3.1 Load the cc-reaper worktree config without overriding explicit environment values.
- [x] 3.2 Add shared active-session discovery and pre-removal refresh.
- [x] 3.3 Add harness repository discovery and common-directory deduplication.
- [x] 3.4 Add the shared hook entrypoint and generic session logging.
- [x] 3.5 Deploy the config and six-hour LaunchAgent from `install.sh`.
- [x] 3.6 Expose the shared landed proof as a read-only query for attached-resource reapers.
- [x] 3.7 Migrate the Claude-private orphan hook path and deploy both lifecycle hooks for explicit Codex repositories.
- [x] 3.8 Add bounded recent-session leases and observable live/recent claim diagnostics.
- [x] 3.9 Reconcile Codex archive races through current state and cache transcript-tail evidence per snapshot.
- [x] 3.10 Bound the installed log paths and delimit scheduled runs with elapsed/status evidence.
- [x] 3.11 Persist offset-only scheduled transcript indexes behind exact file-identity validation.
- [x] 3.12 Materialize a private per-snapshot structured-tool search projection so candidate matching does not start an interpreter for every transcript/worktree pair.

## 4. Integration and proof

- [x] 4.1 Update README and reclamation method documentation.
- [x] 4.2 Point the stima Codex SessionEnd adapter at cc-reaper; provide the Claude hook command.
- [x] 4.3 Run shell syntax checks and the full repository test suite.
- [x] 4.4 Run strict OpenSpec validation and a real report-only inventory.
- [ ] 4.5 Record activation as pending until reviewed changes reach clean canonical main.
