## 1. Detection Helpers

- [x] 1.1 Add shared stale-age and command matching helpers to `shell/claude-cleanup.sh`
- [x] 1.2 Add agent-browser, Puppeteer headless Chrome, and Codex process family matchers to `shell/claude-cleanup.sh`

## 2. Manual Cleanup

- [x] 2.1 Extend `claude-cleanup` reporting and candidate collection for stale browser automation processes
- [x] 2.2 Extend `claude-cleanup` reporting and candidate collection for orphaned/stale Codex process groups and MCP subprocesses
- [x] 2.3 Preserve existing whitelists for shared MCP services, dev servers, normal Chrome, cmux, ChatGPT, and system daemons

## 3. Scheduled Cleanup

- [x] 3.1 Mirror the new process family matchers in `launchd/cc-reaper-monitor.sh`
- [x] 3.2 Add monitor logging for stale browser automation and orphaned Codex cleanup decisions

## 4. proc-janitor and Docs

- [x] 4.1 Update `proc-janitor/config.toml` target and whitelist patterns for agent process cleanup
- [x] 4.2 Update `README.md` with new coverage, safety boundaries, and threshold configuration

## 5. Validation

- [x] 5.1 Add lightweight shell/pattern validation for positive and negative process examples
- [x] 5.2 Run shell syntax checks and validation script from the feature worktree
