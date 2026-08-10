## 1. Shared session detection helper

- [x] 1.1 Add `_cc_reaper_session_pids` to `shell/claude-cleanup.sh`, emitting one PID per line
- [x] 1.2 Reject `ps` continuation lines by validating the PID and TTY field shapes (same guard as `_cc_monitor_snapshot`)
- [x] 1.3 Require a controlling terminal; exclude `??` / `?` / `-` so Desktop-hosted sessions and subagents drop out
- [x] 1.4 Require the `claude` executable plus a session flag; exclude `mcp-server`, `-p`/`--print`, and `--output-format`
- [x] 1.5 Support `CC_REAPER_PS_SNAPSHOT_FILE` so tests can feed a fixed process table without mocking `ps`

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

## 4. Regression proof

- [x] 4.1 Add `tests/guard-session-detect.sh` covering every scenario in the spec delta
- [x] 4.2 Assert the multi-line `--settings` case emits the PID exactly once
- [x] 4.3 Assert a bare-number continuation line is rejected
- [x] 4.4 Drive all three kill phases end-to-end in `--dry-run` under both bash and zsh, asserting the exact PID so an index regression printing `PID 0` cannot pass
- [x] 4.5 Confirm the phase checks fail when the index-based loops are restored (6/6 fail; zsh reports `bad substitution`)
- [x] 4.6 Full suite green: 13 test scripts, plus `bash -n` and `zsh -n` on all three shell entry points

## 5. Live verification

- [x] 5.1 Old matcher finds 0 sessions on the live host; the helper finds the 4 terminal sessions and excludes Desktop-hosted and subagent PIDs
- [x] 5.2 `claude-guard --dry-run`, `claude-sessions`, and `claude-fd` all report the same 4 PIDs
- [x] 5.3 Forced `CC_MAX_RSS_MB=1` and `CC_MAX_FD=1` dry-runs exercise the bloated and FD-leak phases under both shells

## 6. Documentation

- [x] 6.1 Record the session definition and its exclusions in `CLAUDE.md`
