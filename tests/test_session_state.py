#!/usr/bin/env python3
"""session_state.py (stima-api #7061): one state per session from recorded pane, transcript and oracle samples, the
file readers act on, and how the reaper consumes it (shadow columns, the clean-round counter and its flip)."""

import gc
import importlib.util
import json
import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


reaper = load("session_reaper", ROOT / "shell" / "session-reaper.py")
ss = load("session_state", ROOT / "shell" / "session_state.py")
REAL = json.loads((ROOT / "tests" / "fixtures" / "delivery-state-briefs.json").read_text())
REPO = "theQuert/stima-api"
CFG = dict(reaper.DEFAULTS, IDLE_MINUTES="60", DONE_GRACE_MINUTES="5", STALL_MARK_DIR="",
           CHECKBY_REPO=REPO, PROTECT="keep-*", NEVER_CLOSE="")
NOW = 1_800_000_000.0

# Recorded oracle briefs (delivery_state.py N --brief, stima-api 2026-11-03), trimmed to the lines the judge reads.
STOP_REPORTED = ("delivery #6842: reviewed (backend) -> stop no-production-authority  [55a3e777da574740]\n"
                 "  relay_ask_check judges #6845 NEEDS-RELAY (money): post one ask with the evidence\n"
                 "  stop: no-production-authority (reported)")
STOP_UNREPORTED = ("delivery #6374: pr-open (backend) -> stop same-root-cause-limit  [8602e7efeb294424]\n"
                   "  declared on the issue for this boundary and state\n"
                   "  stop: same-root-cause-limit; post once with <!-- stop:same-root-cause-limit -->")
WAIT_OWNER = ("delivery #6945: merged (backend) -> wait staging-window  [4aead3b97f60c276]\n"
              "  wake: refs/staging-verified/<S> containing 4394114e4567\n"
              "  owner: tech.stima.release-window-driver wakes it; no watcher needed, and the session may end")
WAIT_SCHEDULED = ("delivery #6633: pr-open (frontend) -> wait check-by  [421fc9d7f75665a6]\n"
                  "  then merge-gate: merge-gate completes on 3ac1ecc23859\n"
                  "  check-by scheduled for 2026-11-03T07:23:00Z; the stranded-step dispatcher wakes the session then: "
                  "end the turn.")
AGENT_MINE = ("delivery #7026: staging-verified (backend) -> agent check-by  [112250b17c86a9fd]\n"
              "  check-by 2026-11-03T05:15:00Z: PR #7033 merged.\n"
              "  claimant: claude session sid-1 (full-audits, lead); the step is that session's: hand it over while it "
              "lives (AGENTS.md, Deferred checks)")
AGENT_UNCLAIMED = "delivery #7050: unclaimed -> agent claim  [0000000000000000]\n  claim it first"
CLOSED = "delivery #6000: closed -> none  [aaaaaaaaaaaaaaaa]"
# A pane tail with a confirmation dialog (recorded shape of Claude Code's tool permission prompt).
DIALOG_PANE = " Bash command\n   rm -rf build\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n Esc to cancel"
# A wait whose check-by (ahead of NOW) the oracle says the dispatcher wakes: not the session's step.
WAIT_AHEAD = WAIT_SCHEDULED.replace("6633", "6634").replace("2026-11-03T07:23:00Z", "2027-02-01T08:00:00Z")
# The reviewer's false-claim branches (stima-api #7061 review, finding 1): none names an issue.
FALSE_CLAIM_BRANCHES = ("canary-main-1031", "chore/uiux-sync-1026", "uiux-accept-1029", "claude/prompt-size-403-4389")


def transcript(tmp, text="Merged.\n\nSESSION-DONE: nothing left, #7026 merged"):
    """transcript_facts() of a recorded transcript: a prompt 20 min ago, the reply 10 min ago."""
    path = tmp / "t.jsonl"
    stamp = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))  # noqa: E731
    path.write_text("\n".join(json.dumps(e) for e in [
        {"type": "user", "timestamp": stamp(NOW - 1200), "message": {"content": "ship #7026"}},
        {"type": "assistant", "timestamp": stamp(NOW - 600), "message": {"content": [{"type": "text", "text": text}]}},
    ]) + "\n")
    return reaper.transcript_facts(path, NOW)


def session(**kw):
    s = {"kind": "interactive", "tmux": "work", "name": "work", "sid": "sid-1", "pid": 11, "status": "idle",
         "status_at": 1, "idle_min": 90.0, "bg_shells": [], "loop": False, "crons": 0, "scheduled": False,
         "sub_active": 0, "asking": False, "last_text": "", "text_at": 0, "prompt_at": 0, "screen_tail": "",
         "claims": [], "owned": [], "other_sids": [], "cwd": "/tmp/x", "never_kill": [], "descendants": 0, "fg": True,
         "vim": False}
    s.update(kw)
    return s


def wt(name, problems=(), branch="claude-7026-x", marker="sid-1"):
    return {"repo": Path("/r"), "path": Path("/w") / name, "gitdir": Path("/g") / name, "marker": marker,
            "branch": branch, "problems": list(problems)}


class Judge(unittest.TestCase):
    def judge(self, s, briefs=None, json_by_issue=None, named=(), **cfg):
        briefs = briefs or {}
        with mock.patch.object(reaper, "oracle_brief", side_effect=lambda r, n, c, now: briefs.get(str(n))), \
             mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: list(w.get("problems", []))), \
             mock.patch.object(reaper, "oracle_json", side_effect=lambda r, n, c: (json_by_issue or {}).get(str(n))), \
             mock.patch.object(reaper, "oracle_claims", return_value=list(named)):
            return ss.judge(s, reaper, dict(CFG, **cfg), NOW)

    def test_working(self):
        self.assertEqual(self.judge(session(status="busy"))["state"], "WORKING")
        rec = self.judge(session(claims=[(REPO, "7026")], owned=[wt("a")]), {"7026": AGENT_MINE})
        self.assertEqual((rec["state"], rec["claims"][0]["mine"]), ("WORKING", True))
        self.assertIn("own-step:#7026 agent check-by", rec["reasons"])
        self.assertEqual(self.judge(session(idle_min=20))["reasons"], ["idle:20<60min"])
        self.assertEqual(self.judge(session(bg_shells=[5], sub_active=2))["reasons"], ["shell-child", "subagent-active"])

    def test_never_kill_and_child_processes_are_working(self):
        # finding 6: the dispatcher stops a DONE session, so a never-kill pid or a child process is never DONE
        rec = self.judge(session(kind="bg", name="tracker-x", tmux="tracker-x", never_kill=[4242], descendants=3))
        self.assertEqual((rec["state"], rec["bg_work"]), ("WORKING", ["never-kill:4242", "child-process:3"]))
        self.assertEqual(self.judge(session(descendants=1))["reasons"], ["child-process:1"])
        self.assertEqual(self.judge(session(never_kill=[70987]))["reasons"], ["never-kill:70987"])
        self.assertEqual(self.judge(session())["state"], "DONE")
        # a stop the session has not posted yet is still its step
        self.assertEqual(self.judge(session(claims=[(REPO, "6374")]), {"6374": STOP_UNREPORTED})["state"], "WORKING")

    def test_push_is_only_unpushed_work(self):
        rec = self.judge(session(claims=[(REPO, "6000")], owned=[wt("a", ["unpushed:a"])]), {"6000": CLOSED})
        self.assertEqual((rec["state"], rec["reasons"]), ("PUSH", ["unpushed:a"]))
        self.assertEqual(rec["worktrees"][0], {"path": "/w/a", "branch": "claude-7026-x", "dirty": False,
                                               "unpushed": True, "unchecked": False})

    def test_waiting_person_is_the_oracle_stop_or_a_dialog_never_a_keyword(self):
        rec = self.judge(session(claims=[(REPO, "6842")], owned=[wt("a", ["unpushed:a"])]), {"6842": STOP_REPORTED})
        self.assertEqual(rec["state"], "WAITING_PERSON")
        self.assertEqual(rec["claims"][0]["oracle_step"], "stop no-production-authority")
        self.assertEqual(self.judge(session(screen_tail=DIALOG_PANE))["reasons"], ["dialog"])
        self.assertEqual(self.judge(session(asking=True))["state"], "WAITING_PERSON")
        # "waits on Leo" in the text is not a state: with nothing else open the session is DONE
        self.assertEqual(self.judge(session(last_text="等 Leo 決定，需要授權"))["state"], "DONE")

    def test_unknown(self):
        self.assertEqual(self.judge(session(claims=[(REPO, "1")]))["reasons"], ["oracle-unknown:#1 unread"])
        self.assertEqual(self.judge(session(claims=[(REPO, "7050")]), {"7050": AGENT_UNCLAIMED})["state"], "UNKNOWN")
        other = REAL["real-shape-claimant-other-9004"]  # claimant `other-sid`, which is no live session here
        self.assertEqual(self.judge(session(claims=[(REPO, "9004")]), {"9004": other})["state"], "UNKNOWN")
        live = self.judge(session(claims=[(REPO, "9004")], other_sids=["other-sid"]), {"9004": other})
        self.assertEqual((live["state"], live["claims"][0]["mine"]), ("DONE", False))
        self.assertEqual(self.judge(session(owned=[wt("a", ["unchecked:a"])]))["state"], "UNKNOWN")
        with mock.patch.object(reaper, "worktree_state", side_effect=OSError("boom")):
            rec = ss.judge(session(owned=[wt("a")]), reaper, CFG, NOW)
        self.assertEqual((rec["state"], rec["reasons"]), ("UNKNOWN", ["error:OSError: boom"]))

    def test_done_is_mechanical(self):
        rec = self.judge(session(claims=[(REPO, "6945"), (REPO, "6633")], owned=[wt("a"), wt("b")]),
                         {"6945": WAIT_OWNER, "6633": WAIT_SCHEDULED})
        self.assertEqual(rec["state"], "DONE")
        self.assertEqual([c["mine"] for c in rec["claims"]], [False, False])
        self.assertEqual(self.judge(session())["reasons"], ["no claim", "idle 90>=60min"])
        self.assertEqual(self.judge(session(claims=[(REPO, "6311")]), {"6311": REAL["real-may-end-6311"]})["state"],
                         "DONE")
        # a wait that asks the session to record its check-by is still its step
        self.assertEqual(self.judge(session(claims=[(REPO, "6310")]), {"6310": REAL["real-wait-no-owner-6310"]})["state"],
                         "WORKING")
        # a named issue whose oracle claimant is this session counts as a claim
        rec = self.judge(session(), {"7026": AGENT_MINE}, named=[(REPO, "7026")])
        self.assertEqual((rec["state"], rec["claims"][0]["source"]), ("WORKING", "named"))

    def test_session_done_shortens_the_threshold_only_under_done_grace_apply(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        facts = transcript(tmp)
        # finding 2: the reaper's own idle_threshold(); DONE_GRACE=shadow (and off) keeps IDLE_MINUTES
        for grace in ("shadow", "off"):
            rec = self.judge(session(idle_min=10, **facts), DONE_GRACE=grace)
            self.assertEqual((rec["state"], rec["reasons"], rec["idle_threshold"]), ("WORKING", ["idle:10<60min"], 60.0))
        self.assertEqual(self.judge(session(idle_min=10, **facts), DONE_GRACE="apply")["state"], "DONE")
        self.assertEqual(self.judge(session(idle_min=3, **facts), DONE_GRACE="apply")["reasons"], ["idle:3<5min"])
        # the line does not override anything else
        rec = self.judge(session(idle_min=10, claims=[(REPO, "7026")], **facts), {"7026": AGENT_MINE}, DONE_GRACE="apply")
        self.assertEqual(rec["state"], "WORKING")
        self.assertEqual(self.judge(session(idle_min=10, last_text="SESSION-DONE: x"), DONE_GRACE="apply")["state"],
                         "WORKING")  # no text_at

    def test_background_loop_past_its_due_is_done(self):
        loop = session(kind="bg", name="loop #6837 check-by", tmux="loop #6837 check-by", sid="1be6c43d-bg")
        brief = {"6837": WAIT_OWNER.replace("6945", "6837")}
        past = self.judge(loop, brief, {"6837": {"pending_check_by": "2026-11-03T01:00:00Z"}})
        self.assertEqual((past["state"], past["claims"][0]["source"]), ("DONE", "name"))
        soon = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW + 1800))
        ahead = self.judge(loop, brief, {"6837": {"pending_check_by": soon}})
        self.assertEqual((ahead["state"], ahead["reasons"]), ("WORKING", ["check-by-ahead:#6837 " + soon]))
        self.assertEqual(self.judge(loop, brief, {})["state"], "UNKNOWN")  # the oracle could not say when it is due
        own = self.judge(loop, {"6837": AGENT_MINE.replace("sid-1", "1be6c43d-bg")}, {"6837": {"pending_check_by": ""}})
        self.assertEqual(own["state"], "WORKING")
        self.assertEqual(self.judge(dict(loop, name="merge-velocity wake 1103"))["state"], "DONE")

    def test_check_by_ahead_keeps_a_loop_only_within_its_idle_threshold(self):
        """stima-api#7061: a check-by many hours away holds a live slot and buys nothing (prompt cache TTL is 60 min)."""
        iso = lambda m: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW + m * 60))  # noqa: E731
        loop = session(kind="bg", name="loop #6837 check-by", tmux="loop #6837 check-by", sid="1be6c43d-bg", idle_min=177.0)
        brief = {"6837": WAIT_OWNER.replace("6945", "6837")}
        far = self.judge(loop, brief, {"6837": {"pending_check_by": iso(21 * 60)}})
        self.assertEqual(far["state"], "DONE")
        near = self.judge(loop, brief, {"6837": {"pending_check_by": iso(30)}})
        self.assertEqual((near["state"], near["reasons"]), ("WORKING", ["check-by-ahead:#6837 " + iso(30)]))
        fresh = self.judge(dict(loop, idle_min=20.0), brief, {"6837": {"pending_check_by": iso(21 * 60)}})
        self.assertEqual((fresh["state"], fresh["reasons"][0][:5]), ("WORKING", "idle:"))

    def test_loop_whose_step_belongs_to_another_session_is_done(self):
        """stima-api#7061 follow-up: `loop #6953` idle 274 min held a slot because the claimant (pr-drain) is not it."""
        iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW + 12 * 3600))
        loop = session(kind="bg", name="loop #6953 check-by", tmux="loop #6953 check-by", sid="1be6c43d-bg", idle_min=274.0)
        claim = ("delivery #6953: reviewed (backend) -> agent claim  [0000000000000001]\n"
                 "  claimant: claude session d51d6e58-1082-4130-8943-4a6dc14d588f (pr-drain); the step is that "
                 "session's: hand it over while it lives")
        js = {"6953": {"pending_check_by": iso}}
        rec = self.judge(loop, {"6953": claim}, js)
        self.assertEqual(rec["state"], "DONE")
        self.assertEqual((rec["claims"][0]["mine"], rec["claims"][0]["oracle_step"]), (False, "agent claim"))
        self.assertIn("#6953 agent claim (not its step)", rec["reasons"])
        # claimant is this loop (8-hex prefix or full id): still its step
        mine = claim.replace("d51d6e58-1082-4130-8943-4a6dc14d588f", "1be6c43d-bg")
        self.assertEqual(self.judge(loop, {"6953": mine}, js)["state"], "WORKING")
        # no claimant line: unchanged (unclaimed stays UNKNOWN)
        self.assertEqual(self.judge(loop, {"6953": AGENT_UNCLAIMED}, js)["state"], "UNKNOWN")
        # #6198 shape: a due `agent check-by` served by the loop stays UNKNOWN as before, claimant elsewhere or not
        cb = AGENT_MINE.replace("sid-1 (full-audits, lead)", "fd576cac-1111-2222-3333-444455556666 (ci)")
        self.assertEqual(self.judge(loop, {"6953": cb}, js)["state"], "UNKNOWN")
        # an interactive named claim with a dead claimant is unchanged too
        self.assertEqual(self.judge(session(claims=[(REPO, "6953")]), {"6953": claim})["state"], "UNKNOWN")

    def test_an_interactive_branch_claim_is_unchanged_by_a_far_check_by(self):
        iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW + 21 * 3600))
        s = session(claims=[(REPO, "6837")])
        rec = self.judge(s, {"6837": WAIT_OWNER.replace("6945", "6837")}, {"6837": {"pending_check_by": iso}})
        self.assertEqual((rec["state"], rec["claims"][0]["source"]), ("DONE", "branch"))

    def test_branch_claims_follow_a_slash_never_a_hyphen(self):
        # finding 1: the regex of f9fdaec; a hyphen never starts the number
        for branch, n in (("claude/7023-no-signature", "7023"), ("fix/6945-p3-followups", "6945"),
                          ("claude/6843-helmway-acl", "6843"), ("7061-session-state", "7061")):
            self.assertEqual(reaper.ISSUE_RE.search(branch).group(1), n, branch)
        for branch in (*FALSE_CLAIM_BRANCHES, "claude-7023-no-signature", "ci-6338-relay-same-change-rebind",
                       "t120-org-alert", "claude-compact-busy-queue", "feat/t24-x", "claude-acceptance-bc-20261103"):
            self.assertIsNone(reaper.ISSUE_RE.search(branch), branch)

    def gather(self, branches):
        """gather() over one interactive session that owns a worktree per branch, and one unattached bg loop."""
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "sessions").mkdir()
        (tmp / "sessions" / "11.json").write_text(json.dumps(
            {"kind": "interactive", "pid": 11, "procStart": "A", "sessionId": "sid-1", "tmux": "work:0.%7",
             "status": "idle", "statusUpdatedAt": (NOW - 5400) * 1000, "cwd": "/w/a", "name": "full-audits"}))
        (tmp / "sessions" / "12.json").write_text(json.dumps(
            {"kind": "bg", "pid": 12, "procStart": "B", "sessionId": "1be6c43d-bg", "status": "idle",
             "statusUpdatedAt": (NOW - 19000) * 1000, "cwd": "/tmp", "name": "loop #6837 check-by"}))
        state = dict(session="full-audits", session_id="$1", pane_pid=10, cx=2, cy=0, alone=True, screen="❯ ")
        wts = [dict(wt(f"w{i}", branch=b), path=Path("/w/a") if i == 0 else Path(f"/w/x{i}"))
               for i, b in enumerate(branches)]
        returns = {"ps_table": {10: (1, "P", "-zsh"), 11: (10, "A", "claude"), 12: (1, "B", "claude --bg")},
                   "worktrees": wts, "gh_repo": REPO, "pane_state": state, "foreground": True, "vim_mode": False,
                   "subagent_activity": 0, "transcript_path": None, "attached_pane": None}
        with mock.patch.multiple(reaper, SESSIONS_DIR=tmp / "sessions"), \
             mock.patch.multiple(reaper, **{k: mock.Mock(return_value=v) for k, v in returns.items()}):
            return reaper.gather(CFG, NOW), reaper.gather(CFG, NOW, include_bg=True)

    def test_false_claim_branches_claim_nothing_in_gather(self):
        plain, _ = self.gather(list(FALSE_CLAIM_BRANCHES))
        self.assertEqual([s["claims"] for s in plain], [[]])
        self.assertTrue(plain[0]["claim_why"].startswith("no-issue-branch:"), plain[0]["claim_why"])
        plain, both = self.gather(["claude/7023-no-signature"])
        self.assertEqual([s["claims"] for s in plain], [[(REPO, "7023")]])
        self.assertEqual([s["sid"] for s in both], ["sid-1", "1be6c43d-bg"])
        bg = both[1]
        self.assertEqual((bg["unattached"], bg["pane"], bg["tmux"], bg["fg"]), (True, "", "loop #6837 check-by", False))
        self.assertEqual([why for _, why, _ in reaper.SKIPPED], ["kind:bg"])  # still an unjudged row in the report

    def test_a_bg_loop_is_not_another_live_session_for_an_attached_one(self):
        # finding 8: other_sids from attached sessions only, as before include_bg
        plain, both = self.gather(["claude/6837-x"])
        self.assertEqual((plain[0]["other_sids"], both[0]["other_sids"]), ([], []))
        self.assertEqual(both[0]["other_claims"], set())
        self.assertEqual(both[1]["other_sids"], ["sid-1"])  # the unattached one still sees the attached ones
        # the loop holds #6837: its claimant line must not make the interactive session's claim `ended` (closed)
        brief = AGENT_MINE.replace("7026", "6837").replace("sid-1", "1be6c43d-bg")
        s = dict(both[0], last_text="next I will run the tests", asking=False, loop=False, crons=0, scheduled=False,
                 bg_shells=[], idle_min=90.0)
        with mock.patch.object(reaper, "oracle_brief", return_value=brief), \
             mock.patch.object(reaper, "worktree_state", return_value=[]):
            self.assertEqual(reaper._decide(dict(s), CFG, NOW), ["issue-unknown:#6837"])


class ClaimStepTrailer(unittest.TestCase):
    """claim_step reads the deciding line before the oracle's trailer (stima-api#7061: `loop #3041 check-by` stayed UNKNOWN)."""
    HEAD = ("delivery #9: serving-verified (none) -> wait check-by  [abc]\n  then acceptance: ...\n"
            "  wake: 2026-11-09T01:00:00Z: ...\n")
    OWNER = "  owner: tech.stima.stranded-step-dispatcher wakes it; no watcher needed, and the session may end"
    JUDGE = "\n  judge: none (the session is woken)"
    BOARD = "\nboard: \u672c\u5730\u63a8\u7b97 \u9032\u5ea6 5% (\u968e\u6bb5) \u968e\u6bb5 wait check-by \u958b\u59cb\u5be6\u4f5c \u7121 \u8017\u6642 \u7121"
    RECORD = "  record `check-by 2026-11-09T01:00:00Z` on the issue: the wake is scheduled by that comment"

    def step(self, brief):
        return ss.claim_step(reaper, brief, "sid-x")

    def test_owner_line_then_judge_and_board_ends_the_wait(self):
        self.assertEqual(self.step(self.HEAD + self.OWNER + self.JUDGE + self.BOARD)[1], False)

    def test_owner_line_then_board_only_ends_the_wait(self):
        self.assertEqual(self.step(self.HEAD + self.OWNER + self.BOARD)[1], False)

    def test_owner_line_alone_still_ends_the_wait(self):
        self.assertEqual(self.step(self.HEAD + self.OWNER)[1], False)

    def test_record_check_by_with_a_trailer_is_mine(self):
        self.assertEqual(self.step(self.HEAD + self.RECORD + self.JUDGE + self.BOARD)[1], True)

    def test_free_text_owner_line_mid_brief_ends_nothing(self):
        self.assertIsNone(self.step(self.HEAD + self.OWNER + "\n  some other line" + self.BOARD)[1])


class File(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_write_read_and_staleness(self):
        rec = {"sid": "abcdef12-3456", "state": "DONE", "name": "x"}
        path = ss.write(ss.document([rec], NOW), self.tmp / "s" / "sessions.json")
        doc = ss.read(path, NOW + 60)
        self.assertEqual((doc["counts"]["DONE"], doc["sessions"]), (1, [rec]))
        self.assertIsNone(ss.read(path, NOW + ss.MAX_AGE_SECONDS + 1))
        self.assertIsNone(ss.read(self.tmp / "missing.json", NOW))
        self.assertEqual(ss.lookup(doc, "abcdef12")["state"], "DONE")
        self.assertIsNone(ss.lookup(doc, "abcdef1"))  # under 8 characters
        path.write_text(json.dumps(dict(doc, version=99)))
        self.assertIsNone(ss.read(path, NOW))
        with mock.patch.dict(os.environ, {ss.ENV_FILE: str(self.tmp / "env.json")}):
            self.assertEqual(ss.default_path(self.tmp / "ignored"), self.tmp / "env.json")


    def test_only_the_live_config_writes_the_live_file(self):
        # finding 5: state_file() and the session_state.py CLI
        live_file, live_conf = self.tmp / "live.json", self.tmp / "session-reaper.conf"
        live_conf.write_text("APPLY=1\n")
        copy, own = self.tmp / "copy.conf", self.tmp / "own"
        copy.write_text(f"STATE_DIR={own}\n")
        bare, same = self.tmp / "bare.conf", self.tmp / "same.conf"
        bare.write_text("APPLY=0\n")
        same.write_text(f"STATE_DIR={self.tmp / 'home' / '.cc-reaper' / 'state'}\n")
        with mock.patch.dict(os.environ, {ss.ENV_FILE: str(live_file)}), \
             mock.patch.object(reaper, "CONFIG", live_conf), mock.patch.object(reaper, "HOME", self.tmp / "home"):
            self.assertEqual(reaper.state_file(reaper.load_config(live_conf), True, ss), live_file)
            self.assertEqual(reaper.state_file(reaper.load_config(copy), False, ss), own / "sessions.json")
            self.assertIsNone(reaper.state_file(reaper.load_config(bare), False, ss))
            self.assertIsNone(reaper.state_file(reaper.load_config(same), False, ss))  # its STATE_DIR is the live one
            self.assertTrue(reaper.live_config(str(live_conf)) and not reaper.live_config(str(copy)))
            s = session()
            with mock.patch.object(ss, "load_reaper", return_value=reaper), \
                 mock.patch.object(reaper, "gather", return_value=[s]), mock.patch.object(reaper, "prefetch"), \
                 mock.patch.object(reaper, "oracle_brief", return_value=None), \
                 mock.patch.object(reaper, "oracle_claims", return_value=[]), \
                 mock.patch("sys.stdout"), mock.patch("sys.stderr"):
                self.assertEqual(ss.main(["--config", str(bare)]), 2)
                self.assertEqual(ss.main(["--config", str(copy)]), 0)
                self.assertFalse(live_file.exists())
                # review 2, P3: --out may not point a non-live run at the live file either
                self.assertEqual(ss.main(["--config", str(copy), "--out", str(live_file)]), 2)
                self.assertFalse(live_file.exists())
                self.assertEqual(ss.read(own / "sessions.json", time.time())["counts"]["DONE"], 1)
                self.assertEqual(ss.main(["--config", str(live_conf)]), 0)
                self.assertEqual(ss.read(live_file, time.time())["counts"]["DONE"], 1)


class ReaperConsumes(unittest.TestCase):
    """decide() reads the state through its own STATE_DONE column, and every existing gate still holds."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def state(self, st="DONE", claims=()):
        return {"state": st, "claims": [{"issue": int(n), "repo": REPO, "oracle_step": "wait check-by"}
                                        for n in claims], "reasons": []}

    def done(self, **kw):
        """A session the state calls DONE whose one claim the oracle says is a check-by wait another party wakes
        (see dec()): the oracle's soft `issue-unknown:#6634` is all that keeps it."""
        kw.setdefault("claims", [(REPO, "6634")])
        kw.setdefault("state", self.state(claims=["6634"]))
        kw.setdefault("last_text", "all good")
        return session(prompt_at=NOW - 9000, **kw)

    def dec(self, s, **cfg):
        return self.decide(s, {"6634": WAIT_AHEAD}, bound=True, **cfg)

    def decide(self, s, briefs=None, checkby="UNKNOWN", bound=False, **cfg):
        cfg = dict(CFG, **cfg)
        with mock.patch.object(reaper, "oracle_brief", side_effect=lambda r, n, c, now: (briefs or {}).get(str(n))), \
             mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: list(w.get("problems", []))), \
             mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "checkby_state", return_value=checkby), \
             mock.patch.object(reaper, "oracle_claims", return_value=[]), \
             mock.patch.object(reaper, "wait_bound", return_value=bound):
            return reaper.decide(s, cfg, NOW)

    def test_the_state_has_its_own_column_shadow_by_default(self):
        self.assertEqual(reaper.DEFAULTS["STATE_DONE"], "shadow")
        s = self.done()
        self.assertEqual(self.dec(s), ["issue-unknown:#6634"])
        self.assertEqual(s["state_shadow"], "STATE_DONE")
        self.assertIn("would-close: state DONE (STATE_DONE shadow)", reaper.report_line(dict(s, descendants=0), [], "x"))
        # ORACLE_NOT_MINE=apply does not close on the state: only STATE_DONE does
        s = self.done(last_text="要不要繼續？請確認")  # a waiting keyword keeps it
        self.assertTrue(any(k.startswith("waiting") for k in self.dec(s, ORACLE_NOT_MINE="apply")))
        self.assertNotIn("state_close", s)
        s = self.done()
        self.assertEqual(self.dec(s, STATE_DONE="apply"), [])
        self.assertEqual(s["state_close"], "STATE_DONE")
        s = self.done()
        self.assertEqual(self.dec(s, STATE_DONE="off"), ["issue-unknown:#6634"])
        self.assertNotIn("state_shadow", s)

    def test_a_claim_less_done_session_is_never_released_by_the_state(self):
        """stima-api #7079: the inbox DONE header was the only release for a claim-less session besides its own
        SESSION-DONE line, which decide() reads before the state; with the header gone the state holds it."""
        for mode in ("shadow", "apply"):
            with self.subTest(mode):
                s = self.done(claims=[], state=self.state())
                self.assertEqual(self.decide(s, STATE_DONE=mode), ["claim-unknown"])
                self.assertEqual(s["state_held"], "no-claim")
                self.assertNotIn("state_shadow", s)
                self.assertNotIn("state_close", s)
        self.assertFalse(hasattr(reaper, "noclaim_done"))

    def test_a_claimed_done_session_closes_only_when_claim_class_ends_every_claim(self):
        claimed = dict(session(claims=[(REPO, "6634")]), state=self.state(claims=["6634"]))
        self.assertEqual(self.decide(dict(claimed, state=None), {"6634": WAIT_AHEAD}), ["issue-unknown:#6634"])
        s = dict(claimed)  # the wait's check-by is not bound to this session: claim_class() keeps it
        self.assertEqual(self.decide(s, {"6634": WAIT_AHEAD}, STATE_DONE="apply"), ["issue-unknown:#6634"])
        self.assertEqual(s["state_held"], "claim #6634: unknown")
        s = dict(claimed)
        self.assertEqual(self.decide(s, {"6634": WAIT_AHEAD}, bound=True, STATE_DONE="apply"), [])
        self.assertEqual(s["oracle_not_mine"], {"6634": "state DONE: wait check-by"})  # kept, not released
        s = dict(claimed)  # an unread brief: unknown, kept
        self.assertEqual(self.decide(s, {}, bound=True, STATE_DONE="apply"), ["issue-unknown:#6634"])

    def test_a_question_to_a_person_keeps_a_done_session(self):
        # finding 3: `waiting` and `owed-step:` are not soft for the state
        self.assertFalse(any(k.startswith(reaper.STATE_SOFT) for k in ("waiting", "waiting-keyword", "owed-step:#1")))
        for text in ("要不要我改成 B 方案？等你回覆", "Should I go with option B? 請確認"):
            with self.subTest(text):
                s = self.done(last_text=text)
                keep = self.dec(s, STATE_DONE="apply")
                self.assertTrue(any(k.startswith("waiting") for k in keep), keep)
                self.assertNotIn("state_close", s)
        # the same session judged end to end: the state calls it DONE (it never reads keywords), the reaper keeps it
        s = self.done(last_text="要不要我改成 B 方案？等你回覆", state=None)
        with mock.patch.object(reaper, "oracle_brief", return_value=WAIT_AHEAD), \
             mock.patch.object(reaper, "wait_bound", return_value=True), \
             mock.patch.object(reaper, "oracle_claims", return_value=[]):
            s["state"] = ss.judge(dict(s), reaper, CFG, NOW)
        self.assertEqual(s["state"]["state"], "DONE")
        self.assertTrue(any(k.startswith("waiting") for k in self.dec(s, STATE_DONE="apply")))

    def test_existing_gates_hold_under_state_done_apply(self):
        cases = {"never-close": dict(tmux="uiux-work"),
                 "blocked:#7100": dict(last_text="all good, BLOCKED:#7100 on Leo")}
        for held, kw in cases.items():
            with self.subTest(held):
                s = self.done(**kw)
                self.assertEqual(self.dec(s, STATE_DONE="apply", NEVER_CLOSE="uiux*"), ["issue-unknown:#6634"])
                self.assertEqual((s.get("state_held"), "state_close" in s), (held, False))
        # a claimed stop with a wake line closes only once its check-by is CLEAR
        stop = STOP_REPORTED + "\n  wake: a person answers on the issue"
        claimed = dict(session(claims=[(REPO, "6842")]), state=self.state(claims=["6842"]))
        s = dict(claimed)
        self.assertEqual(self.decide(s, {"6842": stop}, checkby="OPEN", STATE_DONE="apply"), ["issue-unknown:#6842"])
        self.assertEqual(s["state_held"], "claim #6842: unknown")
        s = dict(claimed)
        self.assertEqual(self.decide(s, {"6842": stop}, checkby="CLEAR", STATE_DONE="apply"), [])
        s = dict(claimed, tmux="homepage-x")  # NEVER_CLOSE wins over a claim claim_class() would end
        self.assertEqual(self.decide(s, {"6842": stop}, checkby="CLEAR", STATE_DONE="apply", NEVER_CLOSE="homepage*"),
                         ["issue-unknown:#6842"])
        self.assertEqual(s["state_held"], "never-close")

    def test_the_guards_still_keep(self):
        cases = {"unpushed:a": dict(owned=[wt("a", ["unpushed:a"])]), "protected": dict(tmux="keep-me"),
                 "subagent-active": dict(sub_active=1), "vim-mode": dict(vim=True), "never-kill:7": dict(never_kill=[7]),
                 "kind:bg": dict(kind="bg"), "status:busy": dict(status="busy")}
        for reason, kw in cases.items():
            with self.subTest(reason):
                s = self.done(**kw)
                keep = self.dec(s, STATE_DONE="apply")
                self.assertIn(reason, keep)
                self.assertNotIn("state_close", s)
        s = self.done(state=self.state("PUSH", claims=["6634"]))
        self.assertEqual(self.dec(s, STATE_DONE="apply"), ["issue-unknown:#6634"])

    def test_an_error_in_the_state_gates_keeps_the_session(self):
        s = self.done()
        with mock.patch.object(reaper, "state_gates", side_effect=RuntimeError("boom")):
            self.assertEqual(self.dec(s, STATE_DONE="apply"), ["issue-unknown:#6634"])
        self.assertEqual((s["state_error"], "state_close" in s, "state_shadow" in s), ("RuntimeError: boom", False, False))
        self.assertIn("state error: RuntimeError: boom", reaper.report_line(dict(s, descendants=0), ["claim-unknown"], "x"))
        s = self.done(state={"state": "DONE", "claims": "garbage"})
        self.assertEqual(self.dec(s, STATE_DONE="apply"), ["issue-unknown:#6634"])  # a malformed state record
        self.assertNotIn("state_close", s)


class Rounds(unittest.TestCase):
    """shadow_rounds(): only the live config at APPLY=1 with its own threshold counts, 25+ min apart, per source."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.live = self.tmp / "session-reaper.conf"
        self.live.write_text("APPLY=1\nSTATE_DONE=shadow\nORACLE_NOT_MINE=shadow\n")
        self.sdir = self.tmp / "state"
        self.sdir.mkdir()
        patcher = mock.patch.object(reaper, "CONFIG", self.live)
        patcher.start()
        self.addCleanup(patcher.stop)

    def sweep(self, at, sids=("a1",), source="state_shadow", config=None, status_at=1, override=False):
        conf = config or self.live
        seen = []
        for sid in sids:
            s = session(sid=sid, tmux=f"t-{sid}", status_at=status_at)
            s.update({"state_shadow": "STATE_DONE"} if source == "state_shadow" else {source: {"1": "x"}})
            seen.append((s, ["claim-unknown"], "would-close"))
        return reaper.shadow_rounds(reaper.load_config(conf), str(conf), seen, self.sdir, at, override)

    def counter(self, config=None):
        path = reaper.rounds_path(self.sdir, config or self.live)
        return json.loads(path.read_text()) if path.exists() else None

    def test_same_instant_rounds_do_not_count(self):
        self.sweep(NOW, ("a1", "a2", "a3"))
        for _ in range(6):
            lines = self.sweep(NOW, ("a1", "a2", "a3"))
        self.assertEqual(lines, ["- no shadow round counted: 0 min since the last counted round (needs 25)"])
        lines = self.sweep(NOW + 10 * 60, ("a1", "a2", "a3"))  # a close round: 10 min later
        self.assertEqual(lines, ["- no shadow round counted: 10 min since the last counted round (needs 25)"])
        data = self.counter()
        self.assertEqual((data["STATE_DONE"].get("streak", 0), data["_last_round_at"]), (0, NOW))
        self.assertNotIn("STATE_DONE=apply", self.live.read_text())

    def test_five_spaced_clean_rounds_over_three_sessions_flip_their_own_source_once(self):
        lines = []
        for i in range(6):
            lines = self.sweep(NOW + i * 1800, (f"a{i % 3}",))
        self.assertEqual([x for x in lines if x.startswith("- FLIP")], [f"- FLIP: STATE_DONE=apply written to {self.live} "
                                                                        "after 5 clean rounds"])
        self.assertEqual(reaper.load_config(self.live)["STATE_DONE"], "apply")
        self.assertEqual(reaper.load_config(self.live)["ORACLE_NOT_MINE"], "shadow")  # the other sources are their own
        data = self.counter()
        self.assertEqual((data["STATE_DONE"]["streak"], data["STATE_DONE"]["sessions"]), (5, ["a0", "a1", "a2"]))
        self.assertEqual(data["ORACLE_NOT_MINE"].get("streak", 0), 0)  # no candidate of its own: no round
        self.sweep(NOW + 7 * 1800, ("a0",))
        self.assertEqual(self.live.read_text().count("STATE_DONE=apply"), 1)  # written once

    def test_a_streak_of_one_session_never_flips(self):
        for i in range(8):
            lines = self.sweep(NOW + i * 1800, ("a1",))
        self.assertNotIn("STATE_DONE=apply", self.live.read_text())
        self.assertIn("7/5 clean rounds, 1 distinct sessions (needs 3)", lines[0])

    def test_each_source_counts_only_its_own_candidates(self):
        # finding 9: the #7001 trial's candidates advance ORACLE_NOT_MINE, never STATE_DONE, and the other way round
        for i in range(6):
            self.sweep(NOW + i * 1800, (f"o{i % 3}",), source="oracle_not_mine_shadow")
        cfg = reaper.load_config(self.live)
        self.assertEqual((cfg["ORACLE_NOT_MINE"], cfg["STATE_DONE"]), ("apply", "shadow"))
        data = self.counter()
        self.assertEqual(data["STATE_DONE"].get("streak", 0), 0)
        self.assertNotIn("NOCLAIM_DONE", data)  # #7079: the claim-less inbox source is gone

    def test_a_miss_resets_the_streak_and_its_sessions(self):
        for i in range(4):
            self.sweep(NOW + i * 1800, (f"a{i % 3}", "m1"))
        self.sweep(NOW + 4 * 1800, ("a1", "m1"), status_at=2)  # used after it was called finished
        data = self.counter()["STATE_DONE"]
        self.assertEqual((data["streak"], data["sessions"], len(data["misses"])), (0, [], 1))

    def test_a_copied_config_advances_nothing_and_never_writes_apply(self):
        copy = self.tmp / "copy.conf"
        copy.write_text(self.live.read_text())
        before = self.live.read_text()
        for i in range(8):
            lines = self.sweep(NOW + i * 1800, (f"a{i % 3}",), config=copy)
        self.assertEqual(lines, [f"- no shadow round counted: {copy} is not the live config {self.live}"])
        self.assertEqual((copy.read_text(), self.live.read_text()), (before, before))
        self.assertEqual(list(self.sdir.iterdir()), [])  # no counter, live or keyed by the copy
        self.assertNotEqual(reaper.rounds_path(self.sdir, copy), reaper.rounds_path(self.sdir, self.live))

    def test_apply_0_and_an_idle_override_never_count(self):
        self.live.write_text("APPLY=0\nSTATE_DONE=shadow\n")
        for i in range(8):
            lines = self.sweep(NOW + i * 1800, (f"a{i % 3}",))
        self.assertEqual(lines, ["- no shadow round counted: APPLY is not 1"])
        self.assertNotIn("STATE_DONE=apply", self.live.read_text())
        self.live.write_text("APPLY=1\nSTATE_DONE=shadow\n")
        for i in range(8):
            lines = self.sweep(NOW + i * 1800, (f"a{i % 3}",), override=True)
        self.assertEqual(lines, ["- no shadow round counted: --idle-minutes overrides the threshold"])
        self.assertEqual(list(self.sdir.iterdir()), [])


class Main(unittest.TestCase):
    """main(): which run writes the live sessions.json and the live counter."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.live_file = self.tmp / "live" / "sessions.json"
        self.live = self.tmp / "session-reaper.conf"
        base = (f"REPORT={self.tmp / 'report.md'}\nCC_NEVER_KILL_PIDS=\nDONE_INBOX=\nSTALL_MARK_DIR=\n"
                f"REAPED_DIR={self.tmp / 'reaped'}\nCLOSED_LOG={self.tmp / 'closed.md'}\n")
        self.live.write_text(base + "APPLY=1\n")
        self.copy = self.tmp / "copy.conf"
        self.copy.write_text(base + f"APPLY=0\nSTATE_DIR={self.tmp / 'preview'}\n")
        self.bare_copy = self.tmp / "bare.conf"
        self.bare_copy.write_text(base + "APPLY=0\n")

    def run_main(self, *argv, state_fails=False):
        s = session(last_text="all good", fg=True, file=str(self.tmp / "x.json"), start="A", pane="%1")
        patches = [mock.patch.object(reaper, "HOME", self.tmp), mock.patch.object(reaper, "CONFIG", self.live),
                   mock.patch.object(reaper, "gather", return_value=[s]),
                   mock.patch.object(reaper, "reap", side_effect=AssertionError("a test run never reaps")),
                   mock.patch.object(reaper, "recover_exiting", return_value=[]),
                   mock.patch.object(reaper, "alert"), mock.patch.object(reaper, "oracle_claims", return_value=[]),
                   mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": "", ss.ENV_FILE: str(self.live_file)})]
        if state_fails:
            patches.append(mock.patch.object(reaper, "produce_state", side_effect=RuntimeError("no state")))
        for p in patches:
            p.start()
        try:
            rc = reaper.main(list(argv))
        finally:
            for p in reversed(patches):
                p.stop()
        # main() leaves its lock file to the collector, and a raised side_effect keeps main's frame alive through its
        # traceback: drop the patches and collect, so the next run does not find the lock held
        del patches, p
        gc.collect()
        return rc, (self.tmp / "report.md").read_text()

    def live_counter(self):
        return reaper.rounds_path(self.tmp / ".cc-reaper" / "state", self.live)

    def test_the_live_run_writes_the_live_file_and_counts_a_round(self):
        rc, report = self.run_main("--config", str(self.live))
        self.assertEqual(rc, 0)
        doc = ss.read(self.live_file, time.time())
        self.assertEqual([(x["sid"], x["state"]) for x in doc["sessions"]], [("sid-1", "DONE")])
        self.assertIn("| work | `sid-1` | interactive | idle 90m | DONE | no claim, idle 90>=60min |", report)
        self.assertIn("- STATE_DONE=shadow: 0/5 clean rounds", report)
        self.assertTrue(self.live_counter().exists())

    def test_a_preview_leaves_the_live_file_and_the_live_counter_alone(self):
        rc, report = self.run_main("--config", str(self.copy))
        self.assertEqual(rc, 0)
        self.assertFalse(self.live_file.exists())
        self.assertFalse(self.live_counter().exists())
        self.assertFalse(reaper.rounds_path(self.tmp / "preview", self.copy).exists())
        own = ss.read(self.tmp / "preview" / "sessions.json", time.time())
        self.assertEqual([x["sid"] for x in own["sessions"]], ["sid-1"])
        self.assertIn(f"- no shadow round counted: {self.copy} is not the live config", report)
        # a copy with no STATE_DIR of its own writes no sessions.json anywhere
        rc, report = self.run_main("--config", str(self.bare_copy))
        self.assertFalse(self.live_file.exists())
        self.assertFalse((self.tmp / ".cc-reaper" / "state" / "sessions.json").exists())
        self.assertIn("sessions.json not written", report)
        # the live config with a threshold override is not the live run either
        rc, report = self.run_main("--config", str(self.live), "--idle-minutes", "5")
        self.assertFalse(self.live_file.exists())
        self.assertFalse(self.live_counter().exists())
        self.assertIn("- no shadow round counted: --idle-minutes overrides the threshold", report)

    def test_a_failed_state_counts_no_round(self):
        rc, report = self.run_main("--config", str(self.live), state_fails=True)
        self.assertEqual(rc, 1)  # a failure in the report
        self.assertIn("session state: RuntimeError: no state", report)
        self.assertFalse(self.live_counter().exists())
        self.assertFalse(self.live_file.exists())
        with mock.patch.object(reaper, "load_session_state", return_value=(None, "ImportError: x")):
            rc, report = self.run_main("--config", str(self.live))
        self.assertIn("session_state unavailable (ImportError: x)", report)
        self.assertFalse(self.live_counter().exists())


if __name__ == "__main__":
    unittest.main()
