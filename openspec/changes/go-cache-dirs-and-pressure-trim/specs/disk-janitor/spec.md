## MODIFIED Requirements

### Requirement: The go build cache is trimmed by age, never emptied
The weekly clean SHALL delete only go build cache entries - files named `*-a` or `*-d`, and directories
named `*-d` whose newest member is as old, in the two-hex-digit subdirectories of the directory `go env
GOCACHE` reports - whose modification time is older than `CC_DJ_GO_CACHE_TRIM_DAYS` days (default 3).
Go refreshes an entry's modification time when it uses the entry, so this is the rule Go applies itself
after five days, applied sooner. A `<hash>-d` directory SHALL be removed as one unit. The janitor SHALL NOT
run `go clean -cache`, and SHALL NOT delete the cache's top-level files (`README`, `trim.txt`,
`testexpire.txt`). While a `go build`, `go test`, `go run`, `go vet`, `go install` or `go generate`, or a
toolchain `compile`, `link`, `asm` or `cgo` process is running, the target SHALL remove nothing and be
logged as `SKIP` and counted.

#### Scenario: An idle executable directory goes, a used one stays
- **WHEN** one `<hash>-d` directory has had nothing modified in it for ten days and another has a member modified just now
- **THEN** the first is removed whole and the second is kept

## ADDED Requirements

### Requirement: The go-build-age step takes executable directories and respects a holder inside them
The `go-build-age` step SHALL list the `<hash>-d` directories (older than its age, with nothing inside
newer) beside the regular files, count and size each directory as one entry, and remove it whole in
`auto` mode. A directory SHALL be held, and kept, when the single system-wide `lsof` listing names any path
inside it.

#### Scenario: A running go run executable
- **WHEN** a process holds `<hash>-d/<name>` open and the directory is otherwise idle
- **THEN** the directory is kept and counted as held
