#!/usr/bin/env python3
"""Isolated tests for stall-watch: each fingerprint on a fixture pane text, a healthy pane stays silent, one report
per event across runs, the hash skip, shadow vs apply, the marks the session reaper shows, and the #5212 wall: the
only tmux calls are display and capture-pane, never send-keys. Every path is a temp path; nothing real is touched."""

import importlib.util
import json
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
INTERRUPT_DRAFT = screen("[Request interrupted by user]", "", typed="continue with")


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


class Fleet:
    """A fake tmux and process table: panes {%id: (tmux name, claude pid, screen spec)}; records every tmux argv."""

    def __init__(self, tmp, panes):
        self.tmp, self.panes, self.calls = tmp, panes, []
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
        if sub == "display":
            return 0, f"{target}\t{name}\t$1\t{100 + 10 * n}\t{cx}\t{cy}\t1\t1\n"
        if sub == "capture-pane":
            return 0, text
        raise AssertionError(f"unexpected tmux {cmd}")


class Runs(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.inbox = self.tmp / "neo-inbox.md"
        self.marks = self.tmp / "stalled"
        self.write_config()

    def write_config(self, apply="1", fleet_min="2"):
        self.cfg = self.tmp / "conf"
        self.cfg.write_text(f"STALL_APPLY={apply}\nSTALL_INBOX={self.inbox}\nSTALL_STATE={self.tmp / 'state.json'}\n"
                            f"STALL_MARK_DIR={self.marks}\nSTALL_FLEET_MIN={fleet_min}\n")

    def start(self, panes):
        self.fleet = Fleet(self.tmp, panes)
        return self.fleet

    def run_once(self, *flags):
        f = self.fleet
        with mock.patch.object(reaper, "SESSIONS_DIR", self.tmp / "sessions"), \
             mock.patch.object(reaper, "ps_table", return_value=f.table), \
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
        self.assertIn("0 stalled", self.printed)

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
        self.assertEqual(len(list(self.marks.glob("*.json"))), 1)  # the mark only ever keeps a session

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
        f = self.start({"%1": ("work", WEEKLY), "%2": ("fine", HEALTHY)})
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
        mark.write_text(json.dumps({"fingerprints": ["weekly-limit", "rate-limit-429"]}))
        self.assertEqual(reaper.decide(dict(s), cfg), ["stalled:weekly-limit,rate-limit-429"])
        old = mark.stat().st_mtime - 13 * 3600
        os.utime(mark, (old, old))
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        mark.write_text("not json")
        os.utime(mark, None)
        self.assertEqual(reaper.decide(dict(s), cfg), [])  # an unreadable mark fails open to the old behavior
        self.assertEqual(reaper.stall_mark(cfg, "../escape"), "")


if __name__ == "__main__":
    unittest.main()
