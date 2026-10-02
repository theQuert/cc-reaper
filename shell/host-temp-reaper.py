#!/usr/bin/env python3
"""Reclaim what headless-Chrome scripts, wrangler and failed test builds leave in this
user's temp space.

Four kinds, each proved abandoned before it is touched:

- an orphaned headless Chrome: launched with --headless, --remote-debugging-port and a
  --user-data-dir directly under this user's temp directory, reparented to launchd (its
  launcher is gone), older than the idle limit, and with no DevTools client connected;
- a `cdp-XXXXXX` profile directory directly under the temp directory that no running
  process names as its --user-data-dir, no process holds open, and nothing has changed
  for the idle limit;
- a `wrangler-*.log` under ~/Library/Preferences/.wrangler/logs that nothing has written
  for the idle limit and no process holds open;
- a known test's throwaway repository copy (`BUILD_COPY`) directly under the temp
  directory, created at least BUILD_COPY_IDLE_SECONDS ago and held open by no process
  (lsof +D also reports a process whose cwd is inside it). The docs repo's nimbus
  articles build test removes its 1.8 GB copy only when it passes, so every failed run
  left one: five copies, 9.2 GB, on 2026-10-02. A day rather than the idle limit,
  because NIMBUS_ARTICLES_BUILD_KEEP=1 keeps a copy on purpose and nothing on disk
  tells it from a leak; a day still covers reading it the next morning.

Every probe that fails or cannot decide keeps the item. Chrome is sent SIGTERM only, so
it shuts down on its own terms. Tests drive the seams (`processes`, `listening_ports`,
`has_client`, `held`) with fixtures; no CLI option names an arbitrary root.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


PROFILE_NAME = re.compile(r"cdp-[A-Za-z0-9]{6}$")
WRANGLER_LOG = re.compile(r"wrangler-[0-9_-]+\.log$")
BUILD_COPY = re.compile(r"nimbus-articles-build-[A-Za-z0-9]{6}$")
BUILD_COPY_IDLE_SECONDS = 24 * 3600
# The browser itself, never a Helper: helper paths run from "Google Chrome Helper.app".
CHROME_BINARY = re.compile(r"/\S.*/Google Chrome\.app/Contents/MacOS/Google Chrome(?= --)")


def temp_root():
    return Path(tempfile.gettempdir()).resolve()


def processes():
    """Yield (pid, ppid, elapsed_seconds, command) for every process; None when ps fails."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,etime=,command="], capture_output=True,
                             text=True, timeout=30, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), elapsed_seconds(parts[2]), parts[3]))
    return rows


def elapsed_seconds(etime):
    """ps etime: [[dd-]hh:]mm:ss."""
    days, _, clock = etime.rpartition("-")
    fields = [int(f) for f in clock.split(":")]
    while len(fields) < 3:
        fields.insert(0, 0)
    return (int(days) if days else 0) * 86400 + fields[0] * 3600 + fields[1] * 60 + fields[2]


def user_data_dir(command):
    match = re.search(r"--user-data-dir=(\S+)", command)
    return Path(match.group(1)).resolve() if match else None


def listening_ports(pid):
    """TCP ports pid listens on; None when lsof cannot answer."""
    try:
        probe = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
                               capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if probe.returncode not in (0, 1):
        return None
    return {int(f.rsplit(":", 1)[1]) for f in probe.stdout.split() if f.startswith("n") and ":" in f}


def has_client(port):
    """True when any established TCP connection uses port, or the probe fails."""
    try:
        probe = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:ESTABLISHED", "-Fn"],
                               capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return True
    if probe.returncode not in (0, 1):
        return True
    return any(f.startswith("n") for f in probe.stdout.split())


def held(path):
    """True for a holder or any failed/inconclusive probe."""
    flag = "+D" if path.is_dir() else "--"
    try:
        probe = subprocess.run(["lsof", "-F0n", flag, str(path)], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return True
    if probe.stderr or probe.returncode not in (0, 1):
        return True
    target = os.fsencode(str(path))
    return any(f == b"n" + target or f.startswith(b"n" + target + b"/")
               for f in probe.stdout.split(b"\0"))


def orphan_chrome(row, root, idle_seconds):
    pid, ppid, elapsed, command = row
    if ppid != 1 or elapsed < idle_seconds or not CHROME_BINARY.match(command):
        return False
    if "--headless" not in command or "--remote-debugging-port=" not in command:
        return False
    profile = user_data_dir(command)
    if profile is None or profile.parent != root:
        return False
    ports = listening_ports(pid)
    return bool(ports) and not any(has_client(port) for port in ports)


def idle(path, idle_seconds, now):
    return now - path.lstat().st_mtime >= idle_seconds


def reap(root, logs_dir, clean=False, idle_seconds=3600, now=None, send=os.kill):
    """Return counts {kind: (candidates, acted)}; prints one line per item."""
    now = time.time() if now is None else now
    rows = processes()
    if rows is None:
        raise RuntimeError("ps failed; kept everything")
    counts = {"chrome": [0, 0], "profile": [0, 0], "wrangler": [0, 0], "build": [0, 0]}

    for row in rows:
        if not orphan_chrome(row, root, idle_seconds):
            continue
        counts["chrome"][0] += 1
        if not clean:
            print(f"CANDIDATE chrome pid={row[0]}")
            continue
        # Recheck the same pid right before signalling: a reused pid fails closed.
        again = [r for r in (processes() or []) if r[0] == row[0]]
        if not again or again[0][3] != row[3] or not orphan_chrome(again[0], root, idle_seconds):
            print(f"KEEP chrome pid={row[0]} (changed)")
            continue
        send(row[0], signal.SIGTERM)
        counts["chrome"][1] += 1
        print(f"TERM chrome pid={row[0]} profile={user_data_dir(row[3]).name}")

    # Profiles named by a live process, including the Chromes just signalled, are kept
    # this run; the next run finds them unreferenced.
    named = {user_data_dir(r[3]) for r in rows} - {None}
    for path in sorted(root.iterdir()) if root.is_dir() else []:
        if not PROFILE_NAME.fullmatch(path.name) or path.is_symlink() or not path.is_dir():
            continue
        if path in named or not idle(path, idle_seconds, now) or held(path):
            continue
        counts["profile"][0] += 1
        if clean:
            shutil.rmtree(path)
            counts["profile"][1] += 1
        print(f"{'REMOVED' if clean else 'CANDIDATE'} profile {path.name}")

    for path in sorted(logs_dir.iterdir()) if logs_dir.is_dir() else []:
        if not WRANGLER_LOG.fullmatch(path.name) or path.is_symlink() or not path.is_file():
            continue
        if not idle(path, idle_seconds, now) or held(path):
            continue
        counts["wrangler"][0] += 1
        if clean:
            path.unlink()
            counts["wrangler"][1] += 1
        print(f"{'REMOVED' if clean else 'CANDIDATE'} wrangler {path.name}")

    for path in sorted(root.iterdir()) if root.is_dir() else []:
        # One copy that vanishes or will not delete is kept; it never stops the run.
        try:
            if not BUILD_COPY.fullmatch(path.name) or path.is_symlink() or not path.is_dir():
                continue
            if not idle(path, max(idle_seconds, BUILD_COPY_IDLE_SECONDS), now) or held(path):
                continue
            counts["build"][0] += 1
            if clean:
                shutil.rmtree(path)
                counts["build"][1] += 1
            print(f"{'REMOVED' if clean else 'CANDIDATE'} build {path.name}")
        except OSError as error:
            print(f"KEEP build {path.name} ({error.strerror or error})")
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check", "clean"))
    parser.add_argument("--idle-minutes", type=int, default=60)
    args = parser.parse_args()
    if args.idle_minutes < 30:
        raise ValueError("idle limit must be at least 30 minutes")
    counts = reap(temp_root(), Path.home() / "Library/Preferences/.wrangler/logs",
                  clean=args.mode == "clean", idle_seconds=args.idle_minutes * 60)
    print("host temp: " + " ".join(f"{k}={v[1]}/{v[0]}" for k, v in counts.items()))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(f"host temp: SKIP {error}", file=sys.stderr)
        sys.exit(1)
