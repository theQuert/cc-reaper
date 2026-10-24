## ADDED Requirements

### Requirement: A scratchpad is kept for liveness, not for being named
The reaper SHALL NOT keep an idle session scratchpad merely because a transcript names its path. A directory a transcript names SHALL be kept only while its session is alive (a live `~/.claude/sessions/<pid>.json` record, or its id on a running command line), a process holds a file or cwd under it, its session wrote a transcript inside the idle window, it belongs to a session named by `BYPRODUCT_PROTECT_SESSIONS`, or `closed-sessions.md` records its session closed within `BYPRODUCT_RESUME_DAYS` days. Holders SHALL be read from one `lsof` listing per run, and a fresh `lsof` SHALL be taken immediately before each removal; a directory then held SHALL be skipped. An `lsof` that lists nothing, or session records that cannot be read, SHALL keep a directory only this rule would remove. A directory no transcript names SHALL still be judged by the liveness gate.

#### Scenario: Named by another session, otherwise dead
- **WHEN** an idle scratchpad is named only by another session's transcript, its session is not alive, nothing holds it and it is not protected
- **THEN** it is removable under this rule

#### Scenario: A process holds it
- **WHEN** the same scratchpad has a file open under it
- **THEN** it is kept and the log names the holder's pid

### Requirement: Newly allowed removals are spot-checked before they delete
A removal that only this rule allows SHALL, while `CC_RB_NEW_RULES_MODE` is not `auto` (the default is `spotcheck`), delete nothing and append its run id, path, size, decision, reason and holder check to `~/.cc-reaper/logs/spotcheck-reclaim-byproducts.log`. A dry run SHALL print those lines and write no file. Removals the previous rules allowed SHALL continue in either mode.

#### Scenario: Default mode
- **WHEN** a sweep finds a scratchpad removable only under this rule
- **THEN** it stays on disk and the spot-check log records `decision=would-remove`
