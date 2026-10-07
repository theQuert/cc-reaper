# Adopt the byproducts reaper from the skills repository

## Why

Host reclamation lived in three repositories. The byproducts reaper (session scratchpads,
anonymous Docker volumes, the go build cache, old reclaim archives, configured dead caches)
is host maintenance with nothing to do with skills, yet it lived in the skills repository,
ran from a symlink into that checkout, and was scheduled under its own label beside
cc-reaper's agents. Its go-cache ownership was already coordinated with `disk-janitor.conf`
across the two repositories (skills#154, cc-reaper#50). One home makes the ownership
visible in one place, ships it with `install.sh --check`, and lets another machine get it
from cc-reaper alone.

## What Changes

- `shell/reclaim-byproducts.sh` and `tests/reclaim-byproducts.sh` move here from skills
  `hooks/` and `tests/` at b54143d, behaviour unchanged except:
  - the LaunchAgent label is `com.cc-reaper.reclaim-byproducts`; after a successful install
    the skills-era `com.claude.reclaim-byproducts` is unloaded and its plist moved to
    `~/.cc-reaper/state/retired-agents/`. A sweep it is running is waited for
    (`BYPRODUCT_LEGACY_WAIT_SECONDS`, default 900) and never signalled; past the wait it is
    left loaded and named.
  - the scratchpad root defaults to `/tmp/claude-$(id -u)`, not uid 501;
  - the liveness gate defaults to `~/.claude/hooks/path-in-use.sh` (the harness's), since
    the deployed copy has no sibling; without it the run still refuses.
- `install.sh` deploys it with the other scripts, so `--check` covers it, and prints the
  one-time `--install-launchd 3h` command while the agent is not loaded. The installer's
  probe takes minutes and needs Full Disk Access, so it is not run on every update.
- Unchanged: the log, stamp and archive paths under `~/.claude`, so the staleness gate and
  log history carry across the move.

## Ownership after the move

Each resource still has one actor: scratchpads, anonymous volumes and the go build cache
are this reaper's (`CC_DJ_GO_CACHE_TRIM_DAYS=off` on this host); `disk-janitor` keeps the
builder cache, pip and the weekly caches and only reports volumes; `host-temp-reaper`
keeps `$TMPDIR` tool leftovers. Nothing is reaped by two agents.

## Impact

- New: `shell/reclaim-byproducts.sh`, `tests/reclaim-byproducts.sh`. Changed: `install.sh`,
  README, CLAUDE.md. The skills repository removes its copy in a follow-up PR after this
  host's agent is cut over.
