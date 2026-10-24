## ADDED Requirements

### Requirement: The low-disk act never holds the round
Below `CC_RW_DISK_ACT_GB` (default 40) free, at most once per `CC_RW_ACT_COOLDOWN_SECS`, the watcher
SHALL start the reclaim as a detached `resource-watch.sh --act` in its own process group and return
without waiting for it. At most one act SHALL run: the round claims `<state>/disk-act.lock` with an
atomic `mkdir`, and the act records its own pid there. A lock whose pid is dead, or alive but not a
`resource-watch --act`, SHALL be taken over without signalling that pid. An act older than
`CC_RW_ACT_MAX_SECONDS` (default 5400; `0` disables) SHALL be ended by the next round: an ERROR line,
`ALERT:disk-act-overrun`, TERM to the act's pid and each descendant found by `pgrep -P`, KILL to
those still alive after `CC_RW_ACT_KILL_GRACE_SECS`. No process SHALL be signalled by name.

#### Scenario: A hanging act does not stop sampling
- **WHEN** the act hangs and two rounds run
- **THEN** each round returns within seconds and logs a snapshot line, and only one act exists

#### Scenario: An overrun act is ended by pid
- **WHEN** the act has run past `CC_RW_ACT_MAX_SECONDS`
- **THEN** the round ends exactly the act's process tree, leaves other processes alone, and releases the lock

### Requirement: Disk tiers and flags
The watcher SHALL raise `ALERT:disk-low` below `CC_RW_DISK_ALERT_GB` (60), start the act below
`CC_RW_DISK_ACT_GB` (40), and below `CC_RW_DISK_EMERGENCY_GB` (20) raise `ALERT:disk-emergency` and
write `<state>/disk-emergency` (`<epoch> <free GB>`), removing it once free space is read at or above
that line. A limit of `0` disables its tier.

#### Scenario: Emergency flag set and cleared
- **WHEN** free space is 19 GB, then 25 GB
- **THEN** the flag exists after the first round and is gone after the second

### Requirement: Disk write rate
Every round SHALL append `<epoch>\t<free KB>` to `<state>/disk-free-samples.tsv`, keep 48 hours, and
compute GB/h against the oldest sample aged between a third of `CC_RW_RATE_WINDOW_SECS` (3600) and
the window plus 300 seconds. Above `CC_RW_RATE_ALERT_GBH` (10) it SHALL raise `ALERT:disk-rate`;
above `CC_RW_RATE_FLAG_GBH` (20) it SHALL also write `<state>/disk-rate-high`, removed when a
measured rate is at or below it. With no qualifying sample no rate is computed and the flag is left
as it was.

#### Scenario: 30 GB in an hour
- **WHEN** the sample an hour old shows 30 GB more free than now
- **THEN** `ALERT:disk-rate` is logged and `disk-rate-high` exists
