## 1. Specification

- [x] 1.1 Validate strictly; the MODIFIED requirement keeps every existing scenario.

## 2. Implementation

- [x] 2.1 Red then green: old entries deleted, recent entries and top-level files kept;
  `go clean` never invoked.
- [x] 2.2 Red then green: a running build, an absent `go`, a non-absolute `GOCACHE` and an
  unusable retention are each a counted `SKIP` that deletes nothing.

## 3. Verification and delivery

- [x] 3.1 Full shell suite, `bash -n` and `zsh -n`, `openspec validate --all --strict`;
  own review of the exact head. #48 at `4ba6667`: 22/22 suite files, and
  `tests/disk-janitor.sh` 124 ok with all three mutants caught. `bash -n`, `zsh -n` and
  `openspec validate --all --strict` (9/9) passed.
- [x] 3.2 Deploy by rename with a rollback manifest; the next weekly clean trims by age. The
  manifest is `go-cache-age-trim-20260923T080038` (`restart: false`,
  `launchagents_reloaded: false`).

Not done as written: on this host the weekly clean no longer trims the go build cache. #50
(manifest `go-cache-owner-off-20260923T092001`) sets `CC_DJ_GO_CACHE_TRIM_DAYS=off`, because
the skills `reclaim-byproducts` hook owns that cache and trims idle entries every three
hours. The first weekly clean after both deploys, on 2026-09-27 at 04:00, took the "Another
reclaimer owns the cache" path. It logged `go build cache: owned by another reclaimer here
(CC_DJ_GO_CACHE_TRIM_DAYS=off)` and ran neither `go clean` nor a trim. From 2026-09-23T19:00
to 2026-09-27T01:26 the hook ran 26 sweeps. Every one trimmed entries only, none emptied the
cache, and `README` and `trim.txt` are still in place.
