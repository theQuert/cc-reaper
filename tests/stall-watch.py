#!/usr/bin/env python3
"""Isolated tests for stall-watch: each fingerprint on a fixture pane text, a healthy pane stays silent, one report
per event across runs, the hash skip, shadow vs apply, the marks the session reaper shows, the interactive prompt
aging and alerts (EL-T921), and the #5212 wall: the only tmux calls are display and capture-pane, never send-keys. Every path is a temp path; nothing real is touched."""

import importlib.util
import json
import time
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
# The five texts Opus measured as false positives of the first version (ordinary transcript content).
QUOTED_RC = screen('● The log said "Remote Control disconnected" after the switch, which matches the bug report.')
SENTENCE_LIMIT = screen("● Users who hit your weekly limit see a banner; the copy should say so.")
READ_429 = screen("● Read(docs/log.txt)", "  ⎿  Read 429 lines")
HASH_429 = screen("● Bash(gh pr view)", "  ⎿  #429 merged")
RATE_FILE = screen("● Search(rate)", "  ⎿  …/rate_limit.go")
TEST_STATUS = screen("● Bash(go test ./...)", "  ⎿  expected status 429, got 200")
GREP_STATUS = screen("● Search(upstream)", "  ⎿  // upstream returned status 429")
GREP_RC = screen("● Search(disconnected)", "  ⎿  Remote Control disconnected.")
FALSE_POSITIVES = {"go test status 429": TEST_STATUS, "grep status 429": GREP_STATUS, "grep result Remote Control disconnected": GREP_RC, "quoted Remote Control disconnected": QUOTED_RC, "weekly limit inside a sentence": SENTENCE_LIMIT,
                   "Read 429 lines": READ_429, "#429 merged": HASH_429, "…/rate_limit.go": RATE_FILE}
STATUS_429 = screen("● Agent(audit)", "  ⎿  Agent failed: request failed with status code 429")
INTERRUPT_DRAFT = screen("[Request interrupted by user]", "", typed="continue with")


# Interactive prompts (EL-T921-CI-CONFIRM-CLEAR), in the shape the `ci` and `security` panes showed on 2026-10-29.
def bottom(*lines):
    """A pane whose bottom is a live menu (no input box): (text, cx, cy) with the cursor on the last line."""
    text = "\n".join(lines) + "\n"
    return text, 1, len(lines) - 1


DASH = "╌" * 40
PERMISSION = bottom("● Ran the backup test", "✻ Waiting for 2 background agents to finish", "", RULE,
                    " Bash command · from the worker-high agent", " Run shell command", DASH,
                    " │ cd /tmp/bk && rm -rf bs r.git && git init -q --bare r.git", DASH,
                    " This shell -c script runs rm and could not be checked", "", " Do you want to proceed?",
                    " ❯ 1. Yes", "   2. No", "", " Esc to cancel · Tab to amend · ctrl+x ctrl+k twice to stop background agents")
PERMISSION_OTHER = bottom(*PERMISSION[0].split("\n")[:7], " │ make clean", *PERMISSION[0].split("\n")[8:-1])
PERMISSION_MOVED = bottom(*[l.replace(" ❯ 1. Yes", "   1. Yes").replace("   2. No", " ❯ 2. No") for l in PERMISSION[0].split("\n")[:-1]])
EDIT_PERMISSION = bottom(RULE, " Edit file", " web/next/app/page.tsx", " Do you want to make this edit to page.tsx?",
                         " ❯ 1. Yes", "   2. Yes, allow all edits during this session (shift+tab)",
                         "   3. No, and tell Claude what to do differently (esc)", "", " Esc to cancel")
ASK_USER = bottom("⏺ The build is green; one decision is left.", "", RULE, " ☐ #6169 boundary", "",
                  "│ Approve the boundary and merge once merge-gate is green?", "",
                  "❯ 1. Approve and ship (Recommended)     ┌──────────────────────┐",
                  "  2. Approve, do not ship yet         │ write_set: lockfile  │",
                  "  3. Do not do it                     └──────────────────────┘", "",
                  "                                  Notes: press n to add notes", "", RULE, "  Chat about this", "",
                  "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel", RULE + " security ─")
ASK_MOVED = bottom(*[l.replace("❯ 1. Approve", "  1. Approve").replace("  2. Approve,", "❯ 2. Approve,")
                     .replace("write_set: lockfile ", "rollback: revert PR ") for l in ASK_USER[0].split("\n")[:-1]])
# Folder trust as 2.1.293 draws it (strings read from the binary), the older boxed wording, and plan approval.
TRUST = bottom(RULE, " Accessing workspace:", "", " /Users/x/GitHub/proj", "",
               " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known",
               " open source project, or work from your team). If not, take a moment to review what's in this folder first.",
               "", " Claude Code'll be able to read, edit, and execute files here.", "", " Security guide", "",
               " ❯ 1. Yes, I trust this folder", "   2. No, exit", "", " Enter to confirm · Esc to cancel")
BOXW = 52
TRUST_OLD = bottom("╭" + "─" * BOXW + "╮", *[f"│ {t:<{BOXW - 1}}│" for t in (
    "Do you trust the files in this folder?", "", "/Users/x/proj", "", "❯ 1. Yes, proceed", "  2. No, exit", "",
    "Enter to confirm · Esc to exit")], "╰" + "─" * BOXW + "╯")
PLAN = bottom("● The plan is written.", RULE, " Ready to code?", "", " Here is Claude's plan:", " ╭" + "─" * 40,
              " │ 1. Bump the lockfile", " │ 2. Run the audit", " ╰" + "─" * 40, "",
              " Claude has written up a plan and is ready to execute. Would you like to proceed?", "",
              " ❯ 1. Yes, clear context and auto-accept edits", "   2. Yes, and auto-accept edits",
              "   3. Yes, and manually approve edits", "   4. No, keep planning", "",
              " shift+tab to approve with this feedback")
# A menu with no tab line and no rule above it: the question is its only identity.
UNRULED_A = bottom("│ Which region should the canary use?", "", "❯ 1. us-east", "  2. eu-west", "",
                   "Enter to select · ↑/↓ to navigate · Esc to cancel")
UNRULED_B = bottom("│ Which size should the runner be?", "", "❯ 1. us-east", "  2. eu-west", "",
                   "Enter to select · ↑/↓ to navigate · Esc to cancel")
UNRULED_C = bottom("│ Which region should the canary use?", "", "❯ 1. ap-south", "  2. eu-west", "",
                   "Enter to select · ↑/↓ to navigate · Esc to cancel")
# A quoted prompt as the very last text above an idle input box (4 non-blank lines: rule, ❯, rule, footer).
QUOTE_BOTTOM_PERMISSION = screen("● The hook printed:", "  Do you want to proceed?", "  ❯ 1. Yes", "    2. No")
QUOTE_BOTTOM_ASK = screen("● Its menu read:", "  ☐ Region", "  Which region?", "  ❯ 1. us-east", "    2. eu-west",
                          "  Enter to select · ↑/↓ to navigate · Esc to cancel")
QUOTE_BOTTOM_PLAN = screen("● It asked: Would you like to proceed?", "  1. Yes, and auto-accept edits", "  2. No, keep planning")
QUOTE_BOTTOM_TRUST = screen("● The dialog said:", "  ❯ 1. Yes, I trust this folder", "    2. No, exit")
QUOTE_BOTTOM_DRAFT = screen("● The hook printed:", "  Do you want to proceed?", "  ❯ 1. Yes", "    2. No", typed="yes")
BUSY = screen("● Bash(go test ./...)", "  ⎿  Running…", "", "✻ Compiling… (2m 3s · esc to interrupt)")
# The words of a prompt in ordinary transcript text, with the idle input box below: not a live prompt.
QUOTED_PROMPT = screen("● The hook printed:", "  Do you want to proceed?", "  ❯ 1. Yes", "    2. No",
                       "● I answered nothing; the session that owns it must decide.", "● Done.")
QUOTED_ASK = screen("● Its footer reads", "  1. first", "  Enter to select · ↑/↓ to navigate · Esc to cancel",
                    "● and that is the menu shape.", "● Done.")


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

    def test_ordinary_transcript_text_is_not_a_fingerprint(self):
        for name, spec_ in FALSE_POSITIVES.items():
            with self.subTest(name):
                self.assertEqual(self.fps(spec_), [])
        self.assertIn("rate-limit-429", self.fps(STATUS_429))

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


class Prompts(unittest.TestCase):
    def prompt(self, spec_):
        return stall.scan(pane(spec_))["prompt"]

    def test_a_permission_prompt_is_detected(self):
        for name, spec_ in {"proceed": PERMISSION, "edit": EDIT_PERMISSION}.items():
            with self.subTest(name):
                self.assertEqual(self.prompt(spec_)["kind"], "permission")

    def test_an_ask_user_question_menu_is_detected(self):
        self.assertEqual(self.prompt(ASK_USER)["kind"], "ask-user-question")

    def test_folder_trust_and_plan_approval_are_detected(self):
        for name, (spec_, kind) in {"trust 2.1": (TRUST, "folder-trust"), "trust boxed": (TRUST_OLD, "folder-trust"),
                                    "plan": (PLAN, "plan-approval")}.items():
            with self.subTest(name):
                self.assertEqual(self.prompt(spec_)["kind"], kind)
        self.assertNotEqual(self.prompt(TRUST)["fp"], self.prompt(TRUST_OLD)["fp"])

    def test_a_quoted_prompt_at_the_very_bottom_above_an_idle_input_box_is_not_a_prompt(self):
        for name, spec_ in {"permission": QUOTE_BOTTOM_PERMISSION, "ask": QUOTE_BOTTOM_ASK, "plan": QUOTE_BOTTOM_PLAN,
                            "trust": QUOTE_BOTTOM_TRUST, "with a draft": QUOTE_BOTTOM_DRAFT}.items():
            with self.subTest(name):
                text, cx, cy = spec_
                self.assertEqual(sum(1 for l in text.split("\n")[cy - 1:] if l.strip()), 4)  # the 4-line idle box
                self.assertIsNone(self.prompt(spec_))

    def test_a_menu_with_no_tab_line_or_rule_is_identified_by_its_question_and_first_option(self):
        a, b, c = self.prompt(UNRULED_A), self.prompt(UNRULED_B), self.prompt(UNRULED_C)
        self.assertEqual((a["kind"], b["kind"]), ("ask-user-question", "ask-user-question"))
        self.assertNotEqual(a["fp"], b["fp"])  # another question
        self.assertNotEqual(a["fp"], c["fp"])  # the same question, other options

    def test_an_idle_or_busy_pane_and_quoted_prompt_text_are_not_prompts(self):
        for name, spec_ in {"idle": HEALTHY, "busy": BUSY, "quoted permission": QUOTED_PROMPT,
                            "quoted menu": QUOTED_ASK, "interrupted": INTERRUPTED, "weekly": WEEKLY}.items():
            with self.subTest(name):
                self.assertIsNone(self.prompt(spec_))

    def test_the_fingerprint_is_one_prompt_instance(self):
        fp = self.prompt(PERMISSION)["fp"]
        self.assertEqual(self.prompt(PERMISSION_MOVED)["fp"], fp)  # the option cursor moved: same prompt
        self.assertNotEqual(self.prompt(PERMISSION_OTHER)["fp"], fp)  # another command: another prompt
        self.assertEqual(self.prompt(ASK_MOVED)["fp"], self.prompt(ASK_USER)["fp"])  # cursor and preview moved
        listed = bottom("● Plan:", "  1. bump the lockfile", "  2. run the audit", *ASK_USER[0].split("\n")[:-1])
        self.assertEqual(self.prompt(listed)["fp"], self.prompt(ASK_USER)["fp"])  # a numbered list above is not the menu
        untabbed = bottom("  1. an earlier list", *[l for l in ASK_USER[0].split("\n")[:-1] if "☐" not in l])
        self.assertEqual(self.prompt(untabbed)["kind"], "ask-user-question")
        self.assertEqual(self.prompt(untabbed)["fp"], self.prompt(bottom(*untabbed[0].split("\n")[1:-1]))["fp"])
        self.assertNotEqual(self.prompt(ASK_USER)["fp"], fp)
        lines = PERMISSION[0].split("\n")[:-1]
        wrapped = bottom(*lines[:9], " This shell -c script runs rm and", " could not be checked", *lines[10:])
        self.assertEqual(self.prompt(wrapped)["fp"], fp)  # a narrower pane wraps the text: same prompt


class Fleet:
    """A fake tmux and process table: panes {%id: (tmux name, claude pid, screen spec)}; records every tmux argv."""

    def __init__(self, tmp, panes):
        self.tmp, self.panes, self.calls, self.fail, self.empty = tmp, panes, [], set(), set()
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
        if target in self.fail:
            return 1, ""  # a tmux timeout under load
        if sub == "capture-pane" and target in self.empty:
            return 0, ""
        if sub == "display":
            return 0, f"{target}\t{name}\t$1\t{100 + 10 * n}\t{cx}\t{cy}\t1\t1\n"
        if sub == "capture-pane":
            return 0, text
        raise AssertionError(f"unexpected tmux {cmd}")


class Runs(unittest.TestCase):
    table = None

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.inbox = self.tmp / "neo-inbox.md"
        self.marks = self.tmp / "stalled"
        self.write_config()

    def write_config(self, apply="1", fleet_min="2", extra=""):
        self.cfg = self.tmp / "conf"
        self.cfg.write_text(f"STALL_APPLY={apply}\nSTALL_INBOX={self.inbox}\nSTALL_STATE={self.tmp / 'state.json'}\n"
                            f"STALL_MARK_DIR={self.marks}\nSTALL_FLEET_MIN={fleet_min}\n{extra}")

    def start(self, panes):
        self.fleet = Fleet(self.tmp, panes)
        return self.fleet

    def run_once(self, *flags):
        f = self.fleet
        with mock.patch.object(reaper, "SESSIONS_DIR", self.tmp / "sessions"), \
             mock.patch.object(reaper, "ps_table", return_value=f.table if self.table is None else self.table), \
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
        self.assertIn("0 marked", self.printed)

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
        self.assertFalse(self.marks.exists() and list(self.marks.glob("*")))  # a mark holds the reaper: never in shadow

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
        self.write_config(apply="0")
        f = self.start({"%1": ("work", WEEKLY), "%2": ("fine", HEALTHY)})
        self.run_once()
        self.assertFalse(self.marks.exists() and list(self.marks.glob("*")))  # shadow: no mark
        self.write_config(apply="1")
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

    def test_the_fingerprints_in_the_five_false_positive_texts_report_and_mark_nothing(self):
        for name, spec_ in FALSE_POSITIVES.items():
            with self.subTest(name):
                self.start({"%1": ("work", spec_)})
                self.run_once()
                self.run_once()
                self.assertEqual(self.inbox_text(), "")
                self.assertEqual(list(self.marks.glob("*")), [])

    def test_a_mark_does_not_outlive_its_first_sighting_however_often_it_is_refreshed(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        sid = f.sids["%1"]
        cfg = dict(reaper.DEFAULTS, STALL_MARK_DIR=str(self.marks))
        self.assertEqual(reaper.stall_mark(cfg, sid), "weekly-limit")
        st = json.loads((self.tmp / "state.json").read_text())
        for ev in st["events"].values():
            ev["first"] -= 49 * 3600
        (self.tmp / "state.json").write_text(json.dumps(st))
        self.run_once()  # unchanged idle screen: refreshed, but past the cap from its first sighting
        self.assertFalse((self.marks / f"{sid}.json").exists())
        self.assertEqual(reaper.stall_mark(cfg, sid), "")
        self.assertEqual(self.inbox_text().count("STALL work"), 1)

    def test_a_failed_read_keeps_the_event_and_the_mark_and_reports_nothing_again(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        sid = f.sids["%1"]
        mark = self.marks / f"{sid}.json"
        before = mark.read_text()
        for failing in (f.fail, f.empty):
            failing.add("%1")
            self.assertEqual(self.run_once(), 0)
            self.assertIn("1 unread", self.printed)
            self.assertEqual(mark.read_text(), before)
            failing.discard("%1")
        self.run_once()
        self.assertEqual(self.inbox_text().count("STALL work"), 1)
        self.assertEqual(mark.read_text().count(sid), 1)

    def test_a_missing_process_table_changes_nothing(self):
        f = self.start({"%1": ("work", WEEKLY)})
        self.run_once()
        state, marks = (self.tmp / "state.json").read_text(), sorted(p.name for p in self.marks.glob("*"))
        self.table = {}
        self.assertEqual(self.run_once(), 1)
        self.assertEqual((self.tmp / "state.json").read_text(), state)
        self.assertEqual(sorted(p.name for p in self.marks.glob("*")), marks)

    def test_a_session_id_that_is_not_word_characters_is_skipped(self):
        f = self.start({"%1": ("work", WEEKLY)})
        p = next((self.tmp / "sessions").glob("*.json"))
        d = json.loads(p.read_text())
        d["sessionId"] = "abc`reboot`"
        p.write_text(json.dumps(d))
        self.run_once()
        self.assertEqual(self.inbox_text(), "")

    def test_a_backtick_in_the_name_cannot_close_the_code_span(self):
        self.start({"%1": ("my`name", WEEKLY)})
        self.run_once()
        block = self.inbox_text()
        self.assertEqual(block.count("`"), 2)
        import shlex
        command = block.split("`")[1]
        self.assertEqual(shlex.split(command)[-2:], ["--remote-control", "my'name"])

    def test_cleanup_deletes_only_mark_files_and_refuses_a_shared_directory(self):
        f = self.start({"%1": ("work", HEALTHY)})
        self.marks.mkdir()
        other = self.marks / "notes.json"
        other.write_text("{}")
        session_like = self.marks / "abc.json"
        session_like.write_text(json.dumps({"pid": 1, "sessionId": "abc"}))
        gone = self.marks / "gone-sid.json"
        gone.write_text(json.dumps({"sid": "gone-sid", "tmux": "x", "fingerprints": ["weekly-limit"], "pane": "%9",
                                    "since": 1, "updated": 1}))
        self.run_once()
        self.assertTrue(other.exists() and session_like.exists())
        self.assertFalse(gone.exists())
        # the sessions directory itself as the mark directory: refused, nothing in it touched
        sessions = self.tmp / "sessions"
        before = sorted(p.name for p in sessions.glob("*"))
        self.cfg.write_text(self.cfg.read_text().replace(f"STALL_MARK_DIR={self.marks}", f"STALL_MARK_DIR={sessions}"))
        f.set("%1", WEEKLY)
        with mock.patch.object(reaper, "PROJECTS_DIR", self.tmp / "projects"):
            self.assertEqual(self.run_once(), 1)
        self.assertIn("shared directory", self.printed)
        self.assertEqual(sorted(p.name for p in sessions.glob("*")), before)

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


class PromptRuns(unittest.TestCase):
    """A prompt on screen is aged from its first sighting and flagged past STALL_PROMPT_MINUTES, once per instance."""
    table = None
    setUp, write_config, start, run_once, inbox_text = Runs.setUp, Runs.write_config, Runs.start, Runs.run_once, Runs.inbox_text

    def age(self, minutes, field="first"):
        """Move every prompt event's `field` back by `minutes`, as if that much time had passed."""
        path = self.tmp / "state.json"
        st = json.loads(path.read_text())
        for ev in st["prompts"].values():
            if ev.get(field) is not None:
                ev[field] -= minutes * 60
        path.write_text(json.dumps(st))

    def prompt_blocks(self, name):
        return self.inbox_text().count(f"## EL-T921-PROMPT-STALL {name}\n")

    def test_a_permission_prompt_is_flagged_with_its_age_after_the_threshold(self):
        f = self.start({"%1": ("ci", PERMISSION), "%2": ("fine", HEALTHY)})
        self.assertEqual(self.run_once(), 0)
        self.assertIn("1 prompts on screen, 0 prompts flagged", self.printed)
        self.assertEqual(self.inbox_text(), "")
        self.age(11)
        self.assertEqual(self.run_once(), 0)
        text = self.inbox_text()
        self.assertEqual(self.prompt_blocks("ci"), 1)
        self.assertIn(f"id={f.sids['%1']} pane=%1 kind=permission", text)
        self.assertIn("on-screen=11m", text)
        self.assertNotIn("r.git", text)  # no screen text reaches the inbox
        self.assertNotIn("fine", text)
        self.assertIn("would push ci", self.printed)  # STALL_PUSH unset: the push is shadow
        self.assertEqual({c[1] for c in f.calls}, {"display", "capture-pane"})  # never answered, never typed

    def test_an_ask_user_question_menu_is_flagged(self):
        self.start({"%1": ("security", ASK_USER)})
        self.run_once()
        self.age(30)
        self.run_once()
        self.assertEqual(self.prompt_blocks("security"), 1)
        self.assertIn("kind=ask-user-question", self.inbox_text())
        self.assertIn("on-screen=30m", self.inbox_text())

    def test_prompt_apply_alone_alerts_once_per_menu_names_its_question_and_leaves_marks_in_shadow(self):
        # cc-reaper #128: sre and ci sat on a menu for hours while STALL_APPLY=0 kept the prompt half in shadow.
        self.write_config(apply="0", extra="STALL_PROMPT_APPLY=1\n")
        f = self.start({"%1": ("sre", ASK_USER), "%2": ("lost", DISCONNECTED)})
        self.run_once()
        self.age(10)
        self.run_once()  # the first tick past the threshold alerts
        text = self.inbox_text()
        self.assertEqual(self.prompt_blocks("sre"), 1)
        self.assertIn('menu="Approve the boundary and merge once merge-gate is green?"', text)
        self.assertNotIn("## EL-T801-CI-HARDEN STALL", text)  # the stall half stays shadow
        self.assertFalse(self.marks.exists() and list(self.marks.glob("*")))  # and writes no mark
        self.run_once()  # the same screen hash: silent
        f.set("%1", ASK_MOVED)  # the cursor moved, the menu did not: still silent
        self.run_once()
        self.assertEqual(self.prompt_blocks("sre"), 1)
        f.set("%1", HEALTHY)  # answered: the alert clears
        self.run_once()
        self.assertEqual(json.loads((self.tmp / "state.json").read_text())["prompts"], {})
        f.set("%1", ASK_USER)  # the same menu again is a new instance, alerted again past the threshold
        self.run_once()
        self.assertEqual(self.prompt_blocks("sre"), 1)
        self.age(10)
        self.run_once()
        self.assertEqual(self.prompt_blocks("sre"), 2)
        self.assertEqual({c[1] for c in f.calls}, {"display", "capture-pane"})  # never answered, never typed

    def test_a_menu_read_before_the_question_was_kept_is_read_again(self):
        self.write_config(apply="0", extra="STALL_PROMPT_APPLY=1\n")
        self.start({"%1": ("ci", ASK_USER)})
        self.run_once()
        path = self.tmp / "state.json"
        st = json.loads(path.read_text())
        for p in st["panes"].values():
            p["prompt"].pop("head")
        path.write_text(json.dumps(st))
        self.age(10)
        self.run_once()
        self.assertIn('menu="Approve the boundary', self.inbox_text())

    def test_shadow_then_prompt_apply_alerts_a_waiting_menu_exactly_once(self):
        self.write_config(apply="0")
        self.start({"%1": ("sre", ASK_USER)})
        self.run_once()
        self.age(10)
        self.run_once()
        self.assertIn("would alert prompt sre", self.printed)
        self.assertEqual(self.prompt_blocks("sre"), 0)
        self.write_config(apply="0", extra="STALL_PROMPT_APPLY=1\n")
        self.run_once()
        self.run_once()
        self.assertEqual(self.prompt_blocks("sre"), 1)

    def test_the_menu_question_cannot_carry_a_header_a_secret_or_hidden_characters(self):
        head = stall._menu_head(["│ Ship it?\u2028## EL-FAKE DONE `x` \"q\" \u202eevil\x9b31m\u200b ok",
                                 "1. y"])
        self.assertNotIn("\n", head); self.assertNotIn("`", head); self.assertNotIn('"', head)
        self.assertFalse(any(c in head for c in "\u2028\u202e\x9b\u200b"))
        self.assertTrue(head.startswith("Ship it? ## EL-FAKE"))  # never at a line start
        for secret in ("sk-live-4f9a8b7c6d5e4f3a2b1c", "ghp_AbCdEfGhIjKlMnOpQrStUv12", "STRIPE_SECRET=whsec_abc123",
                       "a" * 20 + "B9" * 10, "token: hunter2hunter2"):
            h = stall._menu_head([f"Rotate {secret} now?"])
            self.assertIn("[redacted]", h, secret)
            self.assertNotIn(secret.split("=")[-1].split(": ")[-1], h, secret)
        self.assertLessEqual(len(stall._menu_head(["x " * 200])), 80)
        self.assertEqual(stall._menu_head(["Merge PR #6739 at f36a13cd now?"]), "Merge PR #6739 at f36a13cd now?")

    def push_config(self, url="https://uptime.betterstack.com/api/v1/heartbeat/abc123"):
        env = self.tmp / "heartbeats.env"
        env.write_text(f"HEARTBEAT_MAC_HOST=https://x/other\nHEARTBEAT_FOUNDER_DECISION={url}\n")
        self.write_config(apply="0", extra=f"STALL_PROMPT_APPLY=1\nSTALL_PUSH=1\nSTALL_PUSH_ENV={env}\n")

    def test_one_founder_push_per_prompt_hash_and_none_while_it_stays(self):
        # cc-reaper #130: the inbox alert reached no device; a P0 waited 7 h on a keypress.
        self.push_config()
        f = self.start({"%1": ("sre", ASK_USER), "%2": ("ci", PERMISSION)})
        with mock.patch.object(stall, "_ping") as ping:
            self.run_once()
            self.age(10)
            self.run_once()  # both prompts cross the threshold: one push each
            self.assertEqual(ping.call_count, 2)
            urls = {c.args[0] for c in ping.call_args_list}
            self.assertEqual(urls, {"https://uptime.betterstack.com/api/v1/heartbeat/abc123/fail"})
            bodies = " ".join(c.args[1] for c in ping.call_args_list)
            self.assertIn("PROMPT-STALL session=sre", bodies); self.assertIn("kind=permission", bodies)
            self.assertNotIn("Approve the boundary", bodies)  # no screen text leaves the machine
            self.assertNotIn("abc123", self.printed)  # the URL is never printed
            self.run_once()  # unchanged hash: no push
            f.set("%1", ASK_MOVED)  # cursor moved, same prompt: no push
            self.run_once()
            self.age(200, "alerted")  # a log-only re-alert is not a push either
            self.run_once()
            self.assertEqual(ping.call_count, 2)
            f.set("%1", HEALTHY); self.run_once()
            f.set("%1", ASK_USER); self.run_once(); self.age(10); self.run_once()  # a new instance: one more
            self.assertEqual(ping.call_count, 3)
        self.assertEqual({c[1] for c in f.calls}, {"display", "capture-pane"})  # never answered, never typed

    def test_a_failed_push_is_a_failure_and_retried_until_it_goes_out_whatever_the_inbox(self):
        self.push_config()
        self.start({"%2": ("ci", PERMISSION)})
        with mock.patch.object(stall, "_ping", side_effect=[OSError("https://uptime.betterstack.com/secret"), None]) as ping:
            self.run_once(); self.age(10)
            self.assertEqual(self.run_once(), 1)  # the inbox alert went out, the push did not: a failure, not silence
            self.assertIn("push failed (OSError)", self.printed)
            self.assertIn("founder push failed, try 1 of 5", self.printed)
            self.assertNotIn("secret", self.printed)
            self.assertEqual(self.run_once(), 0)  # retried on the next tick, although the inbox was alerted already
            self.run_once()
        self.assertEqual(ping.call_count, 2)
        self.assertEqual(self.prompt_blocks("ci"), 1)

    def test_a_missing_url_is_retried_five_times_then_left(self):
        self.push_config(url="")
        self.start({"%1": ("sre", ASK_USER)})
        with mock.patch.object(stall, "_ping") as ping:
            self.run_once(); self.age(10)
            rcs, said = [], []
            for _ in range(7):
                rcs.append(self.run_once()); said.append(self.printed)
        ping.assert_not_called()
        self.assertEqual(rcs, [1] * 5 + [0, 0])
        self.assertIn("push: no https URL under HEARTBEAT_FOUNDER_DECISION", said[0])
        self.assertEqual(self.prompt_blocks("sre"), 1)

    def test_an_inbox_that_cannot_be_written_still_pushes(self):
        self.push_config()
        self.inbox.parent.mkdir(parents=True, exist_ok=True)
        self.start({"%1": ("sre", ASK_USER)})
        with mock.patch.object(stall, "_ping") as ping, mock.patch.object(stall, "append_inbox", side_effect=OSError("ro")):
            self.run_once(); self.age(10); self.run_once()
        self.assertEqual(ping.call_count, 1)

    def test_a_permission_prompt_carries_no_menu_text(self):
        self.write_config(apply="0", extra="STALL_PROMPT_APPLY=1\n")
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        self.run_once()
        self.assertEqual(self.prompt_blocks("ci"), 1)
        self.assertNotIn("menu=", self.inbox_text())

    def test_below_the_threshold_nothing_is_flagged(self):
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(9)
        self.run_once()
        self.assertEqual(self.inbox_text(), "")
        self.assertIn("0 prompts flagged", self.printed)
        self.write_config(extra="STALL_PROMPT_MINUTES=5\n")
        self.run_once()
        self.assertEqual(self.prompt_blocks("ci"), 1)

    def test_an_idle_or_busy_pane_is_never_flagged(self):
        self.start({"%1": ("idle", HEALTHY), "%2": ("busy", BUSY), "%3": ("quoted", QUOTED_PROMPT)})
        self.run_once()
        self.age(600)
        self.run_once()
        self.assertEqual(self.inbox_text(), "")
        self.assertIn("0 prompts on screen", self.printed)

    def test_one_inbox_entry_per_prompt_and_a_log_only_re_alert_after_the_longer_interval(self):
        f = self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        self.run_once()
        f.set("%1", PERMISSION_MOVED)  # the screen changed, the prompt did not
        self.run_once()
        self.age(60, "alerted")
        self.run_once()
        self.assertNotIn("still on screen", self.printed)
        self.assertEqual(self.prompt_blocks("ci"), 1)
        self.age(61, "alerted")  # 121 minutes since the alert
        self.run_once()
        self.assertIn("prompt still on screen ci", self.printed)
        self.assertIn("(log only; inbox alerted once)", self.printed)
        self.assertEqual(self.prompt_blocks("ci"), 1)  # no "still waiting" post (one ## entry per state change)
        self.run_once()
        self.assertNotIn("still on screen", self.printed)  # and the log line keeps the interval too
        self.age(121, "alerted")
        self.run_once()
        self.assertIn("prompt still on screen ci", self.printed)
        self.assertEqual(self.prompt_blocks("ci"), 1)

    def test_shadow_re_alert_is_a_log_line_too(self):
        self.write_config(apply="0")
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        self.run_once()
        self.assertIn("would alert prompt ci", self.printed)
        self.age(121, "shadow_at")
        self.run_once()
        self.assertIn("prompt still on screen ci", self.printed)
        self.assertNotIn("would alert prompt", self.printed)
        self.assertIn("0 would alert", self.printed)

    def test_folder_trust_and_plan_approval_are_flagged(self):
        self.start({"%1": ("trust", TRUST), "%2": ("plan", PLAN), "%3": ("quoted", QUOTE_BOTTOM_PERMISSION)})
        self.run_once()
        self.age(11)
        self.run_once()
        text = self.inbox_text()
        self.assertEqual((self.prompt_blocks("trust"), self.prompt_blocks("plan"), self.prompt_blocks("quoted")), (1, 1, 0))
        self.assertIn("kind=folder-trust", text)
        self.assertIn("kind=plan-approval", text)

    def test_malformed_stored_prompts_never_raise_and_are_seen_afresh(self):
        f = self.start({"%1": ("ci", PERMISSION), "%2": ("security", ASK_USER), "%3": ("work", WEEKLY)})
        self.run_once()
        self.assertEqual(self.inbox_text().count("STALL work"), 1)
        path = self.tmp / "state.json"
        st = json.loads(path.read_text())
        (k1, good), (k2, _) = sorted(st["prompts"].items())
        bad_entries = [
            {}, None, [], "x", 5,
            dict(good, first="yesterday"), dict(good, first=None), dict(good, alerts=True), dict(good, alerts=-1),
            dict(good, alerts="1"), dict(good, alerted="soon"), dict(good, shadow_at=[1]), dict(good, kind=7),
            dict(good, fp="0" * 16), {k: v for k, v in good.items() if k != "pane"},
            {k: v for k, v in good.items() if k != "first"}, dict(good, first=float("inf")),
        ]
        for n, bad in enumerate(bad_entries):
            with self.subTest(n=n, bad=bad):
                st["prompts"] = {k1: bad, "no-separator": good, "a|b|c": good, k2: st["prompts"].get(k2)}
                path.write_text(json.dumps(st))
                self.assertEqual(self.run_once(), 0, self.printed)
                self.assertIn("2 prompts on screen", self.printed)
                saved = json.loads(path.read_text())["prompts"]
                self.assertEqual(sorted(saved), sorted([k1, k2]))  # the bad entry was replaced by a fresh sighting
                st = json.loads(path.read_text())
        for whole in ([["a", "b"]], "x", None, 3):
            with self.subTest(whole=whole):
                st["prompts"] = whole
                path.write_text(json.dumps(st))
                self.assertEqual(self.run_once(), 0, self.printed)
                self.assertIn("2 prompts on screen", self.printed)
                # a bad prompts section costs nothing else: the pane hashes (no rescan) and the reported STALL event
                self.assertIn("0 rescanned", self.printed)
                self.assertEqual(self.inbox_text().count("STALL work"), 1)
                st = json.loads(path.read_text())

    def test_a_malformed_pane_prompt_reading_never_raises(self):
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        path = self.tmp / "state.json"
        for bad in ("garbage", 5, {"kind": 1}, {"fp": None, "kind": "permission"}, []):
            with self.subTest(bad=bad):
                st = json.loads(path.read_text())
                for p in st["panes"].values():
                    p["prompt"] = bad  # same hash: the stored reading is reused as it is
                path.write_text(json.dumps(st))
                self.assertEqual(self.run_once(), 0, self.printed)
                self.assertIn("0 rescanned", self.printed)

    def test_a_bad_minutes_value_falls_back_to_the_default(self):
        for v in ("nan", "inf", "ten", "-inf"):
            with self.subTest(v=v):
                (self.tmp / "state.json").unlink(missing_ok=True)
                self.inbox.unlink(missing_ok=True)
                self.write_config(extra=f"STALL_PROMPT_MINUTES={v}\nSTALL_PROMPT_REALERT_MINUTES={v}\n")
                self.start({"%1": ("ci", PERMISSION)})
                self.assertEqual(self.run_once(), 0)
                self.age(9)
                self.run_once()
                self.assertEqual(self.prompt_blocks("ci"), 0)
                self.age(2)
                self.run_once()
                self.assertEqual(self.prompt_blocks("ci"), 1)

    def test_a_prompt_sweep_crash_is_a_failure_and_the_state_is_still_saved(self):
        self.start({"%1": ("ci", PERMISSION), "%2": ("work", WEEKLY)})
        with mock.patch.object(stall, "prompt_sweep", side_effect=KeyError("first")):
            self.assertEqual(self.run_once(), 1)
        self.assertIn("ERROR prompt sweep failed (KeyError)", self.printed)
        st = json.loads((self.tmp / "state.json").read_text())
        self.assertEqual(len(st["panes"]), 2)
        self.assertEqual(st["prompts"], {})
        self.assertEqual(self.inbox_text().count("STALL work"), 1)  # the STALL report before it still stands

    def test_a_prompt_that_leaves_the_screen_and_comes_back_is_a_new_instance(self):
        f = self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        self.run_once()
        f.set("%1", HEALTHY)
        self.run_once()
        self.assertEqual(json.loads((self.tmp / "state.json").read_text())["prompts"], {})
        f.set("%1", PERMISSION)
        self.run_once()  # first sighting again: not aged
        self.assertEqual(self.prompt_blocks("ci"), 1)
        f.set("%1", PERMISSION_OTHER)  # a different prompt on the same session is its own instance
        self.run_once()
        self.assertEqual(len(json.loads((self.tmp / "state.json").read_text())["prompts"]), 1)

    def test_shadow_logs_what_it_would_alert_once_and_sends_nothing(self):
        self.write_config(apply="0")
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        self.run_once()
        self.assertIn("shadow: would alert prompt ci", self.printed)
        self.assertIn("kind=permission", self.printed)
        self.assertIn("1 would alert", self.printed)
        self.run_once()
        self.assertNotIn("would alert prompt", self.printed)
        self.assertFalse(self.inbox.exists())
        self.write_config(apply="1")
        self.run_once()  # apply after shadow still alerts the prompt that is there
        self.assertEqual(self.prompt_blocks("ci"), 1)

    def test_a_state_from_before_prompt_detection_is_rescanned(self):
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        path = self.tmp / "state.json"
        st = json.loads(path.read_text())
        for p in st["panes"].values():
            del p["prompt"]
        st.pop("prompts")
        path.write_text(json.dumps(st))
        self.run_once()
        self.assertIn("1 rescanned", self.printed)
        self.assertIn("1 prompts on screen", self.printed)

    def test_a_failed_read_keeps_the_prompt_first_sighting(self):
        f = self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        first = json.loads((self.tmp / "state.json").read_text())["prompts"]
        self.assertEqual(len(first), 1)
        f.fail.add("%1")
        self.run_once()
        self.assertEqual(json.loads((self.tmp / "state.json").read_text())["prompts"], first)

    def test_zero_minutes_turns_prompt_detection_off(self):
        self.write_config(extra="STALL_PROMPT_MINUTES=0\n")
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.run_once()
        self.assertEqual(self.inbox_text(), "")
        self.assertIn("0 prompts on screen", self.printed)

    def test_a_failed_alert_write_is_retried_next_run(self):
        self.start({"%1": ("ci", PERMISSION)})
        self.run_once()
        self.age(11)
        with mock.patch.object(stall, "append_inbox", side_effect=OSError("disk")):
            self.assertEqual(self.run_once(), 1)
        self.assertIn("prompt alert inbox write failed", self.printed)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.prompt_blocks("ci"), 1)


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
        now = time.time()

        def write(**kw):
            d = {"sid": "abc-123", "fingerprints": ["weekly-limit", "rate-limit-429"], "since": now - 60, "updated": now}
            d.update(kw)
            mark.write_text(json.dumps(d))
            os.utime(mark, None)
        write()
        self.assertEqual(reaper.decide(dict(s), cfg), ["stalled:weekly-limit,rate-limit-429"])
        old = mark.stat().st_mtime - 13 * 3600
        os.utime(mark, (old, old))
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        write(since=now - 49 * 3600)  # refreshed just now, but first seen past the cap
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        write(since=now + 30 * 86400, updated=now + 30 * 86400)  # a timestamp in the future still expires
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        write()
        future = now + 30 * 86400
        os.utime(mark, (future, future))  # a future mtime never makes a mark immortal
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        write(sid="other")  # a file that is not this session's mark
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        mark.write_text(json.dumps({"pid": 1, "sessionId": "abc-123", "status": "idle"}))  # a session file, not a mark
        self.assertEqual(reaper.decide(dict(s), cfg), [])
        mark.write_text("not json")
        os.utime(mark, None)
        self.assertEqual(reaper.decide(dict(s), cfg), [])  # an unreadable mark fails open to the old behavior
        self.assertEqual(reaper.stall_mark(cfg, "../escape"), "")


if __name__ == "__main__":
    unittest.main()
