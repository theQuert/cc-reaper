#!/usr/bin/env python3
"""Stop dev servers that serve nothing: a launcher left behind in a task worktree whose
process tree does not listen on the port its own command line asked for.

On 2026-10-04 swap was 22.5 of 23.5 GB and the harness killed a session's background
command for low memory. Five `npm run preview --port 8811` trees for one docs worktree,
started 09-29 and 09-30, held about 2.7 GB between them, and none of them, nor anything
else on the host, listened on 8811: each lost the bind or its server had exited, leaving
wrangler and workerd running behind a port nobody could reach.

A launcher tree is stopped only when every one of these holds:

- its root runs a known dev-server launcher (`npm run dev|preview|start`, `wrangler dev`,
  `next dev|start`, `vite`) and names its port on the command line - no port named, no
  verdict - or runs `react-scripts start`, which takes its port from the environment;
- the root was reparented to launchd (ppid 1), so no session's shell is waiting on it, and
  no `claude` or `codex` process is in the tree or shares a process group with one in it;
- the root's working directory is inside a linked git worktree, never a primary checkout;
- it serves nobody, in one of two ways:
  - no process in the tree listens on its port, nor on one of the 20 above it where vite
    and astro move when theirs is taken (the inspector ports a server also opens do not
    count) - it can serve nobody, so it goes at once;
  - it runs a hot-reload dev server (`react-scripts start`, `next dev`, `vite` other than
    `vite preview|build`, `webpack serve`, judged from the commands its tree actually runs,
    not the npm script's name) and listens, but nothing has been connected to that port
    (for `react-scripts start`, which names no port, to any port its tree listens on) at
    any run for IDLE_HOURS, as recorded in the state directory, nor at the recheck. Only a
    hot-reload server can be judged this way: an open tab keeps its socket connected,
    while `next start`, `vite preview` or `wrangler dev` hold no connection between
    requests, so a listening one of those is always taken as serving. A closed laptop
    drops even the hot-reload socket within seconds, so one empty moment proves nothing,
    and runs more than MAX_SAMPLE_GAP apart start the count over. Two CRA servers sat 2
    days like that on 2026-10-05, holding 4.5 GB while the compressor churned 850 MB/s.
    While the kernel's memory pressure level is 2 or more - now, or in any sample of the
    host's pressure log within the last PRESSURE_LOOKBACK - the window is
    PRESSURE_IDLE_HOURS instead. The level flips between 1 and 2 by the minute under load,
    so one reading at run time took the 12h window at 13:47 on 2026-10-05 while the log
    showed level 2 that hour;
- nothing publishes it: no other listening process names its worktree on its command line
  (a review front such as ~/stima-review/tailnet_review.mjs <worktree> <port>), and no
  `tailscale serve` handler proxies to a port the tree listens on;
- the root is at least the minimum age, so a server still starting is not judged;
- the worktree janitor's `--claims <worktree>` names no live session cwd and no live
  session tool call for that worktree (this session's own mentions excepted, as the
  janitor does).

Nothing is judged by file times: a page being viewed writes no file, and a stack with
its own ticker writes one every minute. A tree something is connected to, or that is
published, is listed as SERVING for a person to decide on, never stopped. Every probe that fails or cannot decide
keeps the tree.

An esbuild `--service` (the stdio build service wrangler and vite spawn) whose parent died
is stopped too: run from a `node_modules` esbuild binary, reparented to launchd, no child,
no socket but its dead stdio pair, the minimum age, no agent or launcher left in its process
group, cwd in a linked worktree with no live claim. Twelve sat 5-7 days on 2026-10-06 while
swap was 13.6 of 14.3 GB, each holding memory for a dev server that no longer existed.

Stopping is SIGTERM to every process in the tree, then SIGKILL to those
still alive after the grace period; each pid is signalled only while its start time still
matches the scan, so a reused pid is never hit.
"""

import argparse
import calendar
import json
import os
import shutil
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


AGENT = re.compile(r"(?:^|/)(?:claude|codex)(?:\s|$)")
# How far a dev server moves when its port is taken: vite and astro try the next ports.
PORT_SHIFT = 20
# `react-scripts start` reads PORT from the environment; its port is whatever it listens on.
ANY_PORT = -1
# How long a listening tree must have had no connection at every run before it is stopped,
# and the shorter window while memory is short.
IDLE_HOURS = 12
PRESSURE_IDLE_HOURS = 3
# Runs further apart than this cannot vouch for the time between them.
MAX_SAMPLE_GAP = 2 * 3600
# A host's 5-minute pressure samples ("<UTC>Z ... mp=<level> ..."). The sampler is the
# host's own, so the path is set where the host is configured (disk-janitor.conf exports
# it); unset, only the live level is read.
PRESSURE_LOG = os.environ.get("CC_DEV_SERVER_PRESSURE_LOG", "")
PRESSURE_LOOKBACK = 3600
STATE_DIR = Path.home() / ".cc-reaper" / "state" / "dev-server-idle"
ESBUILD = re.compile(r"/node_modules/(?:\.bin|(?:.+/)?@esbuild/[^/]+/bin)/esbuild$")


def launcher(command):
    """The port a dev-server launcher names (0 for none); None when command is not one.

    Judged from argv[0], or the script after `node`, never from anywhere in the line: a
    tmux or screen server keeps the argv of the command that started it, and an agent
    keeps its prompt, so `npm run dev --port 5173` can appear in either.
    """
    args = command.split()
    if args and os.path.basename(args[0]) == "node":
        args = args[1:]
    if not args:
        return None
    tool = re.sub(r"\.(?:c|m)?js$", "", os.path.basename(args[0]))
    sub = args[1:]
    if tool == "react-scripts":
        return ANY_PORT if sub[:1] == ["start"] else None
    if not ((tool == "npm" and sub[:1] == ["run"] and sub[1:2] in (["dev"], ["preview"], ["start"]))
            or (tool == "wrangler" and (sub[:1] == ["dev"] or sub[:2] == ["pages", "dev"]))
            or (tool == "next" and sub[:1] in (["dev"], ["start"]))
            or tool == "vite"):
        return None
    for i, arg in enumerate(args):
        value = None
        if arg in ("--port", "-p") and i + 1 < len(args):
            value = args[i + 1]
        elif arg.startswith("--port="):
            value = arg.split("=", 1)[1]
        if value is not None:
            return int(value) if value.isdigit() and 0 < int(value) < 65536 else 0
    return 0


def esbuild_service(command):
    """Whether argv[0] is a node_modules esbuild binary run with --service."""
    args = command.split()
    return bool(args and ESBUILD.search(args[0])
                and any(a == "--service" or a.startswith("--service=") for a in args[1:]))


def processes():
    """{pid: (ppid, pgid, rss_kb, lstart, command)}; None when ps fails."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,rss=,lstart=,command="],
                             capture_output=True, text=True, timeout=30, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    rows = {}
    for line in out.splitlines():
        parts = line.split(None, 9)
        if len(parts) == 10 and all(p.isdigit() for p in parts[:4]):
            rows[int(parts[0])] = (int(parts[1]), int(parts[2]), int(parts[3]),
                                   " ".join(parts[4:9]), parts[9])
    return rows


def started(lstart):
    try:
        return time.mktime(time.strptime(lstart, "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return None


def listening():
    """{pid: {port}} for every TCP listener; None when lsof cannot answer."""
    try:
        probe = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                               capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if probe.returncode not in (0, 1):
        return None
    ports, pid = {}, None
    for field in probe.stdout.split():
        if field.startswith("p") and field[1:].isdigit():
            pid = int(field[1:])
        elif field.startswith("n") and pid is not None and ":" in field:
            tail = field.rsplit(":", 1)[1]
            if tail.isdigit():
                ports.setdefault(pid, set()).add(int(tail))
    # A host always has listeners; an empty answer is a failed probe, not a quiet machine.
    return ports or None


def connected():
    """Every local or remote port of an established TCP connection; None when lsof cannot
    answer. Both ends count, so a browser on this host connected to a server counts too."""
    try:
        probe = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fn"],
                               capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if probe.returncode not in (0, 1):
        return None
    found = set()
    for field in probe.stdout.split():
        if field.startswith("n") and "->" in field:
            for end in field[1:].split("->"):
                tail = end.rsplit(":", 1)[-1]
                if tail.isdigit():
                    found.add(int(tail))
    # This host always has connections (every session talks to its API); none is a failed probe.
    return found or None


def served_ports():
    """Local ports a `tailscale serve` handler forwards to; empty without tailscale, None
    when tailscale is there and cannot answer."""
    # launchd's PATH has no Homebrew; look where it is installed before calling it absent.
    binary = shutil.which("tailscale") or next(
        (p for p in ("/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                     "/Applications/Tailscale.app/Contents/MacOS/Tailscale") if os.access(p, os.X_OK)), None)
    if binary is None:
        return set()
    try:
        probe = subprocess.run([binary, "serve", "status", "--json"], capture_output=True,
                               text=True, timeout=30, check=False)
        config = json.loads(probe.stdout) if probe.returncode == 0 and probe.stdout.strip() else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    found = set()

    def walk(node):
        if isinstance(node, dict):
            for value in node.values():
                walk(value)
        elif isinstance(node, str):
            match = re.search(r":(\d{2,5})(?:/|$)", node)
            if match:
                found.add(int(match.group(1)))
    walk(config)   # values only: TCPForward targets count, listen-port keys do not
    return found


def published(rows, ports, members, worktree):
    """Why the tree is published to someone, or None. Anything unreadable is a reason."""
    # An argument that IS the worktree, not argv[0] and not a path inside it: the local
    # stack's own API runs from a binary in the worktree, and a sibling dev server's child
    # runs a script under it (node <wt>/node_modules/...), and neither publishes anything.
    for pid, held in ports.items():
        if not held or pid in members or pid not in rows:
            continue
        if any(arg.rstrip("/") == str(worktree) for arg in rows[pid][4].split()[1:]):
            return f"published by listening pid {pid}, which names its worktree"
    forwarded = served_ports()
    if forwarded is None:
        return "tailscale serve unreadable"
    hit = sorted(forwarded & {p for pid in members for p in ports.get(pid, ())})
    return f"published by tailscale serve on {hit[0]}" if hit else None


def idle_for(state_dir, root, begun, now):
    """Seconds this tree has been seen unused at every run without a gap; records it first
    when new. The marker's mtime is when the unbroken run of samples began, its content the
    last sample; a gap over MAX_SAMPLE_GAP (a skipped or overlong run) starts it over."""
    marker = state_dir / f"{root}-{int(begun)}"
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        try:
            last = float(marker.read_text().strip()) if marker.exists() else None
        except ValueError:   # unreadable or not a number: start over
            last = None
        if last is None or now - last > MAX_SAMPLE_GAP:
            marker.write_text(f"{now}\n")
            os.utime(marker, (now, now))
            return 0
        since = marker.stat().st_mtime
        marker.write_text(f"{now}\n")
        os.utime(marker, (since, since))   # the write moved mtime; the start must not move
        return now - since
    except OSError:
        return 0


def forget_idle(state_dir, root, begun):
    try:
        (state_dir / f"{root}-{int(begun)}").unlink()
    except OSError:
        pass


def prune_idle(state_dir, rows):
    """Drop markers of trees that no longer run, so a reused pid starts from zero."""
    live = {f"{pid}-{int(started(row[3]) or 0)}" for pid, row in rows.items()}
    try:
        for marker in state_dir.iterdir():
            if marker.name not in live:
                marker.unlink()
    except OSError:
        pass


def pressure(log=None, now=None):
    """(True, why) while the kernel's memory pressure level is 2 (warn) or more, now or in
    the pressure log's samples of the last PRESSURE_LOOKBACK. Not swap free: macOS grows
    swap a file at a time, so free swap sits near one file's size whenever swap is in use
    at all. A probe or log that fails says not short, the longer window."""
    try:
        level = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                               capture_output=True, text=True, timeout=10, check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        level = ""
    if level.isdigit() and int(level) >= 2:
        return True, f"memory pressure level {level}"
    log = PRESSURE_LOG if log is None else log
    if not log:
        return False, ""
    now = time.time() if now is None else now
    try:
        with open(log, "rb") as f:
            f.seek(max(0, os.fstat(f.fileno()).st_size - 65536))
            lines = f.read().decode(errors="replace").splitlines()
    except OSError:
        return False, ""
    for line in reversed(lines):
        sample = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) .*\bmp=(\d+)", line)
        if not sample:
            continue
        try:
            at = calendar.timegm(time.strptime(sample.group(1), "%Y-%m-%dT%H:%M:%SZ"))
        except ValueError:
            continue
        if int(sample.group(2)) >= 2 and 0 <= now - at <= PRESSURE_LOOKBACK:
            return True, f"memory pressure level {sample.group(2)} at {sample.group(1)}"
    return False, ""


def hot_reload(rows, members, ports=None, used_on=None):
    """Whether the process serving `used_on` runs a dev server whose open tab holds a socket
    to it. Judged from that listener and its parent only, not the whole tree: a tree can
    mix a vite and a wrangler (one `concurrently` even names both on its own command line),
    and the port being measured must belong to the hot-reload one. Without ports, any
    member counts, for callers that only ask whether the tree runs one at all."""
    if ports is not None and used_on:
        owners = {pid for pid in members if ports.get(pid, set()) & set(used_on)}
        members = owners | {rows[pid][0] for pid in owners if rows[pid][0] in rows}
    for pid in members:
        args = rows[pid][4].split()
        names = [re.sub(r"\.(?:c|m)?js$", "", os.path.basename(a)) for a in args]
        for i, name in enumerate(names):
            following = args[i + 1] if i + 1 < len(args) else ""
            if (name == "react-scripts" and following == "start") or args[i].endswith("react-scripts/scripts/start.js"):
                return True
            if name == "next" and following == "dev":
                return True
            # Any later word, not the next one: options can come first (`--mode x preview`),
            # and a stray match only means the server is taken as serving.
            if name == "vite" and not {"preview", "build", "optimize"} & set(args[i + 1:]):
                return True
            if (name == "webpack" and following == "serve") or name == "webpack-dev-server":
                return True
    return False


def cwd(pid):
    """The process's working directory; None when lsof cannot say."""
    try:
        probe = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                               capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    names = [line[1:] for line in probe.stdout.splitlines() if line.startswith("n")]
    return Path(names[0]) if probe.returncode == 0 and len(names) == 1 else None


def sockets(pid):
    """Whether the process holds an internet socket, or a unix socket that listens or has a
    peer; None when lsof cannot say. A unix socket whose peer is gone (`->(none)`, the stdio
    pair of a service whose parent died) is neither."""
    try:
        probe = subprocess.run(["lsof", "-nP", "-p", str(pid), "-Ftn"],
                               capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    lines = probe.stdout.splitlines()
    if probe.returncode != 0 or lines[:1] != [f"p{pid}"]:
        return None
    for kind, name in zip(lines, lines[1:]):
        if kind in ("tIPv4", "tIPv6") or (kind == "tunix" and name != "n->(none)"):
            return True
    return False


def linked_worktree(path):
    """The top of the linked worktree holding path; None for a primary checkout or no repo."""
    def git(*args):
        return subprocess.run(["git", "-C", str(path), *args], capture_output=True,
                              text=True, timeout=30, check=True).stdout.strip()
    try:
        # Absolute, because a relative --git-common-dir is relative to the -C directory, not
        # the top: from a primary checkout's subdirectory it read as a linked worktree.
        top, gd, common = git("rev-parse", "--show-toplevel", "--absolute-git-dir",
                              "--path-format=absolute", "--git-common-dir").splitlines()
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return Path(top) if Path(gd).resolve() != Path(common).resolve() else None


def claimed(worktree, janitor, timeout=900):
    """True when a live session claims the worktree, or the janitor cannot say."""
    try:
        # Minutes, not seconds: it reads every live and recent transcript, and took 5m11s
        # under load on 2026-10-05. A timeout is a claim, so too short keeps everything.
        probe = subprocess.run([str(janitor), "--claims", str(worktree)], capture_output=True,
                               text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return True
    if probe.returncode != 0 or not probe.stdout.startswith("CLAIMS"):
        return True
    own = os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("CODEX_THREAD_ID")
    for line in probe.stdout.splitlines():
        kind, _, rest = line.partition("\t")
        if kind not in ("LIVE", "LIVE_TOOL"):
            continue
        if own and f"id={own}\t" in rest + "\t":
            continue
        return True
    return False


def tree(rows, root):
    children = {}
    for pid, row in rows.items():
        children.setdefault(row[0], []).append(pid)
    found, todo = [], [root]
    while todo:
        pid = todo.pop()
        found.append(pid)
        todo.extend(children.get(pid, []))
    return found


def serving(ports, members, port, hot=True, rows=None):
    """(state, why). unserved: it does not listen on its port or the 20 above it, where vite
    and astro move. serving: something is connected to the port it serves on (with ANY_PORT,
    to any port it listens on), connections are unreadable, or it listens without a
    hot-reload socket to judge use by. idle: a hot-reload server listens, unused."""
    listens = {p for pid in members for p in ports.get(pid, ())}
    if port == ANY_PORT:
        used_on = listens
        if not used_on:
            return "idle", "listens on nothing"
    elif port in listens:
        used_on = {port}
    else:
        moved = sorted(p for p in listens if port < p <= port + PORT_SHIFT)
        if not moved:
            return "unserved", f"does not listen on its port {port}"
        used_on = {moved[0]}
    if rows is not None:
        hot = hot_reload(rows, members, ports, used_on)
    if not hot and port != ANY_PORT:
        return "serving", f"listens on {min(used_on)}; no hot-reload socket to judge use by"
    clients = connected()
    if clients is None:
        return "serving", "kept: connections unreadable"
    used = sorted(used_on & clients)
    if used:
        return "serving", f"has connections on {used[0]}"
    return "idle", f"listens on {min(used_on)} with no connection"


def judge(rows, ports, root, min_age, now, janitor, claims=None, claim_timeout=900,
          state_dir=STATE_DIR, idle_hours=IDLE_HOURS):
    """(verdict, reason, worktree, members, port, state); verdict is reap, serving or keep,
    state is serving()'s, so the recheck can tell what changed."""
    ppid, _, _, lstart, command = rows[root]
    port = launcher(command)
    if not port:
        return "keep", "no port on the command line", None, [], port, None
    begun = started(lstart)
    if begun is None or now - begun < min_age:
        return "keep", "younger than the minimum age", None, [], port, None
    members = tree(rows, root)
    state, why = serving(ports, members, port, rows=rows)
    if state == "serving":
        forget_idle(state_dir, root, begun)
        return "serving", why, None, members, port, state
    groups = {rows[pid][1] for pid in members}
    if any(AGENT.search(row[4]) and (pid in members or row[1] in groups)
           for pid, row in rows.items()):
        return "keep", "an agent process is in the tree or its process group", None, [], port, state
    where = cwd(root)
    worktree = linked_worktree(where) if where else None
    if worktree is None:
        return "keep", "not in a linked worktree", None, [], port, state
    # One janitor --claims call per worktree per run: it reads every live transcript, and
    # duplicates share their worktree.
    claims = {} if claims is None else claims
    if worktree not in claims:
        claims[worktree] = claimed(worktree, janitor, claim_timeout)
    if claims[worktree]:
        return "keep", "a live session claims the worktree, or the claim check failed", worktree, [], port, state
    published_by = published(rows, ports, members, worktree)
    if published_by:
        # Unused starts counting again when the publisher goes, not from before it came.
        forget_idle(state_dir, root, begun)
        return "serving", published_by, worktree, members, port, "serving"
    if state == "idle":
        idle = idle_for(state_dir, root, begun, now)
        if idle < idle_hours * 3600:
            return "keep", f"{why}; unused for {idle / 3600:.1f}h of the {idle_hours}h it must be", worktree, [], port, state
        return "reap", f"{why} for {idle / 3600:.1f}h", worktree, members, port, state
    return "reap", why, worktree, members, port, state


def orphan(rows, ports, pid, min_age, now, janitor, claims, claim_timeout=900):
    """(why it stays, worktree) for an esbuild service reparented to launchd (the caller
    checks; a process cannot leave launchd); why is None when it is abandoned."""
    _, pgid, _, lstart, _ = rows[pid]
    begun = started(lstart)
    if begun is None or now - begun < min_age:
        return "younger than the minimum age", None
    if any(row[0] == pid for row in rows.values()):
        return "it has a child", None
    if any(other != pid and row[1] == pgid and (AGENT.search(row[4]) or launcher(row[4]) is not None)
           for other, row in rows.items()):
        return "an agent or launcher shares its process group", None
    if ports.get(pid) or sockets(pid) is not False:
        return "it has a socket, or the socket probe failed", None
    where = cwd(pid)
    worktree = linked_worktree(where) if where else None
    if worktree is None:
        return "not in a linked worktree", None
    if worktree not in claims:
        claims[worktree] = claimed(worktree, janitor, claim_timeout)
    if claims[worktree]:
        return "a live session claims the worktree, or the claim check failed", worktree
    return None, worktree


def stop(members, snapshot, grace, send=os.kill, sleep=time.sleep):
    """TERM then KILL members whose start time still matches.

    Returns (signalled, denied): a member this user may not signal is left alone and named.
    """
    denied = set()

    def alive_same():
        now = processes() or {}
        return [p for p in members if p in now and now[p][3] == snapshot[p] and p not in denied]

    def signal_all(pids, sig):
        done = []
        for pid in pids:
            try:
                send(pid, sig)
                done.append(pid)
            except ProcessLookupError:
                pass
            except PermissionError:
                denied.add(pid)
        return done
    targets = signal_all(alive_same(), signal.SIGTERM)
    sleep(grace)
    signal_all(alive_same(), signal.SIGKILL)
    return targets, sorted(denied)


def reap(apply=False, min_age=6 * 3600, grace=10, now=None, janitor=None, send=os.kill,
         sleep=time.sleep, claim_timeout=900, state_dir=STATE_DIR, idle_hours=IDLE_HOURS,
         pressure_hours=PRESSURE_IDLE_HOURS):
    """Print one line per launcher root and a summary; return (reaped, candidates)."""
    now = time.time() if now is None else now
    short, short_why = pressure()
    window = min(pressure_hours, idle_hours) if short else idle_hours
    janitor = janitor or Path.home() / ".cc-reaper" / "worktree-janitor.sh"
    rows = processes()
    if rows is None:
        raise RuntimeError("ps failed; kept everything")
    ports = listening()
    if ports is None:
        raise RuntimeError("lsof could not list listeners; kept everything")
    reaped = candidates = 0
    rss_kb = 0
    claims = {}
    prune_idle(state_dir, rows)
    orphans = []
    for root in sorted(rows):
        ppid, _, _, _, command = rows[root]
        if ppid == 1 and esbuild_service(command):
            why, worktree = orphan(rows, ports, root, min_age, now, janitor, claims, claim_timeout)
            label = f"pid={root} worktree={worktree or '-'} cmd={command[:80]!r}"
            if why:
                print(f"KEEP {label} (esbuild service: {why})")
                continue
            candidates += 1
            if apply:
                orphans.append((root, label))
            else:
                print(f"CANDIDATE {label} (esbuild service with no parent; {rows[root][2] // 1024} MB)")
            continue
        if ppid != 1 or launcher(command) is None:
            continue
        verdict, reason, worktree, members, port, state = judge(
            rows, ports, root, min_age, now, janitor, claims, claim_timeout, state_dir, window)
        label = f"pid={root} worktree={worktree or '-'} cmd={command[:80]!r}"
        if verdict != "reap":
            print(f"{verdict.upper()} {label} ({reason})")
            continue
        candidates += 1
        size = sum(rows[p][2] for p in members)
        if not apply:
            print(f"CANDIDATE {label} ({reason}; {len(members)} processes, {size // 1024} MB)")
            continue
        # Processes and listeners again, right before signalling: the scan, and the claim
        # checks since, can be minutes old, and a restarting server may have new children
        # bound to its port by now. The tree is rebuilt from the fresh listing.
        fresh_rows, fresh = processes(), listening()
        if (fresh_rows is None or fresh is None or root not in fresh_rows
                or fresh_rows[root][3] != rows[root][3]):
            print(f"KEEP {label} (changed, or unreadable, at the recheck)")
            continue
        members = tree(fresh_rows, root)
        # Kept if it is now used, or no longer what it was judged as: a tree judged unserved
        # that listens now is a server that came up, whatever its connections say.
        now_state, _ = serving(fresh, members, port, rows=fresh_rows)
        if (now_state != state or published(fresh_rows, fresh, members, worktree)
                or any(AGENT.search(fresh_rows[p][4]) for p in members)):
            print(f"KEEP {label} (serving, or an agent joined, at the recheck)")
            continue
        snapshot = {p: fresh_rows[p][3] for p in members}
        signalled, denied = stop(members, snapshot, grace, send=send, sleep=sleep)
        note = f"; not permitted to signal {denied}" if denied else ""
        if signalled:
            reaped += 1
            rss_kb += size
            print(f"STOPPED {label} ({reason}; {len(signalled)} processes, {size // 1024} MB{note})")
        else:
            print(f"KEEP {label} (changed before it could be stopped{note})")
    if orphans:
        # Rechecked like a tree, then stopped together so they share one grace period. The
        # claim answers are reused: one janitor call per worktree per run.
        fresh_rows, fresh = processes(), listening()
        chosen = {}
        for pid, label in orphans:
            if (fresh_rows is None or fresh is None or pid not in fresh_rows
                    or fresh_rows[pid][3] != rows[pid][3]
                    or orphan(fresh_rows, fresh, pid, min_age, now, janitor, claims, claim_timeout)[0]):
                print(f"KEEP {label} (changed, or unreadable, at the recheck)")
            else:
                chosen[pid] = label
        signalled, denied = stop(list(chosen), {p: fresh_rows[p][3] for p in chosen}, grace,
                                 send=send, sleep=sleep) if chosen else ([], [])
        for pid, label in chosen.items():
            if pid in signalled:
                reaped += 1
                rss_kb += rows[pid][2]
                print(f"STOPPED {label} (esbuild service with no parent; {rows[pid][2] // 1024} MB)")
            else:
                print(f"KEEP {label} (changed before it could be stopped"
                      + (", not permitted to signal it)" if pid in denied else ")"))
    print(f"dev servers: stopped={reaped}/{candidates} rss={rss_kb // 1024}MB idle-window={window}h"
          + (f" ({short_why})" if short else "") + ("" if apply else " (report only)"))
    return reaped, candidates


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("report", "apply"))
    parser.add_argument("--min-hours", type=int, default=6)
    parser.add_argument("--grace-seconds", type=int, default=10)
    parser.add_argument("--claim-timeout-seconds", type=int, default=900)
    parser.add_argument("--idle-hours", type=int, default=IDLE_HOURS)
    parser.add_argument("--pressure-idle-hours", type=int, default=PRESSURE_IDLE_HOURS)
    args = parser.parse_args()
    if min(args.min_hours, args.idle_hours, args.pressure_idle_hours) < 1:
        raise ValueError("minimum age and idle windows must be at least 1 hour")
    reap(apply=args.mode == "apply", min_age=args.min_hours * 3600, grace=args.grace_seconds,
         claim_timeout=args.claim_timeout_seconds, idle_hours=args.idle_hours,
         pressure_hours=args.pressure_idle_hours)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(f"dev servers: SKIP {error}", file=sys.stderr)
        sys.exit(1)
