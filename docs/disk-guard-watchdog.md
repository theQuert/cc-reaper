# Disk guard watchdog

On 2026-10-24 the disk guard went blind for more than five hours (stima-api #5886). A round of
`resource-watch.sh` waited on a reclaim that never returned, and then an operator stopped
(SIGSTOP) that reclaim. launchd starts no new round while one is running, so sampling, alerts and
the go cache cap all stopped. `reclaim-byproducts.sh` spent the whole time in its scratchpad
liveness phase, and its lock made every other run exit 0 without a word. launchd has no maximum
run time (`ExitTimeOut` only sets the gap between TERM and KILL), so every bound below lives in
the scripts.

| What | Where | Knob (default) |
|---|---|---|
| Heartbeat: the round's start epoch, written before any step that can block | `<state>/resource-watch.heartbeat` | none |
| Whole-round deadline: past it, the round ends its own tree by pid (never a resource-watch act); ERROR, `ALERT:round-overrun` | `resource-watch.sh` | `CC_RW_ROUND_MAX_SECONDS` (240, 0 = off) |
| A stopped (`T`) act, or a stopped pid in its tree, is an operator hold: ERROR, `ALERT:disk-act-held`, `ACT:held:<pid>` every round; never signalled at any age; no new act while it holds the lock. Sampling, alerts and the go cache cap go on | `resource-watch.sh` | none |
| The go cache (age trim and cap) runs before the scratchpad phase | `reclaim-byproducts.sh` | none |
| Scratchpad time budget: stop before the next directory (always after at least one), save a cursor, continue next run. A directory not reached is kept | `reclaim-byproducts.sh`, `<state>/reclaim-byproducts.scratch-cursor` | `CC_RB_SCRATCH_BUDGET_SECONDS` (900, 0 = off) |
| A lock holder that is stopped or too old: ERROR, `ALERT:byproducts-lock-held` / `-old`, exit 1, a notification at most once per cooldown. Never taken over, never signalled | `reclaim-byproducts.sh` | `CC_RB_LOCK_MAX_AGE_SECONDS` (10800, 0 = off), `CC_RB_ALERT_COOLDOWN_SECS` (3600) |
| `--go-cache` / `--go-cache-cap` take their own lock, so a sweep cannot block them | `<state>/reclaim-byproducts-go.lock` | `CC_RB_GO_LOCK_DIR` |

No deletion rule changed: only order, timing and alerts. Tests: `tests/resource-watch-watchdog.sh`
(W1-W3) and `tests/reclaim-byproducts-watchdog.sh` (R1-R3).

Still open: something has to read the heartbeat. A reader in a different launchd job should raise
P1 when the heartbeat is older than 2 × the 600 s interval. It has to be a different job, because
a reader in the same job stalls along with what it reads.
