## MODIFIED Requirements

### Requirement: Tree RSS calculation
The system SHALL calculate tree RSS over the session process and **all** its descendants, to any
depth.

Member sizes SHALL be summed in kilobytes and converted to megabytes once, at the end. Truncating
each member individually loses roughly 0.5 MB per process, which on a ten-process tree is several
megabytes of silent undercount.

Both corrections make tree RSS larger than before, so a session crosses `CC_MAX_RSS_MB` slightly
earlier than it used to. The previous behaviour was an undercount, not a safety margin.

#### Scenario: Session with MCP server children
- **WHEN** a Claude session (PID 1000) has 3 child MCP servers each using 200 MB, and the session itself uses 500 MB
- **THEN** tree RSS SHALL be calculated as 1100 MB

#### Scenario: Members carry fractional megabytes
- **WHEN** a session's own RSS is 4095 MB plus 1023 KB and its single child holds 1 KB
- **THEN** tree RSS SHALL be 4096 MB, because members are summed in kilobytes before conversion

#### Scenario: Great-grandchild process
- **WHEN** a session's grandchild has spawned a further child of its own
- **THEN** that process's RSS SHALL be included in tree RSS

#### Scenario: Deep wrapper chain
- **WHEN** a session runs behind a chain such as CLI → `npm` → shell → server
- **THEN** every process in that chain SHALL contribute to tree RSS
