#!/usr/bin/env python3
"""A claim whose claimant name matches nothing alive is released once (stima-api#7527).

The pass reads the open issues that carry a claim, asks the oracle's claimant() who holds each, and posts the
`Released by <harness> session <id>` comment (the form claimant() already honours, #6134) when the claimant's name and
id match no live tmux session and no live sessions.json entry and its last activity is 6 h or more old. A live list
that cannot be read releases nothing."""

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import types
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "shell" / "session-reaper.py"
spec = importlib.util.spec_from_file_location("session_reaper_dead_claims", SOURCE)
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)

REPO = "theQuert/stima-api"
NOW = 1794121000  # 2026-11-08T07:16:40Z
H = 3600
SID_DEAD = "0f8e2c4a"
SID_LIVE = "aabbccdd"


def iso(epoch):
    return reaper.time.strftime("%Y-%m-%dT%H:%M:%SZ", reaper.time.gmtime(epoch))


def claim(cid, sid, name, age_h, harness="codex"):
    return {"id": cid, "createdAt": iso(NOW - age_h * H), "body": f"Claimed by {harness} session {sid} ({name})"}


def stub_claimant(comments):
    """A stand-in for delivery_state.claimant(): the newest `Claimed by <harness> session <id> (<name>)` first line,
    ended by a `Released by ... session <id>` first line of the same session. The real one is exercised below."""
    found = None
    for c in comments:
        line = (c.get("body") or "").strip().splitlines()[0] if (c.get("body") or "").strip() else ""
        m = re.match(r"(?i)(claimed|released) by (\w+) session `?([0-9a-f]{8})\S*`?(?: \(([^()]*)\))?", line)
        if not m:
            continue
        if m.group(1).lower() == "claimed":
            found = {"session": m.group(3), "name": (m.group(4) or "").strip(), "harness": m.group(2).lower()}
        elif found and m.group(3) == found["session"]:
            found = None
    return found


class World:
    """Fake GitHub: issue number -> comments; every patched seam reads it, comment() appends to it."""

    def __init__(self, issues):
        self.issues = {n: list(c) for n, c in issues.items()}
        self.posted = []
        self.batches = 0

    def search(self, repo):
        return [(n, "2026-11-01T00:00:00Z") for n in self.issues]

    def batch(self, repo, nums):
        self.batches += 1
        return {n: list(self.issues[n]) for n in nums}

    def fresh(self, repo, num):
        return list(self.issues[num])

    def comment(self, ref, body):
        self.posted.append((ref, body))
        self.issues[int(ref[1])].append({"id": f"IC_{len(self.posted)}", "createdAt": iso(NOW), "body": body})
        return True


class Base(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d)
        self.cfg = dict(reaper.DEFAULTS, DEAD_CLAIMS_CACHE=str(self.d / "cache.json"), DEAD_CLAIMS="apply")
        self.tmux = {"uiux", "infra"}
        self.state = ({"uiux", "infra", "loop #7521 gate"}, {"f76f6898-fcc2-48af-8089-144073f59b81"})
        self.checkby = {}
        patcher = mock.patch.object(reaper, "checkby_state", side_effect=lambda repo, n, cfg: self.checkby.get(n, "CLEAR"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_pass(self, world, apply=True, tmux="default", state="default", oracle=True):
        tm = self.tmux if tmux == "default" else tmux
        st = self.state if state == "default" else state
        mods = types.SimpleNamespace(claimant=stub_claimant) if oracle else None
        with mock.patch.object(reaper, "read_tmux_names", return_value=tm), \
             mock.patch.object(reaper, "read_state_live", return_value=st), \
             mock.patch.object(reaper, "load_oracle", return_value=mods), \
             mock.patch.object(reaper, "search_claimed", side_effect=world.search), \
             mock.patch.object(reaper, "read_comment_batches", side_effect=world.batch), \
             mock.patch.object(reaper, "fresh_comments", side_effect=world.fresh), \
             mock.patch.object(reaper, "comment", side_effect=world.comment):
            return reaper.release_dead_claims(self.cfg, NOW, apply)


class DeadClaimant(Base):
    def test_dead_claimant_six_hours_old_is_released_once(self):
        w = World({6850: [claim("IC_1", SID_DEAD, "codex-ci-2", 30)]})
        r = self.run_pass(w)
        self.assertEqual(len(w.posted), 1)
        ref, body = w.posted[0]
        self.assertEqual(ref, (REPO, "6850"))
        first = body.splitlines()[0]
        self.assertTrue(first.startswith(f"Released by codex session {SID_DEAD} (codex-ci-2)"), first)
        self.assertIn(f"session codex-ci-2 is not in the live session list since {iso(NOW - 30 * H)}", body)
        self.assertIn("<!-- session-reaper-dead-claim:codex-ci-2:IC_1 -->", body)
        self.assertEqual([x[0] for x in r["released"]], [6850])
        again = self.run_pass(w)  # the issue now reads unclaimed
        self.assertEqual(len(w.posted), 1)
        self.assertEqual(again["released"], [])

    def test_the_marker_alone_stops_a_second_post_even_if_the_claim_still_reads(self):
        w = World({7: [claim("IC_1", SID_DEAD, "sre", 30)]})
        w.issues[7].append({"id": "IC_2", "createdAt": iso(NOW - H),
                            "body": "x\n<!-- session-reaper-dead-claim:sre:IC_1 -->"})
        self.run_pass(w)
        self.assertEqual(w.posted, [])

    def test_a_new_claim_by_the_same_name_is_a_new_key(self):
        w = World({7: [claim("IC_1", SID_DEAD, "sre", 40)]})
        self.run_pass(w)
        w.issues[7].append(claim("IC_9", SID_DEAD, "sre", 20))
        self.cfg["DEAD_CLAIMS_CACHE"] = str(self.d / "other.json")
        self.run_pass(w)
        self.assertEqual(len(w.posted), 2)
        self.assertIn("sre:IC_9", w.posted[1][1])

    def test_claude_and_custom_names_are_the_same_as_codex(self):
        w = World({1: [claim("IC_1", SID_DEAD, "ci", 8, "claude")], 2: [claim("IC_2", SID_LIVE, "ops-dispatch", 9, "codex")],
                   3: [claim("IC_3", "11111111", "tmux uiux", 10, "claude")]})
        self.run_pass(w)
        self.assertEqual(sorted(int(p[0][1]) for p in w.posted), [1, 2, 3])

    def test_under_six_hours_waits(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 5.9)]})
        r = self.run_pass(w)
        self.assertEqual(w.posted, [])
        self.assertEqual([x[0] for x in r["young"]], [1])

    def test_a_later_comment_naming_the_session_is_its_activity(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 30),
                       {"id": "IC_2", "createdAt": iso(NOW - 2 * H), "body": f"check-by: session {SID_DEAD} is waiting"}]})
        self.run_pass(w)
        self.assertEqual(w.posted, [])

    def test_a_later_comment_naming_another_session_is_not(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 30),
                       {"id": "IC_2", "createdAt": iso(NOW - 2 * H), "body": "dispatcher note, session 99999999"}]})
        self.run_pass(w)
        self.assertEqual(len(w.posted), 1)

    def test_shadow_and_report_only_post_nothing_but_list_it(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 30)]})
        r = self.run_pass(w, apply=False)
        self.assertEqual(w.posted, [])
        self.assertEqual([x[0] for x in r["would"]], [1])
        self.cfg["DEAD_CLAIMS"] = "shadow"
        r = self.run_pass(w, apply=True)
        self.assertEqual(w.posted, [])
        self.assertEqual([x[0] for x in r["would"]], [1])
        self.cfg["DEAD_CLAIMS"] = "off"
        r = self.run_pass(w, apply=True)
        self.assertEqual((w.posted, r["would"], r["released"]), ([], [], []))

    def test_a_run_posts_at_most_the_cap(self):
        w = World({n: [claim(f"IC_{n}", SID_DEAD, f"gone-{n}", 30)] for n in range(1, 6)})
        self.cfg["DEAD_CLAIMS_MAX"] = "3"
        self.run_pass(w)
        self.assertEqual(len(w.posted), 3)

    def test_an_unchanged_issue_is_not_read_again(self):
        w = World({1: [claim("IC_1", SID_LIVE, "sre", 30)]})
        self.tmux = {"sre"}
        self.run_pass(w)
        self.assertEqual(w.batches, 1)
        self.tmux = set()  # it died since: judged from the cache, no comment read
        self.run_pass(w)
        self.assertEqual(w.batches, 1)
        self.assertEqual(len(w.posted), 1)

    def test_a_claim_that_changed_under_the_cache_is_not_released(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 30)]})
        orig = w.batch

        def stale_then_changed(repo, nums):
            out = orig(repo, nums)
            w.issues[1].append(claim("IC_2", SID_LIVE, "new-owner", 0.1, "claude"))  # claimed while we were reading
            return out
        with mock.patch.object(w, "batch", side_effect=stale_then_changed):
            self.run_pass(w)
        self.assertEqual(w.posted, [])


class Alive(Base):
    def test_a_live_tmux_name_keeps_the_claim(self):
        w = World({1: [claim("IC_1", SID_DEAD, "uiux", 99, "claude")]})
        self.run_pass(w)
        self.assertEqual(w.posted, [])

    def test_a_live_name_keeps_a_codex_claim_too(self):
        w = World({1: [claim("IC_1", SID_DEAD, "infra", 99, "codex")]})
        self.run_pass(w)
        self.assertEqual(w.posted, [])

    def test_name_match_ignores_case_and_edges(self):
        w = World({1: [claim("IC_1", SID_DEAD, " UIUX ", 99, "claude")]})
        self.run_pass(w)
        self.assertEqual(w.posted, [])

    def test_a_live_sessions_json_name_or_tmux_keeps_it(self):
        w = World({1: [claim("IC_1", SID_DEAD, "loop #7521 gate", 99, "claude")]})
        self.run_pass(w)
        self.assertEqual(w.posted, [])

    def test_a_live_sessions_json_id_keeps_a_claim_under_another_name(self):
        w = World({1: [claim("IC_1", "f76f6898", "stima-api-80", 99, "claude")]})
        self.tmux = {"social"}
        self.state = (set(), {"f76f6898-fcc2-48af-8089-144073f59b81"})
        self.run_pass(w, state=(set(), {"f76f6898-fcc2-48af-8089-144073f59b81"}))
        self.assertEqual(w.posted, [])

    def test_a_substring_of_a_live_name_is_not_a_match(self):
        w = World({1: [claim("IC_1", SID_DEAD, "ui", 99, "claude")]})
        self.run_pass(w)
        self.assertEqual(len(w.posted), 1)


class FailsClosed(Base):
    def assertSilent(self, r, w, why):
        self.assertEqual(w.posted, [])
        self.assertEqual(r["released"], [])
        self.assertIn(why, r["unreadable"])

    def test_tmux_unreadable_releases_nothing(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 99)]})
        self.assertSilent(self.run_pass(w, tmux=None), w, "tmux")

    def test_sessions_json_unreadable_releases_nothing(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 99)]})
        self.assertSilent(self.run_pass(w, state=None), w, "sessions.json")

    def test_no_oracle_releases_nothing(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 99)]})
        self.assertSilent(self.run_pass(w, oracle=False), w, "oracle")

    def test_an_issue_search_that_fails_releases_nothing(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 99)]})
        with mock.patch.object(reaper, "read_tmux_names", return_value=self.tmux), \
             mock.patch.object(reaper, "read_state_live", return_value=self.state), \
             mock.patch.object(reaper, "load_oracle", return_value=types.SimpleNamespace(claimant=stub_claimant)), \
             mock.patch.object(reaper, "search_claimed", return_value=None), \
             mock.patch.object(reaper, "comment", side_effect=w.comment):
            r = reaper.release_dead_claims(self.cfg, NOW, True)
        self.assertSilent(r, w, "issue list")

    def test_the_failure_is_one_log_line(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 99)], 2: [claim("IC_2", SID_DEAD, "ci", 99)]})
        r = self.run_pass(w, tmux=None)
        self.assertEqual(len(r["notes"]), 1)
        self.assertIn("released nothing", r["notes"][0])


class OpenCheckBy(Base):
    """stima-api#8959: #9633 lost its claim while its 7-day check-by was still ahead, so no session woke for it."""

    def test_a_pending_or_unread_check_by_keeps_a_dead_claim(self):
        for state in ("OPEN", "UNKNOWN"):
            w = World({9633: [claim("IC_1", SID_DEAD, "release-cadence", 30, harness="claude")]})
            self.checkby = {9633: state}
            self.cfg["DEAD_CLAIMS_CACHE"] = str(self.d / f"{state}.json")
            r = self.run_pass(w)
            self.assertEqual(w.posted, [], state)
            self.assertTrue(any("#9633" in n and "check-by" in n for n in r["notes"]), r["notes"])

    def test_a_clear_check_by_still_releases(self):
        w = World({9633: [claim("IC_1", SID_DEAD, "release-cadence", 30, harness="claude")]})
        self.checkby = {9633: "CLEAR"}
        self.run_pass(w)
        self.assertEqual(len(w.posted), 1)


class StatusSessionName(Base):
    """A session that claims under one name and runs in a tmux of another names its tmux on its STATUS comments."""

    def status(self, name, age_h):
        return {"id": "IC_S", "createdAt": iso(NOW - age_h * H), "body": f"STATUS claimed\nProgress: 90%\nsession: {name}"}

    def test_the_tmux_name_on_a_later_status_keeps_the_claim(self):
        w = World({9633: [claim("IC_1", SID_DEAD, "release-cadence", 30), self.status("uiux", 29)]})
        r = self.run_pass(w)
        self.assertEqual(w.posted, [])
        self.assertEqual(r["alive"], 1)

    def test_a_status_naming_a_dead_tmux_does_not(self):
        w = World({9633: [claim("IC_1", SID_DEAD, "release-cadence", 30), self.status("release-speed", 29)]})
        self.run_pass(w)
        self.assertEqual(len(w.posted), 1)

    def test_a_status_before_the_claim_is_not_the_claimant(self):
        w = World({9633: [self.status("uiux", 31), claim("IC_1", SID_DEAD, "release-cadence", 30)]})
        self.run_pass(w)
        self.assertEqual(len(w.posted), 1)


class BareTmux(unittest.TestCase):
    """stima-api#8959: tmux sessions left with only an idle shell (claude exited) are closed."""

    def panes(self, *rows):
        return (0, "".join("\t".join(map(str, r)) + "\n" for r in rows))

    def pick(self, out, children=(), **cfg):
        c = dict(reaper.DEFAULTS, PROTECT="keep*", **cfg)
        kids = set(map(str, children))
        with mock.patch.object(reaper, "tmux", return_value=out), \
             mock.patch.object(reaper, "run", side_effect=lambda cmd, t=30: (0, "1\n") if cmd[-1] in kids else (1, "")):
            return reaper.bare_tmux_sessions(c, NOW)

    def test_only_an_unattached_quiet_childless_shell_session_is_picked(self):
        old, new = NOW - 7 * H, NOW - 1 * H
        got = self.pick(self.panes(
            ("release-speed", 0, old, 101, "zsh"),
            ("mem-leak", 0, old, 102, "-zsh"), ("mem-leak", 0, old, 103, "bash"),
            ("attached", 1, old, 104, "zsh"),
            ("recent", 0, new, 105, "zsh"),
            ("running", 0, old, 106, "zsh"), ("running", 0, old, 107, "node"),
            ("claude", 0, old, 108, "claude"),
            ("child", 0, old, 109, "zsh"),
            ("keep-me", 0, old, 110, "zsh"), ("uiux-1", 0, old, 111, "zsh")), children=[109])
        self.assertEqual([n for n, _ in got], ["mem-leak", "release-speed"])

    def test_tmux_unreadable_is_none(self):
        self.assertIsNone(self.pick((1, "")))

    def test_shadow_and_report_only_list_and_apply_kills_by_exact_name(self):
        found = [("release-speed", 7.0)]
        for mode, apply in (("shadow", True), ("apply", False)):
            with mock.patch.object(reaper, "bare_tmux_sessions", return_value=found), \
                 mock.patch.object(reaper, "tmux", side_effect=AssertionError("killed")):
                notes = reaper.close_bare_tmux(dict(reaper.DEFAULTS, BARE_TMUX=mode), NOW, apply)
            self.assertEqual(notes, ["bare tmux: would close release-speed (idle 7.0 h, only an idle shell)"])
        with mock.patch.object(reaper, "bare_tmux_sessions", return_value=found), \
             mock.patch.object(reaper, "tmux", return_value=(0, "")) as t:
            notes = reaper.close_bare_tmux(dict(reaper.DEFAULTS), NOW, True)
        t.assert_called_once_with("kill-session", "-t", "=release-speed")
        self.assertEqual(notes, ["bare tmux: closed release-speed (idle 7.0 h, only an idle shell)"])
        with mock.patch.object(reaper, "bare_tmux_sessions", side_effect=AssertionError("read")):
            self.assertEqual(reaper.close_bare_tmux(dict(reaper.DEFAULTS, BARE_TMUX="off"), NOW, True), [])


class ReadsTheLiveList(unittest.TestCase):
    def test_tmux_names(self):
        with mock.patch.object(reaper, "tmux", return_value=(0, "uiux\ninfra\n")):
            self.assertEqual(reaper.read_tmux_names(), {"uiux", "infra"})

    def test_tmux_failure_is_none_not_empty(self):
        with mock.patch.object(reaper, "tmux", return_value=(1, "")):
            self.assertIsNone(reaper.read_tmux_names())

    def test_state_file_names_and_ids(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        f = d / "sessions.json"
        f.write_text(json.dumps({"version": 1, "at_epoch": NOW - 600, "sessions": [
            {"name": "Social X", "tmux": "social", "sid": "f76f6898-fcc2-48af-8089-144073f59b81"}]}))
        with mock.patch.dict(os.environ, {"CC_SESSION_STATE_FILE": str(f)}):
            names, sids = reaper.read_state_live(dict(reaper.DEFAULTS), NOW)
        self.assertEqual(names, {"social x", "social"})
        self.assertEqual(sids, {"f76f6898-fcc2-48af-8089-144073f59b81"})

    def test_a_stale_or_broken_state_file_is_none(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        f = d / "sessions.json"
        with mock.patch.dict(os.environ, {"CC_SESSION_STATE_FILE": str(f)}):
            self.assertIsNone(reaper.read_state_live(dict(reaper.DEFAULTS), NOW))  # missing
            f.write_text("{not json")
            self.assertIsNone(reaper.read_state_live(dict(reaper.DEFAULTS), NOW))
            f.write_text(json.dumps({"version": 1, "at_epoch": NOW - 3 * H, "sessions": []}))
            self.assertIsNone(reaper.read_state_live(dict(reaper.DEFAULTS), NOW))


def _delivery_state():
    root = Path(os.environ.get("STIMA_API_ROOT") or reaper.DEFAULTS["ORACLE_ROOT"]) / "scripts" / "ci"
    if not (root / "delivery_state.py").is_file():
        return None
    sys.path.insert(0, str(root))
    try:
        import delivery_state  # noqa: PLC0415
        return delivery_state
    except Exception:  # noqa: BLE001
        return None
    finally:
        sys.path.remove(str(root))


class TheRealOracleHonoursIt(Base):
    def test_claimant_reads_unclaimed_after_the_release(self):
        ds = _delivery_state()
        if ds is None:
            self.skipTest("no stima-api checkout to cross-check against (set STIMA_API_ROOT)")
        for sid, label in ((SID_DEAD, "8-hex"), ("0f8e2c4a-1b3d-4e5f-8a9b-0c1d2e3f4a5b", "uuid")):
            w = World({1: [claim("IC_1", sid, "codex-ci-2", 30)]})
            self.assertEqual(ds.claimant(w.issues[1])["session"], sid, label)
            with mock.patch.object(reaper, "read_tmux_names", return_value=self.tmux), \
                 mock.patch.object(reaper, "read_state_live", return_value=self.state), \
                 mock.patch.object(reaper, "load_oracle", return_value=ds), \
                 mock.patch.object(reaper, "search_claimed", side_effect=w.search), \
                 mock.patch.object(reaper, "read_comment_batches", side_effect=w.batch), \
                 mock.patch.object(reaper, "fresh_comments", side_effect=w.fresh), \
                 mock.patch.object(reaper, "comment", side_effect=w.comment):
                self.cfg["DEAD_CLAIMS_CACHE"] = str(self.d / f"{label}.json")
                reaper.release_dead_claims(self.cfg, NOW, True)
            self.assertEqual(len(w.posted), 1, label)
            self.assertIsNone(ds.claimant(w.issues[1]), label)


class StandaloneRun(Base):
    def test_dead_claims_only_prints_the_list_and_posts_nothing(self):
        w = World({1: [claim("IC_1", SID_DEAD, "sre", 30)]})
        conf = self.d / "r.conf"
        conf.write_text(f"DEAD_CLAIMS_CACHE={self.d / 'c.json'}\nSTATE_DIR={self.d}\n")
        out = []
        with mock.patch.object(reaper, "read_tmux_names", return_value=self.tmux), \
             mock.patch.object(reaper, "read_state_live", return_value=self.state), \
             mock.patch.object(reaper, "load_oracle", return_value=types.SimpleNamespace(claimant=stub_claimant)), \
             mock.patch.object(reaper, "search_claimed", side_effect=w.search), \
             mock.patch.object(reaper, "read_comment_batches", side_effect=w.batch), \
             mock.patch.object(reaper, "fresh_comments", side_effect=w.fresh), \
             mock.patch.object(reaper, "comment", side_effect=w.comment), \
             mock.patch("builtins.print", side_effect=lambda *a, **k: out.append(" ".join(map(str, a)))):
            rc = reaper.main(["--config", str(conf), "--dead-claims-only"])
        self.assertEqual(rc, 0)
        self.assertEqual(w.posted, [])
        self.assertTrue(any("would release #1" in line and "sre" in line for line in out), out)


class OnlyTheLivePolicyActs(unittest.TestCase):
    """The first draft of this pass ran inside every main(), and a test's APPLY=1 sweep posted release comments to the
    real issues. A config that is not the live policy never reaches it."""

    def test_a_copied_config_never_runs_the_pass(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        conf = d / "r.conf"
        conf.write_text(f"APPLY=1\nSTATE_DIR={d}\nREPORT={d / 'report.md'}\nREAPED_DIR={d / 'reaped'}\n"
                        f"CLOSED_LOG={d / 'closed.md'}\nIDLE_LIST_HOURS=0\n")
        with mock.patch.object(reaper, "release_dead_claims", side_effect=AssertionError("ran")) as ran, \
             mock.patch.object(reaper, "gather", return_value=[]):
            reaper.main(["--config", str(conf), "--apply"])
        ran.assert_not_called()

    def test_the_live_policy_runs_it(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        conf = d / "r.conf"
        conf.write_text(f"APPLY=1\nSTATE_DIR={d}\nREPORT={d / 'report.md'}\nREAPED_DIR={d / 'reaped'}\n"
                        f"CLOSED_LOG={d / 'closed.md'}\nIDLE_LIST_HOURS=0\n")
        res = {"released": [], "would": [], "young": [], "alive": 0, "deferred": [], "unreadable": "", "notes": []}
        with mock.patch.object(reaper, "CONFIG", conf), \
             mock.patch.object(reaper, "release_dead_claims", return_value=res) as ran, \
             mock.patch.object(reaper, "close_bare_tmux", return_value=[]), \
             mock.patch.object(reaper, "gather", return_value=[]):
            reaper.main(["--config", str(conf)])
        ran.assert_called_once()
        self.assertTrue(ran.call_args.args[2])  # apply


if __name__ == "__main__":
    unittest.main()
