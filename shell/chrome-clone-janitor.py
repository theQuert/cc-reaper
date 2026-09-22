#!/usr/bin/env python3
"""Reclaim old Chrome code-sign clones without touching open application bundles.

The CLI root is derived from this user's macOS temporary directory. Tests call
scan() with an isolated root; no CLI option permits an arbitrary deletion root.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


NAME = re.compile(r"code_sign_clone\.[A-Za-z0-9]{6,}$")


def clone_roots():
    # Chrome creates one code-sign root per macOS per-user temp namespace.
    roots = sorted(Path("/private/var/folders").glob("*/*/X/com.google.Chrome.code_sign_clone"))
    return [root for root in roots if root.is_dir()]


def lsof_works():
    try:
        probe = subprocess.run(
            ["lsof", "-p", str(os.getpid()), "-d", "cwd", "-Fn"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
    except OSError:
        return False
    return b"n/" in probe.stdout


def held(path):
    """Return True for a holder or any failed/inconclusive probe."""
    try:
        probe = subprocess.run(
            ["lsof", "-F0n", "+D", str(path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return True
    # lsof returns 1 for a valid empty +D search on macOS. Other failures
    # that print diagnostics are not evidence of absence.
    if probe.stderr or probe.returncode not in (0, 1):
        return True
    prefix = os.fsencode(str(path)) + b"/"
    return any(field.startswith(b"n" + prefix) or field == b"n" + prefix[:-1]
               for field in probe.stdout.split(b"\0"))


def scan(root, clean=False, min_age_days=3, now=None):
    if not lsof_works():
        raise RuntimeError("lsof cannot see its own cwd; kept all clones")
    if min_age_days < 1:
        raise ValueError("minimum age must be at least one day")
    now = time.time() if now is None else now
    count = kept = removed = 0
    if not root.is_dir() or root.is_symlink():
        return count, kept, removed
    for path in sorted(root.iterdir()):
        if not NAME.fullmatch(path.name) or path.is_symlink() or not path.is_dir():
            continue
        count += 1
        before = path.lstat()
        if now - before.st_mtime < min_age_days * 86400 or held(path):
            kept += 1
            print(f"KEEP {path.name} (recent or open/inconclusive)")
            continue
        if not clean:
            print(f"CANDIDATE {path.name}")
            continue
        # Recheck immediately before removal. An inode replacement or newly
        # opened clone fails closed. rmtree does not traverse directory symlinks.
        current = path.lstat()
        if (current.st_dev, current.st_ino, current.st_mtime_ns) != (
                before.st_dev, before.st_ino, before.st_mtime_ns) or held(path):
            kept += 1
            print(f"KEEP {path.name} (changed or newly open)")
            continue
        shutil.rmtree(path)
        removed += 1
        print(f"REMOVED {path.name}")
    return count, kept, removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check", "clean"))
    parser.add_argument("--min-age-days", type=int, default=3)
    args = parser.parse_args()
    roots = clone_roots()
    result = [0, 0, 0]
    for root in roots:
        current = scan(root, clean=args.mode == "clean", min_age_days=args.min_age_days)
        result = [a + b for a, b in zip(result, current)]
        print(f"chrome clones: root={root} total={current[0]} kept={current[1]} removed={current[2]}")
    print(f"chrome clones: total={result[0]} kept={result[1]} removed={result[2]}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(f"chrome clones: SKIP {error}", file=sys.stderr)
        sys.exit(1)
