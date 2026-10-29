#!/usr/bin/env python3
"""Detect Claude Code sessions stalled by an account switch or a rate limit, report each once, mark them.

A /login leaves every session at "Login successful. Remote Control disconnected." with its turn interrupted;
a spent quota leaves a session (or its subagents) at "You've hit your weekly limit" / HTTP 429. Nobody notices
until a person looks. This is the cheap detector for that, and it calls no model:

  detect  one `tmux display` + `tmux capture-pane -p` per live interactive session; the screen (and cursor) is
          hashed per pane and a pane is re-scanned only when the hash changed. Fingerprints:
            weekly-limit      "hit your weekly limit" (any "<word> limit")
            remote-disconnected   "Remote Control disconnected", unless a later line says it is connected again
            rate-limit-429    "429" or "rate_limit" on an agent result line (a `⎿` result or an `API Error`)
            interrupted-idle  "[Request interrupted by user]" (or the "Interrupted · What should Claude do instead?" result) just above an idle, empty prompt, counted only
                              when "Login successful" is on that screen or STALL_FLEET_MIN panes show it at
                              once (a single Esc by a person is not an account switch)
  report  once per event, deduped by (pane, fingerprint, session id): one block appended to STALL_INBOX under
          `## EL-T801-CI-HARDEN STALL <session-name>` with the exact `claude --resume <id> --remote-control
          <name>` a person or Neo runs. An event ends when its fingerprint leaves the screen, so a later
          stall in the same pane is a new event. Shadow by default: it prints what it would report and
          writes nothing to the inbox until STALL_APPLY=1 (or --apply).
  mark    a file per stalled session id in STALL_MARK_DIR, refreshed every run while the stall lasts. The
          session reaper reads it and keeps the session with the reason `stalled:<fingerprint>`. A mark only
          ever keeps a session, so it is written in shadow mode too.

HARD RULE (stima-api #5212): nothing here types into another agent's pane. The only tmux calls are `display`
and `capture-pane`; `tmux_ro` refuses every other subcommand, send-keys included. Re-enabling Remote Control
(or resuming) is a person's or Neo's step, given in the report.
"""

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import shlex
import sys
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location("session_reaper", Path(__file__).resolve().with_name("session-reaper.py"))
reaper = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(reaper)

HEADER = "EL-T801-CI-HARDEN STALL"
DEFAULTS = {
    "STALL_APPLY": "0",  # 0: shadow (print what would be reported). 1: append to STALL_INBOX
    "STALL_INBOX": "~/handoffs/neo-inbox.md",
    "STALL_STATE": "~/.cc-reaper/state/stall-watch.json",  # pane hashes and the events already seen
    "STALL_MARK_DIR": "~/.cc-reaper/state/stalled",  # one <session id>.json per stalled session
    "STALL_FLEET_MIN": "2",  # panes showing interrupted-idle at once that stand in for "Login successful"
}
READ_ONLY_TMUX = ("display", "capture-pane")  # #5212: nothing that types into a pane

WEEKLY_RE = re.compile(r"hit your (?:[\w-]+ )?limit", re.I)
REMOTE_RE = re.compile(r"Remote Control disconnected", re.I)
REMOTE_OK_RE = re.compile(r"(?:Remote Control|/remote-control) (?:is )?(?:active|reconnected|(?<!dis)connected)", re.I)
RESULT_LINE_RE = re.compile(r"⎿|API Error")
LIMIT_RE = re.compile(r"\b429\b|rate_limit")
INTERRUPT_RE = re.compile(r"\[Request interrupted by user[^\]]*\]|Interrupted · What should Claude do instead\?")
LOGIN_RE = re.compile(r"Login successful", re.I)
INTERRUPT_MAX_GAP = 8  # lines between the marker and the prompt line (the prompt box's border and blank lines)


def tmux_ro(*args):
    """The only tmux entry point: read-only subcommands, so no code path can type into a pane."""
    if not args or args[0] not in READ_ONLY_TMUX:
        raise RuntimeError(f"stall-watch never runs tmux {args[0] if args else ''}: it must not type into a pane (#5212)")
    return reaper.run(["tmux", *args], timeout=10)


reaper.tmux = tmux_ro  # reaper.pane_state and pane_exists now reach tmux only through the guard


def load_config(path):
    cfg = dict(DEFAULTS)
    cfg.update({k: v for k, v in reaper.load_config(path).items() if k in DEFAULTS})
    return cfg


def scan(pane):
    """Fingerprints one pane screen shows right now: {"fps": [...], "login": bool}. Pure over its argument
    ({"screen", "cx", "cy"}); `interrupted-idle` is a candidate that main() still has to corroborate."""
    lines = pane["screen"].split("\n")
    fps = []
    if WEEKLY_RE.search(pane["screen"]):
        fps.append("weekly-limit")
    last = max((i for i, l in enumerate(lines) if REMOTE_RE.search(l)), default=None)
    if last is not None and not any(REMOTE_OK_RE.search(l) for l in lines[last + 1:]):
        fps.append("remote-disconnected")
    for i, l in enumerate(lines):
        if RESULT_LINE_RE.search(l) and LIMIT_RE.search(" ".join(lines[i:i + 3])):
            fps.append("rate-limit-429")
            break
    marker = max((i for i, l in enumerate(lines) if INTERRUPT_RE.search(l)), default=None)
    if marker is not None and reaper.empty_prompt(pane) and 0 < pane["cy"] - marker <= INTERRUPT_MAX_GAP \
            and not any(l.strip() for l in lines[marker + 1:pane["cy"] - 1]):
        fps.append("interrupted-idle")
    return {"fps": fps, "login": bool(LOGIN_RE.search(pane["screen"]))}


def screen_hash(pane):
    h = hashlib.sha256()
    h.update(f"{pane['cx']},{pane['cy']}\n".encode())
    h.update(pane["screen"].encode("utf-8", "replace"))
    return h.hexdigest()


def live_sessions():
    """Interactive tmux sessions whose pid and start time still match: [(file data, pane id, pane state)]."""
    table = reaper.ps_table()
    out = []
    for f in sorted(reaper.SESSIONS_DIR.glob("*.json")):
        try:
            d = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        pid = d.get("pid")
        if d.get("kind") != "interactive" or not d.get("tmux") or pid not in table \
                or " ".join(d.get("procStart", "").split()) != table[pid][1]:
            continue
        pane = d["tmux"].rsplit(".", 1)[-1]
        state = reaper.pane_state(pane)
        if state and reaper.is_ancestor(table, state["pane_pid"], pid) and d.get("sessionId"):
            out.append((d, pane, state))
    return out


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def one_line(text):
    return re.sub(r"\s+", " ", text or "").strip()


def resume_command(sid, name):
    return f"claude --resume {shlex.quote(sid)} --remote-control {shlex.quote(name)}"


def inbox_block(name, sid, fps, now):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(now))
    return (f"\n## {HEADER} {name}\n\n"
            f"STALL session={name} id={sid} fingerprint={','.join(fps)} detected={stamp}; "
            f"recover (a person or Neo runs it; the detector types nothing): `{resume_command(sid, name)}`\n")


def append_inbox(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(text)


def load_state(path):
    try:
        st = json.loads(path.read_text())
        return {"panes": dict(st.get("panes", {})), "events": dict(st.get("events", {}))}
    except (OSError, ValueError, AttributeError, TypeError):
        return {"panes": {}, "events": {}}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", default=str(reaper.CONFIG))
    ap.add_argument("--apply", action="store_true", help="append reports to STALL_INBOX (default: shadow, unless STALL_APPLY=1)")
    args = ap.parse_args(argv)
    cfg = load_config(args.config)
    apply = args.apply or cfg["STALL_APPLY"] == "1"
    state_path = Path(os.path.expanduser(cfg["STALL_STATE"]))
    mark_dir = Path(os.path.expanduser(cfg["STALL_MARK_DIR"])) if cfg["STALL_MARK_DIR"] else None
    inbox = Path(os.path.expanduser(cfg["STALL_INBOX"]))
    state_path.parent.mkdir(parents=True, exist_ok=True)
    lock = open(state_path.with_name(state_path.name + ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("stall-watch: another run holds the lock")
        return 0
    try:
        return sweep(cfg, apply, state_path, mark_dir, inbox)
    finally:
        lock.close()


def sweep(cfg, apply, state_path, mark_dir, inbox):
    now = time.time()
    state = load_state(state_path)
    old_panes, panes, rescanned = state["panes"], {}, 0
    live = live_sessions()
    for d, pane, ps in live:
        sid, h = d["sessionId"], screen_hash(ps)
        prev = old_panes.get(pane)
        if prev and prev.get("hash") == h and prev.get("sid") == sid:
            panes[pane] = prev  # unchanged screen: nothing to re-read
            continue
        rescanned += 1
        panes[pane] = {"hash": h, "sid": sid, **scan(ps)}
    fleet = sum("interrupted-idle" in p["fps"] for p in panes.values())
    fleet_min = max(1, int(cfg["STALL_FLEET_MIN"] or 2))
    events, failures, would, stalled = {}, [], 0, {}
    for d, pane, ps in live:
        sid, p = d["sessionId"], panes[pane]
        name = one_line(ps["session"]) or one_line(d.get("name")) or sid[:8]
        confirmed = [f for f in p["fps"] if f != "interrupted-idle" or p["login"] or fleet >= fleet_min]
        if not confirmed:
            continue
        stalled[sid] = {"sid": sid, "tmux": name, "fingerprints": confirmed, "pane": pane}
        fresh = []
        for fp in confirmed:
            key = f"{pane}|{fp}|{sid}"
            ev = state["events"].get(key) or {"first": now, "reported": False}
            events[key] = ev
            if not ev["reported"] and (apply or not ev.get("shadow_logged")):  # shadow logs an event once too
                fresh.append(fp)
        if not fresh:
            continue
        if apply:
            try:
                append_inbox(inbox, inbox_block(name, sid, fresh, now))
                for fp in fresh:
                    events[f"{pane}|{fp}|{sid}"]["reported"] = True
                print(f"stall-watch: reported {name} ({sid[:8]}) {','.join(fresh)}")
            except OSError as e:
                failures.append(f"{name} ({sid}): inbox write failed: {e}")
        else:
            would += 1
            for fp in fresh:
                events[f"{pane}|{fp}|{sid}"]["shadow_logged"] = True
            print(f"stall-watch shadow: would report {name} ({sid[:8]}) {','.join(fresh)} -> {resume_command(sid, name)}")
    if mark_dir:
        mark_dir.mkdir(parents=True, exist_ok=True)
        for sid, m in stalled.items():
            if re.fullmatch(r"[\w-]+", sid):
                atomic_write(mark_dir / f"{sid}.json", json.dumps({**m, "updated": now}) + "\n")
        for f in mark_dir.glob("*.json"):
            if f.stem not in stalled:
                f.unlink(missing_ok=True)  # the stall cleared, or the session is gone
    atomic_write(state_path, json.dumps({"panes": panes, "events": events}) + "\n")
    print(f"stall-watch {'apply' if apply else 'shadow'}: {len(live)} sessions, {rescanned} rescanned, "
          f"{len(stalled)} stalled, {would} would report, {len(failures)} failures")
    for f in failures:
        print(f"stall-watch: ERROR {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
