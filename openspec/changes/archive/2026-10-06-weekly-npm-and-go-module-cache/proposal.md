# Weekly clean reclaims the npm cache and, under pressure, the Go module cache

## Why

On 2026-10-06 the data volume had 37 GiB free and three rebuildable caches had no reclaimer:
`~/.npm/_cacache` (3.6 GB), `~/.npm/_npx` (2.1 GB) and `~/go/pkg/mod` (3.1 GB). The stima-api
CI slots keep their own npm and Go module caches inside their containers, so the host copies
are used only by sessions and MCP servers running as this user. `~/.cache` stays report-only:
its largest entry, `uv`, already has a reclaimer, and others (`huggingface`, `qmd`) are state.

## What Changes

- **npm cache.** The weekly clean runs `npm cache clean --force`, unless an `npm install`,
  `npm ci`, `npm update` or `npm add` process is running, in which case it is a counted `SKIP`.
- **npx installs.** It removes `~/.npm/_npx/<hash>` entries untouched for `CC_DJ_NPX_TRIM_DAYS`
  days (default 14) that no running process's command line or working directory names.
- **Go module cache.** Only when the data volume is below `CC_DJ_DISK_MIN_PCT` free and no Go
  build or toolchain process is running, it runs `go clean -modcache`.
- Each target has an `off` switch, and each is logged with freed bytes like every other target.

## Non-goals

- No automatic cleanup in `~/.cache`.
- No change to the go build cache rule.

## Capabilities

- Modified: `disk-janitor`.
