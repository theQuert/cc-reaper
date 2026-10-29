#!/usr/bin/env python3
"""Isolated tests for gce-disk-watch: the gcloud call is a stub runner and the notification a stub notifier, every
path is a temp path, nothing reaches a GCE host or the real inbox. Covers the df parse (ctl-1's real full output of
2026-10-30), the judge, unreadable and timeout reads, one alert per state change, the re-alert window, the recovery
line, shadow against apply, a failed write kept pending, and that the only remote command is the df read."""

import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "shell" / "gce-disk-watch.py"
spec = importlib.util.spec_from_file_location("gce_disk_watch", SOURCE)
gdw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gdw)

HOSTS = ["stima-ci-1", "stima-ci-2", "stima-ci-3", "stima-ci-ctl-1", "stima-ci-deploy-1"]
# What `df -P / ; df -Pi /` printed on stima-ci-ctl-1 with its root full (read by the lead, 2026-10-30).
CTL1_FULL = ("Filesystem     1024-blocks     Used Available Capacity Mounted on\n"
             "/dev/root         19221248 19204864         0     100% /\n"
             "Filesystem      Inodes  IUsed   IFree IUse% Mounted on\n"
             "/dev/root       2432000 194560 2237440    8% /\n")
HEALTHY = ("Filesystem     1024-blocks     Used Available Capacity Mounted on\n"
           "/dev/root         50620216 20248064  30355768      41% /\n"
           "Filesystem      Inodes  IUsed   IFree IUse% Mounted on\n"
           "/dev/root       6451200 401234 6049966    7% /\n")
LOW_AVAIL = HEALTHY.replace("50620216 20248064  30355768      41%", "50620216 48620216   1572864      85%")  # 1.5 GiB
INODES_FULL = HEALTHY.replace("401234 6049966    7%", "6000000  451200   93%")


class Clock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


class Runner:
    """Stub gcloud: per-host (rc, stdout, reason); records each call's argv."""

    def __init__(self, outputs):
        self.outputs, self.calls = dict(outputs), []

    def __call__(self, cfg, host, timeout):
        self.calls.append((host, gdw.gcloud_argv(cfg, host), timeout))
        out = self.outputs.get(host, (0, HEALTHY, None))
        if isinstance(out, Exception):
            raise out
        return out


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.clock = Clock()
        self.notes = []
        self.notify_fails = False
        gdw.print = lambda *a, **k: None  # the log file and Watch.lines carry every line; keep the test output quiet
        self.addCleanup(delattr, gdw, "print")

    def cfg(self, **over):
        cfg = gdw.load_config(self.tmp / "absent.conf", env={})
        key = self.tmp / "ssh" / "google_compute_engine"
        if not key.parent.exists():
            key.parent.mkdir()
            key.write_text("k")
            key.with_name(key.name + ".pub").write_text("k.pub")
        cfg.update(GDW_SSH_KEY=str(key),
                   GDW_INBOX=str(self.tmp / "handoffs" / "neo-inbox.md"),
                   GDW_EVENTS_LOG=str(self.tmp / "handoffs" / "ops-dispatch" / "events.log"),
                   GDW_STATE=str(self.tmp / "state" / "gce-disk-watch.json"),
                   GDW_LOG=str(self.tmp / "logs" / "gce-disk-watch.log"))
        cfg.update(over)
        return cfg

    def notifier(self, title, text):
        if self.notify_fails:
            raise OSError("osascript exit 1")
        self.notes.append((title, text))

    def run_once(self, outputs, **over):
        runner = Runner(outputs)
        w = gdw.Watch(self.cfg(**over), runner, self.notifier, self.clock)
        rc = w.run(HOSTS)
        return rc, w.lines, runner

    def inbox(self):
        p = self.tmp / "handoffs" / "neo-inbox.md"
        return p.read_text() if p.exists() else ""

    def events(self):
        p = self.tmp / "handoffs" / "ops-dispatch" / "events.log"
        return p.read_text().splitlines() if p.exists() else []

    def summary(self, lines):
        return [l for l in lines if " hosts, " in l][-1]


class Parse(Base):
    def test_ctl1_full_output_parses_and_is_disk_high(self):
        m = gdw.parse_df(CTL1_FULL)
        self.assertEqual(m, {"used_pct": 100, "avail_kb": 0, "inode_pct": 8})
        self.assertEqual(gdw.judge(self.cfg(), m), gdw.HIGH)

    def test_healthy_is_ok_and_each_threshold_fires(self):
        cfg = self.cfg()
        self.assertEqual(gdw.judge(cfg, gdw.parse_df(HEALTHY)), gdw.OK)
        self.assertEqual(gdw.judge(cfg, gdw.parse_df(LOW_AVAIL)), gdw.HIGH)  # 85% used but 1.5 GiB left
        self.assertEqual(gdw.judge(cfg, gdw.parse_df(INODES_FULL)), gdw.HIGH)
        self.assertEqual(gdw.judge(cfg, {"used_pct": 90, "avail_kb": 10 << 20, "inode_pct": 1}), gdw.HIGH)
        self.assertEqual(gdw.judge(cfg, {"used_pct": 89, "avail_kb": 10 << 20, "inode_pct": None}), gdw.OK)

    def test_output_without_a_root_line_is_no_reading(self):
        self.assertIsNone(gdw.parse_df(""))
        self.assertIsNone(gdw.parse_df("ssh: connect to host stima-ci-1 port 22: Connection timed out\n"))
        self.assertIsNone(gdw.parse_df(CTL1_FULL.replace(" /\n", " /boot\n")))

    def test_the_only_remote_command_is_the_df_read(self):
        argv = gdw.gcloud_argv(self.cfg(), "stima-ci-ctl-1")
        self.assertEqual(argv[argv.index("--command") + 1], "df -P / ; df -Pi /")
        self.assertEqual(argv.count("--command"), 1)
        self.assertIn("--tunnel-through-iap", argv)
        self.assertIn("BatchMode=yes", argv)
        self.assertEqual(argv[argv.index("--project") + 1], "stima-ci-runners")
        self.assertEqual(argv[argv.index("--zone") + 1], "asia-east1-b")

    def test_config_file_then_environment(self):
        conf = self.tmp / "gdw.conf"
        conf.write_text("GDW_HOSTS=a-1 b-2\nGDW_USED_PCT=80\nNOT_OURS=x\n")
        cfg = gdw.load_config(conf, env={"GDW_USED_PCT": "70"})
        self.assertEqual(cfg["GDW_HOSTS"], "a-1 b-2")
        self.assertEqual(cfg["GDW_USED_PCT"], "70")
        self.assertNotIn("NOT_OURS", cfg)
        self.assertEqual(gdw.load_config(self.tmp / "none", env={})["GDW_HOSTS"].split(), HOSTS)


class Runs(Base):
    def test_ctl1_full_fires_disk_high_and_healthy_hosts_do_not(self):
        rc, lines, runner = self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)})
        self.assertEqual(rc, 0)
        would = [l for l in lines if "would alert" in l]
        self.assertEqual(len(would), 1)
        self.assertIn("would alert stima-ci-ctl-1 disk-high used=100% avail=0.0GB inodes=8%", would[0])
        self.assertEqual(sorted(h for h, _, _ in runner.calls), sorted(HOSTS))
        self.assertIn("5 hosts, 5 read, 1 high, 0 unreadable, 1 would-alert, 0 alerted, 0 recovered, 0 failures",
                      self.summary(lines))

    def test_unreadable_and_timeout_are_their_own_kind_and_never_stop_the_others(self):
        bad = {"stima-ci-1": (255, "", None), "stima-ci-2": (None, "", "timeout"),
               "stima-ci-3": RuntimeError("boom"), "stima-ci-deploy-1": (0, "garbage\n", None)}
        rc, lines, _ = self.run_once(bad)
        self.assertEqual(rc, 0)
        self.assertNotIn("would alert", "\n".join(lines))  # one unreadable round is not told
        self.assertIn("host stima-ci-1 unreadable used=? avail=? inodes=? reason=exit-255 fails=1/2", "\n".join(lines))
        self.assertIn("unreadable: stima-ci-1(exit-255) stima-ci-2(timeout) stima-ci-3(runner-RuntimeError) "
                      "stima-ci-deploy-1(no-df-output)", self.summary(lines))
        self.clock.t += 600
        rc, lines, _ = self.run_once(bad)
        self.assertEqual(rc, 0)
        self.assertIn("would alert stima-ci-1 unreadable used=? avail=? inodes=? reason=exit-255", "\n".join(lines))
        self.assertIn("would alert stima-ci-2 unreadable used=? avail=? inodes=? reason=timeout", "\n".join(lines))
        self.assertIn("would alert stima-ci-3 unreadable used=? avail=? inodes=? reason=runner-RuntimeError", "\n".join(lines))
        self.assertIn("would alert stima-ci-deploy-1 unreadable used=? avail=? inodes=? reason=no-df-output", "\n".join(lines))
        self.assertIn("host stima-ci-ctl-1 ok used=41%", "\n".join(lines))
        self.assertIn("5 hosts, 1 read, 0 high, 4 unreadable, 4 would-alert", self.summary(lines))
        self.assertNotIn("garbage", "\n".join(lines))  # the command's output never reaches a record

    def test_the_real_runner_times_out_its_own_child(self):
        fake = self.tmp / "fake-gcloud"
        fake.write_text("#!/bin/sh\nsleep 30\n")
        fake.chmod(0o755)
        rc, out, reason = gdw.gcloud_runner(self.cfg(GDW_GCLOUD=str(fake)), "stima-ci-1", 1)
        self.assertEqual((rc, out, reason), (None, "", "timeout"))
        self.assertEqual(gdw.gcloud_runner(self.cfg(GDW_GCLOUD=str(self.tmp / "missing")), "stima-ci-1", 1)[2], "no-gcloud")

    def test_one_alert_per_state_change(self):
        full = {"stima-ci-ctl-1": (0, CTL1_FULL, None)}
        self.run_once(full, GDW_APPLY="1")
        for _ in range(5):
            self.clock.t += 600
            rc, lines, _ = self.run_once(full, GDW_APPLY="1")
            self.assertEqual(rc, 0)
            self.assertIn("0 alerted", self.summary(lines))
        self.assertEqual(self.inbox().count("## EL-T24-GCE-DISK stima-ci-ctl-1"), 1)
        self.assertEqual(len(self.events()), 1)
        self.assertEqual(len(self.notes), 1)
        self.clock.t += 600  # a different bad state is a new state change
        self.run_once({"stima-ci-ctl-1": (255, "", None)}, GDW_APPLY="1")
        self.assertEqual(self.inbox().count("## EL-T24-GCE-DISK stima-ci-ctl-1"), 1)  # held at disk-high for one round
        self.clock.t += 600
        self.run_once({"stima-ci-ctl-1": (255, "", None)}, GDW_APPLY="1")
        self.assertEqual(self.inbox().count("## EL-T24-GCE-DISK stima-ci-ctl-1"), 2)
        self.assertIn("kind=unreadable", self.inbox())

    def test_re_alert_window(self):
        full = {"stima-ci-ctl-1": (0, CTL1_FULL, None)}
        self.run_once(full, GDW_APPLY="1")
        self.clock.t += 119 * 60
        self.run_once(full, GDW_APPLY="1")
        self.assertEqual(len(self.events()), 1)
        self.clock.t += 60
        _, lines, _ = self.run_once(full, GDW_APPLY="1")
        self.assertEqual(len(self.events()), 2)
        self.assertIn("P0 GCE-DISK stima-ci-ctl-1 disk-high", self.events()[1])
        self.assertIn("1 alerted", self.summary(lines))
        self.assertEqual(self.inbox().count("## EL-T24-GCE-DISK"), 1)  # the inbox gets state changes only
        self.assertEqual(len(self.notes), 2)
        self.clock.t += 60
        self.run_once(full, GDW_APPLY="1")
        self.assertEqual(len(self.events()), 2)  # the window restarts at the re-alert
        self.clock.t += 120 * 60
        self.run_once(full, GDW_APPLY="1", GDW_REALERT_INBOX="1")
        self.assertEqual(self.inbox().count("## EL-T24-GCE-DISK"), 2)
        self.assertIn("GCE-DISK STILL host=stima-ci-ctl-1", self.inbox())

    def test_recovery_line_once(self):
        self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)}, GDW_APPLY="1")
        for _ in range(3):
            self.clock.t += 600
            _, lines, _ = self.run_once({}, GDW_APPLY="1")
        self.assertEqual(self.inbox().count("GCE-DISK RECOVERED host=stima-ci-ctl-1"), 1)
        self.assertEqual([l.split(" ", 1)[1] for l in self.events()][1:],
                         ["INFO GCE-DISK stima-ci-ctl-1 recovered used=41% avail=28.9GB inodes=7%"])
        self.assertEqual(len(self.notes), 2)
        self.assertIn("0 recovered", self.summary(lines))
        # A healthy host never says it recovered.
        self.assertNotIn("stima-ci-1 ", self.inbox() + "\n".join(self.events()))

    def test_shadow_writes_nothing_outside_its_log(self):
        self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)})
        self.clock.t += 600
        _, lines, _ = self.run_once({})
        self.assertIn("would recover stima-ci-ctl-1 recovered", "\n".join(lines))
        self.assertEqual(self.notes, [])
        written = sorted(str(p.relative_to(self.tmp)) for p in self.tmp.rglob("*")
                         if p.is_file() and p.parent.name != "ssh")  # ssh/: the test's own key fixture
        self.assertEqual(written, ["logs/gce-disk-watch.log", "state/gce-disk-watch.json"])
        self.assertIn("would alert stima-ci-ctl-1 disk-high", (self.tmp / "logs" / "gce-disk-watch.log").read_text())

    def test_apply_writes_inbox_events_and_notification(self):
        rc, lines, _ = self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)}, GDW_APPLY="1")
        self.assertEqual(rc, 0)
        self.assertIn("\n## EL-T24-GCE-DISK stima-ci-ctl-1\n\nGCE-DISK ALERT host=stima-ci-ctl-1 kind=disk-high "
                      "used=100% avail=0.0GB inodes=8% project=stima-ci-runners zone=asia-east1-b at=", self.inbox())
        ev = self.events()
        self.assertEqual(len(ev), 1)
        self.assertRegex(ev[0], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4} P0 GCE-DISK stima-ci-ctl-1 disk-high "
                                r"used=100% avail=0\.0GB inodes=8%$")
        self.assertEqual(self.notes, [("GCE disk", "stima-ci-ctl-1 disk-high used=100% avail=0.0GB inodes=8%")])
        self.assertIn("1 alerted", self.summary(lines))
        self.assertNotIn("would alert", "\n".join(lines))
        st = json.loads((self.tmp / "state" / "gce-disk-watch.json").read_text())
        self.assertEqual(set(st), {"apply"})

    def test_a_switch_from_shadow_to_apply_alerts_afresh(self):
        self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)})
        self.clock.t += 600
        self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)}, GDW_APPLY="1")
        self.assertEqual(self.inbox().count("## EL-T24-GCE-DISK stima-ci-ctl-1"), 1)

    def test_a_failed_write_keeps_state_and_retries_that_channel_alone(self):
        full = {"stima-ci-ctl-1": (0, CTL1_FULL, None)}
        blocker = self.tmp / "handoffs"
        blocker.write_text("not a directory")  # the inbox and events log cannot be written under a file
        rc, lines, _ = self.run_once(full, GDW_APPLY="1")
        self.assertEqual(rc, 1)
        self.assertIn("ERROR stima-ci-ctl-1: inbox write failed", "\n".join(lines))
        self.assertIn("ERROR stima-ci-ctl-1: events write failed", "\n".join(lines))
        self.assertIn("0 alerted", self.summary(lines))
        self.assertIn("2 failures", self.summary(lines))
        self.assertEqual(len(self.notes), 1)  # the notification still went out
        st = json.loads((self.tmp / "state" / "gce-disk-watch.json").read_text())["apply"]["stima-ci-ctl-1"]
        self.assertEqual(st["todo"], ["inbox", "events"])
        blocker.unlink()
        self.clock.t += 600
        rc, lines, _ = self.run_once(full, GDW_APPLY="1")
        self.assertEqual(rc, 0)
        self.assertEqual(self.inbox().count("## EL-T24-GCE-DISK stima-ci-ctl-1"), 1)
        self.assertEqual(len(self.events()), 1)
        self.assertEqual(len(self.notes), 1)  # the channel that worked is not repeated
        self.assertIn("1 alerted", self.summary(lines))
        self.clock.t += 600
        self.run_once(full, GDW_APPLY="1")
        self.assertEqual(len(self.events()), 1)

    def test_a_failed_notification_is_retried(self):
        self.notify_fails = True
        rc, lines, _ = self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)}, GDW_APPLY="1")
        self.assertEqual(rc, 1)
        self.notify_fails = False
        self.clock.t += 600
        self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)}, GDW_APPLY="1")
        self.assertEqual(len(self.notes), 1)
        self.assertEqual(len(self.events()), 1)

    def test_a_bad_host_name_is_refused_and_never_reaches_gcloud(self):
        runner = Runner({})
        w = gdw.Watch(self.cfg(), runner, self.notifier, self.clock)
        rc = w.run(["stima-ci-1", "x;rm -rf /", "--command=id"])
        self.assertEqual(rc, 1)
        self.assertEqual([h for h, _, _ in runner.calls], ["stima-ci-1"])

    def test_a_stuck_runner_is_bounded_by_the_run_timeout(self):
        import threading
        gate = threading.Event()

        def stuck(cfg, host, timeout):
            if host == "stima-ci-2":
                gate.wait(30)
            return 0, HEALTHY, None

        w = gdw.Watch(self.cfg(GDW_RUN_TIMEOUT_SECONDS="1", GDW_UNREADABLE_ROUNDS="1"), stuck, self.notifier, self.clock)
        orig = gdw.concurrent.futures.wait
        gdw.concurrent.futures.wait = lambda fs, timeout: orig(fs, timeout=min(timeout, 2))
        try:
            rc = w.run(HOSTS)
        finally:
            gdw.concurrent.futures.wait = orig
            gate.set()
        self.assertEqual(rc, 0)
        self.assertIn("would alert stima-ci-2 unreadable used=? avail=? inodes=? reason=run-timeout", "\n".join(w.lines))
        self.assertIn("4 read", self.summary(w.lines))


class Review(Base):
    """The Opus review of f2d6096: unreadable rounds, damaged state, shadow channels, the ssh key."""

    def state(self):
        return json.loads((self.tmp / "state" / "gce-disk-watch.json").read_text())

    def write_state(self, st):
        (self.tmp / "state").mkdir(exist_ok=True)
        (self.tmp / "state" / "gce-disk-watch.json").write_text(json.dumps(st))

    def test_one_transient_unreadable_read_is_not_told_and_a_second_is(self):
        blip = {"stima-ci-1": (255, "", None)}
        _, lines, _ = self.run_once(blip, GDW_APPLY="1")
        self.assertEqual(self.events(), [])
        self.assertEqual(self.state()["apply"]["stima-ci-1"]["fails"], 1)
        self.clock.t += 600
        self.run_once({}, GDW_APPLY="1")  # it read fine: the counter resets, nothing was told, nothing recovers
        self.assertEqual(self.state()["apply"]["stima-ci-1"]["fails"], 0)
        self.clock.t += 600
        self.run_once(blip, GDW_APPLY="1")
        self.assertEqual(self.events(), [])  # 1, 0, 1: never two in a row
        self.clock.t += 600
        _, lines, _ = self.run_once(blip, GDW_APPLY="1")
        self.assertEqual(len(self.events()), 1)
        self.assertIn("P0 GCE-DISK stima-ci-1 unreadable used=? avail=? inodes=? reason=exit-255", self.events()[0])
        self.assertIn("host stima-ci-1 unreadable used=? avail=? inodes=? reason=exit-255 fails=2/2", "\n".join(lines))

    def test_disk_high_still_alerts_on_the_first_read_and_a_blip_does_not_recover_it(self):
        self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)}, GDW_APPLY="1")
        self.assertEqual(len(self.events()), 1)
        self.clock.t += 600
        self.run_once({"stima-ci-ctl-1": (None, "", "timeout")}, GDW_APPLY="1")
        self.assertEqual(len(self.events()), 1)
        self.assertEqual(self.state()["apply"]["stima-ci-ctl-1"]["kind"], "disk-high")

    def test_rounds_of_one_tells_the_first_unreadable_read(self):
        self.run_once({"stima-ci-1": (255, "", None)}, GDW_APPLY="1", GDW_UNREADABLE_ROUNDS="1")
        self.assertEqual(len(self.events()), 1)

    def test_a_known_unreadable_host_is_read_every_round_and_never_told_unreadable(self):
        refused = {"stima-ci-1": (255, "", None)}
        for _ in range(4):
            _, lines, runner = self.run_once(refused, GDW_APPLY="1", GDW_KNOWN_UNREADABLE="stima-ci-1")
            self.clock.t += 600
        self.assertIn("stima-ci-1", [c[0] for c in runner.calls])  # still read
        self.assertEqual(self.events(), [])
        self.assertEqual(self.inbox(), "")
        self.assertIn("host stima-ci-1 unreadable used=? avail=? inodes=? reason=exit-255 known-unreadable", "\n".join(lines))
        self.assertIn("unreadable: stima-ci-1(exit-255 known)", self.summary(lines))
        # Not every host: an unlisted one still tells after its rounds.
        self.run_once({"stima-ci-2": (255, "", None)}, GDW_APPLY="1", GDW_KNOWN_UNREADABLE="stima-ci-1")
        self.clock.t += 600
        self.run_once({"stima-ci-2": (255, "", None)}, GDW_APPLY="1", GDW_KNOWN_UNREADABLE="stima-ci-1")
        self.assertEqual(len(self.events()), 1)
        self.assertIn("P0 GCE-DISK stima-ci-2 unreadable", self.events()[0])

    def test_a_stored_unreadable_state_on_a_known_host_clears_without_a_recovery(self):
        refused = {"stima-ci-1": (255, "", None)}
        self.run_once(refused, GDW_APPLY="1")
        self.clock.t += 600
        self.run_once(refused, GDW_APPLY="1")
        self.assertEqual(len(self.events()), 1)  # told before it was listed
        self.clock.t += 600
        self.run_once(refused, GDW_APPLY="1", GDW_KNOWN_UNREADABLE="stima-ci-1")
        self.assertEqual(len(self.events()), 1)  # no `recovered`: nothing recovered
        self.assertEqual(self.state()["apply"]["stima-ci-1"]["kind"], "ok")
        self.clock.t += 7200
        self.run_once(refused, GDW_APPLY="1", GDW_KNOWN_UNREADABLE="stima-ci-1")
        self.assertEqual(len(self.events()), 1)  # and no re-alert

    def test_a_known_unreadable_host_that_reads_full_still_alerts(self):
        self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)}, GDW_APPLY="1", GDW_KNOWN_UNREADABLE="stima-ci-ctl-1")
        self.assertEqual(len(self.events()), 1)
        self.assertIn("disk-high", self.events()[0])

    def test_the_shipped_policy_lists_the_two_refused_hosts_and_the_default_lists_none(self):
        self.assertEqual(self.cfg()["GDW_KNOWN_UNREADABLE"], "")
        conf = gdw.load_config(Path(__file__).resolve().parent.parent / "config" / "gce-disk-watch.conf", env={})
        self.assertEqual(conf["GDW_KNOWN_UNREADABLE"].split(), ["stima-ci-1", "stima-ci-deploy-1"])

    def test_a_damaged_entry_never_crashes_the_round_and_the_host_alerts_again(self):
        damaged = [{"kind": "disk-high", "sent": "yesterday", "todo": [], "notice": "alert", "told": True},
                   {"kind": "disk-high", "todo": ["inbox"], "told": True},  # todo without a notice
                   {"kind": "disk-high", "todo": ["rm -rf"], "notice": "alert"},
                   {"kind": "full", "notice": "alert"}, {"kind": "disk-high", "fails": "2"}, "not a dict", [1, 2]]
        for bad in damaged:
            with self.subTest(bad=bad):
                for f in (self.tmp / "handoffs").glob("**/*"):
                    if f.is_file():
                        f.unlink()
                self.write_state({"apply": {"stima-ci-ctl-1": bad}})
                self.clock.t += 600
                rc, lines, _ = self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)}, GDW_APPLY="1")
                self.assertEqual(rc, 0)
                self.assertEqual(len(self.events()), 1)
                self.assertIn("GCE-DISK ALERT host=stima-ci-ctl-1 kind=disk-high", self.inbox())
                self.assertEqual(self.state()["apply"]["stima-ci-ctl-1"]["todo"], [])

    def test_an_error_in_one_host_is_a_counted_failure_not_an_aborted_round(self):
        orig = gdw.Watch.one_host

        def flaky(w, host, *a):
            if host == "stima-ci-2":
                raise TypeError("bad entry")
            return orig(w, host, *a)

        gdw.Watch.one_host = flaky
        try:
            rc, lines, _ = self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)}, GDW_APPLY="1")
        finally:
            gdw.Watch.one_host = orig
        self.assertEqual(rc, 1)
        self.assertIn("1 alerted", self.summary(lines))
        self.assertIn("1 failures", self.summary(lines))
        self.assertIn("ERROR stima-ci-2: round failed (TypeError): state reset for this host", "\n".join(lines))
        self.assertNotIn("stima-ci-2", self.state()["apply"])

    def test_shadow_never_delivers_a_stored_apply_channel(self):
        self.write_state({"shadow": {"stima-ci-ctl-1": {"kind": "disk-high", "since": 1.0, "notice": "alert",
                                                         "todo": ["inbox", "events", "notify"], "sent": None,
                                                         "told": False, "fails": 0}}})
        rc, lines, _ = self.run_once({"stima-ci-ctl-1": (0, CTL1_FULL, None)})
        self.assertEqual(rc, 0)
        self.assertFalse((self.tmp / "handoffs").exists())
        self.assertEqual(self.notes, [])
        self.assertEqual(self.state()["shadow"]["stima-ci-ctl-1"]["todo"], [])

    def test_no_ssh_key_means_no_gcloud_call(self):
        key = self.tmp / "ssh" / "google_compute_engine"
        for missing in (key.with_name(key.name + ".pub"), key):
            with self.subTest(missing=missing.name):
                self.cfg()  # creates both
                missing.unlink()
                rc, lines, runner = self.run_once({}, GDW_UNREADABLE_ROUNDS="1")
                self.assertEqual(runner.calls, [])
                self.assertIn("would alert stima-ci-ctl-1 unreadable used=? avail=? inodes=? reason=no-ssh-key",
                              "\n".join(lines))
                self.assertIn("unreadable: stima-ci-1(no-ssh-key)", self.summary(lines))
                shutil.rmtree(key.parent)
                (self.tmp / "state" / "gce-disk-watch.json").unlink()

    def test_gcloud_is_given_the_checked_key(self):
        argv = gdw.gcloud_argv(self.cfg(), "stima-ci-1")
        self.assertEqual(argv[argv.index("--ssh-key-file") + 1], str(self.tmp / "ssh" / "google_compute_engine"))


if __name__ == "__main__":
    unittest.main()
