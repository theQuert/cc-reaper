## 1. Specification

- [x] 1.1 An ADDED scenario under "Dual safety gate for removal"; validate strictly.

## 2. Implementation

- [x] 2.1 Red then green: a plist naming a path under a landed, idle worktree keeps it; a plist
  naming another path does not; an unreadable plist changes nothing.

## 3. Verification and delivery

- [ ] 3.1 Shell suites, `bash -n`, shellcheck, `openspec validate --strict`.
