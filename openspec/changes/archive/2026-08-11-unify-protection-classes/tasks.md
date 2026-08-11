## 1. Single classification

- [x] 1.1 Add `_cc_reaper_protection_class` returning `immutable` / `shared` / `none`
- [x] 1.2 Fold the three existing lists into it, reconciling `mcp-server-stripe` with `@stripe/mcp` and giving dev servers/`pm2` the same class everywhere
- [x] 1.3 Re-express `_cc_reaper_is_protected_cmd` and `_cc_reaper_is_direct_cleanup_protected` in terms of the class, so no caller changes shape
- [x] 1.4 Replace `MCP_WHITELIST` in `_claude_pgid_kill` with the class

## 2. Runaway correctness

- [x] 2.1 Exclude `immutable` from `_cc_guard_runaway_protected_pids`
- [x] 2.2 Signal the selected runaway PID even when its class is `shared`, sparing other group members
- [x] 2.3 Count and total only what was actually signalled; suppress the per-candidate notification when nothing was sent

## 3. Tree RSS

- [x] 3.1 Sum member RSS in kilobytes, convert once
- [x] 3.2 Walk the full descendant tree instead of stopping at grandchildren
- [x] 3.3 Measure the added cost on a live session tree

## 4. Regression proof

- [x] 4.1 Classification table test: every representative command from the proposal, asserting its class
- [x] 4.2 Assert the three paths agree on protection for the same command
- [x] 4.3 Runaway: immutable excluded, shared selected, user `protect` still exempt
- [x] 4.4 Runaway signalling: selected PID signalled, group sibling spared
- [x] 4.5 Counters: all delivered, partially delivered, none delivered
- [x] 4.6 Tree RSS: fractional members, great-grandchild, deep chain
- [x] 4.7 Existing suite stays green under bash and zsh

## 5. Failure and rollback proof (High-risk)

- [x] 5.1 Prove no signal is sent to any `immutable` command on any path
- [x] 5.2 Prove a user `protect` rule still exempts on all three paths
- [x] 5.3 Dry-run the whole reaper against the live host and diff the candidate set against the current implementation, explaining every difference
- [x] 5.4 Confirm revert is a single `git revert` with no state migration

## 6. Documentation

- [x] 6.1 Update `CLAUDE.md`: the classification, the runaway exclusion, and that counters mean deliveries
