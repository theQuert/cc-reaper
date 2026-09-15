## 1. Monitor selection

- [ ] 1.1 Red-verify against the current monitor: a hot PPID=1 pytest carrying a scratchpad path, and a hot PPID=1 protected dev server, are signalled
- [ ] 1.2 Remove the runaway-CPU override and `CC_RUNAWAY_ORPHAN_MIN_SEC`; the family sweep still signals an orphaned unprotected MCP server
- [ ] 1.3 README and CHANGELOG: the override is gone and stuck shared services belong to claude-guard

## 2. Shell functions

- [ ] 2.1 Red-verify in a sandbox HOME: a fresh install writes a checkout path; a stale installer line is not repaired
- [ ] 2.2 Guarded deployed-copy lines; rewrite installer-shaped stale lines with a backup and an atomic rename; leave and name other shapes; idempotent
- [ ] 2.3 Proof: an interactive zsh with the installed rc defines `claude-cleanup` and `cc-monitor` and prints nothing to stderr

## 3. Docker on a shared host

- [ ] 3.1 Red-verify: with dangling images listed, the clean invokes `docker rmi`
- [ ] 3.2 Report dangling images (count and review command); a failed inventory reports that nothing was examined
- [ ] 3.3 Structural check: no `docker rmi`, `image rm`, `volume rm` or `prune` invocation in the janitor

## 4. Stop hook

- [ ] 4.1 Carry the documented tool-call process-group blind spot into the repository's hook (comment only)

## 5. Delivery

- [ ] 5.1 All suites, `bash -n`, `zsh -n`, `openspec validate --strict`
- [ ] 5.2 Independent review
- [ ] 5.3 Deploy by rename with backups of the replaced files; repair this host's rc lines with a backup; verify the running copies match main and a new shell loads the functions
