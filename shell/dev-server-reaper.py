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
  `tailscale serve` handler proxies to a port the tree listens on - unless its owning
  session has ended (below), when a `tailscale serve` entry no longer keeps it;
- no live session's own listening process forwards to it: a proxy a live or in-grace worktree
  claim or session scratchpad owns, listening itself, whose command line or script file (one under
  a scratchpad or a linked worktree, the first 64 KB) names a port the tree listens on - a
  `frameproxy.mjs` carries its target in a constant, not on its command line;
- the root is at least the minimum age, so a server still starting is not judged;
- the worktree janitor's `--claims <worktree>` names no live session cwd and no live
  session tool call for that worktree (this session's own mentions excepted, as the
  janitor does).

The owner is who started it, read from the root only: the linked worktree of its working
directory, or the session id in a `/tmp/claude-<uid>/<project>/<session id>/` path in that
directory or in the script the root runs (`node /tmp/claude-.../scratchpad/proxy.mjs`, also
inside a `zsh -c 'eval node ...'` wrapper). An argument, or a child's command line, that
names a scratchpad attributes nothing. A missing claim is not proof the owner is gone: the
janitor sees a worktree only through a live session's cwd or its last two turns, and a
session working from the primary checkout can have started a server and moved on. The owner
has ended only on positive evidence, all of it, for every owner of the tree:

- the janitor's `--claims` names no live session and none inside its grace period, and
- for a worktree, nothing has touched it for 3 days: no commit, no change to a file `git
  status` names, no stack file (the evidence local_stack.sh's stale-idle uses);
- for a session, its transcript `~/.claude/projects/*/<id>.jsonl` has not been written for
  24h and no process holds it open.

A tree whose owner has ended is stopped when nothing is connected to it, even though it
listens and even if `tailscale serve` forwards to it (2026-11-17: 23 servers, 4 to 35 days
old, every one of them published, or `next start`, or under a scratchpad, so none of the rules
above could ever reach them). A tree whose owner is alive, inside the grace period, not yet
proven ended, or unknown keeps every protection above, `next start` and `tailscale serve`
included.

Nothing is judged by file times: a page being viewed writes no file, and a stack with
its own ticker writes one every minute. A tree something is connected to, or that is
published, is listed as SERVING for a person to decide on, never stopped. Every probe that fails or cannot decide
keeps the tree.

An esbuild `--service` (the stdio build service wrangler and vite spawn) whose parent died
is stopped too: run from a `node_modules` esbuild binary, reparented to launchd, no child,
no socket but its dead stdio pair, the minimum age, no agent or launcher left in its process
group, cwd in a linked worktree with no live claim. Twelve sat 5-7 days on 2026-10-06 while
swap was 13.6 of 14.3 GB, each holding memory for a dev server that no longer existed.

After the verdicts, `STALE-SERVE backend port N` names each `tailscale serve` handler whose
backend nothing listens on any more. It is a list for a person: nothing here edits the serve
configuration.

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
# A script a session's scratchpad runs names no port either, and unlike react-scripts it has no
# hot-reload socket: judged by what it listens on, and static (never idle-reaped) until its owner ended.
PROXY_PORT = -2
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
# A Claude session's scratchpad and task directories: /tmp/claude-<uid>/<project>/<session id>/...
SCRATCH = re.compile(r"/claude-\d+/[^/\s]+/([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})(?:/|\s|$)")
SERVER_ROOTS = {"node", "bun", "deno", "npm", "npx", "python", "python3", "zsh", "bash", "sh"}
RUNTIMES = {"node", "bun", "deno", "python", "python3"}
SHELLS = {"zsh", "bash", "sh"}
SCRIPT_EXT = (".js", ".mjs", ".cjs", ".ts", ".py", ".sh")
# How long an owner must have been quiet before a missing claim counts as an ended session.
WORKTREE_IDLE_SECONDS = 3 * 86400
TRANSCRIPT_IDLE_SECONDS = 24 * 3600
PROJECTS = Path.home() / ".claude" / "projects"
ESBUILD = re.compile(r"/node_modules/(?:\.bin|(?:.+/)?@esbuild/[^/]+/bin)/esbuild$")


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


def scratch_sessions(where, commands):
    """Session ids named by a /tmp/claude-<uid>/<project>/<id>/ path: where, then each command."""
    found = set()
    if where:
        found.update(SCRATCH.findall(f"{where}/"))
    for text in commands:
        found.update(SCRATCH.findall(f"{text} "))
    return found


def script_paths(command):
    """Absolute script paths a command line runs: the first word after a runtime (`node
    /x/proxy.mjs`), where the line starts with the runtime or with a shell that runs it
    (`zsh -c '... eval node /x/proxy.mjs'`). Any other argument is not the script."""
    tokens = [t.strip("'\"") for t in command.split()]
    shell = bool(tokens) and os.path.basename(tokens[0]) in SHELLS
    found = []
    for i, token in enumerate(tokens):
        if os.path.basename(token) not in RUNTIMES or not (i == 0 or shell):
            continue
        script = next((t for t in tokens[i + 1:] if t and not t.startswith("-")), "")
        if script.startswith("/") and script.endswith(SCRIPT_EXT):
            found.append(script)
    return found


def scratch_server(rows, ports, members):
    """Whether a tree that is not a known launcher is a server a session's scratchpad started:
    something in it listens and its root runs a script from a scratchpad. Only the root's
    script counts: a tool that merely has a scratchpad path among its arguments, or a child
    that does, is not owned by that session. The root must be a runtime or a shell: a tmux or
    screen server keeps every pane in its tree, and one pane's path must not condemn the rest."""
    command = rows[members[0]][4]
    args = command.split()
    return (bool(args) and os.path.basename(args[0]) in SERVER_ROOTS
            and any(ports.get(pid) for pid in members)
            and bool(scratch_sessions(None, script_paths(command))))


SCRIPT_BYTES = 64 * 1024


def script_text(path, cache=None):
    """The first SCRIPT_BYTES of a script a command line names, only when it lies under a
    session scratchpad or a linked worktree; "" otherwise. Returns (text, worktree or None).
    `cache` (a dict kept for the run) holds each file and each directory's worktree, so one
    `git` call serves every process that names the directory."""
    cache = {} if cache is None else cache
    if ("script", path) in cache:
        return cache[("script", path)]
    result = ("", None)
    try:
        if os.path.isfile(path):
            owned = SCRATCH.search(path) is not None
            directory = Path(path).parent
            worktree = None
            if not owned:
                if ("wtdir", directory) not in cache:
                    cache[("wtdir", directory)] = linked_worktree(directory)
                worktree = cache[("wtdir", directory)]
            if owned or worktree is not None:
                with open(path, "rb") as f:
                    result = (f.read(SCRIPT_BYTES).decode(errors="replace"), worktree)
    except OSError:
        pass
    cache[("script", path)] = result
    return result


def forwarder(rows, ports, members, targets, janitor, claims, claim_timeout):
    """The pid of a listening process outside the tree, owned by a live session or worktree
    claim, that names one of the target ports in its command line or its script; None if none.
    Live means what the janitor's --claims says is live or still inside its grace period: it
    reports a running `claude` whose command line lacks its session id (every one started
    without --resume) as RECENT only, and 7f116ef5's two proxies, running for 2 days, were
    exactly that. The owner is read from the script it runs, as for a tree; one nobody can
    attribute vouches for nothing, and a failed claim check counts as live."""
    if not targets:
        return None
    named = re.compile(r"(?<!\d)(?:%s)(?!\d)" % "|".join(str(t) for t in sorted(targets)))
    for pid, held in sorted(ports.items()):
        if not held or pid in members or pid not in rows:
            continue
        command = rows[pid][4]
        scripts = script_paths(command)
        owners, text = set(scratch_sessions(None, scripts)), command
        for script in scripts:
            body, worktree = script_text(script, claims)
            text += "\n" + body
            if worktree is not None:
                owners.add(worktree)
        if not owners or not named.search(text):
            continue
        for key in sorted(owners, key=str):
            if ("level", key) not in claims:
                claims[("level", key)] = claim_level(key, janitor, claim_timeout)
            if claims[("level", key)] >= 1:
                return pid
    return None


def listened_ports(ports, members, port):
    return {p for pid in members for p in ports.get(pid, ())} | ({port} if port > 0 else set())


def worktree_idle(worktree, now):
    """Seconds since anything touched the worktree, or None when git cannot say: HEAD's
    commit time, the stack's files, and every file `git status` names. The same evidence as
    local_stack.sh's last_activity, read the same way: not the index (status rewrites it), no
    optional locks, and what the stack itself keeps is counted once, by its own files."""
    def git(*args):
        return subprocess.run(["git", "-C", str(worktree), "--no-optional-locks", *args],
                              capture_output=True, text=True, timeout=120, check=True).stdout
    try:
        newest = float(git("log", "-1", "--format=%ct").strip() or 0)
        status = subprocess.run(["git", "-C", str(worktree), "--no-optional-locks", "status", "--porcelain", "-z"],
                                capture_output=True, text=True, timeout=120, check=True).stdout.split("\0")
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    names = [worktree / ".local-stack.env", worktree / ".local-stack" / "api.pid"]
    skip = False
    for entry in status:
        if skip:                      # a rename's old name
            skip = False
            continue
        if len(entry) < 4:
            continue
        skip = entry[0] in "RC"
        if not re.match(r"\.local-stack(\.env|/)", entry[3:]):
            names.append(worktree / entry[3:])
    for name in names:
        try:
            newest = max(newest, name.stat().st_mtime)
        except OSError:
            continue
    return max(0.0, now - newest)


def transcripts_ended(sids, now):
    """The session ids among sids whose transcript was written more than TRANSCRIPT_IDLE_SECONDS
    ago and is held open by no process. A session with no transcript, one with several, or an
    lsof that cannot answer is not proven: the caller keeps it."""
    files = {}
    for sid in sids:
        found = list(PROJECTS.glob(f"*/{sid}.jsonl"))
        try:
            if len(found) == 1 and now - found[0].stat().st_mtime >= TRANSCRIPT_IDLE_SECONDS:
                files[sid] = found[0]
        except OSError:
            continue
    if not files:
        return set()
    try:
        probe = subprocess.run(["lsof", "-nP", "-Fpn", "--", *map(str, files.values())],
                               capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return set()
    if probe.returncode not in (0, 1):
        return set()
    held = {line[1:] for line in probe.stdout.splitlines() if line.startswith("n")}
    return {sid for sid, path in files.items() if str(path) not in held}


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


def stale_serves():
    """Backend ports a `tailscale serve` handler still forwards to that nothing listens on,
    sorted. Only a list: the serve configuration is never changed from here. Empty when
    either probe cannot answer, because a failed probe is not a stale entry."""
    forwarded, live = served_ports(), listening()
    if not forwarded or not live:
        return []
    return sorted(forwarded - {p for held in live.values() for p in held})


def published(rows, ports, members, worktree, tailscale=True):
    """Why the tree is published to someone, or None. Anything unreadable is a reason.
    tailscale=False leaves the `tailscale serve` entries out: a stale entry is what kept
    abandoned servers for weeks, so the caller drops it once the owner has ended."""
    # An argument that IS the worktree, not argv[0] and not a path inside it: the local
    # stack's own API runs from a binary in the worktree, and a sibling dev server's child
    # runs a script under it (node <wt>/node_modules/...), and neither publishes anything.
    for pid, held in ports.items():
        if worktree is None or not held or pid in members or pid not in rows:
            continue
        if any(arg.rstrip("/") == str(worktree) for arg in rows[pid][4].split()[1:]):
            return f"published by listening pid {pid}, which names its worktree"
    if not tailscale:
        return None
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


def claim_level(key, janitor, timeout=900):
    """What the janitor's `--claims <key>` says about a worktree path or a session id: 2 when
    a live session claims it or the janitor cannot say, 1 when only a session still inside its
    grace period does, 0 when none does. 0 is only the absence of a claim."""
    try:
        # Minutes, not seconds: it reads every live and recent transcript, and took 5m11s
        # under load on 2026-10-05. A timeout is a claim, so too short keeps everything.
        probe = subprocess.run([str(janitor), "--claims", str(key)], capture_output=True,
                               text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return 2
    if probe.returncode != 0 or not probe.stdout.startswith("CLAIMS"):
        return 2
    own = os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("CODEX_THREAD_ID")
    level = 0
    for line in probe.stdout.splitlines():
        kind, _, rest = line.partition("\t")
        if kind not in ("LIVE", "LIVE_TOOL", "RECENT", "RECENT_TOOL"):
            continue
        # The session's own mentions of a path are what running this from a session adds, so those
        # are left out; its own record is not: a session is the owner of the servers it started.
        if own and kind.endswith("_TOOL") and f"id={own}\t" in rest + "\t":
            continue
        if kind.startswith("LIVE"):
            return 2
        left = re.search(r"(?:^|\t)remaining=(\d+)s(?:\t|$)", rest)
        if left is None or int(left.group(1)) > 0:   # no readable grace left: it still claims
            level = 1
    return level


def claimed(worktree, janitor, timeout=900):
    """True when a live session claims the worktree, or the janitor cannot say."""
    return claim_level(worktree, janitor, timeout) == 2


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
    to any port it listens on), or connections are unreadable. idle: a hot-reload server
    listens, unused. static: a server without hot reload (`next start`, `vite preview`)
    listens and nothing is connected right now; it holds no connection between requests, so
    one empty moment is no proof it is unused and only an ended owner lets it be stopped."""
    listens = {p for pid in members for p in ports.get(pid, ())}
    if port in (ANY_PORT, PROXY_PORT):
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
    clients = connected()
    if clients is None:
        return "serving", "kept: connections unreadable"
    used = sorted(used_on & clients)
    if used:
        return "serving", f"has connections on {used[0]}"
    if not hot and port != ANY_PORT:
        return "static", f"listens on {min(used_on)}; no hot-reload socket to judge use by"
    return "idle", f"listens on {min(used_on)} with no connection"


def owners_ended(worktree, sessions, claims, now):
    """Whether every owner of the tree is proven gone, not only unclaimed: the worktree idle
    for WORKTREE_IDLE_SECONDS, each session's transcript quiet and closed. Cached for the run."""
    if worktree is not None:
        if ("idle", worktree) not in claims:
            claims[("idle", worktree)] = worktree_idle(worktree, now)
        idle = claims[("idle", worktree)]
        if idle is None or idle < WORKTREE_IDLE_SECONDS:
            return False
    unknown = sorted(sid for sid in sessions if ("ended", sid) not in claims)
    if unknown:
        proven = transcripts_ended(set(unknown), now)
        for sid in unknown:
            claims[("ended", sid)] = sid in proven
    return all(claims[("ended", sid)] for sid in sessions)


def judge(rows, ports, root, min_age, now, janitor, claims=None, claim_timeout=900,
          state_dir=STATE_DIR, idle_hours=IDLE_HOURS):
    """(verdict, reason, worktree, members, port, state, ended); verdict is reap, serving or
    keep, state is serving()'s, so the recheck can tell what changed, and ended says the
    owning session is gone, so the recheck leaves `tailscale serve` out as judge did."""
    ppid, _, _, lstart, command = rows[root]
    members = tree(rows, root)
    port = launcher(command)
    if port is None and scratch_server(rows, ports, members):
        port = PROXY_PORT
    if not port:
        return "keep", "no port on the command line", None, [], port, None, False
    begun = started(lstart)
    if begun is None or now - begun < min_age:
        return "keep", "younger than the minimum age", None, [], port, None, False
    state, why = serving(ports, members, port, rows=rows)
    if state == "serving":
        forget_idle(state_dir, root, begun)
        return "serving", why, None, members, port, state, False
    groups = {rows[pid][1] for pid in members}
    if any(AGENT.search(row[4]) and (pid in members or row[1] in groups)
           for pid, row in rows.items()):
        return "keep", "an agent process is in the tree or its process group", None, [], port, state, False
    where = cwd(root)
    worktree = linked_worktree(where) if where else None
    sessions = scratch_sessions(where, script_paths(command))
    if worktree is None and not sessions:
        return "keep", "not in a linked worktree or a session scratchpad", None, [], port, state, False
    # One janitor --claims call per owner per run: it reads every live transcript, and
    # duplicates share their worktree or session.
    claims = {} if claims is None else claims
    level = 0
    for key in ([worktree] if worktree else []) + sorted(sessions):
        if ("level", key) not in claims:
            claims[("level", key)] = claim_level(key, janitor, claim_timeout)
        level = max(level, claims[("level", key)])
    if level == 2:
        return ("keep", "a live session claims the worktree or scratchpad, or the claim check failed",
                worktree, [], port, state, False)
    ended = level == 0 and owners_ended(worktree, sessions, claims, now)
    published_by = published(rows, ports, members, worktree, tailscale=not ended)
    if published_by:
        # Unused starts counting again when the publisher goes, not from before it came.
        forget_idle(state_dir, root, begun)
        return "serving", published_by, worktree, members, port, "serving", False
    idle = 0
    if state == "static" and not ended:
        forget_idle(state_dir, root, begun)
        return "serving", why, worktree, members, port, state, False
    if state == "idle" and not ended:
        idle = idle_for(state_dir, root, begun, now)
        if idle < idle_hours * 3600:
            return "keep", f"{why}; unused for {idle / 3600:.1f}h of the {idle_hours}h it must be", worktree, [], port, state, False
    # Decided: stop it. Unless a live session's proxy forwards to it.
    front = forwarder(rows, ports, members, listened_ports(ports, members, port), janitor, claims, claim_timeout)
    if front:
        forget_idle(state_dir, root, begun)
        return "serving", f"forwarded to by live pid {front}", worktree, members, port, "serving", False
    if state == "unserved":
        return "reap", why, worktree, members, port, state, ended
    if ended:
        return "reap", f"{why}; its session ended", worktree, members, port, state, True
    return "reap", f"{why} for {idle / 3600:.1f}h", worktree, members, port, state, False


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
    A member on the never-kill list, or descended from one, is never signalled: it is named
    with a `never-kill <pid>` line, read from the same listing the start times come from.
    """
    denied = set()
    spared = set()

    def alive_same():
        now = processes() or {}
        parents = {p: row[0] for p, row in now.items()}
        chosen = []
        for p in members:
            if p not in now or now[p][3] != snapshot[p] or p in denied:
                continue
            if never_kill(p, parents):
                if p not in spared:
                    spared.add(p)
                    print(f"never-kill {p}")
                continue
            chosen.append(p)
        return chosen

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
        if ppid != 1 or (launcher(command) is None and not scratch_server(rows, ports, tree(rows, root))):
            continue
        verdict, reason, worktree, members, port, state, ended = judge(
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
        if (now_state != state or published(fresh_rows, fresh, members, worktree, tailscale=not ended)
                or forwarder(fresh_rows, fresh, members, listened_ports(fresh, members, port),
                             janitor, claims, claim_timeout)
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
    for port in stale_serves():
        print(f"STALE-SERVE backend port {port} (nothing listens; listed only, the serve config is untouched)")
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
