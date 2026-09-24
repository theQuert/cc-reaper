## 1. Specification

- [x] 1.1 An ADDED requirement only: a MODIFIED block drops every scenario it omits when the
  change is archived. Validate strictly.

## 2. Implementation

- [x] 2.1 Red then green: a done worktree inside the idle window with a cwd or a
  structured-tool-call lease is REMOVABLE, `--apply` removes it, and its branch remains;
  without the annotation it is kept.
- [x] 2.2 Red then green: stale, malformed, detached, dirty, unlanded, held and live-claimed
  annotated worktrees are judged as before; the validity rule case by case.
- [x] 2.3 Red then green: an annotation withdrawn before a removal restores the lease recheck;
  a lease answer from an archive race neither keeps a done worktree nor hides a live claim
  read after it.
- [x] 2.4 Mutants: ignoring the head comparison, accepting a detached HEAD, skipping the landed
  requirement, waiving the lease at classification or at removal only, honouring the
  annotation on a dirty tree, and waiving a lease answer without asking again each turn a
  test red.

## 3. Verification and delivery

- [ ] 3.1 Full shell suite, `bash -n` and `zsh -n`, `openspec validate --strict`; review of the
  exact head.
- [ ] 3.2 Deploy by rename; the stima-api dev loop starts writing the annotation.
