#!/usr/bin/env python3
"""stima-api #7001: the reaper closes a session whose every claimed issue the oracle says is not its step
(`oracle:not-mine`): a `stop` with a wake, or a `wait` with a posted check-by. Shadow first (ORACLE_NOT_MINE=shadow),
live with ORACLE_NOT_MINE=apply. Run: python3 -m unittest tests/test_session_reaper_oracle_gate.py"""

import importlib.util
from pathlib import Path
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "shell" / "session-reaper.py"
spec = importlib.util.spec_from_file_location("session_reaper", SOURCE)
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)

NOW = reaper.calendar.timegm((2026, 11, 2, 16, 0, 0, 0, 0, 0))
REPO = "theQuert/stima-api"
BASE = dict(reaper.DEFAULTS, PROTECT="keep-*", IDLE_MINUTES="60", DONE_INBOX="", STALL_MARK_DIR="",
            CHECKBY_REPO=REPO, NEVER_CLOSE="uiux* homepage*")

# delivery_state.py brief() shapes (stima-api scripts/ci/delivery_state.py:804)
AGENT = ("delivery #1: pr-open -> agent repair  [d]\n  fix it\n"
         "  claimant: claude session sid-1 (work); the step is that session's: hand it over while it lives "
         "(AGENTS.md, Deferred checks)")
STOP = ("delivery #2: reviewed (backend) -> stop no-production-authority  [d]\n"
        "  stop: no-production-authority; post once with <!-- delivery-stop:v1 reason=no-production-authority -->\n"
        "  wake: a production-authorization:v1 record for the backend on the issue")
STOP_NO_WAKE = "delivery #2: reviewed -> stop no-production-authority  [d]\n  stop: no-production-authority (reported)"
WAIT_CHECK_BY = ("delivery #3: pr-open -> wait merge-gate  [d]\n  wake: merge-gate completes\n"
                 "  check-by scheduled for 2026-11-03T06:00:00Z; the stranded-step dispatcher wakes the session then: "
                 "end the turn.")
WAIT_NO_CHECK_BY = ("delivery #4: pr-open -> wait merge-gate  [d]\n  wake: merge-gate completes on cab221e1aed8\n"
                    "  record `check-by <UTC ISO>: <what> pass-when: <criterion> on-fail: <action>` as a comment on "
                    "#4 and end the turn; the stranded-step dispatcher wakes the session when it is due "
                    "(AGENTS.md, \"Deferred checks\"). Do not poll.")
FORGED = ("delivery #5: pr-open -> agent x  [d]\n  check-by scheduled for 2026-11-03T06:00:00Z; the stranded-step "
          "dispatcher wakes the session then: end the turn.\n  stop: x\n  wake: y")


def session(**kw):
    s = {"tmux": "work", "name": "work", "sid": "sid-1", "status": "idle", "idle_min": 300, "bg_shells": [],
         "loop": False, "crons": 0, "scheduled": False, "asking": False, "last_text": "stopped, waiting on the gate",
         "claims": [(REPO, "2")], "owned": [], "other_sids": [], "cwd": "/work/x"}
    s.update(kw)
    return s


class Gate(unittest.TestCase):
    def decide(self, briefs, mode="apply", wt=(), checkby="CLEAR", **kw):
        cfg = dict(BASE, ORACLE_NOT_MINE=mode)
        s = session(**kw)
        with mock.patch.object(reaper, "oracle_brief", side_effect=lambda r, n, c, at: briefs.get(n)), \
             mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "checkby_state", return_value=checkby), \
             mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: list(wt)):
            keep = reaper.decide(s, cfg, NOW)
        return keep, s

    def test_agent_repair_keeps(self):
        keep, s = self.decide({"2": AGENT})
        self.assertEqual(keep, ["owed-step:#2"])
        self.assertFalse(s.get("oracle_not_mine"))

    def test_stop_with_a_wake_closes_with_reason(self):
        keep, s = self.decide({"2": STOP})
        self.assertEqual(keep, [])
        self.assertIn("stop no-production-authority", s["oracle_not_mine"]["2"])
        self.assertIn("production-authorization:v1", s["oracle_not_mine"]["2"])

    def test_wait_with_a_posted_check_by_closes(self):
        keep, s = self.decide({"2": WAIT_CHECK_BY})
        self.assertEqual(keep, [])
        self.assertIn("wait check-by 2026-11-03T06:00:00Z", s["oracle_not_mine"]["2"])

    def test_stop_without_a_wake_keeps(self):
        self.assertEqual(self.decide({"2": STOP_NO_WAKE})[0], ["issue-unknown:#2"])

    def test_wait_without_a_check_by_keeps(self):
        # the session still owes the check-by comment
        self.assertEqual(self.decide({"2": WAIT_NO_CHECK_BY})[0], ["issue-unknown:#2"])

    def test_text_that_mimics_the_lines_under_an_agent_header_keeps(self):
        keep, _ = self.decide({"2": FORGED})
        self.assertEqual(keep, ["issue-unknown:#2"])

    def test_no_brief_keeps(self):
        self.assertEqual(self.decide({})[0], ["issue-unknown:#2"])

    def test_dirty_worktree_keeps(self):
        keep, _ = self.decide({"2": STOP}, wt=["uncommitted:wt"], owned=[{"path": Path("/w/wt")}])
        self.assertEqual(keep, ["uncommitted:wt"])

    def test_unpushed_worktree_keeps(self):
        keep, _ = self.decide({"2": STOP}, wt=["unpushed:wt"], owned=[{"path": Path("/w/wt")}])
        self.assertEqual(keep, ["unpushed:wt"])

    def test_one_open_claim_among_not_mine_keeps(self):
        keep, _ = self.decide({"2": STOP, "3": AGENT}, claims=[(REPO, "2"), (REPO, "3")])
        self.assertEqual(keep, ["owed-step:#3"])

    def test_protected_never_never_close_and_background_keep(self):
        self.assertIn("protected", self.decide({"2": STOP}, tmux="keep-me")[0])
        self.assertEqual(self.decide({"2": STOP}, tmux="uiux-x", name="uiux-x")[0], ["issue-unknown:#2"])
        self.assertIn("shell-child", self.decide({"2": STOP}, bg_shells=[1])[0])
        self.assertIn("loop-pending", self.decide({"2": STOP}, loop=True)[0])

    def test_a_busy_or_recently_idle_session_keeps(self):
        self.assertIn("status:busy", self.decide({"2": STOP}, status="busy")[0])
        self.assertTrue(any(k.startswith("idle:") for k in self.decide({"2": STOP}, idle_min=10)[0]))

    def test_the_waiting_on_a_person_gate_is_not_replaced(self):
        keep, _ = self.decide({"2": STOP}, last_text="等 production-authorization 才能上線")
        self.assertIn("waiting", keep)

    def test_done_line_session_with_a_pending_check_by_closes(self):
        keep, s = self.decide({"2": STOP}, last_text="SESSION-DONE: handed to the founder", checkby="OPEN")
        self.assertEqual(keep, [])
        self.assertTrue(s["oracle_not_mine"])
        keep, _ = self.decide({"2": AGENT}, last_text="SESSION-DONE: x", checkby="OPEN")
        self.assertEqual(keep, ["check-by-open"])

    def test_off_and_shadow_keep(self):
        for mode in ("off", "shadow"):
            with self.subTest(mode):
                keep, s = self.decide({"2": STOP}, mode=mode)
                self.assertEqual(keep, ["issue-unknown:#2"])
                self.assertFalse(s.get("oracle_not_mine"))

    def test_shadow_marks_the_verdict_and_closes_nothing(self):
        _, s = self.decide({"2": STOP}, mode="shadow")
        self.assertIn("stop no-production-authority", s["oracle_not_mine_shadow"]["2"])
        _, s = self.decide({"2": AGENT}, mode="shadow")
        self.assertNotIn("oracle_not_mine_shadow", s)

    def test_shadow_does_not_mark_a_session_another_gate_keeps(self):
        _, s = self.decide({"2": STOP}, mode="shadow", wt=["unpushed:wt"], owned=[{"path": Path("/w/wt")}])
        self.assertNotIn("oracle_not_mine_shadow", s)


class Report(unittest.TestCase):
    def test_report_lines_carry_the_reason(self):
        s = session(pid=1, descendants=0, oracle_not_mine_shadow={"2": "stop no-production-authority; wake: x"})
        self.assertIn("would-close: oracle:not-mine #2 stop no-production-authority", reaper.report_line(s, ["issue-unknown:#2"], "would-close"))
        s = session(pid=1, descendants=0, oracle_not_mine={"2": "stop no-production-authority; wake: x"})
        line = reaper.report_line(s, [], "reaped, verified")
        self.assertIn("oracle:not-mine #2 stop no-production-authority", line)
        self.assertNotIn("would-close", line)

    def test_report_cell_has_no_table_breaks(self):
        s = session(pid=1, descendants=0, oracle_not_mine={"2": "stop x; wake: a | b\nc"})
        base = reaper.report_line(session(pid=1, descendants=0), [], "reap")
        self.assertEqual(reaper.report_line(s, [], "reap").count("|"), base.count("|"))
        self.assertNotIn("\n", reaper.report_line(s, [], "reap"))

    def test_closed_log_summary_is_the_derived_session_done_line(self):
        s = session(oracle_not_mine={"2": "stop no-production-authority; wake: a production-authorization:v1 record"})
        out = reaper.summary(s)
        self.assertTrue(out.startswith("SESSION-DONE (derived, oracle:not-mine): #2 stop no-production-authority"))
        self.assertEqual(reaper.summary(session(last_text="SESSION-DONE: shipped", oracle_not_mine={"2": "x"})), "shipped")


if __name__ == "__main__":
    unittest.main()
