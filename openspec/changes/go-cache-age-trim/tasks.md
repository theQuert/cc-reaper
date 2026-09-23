## 1. Specification

- [x] 1.1 Validate strictly; the MODIFIED requirement keeps every existing scenario.

## 2. Implementation

- [x] 2.1 Red then green: old entries deleted, recent entries and top-level files kept;
  `go clean` never invoked.
- [x] 2.2 Red then green: a running build, an absent `go`, a non-absolute `GOCACHE` and an
  unusable retention are each a counted `SKIP` that deletes nothing.

## 3. Verification and delivery

- [ ] 3.1 Full shell suite, `bash -n` and `zsh -n`, `openspec validate --all --strict`;
  own review of the exact head.
- [ ] 3.2 Deploy by rename with a rollback manifest; the next weekly clean trims by age.
