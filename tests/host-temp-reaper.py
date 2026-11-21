#!/usr/bin/env python3
"""Isolated safety tests for the host temp reaper: every keep rule, and what it removes."""

from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import types
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[1] / "shell" / "host-temp-reaper.py"
spec = importlib.util.spec_from_file_location("host_temp_reaper", SOURCE)
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)
REAL_HELD = reaper.held
REAL_HOLDERS = reaper.holders
REAL_PROCESSES = reaper.processes

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
        self.ctimes = {}
        # ctime cannot be set with os.utime, so the reaper sees ctime == mtime except where a test says so.
        real_lstat = os.lstat
        def lstat(path, *a, **k):
            st = real_lstat(path, *a, **k)
            fields = {n: getattr(st, n) for n in dir(st) if n.startswith("st_")}
            fields["st_ctime"] = self.ctimes.get(os.fspath(path), st.st_mtime)
            return types.SimpleNamespace(**fields)
        class OsView:
            def __getattr__(self, name):
                return getattr(os, name)
        view = OsView()
        view.lstat = lstat
        patcher = mock.patch.object(reaper, "os", view)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name, fake in (("processes", lambda env=False: list(self.rows)),
                           ("listening_ports", lambda pid: self.ports.get(pid, set())),
                           ("has_client", lambda port: port in self.clients),
                           ("held", lambda path: path in self.holders),
                           ("holders", lambda root, rows: {p.name for p in self.holders})):
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

    def test_a_never_kill_chrome_is_not_signalled(self):
        self.chrome(30, self.root / "cdp-Listed")
        self.chrome(31, self.root / "cdp-Other")
        with mock.patch.dict(os.environ, {"CC_NEVER_KILL_PIDS": "30"}), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            counts = self.run_clean()
        self.assertEqual(self.sent, [(31, signal.SIGTERM)])
        self.assertEqual(counts["chrome"], [2, 1])
        self.assertIn("never-kill 30\n", out.getvalue())

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

    def leftover(self, name, age, inner_age=None, file=False):
        path = self.root / name
        if file:
            path.write_text("x")
        else:
            (path / "deep").mkdir(parents=True)
            (path / "deep" / "f").write_text("x")
            self.aged(path / "deep" / "f", age if inner_age is None else inner_age)
            self.aged(path / "deep", age)
        return self.aged(path, age)

    def test_only_untouched_unheld_tool_leftovers_are_removed(self):
        gone = [self.leftover("tmpab_cd123", 3 * DAY + HOUR),
                self.leftover("tmp.AbCdEf123x", 3 * DAY + HOUR),
                self.leftover("pip-unpack-6pi0dsfu", DAY + HOUR),
                self.leftover("go-build535115792", DAY + HOUR),
                self.leftover("nimbus-m2-build-Ab12Cd", DAY + HOUR),
                self.leftover("tmpab_cd124", 2 * DAY),             # generic name: a day (was three)
                self.leftover("tmpabcdefgh", DAY + HOUR),          # mkdtemp with no digit, no underscore
                self.leftover("tmp.AbCdEfGhIj", DAY + HOUR),       # mktemp with an upper-case letter, no digit
                self.leftover("go-build777", 3 * HOUR),            # go WORK dir: two hours
                self.leftover("hold-Ab12Cd", DAY + HOUR),          # node mkdtempSync leftovers of the router tests
                self.leftover("preview-unpack-xYz9Qa", DAY + HOUR)]
        kept = [self.leftover("tmpab_cd125", DAY - HOUR),          # generic name: a day not yet up
                self.leftover("go-build778", HOUR),                 # go WORK dir younger than two hours
                self.leftover("hold-Ab12Ce", DAY - HOUR),
                self.leftover("hold-canary", 4 * DAY),               # an English word, not a random suffix
                self.leftover("pip-unpack-6pi0dsfx", DAY - HOUR),   # a day not yet up
                self.leftover("go-build1", DAY + HOUR, inner_age=HOUR),  # changed deep inside
                self.leftover("tmpheld0001", 4 * DAY),
                self.leftover("node-compile-cache", 9 * DAY),       # not a tool temp name
                self.leftover("tmpTOOLONG123", 4 * DAY),
                self.leftover("tmp-scratch", 4 * DAY),               # a person's name, in no tool's shape
                self.leftover("tmp.AbCdEf1234", 4 * DAY, file=True),  # a generic name: dirs only
                self.leftover("nimbus-prod-config", 4 * DAY)]       # not a known nimbus test
        self.holders.add(self.root / "tmpheld0001")
        counts = self.run_clean()
        for path in gone:
            self.assertFalse(path.exists(), path)
        for path in kept:
            self.assertTrue(path.exists(), path)
        self.assertEqual(counts["leftover"], [11, 11])

    # stima-api#7106: the seventh kind, the tmp shapes the leftover rule leaves alone.
    def test_only_old_unheld_tmp_dirs_the_leftover_rule_leaves_are_removed(self):
        gone = [self.leftover("tmp_sriaqhi", 2 * DAY + HOUR),         # a Python sandbox: no digit, an underscore
                self.leftover("tmp___6x43l", 3 * DAY),                # leftover-shaped? no: three underscores, a digit
                self.leftover("tmp_scratch", 4 * DAY),                # the shape is all there is to go on
                self.leftover("tmpAbCdEfGh", 2 * DAY + HOUR),         # upper case
                self.leftover("tmp.abcdefghij", 2 * DAY + HOUR)]      # mktemp, all lower case
        kept = [self.leftover("tmp_youngun", 2 * DAY - HOUR),         # 48 h not yet up
                self.leftover("tmp_deepchg", 3 * DAY, inner_age=HOUR),  # changed deep inside
                self.leftover("tmp_heldone", 3 * DAY),                # an open file or cwd inside (snapshot)
                self.leftover("tmp_lsofsee", 3 * DAY),                # lsof +D finds a holder
                self.leftover("tmp_cmdline", 3 * DAY),                # named on a command line
                self.leftover("tmp_toolong1", 3 * DAY),               # nine characters
                self.leftover("tmp.abcdefghi", 3 * DAY),              # nine characters
                self.leftover("tmp_isafile", 3 * DAY, file=True)]     # directories only
        self.rows.append((77, 1, 10, f"python3 -m pytest --basetemp=/x/{'tmp_cmdline'}"))
        self.holders.add(self.root / "tmp_heldone")
        lsof_held = {self.root / "tmp_lsofsee"}
        out = io.StringIO()
        with mock.patch.object(reaper, "held", side_effect=lambda path: path in lsof_held), \
             mock.patch.object(reaper, "holders", side_effect=lambda root, rows: {"tmp_heldone"}), \
             mock.patch("sys.stdout", out):
            counts = self.run_clean()
        for path in gone:
            self.assertFalse(path.exists(), path)
        for path in kept:
            self.assertTrue(path.exists(), path)
        self.assertEqual(counts["tmpdir"], [4, 4])
        self.assertEqual(counts["leftover"], [1, 1])  # tmp___6x43l has a digit: the leftover rule's, at a day
        self.assertRegex(out.getvalue(), r"REMOVED tmpdir tmp_sriaqhi bytes=\d+")
        self.assertRegex(out.getvalue(), r"tmpdir: 4 removed of 4, bytes=[1-9]\d*, not reached=0")

    # stima-api#7106: the eighth kind, a prefix-named mkdtemp directory untouched for 7 days.
    AGED_GONE = ("security-review-gate-z94a16f_", "restart-mbpJmx", ".tmpHXQE3i", "stable-version-E7IlyN")

    def crowd(self, prefix, sep="-", count=25):
        """`count` fresh siblings of a prefix: what a leak has and a person's directory does not."""
        for i in range(count):
            (self.root / f"{prefix}{sep}Cr{i:04d}").mkdir(exist_ok=True)

    def run_quiet(self, clean=True):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            counts = reaper.reap(self.root, self.logs, clean=clean, idle_seconds=HOUR,
                                 send=lambda pid, sig: self.sent.append((pid, sig)))
        return counts, out.getvalue()

    def test_only_old_unheld_prefix_named_mkdtemp_dirs_are_removed_and_check_lists_them(self):
        for prefix, sep in (("security-review-gate", "-"), ("restart", "-"), (".tmp", ""), ("stable-version", "-")):
            self.crowd(prefix, sep)
        gone = [self.leftover(name, 8 * DAY) for name in self.AGED_GONE]
        kept = [self.leftover("restart-mbpJmy", 6 * DAY),               # 7 days not yet up
                self.leftover("restart-deepchg1", 9 * DAY, inner_age=DAY),  # changed deep inside
                self.leftover("restart-heldnam1", 9 * DAY),             # open file or cwd (snapshot)
                self.leftover("restart-lsofsee1", 9 * DAY),             # lsof +D finds a holder
                self.leftover("restart-cmdline1", 9 * DAY),             # named on a command line
                self.leftover("restart-AbCd12", 9 * DAY, file=True),    # a file
                self.leftover("com.apple.foo-AbC123", 9 * DAY),         # the system's
                self.leftover("my-project", 9 * DAY),
                self.leftover("delivery-state-etag", 9 * DAY),
                self.leftover("claude-501", 9 * DAY),
                self.leftover("node-compile-cache", 9 * DAY),
                self.leftover("my-folder", 9 * DAY),                    # six letters, nothing random
                self.leftover("data-pre_post", 9 * DAY),                # eight characters, no digit
                self.leftover("restart-toolong12", 9 * DAY)]            # nine characters
        target = self.leftover("delivery-target", 9 * DAY)
        link = self.root / "restart-lnk123"
        link.symlink_to(target)
        old = time.time() - 9 * DAY
        os.utime(link, (old, old), follow_symlinks=False)
        self.rows.append((77, 1, 10, "node run.js --dir=/x/restart-cmdline1/out"))
        lsof_held = {self.root / "restart-lsofsee1"}
        def run(clean):
            out = io.StringIO()
            with mock.patch.object(reaper, "held", side_effect=lambda path: path in lsof_held), \
                 mock.patch.object(reaper, "holders", side_effect=lambda root, rows: {"restart-heldnam1"}), \
                 mock.patch("sys.stdout", out):
                counts = reaper.reap(self.root, self.logs, clean=clean, idle_seconds=HOUR,
                                     send=lambda pid, sig: None)
            return counts, out.getvalue()
        counts, out = run(clean=False)
        self.assertEqual(counts["aged"], [4, 0])
        self.assertTrue(all(path.exists() for path in gone))
        self.assertRegex(out, r"CANDIDATE aged restart-mbpJmx bytes=\d+")
        self.assertNotIn("restart-lnk123", out)
        counts, out = run(clean=True)
        for path in gone:
            self.assertFalse(path.exists(), path)
        for path in kept + [target]:
            self.assertTrue(path.exists(), path)
        self.assertTrue(link.is_symlink())
        self.assertNotIn("restart-lnk123", out)
        self.assertEqual(counts["aged"], [4, 4])
        self.assertRegex(out, r"REMOVED aged restart-mbpJmx bytes=\d+")
        self.assertRegex(out, r"aged: 4 removed of 4, bytes=[1-9]\d*, not reached=0")

    def test_a_shape_that_is_not_a_leak_is_kept_alone_and_among_siblings(self):
        # Each of these with 25 siblings of its own prefix (a real leak's company) and, for the
        # shapes that do match, alone.
        odd = ["my-Folder", "project-Backup", "com.google.Chrome", "com.docker.Docker", "com.anthropic.Claude",
               "org.python.Python", "com.microsoft.VSCode", "backup-20261101", "backup-202611"]
        for name in odd:
            cut = max(name.rfind("-"), name.rfind("."))
            self.crowd(name[:cut], name[cut])
        alone = ["Xcode-Build1", "data-2026Q4", "nvim.leo123", "pkg-1.0.0-abc123"]
        kept = [self.leftover(name, 9 * DAY) for name in odd + alone]
        counts, out = self.run_quiet(clean=True)
        for path in kept:
            self.assertTrue(path.exists(), path)
        self.assertEqual(counts["aged"], [0, 0])

    def test_nineteen_siblings_are_kept_and_twenty_are_candidates(self):
        few = [self.leftover(f"batch-Ab{i:04d}", 9 * DAY) for i in range(19)]
        many = [self.leftover(f"lot-Ab{i:04d}", 9 * DAY) for i in range(20)]
        counts, out = self.run_quiet(clean=False)
        self.assertEqual(counts["aged"], [20, 0])
        counts, out = self.run_quiet(clean=True)
        self.assertTrue(all(path.exists() for path in few))
        self.assertFalse(any(path.exists() for path in many))
        self.assertEqual(counts["aged"], [20, 20])

    def test_a_tail_of_only_digits_or_one_leading_capital_never_matches(self):
        self.assertIsNone(reaper.aged_prefix("backup-20261101"))
        self.assertIsNone(reaper.aged_prefix("backup-202611"))
        self.assertIsNone(reaper.aged_prefix("my-Folder"))
        self.assertEqual(reaper.aged_prefix("my-Folder", plain=True), "my")       # the plain reading, per crowd
        self.assertEqual(reaper.aged_prefix(".tmpabcdef", plain=True), ".tmp")
        self.assertIsNone(reaper.aged_prefix(".tmp123456", plain=True))
        self.assertIsNone(reaper.aged_prefix("data-lowerabc"))     # eight lower case, no digit
        self.assertIsNone(reaper.aged_prefix("com.microsoft.VSCode"))
        for name in ("io.sentry.Ab12Cd", "app.x.Ab12Cd", "net.y.z0z0z0"):
            self.assertIsNone(reaper.aged_prefix(name), name)
        self.assertEqual(reaper.aged_prefix("restart-mbpJmx"), "restart")
        self.assertEqual(reaper.aged_prefix("restart-bpJmxa"), "restart")  # an upper-case letter not first
        self.assertEqual(reaper.aged_prefix("restart-JKmxab"), "restart")  # two upper-case letters
        self.assertEqual(reaper.aged_prefix("restart-abcde1"), "restart")  # a digit
        self.assertEqual(reaper.aged_prefix("security-review-gate-z94a16f_"), "security-review-gate")
        self.assertEqual(reaper.aged_prefix(".tmpHXQE3i"), ".tmp")

    def plain(self, prefix, count, tail="rpllrrv", age=9 * DAY):
        """`count` old directories of a prefix whose tails have no digit, as one in twelve of Python's do."""
        return [self.leftover(f"{prefix}-{'abcdefghijklmnopqrstuvwxyz'[i]}{tail}", age) for i in range(count)]

    def test_a_tail_that_does_not_look_random_goes_with_twenty_siblings_like_it(self):
        # 2026-11-21: a pass that ended `not reached=0` left 2,000 directories idle past the 7 days whose tails
        # do not look random: `security-review-gate-srpllrrv`, `preview-unpack-ymqbwn`, `restart-Wycuml`.
        gone = (self.plain("security-review-gate", 20) + self.plain("preview-unpack", 20, tail="mqbwn")
                + [self.leftover(f"restart-{c}ycuml", 9 * DAY) for c in "ABCDEFGHIJKLMNOPQRST"]
                + [self.leftover("restart-backup", 9 * DAY)])            # a word of the crowd's length goes with it
        self.crowd("neo-feed")                                           # siblings that look random are not its company
        kept = (self.plain("neo-feed", 19)
                + [self.leftover(f"report-202611{i:02d}", 9 * DAY) for i in range(20)]   # dated, however many
                + [self.leftover(f"log-2026{i:02d}", 9 * DAY) for i in range(20)]
                + self.plain("stall-audit-selftest", 20, age=6 * DAY)    # 7 days not yet up
                + [self.leftover("restart-fixtures", 9 * DAY)])          # a word of another length has no company
        counts, out = self.run_quiet(clean=False)
        self.assertEqual(counts["aged"], [61, 0])
        self.assertRegex(out, r"CANDIDATE aged security-review-gate-arpllrrv bytes=\d+")
        counts, out = self.run_quiet(clean=True)
        for path in gone:
            self.assertFalse(path.exists(), path)
        for path in kept:
            self.assertTrue(path.exists(), path)
        self.assertEqual(counts["aged"], [61, 61])

    def test_a_python_tail_with_an_underscore_second_is_read_as_its_eight_characters(self):
        # Read as six characters after `_`, `security-review-gate-r_2chwxv` had the prefix `security-review-gate-r`:
        # one name in 37 of a leak, split 37 ways with no twenty among them (386 left on 2026-11-21).
        self.assertEqual(reaper.aged_prefix("security-review-gate-r_2chwxv"), "security-review-gate")
        gone = [self.leftover(f"security-review-gate-{c}_2chwxv", 9 * DAY) for c in "abcdefghijklmnopqrst"]
        counts, out = self.run_quiet(clean=True)
        for path in gone:
            self.assertFalse(path.exists(), path)
        self.assertEqual(counts["aged"], [20, 20])

    def test_a_tree_with_an_old_mtime_and_a_fresh_ctime_is_kept(self):
        self.crowd("restart")
        carried = self.leftover("restart-carried1", 9 * DAY)        # a file unpacked with its old mtime
        top = self.leftover("restart-carried2", 9 * DAY)            # the entry itself moved in
        dated = self.leftover("tmp_carriedx", 4 * DAY)
        goish = self.leftover("go-build4242", 3 * HOUR)
        control = self.leftover("restart-control1", 9 * DAY)
        fresh = time.time() - HOUR
        self.ctimes[str(carried / "deep" / "f")] = fresh
        self.ctimes[str(top)] = fresh
        self.ctimes[str(dated / "deep")] = fresh
        self.ctimes[str(goish / "deep" / "f")] = fresh
        counts, out = self.run_quiet()
        for path in (carried, top, dated, goish):
            self.assertTrue(path.exists(), path)
        self.assertFalse(control.exists())
        self.assertEqual(counts["aged"], [1, 1])
        self.assertEqual((counts["tmpdir"], counts["leftover"]), ([0, 0], [0, 0]))

    def test_newest_change_reads_the_real_ctime(self):
        path = self.leftover("restart-realctime", 9 * DAY)
        with mock.patch.object(reaper, "os", os):
            newest = reaper.newest_change(path)
        self.assertGreater(newest, time.time() - 60)   # os.utime sets mtime; the ctime is now

    def test_a_tree_holding_a_socket_is_kept(self):
        self.crowd("restart")
        trees = [self.leftover("restart-sockdir1", 9 * DAY), self.leftover("tmp_socketx", 4 * DAY),
                 self.leftover("go-build9191", 3 * HOUR)]
        for tree in trees:
            # A relative name keeps the path inside sun_path's 104 bytes.
            sock = socket.socket(socket.AF_UNIX)
            self.addCleanup(sock.close)
            cwd = os.getcwd()
            os.chdir(tree)
            try:
                sock.bind("s")
            finally:
                os.chdir(cwd)
            self.aged(tree / "s", 9 * DAY)
            self.aged(tree, 9 * DAY)
        counts, out = self.run_quiet()
        for tree in trees:
            self.assertTrue(tree.exists(), tree)
            self.assertIn(f"KEEP {'aged' if tree.name.startswith('restart') else 'tmpdir' if tree.name.startswith('tmp_') else 'leftover'}"
                          f" {tree.name} (socket)\n", out)
        self.assertEqual((counts["aged"], counts["tmpdir"], counts["leftover"]), ([0, 0], [0, 0], [0, 0]))

    def test_aged_leaves_what_an_earlier_kind_or_a_link_is_to_its_own_rule(self):
        # check mode keeps everything where it is, so a wrong take-over would be printed as `aged`.
        for prefix in ("restart", "cdp", "nimbus-articles-build", "hold", "neo-rot", "pip-unpack"):
            self.crowd(prefix)
        for name in ("restart-Ab12Cd",):
            self.leftover(name, 9 * DAY)
        for name in ("cdp-Ab12Cd", "nimbus-articles-build-Ab12Cd", "hold-Ab12Cd", "neo-rot-Ab12Cd"):
            self.leftover(name, 9 * DAY)
        target = self.leftover("delivery-target", 9 * DAY)
        link = self.root / "restart-lnk123"
        link.symlink_to(target)
        old = time.time() - 9 * DAY
        os.utime(link, (old, old), follow_symlinks=False)
        counts, out = self.run_quiet(clean=False)
        self.assertIn("CANDIDATE aged restart-Ab12Cd bytes=", out)
        self.assertNotRegex(out, r"(CANDIDATE|REMOVED|KEEP) aged (restart-lnk123|cdp-|nimbus-articles-build-|hold-|neo-rot-)")
        self.assertEqual(counts["aged"][0], 1)
        self.assertTrue(link.is_symlink() and target.exists())

    def test_an_aged_dir_a_failing_lsof_cannot_clear_is_kept(self):
        self.crowd("restart")
        path = self.leftover("restart-unsure1", 9 * DAY)
        with mock.patch.object(reaper, "held", side_effect=REAL_HELD), \
             mock.patch.object(reaper.subprocess, "run", side_effect=OSError("no lsof")):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(counts["aged"], [0, 0])

    def test_an_aged_dir_a_real_process_cwd_holds_is_kept(self):
        self.crowd("restart")
        path = self.leftover("restart-cwdhold1", 9 * DAY)
        child = subprocess.Popen(["sleep", "30"], cwd=path / "deep")
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        with mock.patch.object(reaper, "held", side_effect=REAL_HELD), \
             mock.patch.object(reaper, "holders", side_effect=REAL_HOLDERS):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(counts["aged"], [0, 0])

    def test_no_holder_snapshot_keeps_every_aged_dir(self):
        self.crowd("restart")
        path = self.leftover("restart-nosnap01", 9 * DAY)
        with mock.patch.object(reaper, "holders", return_value=None):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(counts["aged"], [0, 0])

    def test_a_name_an_earlier_rule_owns_keeps_that_rules_idle_limit(self):
        for prefix in ("hold", "neo-rot", "restart"):
            self.crowd(prefix)
        taken = [self.leftover("tmpab12cd34", DAY + HOUR),          # leftover rule: a day, not seven
                 self.leftover("go-build123456", 3 * HOUR),         # go: two hours
                 self.leftover("tmp_sriaqhi", 2 * DAY + HOUR),      # tmpdir rule: 48 h
                 self.leftover("hold-Ab12Cd", 2 * DAY),             # a name that also has the aged shape
                 self.leftover("neo-rot-Ab12Cd", 2 * DAY)]
        young = [self.leftover("tmpab12cd35", DAY - HOUR),
                 self.leftover("go-build123457", HOUR),
                 self.leftover("tmp_sriaqhj", 2 * DAY - HOUR),
                 self.leftover("hold-Ab12Ce", 12 * HOUR),           # a day not yet up for the leftover rule
                 self.leftover("restart-Zz12Cd", 6 * DAY)]          # aged proper, 7 days not yet up
        counts = self.run_clean()
        for path in taken:
            self.assertFalse(path.exists(), path)
        for path in young:
            self.assertTrue(path.exists(), path)
        self.assertEqual(counts["aged"], [0, 0])
        self.assertEqual((counts["leftover"], counts["tmpdir"]), ([4, 4], [1, 1]))

    def test_the_budget_is_shared_with_tmpdir_and_leaves_the_rest_not_reached_oldest_first(self):
        self.crowd("restart")
        self.leftover("tmp_budgetx", 4 * DAY)
        names = ["restart-Ab12Cd", "restart-Bb12Cd", "restart-Cb12Cd", "restart-Db12Cd", "restart-Eb12Cd"]
        for i, name in enumerate(names):
            self.leftover(name, (9 + i) * DAY)       # Eb12Cd is the oldest
        clock = [0.0]
        real = reaper.shutil.rmtree
        def rmtree(path, *a, **k):
            clock[0] += 1.0                           # every removal costs a second
            return real(path, *a, **k)
        fake = types.SimpleNamespace(time=time.time, monotonic=lambda: clock[0])
        out = io.StringIO()
        with mock.patch.object(reaper, "time", fake), \
             mock.patch.object(reaper.shutil, "rmtree", side_effect=rmtree), mock.patch("sys.stdout", out):
            # tmpdir takes the first second; the budget (2.5 s) then lets two aged ones go.
            counts = reaper.reap(self.root, self.logs, clean=True, idle_seconds=HOUR, tmpdir_budget=2.5,
                                 send=lambda pid, sig: None)
        self.assertEqual(counts["tmpdir"], [1, 1])
        self.assertEqual(counts["aged"], [2, 2])
        self.assertEqual([n for n in names if not (self.root / n).exists()],
                         ["restart-Db12Cd", "restart-Eb12Cd"])
        self.assertRegex(out.getvalue(), r"aged: 2 removed of 2, bytes=[1-9]\d*, not reached=3 \(budget 2.5s\)")
        self.assertRegex(out.getvalue(), r"tmpdir: 1 removed of 1, bytes=[1-9]\d*, not reached=0")
        summary = " ".join(f"{k}={v[1]}/{v[0]}" for k, v in counts.items())
        self.assertTrue(summary.endswith("tmpdir=1/1 aged=2/2"), summary)

    def test_aged_dirs_outside_the_per_user_temp_directory_are_never_swept(self):
        self.crowd("restart")
        path = self.leftover("restart-outside1", 9 * DAY)
        with mock.patch.object(reaper, "USER_TEMP_PREFIX", "/no/such/prefix/"):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(counts["aged"], [0, 0])

    def test_holders_reads_a_doubled_slash_path_as_the_name_under_the_root(self):
        stdout = (f"p1\0\nn{self.root}//x/y\0n{self.root}/z\0n{self.root}/./w/q\0"
                  f"n{self.root}/../outside\0n/elsewhere/{self.root.name}/v\0").encode()
        probe = types.SimpleNamespace(returncode=0, stderr=b"", stdout=stdout)
        with mock.patch.object(reaper.subprocess, "run", return_value=probe):
            names = REAL_HOLDERS(self.root, [])
        self.assertEqual(names, {"x", "z", "w"})

    def test_a_tmp_dir_link_is_never_followed(self):
        target = self.leftover("tmp_targetx", 3 * DAY)
        (self.root / "tmp_linkone").symlink_to(target)
        old = time.time() - 3 * DAY
        os.utime(self.root / "tmp_linkone", (old, old), follow_symlinks=False)  # as old as a real one
        counts = self.run_clean()
        self.assertEqual(counts["tmpdir"], [1, 1])
        self.assertTrue((self.root / "tmp_linkone").is_symlink())

    def test_an_inconclusive_lsof_keeps_a_tmp_dir(self):
        path = self.leftover("tmp_unsurex", 3 * DAY)
        with mock.patch.object(reaper, "held", side_effect=REAL_HELD), \
             mock.patch.object(reaper.subprocess, "run", side_effect=OSError("no lsof")):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(counts["tmpdir"], [0, 0])

    def test_no_holder_snapshot_keeps_every_tmp_dir(self):
        path = self.leftover("tmp_nosnapx", 3 * DAY)
        out = io.StringIO()
        with mock.patch.object(reaper, "holders", return_value=None), mock.patch("sys.stdout", out):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(counts["tmpdir"], [0, 0])
        self.assertIn("aged: skipped (no holder snapshot)\n", out.getvalue())

    def test_past_its_budget_a_run_leaves_the_rest_for_the_next(self):
        path = self.leftover("tmp_budgetx", 3 * DAY)
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            counts = reaper.reap(self.root, self.logs, clean=True, idle_seconds=HOUR, tmpdir_budget=-1,
                                 send=lambda pid, sig: None)
        self.assertTrue(path.exists())
        self.assertEqual(counts["tmpdir"], [0, 0])
        self.assertIn("not reached=1", out.getvalue())

    def test_tmp_dirs_are_only_listed_without_clean(self):
        path = self.leftover("tmp_listedx", 3 * DAY)
        counts = reaper.reap(self.root, self.logs, clean=False, jobs_dir=self.jobs)
        self.assertTrue(path.exists())
        self.assertEqual(counts["tmpdir"], [1, 0])

    def test_a_leftover_reaching_another_filesystem_is_kept(self):
        path = self.leftover("go-build79", DAY + HOUR)
        real = reaper.os.lstat
        def lstat(p, *a, **k):
            st = real(p, *a, **k)
            if str(p).endswith("/deep/f"):
                return types.SimpleNamespace(**{**vars(st), "st_dev": st.st_dev + 1})
            return st
        with mock.patch.object(reaper.os, "lstat", side_effect=lstat):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(counts["leftover"], [0, 0])

    def test_a_failed_ps_while_removing_keeps_the_rest(self):
        path = self.leftover("go-build80", DAY + HOUR)
        calls = []
        def processes(env=False):
            calls.append(env)
            return list(self.rows) if len(calls) == 1 else None
        with mock.patch.object(reaper, "processes", side_effect=processes):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(calls[1:], [True], "the holder scan reads environments")
        self.assertEqual(counts["leftover"], [0, 0])

    def test_only_the_per_user_temp_directory_is_swept(self):
        path = self.leftover("go-build81", DAY + HOUR)
        # The fixtures live under this user's temp directory; any other root is refused.
        with mock.patch.object(reaper, "USER_TEMP_PREFIX", "/no/such/prefix/"):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(counts["leftover"], [0, 0])

    def test_the_holder_scan_reads_environments(self):
        rows = REAL_PROCESSES(env=True)
        self.assertIsNotNone(rows)
        me = next(r for r in rows if r[0] == os.getpid())
        self.assertIn("PATH=", me[3])

    def test_leftovers_are_only_listed_without_clean(self):
        path = self.leftover("go-build77", DAY + HOUR)
        counts = reaper.reap(self.root, self.logs, clean=False, jobs_dir=self.jobs)
        self.assertTrue(path.exists())
        self.assertEqual(counts["leftover"], [1, 0])

    def test_no_lsof_answer_keeps_every_leftover(self):
        path = self.leftover("go-build78", DAY + HOUR)
        with mock.patch.object(reaper, "holders", return_value=None):
            counts = self.run_clean()
        self.assertTrue(path.exists())
        self.assertEqual(counts["leftover"], [0, 0])

    def test_holders_reads_open_files_cwds_and_command_lines(self):
        inside = self.root / "tmpcwdcwd01"
        (inside / "sub").mkdir(parents=True)
        opened = self.root / "tmpopen0001"
        opened.mkdir()
        named = self.root / "tmpnamed001"
        named.mkdir()
        idle_dir = self.root / "tmpidle0001"
        idle_dir.mkdir()
        child = subprocess.Popen(["sleep", "30"], cwd=inside / "sub")
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        handle = open(opened / "f", "w")
        self.addCleanup(handle.close)
        rows = [(1, 1, 0, f"python3 {named}/x.py"),
                (2, 1, 0, f"docker run -v {self.root}//tmpslash001:/cfg img"),
                (3, 1, 0, "python3 tmprel00001/x.py"),
                (4, 1, 0, f"node server.js PYTHONPATH={self.root}//tmpenvenv01 HOME=/x")]
        names = REAL_HOLDERS(self.root, rows)
        for held in ("tmpcwdcwd01", "tmpopen0001", "tmpnamed001", "tmpslash001", "tmprel00001",
                     "tmpenvenv01"):
            self.assertIn(held, names)
        self.assertNotIn("tmpidle0001", names)

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
