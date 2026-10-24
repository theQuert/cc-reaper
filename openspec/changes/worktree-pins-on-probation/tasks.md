## 1. Specification

- [x] 1.1 ADDED requirements only.

## 2. Implementation

- [x] 2.1 Red then green: a top-level log and a skills or commands link into the primary
  checkout no longer keep a tree in auto; a nested log and a link elsewhere still do.
- [x] 2.2 Red then green: spotcheck keeps every decision, logs would-remove and would-trim with
  rule, path, bytes, holder and run id, and logs nothing for a held or deny-listed tree.
- [x] 2.3 Red then green: an unlanded idle tree whose only pin is a log has node_modules trimmed in
  auto and only logged in spotcheck; a held one is kept.
- [x] 2.4 Red then green: a deny-listed tree, by name or by a live session's name, is neither
  trimmed nor removed.
- [x] 2.5 Red then green: a trim under pressure walks no tree with nothing to trim.
- [x] 2.6 Characterization: one holder scan (two lsof calls) per sweep over ten worktrees.
- [x] 2.7 Mutants: spotcheck acting as auto, any link target accepted, the trim precheck
  skipped, and the deny check skipped each turn a test red.
