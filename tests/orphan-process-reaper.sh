#!/usr/bin/env bash
# shell/orphan-process-reaper.py stops a process only on positive evidence its owning Claude Code
# session is dead (or, for a live session's own Bash-tool shell, that it waited past a bound).
#
# Nothing here can signal a real process: `ps`, `lsof` and `launchctl` are fixture scripts on PATH,
# `kill` is a recording function handed to the reaper, and fixture pids (7000000+) are above any
# reachable pid_max. HOME is a sandbox, so the session registry, the roster, the transcripts and
# the leases are fixtures too. Every case asserts on what WOULD have been signalled.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export OPR_SOURCE="${OPR_SOURCE:-$ROOT_DIR/shell/orphan-process-reaper.py}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cc-opr.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export OPR_SANDBOX="$SANDBOX"
mkdir -p "$SANDBOX/bin" "$SANDBOX/fake" "$SANDBOX/home"

# The fixture commands read what the case wrote under $OPR_SANDBOX/fake.
cat > "$SANDBOX/bin/ps" <<'FAKE'
#!/usr/bin/env bash
F="$OPR_SANDBOX/fake"
case " $* " in
  *" eww "*) cat "$F/ps.env" ;;
  *) cat "$F/ps.table" ;;
esac
FAKE
cat > "$SANDBOX/bin/lsof" <<'FAKE'
#!/usr/bin/env bash
F="$OPR_SANDBOX/fake"
case " $* " in
  *" -sTCP:LISTEN "*) cat "$F/lsof.listen" ;;
  *" -sTCP:ESTABLISHED "*) cat "$F/lsof.established" ;;
  *" -d cwd "*)
    pid=""; prev=""
    for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
    if [ -f "$F/cwd.$pid" ]; then printf 'p%s\nn%s\n' "$pid" "$(cat "$F/cwd.$pid")"; else exit 1; fi ;;
  *) exit 1 ;;
esac
FAKE
cat > "$SANDBOX/bin/launchctl" <<'FAKE'
#!/usr/bin/env bash
cat "$OPR_SANDBOX/fake/launchctl.out"
FAKE
chmod +x "$SANDBOX/bin/ps" "$SANDBOX/bin/lsof" "$SANDBOX/bin/launchctl"
export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export CC_NEVER_KILL_PIDS=""

python3 -I - <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

SOURCE = os.environ["OPR_SOURCE"]
SANDBOX = Path(os.environ["OPR_SANDBOX"])
FAKE = SANDBOX / "fake"
HOME = Path(os.environ["HOME"])
LIVE = "11111111-1111-4111-8111-111111111111"      # a session in ~/.claude/sessions with a live pid
DAEMON = "22222222-2222-4222-8222-222222222222"    # a session only the daemon roster lists
DEAD = "33333333-3333-4333-8333-333333333333"      # a session that ended: transcript, no registry
DEAD2 = "44444444-4444-4444-8444-444444444444"
FRESH = "55555555-5555-4555-8555-555555555555"     # not live, but its transcript was written minutes ago
NOREC = "66666666-6666-4666-8666-666666666666"     # an id nothing on this host has a record of
SECRET = "hunter2-do-not-log"
HOUR, MIN = 3600, 60
failures = 0


def ok(msg):
    print(f"ok - {msg}")


def bad(msg):
    global failures
    failures += 1
    print(f"not ok - {msg}")


def check(cond, msg):
    ok(msg) if cond else bad(msg)


if not Path(SOURCE).exists():
    bad(f"{SOURCE} does not exist")
    sys.exit(1)
spec = importlib.util.spec_from_file_location("orphan_process_reaper", SOURCE)
opr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(opr)

NOW = time.time()


def lstart(age):
    return time.strftime("%a %b %d %H:%M:%S %Y", time.localtime(NOW - age))


class World:
    """One fixture host: processes, their environment's session id, the registry, the roster."""

    def __init__(self):
        self.rows = {}
        self.env = {}
        self.sent = []
        for p in FAKE.iterdir():
            p.unlink()
        for d in ("sessions", "daemon", "projects", "jobs"):
            subprocess.run(["rm", "-rf", str(HOME / ".claude" / d)], check=True)
            (HOME / ".claude" / d).mkdir(parents=True)
        subprocess.run(["rm", "-rf", str(HOME / ".cache")], check=True)
        (HOME / ".cache/stima-api/resource-locks/leases").mkdir(parents=True)
        (FAKE / "launchctl.out").write_text("PID\tStatus\tLabel\n")
        (FAKE / "lsof.listen").write_text("p7999000\nn*:22\n")                 # a host always has listeners
        (FAKE / "lsof.established").write_text("n127.0.0.1:443->127.0.0.1:55555\n")  # and connections
        self.alive = set()
        self.roster = {}

    def proc(self, pid, ppid, age, command, sid=None, extra_env=""):
        self.rows[pid] = (ppid, age, command)
        env = f"HOME=/x PATH=/usr/bin {extra_env}"
        if sid:
            env += f" CLAUDE_CODE_SESSION_ID={sid}"
        self.env[pid] = env
        self.alive.add(pid)

    def session(self, pid, sid, kind="interactive"):
        """A live claude process registered the way Claude Code registers it."""
        self.proc(pid, 1, 3 * 86400, "/Users/x/.local/share/claude/versions/2.1.323 --resume", sid)
        (HOME / ".claude/sessions" / f"{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": sid, "kind": kind}))

    def transcript(self, sid, age):
        path = HOME / ".claude/projects/-x" / f"{sid}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{}\n")
        os.utime(path, (NOW - age, NOW - age))

    def write(self):
        lines = []
        for pid, (ppid, age, command) in sorted(self.rows.items()):
            lines.append(f"{pid} {ppid} {pid} 1024 {lstart(age)} {command}")
        (FAKE / "ps.table").write_text("\n".join(lines) + "\n")
        (FAKE / "ps.env").write_text("\n".join(f"{pid} {self.rows[pid][2]} {env}" for pid, env in sorted(self.env.items())) + "\n")
        if self.roster:
            (HOME / ".claude/daemon/roster.json").write_text(json.dumps({"supervisorPid": 7000900, "workers": self.roster}))

    def run(self, apply=True, **kw):
        self.write()
        self.sent = []

        def send(pid, sig):
            self.sent.append((pid, sig))

        buf = io.StringIO()
        kw.setdefault("self_pid", 7999999)
        kw.setdefault("janitor", str(SANDBOX / "janitor-free.sh"))
        with contextlib.redirect_stdout(buf):
            result = opr.reap(apply=apply, now=NOW, send=send, sleep=lambda s: None, home=HOME,
                              alive=lambda pid: pid in self.alive, **kw)
        self.out = buf.getvalue()
        return result

    def stopped(self):
        return [pid for pid, sig in self.sent if sig == signal.SIGTERM]


def write_janitor(name, body):
    path = SANDBOX / name
    path.write_text(f"#!/usr/bin/env bash\n{body}\n")
    path.chmod(0o755)


write_janitor("janitor-free.sh", 'echo CLAIMS')
write_janitor("janitor-live.sh", 'printf "CLAIMS\\nLIVE\\tid=x\\n"')


def tree(w, sid, root=7000010, age=2 * 86400, root_command="/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'cd /w && npx next dev --port 4165'"):
    """The leftover shape of 2026-11-18: a wrapper shell with no environment id, an npm exec, a node child."""
    w.proc(root, 1, age, root_command)
    w.proc(root + 1, root, age, "npm exec next dev --port 4165")
    w.proc(root + 2, root + 1, age, "node /w/node_modules/.bin/next dev --port 4165", sid)
    return root


# 1. A dead owner's whole tree is stopped, children first, with SIGTERM only.
w = World(); w.transcript(DEAD, 2 * 86400); tree(w, DEAD)
w.run()
check(w.stopped() == [7000012, 7000011, 7000010], f"dead owner: the tree is stopped children first (got {w.stopped()})")
check(all(sig == signal.SIGTERM for _, sig in w.sent), "dead owner: SIGTERM only, never SIGKILL")
check("STOPPED pid=7000010" in w.out, "dead owner: one STOPPED line per tree")
check(DEAD[:8] in w.out and DEAD not in w.out, "dead owner: the line names the session by its first 8 characters")

# 2. A live owner is kept: registry pid alive, daemon roster, state file.
w = World(); w.session(7000100, LIVE); w.transcript(LIVE, 5 * 86400); tree(w, LIVE)
w.run()
check(w.sent == [] and "KEEP(owner-live)" in w.out, "live owner (session registry): kept")
w = World(); w.transcript(DAEMON, 5 * 86400); tree(w, DAEMON)
w.proc(7000200, 1, 86400, "/x/claude bg-spare --bg-spare /tmp/x.sock")
w.roster = {"abcdef12": {"pid": 7000200, "sessionId": DAEMON, "replPid": 7000201}}
w.run()
check(w.sent == [] and "KEEP(owner-live)" in w.out, "live owner (daemon roster, pid alive): kept")
w = World(); w.transcript(DAEMON, 5 * 86400); tree(w, DAEMON)
w.roster = {"abcdef12": {"pid": 7000200, "sessionId": DAEMON}}   # roster names it, its pid is gone
w.run()
check(w.stopped() == [7000012, 7000011, 7000010], "a roster entry whose pids are dead does not keep a tree")
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
(HOME / ".claude/daemon/roster.json").write_text("{not json")
w.write(); w.sent = []
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    try:
        opr.reap(apply=True, now=NOW, send=lambda p, s: w.sent.append((p, s)), sleep=lambda s: None, home=HOME,
                 alive=lambda pid: pid in w.alive, self_pid=7999999)
    except RuntimeError:
        pass
check(w.sent == [], "an unreadable roster means liveness is unknown: nothing is stopped")

# 3. Unknown owners are kept, and said so.
w = World(); tree(w, None)
w.run()
check(w.sent == [] and "KEEP(unknown-owner)" in w.out, "no environment id, no scratchpad, no marker: kept as unknown-owner")
w = World(); tree(w, NOREC)   # an id nothing on this host has a record of
w.run()
check(w.sent == [] and "KEEP(unknown-owner)" in w.out, "an id with no transcript or job record: kept as unknown-owner")
w = World(); w.transcript(FRESH, 5 * MIN); tree(w, FRESH)
w.run()
check(w.sent == [] and "KEEP(owner-recent)" in w.out, "a transcript written minutes ago: kept")
w = World(); w.transcript(DEAD, 5 * 86400); w.transcript(LIVE, 5 * 86400); w.session(7000100, LIVE)
tree(w, DEAD); w.env[7000011] += f" CLAUDE_CODE_SESSION_ID={LIVE}"
w.run()
check(w.sent == [] , "two owners in one tree, one live: kept")

# 4. The owner by scratchpad path in argv, and by the worktree's marker.
pad = "/private/tmp/claude-501/-Users-x-GitHub-y/%s/scratchpad/p.sh"
w = World(); w.transcript(DEAD, 5 * 86400)
w.proc(7000020, 1, 86400, "/bin/zsh -c until grep -q fetched " + pad % DEAD + "; do sleep 5; done")
w.run()
check(w.stopped() == [7000020], "owner from a scratchpad path in argv (no environment id): dead, stopped")
w = World(); w.session(7000100, LIVE); w.transcript(LIVE, 5 * 86400)
w.proc(7000020, 1, 86400, "/bin/zsh -c until grep -q fetched " + pad % LIVE + "; do sleep 5; done")
w.run()
check(w.sent == [] and "KEEP(owner-live)" in w.out, "owner from a scratchpad path in argv, live: kept")

repo = SANDBOX / "repo"
subprocess.run(["git", "init", "-q", str(repo)], check=True)
subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i"], check=True)
wt = SANDBOX / "wt"
subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "-b", "b", str(wt)], check=True)
gitdir = subprocess.run(["git", "-C", str(wt), "rev-parse", "--absolute-git-dir"], capture_output=True, text=True, check=True).stdout.strip()
Path(gitdir, "claude-task-worktree").write_text(DEAD + "\n")
w = World(); w.transcript(DEAD, 5 * 86400)
w.proc(7000030, 1, 86400, "/usr/local/bin/python3 -m http.server 8790")
(FAKE / "cwd.7000030").write_text(str(wt))
w.run()
check(w.stopped() == [7000030], "owner from the worktree's task marker, no live claim: dead, stopped")
w = World(); w.transcript(DEAD, 5 * 86400)
w.proc(7000030, 1, 86400, "/usr/local/bin/python3 -m http.server 8790")
(FAKE / "cwd.7000030").write_text(str(wt))
w.run(janitor=str(SANDBOX / "janitor-live.sh"))
check(w.sent == [] and "KEEP(owner-claimed)" in w.out, "the marker's creator is dead but a live session claims the worktree: kept")

# 5. A live session's own Bash-tool shell that waits.
snap = "/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-9.sh && setopt NO_EXTENDED_GLOB && eval '%s' < /dev/null"
loop = "until gh run view 1 | grep -q completed; do sleep 30; done"
tight = 'until grep -q "" /dev/null; do :; done'


def shell(w, pid, age, body, parent=7000100, sid=LIVE):
    w.proc(pid, parent, age, snap % body, sid)


w = World(); w.session(7000100, LIVE)
shell(w, 7000040, 25 * HOUR, loop); shell(w, 7000041, 2 * MIN, loop)
shell(w, 7000042, 25 * HOUR, "npm test -- --watchAll=false")        # long, but not a wait loop
shell(w, 7000043, 23 * HOUR, loop)                                  # inside the bound
shell(w, 7000044, 11 * MIN, tight); shell(w, 7000045, 2 * MIN, tight)
shell(w, 7000046, 11 * MIN, loop)                                  # sleeps: the 6 h bound applies
shell(w, 7000047, 11 * MIN, "while true; do\\012  :\\012done")   # ps shows a newline as \012
w.proc(7000048, 7000040, 25 * HOUR, "sleep 30")
w.run()
check(sorted(w.stopped()) == [7000040, 7000044, 7000047, 7000048],
      f"wait loops over their bound are stopped (got {sorted(w.stopped())})")
check(7000041 not in w.stopped() and 7000045 not in w.stopped(), "a 2-minute-old wait loop is kept, tight or not")
check(7000042 not in w.stopped() and 7000043 not in w.stopped() and 7000046 not in w.stopped(),
      "a long non-loop, a loop inside 24 h and a sleeping loop of 11 minutes are kept")
import inspect
check(inspect.signature(opr.reap).parameters["loop_hours"].default == 24 and "--loop-hours\", type=float, default=24" in Path(SOURCE).read_text(),
      "the wait-loop bound defaults to 24 hours, in reap and on the command line")
check(w.stopped().index(7000048) < w.stopped().index(7000040), "the loop's child goes before the loop")
check(7000100 not in w.stopped(), "the session's own claude process is never signalled")
w.run(loop_hours=30)
check(7000040 not in w.stopped(), "the bound is configurable: a 25 h loop is kept under a 30 h bound")
w = World(); w.session(7000100, LIVE); w.proc(7000101, 1, 86400, "/bin/zsh -c x", None)
shell(w, 7000049, 25 * HOUR, loop, parent=7000101)                  # parent is not a claude process
w.run()
check(7000049 not in w.stopped(), "a snapshot shell whose parent is not the live session's claude process is not judged as a tool shell")
w = World(); w.session(7000100, LIVE); shell(w, 7000049, 25 * HOUR, loop, sid=DEAD2)
w.run()
check(7000049 not in w.stopped(), "a tool shell whose own session id differs from its parent's is kept")

# 5b. A loop that already ended is not a stuck loop: a long-lived child keeps the shell.
started = "npm run dev & " + loop + "; wait"
w = World(); w.session(7000100, LIVE)
shell(w, 7000060, 25 * HOUR, started); w.proc(7000061, 7000060, 2 * HOUR, "node server.js")
w.run()
check(w.sent == [] and "KEEP(long-child)" in w.out, "a wait loop shell with a 2 h old node child is kept as long-child")
w = World(); w.session(7000100, LIVE)
shell(w, 7000060, 25 * HOUR, loop); w.proc(7000061, 7000060, 20, "sleep 30")
w.run()
check(sorted(w.stopped()) == [7000060, 7000061], "a 20 s old sleep child does not keep a stuck loop")
w = World(); w.session(7000100, LIVE)
shell(w, 7000060, 25 * HOUR, loop); w.proc(7000061, 7000060, 25 * HOUR, "tail -f /tmp/log")
w.run()
check(sorted(w.stopped()) == [7000060, 7000061], "a 25 h old tail child does not keep a stuck loop")
w = World(); w.session(7000100, LIVE)
shell(w, 7000060, 25 * HOUR, loop); w.proc(7000061, 7000060, 2 * HOUR, "sleep 30")
w.run()
check(sorted(w.stopped()) == [7000060, 7000061], "a sleep child is never long-lived, whatever its age")
w = World(); w.session(7000100, LIVE)
shell(w, 7000060, 25 * HOUR, loop); w.proc(7000061, 7000060, 2 * HOUR, "node server.js")
w.write()
# a start time that cannot be read counts as long-lived
table = (FAKE / "ps.table").read_text().replace(lstart(2 * HOUR), "Xxx Xxx 99 99:99:99 9999")
(FAKE / "ps.table").write_text(table)
buf = io.StringIO(); w.sent = []
with contextlib.redirect_stdout(buf):
    opr.reap(apply=True, now=NOW, send=lambda p, s: w.sent.append((p, s)), sleep=lambda s: None, home=HOME,
             alive=lambda pid: pid in w.alive, self_pid=7999999, janitor=str(SANDBOX / "janitor-free.sh"))
check(w.sent == [], "a child whose start time cannot be read counts as long-lived")
w = World(); w.session(7000100, LIVE)
shell(w, 7000062, 11 * MIN, tight)
w.run()
check(w.stopped() == [7000062], "a spin loop with no child still gets the verdict")
w = World(); w.session(7000100, LIVE)
shell(w, 7000062, 11 * MIN, "until pg_isready -h localhost; do :; done && go run main.go"); w.proc(7000063, 7000062, 2 * HOUR, "node server.js")
w.run()
check(w.sent == [] and "KEEP(long-child)" in w.out, "a spin-shaped line whose loop ended and runs a 2 h old child is kept as long-child")

# 5c. Verdict 2 applies the lease and serving keeps of verdict 1, spin or not.
for body, age, what in ((loop, 25 * HOUR, "wait loop"), (tight, 11 * MIN, "spin loop")):
    w = World(); w.session(7000100, LIVE)
    shell(w, 7000070, age, body)
    (HOME / ".cache/stima-api/resource-locks/leases/x.abc.lease").write_text(json.dumps(
        {"resource": "next", "detached": True, "owner_pid": 7000070, "started": NOW - 100, "ttl": None, "worktree": "/w"}))
    w.run()
    check(w.sent == [] and "KEEP(lease)" in w.out, f"a {what} shell holding a live lease is kept")
    w = World(); w.session(7000100, LIVE)
    shell(w, 7000070, age, body)
    (FAKE / "lsof.listen").write_text("p7000070\nn*:4165\n")
    (FAKE / "lsof.established").write_text("n127.0.0.1:55555->127.0.0.1:4165\n")
    w.run()
    check(w.sent == [] and "KEEP(serving)" in w.out, f"a {what} shell listening with a connection is kept")

# 5d. The log carries the tool's name, and a tool shell's eval text with credentials masked.
w = World(); w.session(7000100, LIVE)
shell(w, 7000071, 25 * HOUR, "until curl --token eyJabc.def.ghi -s x; do sleep 5; done")
shell(w, 7000072, 25 * HOUR, 'until curl -H "Authorization: Bearer abc123tok" x; do sleep 5; done')
shell(w, 7000073, 25 * HOUR, "until psql postgres://dbuser:pw0rd@host/db -c x; do sleep 5; done")
w.proc(7000074, 1, 3 * 86400, "/usr/bin/python3 -m http.server 8790 --password hunter2", DEAD)
w.transcript(DEAD, 5 * 86400)
w.run(apply=False)
check(all(secret not in w.out for secret in ("eyJabc", "abc123tok", "pw0rd", "hunter2")),
      "the log carries no --token value, Bearer token, URL password or --password value")
check("until curl" in w.out and "until psql" in w.out and "zsh eval 'until" in w.out and "cmd='python3'" in w.out,
      "a tool shell logs its basename and the start of its eval text; any other process only its basename")

# 5e. Launchd jobs, whatever their label; unowned leases; a shell and an unshaped root.
w = World(); w.transcript(DEAD, 5 * 86400)
w.proc(7000080, 1, 3 * 86400, "node /x/chrome-launcher.js"); w.proc(7000081, 7000080, 3 * 86400, "node /x/h.js", DEAD)
(FAKE / "launchctl.out").write_text("PID\tStatus\tLabel\n7000080\t0\tapplication.com.google.Chrome.1\n")
w.run()
check(w.sent == [] and "KEEP(protected: launchd job application.com.google.Chrome.1)" in w.out,
      "a tree whose root is a launchd job of any label is kept, the reason naming the label")
lease = HOME / ".cache/stima-api/resource-locks/leases/x.abc.lease"
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
lease.write_text(json.dumps({"resource": "next", "detached": True, "owner_pid": None, "ttl": 3600, "started": NOW - 100}))
w.run()
check(w.sent == [] and "KEEP(lease)" in w.out, "a live lease with no owner pid, inside its ttl, keeps every dead-owner tree")
lease.write_text(json.dumps({"resource": "next", "detached": True, "owner_pid": None, "ttl": 3600, "started": NOW - 7200}))
w.run()
check(w.stopped() == [7000012, 7000011, 7000010], "the same lease past its ttl does not")
w = World(); w.transcript(DEAD, 5 * 86400)
w.proc(7000090, 1, 3 * 86400, "/usr/libexec/shared-helper --daemon"); w.proc(7000091, 7000090, 3 * 86400, "/x/native-host", DEAD)
w.run()
check(w.sent == [] and "7000090" not in w.out, "a root that is not shaped like a Claude-started tree is not judged and prints nothing")
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
(FAKE / "cwd.7000010").write_text(str(wt))
w.run(janitor=str(SANDBOX / "janitor-live.sh"))
check(w.sent == [] and "KEEP(owner-claimed)" in w.out, "a dead environment owner whose root runs in a worktree a live session claims: kept")
w.run()
check(w.stopped() == [7000012, 7000011, 7000010], "the same worktree with no claim: stopped")

# 6. Protected families, kept even when the owner is dead and when it cannot be resolved.
FAMILIES = {
    "tmux server": ("tmux: server", None),
    "ci runner (launchd label)": ("/bin/bash /opt/x/run-loop.sh", "tech.stima.ci-runner-macos.2"),
    "gce-jit-broker (launchd label)": ("/bin/bash /x/y.sh", "tech.stima.gce-jit-broker.main"),
    "gce-jit-broker (command)": ("/bin/bash /w/ops/ci-runner/gce-jit-broker.sh", None),
    "Runner.Listener": ("/x/actions-runner/bin/Runner.Listener run", None),
    "docker": ("/Applications/Docker.app/Contents/MacOS/com.docker.backend", None),
    "docker CLI": ("docker compose up", None),
    "OrbStack": ("/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper", None),
    "claude daemon": ("/Users/x/.local/bin/claude daemon run --origin transient", None),
    "bg-pty-host": ("/Users/x/.local/bin/claude bg-pty-host --sock /tmp/x", None),
}
for name, (command, label) in FAMILIES.items():
    for sid in (DEAD, None):
        w = World(); w.transcript(DEAD, 5 * 86400)
        w.proc(7000050, 1, 3 * 86400, command, sid)
        w.proc(7000051, 7000050, 3 * 86400, "/bin/sleep 1", sid)
        if label:
            (FAKE / "launchctl.out").write_text(f"PID\tStatus\tLabel\n7000050\t0\t{label}\n")
        w.run()
        check(w.sent == [], f"protected family kept ({name}, owner {'dead' if sid else 'unresolved'})")
w = World(); w.transcript(DEAD, 5 * 86400); w.transcript(DAEMON, 5 * 86400)
w.proc(7000050, 1, 3 * 86400, "/x/helper --serve", DEAD)
w.roster = {"abcdef12": {"pid": 7000050, "sessionId": DAEMON}}
w.run()
check(w.sent == [], "a pid the roster lists as live is kept whatever its environment says")
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
w.run(self_pid=7000011)
check(w.sent == [], "the reaper's own process tree is kept")
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
w.run(keep_pids={7000011})
check(w.sent == [], "a never-kill pid inside the tree keeps the whole tree")

# 7. A detached lease and a connected server keep a tree.
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
(HOME / ".cache/stima-api/resource-locks/leases/next.abc.lease").write_text(json.dumps(
    {"resource": "next", "detached": True, "owner_pid": 7000012, "started": NOW - 100, "ttl": None, "worktree": "/w"}))
w.run()
check(w.sent == [] and "KEEP(lease)" in w.out, "a live detached lease whose owner pid is in the tree keeps it")
w.alive.discard(7000012)
w.run()
check(w.stopped() == [7000012, 7000011, 7000010], "the same lease with a dead owner pid does not")
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
(FAKE / "lsof.listen").write_text("p7000012\nn*:4165\n")
(FAKE / "lsof.established").write_text("n127.0.0.1:55555->127.0.0.1:4165\n")
w.run()
check(w.sent == [] and "KEEP(serving)" in w.out, "a tree something is connected to is kept as serving")
(FAKE / "lsof.established").write_text("n127.0.0.1:443->127.0.0.1:55555\n")
w.run()
check(w.stopped() == [7000012, 7000011, 7000010], "a listening tree nothing is connected to goes")
(FAKE / "lsof.established").write_text("")
w.run()
check(w.sent == [], "connections that cannot be read keep the tree")

# 8. Report mode signals nothing; the environment never reaches the log.
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
w.env[7000012] += f" API_TOKEN={SECRET}"
w.run(apply=False)
check(w.sent == [] and "CANDIDATE pid=7000010" in w.out, "report mode lists the candidate and sends no signal")
check(SECRET not in w.out and "CLAUDE_CODE_SESSION_ID" not in w.out and DEAD not in w.out, "the environment is never written to the log")
w.run(apply=True)
check(SECRET not in w.out and "CLAUDE_CODE_SESSION_ID" not in w.out, "nor in apply mode")
w.write()
cli = subprocess.run([sys.executable, "-I", SOURCE, "report"], capture_output=True, text=True, timeout=120,
                     env={**os.environ, "HOME": str(HOME)})
check(cli.returncode == 0 and "CANDIDATE pid=7000010" in cli.stdout and SECRET not in cli.stdout + cli.stderr,
      f"the command line in report mode lists it and exits 0 (rc={cli.returncode})")
check("orphan processes:" in cli.stdout.splitlines()[-1], "one summary line per run")

# 9. A survivor is reported, not killed; a process that exits is not.
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
w.run()
check("SURVIVOR pid=7000012" in w.out and all(sig == signal.SIGTERM for _, sig in w.sent), "a process still there after the wait is reported as a survivor, never killed")
w.write()


def send_and_exit(pid, sig):
    w.sent.append((pid, sig))
    w.rows.pop(pid, None); w.env.pop(pid, None)
    w.write()


buf = io.StringIO()
w.sent = []
with contextlib.redirect_stdout(buf):
    opr.reap(apply=True, now=NOW, send=send_and_exit, sleep=lambda s: None, home=HOME,
             alive=lambda pid: pid in w.alive, self_pid=7999999, janitor=str(SANDBOX / "janitor-free.sh"))
check("SURVIVOR" not in buf.getvalue() and len(w.sent) == 3, "processes that exited are not reported as survivors")

# 10. A reused pid is not signalled: the start time must still match at the recheck.
w = World(); w.transcript(DEAD, 5 * 86400); tree(w, DEAD)
w.write(); w.sent = []
calls = {"n": 0}
real_processes = opr.processes


def drifting():
    rows = real_processes()
    calls["n"] += 1
    if calls["n"] > 2 and rows and 7000011 in rows:
        row = list(rows[7000011]); row[3] = "Mon Jan 01 00:00:00 2001"; rows[7000011] = tuple(row)
    return rows


opr.processes = drifting
with contextlib.redirect_stdout(io.StringIO()):
    opr.reap(apply=True, now=NOW, send=lambda p, s: w.sent.append((p, s)), sleep=lambda s: None, home=HOME,
             alive=lambda pid: pid in w.alive, self_pid=7999999, janitor=str(SANDBOX / "janitor-free.sh"))
opr.processes = real_processes
check(7000011 not in [p for p, _ in w.sent], "a pid whose start time changed since the scan is not signalled")

print(f"{failures} failure(s)")
sys.exit(1 if failures else 0)
PY
rc=$?
echo "orphan-process-reaper tests rc=$rc"
exit "$rc"
