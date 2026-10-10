#!/usr/bin/env python3
"""Reap finished interactive Claude Code sessions that run in tmux.

A session is reaped only when every gate holds: idle long enough, no background work, done
(a SESSION-DONE line or every claimed issue closed), its worktrees clean and pushed, not
waiting on a person, and not protected. Reaping types /exit at a verified empty prompt
(Stay if the background-task menu appears), kills the tmux session once claude has exited,
then verifies the process tree, tmux session, session file and worktree locks are gone.

Report-only unless the config sets APPLY=1 or --apply is passed.
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
ISSUE_RE = re.compile(r"(?:^|/)(\d{3,6})(?:-|$)")
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


def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
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


# ---------- transcript ----------

def transcript_path(sid):
    hits = glob.glob(str(PROJECTS_DIR / "*" / f"{sid}.jsonl"))
    return Path(hits[0]) if hits else None


def blocks(entry):
    c = entry.get("message", {}).get("content")
    return c if isinstance(c, list) else []


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
                elif b.get("name") == "CronCreate":
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


# ---------- gather and decide ----------

def gather(cfg, now):
    table = ps_table()
    wts = worktrees(cfg)
    found = []
    for f in sorted(SESSIONS_DIR.glob("*.json")):
        try:
            d = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if d.get("kind") != "interactive" or not d.get("tmux"):
            continue
        pid = d.get("pid")
        alive = pid in table and " ".join(d.get("procStart", "").split()) == table[pid][1]
        pane = d["tmux"].rsplit(".", 1)[-1]
        state = pane_state(pane) if alive else None
        if not alive or not state or not is_ancestor(table, state["pane_pid"], pid):
            continue  # stale file, recycled pid, or a pane that no longer holds this claude
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
            "owned": owned, "claims": claims, "descendants": len(descendants(table, pid)),
            **transcript_facts(transcript_path(sid), now),
        })
    return found


def protected(cfg, *names):
    return any(fnmatch.fnmatch(n, p) for p in cfg["PROTECT"].split() for n in names if n)


def waiting_re(cfg):
    extra = cfg.get("WAITING_EXTRA", "")
    return re.compile(WAITING_RE.pattern + ("|" + extra if extra else ""), re.I)


def decide(s, cfg):
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
    if s["asking"] or waiting_re(cfg).search(DONE_RE.sub("", s["last_text"])):
        keep.append("waiting")
    if not (DONE_RE.search(s["last_text"]) or DONE_PHRASE_RE.search(s["last_text"])):
        states = [issue_state(r, n) for r, n in s["claims"]]
        if not s["claims"]:
            keep.append("claim-unknown")
        elif any(st != "CLOSED" for st in states):
            keep.append("issue-open:" + ",".join(f"#{n}" for (_, n), st in zip(s["claims"], states)
                                                  if st != "CLOSED"))
    for w in s["owned"]:
        keep.extend(worktree_state(w, cfg))
    return keep


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
    stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
    issues = " ".join(f"{r}#{n}" for r, n in s["claims"]) or "-"
    log = Path(os.path.expanduser(cfg["CLOSED_LOG"]))
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a") as fh:
        fh.write(f"\n## {stamp} session-reaper (resume: claude --resume <sid>)\n"
                 f"- {s['tmux']} {s['sid']} cwd={s['cwd']} issues={issues} — {summary(s)}\n")
    for ref in s["claims"]:
        comment(ref, f"Session `{s['tmux']}` (`{s['sid']}`) finished and was reaped by session-reaper. "
                     f"Resume it with `cd {s['cwd']} && claude --resume {s['sid']}`.")
    # Kill only what this session owned: the whole tmux session if it was its only pane.
    s["killed_session"] = alone
    tmux("kill-session", "-t", s["session_id"]) if alone else tmux("kill-pane", "-t", s["pane"])
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
    issues = ",".join(f"#{n}" for _, n in s["claims"]) or "-"
    plan = f"pid {s['pid']}+{s['descendants']} desc; tmux {s['tmux']}; worktrees {wt}"
    return (f"| {s['tmux']} | `{s['sid'][:8]}` | {s['status']} {s['idle_min']:.0f}m | {issues} | "
            f"{outcome} | {', '.join(keep) or '-'} | {plan} |")


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
    rows, failures, reaped = [], [], 0
    try:
        for s in gather(cfg, now):
            if args.only and s["tmux"] != args.only:
                continue
            keep, outcome = [], "error"
            try:
                keep = decide(s, cfg)
                outcome = "keep" if keep else ("reap" if apply else "would-reap")
                if not keep and apply:
                    outcome, fails = reap(s, cfg, now)
                    reaped += outcome == "reaped"
                    failures += [f"{s['tmux']} ({s['sid']}): {f}" for f in fails]
                    if outcome == "reaped":
                        outcome = "reaped, verified" if not fails else "reaped, VERIFY FAILED"
            except Exception as e:  # one bad session must not cost the others their report
                failures.append(f"{s['tmux']} ({s['sid']}): {type(e).__name__}: {e}")
            rows.append(report_line(s, keep, outcome))
    except Exception as e:
        failures.append(f"sweep aborted: {type(e).__name__}: {e}")
    mode = "apply" if apply else "report-only"
    stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(now))
    report = [f"# session-reaper {mode} {stamp}", "",
              f"idle threshold {cfg['IDLE_MINUTES']} min; protected: {cfg['PROTECT'] or '(none)'}", "",
              "| tmux | session | status idle | issues | outcome | keeps it | verification target |",
              "|---|---|---|---|---|---|---|", *rows]
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
