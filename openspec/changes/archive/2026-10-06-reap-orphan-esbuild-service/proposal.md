# Stop an esbuild service whose dev server died

## Why

On 2026-10-06, twelve `esbuild --service=0.27.3 --ping` processes had been reparented to launchd
for five to seven days. Each was the stdio build service of a `wrangler dev` whose process group
was gone; with no parent to talk to over stdio, an esbuild service does nothing but hold memory
while the host was in swap (13.6 of 14.3 GB). The dev-server reaper only considers launcher
roots (`npm run dev`, `wrangler dev`, `next dev`, `vite`, `react-scripts start`), so it never
looks at a lone esbuild.

`.local-stack/api` orphans from stima-api's local stack are out of scope: that repository's
`local_stack.sh reap` already owns them, with pid-file and container-label proof of ownership.

## What Changes

- The dev-server reaper also stops an orphaned esbuild service: parent launchd, the esbuild
  binary from a `node_modules` install, run with `--service`, no children, no socket, at least
  the minimum age, its process group holding no live agent or launcher, cwd inside a linked
  worktree that has no live claim. It is stopped with the reaper's existing TERM-then-KILL
  path, under the same `report` / `apply` switch.

## Non-goals

- No change for launcher roots, idle windows or memory-pressure tiers.
- No reaping of `.local-stack/api`.

## Capabilities

- Modified: `disk-janitor`.
