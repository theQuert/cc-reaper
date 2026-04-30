# Design: monitor-apply-modules

## Architecture

`cc-monitor` retains its existing pipeline: `_cc_monitor_collect_samples` → `_cc_monitor_aggregate_samples` → `_cc_monitor_enrich_findings` → report (`_cc_monitor_human_report` or `_cc_monitor_json_report`). This change appends an optional **dispatch stage** after the human report:

```
sample → aggregate → enrich → human_report → [dispatch stage]
                                              ├─ --apply MODULE  → dispatch_module(MODULE)
                                              └─ TTY && has SAFE_TO_REAP && !no_prompt
                                                  └─ prompt_apply → confirm → dispatch_module
```

The JSON path is unchanged (no dispatch).

## Components

### New helpers (in `shell/cc-monitor.sh`)

| Helper | Responsibility |
|---|---|
| `_cc_monitor_module_available <name>` | `command -v` check for the underlying binary; returns 0/1 |
| `_cc_monitor_module_command <name>` | Maps module name → executable + args (e.g. `claude-guard-dry` → `claude-guard --dry-run`) |
| `_cc_monitor_module_label <name>` | Maps module name → human label for menu (`claude-guard --dry-run (preview)`) |
| `_cc_monitor_module_destructive <name>` | Returns 0 for modules requiring y/N confirmation in interactive mode |
| `_cc_monitor_recommended_module <findings_file>` | Picks recommended module name based on findings (`claude-cleanup` if SAFE_TO_REAP exists; else `claude-guard-dry` if heat without orphans; else empty string) |
| `_cc_monitor_prompt_apply <findings_file>` | Renders menu to stderr, reads selection from `/dev/tty`, returns chosen module name on stdout (empty if skipped) |
| `_cc_monitor_dispatch_module <name> <skip_confirm>` | Optionally confirms (if interactive + destructive); execs underlying command via `command`; propagates exit code |

### Module catalogue

Module name mapping table (canonical names used in `--apply` and menu):

| Name | Command | Destructive |
|---|---|---|
| `claude-cleanup` | `claude-cleanup` | yes |
| `claude-guard` | `claude-guard` | yes |
| `claude-guard-dry` | `claude-guard --dry-run` | no |
| `proc-janitor-scan` | `proc-janitor scan` | no |
| `proc-janitor-clean` | `proc-janitor clean` | yes |

Unknown names → exit 2 with `cc-monitor: unknown module 'X'. Valid: claude-cleanup, claude-guard, claude-guard-dry, proc-janitor-scan, proc-janitor-clean`.

### Arg parsing additions

```
--apply <module>     # run module after report; rejects with --json; non-interactive
--no-prompt          # disable interactive menu; equivalent to non-TTY behavior
```

Validation:
- `--apply` + `--json` → exit 2 with `cc-monitor: --apply cannot be combined with --json`.
- `--apply` with empty value → exit 2.
- Both flags present without conflict are independent.

### TTY detection

Single helper `_cc_monitor_is_tty` returns 0 only when both `[ -t 0 ]` (stdin) and `[ -t 1 ]` (stdout) hold. Prompts read from `/dev/tty` (not stdin) so they survive `cc-monitor < /dev/null` style invocations only when the controlling TTY is present; if `/dev/tty` cannot be opened, prompt is skipped and treated as decline.

### Recommendation logic

After enrichment:

1. If at least one `SAFE_TO_REAP` finding exists → recommend `claude-cleanup`.
2. Else if any family-level RSS sum > 1024 MB OR any process > 60% avg CPU → recommend `claude-guard-dry`.
3. Else → no recommendation, no menu shown.

The threshold values are intentionally conservative; they are constants in the source (no env knobs in this change).

## Failure scenarios and behavior

| Scenario | Behavior |
|---|---|
| Module binary missing on PATH | Hide from menu; show one-line install hint after menu (e.g. `proc-janitor not installed: brew install ...`) |
| User picks hidden/missing module via `--apply` | Exit 127 with `cc-monitor: module 'X' not available on PATH` |
| `/dev/tty` unavailable during prompt | Skip prompt, treat as decline, exit 0 |
| User Ctrl+C at prompt | Exit 130, no module dispatched |
| User selects skip / presses Enter | Exit 0 |
| Confirmation prompt: invalid input | Treat as N (decline), exit 0 |
| Dispatched module exits non-zero | Propagate exit code; print module's stderr verbatim |
| Race: process state changed between sample and apply | Acceptable — modules re-scan; no stale PIDs reused |

## Test strategy

Tests live in `tests/cc-monitor-optimize.sh` (mirror of existing `tests/cc-monitor.sh` style). They use `CC_MONITOR_SNAPSHOT_FILE` to inject deterministic `ps`-style snapshots and a temp `PATH` containing stub scripts for `claude-cleanup` / `claude-guard` / `proc-janitor`. Each stub records its argv to a side file so tests can assert dispatch + arguments.

Coverage matrix:

| Case | Setup | Assertion |
|---|---|---|
| JSON mode never prompts | `--once --json` | No menu in stderr; stdout valid JSON |
| `--no-prompt` disables menu | TTY + SAFE_TO_REAP fixture | No menu in stderr |
| Non-TTY auto-disables menu | `</dev/null` + SAFE_TO_REAP | No menu |
| Menu shows on TTY with candidates | TTY + SAFE_TO_REAP | Menu present, recommended marker on `claude-cleanup` |
| No menu without candidates | TTY + clean fixture | No menu |
| Missing module hidden | TTY, `proc-janitor` stub absent | Menu omits `proc-janitor-*`; install hint printed |
| Confirmation y/N — `n` | Menu select `claude-cleanup`, answer `n` | Stub not invoked |
| Confirmation y/N — `y` | Menu select `claude-cleanup`, answer `y` | Stub invoked once |
| `--apply claude-cleanup` skips confirm | non-TTY + flag | Stub invoked, no prompt text |
| `--apply` + `--json` rejected | both flags | Exit 2, error to stderr |
| Unknown `--apply` value | `--apply foo` | Exit 2, error lists valid modules |
| `--apply` to unavailable module | flag + stub absent | Exit 127 |
| Dispatched module non-zero exit | stub exits 5 | cc-monitor exits 5 |
| Recommendation: RSS-only path | fixture without orphans, high RSS | Menu marks `claude-guard-dry` |

## Trade-offs

- **Linear flow vs streaming**: keeps existing batch (sample → aggregate → report → dispatch) flow rather than streaming reports during sample, because dispatching mid-sample creates ambiguous state and mixes responsibilities.
- **No new env knobs**: thresholds for recommendation are hard-coded constants for now to avoid premature flexibility; can be promoted to env vars later if needed.
- **No multi-module run**: a single dispatch per invocation; running multiple modules can be done via two `cc-monitor --apply` calls or scripting.
