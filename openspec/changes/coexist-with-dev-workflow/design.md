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

### The runaway phase signals one known MCP server, measured over its life

The phase exists for one incident class: a shared MCP server stuck hot for hours. Five
properties made it dangerous beside interactive work.

- **It signalled a process group.** `_claude_pgid_kill <pid> 1` walks the selected PID's group
  and signals every `none` member. A shared MCP server started by a Claude CLI is in that CLI's
  group, so selecting the server ended the session. The phase now signals the selected PID
  alone, through `_cc_reaper_kill_pid`, and counts that delivery.
- **It matched a name anywhere in the command line.** The protection class is a substring test
  over the whole argv, which errs safe for protection and unsafe for a kill path: a session whose
  `--settings` named `claude-mem`, a subagent whose `--mcp-config` named `context7`, and test runs
  under directories named after servers all classified `shared`. Eligibility now requires the
  process itself to be a known shared MCP server: its executable or, through a package runner or
  interpreter, the first word that is neither an option nor a subcommand, compared whole as a
  package with any version dropped, a program in a `bin` directory, or a package directory under
  `node_modules`. No other argument counts, so a checkout path named after a server does not.
  Claude and Codex CLIs are never eligible, except `codex mcp-server`, and nothing inside an
  `.app` bundle is. cc-monitor carries the same awk program, compared by a test, so it names
  claude-guard only for what claude-guard would select.
- **It read candidates from a table with a command column.** A line of argument text shaped like
  a row added a PID, with numbers of its own. Candidates now come from
  `ps -axo pid=,etime=,time=,%cpu=`, and each command is read per PID and flattened to one line -
  the seam session detection already uses.
- **It judged heat on `ps %cpu`.** That value decays over about a minute, and etime stood in for
  "hot for an hour", so a routine burst in a server old enough qualified. Selection now requires
  the CPU time used to be at least `CC_RUNAWAY_CPU` percent of an elapsed time of at least
  `CC_RUNAWAY_MIN`. After at least three seconds each PID is read again, and signalled only if
  it runs the same command, is still eligible and is still over the threshold. A PID reused by a
  different command in that window is not signalled; one reused by the same command would be,
  which needs the PID to wrap within seconds.
- **It selected applications and dev servers.** On the audited host it signalled `ChatGPT.app`
  and `cmux.app`, the terminal the sessions run in. None of them is an MCP server, so none is
  eligible, and cc-monitor's report still names them with a kill line for a human.

Protection classes stay the single owner of "how protected". Runaway eligibility is `shared`, no
user `protect` rule, and the MCP server identity test.

Cost: a stuck shared MCP server is signalled only once its lifetime average reaches the
threshold, which for a server that ran idle for long before stalling may be never. The incident
that motivated the monitor override ran for 9 hours.

### Shell functions come from the deployed copies

The LaunchAgents already run `~/.cc-reaper/claude-cleanup.sh`, so the shell and the scheduler
now run one deployed version. The rc line is
`[ -r "$HOME/.cc-reaper/claude-cleanup.sh" ] && source "$HOME/.cc-reaper/claude-cleanup.sh"`.
A shell started before step 5 of an interrupted install prints nothing.

- **What gets repaired.** Only whole, uncommented lines in the installer's own generated form,
  `source "<anything>/shell/<script>"`. Anything else may be deliberate: it is left alone and
  printed, and when it sits beside a stale line the stale line is removed and nothing is added.
  A commented-out line does not count as a mention.
- **When the current line already exists.** Stale lines for that script are removed.
- **Backup.** The rc file is copied to `<rc>.cc-reaper-backup-<timestamp>` before the first
  change of any kind in the run, so the backup is always the pre-run file. With no rc file yet
  there is nothing to keep, and nothing later in the run backs up the file the run created.
- **How a rewrite is written.** On a `cp -p` copy in the same directory, which keeps the mode,
  ACL and extended attributes, then renamed.
- **When a change would do harm, or cannot work.** A symlink (a dotfiles checkout), a file with
  more than one hard link, or an unreadable or unwritable file is not changed at all - not even
  appended to, since an append writes into whatever the link points at. The installer prints the
  exact change.
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
- **A stuck shared MCP server is signalled only once its lifetime average reaches the
  threshold.** A server idle for a day and then pinned for an hour averages about 4% and is never
  signalled. Accepted: cc-monitor reports it, and measuring the last `CC_RUNAWAY_MIN` minutes
  would need CPU time kept per process between runs.
- **Only listed MCP servers, in known forms, are eligible.** claude-mem's worker is protected but
  not listed, since its process form was never observed. A server run from its own checkout
  rather than from `node_modules` or a `bin` directory is not identified, nor is one run by a
  Python inside an `.app` bundle (framework or Homebrew Python). An option whose value is a
  separate word is read as what a runner runs, which misses the server unless that value itself
  names a known one. Accepted: a missed runaway is reported, not killed.
- **A stuck application or dev server is never signalled automatically.** Accepted.
  cc-monitor's runaway section names it with a kill line.
- **A symlinked or hard-linked rc file gets no lines, even on a fresh install.** Accepted: the
  installer prints the two lines to add, and the file stays the dotfiles checkout's to change.
- **A hand-written rc line in the installer's exact shape is rewritten.** Mitigated: a backup,
  and the replaced line is printed.
