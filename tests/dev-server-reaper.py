#!/usr/bin/env python3
"""Isolated safety tests for the dev-server reaper: every keep rule, and what it stops."""

import importlib.util
from pathlib import Path
import signal
import time
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[1] / "shell" / "dev-server-reaper.py"
spec = importlib.util.spec_from_file_location("dev_server_reaper", SOURCE)
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)

HOUR = 3600
NOW = time.mktime(time.strptime("Sun Oct  4 12:00:00 2026", "%a %b %d %H:%M:%S %Y"))
OLD = "Tue Sep 29 20:48:04 2026"
NEW = "Sun Oct  4 11:30:00 2026"
WT = Path("/wt/docs-m9")


class ReaperTest(unittest.TestCase):
    def setUp(self):
        self.rows = {}
        self.ports = {}
        self.cwds = {}
        self.worktrees = {WT / "site": WT}
        self.claims = set()
        self.sent = []
        self.claim_calls = []
        for name, fake in (("processes", lambda: dict(self.rows)),
                           ("listening", lambda: dict(self.ports)),
                           ("cwd", lambda pid: self.cwds.get(pid)),
                           ("linked_worktree", lambda path: self.worktrees.get(path)),
                           ("claimed", self.fake_claimed)):
            patcher = mock.patch.object(reaper, name, side_effect=fake)
            patcher.start()
            self.addCleanup(patcher.stop)

    def fake_claimed(self, worktree, janitor):
        self.claim_calls.append(worktree)
        return worktree in self.claims

    def server(self, root, port=8811, ppid=1, lstart=OLD, cmd=None, where=WT / "site", pgid=None):
        """A launcher root, its wrangler child and its workerd grandchild."""
        cmd = cmd or f"npm run preview --port {port} --ip 0.0.0.0"
        pgid = pgid or root
        self.rows[root] = (ppid, pgid, 1000, lstart, cmd)
        self.rows[root + 1] = (root, pgid, 2000, lstart, "node wrangler dev")
        self.rows[root + 2] = (root + 1, pgid, 500000, lstart, "workerd serve --inspector-addr=localhost:9229")
        self.ports[root + 2] = {9229}
        self.cwds[root] = where

    def run_reap(self, apply=True):
        def send(pid, sig):
            self.sent.append((pid, sig))
            if sig == signal.SIGTERM:
                self.rows.pop(pid, None)
        return reaper.reap(apply=apply, min_age=6 * HOUR, grace=0, now=NOW,
                           janitor=Path("/janitor"), send=send, sleep=lambda s: None)

    def terms(self):
        return sorted(p for p, s in self.sent if s == signal.SIGTERM)

    def test_unserved_tree_is_stopped_whole(self):
        self.server(100)
        self.assertEqual(self.run_reap(), (1, 1))
        self.assertEqual(self.terms(), [100, 101, 102])

    def test_duplicates_that_lost_the_bind_all_go_and_the_server_stays(self):
        self.server(100)
        self.server(200)
        self.server(300)
        self.ports[302] = {8811, 9230}
        self.run_reap()
        self.assertEqual(self.terms(), [100, 101, 102, 200, 201, 202])

    def test_report_mode_signals_nothing(self):
        self.server(100)
        self.assertEqual(self.run_reap(apply=False), (0, 1))
        self.assertEqual(self.sent, [])

    def test_a_tree_serving_its_port_is_kept(self):
        self.server(100)
        self.ports[101] = {8811}
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_an_attached_launcher_is_kept(self):
        self.server(100, ppid=55)
        self.rows[55] = (1, 55, 10, OLD, "-zsh")
        self.run_reap()
        self.assertEqual(self.sent, [])

    def test_no_port_on_the_command_line_is_kept(self):
        self.server(100, cmd="node ./node_modules/.bin/react-scripts start")
        self.server(200, cmd="npm run dev")
        self.run_reap()
        self.assertEqual(self.sent, [])

    def test_an_unknown_launcher_is_kept(self):
        self.server(100, cmd="/bin/bash sup.sh --port 8811")
        self.run_reap()
        self.assertEqual(self.sent, [])

    def test_a_young_server_is_kept(self):
        self.server(100, lstart=NEW)
        self.run_reap()
        self.assertEqual(self.sent, [])

    def test_an_agent_in_the_process_group_keeps_it(self):
        self.server(100)
        self.rows[900] = (1, 100, 10, OLD, "/Users/x/.local/bin/claude --resume abc")
        self.run_reap()
        self.assertEqual(self.sent, [])

    def test_a_primary_checkout_is_kept(self):
        self.server(100, where=Path("/repo/primary"))
        self.run_reap()
        self.assertEqual(self.sent, [])

    def test_an_unreadable_cwd_is_kept(self):
        self.server(100)
        del self.cwds[100]
        self.run_reap()
        self.assertEqual(self.sent, [])

    def test_a_claimed_worktree_is_kept(self):
        self.server(100)
        self.claims.add(WT)
        self.run_reap()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.claim_calls, [WT])

    def test_duplicates_ask_the_janitor_once(self):
        self.server(100)
        self.server(200)
        self.run_reap()
        self.assertEqual(self.claim_calls, [WT])

    def test_a_reused_pid_is_not_signalled(self):
        self.server(100)
        original = reaper.processes.side_effect
        calls = []

        def swapped():
            # The scan sees the server; by the time it signals, pid 102 is a new process.
            calls.append(1)
            rows = original()
            if len(calls) > 1:
                rows[102] = (101, 100, 1, NEW, "something else")
            return rows
        reaper.processes.side_effect = swapped
        self.run_reap()
        self.assertNotIn(102, self.terms())

    def test_survivors_of_term_get_kill(self):
        self.server(100)
        reaper.reap(apply=True, min_age=6 * HOUR, grace=0, now=NOW, janitor=Path("/j"),
                    send=lambda pid, sig: self.sent.append((pid, sig)), sleep=lambda s: None)
        self.assertEqual(sorted(p for p, s in self.sent if s == signal.SIGKILL), [100, 101, 102])

    def test_scan_failures_keep_everything(self):
        self.server(100)
        reaper.listening.side_effect = lambda: None
        with self.assertRaises(RuntimeError):
            self.run_reap()
        reaper.listening.side_effect = lambda: dict(self.ports)
        reaper.processes.side_effect = lambda: None
        with self.assertRaises(RuntimeError):
            self.run_reap()
        self.assertEqual(self.sent, [])


class ClaimsTest(unittest.TestCase):
    """The claim probe reads the janitor's --claims output; anything unexpected is a claim."""

    def probe(self, stdout, rc=0, own=None):
        result = mock.Mock(returncode=rc, stdout=stdout)
        env = {"CLAUDE_CODE_SESSION_ID": own} if own else {}
        with mock.patch.object(reaper.subprocess, "run", return_value=result), \
             mock.patch.dict(reaper.os.environ, env, clear=True):
            return reaper.claimed(WT, Path("/janitor"))

    def test_no_live_lines_is_unclaimed(self):
        self.assertFalse(self.probe("CLAIMS session_grace_hours=24\nRECENT\tharness=Claude\tid=a\tcwd=/wt\n"))

    def test_a_live_cwd_or_tool_line_is_a_claim(self):
        self.assertTrue(self.probe("CLAIMS x\nLIVE\tharness=Claude\tid=a\tcwd=/wt/docs-m9\n"))
        self.assertTrue(self.probe("CLAIMS x\nLIVE_TOOL\tharness=Codex\tid=b\tpath=/wt\tscope=x\n"))

    def test_own_session_mentions_do_not_count(self):
        self.assertFalse(self.probe("CLAIMS x\nLIVE_TOOL\tharness=Claude\tid=me\tpath=/wt\tscope=x\n", own="me"))
        self.assertTrue(self.probe("CLAIMS x\nLIVE_TOOL\tharness=Claude\tid=mex\tpath=/wt\tscope=x\n", own="me"))

    def test_failure_or_garbage_is_a_claim(self):
        self.assertTrue(self.probe("", rc=2))
        self.assertTrue(self.probe("ERROR\tharness=Claude\n"))


class PatternTest(unittest.TestCase):
    def test_launchers(self):
        for cmd in ("npm run preview --port 8811 --ip 0.0.0.0", "npm run dev -- --port 3000",
                    "node node_modules/.bin/next dev --webpack --port 4462",
                    "node /x/node_modules/.bin/wrangler dev --port 8787",
                    "node /x/node_modules/.bin/vite --port 5173"):
            self.assertTrue(reaper.LAUNCHER.search(cmd), cmd)
            self.assertTrue(reaper.PORT.search(cmd), cmd)
        for cmd in ("npm run build", "npm run test --port 1", "/bin/bash sup.sh",
                    "node ./node_modules/.bin/react-scripts start"):
            self.assertFalse(reaper.LAUNCHER.search(cmd), cmd)


if __name__ == "__main__":
    unittest.main()
