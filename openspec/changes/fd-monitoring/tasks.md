# FD Monitoring Tasks

## Section 1: claude-fd command
- [x] 1.1 [P] Add `_claude_process_fds` helper function (count FDs for a PID via lsof)
- [x] 1.2 Add `claude-fd` function (report FD usage for all Claude + VM processes)

## Section 2: claude-guard FD integration
- [x] 2.1 Add CC_MAX_FD config + Phase 0 FD-leak detection to `claude-guard`
- [x] 2.2 Add `[FD-LEAK]` status to session classification output

## Section 3: Documentation
- [x] 3.1 Update CLAUDE.md with `claude-fd` command and `CC_MAX_FD` env var
