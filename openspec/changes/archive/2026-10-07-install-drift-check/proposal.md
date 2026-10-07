# Say whether the deployed copies match the repository

## Why

launchd and the hooks run the copies under `~/.cc-reaper`, not this checkout, and the
installer leaves the operator's policies alone on update. Nothing compared the two: on
2026-10-06 four deploys were each verified by a hand-written byte comparison, and a review
of the host's reclaim mechanisms found the policies and the targets had drifted from the
repository without anything saying so. The dev-server reaper also defaulted its pressure
log to one host's sampler path (`~/stima-watch/host/pressure.log`), a machine-specific value
in code that is meant to install on any machine.

## What Changes

- `install.sh --check` compares every script step 5 deploys, the orphan monitor where it is
  installed, and every LaunchAgent it renders against this checkout, changes nothing, and
  never calls `launchctl`. A deployed script or agent that differs or is missing is drift,
  exit 1. The worktree agent is rendered with its installed interval. The policies and the
  growth targets are reported as operator-owned when they differ, never as drift.
- The deploy and the check read one list (`CC_PAYLOAD`, `CC_AGENTS`).
- The dev-server reaper reads a pressure log only when `CC_DEV_SERVER_PRESSURE_LOG` names
  one; the host sets it in `disk-janitor.conf`. Unset, only the live level counts.

## Impact

- `install.sh`, `shell/dev-server-reaper.py`, `config/disk-janitor.conf`,
  `tests/install-check.sh`, `tests/dev-server-reaper.py`, README.
- This host keeps its window: its `disk-janitor.conf` exports the existing path before the
  new reaper is deployed.
