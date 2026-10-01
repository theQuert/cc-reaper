## ADDED Requirements

### Requirement: A torn transcript record is read once more before failing closed
When a transcript claim query cannot decode a relevant record, the janitor SHALL wait `CC_WJ_TRANSCRIPT_RETRY_SECONDS` (default 1) and query the transcript once more. Only a second failure SHALL report the transcript unparsable. The wait SHALL be paid at most once per transcript per process. That report SHALL keep failing closed as before.

#### Scenario: The writer finishes the line during the wait
- **WHEN** the first read finds a half-written last record and the writer completes it within the wait
- **THEN** the second read decodes it, and a claim it makes on the worktree is found

#### Scenario: The record stays malformed
- **WHEN** the record still cannot be decoded on the second read
- **THEN** the transcript is reported unparsable and every worktree it could name is kept

#### Scenario: Many candidates name the same malformed transcript
- **WHEN** one sweep judges several worktrees against a transcript that stays malformed
- **THEN** it waits once for that transcript, and every later read of it in the sweep goes without the wait
