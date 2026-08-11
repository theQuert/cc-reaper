## ADDED Requirements

### Requirement: cc-reaper bounds its own logs
Every log file cc-reaper writes SHALL be size-bounded. When a log exceeds its cap — 1 MB by
default — the current contents SHALL be copied to a single `.old` generation and the live file
truncated, so a file pair never exceeds roughly twice the cap.

The live file SHALL keep its inode. Renaming would leave a descriptor another process already
holds — such as the one launchd opens for `StandardOutPath` — appending to the moved inode, which
grows the rotated copy while the live path stays empty. Copy-then-truncate keeps one mechanism for
every log, whoever holds it open.

#### Scenario: Log crosses the cap
- **WHEN** a runner starts and its log exceeds the cap
- **THEN** its contents SHALL be copied to `<log>.old`, replacing any previous generation, and the live file SHALL be emptied

#### Scenario: Log is under the cap
- **WHEN** a runner starts and its log is below the cap
- **THEN** the file SHALL be left untouched

#### Scenario: A descriptor is already open on the log
- **WHEN** a log is bounded while another process holds it open for appending
- **THEN** that descriptor SHALL keep writing to the live file, because the inode is preserved

#### Scenario: Log does not exist yet
- **WHEN** a runner starts before any log has been written
- **THEN** rotation SHALL succeed silently and create nothing

### Requirement: Notifications require a controlling terminal
Desktop notifications SHALL be raised only when the reaper is attached to a terminal. Without one
the notification SHALL be skipped rather than spawned, and no background process SHALL be left
behind by the attempt.

#### Scenario: Interactive run
- **WHEN** `claude-guard` reaps a session from a terminal
- **THEN** a notification SHALL be raised

#### Scenario: launchd run
- **WHEN** the guard agent reaps a session with no controlling terminal
- **THEN** no notification process SHALL be started, and the run SHALL leave no child behind

#### Scenario: Notification tooling is unavailable
- **WHEN** the notification command is missing or fails
- **THEN** the reaper SHALL continue and its exit status SHALL be unaffected

### Requirement: Interrupted runs clean up their temp files
Any script creating a temporary directory SHALL remove it on `EXIT`, `INT`, and `TERM`, not only
on the successful path. `cc-monitor` samples for 60 seconds by default, so interruption is an
ordinary outcome rather than an edge case.

#### Scenario: Sampling is interrupted
- **WHEN** `cc-monitor` is interrupted during its sampling window
- **THEN** its temp directory SHALL be removed

#### Scenario: Sampling completes
- **WHEN** `cc-monitor` finishes normally
- **THEN** its temp directory SHALL be removed exactly once, and the exit status SHALL be the one the run produced

### Requirement: Agent installation is verified
`install.sh` SHALL clear any `disabled` state before loading an agent, and SHALL confirm the agent
is loaded afterwards. An agent that fails to start SHALL be reported by name rather than passed
over silently.

#### Scenario: Agent was previously disabled
- **WHEN** `install.sh` runs and an agent is marked `disabled` in the launchd database
- **THEN** it SHALL be enabled and loaded, because `launchctl load` alone cannot clear that flag

#### Scenario: Agent fails to load
- **WHEN** an agent is still absent after installation
- **THEN** `install.sh` SHALL print the failing label

#### Scenario: Every agent loads
- **WHEN** all agents load
- **THEN** `install.sh` SHALL report them as active
