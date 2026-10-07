## ADDED Requirements

### Requirement: The installer reports drift without changing anything
`install.sh --check` SHALL compare each deployed script and each rendered LaunchAgent with the checkout it runs from, using the same list the deploy uses, and SHALL exit non-zero when any differs or is missing. It SHALL write nothing and SHALL NOT call `launchctl`. The worktree LaunchAgent SHALL be compared at its installed interval. An operator-owned policy or target file that differs SHALL be reported and SHALL NOT count as drift. The optional orphan monitor SHALL be compared only where it is installed.

#### Scenario: A deployed script was edited
- **WHEN** a script under `~/.cc-reaper` differs from its source in the checkout
- **THEN** `--check` prints `DRIFT` with its path and exits 1

#### Scenario: A policy was tuned for this host
- **WHEN** `~/.cc-reaper/worktree-janitor.conf` differs from `config/worktree-janitor.conf`
- **THEN** `--check` reports it as operator-owned and the exit status is unaffected

#### Scenario: The check runs on a live host
- **WHEN** `--check` runs
- **THEN** no file under the home directory changes and `launchctl` is not invoked
