## Context

cc-reaper's scheduled paths run unattended beside interactive Claude Code sessions, a
dev-workflow harness that runs tests and mutation matrices in the background, and CI runner
slots. A false kill there destroys work, and the only trace it leaves is a log line. A broken rc
line takes away the manual tools.

## Decisions

### Remove the monitor's runaway override rather than narrow it

Narrowing the name match does not reach the root cause. Matching the executable instead of the
whole line still selects `node` test runners, `bun` dev servers and `next build`. Raising the age
floor still kills an experiment that runs longer than the floor. From a process table alone,
nothing separates a hot orphaned MCP server nobody named from a hot orphaned test run: both are
`node` or `python`, both are orphaned, and both are busy.

So the monitor keeps only what it can name. The family sweep still reaps orphans whose command
lines carry `claude … stream-json`, `node … mcp-server`, `npx … mcp-server`,
`npm exec … mcp-server` or `npm exec mcp-`, `worker-service`, Codex CLI forms, agent-browser and
Puppeteer profiles, whatever their CPU. A hot orphan outside those forms is reaped by nothing. A
bare `node …/index.js` MCP server and `npm exec @playwright/mcp` are both outside them. That gap
is accepted and documented, because the class that shares it is user work.

### The runaway phase signals one process, re-checked, and never an application

The phase exists for one incident class: a shared MCP server stuck hot for hours. Three
properties made it dangerous beside interactive work.

- **It signalled a process group.** `_claude_pgid_kill <pid> 1` walks the selected PID's group
  and signals every `none` member. A shared MCP server started by a Claude CLI is in that CLI's
  group, so selecting the server ended the session. The phase now signals the selected PID
  alone, through `_cc_reaper_kill_pid`, and counts that delivery.
- **It judged on one sample and on age.** `ps %cpu` at one instant, with etime standing in for
  "hot for an hour". The phase now waits at least three seconds and re-reads the PID. It signals
  only if the command is unchanged, which also covers PID reuse, the process is still eligible,
  and CPU is still over the threshold.
- **It selected applications and dev servers.** On the audited host it signalled `ChatGPT.app`
  and `cmux.app`, the terminal the sessions run in. An `.app` bundle, a development server or a
  process manager is something a person is using. The phase now leaves them to cc-monitor's
  report, which names them with a kill line for a human.

Protection classes stay the single owner of "how protected". Runaway eligibility is `shared`
minus those three user-facing kinds, expressed in one helper.

Cost: a stuck shared MCP server is signalled after `CC_RUNAWAY_MIN` (60) minutes of age plus a
confirming re-sample, not after 3 minutes. The incident that motivated the monitor override ran
for 9 hours.

### Shell functions come from the deployed copies

The LaunchAgents already run `~/.cc-reaper/claude-cleanup.sh`, so the shell and the scheduler
now run one deployed version. The rc line is
`[ -r "$HOME/.cc-reaper/claude-cleanup.sh" ] && source "$HOME/.cc-reaper/claude-cleanup.sh"`.
A shell started before step 5 of an interrupted install prints nothing.

- **What gets repaired.** Only whole, uncommented lines in the installer's own generated form,
  `source "<anything>/shell/<script>"`. Anything else may be deliberate: it is left alone and
  printed. A commented-out line does not count as a mention.
- **When the current line already exists.** Stale lines for that script are removed.
- **Backup.** The rc file is copied to `<rc>.cc-reaper-backup-<timestamp>` before the first
  change of any kind in the run, so the backup is always the pre-run file.
- **How a rewrite is written.** To a temporary file in the same directory with the original
  mode, then renamed.
- **When a rename would do harm, or cannot work.** A symlink (a dotfiles checkout), a file with
  more than one hard link, or an unreadable or unwritable file is not rewritten. The installer
  prints the exact replacement.
- **Failure.** rc configuration never stops the installer: a failed step prints what to do and
  the installation continues.

### Deploy by rename

`bash` reads a script incrementally from its open file. Overwriting a running script in place
with `cp`, as `install.sh` did for every deployed script, can make a monitor, janitor or hook run
already in progress execute a mix of old and new bytes. Interactive shells now source the
deployed copies too. Every deployment writes a temporary file in the destination directory and
renames it: a running reader keeps the old inode.

### Docker images are reported, not removed

A dangling image carries no tag, but that does not make it the janitor's to remove on a host
several people and systems build on. It reports the count and the command that lists them, the
same way it already handles unreferenced volumes.

## Risks

- **A hot orphan no family predicate names is not reaped by any scheduled path.** Accepted and
  documented. cc-monitor reports heat by family for a human.
- **A stuck shared MCP server runs up to `CC_RUNAWAY_MIN` before it is signalled.** Accepted.
- **A stuck application or dev server is never signalled automatically.** Accepted.
  cc-monitor's runaway section names it with a kill line.
- **A hand-written rc line in the installer's exact shape is rewritten.** Mitigated: a backup,
  and the replaced line is printed.
