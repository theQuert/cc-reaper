## Why

On 2026-10-24 the low-disk act in `resource-watch.sh` (`worktree-janitor.sh --scheduled`, then
`reclaim-byproducts.sh`) ran in the foreground of the launchd job for 3h34m (pid 55146). launchd
starts no new round of a job that is still running, so from 10:35 on there were no samples, no go
cache cap and no alerts, while free space fell at up to about 25 GB/h (54.5 GB to 23.5 GB in 73
minutes). At that rate the old 25 GB act line left about an hour of headroom.
(stima-api #5886, EL-DISK-ROOTFIX-1356 design D1 and D7.)

## What Changes

- **The act runs detached**: `resource-watch.sh --act` in its own process group under nohup, so the
  round returns in seconds and every round keeps sampling.
- **Single instance**: an atomic `mkdir` lock `<state>/disk-act.lock` with `started` and `pid`; a lock
  whose pid is dead or not a `resource-watch --act` is taken over.
- **Runtime cap** `CC_RW_ACT_MAX_SECONDS` (5400): the next round logs ERROR, raises
  `ALERT:disk-act-overrun` and ends the act's tree by pid (`pgrep -P` walk, TERM, then KILL after
  `CC_RW_ACT_KILL_GRACE_SECS`). Nothing is matched by name.
- **Tiers move up**: `ALERT:disk-low` under 60 GB (was 40), the act under 40 GB (was 25), and a new
  emergency tier under 20 GB: `ALERT:disk-emergency` plus the flag `<state>/disk-emergency`.
- **Write rate (D7)**: every round appends `<epoch>\t<free KB>` to `<state>/disk-free-samples.tsv`
  (48 hours kept); GB/h over the last hour above 10 raises `ALERT:disk-rate`, above 20 also writes
  `<state>/disk-rate-high`, removed once a measured rate is at or below it.
- **The go cache cap is bounded** by `CC_RW_GO_CAP_MAX_SECONDS` (120), ended by pid past it.

## Not in this change

- Readers of the two flag files (disk-janitor, dispatchers); they are a contract for later work.
- An issue comment as an alert path: resource-watch alerts by log line and macOS notification only.
