#!/usr/bin/env python3
"""Isolated safety tests for the host temp reaper: every keep rule, and what it removes."""

import importlib.util
import os
from pathlib import Path
import signal
import tempfile
import time
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[1] / "shell" / "host-temp-reaper.py"
spec = importlib.util.spec_from_file_location("host_temp_reaper", SOURCE)
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HOUR = 3600


class ReaperTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve() / "T"
        self.logs = Path(temp.name).resolve() / "wrangler-logs"
        self.root.mkdir()
        self.logs.mkdir()
        self.rows = []
        self.ports = {}
        self.clients = set()
        self.holders = set()
        self.sent = []
        for name, fake in (("processes", lambda: list(self.rows)),
                           ("listening_ports", lambda pid: self.ports.get(pid, set())),
                           ("has_client", lambda port: port in self.clients),
                           ("held", lambda path: path in self.holders)):
            patcher = mock.patch.object(reaper, name, side_effect=fake)
            patcher.start()
            self.addCleanup(patcher.stop)

    def aged(self, path, seconds):
        old = time.time() - seconds
        os.utime(path, (old, old))
        return path

    def profile(self, name, age=2 * HOUR):
        path = self.root / name
        path.mkdir()
        (path / "Default").mkdir()
        return self.aged(path, age)

    def chrome(self, pid, profile, ppid=1, elapsed=2 * HOUR, port=None, flags="--headless=new"):
        command = f"{CHROME} {flags} --remote-debugging-port=0 --user-data-dir={profile} about:blank"
        self.rows.append((pid, ppid, elapsed, command))
        self.ports[pid] = {port or 50000 + pid}

    def run_clean(self):
        return reaper.reap(self.root, self.logs, clean=True, idle_seconds=HOUR,
                           send=lambda pid, sig: self.sent.append((pid, sig)))

    def test_an_abandoned_headless_chrome_gets_sigterm_and_nothing_else_does(self):
        self.chrome(10, self.root / "cdp-Orphan")
        self.chrome(11, self.root / "cdp-Parent", ppid=4242)            # launcher alive
        self.chrome(12, self.root / "cdp-Young1", elapsed=HOUR - 60)     # too young
        self.chrome(13, self.root / "cdp-Client")                        # DevTools attached
        self.clients.add(50013)
        self.chrome(14, Path("/Users/me/Chrome Profile"))                # not under temp
        self.chrome(15, self.root / "cdp-NoHead", flags="--window-size=1,1")  # not headless
        helper = ("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework"
                  "/Versions/152.0.7977.77/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
        self.rows.append((16, 1, 2 * HOUR, f"{helper} --headless --remote-debugging-port=0"
                                           f" --user-data-dir={self.root}/cdp-Helper"))
        self.ports[16] = {50016}                                         # a Helper, not the browser
        self.chrome(17, self.root / "cdp-NoLsof")                        # port probe failed
        self.ports[17] = None
        counts = self.run_clean()
        self.assertEqual(self.sent, [(10, signal.SIGTERM)])
        self.assertEqual(counts["chrome"], [1, 1])

    def test_a_reused_pid_is_not_signalled(self):
        self.chrome(20, self.root / "cdp-Orphan")
        first = list(self.rows)
        calls = iter([first, [(20, 1, 5, "/usr/bin/other")]])
        with mock.patch.object(reaper, "processes", side_effect=lambda: next(calls)):
            counts = self.run_clean()
        self.assertEqual(self.sent, [])
        self.assertEqual(counts["chrome"], [1, 0])

    def test_only_unnamed_idle_unheld_profiles_are_removed(self):
        gone = self.profile("cdp-AAAAAA")
        named = self.profile("cdp-BBBBBB")
        self.rows.append((30, 999, 10, f"{CHROME} --user-data-dir={named}"))
        young = self.profile("cdp-CCCCCC", age=HOUR - 60)
        held = self.profile("cdp-DDDDDD")
        self.holders.add(held)
        other = self.profile("puppeteer_dev_profile-EEEEEE")
        link = self.root / "cdp-FFFFFF"
        link.symlink_to(named)
        counts = self.run_clean()
        self.assertFalse(gone.exists())
        for path in (named, young, held, other, link):
            self.assertTrue(path.exists() or path.is_symlink(), path)
        self.assertEqual(counts["profile"], [1, 1])

    def test_a_signalled_chromes_profile_waits_for_the_next_run(self):
        profile = self.profile("cdp-GGGGGG")
        self.chrome(40, profile)
        self.run_clean()
        self.assertTrue(profile.exists())
        self.rows.clear()
        self.run_clean()
        self.assertFalse(profile.exists())

    def test_only_idle_unheld_wrangler_logs_are_removed(self):
        def log(name, age):
            path = self.logs / name
            path.write_text("x")
            return self.aged(path, age)
        old = log("wrangler-2026-09-28_19-38-13_509.log", 2 * HOUR)
        live = log("wrangler-2026-09-30_12-32-17_156.log", 60)
        open_ = log("wrangler-2026-09-29_08-49-08_537.log", 2 * HOUR)
        self.holders.add(open_)
        other = log("notes.txt", 2 * HOUR)
        counts = self.run_clean()
        self.assertFalse(old.exists())
        self.assertTrue(live.exists() and open_.exists() and other.exists())
        self.assertEqual(counts["wrangler"], [1, 1])

    def test_check_mode_changes_nothing(self):
        profile = self.profile("cdp-HHHHHH")
        self.chrome(50, self.root / "cdp-IIIIII")
        counts = reaper.reap(self.root, self.logs, clean=False, idle_seconds=HOUR,
                             send=lambda pid, sig: self.sent.append(pid))
        self.assertTrue(profile.exists())
        self.assertEqual(self.sent, [])
        self.assertEqual(counts["profile"], [1, 0])
        self.assertEqual(counts["chrome"], [1, 0])

    def test_a_failed_process_listing_keeps_everything(self):
        profile = self.profile("cdp-JJJJJJ")
        with mock.patch.object(reaper, "processes", return_value=None):
            with self.assertRaises(RuntimeError):
                self.run_clean()
        self.assertTrue(profile.exists())

    def test_elapsed_parses_every_ps_shape(self):
        self.assertEqual(reaper.elapsed_seconds("05"), 5)
        self.assertEqual(reaper.elapsed_seconds("01:05"), 65)
        self.assertEqual(reaper.elapsed_seconds("02:01:05"), 7265)
        self.assertEqual(reaper.elapsed_seconds("3-02:01:05"), 3 * 86400 + 7265)


if __name__ == "__main__":
    unittest.main()
