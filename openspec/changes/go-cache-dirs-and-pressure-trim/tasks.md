## 1. Specification

- [x] 1.1 ADDED and MODIFIED requirements.

## 2. Implementation

- [x] 2.1 Red then green: an `<hash>-d` directory idle past the window and over the cap is removed
  by `--go-cache-cap`, the age trim, the `go-build-age` step and `--clean`; one with a member used
  inside the window, a fresh one, and a held one stay.
- [x] 2.2 The cap logs the measured size remaining inside the window.
- [x] 2.3 `dirty-pressure` promoted, pressure wait 6 h; a deny-listed tree is trimmed like any
  other and kept for removal; the trim summary reports the `df` delta.
- [ ] 2.4 After install, measure on the Mac mini: `du -sk ~/Library/Caches/go-build` after a cap
  run, and the first scheduled trim's `df-freed` (operator).
