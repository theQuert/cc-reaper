#!/usr/bin/env python3
"""session_state.py (stima-api #7061): one state per session from recorded pane, transcript and oracle samples, the
file readers act on, and how the reaper consumes it (shadow columns, the clean-round counter and its flip)."""

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
CFG = dict(reaper.DEFAULTS, IDLE_MINUTES="60", DONE_GRACE_MINUTES="5", DONE_INBOX="", STALL_MARK_DIR="",
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


def session(**kw):
    s = {"kind": "interactive", "tmux": "work", "name": "work", "sid": "sid-1", "pid": 11, "status": "idle",
         "status_at": 1, "idle_min": 90.0, "bg_shells": [], "loop": False, "crons": 0, "scheduled": False,
         "sub_active": 0, "asking": False, "last_text": "", "text_at": 0, "prompt_at": 0, "screen_tail": "",
         "claims": [], "owned": [], "other_sids": [], "cwd": "/tmp/x"}
    s.update(kw)
    return s


def wt(name, problems=(), branch="claude-7026-x", marker="sid-1"):
    return {"repo": Path("/r"), "path": Path("/w") / name, "gitdir": Path("/g") / name, "marker": marker,
            "branch": branch, "problems": list(problems)}


class Judge(unittest.TestCase):
    def judge(self, s, briefs=None, json_by_issue=None, named=()):
        briefs = briefs or {}
        with mock.patch.object(reaper, "oracle_brief", side_effect=lambda r, n, c, now: briefs.get(str(n))), \
             mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: list(w.get("problems", []))), \
             mock.patch.object(reaper, "oracle_json", side_effect=lambda r, n, c: (json_by_issue or {}).get(str(n))), \
             mock.patch.object(reaper, "oracle_claims", return_value=list(named)):
            return ss.judge(s, reaper, CFG, NOW)

    def test_working(self):
        self.assertEqual(self.judge(session(status="busy"))["state"], "WORKING")
        rec = self.judge(session(claims=[(REPO, "7026")], owned=[wt("a")]), {"7026": AGENT_MINE})
        self.assertEqual((rec["state"], rec["claims"][0]["mine"]), ("WORKING", True))
        self.assertIn("own-step:#7026 agent check-by", rec["reasons"])
        self.assertEqual(self.judge(session(idle_min=20))["reasons"], ["idle:20<60min"])
        self.assertEqual(self.judge(session(bg_shells=[5], sub_active=2))["reasons"], ["shell-child", "subagent-active"])
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

    def test_session_done_only_shortens_the_threshold(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        transcript = tmp / "t.jsonl"
        stamp = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))  # noqa: E731
        transcript.write_text("\n".join(json.dumps(e) for e in [
            {"type": "user", "timestamp": stamp(NOW - 1200), "message": {"content": "ship #7026"}},
            {"type": "assistant", "timestamp": stamp(NOW - 600),
             "message": {"content": [{"type": "text", "text": "Merged.\n\nSESSION-DONE: nothing left, #7026 merged"}]}},
        ]) + "\n")
        facts = reaper.transcript_facts(transcript, NOW)
        self.assertEqual(self.judge(session(idle_min=10, **facts))["state"], "DONE")
        self.assertEqual(self.judge(session(idle_min=3, **facts))["reasons"], ["idle:3<5min"])
        # the line does not override anything else
        rec = self.judge(session(idle_min=10, claims=[(REPO, "7026")], **facts), {"7026": AGENT_MINE})
        self.assertEqual(rec["state"], "WORKING")
        self.assertEqual(self.judge(session(idle_min=10, last_text="SESSION-DONE: x"))["state"], "WORKING")  # no text_at

    def test_background_loop_past_its_due_is_done(self):
        loop = session(kind="bg", name="loop #6837 check-by", tmux="loop #6837 check-by", sid="1be6c43d-bg")
        brief = {"6837": WAIT_OWNER.replace("6945", "6837")}
        past = self.judge(loop, brief, {"6837": {"pending_check_by": "2026-11-03T01:00:00Z"}})
        self.assertEqual((past["state"], past["claims"][0]["source"]), ("DONE", "name"))
        ahead = self.judge(loop, brief, {"6837": {"pending_check_by": "2027-02-01T08:00:00Z"}})
        self.assertEqual((ahead["state"], ahead["reasons"]), ("WORKING", ["check-by-ahead:#6837 2027-02-01T08:00:00Z"]))
        self.assertEqual(self.judge(loop, brief, {})["state"], "UNKNOWN")  # the oracle could not say when it is due
        own = self.judge(loop, {"6837": AGENT_MINE.replace("sid-1", "1be6c43d-bg")}, {"6837": {"pending_check_by": ""}})
        self.assertEqual(own["state"], "WORKING")
        self.assertEqual(self.judge(dict(loop, name="merge-velocity wake 1103"))["state"], "DONE")

    def test_hyphenated_branch_is_a_claim(self):
        for branch, n in (("claude-7023-no-signature", "7023"), ("fix/6945-p3-followups", "6945"),
                          ("ci-6338-relay-same-change-rebind", "6338"), ("claude/6843-helmway-acl", "6843")):
            self.assertEqual(reaper.ISSUE_RE.search(branch).group(1), n, branch)
        for branch in ("t120-org-alert", "claude-compact-busy-queue", "feat/t24-x", "claude-acceptance-bc-20261103"):
            self.assertIsNone(reaper.ISSUE_RE.search(branch), branch)
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
        w = dict(wt("a", branch="claude-7023-no-signature"), path=Path("/w/a"))
        patches = {"SESSIONS_DIR": tmp / "sessions"}
        returns = {"ps_table": {10: (1, "P", "-zsh"), 11: (10, "A", "claude"), 12: (1, "B", "claude --bg")},
                   "worktrees": [w], "gh_repo": REPO, "pane_state": state, "foreground": True, "vim_mode": False,
                   "subagent_activity": 0, "transcript_path": None, "relay_pending": [], "attached_pane": None}
        with mock.patch.multiple(reaper, **patches), \
             mock.patch.multiple(reaper, **{k: mock.Mock(return_value=v) for k, v in returns.items()}):
            plain = reaper.gather(CFG, NOW)
            both = reaper.gather(CFG, NOW, include_bg=True)
        self.assertEqual([(s["claims"], s["claim_why"]) for s in plain], [([(REPO, "7023")], "")])
        self.assertEqual([s["sid"] for s in both], ["sid-1", "1be6c43d-bg"])
        bg = both[1]
        self.assertEqual((bg["unattached"], bg["pane"], bg["tmux"], bg["fg"]), (True, "", "loop #6837 check-by", False))
        self.assertEqual([why for _, why, _ in reaper.SKIPPED], ["kind:bg"])  # still an unjudged row in the report
        self.assertEqual(both[0]["other_sids"], ["1be6c43d-bg"])


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


class ReaperConsumes(unittest.TestCase):
    def state(self, st="DONE", claims=()):
        return {"state": st, "claims": [{"issue": int(n), "repo": REPO, "oracle_step": "wait staging-window"}
                                        for n in claims], "reasons": []}

    def decide(self, s, **cfg):
        with mock.patch.object(reaper, "oracle_brief", return_value=None), \
             mock.patch.object(reaper, "worktree_state", side_effect=lambda w, c: list(w.get("problems", []))), \
             mock.patch.object(reaper, "issue_state", return_value="OPEN"), \
             mock.patch.object(reaper, "checkby_state", return_value="UNKNOWN"):
            return reaper.decide(s, dict(CFG, **cfg), NOW)

    def test_shadow_marks_and_apply_closes_a_done_session_kept_only_by_soft_reasons(self):
        claimed = session(claims=[(REPO, "6945")], state=self.state(claims=["6945"]))
        self.assertEqual(self.decide(dict(claimed, state=None)), ["issue-unknown:#6945"])
        s = dict(claimed)
        self.assertEqual(self.decide(s), ["issue-unknown:#6945"])
        self.assertEqual(s["state_shadow"], "ORACLE_NOT_MINE")
        self.assertIn("would-close: state DONE (ORACLE_NOT_MINE shadow)", reaper.report_line(dict(s, descendants=0), [], "x"))
        s = dict(claimed)
        self.assertEqual(self.decide(s, ORACLE_NOT_MINE="apply"), [])
        self.assertEqual(s["oracle_not_mine"], {"6945": "state DONE: wait staging-window"})  # kept, not released
        bare = session(last_text="all good", state=self.state())
        self.assertEqual(self.decide(dict(bare)), ["claim-unknown"])
        self.assertEqual(self.decide(dict(bare), NOCLAIM_DONE="apply"), [])

    def test_the_guards_still_keep(self):
        cases = {"unpushed:a": dict(owned=[wt("a", ["unpushed:a"])]), "protected": dict(tmux="keep-me"),
                 "subagent-active": dict(sub_active=1), "vim-mode": dict(vim=True), "never-kill:7": dict(never_kill=[7]),
                 "kind:bg": dict(kind="bg"), "status:busy": dict(status="busy")}
        for reason, kw in cases.items():
            with self.subTest(reason):
                s = session(last_text="all good", state=self.state(), **kw)
                keep = self.decide(s, NOCLAIM_DONE="apply")
                self.assertIn(reason, keep)
                self.assertNotIn("state_close", s)
        s = session(last_text="all good", state=self.state("PUSH"))
        self.assertEqual(self.decide(s, NOCLAIM_DONE="apply"), ["claim-unknown"])

    def test_clean_rounds_flip_the_policy_once_and_a_miss_resets(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        conf = tmp / "session-reaper.conf"
        conf.write_text("APPLY=0\nNOCLAIM_DONE=shadow\n")
        cfg = reaper.load_config(conf)

        def sweep(status="idle", status_at=1):
            s = session(status=status, status_at=status_at, state_shadow="NOCLAIM_DONE")
            return reaper.shadow_rounds(cfg, str(conf), [(s, ["claim-unknown"], "would-close")], tmp, NOW)
        sweep()  # round 0: the first candidates, nothing to check yet
        for _ in range(3):
            sweep()
        sweep(status_at=2)  # it was used after it was called finished: a miss
        data = json.loads((tmp / "state-shadow-rounds.json").read_text())
        self.assertEqual((data["NOCLAIM_DONE"]["streak"], len(data["NOCLAIM_DONE"]["misses"])), (0, 1))
        self.assertNotIn("NOCLAIM_DONE=apply", conf.read_text())
        lines = []
        for _ in range(5):
            lines = sweep(status_at=2)
        self.assertIn("- FLIP: NOCLAIM_DONE=apply written to", lines[-1])
        self.assertEqual(reaper.load_config(conf)["NOCLAIM_DONE"], "apply")
        sweep(status_at=2)
        self.assertEqual(conf.read_text().count("NOCLAIM_DONE=apply"), 1)  # written once
        self.assertEqual(reaper.load_config(conf)["ORACLE_NOT_MINE"], "shadow")  # the other column is its own

    def test_main_writes_the_file_and_the_report_section(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        conf = tmp / "c.conf"
        conf.write_text(f"REPORT={tmp / 'report.md'}\nCC_NEVER_KILL_PIDS=\nDONE_INBOX=\nSTALL_MARK_DIR=\n")
        s = session(last_text="all good", descendants=0, fg=True, file=str(tmp / "x.json"), start="A", pane="%1")
        with mock.patch.object(reaper, "HOME", tmp), mock.patch.object(reaper, "gather", return_value=[s]), \
             mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": ""}):
            self.assertEqual(reaper.main(["--config", str(conf)]), 0)
        doc = ss.read(tmp / ".cc-reaper" / "state" / "sessions.json", time.time())
        self.assertEqual([(x["sid"], x["state"]) for x in doc["sessions"]], [("sid-1", "DONE")])
        report = (tmp / "report.md").read_text()
        self.assertIn("| work | `sid-1` | interactive | idle 90m | DONE | no claim, idle 90>=60min |", report)
        self.assertIn("would-close: state DONE (NOCLAIM_DONE shadow)", report)
        self.assertIn("- NOCLAIM_DONE=shadow: 0/5 clean rounds; candidates now: work;", report)


if __name__ == "__main__":
    unittest.main()
