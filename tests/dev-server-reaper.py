#!/usr/bin/env python3
"""Isolated safety tests for the dev-server reaper: every keep rule, and what it stops."""

import calendar
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
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


class Fixture(unittest.TestCase):
    def setUp(self):
        self.rows = {}
        self.ports = {}
        self.cwds = {}
        self.worktrees = {WT / "site": WT}
        self.claims = set()
        self.connections = {443}
        self.forwarded = set()
        self.short = (False, "")
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.state = Path(temp.name)
        self.sent = []
        self.claim_calls = []
        self.socket_pids = set()
        for name, fake in (("processes", lambda: dict(self.rows)),
                           ("listening", lambda: dict(self.ports)),
                           ("cwd", lambda pid: self.cwds.get(pid)),
                           ("linked_worktree", lambda path: self.worktrees.get(path)),
                           ("connected", lambda: set(self.connections) or None),
                           ("served_ports", lambda: set(self.forwarded)),
                           ("pressure", lambda: self.short),
                           ("claimed", self.fake_claimed),
                           ("sockets", lambda pid: pid in self.socket_pids)):
            patcher = mock.patch.object(reaper, name, side_effect=fake)
            patcher.start()
            self.addCleanup(patcher.stop)

    def fake_claimed(self, worktree, janitor, timeout=900):
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

    def run_reap(self, apply=True, now=NOW):
        def send(pid, sig):
            self.sent.append((pid, sig))
            if sig == signal.SIGTERM:
                self.rows.pop(pid, None)
        return reaper.reap(apply=apply, min_age=6 * HOUR, grace=0, now=now,
                           janitor=Path("/janitor"), send=send, sleep=lambda s: None,
                           state_dir=self.state, idle_hours=12)

    def terms(self):
        return sorted(p for p, s in self.sent if s == signal.SIGTERM)


class ReaperTest(Fixture):
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
        self.server(100, cmd="node ./node_modules/.bin/vite")
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
            # The scan and the recheck see the server; by the time it signals, pid 102 is a
            # new process.
            calls.append(1)
            rows = original()
            if len(calls) > 2:
                rows[102] = (101, 100, 1, NEW, "something else")
            return rows
        reaper.processes.side_effect = swapped
        self.run_reap()
        self.assertNotIn(102, self.terms())

    def test_a_tmux_server_carrying_a_dev_command_is_not_a_launcher(self):
        self.server(100, cmd="tmux new-session -d npm run dev --port 5173")
        self.rows[105] = (100, 105, 10, OLD, "/Users/x/.local/bin/claude")
        self.run_reap()
        self.assertEqual(self.sent, [])

    def test_an_agent_inside_the_tree_keeps_it(self):
        self.server(100)
        self.rows[103] = (100, 103, 10, OLD, "/Users/x/.local/bin/claude --resume abc")
        self.assertEqual(self.run_reap(apply=False), (0, 0))
        self.run_reap()
        self.assertEqual(self.sent, [])

    def test_a_server_that_moved_off_a_taken_port_is_serving(self):
        self.server(100, port=5173)
        self.ports[777] = {5173}
        self.ports[102] = {9229, 5174}
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_server_that_moved_stays_serving_after_its_port_frees(self):
        self.server(100, port=5173)
        self.ports[102] = {9229, 5174}
        self.assertEqual(self.run_reap(), (0, 0))

    def test_a_sibling_holding_the_port_does_not_make_a_duplicate_serving(self):
        self.server(100)
        self.server(200)
        self.ports[202] = {8812, 9230}   # a sibling that moved: its port, not this tree's
        self.ports[102] = {9229, 52011}
        self.run_reap()
        self.assertEqual(self.terms(), [100, 101, 102])

    def test_a_new_child_bound_to_the_port_at_the_recheck_keeps_the_tree(self):
        self.server(100)
        scans = []
        original = reaper.processes.side_effect

        def restarted():
            scans.append(1)
            rows = original()
            if len(scans) > 1:
                rows[150] = (101, 100, 10, NEW, "workerd serve")
            return rows
        reaper.processes.side_effect = restarted
        reaper.listening.side_effect = lambda: {**self.ports, 150: {8811}} if len(scans) > 1 else dict(self.ports)
        self.assertEqual(self.run_reap(), (0, 1))
        self.assertEqual(self.sent, [])

    def test_a_server_that_binds_before_the_signal_is_kept(self):
        self.server(100)
        scans = []

        def later():
            scans.append(1)
            return dict(self.ports) if len(scans) == 1 else {**self.ports, 102: {8811}}
        reaper.listening.side_effect = later
        self.assertEqual(self.run_reap(), (0, 1))
        self.assertEqual(self.sent, [])

    def test_a_member_it_may_not_signal_is_named_and_the_rest_continue(self):
        self.server(100)
        self.server(200)

        def send(pid, sig):
            if pid == 101:
                raise PermissionError
            self.sent.append((pid, sig))
            if sig == signal.SIGTERM:
                self.rows.pop(pid, None)
        reaped = reaper.reap(apply=True, min_age=6 * HOUR, grace=0, now=NOW, janitor=Path("/j"),
                             send=send, sleep=lambda s: None, state_dir=self.state)
        self.assertEqual(reaped, (2, 2))
        self.assertEqual(self.terms(), [100, 102, 200, 201, 202])

    def cra(self, root, port=3633):
        self.server(root, cmd="node ./node_modules/.bin/react-scripts start")
        self.ports[root + 2] = {port}

    def aged_marker(self, root, hours, last_sample=0.5):
        """Unused since `hours` ago, last sampled `last_sample` hours ago."""
        begun = int(reaper.started(OLD))
        marker = self.state / f"{root}-{begun}"
        marker.write_text(f"{NOW - last_sample * HOUR}\n")
        old = NOW - hours * HOUR
        os.utime(marker, (old, old))

    def test_an_unused_cra_server_is_first_recorded_then_stopped_after_12h(self):
        self.cra(100)
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertTrue(any(self.state.iterdir()))
        self.aged_marker(100, 11)
        self.assertEqual(self.run_reap(), (0, 0))
        self.aged_marker(100, 13)
        self.assertEqual(self.run_reap(), (1, 1))
        self.assertEqual(self.terms(), [100, 101, 102])

    def test_hourly_samples_accumulate_and_a_gap_starts_over(self):
        self.cra(100)
        for hour in range(0, 13):
            self.assertEqual(self.run_reap(apply=False, now=NOW + hour * HOUR), (0, 1 if hour >= 12 else 0))
        self.assertEqual(self.run_reap(apply=False, now=NOW + 16 * HOUR), (0, 0))   # 3h gap

    def test_a_sample_does_not_move_the_start(self):
        self.cra(100)
        self.aged_marker(100, 5)
        self.run_reap(apply=False)
        marker = next(self.state.iterdir())
        self.assertAlmostEqual(marker.stat().st_mtime, NOW - 5 * HOUR, delta=1)

    def test_a_connection_resets_the_idle_record(self):
        self.cra(100)
        self.aged_marker(100, 13)
        self.connections.add(3633)
        self.run_reap()
        self.connections.discard(3633)
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_cra_server_published_by_a_review_front_is_kept(self):
        self.cra(100)
        self.aged_marker(100, 13)
        self.rows[500] = (1, 500, 10, OLD, f"node /x/tailnet_review.mjs {WT} 3157")
        self.ports[500] = {3157}
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])
        del self.rows[500], self.ports[500]          # the review ends: the 12h start over
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_review_front_started_by_the_recheck_keeps_it(self):
        self.cra(100)
        self.aged_marker(100, 13)
        scans = []
        original = reaper.processes.side_effect

        def front_appears():
            scans.append(1)
            rows = original()
            if len(scans) > 1:
                rows[500] = (1, 500, 10, NEW, f"node /x/tailnet_review.mjs {WT} 3157")
            return rows
        reaper.processes.side_effect = front_appears
        reaper.listening.side_effect = lambda: {**self.ports, 500: {3157}} if len(scans) > 1 else dict(self.ports)
        self.assertEqual(self.run_reap(), (0, 1))
        self.assertEqual(self.sent, [])

    def test_the_stacks_own_api_running_from_the_worktree_is_not_a_publisher(self):
        self.cra(100)
        self.aged_marker(100, 13)
        self.rows[600] = (1, 600, 10, OLD, f"{WT}/.local-stack/api")
        self.ports[600] = {3632}
        self.assertEqual(self.run_reap(), (1, 1))

    def test_a_sibling_dev_server_in_the_same_worktree_is_not_a_publisher(self):
        self.server(100)
        self.rows[700] = (1, 700, 10, OLD, f"node {WT}/node_modules/react-scripts/scripts/start.js")
        self.ports[700] = {3579}
        self.assertEqual(self.run_reap(), (1, 1))

    def test_a_cra_server_behind_tailscale_serve_is_kept(self):
        self.cra(100)
        self.aged_marker(100, 13)
        self.forwarded = {3633}
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_unreadable_tailscale_keeps_it(self):
        self.cra(100)
        self.aged_marker(100, 13)
        reaper.served_ports.side_effect = lambda: None
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_listening_server_nobody_uses_goes_after_the_window(self):
        self.server(100, cmd="node ./node_modules/.bin/next dev --port 8811")
        self.rows[101] = (100, 100, 2000, OLD, "next-server (v15.5.0)")
        self.ports[101] = {8811}
        self.assertEqual(self.run_reap(), (0, 0))       # first seen: recorded, kept
        self.aged_marker(100, 11)
        self.assertEqual(self.run_reap(), (0, 0))
        self.aged_marker(100, 13)
        self.assertEqual(self.run_reap(), (1, 1))
        self.assertEqual(self.terms(), [100, 101, 102])

    def test_a_listening_server_with_a_connection_is_serving_and_starts_over(self):
        self.server(100, cmd="node ./node_modules/.bin/next dev --port 8811")
        self.rows[101] = (100, 100, 2000, OLD, "next-server (v15.5.0)")
        self.ports[101] = {8811}
        self.aged_marker(100, 13)
        self.connections.add(8811)
        self.assertEqual(self.run_reap(), (0, 0))
        self.connections.discard(8811)
        self.assertEqual(self.run_reap(), (0, 0))       # the record started over
        self.assertEqual(self.sent, [])

    def test_a_connection_on_the_inspector_port_alone_does_not_count_for_a_named_port(self):
        self.server(100, cmd="node ./node_modules/.bin/next dev --port 8811")
        self.rows[101] = (100, 100, 2000, OLD, "next-server (v15.5.0)")
        self.ports[101] = {8811}
        self.aged_marker(100, 13)
        self.connections.add(9229)
        self.assertEqual(self.run_reap(), (1, 1))

    def test_under_memory_pressure_the_window_is_three_hours(self):
        self.server(100, cmd="node ./node_modules/.bin/next dev --port 8811")
        self.rows[101] = (100, 100, 2000, OLD, "next-server (v15.5.0)")
        self.ports[101] = {8811}
        self.aged_marker(100, 4)
        self.assertEqual(self.run_reap(), (0, 0))
        self.short = (True, "swap free 900M")
        self.assertEqual(self.run_reap(), (1, 1))

    def test_pressure_keeps_its_three_hour_window_and_never_touches_a_published_tree(self):
        self.cra(100)
        self.aged_marker(100, 2)
        self.short = (True, "memory pressure level 4")
        self.assertEqual(self.run_reap(), (0, 0))
        self.aged_marker(100, 4)
        self.forwarded = {3633}
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_server_that_started_listening_by_the_recheck_is_kept(self):
        self.server(100)
        scans = []

        def later():
            scans.append(1)
            return dict(self.ports) if len(scans) == 1 else {**self.ports, 102: {9229, 8811}}
        reaper.listening.side_effect = later
        self.assertEqual(self.run_reap(), (0, 1))
        self.assertEqual(self.sent, [])

    def test_a_listening_server_without_hot_reload_is_serving(self):
        for root, cmd in ((100, "node ./node_modules/.bin/next start --port 8811"),
                          (200, "node ./node_modules/.bin/vite preview --port 8812"),
                          (300, "npm run preview --port 8813")):
            self.server(root, cmd=cmd)
            self.ports[root] = {int(cmd.rsplit(" ", 1)[1])}   # the launcher itself serves
            self.aged_marker(root, 13)
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_npm_run_dev_running_vite_is_judged_by_what_it_runs(self):
        self.server(100, cmd="npm run dev -- --port 5173")
        self.rows[101] = (100, 100, 2000, OLD, "node /wt/node_modules/.bin/vite --port 5173")
        self.ports[102] = {9229, 5173}
        self.aged_marker(100, 13)
        self.assertEqual(self.run_reap(), (1, 1))

    def test_a_hot_reload_server_that_came_up_by_the_recheck_is_kept_though_unused(self):
        self.server(100, cmd="node ./node_modules/.bin/next dev --port 8811")
        self.rows[101] = (100, 100, 2000, OLD, "next-server (v15.5.0)")
        scans = []

        def later():
            scans.append(1)
            return dict(self.ports) if len(scans) == 1 else {**self.ports, 101: {8811}}
        reaper.listening.side_effect = later
        self.assertEqual(self.run_reap(), (0, 1))
        self.assertEqual(self.sent, [])

    def test_a_mixed_tree_is_judged_by_what_serves_the_measured_port(self):
        self.server(100, cmd="npm run dev --port=8787")
        self.rows[101] = (100, 100, 2000, OLD, "node /wt/node_modules/.bin/concurrently vite 'wrangler dev --port 8787'")
        self.rows[103] = (101, 100, 2000, OLD, "node /wt/node_modules/.bin/vite --port 5173")
        self.rows[104] = (101, 100, 2000, OLD, "node /wt/node_modules/.bin/wrangler dev --port 8787")
        self.rows[105] = (104, 100, 2000, OLD, "workerd serve")
        self.ports[103] = {5173}
        self.ports[105] = {8787}
        self.connections.add(5173)
        self.aged_marker(100, 13)
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_vite_with_flags_before_preview_is_not_hot(self):
        self.assertFalse(reaper.hot_reload({1: (0, 1, 1, OLD, "node /x/vite --mode staging preview --port 4173")}, [1]))
        self.assertTrue(reaper.hot_reload({1: (0, 1, 1, OLD, "node /x/vite --mode staging --port 5173")}, [1]))

    def test_a_marker_that_is_not_a_number_starts_over(self):
        self.cra(100)
        marker = self.state / f"100-{int(reaper.started(OLD))}"
        marker.write_text("²\n")
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(float(marker.read_text()), NOW)

    def test_markers_of_gone_trees_are_pruned(self):
        (self.state / "999-123").touch()
        self.run_reap()
        self.assertFalse((self.state / "999-123").exists())

    def test_a_cra_server_with_a_connection_is_serving(self):
        self.cra(100)
        self.connections.add(3633)
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_cra_server_connected_by_the_recheck_is_kept(self):
        self.cra(100)
        self.aged_marker(100, 13)
        calls = []

        def later():
            calls.append(1)
            return {443} if len(calls) == 1 else {443, 3633}
        reaper.connected.side_effect = later
        self.assertEqual(self.run_reap(), (0, 1))
        self.assertEqual(self.sent, [])

    def test_unreadable_connections_keep_a_cra_server(self):
        self.cra(100)
        self.aged_marker(100, 13)
        self.connections.clear()
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_survivors_of_term_get_kill(self):
        self.server(100)
        reaper.reap(apply=True, min_age=6 * HOUR, grace=0, now=NOW, janitor=Path("/j"),
                    send=lambda pid, sig: self.sent.append((pid, sig)), sleep=lambda s: None,
                    state_dir=self.state)
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


ESBUILD = f"{WT}/site/node_modules/wrangler/node_modules/@esbuild/darwin-arm64/bin/esbuild --service=0.27.3 --ping"


class EsbuildTest(Fixture):
    """An esbuild --service whose wrangler dev died, reparented to launchd."""

    def esbuild(self, pid, ppid=1, pgid=None, lstart=OLD, cmd=ESBUILD, where=WT):
        self.rows[pid] = (ppid, pgid or pid - 1, 13000, lstart, cmd)
        self.cwds[pid] = where
        self.worktrees[WT] = WT

    def test_an_orphaned_esbuild_service_is_stopped(self):
        self.esbuild(7171)
        self.assertEqual(self.run_reap(), (1, 1))
        self.assertEqual(self.terms(), [7171])

    def test_report_mode_lists_it_and_signals_nothing(self):
        self.esbuild(7171)
        self.assertEqual(self.run_reap(apply=False), (0, 1))
        self.assertEqual(self.sent, [])

    def test_orphans_sharing_a_group_all_go_with_one_claim_check(self):
        self.esbuild(30608, pgid=4234)
        self.esbuild(84624, pgid=4234)
        self.esbuild(7171)
        self.assertEqual(self.run_reap(), (3, 3))
        self.assertEqual(self.terms(), [7171, 30608, 84624])
        self.assertEqual(self.claim_calls, [WT])

    def test_a_dot_bin_esbuild_counts(self):
        self.esbuild(7171, cmd=f"{WT}/node_modules/.bin/esbuild --service=0.19.2 --ping")
        self.assertEqual(self.run_reap(), (1, 1))

    def test_a_live_parent_keeps_it(self):
        self.esbuild(7171, ppid=7000)
        self.rows[7000] = (1, 7000, 10, OLD, "node /x/wrangler-dist/cli.js dev")
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_launcher_in_its_group_keeps_it(self):
        self.esbuild(7171, pgid=7098)
        self.rows[7098] = (1, 7098, 10, OLD, "node /x/node_modules/.bin/wrangler dev")
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_an_agent_in_its_group_keeps_it(self):
        self.esbuild(7171, pgid=7098)
        self.rows[7098] = (1, 7098, 10, OLD, "/Users/x/.local/bin/claude --resume abc")
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_young_one_is_kept(self):
        self.esbuild(7171, lstart=NEW)
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_socket_keeps_it(self):
        self.esbuild(7171)
        self.socket_pids.add(7171)
        self.assertEqual(self.run_reap(), (0, 0))
        self.esbuild(7171)
        self.socket_pids.clear()
        self.ports[7171] = {5000}
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_child_keeps_it(self):
        self.esbuild(7171)
        self.rows[7200] = (7171, 7200, 10, OLD, "sleep 100")
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_primary_checkout_is_kept(self):
        self.esbuild(7171, where=Path("/repo/primary"))
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_a_claimed_worktree_is_kept(self):
        self.esbuild(7171)
        self.claims.add(WT)
        self.assertEqual(self.run_reap(), (0, 0))
        self.assertEqual(self.sent, [])

    def test_every_failed_probe_keeps_it(self):
        self.esbuild(7171)
        reaper.sockets.side_effect = lambda pid: None
        self.assertEqual(self.run_reap(), (0, 0))
        reaper.sockets.side_effect = lambda pid: False
        del self.cwds[7171]
        self.assertEqual(self.run_reap(), (0, 0))
        self.cwds[7171] = WT
        reaper.claimed.side_effect = lambda wt, j, t=900: True   # claimed() maps failure to True
        self.assertEqual(self.run_reap(), (0, 0))
        reaper.claimed.side_effect = self.fake_claimed
        reaper.processes.side_effect = lambda: None
        with self.assertRaises(RuntimeError):
            self.run_reap()
        self.assertEqual(self.sent, [])

    def test_a_socket_opened_by_the_recheck_keeps_it(self):
        self.esbuild(7171)
        calls = []

        def later(pid):
            calls.append(pid)
            return len(calls) > 1
        reaper.sockets.side_effect = later
        self.assertEqual(self.run_reap(), (0, 1))
        self.assertEqual(self.sent, [])

    def test_only_an_esbuild_service_binary_matches(self):
        for cmd in (ESBUILD,
                    "/x/node_modules/@esbuild/linux-x64/bin/esbuild --service",
                    "/x/node_modules/.bin/esbuild --service=0.19.2"):
            self.assertTrue(reaper.esbuild_service(cmd), cmd)
        for cmd in ("node /x/node_modules/.bin/esbuild --service=0.19.2",
                    "/x/node_modules/.bin/esbuild src/index.ts --bundle",
                    "/usr/local/bin/esbuild --service=0.19.2",
                    f"tmux new-session -d {ESBUILD}",
                    f"/Users/x/.local/bin/claude --bg run {ESBUILD}", ""):
            self.assertFalse(reaper.esbuild_service(cmd), cmd)


class SocketsTest(unittest.TestCase):
    def run_lsof(self, stdout, rc=0):
        with mock.patch.object(reaper.subprocess, "run", return_value=mock.Mock(returncode=rc, stdout=stdout)):
            return reaper.sockets(7171)

    def test_a_dead_stdio_socketpair_is_not_a_socket(self):
        files = "p7171\nfcwd\ntDIR\nn/wt\nf0\ntunix\nn->(none)\nf1\ntunix\nn->(none)\nf3\ntKQUEUE\nncount=0\n"
        self.assertFalse(self.run_lsof(files))
        self.assertTrue(self.run_lsof(files + "f4\ntunix\nn->0x8561a0dfe2fdb8fc\n"))
        self.assertTrue(self.run_lsof(files + "f4\ntunix\nn/tmp/x.sock\n"))
        self.assertTrue(self.run_lsof(files + "f4\ntIPv4\nn127.0.0.1:5000\n"))
        self.assertTrue(self.run_lsof(files + "f4\ntIPv6\nn*:5000\n"))

    def test_a_failed_probe_is_unknown(self):
        self.assertIsNone(self.run_lsof("", rc=1))
        self.assertIsNone(self.run_lsof("p9\nfcwd\ntDIR\nn/\n"))
        with mock.patch.object(reaper.subprocess, "run",
                               side_effect=reaper.subprocess.TimeoutExpired("lsof", 30)):
            self.assertIsNone(reaper.sockets(7171))


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

    def test_a_timeout_is_a_claim(self):
        with mock.patch.object(reaper.subprocess, "run",
                               side_effect=reaper.subprocess.TimeoutExpired("janitor", 900)):
            self.assertTrue(reaper.claimed(WT, Path("/janitor")))

    def test_failure_or_garbage_is_a_claim(self):
        self.assertTrue(self.probe("", rc=2))
        self.assertTrue(self.probe("ERROR\tharness=Claude\n"))


class PatternTest(unittest.TestCase):
    def test_launchers_and_their_ports(self):
        for cmd, port in (("npm run preview --port 8811 --ip 0.0.0.0", 8811),
                          ("npm run dev -- --port 3000", 3000),
                          ("node node_modules/.bin/next dev --webpack --port 4462", 4462),
                          ("/opt/homebrew/bin/node /x/node_modules/.bin/wrangler dev --port=8787", 8787),
                          ("node /x/node_modules/wrangler/bin/wrangler.js pages dev -p 8788", 8788),
                          ("node /x/node_modules/.bin/vite --port 5173", 5173),
                          ("npm run dev", 0), ("node ./node_modules/.bin/next start --port x", 0),
                          ("node ./node_modules/.bin/react-scripts start", reaper.ANY_PORT)):
            self.assertEqual(reaper.launcher(cmd), port, cmd)

    def test_not_launchers(self):
        for cmd in ("npm run build", "npm run test --port 1", "/bin/bash sup.sh --port 8811",
                    "node ./node_modules/.bin/react-scripts build",
                    "tmux new-session -d npm run dev --port 5173",
                    "SCREEN -dmS x npm run dev --port 5173",
                    "/Users/x/.local/bin/claude --bg run npm run dev --port 3000",
                    "sh -c npm run dev --port 3000", "node", ""):
            self.assertIsNone(reaper.launcher(cmd), cmd)


class WorktreeTest(unittest.TestCase):
    """Real git: a primary checkout, a linked worktree, and a subdirectory of each."""

    def test_only_a_linked_worktree_is_one(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp).resolve()
            primary, linked = base / "repo", base / "wt"

            def git(*args):
                subprocess.run(["git", "-C", str(primary), *args], check=True, capture_output=True)
            primary.mkdir()
            git("init", "-q")
            (primary / "web" / "next").mkdir(parents=True)
            (primary / "web" / "next" / "f").write_text("x")
            git("add", ".")
            git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
            git("worktree", "add", "-q", str(linked))
            self.assertIsNone(reaper.linked_worktree(primary))
            self.assertIsNone(reaper.linked_worktree(primary / "web" / "next"))
            self.assertEqual(reaper.linked_worktree(linked), linked)
            self.assertEqual(reaper.linked_worktree(linked / "web" / "next"), linked)
            self.assertIsNone(reaper.linked_worktree(base))


class ServedPortsTest(unittest.TestCase):
    def run_status(self, stdout, rc=0, which="/bin/tailscale"):
        with mock.patch.object(reaper.shutil, "which", return_value=which), \
             mock.patch.object(reaper.subprocess, "run", return_value=mock.Mock(returncode=rc, stdout=stdout)):
            return reaper.served_ports()

    def test_proxies_are_read_and_tcp_listen_ports_are_not(self):
        status = {"TCP": {"8157": {"HTTP": True}, "9000": {"TCPForward": "127.0.0.1:3000"}},
                  "Web": {"h:8157": {"Handlers": {
                      "/": {"Proxy": "http://127.0.0.1:3157"}, "/v": {"Proxy": "http://127.0.0.1:4979/"}}}}}
        self.assertEqual(self.run_status(json.dumps(status)), {3157, 4979, 3000})

    def test_no_tailscale_is_nothing_served_and_a_failure_is_unknown(self):
        with mock.patch.object(reaper.os, "access", return_value=False):
            self.assertEqual(self.run_status("", which=None), set())
        self.assertIsNone(self.run_status("not json"))


class PressureTest(unittest.TestCase):
    def run_sysctl(self, level, swap):
        answers = {"kern.memorystatus_vm_pressure_level": level, "vm.swapusage": swap}

        def fake(args, **kw):
            value = answers[args[-1]]
            if value is None:
                raise reaper.subprocess.CalledProcessError(1, args)
            return mock.Mock(stdout=value + "\n")
        with mock.patch.object(reaper.subprocess, "run", side_effect=fake):
            return reaper.pressure(log="/nonexistent/pressure.log")

    def test_only_the_pressure_level_counts(self):
        tight = "total = 14336.00M  used = 13432.75M  free = 903.25M  (encrypted)"
        self.assertEqual(self.run_sysctl("1", tight), (False, ""))
        self.assertEqual(self.run_sysctl("2", tight), (True, "memory pressure level 2"))
        self.assertEqual(self.run_sysctl("4", tight), (True, "memory pressure level 4"))

    def test_a_failed_probe_is_not_pressure(self):
        self.assertEqual(self.run_sysctl(None, None), (False, ""))

    def run_log(self, level, text, now):
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
            f.write(text)
        self.addCleanup(os.unlink, f.name)
        with mock.patch.object(reaper.subprocess, "run",
                               return_value=mock.Mock(stdout=level + "\n")):
            return reaper.pressure(log=f.name, now=now)

    def test_a_level_two_sample_in_the_last_hour_counts(self):
        now = calendar.timegm((2026, 10, 5, 7, 0, 0))
        log = ("2026-10-04T17:32:44Z load=1 swap=1M cmpGB=9.2\n"
               "2026-10-05T06:10:00Z load=1 swap=1M mp=2 cmpGB=9\n"
               "2026-10-05T06:30:00Z load=1 swap=1M mp=2 cmpGB=9\n"
               "2026-10-05T06:55:00Z load=1 swap=1M mp=1 cmpGB=9\n")
        self.assertEqual(self.run_log("1", log, now),
                         (True, "memory pressure level 2 at 2026-10-05T06:30:00Z"))
        self.assertEqual(self.run_log("1", log, now + 1801), (False, ""))
        self.assertEqual(self.run_log("1", log.replace("mp=2", "mp=1"), now), (False, ""))
        self.assertEqual(self.run_log("1", "", now), (False, ""))
        with mock.patch.object(reaper.subprocess, "run", return_value=mock.Mock(stdout="1\n")):
            self.assertEqual(reaper.pressure(log="/nonexistent/pressure.log", now=now), (False, ""))

    def test_no_log_is_configured_by_default(self):
        # The sampler is host-specific (stima-watch on one machine); unset, only the live
        # level is read, and a log path is never guessed.
        self.assertEqual(reaper.PRESSURE_LOG, os.environ.get("CC_DEV_SERVER_PRESSURE_LOG", ""))
        with mock.patch.object(reaper, "PRESSURE_LOG", ""), \
             mock.patch.object(reaper.subprocess, "run", return_value=mock.Mock(stdout="1\n")), \
             mock.patch("builtins.open", side_effect=AssertionError("opened a log")):
            self.assertEqual(reaper.pressure(), (False, ""))


class ConnectedTest(unittest.TestCase):
    def test_both_ends_count_and_empty_is_a_failed_probe(self):
        result = mock.Mock(returncode=0, stdout="p1\nn127.0.0.1:55001->127.0.0.1:3633\nn[::1]:3579->[::1]:61000\n")
        with mock.patch.object(reaper.subprocess, "run", return_value=result):
            self.assertEqual(reaper.connected(), {55001, 3633, 3579, 61000})
        with mock.patch.object(reaper.subprocess, "run", return_value=mock.Mock(returncode=1, stdout="")):
            self.assertIsNone(reaper.connected())


class ListeningTest(unittest.TestCase):
    def test_an_empty_listing_is_a_failed_probe(self):
        result = mock.Mock(returncode=1, stdout="")
        with mock.patch.object(reaper.subprocess, "run", return_value=result):
            self.assertIsNone(reaper.listening())

    def test_listeners_parse_every_address_form(self):
        result = mock.Mock(returncode=0, stdout="p10\nn*:8811\nn[::1]:9229\np11\nn127.0.0.1:4462\n")
        with mock.patch.object(reaper.subprocess, "run", return_value=result):
            self.assertEqual(reaper.listening(), {10: {8811, 9229}, 11: {4462}})


if __name__ == "__main__":
    unittest.main()
