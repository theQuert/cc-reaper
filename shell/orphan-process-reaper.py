#!/usr/bin/env python3
"""Stop processes no live Claude Code session owns, and a live session's own tool shells that wait forever.

On 2026-11-18 the Mac mini sat at 0% CPU with a 5-minute load of 98 to 127: dev servers, proxies and
`until` shells of dead sessions, and 23 Bash-tool shells of one live session whose wait loops never
ended (two without a `sleep`, 22 hours and 2 days old). No rule reached them: the monitor matches
`claude ... stream-json`, dev-server-reaper.py judges launchers by argv[0] in a worktree,
session-reaper.py closes tmux panes (stima-api#9007).

Two kinds of verdict, both stopped by SIGTERM to the whole tree (children first), a wait, and a
report of the survivors; there is no SIGKILL.

1. A tree reparented to launchd whose owner session is dead. The owner is read, in this order, from
   `CLAUDE_CODE_SESSION_ID` in the environment of any process in the tree (one `ps eww` for the host;
   only that key is kept, no environment value is printed or logged), a session scratchpad path
   (`/tmp/claude-<uid>/<project>/<session id>/`) in the root's command line or working directory, the
   `claude-task-worktree` marker of the root's linked worktree (its creator, a weaker owner). Only a root
   shaped like a Claude-started tree (a runtime or shell, the local stack's binary, a scratchpad) is judged,
   never a shared daemon that carries one session's helper. The owner is dead only on positive evidence,
   all of it, and a live claim on the root's linked worktree (`worktree-janitor.sh --claims`) keeps the tree
   whoever the owner is, since a session's id can change while it lives (`/clear`):
   - no live pid in `~/.claude/sessions/*.json`, none in the daemon roster `~/.claude/daemon/roster.json`
     (a hosted session is live while its pty host or repl pid is), none in the session state file;
   - the host has a record of it (a transcript under `~/.claude/projects`, or a job directory), so an id
     nothing here knows is unknown, not dead;
   - its transcript was not written in the last hour.
   An owner that cannot be found, an unreadable registry, roster or probe: keep, and say so
   (`KEEP(unknown-owner)`). A tree with several owners goes only when every one is dead.
2. A live session's own Bash-tool shell (`shell-snapshots/snapshot-zsh-` in its command, its parent that
   session's claude process) whose command is a wait loop (`until` or `while` ... `done`) older than
   --loop-hours, or whose loop body does nothing (`do :; done`, no `sleep`, no command) older than
   --spin-minutes. A shell with a descendant older than 10 minutes that is not `sleep` or `tail` is kept,
   spin-shaped or not (the loop ended; the shell runs something). Both kinds keep the lease and serving
   rules of 1.

Never touched, owner or no owner: the tmux server, any process `launchctl list` names (whatever the label:
the ci-runner-macos and gce-jit-broker families, Chrome), docker and OrbStack, a claude daemon, a pid the
registry or roster lists as live, any claude or codex process in the tree, a tree holding a live
resource lease (`with_local_resource.py`; while any live lease names no owner pid, such as a
`--detach --ttl` one, every rule-1 tree is kept), a listening tree something is connected to, a never-kill
pid and its descendants, and the reaper's own tree.
"""

import argparse
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path


def _sibling(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").removesuffix(".py"),
                                                  Path(__file__).resolve().with_name(name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dsr = _sibling("dev-server-reaper.py")
try:
    session_state = _sibling("session_state.py")
except (OSError, ImportError, SyntaxError):
    session_state = None

processes = dsr.processes   # {pid: (ppid, pgid, rss_kb, lstart, command)}; None when ps fails

UUID = r"[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}"
ENV_KEY = re.compile(r"(?:^|\s)CLAUDE_CODE_SESSION_ID=(" + UUID + r")(?=\s|$)")
# A tool shell: `zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-N.sh && ... eval '<the command>'`.
SNAPSHOT = "shell-snapshots/snapshot-zsh-"
# until|while ... do <body> done, the body running to the last `done`. ps shows a newline as \012.
LOOP = re.compile(r"(?<![\w./-])(?:until|while)\s.*?(?<![\w-])do(?![\w-])(.*)(?<![\w-])done(?![\w-])", re.S)
EMPTY_BODY = re.compile(r"(?:[\s;:]|true\b|false\b)*")
PROTECTED_COMMAND = re.compile(
    r"ci-runner-macos|gce-jit-broker|ops/ci-runner/|Runner\.Listener|actions-runner"
    r"|claude\s+(?:daemon|bg-pty-host|bg-spare)\b|/Applications/(?:Docker|OrbStack)")
PROTECTED_TOOL = re.compile(r"(?:tmux|docker|dockerd|containerd|com\.docker\..*|orbstack.*|tailscaled)", re.I)
# What a Claude-spawned detached tree looks like, for the unknown-owner report: a runtime or shell
# root, the local stack's binary, a session scratchpad. Anything else owned by launchd is not reported.
LOOKS = re.compile(r"/\.local-stack/|/claude-\d+/")
OWNER_QUIET_SECONDS = 3600
LONG_CHILD_SECONDS = 600
# What a log line must not carry: a credential flag or pair, a bearer token, the password of a URL.
MASK = re.compile(r"(?i)\b(--?)?(token|key|secret|password)([ =])\S+|Bearer \S+|(://[^/@\s]+:)[^/@\s]+@")


def mask(text):
    return MASK.sub(lambda m: (f"{m.group(1) or ''}{m.group(2)}{m.group(3)}<masked>" if m.group(2)
                               else "Bearer <masked>" if m.group(0).startswith(("B", "b")) else f"{m.group(4)}<masked>@"), text)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def run(*argv, timeout=60):
    try:
        done = subprocess.run(list(argv), capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def env_owners():
    """{pid: session id} from one `ps eww` over the host; None when ps fails. Only the one key is
    kept, the rest of each line is dropped here."""
    out = run("ps", "eww", "-axo", "pid=,command=")
    if out is None:
        return None
    owners = {}
    for line in out.splitlines():
        head = re.match(r"\s*(\d+)\s", line)
        found = ENV_KEY.findall(line) if head else []
        if found:
            owners[int(head.group(1))] = found[-1].lower()   # the environment follows the command
    return owners


def launchd_labels():
    """{pid: label} of running launchd jobs; None when launchctl cannot answer."""
    out = run("launchctl", "list", timeout=30)
    if out is None:
        return None
    labels = {}
    for line in out.splitlines():
        cols = line.split("\t")
        if len(cols) == 3 and cols[0].isdigit():
            labels[int(cols[0])] = cols[2]
    return labels


def live_sessions(home, alive, now):
    """(session ids, {live pid: session id}) of what is running; None when a registry exists and
    cannot be read, because then nobody knows what is live."""
    ids, pids = set(), {}
    try:
        for record in sorted((home / ".claude" / "sessions").glob("*.json")):
            data = json.loads(record.read_text())
            pid, sid = data.get("pid"), str(data.get("sessionId") or "").lower()
            if isinstance(pid, int) and sid and alive(pid):
                ids.add(sid)
                pids[pid] = sid
        roster = home / ".claude" / "daemon" / "roster.json"
        if roster.exists():
            data = json.loads(roster.read_text())
            for worker in (data.get("workers") or {}).values():
                sid = str(worker.get("sessionId") or "").lower()
                held = [p for p in (worker.get("pid"), worker.get("replPid")) if isinstance(p, int) and alive(p)]
                if held:
                    ids.add(sid)
                    pids.update({p: sid for p in held})
            daemon = data.get("supervisorPid")
            if isinstance(daemon, int) and alive(daemon):
                pids[daemon] = ""
    except (OSError, ValueError, AttributeError, TypeError):
        return None
    if session_state is not None:
        doc = session_state.read(home / ".cc-reaper" / "state" / "sessions.json", now=now)
        ids |= {sid.lower() for sid in session_state.by_sid(doc)}
    return ids, pids


def transcript_age(sid, home, now):
    """Seconds since the session's transcript (or job record) was written; None when the host has none."""
    found = list((home / ".claude" / "projects").glob(f"*/{sid}.jsonl"))
    found += list((home / ".claude" / "jobs").glob(f"{sid[:8]}/state.json"))
    times = []
    for path in found:
        try:
            times.append(path.stat().st_mtime)
        except OSError:
            continue
    return max(0.0, now - max(times)) if times else None


def marker_owner(where):
    """(creator session id, worktree) from the claude-task-worktree marker of the linked worktree
    holding `where`; (None, None) when there is none."""
    worktree = dsr.linked_worktree(where) if where else None
    gitdir = run("git", "-C", str(worktree), "rev-parse", "--absolute-git-dir", timeout=30) if worktree else None
    if not gitdir:
        return None, None
    try:
        first = (Path(gitdir.strip()) / "claude-task-worktree").read_text().split()[:1]
    except OSError:
        return None, None
    return (first[0].lower(), worktree) if first and re.fullmatch(UUID, first[0]) else (None, None)


def lease_owners(home, alive, now):
    """(owner pids, unowned) of the resource leases (`with_local_resource.py`) still live. A lease is
    live while its ttl has not run out and, when it names an owner pid, that pid is alive. `unowned`
    is true while any live lease names no owner pid: a `--detach --ttl` lease deliberately has none,
    and the resource it covers lives in some other tree, so nothing can say whose it is and every
    tree is kept (conservative on purpose)."""
    root = os.environ.get("STIMA_LOCAL_RESOURCE_LOCK_DIR")
    base = Path(root).expanduser() if root else home / ".cache" / "stima-api" / "resource-locks"
    owners, unowned = set(), False
    for path in (base / "leases").glob("*.lease"):
        try:
            record = json.loads(path.read_text())
            owner, ttl = int(record.get("owner_pid") or 0), record.get("ttl")
            expired = bool(ttl) and now > float(record.get("started") or 0) + float(ttl)
        except (OSError, ValueError, TypeError):
            continue
        if expired:
            continue
        if owner and alive(owner):
            owners.add(owner)
        elif not owner and ttl:
            unowned = True
    return owners, unowned


def wait_loop(command):
    """(True, spin) when the command is a wait loop; spin when its body runs nothing."""
    match = LOOP.search(command.replace("\\012", "\n"))
    if not match:
        return False, False
    return True, EMPTY_BODY.fullmatch(match.group(1)) is not None


def long_lived_child(rows, members, root, now):
    """Whether a descendant of the shell, other than sleep or tail, is older than LONG_CHILD_SECONDS.
    A shell stuck in its loop has only seconds-old condition commands under it; a long-lived child
    means the loop ended and the shell is running something. A start time that cannot be read counts."""
    for pid in members:
        tool = os.path.basename((rows[pid][4].split() or [""])[0])
        if pid == root or tool in ("sleep", "tail"):
            continue
        begun = dsr.started(rows[pid][3])
        if begun is None or now - begun > LONG_CHILD_SECONDS:
            return True
    return False


def describe(command):
    """What a log line says of a process: the basename of argv[0]; for a tool shell also the start of
    the command it evals (credentials masked first, then cut)."""
    text = os.path.basename((command.split() or ["?"])[0])
    if SNAPSHOT in command and "eval '" in command:
        text += " eval '" + mask(command.split("eval '", 1)[1].replace("\\012", " "))[:80]
    return text


def label(pid, row, owner=None):
    return f"pid={pid} owner={(owner or '-')[:8]} cmd={describe(row[4])!r}"


def ancestors(rows, pid):
    found = set()
    while pid in rows and pid not in found and pid > 1:
        found.add(pid)
        pid = rows[pid][0]
    return found


def why_protected(rows, members, own, live_pids, labels, keep):
    parents = {p: r[0] for p, r in rows.items()}
    for pid in members:
        command = rows[pid][4]
        tool = os.path.basename((command.split() or [""])[0]).rstrip(":")
        if pid in own:
            return "the reaper's own tree"
        if pid in live_pids:
            return f"live session process {pid}"
        if pid in labels:
            return f"launchd job {labels[pid]}"
        if PROTECTED_COMMAND.search(command) or PROTECTED_TOOL.fullmatch(tool):
            return f"protected family at pid {pid}"
        if dsr.AGENT.search(command):
            return f"an agent process, pid {pid}, in the tree"
        if dsr.never_kill(pid, parents, keep):
            return f"never-kill pid at {pid}"
    return None


def reap(apply=False, loop_hours=24, spin_minutes=10, grace=10, now=None, home=None, send=os.kill,
         sleep=time.sleep, alive=pid_alive, janitor=None, self_pid=None, keep_pids=None):
    """Print one line per decision and a summary; return (stopped, candidates)."""
    now = time.time() if now is None else now
    home = Path.home() if home is None else Path(home)
    janitor = janitor or home / ".cc-reaper" / "worktree-janitor.sh"
    keep = dsr.never_kill_pids() if keep_pids is None else set(keep_pids)
    rows = processes()
    owners = env_owners()
    labels = launchd_labels()
    live = live_sessions(home, alive, now)
    if rows is None or owners is None or labels is None or live is None:
        raise RuntimeError("ps, launchctl or the session registry could not answer; kept everything")
    live_ids, live_pids = live
    own = ancestors(rows, os.getpid() if self_pid is None else self_pid)
    leases, unowned_lease = lease_owners(home, alive, now)
    cache = {}
    verdicts = []   # (root, label text, reason)
    kept = 0

    def keep_line(why, pid, owner=None):
        nonlocal kept
        kept += 1
        print(f"KEEP({why}) {label(pid, rows[pid], owner)}")

    def serving(members):
        if "ports" not in cache:
            cache["ports"], cache["connected"] = dsr.listening(), None
        ports = cache["ports"]
        if ports is None:
            return "probe-failed"
        listens = {p for pid in members for p in ports.get(pid, ())}
        if not listens:
            return None
        if cache["connected"] is None:
            cache["connected"] = dsr.connected()
        if cache["connected"] is None:
            return "probe-failed"
        return "serving" if listens & cache["connected"] else None

    # 1. Trees reparented to launchd whose owner is gone.
    for root in sorted(rows):
        ppid, _, _, lstart, command = rows[root]
        if ppid != 1:
            continue
        members = dsr.tree(rows, root)
        tool = os.path.basename((command.split() or [""])[0])
        if not (tool in dsr.SERVER_ROOTS or LOOKS.search(command)):
            continue   # a shared daemon carrying one session's helper is not that session's tree
        ids = sorted({owners[p] for p in members if p in owners})
        sid = ids[0] if ids else None
        protected = why_protected(rows, members, own, live_pids, labels, keep)
        if protected:
            keep_line(f"protected: {protected}", root, sid)
            continue
        where = None
        if not ids:
            ids = sorted(set(dsr.scratch_sessions(None, [command])))
            if not ids:
                where = dsr.cwd(root)
                ids = sorted(dsr.scratch_sessions(where, []))
            if not ids:
                ids = [i for i in [marker_owner(where)[0]] if i]
        if not ids:
            keep_line("unknown-owner", root)
            continue
        sid = ids[0]
        if any(i in live_ids for i in ids):
            keep_line("owner-live", root, sid)
            continue
        ages = [transcript_age(i, home, now) for i in ids]
        if any(a is None for a in ages):
            keep_line("unknown-owner", root, sid)
            continue
        if any(a < OWNER_QUIET_SECONDS for a in ages):
            keep_line("owner-recent", root, sid)
            continue
        # A session's id can change while it lives (/clear), so a dead id proves nothing about a
        # worktree a live session still claims, whoever the owner was found to be.
        where = where or dsr.cwd(root)
        worktree = dsr.linked_worktree(where) if where else None
        if worktree is not None and cache.setdefault(("claim", worktree), dsr.claim_level(worktree, janitor)) != 0:
            keep_line("owner-claimed", root, sid)
            continue
        if unowned_lease or leases & set(members):
            keep_line("lease", root, sid)
            continue
        busy = serving(members)
        if busy:
            keep_line(busy, root, sid)
            continue
        verdicts.append((root, sid, f"its session ended; {len(members)} processes"))

    # 2. A live session's own tool shells that wait.
    for pid, (ppid, _, _, lstart, command) in sorted(rows.items()):
        if SNAPSHOT not in command or ppid not in live_pids or not live_pids[ppid]:
            continue
        is_loop, spin = wait_loop(command)
        begun = dsr.started(lstart)
        if not is_loop or begun is None:
            continue
        age = now - begun
        if age < (spin_minutes * 60 if spin else loop_hours * 3600):
            continue
        if owners.get(pid, live_pids[ppid]) != live_pids[ppid]:
            keep_line("owner-differs", pid, owners.get(pid))
            continue
        members = dsr.tree(rows, pid)
        protected = why_protected(rows, members, own, live_pids, labels, keep)
        if protected:
            keep_line(f"protected: {protected}", pid, live_pids[ppid])
            continue
        if long_lived_child(rows, members, pid, now):
            keep_line("long-child", pid, live_pids[ppid])
            continue
        if leases & set(members):
            keep_line("lease", pid, live_pids[ppid])
            continue
        busy = serving(members)
        if busy:
            keep_line(busy, pid, live_pids[ppid])
            continue
        shape = "a loop that runs nothing" if spin else "a wait loop"
        verdicts.append((pid, live_pids[ppid], f"{shape} of a live session for {age / 3600:.1f}h; {len(members)} processes"))

    stopped = 0
    chosen = {}
    if verdicts and apply:
        # Processes again, right before signalling: the scan and the probes can be minutes old.
        fresh = processes()
        for root, sid, why in verdicts:
            text = label(root, rows[root], sid)
            if fresh is None or root not in fresh or fresh[root][3] != rows[root][3]:
                print(f"KEEP(changed) {text}")
                continue
            members = dsr.tree(fresh, root)
            protected = why_protected(fresh, members, own, live_pids, labels, keep)
            if protected:
                print(f"KEEP(protected: {protected} at the recheck) {text}")
                continue
            chosen[root] = (text, why, members, {p: fresh[p][3] for p in members})
    else:
        for root, sid, why in verdicts:
            print(f"CANDIDATE {label(root, rows[root], sid)} ({why})")
    if chosen:
        order = [p for root in chosen for p in reversed(chosen[root][2])]   # a tree's children first
        snapshot = {p: s for root in chosen for p, s in chosen[root][3].items()}
        now_rows = processes() or {}
        sent = []
        for pid in order:
            if pid in now_rows and now_rows[pid][3] == snapshot[pid]:
                try:
                    send(pid, signal.SIGTERM)
                    sent.append(pid)
                except (ProcessLookupError, PermissionError):
                    pass
        sleep(grace)
        after = processes() or {}
        left = [p for p in sent if p in after and after[p][3] == snapshot[p]]
        for root, (text, why, members, _) in chosen.items():
            if any(p in sent for p in members):
                stopped += 1
                print(f"STOPPED {text} ({why})")
            else:
                print(f"KEEP(changed) {text}")
        for pid in left:
            print(f"SURVIVOR pid={pid} cmd={describe(after[pid][4])!r} (still running {grace}s after SIGTERM; not killed)")
    print(f"orphan processes: stopped={stopped}/{len(verdicts)} kept={kept}" + ("" if apply else " (report only)"))
    return stopped, len(verdicts)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("report", "apply"))
    parser.add_argument("--loop-hours", type=float, default=24)
    parser.add_argument("--spin-minutes", type=float, default=10)
    parser.add_argument("--grace-seconds", type=int, default=10)
    args = parser.parse_args()
    if args.loop_hours <= 0 or args.spin_minutes <= 0:
        raise ValueError("the age bounds must be positive")
    reap(apply=args.mode == "apply", loop_hours=args.loop_hours, spin_minutes=args.spin_minutes,
         grace=args.grace_seconds)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(f"orphan processes: SKIP {error}", file=sys.stderr)
        sys.exit(1)
