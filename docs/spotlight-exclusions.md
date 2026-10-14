# Keeping worktree trees out of Spotlight

Measured on the Mac mini (macOS 26.2, 2026-10-14) with a probe directory under `$HOME`, a control
folder beside each variant, and `mdfind -onlyin <dir> -name <unique tag>` after the control showed up
in the index (about 10 s). Nothing here needed root.

| Mechanism | Result |
|---|---|
| `.metadata_never_index` file inside the folder | **Not honoured.** Created before the files, they were indexed anyway. (It works at a volume root only.) |
| `chflags hidden` on the folder | **Not honoured.** Indexed. |
| `mdutil -i off <folder>` | Refused as the user: `Error: invalid operation` (mdutil takes volumes, not folders). |
| Folder name ending `.noindex` | **Works.** Never indexed; renaming an already indexed folder to `x.noindex` removed its files from `mdfind` within 25 s. |
| Dot-prefixed folder name | Works (same rule), no use for fixed paths. |
| Symlink `x -> x.noindex` | **Works**: files created through the link live under the `.noindex` directory and are not indexed. |

Which of the folders the reaper cares about are indexed today (`mdfind -onlyin`):

| Folder | Indexed |
|---|---|
| `~/GitHub/stima-api-worktrees` | yes (5610 `package.json` hits) |
| `~/GitHub/cc-reaper-worktrees` | yes |
| `~/GitHub/skills-worktrees` | empty today |
| `~/GitHub/stima-api/.claude/worktrees` | no (hidden `.claude` parent) |
| `~/Library/Caches/go-build` | no |
| `/private/tmp/claude-501` | no |

So only the worktree roots need action, and the only no-root mechanism is a rename. The reaper does
not do it, because the rename changes `git rev-parse --show-toplevel` inside every worktree to the
`.noindex` path (measured: `git worktree list` keeps the old path, `--show-toplevel` and `pwd -P`
report `wts.noindex/a`), which feeds Claude Code's per-path project keys and the janitor's path
comparisons. The owner's choice, in a quiet moment with no session inside a worktree:

1. System Settings > Spotlight > Search Privacy > add the folders (admin authentication in the GUI;
   no path changes). Not verifiable from a script here, so not tested.
2. Or the verified rename, per root, accepting the path change above:

   ```
   mv ~/GitHub/stima-api-worktrees ~/GitHub/stima-api-worktrees.noindex &&
     ln -s stima-api-worktrees.noindex ~/GitHub/stima-api-worktrees
   ```

Check after either: `mdfind -onlyin ~/GitHub/stima-api-worktrees -name package.json | wc -l` falls to 0
once `mds` has processed the change.
