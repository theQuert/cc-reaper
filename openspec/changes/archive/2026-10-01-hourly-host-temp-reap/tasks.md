## 1. Reclaimer

- [x] 1.1 `shell/host-temp-reaper.py` with isolated tests (`tests/host-temp-reaper.py`) for every keep rule, and mutants for each.
- [x] 1.2 Wire it, the one-day clone age and the daily builder prune into `disk-janitor --check`, and extend `tests/disk-janitor.sh` with the contract.
- [x] 1.3 Installer deploys `host-temp-reaper.py`.

## 2. Verification and delivery

- [x] 2.1 Full shell suite, `bash -n`, `zsh -n`, `openspec validate --all --strict`, and my own review of the exact head.
  Every `tests/*.sh` and `tests/*.py` passed; `tests/disk-janitor.sh` 136 ok; 8 reclaimer tests
  with 14 mutants caught and 5 wiring mutants caught; strict validate 10/10.
- [x] 2.2 Deploy by rename with a rollback manifest; confirm the next hourly check logs the host temp step and the daily builder prune. Deployed 2026-09-30T18:13Z (`hourly-host-temp-reap-20260930T181321`). By 2026-10-01 the host temp step had run 15 hourly checks without a SKIP and removed 53 profiles; the daily builder prune ran at 02:17 and wrote its stamp.
