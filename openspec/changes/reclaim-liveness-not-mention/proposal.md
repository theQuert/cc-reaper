# Keep a scratchpad because its session is alive, not because a transcript names it

## Why

`reclaim-byproducts.sh` kept an idle session scratchpad whenever any other transcript written
in the last 24h named its path (`path-in-use.sh`'s "mention" check). A mention is what someone
typed, not whether the directory is in use: `1ff8c396` (5.47 GB) was kept for days because the
ci session printed its id in an inventory, and 12 GB of such directories were removed by hand on
2026-10-24 (stima-api#5886). The same check is the slow half of the run: four `grep -F` passes
over about 2 GB of transcripts per directory, 64s per directory measured, which is the
2h13m sweep.

## What Changes

- The transcripts are searched once per run, to tell the directories the mention rule kept from
  the ones it did not. A directory no transcript names goes through `path-in-use.sh` as before.
- A directory a transcript names is kept only when its session is alive, a process holds a file
  or cwd under it (one `lsof` for the run), its session wrote a transcript inside the idle
  window, it belongs to a protected session (`BYPRODUCT_PROTECT_SESSIONS`, default `homepage
  uiux verify-signin-redesign`), or `closed-sessions.md` records it closed within
  `BYPRODUCT_RESUME_DAYS` (2) days. Every removal is preceded by a fresh `lsof`.
- Removals newly allowed run in spot-check mode by default (`CC_RB_NEW_RULES_MODE`): they are
  logged to `~/.cc-reaper/logs/spotcheck-reclaim-byproducts.log` and nothing is deleted. `auto`
  deletes.

## Impact

- `shell/reclaim-byproducts.sh`, `tests/reclaim-byproducts.sh`. No change to the gate default or
  to the refusal when `path-in-use.sh` is unreadable.
