#!/usr/bin/env python3
"""Reclaim what headless-Chrome scripts, wrangler, failed test builds and finished
background Claude jobs leave in this user's temp space.

Six kinds, each proved abandoned before it is touched:

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
  tells it from a leak; a day still covers reading it the next morning;
- a Python virtualenv (a directory holding `pyvenv.cfg`) directly in the `tmp/` of a
  finished background Claude job (~/.claude/jobs/<8 hex>/): its state.json says `done`
  or `stopped`, its last terminal time and the file itself are JOB_TMP_IDLE_SECONDS old,
  no running process names the venv on its command line (a test's child still running
  the venv's python does), and lsof +D finds no holder. Loop jobs built one there and
  nothing removed it: 75 jobs, 9.7 GB on 2026-10-02. Only the venv goes, because a
  resumed job reuses its directory: every other file in `tmp/` is the job's own and
  stays, and a venv is what `pip install` rebuilds. Three days, because resumes were
  seen 23 h and 42 h after a job ended. The job is checked again just before removal.

- a tool's own temp leftover directly under the temp directory, by the name that tool's
  mkdtemp/mktemp gives it (`LEFTOVERS`): Python's `tmpXXXXXXXX`, mktemp's `tmp.XXXXXXXXXX`,
  pip's `pip-unpack-…`, go's `go-build<N>`, the docs repo's `nimbus-…-XXXXXX` test copies.
  Nothing anywhere under it changed for that name's idle limit, no open file or cwd of
  this user's processes is inside it, and no command line names it. Each tool removes its
  own on a clean exit, so what is left is a killed or failed run: 442,337 entries, 16.4 GB
  on 2026-10-05, 10.3 GB of it untouched for a day. A day for the build tools; three for
  the generic `tmp` names, the age macOS itself clears them at boot, because any program
  may use one.

Every probe that fails or cannot decide keeps the item. Chrome is sent SIGTERM only, so
it shuts down on its own terms. Tests drive the seams (`processes`, `listening_ports`,
`has_client`, `held`) with fixtures; no CLI option names an arbitrary root.
"""

import argparse
from datetime import datetime
import json
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
# (name, idle seconds, directories only): a tool's own temp name, and how long it must be
# untouched. The generic names are directories only and must hold a digit, so a person's
# `tmp_scratch` or a file another program was handed by name is not one.
LEFTOVERS = (
    (re.compile(r"tmp(?=[a-z0-9_]*[0-9])[a-z0-9_]{8}"), 72 * 3600, True),
    (re.compile(r"tmp\.(?=[A-Za-z0-9]*[0-9])[A-Za-z0-9]{10}"), 72 * 3600, True),
    (re.compile(r"pip-[a-z]+(-[a-z]+)*-[a-z0-9_]{8}"), 24 * 3600, False),
    (re.compile(r"go-(build|link-)\d+"), 24 * 3600, False),
    (re.compile(r"nimbus-(acceptance|articles|env|m2|m2-build|m3r|m8|manifest|static)-[A-Za-z0-9_]{6}"),
     24 * 3600, False),
)
# Any of those names, wherever it appears in a command line: `$TMPDIR/x` expands to `T//x`,
# and a relative path names no directory at all.
LEFTOVER_MENTION = re.compile(r"(?<![A-Za-z0-9_.-])(tmp[a-z0-9_]{8}|tmp\.[A-Za-z0-9]{10}"
                              r"|pip-[a-z]+(?:-[a-z]+)*-[a-z0-9_]{8}|go-(?:build|link-)\d+"
                              r"|nimbus-[a-z0-9-]+-[A-Za-z0-9_]{6})(?![A-Za-z0-9_])")
# The per-user temp directory is the only root this rule may sweep: /tmp is shared with
# other users and root, whose processes neither lsof -u nor this user's ps can vouch for.
USER_TEMP_PREFIX = "/private/var/folders/"
# A fresh picture of what is open, at least this often while removing.
HOLDERS_MAX_AGE = 60
JOB_ID = re.compile(r"[0-9a-f]{8}$")
JOB_TERMINAL_STATES = ("done", "stopped")
JOB_TMP_IDLE_SECONDS = 72 * 3600
# The browser itself, never a Helper: helper paths run from "Google Chrome Helper.app".
CHROME_BINARY = re.compile(r"/\S.*/Google Chrome\.app/Contents/MacOS/Google Chrome(?= --)")


def temp_root():
    """This user's own temp directory, whatever TMPDIR says: launchd jobs may have none."""
    try:
        path = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True,
                              text=True, timeout=10, check=True).stdout.strip()
        if path:
            return Path(path).resolve()
    except (OSError, subprocess.SubprocessError):
        pass
    return Path(tempfile.gettempdir()).resolve()


def processes(env=False):
    """Yield (pid, ppid, elapsed_seconds, command) for every process; None when ps fails.
    With env, this user's processes' environments follow their command lines (ps -E), so a
    `PYTHONPATH=$TMPDIR/tmp…` names its directory too."""
    try:
        out = subprocess.run(["ps", "-axww" + ("E" if env else ""), "-o", "pid=,ppid=,etime=,command="],
                             capture_output=True,
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


def leftover_rule(name):
    """(idle seconds, directories only) for a tool temp name, or None for any other name."""
    return next(((idle, dirs) for pattern, idle, dirs in LEFTOVERS if pattern.fullmatch(name)), None)


def newest_change(path):
    """The newest mtime of path and everything under it, links not followed; None when
    any part cannot be read or lies on another filesystem - a share mounted on a temp
    directory is not the temp directory's to delete."""
    try:
        top_stat = path.lstat()
        newest, device = top_stat.st_mtime, top_stat.st_dev
        if path.is_dir() and not path.is_symlink():
            if os.path.ismount(path):
                return None
            for top, dirs, files in os.walk(path, onerror=_raise):
                for name in dirs + files:
                    st = os.lstat(os.path.join(top, name))
                    if st.st_dev != device:
                        return None
                    newest = max(newest, st.st_mtime)
    except OSError:
        return None
    return newest


def _raise(error):
    raise error


def holders(root, rows):
    """Names directly under root that an open file, a cwd or a command line reaches;
    None when lsof cannot answer. One lsof for all of this user's processes, not one per
    item: there were 442,337 items."""
    try:
        probe = subprocess.run(["lsof", "-n", "-F0n", "-u", str(os.getuid())],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=120, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    # A partial answer is no answer: a process lsof could not read is one it cannot vouch for.
    if probe.returncode not in (0, 1) or probe.stderr or not probe.stdout:
        return None
    names = set()
    prefixes = {os.fsencode(str(root)) + b"/"}
    if str(root).startswith("/private/"):
        prefixes.add(os.fsencode(str(root)[len("/private"):]) + b"/")
    for field in probe.stdout.split(b"\0"):
        field = field.lstrip(b"\n")
        for prefix in prefixes:
            if field.startswith(b"n" + prefix):
                names.add(os.fsdecode(field[len(prefix) + 1:].split(b"/", 1)[0]))
    for row in rows:
        names.update(LEFTOVER_MENTION.findall(row[3]))
    return names


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


def finished_job(job, now):
    """True only when state.json proves the job ended JOB_TMP_IDLE_SECONDS ago."""
    state_file = job / "state.json"
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
        if not isinstance(state, dict) or state.get("state") not in JOB_TERMINAL_STATES:
            return False
        ended = state.get("lastTerminalAt") or state.get("updatedAt")
        ended = datetime.fromisoformat(ended.replace("Z", "+00:00")).timestamp()
        return min(now - ended, now - state_file.stat().st_mtime) >= JOB_TMP_IDLE_SECONDS
    except (OSError, ValueError, AttributeError, TypeError):
        return False


def reap(root, logs_dir, clean=False, idle_seconds=3600, now=None, send=os.kill, jobs_dir=None):
    """Return counts {kind: (candidates, acted)}; prints one line per item."""
    now = time.time() if now is None else now
    rows = processes()
    if rows is None:
        raise RuntimeError("ps failed; kept everything")
    counts = {"chrome": [0, 0], "profile": [0, 0], "wrangler": [0, 0], "build": [0, 0],
              "jobvenv": [0, 0], "leftover": [0, 0]}

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

    held_names, held_at = None, 0
    sweep = root.is_dir() and str(root).startswith(USER_TEMP_PREFIX)
    for path in sorted(root.iterdir()) if sweep else []:
        try:
            rule = leftover_rule(path.name)
            # A build copy has its own rule above.
            if rule is None or BUILD_COPY.fullmatch(path.name) or path.is_symlink():
                continue
            limit, dirs_only = rule
            if dirs_only and not path.is_dir():
                continue
            # The entry's own time first: most are recent, and a deep walk costs.
            if now - path.lstat().st_mtime < limit:
                continue
            newest = newest_change(path)
            if newest is None or now - newest < limit:
                continue
            if held_names is None or time.time() - held_at > HOLDERS_MAX_AGE:
                rows_now = processes(env=True)
                held_names = None if rows_now is None else holders(root, rows_now)
                held_at = time.time()
                if held_names is None:
                    print("KEEP leftover (lsof could not answer; kept them all)")
                    break
            if path.name in held_names:
                continue
            counts["leftover"][0] += 1
            if clean:
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
                counts["leftover"][1] += 1
            print(f"{'REMOVED' if clean else 'CANDIDATE'} leftover {path.name}")
        except OSError as error:
            print(f"KEEP leftover {path.name} ({error.strerror or error})")

    jobs = jobs_dir.resolve() if jobs_dir is not None and jobs_dir.is_dir() else None
    for job in sorted(jobs.iterdir()) if jobs is not None else []:
        tmp = job / "tmp"
        try:
            if not JOB_ID.fullmatch(job.name) or job.is_symlink() or tmp.is_symlink() or not tmp.is_dir():
                continue
            if not finished_job(job, now):
                continue
            for venv in sorted(tmp.iterdir()):
                if venv.is_symlink() or not (venv / "pyvenv.cfg").is_file():
                    continue
                if in_use(venv):
                    continue
                counts["jobvenv"][0] += 1
                if clean:
                    # A resume between the scan and here would be seen now.
                    if not finished_job(job, time.time()) or in_use(venv):
                        print(f"KEEP jobvenv {job.name}/{venv.name} (changed)")
                        continue
                    shutil.rmtree(venv)
                    counts["jobvenv"][1] += 1
                print(f"{'REMOVED' if clean else 'CANDIDATE'} jobvenv {job.name}/{venv.name}")
        except OSError as error:
            print(f"KEEP jobvenv {job.name} ({error.strerror or error})")
    return counts


def in_use(path):
    """A process names the path on its command line, or lsof finds a holder; True when unsure."""
    rows = processes()
    return rows is None or any(str(path) in r[3] for r in rows) or held(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check", "clean"))
    parser.add_argument("--idle-minutes", type=int, default=60)
    args = parser.parse_args()
    if args.idle_minutes < 30:
        raise ValueError("idle limit must be at least 30 minutes")
    counts = reap(temp_root(), Path.home() / "Library/Preferences/.wrangler/logs",
                  clean=args.mode == "clean", idle_seconds=args.idle_minutes * 60,
                  jobs_dir=Path.home() / ".claude/jobs")
    print("host temp: " + " ".join(f"{k}={v[1]}/{v[0]}" for k, v in counts.items()))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(f"host temp: SKIP {error}", file=sys.stderr)
        sys.exit(1)
