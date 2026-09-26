# Trim the go build cache by age instead of emptying it

## Why

`disk-janitor --clean` ran `go clean -cache` every Sunday. On the reporting host that removed
28.6 GB on 2026-09-13 and 10.8 GB on 2026-09-20, and every session rebuilt from cold
afterwards. Three days after the second wipe the cache was back to 27.1 GB, and 14.0 GB of
it was entries created in the two days after the wipe and never used again. The hot set,
entries used within two days, was 6.2 GB. The wipe produced the churn it was cleaning up.

It also ran whatever else was running. `go clean -cache` removes the cache's subdirectories,
which a build in progress writes its results into, and the host runs agent sessions around
the clock. The host's other reclaimer for this cache already trims by age and stands down
while a build runs.

## What Changes

- The weekly go target deletes only cache entries unused for `CC_DJ_GO_CACHE_TRIM_DAYS`
  (default 3) days, matching the files Go's own five-day trim removes, in the directory
  `go env GOCACHE` reports. It never runs `go clean -cache` and never touches the cache's
  top-level files.
- While a go build, test, run, vet, install or generate, or a toolchain compile, link, asm
  or cgo process is running, the target removes nothing and is a counted `SKIP`.
- An absent `go`, a `GOCACHE` that is not an absolute path, or an unusable retention value
  is a counted `SKIP`.
- `CC_DJ_GO_CACHE_TRIM_DAYS=off` leaves the cache to another reclaimer. On the reporting
  host the skills repository's `reclaim-byproducts` trims it every three hours, which the
  cache's growth of several GB a day needs; one owner per cache, so this janitor steps
  aside there instead of trimming the same cache by a second rule.

## Impact

- Hosts keep the hot part of the cache across the weekly clean; a host that relied on the
  weekly wipe to bound the cache is bounded by the retention instead (and by Go's own
  five-day trim when the janitor skips).
- `CC_DJ_GO_CACHE_TRIM_DAYS` is new.
