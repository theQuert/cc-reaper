## MODIFIED Requirements

### Requirement: Decimal elapsed-time parsing

The orphan monitor SHALL parse every zero-padded elapsed field emitted by `ps` as decimal,
including hour or minute values `08` and `09`, and SHALL preserve day-prefixed elapsed values.

#### Scenario: Zero-padded elapsed value

- **WHEN** `ps` reports `08:07:51` or `09:07:51`
- **THEN** stale and runaway checks receive the corresponding decimal seconds
- **AND** the monitor emits no Bash arithmetic error

#### Scenario: Day-prefixed value

- **WHEN** `ps` reports `1-09:07:51`
- **THEN** the day and time fields are combined as decimal seconds
