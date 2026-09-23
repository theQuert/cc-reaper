## 1. disk-janitor sees its tools

- [x] 1.1 Append the known tool directories to `PATH` at script scope, before any target resolves. Appended, not prepended: a caller's own entry and a test sandbox's stubs keep priority
- [x] 1.2 Cover the standard Bun (`$HOME/.bun/bin`) and Go (`/usr/local/go/bin`) install locations — a default list that misses a tool's standard location reproduces the bug
- [x] 1.3 Red-verify: with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, the pre-change script skips go/yarn/brew/bun/docker and the post-change script does not
- [x] 1.4 Gate the resolution test on `CC_DJ_TOOL_DIRS`, not the ambient `PATH`, and tolerate an absent tool under `set -e`

## 2. A skipped run says so

- [x] 2.1 Count targets run and skipped in `_cc_dj_clean_target` and `_cc_dj_clean_dir`
- [x] 2.2 Report both counts on the final line
- [x] 2.3 Reset both counters at the top of `_cc_dj_clean`, not at source time
- [x] 2.4 Measure per-target freed bytes from the volume free-space delta, using `df -Pk` — bare `df -P` is 512-byte blocks on macOS and reported every saving at twice its size
- [x] 2.5 Measure directory removals the same way, reporting `du` size and the delta separately so held-open blocks are visible
- [x] 2.6 Declare the volume report's `python3` dependency and count it as a skip; a target that exits 127 is otherwise counted as one that ran

## 3. docker cleanup stops being able to destroy anything expensive

- [x] 3.1 Replace `docker system prune -af` with dangling-image removal by id
- [x] 3.2 Report unreferenced volumes with docker-generated-looking names; do **not** remove them. A 64-hex name does not establish provenance — `docker volume create` accepts one from anyone and `docker volume inspect` exposes no flag separating the two
- [x] 3.3 Distinguish "docker absent" from "daemon unreachable" in the skip line
- [x] 3.4 Propagate the status of every docker command, including the inventory producers: an unreadable container inventory must not read as an empty reference set
- [x] 3.5 Assert that neither `docker .* prune` nor `volume rm` survives outside comments

## 4. worktree inventory: what a schedule can and cannot do

- [x] 4.1 Measure whether a LaunchAgent can reach `~/Documents`; it cannot, so no agent is added and the gap is recorded as still open
- [x] 4.2 Have `install.sh` state that the inventory is manual and why
- [x] 4.3 Gate the report path's prune on `--apply`
- [x] 4.4 Bound the launchd log pair at the top of `_cc_wj_run` — a report-only run never reaches `_cc_wj_log_write`

## 5. cc-monitor identifies runaways by behaviour, not identity

- [x] 5.1 Move the sustained-CPU test out of the protected-command branch so any non-immutable process can be labelled. It was never orphan-gated — the first diagnosis was wrong and the fixture written to prove it passed against the unfixed source
- [x] 5.2 Stop an Always Protect user rule from suppressing the label; the rule still governs the action
- [x] 5.3 Admit rows meeting the runaway CPU threshold through the prefilter, so a raised `--min-cpu` cannot make detection depend on identity again
- [x] 5.4 Lower the reporting floor to 30 minutes, leaving `claude-guard`'s signalling floor at 60 in its own implementation
- [x] 5.5 Give unprotected runaways an applicable suggested action; `claude-guard` filters through its whitelist and would do nothing for them
- [x] 5.6 Drop "protected" from the section heading and reason text, which stopped being true of what they list

Not done, and not claimed: the human report does not print a parent chain. The JSON
findings carry `ppid` and `pgid`; the text line does not, and adding it was not part of
what shipped.

## 6. Proof

- [x] 6.1 Unit tests for the docker target's id computation, the volume report's count, skip accounting, counter scope, tool resolution and inventory-failure handling
- [x] 6.2 Red-verify each fix against its pre-fix source, and say so where an assertion is a guard rather than evidence
- [x] 6.3 Stop the test fixture writing through its own symlinks into `/usr/bin`, and assert that stubbed entries are files in the sandbox
- [x] 6.4 Re-run the repo's existing test suite: 15 files, no failures, no hangs
