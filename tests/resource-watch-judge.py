#!/usr/bin/env python3
"""Isolated tests for resource-watch-judge (EL-T24): its defaults are the script's, the LaunchAgent's
EnvironmentVariables override them as launchd does, each judged ALERT marker follows the line's own numbers under
that config (the swap= and rate= fields included), and the pause chain's dedupe and resume are checked. Every path
is a temp path; nothing real is read."""

import importlib.util
import plistlib
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "shell" / "resource-watch-judge.py"
spec = importlib.util.spec_from_file_location("resource_watch_judge", SOURCE)
judge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(judge)

NCPU, PHYS = 10, 32.0
CFG = judge.config(env={})


def snap(load1=4.0, mf=30.0, comp=6.0, free=100.0, pct=20.0, swap="3.0GB", rate="1.0GB/h", markers=""):
    fields = "" if swap is None else f" swap={swap} rate={rate}"
    return (f"2026-10-30T01:07:01 load={load1:.2f}/5.00/5.00 cpu_idle=50% mem_free={mf}% compressor={comp}GB "
            f"disk_free={free}GB/{pct}%{fields}{(' ' + markers) if markers else ''}")


def event(kind, mode="emitted", ts="2026-10-30T01:07:00"):
    head = "EVENT emitted to /x/events.log" if mode == "emitted" else \
        "EVENT shadow (CC_RW_PAUSE_EVENTS=shadow): would emit to /x/events.log"
    body = "DISK-PAUSE on: swap-high free=56.3GB swap=19.5GB rate=4.5GB/h" if kind == "pause" else \
        "DISK-RESUME: all clear free=60.0GB swap=3.0GB rate=1.0GB/h"
    return f"{ts} {head}: {body}"


class Defaults(unittest.TestCase):
    def test_defaults_are_the_scripts(self):
        text = (ROOT / "shell" / "resource-watch.sh").read_text()
        found = {k: float(v) for k, v in re.findall(r"_cc_rw_num (CC_RW_\w+) ([0-9.]+)", text)}
        found.update({k: float(v) for k, v in re.findall(r"\$\{(CC_RW_\w+):-([0-9.]+)\}", text)})
        for key, value in judge.DEFAULTS.items():
            self.assertIn(key, found, f"{key} has no default in resource-watch.sh")
            self.assertEqual(found[key], value, f"{key}: script {found[key]} vs judge {value}")

    def test_launchagent_env_overrides(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "rw.plist"
            p.write_bytes(plistlib.dumps({"Label": "x", "EnvironmentVariables": {
                "CC_RW_DISK_EMERGENCY_GB": "25", "CC_RW_RATE_FLAG_GBH": "12", "CC_RW_SWAP_FLAG_GB": "bad", "PATH": "/bin"}}))
            cfg = judge.config(p)
        self.assertEqual(cfg["CC_RW_DISK_EMERGENCY_GB"], 25.0)
        self.assertEqual(cfg["CC_RW_RATE_FLAG_GBH"], 12.0)
        self.assertEqual(cfg["CC_RW_SWAP_FLAG_GB"], 18.0, "a value the script refuses falls back to its default")

    def test_unreadable_plist_is_the_defaults(self):
        self.assertEqual(judge.config("/nonexistent/x.plist"), judge.DEFAULTS)


class Line(unittest.TestCase):
    def j(self, line, cfg=CFG):
        return judge.judge_line(line, cfg, NCPU, PHYS)

    def test_quiet_line_agrees(self):
        self.assertEqual(self.j(snap()), [])

    def test_live_shape_agrees(self):
        # the shape of 2026-10-30T01:07:01 on the Mac mini, with the new fields
        line = snap(load1=107.79, mf=19.2, comp=13.19, free=56.3, pct=13.0, swap="19.5GB", rate="4.5GB/h",
                    markers="ALERT:load ALERT:disk ALERT:swap ALERT:disk-low disk_rate=4.5GB/h")
        self.assertEqual(self.j(line), [])

    def test_swap_over_the_line_without_its_marker(self):
        self.assertTrue(any("imply ['swap']" in m for m in self.j(snap(swap="19.5GB"))))

    def test_swap_marker_without_swap_over_the_line(self):
        self.assertTrue(self.j(snap(swap="3.0GB", markers="ALERT:swap")))

    def test_swap_line_follows_the_config(self):
        cfg = dict(CFG, CC_RW_SWAP_FLAG_GB=25.0)
        self.assertEqual(self.j(snap(swap="19.5GB"), cfg), [])
        self.assertTrue(self.j(snap(swap="19.5GB", markers="ALERT:swap"), dict(CFG, CC_RW_SWAP_FLAG_GB=0.0)),
                        "a limit of 0 is off: the marker is then wrong")

    def test_unreadable_swap_implies_no_marker(self):
        self.assertEqual(self.j(snap(swap="?", rate="?")), [])
        self.assertTrue(self.j(snap(swap="?", rate="?", markers="ALERT:swap")))

    def test_disk_low_is_60_not_40(self):
        self.assertEqual(self.j(snap(free=50.0, markers="ALERT:disk-low")), [])
        self.assertTrue(self.j(snap(free=50.0)), "50 GB free without ALERT:disk-low is a miss")

    def test_emergency_follows_the_launchagent(self):
        cfg = dict(CFG, CC_RW_DISK_EMERGENCY_GB=25.0)
        self.assertEqual(self.j(snap(free=24.0, markers="ALERT:disk-low ALERT:disk-emergency"), cfg), [])
        self.assertTrue(self.j(snap(free=24.0, markers="ALERT:disk-low"), cfg))
        self.assertEqual(self.j(snap(free=24.0, markers="ALERT:disk-low"), CFG), [], "20 by default")

    def test_rate(self):
        self.assertEqual(self.j(snap(rate="12.5GB/h", markers="ALERT:disk-rate disk_rate=12.5GB/h")), [])
        self.assertTrue(self.j(snap(rate="12.5GB/h", markers="disk_rate=12.5GB/h")))
        self.assertTrue(any("disk_rate=" in m for m in self.j(snap(rate="1.0GB/h", markers="disk_rate=9.0GB/h"))))

    def test_load_and_mem(self):
        self.assertTrue(self.j(snap(load1=21.0)))
        self.assertEqual(self.j(snap(load1=21.0, markers="ALERT:load")), [])
        self.assertEqual(self.j(snap(mf=4.0, comp=17.0, markers="ALERT:mem")), [])

    def test_unjudged_markers_are_left_alone(self):
        self.assertEqual(self.j(snap(markers="ALERT:disk-drop ALERT:reclaim-stalled ACT:running:12")), [])

    def test_a_line_without_the_fields_is_one_miss(self):
        self.assertEqual(len(self.j(snap(swap=None, markers="ALERT:swap disk_rate=4.5GB/h"))), 1)
        self.assertTrue(any("no swap=/rate=" in m for m in self.j(snap(swap=None))))

    def test_a_line_without_the_fields_is_still_judged_on_the_rest(self):
        self.assertEqual(len(self.j(snap(swap=None, free=50.0))), 2, "no fields, and no ALERT:disk-low at 50 GB")

    def test_other_lines_are_not_judged(self):
        self.assertEqual(self.j("2026-10-30T01:07:00 INFO reclaim-stalled: no finished-sweep stamp yet"), [])
        self.assertEqual(self.j(event("pause")), [])

    def test_garbage_snapshot_is_unparsable(self):
        self.assertTrue(self.j("2026-10-30T01:07:01 load=1/1/1 cpu_idle=% mem_free=% compressor=GB disk_free=GB/%"))


class Events(unittest.TestCase):
    def j(self, lines, cfg=CFG):
        return judge.judge_events(lines, cfg)

    def test_pause_then_resume_is_fine(self):
        self.assertEqual(self.j([event("pause"), snap(swap="19.5GB"), event("resume"), snap()]), [])

    def test_two_pauses_in_a_row(self):
        self.assertTrue(any("two DISK-PAUSE" in m for m in self.j([event("pause"), snap(), event("pause")])))

    def test_two_resumes_in_a_row(self):
        self.assertTrue(any("two DISK-RESUME" in m for m in self.j([event("resume"), event("resume")])))

    def test_modes_are_separate(self):
        self.assertEqual(self.j([event("pause", "shadow"), event("pause", "emitted")]), [])

    def test_swap_after_a_resume(self):
        self.assertTrue(any("newest event is DISK-RESUME" in m
                            for m in self.j([event("pause"), event("resume"), snap(swap="19.5GB")])))

    def test_emergency_and_flag_rate_after_a_resume(self):
        cfg = dict(CFG, CC_RW_DISK_EMERGENCY_GB=25.0, CC_RW_RATE_FLAG_GBH=12.0)
        self.assertTrue(self.j([event("resume"), snap(free=24.0)], cfg))
        self.assertTrue(self.j([event("resume"), snap(rate="13.0GB/h")], cfg))
        self.assertEqual(self.j([event("resume"), snap(rate="11.0GB/h")], cfg), [])

    def test_no_event_yet_judges_nothing(self):
        self.assertEqual(self.j([snap(swap="19.5GB")]), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
