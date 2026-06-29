#!/usr/bin/env bash
# cc-reaper guard-runner — scheduled by the com.cc-reaper.guard LaunchAgent.
#
# Runs ONLY claude-guard's runaway phase: reaps whitelisted MCP servers that
# have been pinned at high CPU for a long time. Session / RSS / FD eviction is
# suppressed with huge thresholds so an unattended timer can NEVER kill an idle
# session you meant to keep — only a genuinely runaway protected process dies.
#
# Sources the DEPLOYED claude-cleanup.sh under ~/.cc-reaper, NOT the repo: a
# launchd agent has no TCC access to a ~/Documents checkout ("Operation not
# permitted"). install.sh ships a current copy next to this runner.
#
# No `set -u`: claude-cleanup.sh is a shell-rc function library that assumes
# unset-var tolerance; sourcing it under set -u trips on its first $1 reference.

CLEANUP="${CC_REAPER_CLEANUP:-$HOME/.cc-reaper/claude-cleanup.sh}"
[ -r "$CLEANUP" ] || exit 0

# shellcheck source=/dev/null
. "$CLEANUP"

# Suppress every non-runaway phase (idle eviction, RSS bloat, FD leak) by
# setting thresholds out of reach. Runaway thresholds keep their defaults
# (CC_RUNAWAY_CPU=80, CC_RUNAWAY_MIN=60). No grace wait — nobody is watching.
export CC_MAX_SESSIONS=99999 CC_MAX_RSS_MB=99999999 CC_MAX_FD=99999999
export CC_RUNAWAY_GRACE_SEC="${CC_RUNAWAY_GRACE_SEC:-0}"

claude-guard
