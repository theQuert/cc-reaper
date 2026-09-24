## 1. Specification

- [x] 1.1 One ADDED requirement only. A MODIFIED block drops every scenario it leaves out when
  the change is archived. Validate strictly.

## 2. Implementation

- [x] 2.1 Red then green: a landed worktree whose only content is archive-declared files is
  REMOVABLE, and the report names what will be archived. `--apply` copies byte-identical files
  into a new directory, records an index row, removes the worktree and keeps its branch.
- [x] 2.2 Red then green: an oversize file, a credential-shaped name, a symlink and an
  invalid size limit each keep the worktree, and each is named in the report. A pattern that
  names no path is dropped with its prefix.
- [x] 2.3 Red then green: a file written between the scan and the removal is copied too; an
  archive directory that cannot be created keeps the worktree; a copy that differs from its
  source keeps the worktree.
- [x] 2.4 Mutants, each of which must turn a test red:
  - archiving the inventory-time list instead of the fresh one;
  - skipping the byte comparison;
  - dropping the size limit;
  - dropping the credential check;
  - removing the worktree after a failed copy.

## 3. Verification and delivery

- [ ] 3.1 Full shell suite, `bash -n` and `zsh -n`, `openspec validate --strict`, and a
  review of the exact head.
- [ ] 3.2 Deploy by rename. stima-api declares `archive:.canary-window-plan`, and a dry run on
  the host shows the plan-only worktrees REMOVABLE with their archive line.
