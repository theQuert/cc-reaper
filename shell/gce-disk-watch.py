#!/usr/bin/env python3
"""Watch the root disk of the GCE CI hosts from the Mac mini, and tell a full or unreadable one once.

stima-ci-ctl-1's `/` sat at 100% (19G/19G) from about 16:50Z on 2026-10-30: its event gateway failed, the JIT
runners stopped, and nothing alerted, because every disk alarm either lived on the watched host or went through
that gateway. This watch depends on neither: it runs on the Mac mini, reads each host over IAP, and writes only
to local files (and a local notification).

  read    per host, one `gcloud compute ssh <host> --tunnel-through-iap --command 'df -P / ; df -Pi /'` with
          BatchMode and a per-host timeout (GDW_HOST_TIMEOUT_SECONDS, 90), all hosts in parallel and the whole
          run bounded (GDW_RUN_TIMEOUT_SECONDS, 240). Nothing but that df command ever runs on a host. macOS has
          no `timeout`, so the bound is Python's: on expiry this script's own gcloud child (its process group,
          ssh included) is ended. No other process is signalled.
  judge   `/` used >= GDW_USED_PCT (90) or available < GDW_MIN_AVAIL_GB (2 GiB) or inodes >= GDW_INODE_PCT (90)
          is `disk-high`; a read that fails, times out or prints no `/` line is `unreadable` (its own kind, with
          a fixed reason word, never the command's output), told only after GDW_UNREADABLE_ROUNDS (2) such reads in a
          row (until then the host keeps its previous kind); a host in GDW_KNOWN_UNREADABLE is never told `unreadable`
          (logged `known-unreadable`); a disk-high read on it still is, and stays until a read shows it clear. Without GDW_SSH_KEY and its .pub every host is
          `unreadable reason=no-ssh-key` and gcloud is never called. One bad host, or one damaged state entry (read
          back as `ok`, so the host is told again), never stops the others.
  tell    once per host per state change; while it stays, again at most every GDW_REALERT_MINUTES (120); one
          `recovered` line when it clears. Shadow by default (GDW_APPLY=0): a `would alert` line in the log and
          nothing else. GDW_APPLY=1: one `## EL-T24-GCE-DISK <host>` block in GDW_INBOX (state changes only,
          unless GDW_REALERT_INBOX=1), one `<ts> P0 GCE-DISK <host> <kind> ...` line in GDW_EVENTS_LOG and a
          macOS notification. Every write goes to a local path. A write that fails is logged ERROR and stays
          pending in the state, so the next run retries that channel alone.
  record  every run logs one line per host and one summary line (hosts, read, high, unreadable, would-alert,
          alerted, recovered, failures): the spot-check record.

Config: defaults, then GDW_CONFIG (~/.cc-reaper/gce-disk-watch.conf, KEY=VALUE), then GDW_* environment variables.
"""

import argparse
import concurrent.futures
import fcntl
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

HEADER = "EL-T24-GCE-DISK"
DEFAULTS = {
    "GDW_APPLY": "0",  # 0: shadow (log only). 1: inbox, events log and notification
    "GDW_HOSTS": "stima-ci-1 stima-ci-2 stima-ci-3 stima-ci-ctl-1 stima-ci-deploy-1",
    "GDW_PROJECT": "stima-ci-runners",
    "GDW_ZONE": "asia-east1-b",
    "GDW_GCLOUD": "gcloud",
    "GDW_USED_PCT": "90",
    "GDW_MIN_AVAIL_GB": "2",  # GiB
    "GDW_INODE_PCT": "90",
    "GDW_HOST_TIMEOUT_SECONDS": "90",
    "GDW_RUN_TIMEOUT_SECONDS": "240",
    "GDW_REALERT_MINUTES": "120",
    "GDW_REALERT_INBOX": "0",  # 0: a re-alert goes to the events log and the notification, the inbox gets state changes
    "GDW_INBOX": "~/handoffs/neo-inbox.md",
    "GDW_EVENTS_LOG": "~/handoffs/ops-dispatch/events.log",
    "GDW_STATE": "~/.cc-reaper/state/gce-disk-watch.json",
    "GDW_LOG": "~/.cc-reaper/logs/gce-disk-watch.log",
    "GDW_NOTIFY": "1",  # 0: no macOS notification even with GDW_APPLY=1
    "GDW_UNREADABLE_ROUNDS": "2",  # consecutive unreadable reads before `unreadable` is told (one IAP blip is not)
    "GDW_KNOWN_UNREADABLE": "",  # hosts read every round whose failed read is logged, never told (access refused by design)
    "GDW_SSH_KEY": "~/.ssh/google_compute_engine",  # must exist with its .pub: gcloud is never let generate one
}
CONFIG = Path.home() / ".cc-reaper" / "gce-disk-watch.conf"
DF_COMMAND = "df -P / ; df -Pi /"  # the only command that ever runs on a host
NAME_RE = re.compile(r"[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?")  # GCE instance, project and zone names
GIB = 1 << 30
OK, HIGH, UNREADABLE = "ok", "disk-high", "unreadable"
KINDS = (OK, HIGH, UNREADABLE)
NOTICES = (None, "alert", "recover", "realert")
CHANNELS = ("shadow", "inbox", "events", "notify")


# ---------- config ----------

def load_config(path=None, env=None):
    env = os.environ if env is None else env
    cfg = dict(DEFAULTS)
    path = Path(os.path.expanduser(path or env.get("GDW_CONFIG") or str(CONFIG)))
    try:
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                if k.strip() in DEFAULTS:
                    cfg[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    cfg.update({k: env[k] for k in DEFAULTS if k in env})
    return cfg


def number(cfg, key):
    try:
        v = float(cfg[key])
    except (TypeError, ValueError):
        v = float(DEFAULTS[key])
    return v if math.isfinite(v) else float(DEFAULTS[key])


def path_of(cfg, key):
    return Path(os.path.expanduser(cfg[key]))


# ---------- read ----------

def gcloud_argv(cfg, host):
    return [cfg["GDW_GCLOUD"], "compute", "ssh", host, "--project", cfg["GDW_PROJECT"], "--zone", cfg["GDW_ZONE"],
            "--tunnel-through-iap", "--quiet", "--ssh-key-file", os.path.expanduser(cfg["GDW_SSH_KEY"]),
            "--command", DF_COMMAND,
            "--", "-o", "ConnectTimeout=30", "-o", "BatchMode=yes"]


def gcloud_runner(cfg, host, timeout):
    """One read of one host: (exit status, stdout, reason). Ends only its own child's process group on timeout."""
    env = dict(os.environ, CLOUDSDK_CORE_DISABLE_PROMPTS="1")
    try:
        p = subprocess.Popen(gcloud_argv(cfg, host), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, start_new_session=True, env=env)
    except OSError:
        return 127, "", "no-gcloud"
    try:
        out, _ = p.communicate(timeout=max(1.0, timeout))
        return p.returncode, out or "", None
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(p.pid, sig)
            except OSError:
                pass
            try:
                p.wait(timeout=5)
                break
            except subprocess.TimeoutExpired:
                continue
        if p.stdout:
            p.stdout.close()
        return None, "", "timeout"


def parse_df(text):
    """`df -P /` then `df -Pi /` output -> {"used_pct", "avail_kb", "inode_pct"} or None. inode_pct may be None (a
    filesystem without inode counts prints `-`); the block line for `/` is required."""
    kind, blocks, inodes = None, None, None
    for line in (text or "").splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "Filesystem":
            kind = "inodes" if any(h in ("Inodes", "IUse%") for h in f) else "blocks"
            continue
        if len(f) < 6 or f[-1] != "/":
            continue
        if kind == "blocks" and blocks is None:
            blocks = f
        elif kind == "inodes" and inodes is None:
            inodes = f
    if blocks is None:
        return None
    try:
        used_pct = int(blocks[-2].rstrip("%"))
        avail_kb = int(blocks[-3])
    except ValueError:
        return None
    inode_pct = None
    if inodes is not None:
        try:
            inode_pct = int(inodes[-2].rstrip("%"))
        except ValueError:
            inode_pct = None
    return {"used_pct": used_pct, "avail_kb": avail_kb, "inode_pct": inode_pct}


def judge(cfg, m):
    avail_gb = m["avail_kb"] * 1024 / GIB
    if m["used_pct"] >= number(cfg, "GDW_USED_PCT") or avail_gb < number(cfg, "GDW_MIN_AVAIL_GB") \
            or (m["inode_pct"] is not None and m["inode_pct"] >= number(cfg, "GDW_INODE_PCT")):
        return HIGH
    return OK


def read_hosts(cfg, hosts, runner):
    """{host: {"kind", "metrics" | None, "reason" | None}}; every host gets an answer within the run bound."""
    per_host = max(1.0, number(cfg, "GDW_HOST_TIMEOUT_SECONDS"))
    deadline = time.monotonic() + max(1.0, number(cfg, "GDW_RUN_TIMEOUT_SECONDS"))

    def one(host):
        left = deadline - time.monotonic()
        if left <= 0:
            return None, "", "run-timeout"
        return runner(cfg, host, min(per_host, left))

    out = {}
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(hosts)))
    futures = {pool.submit(one, h): h for h in hosts}
    try:
        done, _ = concurrent.futures.wait(futures, timeout=max(0.0, deadline - time.monotonic()) + 10)
    finally:
        pool.shutdown(wait=False)
    for fut, host in futures.items():
        if fut not in done:
            out[host] = {"kind": UNREADABLE, "metrics": None, "reason": "run-timeout"}
            continue
        try:
            rc, text, reason = fut.result()
        except Exception as e:  # noqa: BLE001 - a broken runner is one unreadable host, never a stopped run
            out[host] = {"kind": UNREADABLE, "metrics": None, "reason": f"runner-{type(e).__name__}"}
            continue
        m = parse_df(text) if rc == 0 else None
        if m is None:
            reason = reason or (f"exit-{rc}" if rc != 0 else "no-df-output")
            out[host] = {"kind": UNREADABLE, "metrics": None, "reason": reason}
        else:
            out[host] = {"kind": judge(cfg, m), "metrics": m, "reason": None}
    return out


# ---------- tell ----------

def numbers(r):
    m = r.get("metrics")
    if not m:
        return f"used=? avail=? inodes=? reason={r.get('reason') or 'unknown'}"
    inodes = "?" if m["inode_pct"] is None else f"{m['inode_pct']}%"
    return f"used={m['used_pct']}% avail={m['avail_kb'] * 1024 / GIB:.1f}GB inodes={inodes}"


def stamp(now):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))


def utc(now):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))


def inbox_block(cfg, host, notice, kind, r, now):
    word = "RECOVERED" if notice == "recover" else ("STILL" if notice == "realert" else "ALERT")
    return (f"\n## {HEADER} {host}\n\n"
            f"GCE-DISK {word} host={host} kind={kind} {numbers(r)} project={cfg['GDW_PROJECT']} "
            f"zone={cfg['GDW_ZONE']} at={utc(now)}\n")


def events_line(host, notice, kind, r, now):
    if notice == "recover":
        return f"{stamp(now)} INFO GCE-DISK {host} recovered {numbers(r)}\n"
    return f"{stamp(now)} P0 GCE-DISK {host} {kind} {numbers(r)}\n"


def append(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(text)


def osascript_notify(title, text):
    """A local notification. The text is a host name, a fixed kind and numbers, so it needs no AppleScript quoting
    beyond refusing a quote or backslash outright."""
    if any(c in title + text for c in '"\\'):
        raise OSError("notification text holds a quote")
    p = subprocess.run(["osascript", "-e", f'display notification "{text}" with title "{title}"'],
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
    if p.returncode != 0:
        raise OSError(f"osascript exit {p.returncode}")


class Watch:
    def __init__(self, cfg, runner=gcloud_runner, notifier=osascript_notify, clock=time.time):
        self.cfg, self.runner, self.notifier, self.clock = cfg, runner, notifier, clock
        self.apply = cfg["GDW_APPLY"] == "1"
        self.log_path = path_of(cfg, "GDW_LOG")
        self.lines = []

    def log(self, text):
        line = f"{utc(self.clock())} gce-disk-watch {text}"
        self.lines.append(line)
        print(line)
        try:
            append(self.log_path, line + "\n")
        except OSError as e:
            print(f"gce-disk-watch: ERROR log write failed: {e}", file=sys.stderr)

    def channels(self, notice):
        if not self.apply:
            return ["shadow"]
        ch = []
        if notice != "realert" or self.cfg["GDW_REALERT_INBOX"] == "1":
            ch.append("inbox")
        ch.append("events")
        if self.cfg["GDW_NOTIFY"] == "1":
            ch.append("notify")
        return ch

    def has_ssh_key(self):
        """--quiet would let gcloud generate a key and write it into project or instance metadata: a missing key
        (or its .pub) is reported, and gcloud is never called."""
        key = Path(os.path.expanduser(self.cfg["GDW_SSH_KEY"]))
        return key.is_file() and key.with_name(key.name + ".pub").is_file()

    def deliver(self, channel, host, entry, r, now):
        notice, kind = entry["notice"], entry["kind"]
        if channel == "shadow":
            verb = "would recover" if notice == "recover" else ("would re-alert" if notice == "realert" else "would alert")
            self.log(f"shadow: {verb} {host} {'recovered' if notice == 'recover' else kind} {numbers(r)}")
        elif channel == "inbox":
            append(path_of(self.cfg, "GDW_INBOX"), inbox_block(self.cfg, host, notice, kind, r, now))
        elif channel == "events":
            append(path_of(self.cfg, "GDW_EVENTS_LOG"), events_line(host, notice, kind, r, now))
        elif channel == "notify":
            word = "recovered" if notice == "recover" else kind
            self.notifier("GCE disk", f"{host} {word} {numbers(r)}")

    def one_host(self, host, r, book, now, every, rounds, counts, failures):
        read_kind = r["kind"]
        counts["read"] += r["metrics"] is not None
        counts[HIGH] += read_kind == HIGH
        counts[UNREADABLE] += read_kind == UNREADABLE
        prev = valid_entry(book.get(host)) or {"kind": OK, "todo": [], "told": False, "fails": 0, "notice": None,
                                                 "sent": None, "since": None}
        fails = prev["fails"] + 1 if read_kind == UNREADABLE else 0
        # An unreadable read is told only after `rounds` in a row; until then the host keeps its previous kind.
        # A known-unreadable host is never told `unreadable`: a stored one clears silently, a disk-high read still tells.
        known = host in self.cfg["GDW_KNOWN_UNREADABLE"].split()
        quiet = known and read_kind == UNREADABLE and prev["kind"] == UNREADABLE
        if read_kind != UNREADABLE or (fails >= rounds and not known):
            kind = read_kind
        else:
            kind = OK if quiet else prev["kind"]
        held = (" known-unreadable" if known else f" fails={fails}/{rounds}") if read_kind == UNREADABLE else ""
        self.log(f"host {host} {read_kind} {numbers(r)}{held}")
        if kind != prev["kind"]:
            # A recovery is told only for a state something was told about; a never-told one just clears.
            notice = "alert" if kind != OK else ("recover" if prev["told"] and not quiet else None)
            entry = {"kind": kind, "since": now, "notice": notice, "todo": self.channels(notice) if notice else [],
                     "sent": None, "told": False}
        else:
            entry = prev
            if kind != OK and not entry["todo"] and entry["sent"] is not None and now - entry["sent"] >= every:
                entry.update(notice="realert", todo=self.channels("realert"))
        entry["fails"] = fails
        # Only this mode's channels: a stored todo (a hand edit, the other mode's) never reaches another channel.
        allowed = set(self.channels(entry["notice"])) if entry["notice"] else set()
        entry["todo"] = [c for c in entry["todo"] if c in allowed]
        book[host] = entry
        todo = list(entry["todo"])
        for ch in todo:
            try:
                self.deliver(ch, host, entry, r, now)
            except (OSError, subprocess.SubprocessError) as e:
                failures.append(f"{host}: {ch} write failed ({type(e).__name__}): kept pending, retried next run")
                continue
            entry["todo"].remove(ch)
            entry["told"] = True
        if todo and not entry["todo"]:
            entry["sent"] = now
            if entry["notice"] == "recover":
                counts["recovered"] += 1
            elif self.apply:
                counts["alerted"] += 1
                self.log(f"alerted {host} {kind} {numbers(r)} ({entry['notice']})")
            else:
                counts["would"] += 1

    def run(self, hosts):
        now = self.clock()
        mode = "apply" if self.apply else "shadow"
        state_path = path_of(self.cfg, "GDW_STATE")
        state = load_state(state_path)
        book = state.setdefault(mode, {})  # shadow and apply keep separate books: a switch to apply alerts afresh
        failures, counts = [], {"read": 0, HIGH: 0, UNREADABLE: 0, "would": 0, "alerted": 0, "recovered": 0}
        bad = [h for h in hosts if not NAME_RE.fullmatch(h)]
        for h in bad:
            failures.append(f"host name refused: {h!r}")
        hosts = [h for h in hosts if NAME_RE.fullmatch(h)]
        for key in ("GDW_PROJECT", "GDW_ZONE"):
            if not NAME_RE.fullmatch(self.cfg[key]):
                failures.append(f"{key} refused: {self.cfg[key]!r}")
                hosts = []
        if hosts and not self.has_ssh_key():
            readings = {h: {"kind": UNREADABLE, "metrics": None, "reason": "no-ssh-key"} for h in hosts}
        else:
            readings = read_hosts(self.cfg, hosts, self.runner) if hosts else {}
        rounds = max(1, int(number(self.cfg, "GDW_UNREADABLE_ROUNDS")))
        every = max(1.0, number(self.cfg, "GDW_REALERT_MINUTES")) * 60
        unread = []
        for host in hosts:
            r = readings[host]
            if r["kind"] == UNREADABLE:
                known = " known" if host in self.cfg["GDW_KNOWN_UNREADABLE"].split() else ""
                unread.append(f"{host}({r.get('reason') or 'unknown'}{known})")
            try:
                self.one_host(host, r, book, now, every, rounds, counts, failures)
            except Exception as e:  # noqa: BLE001 - one bad entry never aborts the round; the host starts afresh
                book.pop(host, None)
                failures.append(f"{host}: round failed ({type(e).__name__}): state reset for this host")
        for host in list(book):
            if host not in hosts:
                del book[host]  # a host no longer watched is forgotten
        try:
            save_state(state_path, state)
        except OSError as e:
            failures.append(f"state write failed: {e}")
        self.log(f"{mode}: {len(hosts)} hosts, {counts['read']} read, {counts[HIGH]} high, {counts[UNREADABLE]} unreadable, "
                 f"{counts['would']} would-alert, {counts['alerted']} alerted, {counts['recovered']} recovered, "
                 f"{len(failures)} failures" + (f"; unreadable: {' '.join(unread)}" if unread else ""))
        for f in failures:
            self.log(f"ERROR {f}")
        return 1 if failures else 0


def valid_entry(e):
    """A stored host entry exactly as one_host writes it, or None (a hand edit, an older or damaged file)."""
    def num(v):
        return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
    if not isinstance(e, dict) or e.get("kind") not in KINDS or e.get("notice") not in NOTICES:
        return None
    todo = e.get("todo", [])
    if not isinstance(todo, list) or not all(isinstance(c, str) and c in CHANNELS for c in todo) \
            or (todo and e.get("notice") is None):
        return None
    if not (e.get("sent") is None or num(e.get("sent"))) or not (e.get("since") is None or num(e.get("since"))):
        return None
    fails = e.get("fails", 0)
    if not isinstance(fails, int) or isinstance(fails, bool) or fails < 0 or not isinstance(e.get("told", False), bool):
        return None
    return {"kind": e["kind"], "since": e.get("since"), "notice": e.get("notice"), "todo": list(todo),
            "sent": e.get("sent"), "told": e.get("told", False), "fails": fails}


def load_state(path):
    try:
        st = json.loads(path.read_text())
        return {k: v for k, v in st.items() if k in ("shadow", "apply") and isinstance(v, dict)} if isinstance(st, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(state, sort_keys=True) + "\n")
    os.replace(tmp, path)


def main(argv=None, runner=gcloud_runner, notifier=osascript_notify):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", default=None, help="KEY=VALUE policy (default: $GDW_CONFIG or ~/.cc-reaper/gce-disk-watch.conf)")
    ap.add_argument("--apply", action="store_true", help="write the inbox, events log and notification (default: GDW_APPLY)")
    args = ap.parse_args(argv)
    cfg = load_config(args.config)
    if args.apply:
        cfg["GDW_APPLY"] = "1"
    state_path = path_of(cfg, "GDW_STATE")
    state_path.parent.mkdir(parents=True, exist_ok=True)
    lock = open(state_path.with_name(state_path.name + ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("gce-disk-watch: another run holds the lock")
        return 0
    try:
        return Watch(cfg, runner, notifier).run(cfg["GDW_HOSTS"].split())
    finally:
        lock.close()


if __name__ == "__main__":
    sys.exit(main())
