## 1. Reclaimer

- [x] 1.1 `shell/host-temp-reaper.py` with isolated tests (`tests/host-temp-reaper.py`) for every keep rule, and mutants for each.
- [x] 1.2 Wire it, the one-day clone age and the daily builder prune into `disk-janitor --check`, and extend `tests/disk-janitor.sh` with the contract.
- [x] 1.3 Installer deploys `host-temp-reaper.py`.

## 2. Verification and delivery

- [ ] 2.1 Full shell suite, `bash -n`, `zsh -n`, `openspec validate --all --strict`, and my own review of the exact head.
- [ ] 2.2 Deploy by rename with a rollback manifest; confirm the next hourly check logs the host temp step and the daily builder prune.
