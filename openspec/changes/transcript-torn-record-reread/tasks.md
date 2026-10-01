## 1. Change

- [x] 1.1 Reread once in `_cc_wj_transcript_claims_path`, which serves both the active and the recent claim paths.
- [x] 1.2 Tests in `tests/worktree-active-sessions.sh` cover a torn record the writer completes during the wait (the claim is found) and a record still torn on the second read (fails closed, `2`). The fast-path count test now expects the reread. A third test covers a transcript that stays malformed: it is waited on once per process. The no-retry and wait-every-time mutants are both caught.

## 2. Verification and delivery

- [ ] 2.1 Full suite, `bash -n`, `zsh -n`, `openspec validate --all --strict`; my own review of the exact head.
- [ ] 2.2 Deploy by rename with a rollback manifest; the next session sweeps exit `status=0` while sessions write.
