#!/usr/bin/env python3
"""Install cc-reaper lifecycle triggers into a Claude or Codex hook file."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path
from typing import Any


LEGACY_WORKTREE_COMMANDS = (
    "/.claude/hooks/reclaim-worktrees.sh",
    "/.claude/hooks/reclaim-inventory.sh",
)
LEGACY_WORKTREE_ENV = ("WORKTREE_IDLE_HOURS", "WORKTREE_DRY_RUN")
LEGACY_STOP_COMMAND = "/.claude/hooks/stop-cleanup-orphans.sh"
SHARED_STOP_COMMAND = "/.cc-reaper/stop-cleanup-orphans.sh"


def command_for(harness: str) -> str:
    return f'"$HOME"/.cc-reaper/worktree-session-end.sh {harness}'


def stop_command() -> str:
    return '"$HOME"/.cc-reaper/stop-cleanup-orphans.sh'


def install(path: Path, harness: str) -> bool:
    if path.is_symlink():
        # Update the managed target atomically without replacing the symlink entry.
        # A relative target is resolved against the link's parent by Path.resolve().
        config_path = path.resolve(strict=True)
    else:
        config_path = path

    if config_path.exists():
        data: dict[str, Any] = json.loads(config_path.read_text())
    else:
        data = {}

    changed = False
    if harness == "claude":
        environment = data.get("env")
        if isinstance(environment, dict):
            for key in LEGACY_WORKTREE_ENV:
                if key in environment:
                    del environment[key]
                    changed = True

    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("hooks must be an object")

    # The process cleanup implementation belongs to cc-reaper too. Some older
    # installs registered it on SessionEnd; normalize it to its turn-level Stop event
    # and migrate the executable out of Claude's private hook directory. This walks
    # every event so a misplaced legacy command cannot survive beside the shared one.
    found_stop = False
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            commands = group.get("hooks")
            if not isinstance(commands, list):
                continue
            kept = []
            for hook in commands:
                if not isinstance(hook, dict):
                    kept.append(hook)
                    continue
                command = hook.get("command")
                if not isinstance(command, str):
                    kept.append(hook)
                    continue
                if harness == "claude" and LEGACY_STOP_COMMAND in command:
                    command = command.replace(LEGACY_STOP_COMMAND, SHARED_STOP_COMMAND)
                    hook["command"] = command
                    changed = True
                if SHARED_STOP_COMMAND in command:
                    if event == "Stop":
                        found_stop = True
                        kept.append(hook)
                    else:
                        changed = True
                    continue
                kept.append(hook)
            if kept != commands:
                group["hooks"] = kept

    if not found_stop:
        stop = hooks.setdefault("Stop", [])
        if not isinstance(stop, list):
            raise ValueError("hooks.Stop must be an array")
        stop.append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": stop_command(),
                        "timeout": 15,
                    }
                ]
            }
        )
        changed = True

    session_end = hooks.setdefault("SessionEnd", [])
    if not isinstance(session_end, list):
        raise ValueError("hooks.SessionEnd must be an array")

    wanted = command_for(harness)
    found = False
    for group in session_end:
        if not isinstance(group, dict):
            continue
        commands = group.get("hooks")
        if not isinstance(commands, list):
            continue
        kept = []
        for hook in commands:
            if not isinstance(hook, dict):
                kept.append(hook)
                continue
            command = hook.get("command", "")
            if any(marker in command for marker in LEGACY_WORKTREE_COMMANDS):
                changed = True
                continue
            if command == wanted:
                found = True
            kept.append(hook)
        if kept != commands:
            group["hooks"] = kept

    if not found:
        session_end.append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": wanted,
                        "timeout": 10,
                    }
                ]
            }
        )
        changed = True

    if not changed:
        return False

    config_path.parent.mkdir(parents=True, exist_ok=True)
    mode = config_path.stat().st_mode & 0o777 if config_path.exists() else 0o600
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=config_path.parent, delete=False
    ) as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
        temp_path = Path(handle.name)
    os.chmod(temp_path, mode)
    os.replace(temp_path, config_path)
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", choices=("claude", "codex"), required=True)
    parser.add_argument("--file", type=Path, required=True)
    args = parser.parse_args()
    try:
        changed = install(args.file, args.harness)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"cc-reaper: could not update {args.file}: {exc}", file=os.sys.stderr)
        return 1
    print(f"cc-reaper: {'updated' if changed else 'already configured'} {args.file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
