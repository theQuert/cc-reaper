# Read a torn transcript record once more before failing closed

## Why

A live Claude or Codex session appends its transcript one line at a time. When a sweep reads that transcript while a tool-call line is half written, the parser cannot decode the record and reports the transcript unparsable. That fails closed: every worktree the sweep was judging is kept, and the sweep exits `status=1`.

This happened on 2026-09-27, when 23 worktrees were blinded by session `f8678f1f`, and again on 2026-10-01, when 46 were blinded by session `0f53e6c7`. Both times, the same transcript decoded cleanly minutes later, every line of it.

## What Changes

- When the transcript claim query reports a record it cannot decode, the janitor waits `CC_WJ_TRANSCRIPT_RETRY_SECONDS` (default 1) and reads the transcript once more. A writer finishes its line in milliseconds.
- The wait is paid once per transcript per process. A record that stays malformed then costs one second per sweep, not one second per candidate worktree.
- Only a second failure reports the transcript unparsable. That failure still fails closed exactly as before.
- Nothing is relaxed. A record that is still malformed on the second read keeps every worktree it could name.
