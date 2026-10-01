## 1. Change

- [x] 1.1 Reread once in `_cc_wj_transcript_claims_path`, which serves both the active and the recent claim paths.
- [x] 1.2 Tests in `tests/worktree-active-sessions.sh` cover a torn record the writer completes during the wait (the claim is found) and a record still torn on the second read (fails closed, `2`). The fast-path count test now expects the reread. A third test covers a transcript that stays malformed: it is waited on once per process. The no-retry and wait-every-time mutants are both caught.

## 2. Verification and delivery

- [x] 2.1 Full suite, `bash -n`, `zsh -n`, `openspec validate --all --strict`; my own review of the exact head. (Merged as #59.)
- [x] 2.2 Deploy by rename with a rollback manifest; the next session sweeps exit `status=0` while sessions write. (Deployed 2026-10-01T08:57:52Z as `transcript-torn-record-reread-20261001T085752`. The four session sweeps that started after it, 17:00:54 to 17:15:03 +0800, all ended `status=0`, with no "could not be parsed" line. Before it, the same day had 46 such lines.)
