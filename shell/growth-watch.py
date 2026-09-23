#!/usr/bin/env python3
"""Rotating, budgeted size samples of configured storage targets, and growth alerts.

Called by `disk-janitor --check`, which logs every line printed here and raises one
cooldown-gated notification when a line starts with `ALERT:growth`. Read-only: it measures,
records and reports, and removes nothing.

Targets file (CC_DJ_GROWTH_TARGETS), one row per target:
    label<TAB>path<TAB>owner[<TAB>alert GB]
A path with a glob wildcard makes one key per matching directory, and the label is their
total. `docker:<type>` reads one category of `docker system df`; `docker:volumes/<glob>`
reads matching volumes from `docker system df -v`. `~` and `{uid}` are expanded.

Samples (CC_DJ_STATE_DIR/growth-samples.tsv): `<epoch>\t<key>\t<KiB or status>`.
"""
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from glob import glob

KEEP_SECONDS = 14 * 86400
MIN_BASELINE_SECONDS = 3 * 3600
GLOB_CHARS = re.compile(r"[*?\[]")
DOCKER_UNITS = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}


def env_number(name, default):
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        value = float(raw)
    except ValueError:
        print(f"growth: {name}={raw!r} is not a number; using {default}")
        return default
    if value < 0:
        print(f"growth: {name}={raw!r} is negative; using {default}")
        return default
    return value


def expand(path):
    path = path.replace("{uid}", str(os.getuid()))
    return os.path.expanduser(path)


def gb(kib):
    return kib / 1048576.0


def read_targets(path, default_alert):
    rows = []
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except (FileNotFoundError, NotADirectoryError):
        return rows
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 3 or not fields[0].strip() or not fields[1].strip():
            print(f"growth: {path} line {number} is not label<TAB>path<TAB>owner; ignored")
            continue
        alert = default_alert
        if len(fields) > 3 and fields[3].strip():
            try:
                alert = float(fields[3])
            except ValueError:
                print(f"growth: {path} line {number} alert GB {fields[3]!r} is not a number; ignored")
                continue
        rows.append({
            "label": fields[0].strip(),
            "path": fields[1].strip(),
            "owner": fields[2].strip() or "-",
            "alert": alert,
        })
    return rows


def read_samples(path, now):
    samples = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                fields = line.rstrip("\n").split("\t")
                if len(fields) != 3:
                    continue
                try:
                    epoch = int(fields[0])
                except ValueError:
                    continue
                if now - epoch > KEEP_SECONDS or epoch > now:
                    continue
                value = int(fields[2]) if fields[2].isdigit() else fields[2]
                samples.append((epoch, fields[1], value))
    except FileNotFoundError:
        pass
    return samples


def write_samples(path, samples):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        for epoch, key, value in samples:
            handle.write(f"{epoch}\t{key}\t{value}\n")
    os.replace(tmp, path)


def dir_status(path):
    """`absent` or `denied` when a directory cannot be listed, else None."""
    try:
        os.listdir(path)
    except (FileNotFoundError, NotADirectoryError):
        return "absent"
    except PermissionError:
        return "denied"
    return None


def du_kib(path, timeout):
    """KiB used under path, or a status. A status is never a size."""
    if not os.path.lexists(path):
        return "absent"
    if os.path.isdir(path):
        try:
            os.listdir(path)
        except PermissionError:
            return "denied"
        except FileNotFoundError:
            return "absent"
    try:
        # du is resolved on PATH at call time; nice keeps it out of interactive work.
        done = subprocess.run(["nice", "-n", "19", "du", "-skx", path],
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timeout"
    except OSError:
        return "error"
    lines = [line for line in done.stdout.splitlines() if line.strip()]
    if not lines:
        if "not permitted" in done.stderr or "Permission denied" in done.stderr:
            return "denied"
        return "absent" if not os.path.lexists(path) else "error"
    # A total with unreadable entries below it is still the total of what can be read, and
    # the same entries stay unreadable, so its growth is still growth.
    try:
        return int(lines[-1].split(None, 1)[0])
    except ValueError:
        return "error"


def docker_size_kib(text):
    match = re.fullmatch(r"\s*([0-9.]+)\s*([kKMGT]?B)\s*", text or "")
    if not match:
        return None
    return int(float(match.group(1)) * DOCKER_UNITS[match.group(2)] / 1024)


def docker_json_lines(args, timeout):
    try:
        done = subprocess.run(["docker"] + args, capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if done.returncode != 0:
        return None
    rows = []
    for line in done.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            return None
    return rows


def main():
    now = int(env_number("CC_DJ_GROWTH_NOW", 0)) or int(time.time())
    state_dir = os.environ.get("CC_DJ_STATE_DIR") or os.path.expanduser("~/.cc-reaper/state")
    targets_path = expand(os.environ.get("CC_DJ_GROWTH_TARGETS") or "~/.cc-reaper/growth-targets.tsv")
    interval = env_number("CC_DJ_GROWTH_INTERVAL_HOURS", 6) * 3600
    budget = env_number("CC_DJ_GROWTH_BUDGET_SECONDS", 240)
    window = env_number("CC_DJ_GROWTH_WINDOW_HOURS", 24) * 3600
    default_alert = env_number("CC_DJ_GROWTH_ALERT_GB", 5)
    key_timeout = env_number("CC_DJ_GROWTH_KEY_TIMEOUT", 900)

    rows = read_targets(targets_path, default_alert)
    if not rows:
        print(f"growth: no growth targets configured ({targets_path})")
        return 0
    os.makedirs(state_dir, exist_ok=True)
    samples_path = os.path.join(state_dir, "growth-samples.tsv")
    samples = read_samples(samples_path, now)
    last = {}
    for epoch, key, _ in samples:
        last[key] = max(last.get(key, 0), epoch)

    def due(key):
        return key not in last or now - last[key] >= interval

    # One task per measurement. Glob members are separate tasks; each docker source is one
    # task however many keys it records.
    tasks = []
    owners, alerts, members = {}, {}, {}
    docker_categories = {}
    for row in rows:
        label, path = row["label"], row["path"]
        owners[label], alerts[label] = row["owner"], row["alert"]
        if path.startswith("docker:volumes/"):
            pattern = path[len("docker:volumes/"):] or "*"
            known = [k for k in last if k.startswith(label + "/")]
            newest = max((last[k] for k in known), default=None)
            members[label] = None  # decided by the listing
            if newest is None or now - newest >= interval:
                tasks.append((newest or 0, "volumes", (label, pattern)))
        elif path.startswith("docker:"):
            docker_categories[path[len("docker:"):]] = label
        elif GLOB_CHARS.search(path):
            expanded = expand(path)
            prefix = expanded[:GLOB_CHARS.search(expanded).start()].rsplit("/", 1)[0]
            # glob() answers an unreadable or missing prefix with an empty list, which would
            # read as "nothing here". Record why instead.
            status = dir_status(prefix)
            if status:
                members[label] = []
                if due(label):
                    tasks.append((last.get(label, 0), "status", (label, status)))
                continue
            found = sorted(p for p in glob(expanded) if os.path.isdir(p) and not os.path.islink(p))
            keys = []
            for match in found:
                key = f"{label}/{os.path.relpath(match, prefix)}"
                keys.append(key)
                owners[key], alerts[key] = row["owner"], row["alert"]
                if due(key):
                    tasks.append((last.get(key, 0), "path", (key, match)))
            members[label] = keys
        else:
            if due(label):
                tasks.append((last.get(label, 0), "path", (label, expand(path))))
    if docker_categories:
        oldest = min((last.get(k, 0) for k in docker_categories.values()), default=0)
        if any(due(k) for k in docker_categories.values()):
            tasks.append((oldest, "categories", None))

    tasks.sort(key=lambda task: task[0])
    started = time.monotonic()
    measured, waiting, fresh = 0, 0, {}
    for _, kind, spec in tasks:
        if time.monotonic() - started >= budget:
            waiting += 1
            continue
        measured += 1
        if kind == "path":
            key, path = spec
            fresh[key] = du_kib(path, key_timeout)
        elif kind == "status":
            key, status = spec
            fresh[key] = status
        elif kind == "categories":
            listing = docker_json_lines(["system", "df", "--format", "{{json .}}"], key_timeout)
            sizes = {} if listing is None else {r.get("Type"): docker_size_kib(r.get("Size")) for r in listing}
            for kind_name, key in docker_categories.items():
                value = sizes.get(kind_name)
                fresh[key] = "unavailable" if listing is None else (value if value is not None else "absent")
        else:
            label, pattern = spec
            listing = docker_json_lines(["system", "df", "-v", "--format", "{{json .}}"], key_timeout)
            if listing is None:
                fresh[label] = "unavailable"
                continue
            keys = []
            for volume in (listing[0].get("Volumes") or []) if listing else []:
                name = volume.get("Name") or ""
                size = docker_size_kib(volume.get("Size"))
                if fnmatch.fnmatchcase(name, pattern) and size is not None:
                    key = f"{label}/{name}"
                    keys.append(key)
                    owners[key], alerts[key] = owners[label], alerts[label]
                    fresh[key] = size
            members[label] = keys

    for key, value in fresh.items():
        samples.append((now, key, value))
        if not isinstance(value, int):
            print(f"growth: {key} could not be measured ({value})")

    # A label total, only when every current member has a number, and only when this run
    # measured one of them: a member not yet measured must not read as a fall.
    latest = {}
    for epoch, key, value in samples:
        if key not in latest or epoch >= latest[key][0]:
            latest[key] = (epoch, value)
    for label, keys in members.items():
        if not keys or not any(k in fresh for k in keys):
            continue
        values = [latest.get(k, (0, None))[1] for k in keys]
        if all(isinstance(v, int) for v in values):
            fresh[label] = sum(values)
            samples.append((now, label, fresh[label]))

    write_samples(samples_path, samples)

    history = {}
    for epoch, key, value in samples:
        if isinstance(value, int) and epoch < now:
            history.setdefault(key, []).append((epoch, value))
    grown = []
    for key, value in fresh.items():
        if not isinstance(value, int):
            continue
        past = history.get(key, [])
        older = [s for s in past if s[0] <= now - window]
        if older:
            base = max(older)
        else:
            candidates = [s for s in past if s[0] <= now - MIN_BASELINE_SECONDS]
            if not candidates:
                continue
            base = min(candidates)
        grown.append((value - base[1], (now - base[0]) / 3600.0, key, value))

    print(f"growth: sampled {measured} target(s)"
          + (f"; {waiting} due target(s) wait for a later run" if waiting else ""))
    top = sorted((g for g in grown if g[0] > 0), reverse=True)[:3]
    if top:
        print("growth: top " + "; ".join(
            f"+{gb(d):.1f}GB {key} ({owners.get(key, '-')}) in {h:.1f}h" for d, h, key, _ in top))
    for delta, hours, key, value in sorted(grown, reverse=True):
        if gb(delta) >= alerts.get(key, default_alert) > 0:
            print(f"ALERT:growth key={key} owner={owners.get(key, '-')} "
                  f"+{gb(delta):.1f}GB in {hours:.1f}h now={gb(value):.1f}GB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
