#!/usr/bin/env python3
"""Isolated tests for stall-watch: each fingerprint on a fixture pane text, a healthy pane stays silent, one report
per event across runs, the hash skip, shadow vs apply, the marks the session reaper shows, the interactive prompt
aging and alerts (EL-T921), and the #5212 wall: the only tmux calls are display and capture-pane, never send-keys. Every path is a temp path; nothing real is touched."""

import importlib.util
import json
import time
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "shell" / "stall-watch.py"
spec = importlib.util.spec_from_file_location("stall_watch", SOURCE)
stall = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stall)
reaper = stall.reaper

NB = "\xa0"
RULE = "─" * 40


def screen(*above, typed=""):
    """A Claude Code pane: the conversation, the prompt box, the footer. Returns (text, cx, cy)."""
    lines = [*above, "", RULE]
    cy = len(lines)
    lines += [f"❯{NB}{typed}", RULE, "  ? for shortcuts"]
    return "\n".join(lines) + "\n", 2 + len(typed), cy


HEALTHY = screen("● Fixed the retry loop and pushed.", "  ⎿  Done (3 tool uses · 12.1k tokens)", "● Merged.")
WEEKLY = screen("● Agent(review the diff)", "  ⎿  You've hit your weekly limit · resets Nov 2, 9am")
WEEKLY_CURLY = screen("  ⎿  You’ve hit your Opus limit · resets 3pm")
DISCONNECTED = screen("Login successful. Remote Control disconnected.", "")
RECONNECTED = screen("Login successful. Remote Control disconnected.", "Remote Control active", "")
HTTP_429 = screen("● Agent(audit)", '  ⎿  API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}')
RATE_LIMIT_WRAPPED = screen("  ⎿  Error: request failed", "     with status 429 Too Many Requests")
INTERRUPTED = screen("● Working on the migration", "  ⎿  [Request interrupted by user]", "")
INTERRUPTED_LOGIN = screen("Login successful. Remote Control disconnected.", "[Request interrupted by user]", "")
# The wording the Mac mini's panes showed after the 2026-10-29 account switch (read from live panes).
REAL_DISCONNECTED = screen("⏺ Remote Control disconnected — signed-in claude.ai account or",
                           "  organization changed on this machine — run /remote-control to start a",
                           "  session for the current account, or /login to switch back, then /remote-control")
REAL_RECOVERED = screen(*REAL_DISCONNECTED[0].split("\n")[:3], "❯ /remote-control",
                        "  /remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_x")
REAL_INTERRUPTED = screen("● Ran 1 shell command", "  ⎿  Interrupted · What should Claude do instead?", "")
# Not stalls: text that mentions the words in ordinary work.
CODE_429 = screen("  const retryAfter = 429", "  limiter := rate_limit.New(10)", "● Added a rate_limit test")
PROSE_LIMIT = screen("● Users can see how close they are to their weekly usage cap.")
INTERRUPT_THEN_WORK = screen("[Request interrupted by user]", "● Resuming: reading the file", "")
# The five texts Opus measured as false positives of the first version (ordinary transcript content).
QUOTED_RC = screen('● The log said "Remote Control disconnected" after the switch, which matches the bug report.')
SENTENCE_LIMIT = screen("● Users who hit your weekly limit see a banner; the copy should say so.")
READ_429 = screen("● Read(docs/log.txt)", "  ⎿  Read 429 lines")
HASH_429 = screen("● Bash(gh pr view)", "  ⎿  #429 merged")
RATE_FILE = screen("● Search(rate)", "  ⎿  …/rate_limit.go")
TEST_STATUS = screen("● Bash(go test ./...)", "  ⎿  expected status 429, got 200")
GREP_STATUS = screen("● Search(upstream)", "  ⎿  // upstream returned status 429")
GREP_RC = screen("● Search(disconnected)", "  ⎿  Remote Control disconnected.")
FALSE_POSITIVES = {"go test status 429": TEST_STATUS, "grep status 429": GREP_STATUS, "grep result Remote Control disconnected": GREP_RC, "quoted Remote Control disconnected": QUOTED_RC, "weekly limit inside a sentence": SENTENCE_LIMIT,
                   "Read 429 lines": READ_429, "#429 merged": HASH_429, "…/rate_limit.go": RATE_FILE}
STATUS_429 = screen("● Agent(audit)", "  ⎿  Agent failed: request failed with status code 429")
INTERRUPT_DRAFT = screen("[Request interrupted by user]", "", typed="continue with")


# Interactive prompts (EL-T921-CI-CONFIRM-CLEAR), in the shape the `ci` and `security` panes showed on 2026-10-29.
def bottom(*lines):
    """A pane whose bottom is a live menu (no input box): (text, cx, cy) with the cursor on the last line."""
    text = "\n".join(lines) + "\n"
    return text, 1, len(lines) - 1


DASH = "╌" * 40
PERMISSION = bottom("● Ran the backup test", "✻ Waiting for 2 background agents to finish", "", RULE,
                    " Bash command · from the worker-high agent", " Run shell command", DASH,
                    " │ cd /tmp/bk && rm -rf bs r.git && git init -q --bare r.git", DASH,
                    " This shell -c script runs rm and could not be checked", "", " Do you want to proceed?",
                    " ❯ 1. Yes", "   2. No", "", " Esc to cancel · Tab to amend · ctrl+x ctrl+k twice to stop background agents")
PERMISSION_OTHER = bottom(*PERMISSION[0].split("\n")[:7], " │ make clean", *PERMISSION[0].split("\n")[8:-1])
PERMISSION_MOVED = bottom(*[l.replace(" ❯ 1. Yes", "   1. Yes").replace("   2. No", " ❯ 2. No") for l in PERMISSION[0].split("\n")[:-1]])
EDIT_PERMISSION = bottom(RULE, " Edit file", " web/next/app/page.tsx", " Do you want to make this edit to page.tsx?",
                         " ❯ 1. Yes", "   2. Yes, allow all edits during this session (shift+tab)",
                         "   3. No, and tell Claude what to do differently (esc)", "", " Esc to cancel")
ASK_USER = bottom("⏺ The build is green; one decision is left.", "", RULE, " ☐ #6169 boundary", "",
                  "│ Approve the boundary and merge once merge-gate is green?", "",
                  "❯ 1. Approve and ship (Recommended)     ┌──────────────────────┐",
                  "  2. Approve, do not ship yet         │ write_set: lockfile  │",
                  "  3. Do not do it                     └──────────────────────┘", "",
                  "                                  Notes: press n to add notes", "", RULE, "  Chat about this", "",
                  "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel", RULE + " security ─")
ASK_MOVED = bottom(*[l.replace("❯ 1. Approve", "  1. Approve").replace("  2. Approve,", "❯ 2. Approve,")
                     .replace("write_set: lockfile ", "rollback: revert PR ") for l in ASK_USER[0].split("\n")[:-1]])
BUSY = screen("● Bash(go test ./...)", "  ⎿  Running…", "", "✻ Compiling… (2m 3s · esc to interrupt)")
# The words of a prompt in ordinary transcript text, with the idle input box below: not a live prompt.
QUOTED_PROMPT = screen("● The hook printed:", "  Do you want to proceed?", "  ❯ 1. Yes", "    2. No",
                       "● I answered nothing; the session that owns it must decide.", "● Done.")
QUOTED_ASK = screen("● Its footer reads", "  1. first", "  Enter to select · ↑/↓ to navigate · Esc to cancel",
                    "● and that is the menu shape.", "● Done.")


def pane(spec_):
    text, cx, cy = spec_
    return {"screen": text, "cx": cx, "cy": cy}


class Fingerprints(unittest.TestCase):
    def fps(self, spec_):
        return stall.scan(pane(spec_))["fps"]

    def test_each_fingerprint_is_detected(self):
        cases = {
            "weekly-limit": [WEEKLY, WEEKLY_CURLY],
            "remote-disconnected": [DISCONNECTED, INTERRUPTED_LOGIN, REAL_DISCONNECTED],
            "rate-limit-429": [HTTP_429, RATE_LIMIT_WRAPPED],
            "interrupted-idle": [INTERRUPTED, INTERRUPTED_LOGIN, REAL_INTERRUPTED],
        }
        for fp, specs in cases.items():
            for i, spec_ in enumerate(specs):
                with self.subTest(fp=fp, i=i):
                    self.assertIn(fp, self.fps(spec_))

    def test_ordinary_transcript_text_is_not_a_fingerprint(self):
        for name, spec_ in FALSE_POSITIVES.items():
            with self.subTest(name):
                self.assertEqual(self.fps(spec_), [])
        self.assertIn("rate-limit-429", self.fps(STATUS_429))

    def test_a_healthy_pane_has_no_fingerprint(self):
        self.assertEqual(self.fps(HEALTHY), [])

    def test_the_words_in_ordinary_work_are_not_fingerprints(self):
        for name, spec_ in {"code": CODE_429, "prose": PROSE_LIMIT, "interrupt then work": INTERRUPT_THEN_WORK,
                            "interrupt with a draft": INTERRUPT_DRAFT, "reconnected": RECONNECTED, "really reconnected": REAL_RECOVERED}.items():
            with self.subTest(name):
                self.assertEqual(self.fps(spec_), [])

    def test_login_text_is_reported_for_the_interrupt_corroboration(self):
        self.assertTrue(stall.scan(pane(INTERRUPTED_LOGIN))["login"])
        self.assertFalse(stall.scan(pane(INTERRUPTED))["login"])

    def test_the_hash_moves_with_the_screen_and_the_cursor(self):
        a, b = pane(HEALTHY), pane(WEEKLY)
        self.assertEqual(stall.screen_hash(a), stall.screen_hash(dict(a)))
        self.assertNotEqual(stall.screen_hash(a), stall.screen_hash(b))
        self.assertNotEqual(stall.screen_hash(a), stall.screen_hash(dict(a, cx=a["cx"] + 1)))


class Prompts(unittest.TestCase):
    def prompt(self, spec_):
        return stall.scan(pane(spec_))["prompt"]

    def test_a_permission_prompt_is_detected(self):
        for name, spec_ in {"proceed": PERMISSION, "edit": EDIT_PERMISSION}.items():
            with self.subTest(name):
                self.assertEqual(self.prompt(spec_)["kind"], "permission")

    def test_an_ask_user_question_menu_is_detected(self):
        self.assertEqual(self.prompt(ASK_USER)["kind"], "ask-user-question")

    def test_an_idle_or_busy_pane_and_quoted_prompt_text_are_not_prompts(self):
        for name, spec_ in {"idle": HEALTHY, "busy": BUSY, "quoted permission": QUOTED_PROMPT,
                            "quoted menu": QUOTED_ASK, "interrupted": INTERRUPTED, "weekly": WEEKLY}.items():
            with self.subTest(name):
                self.assertIsNone(self.prompt(spec_))

    def test_the_fingerprint_is_one_prompt_instance(self):
        fp = self.prompt(PERMISSION)["fp"]
        self.assertEqual(self.prompt(PERMISSION_MOVED)["fp"], fp)  # the option cursor moved: same prompt
        self.assertNotEqual(self.prompt(PERMISSION_OTHER)["fp"], fp)  # another command: another prompt
        self.assertEqual(self.prompt(ASK_MOVED)["fp"], self.prompt(ASK_USER)["fp"])  # cursor and preview moved
        self.assertNotEqual(self.prompt(ASK_USER)["fp"], fp)
        lines = PERMISSION[0].split("\n")[:-1]
        wrapped = bottom(*lines[:9], " This shell -c script runs rm and", " could not be checked", *lines[10:])
        self.assertEqual(self.prompt(wrapped)["fp"], fp)  # a narrower pane wraps the text: same prompt


class Fleet:
    """A fake tmux and process table: panes {%id: (tmux name, claude pid, screen spec)}; records every tmux argv."""

    def __init__(self, tmp, panes):
        self.tmp, self.panes, self.calls, self.fail, self.empty = tmp, panes, [], set(), set()
        (tmp / "sessions").mkdir(exist_ok=True)
        self.table = {}
        for n, (pid_pane, (name, spec_)) in enumerate(panes.items()):
            sid = f"sid{n}-0000-aaaa"
            pane_pid, claude_pid = 100 + 10 * n, 101 + 10 * n
            self.table[pane_pid] = (1, "P", "-zsh")
            self.table[claude_pid] = (pane_pid, f"S{n}", "claude")
            (tmp / "sessions" / f"{n}.json").write_text(json.dumps({
                "kind": "interactive", "pid": claude_pid, "procStart": f"S{n}", "sessionId": sid,
                "name": name, "tmux": f"{name},1,0.{pid_pane}"}))
        self.sids = {pid_pane: f"sid{n}-0000-aaaa" for n, pid_pane in enumerate(panes)}

    def set(self, pane_id, spec_):
        self.panes[pane_id] = (self.panes[pane_id][0], spec_)

    def run(self, cmd, timeout=30, cwd=None):
        self.calls.append(cmd)
        assert cmd[0] == "tmux", cmd
        sub, target = cmd[1], cmd[cmd.index("-t") + 1]
        name, (text, cx, cy) = self.panes[target]
        n = list(self.panes).index(target)
        if target in self.fail:
            return 1, ""  # a tmux timeout under load
        if sub == "capture-pane" and target in self.empty:
            return 0, ""
        if sub == "display":
            return 0, f"{target}\t{name}\t$1\t{100 + 10 * n}\t{cx}\t{cy}\t1\t1\n"
        if sub == "capture-pane":
            return 0, text
        raise AssertionError(f"unexpected tmux {cmd}")


class Runs(unittest.TestCase):
    table = None

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.inbox = self.tmp / "neo-inbox.md"
        self.marks = self.tmp / "stalled"
        self.write_config()

    def write_config(self, apply="1", fleet_min="2", extra=""):
        self.cfg = self.tmp / "conf"
        self.cfg.write_text(f"STALL_APPLY={apply}\nSTALL_INBOX={self.inbox}\nSTALL_STATE={self.tmp / 'state.json'}\n"
                            f"STALL_MARK_DIR={self.marks}\nSTALL_FLEET_MIN={fleet_min}\n{extra}")

    def start(self, panes):
        self.fleet = Fleet(self.tmp, panes)
        return self.fleet

    def run_once(self, *flags):
        f = self.fleet
        with mock.patch.object(reaper, "SESSIONS_DIR", self.tmp / "sessions"), \
             mock.patch.object(reaper, "ps_table", return_value=f.table if self.table is None else self.table), \
             mock.patch.object(reaper, "run", side_effect=f.run), \
             mock.patch("builtins.print") as out:
            rc = stall.main(["--config", str(self.cfg), *flags])
        self.printed = "\n".join(" ".join(map(str, c.args)) for c in out.call_args_list)
        return rc

    def inbox_text(self):
        return self.inbox.read_text() if self.inbox.exists() else ""

    def test_each_fingerprint_is_reported_with_the_exact_resume_command(self):
        for fp, spec_ in {"weekly-limit": WEEKLY, "remote-disconnected": DISCONNECTED, "rate-limit-429": HTTP_429}.items():
            with self.subTest(fp):
                self.inbox.unlink(missing_ok=True)
                (self.tmp / "state.json").unlink(missing_ok=True)
                f = self.start({"%1": ("auth audit", spec_)})
                self.assertEqual(self.run_once(), 0)
                text = self.inbox_text()
                sid = f.sids["%1"]
                self.assertIn("\n## EL-T801-CI-HARDEN STALL auth audit\n", text)
                self.assertIn(f"fingerprint={fp}", text)
                self.assertIn(f"`claude --resume {sid} --remote-control 'auth audit'`", text)
                self.assertEqual(text.count("## EL-T801-CI-HARDEN STALL"), 1)

    def test_a_healthy_pane_reports_and_marks_nothing(self):
        self.start({"%1": ("work", HEALTHY)})
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.inbox_text(), "")
        self.assertEqual(list(self.marks.glob("*")), [])
        self.assertIn("0 marked", self.printed)

    def test_two_runs_report_an_event_once(self):
        self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        self.run_once()
        self.assertEqual(self.inbox_text().count("## EL-T801-CI-HARDEN STALL work"), 1)

    def test_a_changed_screen_with_the_same_fingerprint_is_the_same_event(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        f.set("%1", screen("● more output", "  ⎿  You've hit your weekly limit · resets Nov 2"))
        self.run_once()
        self.assertEqual(self.inbox_text().count("STALL work"), 1)

    def test_a_cleared_stall_that_comes_back_is_a_new_event(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        f.set("%1", HEALTHY)
        self.run_once()
        self.assertEqual(list(self.marks.glob("*")), [])
        f.set("%1", WEEKLY)
        self.run_once()
        self.assertEqual(self.inbox_text().count("STALL work"), 2)

    def test_a_second_fingerprint_on_the_same_pane_is_a_second_report(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        f.set("%1", screen("Remote Control disconnected.", "You've hit your weekly limit"))
        self.run_once()
        text = self.inbox_text()
        self.assertEqual(text.count("STALL work"), 2)
        self.assertEqual(text.count("fingerprint=weekly-limit"), 1)
        self.assertIn("fingerprint=remote-disconnected", text)

    def test_the_same_fingerprint_on_two_panes_is_two_events(self):
        self.start({"%1": ("one", WEEKLY), "%2": ("two", WEEKLY)})
        self.run_once()
        self.run_once()
        text = self.inbox_text()
        self.assertEqual((text.count("STALL one"), text.count("STALL two")), (1, 1))

    def test_an_unchanged_pane_is_not_rescanned_and_a_changed_one_is(self):
        f = self.start({"%1": ("a", HEALTHY), "%2": ("b", WEEKLY)})
        self.run_once()
        self.assertIn("2 rescanned", self.printed)
        with mock.patch.object(stall, "scan", wraps=stall.scan) as scan:
            self.run_once()
            scan.assert_not_called()
            self.assertIn("0 rescanned", self.printed)
            f.set("%1", WEEKLY)
            self.run_once()
            self.assertEqual(scan.call_count, 1)
        self.assertEqual(self.inbox_text().count("STALL a"), 1)

    def test_shadow_is_the_default_prints_once_and_writes_no_inbox(self):
        self.write_config(apply="0")
        self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        self.assertIn("shadow: would report work", self.printed)
        self.assertIn("--remote-control work", self.printed)
        self.run_once()
        self.assertNotIn("would report work", self.printed)  # logged once for the event
        self.assertFalse(self.inbox.exists())
        self.assertFalse(self.marks.exists() and list(self.marks.glob("*")))  # a mark holds the reaper: never in shadow

    def test_apply_after_shadow_reports_the_stall_that_is_still_there(self):
        self.write_config(apply="0")
        self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        self.write_config(apply="1")
        self.run_once()
        self.assertEqual(self.inbox_text().count("STALL work"), 1)

    def test_the_apply_flag_overrides_a_shadow_config(self):
        self.write_config(apply="0")
        self.start({"%1": ("work", WEEKLY)})
        self.run_once("--apply")
        self.assertEqual(self.inbox_text().count("STALL work"), 1)

    def test_an_inbox_write_failure_is_not_marked_reported(self):
        self.start({"%1": ("work", WEEKLY)})
        with mock.patch.object(stall, "append_inbox", side_effect=OSError("disk")):
            self.assertEqual(self.run_once(), 1)
        self.assertIn("ERROR work", self.printed)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.inbox_text().count("STALL work"), 1)

    def test_a_session_name_cannot_inject_a_header_or_a_command(self):
        self.start({"%1": ("x\n## OTHER; rm -rf /", WEEKLY)})
        self.run_once()
        text = self.inbox_text()
        self.assertEqual(text.count("\n## "), 1)
        self.assertIn("--remote-control 'x ## OTHER; rm -rf /'", text)

    def test_an_interrupt_alone_is_not_an_account_switch(self):
        self.start({"%1": ("work", INTERRUPTED)})
        self.run_once()
        self.assertEqual(self.inbox_text(), "")
        self.assertEqual(list(self.marks.glob("*")), [])

    def test_an_interrupt_counts_with_login_text_or_a_fleet_of_them(self):
        self.start({"%1": ("one", INTERRUPTED), "%2": ("two", INTERRUPTED)})
        self.run_once()
        text = self.inbox_text()
        self.assertIn("STALL one", text)
        self.assertIn("STALL two", text)
        self.assertIn("fingerprint=interrupted-idle", text)
        self.inbox.unlink()
        (self.tmp / "state.json").unlink()
        self.start({"%1": ("solo", INTERRUPTED_LOGIN)})
        self.run_once()
        self.assertIn("fingerprint=remote-disconnected,interrupted-idle", self.inbox_text())

    def test_marks_follow_the_stall_and_the_session_reaper_shows_the_reason(self):
        self.write_config(apply="0")
        f = self.start({"%1": ("work", WEEKLY), "%2": ("fine", HEALTHY)})
        self.run_once()
        self.assertFalse(self.marks.exists() and list(self.marks.glob("*")))  # shadow: no mark
        self.write_config(apply="1")
        self.run_once()
        marks = list(self.marks.glob("*.json"))
        self.assertEqual([m.stem for m in marks], [f.sids["%1"]])
        cfg = dict(reaper.DEFAULTS, STALL_MARK_DIR=str(self.marks))
        self.assertEqual(reaper.stall_mark(cfg, f.sids["%1"]), "weekly-limit")
        self.assertEqual(reaper.stall_mark(cfg, f.sids["%2"]), "")
        self.assertEqual(reaper.stall_mark(dict(cfg, STALL_MARK_DIR=""), f.sids["%1"]), "")
        f.set("%1", HEALTHY)
        self.run_once()
        self.assertEqual(reaper.stall_mark(cfg, f.sids["%1"]), "")

    def test_the_fingerprints_in_the_five_false_positive_texts_report_and_mark_nothing(self):
        for name, spec_ in FALSE_POSITIVES.items():
            with self.subTest(name):
                self.start({"%1": ("work", spec_)})
                self.run_once()
                self.run_once()
                self.assertEqual(self.inbox_text(), "")
                self.assertEqual(list(self.marks.glob("*")), [])

    def test_a_mark_does_not_outlive_its_first_sighting_however_often_it_is_refreshed(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        sid = f.sids["%1"]
        cfg = dict(reaper.DEFAULTS, STALL_MARK_DIR=str(self.marks))
        self.assertEqual(reaper.stall_mark(cfg, sid), "weekly-limit")
        st = json.loads((self.tmp / "state.json").read_text())
        for ev in st["events"].values():
            ev["first"] -= 49 * 3600
        (self.tmp / "state.json").write_text(json.dumps(st))
        self.run_once()  # unchanged idle screen: refreshed, but past the cap from its first sighting
        self.assertFalse((self.marks / f"{sid}.json").exists())
        self.assertEqual(reaper.stall_mark(cfg, sid), "")
        self.assertEqual(self.inbox_text().count("STALL work"), 1)

    def test_a_failed_read_keeps_the_event_and_the_mark_and_reports_nothing_again(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        sid = f.sids["%1"]
        mark = self.marks / f"{sid}.json"
        before = mark.read_text()
        for failing in (f.fail, f.empty):
            failing.add("%1")
            self.assertEqual(self.run_once(), 0)
            self.assertIn("1 unread", self.printed)
            self.assertEqual(mark.read_text(), before)
            failing.discard("%1")
        self.run_once()
        self.assertEqual(self.inbox_text().count("STALL work"), 1)
        self.assertEqual(mark.read_text().count(sid), 1)

    def test_a_missing_process_table_changes_nothing(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        state, marks = (self.tmp / "state.json").read_text(), sorted(p.name for p in self.marks.glob("*"))
        self.table = {}
        self.assertEqual(self.run_once(), 1)
        self.assertEqual((self.tmp / "state.json").read_text(), state)
        self.assertEqual(sorted(p.name for p in self.marks.glob("*")), marks)

    def test_a_session_id_that_is_not_word_characters_is_skipped(self):
        f = self.start({"%1": ("work", WEEKLY)})
        p = next((self.tmp / "sessions").glob("*.json"))
        d = json.loads(p.read_text())
        d["sessionId"] = "abc`reboot`"
        p.write_text(json.dumps(d))
        self.run_once()
        self.assertEqual(self.inbox_text(), "")

    def test_a_backtick_in_the_name_cannot_close_the_code_span(self):
        self.start({"%1": ("my`name", WEEKLY)})
        self.run_once()
        block = self.inbox_text()
        self.assertEqual(block.count("`"), 2)
        import shlex
        command = block.split("`")[1]
        self.assertEqual(shlex.split(command)[-2:], ["--remote-control", "my'name"])

    def test_cleanup_deletes_only_mark_files_and_refuses_a_shared_directory(self):
        f = self.start({"%1": ("work", HEALTHY)})
        self.marks.mkdir()
        other = self.marks / "notes.json"
        other.write_text("{}")
        session_like = self.marks / "abc.json"
        session_like.write_text(json.dumps({"pid": 1, "sessionId": "abc"}))
        gone = self.marks / "gone-sid.json"
        gone.write_text(json.dumps({"sid": "gone-sid", "tmux": "x", "fingerprints": ["weekly-limit"], "pane": "%9",
                                    "since": 1, "updated": 1}))
        self.run_once()
        self.assertTrue(other.exists() and session_like.exists())
        self.assertFalse(gone.exists())
        # the sessions directory itself as the mark directory: refused, nothing in it touched
        sessions = self.tmp / "sessions"
        before = sorted(p.name for p in sessions.glob("*"))
        self.cfg.write_text(self.cfg.read_text().replace(f"STALL_MARK_DIR={self.marks}", f"STALL_MARK_DIR={sessions}"))
        f.set("%1", WEEKLY)
        with mock.patch.object(reaper, "PROJECTS_DIR", self.tmp / "projects"):
            self.assertEqual(self.run_once(), 1)
        self.assertIn("shared directory", self.printed)
        self.assertEqual(sorted(p.name for p in sessions.glob("*")), before)

    def test_a_gone_session_loses_its_mark(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        for p in (self.tmp / "sessions").glob("*.json"):
            p.unlink()
        self.run_once()
        self.assertEqual(list(self.marks.glob("*")), [])

    def test_never_types_into_a_pane(self):
        f = self.start({"%1": ("a", WEEKLY), "%2": ("b", DISCONNECTED), "%3": ("c", INTERRUPTED), "%4": ("d", HEALTHY)})
        self.run_once()
        self.run_once("--apply")
        self.assertTrue(f.calls)
        self.assertEqual({c[1] for c in f.calls}, {"display", "capture-pane"})
        self.assertFalse([c for c in f.calls if "send-keys" in c or "send" in c[1]])

    def test_the_tmux_wall_refuses_everything_that_could_type(self):
        self.assertIs(reaper.tmux, stall.tmux_ro)
        for sub in ("send-keys", "send-prefix", "paste-buffer", "run-shell", "kill-session", "load-buffer"):
            with self.subTest(sub), mock.patch.object(reaper, "run") as run:
                with self.assertRaises(RuntimeError):
                    stall.tmux_ro(sub, "-t", "%1", "/remote-control", "Enter")
                with self.assertRaises(RuntimeError):
                    reaper.tmux(sub, "-t", "%1")
                run.assert_not_called()
        with mock.patch.object(reaper, "run", return_value=(0, "")) as run:
            stall.tmux_ro("capture-pane", "-p", "-t", "%1")
            run.assert_called_once_with(["tmux", "capture-pane", "-p", "-t", "%1"], timeout=10)


class PromptRuns(unittest.TestCase):
    """A prompt on screen is aged from its first sighting and flagged past STALL_PROMPT_MINUTES, once per instance."""
    table = None
    setUp, write_config, start, run_once, inbox_text = Runs.setUp, Runs.write_config, Runs.start, Runs.run_once, Runs.inbox_text

    def age(self, minutes, field="first"):
        """Move every prompt event's `field` back by `minutes`, as if that much time had passed."""
        path = self.tmp / "state.json"
        st = json.loads(path.read_text())
        for ev in st["prompts"].values():
            if ev.get(field) is not None:
                ev[field] -= minutes * 60
        path.write_text(json.dumps(st))

    def prompt_blocks(self, name):
        return self.inbox_text().count(f"## EL-T921-PROMPT-STALL {name}\n")

    def test_a_permission_prompt_is_flagged_with_its_age_after_the_threshold(self):
        f = self.start({"%1": ("ci", PERMISSION), "%2": ("fine", HEALTHY)})
        self.assertEqual(self.run_once(), 0)
        self.assertIn("1 prompts on screen, 0 prompts flagged", self.printed)
        self.assertEqual(self.inbox_text(), "")
        self.age(11)
        self.assertEqual(self.run_once(), 0)
        text = self.inbox_text()
        self.assertEqual(self.prompt_blocks("ci"), 1)
        self.assertIn(f"id={f.sids['%1']} pane=%1 kind=permission", text)
        self.assertIn("on-screen=11m", text)
        self.assertNotIn("r.git", text)  # no screen text reaches the inbox
        self.assertNotIn("fine", text)
        self.assertIn("push: no founder-device channel", self.printed)
        self.assertEqual({c[1] for c in f.calls}, {"display", "capture-pane"})  # never answered, never typed

    def test_an_ask_user_question_menu_is_flagged(self):
        self.start({"%1": ("security", ASK_USER)})
        self.run_once()
        self.age(30)
        self.run_once()
        self.assertEqual(self.prompt_blocks("security"), 1)
        self.assertIn("kind=ask-user-question", self.inbox_text())
        self.assertIn("on-screen=30m", self.inbox_text())

    def test_below_the_threshold_nothing_is_flagged(self):
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(9)
        self.run_once()
        self.assertEqual(self.inbox_text(), "")
        self.assertIn("0 prompts flagged", self.printed)
        self.write_config(extra="STALL_PROMPT_MINUTES=5\n")
        self.run_once()
        self.assertEqual(self.prompt_blocks("ci"), 1)

    def test_an_idle_or_busy_pane_is_never_flagged(self):
        self.start({"%1": ("idle", HEALTHY), "%2": ("busy", BUSY), "%3": ("quoted", QUOTED_PROMPT)})
        self.run_once()
        self.age(600)
        self.run_once()
        self.assertEqual(self.inbox_text(), "")
        self.assertIn("0 prompts on screen", self.printed)

    def test_one_alert_per_prompt_and_a_re_alert_only_after_the_longer_interval(self):
        f = self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        self.run_once()
        f.set("%1", PERMISSION_MOVED)  # the screen changed, the prompt did not
        self.run_once()
        self.age(60, "alerted")
        self.run_once()
        self.assertEqual(self.prompt_blocks("ci"), 1)
        self.age(61, "alerted")  # 121 minutes since the alert
        self.run_once()
        self.assertEqual(self.prompt_blocks("ci"), 2)
        self.assertIn("re-alert=1", self.inbox_text())

    def test_a_prompt_that_leaves_the_screen_and_comes_back_is_a_new_instance(self):
        f = self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        self.run_once()
        f.set("%1", HEALTHY)
        self.run_once()
        self.assertEqual(json.loads((self.tmp / "state.json").read_text())["prompts"], {})
        f.set("%1", PERMISSION)
        self.run_once()  # first sighting again: not aged
        self.assertEqual(self.prompt_blocks("ci"), 1)
        f.set("%1", PERMISSION_OTHER)  # a different prompt on the same session is its own instance
        self.run_once()
        self.assertEqual(len(json.loads((self.tmp / "state.json").read_text())["prompts"]), 1)

    def test_shadow_logs_what_it_would_alert_once_and_sends_nothing(self):
        self.write_config(apply="0")
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        self.run_once()
        self.assertIn("shadow: would alert prompt ci", self.printed)
        self.assertIn("kind=permission", self.printed)
        self.assertIn("1 would alert", self.printed)
        self.run_once()
        self.assertNotIn("would alert prompt", self.printed)
        self.assertFalse(self.inbox.exists())
        self.write_config(apply="1")
        self.run_once()  # apply after shadow still alerts the prompt that is there
        self.assertEqual(self.prompt_blocks("ci"), 1)

    def test_a_state_from_before_prompt_detection_is_rescanned(self):
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        path = self.tmp / "state.json"
        st = json.loads(path.read_text())
        for p in st["panes"].values():
            del p["prompt"]
        st.pop("prompts")
        path.write_text(json.dumps(st))
        self.run_once()
        self.assertIn("1 rescanned", self.printed)
        self.assertIn("1 prompts on screen", self.printed)

    def test_a_failed_read_keeps_the_prompt_first_sighting(self):
        f = self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        first = json.loads((self.tmp / "state.json").read_text())["prompts"]
        self.assertEqual(len(first), 1)
        f.fail.add("%1")
        self.run_once()
        self.assertEqual(json.loads((self.tmp / "state.json").read_text())["prompts"], first)

    def test_zero_minutes_turns_prompt_detection_off(self):
        self.write_config(extra="STALL_PROMPT_MINUTES=0\n")
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.run_once()
        self.assertEqual(self.inbox_text(), "")
        self.assertIn("0 prompts on screen", self.printed)

    def test_a_failed_alert_write_is_retried_next_run(self):
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        with mock.patch.object(stall, "append_inbox", side_effect=OSError("disk")):
            self.assertEqual(self.run_once(), 1)
        self.assertIn("prompt alert inbox write failed", self.printed)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.prompt_blocks("ci"), 1)


class ReaperKeepsStalledSessions(unittest.TestCase):
    def test_a_fresh_mark_keeps_an_otherwise_reapable_session_and_a_stale_one_does_not(self):
        import os
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        cfg = dict(reaper.DEFAULTS, STALL_MARK_DIR=str(tmp), DONE_INBOX="", PROTECT="")
        s = {"tmux": "w", "name": "w", "sid": "abc-123", "status": "idle", "idle_min": 500, "bg_shells": [], "loop": False,
             "crons": 0, "scheduled": False, "asking": False, "last_text": "SESSION-DONE: shipped", "claims": [], "owned": []}
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        mark = tmp / "abc-123.json"
        now = time.time()

        def write(**kw):
            d = {"sid": "abc-123", "fingerprints": ["weekly-limit", "rate-limit-429"], "since": now - 60, "updated": now}
            d.update(kw)
            mark.write_text(json.dumps(d))
            os.utime(mark, None)
        write()
        self.assertEqual(reaper.decide(dict(s), cfg), ["stalled:weekly-limit,rate-limit-429"])
        old = mark.stat().st_mtime - 13 * 3600
        os.utime(mark, (old, old))
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        write(since=now - 49 * 3600)  # refreshed just now, but first seen past the cap
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        write(since=now + 30 * 86400, updated=now + 30 * 86400)  # a timestamp in the future still expires
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        write()
        future = now + 30 * 86400
        os.utime(mark, (future, future))  # a future mtime never makes a mark immortal
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        write(sid="other")  # a file that is not this session's mark
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        mark.write_text(json.dumps({"pid": 1, "sessionId": "abc-123", "status": "idle"}))  # a session file, not a mark
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        mark.write_text("not json")
        os.utime(mark, None)
        self.assertEqual(reaper.decide(dict(s), cfg), [])  # an unreadable mark fails open to the old behavior
        self.assertEqual(reaper.stall_mark(cfg, "../escape"), "")


if __name__ == "__main__":
    unittest.main()
