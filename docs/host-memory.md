# Host memory: the wired-memory leak

## What it is

On macOS 26 a process that was started through a `#!` line and then starts another script
through its own `#!` line leaks about 1 KiB of kernel memory. The memory sits in the kernel
zone `kalloc.1024` (shown as `data_shared.kalloc.1024`, or `data.kalloc.1024` on some builds)
and counts as wired memory. Nothing frees it except a restart. The cause is a macOS bug, so the
only defence is to start scripts by their interpreter (`python3 x.py`, `/bin/sh x.sh`) wherever
one script starts another often. The largest source, the stima-api hook dispatcher, was changed
that way in theQuert/stima-api#9010: measured there, a guard started by path leaks a median 1.12
elements a launch, started by its interpreter 0.31 or less.

## The three fields

`resource-watch` writes them on every line (every 180 s):

- `wired=<GB>`: wired memory from `vm_stat`, in GB with one decimal. `ALERT:wired` is added
  when it is at or above `CC_RW_WIRED_ALERT_GB` (default 12). The notification is sent once per
  breach: the leak only grows until a restart, so it stays quiet until wired has read under the
  line again. Every line keeps `ALERT:wired` while the breach lasts.
- `kzone=<count>`: elements in use in the `kalloc.1024` zone, the larger of the `data` and
  `data_shared` zones, read with `zprint` (needs no root). Each element is 1024 bytes.
  `kzone=?` means `zprint` is missing or failed.
- `kzone_rate=<elements/hour>`: growth since the previous run, from `<state>/kzone-last`
  (`<epoch> <count>`). `?` on the first run, after a restart (the count fell), or when
  `kzone` is unreadable.

## Measured 2026-11-18 (macOS 26.2, 32 GB)

- Wired 18.1 GB (1187106 pages of 16384 bytes); compressor 356434 pages; swap 5.3 of 6.1 GB.
- `data_shared.kalloc.1024`: 16.1 million elements, about 15.7 GB, most of the wired memory.
- Growth 4-8 elements/s, about 14-28 MB/h.

## When to restart

Recommend a restart when wired is at or above 12 GB, or `kzone` is above 10 million, at a time
when no release or staging window is running.

A restart interrupts every tmux and Claude Code session and the CI runners. FileVault is off and
auto-login is set, so the host comes back by itself; sessions return with
`claude --resume <id>`.

No script restarts the host. The founder decides.

## Does a macOS update fix it

Do not assume. After an update, compare `kzone_rate` before and after, with sessions running a
similar load. A rate near zero is the evidence; the version number is not.
