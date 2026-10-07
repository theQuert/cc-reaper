#!/usr/bin/env python3
"""The OrbStack trim agent, run through its LaunchAgent's own command line.

Each case installs the script where the plist expects it, under a temporary
HOME, and runs the plist's ProgramArguments with `pgrep`, `ps`, `sysctl` and
`docker` replaced. The run's PATH holds those shims and links to the few tools
the script needs, each found on the plist's own PATH, so no case can ever reach
a real docker. The install path, the log path and the agent's PATH are checked
together with the trim decision.
"""

import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "shell/orbstack-memory-trim.sh"
PLIST = ROOT / "launchd/com.cc-reaper.orbstack-memory-trim.plist"
AGENT = plistlib.loads(PLIST.read_bytes())
MIB = 1024  # ps reports rss in KiB
SWAP = "total = 8192.00M  used = 7290.50M  free = 901.50M  (encrypted)"

TOOLS = ("awk", "cat", "cp", "date", "perl", "sleep")
SHIMS = {
    "pgrep": '[ -f "$STATE/running" ] || exit 1\necho 4242\n',
    "ps": '[ -f "$STATE/gone" ] || cat "$STATE/rss"\n',
    "sysctl": 'case "$2" in hw.memsize) cat "$STATE/memsize" ;; vm.swapusage) echo "$SWAP" ;; *) exit 1 ;; esac\n',
    "docker": (
        'printf "%s\\n" "$@" >>"$STATE/docker.args"\n'
        # A hung docker ignores SIGALRM as the real Go CLI does, so only SIGKILL ends it.
        '[ ! -f "$STATE/hang" ] || { trap "" ALRM; sleep 30; }\n'
        'rc=$(cat "$STATE/docker.rc")\n'
        '[ "$rc" != 0 ] || cp "$STATE/after" "$STATE/rss"\n'
        'exit "$rc"\n'
    ),
}


class TrimAgent(unittest.TestCase):
    def run_agent(self, vm_mib, after_mib=0, ram_gib=32, docker_rc=0, running=True, env=None, flags=(),
                  shims=SHIMS):
        home = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, home)
        state, bin_dir, tools = home / "state", home / "bin", home / "tools"
        for d in (state, bin_dir, tools, home / ".cc-reaper/logs"):
            d.mkdir(parents=True)
        for tool in TOOLS:
            found = shutil.which(tool, path=AGENT["EnvironmentVariables"]["PATH"])
            self.assertIsNotNone(found, f"{tool} is not on the agent's PATH")
            (tools / tool).symlink_to(found)
        installed = home / ".cc-reaper/orbstack-memory-trim.sh"
        shutil.copy(SCRIPT, installed)
        installed.chmod(0o755)
        for name, body in shims.items():
            (bin_dir / name).write_text("#!/bin/sh\n" + body)
            (bin_dir / name).chmod(0o755)
        (state / "rss").write_text(f"{vm_mib * MIB}\n")
        (state / "after").write_text(f"{after_mib * MIB}\n")
        (state / "memsize").write_text(f"{ram_gib * 1024**3}\n")
        (state / "docker.rc").write_text(str(docker_rc))
        if running:
            (state / "running").touch()
        for flag in flags:
            (state / flag).touch()
        run_env = {
            "HOME": str(home),
            "PATH": f"{bin_dir}:{tools}",
            "STATE": str(state),
            "SWAP": SWAP,
            "ORBSTACK_TRIM_SETTLE_SECONDS": "0",
            **(env or {}),
        }
        rc = subprocess.run(AGENT["ProgramArguments"], env=run_env).returncode
        log = (home / ".cc-reaper/logs/orbstack-memory-trim.log").read_text()
        args_file = state / "docker.args"
        docker = args_file.read_text().splitlines() if args_file.exists() else None
        return rc, log, docker

    def test_under_or_at_the_limit_does_nothing(self):
        for vm in (5120, 8192):  # a quarter of 32 GiB is 8192 MiB, and at it is not over it
            rc, log, docker = self.run_agent(vm)
            self.assertEqual((rc, docker), (0, None))
            self.assertRegex(log, rf"^\S+ vm_mib={vm} limit_mib=8192 swap_used=7290.50M action=none\n$")

    def test_over_the_limit_drops_the_guest_caches_from_a_pinned_throwaway_container(self):
        rc, log, docker = self.run_agent(10711, after_mib=4116)
        self.assertEqual(rc, 0)
        # Exactly one call, sent to the OrbStack context by name whatever the current context is.
        self.assertEqual(docker[:9], ["--context", "orbstack", "run", "--rm", "--name",
                                      "cc-reaper-orbstack-memory-trim", "--privileged", "--network", "none"])
        self.assertRegex(docker[9], r"^alpine@sha256:[0-9a-f]{64}$")
        self.assertEqual(docker[10:], ["sh", "-c", "sync && echo 3 > /proc/sys/vm/drop_caches"])
        self.assertRegex(log, r"^\S+ vm_mib=10711 limit_mib=8192 swap_used=7290.50M action=trim after_mib=4116\n$")

    def test_the_limit_follows_the_hosts_memory(self):
        rc, log, docker = self.run_agent(5120, after_mib=2048, ram_gib=16)
        self.assertEqual(rc, 0)
        self.assertIsNotNone(docker)
        self.assertIn("limit_mib=4096", log)

    def test_an_explicit_limit_wins(self):
        rc, log, docker = self.run_agent(5120, env={"ORBSTACK_TRIM_LIMIT_MIB": "6144"})
        self.assertEqual((rc, docker), (0, None))
        self.assertIn("limit_mib=6144 ", log)

    def test_a_failed_trim_fails_the_run_and_says_so(self):
        rc, log, docker = self.run_agent(10711, docker_rc=125)
        self.assertEqual(rc, 1)
        self.assertIsNotNone(docker)
        self.assertRegex(log, r"action=trim-failed\n$")

    def test_no_vm_means_nothing_to_trim(self):
        for running, flags in ((False, ()), (True, ("gone",))):  # gone: exited between pgrep and ps
            rc, log, docker = self.run_agent(10711, running=running, flags=flags)
            self.assertEqual((rc, docker), (0, None))
            self.assertRegex(log, r"^\S+ vm=not-running swap_used=7290.50M action=none\n$")

    def test_a_hung_trim_is_killed_and_logged_as_failed(self):
        started = time.monotonic()
        rc, log, docker = self.run_agent(10711, flags=("hang",), env={"ORBSTACK_TRIM_TIMEOUT_SECONDS": "1"})
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual(rc, 1)
        self.assertIsNotNone(docker)
        self.assertRegex(log, r"action=trim-failed\n$")

    def test_a_docker_that_cannot_start_is_a_failed_trim(self):
        rc, log, docker = self.run_agent(10711, shims={k: v for k, v in SHIMS.items() if k != "docker"})
        self.assertEqual((rc, docker), (1, None))
        self.assertIn("exec docker: ", log)
        self.assertRegex(log, r"action=trim-failed\n$")

    def test_the_agent_runs_on_an_interval_and_is_never_kept_alive(self):
        self.assertEqual(PLIST.stem, AGENT["Label"])
        self.assertEqual(AGENT["StartInterval"], 900)
        self.assertTrue(AGENT["RunAtLoad"])
        self.assertNotIn("KeepAlive", AGENT)
        # OrbStack installs its docker CLI in /usr/local/bin, which launchd's default PATH lacks.
        self.assertIn("/usr/local/bin", AGENT["EnvironmentVariables"]["PATH"].split(":"))


if __name__ == "__main__":
    unittest.main()
