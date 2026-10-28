#!/usr/bin/env python3
"""Reap finished interactive Claude Code sessions that run in tmux.

A session is reaped only when every gate holds: idle long enough, no background work, done
(a SESSION-DONE line or every claimed issue closed), its worktrees clean and pushed, not
waiting on a person, and not protected. Reaping types /exit at a verified empty prompt
(Stay if the background-task menu appears), kills the tmux session once claude has exited,
then verifies the process tree, tmux session, session file and worktree locks are gone.

Report-only unless the config sets APPLY=1 or --apply is passed.

Shadow verdict (#6477): a kept session that a person would also call finished gets the outcome
`would-close` in the report. It is never acted on: reap() runs only for a session with no keep reason.
"""

import argparse
import calendar
import fcntl
import fnmatch
import glob
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
CONFIG = HOME / ".cc-reaper" / "session-reaper.conf"
DEFAULTS = {
    "APPLY": "0",
    "IDLE_MINUTES": "60",
    "PROTECT": "",  # space-separated fnmatch patterns over the tmux and session names
    "REPOS": "",  # space-separated repository roots; empty: every git repo in ~/GitHub
    "CLOSED_LOG": "~/handoffs/closed-sessions.md",
    "REPORT": "~/.cc-reaper/state/session-reaper-report.md",
    "TRACKING_ISSUE": "",  # owner/repo#N that receives verification failures
    "JANITOR": "~/.cc-reaper/worktree-janitor.sh",
    "WAITING_EXTRA": "",  # extra regex alternatives that mean "waiting on a person"
    "SUBAGENT_QUIET_MINUTES": "30",  # a subagent or workflow transcript written this recently is still running
    "PROMPT_RE": r"\(y/n\)|do you want to proceed|waiting for input|NEEDS_HUMAN",  # on screen: asks a person
    "RELAY_DIR": "",  # pending <issue>-*.json requests for a claimed issue keep the session; empty: off
    "RELAY_MAX_AGE_HOURS": "48",  # an older request no longer counts as pending
    "HANDOFF_ROOT": "",  # a path under it named in the last message must exist; empty: off
    "REAPED_DIR": "~/.cc-reaper/state/reaped",  # one record per reaped tmux name, written before /exit
    "IDLE_LIST_HOURS": "0",  # list idle/shell sessions with no claimed issue idle this long; 0: off
    "IDLE_LIST_FILE": "~/.cc-reaper/state/idle-sessions.md",  # rewritten every sweep with that list
    "IDLE_LIST_INBOX": "",  # a path: append the list once per local day under ## key=IDLE-SESSIONS-<date>; empty: off
    "DONE_INBOX": "~/handoffs/neo-inbox.md",  # a session whose newest header here is DONE (>= IDLE_MINUTES old) is done; empty: off
    "CHECKBY_ORACLE": "/Users/stimaclaw/GitHub/stima-api/scripts/ci/delivery_state.py",  # --json: pending_check_by, due_check
    "CHECKBY_REPO": "theQuert/stima-api",  # the only repo the oracle reads; a claim elsewhere is UNKNOWN (kept)
    "ORACLE_ROOT": "/Users/stimaclaw/GitHub/stima-api",  # checkout whose `scripts/ci/delivery_state.py N --brief` judges an idle session's open claims
    "ORACLE_CACHE_DIR": "~/.cc-reaper/state/oracle-brief",  # one brief per issue, reused for ORACLE_CACHE_MINUTES (GitHub REST budget)
    "ORACLE_CACHE_MINUTES": "10",
    "NEVER_CLOSE": "uiux* homepage*",  # fnmatch over tmux/session names, case-insensitive: never `would-close`
    "IDLE_LIST_EXCLUDE": "",  # space-separated fnmatch patterns over tmux and session names never listed
}
SESSIONS_DIR = HOME / ".claude" / "sessions"
PROJECTS_DIR = HOME / ".claude" / "projects"
MARKER = "claude-task-worktree"
TAIL_BYTES = 4 << 20
EXIT_WAIT_SECONDS = 20
DONE_RE = re.compile(r"(?m)^\W*SESSION-DONE:\s*(.+)$")
DONE_PHRASE_RE = re.compile(r"這個主題(已經)?結束|may be closed", re.I)
WAITING_RE = re.compile(
    r"production-authorization|authoriz|approv|授權|批准|等你|你決定|請確認", re.I
)
# A close line that is not SESSION-DONE: the session says it has no scope left (#6477).
CLOSE_LINE_RE = re.compile(
    r"no open scope|reaper can close|can be (?:closed|reaped)|safe to close|nothing (?:left|open|owed)"
    r"|(?m:^\W*(?:DONE|IDLE-no-scope)\b)", re.I)
BLOCKED_RE = re.compile(r"BLOCKED:#(\d{3,6})")
NAMED_RE = re.compile(r"(?<![\w/])#(\d{3,6})\b")
SOFT_KEEP = ("claim-unknown", "waiting")  # `waiting-keyword` also starts with `waiting`
ISSUE_RE = re.compile(r"(?:^|/)(\d{3,6})(?:-|$)")
PATH_RE = re.compile(r"(?:~|/)[\w./@+-]+")
# Keep reasons added after the first 48 h of live reaping: a row kept only by these is one the
# earlier gates would have reaped, which is what the report-only comparison looks for.
NEW_GATES = ("subagent-active", "handoff-")
BACKGROUND_ONLY = {"status:shell", "shell-child"}
MENU_TEXT = "Exit and stop tasks"
DIALOG_TEXT = ("Enter to confirm", "Esc to cancel")


def load_config(path):
    cfg = dict(DEFAULTS)
    try:
        for line in Path(path).read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return cfg


def run(cmd, timeout=30, cwd=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


# ---------- processes ----------

def ps_table():
    """{pid: (ppid, lstart, command)}; lstart in UTC, the form session files record."""
    env = dict(os.environ, LC_ALL="C", TZ="UTC")
    out = subprocess.run(
        ["ps", "-A", "-o", "pid=,ppid=,lstart=,command="], capture_output=True, text=True, env=env
    ).stdout
    table = {}
    for line in out.splitlines():
        f = line.split(None, 7)
        if len(f) >= 7:
            table[int(f[0])] = (int(f[1]), " ".join(f[2:7]), f[7] if len(f) > 7 else "")
    return table


def descendants(table, root):
    kids, todo = [], [root]
    while todo:
        p = todo.pop()
        for pid, (ppid, start, _) in table.items():
            if ppid == p:
                kids.append((pid, start))
                todo.append(pid)
    return kids


def is_ancestor(table, anc, pid):
    seen = set()
    while pid in table and pid not in seen and pid > 1:
        if pid == anc:
            return True
        seen.add(pid)
        pid = table[pid][0]
    return False


def survivors(table, snapshot):
    return [(pid, start) for pid, start in snapshot if pid in table and table[pid][1] == start]


# ---------- tmux ----------

def tmux(*args):
    return run(["tmux", *args], timeout=10)


def pane_exists(pane):
    # `display -t <missing pane>` exits 0 with empty output, so ask for the id and compare.
    rc, out = tmux("display", "-p", "-t", pane, "#{pane_id}")
    return rc == 0 and out.strip() == pane


def pane_state(pane):
    rc, out = tmux("display", "-p", "-t", pane, "#{pane_id}\t#{session_name}\t#{session_id}\t"
                   "#{pane_pid}\t#{cursor_x}\t#{cursor_y}\t#{window_panes}\t#{session_windows}")
    fields = out.rstrip("\n").split("\t")
    if rc or len(fields) != 8 or fields[0] != pane:
        return None
    _, name, sid, pane_pid, cx, cy, panes, windows = fields
    rc, screen = tmux("capture-pane", "-p", "-t", pane)
    return {"session": name, "session_id": sid, "pane_pid": int(pane_pid), "cx": int(cx),
            "cy": int(cy), "alone": panes == "1" and windows == "1", "screen": screen}


def cursor_line(state):
    lines = state["screen"].split("\n")
    # The prompt glyph is followed by a no-break space.
    return lines[state["cy"]].replace("\xa0", " ").rstrip() if state["cy"] < len(lines) else ""


def foreground(pid):
    """claude owns its terminal: not stopped, and in the tty's foreground process group."""
    rc, stat = run(["ps", "-o", "stat=", "-p", str(pid)])
    return rc == 0 and "+" in stat and "T" not in stat


def vim_mode():
    try:
        return json.loads((HOME / ".claude.json").read_text()).get("editorMode") == "vim"
    except (OSError, ValueError):
        return False


def empty_prompt(state):
    """The cursor sits right after an empty `❯ ` and no dialog or menu is on screen."""
    if any(t in state["screen"] for t in DIALOG_TEXT + (MENU_TEXT,)):
        return False
    return cursor_line(state).startswith("❯") and state["cx"] == 2


# ---------- git ----------

def repo_roots(cfg):
    if cfg["REPOS"]:
        return [Path(os.path.expanduser(r)) for r in cfg["REPOS"].split()]
    return [p.parent for p in sorted((HOME / "GitHub").glob("*/.git")) if p.is_dir()]


def worktrees(cfg):
    out = []
    for repo in repo_roots(cfg):
        for gd in sorted((repo / ".git" / "worktrees").glob("*")):
            try:
                path = Path((gd / "gitdir").read_text().strip()).parent
            except OSError:
                continue
            head = (gd / "HEAD").read_text().strip() if (gd / "HEAD").exists() else ""
            marker = (gd / MARKER).read_text().strip() if (gd / MARKER).exists() else ""
            out.append({"repo": repo, "path": path, "gitdir": gd, "marker": marker,
                        "branch": head.removeprefix("ref: refs/heads/")})
    return out


def worktree_state(wt, cfg):
    """Problems that keep the worktree's owner alive: uncommitted or unpushed work."""
    if not wt["path"].exists():
        return []
    problems = []
    rc, out = run(["git", "-C", str(wt["path"]), "status", "--porcelain"])
    if rc or out.strip():
        problems.append(f"uncommitted:{wt['path'].name}")
    rc, out = run(["git", "-C", str(wt["path"]), "rev-list", "--count", "HEAD", "--not", "--remotes"])
    if rc or out.strip() != "0":
        janitor = os.path.expanduser(cfg["JANITOR"])
        landed = os.access(janitor, os.X_OK) and run([janitor, "--landed", str(wt["path"])], 120)[0] == 0
        if not landed:
            problems.append(f"unpushed:{wt['path'].name}")
    return problems


def gh_repo(repo):
    rc, url = run(["git", "-C", str(repo), "remote", "get-url", "origin"])
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", url.strip())
    return m.group(1) if m else ""


_issue_cache = {}


def issue_state(repo, num):
    key = (repo, num)
    if key not in _issue_cache:
        rc, out = run(["gh", "issue", "view", num, "-R", repo, "--json", "state", "-q", ".state"])
        _issue_cache[key] = out.strip() if rc == 0 else "UNKNOWN"
    return _issue_cache[key]


_checkby_cache = {}


def checkby_state(repo, num, cfg):
    """OPEN when the repo's oracle reports a pending check-by or a due check; UNKNOWN when it cannot say."""
    key = (repo, num)
    if key not in _checkby_cache and repo != cfg["CHECKBY_REPO"]:
        _checkby_cache[key] = "UNKNOWN"  # the oracle would read another repo's issue with this number
    if key not in _checkby_cache:
        oracle = os.path.expanduser(cfg["CHECKBY_ORACLE"])
        root = os.path.dirname(os.path.dirname(os.path.dirname(oracle)))
        rc, out = run(["python3", oracle, str(num), "--json"], 60, cwd=root)
        try:
            if rc != 0:
                raise ValueError(rc)
            d = json.loads(out)
            if isinstance(d, dict) and d.get("state") == "closed":
                d = dict(d, pending_check_by="", due_check="")  # a closed issue's payload has neither key
            pending, due = d["pending_check_by"], d["due_check"]
            if not isinstance(pending, str) or not isinstance(due, str):
                raise ValueError("shape")
            state = "OPEN" if pending or due else "CLEAR"
        except (ValueError, TypeError, KeyError):
            state = "UNKNOWN"
        _checkby_cache[key] = state
    return _checkby_cache[key]


_brief_cache = {}


def oracle_brief(repo, num, cfg, now):
    """`delivery_state.py N --brief` for the claim, cached on disk for ORACLE_CACHE_MINUTES; None when it cannot say."""
    if repo != cfg["CHECKBY_REPO"]:
        return None  # the oracle would read another repo's issue with this number
    key = (repo, str(num))
    if key in _brief_cache:
        return _brief_cache[key]
    cache = Path(os.path.expanduser(cfg["ORACLE_CACHE_DIR"])) / f"{repo.replace('/', '_')}-{num}.json"
    ttl = float(cfg["ORACLE_CACHE_MINUTES"]) * 60
    try:
        d = json.loads(cache.read_text())
        if 0 <= now - d["at"] < ttl and isinstance(d["brief"], str):
            _brief_cache[key] = d["brief"]
            return d["brief"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    root = os.path.expanduser(cfg["ORACLE_ROOT"])
    rc, out = run(["python3", "scripts/ci/delivery_state.py", str(num), "--brief", "--repo", repo], 30, cwd=root)
    brief = out if rc == 0 and out.startswith("delivery #") else None
    if brief is not None:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps({"at": now, "brief": brief}))
        except OSError:
            pass
    _brief_cache[key] = brief
    return brief


BRIEF_STATE_RE = re.compile(r"\Adelivery #\d+: (\w+)")
BRIEF_KIND_RE = re.compile(r"\Adelivery #\d+: [^\n]*? -> (\w+)")
CLAIMANT_RE = re.compile(r"(?m)^\s*claimant:.*?session ([0-9A-Za-z-]+)(?: \(.*?\))?; the step is that session's")
OWNER_END_RE = re.compile(r"\A\s*owner: .+ wakes it; no watcher needed, and the session may end\Z")
CHECKBY_AT_RE = re.compile(r"check-by(?: scheduled for)?:? (\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?)")


def _same_session(a, b):
    return bool(a) and bool(b) and (a.startswith(b) or b.startswith(a))


def classify_claim(brief, sid, now, others=(), mine=()):
    """(`ended`|`owed`|`unknown`, overdue) from one oracle brief for a session that is idle.

    `ended` only on a closed issue, on the oracle's own last line (`owner: ... the session may end`) under a
    `-> wait` header, or when the step is claimed by another LIVE session (`others`: their ids). Check-by text is
    free text from issue comments, so a phrase anywhere else in the brief never ends a claim. The claimant is
    this session's when it is `sid` or a worktree marker this session owns (`mine`: a /clear changes the sid
    but not the marker); an id that is neither mine nor another live session's is `unknown` (kept)."""
    if not brief:
        return "unknown", False
    m = BRIEF_STATE_RE.match(brief)
    k = BRIEF_KIND_RE.match(brief)
    last = brief.rstrip("\n").rsplit("\n", 1)[-1]
    if m and m.group(1).lower() == "closed":
        return "ended", False
    if k and k.group(1) == "wait" and OWNER_END_RE.match(last):
        return "ended", False
    c = CLAIMANT_RE.search(brief)
    if not c or not (k and k.group(1) == "agent"):
        return "unknown", False
    other = c.group(1)
    if _same_session(other, sid) or any(_same_session(other, x) for x in mine):
        pass  # this session's own step
    elif any(_same_session(other, x) for x in others):
        return "ended", False
    else:
        return "unknown", False
    overdue = False
    for at in CHECKBY_AT_RE.findall(brief):
        try:
            tt = calendar.timegm(time.strptime(at[:16], "%Y-%m-%dT%H:%M"))
        except ValueError:
            continue
        overdue = overdue or tt < now
    return "owed", overdue


_claim_cache = {}


def claim_time(repo, num, sid):
    """Epoch of the newest `Claimed by ... session <sid>` comment on the issue; None when unknown."""
    key = (repo, num, sid)
    if key not in _claim_cache:
        rc, out = run(["gh", "issue", "view", str(num), "-R", repo, "--json", "comments",
                       "-q", ".comments"], 60)
        at = None
        try:
            if rc != 0:
                raise ValueError(rc)
            for c in json.loads(out):
                if re.search(r"Claimed by[^\n]*session\s+" + re.escape(sid), c.get("body") or ""):
                    t = calendar.timegm(time.strptime(c["createdAt"], "%Y-%m-%dT%H:%M:%SZ"))
                    at = t if at is None or t > at else at
        except (ValueError, TypeError, KeyError, AttributeError):
            at = None
        _claim_cache[key] = at
    return _claim_cache[key]


INBOX_HEADER_RE = re.compile(r"^## .*?(\w+) · (\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d) TPE · (.+?)\s*$")


def inbox_done(cfg, names, now, claim_at=None):
    """True when the newest inbox header written by one of `names` is DONE and old enough.
    The header must be later than the newest claim (`claim_at()` -> epoch or None; None: not done).
    Only header lines are examined; any read or parse failure means not done."""
    path = cfg.get("DONE_INBOX")
    names = {n for n in names if n}
    if not path or not names:
        return False
    newest = None
    try:
        with open(os.path.expanduser(path), errors="replace") as f:
            for line in f:
                if line.startswith("## ") and " · " in line and line.rstrip().rsplit(" · ", 1)[1] in names:
                    newest = line.rstrip()
    except OSError:
        return False
    m = INBOX_HEADER_RE.match(newest or "")
    if not m or m.group(1) != "DONE":
        return False
    y, mo, d, h, mi = (int(x) for x in m.group(2, 3, 4, 5, 6))
    try:
        at = calendar.timegm((y, mo, d, h, mi, 0, 0, 0, 0)) - 8 * 3600  # Asia/Taipei is UTC+8
    except (ValueError, OverflowError):
        return False
    if now - at < float(cfg["IDLE_MINUTES"]) * 60:
        return False
    claimed = claim_at() if claim_at else None
    return claimed is not None and at > claimed


# ---------- transcript ----------

def transcript_path(sid):
    hits = glob.glob(str(PROJECTS_DIR / "*" / f"{sid}.jsonl"))
    return Path(hits[0]) if hits else None


def blocks(entry):
    c = entry.get("message", {}).get("content")
    return c if isinstance(c, list) else []


CRON_TTL = 7 * 86400  # Claude Code expires a recurring session cron after 7 days


def cron_pending(inp, created, now):
    """Whether a CronCreate can still fire: a one-shot pinned to a date that has passed already fired
    (and nobody calls CronDelete on it), and a recurring one expires CRON_TTL after creation."""
    if str(inp.get("recurring", True)).lower() not in ("false", "0"):
        return now - created < CRON_TTL
    f = str(inp.get("cron", "")).split()
    if len(f) != 5 or not all(x.isdigit() for x in f[:4]):
        return True  # not a pinned date: count it, as before
    year = time.localtime(created).tm_year
    at = time.mktime((year, int(f[3]), int(f[2]), int(f[1]), int(f[0]), 0, 0, 0, -1))
    if at < created:  # a pinned date earlier in the year than the creation means next year
        at = time.mktime((year + 1, int(f[3]), int(f[2]), int(f[1]), int(f[0]), 0, 0, 0, -1))
    return at > now - 120


def ts(entry):
    try:
        return calendar.timegm(time.strptime(entry["timestamp"][:19], "%Y-%m-%dT%H:%M:%S"))
    except (KeyError, ValueError):
        return 0


def transcript_facts(path, now):
    facts = {"loop": False, "crons": 0, "last_text": "", "asking": False}
    if not path:
        return facts
    with open(path, "rb") as f:
        for line in f:
            if b'"ScheduleWakeup"' not in line and b'"Cron' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") != "assistant" or e.get("isSidechain"):
                continue
            for b in blocks(e):
                if b.get("type") != "tool_use":
                    continue
                inp = b.get("input") or {}
                if b.get("name") == "ScheduleWakeup":
                    # A wakeup that already fired left its turn; only a future one is pending.
                    due = ts(e) + float(inp.get("delaySeconds") or 0)
                    facts["loop"] = not inp.get("stop") and due > now - 120
                elif b.get("name") == "CronCreate" and cron_pending(inp, ts(e), now):
                    facts["crons"] += 1
                elif b.get("name") == "CronDelete":
                    facts["crons"] -= 1
        offset = max(0, path.stat().st_size - TAIL_BYTES)
        f.seek(offset)
        tail = f.read().split(b"\n")[1 if offset else 0:]  # a mid-file seek lands inside a line
    last = None
    for line in tail:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") != "assistant" or e.get("isSidechain"):
            continue
        last = e
        text = "\n".join(b.get("text", "") for b in blocks(e) if b.get("type") == "text").strip()
        if text:
            facts["last_text"] = text
    if last:
        facts["asking"] = any(b.get("type") == "tool_use" and b.get("name") == "AskUserQuestion"
                              for b in blocks(last))
    return facts


def subagent_activity(sid, now, quiet_minutes):
    """Subagent and workflow transcripts of this session written in the last quiet_minutes.
    They run inside the claude process: no child process shows them, and status may read idle."""
    recent = 0
    for sub in ("subagents", "workflows"):
        for f in PROJECTS_DIR.glob(f"*/{sid}/{sub}/**/*"):
            try:
                recent += f.is_file() and now - f.stat().st_mtime < quiet_minutes * 60
            except OSError:
                continue
    return recent


def relay_pending(cfg, claims, now):
    """Claimed issues with a relay request still waiting: `<issue>-*.json` at the top of RELAY_DIR
    (answered ones are renamed `.done` or moved to a subdirectory), younger than RELAY_MAX_AGE_HOURS."""
    if not cfg["RELAY_DIR"]:
        return []
    root = Path(os.path.expanduser(cfg["RELAY_DIR"]))
    max_age = float(cfg["RELAY_MAX_AGE_HOURS"]) * 3600
    out = []
    for _, num in claims:
        for f in root.glob(f"{num}-*.json"):
            try:
                if now - f.stat().st_mtime < max_age:
                    out.append(num)
                    break
            except OSError:
                continue
    return out


def missing_handoffs(cfg, text):
    """Concrete paths under HANDOFF_ROOT named in the last message that do not exist."""
    if not cfg["HANDOFF_ROOT"]:
        return []
    root = os.path.expanduser(cfg["HANDOFF_ROOT"]).rstrip("/") + "/"
    out = []
    for raw in PATH_RE.findall(text):
        path = os.path.expanduser(raw.rstrip(".,)"))
        if path.startswith(root) and path != root and not os.path.exists(path) and path not in out:
            out.append(path)
    return out


# ---------- gather and decide ----------

SKIPPED = []  # (label, reason, live) for every session file gather did not return; reset by each gather()


def _skip(d, f, reason, live):
    label = " ".join(x for x in (d.get("name") or "", f"tmux={d.get('tmux')}" if d.get("tmux") else "",
                                 f"sid={str(d.get('sessionId') or f.stem)[:8]}", f"pid={d.get('pid')}") if x)
    SKIPPED.append((label, reason, live))


def gather(cfg, now):
    table = ps_table()
    wts = worktrees(cfg)
    found = []
    SKIPPED.clear()
    for f in sorted(SESSIONS_DIR.glob("*.json")):
        try:
            d = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        pid = d.get("pid")
        running = pid in table
        if d.get("kind") != "interactive":
            _skip(d, f, f"kind:{d.get('kind')}", running)
            continue
        if not d.get("tmux"):
            _skip(d, f, "no-tmux-field", running)
            continue
        alive = running and " ".join(d.get("procStart", "").split()) == table[pid][1]
        if not alive:
            _skip(d, f, "procstart-mismatch" if running else "pid-gone", running)
            continue
        pane = d["tmux"].rsplit(".", 1)[-1]
        state = pane_state(pane)
        if not state:
            _skip(d, f, f"pane-missing:{pane}", True)
            continue
        if not is_ancestor(table, state["pane_pid"], pid):
            _skip(d, f, f"pane-ancestor-mismatch:{pane}", True)
            continue  # a pane that no longer holds this claude
        sid, cwd = d["sessionId"], d.get("cwd", "")
        owned = [w for w in wts if w["marker"] == sid
                 or (cwd + "/").startswith(str(w["path"]) + "/")]
        claims = []
        for w in owned:
            m = ISSUE_RE.search(w["branch"])
            repo = gh_repo(w["repo"])
            if m and repo and (repo, m.group(1)) not in claims:
                claims.append((repo, m.group(1)))
        found.append({
            "file": str(f), "pid": pid, "sid": sid, "cwd": cwd, "name": d.get("name", ""),
            "tmux": state["session"], "pane": pane, "status": d.get("status"),
            "status_at": d.get("statusUpdatedAt"), "start": table[pid][1], "fg": foreground(pid),
            "vim": vim_mode(),
            "idle_min": (now - d.get("statusUpdatedAt", now * 1000) / 1000) / 60,
            "bg_shells": [p for p, (pp, _, cmd) in table.items()
                          if pp == pid and "shell-snapshots/" in cmd],
            "scheduled": (Path(cwd) / ".claude" / "scheduled_tasks.json").exists(),
            "sub_active": subagent_activity(sid, now, float(cfg["SUBAGENT_QUIET_MINUTES"])),
            "screen_tail": "\n".join(state["screen"].rstrip("\n").split("\n")[-15:]),
            "owned": owned, "claims": claims, "descendants": len(descendants(table, pid)),
            **transcript_facts(transcript_path(sid), now),
        })
        found[-1]["relay_pending"] = relay_pending(cfg, claims, now)
    for s in found:
        s["other_sids"] = [o["sid"] for o in found if o is not s and o["sid"]]
    return found


def protected(cfg, *names):
    return any(fnmatch.fnmatch(n, p) for p in cfg["PROTECT"].split() for n in names if n)


def idle_list(cfg, seen, now):
    """Report-only list of long-idle sessions without a claim (for a person); decides nothing."""
    hours = float(cfg["IDLE_LIST_HOURS"])
    if hours <= 0:
        return
    names = cfg["IDLE_LIST_EXCLUDE"].split()
    rows = [f"| {s['tmux']} | `{s['sid'][:8]}` | {s['status']} | {s['idle_min'] / 60:.1f} | "
            f"{','.join(w['path'].name for w in s['owned']) or '-'} | {', '.join(keep) or '-'} |"
            for s, keep, outcome in seen
            if s["status"] in ("idle", "shell") and s["idle_min"] >= hours * 60 and not s["claims"]
            and not outcome.startswith("reaped")
            and not any(fnmatch.fnmatch(n, p) for p in names for n in (s["tmux"], s["name"]) if n)]
    head = ["| tmux | session | status | idle h | worktrees | still kept by |", "|---|---|---|---|---|---|"]
    body = [*head, *rows] if rows else ["none"]
    stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(now))
    out = Path(os.path.expanduser(cfg["IDLE_LIST_FILE"]))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join([f"# idle sessions {stamp}", "", f"idle >= {cfg['IDLE_LIST_HOURS']} h, no claimed issue", "",
                              *body]) + "\n")
    inbox = cfg["IDLE_LIST_INBOX"]
    day = time.strftime("%Y-%m-%d", time.localtime(now))
    posted = HOME / ".cc-reaper" / "state" / "idle-list-posted.txt"
    if inbox and (not posted.exists() or posted.read_text().strip() != day):
        path = Path(os.path.expanduser(inbox))
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as f:
            f.write("\n".join(["", f"## key=IDLE-SESSIONS-{day}", "", *body]) + "\n")
        posted.parent.mkdir(parents=True, exist_ok=True)
        tmp = posted.with_name(posted.name + ".tmp")
        tmp.write_text(day + "\n")
        os.replace(tmp, posted)


def waiting_re(cfg):
    extra = cfg.get("WAITING_EXTRA", "")
    return re.compile(WAITING_RE.pattern + ("|" + extra if extra else ""), re.I)


def _newest_claim(s):
    ts = [claim_time(r, n, s["sid"]) for r, n in s["claims"]]
    return None if None in ts else max(ts)


def decide(s, cfg, now=None):
    """Return the list of reasons that keep the session; empty means reap."""
    keep = []
    if protected(cfg, s["tmux"], s["name"]):
        keep.append("protected")
    if not s.get("fg", True):
        keep.append("not-foreground")
    if s.get("vim"):
        keep.append("vim-mode")
    if s["status"] != "idle":
        keep.append(f"status:{s['status']}")
    elif s["idle_min"] < float(cfg["IDLE_MINUTES"]):
        keep.append(f"idle:{s['idle_min']:.0f}<{cfg['IDLE_MINUTES']}min")
    if s["bg_shells"]:
        keep.append("shell-child")
    if s["loop"]:
        keep.append("loop-pending")
    if s["crons"] > 0 or s["scheduled"]:
        keep.append("scheduled-task")
    if s["asking"]:
        keep.append("waiting")
    elif waiting_re(cfg).search(DONE_RE.sub("", s["last_text"])):
        # The keyword alone counts for a session with no claim or a claim at a person step. Otherwise it
        # is only a hint: still kept (shadow, #6477), under a name the shadow verdict can tell apart.
        keep.append("waiting" if not s["claims"] or person_step(s, cfg, now) else "waiting-keyword")
    if s.get("sub_active"):
        keep.append("subagent-active")
    if s.get("relay_pending"):
        keep.append("handoff-pending:relay#" + ",#".join(s["relay_pending"]))
    if cfg["PROMPT_RE"] and re.search(cfg["PROMPT_RE"], s.get("screen_tail", ""), re.I):
        keep.append("handoff-pending:prompt")
    keep.extend("handoff-missing:" + os.path.basename(p) for p in missing_handoffs(cfg, s["last_text"]))
    done = bool(DONE_RE.search(s["last_text"]) or DONE_PHRASE_RE.search(s["last_text"])
                or (s["claims"] and inbox_done(cfg, (s.get("name"), s["tmux"]), now if now is not None else time.time(),
                                            lambda: _newest_claim(s))))
    if done:
        if s["status"] == "idle" and s["idle_min"] >= float(cfg["IDLE_MINUTES"]) and s["claims"]:
            cb = [checkby_state(r, n, cfg) for r, n in s["claims"]]
            if "OPEN" in cb:
                keep.append("check-by-open")
            elif "UNKNOWN" in cb:
                keep.append("check-by-unknown")
    else:
        if not s["claims"]:
            keep.append("claim-unknown")
        elif s["status"] == "idle" and s["idle_min"] >= float(cfg["IDLE_MINUTES"]):
            at = now if now is not None else time.time()
            marks, owed, unknown = [], [], []
            for r, n in s["claims"]:
                cls, overdue = classify_claim(
                    oracle_brief(r, n, cfg, at), s["sid"], at, s.get("other_sids", ()),
                    [w["marker"] for w in s["owned"] if w.get("marker")])
                marks.append(f"#{n}:{cls}" + (":stalled" if overdue else ""))
                if cls == "owed":
                    owed.append(f"#{n}")
                elif cls == "unknown":
                    unknown.append(f"#{n}")
            s["claim_marks"] = marks
            if owed:
                keep.append("owed-step:" + ",".join(owed))
            if unknown:
                keep.append("issue-unknown:" + ",".join(unknown))
        else:
            states = [issue_state(r, n) for r, n in s["claims"]]
            if any(st != "CLOSED" for st in states):
                keep.append("issue-open:" + ",".join(f"#{n}" for (_, n), st in zip(s["claims"], states)
                                                      if st != "CLOSED"))
    for w in s["owned"]:
        keep.extend(worktree_state(w, cfg))
    return keep


def _brief_kind(brief):
    k = BRIEF_KIND_RE.match(brief or "")
    return k.group(1) if k else ""


def claim_briefs(refs, cfg, now):
    return [(ref, oracle_brief(ref[0], ref[1], cfg, now)) for ref in refs]


def person_step(s, cfg, now=None):
    """True when the oracle's step for one of the session's worktree claims is a stop (a person's)."""
    at = now if now is not None else time.time()
    return any(_brief_kind(b) == "stop" for _, b in claim_briefs(s["claims"], cfg, at))


def oracle_claims(s, cfg, now, limit=8):
    """Issues the session names (`#N` in its last text or name) whose oracle brief says THIS session is the
    claimant (its id or a worktree marker it owns); the claim a worktree-less session has no branch for."""
    repo = cfg["CHECKBY_REPO"]
    named = []
    for n in NAMED_RE.findall(f"{s.get('name', '')}\n{s['last_text']}"):
        if n not in named and (repo, n) not in s["claims"]:
            named.append(n)
    mine = [w["marker"] for w in s["owned"] if w.get("marker")]
    out = []
    for n in named[:limit]:
        c = CLAIMANT_RE.search(oracle_brief(repo, n, cfg, now) or "")
        if c and (_same_session(c.group(1), s["sid"]) or any(_same_session(c.group(1), m) for m in mine)):
            out.append((repo, n))
    return out


def shadow_verdict(s, cfg, keep, now):
    """Report-only view of a KEPT session: {"would_close": why|"", "blocked": [issue numbers]}.

    would-close needs every keep reason to be a soft one (`claim-unknown`, a keyword `waiting`) and no work or
    person left: not protected or uiux/homepage, idle past the threshold, no uncommitted or unpushed work in a
    worktree or the cwd, no background child, no question or BLOCKED text, no oracle stop. Then either no claim
    (worktree or oracle) and a close line, or every claim `ended`. Nothing acts on it."""
    blocked = []

    def block(n):
        if n not in blocked:
            blocked.append(n)
    for n in BLOCKED_RE.findall(s["last_text"]):
        block(n)
    idle = s["status"] == "idle" and s["idle_min"] >= float(cfg["IDLE_MINUTES"])
    claims = list(s["claims"])
    marks, stop = [], False
    if idle:
        claims += oracle_claims(s, cfg, now)
        mine = [w["marker"] for w in s["owned"] if w.get("marker")]
        for (r, n), b in zip(claims, [oracle_brief(r, n, cfg, now) for r, n in claims]):
            stop = stop or _brief_kind(b) == "stop"
            for m in BLOCKED_RE.findall(b or ""):
                block(m)
            marks.append(classify_claim(b, s["sid"], now, s.get("other_sids", ()), mine)[0])
    out = {"would_close": "", "blocked": blocked, "claims": claims}
    never = [n for n in (s["tmux"], s.get("name")) if n]
    if (not keep or not idle or blocked or stop or s["asking"] or s["bg_shells"] or s.get("sub_active")
            or any(not k.startswith(SOFT_KEEP) for k in keep)
            or any(fnmatch.fnmatch(n.lower(), p.lower()) for p in cfg["NEVER_CLOSE"].split() for n in never)
            or protected(cfg, *never)):
        return out
    cwd_wt = [] if any(str(w["path"]) == s.get("cwd") for w in s["owned"]) or not s.get("cwd") \
        else [{"path": Path(s["cwd"])}]
    if any(worktree_state(w, cfg) for w in [*s["owned"], *cwd_wt]):
        return out
    text = s["last_text"]
    if not claims:
        if DONE_RE.search(text) or DONE_PHRASE_RE.search(text) or CLOSE_LINE_RE.search(text):
            out["would_close"] = "no claim, close line"
    elif all(m == "ended" for m in marks):
        out["would_close"] = "all claims ended"
    return out


def summary(s):
    m = DONE_RE.search(s["last_text"])
    lines = s["last_text"].strip().splitlines()
    return (m.group(1) if m else lines[-1] if lines else "")[:200]


# ---------- reap and verify ----------

def notify(msg):
    run(["osascript", "-e", f"display notification {json.dumps(msg)} with title \"session-reaper\""])


def comment(issue_ref, body):
    repo, num = issue_ref
    return run(["gh", "issue", "comment", num, "-R", repo, "--body", body], 60)[0] == 0


def verify(s, snapshot):
    """Every check that must hold after a reap; returns the failures."""
    fails = []
    table = ps_table()
    if s["pid"] in table and table[s["pid"]][1] == s["start"]:
        fails.append(f"claude pid {s['pid']} still running")
    orphans = survivors(table, snapshot)
    if orphans:
        # Executable name only: arguments can carry credentials, and this text goes to an issue.
        fails.append("orphan processes: " + ", ".join(
            f"{p} {os.path.basename(table[p][2].split(' ', 1)[0])}" for p, _ in orphans))
    if pane_exists(s["pane"]):
        fails.append(f"tmux pane {s['pane']} still exists")
    if s.get("killed_session") and tmux("has-session", "-t", s["session_id"])[0] == 0:
        fails.append(f"tmux session {s['tmux']} ({s['session_id']}) still exists")
    if Path(s["file"]).exists():
        fails.append(f"session file {s['file']} still exists")
    for w in s["owned"]:
        if (w["gitdir"] / "locked").exists():
            fails.append(f"worktree {w['path']} is locked")
        if (w["gitdir"] / "index.lock").exists():
            fails.append(f"worktree {w['path']} has index.lock")
    return fails


def write_record(s, cfg, now, status):
    """The context a person or `--resume` needs once the session is gone, written before /exit."""
    d = Path(os.path.expanduser(cfg["REAPED_DIR"]))
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"{s['tmux']}.json"
    rec = {"tmux": s["tmux"], "name": s.get("name", ""), "sid": s["sid"], "cwd": s["cwd"],
           "claims": [f"{r}#{n}" for r, n in s["claims"]],
           "worktrees": [{"path": str(w["path"]), "branch": w.get("branch", "")} for w in s["owned"]],
           "last_text": s["last_text"][-2000:], "at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
           "status": status, "pid": s.get("pid"), "start": s.get("start", ""),
           "pane": s.get("pane", ""), "session_id": s.get("session_id", ""),
           "resume": f"tmux new-session -d -s {s['tmux']} -c {s['cwd']} 'claude --resume {s['sid']}'"}
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(rec, ensure_ascii=False, indent=1) + "\n")
    tmp.replace(path)
    return path


def mark_record(path, outcome):
    try:
        rec = json.loads(path.read_text())
        rec["status"] = "reaped" if outcome == "reaped" else f"aborted:{outcome}"
        tmp = path.with_suffix(".tmp")  # whole or not at all, as write_record: a torn record would be unreadable
        tmp.write_text(json.dumps(rec, ensure_ascii=False, indent=1) + "\n")
        tmp.replace(path)
    except (OSError, ValueError):
        pass


def has_marker(issue_ref, sid):
    """True/False when the issue has (no) comment carrying our marker; None when gh could not say."""
    repo, num = issue_ref
    rc, out = run(["gh", "issue", "view", num, "-R", repo, "--json", "comments"], 60)
    if rc != 0:
        return None
    try:
        return any(f"session-reaper:{sid}" in (c.get("body") or "") for c in json.loads(out).get("comments", []))
    except (ValueError, AttributeError):
        return None


def finish_close(rec_tmux, sid, cwd, claims, summ, pane, session_id, alone, cfg, now):
    """The steps after claude has exited, safe to repeat: each checks for its own earlier effect.
    Returns False when a step could not be confirmed (the record then stays "exiting")."""
    log = Path(os.path.expanduser(cfg["CLOSED_LOG"]))
    log.parent.mkdir(parents=True, exist_ok=True)
    try:
        done = sid in log.read_text()
    except OSError:
        done = False
    if not done:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
        issues = " ".join(f"{r}#{n}" for r, n in claims) or "-"
        with log.open("a") as fh:
            fh.write(f"\n## {stamp} session-reaper (resume: claude --resume <sid>)\n"
                     f"- {rec_tmux} {sid} cwd={cwd} issues={issues} — {summ}\n")
    ok = True
    for ref in claims:
        seen = has_marker(ref, sid)
        if seen is False:
            ok = comment(ref, f"Session `{rec_tmux}` (`{sid}`) finished and was reaped by session-reaper. "
                              f"Resume it with `cd {cwd} && claude --resume {sid}`.\n\n<!-- session-reaper:{sid} -->") and ok
        elif seen is None:
            ok = False
    return ok


# `claude …` from a shell, or the versioned binary itself (`~/.local/share/claude/versions/2.1.293 --resume`).
CLAUDE_CMD = re.compile(r"(^|/)claude$|/claude/versions/[^/]+$")
STALE_EXITING_SECONDS = 24 * 3600


def claude_under(table, root):
    """True when root or any process below it is a claude."""
    pids = [root] + [p for p, _ in descendants(table, root)]
    for p in pids:
        cmd = table.get(p, (0, "", ""))[2].split()
        if any(CLAUDE_CMD.search(w) for w in cmd[:2]):
            return True
    return False


def recover_exiting(cfg, now):
    """A crash after /exit leaves reaped/<tmux>.json at "exiting": finish those whose claude is gone.
    Never comments on or kills a session that is alive; returns report lines for stale records."""
    notes = []
    d = Path(os.path.expanduser(cfg["REAPED_DIR"]))
    table = ps_table()
    if not table:
        return notes  # ps failed: nothing can be proven dead, leave every record for the next run
    for path in sorted(d.glob("*.json")):
        try:
            rec = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        pid = rec.get("pid")
        if rec.get("status") != "exiting" or not pid:
            continue
        if pid in table and table[pid][1] == rec.get("start"):
            continue  # still running: a live reap or an earlier abort, not ours to finish
        pane = rec.get("pane")
        if pane and pane_exists(pane):
            st = pane_state(pane)
            if not st:
                continue  # cannot see the pane: not proof of anything
            if claude_under(table, st["pane_pid"]):
                mark_record(path, "alive")  # the user kept or restarted claude here: not ours
                continue
        claims = [tuple(c.rsplit("#", 1)) for c in rec.get("claims", []) if "#" in c]
        if not finish_close(rec["tmux"], rec["sid"], rec["cwd"], claims, (rec.get("last_text") or "").strip()[:120],
                            pane, rec.get("session_id"), True, cfg, now):
            try:
                if now - path.stat().st_mtime > STALE_EXITING_SECONDS:
                    notes.append(f"{rec['tmux']} ({rec['sid']}): record exiting over 24h, issue comment unconfirmed")
            except OSError:
                pass
            continue
        if pane and pane_exists(pane):
            st = pane_state(pane)
            if st and st["session"] == rec["tmux"] and st["session_id"] == rec.get("session_id"):
                if st["alone"]:
                    tmux("kill-session", "-t", st["session_id"])
                else:
                    tmux("kill-pane", "-t", pane)
        mark_record(path, "reaped")
    return notes


def reap(s, cfg, now):
    """Return (outcome, failures). outcome is reaped, or skipped:<why>."""
    # Everything gather saw may be minutes old: re-check that nobody has touched the session.
    try:
        fresh = json.loads(Path(s["file"]).read_text())
    except (OSError, ValueError):
        return "skipped:session-file-unreadable", []
    if fresh.get("status") != "idle" or fresh.get("statusUpdatedAt") != s["status_at"]:
        return "skipped:session-changed", []
    table = ps_table()
    if s["pid"] not in table or table[s["pid"]][1] != s["start"] or not foreground(s["pid"]):
        return "skipped:not-foreground", []
    state = pane_state(s["pane"])
    if not state or not is_ancestor(table, state["pane_pid"], s["pid"]):
        return "skipped:pane-changed", []
    if protected(cfg, state["session"], s["name"]):
        return "skipped:protected", []
    if not empty_prompt(state):
        return "skipped:prompt-not-empty", []
    s["tmux"], s["session_id"] = state["session"], state["session_id"]
    alone = state["alone"]
    snapshot = descendants(table, s["pid"])
    s["record"] = write_record(s, cfg, now, "exiting")
    try:  # until claude is confirmed gone, a crash must not leave "exiting" for recovery to act on
        tmux("send-keys", "-t", s["pane"], "-l", "/exit")
        time.sleep(0.5)
        typed = pane_state(s["pane"])
        if not typed or cursor_line(typed) != "❯ /exit":
            # The input was not empty after all (cursor moved into a draft): take our text back out.
            tmux("send-keys", "-t", s["pane"], *["BSpace"] * len("/exit"))
            return "skipped:input-not-empty", []
        tmux("send-keys", "-t", s["pane"], "Enter")
        deadline = time.time() + EXIT_WAIT_SECONDS
        while time.time() < deadline:
            time.sleep(1)
            if s["pid"] not in ps_table():
                break
            state = pane_state(s["pane"])
            if state and MENU_TEXT in state["screen"]:
                tmux("send-keys", "-t", s["pane"], "Escape")  # Esc is Stay: background tasks keep running
                time.sleep(1.5)
                state = pane_state(s["pane"])
                if state and MENU_TEXT in state["screen"]:
                    return "skipped:menu-stuck", [f"exit menu still open in {s['tmux']} after Esc"]
                return "skipped:background-tasks", []
        else:
            return "skipped:exit-timeout", [f"claude pid {s['pid']} did not exit within {EXIT_WAIT_SECONDS}s"]
    except Exception:
        mark_record(s["record"], "exception")
        raise
    if not finish_close(s["tmux"], s["sid"], s["cwd"], s["claims"], summary(s), s["pane"],
                        s["session_id"], alone, cfg, now):
        return "skipped:close-unconfirmed", [f"{s['tmux']}: log or issue comment not confirmed; record stays exiting"]
    # Kill only what this session owned: the whole tmux session if it was its only pane.
    # Recount just before the kill: a window opened during the exit wait must survive. A pane
    # that closed with claude leaves nothing of this session's to kill.
    still_alone = False
    if pane_exists(s["pane"]):
        state = pane_state(s["pane"])
        still_alone = alone and bool(state and state["alone"])
        tmux("kill-session", "-t", s["session_id"]) if still_alone else tmux("kill-pane", "-t", s["pane"])
    s["killed_session"] = still_alone
    time.sleep(1)
    return "reaped", verify(s, snapshot)


def alert(cfg, lines):
    msg = "; ".join(lines)
    notify(msg[:200])
    m = re.fullmatch(r"([^#\s]+)#(\d+)", cfg["TRACKING_ISSUE"])
    if m and not comment((m.group(1), m.group(2)),
                         "session-reaper verification failed:\n\n" + "\n".join(f"- {l}" for l in lines)):
        notify("session-reaper could not post the failure to " + cfg["TRACKING_ISSUE"])


# ---------- main ----------

def report_line(s, keep, outcome):
    wt = ",".join(w["path"].name for w in s["owned"]) or "-"
    issues = ",".join(s.get("claim_marks") or [f"#{n}" for _, n in s["claims"]]) or "-"
    plan = f"pid {s['pid']}+{s['descendants']} desc; tmux {s['tmux']}; worktrees {wt}"
    background_only = "yes" if keep and set(keep) <= BACKGROUND_ONLY else "-"
    new_only = "yes" if keep and all(k.startswith(NEW_GATES) for k in keep) else "-"
    why = [f"would-close: {s['would_close']}"] if s.get("would_close") else []
    blocked = [", ".join(f"blocked: #{n}" for n in s["blocked"])] if s.get("blocked") else []
    return (f"| {s['tmux']} | `{s['sid'][:8]}` | {s['status']} {s['idle_min']:.0f}m | {issues} | "
            f"{outcome} | {', '.join([*keep, *why, *blocked]) or '-'} | {background_only} | {new_only} | {plan} |")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", default=str(CONFIG))
    ap.add_argument("--apply", action="store_true", help="reap (default: report only, unless APPLY=1)")
    ap.add_argument("--only", help="consider only this tmux session")
    ap.add_argument("--idle-minutes", help="override IDLE_MINUTES")
    args = ap.parse_args(argv)
    cfg = load_config(args.config)
    if args.idle_minutes is not None:
        cfg["IDLE_MINUTES"] = args.idle_minutes
    apply = args.apply or cfg["APPLY"] == "1"
    state_dir = HOME / ".cc-reaper" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    lock = open(state_dir / "session-reaper.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("session-reaper: another run holds the lock")
        return 0
    now = time.time()
    rows, failures, reaped, seen, stale, notes = [], [], 0, [], [], []
    try:
        if apply and not args.only:
            stale = recover_exiting(cfg, now)
    except Exception as e:
        failures.append(f"recover exiting: {type(e).__name__}: {e}")
    try:
        for s in gather(cfg, now):
            if args.only and s["tmux"] != args.only:
                continue
            keep, outcome = [], "error"
            try:
                keep = decide(s, cfg)
                outcome = "keep" if keep else ("reap" if apply else "would-reap")
                if keep:  # shadow only: the outcome label changes, nothing below acts on it
                    try:
                        sv = shadow_verdict(s, cfg, keep, now)
                        s["blocked"], s["would_close"] = sv["blocked"], sv["would_close"]
                        outcome = "would-close" if sv["would_close"] else outcome
                    except Exception as e:  # a report-only verdict must not fail the sweep
                        notes.append(f"{s['tmux']} ({s['sid']}): shadow verdict: {type(e).__name__}: {e}")
                if not keep and apply:
                    outcome, fails = reap(s, cfg, now)
                    if s.get("record") and outcome != "skipped:close-unconfirmed":  # stays "exiting" for recovery
                        mark_record(s["record"], outcome)
                    reaped += outcome == "reaped"
                    failures += [f"{s['tmux']} ({s['sid']}): {f}" for f in fails]
                    if outcome == "reaped":
                        outcome = "reaped, verified" if not fails else "reaped, VERIFY FAILED"
            except Exception as e:  # one bad session must not cost the others their report
                failures.append(f"{s['tmux']} ({s['sid']}): {type(e).__name__}: {e}")
            rows.append(report_line(s, keep, outcome))
            seen.append((s, keep, outcome))
    except Exception as e:
        failures.append(f"sweep aborted: {type(e).__name__}: {e}")
    try:
        if not args.only:  # a one-session run would overwrite the list with that session alone
            idle_list(cfg, seen, now)
    except Exception as e:  # a report-only list must not stop the report
        failures.append(f"idle list: {type(e).__name__}: {e}")
    mode = "apply" if apply else "report-only"
    stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(now))
    report = [f"# session-reaper {mode} {stamp}", "",
              f"idle threshold {cfg['IDLE_MINUTES']} min; protected: {cfg['PROTECT'] or '(none)'}", "",
              "| tmux | session | status idle | issues | outcome | keeps it | held only by background shells "
              "| kept only by new gates | verification target |",
              "|---|---|---|---|---|---|---|---|---|", *rows]
    live = [f"- {label}: {why}" for label, why, is_live in SKIPPED if is_live]
    dead = sum(1 for _, _, is_live in SKIPPED if not is_live)
    report += ["", "## Skipped live sessions (not judged)", *(live or ["none"]),
               f"({dead} session files with no live process not listed)"]
    if notes:
        report += ["", "## Shadow notes", *[f"- {n}" for n in notes]]
    if stale:
        report += ["", "## Stale exiting records", *[f"- {f}" for f in stale]]
    if failures:
        report += ["", "## Verification failures", *[f"- {f}" for f in failures]]
    out = Path(os.path.expanduser(cfg["REPORT"]))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(report) + "\n")
    print(f"session-reaper {mode}: {len(rows)} sessions, {reaped} reaped, "
          f"{len(failures)} verification failures; report {out}")
    if failures:
        alert(cfg, failures)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
