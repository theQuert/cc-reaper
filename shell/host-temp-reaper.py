#!/usr/bin/env python3
"""Reclaim what headless-Chrome scripts, wrangler, failed test builds and finished
background Claude jobs leave in this user's temp space.

Eight kinds, each proved abandoned before it is touched:

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
  on 2026-10-05, 10.3 GB of it untouched for a day. A day for the build tools and,
  since 2026-10-29, for the generic `tmp` names too: 115k test sandboxes 1-3 days old held
  most of $TMPDIR, and the holder check (open files, cwd, command lines) guards a live one.

- any other `tmp[A-Za-z0-9_]{8}` or `tmp.[A-Za-z0-9]{10}` directory directly under the temp
  directory (`TMPDIR_NAME`, stima-api#7106): the shapes the leftover rule leaves alone because
  they look like a person's name (no digit), which on 2026-11-04 were 9,886 Python sandboxes
  holding fake HOMEs (`tmp_sriaqhi/.claude`, `.local`, `Library`) and 45 lower-case `tmp.`
  names, none removed by anything. Nothing under it changed for TMPDIR_IDLE_SECONDS (48 h),
  no open file, cwd or command line of this user's processes reaches it, and `lsof +D`, asked
  for each one just before it goes, finds no holder (an lsof that fails or writes anything to
  stderr is a holder). One lsof +D is ~0.25 s, so a run spends at most `--tmpdir-budget-seconds`
  on them and leaves the rest for the next; each removal and the run's total are logged with
  their bytes.

- any other prefix-named mkdtemp directory directly under the temp directory (`aged_prefix`,
  stima-api#7106): `<prefix><-, . or _><tail>`, the tail being 6 of [A-Za-z0-9] (Node `mkdtemp`,
  `mktemp XXXXXX`) or 8 of [a-z0-9_] (Python `mkdtemp`), or a bare `.tmp` plus a 6. On 2026-11-20 the
  temp directory held 65,848 entries, 63,929 older than 3 days and 57,092 older than 7 days, and the
  new leaks had stopped: what was left were tests' own names (`security-review-gate-z94a16f_` 14,175,
  `.tmpHXQE3i` 7,820, `restart-mbpJmx` 7,072, `neo-rot-…`, `stale-claim-release-…`, `stable-version-…`
  and a long tail) that no rule above names; the file's history adds one name at a time, this takes the
  class. A shape alone proves nothing about a person's directory, so a name is a candidate only when
  all of these hold: the tail looks random (a digit, or for 6 characters two upper-case letters or one
  not in first position; never digits only; 8 lower-case characters need a digit and a non-digit); it
  is not a reverse-DNS name (`com.`, `org.`, `net.`, `io.`, `dev.`, `app.` + a label + `.`); at least
  AGED_MIN_SIBLINGS entries of the same pass have the same prefix, which is what a leak has and a
  user's directory does not (on 2026-11-20 the leaks were a few dozen prefixes with hundreds to 10,000
  siblings each, everything else 322 names). A tail that does not look random is no proof against a
  leak either: one Python name in twelve has no digit, and on 2026-11-21 a pass that ended
  `not reached=0` left 2,000 such directories idle past the 7 days (`security-review-gate-srpllrrv`). Such a name
  is a candidate when AGED_MIN_SIBLINGS entries share its prefix and have such a tail of the same length
  themselves, so a `my-Folder` among a leak's `my-Ab12Cd` still has no company; a tail of digits only
  never is. The edge this leaves: under a prefix that has such a crowd, a directory someone named with a
  word of that length (`restart-backup` beside twenty `restart-wycuml`) is a candidate too, and goes once
  the proof below holds for it; a word of another length (`restart-fixtures`) is not. An
  earlier kind does not own it; and, as the proof,
  nothing under it changed (mtime or ctime, which `tar -x`, `cp -Rp` and `mv` cannot carry in) for
  AGED_IDLE_SECONDS (7 days), no socket is inside it (lsof +D cannot see a listening Unix socket), and
  the same holder checks as `tmpdir`, `lsof +D` just before each removal included. It shares
  `--tmpdir-budget-seconds` with `tmpdir` (that kind first), oldest first, and what the budget does not
  reach is left for the next run and logged as `not reached`.

Every probe that fails or cannot decide keeps the item. Chrome is sent SIGTERM only, so
it shuts down on its own terms. Tests drive the seams (`processes`, `listening_ports`,
`has_client`, `held`) with fixtures; no CLI option names an arbitrary root.
"""

import argparse
from collections import Counter
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time


PROFILE_NAME = re.compile(r"cdp-[A-Za-z0-9]{6}$")
WRANGLER_LOG = re.compile(r"wrangler-[0-9_-]+\.log$")
BUILD_COPY = re.compile(r"nimbus-articles-build-[A-Za-z0-9]{6}$")
BUILD_COPY_IDLE_SECONDS = 24 * 3600
# (name, idle seconds, directories only): a tool's own temp name, and how long it must be
# untouched. The generic names are directories only and must look random (a digit, an upper-case
# letter, or for Python exactly 8 of [a-z0-9]), so a person's `tmp_scratch` or a file
# another program was handed by name is not one.
LEFTOVERS = (
    # Python mkdtemp (tmp + 8 of [a-z0-9_]) and mktemp(1) (tmp. + 10 mixed case). A digit, or for Python no underscore,
    # or for mktemp an upper-case letter, separates them from a person's `tmp_scratch`. 2026-10-29: ~46k such dirs older
    # than 72 h had no digit and were never reaped, and the bulk of $TMPDIR's 23 GiB was 1-3 days old test sandboxes.
    (re.compile(r"tmp(?=[a-z0-9_]*[0-9]|[a-z0-9]{8}$)[a-z0-9_]{8}"), 24 * 3600, True),
    (re.compile(r"tmp\.(?=[A-Za-z0-9]*[0-9A-Z])[A-Za-z0-9]{10}"), 24 * 3600, True),
    (re.compile(r"pip-[a-z]+(-[a-z]+)*-[a-z0-9_]{8}"), 24 * 3600, False),
    # go removes its own WORK dir unless the build is killed (a lease or step timeout under load); nothing reads one
    # after its go process exits, so 2 h untouched and unheld is dead. 2026-10-29: 20 such dirs held ~2.5 GiB at 25 GiB free.
    (re.compile(r"go-(build|link-)\d+"), 2 * 3600, False),
    (re.compile(r"nimbus-(acceptance|articles|env|m2|m2-build|m3r|m8|manifest|static)-[A-Za-z0-9_]{6}"),
     24 * 3600, False),
    # Node mkdtempSync leftovers of this repo's tests (route-origins in cloudflare/apertis-router, the rest from
    # node suites): 26,629 hold- and 18,417 preview-unpack- dirs in $TMPDIR on 2026-10-29, never removed.
    (re.compile(r"(hold|preview-unpack|edge-key|neo-rot|route-origins(-[a-z]+)?)-(?=[A-Za-z0-9]*[0-9A-Z])[A-Za-z0-9]{6}"), 24 * 3600, True),
)
# Any of those names, wherever it appears in a command line: `$TMPDIR/x` expands to `T//x`,
# and a relative path names no directory at all.
LEFTOVER_MENTION = re.compile(r"(?<![A-Za-z0-9_.-])(tmp[a-z0-9_]{8}|tmp\.[A-Za-z0-9]{10}"
                              r"|pip-[a-z]+(?:-[a-z]+)*-[a-z0-9_]{8}|go-(?:build|link-)\d+"
                              r"|nimbus-[a-z0-9-]+-[A-Za-z0-9_]{6}"
                              r"|(?:hold|preview-unpack|edge-key|neo-rot|route-origins(?:-[a-z]+)?)-[A-Za-z0-9]{6})"
                              r"(?![A-Za-z0-9_])")
# The per-user temp directory is the only root this rule may sweep: /tmp is shared with
# other users and root, whose processes neither lsof -u nor this user's ps can vouch for.
USER_TEMP_PREFIX = "/private/var/folders/"
TMPDIR_NAME = re.compile(r"tmp[A-Za-z0-9_]{8}|tmp\.[A-Za-z0-9]{10}")
TMPDIR_IDLE_SECONDS = 48 * 3600
# A directory named <prefix><-, . or _><random tail> by a test's mkdtemp. The prefix is free, which is the
# point: the names of tests are not a list anyone keeps. What makes it a leak and not a person's directory is
# the siblings: a producer leaves hundreds, a person's `my-folder` has none.
AGED_PREFIX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# Eight first: Python's `r_2chwxv` also reads as six characters after `_`, under the prefix `…-r` nothing shares.
AGED_TAIL = {8: re.compile(r"[a-z0-9_]{8}"), 6: re.compile(r"[A-Za-z0-9]{6}")}
BARE_TMP = re.compile(r"\.tmp[A-Za-z0-9]{6}")
REVERSE_DNS = re.compile(r"(com|org|net|io|dev|app)\.[A-Za-z0-9_-]+\.", re.IGNORECASE)
AGED_MIN_SIBLINGS = 20
AGED_IDLE_SECONDS = 7 * 24 * 3600
TMPDIR_BUDGET_SECONDS = 600
# A fresh picture of what is open, at least this often while removing.
HOLDERS_MAX_AGE = 60
JOB_ID = re.compile(r"[0-9a-f]{8}$")
JOB_TERMINAL_STATES = ("done", "stopped")
JOB_TMP_IDLE_SECONDS = 72 * 3600
# The browser itself, never a Helper: helper paths run from "Google Chrome Helper.app".
CHROME_BINARY = re.compile(r"/\S.*/Google Chrome\.app/Contents/MacOS/Google Chrome(?= --)")


# Processes this reaper never signals, nor any process descended from one: CC_NEVER_KILL_PIDS,
# separated by spaces or commas. Unset, the host's default list applies; empty protects no pid.
# The same rule, and the same default, as _cc_reaper_never_kill in the shell scripts.
NEVER_KILL_DEFAULT = "70987 4565"


def never_kill_pids():
    raw = os.environ.get("CC_NEVER_KILL_PIDS")
    raw = NEVER_KILL_DEFAULT if raw is None else raw
    return {int(t) for t in re.split(r"[^0-9]+", raw) if t}


def never_kill(pid, parents, keep=None):
    """True when pid, or one of its ancestors in parents ({pid: ppid}), is on the list. An
    empty table cannot prove the ancestry, so it protects: a skipped signal is retried next run."""
    keep = never_kill_pids() if keep is None else keep
    if not keep:
        return False
    if pid in keep or not parents:
        return True
    p = pid
    for _ in range(512):
        if p in keep:
            return True
        if p <= 1 or p not in parents:
            return False
        p = parents[p]
    return False


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


def random_tail(tail):
    """True when a 6 or 8 character tail looks like mkdtemp's and not like a word or a number."""
    if tail.isdigit():
        return False
    if len(tail) == 8:
        return any(c.isdigit() for c in tail)
    uppers = [i for i, c in enumerate(tail) if c.isupper()]
    return any(c.isdigit() for c in tail) or len(uppers) >= 2 or (len(uppers) == 1 and uppers[0] > 0)


def aged_prefix(name, plain=False):
    """The prefix of a name `<prefix><-, . or _><random tail>`, or None for any other name. With
    `plain`, of a name whose tail does not look random instead; digits only is neither."""
    if REVERSE_DNS.match(name):
        return None

    def fits(tail):
        return not tail.isdigit() and random_tail(tail) != plain

    if BARE_TMP.fullmatch(name):
        return ".tmp" if fits(name[4:]) else None
    for length, pattern in AGED_TAIL.items():
        cut = len(name) - length - 1
        if (cut >= 1 and name[cut] in "-._" and pattern.fullmatch(name[cut + 1:]) and fits(name[cut + 1:])
                and AGED_PREFIX.fullmatch(name[:cut])):
            return name[:cut]
    return None


def owned_earlier(name):
    """True for a name one of the kinds that run before `aged` takes (or leaves) by its own rule."""
    return (leftover_rule(name) is not None or TMPDIR_NAME.fullmatch(name) is not None
            or PROFILE_NAME.fullmatch(name) is not None or BUILD_COPY.fullmatch(name) is not None)


def aged_candidate_prefix(name):
    """What a name's siblings are counted under, or None: (prefix, 0) for a tail that looks random,
    (prefix, the tail's length with its separator) for one that does not. Two crowds, and the plain one
    is per length: a producer's tails are one length, a word beside them usually is not."""
    if owned_earlier(name):
        return None
    for plain in (False, True):
        prefix = aged_prefix(name, plain)
        if prefix is not None:
            return prefix, len(name) - len(prefix) if plain else 0
    return None


def newest_change(path, why=None):
    """The newest mtime or ctime of path and everything under it, links not followed (a tree
    unpacked with tar -x, cp -Rp or mv keeps its old mtimes, not its ctimes); None when any part
    cannot be read, lies on another filesystem - a share mounted on a temp directory is not the
    temp directory's to delete - or is a socket (a listening Unix socket is invisible to lsof +D;
    `why` then gets "socket")."""
    try:
        top_stat = os.lstat(path)
        if stat.S_ISSOCK(top_stat.st_mode):
            if why is not None:
                why.append("socket")
            return None
        newest, device = max(top_stat.st_mtime, top_stat.st_ctime), top_stat.st_dev
        if path.is_dir() and not path.is_symlink():
            if os.path.ismount(path):
                return None
            for top, dirs, files in os.walk(path, onerror=_raise):
                for name in dirs + files:
                    st = os.lstat(os.path.join(top, name))
                    if st.st_dev != device:
                        return None
                    if stat.S_ISSOCK(st.st_mode):
                        if why is not None:
                            why.append("socket")
                        return None
                    newest = max(newest, st.st_mtime, st.st_ctime)
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
        # `T//x/y` is `T/x/y`: the name under the root is read from the normalised path.
        if not field.startswith(b"n/"):
            continue
        path = os.path.normpath(field[1:])
        for prefix in prefixes:
            if path.startswith(prefix):
                names.add(os.fsdecode(path[len(prefix):].split(b"/", 1)[0]))
    for row in rows:
        names.update(LEFTOVER_MENTION.findall(row[3]))
    return names


def tree_bytes(path):
    """Bytes allocated under path, links not followed; what a removal frees, near enough."""
    total = 0
    for top, dirs, files in os.walk(path):
        for name in dirs + files:
            try:
                total += os.lstat(os.path.join(top, name)).st_blocks * 512
            except OSError:
                pass
    return total + path.lstat().st_blocks * 512


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


def reap(root, logs_dir, clean=False, idle_seconds=3600, now=None, send=os.kill, jobs_dir=None,
         tmpdir_budget=TMPDIR_BUDGET_SECONDS):
    """Return counts {kind: (candidates, acted)}; prints one line per item."""
    now = time.time() if now is None else now
    rows = processes()
    if rows is None:
        raise RuntimeError("ps failed; kept everything")
    counts = {"chrome": [0, 0], "profile": [0, 0], "wrangler": [0, 0], "build": [0, 0],
              "jobvenv": [0, 0], "leftover": [0, 0], "tmpdir": [0, 0], "aged": [0, 0]}

    for row in rows:
        if not orphan_chrome(row, root, idle_seconds):
            continue
        counts["chrome"][0] += 1
        if not clean:
            print(f"CANDIDATE chrome pid={row[0]}")
            continue
        # Recheck the same pid right before signalling: a reused pid fails closed.
        fresh = processes() or []
        again = [r for r in fresh if r[0] == row[0]]
        if not again or again[0][3] != row[3] or not orphan_chrome(again[0], root, idle_seconds):
            print(f"KEEP chrome pid={row[0]} (changed)")
            continue
        if never_kill(row[0], {r[0]: r[1] for r in fresh}):
            print(f"never-kill {row[0]}")
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

    held_names, held_at, rows_now = None, 0, None
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
            why = []
            newest = newest_change(path, why)
            if why:
                print(f"KEEP leftover {path.name} ({why[0]})")
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

    # The seventh and eighth kinds: TMPDIR_NAME directories the leftover rule does not take, then any
    # other mkdtemp-shaped name that has been untouched for AGED_IDLE_SECONDS. One budget for both.
    def oldest_first(entries):
        stamped = []
        for path in entries:
            try:
                stamped.append((path.lstat().st_mtime, path.name, path))
            except OSError:
                pass
        return [path for _, _, path in sorted(stamped)]

    deadline = time.monotonic() + tmpdir_budget
    entries = oldest_first(root.iterdir()) if sweep else []
    # What a leak has and a person's directory does not: siblings, counted over this pass's own listing.
    siblings = Counter(filter(None, (aged_candidate_prefix(path.name) for path in entries)))

    def aged_wanted(name):
        prefix = aged_candidate_prefix(name)
        return prefix is not None and siblings[prefix] >= AGED_MIN_SIBLINGS

    for kind, wanted, limit in (
            ("tmpdir", lambda name: TMPDIR_NAME.fullmatch(name) and leftover_rule(name) is None, TMPDIR_IDLE_SECONDS),
            ("aged", aged_wanted, AGED_IDLE_SECONDS)):
        freed, deferred, gave_up = 0, 0, False
        for path in entries:
            try:
                if not wanted(path.name):
                    continue
                if path.is_symlink() or not path.is_dir() or now - path.lstat().st_mtime < limit:
                    continue
                if time.monotonic() > deadline:
                    deferred += 1
                    continue
                why = []
                newest = newest_change(path, why)
                if why:
                    print(f"KEEP {kind} {path.name} ({why[0]})")
                if newest is None or now - newest < limit:
                    continue
                if held_names is None or rows_now is None or time.time() - held_at > HOLDERS_MAX_AGE:
                    rows_now = processes(env=True)
                    held_names = None if rows_now is None else holders(root, rows_now)
                    held_at = time.time()
                    if held_names is None:
                        print(f"KEEP {kind} (lsof could not answer; kept them all)")
                        gave_up = True
                        break
                if path.name in held_names or any(path.name in r[3] for r in rows_now) or held(path):
                    continue
                counts[kind][0] += 1
                size = tree_bytes(path)
                if clean:
                    shutil.rmtree(path)
                    counts[kind][1] += 1
                    freed += size
                print(f"{'REMOVED' if clean else 'CANDIDATE'} {kind} {path.name} bytes={size}")
            except OSError as error:
                print(f"KEEP {kind} {path.name} ({error.strerror or error})")
        print(f"{kind}: {counts[kind][1]} removed of {counts[kind][0]}, bytes={freed}, "
              f"not reached={deferred} (budget {tmpdir_budget}s)")
        if gave_up:
            if kind == "tmpdir":
                print("aged: skipped (no holder snapshot)")
            break

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
    parser.add_argument("--tmpdir-budget-seconds", type=int, default=TMPDIR_BUDGET_SECONDS)
    args = parser.parse_args()
    if args.idle_minutes < 30:
        raise ValueError("idle limit must be at least 30 minutes")
    counts = reap(temp_root(), Path.home() / "Library/Preferences/.wrangler/logs",
                  clean=args.mode == "clean", idle_seconds=args.idle_minutes * 60,
                  jobs_dir=Path.home() / ".claude/jobs", tmpdir_budget=args.tmpdir_budget_seconds)
    print("host temp: " + " ".join(f"{k}={v[1]}/{v[0]}" for k, v in counts.items()))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(f"host temp: SKIP {error}", file=sys.stderr)
        sys.exit(1)
