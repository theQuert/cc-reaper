## 1. RSS Threshold Configuration

- [x] 1.1 [P] Add `CC_MAX_RSS_MB` env var parsing at top of `claude-guard` with default 4096 and non-numeric fallback warning

## 2. Tree RSS Calculation

- [x] 2.1 Extract tree RSS calculation into a reusable helper function `_claude_tree_rss` (refactor from `claude-sessions`)

## 3. Bloated Session Detection & Kill

- [x] 3.1 Add bloated session detection loop in `claude-guard`: iterate sessions, call `_claude_tree_rss`, compare against threshold, mark `[BLOATED]`
- [x] 3.2 Add PGID-based kill for bloated sessions (before idle session eviction), with desktop notification via `osascript`
- [x] 3.3 Update `--dry-run` output to display `[BLOATED]` sessions with tree RSS and threshold

## 4. Documentation

- [x] 4.1 [P] Update CLAUDE.md with `CC_MAX_RSS_MB` in Key Commands section
