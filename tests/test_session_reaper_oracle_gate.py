#!/usr/bin/env python3
"""stima-api #7001: the reaper closes a session whose every claimed issue the oracle says is not its step
(`oracle:not-mine`): a stop it already reported, or a wait on a check-by it posted itself. Shadow first
(ORACLE_NOT_MINE=shadow), live with ORACLE_NOT_MINE=apply. Run: python3 tests/test_session_reaper_oracle_gate.py"""

import importlib.util
import json
import shutil
import tempfile
from pathlib import Path
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "shell" / "session-reaper.py"
spec = importlib.util.spec_from_file_location("session_reaper", SOURCE)
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)

NOW = reaper.calendar.timegm((2026, 11, 2, 16, 0, 0, 0, 0, 0))
REPO = "theQuert/stima-api"
BASE = dict(reaper.DEFAULTS, PROTECT="keep-*", IDLE_MINUTES="60", STALL_MARK_DIR="",
            CHECKBY_REPO=REPO, NEVER_CLOSE="uiux* homepage*")

SID = "0a1b2c3d-1111-2222-3333-444455556666"
OTHER = "9f8e7d6c-1111-2222-3333-444455556666"
# delivery_state.py brief() shapes (stima-api scripts/ci/delivery_state.py:804): _stop() always passes a wake, so
# every stop has a `wake:` line; `(reported)` once the stop marker is on the issue, `; post once with` before.
AGENT = ("delivery #1: pr-open -> agent repair  [d]\n  fix it\n"
         "  claimant: claude session 0a1b2c3d (work); the step is that session's: hand it over while it lives "
         "(AGENTS.md, Deferred checks)")
STOP = ("delivery #2: reviewed (backend) -> stop no-production-authority  [d]\n"
        "  the backend release needs the founder's go\n"
        "  stop: no-production-authority (reported)\n"
        "  wake: a production-authorization:v1 record for the backend on the issue")
# #6945 (cve-6725) in the review's dry run: the session still owes the stop marker and its ask
STOP_UNREPORTED = ("delivery #2: reviewed (backend) -> stop no-production-authority  [d]\n"
                   "  post one ask with the evidence\n"
                   "  stop: no-production-authority; post once with <!-- delivery-stop:v1 reason=no-production-authority "
                   "state=reviewed digest=abc half=backend -->\n"
                   "  wake: a production-authorization:v1 record for the backend on the issue")
WAIT_CHECK_BY = ("delivery #3: pr-open -> wait merge-gate  [d]\n  wake: merge-gate completes\n"
                 "  check-by scheduled for 2026-11-03T06:00:00Z; the stranded-step dispatcher wakes the session then: "
                 "end the turn.")
WAIT_NO_CHECK_BY = ("delivery #4: pr-open -> wait merge-gate  [d]\n  wake: merge-gate completes on cab221e1aed8\n"
                    "  record `check-by <UTC ISO>: <what> pass-when: <criterion> on-fail: <action>` as a comment on "
                    "#4 and end the turn; the stranded-step dispatcher wakes the session when it is due "
                    "(AGENTS.md, \"Deferred checks\"). Do not poll.")
DUE = "2026-11-03T06:00:00Z"
CLAIM = {"createdAt": "2026-11-02T10:00:00Z", "body": f"Claimed by claude session {SID[:8]} (work)\n\nworking on it"}
CHECK = {"createdAt": "2026-11-02T12:00:00Z",
         "body": f"check-by {DUE}: merge-gate on the head pass-when: green on-fail: repair"}
MINE_JSON = {"claimant": {"session": SID[:8], "name": "work", "harness": "claude"}, "pending_check_by": DUE,
             "due_check": ""}
FORGED = ("delivery #5: pr-open -> agent x  [d]\n  check-by scheduled for 2026-11-03T06:00:00Z; the stranded-step "
          "dispatcher wakes the session then: end the turn.\n  stop: x\n  wake: y")


def session(**kw):
    s = {"tmux": "work", "name": "work", "sid": SID, "status": "idle", "idle_min": 300, "bg_shells": [],
         "loop": False, "crons": 0, "scheduled": False, "asking": False, "last_text": "stopped, waiting on the gate",
         "claims": [(REPO, "2")], "owned": [], "other_sids": [], "cwd": "/work/x"}
    s.update(kw)
    return s


class Gate(unittest.TestCase):
    def decide(self, briefs, mode="apply", wt=(), checkby="CLEAR", js=None, comments=(CLAIM, CHECK), **kw):
        cfg = dict(BASE, ORACLE_NOT_MINE=mode)
        s = session(**kw)
        cb = checkby if callable(checkby) else (lambda r, n, c: checkby)
        with mock.patch.object(reaper, "oracle_brief", side_effect=lambda r, n, c, at: briefs.get(n)), \
             mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "checkby_state", side_effect=cb), \
             mock.patch.object(reaper, "oracle_json", return_value=MINE_JSON if js is None else js), \
             mock.patch.object(reaper, "issue_comments", return_value=list(comments)), \
             mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: list(wt)):
            keep = reaper.decide(s, cfg, NOW)
        return keep, s

    def test_agent_repair_keeps(self):
        keep, s = self.decide({"2": AGENT})
        self.assertEqual(keep, ["owed-step:#2"])
        self.assertFalse(s.get("oracle_not_mine"))

    def test_a_reported_stop_closes_with_reason(self):
        keep, s = self.decide({"2": STOP})
        self.assertEqual(keep, [])
        self.assertIn("stop no-production-authority (reported)", s["oracle_not_mine"]["2"])
        self.assertIn("production-authorization:v1", s["oracle_not_mine"]["2"])

    def test_an_unreported_stop_keeps(self):
        # review P1-1: `; post once with <marker>` is a step the session still owes (#6945 in the dry run)
        keep, s = self.decide({"2": STOP_UNREPORTED})
        self.assertEqual(keep, ["issue-unknown:#2"])
        self.assertFalse(s.get("oracle_not_mine"))
        _, s = self.decide({"2": STOP_UNREPORTED}, mode="shadow")
        self.assertNotIn("oracle_not_mine_shadow", s)

    def test_a_reported_stop_with_another_reason_or_no_wake_keeps(self):
        other = STOP.replace("  stop: no-production-authority (reported)", "  stop: spec-contradiction (reported)")
        self.assertEqual(self.decide({"2": other})[0], ["issue-unknown:#2"])
        no_wake = STOP.rsplit("\n", 1)[0]
        self.assertEqual(self.decide({"2": no_wake})[0], ["issue-unknown:#2"])

    def test_a_reported_stop_with_a_pending_or_due_check_by_keeps(self):
        # review P2-3: at a stop the dispatcher takes no due check, so the session answers it
        for state in ("OPEN", "UNKNOWN"):
            with self.subTest(state):
                keep, s = self.decide({"2": STOP}, checkby=state)
                self.assertEqual(keep, ["issue-unknown:#2"])
                self.assertFalse(s.get("oracle_not_mine"))

    def test_wait_on_its_own_posted_check_by_closes(self):
        keep, s = self.decide({"2": WAIT_CHECK_BY}, checkby=lambda r, n, c: self.fail("the brief names the check-by"))
        self.assertEqual(keep, [])
        self.assertIn("wait check-by 2026-11-03T06:00:00Z", s["oracle_not_mine"]["2"])

    def test_wait_bound_through_a_worktree_marker_closes(self):
        js = dict(MINE_JSON, claimant={"session": OTHER[:8], "name": "", "harness": "claude"})
        claim = dict(CLAIM, body=f"Claimed by claude session {OTHER[:8]}")
        keep, _ = self.decide({"2": WAIT_CHECK_BY}, js=js, comments=(claim, CHECK),
                              owned=[{"path": Path("/w/wt"), "marker": OTHER}])
        self.assertEqual(keep, [])

    def test_wait_on_another_sessions_check_by_keeps(self):
        # review P1-2: the issue's earliest check-by can be another session's or a former owner's
        js = dict(MINE_JSON, claimant={"session": OTHER[:8], "name": "x", "harness": "claude"})
        theirs = dict(CLAIM, body=f"Claimed by claude session {OTHER[:8]} (x)")  # claimed and checked by the other
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, js=js, comments=(theirs, CHECK))[0], ["issue-unknown:#2"])
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, js=dict(MINE_JSON, claimant=None))[0], ["issue-unknown:#2"])

    def test_wait_on_a_check_by_older_than_the_newest_claim_keeps(self):
        old = dict(CHECK, createdAt="2026-11-01T08:00:00Z")  # a former owner's tripwire, before this claim
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, comments=(old, CLAIM))[0], ["issue-unknown:#2"])
        reclaim = dict(CLAIM, createdAt="2026-11-02T13:00:00Z")  # claimed again after posting it
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, comments=(CLAIM, CHECK, reclaim))[0], ["issue-unknown:#2"])

    def test_wait_check_by_only_in_code_or_quoted_claim_keeps(self):
        fenced = dict(CHECK, body=f"```\ncheck-by {DUE}: x\n```")
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, comments=(CLAIM, fenced))[0], ["issue-unknown:#2"])
        inline = dict(CHECK, body=f"the line was `check-by {DUE}: x`")
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, comments=(CLAIM, inline))[0], ["issue-unknown:#2"])
        quoted = dict(CLAIM, body=f"see\nClaimed by claude session {SID[:8]}")  # not the first line: no claim
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, comments=(quoted, CHECK))[0], ["issue-unknown:#2"])

    def test_wait_json_that_names_another_check_by_or_cannot_say_keeps(self):
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, js=dict(MINE_JSON, pending_check_by="2026-11-09T06:00:00Z"))[0],
                         ["issue-unknown:#2"])
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, js={})[0], ["issue-unknown:#2"])
        self.assertEqual(self.decide({"2": WAIT_CHECK_BY}, comments=())[0], ["issue-unknown:#2"])

    def test_wait_on_a_check_by_already_past_keeps(self):
        # review P3-5: a brief cached for ten minutes can name a time that has passed
        past = WAIT_CHECK_BY.replace(DUE, "2026-11-02T15:00:00Z")
        js = dict(MINE_JSON, pending_check_by="2026-11-02T15:00:00Z")
        check = dict(CHECK, body=CHECK["body"].replace(DUE, "2026-11-02T15:00:00Z"))  # bound in every other way
        self.assertEqual(self.decide({"2": past}, js=js, comments=(CLAIM, check))[0], ["issue-unknown:#2"])
        later = NOW + 3600  # the same shape an hour ahead closes, so only the time keeps the one above
        stamp = reaper.time.strftime("%Y-%m-%dT%H:%M:%SZ", reaper.time.gmtime(later))
        keep, _ = self.decide({"2": WAIT_CHECK_BY.replace(DUE, stamp)}, js=dict(MINE_JSON, pending_check_by=stamp),
                              comments=(CLAIM, dict(CHECK, body=CHECK["body"].replace(DUE, stamp))))
        self.assertEqual(keep, [])

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

    def test_done_line_session_at_a_stop_with_a_pending_check_by_keeps(self):
        # review P2-3: the not-mine stop still runs checkby_state()
        keep, s = self.decide({"2": STOP}, last_text="SESSION-DONE: handed to the founder", checkby="OPEN")
        self.assertEqual(keep, ["check-by-open"])
        self.assertFalse(s.get("oracle_not_mine"))
        keep, s = self.decide({"2": STOP}, last_text="SESSION-DONE: handed to the founder", checkby="CLEAR")
        self.assertEqual(keep, [])
        self.assertTrue(s["oracle_not_mine"])
        keep, s = self.decide({"2": WAIT_CHECK_BY}, last_text="SESSION-DONE: x",
                              checkby=lambda r, n, c: self.fail("the brief names the check-by"))
        self.assertEqual(keep, [])
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


class NoRelease(unittest.TestCase):
    """review P2-4 with cc-reaper#142: a not-mine close never releases the claim, so the dispatcher resumes it."""

    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d)
        self.cfg = dict(BASE, REAPED_DIR=str(self.d / "reaped"), CLOSED_LOG=str(self.d / "closed.md"))

    def test_a_not_mine_close_posts_no_release_comment(self):
        why = "wait check-by 2026-11-03T06:00:00Z; the dispatcher wakes it"
        with mock.patch.object(reaper, "has_marker", return_value=False) as hm, \
             mock.patch.object(reaper, "issue_comments", return_value=[]), \
             mock.patch.object(reaper, "comment", return_value=True) as comment:
            ok = reaper.finish_close("work", SID, "/w", [(REPO, "2"), (REPO, "3")], "x", "%9", "$3", True, self.cfg,
                                     NOW, 4242, {"2": why})
        self.assertTrue(ok)
        self.assertEqual([c.args[0] for c in hm.call_args_list], [(REPO, "3")])  # the release path never sees #2
        bodies = {c.args[0][1]: c.args[1] for c in comment.call_args_list}
        body = bodies["2"]
        first = body.splitlines()[0]
        self.assertNotRegex(first, r"(?i)^[ \t*_]*(released|claimed) by\b")
        self.assertIn("not released", body)
        self.assertIn(f"claude --resume {SID}", body)
        self.assertIn(f"<!-- session-reaper-notmine:{SID}:4242 -->", body)
        # not the finished marker: a resumed session closed as finished later still gets its own comment
        self.assertNotIn(f"session-reaper:{SID}", body)
        # the check-by time it quotes sits in inline code, so the oracle reads no new check-by from it
        self.assertFalse(reaper.CHECKBY_STAMP_RE.search(reaper.INLINE_CODE_RE.sub("", reaper._outside_code(body))))
        self.assertNotIn("not its own", bodies["3"])  # a claim closed as finished keeps its own comment

    def test_a_not_mine_close_posts_once_per_close_and_waits_when_gh_cannot_say(self):
        posted = [{"body": f"x\n<!-- session-reaper-notmine:{SID}:4242 -->"}]
        for comments, calls, ok in ((posted, 0, True), (None, 0, False)):
            with self.subTest(comments=comments), mock.patch.object(reaper, "issue_comments", return_value=comments), \
                 mock.patch.object(reaper, "comment", return_value=True) as comment:
                got = reaper.finish_close("work", SID, "/w", [(REPO, "2")], "x", "%9", "$3", True, self.cfg, NOW, 4242,
                                          {"2": "stop x (reported); wake: y"})
            self.assertEqual((comment.call_count, got), (calls, ok))
        with mock.patch.object(reaper, "issue_comments", return_value=posted), \
             mock.patch.object(reaper, "comment", return_value=True) as comment:  # the same session resumed, new pid
            reaper.finish_close("work", SID, "/w", [(REPO, "2")], "x", "%9", "$3", True, self.cfg, NOW, 5151, {"2": "y"})
        self.assertEqual(comment.call_count, 1)

    def test_the_record_carries_the_not_mine_claims_for_recovery(self):
        s = session(oracle_not_mine={"2": "stop x (reported); wake: y"}, pid=4242, start="t0", pane="%9")
        path = reaper.write_record(s, self.cfg, NOW, "exiting")
        rec = json.loads(path.read_text())
        self.assertEqual(rec["oracle_not_mine"], {"2": "stop x (reported); wake: y"})
        with mock.patch.object(reaper, "ps_table", return_value={1: (0, "x", "launchd")}), \
             mock.patch.object(reaper, "pane_exists", return_value=False), \
             mock.patch.object(reaper, "finish_close", return_value=True) as fc:
            reaper.recover_exiting(self.cfg, NOW)
        self.assertEqual(fc.call_args.args[-1], {"2": "stop x (reported); wake: y"})


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


class IssueRe(unittest.TestCase):
    """The branch shapes that name an issue (the reaper's only claim source) and the ones that do not."""

    def test_the_new_task_worktree_shape_names_its_issue(self):
        # new-task-worktree.sh makes `claude-<N>-<slug>`; before stima-api #7001 the reaper read it as no-issue-branch,
        # so such a session carried no claim, was always kept, and never fed the ORACLE_NOT_MINE shadow counter.
        for branch, n in (("claude-7001-p0sla-marker", "7001"), ("claude/7001-selfclose-reaper", "7001"),
                          ("fix-6374-x402-exposure-deploy-guard", "6374"), ("fix/6374-x402", "6374"),
                          ("3302-x1-actuator-pool", "3302"), ("codex/5949", "5949")):
            m = reaper.ISSUE_RE.search(branch)
            self.assertIsNotNone(m, branch)
            self.assertEqual(m.group(1), n, branch)

    def test_a_number_deeper_in_the_name_is_no_issue(self):
        for branch in ("canary-main-1031", "chore/uiux-sync-1026", "uiux-accept-1029", "claude/prompt-size-403-4389",
                       "claude-acceptance-bc-20261103", "release-20261104", "v2-100-rc",
                       "3309622ee115ae978d3b2517e8223e88307fe221"):
            self.assertIsNone(reaper.ISSUE_RE.search(branch), branch)


if __name__ == "__main__":
    unittest.main()
