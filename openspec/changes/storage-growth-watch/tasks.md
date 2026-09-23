## 1. Specification

- [x] 1.1 Validate this change strictly and update the disk-janitor Purpose to name the watch.

## 2. Sampler

- [x] 2.1 Red then green: due keys are measured oldest first and never-measured first; a key
  inside its interval is not; the budget stops new measurements and the waiting count is
  logged; glob targets become one key per matching directory.
- [x] 2.2 Red then green: denied, absent and timed-out targets record their status; Docker
  categories and volumes are read from one call each; samples older than 14 days are dropped.

## 3. Growth

- [x] 3.1 Red then green: a key that grew by its threshold against a day-old sample logs
  `ALERT:growth` with owner, growth, hours and size; below the threshold nothing is raised;
  no baseline at least 3 hours old raises nothing; a status sample carries no growth.
- [x] 3.2 Red then green: a label total is recorded only when every member has a number, and
  its growth alerts like a key's; the top three growers are logged.

## 4. Integration

- [x] 4.1 `--check` runs the watch, logs its lines, posts one cooldown-gated `growth`
  notification, counts a missing `python3` as a `SKIP`; the installer deploys the script and
  installs the targets template without replacing an operator-edited copy.

## 5. Verification and delivery

- [ ] 5.1 Full shell suite, `bash -n` and `zsh -n`, `openspec validate --all --strict`;
  independent review of the exact head.
- [ ] 5.2 Deploy by rename with a rollback manifest; host targets configured; the first
  sampling runs complete within budget; no LaunchAgent reload.
