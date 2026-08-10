## 1. Shared session detection helper

- [x] 1.1 Add `_cc_reaper_session_pids` to `shell/claude-cleanup.sh`, emitting one PID per line
- [x] 1.2 Require a controlling terminal; exclude `??` / `?` / `-` so Desktop-hosted sessions and subagents drop out
- [x] 1.3 Require the `claude` executable plus a session flag; exclude `mcp-server`, `-p`/`--print`, and `--output-format`
- [x] 1.4 Support snapshot overrides so tests can feed a fixed process table without mocking `ps`

## 2. Route existing commands through the helper

- [x] 2.1 Replace the matcher in `claude-fd`
- [x] 2.2 Replace the matcher in `claude-sessions`
- [x] 2.3 Replace the matcher in `claude-guard`

## 3. zsh defects uncovered once the phases finally executed

Restoring detection exposed three latent faults on code paths that had never run,
because the session list was always empty. All three break `claude-guard` under zsh,
which is the shell this project installs into.

- [x] 3.1 Rename `local status` to `proc_status` in `claude-guard` and `claude-fd`; `status` is read-only in zsh, matching the naming `claude-sessions` already used
- [x] 3.2 Replace the parallel arrays walked by numeric index with single `pid<TAB>detail` record arrays; `${!arr[@]}` is `bad substitution` in zsh and `${arr[0]}` is empty
- [x] 3.3 Replace `seq 0 $((n-1))` idle-eviction indexing with a counter-bounded value loop

## 4. Codex review findings (PR #5)

Both reproduced against `8466a1e` before fixing.

- [x] 4.1 P2 — a `--settings` payload containing `12345 ttys999 /path/claude --session-id injected` passed every shape check and emitted `12345`; a live process with that PID over a threshold would have had its whole group reaped. Split detection so candidate PIDs come from `ps -eo pid=,tty=,comm=`, which carries no argument text, and fetch the command line per PID.
- [x] 4.2 P2 — a session whose `--settings` JSON held a hook mentioning `--output-format` was excluded, blinding all three commands to it. `_cc_reaper_is_session_cmd` now drops everything from the first `{` before testing any flag.
- [x] 4.3 Confirm genuine headless runs, `mcp-server`, and Desktop-hosted sessions are still excluded after the payload change
- [x] 4.4 Confirm the payload guard has teeth: removing the truncation fails 3 tests

## 5. Regression proof

- [x] 5.1 `tests/guard-session-detect.sh` covers every scenario in the spec delta, driving the command predicate and the table walker as separate seams
- [x] 5.2 Assert a forged process record inside `--settings` never becomes a PID
- [x] 5.3 Assert a payload flag neither disqualifies a real session nor qualifies a non-session
- [x] 5.4 Drive all three kill phases end-to-end in `--dry-run` under both bash and zsh, asserting the exact PID so an index regression printing `PID 0` cannot pass
- [x] 5.5 Confirm the phase checks fail when the index-based loops are restored (6/6 fail; zsh reports `bad substitution`)
- [x] 5.6 Full suite green: 13 test scripts, plus `bash -n` and `zsh -n` on all three shell entry points

## 6. Live verification

- [x] 6.1 Old matcher finds 0 sessions on the live host; the helper finds the 4 terminal sessions and excludes Desktop-hosted and subagent PIDs
- [x] 6.2 `claude-guard --dry-run`, `claude-sessions`, and `claude-fd` all report the same 4 PIDs
- [x] 6.3 Forced `CC_MAX_RSS_MB=1` and `CC_MAX_FD=1` dry-runs exercise the bloated and FD-leak phases under both shells
- [x] 6.4 Candidate set on this host is 13 processes, so the per-PID command lookup costs 13 `ps` calls

## 7. Documentation

- [x] 7.1 Record the session definition, its exclusions, and the two-seam split in `CLAUDE.md`
