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
  verdict;
- the root was reparented to launchd (ppid 1), so no session's shell is waiting on it, and
  no `claude` or `codex` process shares a process group with any process in the tree;
- the root's working directory is inside a linked git worktree, never a primary checkout;
- no process in the tree listens on that port (the inspector ports a server also opens
  do not count);
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
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


LAUNCHER = re.compile(
    r"(?:^|[\s/])(?:npm run (?:dev|preview|start)"
    r"|wrangler(?:\.js)? (?:pages )?dev"
    r"|next (?:dev|start)"
    r"|vite)(?:\s|$)")
PORT = re.compile(r"(?:--port[= ]|\s-p\s+)(\d{2,5})(?:\s|$)")
AGENT = re.compile(r"(?:^|/)(?:claude|codex)(?:\s|$)")


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
    return ports


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
        top, gd, common = git("rev-parse", "--show-toplevel", "--absolute-git-dir",
                              "--git-common-dir").splitlines()
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    common = Path(common) if os.path.isabs(common) else Path(top) / common
    return Path(top) if Path(gd).resolve() != common.resolve() else None


def claimed(worktree, janitor):
    """True when a live session claims the worktree, or the janitor cannot say."""
    try:
        probe = subprocess.run([str(janitor), "--claims", str(worktree)], capture_output=True,
                               text=True, timeout=300, check=False)
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


def judge(rows, ports, root, min_age, now, janitor, claims=None):
    """('reap'|'serving'|'keep', reason, worktree, members) for one launcher root."""
    ppid, _, _, lstart, command = rows[root]
    port = PORT.search(command)
    if port is None:
        return "keep", "no port on the command line", None, []
    port = int(port.group(1))
    begun = started(lstart)
    if begun is None or now - begun < min_age:
        return "keep", "younger than the minimum age", None, []
    members = tree(rows, root)
    if any(port in ports.get(pid, ()) for pid in members):
        return "serving", f"listens on {port}", None, members
    groups = {rows[pid][1] for pid in members}
    if any(row[1] in groups and pid not in members and AGENT.search(row[4])
           for pid, row in rows.items()):
        return "keep", "an agent process shares its process group", None, []
    where = cwd(root)
    worktree = linked_worktree(where) if where else None
    if worktree is None:
        return "keep", "not in a linked worktree", None, []
    # One janitor --claims call per worktree per run: it reads every live transcript, and
    # duplicates share their worktree.
    claims = {} if claims is None else claims
    if worktree not in claims:
        claims[worktree] = claimed(worktree, janitor)
    if claims[worktree]:
        return "keep", "a live session claims the worktree, or the claim check failed", worktree, []
    return "reap", f"does not listen on its port {port}", worktree, members


def stop(members, snapshot, grace, send=os.kill, sleep=time.sleep):
    """TERM then KILL members whose start time still matches; return the pids signalled."""
    def alive_same():
        now = processes() or {}
        return [p for p in members if p in now and now[p][3] == snapshot[p]]
    targets = alive_same()
    for pid in targets:
        try:
            send(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    sleep(grace)
    for pid in alive_same():
        try:
            send(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return targets


def reap(apply=False, min_age=6 * 3600, grace=10, now=None, janitor=None, send=os.kill,
         sleep=time.sleep):
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
    for root in sorted(rows):
        ppid, _, _, _, command = rows[root]
        if ppid != 1 or not LAUNCHER.search(command):
            continue
        verdict, reason, worktree, members = judge(rows, ports, root, min_age, now, janitor, claims)
        label = f"pid={root} worktree={worktree or '-'} cmd={command[:80]!r}"
        if verdict != "reap":
            print(f"{verdict.upper()} {label} ({reason})")
            continue
        candidates += 1
        size = sum(rows[p][2] for p in members)
        if not apply:
            print(f"CANDIDATE {label} ({reason}; {len(members)} processes, {size // 1024} MB)")
            continue
        snapshot = {p: rows[p][3] for p in members}
        signalled = stop(members, snapshot, grace, send=send, sleep=sleep)
        if signalled:
            reaped += 1
            rss_kb += size
            print(f"STOPPED {label} ({reason}; {len(signalled)} processes, {size // 1024} MB)")
        else:
            print(f"KEEP {label} (changed before it could be stopped)")
    print(f"dev servers: stopped={reaped}/{candidates} rss={rss_kb // 1024}MB"
          + ("" if apply else " (report only)"))
    return reaped, candidates


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("report", "apply"))
    parser.add_argument("--min-hours", type=int, default=6)
    parser.add_argument("--grace-seconds", type=int, default=10)
    args = parser.parse_args()
    if args.min_hours < 1:
        raise ValueError("minimum age must be at least 1 hour")
    reap(apply=args.mode == "apply", min_age=args.min_hours * 3600, grace=args.grace_seconds)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(f"dev servers: SKIP {error}", file=sys.stderr)
        sys.exit(1)
