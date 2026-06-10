# resource-watch Specification (delta)

## ADDED Requirements

### Requirement: Lightweight system snapshot
The watcher SHALL collect load average, CPU idle %, memory pressure (compressor size + free %), and Data-volume disk free % in a single sampling pass that completes in under 2 seconds and spawns no long-lived processes.

#### Scenario: Scheduled snapshot runs
- **WHEN** the launchd agent fires the watcher (default every 600s)
- **THEN** one snapshot line is appended to `~/.cc-reaper/logs/resource-watch.log` containing timestamp, load1/5/15, CPU idle %, memory free %, compressor GB, and disk free GB/%

#### Scenario: Snapshot cost stays negligible
- **WHEN** the watcher runs
- **THEN** it uses single-shot sampling (`top -l 1`, `df`, `memory_pressure`/`sysctl`) and exits; it SHALL NOT loop, daemonize, or hold file descriptors open between runs

### Requirement: Threshold-gated alerting
The watcher SHALL compare the snapshot against configurable thresholds and raise a macOS Notification Center alert only when a threshold is breached. Defaults: load1 > 2× logical cores, disk free < 15%, memory free < 5% with compressor > 50% of RAM.

#### Scenario: Load threshold breached
- **WHEN** load1 exceeds 2× logical core count
- **THEN** a notification is posted naming the metric, current value, and threshold, and the breach is logged with an `ALERT` marker

#### Scenario: All metrics within thresholds
- **WHEN** no threshold is breached
- **THEN** no notification is posted (log line only)

#### Scenario: Thresholds are configurable
- **WHEN** the user sets `CC_RW_LOAD_FACTOR`, `CC_RW_DISK_MIN_PCT`, or `CC_RW_MEM_MIN_PCT` in the environment or config
- **THEN** the configured values replace the defaults

### Requirement: Notification cooldown
The watcher SHALL suppress repeat notifications for the same metric within a cooldown window (default 60 minutes), tracked via a state file under `~/.cc-reaper/`.

#### Scenario: Same metric breaches twice within cooldown
- **WHEN** disk-free breaches at 10:00 and again at 10:10 with a 60-minute cooldown
- **THEN** only the 10:00 breach posts a notification; the 10:10 breach is logged but silent

#### Scenario: Different metrics breach within cooldown
- **WHEN** load breaches at 10:00 and disk breaches at 10:10
- **THEN** both post notifications (cooldown is per-metric)
