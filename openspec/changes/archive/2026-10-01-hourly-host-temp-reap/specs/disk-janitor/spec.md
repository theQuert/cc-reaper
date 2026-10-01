## REMOVED Requirements

### Requirement: Hourly threshold check is read-only
**Reason**: The hourly check now reclaims proved-abandoned host temp items and prunes day-old builder cache, because weekly was too late for them (2026-09-30).
**Migration**: Set `CC_DJ_HOST_TEMP_REAP=0` and `CC_DJ_BUILDER_PRUNE_UNTIL=off` to restore a check that deletes nothing but code-sign clones.

## ADDED Requirements

### Requirement: The hourly check reclaims only proved-abandoned host temp items
The hourly check SHALL measure, alert and then reclaim only the items the requirements below name. It SHALL NOT remove images, containers, volumes, or any path outside the user's temp directory, Chrome's code-sign clone root and the wrangler log directory. `CC_DJ_HOST_TEMP_REAP=0` SHALL turn off the host temp step.

#### Scenario: Disk below threshold at hourly check
- **WHEN** the hourly check finds disk free < threshold
- **THEN** it posts one (cooldown-gated) notification recommending `disk-janitor --clean`, logs the measurement, and still runs the reclaim steps

#### Scenario: The host temp step is turned off
- **WHEN** `CC_DJ_HOST_TEMP_REAP=0`
- **THEN** the host temp reclaimer does not run

### Requirement: An orphaned headless Chrome is stopped only when abandoned
The reclaimer SHALL send `SIGTERM`, and nothing stronger, only to a process for which all of the following hold:
- it is the Chrome browser binary, not a Helper;
- it runs with `--headless` and `--remote-debugging-port`;
- its `--user-data-dir` is directly under the user's temp directory;
- its parent is launchd;
- it has run for at least the idle limit;
- `lsof` shows it listening and shows no established connection on any of those ports.

It SHALL recheck the pid's command immediately before signalling. A failed or inconclusive probe SHALL keep the process.

#### Scenario: A launcher died and left its browser
- **WHEN** a headless Chrome with a temp profile is reparented to launchd, has run for two hours, and has no DevTools client
- **THEN** it receives `SIGTERM`

#### Scenario: A browser still in use
- **WHEN** the browser's launcher is alive, or a DevTools client is connected, or it is younger than the idle limit, or its profile is not in the temp directory
- **THEN** it is not signalled

#### Scenario: The pid changed between scan and signal
- **WHEN** the pid's command differs at the recheck
- **THEN** it is not signalled

### Requirement: Unreferenced cdp profiles and idle wrangler logs are removed
The reclaimer SHALL remove a directory named `cdp-` plus six alphanumerics, directly under the user's temp directory and not a symlink, only when all of these hold:
- no running process names it as `--user-data-dir`;
- `lsof` shows no holder;
- it has not changed for the idle limit.

It SHALL remove a file named `wrangler-<timestamp>.log` in `~/Library/Preferences/.wrangler/logs` only when it has not been written for the idle limit and `lsof` shows no holder. The idle limit SHALL be at least 30 minutes.

#### Scenario: A profile whose browser is gone
- **WHEN** a `cdp-XXXXXX` profile is two hours old, unnamed and unheld
- **THEN** it is removed

#### Scenario: A profile or log still in use
- **WHEN** a profile is named by a running process, held open, or recently changed, or a log is being written or held open
- **THEN** it is kept

### Requirement: Builder cache unused for a day is pruned at most once a day
Once per 24 hours, and only when the daemon answers, the hourly check SHALL run `docker builder prune --force --filter until=<CC_DJ_BUILDER_PRUNE_UNTIL>` (default `24h`). `off` SHALL turn it off.

#### Scenario: Two checks on the same day
- **WHEN** the check runs twice within 24 hours
- **THEN** the builder prune runs only on the first

### Requirement: Code-sign clones are reclaimed after one day
Both the hourly check and the weekly clean SHALL remove unheld code-sign clones older than `CC_DJ_CHROME_CLONE_MIN_AGE_DAYS` (default 1).

#### Scenario: A day-old unheld clone
- **WHEN** a clone is older than one day and no process holds it
- **THEN** the next hourly check removes it
