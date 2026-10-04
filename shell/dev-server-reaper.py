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
- no process in the tree listens on that port (the inspector ports a server also opens
  do not count), nor - when something else holds that port - on one of the next 20, where
  vite and astro move to; listeners are read again right before signalling. For
  `react-scripts start`, whose port is not on its command line, serving means a TCP
  connection to any port its tree listens on: an open tab keeps the hot-reload socket
  connected, but a closed laptop drops it within seconds, so one empty moment proves
  nothing: the tree must have had no connection at every run for CRA_IDLE_HOURS, as
  recorded in the state directory, and none again at the recheck. Two CRA servers sat 2
  days like that on 2026-10-05, holding 4.5 GB while the compressor churned 850 MB/s;
- nothing publishes it: no other listening process names its worktree on its command line
  (a review front such as ~/stima-review/tailnet_review.mjs <worktree> <port>), and no
  `tailscale serve` handler proxies to a port the tree listens on;
- the root is at least the minimum age, so a server still starting is not judged;
- the worktree janitor's `--claims <worktree>` names no live session cwd and no live
  session tool call for that worktree (this session's own mentions excepted, as the
  janitor does).

Nothing is judged by file times: a page being viewed writes no file, and a stack with
its own ticker writes one every minute. A tree that does serve its port is listed as
SERVING for a person to decide on, never stopped. Every probe that fails or cannot decide
keeps the tree. Stopping is SIGTERM to every process in the tree, then SIGKILL to those
still alive after the grace period; each pid is signalled only while its start time still
matches the scan, so a reused pid is never hit.
"""

import argparse
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
# How long such a tree must have had no connection at every run before it is stopped.
CRA_IDLE_HOURS = 12
STATE_DIR = Path.home() / ".cc-reaper" / "state" / "dev-server-idle"


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
    binary = shutil.which("tailscale")
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
    walk({k: v for k, v in config.items() if k != "TCP"})
    return found


def published(rows, ports, members, worktree):
    """Why the tree is published to someone, or None. Anything unreadable is a reason."""
    # An argument naming the worktree, not argv[0]: the local stack's own API runs from a
    # binary inside the worktree and publishes nothing.
    for pid, held in ports.items():
        if not held or pid in members or pid not in rows:
            continue
        if any(arg == str(worktree) or arg.startswith(f"{worktree}/") for arg in rows[pid][4].split()[1:]):
            return f"published by listening pid {pid}, which names its worktree"
    forwarded = served_ports()
    if forwarded is None:
        return "tailscale serve unreadable"
    hit = sorted(forwarded & {p for pid in members for p in ports.get(pid, ())})
    return f"published by tailscale serve on {hit[0]}" if hit else None


def idle_for(state_dir, root, begun, now):
    """Seconds this tree has been recorded unused; records it first when new."""
    marker = state_dir / f"{root}-{int(begun)}"
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        if not marker.exists():
            marker.touch()
            return 0
        return now - marker.stat().st_mtime
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


def cwd(pid):
    """The process's working directory; None when lsof cannot say."""
    try:
        probe = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                               capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    names = [line[1:] for line in probe.stdout.splitlines() if line.startswith("n")]
    return Path(names[0]) if probe.returncode == 0 and len(names) == 1 else None


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


def serving(ports, members, port):
    """Why the tree serves, or None: it listens on its port, or on one just above it, where
    vite and astro move when theirs is taken - whether or not it is still taken now. With
    ANY_PORT: something is connected to a port the tree listens on."""
    if port == ANY_PORT:
        listens = {p for pid in members for p in ports.get(pid, ())}
        if not listens:
            return None
        clients = connected()
        if clients is None:
            return "kept: connections unreadable"
        used = sorted(listens & clients)
        return f"has connections on {used[0]}" if used else None
    if any(port in ports.get(pid, ()) for pid in members):
        return f"listens on {port}"
    moved = sorted(p for pid in members for p in ports.get(pid, ()) if port < p <= port + PORT_SHIFT)
    return f"moved from {port} to {moved[0]}" if moved else None


def judge(rows, ports, root, min_age, now, janitor, claims=None, claim_timeout=900,
          state_dir=STATE_DIR, idle_hours=CRA_IDLE_HOURS):
    """(verdict, reason, worktree, members, port); verdict is reap, serving or keep."""
    ppid, _, _, lstart, command = rows[root]
    port = launcher(command)
    if not port:
        return "keep", "no port on the command line", None, [], port
    begun = started(lstart)
    if begun is None or now - begun < min_age:
        return "keep", "younger than the minimum age", None, [], port
    members = tree(rows, root)
    why = serving(ports, members, port)
    if why:
        if port == ANY_PORT:
            forget_idle(state_dir, root, begun)
        return "serving", why, None, members, port
    groups = {rows[pid][1] for pid in members}
    if any(AGENT.search(row[4]) and (pid in members or row[1] in groups)
           for pid, row in rows.items()):
        return "keep", "an agent process is in the tree or its process group", None, [], port
    where = cwd(root)
    worktree = linked_worktree(where) if where else None
    if worktree is None:
        return "keep", "not in a linked worktree", None, [], port
    # One janitor --claims call per worktree per run: it reads every live transcript, and
    # duplicates share their worktree.
    claims = {} if claims is None else claims
    if worktree not in claims:
        claims[worktree] = claimed(worktree, janitor, claim_timeout)
    if claims[worktree]:
        return "keep", "a live session claims the worktree, or the claim check failed", worktree, [], port
    why = published(rows, ports, members, worktree)
    if why:
        # Unused starts counting again when the publisher goes, not from before it came.
        if port == ANY_PORT:
            forget_idle(state_dir, root, begun)
        return "serving", why, worktree, members, port
    if port == ANY_PORT:
        idle = idle_for(state_dir, root, begun, now)
        if idle < idle_hours * 3600:
            return "keep", f"unused for {idle / 3600:.1f}h of the {idle_hours}h it must be", worktree, [], port
        return "reap", f"no connection on any port it listens on for {idle / 3600:.1f}h", worktree, members, port
    return "reap", f"does not listen on its port {port}", worktree, members, port


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
         sleep=time.sleep, claim_timeout=900, state_dir=STATE_DIR, idle_hours=CRA_IDLE_HOURS):
    """Print one line per launcher root and a summary; return (reaped, candidates)."""
    now = time.time() if now is None else now
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
    for root in sorted(rows):
        ppid, _, _, _, command = rows[root]
        if ppid != 1 or launcher(command) is None:
            continue
        verdict, reason, worktree, members, port = judge(rows, ports, root, min_age, now, janitor, claims,
                                                         claim_timeout, state_dir, idle_hours)
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
        if (serving(fresh, members, port) or published(fresh_rows, fresh, members, worktree)
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
    print(f"dev servers: stopped={reaped}/{candidates} rss={rss_kb // 1024}MB"
          + ("" if apply else " (report only)"))
    return reaped, candidates


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("report", "apply"))
    parser.add_argument("--min-hours", type=int, default=6)
    parser.add_argument("--grace-seconds", type=int, default=10)
    parser.add_argument("--claim-timeout-seconds", type=int, default=900)
    parser.add_argument("--cra-idle-hours", type=int, default=CRA_IDLE_HOURS)
    args = parser.parse_args()
    if args.min_hours < 1 or args.cra_idle_hours < 1:
        raise ValueError("minimum age and CRA idle time must be at least 1 hour")
    reap(apply=args.mode == "apply", min_age=args.min_hours * 3600, grace=args.grace_seconds,
         claim_timeout=args.claim_timeout_seconds, idle_hours=args.cra_idle_hours)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(f"dev servers: SKIP {error}", file=sys.stderr)
        sys.exit(1)
