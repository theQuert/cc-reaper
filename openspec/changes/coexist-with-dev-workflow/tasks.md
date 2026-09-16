## 1. Monitor selection

- [x] 1.1 Red-verify against the current monitor: a hot PPID=1 pytest carrying a scratchpad path, and a hot PPID=1 protected dev server, are signalled
- [x] 1.2 Remove the runaway-CPU override and `CC_RUNAWAY_ORPHAN_MIN_SEC`; the family sweep still signals an orphaned MCP server it names
- [x] 1.3 README and CHANGELOG: the override is gone; name the coverage gap it leaves

## 2. Shell functions

- [x] 2.1 Red-verify in a sandbox HOME: a fresh install writes a checkout path; a stale installer line is not repaired
- [x] 2.2 Guarded deployed-copy lines; rewrite installer-shaped stale lines with a backup and an atomic rename; leave and name other shapes; idempotent
- [x] 2.3 Proof: an interactive zsh with the installed rc defines `claude-cleanup` and `cc-monitor` and prints nothing to stderr

## 3. Docker on a shared host

- [x] 3.1 Red-verify: with dangling images listed, the clean invokes `docker rmi`
- [x] 3.2 Report dangling images (count and review command); a failed inventory reports that nothing was examined
- [x] 3.3 Structural check: no `docker rmi`, `image rm`, `volume rm` or `prune` invocation in the janitor

## 4. Stop hook

- [x] 4.1 Carry the documented tool-call process-group blind spot into the repository's hook (comment only)

## 5. Review round 1

- [x] 5.1 Red-verify the guard: a hot MCP server inside a live session's group gets the CLI, subagent and sibling signalled; an application and a dev server are selected; a cooled re-sample still signals
- [x] 5.2 Runaway phase: eligibility excludes `.app` bundles, dev servers and process managers; re-check command, eligibility and CPU after at least three seconds; signal the selected PID only; count deliveries
- [x] 5.3 Red-verify the installer: a read-only or unreadable rc stops the install; a hard link is broken; a backup taken after an append is not the pre-run file; a commented stale line blocks the current line; stale and current lines together leave the stale one
- [x] 5.4 Installer: backup before any change; manual path for symlink, hard link, unreadable, unwritable; print replaced lines; converge both states; never fail the install over rc configuration; deploy every script by rename
- [x] 5.5 Tests: docker removal asserted on the full `--clean` run with dangling ids present; installer exit status and banner checked; zsh stderr empty; sandboxes removed; monitor fixture PIDs above PID_MAX and unknown `ps` calls fail the suite
- [x] 5.6 Docs: CHANGELOG sections, README Option A runaway coverage, CLAUDE.md runaway row and specifics, installer guard echo
- [x] 5.7 cc-monitor: the runaway suggested action names claude-guard only for what it can reap

## 6. Review round 2

- [x] 6.1 Red-verify the guard: sessions, subagents, test runs and a Codex CLI whose arguments name a protected server are signalled; a long-lived server in a burst is signalled; argument text shaped like a row adds a candidate
- [x] 6.2 Runaway eligibility: the executable, or what a package runner or interpreter runs, is a known shared MCP server; Claude and Codex CLIs excluded except `codex mcp-server`; cc-monitor carries the same awk program, compared by a test
- [x] 6.3 Runaway selection: candidates from a listing without argument text; CPU time at least `CC_RUNAWAY_CPU` percent of an elapsed time of at least `CC_RUNAWAY_MIN`
- [x] 6.4 Tests: every signal follows the re-check pause, and changes that land at the pause are seen; a hot server younger than the floor is not selected
- [x] 6.5 Red-verify the installer: a stale line beside a hand-written one adds a second source line and names nothing; a missing rc file is backed up after the run's own append; a rewrite drops extended attributes
- [x] 6.6 Installer: lines in another shape found beside stale lines; no backup of a file the run created; rewrites on a `cp -p` copy; tests run install.sh with /bin/bash
- [x] 6.7 disk-janitor test: docker receives only the read-only calls the reports make
- [x] 6.8 Spec: the baseline runaway counters requirement is modified; the design no longer overstates PID reuse

## 7. Review round 3

- [x] 7.1 Red-verify the guard: a multi-threaded server busy early, a first sample, a reused PID, a short streak, a sample under a minute old, a burst after an idle interval and a streak across a 25-minute gap are signalled, and a stall late in a long life is not; zero thresholds select an idle server; an `.app` URL makes mcp-remote ineligible
- [x] 7.2 Runaway selection from CPU-time samples kept across runs, keyed by PID and start time under `LC_ALL=C TZ=UTC`; an interval over 20 minutes starts a streak over; a dry run records nothing
- [x] 7.3 `CC_RUNAWAY_CPU` and `CC_RUNAWAY_MIN` must be positive, as in cc-monitor
- [x] 7.4 `.app` bundles judged on the executable and the runner's operand only
- [x] 7.5 Red-verify the installer: a stale line beside an alias, beside the current line, or doubled is removed; a commented-out current line is turned back on; an ACL that denies delete leaves a copy of the rc file behind
- [x] 7.6 Installer: one stale line with nothing else naming the script is replaced in place, anything else is left unchanged with the change printed, and no line is ever removed; a commented-out current line stays off; a failed rename drops the copy's ACL before removing it
- [x] 7.7 disk-janitor tests: an unreferenced anonymous volume in the clean run, so the allowlist sees the volume report; the failed inventories' "nothing examined" message
- [x] 7.8 Design, proposal and docs: sampling and its delay replace the lifetime average; the installer never removes a line; cc-monitor names claude-guard only for a known shared MCP server; the rollback note matches what install.sh keeps

## 8. Review round 4

- [x] 8.1 Red-verify: a server whose runner's operand is inside an `.app` bundle, and `codex mcp-server` inside one, are eligible; a sample dated in the future carries its streak; a cool run keeps a streak; a run whose samples cannot be written selects and records anyway
- [x] 8.2 A sample dated after the run, or with a streak starting after it, is refused; a run that cannot write its samples leaves the previous file and selects nothing
- [x] 8.3 The `.app` rule is proven on the executable and on the runner's operand
- [x] 8.4 disk-janitor: the dangling-image report is asserted to send docker nothing but the listing
- [x] 8.5 Deploy tooling, which is host-local and lives beside this session rather than in the repository: rollback keeps the repaired rc lines unless `--with-rc`; the deploy stops when a commented-out current line sits beside a stale one
- [x] 8.6 Docs: the runaway phase signals each selected PID alone; a manual install has no runaway coverage; the rollback note matches the reverted installer

## 9. Review round 5

- [x] 9.1 Red-verify: a samples path with no directory part is turned into a directory, so the phase never records again
- [x] 9.2 A samples path with no directory part is read and rewritten in the directory claude-guard runs from
- [x] 9.3 The runaway phase's selection, re-check and kill branch run under zsh as well as bash, against the same scenario and the same delivered set
- [x] 9.4 A sample whose streak starts after the sample was taken is refused, proven on a fixture of its own: such a record can only shorten a streak, so what it changes is the sample recorded, not a kill
- [x] 9.5 Docs: `zsh -n` reads a `status` local without complaint, so name the suites that run their phases under both shells, and say what a samples path with no directory part means

## 10. Review round 6

- [x] 10.1 Red-verify: a run that can read its samples but cannot write them selects from the stale ones and signals
- [x] 10.2 A run that cannot record any samples selects nothing, as a run that cannot finish writing them already did
- [x] 10.3 The samples directory is created when it does not exist, and a first run at a path with no directory part leaves a file there, not a directory
- [x] 10.4 A dry run is proven to signal nothing, and the zsh leg runs `zsh -f`, so neither leg depends on whose shell it is
- [x] 10.5 Tasks: name the change `openspec validate --strict` gates, mark the deploy tooling as host-local, and say what the streak-after-its-own-sample fixture proves
- [x] 10.6 The runaway suite's signalled-set variable says what it holds: every PID the phase signals, one of whose deliveries fails

## 11. Review round 7

- [x] 11.1 Red-verify: a run that cannot record its samples selects nothing and prints nothing; a rename that fails still selects from the previous samples
- [x] 11.2 A run that cannot create, cannot finish, or cannot put its samples in place warns on stderr and selects nothing
- [x] 11.3 The session-detection suite's zsh leg runs `zsh -f` as the runaway suite's does, so neither depends on whose shell it is
- [x] 11.4 The read-only scenario cannot leave behind a directory the suite's own cleanup cannot remove
- [x] 11.5 Docs: the design bullet and both `CC_RUNAWAY_SAMPLES_FILE` rows say what an unwritable samples directory does, which is not what a lost file does

## 12. Review round 8

- [x] 12.1 Red-verify: the awk-failure path records nothing and says nothing, while the spec and both doc tables say every failure to record warns
- [x] 12.2 All three failures to record warn through one helper, with `printf`, so a samples path holding a backslash survives zsh's `echo`
- [x] 12.3 The function returns 2 and claude-guard says in its own report that nothing could be recorded: the agent writes stderr to a different file from the report a person reads
- [x] 12.4 Both suites drop `BASH_ENV` and `ENV` as well as zsh's rc, proven by a planted rc for each shell
- [x] 12.5 The rename failure-to-record path runs under zsh as well as bash
- [x] 12.6 CHANGELOG: the runaway entry carries the samples-integrity rules, the warning included - it is the one new line a user sees in the guard log
- [x] 12.7 Both `CC_RUNAWAY_SAMPLES_FILE` rows say the rule is about a recording run, since a dry run that cannot record still lists from the previous samples
- [x] 12.8 A dry run whose sampling fails lists nothing: a recording run now returns before that check, so the dry run is the only path its status still decides

## 13. Review round 9

- [x] 13.1 Red-verify: the report says this run's samples could not be recorded without naming which path, in every failure scenario
- [x] 13.2 The samples path has one owner, and the report names it as the stderr warning does
- [x] 13.3 The `printf` behind the warning is proven: under zsh a samples path holding a backslash reaches the line unchanged
- [x] 13.4 The runaway suite's `env -u BASH_ENV -u ENV` is proven by a planted `BASH_ENV`, as the session suite's is
- [x] 13.5 The zsh rename-failure leg checks the temporary file is gone, as its bash twin does
- [x] 13.6 The not-measured header is not a prefix of the listing header, so a grep for one cannot match the other
- [x] 13.7 The warning helper sits outside the phase's docstring
- [x] 13.8 The spec says the recording rule is about a run that records, since a dry run that cannot record still lists from the previous samples
- [x] 13.9 The SIGTERM banner names the grace period plus the re-check pause, which is what a person actually waits
- [x] 13.10 `guard-runner.sh`, which is deployed and is what an operator opens, describes selection by streaks rather than by a whitelist
- [x] 13.11 The design names both sample refusals, the proposal names every suite this change touches, and the README tree carries the guard agent, its runner and the suites added here

## 14. Delivery

- [ ] 14.1 All suites, `bash -n`, `zsh -n`, `openspec validate coexist-with-dev-workflow --strict`
- [ ] 14.2 Independent review until no actionable findings
- [ ] 14.3 Deploy by rename with backups of the replaced files; repair this host's rc lines with a backup; verify the running copies match main and a new shell loads the functions
