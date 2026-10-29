#!/usr/bin/env python3
"""Detect Claude Code sessions stalled by an account switch or a rate limit, report each once, mark them.

A /login leaves every session at "Login successful. Remote Control disconnected." with its turn interrupted;
a spent quota leaves a session (or its subagents) at "You've hit your weekly limit" / HTTP 429. Nobody notices
until a person looks. This is the cheap detector for that, and it calls no model:

  detect  one `tmux display` + `tmux capture-pane -p` per live interactive session; the screen (and cursor) is
          hashed per pane and a pane is re-scanned only when the hash changed. Fingerprints:
            weekly-limit      "hit your weekly limit" (any "<word> limit")
            remote-disconnected   "Remote Control disconnected", unless a later line says it is connected again
            rate-limit-429    "429" or "rate_limit_error" in an `API Error` line, or "status 429" in a `⎿` result
                              that itself starts with `Agent failed`, `Error:` or `API Error` (not any result
                              that merely contains the text, such as test or grep output)
            interrupted-idle  "[Request interrupted by user]" (or the "Interrupted · What should Claude do
                              instead?" result) just above an idle, empty prompt, counted only when "Login
                              successful" is on that screen or STALL_FLEET_MIN panes show it at once (a single
                              Esc by a person is not an account switch)
  report  once per event, deduped by (pane, fingerprint, session id): one block appended to STALL_INBOX under
          `## EL-T801-CI-HARDEN STALL <session-name>` with the exact `claude --resume <id> --remote-control
          <name>` a person or Neo runs. An event ends when its fingerprint leaves the screen, so a later
          stall in the same pane is a new event. Shadow by default: it prints what it would report and
          writes nothing to the inbox until STALL_APPLY=1 (or --apply).
  mark    only with STALL_APPLY=1 (a mark holds the reaper, so shadow never writes one): a file per stalled
          session id in STALL_MARK_DIR, refreshed every run while the stall lasts and ignored by the session
          reaper STALL_MARK_HOURS after its last refresh or STALL_MARK_MAX_HOURS after the event was first
          seen. The reaper keeps the session with the reason `stalled:<fingerprint>`.
  prompt  (EL-T921-CI-CONFIRM-CLEAR) a permission prompt ("Do you want to proceed?" with "1. Yes" ... "N. No") or an
          AskUserQuestion menu ("☐ <header>", options, "Enter to select · ↑/↓ to navigate") live at the bottom of a
          pane is aged from its first sighting per (session id, prompt fingerprint) in the state file. Past
          STALL_PROMPT_MINUTES (10) it is flagged with its age: with apply one `## EL-T921-PROMPT-STALL <session>`
          block in STALL_INBOX, in shadow one `would alert prompt` line, and again at most every
          STALL_PROMPT_REALERT_MINUTES (120) while the same prompt stays. No push channel to the founder's device
          exists in cc-reaper or ~/.claude hooks, so that half is a log line only. The prompt is never answered.

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
PROMPT_HEADER = "EL-T921-PROMPT-STALL"  # its own inbox key: not under the dispatch key, so it never reopens that one
DEFAULTS = {
    "STALL_APPLY": "0",  # 0: shadow (print what would be reported). 1: append to STALL_INBOX
    "STALL_INBOX": "~/handoffs/neo-inbox.md",
    "STALL_STATE": "~/.cc-reaper/state/stall-watch.json",  # pane hashes and the events already seen
    "STALL_MARK_DIR": "~/.cc-reaper/state/stalled",  # one <session id>.json per stalled session
    "STALL_MARK_MAX_HOURS": "48",  # no mark past this long after the event was first seen, however often it is refreshed
    "STALL_FLEET_MIN": "2",  # panes showing interrupted-idle at once that stand in for "Login successful"
    "STALL_PROMPT_MINUTES": "10",  # a permission prompt or AskUserQuestion menu on screen this long is flagged (0: off)
    "STALL_PROMPT_REALERT_MINUTES": "120",  # the same prompt still on screen is flagged again at most this often
}
READ_ONLY_TMUX = ("display", "capture-pane")  # #5212: nothing that types into a pane

# Claude Code's own system and status lines only. Each pattern is anchored at the start of a line (after an optional
# `⎿` result gutter or `⏺`/`●` message bullet) and has the exact shape of the line, so a sentence that quotes the words,
# a file listing, or a `⎿` result that merely contains "429" or "rate_limit" is not a stall. The `⎿` gutter is a tool
# result, whose content can be anything (grep, test output): only the weekly limit, `API Error`, an agent failure and
# the interrupt result are Claude Code's own text there. The Remote Control lines are never a result (BULLET).
LEAD = r"^\s*(?:⎿\s*)?(?:[⏺●]\s*)?"
BULLET = r"^\s*(?:[⏺●]\s*)?"
WEEKLY_RE = re.compile(LEAD + r"You(?:'|’)ve hit your (?:[\w-]+ )?limit\b\s*(?:[·∙]\s*resets\b|[.!]?\s*$)", re.I)
REMOTE_RE = re.compile(BULLET + r"(?:Login successful\.\s*)?Remote Control disconnected\b\s*(?:—|-|\.|$)", re.I)
REMOTE_OK_RE = re.compile(r"^\s*(?:[⏺●]\s*)?(?:Remote Control|/remote-control) (?:is )?(?:active|reconnected|(?<!dis)connected)\b", re.I)
API_ERROR_RE = re.compile(LEAD + r"API Error\b")  # the error itself must carry 429 / rate_limit_error within its 3 lines
API_ERROR_CODE_RE = re.compile(r"\b429\b|\brate_limit_error\b")
STATUS_429_RE = re.compile(r"\bstatus(?: code)?\s*[:=]?\s*429\b", re.I)  # a failed agent result: "... with status 429 ..."
AGENT_FAILED_RE = re.compile(r"^\s*⎿\s*(?:Agent failed|Error:|API Error)")
INTERRUPT_RE = re.compile(LEAD + r"(?:\[Request interrupted by user[^\]]*\]|Interrupted · What should Claude do instead\?)\s*$")
LOGIN_RE = re.compile(BULLET + r"Login successful\b", re.I)
INTERRUPT_MAX_GAP = 8  # lines between the marker and the prompt line (the prompt box's border and blank lines)

# Interactive prompts nobody may answer (EL-T921-CI-CONFIRM-CLEAR). Both are matched only as the live menu at the bottom
# of the screen: the question, its numbered options and at most PROMPT_TAIL non-blank lines below the last of them (the
# footer and Claude Code's bottom rule), so a transcript that quotes the words is not a prompt.
#   permission         "Do you want to proceed?" (or "... make this edit to x?") followed by "❯ 1. Yes" ... "N. No"
#   ask-user-question  the AskUserQuestion menu: a "☐ <header>" tab line, the question, numbered options, and the
#                      footer "Enter to select · ↑/↓ to navigate · ... · Esc to cancel"
RULE_RE = re.compile(r"^\s*[─━]{20,}")
PERM_Q_RE = re.compile(r"^\s*Do you want to [^\n]{1,200}\?\s*$")
OPT_YES_RE = re.compile(r"^\s*(?:❯\s*)?1\.\s+Yes\b")
OPT_NO_RE = re.compile(r"^\s*(?:❯\s*)?\d\.\s+No\b")
OPT_RE = re.compile(r"^\s*(?:❯\s*)?\d+\.\s+\S")
ASK_FOOTER_RE = re.compile(r"^\s*Enter to select\b.*\bto navigate\b")
ASK_TAB_RE = re.compile(r"^\s*(?:←\s*)?[☐☒✔✓]\s+\S")
PROMPT_TAIL = 4  # non-blank lines allowed below a prompt's last option or footer
PROMPT_SPAN = 60  # lines searched upward from the anchor for the start of the prompt
PROMPT_NOISE_RE = re.compile(r"[\s❯│╌─━]+")  # wrap, cursor and box characters do not change a prompt's identity


def _tail_ok(lines, last):
    return sum(1 for l in lines[last + 1:] if l.strip()) <= PROMPT_TAIL


def _fingerprint(kind, region):
    """A prompt instance's identity: its title, text and question, without the option cursor, the preview box or the
    wrap width, so the same prompt keeps one fingerprint while it waits and a different prompt gets another."""
    text = PROMPT_NOISE_RE.sub("", "".join(region))
    return hashlib.sha256(f"{kind}\n{text}".encode("utf-8", "replace")).hexdigest()[:16]


def scan_prompt(lines):
    """The interactive prompt on screen, as {"kind", "fp"}, or None. Pure over the screen lines."""
    for i in range(len(lines) - 1, -1, -1):
        if not PERM_Q_RE.search(lines[i]):
            continue
        yes = next((j for j in range(i + 1, min(i + 4, len(lines))) if OPT_YES_RE.search(lines[j])), None)
        if yes is None:
            break  # the newest question is not a live permission menu
        no = next((j for j in range(yes + 1, min(yes + 6, len(lines))) if OPT_NO_RE.search(lines[j])), None)
        if no is None:
            break
        last = max(j for j in range(yes, min(no + 6, len(lines))) if OPT_RE.search(lines[j]))
        if not _tail_ok(lines, last):
            break
        start = next((j for j in range(i - 1, max(-1, i - PROMPT_SPAN), -1) if RULE_RE.search(lines[j])), max(-1, i - 12))
        return {"kind": "permission", "fp": _fingerprint("permission", lines[start + 1:i + 1])}
    foot = max((i for i, l in enumerate(lines) if ASK_FOOTER_RE.search(l)), default=None)
    if foot is None or not _tail_ok(lines, foot):
        return None
    lo = max(0, foot - PROMPT_SPAN)
    # The menu starts at its nearest "☐ <header>" tab line (else just below the nearest rule above its options), never
    # at a numbered list higher up in the transcript.
    tab = next((j for j in range(foot - 1, lo - 1, -1) if ASK_TAB_RE.search(lines[j])), None)
    if tab is None:
        last_opt = next((j for j in range(foot - 1, lo - 1, -1) if OPT_RE.search(lines[j])), None)
        if last_opt is None:
            return None
        tab = next((j + 1 for j in range(last_opt - 1, lo - 1, -1) if RULE_RE.search(lines[j])), last_opt)
    first_opt = next((j for j in range(tab, foot) if OPT_RE.search(lines[j])), None)
    if first_opt is None:
        return None
    return {"kind": "ask-user-question", "fp": _fingerprint("ask-user-question", lines[tab:first_opt])}


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
    if any(WEEKLY_RE.search(l) for l in lines):
        fps.append("weekly-limit")
    last = max((i for i, l in enumerate(lines) if REMOTE_RE.search(l)), default=None)
    if last is not None and not any(REMOTE_OK_RE.search(l) for l in lines[last + 1:]):
        fps.append("remote-disconnected")
    for i, l in enumerate(lines):
        window = " ".join(x.strip() for x in lines[i:i + 3])
        if (API_ERROR_RE.search(l) and API_ERROR_CODE_RE.search(window)) or (AGENT_FAILED_RE.search(l) and STATUS_429_RE.search(window)):
            fps.append("rate-limit-429")
            break
    marker = max((i for i, l in enumerate(lines) if INTERRUPT_RE.search(l)), default=None)
    if marker is not None and reaper.empty_prompt(pane) and 0 < pane["cy"] - marker <= INTERRUPT_MAX_GAP \
            and not any(l.strip() for l in lines[marker + 1:pane["cy"] - 1]):
        fps.append("interrupted-idle")
    return {"fps": fps, "login": any(LOGIN_RE.search(l) for l in lines), "prompt": scan_prompt(lines)}


def screen_hash(pane):
    h = hashlib.sha256()
    h.update(f"{pane['cx']},{pane['cy']}\n".encode())
    h.update(pane["screen"].encode("utf-8", "replace"))
    return h.hexdigest()


SID_RE = re.compile(r"[\w-]+")


def live_sessions():
    """Interactive tmux sessions whose pid and start time still match: [(file data, pane id, pane state)].
    The state is None when the read failed (a tmux timeout under load, an empty capture): that session is still
    live, so the caller keeps what it knew instead of treating the session as gone."""
    table = reaper.ps_table()
    if not table:
        return None  # ps failed: every session would look gone, which must not clear anything
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
        if not SID_RE.fullmatch(str(d.get("sessionId") or "")):
            continue  # the id goes into a file name, a shell command and the inbox: only [\w-]+
        state = reaper.pane_state(pane)
        if state is not None and not state["screen"].strip():
            state = None  # tmux answered `display` but the capture came back empty: not a reading
        if state is None:
            out.append((d, pane, None))
        elif reaper.is_ancestor(table, state["pane_pid"], pid):
            out.append((d, pane, state))
    return out


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def one_line(text):
    """One line with no backtick: the name sits in a markdown code span (the recovery command) and a header."""
    return re.sub(r"\s+", " ", (text or "").replace("`", "'")).strip()


MARK_KEYS = {"sid", "tmux", "fingerprints", "pane", "since", "updated"}


def is_mark(path):
    """A file this script wrote: <sid>.json holding exactly the mark schema for that sid. Nothing else is deleted."""
    try:
        d = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    return SID_RE.fullmatch(path.stem) is not None and isinstance(d, dict) and set(d) == MARK_KEYS \
        and d["sid"] == path.stem and isinstance(d["fingerprints"], list)


def shared_dir(path):
    """Directories that hold other programs' files; a mark directory must never be one of them."""
    p = path.resolve()
    home = reaper.HOME.resolve()
    return p in {Path("/"), home, home / ".claude", home / ".claude" / "projects", home / ".cc-reaper",
                 home / ".cc-reaper" / "state", reaper.SESSIONS_DIR.resolve(), reaper.PROJECTS_DIR.resolve()} \
        or reaper.SESSIONS_DIR.resolve() in p.parents or reaper.PROJECTS_DIR.resolve() in p.parents


def resume_command(sid, name):
    return f"claude --resume {shlex.quote(sid)} --remote-control {shlex.quote(name)}"


def inbox_block(name, sid, fps, now):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(now))
    return (f"\n## {HEADER} {name}\n\n"
            f"STALL session={name} id={sid} fingerprint={','.join(fps)} detected={stamp}; "
            f"recover (a person or Neo runs it; the detector types nothing): `{resume_command(sid, name)}`\n")


def prompt_block(name, sid, pane, ev, now):
    """Numbers, the session name and a fixed kind only: no screen text (a command line can carry a secret, and text a
    session wrote must not steer the reader)."""
    stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(ev["first"]))
    again = f" re-alert={ev['alerts']}" if ev.get("alerts") else ""
    return (f"\n## {PROMPT_HEADER} {name}\n\n"
            f"PROMPT session={name} id={sid} pane={pane} kind={ev['kind']} prompt={ev['fp']} "
            f"on-screen={int((now - ev['first']) // 60)}m since={stamp}{again}; "
            f"a person answers it at the pane (the detector never answers, types nothing)\n")


def append_inbox(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(text)


def load_state(path):
    try:
        st = json.loads(path.read_text())
        return {"panes": dict(st.get("panes", {})), "events": dict(st.get("events", {})),
                "prompts": dict(st.get("prompts", {}))}
    except (OSError, ValueError, AttributeError, TypeError):
        return {"panes": {}, "events": {}, "prompts": {}}


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
    failures = []
    if mark_dir and shared_dir(mark_dir):
        failures.append(f"STALL_MARK_DIR {mark_dir} is a shared directory: no marks written or removed")
        mark_dir = None
    state = load_state(state_path)
    panes, rescanned, unread = {}, 0, set()
    live = live_sessions()
    if live is None:
        print("stall-watch: ERROR process table unavailable; nothing read, nothing changed")
        return 1
    for d, pane, ps in live:
        sid, prev = d["sessionId"], state["panes"].get(pane)
        if ps is None:  # failed read: what was known stays known (screen, events, mark), nothing is reported or cleared
            unread.add(pane)
            if prev and prev.get("sid") == sid:
                panes[pane] = prev
            continue
        h = screen_hash(ps)
        if prev and prev.get("hash") == h and prev.get("sid") == sid and "prompt" in prev:
            panes[pane] = prev  # unchanged screen: nothing to re-read (a state from before prompt detection is re-read)
            continue
        rescanned += 1
        panes[pane] = {"hash": h, "sid": sid, **scan(ps)}
    fleet = sum("interrupted-idle" in p["fps"] for p in panes.values())
    fleet_min = max(1, int(cfg["STALL_FLEET_MIN"] or 2))
    max_age = float(cfg["STALL_MARK_MAX_HOURS"] or 48) * 3600
    events, would, stalled, kept, prompts = {}, 0, {}, set(), []
    for d, pane, ps in live:
        sid = d["sessionId"]
        if pane in unread:
            kept.add(sid)  # its mark stays exactly as it is
            events.update({k: v for k, v in state["events"].items() if k.startswith(f"{pane}|") and k.endswith(f"|{sid}")})
            continue
        p = panes[pane]
        name = one_line(ps["session"]) or one_line(d.get("name")) or sid[:8]
        if p.get("prompt"):
            prompts.append((d, pane, name, p["prompt"]))
        confirmed = [f for f in p["fps"] if f != "interrupted-idle" or p["login"] or fleet >= fleet_min]
        if not confirmed:
            continue
        fresh, firsts = [], []
        for fp in confirmed:
            key = f"{pane}|{fp}|{sid}"
            ev = state["events"].get(key) or {"first": now, "reported": False}
            events[key] = ev
            firsts.append(ev["first"])
            if not ev["reported"] and (apply or not ev.get("shadow_logged")):  # shadow logs an event once too
                fresh.append(fp)
        # A mark is a hold on the reaper, so it exists only when the report is live and only for a bounded time from
        # the first sighting; refreshing an idle, unchanged screen cannot extend it.
        if apply and now - min(firsts) <= max_age:
            stalled[sid] = {"sid": sid, "tmux": name, "fingerprints": confirmed, "pane": pane, "since": min(firsts)}
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
    prompt_events, seen, flagged, pwould = prompt_sweep(cfg, apply, state, prompts, kept, inbox, now, failures)
    if mark_dir:
        mark_dir.mkdir(parents=True, exist_ok=True)
        for sid, m in stalled.items():
            atomic_write(mark_dir / f"{sid}.json", json.dumps({**m, "updated": now}) + "\n")
        for f in mark_dir.glob("*.json"):
            if f.stem not in stalled and f.stem not in kept and is_mark(f):
                f.unlink(missing_ok=True)  # the stall cleared, or the session is gone
    atomic_write(state_path, json.dumps({"panes": panes, "events": events, "prompts": prompt_events}) + "\n")
    print(f"stall-watch {'apply' if apply else 'shadow'}: {len(live)} sessions, {rescanned} rescanned, "
          f"{len(unread)} unread, {len(stalled)} marked, {would} would report, {seen} prompts on screen, "
          f"{flagged} prompts flagged, {pwould} would alert, {len(failures)} failures")
    for f in failures:
        print(f"stall-watch: ERROR {f}")
    return 1 if failures else 0


def _minutes(cfg, key):
    try:
        return float(cfg[key] or DEFAULTS[key])
    except ValueError:
        return float(DEFAULTS[key])


def prompt_sweep(cfg, apply, state, prompts, kept, inbox, now, failures):
    """Age each on-screen prompt from its first sighting per (session id, fingerprint) and flag one on screen longer than
    STALL_PROMPT_MINUTES: an inbox block with apply, a `would alert` line in shadow, again at most every
    STALL_PROMPT_REALERT_MINUTES while it stays. A prompt that left the screen is forgotten (a later one is a new
    instance); an unread session keeps what was known. Returns (events, on screen, flagged, would alert)."""
    after = _minutes(cfg, "STALL_PROMPT_MINUTES") * 60
    every = max(1.0, _minutes(cfg, "STALL_PROMPT_REALERT_MINUTES")) * 60
    out = {k: v for k, v in state["prompts"].items() if k.split("|", 1)[0] in kept}
    if after <= 0:
        return out, 0, 0, 0
    flagged = would = 0
    for d, pane, name, pr in prompts:
        sid = d["sessionId"]
        key = f"{sid}|{pr['fp']}"
        ev = state["prompts"].get(key) or {"first": now, "kind": pr["kind"], "fp": pr["fp"], "alerts": 0,
                                           "alerted": None, "shadow_at": None}
        ev["pane"] = pane
        out[key] = ev
        age = now - ev["first"]
        if age < after:
            continue
        flagged += 1
        last = ev["alerted"] if apply else ev["shadow_at"]
        if last is not None and now - last < every:
            continue
        line = (f"{name} ({sid[:8]}) pane={pane} kind={ev['kind']} prompt={ev['fp']} on-screen={int(age // 60)}m"
                f"{' re-alert' if last is not None else ''}")
        if apply:
            try:
                append_inbox(inbox, prompt_block(name, sid, pane, ev, now))
            except OSError as e:
                failures.append(f"{name} ({sid}): prompt alert inbox write failed: {e}")
                continue
            ev["alerted"], ev["alerts"] = now, ev["alerts"] + 1
            print(f"stall-watch: prompt alert {line} -> {inbox}")
        else:
            would += 1
            ev["shadow_at"] = now
            print(f"stall-watch shadow: would alert prompt {line} -> {inbox}")
        print(f"stall-watch: push: no founder-device channel in cc-reaper or ~/.claude hooks; logged only ({name})")
    return out, len(prompts), flagged, would


if __name__ == "__main__":
    sys.exit(main())
