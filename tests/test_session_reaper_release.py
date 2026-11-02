#!/usr/bin/env python3
"""The reap comment releases the session's claim (stima-api#7000): its first line is the `Released by ... session
<id>` form that stima-api's delivery_state.claimant() honours (#6134), so a reaped session's issue reads unclaimed."""

import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "shell" / "session-reaper.py"
spec = importlib.util.spec_from_file_location("session_reaper_release", SOURCE)
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)

SID = "0f8e2c4a-1b3d-4e5f-8a9b-0c1d2e3f4a5b"
NOW = 1793676000  # 2026-11-03T03:20:00Z
BRIEF = "delivery #7000: claimed -> agent plan  [abc]\n  claimant: claude session 0f8e2c4a; the step is that session's"


class ReleaseComment(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d)
        self.cfg = dict(reaper.DEFAULTS, REAPED_DIR=str(self.d / "reaped"), CLOSED_LOG=str(self.d / "closed.md"))

    def test_first_line_releases_and_names_the_next_step(self):
        with mock.patch.object(reaper, "oracle_brief", return_value=BRIEF):
            text = reaper.release_comment("work", SID, "/w", ("theQuert/stima-api", "7000"), self.cfg, NOW)
        first = text.splitlines()[0]
        self.assertEqual(first, f"Released by work session {SID} (reaped 2026-11-03T03:20:00Z); "
                                "next: delivery #7000: claimed -> agent plan  [abc]")
        self.assertIn(f"<!-- session-reaper:{SID} -->", text)
        self.assertIn(f"claude --resume {SID}", text)

    def test_unread_oracle_is_said_not_guessed(self):
        with mock.patch.object(reaper, "oracle_brief", return_value=None):
            text = reaper.release_comment("work", SID, "/w", ("theQuert/stima-api", "7000"), self.cfg, NOW)
        self.assertIn("next: unread; run `delivery_state.py 7000 --brief`", text.splitlines()[0])

    def test_finish_close_posts_the_release_once(self):
        posted = []
        with mock.patch.object(reaper, "oracle_brief", return_value=BRIEF), \
             mock.patch.object(reaper, "comment", side_effect=lambda ref, body: posted.append((ref, body)) or True), \
             mock.patch.object(reaper, "has_marker", side_effect=[False, True]):
            for _ in range(2):
                self.assertTrue(reaper.finish_close("work", SID, "/w", [("theQuert/stima-api", "7000")], "done",
                                                    "%9", "$3", True, self.cfg, NOW, 4242))
        self.assertEqual(len(posted), 1)
        self.assertTrue(posted[0][1].startswith(f"Released by work session {SID} "))


def _delivery_state():
    """stima-api's delivery_state module, read from STIMA_API_ROOT or the reaper's ORACLE_ROOT; None when absent."""
    root = Path(os.environ.get("STIMA_API_ROOT") or reaper.DEFAULTS["ORACLE_ROOT"]) / "scripts" / "ci"
    if not (root / "delivery_state.py").is_file():
        return None
    sys.path.insert(0, str(root))
    try:
        import delivery_state  # noqa: PLC0415
        return delivery_state
    except Exception:  # noqa: BLE001 (a checkout that cannot import is the same as none)
        return None
    finally:
        sys.path.remove(str(root))


class ClaimantHonoursIt(unittest.TestCase):
    def test_claimant_reads_unclaimed_after_the_release(self):
        ds = _delivery_state()
        if ds is None:
            self.skipTest("no stima-api checkout to cross-check against (set STIMA_API_ROOT)")
        cfg = dict(reaper.DEFAULTS)
        with mock.patch.object(reaper, "oracle_brief", return_value=BRIEF):
            release = reaper.release_comment("work", SID, "/w", ("theQuert/stima-api", "7000"), cfg, NOW)
        claim = {"body": f"Claimed by claude session {SID} (work)"}
        self.assertEqual(ds.claimant([claim])["session"], SID)
        self.assertIsNone(ds.claimant([claim, {"body": release}]))
        short = {"body": f"Claimed by claude session `{SID[:8]}` (work)"}  # the usual 8-hex claim
        self.assertIsNone(ds.claimant([short, {"body": release}]))
        other = release.replace(SID, "11111111-2222-4333-8444-555555555555", 1)
        self.assertEqual(ds.claimant([claim, {"body": other}])["session"], SID)  # another session's release


if __name__ == "__main__":
    unittest.main()
