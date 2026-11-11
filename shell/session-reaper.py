#!/usr/bin/env python3
"""Reap finished interactive Claude Code sessions that run in tmux.

A session is reaped only when every gate holds: idle long enough, no background work, done
(a SESSION-DONE line or every claimed issue closed), its worktrees clean and pushed, not
waiting on a person, and not protected. Reaping types /exit at a verified empty prompt
(Stay if the background-task menu appears), kills the tmux session once claude has exited,
then verifies the process tree, tmux session, session file and worktree locks are gone.

Report-only unless the config sets APPLY=1 or --apply is passed.

Oracle gate (stima-api #7001): a claimed issue whose `delivery_state.py N --brief` says the step is not the session's
no longer keeps an idle session: reason `oracle:not-mine`, `would-close` in the report under ORACLE_NOT_MINE=shadow
(the default), a real close under ORACLE_NOT_MINE=apply. Not the session's means one of two oracle shapes, and nothing
else: a stop the session already reported (`  stop: <reason> (reported)`, with a `wake:` line) while the issue has no
pending or due check-by; or a wait whose check-by the session posted itself (the `--json` claimant is this session and
the check-by comment is newer than its newest claim) and that is still ahead. Spot-check: the report row names each
claim and its waker; compare with `--brief` of the same issue.

A not-mine close never releases the claim: its issue comment (notmine_comment) has no `Released by` first line, so the
claim stays on this session and the stranded-step dispatcher can `claude --resume` it, with its context, at the
check-by or wake. The release comment of stima-api #7000 is for a session closed as finished, not for one whose step
is merely someone else's for now; the not-mine comment carries its own marker (`session-reaper-notmine:<sid>:<pid>`),
so the finished comment and its release still come when the resumed session is closed as finished.

Shadow verdict (#6477): a kept session that a person would also call finished gets the outcome
`would-close` in the report. It is never acted on: reap() runs only for a session with no keep reason.
"""

import argparse
import calendar
import faulthandler
import fcntl
import fnmatch
import glob
import hashlib
import importlib.util
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
import types
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
    "HANDOFF_ROOT": "",  # a path under it named in the last message must exist; empty: off
    "REAPED_DIR": "~/.cc-reaper/state/reaped",  # one record per reaped tmux name, written before /exit
    "IDLE_LIST_HOURS": "0",  # list idle/shell sessions with no claimed issue idle this long; 0: off
    "IDLE_LIST_FILE": "~/.cc-reaper/state/idle-sessions.md",  # rewritten every sweep with that list
    "CHECKBY_ORACLE": "/Users/stimaclaw/GitHub/stima-api/scripts/ci/delivery_state.py",  # --json: pending_check_by, due_check
    "CHECKBY_REPO": "theQuert/stima-api",  # the only repo the oracle reads; a claim elsewhere is UNKNOWN (kept)
    "ORACLE_ROOT": "/Users/stimaclaw/GitHub/stima-api",  # checkout whose `scripts/ci/delivery_state.py N --brief` judges an idle session's open claims
    "ORACLE_CACHE_DIR": "~/.cc-reaper/state/oracle-brief",  # one brief per issue, reused for ORACLE_CACHE_MINUTES (GitHub REST budget)
    # Longer than the 30-minute launchd interval, so a brief read by one run serves the next (stima-api#7904: at 10 the
    # cache never outlived a run). A session about to close re-reads its claims fresh first (confirm_close()).
    "ORACLE_CACHE_MINUTES": "45",
    "ORACLE_TIMEOUT_SECONDS": "60",  # one --brief read; 30 s timed out under load with 8 parallel reads (stima-api #7061)
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
    # Space- or comma-separated pids: a session whose process tree holds one is kept (`never-kill:<pid>`) and its
    # pane is never killed. The environment variable of the same name wins over this value.
    "CC_NEVER_KILL_PIDS": "70987 4565",
    # stima-api #7001: a claimed issue whose oracle brief says the step is not this session's (a stop it reported, or a
    # wait on a check-by it posted itself; module docstring) does not keep an idle session. `shadow` reports `would-close: oracle:not-mine`
    # and closes nothing (SCRIPT-SAFE-RULE: run it for three reaper reports, then switch to `apply`); `off` neither.
    "ORACLE_NOT_MINE": "shadow",
    # stima-api #7061: where the lock, sessions.json and the shadow round counter live; empty: ~/.cc-reaper/state.
    "STATE_DIR": "",
    # `on`: every sweep judges each session with session_state.py (WORKING, PUSH, WAITING_PERSON, DONE, UNKNOWN), writes
    # sessions.json and lets decide() read it; `off`: neither (the reaper then decides as before #7061).
    "SESSION_STATE": "on",
    # `apply`: a session the state calls DONE, kept only by STATE_SOFT reasons and passing every existing gate
    # (state_gates()), closes; `shadow`: a `would-close: state DONE` row only; `off`: neither. Its own column and counter.
    "STATE_DONE": "shadow",
    # Clean shadow rounds in a row (each with a candidate, at least 3 distinct sessions over the streak, 25+ min apart,
    # counted only on the live config at APPLY=1) after which the sweep writes `<FLAG>=apply` for that one source
    # (STATE_DONE, ORACLE_NOT_MINE) into the live policy, with a line in the report.
    "SHADOW_CLEAN_ROUNDS": "5",
    # stima-api#7106: `on`: at APPLY, a session whose newest reply (written after its last prompt) ends on a bare
    # SESSION-DONE line (said_done) gets `claude-task-done` (session=<id>, at=<UTC>) in its scratchpads (<SCRATCH_ROOT>/*/<id>) and in
    # <JOBS_DIR>/<first 8 of id> when they exist; reclaim-byproducts.sh then reaps them once nothing holds them.
    "DONE_MARKER": "on",
    "SCRATCH_ROOT": "",  # empty: /tmp/claude-<uid>
    "JOBS_DIR": "~/.claude/jobs",
    # stima-api#7527: a claim whose claimant's name and id match no live tmux session and no live sessions.json entry, and
    # that is silent for DEAD_CLAIMS_HOURS, gets one `Released by` comment. `apply`: post (when the run applies);
    # `shadow`: list what it would post in the report; `off`: neither. At most DEAD_CLAIMS_MAX posts a run.
    "DEAD_CLAIMS": "apply",
    "DEAD_CLAIMS_HOURS": "6",
    "DEAD_CLAIMS_MAX": "40",
    "DEAD_CLAIMS_CACHE": "~/.cc-reaper/state/dead-claims-cache.json",  # issue -> claimant, kept while its updated_at holds
}
SESSIONS_DIR = HOME / ".claude" / "sessions"
PROJECTS_DIR = HOME / ".claude" / "projects"
MARKER = "claude-task-worktree"
TAIL_BYTES = 4 << 20
EXIT_WAIT_SECONDS = 20
DONE_RE = re.compile(r"(?m)^\W*SESSION-DONE:\s*(.+)$")
STATE_IDLE_RE = re.compile(r"(?m)^\W*SESSION-STATE:\s*IDLE_NO_WORK\b")
# The done-grace marker (EL-T2512) is stricter than DONE_RE: a bare LAST line of the reply, not
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
# The number starts the branch or follows a `/`. A hyphen does not start it (stima-api #7061 review): `canary-main-1031`,
# `chore/uiux-sync-1026` and `uiux-accept-1029` name no issue, and `claude/prompt-size-403-4389` is not #403.
ISSUE_RE = re.compile(r"(?:^|/)(\d{3,6})(?:-|$)")
# The shape new-task-worktree.sh makes, `claude-7001-p0sla-marker`: the number follows the branch's one leading word
# (stima-api #7001). It names an issue only on a CHECKBY_REPO worktree, through branch_issue(), cfg CHECKBY_REPO: on a skills or cc-reaper
# tree the number is still a stima-api issue, so it is nobody's claim there (a claim of a number the repo has no issue
# for leaves the record exiting after the close, #148 review).
WORD_ISSUE_RE = re.compile(r"^[a-z]+-(\d{3,6})(?:-|$)")
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


def branch_issue(branch, repo, checkby):
    """The (repo, number) a worktree branch claims, or None: ISSUE_RE on any GitHub repo, WORD_ISSUE_RE only on
    `checkby` (cfg CHECKBY_REPO). `repo` is the worktree path (its origin is read only when a shape matched) or an
    `owner/name`."""
    m = ISSUE_RE.search(branch or "")
    word = None if m else WORD_ISSUE_RE.search(branch or "")
    if not m and not word:
        return None
    name = repo if REPO_RE.fullmatch(str(repo)) else gh_repo(repo)
    if not name or (word and name != checkby):
        return None
    return name, (m or word).group(1)


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
_oracle_json_cache = {}


def _fetch_oracle_json(repo, num, cfg):
    """One `delivery_state.py N --json` call, shared with oracle_json(); None when it cannot say or for another repo."""
    d = None
    if repo == cfg["CHECKBY_REPO"]:  # the oracle would read another repo's issue with this number
        oracle = os.path.expanduser(cfg["CHECKBY_ORACLE"])
        root = os.path.dirname(os.path.dirname(os.path.dirname(oracle)))
        rc, out = run(["python3", oracle, str(num), "--json"], 60, cwd=root)
        try:
            d = json.loads(out) if rc == 0 else None
        except ValueError:
            d = None
    _oracle_json_cache[(repo, str(num))] = d
    return d


def oracle_json(repo, num, cfg):
    """`delivery_state.py N --json` for the claim, once per run (checkby_state() fills the same cache)."""
    key = (repo, str(num))
    return _oracle_json_cache[key] if key in _oracle_json_cache else _fetch_oracle_json(repo, num, cfg)


def checkby_state(repo, num, cfg):
    """OPEN when the repo's oracle reports a pending check-by or a due check; UNKNOWN when it cannot say."""
    key = (repo, num)
    if key not in _checkby_cache and repo != cfg["CHECKBY_REPO"]:
        _checkby_cache[key] = "UNKNOWN"  # the oracle would read another repo's issue with this number
    if key not in _checkby_cache:
        d = _fetch_oracle_json(repo, num, cfg)
        try:
            if d is None:
                raise ValueError("unread")
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
_fresh_this_run = set()  # (repo, num) keys whose brief was read from the oracle in this run: taken as is, never read twice


def _read_brief(repo, num, cfg, now):
    """One `delivery_state.py N --brief` run; the brief is cached on disk and in memory, None when the oracle cannot say."""
    key = (repo, str(num))
    cache = Path(os.path.expanduser(cfg["ORACLE_CACHE_DIR"])) / f"{repo.replace('/', '_')}-{num}.json"
    root = os.path.expanduser(cfg["ORACLE_ROOT"])
    rc, out = run(["python3", "scripts/ci/delivery_state.py", str(num), "--brief", "--repo", repo], float(cfg["ORACLE_TIMEOUT_SECONDS"]), cwd=root)
    brief = out if rc == 0 and out.startswith("delivery #") else None
    if brief is not None:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps({"at": now, "brief": brief}))
        except OSError:
            pass
    _brief_cache[key] = brief
    _fresh_this_run.add(key)
    return brief


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
    return _read_brief(repo, num, cfg, now)


def fresh_brief(repo, num, cfg, now):
    """The brief read from the oracle in this run: a key already read in this run is taken as is (no second read);
    otherwise it is read now, whatever the disk or memory cache holds, and replaces both."""
    if repo != cfg["CHECKBY_REPO"]:
        return None
    if (repo, str(num)) in _fresh_this_run:
        return _brief_cache.get((repo, str(num)))
    return _read_brief(repo, num, cfg, now)


def refresh_briefs(s, cfg, now, extra=(), used=None):
    """Numbers whose brief, once read in this run, differs from the one a verdict was built on. Looks at every issue a
    verdict on `s` rests on: its claims, `extra` refs (a loop's own #N), and, for a session with no claim, the issues
    its text names (what oracle_claims() looked at). The cache outlives a run (45 minutes), so a verdict that releases
    a session may not rest on it (stima-api#7904).

    `used` maps (repo, number) to the brief that verdict used (session_state.judge()): the key is read here when no one
    read it in this run, then the brief now in memory is compared with the one used. Another session's judgement may have
    read the key between this verdict's use and now, so that a key is in `_fresh_this_run` proves nothing about `used`.
    A key whose read in this run failed (None) is changed under `used`: it supports no DONE. Without `used`
    (confirm_close(), which runs after the judging threads), a key already read in this run counts unchanged."""
    refs = list(dict.fromkeys([*(s.get("claims") or ()), *((r, str(n)) for r, n in extra),
                               *(() if s.get("claims") else ((cfg["CHECKBY_REPO"], n) for n in named_issues(s, cfg)))]))
    changed = []
    for r, n in refs:
        key = (r, str(n))
        if used is None and key in _fresh_this_run:
            continue
        old = _brief_cache.get(key) if used is None else used.get(key)
        cur = fresh_brief(r, n, cfg, now)  # a key already read in this run is taken as is
        if r == cfg["CHECKBY_REPO"] and (cur != old or (used is not None and cur is None)):
            changed.append(str(n))
    return changed


BRIEF_STATE_RE = re.compile(r"\Adelivery #\d+: (\w+)")
BRIEF_KIND_RE = re.compile(r"\Adelivery #\d+: [^\n]*? -> (\w+)")
CLAIMANT_RE = re.compile(r"(?m)^\s*claimant:.*?session ([0-9A-Za-z-]+)(?: \(.*?\))?; the step is that session's")
OWNER_END_RE = re.compile(r"\A\s*owner: .+ wakes it; no watcher needed, and the session may end\Z")
CHECKBY_AT_RE = re.compile(r"check-by(?: scheduled for)?:? (\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?)")


def _same_session(a, b):
    return bool(a) and bool(b) and (a.startswith(b) or b.startswith(a))


# delivery_state.py appends lines after the owner / check-by-scheduled line that end a wait: `  judge: ...` (#7364),
# `  redundant check-by ...` (#7121) and the board estimate `board: ...` (#7270). They are the oracle's own trailer, not
# free text, so the line that ends a claim is the last line before them (stima-api #7001 check-by of 2026-11-07).
TRAILER_RES = (re.compile(r"\Aboard: (?:本地推算|無法本地推算) "),
               re.compile(r"\A  judge: \S"),
               re.compile(r"\A  redundant check-by \d{4}-\d\d-\d\dT\S+: the event-router wakes this session on "))


def _oracle_last(brief, rx):
    """The oracle's deciding line when `rx` (a whole-line pattern) matches the last line before the trailer and no
    other line of the brief: at most one board line, one judge line and one redundant-check-by line are dropped from
    the end, in that order. A trailer-shaped or `rx`-shaped line anywhere else is free text from a comment (the
    oracle prints each of these once, at a fixed place), and the brief then has no deciding line ("")."""
    lines = brief.rstrip("\n").split("\n")
    for trailer in TRAILER_RES:
        if len(lines) > 1 and trailer.match(lines[-1]):
            lines.pop()
    last = lines[-1]
    if any(trailer.match(last) for trailer in TRAILER_RES) or sum(1 for ln in lines if rx.match(ln)) != 1:
        return ""
    return last if rx.match(last) else ""


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
    last = _oracle_last(brief, OWNER_END_RE)
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


CHECKBY_END_RE = re.compile(r"\A\s*check-by scheduled for (\d{4}-\d\d-\d\dT[\d:]+Z?); the stranded-step dispatcher wakes "
                            r"the session then: end the turn\.\Z")
STOP_HEAD_RE = re.compile(r"\Adelivery #\d+: [^\n]*? -> stop (\S+)")
# delivery_state.brief(): `  stop: <reason> (reported)` once the stop marker is on the issue, `  stop: <reason>; post once
# with <marker>` while the session still owes it (stima-api #6945: an unreported stop is the session's step).
STOP_REPORTED_RE = re.compile(r"(?m)^  stop: (\S+) \(reported\)$")
WAKE_LINE_RE = re.compile(r"(?m)^  wake: (\S.*)$")
# delivery_state.py's own claim and check-by grammar (CLAIM_RE, CLAIM_SESSION_RE, CHECK_BY_RE), read the same way: a
# claim is a comment's first line outside code; a check-by in code or an HTML comment schedules nothing.
CLAIM_LINE_RE = re.compile(r"^[ \t*_]*claimed by\b", re.I)
_SESSION_ID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?"
CLAIM_SID_RE = re.compile(rf"\bsession[ \t*_]*(?:`({_SESSION_ID})`|\(({_SESSION_ID})\)|({_SESSION_ID})\b)", re.I)
CHECKBY_STAMP_RE = re.compile(r"(?<![\w-])check-by:?[ \t]+(\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?)(?:\.\d+)?(?:Z|[+-]00:00)")
FENCE_RE = re.compile(r"(?ms)^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n.*?(?:^[ \t]{0,3}\1[ \t]*$|\Z)")
HTML_COMMENT_RE = re.compile(r"(?s)<!--.*?-->")
INDENTED_RE = re.compile(r"(?m)^(?: {4}|\t).*$")
INLINE_CODE_RE = re.compile(r"(`+)[^`\n].*?\1")


def _cell(text, limit=160):
    """One table-safe line."""
    return " ".join(str(text).replace("|", "/").split())[:limit]


def _iso_epoch(stamp):
    """Epoch of `YYYY-MM-DDTHH:MM[:SS]...` read as UTC; None when it does not parse."""
    s = str(stamp or "")
    for n, fmt in ((19, "%Y-%m-%dT%H:%M:%S"), (16, "%Y-%m-%dT%H:%M")):
        try:
            return calendar.timegm(time.strptime(s[:n], fmt))
        except ValueError:
            pass
    return None


def _outside_code(body):
    """A comment's text outside fenced and indented code and HTML comments (delivery_state._readable, less inline)."""
    return INDENTED_RE.sub("", HTML_COMMENT_RE.sub("", FENCE_RE.sub("", str(body or "").replace("\r\n", "\n"))))


def oracle_not_mine(brief):
    """(`stop`|`wait`, why, due epoch or None) when the oracle's brief says the step is not this session's, else None
    (stima-api #7001). Pure parse; claim_class() adds the bindings that need the issue.

    Only the oracle's own lines count, never free text from an issue comment (the same rule as classify_claim): a
    `-> stop <reason>` header with the oracle's `  stop: <reason> (reported)` line and a `wake:` line (the stop is on
    the issue and a person or a record wakes it), or a `-> wait` header whose last line is the oracle's `check-by
    scheduled for <iso>; the stranded-step dispatcher wakes the session then`. An `agent` step, a stop the session has
    not reported yet (`; post once with <marker>`: it still owes that comment), a stop nothing wakes,
    and a wait with no check-by yet are the session's."""
    if not brief:
        return None
    k = BRIEF_KIND_RE.match(brief)
    last = _oracle_last(brief, CHECKBY_END_RE)
    if k and k.group(1) == "stop":
        head, rep, wake = STOP_HEAD_RE.match(brief), STOP_REPORTED_RE.search(brief), WAKE_LINE_RE.search(brief)
        if head and rep and rep.group(1) == head.group(1) and wake:
            return "stop", _cell(f"stop {head.group(1)} (reported); wake: {wake.group(1)}"), None
    elif k and k.group(1) == "wait":
        m = CHECKBY_END_RE.match(last)
        if m and _iso_epoch(m.group(1)) is not None:
            return "wait", f"wait check-by {m.group(1)}; the dispatcher wakes it", _iso_epoch(m.group(1))
    return None


def wait_bound(repo, num, s, mine, cfg, due):
    """True only when the posted check-by the wait names is this session's own (stima-api #7001 P1-2): the oracle's
    `--json` claimant is this session (its id or a worktree marker it owns), its pending check-by is `due`, and a
    comment scheduling that check-by was posted after this session's newest claim. The issue-wide earliest check-by
    can be another session's or a former owner's (a 7-day tripwire); anything unread or unmatched is False (kept)."""
    d = oracle_json(repo, num, cfg)
    if not isinstance(d, dict):
        return False
    c = d.get("claimant")
    cs = str(c.get("session") or "").lower() if isinstance(c, dict) else ""
    if not (_same_session(cs, s["sid"].lower()) or any(_same_session(cs, str(x).lower()) for x in mine)):
        return False
    if _iso_epoch(d.get("pending_check_by")) != due:
        return False
    comments = issue_comments(repo, num)
    if not comments:
        return False
    claimed = scheduled = None
    for cm in comments:
        at = _iso_epoch(cm.get("createdAt"))
        if at is None:
            continue
        text = _outside_code(cm.get("body"))
        first = next((ln for ln in text.splitlines() if ln.strip()), "")
        sm = CLAIM_SID_RE.search(first) if CLAIM_LINE_RE.match(first) else None
        if sm and _same_session(next(filter(None, sm.group(1, 2, 3))).lower(), cs):
            claimed = at if claimed is None or at > claimed else claimed
        if any(_iso_epoch(m.group(1)) == due for m in CHECKBY_STAMP_RE.finditer(INLINE_CODE_RE.sub("", text))):
            scheduled = at if scheduled is None or at > scheduled else scheduled
    return claimed is not None and scheduled is not None and scheduled > claimed


def claim_class(brief, repo, num, s, at, mine, cfg):
    """classify_claim() plus the not-mine rule: under ORACLE_NOT_MINE=apply an `unknown` claim whose brief names
    another waker is `ended`, recorded in s["oracle_not_mine"][num] for the report and the close log. Never for a
    NEVER_CLOSE session (the exemption is a separate rule, #7001 non-goals).

    A stop still keeps the session while the issue has a pending or due check-by (checkby_state() not CLEAR): at a
    stop the dispatcher does not take a due check (delivery_state `_deferred` does not run), so the session is the
    only one to answer it. A wait's check-by is the one the brief names, so it needs no second look; it needs
    wait_bound() instead, and a scheduled time still ahead of `at` (a cached brief can name a past one)."""
    cls, overdue = classify_claim(brief, s["sid"], at, s.get("other_sids", ()), mine)
    if cls == "unknown" and cfg.get("ORACLE_NOT_MINE") == "apply":
        names = [n for n in (s["tmux"], s.get("name")) if n]
        nm = oracle_not_mine(brief)
        if not nm or any(fnmatch.fnmatch(n.lower(), p.lower()) for p in cfg["NEVER_CLOSE"].split() for n in names):
            return cls, overdue
        kind, why, due = nm
        if kind == "stop" and checkby_state(repo, num, cfg) != "CLEAR":
            return cls, overdue
        if kind == "wait" and not (due > at and wait_bound(repo, num, s, mine, cfg, due)):
            return cls, overdue
        s.setdefault("oracle_not_mine", {})[num] = why
        return "ended", False
    return cls, overdue


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
            # message is one), which only makes a prompt look newer: fail-closed for the done-grace and state gates.
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
    if not any(ISSUE_RE.search(w["branch"]) or WORD_ISSUE_RE.search(w["branch"]) for w in owned):
        return "no-issue-branch:" + ",".join(w["path"].name for w in owned)
    if not any(r for r in repos):
        return "no-github-remote"
    return ""


def attached_pane(table, sid, session_ids):
    """Bind a background job for classification only. Never infer ownership from arbitrary arguments.

    Claude accepts abbreviated session ids; require at least eight characters and one matching session file.
    A second attaching pane is ambiguous, so it is not safe to attribute its screen to this job.
    """
    attach = []
    for pid, (_, _, command) in table.items():
        try:
            args = shlex.split(command)
        except ValueError:
            continue
        if len(args) != 3 or not CLAUDE_CMD.search(args[0]) or args[1] != "attach":
            continue
        target = args[2]
        if target == sid or (len(target) >= 8 and sid.startswith(target)
                             and sum(s.startswith(target) for s in session_ids) == 1):
            attach.append(pid)
    if not attach:
        return None
    rc, panes = tmux("list-panes", "-a", "-F", "#{pane_id}")
    if rc:
        return None
    matches = []
    for pane in set(panes.splitlines()):
        if not re.fullmatch(r"%[0-9]+", pane):
            continue
        state = pane_state(pane)
        if state:
            for pid in attach:
                if is_ancestor(table, state["pane_pid"], pid):
                    matches.append((pane, state, pid))
    return matches[0] if len(matches) == 1 else None


def gather(cfg, now, include_bg=False):
    """The live sessions the reaper judges. With include_bg (session_state.py, stima-api #7061) a background session
    no pane attaches to is returned too, marked `unattached` with no pane, and still listed in SKIPPED as `kind:bg`:
    the reaper's sweep drops it (it never closes a bg session), the state producer judges it."""
    table = ps_table()
    wts = worktrees(cfg)
    found = []
    SKIPPED.clear()
    SKIPPED_INFO.clear()
    records = []
    for f in sorted(SESSIONS_DIR.glob("*.json")):
        try:
            records.append((f, json.loads(f.read_text())))
        except (OSError, ValueError):
            continue
    session_ids = {d["sessionId"] for _, d in records if isinstance(d.get("sessionId"), str)}
    for f, d in records:
        pid = d.get("pid")
        running = pid in table
        kind = d.get("kind")
        if kind not in ("interactive", "bg"):
            _skip(d, f, f"kind:{d.get('kind')}", running, now)
            continue
        if kind == "interactive" and not d.get("tmux"):
            _skip(d, f, "no-tmux-field", running, now)
            continue
        alive = running and " ".join(d.get("procStart", "").split()) == table[pid][1]
        if not alive:
            _skip(d, f, "procstart-mismatch" if running else "pid-gone", running, now)
            continue
        attach_pid = None
        if kind == "bg":
            bound = attached_pane(table, d.get("sessionId") or "", session_ids)
            if not bound:
                _skip(d, f, "kind:bg", True, now)
                if include_bg and d.get("sessionId"):
                    found.append(_record(cfg, now, table, wts, f, d, None, None, None))
                continue
            pane, state, attach_pid = bound
        else:
            pane = d["tmux"].rsplit(".", 1)[-1]
            state = pane_state(pane)
        if not state:
            _skip(d, f, f"pane-missing:{pane}", True, now)
            continue
        if not is_ancestor(table, state["pane_pid"], attach_pid if kind == "bg" else pid):
            _skip(d, f, f"pane-ancestor-mismatch:{pane}", True, now)
            continue  # a pane that no longer holds this claude
        found.append(_record(cfg, now, table, wts, f, d, pane, state, attach_pid))
    # Only attached sessions count as another live session (stima-api #7061 review): a background loop that holds the
    # same claim must not turn an interactive session's claim into "another session's" (`ended`), as before include_bg.
    attached = [o for o in found if not o.get("unattached")]
    for s in found:
        s["other_sids"] = [o["sid"] for o in attached if o is not s and o["sid"]]
        s["other_claims"] = {ref for o in attached if o is not s for ref in o["claims"]}
    return found


def _record(cfg, now, table, wts, f, d, pane, state, attach_pid):
    """One gathered session. `state` None: a background session no pane attaches to (no screen, no tmux name)."""
    kind, pid = d.get("kind"), d.get("pid")
    sid, cwd = d["sessionId"], d.get("cwd", "")
    owned = [w for w in wts if w["marker"] == sid
             or (cwd + "/").startswith(str(w["path"]) + "/")]
    claims, repos = [], []
    for w in owned:
        claim = branch_issue(w["branch"], w["repo"], cfg["CHECKBY_REPO"])
        repos.append(claim[0] if claim else "")
        if claim and claim not in claims:
            claims.append(claim)
    s = {
        "kind": kind, "attach_pid": attach_pid,
        "file": str(f), "pid": pid, "sid": sid, "cwd": cwd, "name": d.get("name", ""),
        "tmux": state["session"] if state else (d.get("name") or sid[:8]), "pane": pane or "",
        "status": d.get("status"),
        "status_at": d.get("statusUpdatedAt"), "start": table[pid][1],
        "fg": foreground(attach_pid if kind == "bg" else pid) if state else False,
        "vim": vim_mode(),
        "idle_min": (now - d.get("statusUpdatedAt", now * 1000) / 1000) / 60,
        "bg_shells": [p for p, (pp, _, cmd) in table.items()
                      if pp == pid and "shell-snapshots/" in cmd],
        "scheduled": (Path(cwd) / ".claude" / "scheduled_tasks.json").exists(),
        "sub_active": subagent_activity(sid, now, float(cfg["SUBAGENT_QUIET_MINUTES"])),
        "screen_tail": "\n".join(state["screen"].rstrip("\n").split("\n")[-15:]) if state else "",
        "owned": owned, "claims": claims, "descendants": len(descendants(table, pid)),
        "claim_why": "" if claims else claim_why(owned, repos),
        "never_kill": never_kill_hit(table, state["pane_pid"] if state else pid, pid, cfg),
        **transcript_facts(transcript_path(sid), now),
    }
    if state is None:
        s["unattached"] = True
    return s


SID_RE = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
DONE_MARKER = "claude-task-done"


def _owned_dir(name, dir_fd=None):
    """An fd for directory `name` (relative to dir_fd when given), opened without following a link and owned by this
    user; None for anything else. Every step from the root down is opened this way, so a link swapped into the shared
    /tmp tree between a check and the write is never followed (stima-api#7106 security review)."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
    except OSError:
        return None
    try:
        if os.fstat(fd).st_uid == os.getuid():
            return fd
    except OSError:
        pass
    os.close(fd)
    return None


def _mark(dir_fd, label, sid, text_at, body, written, skipped):
    """Write the marker inside the open directory dir_fd, never through a link; an existing marker for this session
    no older than its reply is left as it is."""
    try:
        fd = os.open(DONE_MARKER, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
        try:
            st = os.fstat(fd)
            if (st.st_uid == os.getuid() and st.st_mtime >= text_at
                    and os.read(fd, 4096).decode(errors="replace").startswith(f"session={sid}\n")):
                return
        finally:
            os.close(fd)
    except FileNotFoundError:
        pass
    except OSError as e:  # ELOOP: a link at the marker path
        skipped.append(f"{label}/{DONE_MARKER}: not written ({e.strerror or e})")
        return
    try:
        fd = os.open(DONE_MARKER, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
    except OSError as e:
        skipped.append(f"{label}/{DONE_MARKER}: not written ({e.strerror or e})")
        return
    try:
        if os.fstat(fd).st_uid != os.getuid():
            skipped.append(f"{label}/{DONE_MARKER}: not written (not owned by this user)")
            return
        os.write(fd, body.encode())
    finally:
        os.close(fd)
    written.append(f"{label}/{DONE_MARKER}")


def write_done_markers(cfg, sessions, now, skipped=None):
    """stima-api#7106: mark the scratchpads and job directory of every session whose newest reply, written after its
    last prompt, says SESSION-DONE. Only existing directories this user owns, reached without following a link from
    a root that is itself no link and this user's; a marker already naming the session and no older than that reply
    is left as it is. Returns the markers written; what was refused is appended to `skipped`."""
    skipped = [] if skipped is None else skipped
    if cfg.get("DONE_MARKER", "on") != "on":
        return []
    root = os.path.expanduser(cfg.get("SCRATCH_ROOT") or f"/tmp/claude-{os.getuid()}")
    jobs = os.path.expanduser(cfg.get("JOBS_DIR") or "~/.claude/jobs")
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    # said_done(), not DONE_RE: the marker widens deletion, so only a reply that ENDS on a bare SESSION-DONE line,
    # outside a code fence and after the last prompt, counts; a reply that quotes or explains the line does not.
    done = [s for s in sessions if SID_RE.fullmatch(s.get("sid") or "") and said_done(s)]
    written = []
    if not done:
        return written
    for top, kind in ((root, "scratch"), (jobs, "jobs")):
        if not os.path.lexists(top):
            continue
        top_fd = _owned_dir(top)
        if top_fd is None:
            skipped.append(f"{top}: a link, not a directory or not this user's; nothing marked under it")
            continue
        try:
            parents = [(top_fd, top)]
            if kind == "scratch":
                parents = []
                for name in sorted(os.listdir(top_fd)):
                    fd = _owned_dir(name, top_fd)
                    if fd is not None:
                        parents.append((fd, f"{top}/{name}"))
            try:
                for s in done:
                    sid = s["sid"]
                    leaf = sid if kind == "scratch" else sid[:8]
                    for pfd, plabel in parents:
                        if not os.path.lexists(os.path.join(plabel, leaf)):
                            continue
                        fd = _owned_dir(leaf, pfd)
                        if fd is None:
                            skipped.append(f"{plabel}/{leaf}: a link, not a directory or not this user's; not marked")
                            continue
                        try:
                            _mark(fd, f"{plabel}/{leaf}", sid, s["text_at"], f"session={sid}\nat={stamp}\n",
                                  written, skipped)
                        finally:
                            os.close(fd)
            finally:
                for pfd, _ in parents:
                    if pfd != top_fd:
                        os.close(pfd)
        finally:
            os.close(top_fd)
    return written


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


def waiting_re(cfg):
    extra = cfg.get("WAITING_EXTRA", "")
    return re.compile(WAITING_RE.pattern + ("|" + extra if extra else ""), re.I)


def decide(s, cfg, now=None):
    """Return the list of reasons that keep the session; empty means reap."""
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
    # stima-api #7001: the same second decide under ORACLE_NOT_MINE=apply, for a session kept only by claims the oracle
    # cannot place (`issue-unknown`, a check-by it reads as open). Nothing else changes.
    if (keep and cfg.get("ORACLE_NOT_MINE") == "shadow" and s["claims"]
            and any(k.startswith(("issue-unknown:", "check-by-")) for k in keep)):
        trial = dict(s, oracle_not_mine={})
        try:
            if not _decide(trial, dict(cfg, ORACLE_NOT_MINE="apply"), now) and trial["oracle_not_mine"]:
                s["oracle_not_mine_shadow"] = dict(trial["oracle_not_mine"])
        except Exception as e:  # a report-only trial must not turn a kept session into an error
            s["oracle_not_mine_error"] = f"{type(e).__name__}: {e}"
    return state_keeps(s, cfg, keep, now)


# Keep reasons the session's state (session_state.py, stima-api #7061) may answer. A DONE state releases a session
# kept only by these, and only when every gate the reaper's own close paths apply also passes (state_gates()). Every
# other reason still keeps it: protected, never-kill, vim-mode, not-foreground, a subagent, a shell, a loop or
# scheduled task, a child process, a stall mark, a handoff, a question to a person (`waiting`), a step the oracle says
# is its own (`owed-step:`), uncommitted or unpushed work.
STATE_SOFT = ("claim-unknown", "issue-unknown:", "issue-open:", "check-by-", "open-pr", "alarm-passed",
              "named-claim:")
# Each shadow source has its own clean-round counter and flips only its own flag (stima-api #7061 review, finding 9).
SHADOW_SOURCES = ("STATE_DONE", "ORACLE_NOT_MINE")
ROUND_MIN_SECONDS = 25 * 60  # a round counts only this long after the last counted one (launchd runs every 30 min)
ROUND_MIN_SESSIONS = 3  # distinct candidate sessions a streak must have seen before its flag flips


def state_column(s):
    """"STATE_DONE" when the session's state is DONE, else ""."""
    st = s.get("state")
    return "STATE_DONE" if isinstance(st, dict) and st.get("state") == "DONE" else ""


def never_close(s, cfg):
    names = [n for n in (s.get("tmux"), s.get("name")) if n]
    return any(fnmatch.fnmatch(n.lower(), p.lower()) for p in cfg["NEVER_CLOSE"].split() for n in names)


def state_gates(s, cfg, keep, now):
    """Why a DONE state may not release this session, or "" when every existing gate passes. The gates are the
    reaper's own, called, not copied: for a claim-less session none (it is released only by its own `SESSION-DONE:` line,
    which decide() reads; the inbox DONE header that used to release it is gone, stima-api #7079), claim_class() under ORACLE_NOT_MINE=apply for each claim (NEVER_CLOSE, a stop
    with a check-by not CLEAR, a wait not bound to this session), and shadow_verdict()'s BLOCKED:#N."""
    if never_close(s, cfg):
        return "never-close"
    if not s["claims"]:
        return "no-claim"
    else:
        trial = dict(s, oracle_not_mine={})
        mine = [w["marker"] for w in s["owned"] if w.get("marker")]
        trial_cfg = dict(cfg, ORACLE_NOT_MINE="apply")
        for r, n in s["claims"]:
            cls = claim_class(oracle_brief(r, n, cfg, now), r, n, trial, now, mine, trial_cfg)[0]
            if cls != "ended":
                return f"claim #{n}: {cls}"
    blocked = shadow_verdict(s, cfg, keep, now)["blocked"]
    if blocked:
        return "blocked:" + ",".join(f"#{n}" for n in blocked)
    return ""


def state_keeps(s, cfg, keep, now=None):
    """`keep` after the state. A DONE session kept only by STATE_SOFT reasons, which passes every state_gates() gate,
    closes under STATE_DONE=apply and is a `would-close` row (s["state_shadow"]) under `shadow`. An applied close keeps
    every claim (a not-mine comment, no release) unless the oracle says the issue is closed, so the dispatcher can
    resume the session at its next step. Any error keeps the session (s["state_error"])."""
    try:
        if not state_column(s) or not keep or any(not k.startswith(STATE_SOFT) for k in keep):
            return keep
        mode = cfg.get("STATE_DONE", "shadow")
        if mode not in ("apply", "shadow"):
            return keep
        held = state_gates(s, cfg, keep, now if now is not None else time.time())
        if held:
            s["state_held"] = held
            return keep
        if mode == "shadow":
            s["state_shadow"] = "STATE_DONE"
            return keep
        refs = {str(n) for _, n in s.get("claims") or ()}
        notes = {str(c["issue"]): _cell(f"state DONE: {c.get('oracle_step') or 'unread'}", 120)
                 for c in s["state"]["claims"] if str(c["issue"]) in refs and c.get("oracle_step") != "closed"}
        s.setdefault("oracle_not_mine", {}).update(notes)
        s["state_close"] = "STATE_DONE"
        return []
    except Exception as e:  # the state can only release a session; failing to judge it keeps it
        s.pop("state_shadow", None)
        s.pop("state_close", None)
        s["state_error"] = f"{type(e).__name__}: {e}"[:200]
        return keep


def state_dir(cfg):
    return Path(os.path.expanduser(cfg["STATE_DIR"])) if cfg.get("STATE_DIR") else HOME / ".cc-reaper" / "state"


def live_config(config_path):
    """True when `config_path` is the reaper's live policy file, CONFIG."""
    try:
        return Path(os.path.expanduser(str(config_path))).resolve() == Path(CONFIG).expanduser().resolve()
    except (OSError, RuntimeError):
        return False


def state_file(cfg, live, ss):
    """Where this run writes sessions.json (`ss` is session_state), or None. Only a run on the live CONFIG with no
    threshold override (`live`) writes the file readers act on; any other run (a preview on a copied config,
    --idle-minutes) writes under its own STATE_DIR, and nowhere when that is unset or is the live directory."""
    if live:
        return ss.default_path(state_dir(cfg))
    if not cfg.get("STATE_DIR"):
        return None
    own = state_dir(cfg) / "sessions.json"
    return None if is_live_state_path(own, ss) else own


def is_live_state_path(path, ss):
    """True when `path` is a sessions.json readers act on (or cannot be resolved), so a non-live run must not write it."""
    lives = {ss.default_path(), HOME / ".cc-reaper" / "state" / "sessions.json"}
    try:
        lives.add(ss.default_path(state_dir(load_config(CONFIG))))
    except Exception:
        pass
    try:
        return Path(path).expanduser().resolve() in {Path(p).expanduser().resolve() for p in lives}
    except (OSError, RuntimeError):
        return True


def load_session_state():
    """session_state.py beside this file, or (None, why): a reaper installed without it decides as before #7061."""
    try:
        path = Path(__file__).resolve().with_name("session_state.py")
        spec = importlib.util.spec_from_file_location("session_state", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, ""
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"


STATE_ROWS = []  # the records of the last produce_state(), for the report


def produce_state(cfg, gathered, now, sdir, live=False):
    """Judge every gathered session (bg ones a pane does not attach to included) with session_state.py, attach each
    record as s["state"] for decide(), and write sessions.json where state_file() says. Returns report notes."""
    STATE_ROWS.clear()
    ss, why = load_session_state()
    if not ss:
        return [f"session_state unavailable ({why}): every session decided without a state"]
    records = ss.judge_all(types.SimpleNamespace(**globals()), gathered, cfg, now, int(cfg.get("PREFETCH_WORKERS", "8")))
    for s, rec in zip(gathered, records):
        s["state"] = rec
    STATE_ROWS.extend(records)
    unjudged = [{"label": label, "why": why} for label, why, live_ in SKIPPED if live_ and why != "kind:bg"]
    out = state_file(cfg, live, ss)
    if out is None:
        return ["sessions.json not written: not the live config with its own threshold, and no STATE_DIR of its own"]
    ss.write(ss.document(records, now, unjudged), out)
    return [] if live else [f"sessions.json written to {out} (not the live file: not the live config, or a threshold "
                            "override)"]


def state_table():
    rows = [f"| {_cell(x['name'], 60)} | `{x['sid'][:8]}` | {x['kind']} | {x['status']} {x['idle_min']:.0f}m | "
            f"{x['state']} | {_cell(', '.join(x['reasons']), 300) or '-'} |" for x in STATE_ROWS]
    return ["| session | id | kind | status idle | state | why |", "|---|---|---|---|---|---|", *rows] if rows else []


def rounds_path(sdir, config_path):
    """The clean-round counter of one policy file: keyed by the sha256 of its resolved path, so a copied config never
    shares the live counter."""
    key = hashlib.sha256(str(Path(os.path.expanduser(str(config_path))).resolve()).encode()).hexdigest()[:12]
    return sdir / f"state-shadow-rounds-{key}.json"


def round_refused(cfg, config_path, idle_override):
    """Why this sweep counts no shadow round, or "" when it may: only the live CONFIG, at APPLY=1, with no
    --idle-minutes, counts."""
    if not live_config(config_path):
        return f"{config_path} is not the live config {CONFIG}"
    if cfg.get("APPLY") != "1":
        return "APPLY is not 1"
    if idle_override:
        return "--idle-minutes overrides the threshold"
    return ""


def _source_hit(s, src):
    if src == "STATE_DONE":
        return s.get("state_shadow") == "STATE_DONE"
    return bool(s.get("oracle_not_mine_shadow"))


def shadow_rounds(cfg, config_path, seen, sdir, now, idle_override=False):
    """The clean-round counter of each SHADOW_SOURCES flag still at `shadow` (SCRIPT-SAFE-RULE, stima-api #7061).

    A round counts only on the live CONFIG at APPLY=1 with no --idle-minutes (round_refused()), and only
    ROUND_MIN_SECONDS after the last counted round. Each source keeps its own counter: its would-close set is the kept
    sessions it would close under `apply` (STATE_DONE: the state's DONE with every gate passing; ORACLE_NOT_MINE: the
    #7001 trial). The next counted round checks them: a session still there whose
    status changed (busy, or a newer statusUpdatedAt) is a miss, and a miss resets that source's streak; a round whose
    previous set had at least one candidate and no miss counts clean; a session gone counts nothing against it. At
    SHADOW_CLEAN_ROUNDS clean rounds in a row that saw at least ROUND_MIN_SESSIONS distinct sessions, the sweep appends
    `<FLAG>=apply` to the live policy file and says so in the report. Returns report lines."""
    refused = round_refused(cfg, config_path, idle_override)
    if refused:
        return [f"- no shadow round counted: {refused}"]
    path = rounds_path(sdir, config_path)
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            raise ValueError("shape")
    except (OSError, ValueError):
        data = {}
    last_at = data.get("_last_round_at")
    if isinstance(last_at, (int, float)) and now - last_at < ROUND_MIN_SECONDS:
        return [f"- no shadow round counted: {(now - last_at) / 60:.0f} min since the last counted round "
                f"(needs {ROUND_MIN_SECONDS // 60})"]
    need = int(cfg.get("SHADOW_CLEAN_ROUNDS") or 5)
    current = {s["sid"]: s for s, _, _ in seen}
    lines, stamp = [], time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(now))
    for col in SHADOW_SOURCES:
        if cfg.get(col, "shadow") != "shadow":
            continue
        c = data.get(col) if isinstance(data.get(col), dict) else {}
        data[col] = c
        prev, misses = c.get("last") or {}, []
        for sid, was in prev.items():
            s = current.get(sid)
            if s and (s["status"] != "idle" or s.get("status_at") != was.get("status_at")):
                misses.append({"at": stamp, "sid": sid[:8], "name": was.get("name"),
                               "was": f"idle {was.get('idle_min')}m", "now": f"{s['status']} {s['idle_min']:.0f}m"})
        if misses:
            c["streak"], c["sessions"] = 0, []
            c["misses"] = (c.get("misses") or [])[-50:] + misses
        elif prev:
            c["streak"] = int(c.get("streak") or 0) + 1
            c["sessions"] = sorted(set(c.get("sessions") or ()) | set(prev))
        would = {}
        for s, keep, outcome in seen:
            if _source_hit(s, col) and keep and outcome != "error":
                would[s["sid"]] = {"name": s["tmux"], "status_at": s.get("status_at"), "idle_min": round(s["idle_min"])}
        c["last"] = would
        streak, distinct = int(c.get("streak") or 0), len(c.get("sessions") or ())
        missed = "; ".join(f"{m['name']} ({m['was']} -> {m['now']})" for m in misses) or "none"
        lines.append(f"- {col}=shadow: {streak}/{need} clean rounds, {distinct} distinct sessions "
                     f"(needs {ROUND_MIN_SESSIONS}); candidates now: "
                     f"{', '.join(v['name'] for v in would.values()) or 'none'}; misses this round: {missed}")
        if streak >= need and distinct >= ROUND_MIN_SESSIONS and not c.get("flipped_at"):
            try:
                with open(config_path, "a") as fh:
                    fh.write(f"\n# stima-api #7061: written by session-reaper {stamp} after {streak} clean shadow "
                             f"rounds over {distinct} sessions ({len(c.get('misses') or [])} misses before them; "
                             f"list: {path})\n{col}=apply\n")
                c["flipped_at"] = stamp
                lines.append(f"- FLIP: {col}=apply written to {config_path} after {streak} clean rounds")
            except OSError as e:
                lines.append(f"- FLIP of {col} not written to {config_path}: {e}")
    data["_last_round_at"] = now
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    os.replace(tmp, path)
    return lines


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


def _ends_on(s, rx, window=1):
    """The reply that ends the transcript, written after the last prompt, has a bare `rx` line among its last `window`
    non-blank lines (1: the last one), outside a code fence (``` or ~~~) and not in an indented (4 spaces or a tab)
    code block."""
    lines = [ln for ln in (s.get("last_text") or "").splitlines() if ln.strip()]
    tail = lines[-window:]
    fenced = sum(ln.lstrip().startswith(("```", "~~~")) for ln in lines[:len(lines) - len(tail)]) % 2
    return (not fenced and not any(ln.lstrip().startswith(("```", "~~~")) for ln in tail)
            and any(rx.match(ln) and not ln.startswith(("    ", "\t")) for ln in tail)
            and (s.get("text_at") or 0) > (s.get("prompt_at") or 0))


def said_done(s):
    """The newest assistant text says the session is done, and nobody prompted it since (EL-T2512)."""
    return _ends_on(s, GRACE_RE)


def said_waiting(s):
    """The newest reply ends on `SESSION-STATE: WAITING_UNTIL=<iso>` and does not also say it is done (EL-T2520)."""
    return not said_done(s) and _ends_on(s, WAIT_RE, window=3)


def waiting_keeps(s, cfg, now):
    """What keeps an alarm from being pure (EL-T2520): it stands in for claim-unknown, so it carries the gates the claim-less
    close paths use (no child process, not NEVER_CLOSE, a clean cwd, no named claim) and adds the alarm's own: unread or past, an open PR, no worktree to read PRs from."""
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
    keep.extend(open_prs(s) if s["owned"] else named_open_prs(s, cfg))
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


NAMED_PR_LOOKUPS = 5  # `gh pr list` calls a worktree-less session may cost per run (the first issues it names)


def named_open_prs(s, cfg, limit=NAMED_PR_LOOKUPS):
    """Open pull requests of a session that owns no worktree (it works in the primary checkout): search the repo for
    the issues the session names (`#N` in its name or last text, the first `limit` of them) and return
    `open-pr:<repo>#N` per hit, so the reason names the PR. `open-pr-unknown:no-worktree` stays when nothing is
    named, when no lookup finds a PR, when a lookup fails (alongside any hit another lookup found), or when there is
    no repo to ask."""
    repo = cfg.get("CHECKBY_REPO") or ""
    named = []
    for n in NAMED_RE.findall(f"{s.get('name') or ''}\n{s.get('last_text') or ''}"):
        if n not in named:
            named.append(n)
    if not named or not repo:
        return ["open-pr-unknown:no-worktree"]
    hits, failed = [], False
    for n in named[:limit]:
        key = ("named", repo, n)
        if key not in _pr_cache:
            rc, txt = run(["gh", "pr", "list", "-R", repo, "--state", "open", "--search", f"{n} in:title,body",
                           "--json", "number,headRefName", "-q", ".[].number"], 30)
            _pr_cache[key] = txt.split() if rc == 0 else None
        nums = _pr_cache[key]
        if nums is None:
            failed = True
        else:
            hits += [f"open-pr:{repo}#{num}" for num in nums if f"open-pr:{repo}#{num}" not in hits]
    # ponytail: no hit keeps the unknown label, so this change never opens a new close path; a PR on an issue the
    # session does not name stays invisible here
    return hits + (["open-pr-unknown:no-worktree"] if failed or not hits else [])


def idle_threshold(s, cfg):
    """Minutes a session must sit idle before it can close: IDLE_MINUTES, or DONE_GRACE_MINUTES when DONE_GRACE=apply
    and said_done(). The grace replaces only the idle wait; every other keep gate still applies."""
    idle = float(cfg["IDLE_MINUTES"])
    if cfg.get("DONE_GRACE") == "apply" and (said_done(s) or said_waiting(s)):
        return min(idle, float(cfg.get("DONE_GRACE_MINUTES") or idle))
    return idle


def _decide(s, cfg, now=None):
    # /exit on an attachment does not prove the detached job has stopped. Classification is the whole bg path.
    keep = ["kind:bg"] if s.get("kind") == "bg" else []
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
        # is only a hint: still kept (shadow, #6477), under a name the shadow verdict can tell apart. A SESSION-DONE
        # line beats that hint unless the reply still states live work (a check-by ahead, an open PR, `剩 #N`):
        # gtm-content sat `waiting-keyword` on a done reply (#6840 c). A wait on a person stays `waiting`.
        if not s["claims"] or person_step(s, cfg, now):
            keep.append("waiting")
        elif not (DONE_RE.search(s["last_text"]) and not live_work(s["last_text"], now if now is not None else time.time())):
            keep.append("waiting-keyword")
    if s.get("sub_active"):
        keep.append("subagent-active")
    if cfg["PROMPT_RE"] and re.search(cfg["PROMPT_RE"], s.get("screen_tail", ""), re.I):
        keep.append("handoff-pending:prompt")
    keep.extend("handoff-missing:" + os.path.basename(p) for p in missing_handoffs(cfg, s["last_text"]))
    done = bool(DONE_RE.search(s["last_text"]) or DONE_PHRASE_RE.search(s["last_text"]))
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
                  and claim_class(oracle_brief(r, n, cfg, at), r, n, s, at, mine, cfg)[0] != "ended"]
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
                cls, overdue = claim_class(
                    oracle_brief(r, n, cfg, at), r, n, s, at, [w["marker"] for w in s["owned"] if w.get("marker")], cfg)
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


def can_close_now(s, cfg):
    """Idle past the session's own threshold: the only kind of session a run can close, so the only kind whose claims
    the oracle is asked about (stima-api#7904). A busy, shell or waiting session, or an idle one still under the
    threshold, is kept whatever the oracle says."""
    return s["status"] == "idle" and s["idle_min"] >= idle_threshold(s, cfg)


def judge_order(s, cfg):
    """Sort key: the sessions most likely to close come first, so a budget cut leaves only the busy ones unjudged
    (#6477: 13 of 18 ended `unjudged:run-budget`, so nothing was ever reaped). Idle past the threshold before the
    rest, protected last (they never close), fewer claims first (an issue each costs a lookup), longest idle first."""
    idle = can_close_now(s, cfg)
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
    for s in sorted(sessions, key=lambda x: judge_order(x, cfg)):  # candidates first: a budget cut drops the busy ones
        done = DONE_RE.search(s["last_text"]) or DONE_PHRASE_RE.search(s["last_text"])
        idle = can_close_now(s, cfg)
        # An oracle brief is read only for a session this run can close (stima-api#7904), or one whose waiting keyword
        # makes _decide() ask whether a claim is a person's step (person_step()): the label, not the verdict.
        brief = idle or bool(not s["asking"] and waiting_re(cfg).search(DONE_RE.sub("", s["last_text"])))
        for r, n in s.get("claims") or ():
            if brief:
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


# Per-session results of decide() that a re-decide on a changed brief must recompute, never carry over.
DECIDE_RESULTS = ("oracle_not_mine", "state_close", "state_shadow", "state_held", "state_error", "claim_marks",
                  "done_grace_shadow", "done_grace_error", "oracle_not_mine_shadow", "oracle_not_mine_error",
                  "false_waiting")


def confirm_close(s, cfg, keep):
    """`keep` after a fresh look at what a close rests on, for a session decide() would close (empty `keep`).

    The brief cache outlives a run (ORACLE_CACHE_MINUTES 45 > the 30-minute interval, stima-api#7904), so a close is the
    one verdict that may not rest on it: closing a session that still has a step is the costly direction, and the
    cache is keyed on the issue, not on what the issue said a moment ago. refresh_briefs() reads each claim's brief from
    the oracle now, and for a session with no claim the issues its text names (the alarm path's `named-claim:` gate).
    A key already read in this run (by session_state.judge()'s own confirmation, or a cache miss) is not read again.
    Nothing changed: `keep` stands. A brief changed, or came back unreadable: the session is decided again on the fresh
    briefs, the state record is dropped (it was judged on the old ones, so it releases nothing) and every earlier result
    is cleared. What that second decide does with an unreadable brief is what decide() always does: a claim path keeps
    the session (`issue-unknown:`), but a session ending in SESSION-DONE never read the claim's brief for anything but
    a check-by, so it closes as it did before this function. Only a session about to close pays the reads."""
    if keep:
        return keep
    changed = refresh_briefs(s, cfg, time.time())
    if not changed:
        return keep
    for k in DECIDE_RESULTS:
        s.pop(k, None)
    s["state"] = None
    s["brief_changed"] = changed
    return decide(s, cfg)


def person_step(s, cfg, now=None):
    """True when the oracle's step for one of the session's worktree claims is a stop (a person's)."""
    at = now if now is not None else time.time()
    return any(_brief_kind(b) == "stop" for _, b in claim_briefs(s["claims"], cfg, at))


def named_issues(s, cfg, limit=8):
    """The issue numbers (`#N` in the session's name or last text, not already a claim) oracle_claims() looks at."""
    named = []
    for n in NAMED_RE.findall(f"{s.get('name', '')}\n{s['last_text']}"):
        if n not in named and (cfg["CHECKBY_REPO"], n) not in s["claims"]:
            named.append(n)
    return named[:limit]


def oracle_claims(s, cfg, now, limit=8):
    """Issues the session names (`#N` in its last text or name) whose oracle brief says THIS session is the
    claimant (its id or a worktree marker it owns); the claim a worktree-less session has no branch for."""
    repo = cfg["CHECKBY_REPO"]
    mine = [w["marker"] for w in s["owned"] if w.get("marker")]
    out = []
    for n in named_issues(s, cfg, limit):
        c = CLAIMANT_RE.search(oracle_brief(repo, n, cfg, now) or "")
        if c and (_same_session(c.group(1), s["sid"]) or any(_same_session(c.group(1), m) for m in mine)):
            out.append((repo, n))
    return out


ISO_RE = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d")
PR_NAMED_RE = re.compile(r"\bPR\s*#\d+", re.I)
PR_DONE_RE = re.compile(r"\b(?:merged|closed|landed)\b|已\s*(?:合併|merge)", re.I)
PR_UNCERTAIN_RE = re.compile(r"\b(?:not|never|pending|awaiting|unmerged|unclosed|unlanded)\b|n['’]t\b|未|沒|没有", re.I)


def future_time(text, now):
    """The first ISO minute in `text` still ahead of `now`, or ""."""
    for iso in ISO_RE.findall(text):
        try:
            if calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M")) > now:
                return iso
        except ValueError:
            pass
    return ""


def foreign_prs(s, cfg):
    """`PR #N` the reply names whose head branch is an issue another live session claims: a handover note, not this
    session's work (#6477: sec-p1 named auth-audit's PR #6186 and stayed off would-close). Anything GitHub cannot
    answer, and any PR past NAMED_PR_LOOKUPS, stays this session's (kept)."""
    repo, out = cfg.get("CHECKBY_REPO") or "", set()
    for pr in PR_NAMED_RE.findall(s.get("last_text") or "")[:NAMED_PR_LOOKUPS]:
        n = pr.rsplit("#", 1)[1]
        key = ("head", repo, n)
        if key not in _pr_cache:
            rc, txt = run(["gh", "pr", "view", n, "-R", repo, "--json", "headRefName", "-q", ".headRefName"], 30) \
                if repo else (1, "")
            _pr_cache[key] = txt.strip() if rc == 0 else ""
        m = branch_issue(_pr_cache[key], repo, cfg["CHECKBY_REPO"]) if repo else None
        if m and m in s.get("other_claims", ()):
            out.add(n)
    return out


def live_work(text, now, foreign=()):
    """Why a reply that carries a close line still states live work (else ""): a `check-by` / `WAITING_UNTIL` time
    still ahead, an open `PR #N` (or `待 merge`), or a SESSION-DONE whose remainder starts `剩` / `remaining` and names
    an issue or PR. A SESSION-DONE that says nothing remains, with none of these, is not live work. `foreign` holds
    PR numbers that are not this session's; only the shadow verdict passes it, so a real close never depends on it."""
    for line in text.splitlines():
        if re.search(r"check-by|WAITING_UNTIL", line, re.I) and future_time(line, now):
            return "future-check-by:" + future_time(line, now)
        if re.search(r"待\s*merge", line, re.I):
            return "awaiting-merge"
        prs = PR_NAMED_RE.findall(line)
        # A completion word cannot prove multiple named PRs ended, or override a negation/pending state.
        # Keep ambiguous lines rather than assigning one PR's `merged` to its still-open neighbour (#6840).
        # The count stays on every PR named: a foreign PR's `merged` must not vouch for this session's own.
        if any(p.rsplit("#", 1)[1] not in foreign for p in prs) \
                and (len(prs) > 1 or PR_UNCERTAIN_RE.search(line) or not PR_DONE_RE.search(line)):
            return "open-pr-named"
    for m in DONE_RE.finditer(text):
        rest = m.group(1).strip()
        if re.match(r"剩|remain", rest, re.I) and re.search(r"#\d+", rest):
            return "done-line-remaining"
    return ""


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
        at = now if now is not None else time.time()
        live = live_work(text, at)
        if live == "open-pr-named":  # the only reason that costs a GitHub read to answer
            live = live_work(text, at, foreign_prs(s, cfg))
        # A wake can be named in any words (#6477: cve-6725 said `喚醒`), so here any time ahead counts, unless a
        # SESSION-DONE owns it: that line names who wakes the session. Not in live_work(): decide() reads that.
        if live or (future_time(text, at) and not DONE_RE.search(text)):
            pass  # the text still states live work: a close line beside it is not "nothing left" (EL-LEO-T2570)
        elif DONE_RE.search(text) or DONE_PHRASE_RE.search(text) or CLOSE_LINE_RE.search(text):
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
    if not m and s.get("oracle_not_mine"):  # the close line the session did not write (#7001): who wakes each claim
        return ("SESSION-DONE (derived, oracle:not-mine): "
                + "; ".join(f"#{n} {_cell(w, 120)}" for n, w in s["oracle_not_mine"].items()))[:300]
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
           # #7001: the claims closed as not this session's step; finish_close() releases none of them
           "oracle_not_mine": dict(s.get("oracle_not_mine") or {}),
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


CLAIM_BY_SESSION_RE = re.compile(r"Claimed by[^\n]*?session\s+`?([0-9a-f]{8,}(?:-[0-9a-f-]+)?)`?", re.I)


def claims_session(body, sid):
    """True when a comment claims for this session: its full id or a prefix of it (the usual 8-hex claim)."""
    sid = sid.lower()
    for m in CLAIM_BY_SESSION_RE.finditer(body or ""):
        cid = m.group(1).lower()
        if sid.startswith(cid) or cid.startswith(sid):
            return True
    return False


def has_marker(issue_ref, sid):
    """True when the issue has our marker in a comment after the session's newest claim, False when it has none
    there; None when gh could not say. A resumed session keeps its id, so a claim it makes after an earlier release
    needs a release of its own at the next reap (stima-api#7000), or the claim hangs on a dead session."""
    repo, num = issue_ref
    rc, out = run(["gh", "issue", "view", num, "-R", repo, "--json", "comments"], 60)
    if rc != 0:
        return None
    try:
        bodies = [c.get("body") or "" for c in json.loads(out).get("comments", [])]  # oldest first
    except (ValueError, AttributeError):
        return None
    mark = f"session-reaper:{sid}"
    marked = [i for i, b in enumerate(bodies) if mark in b]
    claimed = [i for i, b in enumerate(bodies) if mark not in b and claims_session(b, sid)]
    return bool(marked) and (not claimed or marked[-1] > claimed[-1])


def release_comment(rec_tmux, sid, cwd, ref, cfg, now):
    """The reap comment on a claimed issue. Its first line releases the claim (stima-api#7000): delivery_state.claimant()
    ends a claim at a `Released by ... session <id>` first line (#6134), so the issue reads unclaimed, not owned by a
    dead session. `next:` is the oracle's first line, read before the release; the marker keeps the post once."""
    repo, num = ref
    brief = oracle_brief(repo, num, cfg, now)
    step = brief.splitlines()[0] if brief else f"unread; run `delivery_state.py {num} --brief`"
    at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    return (f"Released by {rec_tmux} session {sid} (reaped {at}); next: {step}\n\n"
            f"Session `{rec_tmux}` (`{sid}`) finished and was reaped by session-reaper. "
            f"Resume it with `cd {cwd} && claude --resume {sid}`.\n\n<!-- session-reaper:{sid} -->")


def notmine_comment(rec_tmux, sid, cwd, why, pid=None):
    """The close comment on a claim the oracle says is not the session's step (stima-api #7001). It is never a release:
    no `Released by` (or `Claimed by`) first line, so delivery_state.claimant() still names this session and the
    stranded-step dispatcher resumes it at its check-by or wake, with its context. The reason goes in inline code, so
    a check-by time it quotes schedules nothing. Its marker is not the `session-reaper:<sid>` one: that marker says the
    session was closed as finished, and a session resumed after this close still gets that comment (and with #7000
    its release) when it is closed as finished. The pid makes each close of a resumed session its own."""
    why = _cell(why, 200).replace("`", "'")
    return (f"Session `{rec_tmux}` (`{sid}`) was closed by session-reaper: the oracle says the step is not its own "
            f"(`{why}`). The claim stays with it, not released, so it is resumed with "
            f"`cd {cwd} && claude --resume {sid}` when that step comes back.\n\n<!-- {notmine_mark(sid, pid)} -->")


def notmine_mark(sid, pid):
    return f"session-reaper-notmine:{sid}:{pid}"


def notmine_posted(ref, sid, pid):
    """True/False when the issue has (no) not-mine close comment for this close; None when gh could not say."""
    comments = issue_comments(*ref)
    if comments is None:
        return None
    return any(notmine_mark(sid, pid) in (c.get("body") or "") for c in comments if isinstance(c, dict))


def finish_close(rec_tmux, sid, cwd, claims, summ, pane, session_id, alone, cfg, now, pid=None, not_mine=None):
    """The steps after claude has exited, safe to repeat: each checks for its own earlier effect.
    Returns False when a step could not be confirmed (the record then stays "exiting").
    `not_mine` ({issue number: why}, #7001): those claims get notmine_comment(), never a release."""
    not_mine = {str(k): v for k, v in (not_mine or {}).items()}
    log = Path(os.path.expanduser(cfg["CLOSED_LOG"]))
    log.parent.mkdir(parents=True, exist_ok=True)
    # One entry per close, not per session id: a resumed session that is closed again needs its own entry (#6477:
    # apertis-ops's second close left none, because its id was already in the log). Its pid is new on every resume.
    mark, summ = f"<!-- pid:{pid} -->", " ".join(summ.split())  # one line, so the id and the mark share it
    try:
        done = any(sid in ln and mark in ln for ln in log.read_text().splitlines())
    except OSError:
        done = False
    if not done:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
        issues = " ".join(f"{r}#{n}" for r, n in claims) or "-"
        with log.open("a") as fh:
            fh.write(f"\n## {stamp} session-reaper (resume: claude --resume <sid>)\n"
                     f"- {rec_tmux} {sid} cwd={cwd} issues={issues} — {summ} {mark}\n")
    ok = True
    for ref in [r for r in claims if str(r[1]) in not_mine]:  # #7001: never a release, so the claim stays
        seen = notmine_posted(ref, sid, pid)
        if seen is False:
            ok = comment(ref, notmine_comment(rec_tmux, sid, cwd, not_mine[str(ref[1])], pid)) and ok
        elif seen is None:
            ok = False
    claims = [r for r in claims if str(r[1]) not in not_mine]
    for ref in claims:
        seen = has_marker(ref, sid)
        if seen is False:
            ok = comment(ref, release_comment(rec_tmux, sid, cwd, ref, cfg, now)) and ok
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
                            pane, rec.get("session_id"), True, cfg, now, pid, rec.get("oracle_not_mine")):
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
    if s.get("kind") == "bg":
        return "skipped:kind:bg", []
    # Everything gather saw may be minutes old: re-check that nobody has touched the session.
    try:
        fresh = json.loads(Path(s["file"]).read_text())
    except (OSError, ValueError):
        return "skipped:session-file-unreadable", []
    if fresh.get("kind") == "bg":
        return "skipped:kind:bg", []
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
                        s["session_id"], alone, cfg, now, s["pid"], s.get("oracle_not_mine")):
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


# ---------- dead claims (stima-api#7527) ----------
# A claim whose claimant's name matches nothing alive is released with the comment the oracle already honours, so the
# issue reads unclaimed and the stranded-step dispatcher can take its step. The test is the name (and the session id),
# never the harness: a codex session, a custom name and a Claude session are judged alike.
DEAD_CLAIM_PAGE = 50  # search results per page, as the rest of the reaper's GitHub reads
DEAD_CLAIM_PAGES = 20  # search's own ceiling is 1000 results
DEAD_CLAIM_BATCH = 25  # issues per GraphQL request: their comment bodies are the payload, not the aliases
DEAD_CLAIM_FALLBACKS = 10  # `gh issue view` reads a run may spend on an issue with more than 100 comments
DEAD_CLAIM_MARK = "session-reaper-dead-claim:"
_oracle_module = []


def load_oracle(cfg):
    """stima-api's delivery_state module from ORACLE_ROOT (its claimant() is the one grammar for who holds an issue),
    or None when it cannot be imported."""
    if _oracle_module:
        return _oracle_module[0]
    root = Path(os.path.expanduser(cfg["ORACLE_ROOT"])) / "scripts" / "ci"
    if not (root / "delivery_state.py").is_file():
        return None
    sys.path.insert(0, str(root))
    try:
        import delivery_state  # noqa: PLC0415
    except Exception:  # noqa: BLE001 (a checkout that cannot import is the same as none)
        return None
    finally:
        sys.path.remove(str(root))
    _oracle_module.append(delivery_state)
    return delivery_state


def read_tmux_names():
    """Lowercased names of the tmux sessions that exist; None when tmux cannot say (not running, not installed, timed
    out), which is not the same as an empty list."""
    rc, out = tmux("list-sessions", "-F", "#{session_name}")
    if rc != 0:
        return None
    return {line.strip().lower() for line in out.splitlines() if line.strip()}


def read_state_live(cfg, now):
    """(names, session ids) of the live entries of sessions.json (session_state.py, which the sweep rewrites every run);
    None when the file is missing, broken, of another version or older than session_state.MAX_AGE_SECONDS."""
    ss, _ = load_session_state()
    if not ss:
        return None
    doc = ss.read(ss.default_path(state_dir(cfg)), now)
    if doc is None:
        return None
    names, sids = set(), set()
    for x in doc["sessions"]:
        if not isinstance(x, dict):
            continue
        names |= {str(x[k]).strip().lower() for k in ("name", "tmux") if x.get(k)}
        if x.get("sid"):
            sids.add(str(x["sid"]).lower())
    return names, sids


def search_claimed(repo):
    """[(number, updated_at)] of the open issues that have a `Claimed by` comment, newest update first: the oracle's own
    claim_candidates() query (delivery_state.py), paged by 50. None when the list is partial or cannot be read."""
    query = f'repo:{repo} is:issue is:open "Claimed by" in:comments'
    jq = ('{total: .total_count, incomplete: .incomplete_results, raw: (.items | length), '
          'items: [.items[] | select(.pull_request == null) | {n: .number, u: .updated_at}]}')
    found, seen = [], 0
    for page in range(1, DEAD_CLAIM_PAGES + 1):
        rc, out = run(["gh", "api", "-X", "GET", "search/issues", "-f", "q=" + query, "-f", "sort=updated",
                       "-f", "order=desc", "-f", f"per_page={DEAD_CLAIM_PAGE}", "-f", f"page={page}", "--jq", jq], 90)
        try:
            if rc != 0:
                return None
            got = json.loads(out)
            if got["incomplete"] or int(got["total"]) > DEAD_CLAIM_PAGE * DEAD_CLAIM_PAGES:
                return None
            found += [(int(i["n"]), str(i["u"])) for i in got["items"]]
            seen += int(got["raw"])
        except (ValueError, TypeError, KeyError):
            return None
        if got["raw"] < DEAD_CLAIM_PAGE or seen >= int(got["total"]):
            return found
    return None


def _comment_row(c):
    return {"id": str(c.get("id") or ""), "createdAt": str(c.get("createdAt") or ""), "body": str(c.get("body") or "")}


def read_comment_batches(repo, nums):
    """{number: comments} for the issues it could read in full, oldest first, 25 per GraphQL request; an issue whose
    last 100 comments are not all of them is read with `gh issue view` (a few a run), and one it cannot read is left
    out. A failed request leaves its issues out too: they are read again next run."""
    owner, name = repo.split("/")
    got = {}
    fallbacks = 0
    for i in range(0, len(nums), DEAD_CLAIM_BATCH):
        chunk = nums[i:i + DEAD_CLAIM_BATCH]
        fields = " ".join(f"i{n}: issue(number: {n}) {{ comments(last: 100) {{ pageInfo {{ hasPreviousPage }} "
                          f"nodes {{ id createdAt body }} }} }}" for n in chunk)
        query = f"query($o: String!, $n: String!) {{ repository(owner: $o, name: $n) {{ {fields} }} }}"
        rc, out = run(["gh", "api", "graphql", "-f", "o=" + owner, "-f", "n=" + name, "-f", "query=" + query], 120)
        try:
            data = json.loads(out)["data"]["repository"]
            if not isinstance(data, dict):
                raise ValueError("shape")
        except (ValueError, TypeError, KeyError):
            continue
        for n in chunk:
            conn = ((data.get(f"i{n}") or {}).get("comments")) or {}
            try:
                rows = [_comment_row(c) for c in conn["nodes"]]
                partial = bool(conn["pageInfo"]["hasPreviousPage"])
            except (KeyError, TypeError):
                continue
            if partial:
                if fallbacks >= DEAD_CLAIM_FALLBACKS:
                    continue
                fallbacks += 1
                full = fresh_comments(repo, n)
                if full is None:
                    continue
                rows = full
            got[n] = rows
    return got


def fresh_comments(repo, num):
    """The issue's comments now, never the run's memo; None when gh could not say."""
    _comments_cache.pop((repo, num), None)
    rc, out = run(["gh", "issue", "view", str(num), "-R", repo, "--json", "comments", "-q", ".comments"], 60)
    try:
        rows = json.loads(out)
        return [_comment_row(c) for c in rows] if rc == 0 and isinstance(rows, list) else None
    except (ValueError, TypeError, AttributeError):
        return None


def _gh_epoch(stamp):
    try:
        return calendar.timegm(time.strptime(str(stamp)[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None


def _same_id(a, b):
    a, b = str(a).lower(), str(b).lower()
    return len(a) >= 8 and len(b) >= 8 and (a.startswith(b) or b.startswith(a))


def dead_claim_key(label, claim_id):
    return f"{label}:{claim_id}"


def claim_facts(ds, comments, updated):
    """What the pass keeps of an issue between runs: who the oracle says holds it, the id and time of that claim's
    newest comment, the last time that session is heard from (its claim, or a later comment that names its id) and the
    dedupe keys already released. `claimant` None: the issue reads unclaimed."""
    facts = {"updated": updated, "claimant": None}
    who = ds.claimant(comments)
    if not who:
        return facts
    sid = str(who["session"]).lower()
    at = claim = None
    for i, c in enumerate(comments):
        lines = [x for x in str(c["body"]).splitlines() if x.strip()]
        if lines and CLAIM_LINE_RE.match(lines[0]) and claims_session(c["body"], sid):
            at, claim = i, c
    if claim is None:
        return facts | {"claimant": who, "claim_id": "", "claim_at": None, "last_at": None, "marked": []}
    claim_at = _gh_epoch(claim["createdAt"])
    last = claim_at
    for c in comments[at + 1:]:
        t = _gh_epoch(c["createdAt"])
        if t is not None and sid[:8] in c["body"].lower() and (last is None or t > last):
            last = t
    marked = sorted({m.group(1) for c in comments for m in re.finditer(re.escape(DEAD_CLAIM_MARK) + r"(\S+?) -->", c["body"])})
    return facts | {"claimant": who, "claim_id": claim["id"], "claim_at": claim_at, "last_at": last, "marked": marked}


def dead_claim_comment(who, label, claim_id, since):
    sid, name = who["session"], (who.get("name") or "").strip()
    at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(since))
    return (f"Released by {who.get('harness') or 'claude'} session {sid}" + (f" ({name})" if name else "")
            + f": session {label} is not in the live session list since {at}\n\n"
            f"session-reaper found no tmux session or sessions.json entry named `{label}` or carrying id `{sid}`, and "
            "nothing from that session on this issue for 6 hours or more, so its claim is released and the issue reads "
            "unclaimed. The issue, its labels and its check-by are untouched.\n\n"
            f"<!-- {DEAD_CLAIM_MARK}{dead_claim_key(label, claim_id)} -->")


def _load_json(path):
    try:
        data = json.loads(Path(path).read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def release_dead_claims(cfg, now, apply, extra=((), ())):
    """Release, with one comment each, the claims of open issues whose claimant matches nothing alive. Returns
    {released, would, young, alive, deferred, unreadable, notes}. `apply` False (or DEAD_CLAIMS=shadow) lists what it
    would release and writes nothing to GitHub; DEAD_CLAIMS=off does nothing. A live list it cannot read (tmux,
    sessions.json), the oracle module or the issue list releases nothing and costs one note."""
    mode = cfg.get("DEAD_CLAIMS", "apply")
    out = {"released": [], "would": [], "young": [], "alive": 0, "deferred": [], "unreadable": "", "notes": []}
    if mode == "off":
        return out

    def closed(why):
        out["unreadable"] = why
        out["notes"].append(f"dead claims: {why}; released nothing this round")
        return out
    names = read_tmux_names()
    if names is None:
        return closed("tmux not readable")
    state = read_state_live(cfg, now)
    if state is None:
        return closed("sessions.json not readable or stale")
    ds = load_oracle(cfg)
    if ds is None:
        return closed("oracle (delivery_state.py) not importable")
    repo = cfg["CHECKBY_REPO"]
    found = search_claimed(repo)
    if found is None:
        return closed("issue list not readable")
    names |= state[0] | {str(x).strip().lower() for x in extra[0] if x}
    sids = state[1] | {str(x).lower() for x in extra[1] if x}
    cache_path = Path(os.path.expanduser(cfg["DEAD_CLAIMS_CACHE"]))
    cache = _load_json(cache_path)
    need = [n for n, u in found if (cache.get(str(n)) or {}).get("updated") != u]
    got = read_comment_batches(repo, need) if need else {}
    cache = {str(n): cache[str(n)] for n, _ in found if str(n) in cache}
    for n, u in found:
        if n in got:
            cache[str(n)] = claim_facts(ds, got[n], u)
    updated_of = dict(found)
    unread = [n for n in updated_of if (cache.get(str(n)) or {}).get("updated") != updated_of[n]]
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(cache))
    except OSError:
        out["notes"].append("dead claims: cache not written")
    if unread:
        out["notes"].append(f"dead claims: {len(unread)} issue(s) not read this round: "
                            + ", ".join(f"#{n}" for n in unread[:10]))
    hours = float(cfg.get("DEAD_CLAIMS_HOURS", "6"))
    cap = int(cfg.get("DEAD_CLAIMS_MAX", "40"))
    due = []
    for n, _ in found:
        e = cache.get(str(n))
        who = (e or {}).get("claimant")
        if not who or e.get("updated") != updated_of[n]:
            continue
        label = (who.get("name") or "").strip() or str(who["session"])
        if (label.lower() in names and who.get("name")) or any(_same_id(who["session"], s) for s in sids):
            out["alive"] += 1
        elif not e.get("claim_id") or e.get("last_at") is None:
            out["notes"].append(f"dead claims: #{n} claimant {label}: claim comment not placed, left alone")
        elif now - e["last_at"] < hours * 3600:
            out["young"].append((n, label, e["last_at"]))
        elif dead_claim_key(label, e["claim_id"]) in e.get("marked", []):
            continue
        else:
            due.append((n, label, e["last_at"], who, e["claim_id"]))
    for n, label, since, who, claim_id in due:
        if mode != "apply" or not apply:
            out["would"].append((n, label, since))
        elif len(out["released"]) >= cap:
            out["deferred"].append((n, label, since))
        else:
            fresh = fresh_comments(repo, n)  # the cache may be minutes old: the claim must still be this one
            now_who = ds.claimant(fresh) if fresh is not None else None
            if not now_who or now_who["session"] != who["session"] or any(
                    DEAD_CLAIM_MARK + dead_claim_key(label, claim_id) in c["body"] for c in fresh):
                continue
            facts = claim_facts(ds, fresh, "")
            if facts.get("claim_id") != claim_id or (facts["last_at"] or 0) != since:
                continue
            if comment((repo, str(n)), dead_claim_comment(who, label, claim_id, since)):
                out["released"].append((n, label, since))
                cache.get(str(n), {})["updated"] = ""  # our own comment moved the issue: read it again
            else:
                out["notes"].append(f"dead claims: could not post the release on #{n}")
    try:
        cache_path.write_text(json.dumps(cache))
    except OSError:
        pass
    return out


def dead_claim_lines(res, stamp=lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))):
    lines = [f"released #{n}: session {label} not in the live session list since {stamp(t)}" for n, label, t in res["released"]]
    lines += [f"would release #{n}: session {label} not in the live session list since {stamp(t)}" for n, label, t in res["would"]]
    lines += [f"deferred #{n}: session {label} (per-run cap)" for n, label, t in res["deferred"]]
    lines += [f"waiting #{n}: session {label} dead, last heard {stamp(t)} (under the grace)" for n, label, t in res["young"]]
    return lines


# ---------- main ----------

def report_line(s, keep, outcome):
    wt = ",".join(w["path"].name for w in s["owned"]) or "-"
    issues = ",".join(s.get("claim_marks") or [f"#{n}" for _, n in s["claims"]]) or "-"
    plan = f"pid {s['pid']}+{s['descendants']} desc; tmux {s['tmux']}; worktrees {wt}"
    background_only = "yes" if keep and set(keep) <= BACKGROUND_ONLY else "-"
    new_only = "yes" if keep and all(k.startswith(NEW_GATES) for k in keep) else "-"
    why = [f"would-close: {s['would_close']}"] if s.get("would_close") else []
    why += ["would-close: done grace (shadow)"] if s.get("done_grace_shadow") else []
    nm = s.get("oracle_not_mine_shadow") or s.get("oracle_not_mine") or {}
    why += [("would-close: " if s.get("oracle_not_mine_shadow") else "") + "oracle:not-mine "
            + "; ".join(f"#{n} {_cell(w, 120)}" for n, w in nm.items())
            + (" (shadow)" if s.get("oracle_not_mine_shadow") else "")] if nm else []
    why += ["FALSE_WAITING: " + ",".join(s["false_waiting"])] if s.get("false_waiting") else []
    why += [f"would-close: state DONE ({s['state_shadow']} shadow)"] if s.get("state_shadow") else []
    why += [f"state DONE ({s['state_close']} apply)"] if s.get("state_close") else []
    why += [f"state DONE held: {_cell(s['state_held'], 120)}"] if s.get("state_held") else []
    why += [f"state error: {_cell(s['state_error'], 120)}"] if s.get("state_error") else []
    why += ["fresh brief changed: " + ",".join(f"#{n}" for n in s["brief_changed"])] if s.get("brief_changed") else []
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
    ap.add_argument("--dead-claims-only", action="store_true",
                    help="run only the dead-claim pass (stima-api#7527): list the claims it would release; post them "
                         "only with --apply (the config's APPLY is ignored here)")
    args = ap.parse_args(argv)
    cfg = load_config(args.config)
    if args.idle_minutes is not None:
        cfg["IDLE_MINUTES"] = args.idle_minutes
    apply = args.apply or cfg["APPLY"] == "1"
    # stima-api #7061 review: only the live policy with its own threshold writes the sessions.json readers act on
    live_run = live_config(args.config) and args.idle_minutes is None
    sdir = state_dir(cfg)
    sdir.mkdir(parents=True, exist_ok=True)
    lock = open(sdir / "session-reaper.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("session-reaper: another run holds the lock")
        return 0
    now = time.time()
    if args.dead_claims_only:
        res = release_dead_claims(cfg, now, args.apply)
        print("\n".join([*dead_claim_lines(res), *res["notes"],
                         f"dead claims: {len(res['released'])} released, {len(res['would'])} would release, "
                         f"{len(res['deferred'])} deferred, {len(res['young'])} under the grace, {res['alive']} alive"]))
        return 0
    rows, failures, reaped, seen, stale, notes, rounds, gathered = [], [], 0, [], [], [], [], []
    dead_claims = None
    swept = state_on = False
    STATE_ROWS.clear()
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
        gathered = gather(cfg, now, include_bg=True)
        sessions = sorted([x for x in gathered if not x.get("unattached")], key=lambda x: judge_order(x, cfg))
        if not args.only:
            prefetch(sessions, cfg, now)
            if cfg.get("SESSION_STATE", "on") == "on":
                try:
                    notes += produce_state(cfg, gathered, now, sdir, live_run)
                    state_on = bool(STATE_ROWS)
                except Exception as e:  # no state: decide() keeps deciding as before #7061
                    failures.append(f"session state: {type(e).__name__}: {e}")
        for s in sessions:
            if args.only and s["tmux"] != args.only:
                continue
            if time.monotonic() - RUN_START > RUN_BUDGET:
                # `working`: not read, it cannot close this run whatever the oracle says; `unjudged:run-budget`: it
                # could have closed and the budget ran out first (stima-api#7904)
                why = ["unjudged:run-budget"] if can_close_now(s, cfg) else \
                    ["working:" + (f"status:{s['status']}" if s["status"] != "idle"
                                   else f"idle:{s['idle_min']:.0f}<{idle_threshold(s, cfg):g}min")]
                rows.append(report_line(s, why, "keep"))
                seen.append((s, why, "keep"))
                continue
            keep, outcome = [], "error"
            try:
                keep = decide(s, cfg)
                keep = confirm_close(s, cfg, keep)
                if s.get("done_grace_error"):
                    notes.append(f"{s['tmux']} ({s['sid']}): DONE_GRACE shadow: {s['done_grace_error']}")
                if s.get("oracle_not_mine_error"):
                    notes.append(f"{s['tmux']} ({s['sid']}): ORACLE_NOT_MINE shadow: {s['oracle_not_mine_error']}")
                outcome = "keep" if keep else ("reap" if apply else "would-reap")
                if keep:  # shadow only: the outcome label changes, nothing below acts on it
                    try:
                        sv = shadow_verdict(s, cfg, keep, now)
                        s["blocked"], s["would_close"] = sv["blocked"], sv["would_close"]
                        outcome = ("would-close" if sv["would_close"] or s.get("done_grace_shadow")
                                   or s.get("oracle_not_mine_shadow") or s.get("state_shadow") else outcome)
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
        swept = True
    except Exception as e:
        failures.append(f"sweep aborted: {type(e).__name__}: {e}")
    try:
        if swept and state_on and not args.only:  # one round per whole sweep that had a state
            rounds = shadow_rounds(cfg, args.config, seen, sdir, now, args.idle_minutes is not None)
    except Exception as e:  # the counter must not stop the report
        failures.append(f"shadow rounds: {type(e).__name__}: {e}")
    try:
        if not args.only:  # a one-session run would overwrite the list with that session alone
            idle_list(cfg, seen, now)
    except Exception as e:  # a report-only list must not stop the report
        failures.append(f"idle list: {type(e).__name__}: {e}")
    try:
        if apply:
            refused = []
            notes += [f"done marker written: {m}" for m in write_done_markers(cfg, gathered, now, refused)]
            notes += [f"done marker skipped: {m}" for m in refused]
    except Exception as e:  # a marker that could not be written only delays a reclaim
        notes.append(f"done marker: {type(e).__name__}: {e}")
    try:
        if not live_run:  # like sessions.json: only the live policy acts on GitHub; a preview or test config never does
            if cfg.get("DEAD_CLAIMS", "apply") != "off":
                notes.append("dead claims: skipped, not the live policy run (--dead-claims-only previews it)")
        elif not args.only and cfg.get("DEAD_CLAIMS", "apply") != "off":
            live_now = {s["tmux"] for s in gathered} | {s["name"] for s in gathered if s.get("name")}
            dead_claims = release_dead_claims(cfg, now, apply, (live_now, {s["sid"] for s in gathered if s.get("sid")}))
            notes += dead_claims["notes"]
    except Exception as e:  # a claim left held is the state before this pass: never fail the sweep over it
        notes.append(f"dead claims: {type(e).__name__}: {e}")
    signal.alarm(0)
    faulthandler.cancel_dump_traceback_later()
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
    if STATE_ROWS:
        report += ["", "## Session state (session_state.py, stima-api #7061)", "", *state_table()]
    if rounds:
        report += ["", "## Shadow rounds (" + ", ".join(SHADOW_SOURCES) + ")", *rounds]
    if dead_claims and dead_claim_lines(dead_claims):
        report += ["", "## Dead claims (stima-api#7527)", *[f"- {l}" for l in dead_claim_lines(dead_claims)]]
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
