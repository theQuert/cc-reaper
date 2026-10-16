#!/usr/bin/env python3
"""Isolated tests for the session reaper: every keep gate, transcript reading, the prompt
check, and a verifier calibrated against a real surviving process, tmux session and lock."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "shell" / "session-reaper.py"
spec = importlib.util.spec_from_file_location("session_reaper", SOURCE)
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)

CFG = dict(reaper.DEFAULTS, PROTECT="keep-* ci", IDLE_MINUTES="60")


def session(**kw):
    s = {"tmux": "work", "name": "work", "status": "idle", "idle_min": 90, "bg_shells": [],
         "loop": False, "crons": 0, "scheduled": False, "asking": False,
         "last_text": "SESSION-DONE: shipped the fix", "claims": [], "owned": []}
    s.update(kw)
    return s


class Decide(unittest.TestCase):
    def keep(self, **kw):
        with mock.patch.object(reaper, "issue_state", side_effect=lambda r, n: self.states[n]), \
             mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: w.get("problems", [])):
            return reaper.decide(session(**kw), CFG)

    def setUp(self):
        self.states = {"1": "CLOSED", "2": "OPEN"}

    def test_done_idle_clean_session_is_reaped(self):
        self.assertEqual(self.keep(), [])

    def test_each_gate_keeps_the_session(self):
        cases = {
            "protected": dict(tmux="keep-me"),
            "status:busy": dict(status="busy"),
            "status:shell": dict(status="shell"),
            "idle:30<60min": dict(idle_min=30),
            "shell-child": dict(bg_shells=[123]),
            "loop-pending": dict(loop=True),
            "scheduled-task": dict(crons=1),
            "waiting": dict(asking=True),
            "claim-unknown": dict(last_text="all good"),
            "issue-open:#2": dict(last_text="", claims=[("o/r", "1"), ("o/r", "2")]),
            "uncommitted:wt": dict(owned=[{"problems": ["uncommitted:wt"]}]),
            "not-foreground": dict(fg=False),
            "vim-mode": dict(vim=True),
        }
        for reason, kw in cases.items():
            with self.subTest(reason):
                self.assertIn(reason, self.keep(**kw))

    def test_scheduled_tasks_file_keeps_the_session(self):
        self.assertIn("scheduled-task", self.keep(scheduled=True))

    def test_session_file_name_is_also_matched_against_protection(self):
        self.assertIn("protected", self.keep(tmux="other", name="ci"))

    def test_closed_claims_count_as_done_without_a_done_line(self):
        self.assertEqual(self.keep(last_text="merged", claims=[("o/r", "1")]), [])

    def test_unknown_issue_state_keeps_the_session(self):
        self.states["1"] = "UNKNOWN"
        self.assertIn("issue-open:#1", self.keep(last_text="", claims=[("o/r", "1")]))

    def test_explicit_topic_end_phrases_count_as_done(self):
        for text in ("這個主題已經結束。", "This issue may be closed."):
            with self.subTest(text):
                self.assertEqual(self.keep(last_text=text), [])

    def test_a_request_for_authorization_is_waiting_even_when_done(self):
        text = "SESSION-DONE: staged\n\n等 production-authorization 才能上線。"
        self.assertIn("waiting", self.keep(last_text=text))

    def test_extra_waiting_patterns_come_from_the_config(self):
        text = "SESSION-DONE: drafted\n\nwaiting for Pat"
        self.assertEqual(self.keep(last_text=text), [])
        with mock.patch.dict(CFG, WAITING_EXTRA="waiting for Pat"):
            self.assertIn("waiting", self.keep(last_text=text))

    def test_the_done_line_itself_does_not_read_as_waiting(self):
        self.assertEqual(self.keep(last_text="SESSION-DONE: PR approved and merged"), [])


class Transcript(unittest.TestCase):
    def write(self, entries):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        p = Path(d) / "t.jsonl"
        p.write_text("\n".join(json.dumps(e) for e in entries) + "\n")
        return p

    @staticmethod
    def assistant(*blocks, at="2026-10-11T00:00:00.000Z", side=False):
        return {"type": "assistant", "isSidechain": side, "timestamp": at,
                "message": {"content": list(blocks)}}

    @staticmethod
    def tool(name, **inp):
        return {"type": "tool_use", "name": name, "input": inp}

    NOW = reaper.calendar.timegm((2026, 10, 11, 0, 10, 0, 0, 0, 0))

    def test_only_a_future_unstopped_wakeup_is_a_pending_loop(self):
        future = self.write([self.assistant(self.tool("ScheduleWakeup", delaySeconds=1800))])
        fired = self.write([self.assistant(self.tool("ScheduleWakeup", delaySeconds=60))])
        stopped = self.write([self.assistant(self.tool("ScheduleWakeup", delaySeconds=1800)),
                              self.assistant(self.tool("ScheduleWakeup", stop=True))])
        self.assertTrue(reaper.transcript_facts(future, self.NOW)["loop"])
        self.assertFalse(reaper.transcript_facts(fired, self.NOW)["loop"])
        self.assertFalse(reaper.transcript_facts(stopped, self.NOW)["loop"])

    def test_crons_count_creates_minus_deletes(self):
        p = self.write([self.assistant(self.tool("CronCreate")), self.assistant(self.tool("CronCreate")),
                        self.assistant(self.tool("CronDelete"))])
        self.assertEqual(reaper.transcript_facts(p, self.NOW)["crons"], 1)

    def test_last_text_and_pending_question_ignore_sidechains(self):
        p = self.write([
            self.assistant({"type": "text", "text": "SESSION-DONE: one"}),
            self.assistant(self.tool("AskUserQuestion")),
            self.assistant({"type": "text", "text": "subagent chatter"}, side=True),
        ])
        f = reaper.transcript_facts(p, self.NOW)
        self.assertEqual(f["last_text"], "SESSION-DONE: one")
        self.assertTrue(f["asking"])

    def test_an_answered_question_is_not_pending(self):
        p = self.write([self.assistant(self.tool("AskUserQuestion")),
                        self.assistant({"type": "text", "text": "thanks"})])
        self.assertFalse(reaper.transcript_facts(p, self.NOW)["asking"])


class Prompt(unittest.TestCase):
    SEP = "─" * 20

    def state(self, screen, cx=2, cy=1):
        return {"screen": screen, "cx": cx, "cy": cy}

    def test_empty_prompt_and_placeholder_qualify(self):
        self.assertTrue(reaper.empty_prompt(self.state(f"{self.SEP}\n❯ \n{self.SEP}")))
        self.assertTrue(reaper.empty_prompt(self.state(f"{self.SEP}\n❯ Try \"fix lint\"\n{self.SEP}")))

    def test_typed_text_is_read_through_the_no_break_space(self):
        self.assertEqual(reaper.cursor_line(self.state("x\n❯\xa0/exit  \ny")), "❯ /exit")

    def test_a_draft_a_dialog_or_the_exit_menu_disqualify(self):
        self.assertFalse(reaper.empty_prompt(self.state(f"{self.SEP}\n❯ hello\n{self.SEP}", cx=7)))
        dialog = f"  ❯ 1. Yes\n  Enter to confirm · Esc to cancel\n{self.SEP}\n❯ \n{self.SEP}"
        self.assertFalse(reaper.empty_prompt(self.state(dialog, cy=3)))
        menu = f"   ❯ 1. Exit and stop tasks\n     3. Stay\n{self.SEP}\n❯ \n"
        self.assertFalse(reaper.empty_prompt(self.state(menu, cy=3)))


class ReapRecheck(unittest.TestCase):
    """reap() acts on minutes-old facts, so it re-reads the session file before touching tmux."""

    def test_a_session_used_since_the_sweep_started_is_skipped(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        f = d / "1.json"
        s = {"file": str(f), "status_at": 1000, "pid": 1, "start": "x", "pane": "%0"}
        with mock.patch.object(reaper, "tmux") as tmux:
            f.write_text(json.dumps({"status": "idle", "statusUpdatedAt": 2000}))
            self.assertEqual(reaper.reap(s, CFG, 0), ("skipped:session-changed", []))
            f.write_text(json.dumps({"status": "busy", "statusUpdatedAt": 1000}))
            self.assertEqual(reaper.reap(s, CFG, 0), ("skipped:session-changed", []))
            f.unlink()
            self.assertEqual(reaper.reap(s, CFG, 0), ("skipped:session-file-unreadable", []))
            tmux.assert_not_called()


@unittest.skipUnless(shutil.which("tmux"), "tmux not installed")
class Verify(unittest.TestCase):
    """The verifier must report each failure it exists to catch, then pass once they are gone."""

    def test_reports_survivor_tmux_session_file_and_locks_then_passes(self):
        name = f"session-reaper-test-{os.getpid()}"
        subprocess.run(["tmux", "new-session", "-d", "-s", name, "sleep 300"], check=True)
        self.addCleanup(subprocess.run, ["tmux", "kill-session", "-t", f"={name}"], capture_output=True)
        child = subprocess.Popen(["sleep", "300"], start_new_session=True)
        self.addCleanup(child.kill)
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        (d / "session.json").write_text("{}")
        (d / "locked").write_text("")
        (d / "index.lock").write_text("")
        time.sleep(0.2)
        start = reaper.ps_table()[child.pid][1]
        pane, sid = subprocess.run(["tmux", "display", "-p", "-t", f"={name}:", "#{pane_id} #{session_id}"],
                                   capture_output=True, text=True, check=True).stdout.split()
        s = {"pid": 999999, "start": "", "tmux": name, "pane": pane, "session_id": sid,
             "killed_session": True, "file": str(d / "session.json"), "owned": [{"path": d, "gitdir": d}]}
        fails = reaper.verify(s, [(child.pid, start)])
        for needle in (f"orphan processes: {child.pid}", f"tmux pane {pane}", f"tmux session {name}",
                       "session file",
                       "is locked", "index.lock"):
            self.assertTrue(any(needle in f for f in fails), (needle, fails))

        child.kill()
        child.wait()
        subprocess.run(["tmux", "kill-session", "-t", f"={name}"], check=True)
        for f in ("session.json", "locked", "index.lock"):
            (d / f).unlink()
        self.assertEqual(reaper.verify(s, [(child.pid, start)]), [])

    def test_a_recycled_pid_is_not_a_survivor(self):
        table = {42: (1, "Sun Oct 11 00:00:00 2026", "other")}
        self.assertEqual(reaper.survivors(table, [(42, "Sat Oct 10 00:00:00 2026")]), [])


class NewKeepGates(unittest.TestCase):
    """Subagents, undelivered handoffs and the pre-exit record: gates that only ever keep a session."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.cfg = dict(CFG, RELAY_DIR=str(self.tmp / "relay"), HANDOFF_ROOT=str(self.tmp / "handoffs"),
                        REAPED_DIR=str(self.tmp / "reaped"))

    def keep(self, **kw):
        with mock.patch.object(reaper, "worktree_state", return_value=[]):
            return reaper.decide(session(**kw), self.cfg)

    def test_a_recent_subagent_or_workflow_transcript_counts_as_activity(self):
        now = time.time()
        with mock.patch.object(reaper, "PROJECTS_DIR", self.tmp):
            for sub, age in (("subagents", 60), ("workflows/run1", 60), ("subagents", 7200)):
                d = self.tmp / "proj" / "sid1" / sub
                d.mkdir(parents=True, exist_ok=True)
                f = d / f"agent-{age}-{sub.replace('/', '-')}.jsonl"
                f.write_text("{}")
                os.utime(f, (now - age, now - age))
            self.assertEqual(reaper.subagent_activity("sid1", now, 30), 2)
            self.assertEqual(reaper.subagent_activity("other", now, 30), 0)
        self.assertIn("subagent-active", self.keep(sub_active=1))
        self.assertEqual(self.keep(sub_active=0), [])

    def test_a_pending_relay_request_for_a_claimed_issue_keeps_the_session(self):
        relay = self.tmp / "relay"
        (relay / "done").mkdir(parents=True)
        now = time.time()
        (relay / "41-sign.json").write_text("{}")
        (relay / "42-sign.json.done").write_text("{}")
        (relay / "done" / "43-sign.json").write_text("{}")
        old = relay / "44-sign.json"
        old.write_text("{}")
        os.utime(old, (now - 3 * 86400, now - 3 * 86400))
        claims = [("o/r", n) for n in ("41", "42", "43", "44", "45")]
        self.assertEqual(reaper.relay_pending(self.cfg, claims, now), ["41"])
        self.assertEqual(reaper.relay_pending(dict(self.cfg, RELAY_DIR=""), claims, now), [])
        self.assertIn("handoff-pending:relay#41", self.keep(relay_pending=["41"]))

    def test_a_question_to_a_person_on_screen_keeps_the_session(self):
        self.assertIn("handoff-pending:prompt", self.keep(screen_tail="Do you want to proceed?\n❯ 1. Yes"))
        self.assertEqual(self.keep(screen_tail="❯ \xa0"), [])

    def test_a_named_handoff_that_does_not_exist_keeps_the_session(self):
        root = self.tmp / "handoffs"
        root.mkdir()
        (root / "ready.md").write_text("x")
        text = f"SESSION-DONE: wrote {root}/ready.md, and the follow-up goes in {root}/later.md."
        self.assertEqual(reaper.missing_handoffs(self.cfg, text), [f"{root}/later.md"])
        self.assertIn("handoff-missing:later.md", self.keep(last_text=text))
        self.assertEqual(reaper.missing_handoffs(dict(self.cfg, HANDOFF_ROOT=""), text), [])

    def test_report_marks_background_only_and_new_gate_only_rows(self):
        s = session(pid=1, descendants=0, sid="abcdef0123")
        row = lambda keep: reaper.report_line(s, keep, "keep").split(" | ")  # noqa: E731
        self.assertEqual(row(["status:shell", "shell-child"])[6:8], ["yes", "-"])
        self.assertEqual(row(["subagent-active", "handoff-missing:x.md"])[6:8], ["-", "yes"])
        self.assertEqual(row(["subagent-active", "issue-open:#2"])[6:8], ["-", "-"])
        self.assertEqual(row([])[6:8], ["-", "-"])

    def test_the_record_is_written_before_exit_and_marked_after(self):
        s = session(sid="sid-1", cwd="/w", claims=[("o/r", "7")],
                    owned=[{"path": Path("/w/t"), "branch": "b"}], last_text="SESSION-DONE: ok")
        path = reaper.write_record(s, self.cfg, time.time(), "exiting")
        rec = json.loads(path.read_text())
        self.assertEqual((rec["status"], rec["sid"], rec["claims"]), ("exiting", "sid-1", ["o/r#7"]))
        self.assertEqual(rec["resume"], "tmux new-session -d -s work -c /w 'claude --resume sid-1'")
        reaper.mark_record(path, "skipped:background-tasks")
        self.assertEqual(json.loads(path.read_text())["status"], "aborted:skipped:background-tasks")
        reaper.mark_record(path, "reaped")
        self.assertEqual(json.loads(path.read_text())["status"], "reaped")


class IdleList(unittest.TestCase):
    """The idle list is a report: who is listed, once-a-day inbox posting, off by default."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        p = mock.patch.object(reaper, "HOME", self.tmp)
        p.start()
        self.addCleanup(p.stop)
        self.cfg = dict(CFG, IDLE_LIST_HOURS="6", IDLE_LIST_FILE=str(self.tmp / "list.md"),
                        IDLE_LIST_INBOX=str(self.tmp / "inbox.md"), IDLE_LIST_EXCLUDE="skip-*")
        self.now = time.mktime((2026, 10, 16, 12, 0, 0, 0, 0, -1))

    def listed(self, cfg=None, now=None, **kw):
        s = session(sid="abcdef0123", **kw)
        reaper.idle_list(cfg or self.cfg, [(s, [], kw.get("outcome", "keep"))], now or self.now)
        return "abcdef01" in (self.tmp / "list.md").read_text()

    def test_idle_seven_hours_without_claims_is_listed_even_when_protected(self):
        self.assertTrue(self.listed(idle_min=420))
        self.assertTrue(self.listed(idle_min=420, tmux="keep-me"))

    def test_a_claimed_issue_keeps_it_off_the_list(self):
        self.assertFalse(self.listed(idle_min=420, claims=[("o/r", "1")]))

    def test_below_the_threshold_is_not_listed(self):
        self.assertFalse(self.listed(idle_min=300))

    def test_excluded_busy_and_reaped_sessions_are_not_listed(self):
        self.assertFalse(self.listed(idle_min=420, tmux="skip-me"))
        self.assertFalse(self.listed(idle_min=420, status="busy"))
        self.assertFalse(self.listed(idle_min=420, outcome="reaped, verified"))

    def test_inbox_section_is_appended_once_per_day(self):
        inbox = self.tmp / "inbox.md"
        self.listed(idle_min=420)
        self.listed(idle_min=420)
        self.assertEqual(inbox.read_text().count("## key=IDLE-SESSIONS-2026-10-16"), 1)
        self.assertIn("abcdef01", inbox.read_text())
        self.listed(idle_min=420, now=self.now + 86400)
        self.assertEqual(inbox.read_text().count("## key=IDLE-SESSIONS-"), 2)
        self.assertIn("## key=IDLE-SESSIONS-2026-10-17", inbox.read_text())

    def test_an_empty_list_posts_none(self):
        self.listed(idle_min=10)
        self.assertIn("\nnone\n", (self.tmp / "inbox.md").read_text())

    def test_off_by_default_writes_nothing(self):
        self.assertEqual(reaper.DEFAULTS["IDLE_LIST_HOURS"], "0")
        reaper.idle_list(dict(self.cfg, IDLE_LIST_HOURS="0"), [(session(sid="abcdef0123", idle_min=900), [], "keep")],
                         self.now)
        self.assertEqual(list(self.tmp.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
