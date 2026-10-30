#!/usr/bin/env python3
"""Isolated tests for the session reaper: every keep gate, transcript reading, the prompt
check, and a verifier calibrated against a real surviving process, tmux session and lock."""

from contextlib import redirect_stderr
import importlib.util
import io
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

CFG = dict(reaper.DEFAULTS, PROTECT="keep-* ci", IDLE_MINUTES="60", DONE_INBOX="", STALL_MARK_DIR="")


def session(**kw):
    s = {"tmux": "work", "name": "work", "sid": "sid-1", "status": "idle", "idle_min": 90, "bg_shells": [],
         "loop": False, "crons": 0, "scheduled": False, "asking": False,
         "last_text": "SESSION-DONE: shipped the fix", "claims": [], "owned": []}
    s.update(kw)
    return s


class Decide(unittest.TestCase):
    def keep(self, **kw):
        def brief(r, n, cfg, now):  # the oracle's view follows self.states: CLOSED ends, anything else is owed to sid-1
            st = self.states[n]
            if st == "UNKNOWN":
                return None
            if st == "CLOSED":
                return f"delivery #{n}: closed -> none"
            return (f"delivery #{n}: pr -> agent x\n  claimant: claude session sid-1; the step is that session's: hand it over")
        with mock.patch.object(reaper, "issue_state", side_effect=lambda r, n: self.states[n]), \
             mock.patch.object(reaper, "oracle_brief", side_effect=brief), \
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
            "issue-open:#2": dict(status="busy", last_text="", claims=[("o/r", "1"), ("o/r", "2")]),
            "owed-step:#2": dict(last_text="", claims=[("o/r", "1"), ("o/r", "2")]),
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
        self.assertIn("issue-unknown:#1", self.keep(last_text="", claims=[("o/r", "1")]))

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


NOW0 = reaper.calendar.timegm((2026, 10, 27, 12, 0, 0, 0, 0, 0))
ENDED = "delivery #9: pr-open -> wait check-by  [d]\n  owner: stranded-step dispatcher wakes it; no watcher needed, and the session may end"
OTHER = "delivery #9: pr -> agent x\n  claimant: claude session other-sid (n); the step is that session's: hand it over while it lives"
MINE = OTHER.replace("other-sid", "sid-1")


class OracleClaims(unittest.TestCase):
    def keep(self, briefs, **kw):
        s = session(last_text="", claims=[("theQuert/stima-api", n) for n in briefs], **kw)
        s.setdefault("other_sids", ["other-sid"])
        with mock.patch.object(reaper, "oracle_brief", side_effect=lambda r, n, c, now: briefs[n]), \
             mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "worktree_state", return_value=[]):
            return reaper.decide(s, CFG, NOW0), s

    def test_all_ended_idle_has_no_issue_keep_reason(self):
        keep, s = self.keep({"1": ENDED, "2": OTHER, "3": "delivery #3: closed -> none"})
        self.assertEqual(keep, [])
        self.assertEqual(s["claim_marks"], ["#1:ended", "#2:ended", "#3:ended"])

    def test_owed_keeps_with_owed_step(self):
        keep, s = self.keep({"1": ENDED, "2": MINE})
        self.assertEqual(keep, ["owed-step:#2"])
        self.assertEqual(s["claim_marks"], ["#1:ended", "#2:owed"])

    def test_overdue_check_by_on_an_owed_claim_is_stalled(self):
        keep, s = self.keep({"2": MINE + "\n  check-by scheduled for 2026-10-27T10:00:00Z; the dispatcher wakes"})
        self.assertEqual(keep, ["owed-step:#2"])
        self.assertEqual(s["claim_marks"], ["#2:owed:stalled"])
        keep, s = self.keep({"2": MINE + "\n  check-by scheduled for 2026-10-27T18:00:00Z; the dispatcher wakes"})
        self.assertEqual(s["claim_marks"], ["#2:owed"])

    def test_unknown_is_kept(self):
        keep, s = self.keep({"1": ENDED, "2": None, "3": "garbled"})
        self.assertEqual(keep, ["issue-unknown:#2,#3"])

    def test_busy_session_keeps_the_old_issue_open(self):
        keep, s = self.keep({"1": ENDED}, status="busy")
        self.assertEqual(keep, ["status:busy", "issue-open:#1"])

    def test_protected_session_is_still_kept_when_all_ended(self):
        keep, s = self.keep({"1": ENDED}, tmux="keep-me")
        self.assertEqual(keep, ["protected"])

    def test_other_gates_still_apply_when_all_ended(self):
        keep, s = self.keep({"1": ENDED}, owned=[{"problems": ["unpushed:wt"]}], bg_shells=[1])
        self.assertEqual(keep, ["shell-child"])  # worktree_state is mocked empty: only the shell gate shows

    def test_report_row_shows_the_marks(self):
        keep, s = self.keep({"1": OTHER})
        s.update(pid=1, descendants=0)
        self.assertIn("#1:ended", reaper.report_line(s, keep, "would-reap"))


FIXTURES = json.loads((Path(__file__).resolve().parent / "fixtures" / "delivery-state-briefs.json").read_text())


def old_substring_classify(brief, sid, now):
    """The first version of classify_claim: the phrase anywhere in the brief ends the claim, any other claimant ends it."""
    m = reaper.BRIEF_STATE_RE.match(brief)
    if (m and m.group(1).lower() == "closed") or "the session may end" in brief:
        return "ended", False
    c = reaper.CLAIMANT_RE.search(brief)
    if not c:
        return "unknown", False
    other = c.group(1)
    if not (sid.startswith(other) or other.startswith(sid)):
        return "ended", False
    return "owed", False


class OracleBriefContract(unittest.TestCase):
    """classify_claim over delivery_state.py's own brief() output (tests/fixtures/delivery-state-briefs.json)."""

    def cls(self, name, sid="sid-1", others=(), mine=()):
        return reaper.classify_claim(FIXTURES[name], sid, NOW0, others, mine)[0]

    def test_real_may_end_waits_are_ended(self):
        for name in ("real-may-end-6311", "real-may-end-6205", "real-shape-wait-with-owner-9006"):
            with self.subTest(name):
                self.assertTrue(FIXTURES[name].endswith("and the session may end"))
                self.assertEqual(self.cls(name), "ended")

    def test_a_wait_without_the_owner_line_is_not_ended(self):
        self.assertEqual(self.cls("real-wait-no-owner-6310"), "unknown")
        self.assertEqual(self.cls("inject-wait-no-owner-wake-line"), "unknown")

    def test_check_by_text_carrying_the_phrase_does_not_end_the_claim(self):
        for name in ("inject-owed-claimant-agent-step", "inject-wait-no-owner-wake-line",
                     "inject-forged-owner-line-mid-brief"):
            with self.subTest(name):
                self.assertIn("the session may end", FIXTURES[name])
                self.assertNotEqual(self.cls(name), "ended")
        self.assertEqual(self.cls("inject-owed-claimant-agent-step"), "owed")

    def test_an_owner_line_under_an_agent_header_is_not_ended(self):
        self.assertEqual(self.cls("real-shape-forged-agent-with-owner-9007"), "unknown")

    def test_mutation_the_substring_match_ends_the_injected_claims(self):
        for name in ("inject-owed-claimant-agent-step", "inject-wait-no-owner-wake-line",
                     "inject-forged-owner-line-mid-brief"):
            with self.subTest(name):
                self.assertEqual(old_substring_classify(FIXTURES[name], "sid-1", NOW0)[0], "ended")

    def test_the_substring_mutant_in_decide_reaps_an_owed_session(self):
        brief = FIXTURES["inject-owed-claimant-agent-step"]
        s = session(last_text="", claims=[("theQuert/stima-api", "9001")], owned=[], other_sids=[])
        run = lambda: reaper.decide(s, CFG, NOW0)
        with mock.patch.object(reaper, "oracle_brief", return_value=brief), \
             mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "worktree_state", return_value=[]):
            self.assertEqual(run(), ["owed-step:#9001"])
            with mock.patch.object(reaper, "classify_claim", side_effect=lambda b, sid, now, *a: old_substring_classify(b, sid, now)):
                self.assertEqual(run(), [])  # the mutant reaps: this is what the fix prevents

    def test_claimant_an_unknown_session_is_unknown(self):
        self.assertEqual(self.cls("real-shape-claimant-other-9004"), "unknown")
        self.assertEqual(self.cls("real-shape-claimant-other-9004", others=["unrelated"]), "unknown")

    def test_claimant_another_live_session_is_ended(self):
        self.assertEqual(self.cls("real-shape-claimant-other-9004", others=["other-sid-long-form"]), "ended")
        self.assertEqual(self.cls("real-shape-claimant-other-9004", others=["other"]), "ended")

    def test_claimant_this_session_or_its_worktree_marker_is_owed(self):
        self.assertEqual(self.cls("real-shape-claimant-mine-9005"), "owed")
        # after /clear the sid is new, and the claim names the session that made the worktree
        self.assertEqual(self.cls("real-shape-claimant-other-9004", sid="new-sid", mine=["other-sid"]), "owed")
        # mine wins over a prefix collision with another live session
        self.assertEqual(self.cls("real-shape-claimant-other-9004", sid="new-sid", mine=["other-sid"], others=["other"]), "owed")

    def test_a_planning_brief_without_owner_or_claimant_is_unknown(self):
        self.assertEqual(self.cls("real-multiline-detail-6315"), "unknown")

    def test_oracle_is_asked_for_the_claim_repo_explicitly(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        reaper._brief_cache.clear()
        with mock.patch.object(reaper, "run", return_value=(0, FIXTURES["real-may-end-6311"])) as r:
            reaper.oracle_brief("theQuert/stima-api", "6311", dict(CFG, ORACLE_CACHE_DIR=d, ORACLE_ROOT=d), 1000)
        self.assertEqual(r.call_args.args[0][-2:], ["--repo", "theQuert/stima-api"])


class OracleBrief(unittest.TestCase):
    def setUp(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        self.cfg = dict(CFG, ORACLE_CACHE_DIR=d, ORACLE_ROOT=d)
        reaper._brief_cache.clear()

    def test_second_call_uses_the_cache_then_expires(self):
        with mock.patch.object(reaper, "run", return_value=(0, ENDED)) as r:
            self.assertEqual(reaper.oracle_brief("theQuert/stima-api", "9", self.cfg, 1000), ENDED)
            reaper._brief_cache.clear()  # a later sweep is a new process: only the disk cache remains
            self.assertEqual(reaper.oracle_brief("theQuert/stima-api", "9", self.cfg, 1500), ENDED)
            self.assertEqual(r.call_count, 1)
            self.assertEqual(r.call_args.args[0][1:], ["scripts/ci/delivery_state.py", "9", "--brief", "--repo", "theQuert/stima-api"])
            reaper._brief_cache.clear()
            reaper.oracle_brief("theQuert/stima-api", "9", self.cfg, 1000 + 601)
            self.assertEqual(r.call_count, 2)

    def test_failure_is_none_and_not_cached(self):
        with mock.patch.object(reaper, "run", return_value=(1, "")) as r:
            self.assertIsNone(reaper.oracle_brief("theQuert/stima-api", "9", self.cfg, 1000))
            reaper._brief_cache.clear()
            self.assertIsNone(reaper.oracle_brief("theQuert/stima-api", "9", self.cfg, 1001))
            self.assertEqual(r.call_count, 2)

    def test_other_repo_is_not_asked(self):
        with mock.patch.object(reaper, "run", side_effect=AssertionError("ran")):
            self.assertIsNone(reaper.oracle_brief("theQuert/skills", "9", self.cfg, 1000))


class DoneCheckBy(unittest.TestCase):
    """Inbox DONE as a done marker, and the check-by-open keep gate (EL-FLOW-P2-2106)."""
    # 2026-10-25 22:00 TPE == 14:00 UTC
    NOW = reaper.calendar.timegm((2026, 10, 25, 14, 0, 0, 0, 0, 0))

    def setUp(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        self.inbox = Path(d) / "neo-inbox.md"
        self.cfg = dict(CFG, DONE_INBOX=str(self.inbox), CHECKBY_REPO="o/r")
        self.checkby = "CLEAR"
        self.claim = reaper.calendar.timegm((2026, 10, 25, 10, 0, 0, 0, 0, 0))  # 18:00 TPE

    def write(self, *headers):
        self.inbox.write_text("# inbox\n\nbody\n" + "\n".join(f"## {h}\n\ntext\n" for h in headers))

    def keep(self, **kw):
        kw.setdefault("last_text", "all good")
        kw.setdefault("name", "ops-dispatch")
        kw.setdefault("claims", [("o/r", "2")])
        with mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "oracle_brief", return_value=None), \
             mock.patch.object(reaper, "checkby_state", side_effect=lambda r, n, c: self.checkby), \
             mock.patch.object(reaper, "claim_time", side_effect=lambda r, n, sid: self.claim), \
             mock.patch.object(reaper, "worktree_state", return_value=[]):
            return reaper.decide(session(**kw), self.cfg, self.NOW)

    def test_old_inbox_done_by_the_session_is_reaped(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch")
        self.assertEqual(self.keep(), [])

    def test_done_older_than_the_newest_claim_is_not_done(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch")
        self.claim = reaper.calendar.timegm((2026, 10, 25, 12, 30, 0, 0, 0, 0))  # 20:30 TPE
        self.assertEqual(self.keep(), ["issue-unknown:#2"])

    def test_unknown_claim_time_is_not_done(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch")
        self.claim = None
        self.assertEqual(self.keep(), ["issue-unknown:#2"])

    def test_inbox_done_without_a_claimed_issue_is_ignored(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch")
        self.assertEqual(self.keep(claims=[]), ["claim-unknown"])

    def test_a_recent_inbox_done_keeps_the_session(self):
        self.write("K1 DONE · 2026-10-25 21:30 TPE · ops-dispatch")
        self.assertEqual(self.keep(), ["issue-unknown:#2"])

    def test_a_later_ack_by_the_same_session_is_not_done(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch",
                   "K2 ACK · 2026-10-25 20:30 TPE · ops-dispatch")
        self.assertEqual(self.keep(), ["issue-unknown:#2"])

    def test_another_sessions_done_does_not_count(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · other-session")
        self.assertEqual(self.keep(), ["issue-unknown:#2"])

    def test_a_later_done_by_another_session_does_not_hide_this_ones(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch",
                   "K2 ACK · 2026-10-25 20:30 TPE · other-session")
        self.assertEqual(self.keep(), [])

    def test_unreadable_or_unparsable_inbox_is_not_done(self):
        self.assertEqual(self.keep(), ["issue-unknown:#2"])  # file absent
        self.write("K1 DONE · yesterday-ish · ops-dispatch")
        self.assertEqual(self.keep(), ["issue-unknown:#2"])

    def test_open_check_by_keeps_an_inbox_done_session(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch")
        self.checkby = "OPEN"
        self.assertEqual(self.keep(), ["check-by-open"])

    def test_open_check_by_keeps_a_session_done_line_session(self):
        self.checkby = "OPEN"
        self.assertEqual(self.keep(last_text="SESSION-DONE: shipped"), ["check-by-open"])

    def test_gh_failure_keeps_check_by_unknown(self):
        self.checkby = "UNKNOWN"
        self.assertEqual(self.keep(last_text="SESSION-DONE: shipped"), ["check-by-unknown"])

    def shadow(self, **kw):
        """DONE_INBOX off, DONE_INBOX_SHADOW on: (keep, inbox_done_shadow) for one decide."""
        self.cfg = dict(CFG, DONE_INBOX="", DONE_INBOX_SHADOW=str(self.inbox), CHECKBY_REPO="o/r")
        kw.setdefault("last_text", "all good")
        kw.setdefault("name", "ops-dispatch")
        kw.setdefault("claims", [("o/r", "2")])
        s = session(**kw)
        with mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "oracle_brief", return_value=None), \
             mock.patch.object(reaper, "checkby_state", side_effect=lambda r, n, c: self.checkby), \
             mock.patch.object(reaper, "claim_time", side_effect=lambda r, n, sid: self.claim), \
             mock.patch.object(reaper, "worktree_state", return_value=[]):
            keep = reaper.decide(s, self.cfg, self.NOW)
        return keep, s.get("inbox_done_shadow")

    def test_shadow_marks_but_never_reaps_an_inbox_done_session(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch")
        keep, marked = self.shadow()
        self.assertEqual(keep, ["issue-unknown:#2"])
        self.assertTrue(marked)
        line = reaper.report_line(session(pid=1, descendants=0, claims=[("o/r", "2")], inbox_done_shadow=True), keep, "keep")
        self.assertIn("would-close: inbox DONE (shadow)", line)

    def test_shadow_does_not_mark_what_the_live_path_would_keep(self):
        self.write("K1 DONE · 2026-10-25 21:30 TPE · ops-dispatch")  # too recent
        self.assertEqual(self.shadow(), (["issue-unknown:#2"], False))
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch")
        self.checkby = "OPEN"  # the shadow decide reads the check-by, as the live one would
        self.assertEqual(self.shadow(), (["issue-unknown:#2"], False))

    def test_shadow_is_off_when_the_live_path_is_on_or_unset(self):
        self.write("K1 DONE · 2026-10-25 20:00 TPE · ops-dispatch")
        self.cfg = dict(CFG, DONE_INBOX=str(self.inbox), DONE_INBOX_SHADOW=str(self.inbox))
        s = session(name="ops-dispatch", claims=[("o/r", "2")])
        with mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "oracle_brief", return_value=None), \
             mock.patch.object(reaper, "checkby_state", side_effect=lambda r, n, c: self.checkby), \
             mock.patch.object(reaper, "claim_time", side_effect=lambda r, n, sid: self.claim), \
             mock.patch.object(reaper, "worktree_state", return_value=[]):
            self.assertEqual(reaper.decide(s, self.cfg, self.NOW), [])
        self.assertNotIn("inbox_done_shadow", s)
        self.assertEqual(self.keep(claims=[]), ["claim-unknown"])

    def test_check_by_is_not_read_for_a_session_that_is_not_idle_long_enough(self):
        with mock.patch.object(reaper, "checkby_state", side_effect=AssertionError("fetched")), \
             mock.patch.object(reaper, "worktree_state", return_value=[]):
            keep = reaper.decide(session(idle_min=10, claims=[("o/r", "2")]), self.cfg, self.NOW)
        self.assertEqual(keep, ["idle:10<60min"])


class CheckByState(unittest.TestCase):
    def state(self, out="", rc=0):
        reaper._checkby_cache.clear()
        with mock.patch.object(reaper, "run", return_value=(rc, out)) as r:
            st = reaper.checkby_state("theQuert/stima-api", "9", CFG)
        self.calls = r.call_args
        return st

    def test_asks_the_oracle_for_json(self):
        self.state(json.dumps({"pending_check_by": "", "due_check": ""}))
        cmd = self.calls.args[0]
        self.assertEqual(cmd[0], "python3")
        self.assertEqual(cmd[1:], [reaper.DEFAULTS["CHECKBY_ORACLE"], "9", "--json"])
        self.assertEqual(self.calls.kwargs["cwd"], "/Users/stimaclaw/GitHub/stima-api")

    def test_pending_or_due_is_open(self):
        self.assertEqual(self.state(json.dumps({"pending_check_by": "2026-10-26T06:00:00Z", "due_check": ""})), "OPEN")
        self.assertEqual(self.state(json.dumps({"pending_check_by": "", "due_check": "check-by x"})), "OPEN")

    def test_both_empty_is_clear(self):
        self.assertEqual(self.state(json.dumps({"pending_check_by": "", "due_check": "", "x": 1})), "CLEAR")

    def test_a_closed_issue_is_clear(self):
        payload = {"issue": 6090, "state": "closed", "stop": None,
                   "next": {"action": "none", "command": "", "detail": "closed as completed", "kind": "done"}}
        self.assertEqual(self.state(json.dumps(payload)), "CLEAR")

    def test_error_timeout_bad_json_or_missing_keys_is_unknown(self):
        self.assertEqual(self.state("{}", rc=1), "UNKNOWN")  # nonzero exit; run() also returns (1, "") on timeout
        self.assertEqual(self.state("not json"), "UNKNOWN")
        self.assertEqual(self.state(json.dumps({"pending_check_by": ""})), "UNKNOWN")
        self.assertEqual(self.state("[]"), "UNKNOWN")

    def test_a_claim_in_another_repo_is_unknown_without_asking(self):
        reaper._checkby_cache.clear()
        with mock.patch.object(reaper, "run", side_effect=AssertionError("asked")):
            self.assertEqual(reaper.checkby_state("theQuert/skills", "9", CFG), "UNKNOWN")

    def test_a_missing_oracle_file_is_unknown(self):
        reaper._checkby_cache.clear()
        cfg = dict(CFG, CHECKBY_ORACLE="/nonexistent/a/b/delivery_state.py")
        self.assertEqual(reaper.checkby_state("theQuert/stima-api", "9", cfg), "UNKNOWN")


class ClaimTime(unittest.TestCase):
    def test_newest_claim_comment_for_the_session(self):
        reaper._claim_cache.clear()
        reaper._comments_cache.clear()
        out = json.dumps([
            {"body": "Claimed by x session abc", "createdAt": "2026-10-25T10:00:00Z"},
            {"body": "Claimed by x session abc", "createdAt": "2026-10-25T11:00:00Z"},
            {"body": "Claimed by y session zzz", "createdAt": "2026-10-25T13:00:00Z"}])
        with mock.patch.object(reaper, "run", return_value=(0, out)):
            self.assertEqual(reaper.claim_time("o/r", "9", "abc"),
                             reaper.calendar.timegm((2026, 10, 25, 11, 0, 0, 0, 0, 0)))
        reaper._claim_cache.clear()
        reaper._comments_cache.clear()
        with mock.patch.object(reaper, "run", return_value=(1, "")):
            self.assertIsNone(reaper.claim_time("o/r", "9", "abc"))


class BatchIssueState(unittest.TestCase):
    """One GraphQL call per repo answers every claimed issue (stima-api #6477); a failure falls back, bounded."""

    def setUp(self):
        for c in (reaper._issue_cache, reaper._issue_tried, reaper._comments_cache, reaper._claim_cache):
            c.clear()
        reaper._issue_fallbacks[0] = 0

    @staticmethod
    def answer(states):
        return json.dumps({"data": {"repository": {f"i{n}": (None if st is None else {"state": st})
                                                    for n, st in states.items()}}})

    def test_one_call_answers_open_closed_and_unknown_without_a_call_per_issue(self):
        calls = []

        def fake(cmd, timeout=30, cwd=None):
            calls.append(cmd)
            return 0, self.answer({"1": "CLOSED", "2": "OPEN", "3": None, "4": "MERGED"})
        with mock.patch.object(reaper, "run", side_effect=fake):
            reaper.batch_issue_states([("o/r", "1"), ("o/r", "2"), ("o/r", "3"), ("o/r", "4"), ("o/r", "2")])
            got = [reaper.issue_state("o/r", n) for n in "1234"]
        self.assertEqual(got, ["CLOSED", "OPEN", "UNKNOWN", "MERGED"])  # not CLOSED keeps the session
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:3], ["gh", "api", "graphql"])
        self.assertNotIn("issue", calls[0][1:2])

    def test_one_call_per_repo(self):
        calls = []

        def fake(cmd, timeout=30, cwd=None):
            calls.append(cmd)
            return 0, self.answer({"1": "OPEN"})
        with mock.patch.object(reaper, "run", side_effect=fake):
            reaper.batch_issue_states([("o/a", "1"), ("o/b", "1")])
        self.assertEqual(len(calls), 2)

    def test_numbers_beyond_the_chunk_size_take_another_call(self):
        calls = []

        def fake(cmd, timeout=30, cwd=None):
            calls.append(cmd)
            return 0, self.answer({str(n): "OPEN" for n in range(100, 100 + reaper.ISSUE_BATCH)})
        with mock.patch.object(reaper, "run", side_effect=fake):
            reaper.batch_issue_states([("o/r", str(n)) for n in range(100, 100 + reaper.ISSUE_BATCH + 1)])
        self.assertEqual(len(calls), 2)

    def test_a_failed_batch_falls_back_to_the_single_call_and_keeps_when_that_fails(self):
        calls = []

        def fake(cmd, timeout=30, cwd=None):
            calls.append(cmd[:3])
            return (0, "CLOSED\n") if cmd[1] == "issue" and cmd[3] == "1" else (1, "")
        with mock.patch.object(reaper, "run", side_effect=fake):
            reaper.batch_issue_states([("o/r", "1"), ("o/r", "2")])
            self.assertEqual(reaper.issue_state("o/r", "1"), "CLOSED")
            self.assertEqual(reaper.issue_state("o/r", "2"), "UNKNOWN")
        self.assertEqual(calls, [["gh", "api", "graphql"], ["gh", "issue", "view"], ["gh", "issue", "view"]])

    def test_an_answer_in_the_wrong_shape_is_a_failure_not_closed(self):
        for out in ("", "not json", json.dumps({"data": {"repository": None}}), json.dumps({"data": None}),
                    json.dumps({"errors": [{"type": "RATE_LIMITED"}]}), json.dumps({"data": {"repository": {"i1": {}}}})):
            reaper._issue_cache.clear()
            reaper._issue_tried.clear()
            reaper._issue_fallbacks[0] = 0
            with self.subTest(out=out), mock.patch.object(reaper, "run", return_value=(1, out)):
                reaper.batch_issue_states([("o/r", "1")])
                self.assertEqual(reaper.issue_state("o/r", "1"), "UNKNOWN")

    def test_the_fallback_is_bounded(self):
        calls = []

        def fake(cmd, timeout=30, cwd=None):
            calls.append(cmd[:3])
            return 1, ""
        with mock.patch.object(reaper, "run", side_effect=fake):
            for n in range(1, 21):
                self.assertEqual(reaper.issue_state("o/r", str(n)), "UNKNOWN")
        self.assertEqual(sum(c == ["gh", "issue", "view"] for c in calls), reaper.ISSUE_FALLBACKS)

    def test_an_unbatched_ask_makes_one_batch_call_not_a_view(self):
        with mock.patch.object(reaper, "run", return_value=(0, self.answer({"7": "CLOSED"}))) as r:
            self.assertEqual(reaper.issue_state("o/r", "7"), "CLOSED")
            self.assertEqual(reaper.issue_state("o/r", "7"), "CLOSED")
        self.assertEqual(r.call_count, 1)

    def test_a_repo_name_that_is_not_one_is_never_put_in_a_query(self):
        with mock.patch.object(reaper, "run", return_value=(1, "")) as r:
            reaper.batch_issue_states([('o/r") { x', "1"), ("o/r", "1; drop")])
        r.assert_not_called()

    def test_comments_are_read_once_per_issue_however_many_sessions_ask(self):
        out = json.dumps([{"body": "Claimed by x session aaa", "createdAt": "2026-10-25T10:00:00Z"},
                          {"body": "Claimed by x session bbb", "createdAt": "2026-10-25T11:00:00Z"}])
        with mock.patch.object(reaper, "run", return_value=(0, out)) as r:
            a, b = reaper.claim_time("o/r", "9", "aaa"), reaper.claim_time("o/r", "9", "bbb")
        self.assertEqual(r.call_count, 1)
        self.assertLess(a, b)

    def test_prefetch_asks_once_for_all_issues_and_decide_adds_no_issue_view(self):
        calls = []

        def fake(cmd, timeout=30, cwd=None):
            calls.append(cmd[:3])
            return 0, self.answer({"1": "CLOSED", "2": "OPEN"})
        busy = [session(sid=f"s{i}", status="busy", last_text="", claims=[("o/r", "1"), ("o/r", "2")])
                for i in range(5)]
        with mock.patch.object(reaper, "run", side_effect=fake), \
             mock.patch.object(reaper, "oracle_brief", return_value=None), \
             mock.patch.object(reaper, "claim_time", return_value=None), \
             mock.patch.object(reaper, "worktree_state", return_value=[]):
            reaper.prefetch(busy, CFG, time.time())
            keeps = [reaper.decide(s, CFG) for s in busy]
        self.assertEqual(calls, [["gh", "api", "graphql"]])
        self.assertTrue(all("issue-open:#2" in k for k in keeps))


class JudgeOrder(unittest.TestCase):
    def test_longest_idle_without_issues_first_busy_and_protected_last(self):
        sessions = [session(tmux="busy", name="busy", status="busy", idle_min=1, claims=[("o/r", "1")]),
                    session(tmux="keep-me", name="keep-me", idle_min=500),
                    session(tmux="issues", name="issues", idle_min=300, claims=[("o/r", "1"), ("o/r", "2")]),
                    session(tmux="young", name="young", idle_min=10),
                    session(tmux="old", name="old", idle_min=200),
                    session(tmux="oldest", name="oldest", idle_min=400),
                    session(tmux="one", name="one", idle_min=100, claims=[("o/r", "3")])]
        got = [s["tmux"] for s in sorted(sessions, key=lambda x: reaper.judge_order(x, CFG))]
        self.assertEqual(got, ["oldest", "old", "one", "issues", "young", "busy", "keep-me"])

    def test_a_budget_cut_leaves_the_busy_sessions_unjudged(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        cfgfile = tmp / "conf"
        cfgfile.write_text(f"APPLY=0\nDONE_INBOX=\nREPORT={tmp / 'report.md'}\nIDLE_LIST_HOURS=0\nSTALL_MARK_DIR=\n")
        extra = dict(pid=5, start="S", file="f", status_at=1, cwd="/w", pane="%1", session_id="$1", descendants=0,
                     fg=True, sub_active=0, relay_pending=[], screen_tail="")
        sessions = [session(tmux="busy", name="busy", status="busy", idle_min=1, sid="b" * 10, **extra),
                    session(tmux="done", name="done", idle_min=300, sid="d" * 10, **extra)]
        judged = []

        def decide(s, cfg, now=None):
            judged.append(s["tmux"])
            reaper.RUN_BUDGET = -1  # the budget is spent after the first session
            return []
        with mock.patch.object(reaper, "HOME", tmp), mock.patch.object(reaper, "gather", return_value=sessions), \
             mock.patch.object(reaper, "prefetch"), mock.patch.object(reaper, "decide", side_effect=decide), \
             mock.patch.object(reaper, "recover_exiting", return_value=[]), mock.patch.object(reaper, "alert"), \
             mock.patch.object(reaper, "RUN_BUDGET", 1200.0):
            reaper.main(["--config", str(cfgfile)])
            reaper.RUN_BUDGET = 1200.0
        self.assertEqual(judged, ["done"])
        report = (tmp / "report.md").read_text()
        self.assertIn("unjudged:run-budget", [l for l in report.splitlines() if l.startswith("| busy")][0])


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

    def test_a_fired_one_shot_or_expired_recurring_cron_is_not_pending(self):
        def pinned(days):  # local-time cron fields for NOW + days
            t = time.localtime(self.NOW + days * 86400)
            return f"{t.tm_min} {t.tm_hour} {t.tm_mday} {t.tm_mon} *"
        fired = self.write([self.assistant(self.tool("CronCreate", cron=pinned(-0.5), recurring=False),
                                           at="2026-10-10T00:00:00.000Z")])
        future = self.write([self.assistant(self.tool("CronCreate", cron=pinned(1), recurring=False))])
        expired = self.write([self.assistant(self.tool("CronCreate", cron="*/5 * * * *"),
                                             at="2026-10-01T00:00:00.000Z")])
        fresh = self.write([self.assistant(self.tool("CronCreate", cron="*/5 * * * *"))])
        self.assertEqual(reaper.transcript_facts(fired, self.NOW)["crons"], 0)
        self.assertEqual(reaper.transcript_facts(future, self.NOW)["crons"], 1)
        self.assertEqual(reaper.transcript_facts(expired, self.NOW)["crons"], 0)
        self.assertEqual(reaper.transcript_facts(fresh, self.NOW)["crons"], 1)

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


class RecoverExiting(unittest.TestCase):
    """A crash after /exit leaves reaped/<tmux>.json at "exiting"; the next run finishes it once."""

    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d)
        self.cfg = dict(CFG, REAPED_DIR=str(self.d / "reaped"), CLOSED_LOG=str(self.d / "closed.md"))
        s = {"tmux": "work", "name": "work", "sid": "sid-1", "sid": "sid-1", "cwd": "/w", "claims": [("o/r", "7")],
             "owned": [], "last_text": "SESSION-DONE: x", "pid": 4242, "start": "t0", "pane": "%9",
             "session_id": "$3"}
        self.rec = reaper.write_record(s, self.cfg, 0, "exiting")
        self.comments = []

    OTHER = {1: (0, "x", "launchd"), 500: (1, "x", "-zsh")}

    def recover(self, comments_existing=(), table=None):
        with mock.patch.object(reaper, "ps_table", return_value=self.OTHER if table is None else table), \
             mock.patch.object(reaper, "has_marker", side_effect=lambda ref, sid: sid in comments_existing), \
             mock.patch.object(reaper, "comment", side_effect=lambda ref, body: self.comments.append(body) or True), \
             mock.patch.object(reaper, "pane_exists", return_value=True), \
             mock.patch.object(reaper, "pane_state", return_value={"session": "work", "session_id": "$3", "alone": True, "pane_pid": 500}), \
             mock.patch.object(reaper, "tmux") as tmux:
            reaper.recover_exiting(self.cfg, 0)
            return tmux

    def test_one_run_completes_a_dead_exiting_record_and_a_second_does_nothing(self):
        tmux = self.recover()
        self.assertEqual(json.loads(self.rec.read_text())["status"], "reaped")
        self.assertEqual((self.d / "closed.md").read_text().count("sid-1"), 1)
        self.assertEqual(len(self.comments), 1)
        self.assertIn("session-reaper:sid-1", self.comments[0])
        tmux.assert_called_once_with("kill-session", "-t", "$3")
        tmux = self.recover()
        self.assertEqual((self.d / "closed.md").read_text().count("sid-1"), 1)
        self.assertEqual(len(self.comments), 1)
        tmux.assert_not_called()

    def test_an_existing_marker_comment_is_not_posted_again(self):
        self.recover(comments_existing=("sid-1",))
        self.assertEqual(self.comments, [])
        self.assertEqual(json.loads(self.rec.read_text())["status"], "reaped")

    def test_a_still_running_pid_is_left_alone(self):
        with mock.patch.object(reaper, "ps_table", return_value={4242: (1, "t0", "claude")}), \
             mock.patch.object(reaper, "tmux") as tmux:
            reaper.recover_exiting(self.cfg, 0)
        tmux.assert_not_called()
        self.assertEqual(json.loads(self.rec.read_text())["status"], "exiting")

    def test_empty_ps_table_skips_recovery_and_leaves_the_record(self):
        tmux = self.recover(table={})
        tmux.assert_not_called()
        self.assertEqual(self.comments, [])
        self.assertEqual(json.loads(self.rec.read_text())["status"], "exiting")

    def test_a_new_claude_under_the_pane_blocks_recovery_and_aborts_the_record(self):
        table = dict(self.OTHER)
        table[600] = (500, "t9", "/usr/local/bin/claude --resume x")
        tmux = self.recover(table=table)
        tmux.assert_not_called()
        self.assertEqual(self.comments, [])
        self.assertEqual(json.loads(self.rec.read_text())["status"], "aborted:alive")

    def test_a_resumed_versioned_claude_binary_also_blocks_recovery(self):
        table = dict(self.OTHER)
        table[600] = (500, "t9", "/Users/x/.local/share/claude/versions/2.1.293 --resume")
        tmux = self.recover(table=table)
        tmux.assert_not_called()
        self.assertEqual(self.comments, [])
        self.assertEqual(json.loads(self.rec.read_text())["status"], "aborted:alive")

    def test_unconfirmed_marker_keeps_the_record_and_notes_it_after_24h(self):
        with mock.patch.object(reaper, "ps_table", return_value=self.OTHER), \
             mock.patch.object(reaper, "has_marker", return_value=None), \
             mock.patch.object(reaper, "comment") as comment, \
             mock.patch.object(reaper, "pane_exists", return_value=False), \
             mock.patch.object(reaper, "tmux") as tmux:
            st = self.rec.stat().st_mtime
            self.assertEqual(reaper.recover_exiting(self.cfg, st + 60), [])
            notes = reaper.recover_exiting(self.cfg, st + 25 * 3600)
        comment.assert_not_called()
        tmux.assert_not_called()
        self.assertEqual(len(notes), 1)
        self.assertIn("sid-1", notes[0])
        self.assertEqual(json.loads(self.rec.read_text())["status"], "exiting")


class HasMarker(unittest.TestCase):
    def check(self, rc, out):
        with mock.patch.object(reaper, "run", return_value=(rc, out)):
            return reaper.has_marker(("o/r", "7"), "sid-1")

    def test_tri_state(self):
        found = json.dumps({"comments": [{"body": "x <!-- session-reaper:sid-1 -->"}]})
        self.assertIs(self.check(0, found), True)
        self.assertIs(self.check(0, json.dumps({"comments": [{"body": "other"}]})), False)
        self.assertIsNone(self.check(1, ""))
        self.assertIsNone(self.check(0, "not json"))


class FinishAndReap(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d)
        self.cfg = dict(CFG, REAPED_DIR=str(self.d / "reaped"), CLOSED_LOG=str(self.d / "closed.md"))

    def test_finish_close_is_false_when_gh_cannot_say_and_posts_nothing(self):
        with mock.patch.object(reaper, "has_marker", return_value=None), \
             mock.patch.object(reaper, "comment") as comment:
            ok = reaper.finish_close("work", "sid-1", "/w", [("o/r", "7")], "x", "%9", "$3", True, self.cfg, 0)
        self.assertFalse(ok)
        comment.assert_not_called()

    def sess(self):
        f = self.d / "1.json"
        f.write_text(json.dumps({"status": "idle", "statusUpdatedAt": 1}))
        return {"file": str(f), "status_at": 1, "pid": 4242, "start": "t0", "pane": "%9", "tmux": "work",
                "name": "work", "sid": "sid-1", "cwd": "/w", "claims": [("o/r", "7")], "owned": [],
                "last_text": "x"}

    def patches(self):
        st = {"session": "work", "session_id": "$3", "alone": True, "pane_pid": 500, "screen": ""}
        table = {4242: (500, "t0", "claude"), 500: (1, "x", "-zsh")}
        return [mock.patch.object(reaper, "ps_table", return_value=table),
                mock.patch.object(reaper, "foreground", return_value=True),
                mock.patch.object(reaper, "pane_state", return_value=st),
                mock.patch.object(reaper, "empty_prompt", return_value=True),
                mock.patch.object(reaper, "protected", return_value=False),
                mock.patch.object(reaper, "tmux"),
                mock.patch.object(reaper.time, "sleep")]

    def run_reap(self, s, extra=()):
        from contextlib import ExitStack
        with ExitStack() as es:
            for m in [*self.patches(), *extra]:
                es.enter_context(m)
            return reaper.reap(s, self.cfg, 0)

    def test_close_unconfirmed_keeps_the_record_exiting(self):
        s = self.sess()
        gone = mock.patch.object(reaper, "cursor_line", return_value="❯ /exit")
        # claude vanishes from ps after Enter: first call (reap start) has it, the wait loop does not
        calls = iter([{4242: (500, "t0", "claude"), 500: (1, "x", "-zsh")}])
        def ps():
            return next(calls, {500: (1, "x", "-zsh")})
        extra = [gone, mock.patch.object(reaper, "finish_close", return_value=False)]
        from contextlib import ExitStack
        with ExitStack() as es:
            for m in self.patches()[1:] + extra:
                es.enter_context(m)
            es.enter_context(mock.patch.object(reaper, "ps_table", side_effect=ps))
            out = reaper.reap(s, self.cfg, 0)
        self.assertEqual(out[0], "skipped:close-unconfirmed")
        self.assertEqual(json.loads(s["record"].read_text())["status"], "exiting")

    def test_an_exception_in_reap_before_claude_exits_marks_the_record_aborted(self):
        s = self.sess()
        boom = mock.patch.object(reaper, "cursor_line", side_effect=RuntimeError("boom"))
        with self.assertRaises(RuntimeError):
            self.run_reap(s, [boom])
        self.assertEqual(json.loads(s["record"].read_text())["status"], "aborted:exception")


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


class DoneGrace(unittest.TestCase):
    """EL-T2512: a session that said it is done, after its last prompt, waits DONE_GRACE_MINUTES, not IDLE_MINUTES."""
    def setUp(self):
        self.states, self.checkby = {"1": "CLOSED"}, "CLEAR"
        self.brief = "delivery #1: closed -> none"

    def run_decide(self, mode, **kw):
        kw.setdefault("idle_min", 10)
        kw.setdefault("text_at", 2000)
        kw.setdefault("prompt_at", 1000)
        self.s = session(**kw)
        cfg = dict(CFG, DONE_GRACE=mode, NOCLAIM_DONE="off", CHECKBY_REPO="o/r")
        brief = lambda r, n, c, now: self.brief
        with mock.patch.object(reaper, "issue_state", side_effect=lambda r, n: self.states[n]), \
             mock.patch.object(reaper, "oracle_brief", side_effect=brief), \
             mock.patch.object(reaper, "checkby_state", side_effect=lambda r, n, c: self.checkby), \
             mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: w.get("problems", [])):
            return reaper.decide(self.s, cfg, 3000)

    def test_session_done_after_the_prompt_closes_after_the_grace(self):
        self.assertEqual(self.run_decide("apply"), [])
        self.assertEqual(self.run_decide("apply", idle_min=3), ["idle:3<5min"])

    def test_without_a_fresh_done_line_the_idle_wait_stands(self):
        self.assertEqual(self.run_decide("apply", prompt_at=2000), ["idle:10<60min"])  # prompted since
        self.assertEqual(self.run_decide("apply", last_text="shipped it"), ["idle:10<60min", "claim-unknown"])
        self.assertEqual(self.run_decide("apply", last_text="quoted: SESSION-DONE: x"),
                         ["idle:10<60min", "claim-unknown"])  # mid-line prose is not a done line
        self.assertEqual(self.run_decide("off"), ["idle:10<60min"])
        for quoted in ("- `SESSION-DONE: x`", "> SESSION-DONE: x", "`SESSION-STATE: IDLE_NO_WORK`",
                       "```\nSESSION-DONE: x\n```", "SESSION-DONE: x\nmore\nand more\nstill more"):
            self.run_decide("shadow", last_text=quoted)
            self.assertFalse(self.s.get("done_grace_shadow"), quoted)  # explained, quoted or not at the end

    def test_idle_no_work_shortens_only_the_wait(self):
        text = "nothing left\nSESSION-STATE: IDLE_NO_WORK"
        self.assertEqual(self.run_decide("apply", last_text=text, claims=[("o/r", "1")]), [])
        self.assertEqual(self.run_decide("apply", last_text=text), ["claim-unknown"])  # not a done line by itself

    def test_every_other_gate_still_holds(self):
        wt = {"path": Path("/x/wt"), "problems": ["uncommitted:wt"]}
        self.assertEqual(self.run_decide("apply", owned=[wt]), ["uncommitted:wt"])
        self.assertEqual(self.run_decide("apply", bg_shells=[1]), ["shell-child"])
        self.checkby, self.states["1"] = "OPEN", "OPEN"
        self.brief = "delivery #1: pr -> agent x\n  claimant: claude session sid-1; the step is that session's: hand it over"
        self.assertEqual(self.run_decide("apply", claims=[("o/r", "1")]), ["check-by-open"])

    def test_a_claim_handed_to_another_live_session_carries_its_check_by(self):
        self.checkby = "OPEN"
        handed = "delivery #1: pr -> agent x\n  claimant: claude session pr-drain-1 (pr-drain); the step is that session's: hand it over"
        with mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "oracle_brief", return_value=handed), \
             mock.patch.object(reaper, "checkby_state", side_effect=lambda r, n, c: self.checkby), \
             mock.patch.object(reaper, "worktree_state", return_value=[]):
            cfg = dict(CFG, NOCLAIM_DONE="off", CHECKBY_REPO="o/r")
            live = session(claims=[("o/r", "1")], other_sids=("pr-drain-1",))
            gone = session(claims=[("o/r", "1")], other_sids=())
            self.assertEqual(reaper.decide(live, cfg, 3000), [])
            self.assertEqual(reaper.decide(gone, cfg, 3000), ["check-by-open"])  # claimant not live: unknown, kept
            own = session(claims=[("o/r", "1")], other_sids=("pr-drain-1",),
                          owned=[{"path": Path("/x/wt"), "marker": "pr-drain-1"}])
            self.assertEqual(reaper.decide(own, cfg, 3000), ["check-by-open"])  # its own marker: its check-by

    def test_a_claim_outside_the_checkby_repo_has_no_check_by(self):
        self.states["7"] = "OPEN"
        self.checkby = "UNKNOWN"
        self.assertEqual(self.run_decide("apply", claims=[("o/docs", "7")]), [])
        self.brief = "delivery #7: pr -> agent x\n  claimant: claude session sid-1; the step is that session's: hand it over"
        self.assertEqual(self.run_decide("apply", claims=[("o/r", "7")]), ["check-by-unknown"])

    def test_shadow_reports_would_close_and_keeps(self):
        self.assertEqual(self.run_decide("shadow"), ["idle:10<60min"])
        self.assertTrue(self.s.get("done_grace_shadow"))
        self.assertIn("would-close: done grace (shadow)", reaper.report_line(
            dict(self.s, pid=1, descendants=0), ["idle:10<60min"], "would-close"))
        self.run_decide("shadow", bg_shells=[1])
        self.assertFalse(self.s.get("done_grace_shadow"))
        self.run_decide("shadow", idle_min=3)
        self.assertFalse(self.s.get("done_grace_shadow"))

    def test_transcript_records_when_the_text_was_written(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        p = Path(d) / "t.jsonl"
        p.write_text("\n".join(json.dumps(e) for e in [
            {"type": "user", "timestamp": "2026-10-11T00:00:00.000Z", "message": {"content": "go"}},
            {"type": "assistant", "timestamp": "2026-10-11T00:05:00.000Z",
             "message": {"content": [{"type": "text", "text": "SESSION-DONE: done"}]}},
            {"type": "assistant", "timestamp": "2026-10-11T00:06:00.000Z",
             "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {}}]}}]) + "\n")
        now = reaper.calendar.timegm((2026, 10, 11, 0, 10, 0, 0, 0, 0))
        f = reaper.transcript_facts(p, now)
        self.assertFalse(reaper.said_done(f))  # a tool call came after the done text: still working
        lines = p.read_text().splitlines()
        p.write_text("\n".join(lines[:2]) + "\n")
        f = reaper.transcript_facts(p, now)
        self.assertEqual(f["text_at"] - f["prompt_at"], 300)
        self.assertTrue(reaper.said_done(f))


class WaitingUntil(unittest.TestCase):
    """EL-T2520: a reply that ends on an alarm closes under the grace only with no open work; else FALSE_WAITING."""
    WAIT = "checked it\nSESSION-STATE: WAITING_UNTIL=2026-10-31T09:00:00Z — the dispatcher wakes it"
    OWN = "delivery #{n}: pr-open (none) -> agent {step}  [x]\n  check-by {at}: x\n  claimant: claude session sid-1; the step is that session's: hand it over"
    # the oracle's real shape for a step that waits on an event (delivery_state.py 6702 --brief, 2026-10-30 09:59Z)
    WAITS = ("delivery #{n}: pr-open (none) -> wait auto-merge  [781beaabc01cfc73]\n  auto-merge is armed on #6703\n"
             "  wake: #6703 merged by GitHub\n  owner: github-auto-merge wakes it; no watcher needed, and the session may end")
    WT = {"path": Path("/x/wt"), "repo": "/r", "branch": "feat/x", "marker": "m-1"}

    def setUp(self):
        self.prs, self.brief = [], None

    def run_decide(self, mode, **kw):
        kw.setdefault("last_text", self.WAIT)
        kw.setdefault("idle_min", 10)
        kw.setdefault("text_at", 2000)
        kw.setdefault("prompt_at", 1000)
        kw.setdefault("descendants", 0)
        kw.setdefault("owned", [dict(self.WT)])
        kw.setdefault("cwd", "/x/wt")
        self.s = session(**kw)
        cfg = dict(CFG, DONE_GRACE=mode, NOCLAIM_DONE="off", CHECKBY_REPO="o/r")
        with mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "oracle_brief", side_effect=lambda r, n, c, now: self.brief), \
             mock.patch.object(reaper, "checkby_state", return_value="OPEN"), \
             mock.patch.object(reaper, "open_prs", side_effect=lambda s: list(self.prs)), \
             mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: w.get("problems", [])):
            return reaper.decide(self.s, cfg, reaper.calendar.timegm((2026, 10, 30, 10, 0, 0, 0, 0, 0)))

    def test_a_pure_alarm_closes_after_the_grace(self):
        self.assertEqual(self.run_decide("apply"), [])
        self.assertEqual(self.run_decide("apply", idle_min=3), ["idle:3<5min"])
        self.assertIsNone(self.s.get("false_waiting"))

    def test_a_claim_that_waits_on_an_event_is_the_alarm(self):
        self.brief = self.WAITS.format(n=7)
        self.assertEqual(self.run_decide("apply", claims=[("o/r", "7")]), [])
        self.brief = self.OWN.format(n=7, step="check-by", at="2026-10-30T05:00Z")  # due: the oracle says agent
        self.assertEqual(self.run_decide("apply", claims=[("o/r", "7")]), ["owed-step:#7"])
        self.assertEqual(self.s["false_waiting"], ["owed-step:#7"])
        self.brief = self.OWN.format(n=7, step="repair-ci", at="2026-10-31T09:00Z")  # a red gate is not an alarm
        self.assertEqual(self.run_decide("apply", claims=[("o/r", "7")]), ["owed-step:#7"])

    def test_open_work_is_false_waiting_and_never_closes(self):
        self.prs = ["open-pr:o/r#5"]
        self.assertEqual(self.run_decide("apply"), ["open-pr:o/r#5"])
        self.assertEqual(self.s["false_waiting"], ["open-pr:o/r#5"])
        self.prs = ["open-pr-unknown:feat/x"]
        self.assertEqual(self.run_decide("apply"), ["open-pr-unknown:feat/x"])
        self.prs = []
        wt = {"path": Path("/x/wt"), "problems": ["unpushed:wt"]}
        self.assertEqual(self.run_decide("apply", owned=[wt]), ["unpushed:wt"])
        self.assertEqual(self.s["false_waiting"], ["unpushed:wt"])

    def test_a_claim_less_alarm_carries_the_noclaim_gates(self):
        """Review of 4764bdf: the alarm stands in for claim-unknown, so every noclaim_done() gate but the inbox holds."""
        self.assertEqual(self.run_decide("apply", owned=[], cwd="/repo"), ["open-pr-unknown:no-worktree"])
        self.assertEqual(self.s["false_waiting"], ["open-pr-unknown:no-worktree"])
        self.assertEqual(self.run_decide("apply", descendants=1), ["child-process"])
        self.assertEqual(self.run_decide("apply", descendants=None), ["child-process"])  # unread counts as one
        self.assertEqual(self.run_decide("apply", cwd="/repo"), [])  # a clean cwd outside its worktrees
        self.assertEqual(self.run_decide("apply", owned=[], cwd=None), ["open-pr-unknown:no-worktree"])
        with mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: ["uncommitted:repo"]), \
             mock.patch.object(reaper, "open_prs", return_value=[]), \
             mock.patch.object(reaper, "oracle_brief", return_value=None):
            s = session(last_text=self.WAIT, descendants=0, owned=[dict(self.WT)], cwd="/repo")
            self.assertIn("uncommitted:repo", reaper.waiting_keeps(
                s, dict(CFG, CHECKBY_REPO="o/r"), reaper.calendar.timegm((2026, 10, 30, 10, 0, 0))))
        self.assertEqual(self.run_decide("apply", tmux="homepage", name="homepage"), ["never-close"])
        self.brief = self.OWN.format(n=909, step="repair", at="2026-10-31T09:00Z")  # a claim it names, no branch
        self.assertEqual(self.run_decide("apply", last_text="fixing #909\n" + self.WAIT), ["named-claim:#909"])

    def test_a_passed_or_unread_alarm_keeps(self):
        late = self.WAIT.replace("2026-10-31T09:00:00Z", "2026-10-30T09:00Z")
        self.assertEqual(self.run_decide("apply", last_text=late), ["alarm-passed"])
        self.assertEqual(self.s["false_waiting"], ["alarm-passed"])
        bad = self.WAIT.replace("2026-10-31T09:00:00Z", "2026-13-45T99:00Z")
        self.assertEqual(self.run_decide("apply", last_text=bad), ["alarm-passed"])

    def test_off_never_asks_github(self):
        calls = []
        with mock.patch.object(reaper, "waiting_keeps", side_effect=lambda *a: calls.append(a) or []):
            self.run_decide("off", idle_min=90)
        self.assertEqual(calls, [])

    def test_shadow_and_off_close_nothing_and_still_report(self):
        self.assertEqual(self.run_decide("shadow", idle_min=90), ["claim-unknown"])
        self.assertTrue(self.s.get("done_grace_shadow"))
        self.prs = ["open-pr:o/r#5"]
        self.assertEqual(self.run_decide("shadow", idle_min=90), ["claim-unknown"])
        self.assertEqual(self.s["false_waiting"], ["open-pr:o/r#5"])
        self.assertFalse(self.s.get("done_grace_shadow"))
        self.assertIn("FALSE_WAITING: open-pr:o/r#5", reaper.report_line(
            dict(self.s, pid=1, descendants=0), ["claim-unknown"], "keep"))
        self.assertEqual(self.run_decide("off", idle_min=90), ["claim-unknown"])
        self.assertIsNone(self.s.get("false_waiting"))  # off asks GitHub nothing; only keep's own reasons show
        self.assertEqual(self.run_decide("off", idle_min=90, owned=[dict(self.WT, problems=["unpushed:wt"])]),
                         ["claim-unknown", "unpushed:wt"])
        self.assertEqual(self.s["false_waiting"], ["unpushed:wt"])

    def test_only_a_bare_fresh_alarm_counts(self):
        for text, kw in (("- `SESSION-STATE: WAITING_UNTIL=2026-10-31T09:00:00Z`", {}),
                         ("SESSION-STATE: WAITING_UNTIL=soon", {}), (self.WAIT, {"prompt_at": 3000})):
            self.assertEqual(self.run_decide("apply", last_text=text, **kw), ["idle:10<60min", "claim-unknown"], text)
        both = self.WAIT + "\nSESSION-DONE: nothing left"
        self.assertFalse(reaper.said_waiting(dict(last_text=both, text_at=2, prompt_at=1)))  # a done reply is done

    def test_open_prs_reads_each_worktree_branch(self):
        reaper._pr_cache.clear()
        self.addCleanup(reaper._pr_cache.clear)
        owned = [{"repo": "/r", "branch": "feat/a"}, {"repo": "/r", "branch": "feat/b"}, {"repo": "/r", "branch": "main"}]
        answers = {"feat/a": (0, "12\n"), "feat/b": (1, "")}
        with mock.patch.object(reaper, "gh_repo", return_value="o/r"), \
             mock.patch.object(reaper, "run", side_effect=lambda cmd, timeout=30, cwd=None: answers[cmd[cmd.index("--head") + 1]]):
            self.assertEqual(reaper.open_prs({"owned": owned}), ["open-pr:o/r#12", "open-pr-unknown:feat/b"])
            detached = [{"repo": "/r", "branch": "c06cce66eb16", "path": Path("/x/wt-6703")}]
            self.assertEqual(reaper.open_prs({"owned": detached}), ["open-pr-unknown:wt-6703"])


class Nudge(unittest.TestCase):
    """EL-T2482: an idle session at an empty prompt kept only by its own open work gets one ROUTE nudge per fingerprint."""
    SEP = "─" * 20

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.cfg = dict(CFG, NUDGE_EVENTS=str(self.tmp / "events.log"), NUDGE_STATE=str(self.tmp / "nudged.json"))
        self.now = time.mktime((2026, 10, 30, 15, 0, 0, 0, 0, -1))
        self.screen = f"{self.SEP}\n❯ \n{self.SEP}"
        p = mock.patch.object(reaper, "pane_state", lambda pane: {"screen": self.screen, "cx": 2, "cy": 1})
        p.start()
        self.addCleanup(p.stop)

    def run_once(self, keep, **kw):
        s = session(sid="abcdef0123", pane="%1", **kw)
        return reaper.nudge_events(self.cfg, [(s, keep, "keep")], self.now)

    def events(self):
        f = self.tmp / "events.log"
        return f.read_text().splitlines() if f.exists() else []

    def test_open_work_at_an_empty_prompt_routes_once(self):
        self.assertEqual(self.run_once(["owed-step:#6702", "unpushed:wt"]), ["abcdef01:owed-step:#6702,unpushed:wt"])
        self.assertRegex(self.events()[0], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4} ROUTE nudge work abcdef01:owed-step:#6702,unpushed:wt$")
        self.assertEqual(self.run_once(["owed-step:#6702", "unpushed:wt"]), [], "same fingerprint: no second nudge")
        self.assertEqual(len(self.events()), 1)

    def test_a_fingerprint_that_clears_nudges_again_when_it_returns(self):
        self.run_once(["owed-step:#1"])
        reaper.nudge_events(self.cfg, [(session(sid="abcdef0123", pane="%1"), [], "keep")], self.now)  # judged, no work
        self.assertEqual(self.run_once(["owed-step:#1"]), ["abcdef01:owed-step:#1"])

    def test_busy_or_a_draft_after_a_nudge_does_not_forget_it(self):
        self.run_once(["owed-step:#1"])
        # what decide() really returns once the session works on it (review: a busy row never carries owed-step)
        self.assertEqual(self.run_once(["status:busy", "issue-open:#1"], status="busy", idle_min=0), [])
        self.assertEqual(self.run_once(["idle:20<60min", "issue-open:#1"], idle_min=20), [])
        self.screen = f"{self.SEP}\n❯ half a reply\n{self.SEP}"
        self.assertEqual(self.run_once(["owed-step:#1"]), [])
        self.screen = f"{self.SEP}\n❯ \n{self.SEP}"
        self.assertEqual(self.run_once(["owed-step:#1"]), [], "same work, idle again: still once")

    def test_decide_then_nudge_end_to_end_nudges_once_across_a_busy_spell(self):
        cfg = dict(self.cfg, CHECKBY_ORACLE="")
        brief = lambda r, n, c, now: f"next: agent repair #{n} claimant: sid-x"
        with mock.patch.object(reaper, "oracle_brief", brief), \
                mock.patch.object(reaper, "classify_claim", lambda *a, **k: ("owed", False)), \
                mock.patch.object(reaper, "issue_state", lambda r, n: "OPEN"):
            routed = []
            for st, idle in (("idle", 90), ("busy", 0), ("idle", 20), ("idle", 90)):
                s = session(sid="abcdef0123", pane="%1", status=st, idle_min=idle, last_text="working",
                            claims=[("o/r", "7")])
                keep = reaper.decide(s, cfg)
                routed += reaper.nudge_events(cfg, [(s, keep, "keep")], self.now)
        self.assertEqual(routed, ["abcdef01:owed-step:#7"])

    def test_an_ended_session_is_dropped_from_the_state(self):
        self.run_once(["owed-step:#1"])
        other = session(sid="99999999xx", tmux="other", name="other")
        reaper.nudge_events(self.cfg, [(other, ["status:busy"], "keep")], self.now)
        self.assertEqual(json.loads((self.tmp / "nudged.json").read_text()), [])

    def test_a_live_session_gather_skipped_keeps_its_fingerprint(self):
        self.run_once(["owed-step:#1"])
        other = session(sid="99999999xx", tmux="other", name="other")
        with mock.patch.object(reaper, "SKIPPED", [("work", "pane-missing", True)]), \
                mock.patch.object(reaper, "SKIPPED_INFO", {"work": {"sid": "abcdef01"}}):
            reaper.nudge_events(self.cfg, [(other, ["status:busy"], "keep")], self.now)
        self.assertEqual(json.loads((self.tmp / "nudged.json").read_text()), ["abcdef01:owed-step:#1"])

    def test_a_failed_event_write_forgets_the_fingerprint(self):
        self.cfg["NUDGE_EVENTS"] = str(self.tmp)  # a directory: open() fails
        with self.assertRaises(OSError) as cm:
            self.run_once(["owed-step:#1"])
        self.assertIn("abcdef01:owed-step:#1", str(cm.exception))
        self.assertEqual(json.loads((self.tmp / "nudged.json").read_text()), [])

    def test_a_busy_session_is_nudged_once_it_is_idle_at_the_prompt(self):
        self.assertEqual(self.run_once(["owed-step:#1"], status="busy"), [])
        self.assertEqual(self.run_once(["owed-step:#1"]), ["abcdef01:owed-step:#1"])

    def test_a_session_not_judged_this_sweep_keeps_its_fingerprint(self):
        self.run_once(["owed-step:#1"])
        for seen in ([], [(session(sid="abcdef0123"), ["unjudged:run-budget"], "keep")],
                     [(session(sid="abcdef0123"), [], "error")]):
            reaper.nudge_events(self.cfg, seen, self.now)
            self.assertEqual(self.run_once(["owed-step:#1"]), [], seen)

    def test_a_pending_check_by_alone_is_not_a_nudge(self):
        self.assertEqual(self.run_once(["check-by-open"]), [])
        self.assertEqual(self.run_once(["check-by-open", "unpushed:wt"]), ["abcdef01:check-by-open,unpushed:wt"])

    def test_a_corrupt_state_file_counts_as_empty(self):
        (self.tmp / "nudged.json").write_text("{not json")
        self.assertEqual(self.run_once(["owed-step:#1"]), ["abcdef01:owed-step:#1"])
        self.assertEqual(json.loads((self.tmp / "nudged.json").read_text()), ["abcdef01:owed-step:#1"])

    def test_no_pane_or_an_unreadable_pane_is_not_a_nudge(self):
        s = session(sid="abcdef0123")  # no "pane" key
        self.assertEqual(reaper.nudge_events(self.cfg, [(s, ["owed-step:#1"], "keep")], self.now), [])
        with mock.patch.object(reaper, "pane_state", lambda pane: None):
            self.assertEqual(self.run_once(["owed-step:#1"]), [])

    def test_any_other_keep_reason_is_not_a_nudge(self):
        for keep in (["owed-step:#1", "check-by-unknown"], ["unpushed:wt", "unchecked:wt"], ["owed-step:#1", "waiting"], ["uncommitted:wt", "protected"], ["subagent-active"], [],
                     ["owed-step:#1", "loop-pending"], ["claim-unknown"]):
            self.assertEqual(self.run_once(keep), [], keep)

    def test_not_idle_long_enough_or_not_idle_is_not_a_nudge(self):
        self.assertEqual(self.run_once(["owed-step:#1"], idle_min=30), [])
        self.assertEqual(self.run_once(["owed-step:#1"], status="busy"), [])

    def test_uiux_and_homepage_are_nudged_like_every_session_and_only_protect_skips(self):
        for name in ("uiux", "homepage"):  # EL-T2490: NEVER_CLOSE (default uiux* homepage*) stops a close, not a nudge
            self.assertEqual(self.run_once(["owed-step:#1"], tmux=name, name=name), ["abcdef01:owed-step:#1"], name)
            reaper.nudge_events(self.cfg, [(session(sid="abcdef0123", pane="%1"), [], "keep")], self.now)
        self.assertEqual(self.run_once(["owed-step:#1"], tmux="keep-me", name="keep-me"), [], "PROTECT keep-*")

    def test_a_draft_or_a_menu_on_screen_is_not_idle_at_the_prompt(self):
        self.screen = f"{self.SEP}\n❯ #24 head 9ccc7b4 待 merge\n{self.SEP}"
        with mock.patch.object(reaper, "pane_state", lambda pane: {"screen": self.screen, "cx": 30, "cy": 1}):
            self.assertEqual(self.run_once(["owed-step:#1"]), [])
        for text in (reaper.MENU_TEXT, *reaper.DIALOG_TEXT):
            self.screen = f"{self.SEP}\n❯ \n{self.SEP}\n{text}"
            self.assertEqual(self.run_once(["owed-step:#1"]), [], text)

    def test_off_by_default(self):
        self.cfg["NUDGE_EVENTS"] = ""
        self.assertEqual(self.run_once(["owed-step:#1"]), [])
        self.assertEqual(self.events(), [])


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


REPO = "theQuert/stima-api"
STOP6432 = ("delivery #5630: reviewed (backend) -> stop no-production-authority  [d]\n"
            "  stop: no-production-authority (reported)\n  BLOCKED:#6432 main allowed_signers trusts only retired keys")


class ShadowVerdict(unittest.TestCase):
    """#6477: `would-close` and `blocked: #N` are report-only views of a session decide() keeps."""

    def view(self, briefs=None, wt_problems=(), now=NOW0, force_keep=None, **kw):
        briefs = briefs or {}
        s = session(**dict(dict(last_text="", cwd="/work/x"), **kw))
        s.setdefault("other_sids", [])
        with mock.patch.object(reaper, "oracle_brief", side_effect=lambda r, n, c, at: briefs.get(n)), \
             mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "worktree_state",
                               side_effect=lambda w, c: list(wt_problems) + w.get("problems", [])):
            keep = reaper.decide(s, CFG, now)
            return keep, reaper.shadow_verdict(s, CFG, force_keep or keep, now)

    SEC_P1 = ("Merged the authorization fix. No open scope: the reaper can close this session.")

    def test_sec_p1_like_session_without_a_worktree_would_close(self):
        keep, v = self.view(last_text=self.SEC_P1, name="sec-p1", tmux="sec-p1")
        self.assertEqual(keep, ["waiting", "claim-unknown"])
        self.assertEqual(v["would_close"], "no claim, close line")

    def test_openlux_like_session_would_close_and_names_no_issue(self):
        keep, v = self.view(last_text="OpenLux supply approved by the founder.\nIDLE-no-scope", name="openlux-supply",
                            tmux="openlux-supply")
        self.assertEqual(v["would_close"], "no claim, close line")
        self.assertEqual(v["blocked"], [])

    def test_all_ended_worktree_claims_with_a_waiting_keyword_would_close(self):
        keep, v = self.view({"9": ENDED}, last_text="PR approved, merged.", claims=[(REPO, "9")])
        self.assertEqual(keep, ["waiting-keyword"])
        self.assertEqual(v["would_close"], "all claims ended")

    def test_a_claim_the_oracle_names_to_this_session_is_found_and_keeps_it(self):
        # no worktree: the claim only exists as `claimant: claude session sid-1` on the issue the text names
        keep, v = self.view({"6200": MINE}, last_text=self.SEC_P1 + " Follow-up in #6200.")
        self.assertEqual(v["claims"], [(REPO, "6200")])
        self.assertEqual(v["would_close"], "")

    def test_an_issue_claimed_by_another_session_is_not_this_sessions_claim(self):
        keep, v = self.view({"6200": OTHER}, last_text=self.SEC_P1 + " See #6200.")
        self.assertEqual(v["claims"], [])
        self.assertEqual(v["would_close"], "no claim, close line")

    def test_an_owed_or_unknown_claim_is_never_would_close(self):
        for brief in (MINE, None):
            with self.subTest(brief):
                _, v = self.view({"9": brief}, last_text="approved and merged", claims=[(REPO, "9")])
                self.assertEqual(v["would_close"], "")

    def test_one_ended_claim_beside_an_owed_one_is_not_would_close(self):
        # force_keep isolates the claim rule: decide() would add owed-step:#10 and end the question earlier
        _, v = self.view({"9": ENDED, "10": MINE}, last_text="approved and merged", claims=[(REPO, "9"), (REPO, "10")],
                         force_keep=["waiting-keyword"])
        self.assertEqual(v["would_close"], "")

    def test_the_report_row_carries_blocked_and_would_close(self):
        s = session(pid=1, descendants=0, blocked=["6432", "5630"], would_close="")
        self.assertIn("waiting, blocked: #6432, blocked: #5630 |", reaper.report_line(s, ["waiting"], "keep"))
        s["would_close"] = "no claim, close line"
        self.assertIn("would-close: no claim, close line", reaper.report_line(s, ["claim-unknown"], "would-close"))

    def test_auth_audit_like_session_is_kept_blocked_on_6432(self):
        keep, v = self.view(last_text="Waiting for authorization. BLOCKED:#6432", name="auth-audit", tmux="auth-audit")
        self.assertEqual(keep, ["waiting", "claim-unknown"])
        self.assertEqual(v["blocked"], ["6432"])
        self.assertEqual(v["would_close"], "")

    def test_release_owner_like_session_with_a_background_shell_is_kept_blocked(self):
        keep, v = self.view(last_text="No open scope. BLOCKED:#6432 until the signers are fixed.", bg_shells=[77])
        self.assertIn("shell-child", keep)
        self.assertEqual((v["would_close"], v["blocked"]), ("", ["6432"]))

    def test_a_claims_oracle_stop_names_the_blocking_issue_and_is_a_person_step(self):
        keep, v = self.view({"5630": STOP6432}, last_text="staged; needs authorization", claims=[(REPO, "5630")])
        self.assertIn("waiting", keep)  # a person step: the keyword still counts
        self.assertEqual((v["would_close"], v["blocked"]), ("", ["6432"]))

    def test_the_waiting_keyword_is_only_a_hint_without_a_person_step(self):
        keep, _ = self.view({"9": MINE}, last_text="needs approval", claims=[(REPO, "9")], status="busy")
        self.assertEqual(keep, ["status:busy", "waiting-keyword", "issue-open:#9"])
        keep, _ = self.view({"9": MINE}, last_text="needs approval", claims=[])
        self.assertIn("waiting", keep)

    def test_a_question_to_a_person_is_still_waiting_with_claims(self):
        keep, v = self.view({"9": ENDED}, last_text="all done", claims=[(REPO, "9")], asking=True)
        self.assertEqual(keep, ["waiting"])
        self.assertEqual(v["would_close"], "")

    def test_uncommitted_or_unpushed_work_is_never_would_close(self):
        for kw, probs in ((dict(owned=[{"path": Path("/w/a"), "problems": ["uncommitted:a"]}]), ()),
                          (dict(owned=[{"path": Path("/w/a"), "problems": ["unpushed:a"]}]), ()),
                          (dict(), ["uncommitted:x"])):  # the cwd itself is dirty, no worktree owned
            with self.subTest(kw=kw, cwd_problems=probs):
                _, v = self.view(last_text=self.SEC_P1, wt_problems=probs, **kw)
                self.assertEqual(v["would_close"], "")

    def test_no_other_gate_is_overridden(self):
        cases = {"background child": dict(bg_shells=[1]), "not idle long enough": dict(idle_min=30),
                 "busy": dict(status="busy"), "protected": dict(tmux="keep-me"), "uiux": dict(tmux="uiux-1"),
                 "homepage by name": dict(name="Homepage"), "subagent": dict(sub_active=2),
                 "loop": dict(loop=True), "scheduled": dict(crons=1), "prompt": dict(screen_tail="do you want to proceed"),
                 "relay": dict(relay_pending=["9"])}
        for label, kw in cases.items():
            with self.subTest(label):
                _, v = self.view(last_text=self.SEC_P1, **kw)
                self.assertEqual(v["would_close"], "")

    def test_the_verdict_itself_refuses_a_background_child_whatever_the_keep_list_says(self):
        _, v = self.view(last_text=self.SEC_P1, bg_shells=[1], force_keep=["waiting"])
        self.assertEqual(v["would_close"], "")

    def test_a_kept_session_without_a_close_line_is_not_would_close(self):
        _, v = self.view(last_text="I am waiting for your approval of the plan.")
        self.assertEqual(v["would_close"], "")


    def test_progress_or_conditional_wording_is_not_a_close_line(self):
        for text in ("Done with step 1. Waiting for Leo to approve the payment.",
                     "done: patch staged, needs authorization",
                     "The PR can be closed once Leo approves",
                     "Nothing left for me until you approve"):
            with self.subTest(text):
                _, v = self.view(last_text=text)
                self.assertEqual(v["would_close"], "")

    def test_the_named_issue_lookups_run_only_for_a_candidate(self):
        calls = []
        with mock.patch.object(reaper, "oracle_claims", side_effect=lambda *a: calls.append(1) or []):
            self.view(last_text=self.SEC_P1 + " See #6200.", bg_shells=[1])
            self.assertEqual(calls, [])
            self.view(last_text=self.SEC_P1 + " See #6200.")
            self.assertEqual(calls, [1])

class SkippedAndApply(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / "sessions").mkdir()
        self.cfgfile = self.tmp / "conf"
        self.cfgfile.write_text(f"APPLY=1\nDONE_INBOX=\nREPORT={self.tmp / 'report.md'}\nREAPED_DIR={self.tmp / 'reaped'}\n"
                                f"IDLE_LIST_HOURS=0\n")

    def write(self, fname, **d):
        (self.tmp / "sessions" / f"{fname}.json").write_text(json.dumps(d))

    def test_every_live_session_gather_does_not_return_is_listed_with_its_reason(self):
        table = {10: (1, "A", "claude"), 11: (1, "B", "claude"), 12: (1, "C", "claude"), 13: (1, "D", "claude")}
        self.write("a", kind="interactive", tmux="%1", pid=10, procStart="WRONG", sessionId="aaaaaaaa11", name="auth-audit")
        self.write("b", kind="background", pid=11, sessionId="bbbbbbbb22")
        self.write("c", kind="interactive", pid=12, procStart="C", sessionId="cccccccc33")
        self.write("d", kind="interactive", tmux="%4", pid=13, procStart="D", sessionId="dddddddd44")
        self.write("e", kind="interactive", tmux="%5", pid=99, procStart="E", sessionId="eeeeeeee55")
        with mock.patch.object(reaper, "SESSIONS_DIR", self.tmp / "sessions"), \
             mock.patch.object(reaper, "ps_table", return_value=table), \
             mock.patch.object(reaper, "worktrees", return_value=[]), \
             mock.patch.object(reaper, "pane_state", return_value=None):
            self.assertEqual(reaper.gather(CFG, time.time()), [])
        got = {label.split("pid=")[1]: (why, live) for label, why, live in reaper.SKIPPED}
        self.assertEqual(got, {"10": ("procstart-mismatch", True), "11": ("kind:background", True),
                               "12": ("no-tmux-field", True), "13": ("pane-missing:%4", True), "99": ("pid-gone", False)})
        self.assertIn("auth-audit", [l for l, _, _ in reaper.SKIPPED][0])

    def test_the_report_lists_skipped_live_sessions_and_counts_dead_files(self):
        reaper.SKIPPED[:] = [("auth-audit tmux=%1 sid=aaaaaaaa pid=10", "procstart-mismatch", True),
                             ("old sid=zz pid=99", "pid-gone", False)]
        with mock.patch.object(reaper, "HOME", self.tmp), mock.patch.object(reaper, "gather", return_value=[]), \
             mock.patch.object(reaper, "recover_exiting", return_value=[]), \
             mock.patch.object(reaper, "alert"):
            reaper.main(["--config", str(self.cfgfile)])
        report = (self.tmp / "report.md").read_text()
        self.assertIn("- auth-audit tmux=%1 sid=aaaaaaaa pid=10: procstart-mismatch", report)
        self.assertNotIn("old sid=zz", report)
        self.assertIn("(1 session files with no live process not listed)", report)

    def test_apply_reports_would_close_and_closes_nothing(self):
        s = session(pid=5, start="S", file="f", status_at=1, cwd="/w", pane="%1", session_id="$1", descendants=0, fg=True,
                    last_text="Authorization fix merged. No open scope: the reaper can close this session.", name="sec-p1", tmux="sec-p1",
                    sid="abcdef0123", sub_active=0, relay_pending=[], screen_tail="")
        boom = AssertionError("closed a would-close session")
        with mock.patch.object(reaper, "HOME", self.tmp), mock.patch.object(reaper, "gather", return_value=[s]), \
             mock.patch.object(reaper, "recover_exiting", return_value=[]), \
             mock.patch.object(reaper, "worktree_state", return_value=[]), \
             mock.patch.object(reaper, "reap", side_effect=boom) as reap, \
             mock.patch.object(reaper, "tmux", side_effect=boom), mock.patch.object(reaper, "write_record", side_effect=boom), \
             mock.patch.object(reaper, "alert") as alert:
            rc = reaper.main(["--config", str(self.cfgfile), "--apply"])
        self.assertEqual(rc, 0)
        reap.assert_not_called()
        alert.assert_not_called()
        row = [l for l in (self.tmp / "report.md").read_text().splitlines() if l.startswith("| sec-p1")][0]
        self.assertIn("| would-close |", row)
        self.assertIn("would-close: no claim, close line", row)
        self.assertEqual(reaper.decide(s, CFG, NOW0), ["waiting", "claim-unknown"])  # decide() itself still keeps it



class NoClaimDone(unittest.TestCase):
    """EL-T24: a claim-less session whose newest inbox header is DONE is `would-close` under NOCLAIM_DONE=shadow and
    done under NOCLAIM_DONE=apply; every other gate still keeps it."""
    NOW = reaper.calendar.timegm((2026, 10, 25, 14, 0, 0, 0, 0, 0))  # 22:00 TPE
    PROMPT = reaper.calendar.timegm((2026, 10, 25, 11, 30, 0, 0, 0, 0))  # 19:30 TPE

    def setUp(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        self.inbox = Path(d) / "neo-inbox.md"
        self.write("K1 DONE · 2026-10-25 20:00 TPE · dispatch")
        self.wt = []
        self.briefs = {}

    def write(self, *headers):
        self.inbox.write_text("# inbox\n\nbody\n" + "\n".join(f"## {h}\n\ntext\n" for h in headers))

    def run_decide(self, mode="shadow", cfg=None, **kw):
        base = dict(name="dispatch", tmux="dispatch", last_text="Reported the result to the inbox.", claims=[],
                    owned=[], cwd="/w/primary", descendants=0, prompt_at=self.PROMPT)
        s = session(**dict(base, **kw))
        s.setdefault("other_sids", [])
        cfg = dict(dict(CFG, DONE_INBOX="", DONE_INBOX_SHADOW=str(self.inbox), NOCLAIM_DONE=mode), **(cfg or {}))
        with mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: list(self.wt) + w.get("problems", [])), \
             mock.patch.object(reaper, "oracle_brief", side_effect=lambda r, n, c, at: self.briefs.get(n)), \
             mock.patch.object(reaper, "issue_state", return_value="OPEN"):
            keep = reaper.decide(s, cfg, self.NOW)
            verdict = reaper.shadow_verdict(s, cfg, keep, self.NOW) if keep else None
        return keep, s, verdict

    def test_shadow_marks_would_close_and_keeps_the_session(self):
        keep, s, _ = self.run_decide()
        self.assertEqual(keep, ["claim-unknown"])
        self.assertEqual(s["noclaim_done_shadow"], "inbox K1 DONE")
        line = reaper.report_line(dict(s, pid=1, claim_why="no-worktree"), keep, "would-close")
        self.assertIn("| would-close | claim-unknown(no-worktree), would-close: no claim, inbox K1 DONE (shadow) |", line)

    def test_shadow_is_the_default(self):
        self.assertEqual(reaper.DEFAULTS["NOCLAIM_DONE"], "shadow")

    def test_apply_counts_it_as_done(self):
        keep, s, _ = self.run_decide(mode="apply")
        self.assertEqual(keep, [])
        self.assertEqual(s["noclaim_done"], "inbox K1 DONE")

    def test_off_does_neither(self):
        keep, s, _ = self.run_decide(mode="off")
        self.assertEqual(keep, ["claim-unknown"])
        self.assertNotIn("noclaim_done_shadow", s)

    def test_the_live_inbox_path_wins_over_the_shadow_path(self):
        other = self.inbox.with_name("other.md")
        other.write_text("## K9 ACK · 2026-10-25 20:30 TPE · dispatch\n")
        keep, s, _ = self.run_decide(mode="apply", cfg=dict(DONE_INBOX=str(other)))
        self.assertEqual(keep, ["claim-unknown"])

    def test_each_gate_still_keeps_it(self):
        cases = {
            "live child process": dict(descendants=2),
            "unknown child count": dict(descendants=None),
            "background shell": dict(bg_shells=[9]),
            "loop": dict(loop=True),
            "cron": dict(crons=1),
            "scheduled": dict(scheduled=True),
            "protected": dict(tmux="keep-me"),
            "never-close name": dict(tmux="uiux-2", name="uiux-2"),
            "waiting on a person": dict(last_text="Staged; needs Leo's approval."),
            "question": dict(asking=True),
            "busy": dict(status="busy"),
            "idle too short": dict(idle_min=30),
            "unpushed owned worktree": dict(owned=[{"path": Path("/w/a"), "problems": ["unpushed:a"], "marker": ""}]),
            "never-kill": dict(never_kill=[70987]),
            "no prompt time": dict(prompt_at=0),
            "a prompt after the DONE": dict(prompt_at=reaper.calendar.timegm((2026, 10, 25, 12, 30, 0, 0, 0, 0))),
            "a worktree claim": dict(claims=[("o/r", "2")]),
        }
        for label, kw in cases.items():
            with self.subTest(label):
                keep, s, v = self.run_decide(**kw)
                self.assertTrue(keep)
                self.assertFalse(s.get("noclaim_done_shadow"))
                self.assertEqual((v or {}).get("would_close", ""), "")
                keep, s, _ = self.run_decide(mode="apply", **kw)
                self.assertTrue(keep, label)

    def test_a_dirty_cwd_keeps_it(self):
        self.wt = ["uncommitted:primary"]
        keep, s, _ = self.run_decide(mode="apply")
        self.assertIn("claim-unknown", keep)
        keep, s, _ = self.run_decide()
        self.assertFalse(s.get("noclaim_done_shadow"))

    def test_the_inbox_header_must_be_done_old_enough_and_this_sessions(self):
        for headers in (["K1 DONE · 2026-10-25 21:30 TPE · dispatch"],  # younger than IDLE_MINUTES
                        ["K1 DONE · 2026-10-25 20:00 TPE · dispatch", "K2 ACK · 2026-10-25 20:10 TPE · dispatch"],
                        ["K1 DONE · 2026-10-25 20:00 TPE · other"],
                        ["K1 PROGRESS · 2026-10-25 20:00 TPE · dispatch"]):
            with self.subTest(headers):
                self.write(*headers)
                keep, s, _ = self.run_decide(mode="apply")
                self.assertEqual(keep, ["claim-unknown"])
        self.inbox.unlink()
        self.assertEqual(self.run_decide(mode="apply")[0], ["claim-unknown"])

    def test_a_prompt_in_the_minute_of_the_header_keeps_it(self):
        keep, _, _ = self.run_decide(mode="apply", prompt_at=reaper.calendar.timegm((2026, 10, 25, 12, 0, 40, 0, 0, 0)))
        self.assertEqual(keep, ["claim-unknown"])

    def test_an_issue_its_text_names_with_this_session_as_claimant_keeps_it(self):
        self.briefs = {"6200": MINE.replace("#9", "#6200")}
        keep, s, _ = self.run_decide(mode="apply", last_text="Follow-up in #6200.")
        self.assertEqual(keep, ["claim-unknown"])
        self.briefs = {"6200": OTHER}
        keep, s, _ = self.run_decide(mode="apply", last_text="Follow-up in #6200.")
        self.assertEqual(keep, [])

    def test_sweep_reports_would_close_and_closes_nothing_in_shadow_then_closes_on_apply(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        s = session(pid=5, start="S", file="f", status_at=1, cwd="/w", pane="%1", session_id="$1", descendants=0,
                    fg=True, last_text="Reported.", name="dispatch", tmux="dispatch", sid="abcdef0123", sub_active=0,
                    relay_pending=[], screen_tail="", prompt_at=self.PROMPT, claim_why="no-worktree")
        for mode, reaped in (("shadow", False), ("apply", True)):
            with self.subTest(mode):
                cfgfile = tmp / "conf"
                cfgfile.write_text(f"APPLY=1\nDONE_INBOX=\nDONE_INBOX_SHADOW={self.inbox}\nNOCLAIM_DONE={mode}\n"
                                   f"REPORT={tmp / 'report.md'}\nREAPED_DIR={tmp / 'reaped'}\nIDLE_LIST_HOURS=0\n"
                                   f"STALL_MARK_DIR=\n")
                with mock.patch.object(reaper, "HOME", tmp), mock.patch.object(reaper, "gather", return_value=[dict(s)]), \
                     mock.patch.object(reaper, "recover_exiting", return_value=[]), \
                     mock.patch.object(reaper, "worktree_state", return_value=[]), \
                     mock.patch.object(reaper, "time") as fake_time, \
                     mock.patch.object(reaper, "reap", return_value=("skipped:prompt-not-empty", [])) as reap, \
                     mock.patch.object(reaper, "alert"):
                    fake_time.time.return_value = self.NOW
                    fake_time.monotonic.side_effect = time.monotonic
                    fake_time.strftime.side_effect = time.strftime
                    fake_time.localtime.side_effect = time.localtime
                    reaper.main(["--config", str(cfgfile)])
                self.assertEqual(reap.called, reaped)
                row = [l for l in (tmp / "report.md").read_text().splitlines() if l.startswith("| dispatch")][0]
                if reaped:
                    self.assertIn("| skipped:prompt-not-empty |", row)
                else:
                    self.assertIn("| would-close | claim-unknown(no-worktree), would-close: no claim, inbox K1 DONE (shadow)", row)


class ClaimWhy(unittest.TestCase):
    def test_each_reason(self):
        wt = lambda name, branch: {"path": Path("/w") / name, "branch": branch}
        self.assertEqual(reaper.claim_why([], []), "no-worktree")
        self.assertEqual(reaper.claim_why([wt("a", "feat/t24-x"), wt("b", "chore/sync")], ["", ""]),
                         "no-issue-branch:a,b")
        self.assertEqual(reaper.claim_why([wt("a", "fix/6655-x")], [""]), "no-github-remote")

    def test_the_report_names_the_reason_and_keeps_the_keep_reason(self):
        s = session(pid=1, descendants=0, claim_why="no-worktree")
        line = reaper.report_line(s, ["waiting", "claim-unknown"], "keep")
        self.assertIn("| keep | waiting, claim-unknown(no-worktree) |", line)
        self.assertIn("claim-unknown", reaper.decide(session(last_text="all good"), CFG))


class NeverKill(unittest.TestCase):
    TABLE = {1: (0, "x", "launchd"), 50: (1, "x", "tmux"), 100: (50, "x", "-zsh"), 10: (100, "A", "claude"),
             11: (10, "B", "node mcp"), 12: (11, "C", "sleep"), 13: (100, "D", "tail -f"), 60: (50, "x", "-zsh")}

    def test_pids_come_from_the_environment_else_the_config(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CC_NEVER_KILL_PIDS", None)
            self.assertEqual(reaper.never_kill_pids(CFG), {70987, 4565})
            self.assertEqual(reaper.never_kill_pids(dict(CFG, CC_NEVER_KILL_PIDS="7, 8 x9")), {7, 8})
        with mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": "12"}):
            self.assertEqual(reaper.never_kill_pids(CFG), {12})
        with mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": ""}):
            self.assertEqual(reaper.never_kill_pids(CFG), set())
        err = io.StringIO()
        with mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": "7;8 \u00b2 9"}), redirect_stderr(err):
            self.assertEqual(reaper.never_kill_pids(CFG), {9})  # no ValueError on a non-ASCII digit
        self.assertIn("not a pid, ignored: 7;8 \u00b2", err.getvalue())

    def test_the_tree_is_the_pane_and_everything_below_it_never_the_server_or_another_pane(self):
        tree = reaper.session_tree(self.TABLE, 100, 10)
        self.assertEqual(tree, {100, 10, 11, 12, 13})
        with mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": "12 60 50"}):
            self.assertEqual(reaper.never_kill_hit(self.TABLE, 100, 10, CFG), [12])

    def gathered(self, pids):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "sessions").mkdir()
        (tmp / "sessions" / "a.json").write_text(json.dumps(dict(
            kind="interactive", tmux="%1", pid=10, procStart="A", sessionId="sid-1", name="dispatch", status="idle",
            statusUpdatedAt=(time.time() - 7200) * 1000, cwd="/w/primary")))
        state = {"session": "dispatch", "session_id": "$1", "pane_pid": 100, "cx": 2, "cy": 0, "alone": True,
                 "screen": "❯ "}
        with mock.patch.object(reaper, "SESSIONS_DIR", tmp / "sessions"), \
             mock.patch.object(reaper, "ps_table", return_value=self.TABLE), \
             mock.patch.object(reaper, "worktrees", return_value=[]), \
             mock.patch.object(reaper, "pane_state", return_value=state), \
             mock.patch.object(reaper, "foreground", return_value=True), \
             mock.patch.object(reaper, "transcript_path", return_value=None), \
             mock.patch.object(reaper, "subagent_activity", return_value=0), \
             mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": pids}):
            return reaper.gather(CFG, time.time())[0]

    def test_gather_names_the_never_kill_pid_and_the_missing_claim_and_decide_keeps_it(self):
        s = self.gathered("12")
        self.assertEqual((s["never_kill"], s["claim_why"]), ([12], "no-worktree"))
        s["last_text"] = "SESSION-DONE: shipped"  # done, idle, clean: only the never-kill pid keeps it
        with mock.patch.object(reaper, "worktree_state", return_value=[]):
            keep = reaper.decide(s, CFG)
        self.assertEqual(keep, ["never-kill:12"])
        self.assertEqual(reaper.shadow_verdict(s, CFG, keep, time.time())["would_close"], "")
        s = self.gathered("60 50")  # another pane, the tmux server: not this session's tree
        self.assertEqual(s["never_kill"], [])

    def reap(self, pids):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        f = d / "1.json"
        f.write_text(json.dumps({"status": "idle", "statusUpdatedAt": 1000}))
        s = {"file": str(f), "status_at": 1000, "pid": 10, "start": "A", "pane": "%1", "name": "dispatch"}
        state = {"session": "dispatch", "session_id": "$1", "pane_pid": 100, "cx": 2, "cy": 0, "alone": True,
                 "screen": "❯ "}
        with mock.patch.object(reaper, "ps_table", return_value=self.TABLE), \
             mock.patch.object(reaper, "foreground", return_value=True), \
             mock.patch.object(reaper, "pane_state", return_value=state), \
             mock.patch.object(reaper, "write_record", side_effect=AssertionError("record written")), \
             mock.patch.object(reaper, "tmux", side_effect=AssertionError("typed into the pane")) as tmux, \
             mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": pids}):
            return reaper.reap(s, CFG, 0), tmux

    def test_reap_rechecks_and_never_types_into_a_pane_holding_a_never_kill_pid(self):
        (outcome, tmux) = self.reap("13")
        self.assertEqual(outcome, ("skipped:never-kill", []))
        tmux.assert_not_called()

    def test_recovery_leaves_a_pane_holding_a_never_kill_pid_open(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        cfg = dict(CFG, REAPED_DIR=str(d / "reaped"), CLOSED_LOG=str(d / "closed.md"))
        rec = reaper.write_record({"tmux": "work", "name": "work", "sid": "sid-1", "cwd": "/w", "claims": [],
                                   "owned": [], "last_text": "SESSION-DONE: x", "pid": 4242, "start": "t0",
                                   "pane": "%9", "session_id": "$3"}, cfg, 0, "exiting")
        table = {1: (0, "x", "launchd"), 500: (1, "x", "-zsh"), 501: (500, "x", "caffeinate")}
        with mock.patch.object(reaper, "ps_table", return_value=table), \
             mock.patch.object(reaper, "pane_exists", return_value=True), \
             mock.patch.object(reaper, "pane_state", return_value={"session": "work", "session_id": "$3",
                                                                   "alone": True, "pane_pid": 500}), \
             mock.patch.object(reaper, "tmux") as tmux, mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": "501"}):
            reaper.recover_exiting(cfg, 0)
        tmux.assert_not_called()
        self.assertEqual(json.loads(rec.read_text())["status"], "aborted:never-kill")


class Unjudged(unittest.TestCase):
    def test_background_and_pane_missing_sessions_are_unjudged_rows_with_idle_minutes(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "sessions").mkdir()
        now = time.time()
        for fname, d in (("a", dict(kind="bg", pid=11, procStart="B", sessionId="bbbbbbbb22", name="auth-audit",
                                    status="idle", statusUpdatedAt=(now - 1800) * 1000)),
                         ("b", dict(kind="interactive", tmux="ci-2:@309.%309", pid=12, procStart="C",
                                    sessionId="cccccccc33", name="ci-2", status="busy")),
                         ("c", dict(kind="bg", pid=99, sessionId="dddddddd44", name="gone"))):
            (tmp / "sessions" / f"{fname}.json").write_text(json.dumps(d))
        cfgfile = tmp / "conf"
        cfgfile.write_text(f"APPLY=1\nDONE_INBOX=\nREPORT={tmp / 'report.md'}\nIDLE_LIST_HOURS=0\nSTALL_MARK_DIR=\n")
        table = {11: (1, "B", "claude"), 12: (1, "C", "claude")}
        with mock.patch.object(reaper, "HOME", tmp), mock.patch.object(reaper, "SESSIONS_DIR", tmp / "sessions"), \
             mock.patch.object(reaper, "ps_table", return_value=table), \
             mock.patch.object(reaper, "worktrees", return_value=[]), \
             mock.patch.object(reaper, "pane_state", return_value=None), \
             mock.patch.object(reaper, "recover_exiting", return_value=[]), \
             mock.patch.object(reaper, "reap", side_effect=AssertionError("acted on an unjudged session")), \
             mock.patch.object(reaper, "tmux", side_effect=AssertionError("touched tmux")), \
             mock.patch.object(reaper, "alert"):
            self.assertEqual(reaper.main(["--config", str(cfgfile)]), 0)
        report = (tmp / "report.md").read_text()
        self.assertIn("| auth-audit | `bbbbbbbb` | idle 30m | - | unjudged | kind:bg | - | - | pid 11; never acted on |", report)
        self.assertIn("| ci-2 | `cccccccc` | busy ?m | - | unjudged | pane-missing:%309 |", report)
        self.assertIn("- auth-audit sid=bbbbbbbb pid=11: kind:bg (unjudged, idle 30m)", report)
        self.assertNotIn("gone", report)


if __name__ == "__main__":
    unittest.main()
