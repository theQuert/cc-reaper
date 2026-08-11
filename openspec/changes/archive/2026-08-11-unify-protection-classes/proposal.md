## Why

cc-reaper decides what it may signal from three independently-grown lists:

| Predicate | Used by |
|---|---|
| `_cc_reaper_protected_pattern` | pattern-based cleanup, runaway **selection** |
| `_cc_reaper_is_direct_cleanup_protected` (immutable ∨ user `protect` ∨ protected pattern) | process-group cleanup |
| `MCP_WHITELIST`, local to `_claude_pgid_kill` | the **signal** stage of group and runaway kills |

They disagree, and the disagreements are not cosmetic. Measured against representative command lines:

| Command | immutable | protected | group whitelist | Consequence |
|---|---|---|---|---|
| `Bitdefender`, `mdworker`, `mds_stores` | yes | yes | **no** | runaway selects **and signals** a system scanner |
| `chrome-devtools-mcp`, `context7-mcp`, `@stripe/mcp`, `sequential-thinking` | no | yes | yes | runaway selects, signal stage skips — reported reaped, still running |
| `mcp-server-stripe` | no | yes | **no** | signalled, while `@stripe/mcp` — the same service, launched differently — is not |
| `pm2`, `next-server` | no | yes | **no** | a dev server in an orphaned group is signalled, though pattern-based cleanup spares it |

Two defects follow directly, and both were confirmed by running the shipped functions:

**A runaway shared MCP is never actually signalled.** `_cc_guard_runaway_protected_pids` selects it, `_claude_pgid_kill` skips it. Worse, `rkilled` increments and the tree RSS is added to `rfreed` regardless of delivery, and a notification fires per candidate — so `claude-guard` reports `Reaped N runaway protected process(es), freed ~X MB` for processes still burning CPU. This is precisely the failure mode the runaway phase was built for: `CLAUDE.md` records that Cloudflare's MCP server is deliberately left off the whitelist because it pins ~100% CPU for hours.

**A stuck system scanner is signalled.** Nothing in runaway selection consults `_cc_reaper_is_immutable_cmd`, so Bitdefender at 80% CPU for an hour is SIGTERM-ed after the grace window.

Separately, `_claude_tree_rss` divides each member's RSS by 1024 before adding, so a tree is undercounted by roughly 0.5 MB per process, and it stops after grandchildren. Measured on four live sessions: 2–4 MB from truncation, 0–1 MB from depth.

## What Changes

- Add `_cc_reaper_protection_class`, returning `immutable`, `shared`, or `none` for a command line. It becomes the single owner of "how protected is this process", and the three paths consult it instead of three separate lists.
- Runaway selection SHALL skip `immutable`. System scanners stop being candidates.
- Runaway SHALL signal the candidate it selected, crossing the shared-service exemption for that PID only. Other members of its process group keep their protection.
- Runaway counters SHALL report processes actually signalled, not processes considered.
- `_claude_tree_rss` SHALL sum in kilobytes and convert once, and SHALL walk the whole descendant tree.

Not in scope: process-group cleanup keeps signalling every non-protected member on membership alone. The group is the unit — its leader is an orphaned session, so the group is a corpse, and requiring per-member staleness would leave half-dead groups behind.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `agent-process-reapers`: protection becomes one classification with three call sites; runaway gains an immutable exclusion and a forced signal for its own target.
- `rss-threshold-reaper`: tree RSS becomes a full-depth sum converted once.

## Impact

- `shell/claude-cleanup.sh`: new `_cc_reaper_protection_class`; `_cc_reaper_is_protected_cmd`, `_cc_reaper_is_direct_cleanup_protected`, `_claude_pgid_kill`, `_cc_guard_runaway_protected_pids`, and `_claude_tree_rss` all change.
- Behavior, in both directions:
  - **Fewer kills**: system scanners leave the runaway candidate set; `mcp-server-stripe`, `pm2`, and `next-server` gain the group-kill protection they already had elsewhere.
  - **More kills**: a runaway shared MCP is now genuinely terminated instead of being reported as such.
  - Sessions cross `CC_MAX_RSS_MB` a few MB earlier, since tree RSS stops undercounting.
- Reported counts change meaning: they become deliveries rather than intentions, so a run that previously claimed to free memory may now report zero. That is the honest number.
