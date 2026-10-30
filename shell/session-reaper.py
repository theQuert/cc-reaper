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
import faulthandler
import fcntl
import fnmatch
import glob
import json
import os
import re
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
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
    "DONE_INBOX_SHADOW": "",  # report-only: with DONE_INBOX off, mark kept sessions DONE_INBOX=<this> would reap
    "CHECKBY_ORACLE": "/Users/stimaclaw/GitHub/stima-api/scripts/ci/delivery_state.py",  # --json: pending_check_by, due_check
    "CHECKBY_REPO": "theQuert/stima-api",  # the only repo the oracle reads; a claim elsewhere is UNKNOWN (kept)
    "ORACLE_ROOT": "/Users/stimaclaw/GitHub/stima-api",  # checkout whose `scripts/ci/delivery_state.py N --brief` judges an idle session's open claims
    "ORACLE_CACHE_DIR": "~/.cc-reaper/state/oracle-brief",  # one brief per issue, reused for ORACLE_CACHE_MINUTES (GitHub REST budget)
    "ORACLE_CACHE_MINUTES": "10",
    "NEVER_CLOSE": "uiux* homepage*",  # fnmatch over tmux/session names, case-insensitive: never `would-close`
    "STALL_MARK_DIR": "~/.cc-reaper/state/stalled",  # stall-watch.py writes <session id>.json here; empty: off
    "STALL_MARK_HOURS": "12",  # a mark not refreshed for this long is stale and ignored
    "STALL_MARK_MAX_HOURS": "48",  # a mark whose event was first seen longer ago is ignored however fresh it is
    "IDLE_LIST_EXCLUDE": "",
    # EL-T2512: a session whose newest assistant text, written after its last prompt, says SESSION-DONE or
    # `SESSION-STATE: IDLE_NO_WORK` waits DONE_GRACE_MINUTES instead of IDLE_MINUTES; every other gate still holds.
    # `shadow` reports `would-close: done grace (shadow)` and closes nothing; `apply` uses it; `off` neither.
    "DONE_GRACE": "off",
    "DONE_GRACE_MINUTES": "5",
    # EL-T2482: a path (ops-dispatch's events.log) that gets `ROUTE nudge <tmux> <fingerprint>` for an idle session kept
    # only by its own open work; ops-dispatch sends the message. Empty: off. NUDGE_STATE dedups. See nudge_events().
    "NUDGE_EVENTS": "",
    "NUDGE_STATE": "~/.cc-reaper/state/nudged.json",  # space-separated fnmatch patterns over tmux and session names never listed
    # A claim-less session whose newest inbox header (DONE_INBOX, else DONE_INBOX_SHADOW) is DONE (EL-T24): `shadow`
    # reports it `would-close` and closes nothing; `apply` counts it as done; `off` neither. See noclaim_done().
    "NOCLAIM_DONE": "shadow",
    # Space- or comma-separated pids: a session whose process tree holds one is kept (`never-kill:<pid>`) and its
    # pane is never killed. The environment variable of the same name wins over this value.
    "CC_NEVER_KILL_PIDS": "70987 4565",
}
SESSIONS_DIR = HOME / ".claude" / "sessions"
PROJECTS_DIR = HOME / ".claude" / "projects"
MARKER = "claude-task-worktree"
TAIL_BYTES = 4 << 20
EXIT_WAIT_SECONDS = 20
DONE_RE = re.compile(r"(?m)^\W*SESSION-DONE:\s*(.+)$")
STATE_IDLE_RE = re.compile(r"(?m)^\W*SESSION-STATE:\s*IDLE_NO_WORK\b")
# The done-grace marker (EL-T2512) is stricter than DONE_RE: a bare line among the last three of the reply, not
# quoted, listed, back-ticked or inside a code fence, so a reply that explains the rule does not shorten the wait.
GRACE_RE = re.compile(r"^\s*(?:SESSION-DONE:\s*\S|SESSION-STATE:\s*IDLE_NO_WORK\b)")
# EL-T2520: a reply that ends on an alarm. Closable under the grace only with no open PR, no owed step and nothing
# unpushed; otherwise it is a FALSE_WAITING row (report-only), so the continue path can fire.
WAIT_RE = re.compile(r"^\s*SESSION-STATE:\s*WAITING_UNTIL=(\d{4}-\d\d-\d\dT\d\d:\d\d)(?::\d\d)?Z?(?!\S)")
FALSE_WAITING = ("open-pr", "owed-step:", "unpushed:", "uncommitted:", "issue-unknown:", "alarm-passed",
                 "named-claim:", "child-process")
DONE_PHRASE_RE = re.compile(r"這個主題(已經)?結束|may be closed", re.I)
WAITING_RE = re.compile(
    r"production-authorization|authoriz|approv|授權|批准|等你|你決定|請確認", re.I
)
# A close line that is not SESSION-DONE: the session says it has no scope left (#6477).
# DONE / IDLE-no-scope are the self-labels, so only their exact case counts: "Done with step 1" is progress.
CLOSE_LINE_RE = re.compile(r"(?i:no open scope|reaper can close|safe to close)|(?m:^\W*(?:DONE|IDLE-no-scope)\b)")
BLOCKED_RE = re.compile(r"BLOCKED:#(\d{3,6})")
NAMED_RE = re.compile(r"(?<![\w/])#(\d{3,6})\b")
SOFT_KEEP = ("claim-unknown", "waiting")  # `waiting-keyword` also starts with `waiting`
ISSUE_FALLBACKS = 6  # single `gh issue view` calls a run may make after a batch failed
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


def never_kill_pids(cfg):
    """The never-kill pids: CC_NEVER_KILL_PIDS from the environment when it is set, else from the config (default
    "70987 4565"). A token that is not an ASCII pid is reported on stderr, never silently dropped."""
    raw = os.environ.get("CC_NEVER_KILL_PIDS", cfg.get("CC_NEVER_KILL_PIDS", ""))
    toks = [x for x in re.split(r"[\s,]+", raw or "") if x]
    bad = [x for x in toks if not re.fullmatch(r"[0-9]+", x)]
    if bad:
        print(f"session-reaper: CC_NEVER_KILL_PIDS: not a pid, ignored: {' '.join(bad)}", file=sys.stderr)
    return {int(x) for x in toks if x not in bad}


def session_tree(table, pane_pid, pid):
    """Every pid a close could end: the pane's process and all below it, the chain from claude up to the pane, and
    claude's own descendants (when the pane no longer holds it)."""
    tree = {pane_pid, pid}
    tree.update(p for p, _ in descendants(table, pane_pid))
    tree.update(p for p, _ in descendants(table, pid))
    seen, p = set(), pid
    while p in table and p not in seen and p > 1 and p != pane_pid:
        seen.add(p)
        tree.add(p)
        p = table[p][0]
    return tree


def never_kill_hit(table, pane_pid, pid, cfg):
    return sorted(session_tree(table, pane_pid, pid) & never_kill_pids(cfg))


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


RUN_START = time.monotonic()
WT_BUDGET = 900  # seconds of a run that may go to worktree git checks; the launchd interval is 1800
# #6477, 2026-10-29: past WT_BUDGET a run still judged every session (gh, tmux, claude agents at about 30 s each
# at load 120), ran past an hour, and wrote no report from 05:39 to 12:40 TPE. Past RUN_BUDGET the remaining sessions
# are kept unjudged (fail-closed: nothing is reaped) so the run ends and the report is written.
RUN_BUDGET = float(os.environ.get("REAPER_RUN_BUDGET", "1200"))
IN_REAP = False
_wt_seen = {}


def worktree_state(wt, cfg):
    """Problems that keep the worktree's owner alive: uncommitted or unpushed work. Once per path per run, and
    within WT_BUDGET: a run at load 130 called `worktree-janitor.sh --landed` (up to 120 s each) for the same
    worktrees once per session and twice per verdict, ran for 4 h, and left the report 4 h stale (EL-GATEWAY-0852).
    A worktree checked past the budget keeps its owner, so the run ends and the report is written."""
    key = str(wt["path"])
    if key not in _wt_seen:
        _wt_seen[key] = (["unchecked:" + wt["path"].name] if time.monotonic() - RUN_START > WT_BUDGET
                         else _worktree_state(wt, cfg))
    return list(_wt_seen[key])


def _worktree_state(wt, cfg):
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
_issue_tried = set()
_issue_fallbacks = [0]
ISSUE_BATCH = 50  # aliases per GraphQL request
REPO_RE = re.compile(r"[\w.-]+/[\w.-]+")


def batch_issue_states(refs):
    """Fill `_issue_cache` with one `gh api graphql` call per repo (and 50 numbers) instead of one `gh issue view`
    per issue. At host load 100 each `gh issue view` took 30 s and more, serially, enough to spend RUN_BUDGET
    before the first session was judged (stima-api #6477). The value per number is what `gh issue view` printed:
    the state of the issue or pull request, and UNKNOWN for a number GitHub does not know (the old call failed
    there too). A call that fails or answers in a shape not understood caches nothing, so issue_state falls back
    to the single call and fails closed (UNKNOWN keeps the session)."""
    by_repo = {}
    for repo, num in refs:
        _issue_tried.add((repo, str(num)))
        if REPO_RE.fullmatch(repo or "") and str(num).isdigit() and (repo, str(num)) not in _issue_cache:
            by_repo.setdefault(repo, [])
            if str(num) not in by_repo[repo]:
                by_repo[repo].append(str(num))
    for repo, nums in by_repo.items():
        owner, name = repo.split("/")
        for i in range(0, len(nums), ISSUE_BATCH):
            chunk = nums[i:i + ISSUE_BATCH]
            fields = " ".join(f"i{n}: issueOrPullRequest(number: {n}) {{ ... on Issue {{ state }} "
                              f"... on PullRequest {{ state }} }}" for n in chunk)
            query = f"query($o: String!, $n: String!) {{ repository(owner: $o, name: $n) {{ {fields} }} }}"
            rc, out = run(["gh", "api", "graphql", "-f", "o=" + owner, "-f", "n=" + name, "-f", "query=" + query], 90)
            try:
                got = json.loads(out)["data"]["repository"]
                if not isinstance(got, dict):
                    raise ValueError("shape")  # a null repository: no access, or the call failed
            except (ValueError, TypeError, KeyError):
                continue
            for n in chunk:
                if f"i{n}" not in got:
                    continue
                v = got[f"i{n}"]
                if isinstance(v, dict) and isinstance(v.get("state"), str):
                    _issue_cache[(repo, n)] = v["state"]
                elif v is None:
                    _issue_cache[(repo, n)] = "UNKNOWN"  # GitHub has no such issue or pull request


def issue_state(repo, num):
    key = (repo, str(num))
    if key not in _issue_cache and key not in _issue_tried:
        batch_issue_states([key])
    if key not in _issue_cache:  # the batch failed or was not understood: the old call, a few times a run
        if _issue_fallbacks[0] >= ISSUE_FALLBACKS:
            return "UNKNOWN"  # not cached: it keeps the session now, and a later call may still succeed
        _issue_fallbacks[0] += 1
        rc, out = run(["gh", "issue", "view", str(num), "-R", repo, "--json", "state", "-q", ".state"])
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
_comments_cache = {}


def issue_comments(repo, num):
    """The issue's comments from one `gh issue view` per issue and run, however many sessions ask; None when gh
    could not say."""
    key = (repo, num)
    if key not in _comments_cache:
        rc, out = run(["gh", "issue", "view", str(num), "-R", repo, "--json", "comments",
                       "-q", ".comments"], 60)
        try:
            if rc != 0:
                raise ValueError(rc)
            comments = json.loads(out)
            if not isinstance(comments, list):
                raise ValueError("shape")
        except (ValueError, TypeError):
            return None  # not cached: a later ask retries
        _comments_cache[key] = comments
    return _comments_cache[key]


def claim_time(repo, num, sid):
    """Epoch of the newest `Claimed by ... session <sid>` comment on the issue; None when unknown."""
    key = (repo, num, sid)
    if key not in _claim_cache:
        at = None
        try:
            comments = issue_comments(repo, num)
            if comments is None:
                raise ValueError("no comments")
            for c in comments:
                if re.search(r"Claimed by[^\n]*session\s+" + re.escape(sid), c.get("body") or ""):
                    t = calendar.timegm(time.strptime(c["createdAt"], "%Y-%m-%dT%H:%M:%SZ"))
                    at = t if at is None or t > at else at
        except (ValueError, TypeError, KeyError, AttributeError):
            at = None
        _claim_cache[key] = at
    return _claim_cache[key]


INBOX_HEADER_RE = re.compile(r"^## .*?(\w+) · (\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d) TPE · (.+?)\s*$")


def inbox_done_header(path, names):
    """(epoch, key) of the newest inbox header written by one of `names` when it is DONE; None otherwise.
    Only header lines are examined; any read or parse failure is None."""
    names = {n for n in names if n}
    if not path or not names:
        return None
    newest = None
    try:
        with open(os.path.expanduser(path), errors="replace") as f:
            for line in f:
                if line.startswith("## ") and " · " in line and line.rstrip().rsplit(" · ", 1)[1] in names:
                    newest = line.rstrip()
    except OSError:
        return None
    m = INBOX_HEADER_RE.match(newest or "")
    if not m or m.group(1) != "DONE":
        return None
    y, mo, d, h, mi = (int(x) for x in m.group(2, 3, 4, 5, 6))
    try:
        at = calendar.timegm((y, mo, d, h, mi, 0, 0, 0, 0)) - 8 * 3600  # Asia/Taipei is UTC+8
    except (ValueError, OverflowError):
        return None
    return at, newest[3:].split(None, 1)[0]


def inbox_done(cfg, names, now, claim_at=None):
    """True when the newest inbox header written by one of `names` is DONE and old enough.
    The header must be later than the newest claim (`claim_at()` -> epoch or None; None: not done).
    Only header lines are examined; any read or parse failure means not done."""
    hit = inbox_done_header(cfg.get("DONE_INBOX"), names)
    if not hit:
        return False
    at = hit[0]
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
    facts = {"loop": False, "crons": 0, "last_text": "", "text_at": 0, "asking": False, "prompt_at": 0}
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
        if e.get("type") == "user" and not e.get("isSidechain"):
            # A prompt: a person's or a peer's message, anything but a tool result. Meta entries count too (a peer
            # message is one), which only makes a prompt look newer: fail-closed for noclaim_done().
            c = e.get("message", {}).get("content")
            if isinstance(c, str) or any(isinstance(b, dict) and b.get("type") != "tool_result"
                                         for b in (c if isinstance(c, list) else [])):
                facts["prompt_at"] = max(facts["prompt_at"], ts(e))
            continue
        if e.get("type") != "assistant" or e.get("isSidechain"):
            continue
        last = e
        text = "\n".join(b.get("text", "") for b in blocks(e) if b.get("type") == "text").strip()
        if text:
            facts["last_text"] = text
    if last:
        # text_at is when the reply that ends the transcript was written; a tool call after the text leaves it 0
        facts["text_at"] = ts(last) if any(b.get("type") == "text" and b.get("text", "").strip()
                                           for b in blocks(last)) else 0
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
SKIPPED_INFO = {}  # label -> {"name", "sid", "status", "idle_min" (None: unknown), "pid"}: the `unjudged` report rows


def _skip(d, f, reason, live, now=None):
    label = " ".join(x for x in (d.get("name") or "", f"tmux={d.get('tmux')}" if d.get("tmux") else "",
                                 f"sid={str(d.get('sessionId') or f.stem)[:8]}", f"pid={d.get('pid')}") if x)
    SKIPPED.append((label, reason, live))
    at = d.get("statusUpdatedAt")
    idle = (now - at / 1000) / 60 if now is not None and isinstance(at, (int, float)) else None
    tmux_name = str(d.get("tmux") or "").split(":", 1)[0]
    SKIPPED_INFO[label] = {"name": d.get("name") or tmux_name or "-", "sid": str(d.get("sessionId") or f.stem)[:8],
                           "status": d.get("status") or "-", "idle_min": idle, "pid": d.get("pid")}


def claim_why(owned, repos):
    """Why gather found no claim for a session ("" when it found one): the reaper's only claim source is the issue
    number in the branch of a worktree the session owns (its marker, or the cwd inside it), on a GitHub repo."""
    if not owned:
        return "no-worktree"
    if not any(ISSUE_RE.search(w["branch"]) for w in owned):
        return "no-issue-branch:" + ",".join(w["path"].name for w in owned)
    if not any(r for r in repos):
        return "no-github-remote"
    return ""


def gather(cfg, now):
    table = ps_table()
    wts = worktrees(cfg)
    found = []
    SKIPPED.clear()
    SKIPPED_INFO.clear()
    for f in sorted(SESSIONS_DIR.glob("*.json")):
        try:
            d = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        pid = d.get("pid")
        running = pid in table
        if d.get("kind") != "interactive":
            _skip(d, f, f"kind:{d.get('kind')}", running, now)
            continue
        if not d.get("tmux"):
            _skip(d, f, "no-tmux-field", running, now)
            continue
        alive = running and " ".join(d.get("procStart", "").split()) == table[pid][1]
        if not alive:
            _skip(d, f, "procstart-mismatch" if running else "pid-gone", running, now)
            continue
        pane = d["tmux"].rsplit(".", 1)[-1]
        state = pane_state(pane)
        if not state:
            _skip(d, f, f"pane-missing:{pane}", True, now)
            continue
        if not is_ancestor(table, state["pane_pid"], pid):
            _skip(d, f, f"pane-ancestor-mismatch:{pane}", True, now)
            continue  # a pane that no longer holds this claude
        sid, cwd = d["sessionId"], d.get("cwd", "")
        owned = [w for w in wts if w["marker"] == sid
                 or (cwd + "/").startswith(str(w["path"]) + "/")]
        claims, repos = [], []
        for w in owned:
            m = ISSUE_RE.search(w["branch"])
            repo = gh_repo(w["repo"]) if m else ""
            repos.append(repo)
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
            "claim_why": "" if claims else claim_why(owned, repos),
            "never_kill": never_kill_hit(table, state["pane_pid"], pid, cfg),
            **transcript_facts(transcript_path(sid), now),
        })
        found[-1]["relay_pending"] = relay_pending(cfg, claims, now)
    for s in found:
        s["other_sids"] = [o["sid"] for o in found if o is not s and o["sid"]]
    return found


def protected(cfg, *names):
    return any(fnmatch.fnmatch(n, p) for p in cfg["PROTECT"].split() for n in names if n)


OPEN_WORK = ("owed-step:", "uncommitted:", "unpushed:", "check-by-open")  # decide()/worktree_state() keep reasons
NUDGE_FOR = OPEN_WORK[:3]  # a pending check-by alone is not: checkby_state says OPEN before it is due, the router wakes it


def nudge_events(cfg, seen, now):
    """EL-T2482: an idle session at an empty prompt kept ONLY by open work of its own (an owed oracle step, an
    uncommitted or unpushed worktree, plus at most an open check-by) gets one `ROUTE nudge <tmux> <fingerprint>` line
    in NUDGE_EVENTS, and ops-dispatch sends it a message. Once per fingerprint (session id + reasons): it stays
    remembered while the session is kept by those same reasons, busy or not, and is forgotten only when a judged
    session's reasons change, so it nudges again only on new open work. A session not judged this sweep (budget,
    error, skipped by gather, aborted sweep) keeps what was remembered. No name is skipped but PROTECT (EL-T2490: uiux
    and homepage are nudged like every session; NEVER_CLOSE only stops a close). Types nothing into any pane."""
    if not cfg["NUDGE_EVENTS"]:
        return []
    st = Path(os.path.expanduser(cfg["NUDGE_STATE"]))
    try:
        sent = {str(x) for x in json.loads(st.read_text())}
    except (OSError, ValueError, TypeError):
        sent = set()
    seen_sids, judged, cur, new = set(), set(), set(), []
    seen_sids |= {(SKIPPED_INFO.get(label) or {}).get("sid") for label, _, live in SKIPPED if live} - {None}  # live, not gathered
    for s, keep, outcome in seen:
        seen_sids.add(s["sid"][:8])
        # decide() names open work only for a session idle past IDLE_MINUTES (busy gets status:busy, a short idle
        #  idle:N<..min, an owed step only past the threshold), so only such a session can say its work changed
        if (outcome == "error" or any(k.startswith("unjudged:") for k in keep) or s["status"] != "idle"
                or s["idle_min"] < float(cfg["IDLE_MINUTES"])):
            continue
        judged.add(s["sid"][:8])
        if not keep or not all(k.startswith(OPEN_WORK) for k in keep) or not any(k.startswith(NUDGE_FOR) for k in keep):
            continue
        fp = f"{s['sid'][:8]}:" + ",".join(sorted(keep))
        if fp in sent:  # already nudged for exactly this: remembered, busy or idle
            cur.add(fp)
            continue
        names = [n for n in (s["tmux"], s.get("name")) if n]
        if protected(cfg, *names):
            continue
        state = pane_state(s["pane"]) if s.get("pane") else None
        if not state or not empty_prompt(state):  # working, a menu, or a draft in the input: not idle at ❯
            continue
        cur.add(fp)
        new.append((s["tmux"], fp))
    # an ended session's sid leaves the sweep; drop it then (not on an empty, aborted sweep)
    keep_sent = {fp for fp in sent if fp.split(":", 1)[0] not in judged
                 and (not seen_sids or fp.split(":", 1)[0] in seen_sids)} | cur

    def save(fps):
        st.parent.mkdir(parents=True, exist_ok=True)
        tmp = st.with_name(st.name + ".tmp")
        tmp.write_text(json.dumps(sorted(fps)))
        os.replace(tmp, st)
    save(keep_sent)  # at most once: remembered before the line is written
    if new:
        try:
            path = Path(os.path.expanduser(cfg["NUDGE_EVENTS"]))
            path.parent.mkdir(parents=True, exist_ok=True)
            stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))
            with open(path, "a") as f:
                f.writelines(f"{stamp} ROUTE nudge {t} {fp}\n" for t, fp in new)
        except OSError as e:  # not routed: forget them so the next sweep tries again
            save(keep_sent - {fp for _, fp in new})
            raise OSError(f"{e}; not routed: {', '.join(fp for _, fp in new)}") from e
    return [fp for _, fp in new]


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
    """Return the list of reasons that keep the session; empty means reap.

    With DONE_INBOX off and DONE_INBOX_SHADOW set (stima-api #6535), a kept session with a claim is decided a second
    time as if DONE_INBOX were that path; when that would reap it, `inbox_done_shadow` is set for the report
    (`would-close: inbox DONE (shadow)`) and nothing else changes. That is how the inbox-DONE close path earns its
    clean rounds before it is switched on (EL-FLOW-P2-2106, SCRIPT-SAFE-RULE)."""
    keep = _decide(s, cfg, now)
    # EL-T2520: an alarm with open work is FALSE_WAITING (report-only; never closed): the continue path fires on it.
    if said_waiting(s) and s["status"] == "idle":
        extra = waiting_keeps(s, cfg, now if now is not None else time.time()) if cfg.get("DONE_GRACE") == "shadow" else []
        work = [k for k in keep + extra if k.startswith(FALSE_WAITING)]
        if work:
            s["false_waiting"] = sorted(set(work))
    # EL-T2512: the same second decide under DONE_GRACE=apply, for a session that said it is done (the idle wait
    # alone keeps it) or ends on an alarm (EL-T2520: idle or claim-unknown keeps it).
    if (keep and cfg.get("DONE_GRACE") == "shadow"
            and ((said_done(s) and any(k.startswith("idle:") for k in keep))
                 or (said_waiting(s) and all(k.startswith(("idle:", "claim-unknown")) for k in keep)))):
        try:
            s["done_grace_shadow"] = not _decide(dict(s), dict(cfg, DONE_GRACE="apply"), now)
        except Exception as e:  # a report-only trial must not turn a kept session into an error
            s["done_grace_error"] = f"{type(e).__name__}: {e}"
    shadow = cfg.get("DONE_INBOX_SHADOW")
    if keep and shadow and not cfg.get("DONE_INBOX") and s["claims"]:
        s["inbox_done_shadow"] = not _decide(dict(s), dict(cfg, DONE_INBOX=shadow), now)
    # EL-T24: the same second decide for a claim-less session under NOCLAIM_DONE=shadow. It can change the verdict
    # only where `claim-unknown` kept the session, so only those pay for it.
    if keep and cfg.get("NOCLAIM_DONE") == "shadow" and not s["claims"] and "claim-unknown" in keep:
        trial = dict(s)
        try:
            if not _decide(trial, dict(cfg, NOCLAIM_DONE="apply"), now) and trial.get("noclaim_done"):
                s["noclaim_done_shadow"] = trial["noclaim_done"]
        except Exception as e:  # a report-only trial must not turn a kept session into an error
            s["noclaim_shadow_error"] = f"{type(e).__name__}: {e}"
    return keep


def noclaim_done(s, cfg, now):
    """Why a claim-less session counts as done, or "" (EL-T24). The idle dispatch, sec-p1 and apertis-ops sessions
    work in the primary checkout with no worktree, so they have no claim and were kept by `claim-unknown` for good.

    Done when the newest inbox header the session wrote (DONE_INBOX, else DONE_INBOX_SHADOW, matched on the tmux
    and session names as inbox_done() does) is DONE, at least IDLE_MINUTES old and not older than the session's
    newest prompt (a later task voids it); and nothing is left: no worktree claim, no issue its text names whose
    oracle claimant is this session, no live child process, no background shell, loop or scheduled task, no
    uncommitted or unpushed work in an owned worktree or the cwd, and not NEVER_CLOSE. Every other gate in
    _decide() still applies; this only answers `claim-unknown`. Any failure to read is "" (kept)."""
    names = [n for n in (s["tmux"], s.get("name")) if n]
    if (s["claims"] or s.get("descendants") != 0 or s["bg_shells"] or s["loop"] or s["crons"] > 0 or s["scheduled"]
            or any(fnmatch.fnmatch(n.lower(), p.lower()) for p in cfg["NEVER_CLOSE"].split() for n in names)):
        return ""
    hit = inbox_done_header(cfg.get("DONE_INBOX") or cfg.get("DONE_INBOX_SHADOW"), names)
    if not hit:
        return ""
    at, key = hit
    prompt_at = s.get("prompt_at") or 0
    # The header has minute precision: a prompt in the header's own minute may have come after it, so it keeps.
    if now - at < float(cfg["IDLE_MINUTES"]) * 60 or not prompt_at or prompt_at >= at:
        return ""
    cwd = s.get("cwd")
    extra = [{"path": Path(cwd)}] if cwd and not any(str(w["path"]) == cwd for w in s["owned"]) else []
    if any(worktree_state(w, cfg) for w in [*s["owned"], *extra]):
        return ""
    if oracle_claims(s, cfg, now):
        return ""
    return f"inbox {key} DONE"


def stall_mark(cfg, sid, now=None):
    """Fingerprints stall-watch.py currently sees on this session ("" when none, stale, over its cap, or unreadable).

    The mark must be refreshed within STALL_MARK_HOURS and must not be older than STALL_MARK_MAX_HOURS from the
    event's first sighting (`since`); both ages are absolute values, so a timestamp in the future expires too."""
    if not cfg.get("STALL_MARK_DIR") or not re.fullmatch(r"[\w-]+", sid or ""):
        return ""
    f = Path(os.path.expanduser(cfg["STALL_MARK_DIR"])) / f"{sid}.json"
    at = now if now is not None else time.time()
    try:
        d = json.loads(f.read_text())
        fps = d.get("fingerprints")
        if not isinstance(fps, list) or not fps or not all(isinstance(x, str) for x in fps) or d.get("sid") != sid:
            return ""  # not a mark (for example a session file in a misconfigured directory)
        refreshed = max(abs(at - f.stat().st_mtime), abs(at - float(d.get("updated", 0))))
        if refreshed > float(cfg["STALL_MARK_HOURS"]) * 3600 \
                or abs(at - float(d.get("since", 0))) > float(cfg["STALL_MARK_MAX_HOURS"]) * 3600:
            return ""
        return ",".join(fps)
    except (OSError, ValueError, AttributeError, TypeError):
        return ""


def _ends_on(s, rx):
    """A bare `rx` line among the last three of the reply that ends the transcript, outside a code fence, written
    after the last prompt."""
    lines = [ln for ln in (s.get("last_text") or "").splitlines() if ln.strip()]
    tail = lines[-3:]
    fenced = sum(ln.lstrip().startswith("```") for ln in lines[:len(lines) - len(tail)]) % 2
    return (not fenced and not any(ln.lstrip().startswith("```") for ln in tail)
            and any(rx.match(ln) for ln in tail)
            and (s.get("text_at") or 0) > (s.get("prompt_at") or 0))


def said_done(s):
    """The newest assistant text says the session is done, and nobody prompted it since (EL-T2512)."""
    return _ends_on(s, GRACE_RE)


def said_waiting(s):
    """The newest reply ends on `SESSION-STATE: WAITING_UNTIL=<iso>` and does not also say it is done (EL-T2520)."""
    return not said_done(s) and _ends_on(s, WAIT_RE)


def waiting_keeps(s, cfg, now):
    """What keeps an alarm from being pure (EL-T2520): it stands in for claim-unknown, so it carries noclaim_done()'s
    gates (minus the inbox header) and adds the alarm's own: unread or past, an open PR, no worktree to read PRs from."""
    m = next((WAIT_RE.match(ln) for ln in reversed((s.get("last_text") or "").splitlines()) if WAIT_RE.match(ln)), None)
    try:
        due = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M")) if m else 0
    except ValueError:
        due = 0
    keep = [] if due > now else ["alarm-passed"]  # nothing wakes a claim-less session whose alarm has passed
    if s.get("descendants") != 0:
        keep.append("child-process")
    names = [n for n in (s["tmux"], s.get("name")) if n]
    if any(fnmatch.fnmatch(n.lower(), p.lower()) for p in cfg["NEVER_CLOSE"].split() for n in names):
        keep.append("never-close")
    cwd = s.get("cwd")
    if cwd and not any(str(w["path"]) == cwd for w in s["owned"]):
        keep.extend(worktree_state({"path": Path(cwd)}, cfg))
    named = oracle_claims(s, cfg, now) if not s["claims"] else []
    if named:
        keep.append("named-claim:" + ",".join(f"#{n}" for _, n in named))
    keep.extend(open_prs(s) if s["owned"] else ["open-pr-unknown:no-worktree"])
    return keep


_pr_cache = {}


def open_prs(s):
    """Keep reasons for open pull requests on the branches of the session's own worktrees: `open-pr:<repo>#N`, or
    `open-pr-unknown:<branch>` when GitHub cannot say (kept)."""
    out = []
    for w in s["owned"]:
        repo, branch = gh_repo(w["repo"]), w.get("branch") or ""
        if branch in ("main", "master"):
            continue
        if not branch or re.fullmatch(r"[0-9a-f]{7,40}", branch):  # detached HEAD: no branch to ask about
            out.append(f"open-pr-unknown:{w['path'].name if w.get('path') else branch}")
            continue
        key = (repo, branch)
        if key not in _pr_cache:
            rc, txt = run(["gh", "pr", "list", "-R", repo, "--head", branch, "--state", "open",
                           "--json", "number", "-q", ".[].number"], 30) if repo else (1, "")
            _pr_cache[key] = txt.split() if rc == 0 else None
        nums = _pr_cache[key]
        out += [f"open-pr-unknown:{branch}"] if nums is None else [f"open-pr:{repo}#{n}" for n in nums]
    return out


def idle_threshold(s, cfg):
    """Minutes a session must sit idle before it can close: IDLE_MINUTES, or DONE_GRACE_MINUTES when DONE_GRACE=apply
    and said_done(). The grace replaces only the idle wait; every other keep gate still applies."""
    idle = float(cfg["IDLE_MINUTES"])
    if cfg.get("DONE_GRACE") == "apply" and (said_done(s) or said_waiting(s)):
        return min(idle, float(cfg.get("DONE_GRACE_MINUTES") or idle))
    return idle


def _decide(s, cfg, now=None):
    keep = []
    stalled = stall_mark(cfg, s.get("sid"), now)
    if stalled:  # an account switch or rate limit stalled it: not idle, not finished
        keep.append("stalled:" + stalled)
    if s.get("never_kill"):  # its process tree holds a pid on the never-kill list
        keep.append("never-kill:" + ",".join(str(p) for p in s["never_kill"]))
    if protected(cfg, s["tmux"], s["name"]):
        keep.append("protected")
    if not s.get("fg", True):
        keep.append("not-foreground")
    if s.get("vim"):
        keep.append("vim-mode")
    if s["status"] != "idle":
        keep.append(f"status:{s['status']}")
    elif s["idle_min"] < idle_threshold(s, cfg):
        keep.append(f"idle:{s['idle_min']:.0f}<{idle_threshold(s, cfg):g}min")
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
    if not done and not s["claims"] and cfg.get("NOCLAIM_DONE") == "apply":
        s["noclaim_done"] = noclaim_done(s, cfg, now if now is not None else time.time())
        done = bool(s["noclaim_done"])
    if done:
        if s["status"] == "idle" and s["idle_min"] >= idle_threshold(s, cfg) and s["claims"]:
            # A claim the oracle now names another live session for (the issue was handed over) carries that
            # session's check-by, not this one's (EL-T2512: homepage kept by #6515 after pr-drain claimed it).
            at = now if now is not None else time.time()
            mine = [w["marker"] for w in s["owned"] if w.get("marker")]
            # Check-bys exist only on CHECKBY_REPO issues (the oracle reads no other repo), so a claim elsewhere has
            # none to keep it: homepage's docs worktree `claude/6361-…` was read as apertis-ai/docs#6361, which does
            # not exist, and kept it as check-by-unknown for good.
            cb = [checkby_state(r, n, cfg) for r, n in s["claims"] if r == cfg["CHECKBY_REPO"]
                  and classify_claim(oracle_brief(r, n, cfg, at), s["sid"], at, s.get("other_sids", ()), mine)[0]
                  != "ended"]
            if "OPEN" in cb:
                keep.append("check-by-open")
            elif "UNKNOWN" in cb:
                keep.append("check-by-unknown")
    else:
        # the alarm's gates only decide an early close: a claimed session past IDLE_MINUTES keeps main's path
        waiting = (cfg.get("DONE_GRACE") == "apply" and said_waiting(s)
                   and not (s["claims"] and s["idle_min"] >= int(cfg["IDLE_MINUTES"])))
        if waiting:
            keep.extend(waiting_keeps(s, cfg, now if now is not None else time.time()))
        if not s["claims"] and not waiting:
            keep.append("claim-unknown")
        elif s["status"] == "idle" and s["idle_min"] >= idle_threshold(s, cfg):
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


def judge_order(s, cfg):
    """Sort key: the sessions most likely to close come first, so a budget cut leaves only the busy ones unjudged
    (#6477: 13 of 18 ended `unjudged:run-budget`, so nothing was ever reaped). Idle past the threshold before the
    rest, protected last (they never close), fewer claims first (an issue each costs a lookup), longest idle first."""
    idle = s["status"] == "idle" and s["idle_min"] >= idle_threshold(s, cfg)
    names = [n for n in (s["tmux"], s.get("name")) if n]
    return (2 if protected(cfg, *names) else 0 if idle else 1, len(s["claims"]), -s["idle_min"])


def prefetch(sessions, cfg, now):
    """Fill the caches for every session at once, in judging order: all claimed issue states in one GraphQL call per
    repo, then the oracle briefs, comments and check-by reads, then the worktree checks, 8 at a time. Serially, at
    load 100, decide() spent 160 s in oracle_brief and the claim-time `gh issue view` calls alone outlasted
    RUN_BUDGET (#6477, EL-SESSION-CLOSE); each call is still bounded by its own subprocess timeout. A job not
    started by PREFETCH_BUDGET is dropped. Failures leave the cache empty: decide() retries."""
    batch_issue_states([ref for s in sessions for ref in s.get("claims") or ()])
    jobs = []
    for s in sessions:
        done = DONE_RE.search(s["last_text"]) or DONE_PHRASE_RE.search(s["last_text"])
        idle = s["status"] == "idle" and s["idle_min"] >= idle_threshold(s, cfg)
        for r, n in s.get("claims") or ():
            jobs.append(lambda r=r, n=n: oracle_brief(r, n, cfg, now))
            jobs.append(lambda r=r, n=n, sid=s["sid"]: claim_time(r, n, sid))
            if done and idle:
                jobs.append(lambda r=r, n=n: checkby_state(r, n, cfg))
        jobs.extend(lambda w=w: worktree_state(w, cfg) for w in s.get("owned") or ())
    budget = float(cfg.get("PREFETCH_BUDGET", "600"))

    def job(j):
        if time.monotonic() - RUN_START <= budget:
            try:
                j()
            except Exception:
                pass  # the cache stays empty and decide() asks again
    pool = ThreadPoolExecutor(max_workers=int(cfg.get("PREFETCH_WORKERS", "8")))
    try:
        for f in [pool.submit(job, j) for j in jobs]:
            f.result()  # a job never raises; the run deadline (SIGALRM) does, and it ends the sweep
    finally:
        pool.shutdown(wait=True, cancel_futures=True)


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
    idle = s["status"] == "idle" and s["idle_min"] >= idle_threshold(s, cfg)
    claims = list(s["claims"])
    marks = []
    mine = [w["marker"] for w in s["owned"] if w.get("marker")]

    def judge(refs):
        for (r, n), b in zip(refs, [oracle_brief(r, n, cfg, now) for r, n in refs]):
            for m in BLOCKED_RE.findall(b or ""):
                block(m)
            marks.append(classify_claim(b, s["sid"], now, s.get("other_sids", ()), mine)[0])
    if idle:
        judge(claims)  # worktree claims: decide() already briefed them, so these hit the cache
    out = {"would_close": "", "blocked": blocked, "claims": claims}
    never = [n for n in (s["tmux"], s.get("name")) if n]
    if (not keep or not idle or blocked or s["asking"] or s["bg_shells"] or s.get("sub_active")
            or any(not k.startswith(SOFT_KEEP) for k in keep)
            or any(fnmatch.fnmatch(n.lower(), p.lower()) for p in cfg["NEVER_CLOSE"].split() for n in never)
            or protected(cfg, *never)):
        return out
    cwd_wt = [] if any(str(w["path"]) == s.get("cwd") for w in s["owned"]) or not s.get("cwd") \
        else [{"path": Path(s["cwd"])}]
    if any(worktree_state(w, cfg) for w in [*s["owned"], *cwd_wt]):
        return out
    # Only a session every cheap gate leaves standing pays for the oracle lookups of the issues its text names.
    named = oracle_claims(s, cfg, now)
    claims += named
    judge(named)
    if blocked:
        return out
    text = s["last_text"]
    if not claims:
        if DONE_RE.search(text) or DONE_PHRASE_RE.search(text) or CLOSE_LINE_RE.search(text):
            out["would_close"] = "no claim, close line"
        elif keep == ["claim-unknown"] and s["idle_min"] >= float(cfg.get("NOCLAIM_IDLE_MINUTES", "480")):
            # A session that finished without a close line never closes (founder 2026-10-29: 「session 如果已經都
            # 完全做完, 該session就應該自己關掉」). Shadow first (SCRIPT-SAFE): nothing else keeps it, nothing is
            # unpushed, no claim anywhere, and nobody typed to it for NOCLAIM_IDLE_MINUTES.
            out["would_close"] = f"no claim, idle {s['idle_min'] / 60:.0f}h, no close line"
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
            if st and never_kill_hit(table, st["pane_pid"], pid, cfg):
                mark_record(path, "never-kill")  # finished, but its pane holds a never-kill pid: left open
                continue
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
    if never_kill_hit(table, state["pane_pid"], s["pid"], cfg):
        return "skipped:never-kill", []
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
        if state and never_kill_hit(ps_table(), state["pane_pid"], s["pid"], cfg):
            return "skipped:never-kill", [f"{s['tmux']}: claude exited, pane {s['pane']} left open: it holds a never-kill pid"]
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
    why += ["would-close: inbox DONE (shadow)"] if s.get("inbox_done_shadow") else []
    why += ["would-close: done grace (shadow)"] if s.get("done_grace_shadow") else []
    why += ["FALSE_WAITING: " + ",".join(s["false_waiting"])] if s.get("false_waiting") else []
    why += [f"would-close: no claim, {s['noclaim_done_shadow']} (shadow)"] if s.get("noclaim_done_shadow") else []
    if s.get("claim_why"):  # name why no claim was found
        keep = [f"claim-unknown({s['claim_why']})" if k == "claim-unknown" else k for k in keep]
    blocked = [", ".join(f"blocked: #{n}" for n in s["blocked"])] if s.get("blocked") else []
    return (f"| {s['tmux']} | `{s['sid'][:8]}` | {s['status']} {s['idle_min']:.0f}m | {issues} | "
            f"{outcome} | {', '.join([*keep, *why, *blocked]) or '-'} | {background_only} | {new_only} | {plan} |")


def unjudged_line(label, why):
    """A live session gather did not return (a background session, a missing pane): listed, never acted on."""
    i = SKIPPED_INFO.get(label) or {"name": label, "sid": "-", "status": "-", "idle_min": None, "pid": "-"}
    idle = "?" if i["idle_min"] is None else f"{i['idle_min']:.0f}"
    return (f"| {i['name']} | `{i['sid']}` | {i['status']} {idle}m | - | unjudged | {why} | - | - | "
            f"pid {i['pid']}; never acted on |")


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
    # #6477, 2026-10-29: RUN_BUDGET is checked between sessions, so a run blocked inside one call (pid 22262, 30 min
    # at load 187) still wrote no report. A hard deadline raises in the sweep, whose handler records it, and the
    # report is written; SIGUSR1 dumps the stack to the log to show where a run is blocked.
    faulthandler.register(signal.SIGUSR1)
    faulthandler.dump_traceback_later(max(1, int(RUN_BUDGET)))  # a run past its budget logs where it is, unasked

    def _deadline(*_):
        global RUN_BUDGET
        RUN_BUDGET = -1  # every later session is kept unjudged
        if IN_REAP:  # never interrupt a close half-way: the reap finishes, the loop then stops judging
            return
        raise TimeoutError(deadline_msg)
    deadline_msg = f"run passed RUN_BUDGET+300 ({RUN_BUDGET + 300:.0f} s); remaining sessions unjudged, nothing more reaped"
    signal.signal(signal.SIGALRM, _deadline)
    signal.alarm(max(1, int(RUN_BUDGET + 300)))
    try:
        if apply and not args.only:
            stale = recover_exiting(cfg, now)
    except Exception as e:
        failures.append(f"recover exiting: {type(e).__name__}: {e}")
    try:
        sessions = sorted(gather(cfg, now), key=lambda x: judge_order(x, cfg))
        if not args.only:
            prefetch(sessions, cfg, now)
        for s in sessions:
            if args.only and s["tmux"] != args.only:
                continue
            if time.monotonic() - RUN_START > RUN_BUDGET:
                rows.append(report_line(s, ["unjudged:run-budget"], "keep"))
                seen.append((s, ["unjudged:run-budget"], "keep"))
                continue
            keep, outcome = [], "error"
            try:
                keep = decide(s, cfg)
                if s.get("done_grace_error"):
                    notes.append(f"{s['tmux']} ({s['sid']}): DONE_GRACE shadow: {s['done_grace_error']}")
                if s.get("noclaim_shadow_error"):
                    notes.append(f"{s['tmux']} ({s['sid']}): NOCLAIM_DONE shadow: {s['noclaim_shadow_error']}")
                outcome = "keep" if keep else ("reap" if apply else "would-reap")
                if keep:  # shadow only: the outcome label changes, nothing below acts on it
                    try:
                        sv = shadow_verdict(s, cfg, keep, now)
                        s["blocked"], s["would_close"] = sv["blocked"], sv["would_close"]
                        outcome = ("would-close" if sv["would_close"] or s.get("noclaim_done_shadow") or s.get("done_grace_shadow")
                                   else outcome)
                    except Exception as e:  # a report-only verdict must not fail the sweep
                        notes.append(f"{s['tmux']} ({s['sid']}): shadow verdict: {type(e).__name__}: {e}")
                if not keep and apply:
                    global IN_REAP
                    IN_REAP = True
                    try:
                        outcome, fails = reap(s, cfg, now)
                    finally:
                        IN_REAP = False
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
    signal.alarm(0)
    faulthandler.cancel_dump_traceback_later()
    try:  # after the alarm is off, so the deadline cannot cut it between the state write and the event line
        if not args.only:
            for fp in nudge_events(cfg, seen, now):
                notes.append(f"nudge routed: {fp}")
    except Exception as e:  # a nudge must not stop the report
        failures.append(f"nudge: {type(e).__name__}: {e}")
    mode = "apply" if apply else "report-only"
    stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(now))
    report = [f"# session-reaper {mode} {stamp}", "",
              f"idle threshold {cfg['IDLE_MINUTES']} min; protected: {cfg['PROTECT'] or '(none)'}", "",
              "| tmux | session | status idle | issues | outcome | keeps it | held only by background shells "
              "| kept only by new gates | verification target |",
              "|---|---|---|---|---|---|---|---|---|", *rows,
              *[unjudged_line(label, why) for label, why, is_live in SKIPPED if is_live]]

    def idle_of(label):
        m = (SKIPPED_INFO.get(label) or {}).get("idle_min")
        return "?" if m is None else f"{m:.0f}"
    live = [f"- {label}: {why} (unjudged, idle {idle_of(label)}m)" for label, why, is_live in SKIPPED if is_live]
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
