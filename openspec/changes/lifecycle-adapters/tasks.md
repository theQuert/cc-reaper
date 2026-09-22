## 1. Specification

- [x] 1.1 Define the lifecycle adapter boundary and supported stages.
- [x] 1.2 Define a short-lived host/context-bound builder drain proof.
- [x] 1.3 Replace hard-coded runner matching with configurable protected filters.

## 2. Implementation

- [x] 2.1 Add proof validation and proof-gated builder cleanup.
- [x] 2.2 Add lifecycle reclaim hook and installer deployment.
- [x] 2.3 Add operator config and documentation.

## 3. Verification

- [x] 3.1 Run shell syntax checks and focused proof tests.
- [x] 3.2 Run the existing disk-janitor suite.
- [ ] 3.3 Run the full suite and review the exact-head diff before merge.
