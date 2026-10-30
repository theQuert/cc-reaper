#!/usr/bin/env python3
"""Judge resource-watch's own log against the thresholds resource-watch itself runs with (EL-T24).

The spot-check that re-judges resource-watch (ops-dispatch spotcheck.d/host.py) carried its own copy of the
thresholds and drifted: it expected ALERT:disk-low under 40 GB while the script raises it under 60, and had no
swap value on the line to check ALERT:swap against. This module is the one judge, installed beside the script:

  config()        the effective CC_RW_* thresholds: the script's defaults (DEFAULTS, pinned to the script by the
                  tests), overridden by the installed LaunchAgent's EnvironmentVariables, which is where launchd
                  takes the script's environment from; a value the script would refuse falls back as it does.
  judge_line()    one snapshot line: the ALERT markers its own numbers imply (load, disk, disk-low,
                  disk-emergency, mem, swap, disk-rate) against the markers it carries, plus the swap=/rate= fields.
                  Swap is judged on the line's swap_hot= field, the script's own decision (swap over the limit
                  AND still being written: macOS never shrinks swap, so size alone is not the flag): ALERT:swap
                  exactly when swap_hot=1, either way when swap_hot=?. A line without swap_hot (written before
                  it existed) keeps the size-only rule.
  judge_events()  the pause chain in a run of lines: a DISK-PAUSE never follows a DISK-PAUSE (nor a RESUME a
                  RESUME) in one mode, and no snapshot whose own numbers hold a lease (swap, emergency, flag rate)
                  comes while the newest event says DISK-RESUME.
  judge_log()     both, over the newest lines of a log.

Read-only: it reads a plist and a log, and never runs the script.

  resource-watch-judge.py [--log PATH] [--plist PATH] [--lines N]   print misses (JSON), exit 1 when any
"""
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
PLIST = HOME / "Library/LaunchAgents/com.cc-reaper.resource-watch.plist"
LOG = HOME / ".cc-reaper/logs/resource-watch.log"

# The script's defaults, knob by knob. tests/resource-watch-judge.py reads them back out of
# shell/resource-watch.sh, so a default changed there without here fails the tests.
DEFAULTS = {
    "CC_RW_LOAD_FACTOR": 2.0,
    "CC_RW_DISK_MIN_PCT": 15.0,
    "CC_RW_MEM_MIN_PCT": 5.0,
    "CC_RW_DISK_ALERT_GB": 60.0,
    "CC_RW_DISK_EMERGENCY_GB": 20.0,
    "CC_RW_RATE_ALERT_GBH": 10.0,
    "CC_RW_RATE_FLAG_GBH": 20.0,
    "CC_RW_SWAP_FLAG_GB": 18.0,
}
NUM = re.compile(r"^[0-9]+(\.[0-9]+)?$")  # the script's own knob check: anything else is the default

LINE = re.compile(
    r"^(?P<ts>\S+) load=(?P<l1>[\d.]+)/(?P<l5>[\d.]+)/(?P<l15>[\d.]+) cpu_idle=\S+ mem_free=(?P<mf>[\d.]+)% "
    r"compressor=(?P<comp>[\d.]+)GB disk_free=(?P<free>[\d.]+)GB/(?P<pct>[\d.]+)%"
    r"(?P<fields> swap=(?:(?P<swap>[\d.]+)GB|\?) rate=(?:(?P<rate>-?[\d.]+)GB/h|\?)(?: swap_hot=(?P<hot>[01?]))?)?"
    r"(?P<rest>.*)$")
EVENT = re.compile(r"^\S+ EVENT (?P<mode>shadow|emitted)\b.*?: (?P<kind>DISK-PAUSE on|DISK-RESUME): ")
# Markers whose truth is on the line itself. disk-drop, disk-act-*, reclaim-stalled read state the line
# does not carry, so they are not judged here.
JUDGED = {"load", "disk", "disk-low", "disk-emergency", "mem", "swap", "disk-rate"}


def config(plist=PLIST, env=None):
    """{knob: float} the script runs with: DEFAULTS, then the LaunchAgent's EnvironmentVariables (or `env`)."""
    if env is None:
        try:
            env = plistlib.loads(Path(plist).read_bytes()).get("EnvironmentVariables") or {}
        except (OSError, ValueError, plistlib.InvalidFileException):
            env = {}
    cfg = dict(DEFAULTS)
    for key in DEFAULTS:
        value = str(env.get(key, "")).strip()
        if NUM.match(value):
            cfg[key] = float(value)
    return cfg


def is_snapshot(line):
    """A snapshot line (load=...), as opposed to an INFO/WARN/ERROR/EVENT line the script also writes."""
    parts = line.split(" ", 2)
    return len(parts) > 1 and parts[1].startswith("load=")


def swap_hot(x, cfg):
    """True/False when the line says whether swap holds the flag this round, None when it cannot be told
    (swap_hot=?). A line without swap_hot falls back to size alone, the rule before the field existed."""
    if x["hot"] is not None:
        return {"1": True, "0": False}.get(x["hot"])
    return x["swap"] is not None and cfg["CC_RW_SWAP_FLAG_GB"] > 0 and float(x["swap"]) > cfg["CC_RW_SWAP_FLAG_GB"]


def implied(x, cfg, ncpu, phys_gb):
    """The judged markers a parsed line's own numbers call for."""
    f = lambda k: float(x[k])
    on = lambda limit: cfg[limit] > 0
    want = set()
    if f("l1") > ncpu * cfg["CC_RW_LOAD_FACTOR"]:
        want.add("load")
    if f("pct") < cfg["CC_RW_DISK_MIN_PCT"]:
        want.add("disk")
    if on("CC_RW_DISK_ALERT_GB") and f("free") < cfg["CC_RW_DISK_ALERT_GB"]:
        want.add("disk-low")
    if on("CC_RW_DISK_EMERGENCY_GB") and f("free") < cfg["CC_RW_DISK_EMERGENCY_GB"]:
        want.add("disk-emergency")
    if f("mf") < cfg["CC_RW_MEM_MIN_PCT"] and f("comp") > phys_gb * 0.5:
        want.add("mem")
    if swap_hot(x, cfg):
        want.add("swap")
    if x["rate"] is not None and on("CC_RW_RATE_ALERT_GBH") and f("rate") > cfg["CC_RW_RATE_ALERT_GBH"]:
        want.add("disk-rate")
    return want


def holds_lease(x, cfg):
    """True when the line's own numbers write a pause flag this round (a lower bound: disk-stop is a dispatch's,
    disk-rate-high outlives an unmeasured round, and swap_hot=? leaves swap-high as it was, so a line can be
    paused without this). Swap counts by swap_hot, or by size on a line from before that field."""
    num = lambda k: x[k] is not None
    return (bool(swap_hot(x, cfg))
            or (cfg["CC_RW_DISK_EMERGENCY_GB"] > 0 and float(x["free"]) < cfg["CC_RW_DISK_EMERGENCY_GB"])
            or (num("rate") and cfg["CC_RW_RATE_FLAG_GBH"] > 0 and float(x["rate"]) > cfg["CC_RW_RATE_FLAG_GBH"]))


def judge_line(line, cfg, ncpu, phys_gb):
    """Misses for one snapshot line; [] when it agrees with itself. A line that is not a snapshot is not judged."""
    if not is_snapshot(line):
        return []
    x = LINE.match(line)
    if not x:
        return [f"unparsable resource-watch line: {line[:80]}"]
    misses, judged = [], JUDGED
    if x["fields"] is None:  # a line from before EL-T24: one miss, and the rest judged without swap and rate
        misses.append(f"{x['ts']} carries no swap=/rate= fields, so ALERT:swap and ALERT:disk-rate cannot be judged")
        judged = JUDGED - {"swap", "disk-rate"}
    have = set(re.findall(r"ALERT:([\w-]+)", x["rest"])) & judged
    want = implied(x, cfg, ncpu, phys_gb) & judged
    if x["hot"] == "?":  # the script left swap-high as it was: ALERT:swap is right either way
        have, want = have - {"swap"}, want - {"swap"}
    if have != want:
        misses.append(f"{x['ts']} markers {sorted(have) or '-'} but its numbers imply {sorted(want) or '-'} "
                      f"(swap={x['swap'] or '?'} rate={x['rate'] or '?'})")
    rate_marker = re.search(r"\bdisk_rate=(-?[\d.]+)GB/h", x["rest"])
    if rate_marker and x["fields"] is not None and rate_marker[1] != (x["rate"] or ""):
        misses.append(f"{x['ts']} rate={x['rate'] or '?'} but disk_rate={rate_marker[1]}GB/h")
    return misses


def judge_events(lines, cfg):
    """Misses in the pause chain over `lines`, oldest first."""
    misses, last = [], {}  # mode -> newest kind told in that mode
    newest = None  # (mode, kind) of the newest event in any mode
    for line in lines:
        e = EVENT.match(line)
        if e:
            if last.get(e["mode"]) == e["kind"]:
                misses.append(f"two {e['kind']} lines in a row ({e['mode']}), the second at {line.split(' ', 1)[0]}: "
                              "the dedupe did not hold")
            last[e["mode"]] = e["kind"]
            newest = (e["mode"], e["kind"])
            continue
        if not is_snapshot(line):
            continue
        x = LINE.match(line)
        if x and newest and newest[1] == "DISK-RESUME" and holds_lease(x, cfg):
            misses.append(f"{x['ts']} holds heavy leases by its own numbers (swap={x['swap'] or '?'} "
                          f"free={x['free']} rate={x['rate'] or '?'}) while the newest event is DISK-RESUME "
                          f"({newest[0]})")
    return misses


def judge_log(lines, cfg, ncpu, phys_gb):
    out = []
    for line in lines:
        out.extend(judge_line(line, cfg, ncpu, phys_gb))
    return out + judge_events(lines, cfg)


def _sysctl(name):
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def main(argv):
    args = dict(zip(argv[::2], argv[1::2]))
    log = Path(args.get("--log", LOG))
    try:
        lines = [l for l in log.read_text(errors="replace").splitlines() if l.strip()][-int(args.get("--lines", 40)):]
    except OSError as e:
        print(json.dumps({"misses": [f"cannot read {log}: {e}"]}))
        return 1
    ncpu, mem = _sysctl("hw.ncpu"), _sysctl("hw.memsize")
    if not (ncpu.isdigit() and mem.isdigit()):
        print(json.dumps({"misses": ["cannot read sysctl hw.ncpu/hw.memsize"]}))
        return 1
    cfg = config(args.get("--plist", PLIST))
    misses = judge_log(lines, cfg, int(ncpu), int(mem) / 1024 ** 3)
    print(json.dumps({"misses": misses, "lines": len(lines), "config": cfg}, indent=1))
    return 1 if misses else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
