# Change: monitor-apply-modules

## Why

After `cc-monitor` prints its heat-attribution report, users have no single entry point to act on the diagnosis. They must switch to a separate command (`claude-cleanup`, `claude-guard`, or `proc-janitor clean`) and pick one without explicit guidance. The existing report already classifies findings as `SAFE_TO_REAP` / `ASK_BEFORE_KILL` / `DO_NOT_KILL`, so the monitor has enough context to recommend and dispatch the right cleanup module — but it does not.

This change closes that gap while preserving the monitor's read-only-by-default contract.

## What Changes

- Add an opt-in interactive prompt at the end of human-mode reports when running on a TTY and the report contains `SAFE_TO_REAP` candidates. The prompt offers a numbered menu of available optimization modules (`claude-cleanup`, `claude-guard`, `claude-guard --dry-run`, `proc-janitor scan`, `proc-janitor clean`) with the recommended option marked.
- Add a `--apply <module>` flag that runs sampling, prints the report, then dispatches the named module non-interactively (script-friendly).
- Add a `--no-prompt` flag that disables the interactive menu while keeping the report.
- Hide modules from the menu when their underlying command is not on PATH and print a one-line install hint.
- Confirm destructive interactive actions (`claude-cleanup`, `proc-janitor clean`) with a `[y/N]` prompt; `--apply` flag invocations skip the confirmation (the flag itself is the explicit opt-in).
- Reject `--apply` combined with `--json` (exit 2 with an explanatory error).
- Preserve all existing read-only behavior: default invocations, `--json`, non-TTY environments, and reports without `SAFE_TO_REAP` candidates produce no signals.

## Impact

- **Affected specs**: `cc-monitor` (additive — new requirements, no scenario changes to existing requirements)
- **Affected code**: `shell/cc-monitor.sh` (new helpers + arg parsing); new test file `tests/cc-monitor-optimize.sh`
- **Docs**: `README.md` updated with `--apply` / `--no-prompt` and menu UX
- **Out of scope**: re-implementing cleanup logic in cc-monitor; modifying `--json` schema; auto-apply mode; multi-module selection
