# Host memory: the wired-memory leak

## What it is

On macOS 26 every start of a script through its `#!` line leaks about 1 KiB of kernel memory,
whatever started it. The memory sits in the kernel zone `kalloc.1024` (shown as
`data_shared.kalloc.1024`, or `data.kalloc.1024` on some builds) and counts as wired memory.
Nothing frees it except a restart. The cause is a macOS bug, so the only defence is to start
scripts by their interpreter (`python3 x.py`, `/bin/sh x.sh`) wherever a script is started often.

Measured on this host on 2026-11-18 (theQuert/stima-api#9010), 100 starts a block, six blocks,
from a parent that was itself started by its interpreter: by path a median +113 elements, by
interpreter -16, an idle block of the same length +20. Hooks are the frequent case: the session
event logs counted about 2,300 tool calls an hour across the host, and each one started five or
more hook scripts by path.

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

## The host is not restarted

The Mac mini stays online and is not restarted (founder, 2026-11-20): a restart would end every tmux and Claude Code
session and the CI runners. The memory the zone holds therefore stays held, and no script, alert or report
recommends a restart.

When wired is at or above 12 GB, or `kzone` is above 10 million, the host has that much less memory for good. What
is left to do:

- Move CPU and memory work off the host: tests, builds and verification run on InstaBox VMs (stima-api #9371, #9359).
- Stop what makes the zone grow: name the interpreter when one script starts another (see above), and fix the launch
  paths `kzone_rate` points at.

## Does a macOS update fix it

Do not assume. After an update, compare `kzone_rate` before and after, with sessions running a
similar load. A rate near zero is the evidence; the version number is not.
