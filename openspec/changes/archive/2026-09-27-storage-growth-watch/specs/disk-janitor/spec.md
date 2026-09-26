## ADDED Requirements

### Requirement: Growth targets are sampled within a budget
`--check` SHALL sample the targets in `CC_DJ_GROWTH_TARGETS` (default
`~/.cc-reaper/growth-targets.tsv`, rows `label<TAB>path<TAB>owner[<TAB>alert GB]`). A path
MAY contain glob wildcards, and each matching directory SHALL be its own key; `docker:<type>`
SHALL read that category from one `docker system df` call and `docker:volumes/*` SHALL read
each volume from one `docker system df -v` call. A key SHALL be measured at most once per
`CC_DJ_GROWTH_INTERVAL_HOURS` (default 6), never-measured and oldest keys first, at low
priority, and no measurement SHALL start after `CC_DJ_GROWTH_BUDGET_SECONDS` (default 240)
have elapsed in the run. Each sample SHALL be appended to `state/growth-samples.tsv` as
`<epoch>\t<key>\t<KiB or status>`, and samples older than 14 days SHALL be dropped.

#### Scenario: A due key is measured
- **WHEN** a key's newest sample is older than the interval and budget remains
- **THEN** it is measured and one sample line is appended

#### Scenario: The budget runs out
- **WHEN** the budget is spent with due keys remaining
- **THEN** no further measurement starts, and the run logs how many keys wait for a later run

#### Scenario: A target cannot be read
- **WHEN** a path is denied, vanished, or its measurement exceeds the per-key timeout
- **THEN** the sample records `denied`, `absent` or `timeout`, never a size of zero

#### Scenario: No targets are configured
- **WHEN** the targets file is missing or empty
- **THEN** the step measures nothing and logs that no growth targets are configured

### Requirement: Abnormal growth is flagged with its owner
After sampling, for every key and every label total with a numeric current sample, growth
SHALL be computed against the newest numeric sample at least `CC_DJ_GROWTH_WINDOW_HOURS`
(default 24) old, or, when none exists, the oldest numeric sample at least 3 hours old. A
label total SHALL be recorded only when every current member has a numeric sample. When
growth reaches the row's alert GB (default `CC_DJ_GROWTH_ALERT_GB`, 5), the janitor SHALL
log `ALERT:growth key=<key> owner=<owner> +<GB>GB in <hours>h now=<GB>GB` and post one
`growth` notification per cooldown. Every run that sampled SHALL log its three largest
growers.

#### Scenario: One worktree grows by six gigabytes in a day
- **WHEN** a worktree key measured 2 GB a day ago measures 8 GB now
- **THEN** an `ALERT:growth` line names that key, its owner and `+6.0GB`, and one notification is posted unless one was within the cooldown

#### Scenario: Growth under the threshold
- **WHEN** every key and total grew by less than its alert GB
- **THEN** no alert is logged and the top growers are still logged

#### Scenario: No comparable baseline
- **WHEN** a key has no numeric sample at least 3 hours old
- **THEN** no growth is computed for it and no alert is raised

#### Scenario: A member of a total is not yet measured
- **WHEN** a glob target has a member with no numeric sample
- **THEN** no total is recorded for that label in this run

#### Scenario: python3 is unavailable
- **WHEN** `python3` cannot be found
- **THEN** the growth step is logged as `SKIP` and counted, and the rest of the check runs
