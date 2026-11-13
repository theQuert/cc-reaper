## ADDED Requirements

### Requirement: The go build cache cap and age trim take executable directories too
The go build cache selectors SHALL list both entry forms in the two-hex-digit subdirectories of the
cache: regular files named `*-a` or `*-d`, and directories named `*-d` (a `go run` or `go tool`
executable is cached as `<xx>/<hash>-d/<name>`). A directory SHALL be aged by the newest modification
time of itself and everything inside it, sized by `du`, ordered with the files by that time, and
removed as one unit. The size cap (`--go-cache-cap`: over `CC_GO_CACHE_MAX_GB`, down to
`CC_GO_CACHE_TARGET_GB`) and the age trim (`--go-cache`) SHALL NOT remove any entry, file or
directory, modified within `CC_GO_CACHE_MIN_AGE_MIN` minutes (the age trim: within its own age). After a
cap run that leaves the cache above its target the log SHALL state the size measured inside that
window, not assert it.

#### Scenario: An idle executable directory is removed
- **WHEN** a `<hash>-d` directory and everything in it is older than the window and the cache is over the cap
- **THEN** the directory is removed whole, oldest first with the files

#### Scenario: One member used inside the window keeps the directory
- **WHEN** a `<hash>-d` directory is old but its executable was modified inside the window
- **THEN** the directory is kept

#### Scenario: The remainder is measured
- **WHEN** the cap leaves the cache above its target
- **THEN** the log names the size of what remains that was modified inside the window
