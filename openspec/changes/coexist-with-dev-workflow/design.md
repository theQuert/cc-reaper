## Context

cc-reaper's scheduled paths run unattended beside interactive Claude Code sessions, a
dev-workflow harness that runs tests and mutation matrices in the background, and CI runner
slots. A false kill there destroys work with no visible trace except a log line. A broken rc
line takes away the manual tools.

## Decisions

### Remove the monitor's runaway override rather than narrow it

Narrowing the name match does not reach the root cause. Matching the executable name instead of
the whole line still selects `node` test runners, `bun` dev servers and `next build`. Raising the
age floor still kills an experiment that runs longer than the floor.

What distinguishes a stuck shared service from busy work is its protection class, and that
decision already has one owner, `_cc_reaper_protection_class`. claude-guard's runaway phase uses
it and runs on the same 10-minute cadence. The override's remaining unique coverage is a hot
PPID=1 process that is not `shared`. That is exactly the class that includes user work.
Non-whitelisted MCP and agent orphans are still reaped by the monitor's main sweep, whatever
their CPU.

Cost: a stuck shared MCP is signalled after 60 minutes instead of 3. The 2026-06-13 incident that
motivated the override ran for 9 hours.

### Shell functions come from the deployed copies

The LaunchAgents already run `~/.cc-reaper/claude-cleanup.sh`, so the shell and the scheduler
run one deployed version. The rc line is
`[ -r "$HOME/.cc-reaper/claude-cleanup.sh" ] && source "$HOME/.cc-reaper/claude-cleanup.sh"`.
A shell started between steps 1 and 5 of an interrupted install prints nothing, instead of an
error on every prompt.

The rewrite matches only the installer's own generated form,
`source "<anything>/shell/claude-cleanup.sh"` (and the same for `cc-monitor.sh`), as a whole
line. Anything else might be a deliberate choice, so it is left alone and printed. The rc file is
copied to `<rc>.cc-reaper-backup-<timestamp>` before the first change, and the rewrite is written
to a temporary file and renamed into place.

### Docker images are reported, not removed

A dangling image carries no tag, but that does not make it the janitor's to remove on a host
several people and systems build on. Report the count and the command that lists them, the same
way unreferenced volumes are already handled.

### Deploy by rename

`bash` reads a script incrementally from its open file. Overwriting a running script in place
(`cp`) can make a monitor or clean run already in progress execute a mix of old and new bytes.
Replacing it by rename (`mv`) leaves the running process on the old inode.

## Risks

- **A stuck shared MCP burns up to 60 minutes before claude-guard signals it.**
  Accepted: the incident class ran for hours.
- **An rc line written by hand in the installer's exact shape gets rewritten.**
  Mitigated: backup plus a printed notice naming the line.
