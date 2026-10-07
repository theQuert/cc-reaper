## ADDED Requirements

### Requirement: The dev-server reaper's pressure log is named by the host
The dev-server reaper SHALL read a memory-pressure sample log only from the path in `CC_DEV_SERVER_PRESSURE_LOG`. When it is unset or empty the reaper SHALL judge pressure from the live kernel level alone and SHALL NOT open any log.

#### Scenario: No sampler is configured
- **WHEN** `CC_DEV_SERVER_PRESSURE_LOG` is unset and the live level is below 2
- **THEN** the reaper uses the normal idle window and opens no file
