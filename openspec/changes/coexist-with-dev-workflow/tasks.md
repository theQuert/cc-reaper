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

## 6. Delivery

- [ ] 6.1 All suites, `bash -n`, `zsh -n`, `openspec validate --strict`
- [ ] 6.2 Independent review until no actionable findings
- [ ] 6.3 Deploy by rename with backups of the replaced files; repair this host's rc lines with a backup; verify the running copies match main and a new shell loads the functions
