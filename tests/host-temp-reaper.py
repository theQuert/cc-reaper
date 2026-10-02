#!/usr/bin/env python3
"""Isolated safety tests for the host temp reaper: every keep rule, and what it removes."""

from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[1] / "shell" / "host-temp-reaper.py"
spec = importlib.util.spec_from_file_location("host_temp_reaper", SOURCE)
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)
REAL_HELD = reaper.held

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HOUR = 3600
DAY = 24 * HOUR


class ReaperTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve() / "T"
        self.logs = Path(temp.name).resolve() / "wrangler-logs"
        self.jobs = Path(temp.name).resolve() / "jobs"
        self.root.mkdir()
        self.logs.mkdir()
        self.jobs.mkdir()
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

    def test_only_old_unheld_build_copies_are_removed(self):
        def copy(name, age):
            path = self.root / name
            (path / "site-nimbus").mkdir(parents=True)
            (path / "site-nimbus" / "package.json").write_text("{}")
            return self.aged(path, age)
        old = copy("nimbus-articles-build-anqCbI", DAY + HOUR)
        # Older than the general idle limit, younger than the build copy's own.
        kept_on_purpose = copy("nimbus-articles-build-JGyZdU", DAY - HOUR)
        running = copy("nimbus-articles-build-k0KChp", DAY + HOUR)
        self.holders.add(running)
        other = copy("nimbus-articles-build-toolong1", DAY + HOUR)
        link = self.root / "nimbus-articles-build-5ilVsv"
        target = self.aged(self.logs, DAY + HOUR)
        link.symlink_to(target)
        os.utime(link, (time.time() - DAY + HOUR,) * 2, follow_symlinks=False)
        counts = self.run_clean()
        self.assertFalse(old.exists())
        for path in (kept_on_purpose, running, other, link):
            self.assertTrue(path.exists() or path.is_symlink(), path)
        self.assertEqual(counts["build"], [1, 1])

    def test_a_build_copy_that_will_not_delete_is_kept_and_the_run_goes_on(self):
        stuck = self.root / "nimbus-articles-build-AAAAAA"
        gone = self.root / "nimbus-articles-build-BBBBBB"
        for path in (stuck, gone):
            path.mkdir()
            self.aged(path, DAY + HOUR)
        real = reaper.shutil.rmtree
        def rmtree(path, *a, **k):
            if Path(path) == stuck:
                raise PermissionError(1, "Operation not permitted", str(path))
            return real(path, *a, **k)
        with mock.patch.object(reaper.shutil, "rmtree", side_effect=rmtree):
            counts = self.run_clean()
        self.assertTrue(stuck.exists())
        self.assertFalse(gone.exists())
        self.assertEqual(counts["build"], [2, 1])

    def test_lsof_sees_a_process_whose_cwd_is_inside(self):
        inside = self.root / "nimbus-articles-build-CCCCCC"
        (inside / "site-nimbus").mkdir(parents=True)
        idle_dir = self.root / "nimbus-articles-build-DDDDDD"
        idle_dir.mkdir()
        child = subprocess.Popen(["sleep", "30"], cwd=inside / "site-nimbus")
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        self.assertTrue(REAL_HELD(inside))
        self.assertFalse(REAL_HELD(idle_dir))

    def job(self, name, state="done", ended=4 * DAY, file_age=4 * DAY, raw=None):
        job = self.jobs / name
        (job / "tmp" / "venv" / "bin").mkdir(parents=True)
        (job / "tmp" / "venv" / "pyvenv.cfg").write_text("home = /usr/bin")
        (job / "tmp" / "comment.md").write_text("the job's own file")
        when = datetime.fromtimestamp(time.time() - ended, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        text = raw if raw is not None else json.dumps({"state": state, "lastTerminalAt": when, "updatedAt": when})
        (job / "state.json").write_text(text)
        self.aged(job / "state.json", file_age)
        return job / "tmp" / "venv"

    def run_jobs(self, clean=True):
        return reaper.reap(self.root, self.logs, clean=clean, idle_seconds=HOUR,
                           send=lambda pid, sig: None, jobs_dir=self.jobs)

    def test_only_a_long_finished_unused_jobs_venv_is_removed(self):
        gone = self.job("aaaaaaaa")
        stopped = self.job("bbbbbbbb", state="stopped")
        working = self.job("cccccccc", state="working")
        blocked = self.job("dddddddd", state="blocked")
        recent = self.job("eeeeeeee", ended=3 * DAY - HOUR)
        touched = self.job("ffffffff", file_age=3 * DAY - HOUR)
        not_venv = self.jobs / "aaaaaaaa" / "tmp" / "scratch"
        not_venv.mkdir()
        in_use = self.job("11111111")
        self.rows.append((70, 1, 10, f"{in_use}/venv/bin/python fake_soffice.py"))
        held = self.job("22222222")
        self.holders.add(held)
        broken = self.job("33333333", raw="{not json")
        no_time = self.job("44444444", raw=json.dumps({"state": "done"}))
        other = self.job("release-owner")
        counts = self.run_jobs()
        self.assertFalse(gone.exists())
        self.assertFalse(stopped.exists())
        self.assertTrue((gone.parent.parent / "state.json").exists())
        self.assertTrue((gone.parent / "comment.md").exists() and not_venv.exists())
        for path in (working, blocked, recent, touched, in_use, held, broken, no_time, other):
            self.assertTrue(path.exists(), path)
        self.assertEqual(counts["jobvenv"], [2, 2])

    def test_a_job_resumed_mid_scan_keeps_its_venv(self):
        venv = self.job("12121212")
        real = reaper.finished_job
        calls = []
        def finished(job, now):
            calls.append(job)
            return len(calls) == 1 and real(job, now)
        with mock.patch.object(reaper, "finished_job", side_effect=finished):
            counts = self.run_jobs()
        self.assertTrue(venv.exists())
        self.assertEqual(counts["jobvenv"], [1, 0])

    def test_a_symlinked_job_tmp_is_never_followed(self):
        target = self.root / "keep-me"
        target.mkdir()
        job = self.jobs / "abcdef01"
        job.mkdir()
        (target / "venv").mkdir()
        (target / "venv" / "pyvenv.cfg").write_text("x")
        (job / "tmp").symlink_to(target)
        when = datetime.fromtimestamp(time.time() - 4 * DAY, timezone.utc).isoformat()
        (job / "state.json").write_text(json.dumps({"state": "done", "lastTerminalAt": when}))
        self.aged(job / "state.json", 4 * DAY)
        linked = self.job("abcdef02")
        shutil.rmtree(linked)
        linked.symlink_to(target / "venv")
        counts = self.run_jobs()
        self.assertTrue((target / "venv").exists())
        self.assertEqual(counts["jobvenv"], [0, 0])

    def test_check_mode_keeps_a_job_tmp(self):
        venv = self.job("abababab")
        counts = self.run_jobs(clean=False)
        self.assertTrue(venv.exists())
        self.assertEqual(counts["jobvenv"], [1, 0])

    def test_check_mode_changes_nothing(self):
        profile = self.profile("cdp-HHHHHH")
        build = self.root / "nimbus-articles-build-KKKKKK"
        build.mkdir()
        self.aged(build, DAY + HOUR)
        self.chrome(50, self.root / "cdp-IIIIII")
        counts = reaper.reap(self.root, self.logs, clean=False, idle_seconds=HOUR,
                             send=lambda pid, sig: self.sent.append(pid))
        self.assertTrue(profile.exists() and build.exists())
        self.assertEqual(self.sent, [])
        self.assertEqual(counts["build"], [1, 0])
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
