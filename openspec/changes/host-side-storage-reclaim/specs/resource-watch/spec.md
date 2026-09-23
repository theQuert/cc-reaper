## ADDED Requirements

### Requirement: Sudden free-space drop alert
The watcher SHALL keep the last 12 `<epoch> <free GB>` samples in `disk-free-samples` under its
state directory, compare the current sample with the newest stored one that is between 25 and 45
minutes old, and, when free space fell by at least `CC_RW_DISK_DROP_GB` (default 10; `0`
disables), mark the log line `ALERT:disk-drop` and post a `disk-drop` notification under the
per-metric cooldown.

#### Scenario: Ten gigabytes gone in half an hour
- **WHEN** the sample from 30 minutes ago shows 140 GB free and the current one shows 128 GB
- **THEN** the log line carries `ALERT:disk-drop` and a `disk-drop` notification is posted unless one was posted within the cooldown

#### Scenario: A small drop
- **WHEN** free space fell by less than `CC_RW_DISK_DROP_GB`
- **THEN** no drop alert is raised

#### Scenario: No comparable sample
- **WHEN** no stored sample is between 25 and 45 minutes old, as on the first run or after sleep
- **THEN** no drop is evaluated and no alert is raised

#### Scenario: Disabled
- **WHEN** `CC_RW_DISK_DROP_GB=0`
- **THEN** no drop alert is raised
