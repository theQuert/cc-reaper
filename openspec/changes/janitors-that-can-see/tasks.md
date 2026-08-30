## 1. disk-janitor sees its tools

- [x] 1.1 Prepend the known tool directories to `PATH` at script scope, before any target resolves
- [x] 1.2 Red-verify: with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, the pre-change script skips go/yarn/brew/bun/docker and the post-change script does not

## 2. A skipped run says so

- [x] 2.1 Count targets run and skipped in `_cc_dj_clean_target` and `_cc_dj_clean_dir`
- [x] 2.2 Report both counts on the final line
- [x] 2.3 Measure per-target freed bytes from the volume free-space delta; report 0, not `?`

## 3. docker cleanup stops being able to delete expensive images

- [x] 3.1 Replace `docker system prune -af` with dangling-image removal by id
- [x] 3.2 Add anonymous-volume removal by name, computed against every container's mounts
- [x] 3.3 Distinguish "docker absent" from "daemon unreachable" in the skip line
- [x] 3.4 Assert no `docker .* prune` string survives anywhere in the source

## 4. worktree inventory: what a schedule can and cannot do

- [x] 4.1 Measure whether a LaunchAgent can reach `~/Documents`; it cannot, so no agent is added
- [x] 4.2 Have `install.sh` state that the inventory is manual and why
- [x] 4.3 Gate the report path's prune on `--apply`

## 5. cc-monitor sees runaways with living parents

- [x] 5.1 Add a sustained-CPU check keyed on elapsed CPU time, independent of PPID
- [x] 5.2 Report the parent chain; never kill from this check

## 6. Proof

- [x] 6.1 Unit tests for the docker target's id/name computation and for skip accounting
- [x] 6.2 Re-run the repo's existing test suite
