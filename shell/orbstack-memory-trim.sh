#!/bin/sh
# Keep OrbStack's VM from pushing this host into swap, without restarting it.
#
# macOS memory pressure never reaches the Linux guest, so the guest's page cache
# grows until the VM process holds most of its memory_mib and the rest of the
# host swaps. Dropping the guest's clean caches hands those pages back to macOS:
# on 2026-09-25 the VM process went from 10.46 GiB to 4.02 GiB.
#
# Each run reads the VM process's resident size. Above the limit, a throwaway
# privileged container drops the guest's caches. Nothing is restarted and
# nothing is deleted; a later read refills what it needs. Each run prints one
# line, which the LaunchAgent appends to its log.
#
# The limit is a quarter of RAM, derived at run time; ORBSTACK_TRIM_LIMIT_MIB
# overrides it. The container goes to the `orbstack` docker context by name, so
# a context switched to another engine never receives it. A trim that has not
# finished within ORBSTACK_TRIM_TIMEOUT_SECONDS (120) is killed with SIGKILL and
# logged as failed, rather than holding the agent: launchd never starts a second
# run while one is still going. SIGALRM would not do: the docker CLI is a Go
# program, which catches it and forwards it into the container.
#
# install.sh deploys it to ~/.cc-reaper/orbstack-memory-trim.sh and loads
# launchd/com.cc-reaper.orbstack-memory-trim.plist, which runs it every 15 minutes.
# A host without OrbStack logs vm=not-running and does nothing.
# Adopted from stima-api scripts/ci/orbstack_memory_trim.sh on 2026-10-07.
# Status: launchctl print gui/$(id -u)/com.cc-reaper.orbstack-memory-trim
# Log:    ~/.cc-reaper/logs/orbstack-memory-trim.log (one line per run)
set -eu

image=alpine@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
limit=${ORBSTACK_TRIM_LIMIT_MIB:-$(( $(sysctl -n hw.memsize) / 4 / 1048576 ))}
settle=${ORBSTACK_TRIM_SETTLE_SECONDS:-10}
timeout=${ORBSTACK_TRIM_TIMEOUT_SECONDS:-120}

say() { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*"; }
vm_mib() { ps -o rss= -p "$1" | awk '{ print int($1 / 1024) }'; }

swap=$(sysctl -n vm.swapusage | awk '{ print $6 }')
pid=$(pgrep -o -f 'MacOS/OrbStack Helper vmgr') || { say "vm=not-running swap_used=$swap action=none"; exit 0; }
before=$(vm_mib "$pid")
# A VM that exited between pgrep and ps reads as no size, which is not "over".
case $before in ''|*[!0-9]*) say "vm=not-running swap_used=$swap action=none"; exit 0 ;; esac
state="vm_mib=$before limit_mib=$limit swap_used=$swap"
if [ "$before" -le "$limit" ]; then
  say "$state action=none"
  exit 0
fi
# ponytail: no backoff. If the guest's own memory stays above the limit, every
# run trims; the log shows after_mib staying high. Lower memory_mib then.
# macOS has no timeout(1). A docker that cannot start exits non-zero too.
perl -e 'my $t = shift; defined(my $pid = fork) or die "fork: $!\n";
  $pid or exec(@ARGV) or die "exec $ARGV[0]: $!\n";
  $SIG{ALRM} = sub { kill "KILL", $pid }; alarm $t; waitpid $pid, 0;
  exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$timeout" \
  docker --context orbstack run --rm --name cc-reaper-orbstack-memory-trim --privileged --network none "$image" \
  sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches' || { say "$state action=trim-failed"; exit 1; }
sleep "$settle"
say "$state action=trim after_mib=$(vm_mib "$pid")"
