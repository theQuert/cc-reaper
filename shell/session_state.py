#!/usr/bin/env python3
"""One answer per live Claude Code session, produced once and read by every tool (stima-api #7061).

Each session gets exactly one `state`:

  WORKING         busy, background work of its own (a shell, a pending wakeup, a cron, a scheduled task, a subagent
                  written to lately, a child process, a never-kill pid in its tree), an oracle step that is this
                  session's, a `loop #N` whose check-by is due within its idle threshold, or
                  idle for less than its threshold.
  WAITING_PERSON  an oracle person-step on one of its claims (a stop it has reported), an open AskUserQuestion, or a
                  confirmation dialog on screen. Never a keyword in its text.
  UNKNOWN         a claim the oracle cannot place (unread brief, a claimant that is no live session, an unclaimed
                  agent step, a wait shape not recognized), a worktree not checked within the budget, or a stall mark.
  PUSH            only unpushed or uncommitted work in a worktree it owns keeps it.
  DONE            idle past its threshold, no claim whose oracle step is its own, every worktree clean and pushed, no
                  background work. The threshold is the reaper's own idle_threshold(): a `SESSION-DONE:` line (or
                  `SESSION-STATE: IDLE_NO_WORK`) shortens it to DONE_GRACE_MINUTES only under DONE_GRACE=apply.

Claims: the issue number in the branch of every worktree the session owns, the reaper's branch_issue() (ISSUE_RE: the number
starts the branch or follows a `/`, `claude/7023-x` names #7023; WORD_ISSUE_RE on a stima-api tree only: `claude-7023-x` names
#7023 there and nothing on a skills or cc-reaper tree; `canary-main-1031` names none); for a session with no branch claim, an issue its name or last reply names
whose oracle claimant (`delivery_state.py N --brief`, from the newest `Claimed by ... session` comment) is this
session; for a `loop #N ...` background session, #N.

The facts come from the reaper's own gather (tmux panes, session files, transcripts, worktrees) and its oracle
readers, loaded from `session-reaper.py` beside this file: there is one gatherer, and this module only judges.
session-reaper.py runs it in every sweep and writes the file; `session_state.py` alone writes it too (read-only
otherwise: no pane is typed into, no session closed).

File: ~/.cc-reaper/state/sessions.json (CC_SESSION_STATE_FILE overrides; the reaper's STATE_DIR moves the default).
Only a run on the live policy (the reaper's CONFIG) with its own threshold writes it; a run on another config writes
under that config's STATE_DIR, or nowhere (the reaper's state_file()).
Readers call read(): None when the file is missing, unreadable, of another version or older than MAX_AGE_SECONDS,
which every reader treats as "no answer" (nothing is released on it).
"""

import argparse
import importlib.util
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

VERSION = 1
STATES = ("WORKING", "PUSH", "WAITING_PERSON", "DONE", "UNKNOWN")
ENV_FILE = "CC_SESSION_STATE_FILE"
ENV_REAPER = "CC_SESSION_REAPER"
MAX_AGE_SECONDS = 45 * 60  # the reaper writes every 30 min; a reader acts on nothing older
LOOP_RE = re.compile(r"^loop #(\d{3,6})(?!\d)")
DIALOG_RE = re.compile(r"\(y/n\)|do you want to proceed|Enter to confirm|Esc to cancel", re.I)
HEAD_RE = re.compile(r"\Adelivery #\d+: [^\n]*? -> (\w+)(?: (\S+))?")
RECORD_CHECKBY_RE = re.compile(r"\A\s*record `check-by ")


def default_path(state_dir=None):
    if os.environ.get(ENV_FILE):
        return Path(os.environ[ENV_FILE])
    return Path(state_dir or Path.home() / ".cc-reaper" / "state") / "sessions.json"


def _same(a, b):
    a, b = str(a or "").lower(), str(b or "").lower()
    return bool(a) and bool(b) and (a.startswith(b) or b.startswith(a))


def claim_step(r, brief, sid, mine_ids=(), other_sids=()):
    """(oracle_step, mine, person) for one claim from its `--brief` text; `r` is the reaper module.

    mine: True when the step is this session's (an agent step whose claimant is this session or a worktree marker it
    owns, a stop it has not reported yet, a wait that asks it to record a check-by); False when it is not (closed, a
    reported stop, a wait whose waker is named, an agent step another live session claims); None when the oracle
    cannot place it. person: the step is a stop already on the issue (a person, or a record, wakes it)."""
    if not brief:
        return "", None, False
    if (r.BRIEF_STATE_RE.match(brief) or [None, ""])[1].lower() == "closed":
        return "closed", False, False
    h = HEAD_RE.match(brief)
    if not h:
        return "", None, False
    kind, step = h.group(1), " ".join(x for x in h.groups() if x)
    if kind == "closed" or kind == "none":
        return step, False, False
    if kind == "stop":
        rep = r.STOP_REPORTED_RE.search(brief)
        if rep and rep.group(1) == h.group(2):
            return step, False, True
        return step, True, False  # the stop comment (or its ask) is still the session's to post
    if kind == "wait":
        # the reaper's own reader: the oracle's trailer (judge, redundant check-by, board) follows the deciding line
        if r._oracle_last(brief, r.OWNER_END_RE) or r._oracle_last(brief, r.CHECKBY_END_RE):
            return step, False, False
        if r._oracle_last(brief, RECORD_CHECKBY_RE):
            return step, True, False  # it owes the check-by comment that schedules its wake
        return step, None, False
    if kind == "agent":
        c = r.CLAIMANT_RE.search(brief)
        if not c:
            return step, None, False  # unclaimed: whoever claims it; not provably this session's or another's
        if _same(c.group(1), sid) or any(_same(c.group(1), m) for m in mine_ids):
            return step, True, False
        if any(_same(c.group(1), o) for o in other_sids):
            return step, False, False
        return step, None, False
    return step, None, False


def _claims(s, r, cfg, now, thr):
    """[(repo, number, source)]: branch claims, a background loop's #N, else issues the session names whose claimant
    is this session (only for an idle session past its threshold: the lookup costs an oracle call per issue)."""
    out = [(rp, str(n), "branch") for rp, n in s.get("claims") or ()]
    repo = cfg.get("CHECKBY_REPO") or ""
    m = LOOP_RE.match(s.get("name") or "")
    if s.get("kind") == "bg" and m and repo and not any(n == m.group(1) for _, n, _ in out):
        out.append((repo, m.group(1), "name"))
    if not out and s.get("status") == "idle" and s.get("idle_min", 0) >= thr:
        out += [(rp, str(n), "named") for rp, n in r.oracle_claims(s, cfg, now)]
    return out


def judge(s, r, cfg, now):
    """The state record of one gathered session (`s` as the reaper's gather() returns it)."""
    sid = s.get("sid") or ""
    rec = {"name": s.get("name") or s.get("tmux") or sid[:8], "tmux": s.get("tmux") or "", "sid": sid,
           "pid": s.get("pid"), "kind": s.get("kind") or "interactive", "status": s.get("status"),
           "status_at": s.get("status_at"), "idle_min": round(float(s.get("idle_min") or 0), 1),
           "claims": [], "worktrees": [], "bg_work": [], "state": "UNKNOWN", "reasons": []}
    try:
        thr = r.idle_threshold(s, cfg)  # the reaper's own: DONE_GRACE=shadow keeps IDLE_MINUTES
        rec["idle_threshold"] = thr
        mine_ids = [w["marker"] for w in s.get("owned") or () if w.get("marker")]
        own, person, unknown = [], [], []
        for repo, n, src in _claims(s, r, cfg, now, thr):
            step, mine, pers = claim_step(r, r.oracle_brief(repo, n, cfg, now), sid, mine_ids, s.get("other_sids", ()))
            c = {"issue": int(n), "repo": repo, "source": src, "oracle_step": step, "mine": mine}
            if src == "name":  # a background loop: when its check-by falls due (None: the oracle could not say)
                d = r.oracle_json(repo, n, cfg) if repo == cfg.get("CHECKBY_REPO") else None
                c["check_by"] = str(d.get("pending_check_by") or "") if isinstance(d, dict) else None
            rec["claims"].append(c)
            label = f"#{n} {step or 'unread'}"
            if c.get("check_by", "") is None and mine is not True:
                mine = None  # past its due or not is unknown: never DONE on it
            (own if mine else person if pers else unknown if mine is None else []).append(label)
        for w in s.get("owned") or ():
            probs = r.worktree_state(w, cfg)
            rec["worktrees"].append({"path": str(w["path"]), "branch": w.get("branch") or "",
                                     "dirty": any(p.startswith("uncommitted:") for p in probs),
                                     "unpushed": any(p.startswith("unpushed:") for p in probs),
                                     "unchecked": any(p.startswith("unchecked:") for p in probs)})
        bg = rec["bg_work"]
        bg += ["shell-child"] if s.get("bg_shells") else []
        bg += ["loop-pending"] if s.get("loop") else []
        bg += ["scheduled-task"] if (s.get("crons") or 0) > 0 or s.get("scheduled") else []
        bg += ["subagent-active"] if s.get("sub_active") else []
        # a never-kill pid or a child process: B (the dispatcher) stops a DONE session, so these are never DONE
        bg += ["never-kill:" + ",".join(str(p) for p in s["never_kill"])] if s.get("never_kill") else []
        bg += [f"child-process:{s['descendants']}"] if (s.get("descendants") or 0) > 0 else []
        stalled = r.stall_mark(cfg, sid, now)
        # a loop's check-by keeps it only when it falls due within the idle threshold: further out it holds a live slot
        # for nothing (the prompt cache lives 60 min, so a later resume costs what a fresh wake does; stima-api#7061)
        ahead = [c for c in rec["claims"]
                 if c.get("check_by") and now < (r._iso_epoch(c["check_by"]) or 0) <= now + thr * 60]
        dirty = [w for w in rec["worktrees"] if w["dirty"] or w["unpushed"]]
        st, why = _state(s, rec, thr, own, person, unknown, stalled, ahead, dirty)
        rec["state"], rec["reasons"] = st, why
    except Exception as e:  # a session this cannot judge is UNKNOWN, never DONE
        rec["state"], rec["reasons"] = "UNKNOWN", [f"error:{type(e).__name__}: {e}"[:200]]
    return rec


def _state(s, rec, thr, own, person, unknown, stalled, ahead, dirty):
    if s.get("status") != "idle":
        return "WORKING", [f"status:{s.get('status')}"]
    if rec["bg_work"]:
        return "WORKING", list(rec["bg_work"])
    if own:
        return "WORKING", ["own-step:" + "; ".join(own)]
    if stalled:
        return "UNKNOWN", ["stalled:" + stalled]
    asks = (["asking"] if s.get("asking") else []) + (["dialog"] if DIALOG_RE.search(s.get("screen_tail") or "") else [])
    if person or asks:
        return "WAITING_PERSON", asks + (["person-step:" + "; ".join(person)] if person else [])
    unchecked = [Path(w["path"]).name for w in rec["worktrees"] if w["unchecked"]]
    if unknown or unchecked:
        return "UNKNOWN", (["oracle-unknown:" + "; ".join(unknown)] if unknown else []) \
            + (["unchecked:" + ",".join(unchecked)] if unchecked else [])
    if ahead:
        return "WORKING", ["check-by-ahead:" + ",".join(f"#{c['issue']} {c['check_by']}" for c in ahead)]
    if rec["idle_min"] < thr:
        return "WORKING", [f"idle:{rec['idle_min']:.0f}<{thr:g}min"]
    if dirty:
        return "PUSH", [("unpushed:" if w["unpushed"] else "uncommitted:") + Path(w["path"]).name for w in dirty]
    why = [f"#{c['issue']} {c['oracle_step'] or 'unread'} (not its step)" for c in rec["claims"]] or ["no claim"]
    return "DONE", why + ([f"idle {rec['idle_min']:.0f}>={thr:g}min"])


def judge_all(r, sessions, cfg, now, workers=8):
    """Judge every session, `workers` at a time (each claim may cost an oracle call; the reaper's caches are shared)."""
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        return list(pool.map(lambda s: judge(s, r, cfg, now), sessions))


def document(records, now, unjudged=()):
    return {"version": VERSION, "producer": "session_state.py", "at_epoch": now,
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
            "counts": {k: sum(1 for x in records if x["state"] == k) for k in STATES},
            "sessions": list(records), "unjudged": list(unjudged)}


def write(doc, path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
    os.replace(tmp, path)
    return path


def read(path=None, now=None, max_age=MAX_AGE_SECONDS):
    """The document, or None when it is missing, unreadable, of another version or older than max_age seconds."""
    try:
        doc = json.loads(Path(path or default_path()).read_text())
        at = float(doc["at_epoch"])
        if doc.get("version") != VERSION or not isinstance(doc.get("sessions"), list):
            return None
    except (OSError, ValueError, KeyError, TypeError):
        return None
    age = (now if now is not None else time.time()) - at
    return doc if 0 <= age <= max_age else None


def by_sid(doc):
    return {str(x.get("sid")): x for x in (doc or {}).get("sessions") or () if isinstance(x, dict) and x.get("sid")}


def lookup(doc, session_id):
    """The record whose sid is `session_id` or shares an 8+ character prefix with it, when exactly one does."""
    sid = str(session_id or "")
    if len(sid) < 8:
        return None
    hits = [x for k, x in by_sid(doc).items() if len(k) >= 8 and _same(k, sid)]
    return hits[0] if len(hits) == 1 else None


def load_reaper(path=None):
    p = Path(path or os.environ.get(ENV_REAPER) or Path(__file__).resolve().with_name("session-reaper.py"))
    spec = importlib.util.spec_from_file_location("session_reaper", p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", help="the reaper policy (default: the reaper's CONFIG)")
    ap.add_argument("--out", help="where to write (default: the live file for the live config, else the config's "
                                  "own STATE_DIR/sessions.json)")
    ap.add_argument("--print", action="store_true", help="also print one line per session")
    args = ap.parse_args(argv)
    r = load_reaper()
    cfg = r.load_config(args.config or r.CONFIG)
    now = time.time()
    gathered = r.gather(cfg, now, include_bg=True)
    r.prefetch([s for s in gathered if not s.get("unattached")], cfg, now)
    records = judge_all(r, gathered, cfg, now)
    unjudged = [{"label": label, "why": why} for label, why, live in r.SKIPPED if live and why != "kind:bg"]
    live = args.config is None or r.live_config(args.config)
    ss = SimpleNamespace(default_path=default_path)
    out = Path(args.out) if args.out else r.state_file(cfg, live, ss)
    if args.out and not live and r.is_live_state_path(out, ss):
        print("session_state: not written: --out names the live sessions.json while --config is not the live config",
              file=sys.stderr)
        return 2
    if out is None:
        print("session_state: not written: --config is not the live config and sets no STATE_DIR of its own; "
              "pass --out", file=sys.stderr)
        return 2
    out = write(document(records, now, unjudged), out)
    if args.print:
        for x in records:
            print(f"{x['name']}\t{x['sid'][:8]}\t{x['state']}\t{', '.join(x['reasons'])}")
    print(f"session_state: {len(records)} sessions; " + ", ".join(f"{k}={v}" for k, v in
                                                                  document(records, now)["counts"].items())
          + f"; {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
