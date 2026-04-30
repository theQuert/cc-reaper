# Tasks: monitor-apply-modules

## 1. Argument parsing and validation

- [x] 1.1 Add `--apply <module>` and `--no-prompt` to `cc-monitor` arg loop in `shell/cc-monitor.sh`
- [x] 1.2 Reject `--apply` + `--json` combination with exit 2 and error message
- [x] 1.3 Validate `--apply` value against the canonical module list; exit 2 with error listing valid names

## 2. Module catalogue and helpers

- [x] 2.1 [P] Implement `_cc_monitor_module_command` and `_cc_monitor_module_label` mapping (shell/cc-monitor.sh)
- [x] 2.2 [P] Implement `_cc_monitor_module_destructive` predicate (shell/cc-monitor.sh)
- [x] 2.3 [P] Implement `_cc_monitor_module_available` using `command -v` (shell/cc-monitor.sh)
- [x] 2.4 Implement `_cc_monitor_recommended_module` recommendation logic against the findings file (shell/cc-monitor.sh, depends on 2.1)

## 3. TTY detection and prompt rendering

- [x] 3.1 Implement `_cc_monitor_is_tty` helper checking both `[ -t 0 ]` and `[ -t 1 ]`
- [x] 3.2 Implement `_cc_monitor_prompt_apply`: render numbered menu to stderr, mark recommended option, read selection from `/dev/tty` (graceful fall-through if /dev/tty unavailable)
- [x] 3.3 Implement install-hint printing for unavailable modules in the menu

## 4. Dispatch and confirmation

- [x] 4.1 Implement `_cc_monitor_dispatch_module <name> <skip_confirm>` to optionally confirm and exec module via `command`, propagating exit code
- [x] 4.2 Wire dispatch into `cc-monitor` flow: after `_cc_monitor_human_report`, call dispatch when `--apply` or interactive menu chose a module
- [x] 4.3 Ensure JSON path in `cc-monitor` skips dispatch entirely

## 5. Tests

- [x] 5.1 Create `tests/cc-monitor-optimize.sh` skeleton with PATH-stub harness for `claude-cleanup`, `claude-guard`, `proc-janitor`
- [x] 5.2 [P] Add test: JSON mode never prompts (with and without `--no-prompt`)
- [x] 5.3 [P] Add test: `--no-prompt` suppresses menu when TTY + SAFE_TO_REAP fixture
- [x] 5.4 [P] Add test: non-TTY auto-suppresses menu
- [x] 5.5 [P] Add test: menu shows on TTY with SAFE_TO_REAP fixture and marks recommended
- [x] 5.6 [P] Add test: no menu without candidates / heat
- [x] 5.7 [P] Add test: missing module hidden from menu and install hint printed
- [x] 5.8 [P] Add test: confirmation declined (`n`) does not invoke stub
- [x] 5.9 [P] Add test: confirmation accepted (`y`) invokes stub once
- [x] 5.10 [P] Add test: `--apply claude-cleanup` skips confirm and invokes stub
- [x] 5.11 [P] Add test: `--apply` + `--json` rejected (exit 2)
- [x] 5.12 [P] Add test: unknown `--apply` value rejected (exit 2 with valid list)
- [x] 5.13 [P] Add test: `--apply` to unavailable module exits 127
- [x] 5.14 [P] Add test: dispatched module non-zero exit propagates
- [x] 5.15 [P] Add test: RSS-only path recommends `claude-guard-dry`

## 6. Docs

- [ ] 6.1 Update `README.md` Key Commands and add an "Optimize after monitor" subsection with `--apply` and `--no-prompt` usage
- [ ] 6.2 Update `shell/cc-monitor.sh` `_cc_monitor_usage` help text with new flags

## 7. Validation

- [ ] 7.1 Run `bash -n shell/cc-monitor.sh` for syntax check
- [ ] 7.2 Run `bash tests/cc-monitor.sh` to confirm existing tests still pass
- [ ] 7.3 Run `bash tests/cc-monitor-optimize.sh` to confirm new tests pass
