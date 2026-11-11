#!/usr/bin/env python3
"""Retention judgements disk-janitor.sh hands to Python (stima-api#7881).

disk-janitor.sh owns the knobs, the modes, the log and the byte report; this file holds the
three rules whose predicate is too long for shell and needs an exact answer:

  projects   ~/.claude/projects/<encoded cwd> directories whose worktree no longer exists
  evidence   ~/.codex/helmway-evidence/<dated dir> and ~/handoffs/i<N>* directories whose
             issue is CLOSED and that nothing has written to for N days
  devprocs   long-running dev servers (next dev, proxy.mjs, ...) in a merged or idle worktree
             whose Claude session is gone

Every rule is fail-closed: an input it cannot read keeps the item and says why. Removal is by
explicit path, and a symlink is never followed: a root that is a symlink is refused, and an
entry that is a symlink is never a candidate.

Output is line-oriented. `projects` prints `CAND<TAB>name` / `KEEP<TAB>name<TAB>reason` /
`ERR<TAB>text` and removes nothing (the shell measures and removes). `evidence` and `devprocs`
act themselves, because their candidates need a fresh read (a gh result, a pid's start time)
right before the action; they print one line per item and a last `SUMMARY` line.
"""

import argparse
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time


def enc(name):
    """Claude Code's project-directory encoding of one path component or a whole path."""
    return re.sub(r"[^A-Za-z0-9]", "-", name)


def newest_within(path, seconds, now=None):
    """True when anything under `path` (itself included) was modified inside `seconds`.
    Walks without following symlinks; stops at the first recent file. A read error raises."""
    now = time.time() if now is None else now
    cutoff = now - seconds
    if os.lstat(path).st_mtime >= cutoff:
        return True
    errors = []
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False, onerror=errors.append):
        if errors:
            raise errors[0]
        for n in dirnames + filenames:
            if os.lstat(os.path.join(dirpath, n)).st_mtime >= cutoff:
                return True
    if errors:
        raise errors[0]
    return False


def disk_bytes(path):
    total = 0
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        for n in dirnames + filenames:
            try:
                st = os.lstat(os.path.join(dirpath, n))
            except OSError:
                continue
            total += st.st_blocks * 512
    try:
        total += os.lstat(path).st_blocks * 512
    except OSError:
        pass
    return total


def want_uid():
    raw = os.environ.get("CC_DJ_RET_UID", "")
    return int(raw) if raw.isdigit() else os.getuid()


def trusted_stat(st):
    """A root is trusted only when we own it and neither group nor others can write it: anyone who
    can write a directory can rename an entry in it for a symlink between a listing and a removal."""
    return st.st_uid == want_uid() and (st.st_mode & 0o022) == 0


def real_root(root):
    """The canonical root, or None when it is missing, not a directory, itself a symlink, or not
    owned by us / writable by group or others."""
    if os.path.islink(root) or not os.path.isdir(root):
        return None
    if not trusted_stat(os.lstat(root)):
        return None
    return os.path.realpath(root)


def safe_rmtree(root, path):
    """Remove the directory tree `path` under `root` without ever following a symlink: the root is
    opened O_NOFOLLOW and its ownership and mode are checked on the descriptor, every component
    down to the parent is opened O_NOFOLLOW|O_DIRECTORY relative to the one before, and the leaf
    is removed with shutil.rmtree(dir_fd=...). A path swapped for a symlink after it was listed
    fails the open. Raises OSError (with the reason) when it refuses."""
    if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
        raise OSError("shutil.rmtree is not symlink-attack safe on this platform; refusing to remove")
    root = root.rstrip("/")
    if not path.startswith(root + "/"):
        raise OSError("not inside the root")
    parts = path[len(root) + 1:].split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise OSError("path has an empty, . or .. component")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(root, flags)
    try:
        if not trusted_stat(os.fstat(fd)):
            raise OSError("root is not owned by us or is writable by group or others")
        for comp in parts[:-1]:
            nfd = os.open(comp, flags, dir_fd=fd)
            os.close(fd)
            fd = nfd
        leaf = parts[-1]
        st = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
        if stat.S_ISLNK(st.st_mode):
            raise OSError("is a symlink")
        if not stat.S_ISDIR(st.st_mode):
            raise OSError("is not a directory")
        shutil.rmtree(leaf, dir_fd=fd)
    finally:
        os.close(fd)


def cmd_remove(a):
    """Remove each directory in the NUL-separated list under the verified root, by explicit path,
    within the time budget. One line per path: REMOVED or REFUSED with the reason."""
    root = real_root(a.root)
    if root is None:
        print("ERR\troot %s is missing, a symlink, or not owned by us / writable by others" % a.root)
        return 0
    deadline = time.time() + a.seconds
    with open(a.list, "rb") as f:
        paths = [p.decode("utf-8", "surrogateescape") for p in f.read().split(b"\0") if p]
    for p in paths:
        if time.time() >= deadline:
            print("ERR\ttime budget spent; the rest waits for the next run")
            break
        try:
            safe_rmtree(root, p)
            print("REMOVED\t%s" % p)
        except OSError as e:
            print("REFUSED\t%s\t%s" % (p, e))
    return 0


def inside(root, path):
    return os.path.realpath(path).startswith(root.rstrip("/") + "/")


# ------------------------------------------------------------------ projects

def resolve_prefix(rem, node="/", budget=None):
    """Existing directories whose encoded absolute path is `rem` (a string starting with '-',
    the encoded root slash). Backtracks, because '-' stands for '/', '.', '-' and '_' alike."""
    budget = budget if budget is not None else [20000]
    if rem == "":
        return [node]
    if not rem.startswith("-"):
        return []
    rest = rem[1:]
    found = []
    budget[0] -= 1
    if budget[0] < 0:
        raise OSError("resolve budget spent")
    for entry in os.listdir(node):
        e = enc(entry)
        if rest == e or rest.startswith(e + "-"):
            child = os.path.join(node, entry)
            if os.path.isdir(child):
                found += resolve_prefix(rest[len(e):], child, budget)
    return found


def project_verdict(name, match, days, projects_root):
    """(verdict, reason): CAND when the worktree the encoded name points at is gone and the
    directory is quiet; KEEP otherwise, with the reason. Only names holding `match` are judged."""
    if match not in name:
        return "SKIP", "not a worktree-named project"
    pos = [m.start() for m in re.finditer(re.escape(match), name)]
    resolved_any = False
    for p in pos:
        # parent = everything up to and including the 'worktrees' word, leaf = what follows.
        parent_enc = name[:p + len(match.rstrip("-"))]
        leaf = name[p + len(match):]
        if leaf == "":
            continue
        try:
            parents = resolve_prefix(parent_enc)
        except OSError as e:
            return "KEEP", "cannot resolve the parent path (%s)" % e
        for parent in parents:
            if not os.path.basename(parent).endswith("worktrees"):
                continue
            resolved_any = True
            try:
                entries = os.listdir(parent)
            except OSError as e:
                return "KEEP", "cannot read %s (%s)" % (parent, e)
            for entry in entries:
                e = enc(entry)
                if leaf == e or leaf.startswith(e + "-"):
                    return "KEEP", "worktree %s exists" % os.path.join(parent, entry)
    if not resolved_any:
        return "KEEP", "no existing worktrees directory encodes the parent path"
    d = os.path.join(projects_root, name)
    try:
        if newest_within(d, days * 86400):
            return "KEEP", "a file under it changed within %s days" % days
    except OSError as e:
        return "KEEP", "cannot read it (%s)" % e
    return "CAND", "worktree gone, quiet for %s+ days" % days


def cmd_projects(a):
    root = real_root(a.root)
    if root is None:
        print("ERR\tprojects root %s is missing, not a directory, or a symlink" % a.root)
        return 0
    for name in sorted(os.listdir(root)):
        p = os.path.join(root, name)
        if os.path.islink(p) or not os.path.isdir(p):
            continue
        verdict, reason = project_verdict(name, a.match, a.days, root)
        if verdict == "SKIP":
            continue
        print("%s\t%s\t%s" % (verdict, name, reason))
    return 0


# ------------------------------------------------------------------ evidence

ENTRY_ISSUE = re.compile(r"^(?:i)?(\d{3,6})(?:[-_.]|$)")
NAME_ISSUE = re.compile(r"(?:^|[-_.])(?:i|issue-?)(\d{3,6})(?![0-9A-Za-z])")
MANIFEST_ISSUE = re.compile(r'stima-api#(\d{3,6})|"issue(?:_number)?"\s*:\s*(\d{3,6})')


def issues_of(kind, path):
    """Issue numbers a directory names: handoffs by `i<N>` in the name; helmway-evidence by
    `i<N>`/`issue-<N>` in the name, by top-level entries named `<N>-...`, or by a top-level
    manifest file naming `stima-api#N`. An empty set means the directory names no issue."""
    base = os.path.basename(path)
    found = set()
    m = re.match(r"^i(\d+)(?![0-9])", base) if kind == "handoffs" else None
    if m:
        found.add(int(m.group(1)))
    if kind == "helmway":
        found |= {int(x) for x in NAME_ISSUE.findall(base)}
        for entry in os.listdir(path):
            m = ENTRY_ISSUE.match(entry)
            if m:
                found.add(int(m.group(1)))
            if entry.lower().startswith("manifest") and os.path.isfile(os.path.join(path, entry)) \
                    and not os.path.islink(os.path.join(path, entry)):
                with open(os.path.join(path, entry), "rb") as f:
                    text = f.read(65536).decode("utf-8", "replace")
                for g in MANIFEST_ISSUE.findall(text):
                    found.add(int(g[0] or g[1]))
    return found


def closed_issues(repo, gh, limit):
    """One batched read for the whole run: the numbers of every closed issue, or None."""
    try:
        out = subprocess.run(
            [gh, "issue", "list", "--repo", repo, "--state", "closed", "--json", "number",
             "--limit", str(limit), "--jq", ".[].number"],
            capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    nums = set()
    for line in out.stdout.split():
        if line.isdigit():
            nums.add(int(line))
    return nums


def cmd_evidence(a):
    apply = a.mode == "apply"
    roots = []
    for spec in a.root:
        kind, _, path = spec.partition(":")
        if kind not in ("helmway", "handoffs"):
            print("ERR\tunknown root kind %s" % kind)
            continue
        r = real_root(path)
        if r is None:
            print("ERR\tevidence root %s is missing, not a directory, or a symlink; skipped" % path)
            continue
        roots.append((kind, r))
    # First pass: the directories old enough to matter, so gh is asked only when needed.
    old = []
    for kind, root in roots:
        try:
            names = sorted(os.listdir(root))
        except OSError as e:
            print("ERR\tcannot list %s (%s)" % (root, e))
            continue
        for n in names:
            p = os.path.join(root, n)
            if os.path.islink(p) or not os.path.isdir(p):
                continue
            if kind == "handoffs" and not re.match(r"^i\d+", n):
                continue
            try:
                if newest_within(p, a.days * 86400):
                    continue
            except OSError as e:
                print("KEEP\t%s\t0\tcannot read it (%s)" % (p, e))
                continue
            try:
                nums = issues_of(kind, p)
            except OSError as e:
                print("KEEP\t%s\t0\tcannot read it (%s)" % (p, e))
                continue
            old.append((kind, root, p, nums))
    closed = None
    if any(nums for _, _, _, nums in old):
        closed = closed_issues(a.repo, a.gh, a.limit)
        if closed is None:
            print("ERR\tgh issue list failed; no directory is judged closed this run")
    cand = total = removed = 0
    for kind, root, p, nums in old:
        if not nums:
            print("KEEP\t%s\t0\tnames no issue" % p)
            continue
        if closed is None:
            print("KEEP\t%s\t0\tissue state unknown (%s)" % (p, ",".join("#%d" % n for n in sorted(nums))))
            continue
        still = sorted(n for n in nums if n not in closed)
        if still:
            print("KEEP\t%s\t0\tissue not closed (%s)" % (p, ",".join("#%d" % n for n in still)))
            continue
        b = disk_bytes(p)
        cand += 1
        total += b
        label = ",".join("#%d" % n for n in sorted(nums))
        if not apply:
            print("WOULD-REMOVE\t%s\t%d\tclosed %s, quiet for %s+ days" % (p, b, label, a.days))
            continue
        # A fresh look right before removing: the directory may have been written to since.
        try:
            if newest_within(p, a.days * 86400) or not inside(root, p) or os.path.islink(p):
                print("KEEP\t%s\t0\tchanged since it was listed" % p)
                continue
            safe_rmtree(root, p)
            removed += 1
            print("REMOVED\t%s\t%d\tclosed %s, quiet for %s+ days" % (p, b, label, a.days))
        except OSError as e:
            print("ERR\tremoving %s failed (%s)" % (p, e))
    print("SUMMARY\tcandidates=%d bytes=%d removed=%d" % (cand, total, removed))
    return 0


# ------------------------------------------------------------------ devprocs

def is_agent(cmd):
    """A claude or codex process, judged by its executable (or the script node runs), never by
    a substring of its arguments."""
    t = cmd.split()
    if not t:
        return False
    if os.path.basename(t[0]) in ("node", "bun") and len(t) > 1:
        t = t[1:]
    return os.path.basename(t[0]) in ("claude", "codex")


UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
IDLE_SKIP = {"node_modules", ".next", ".git", ".turbo", ".cache"}


def parse_etime(s):
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = [int(x) for x in s.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return days * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


def process_table():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,lstart=,etime=,command="],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0 or not out.stdout.strip():
        raise OSError("ps cannot list processes")
    rows = {}
    for line in out.stdout.splitlines():
        t = line.split(None, 8)
        if len(t) < 9 or not t[0].isdigit() or not t[1].isdigit():
            continue
        try:
            age = parse_etime(t[7])
        except ValueError:
            continue
        rows[int(t[0])] = {"pid": int(t[0]), "ppid": int(t[1]), "start": " ".join(t[2:7]),
                           "age": age, "cmd": t[8]}
    return rows


def lstart_of(pid):
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=20)
    return " ".join(out.stdout.split()) if out.returncode == 0 else None


def cwd_of(pid):
    try:
        out = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn", "-p", str(pid)],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.stdout.splitlines():
        if line.startswith("n/"):
            return line[1:]
    return None


def git(cwd, *args):
    out = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True, timeout=60)
    return out.returncode, out.stdout.strip()


def worktree_state(cwd, idle_days, base):
    """(toplevel or None, 'merged'/'idle'/'active'/reason). Linked worktrees only."""
    rc, top = git(cwd, "rev-parse", "--show-toplevel")
    if rc != 0 or not top:
        return None, "cwd is not in a git worktree"
    rc1, gd = git(top, "rev-parse", "--path-format=absolute", "--git-dir")
    rc2, cd = git(top, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if rc1 != 0 or rc2 != 0 or os.path.realpath(gd) == os.path.realpath(cd):
        return None, "cwd is a primary checkout or unreadable"
    rc, _ = git(top, "merge-base", "--is-ancestor", "HEAD", base)
    if rc == 0:
        return top, "merged"
    try:
        # Only the worktree's own files count: a running dev server writes its own cache.
        newest = 0.0
        cutoff = time.time() - idle_days * 86400
        recent = False
        for dirpath, dirnames, filenames in os.walk(top, followlinks=False):
            dirnames[:] = [d for d in dirnames if d not in IDLE_SKIP]
            for n in filenames:
                try:
                    m = os.lstat(os.path.join(dirpath, n)).st_mtime
                except OSError:
                    continue
                newest = max(newest, m)
                if m >= cutoff:
                    recent = True
                    break
            if recent:
                break
    except OSError as e:
        return top, "unreadable (%s)" % e
    return top, "active" if recent else "idle"


def live_sessions(sessions_dir):
    """(records, ids, error). records: cwd of every session record whose pid is alive."""
    cwds, ids = [], set()
    if not os.path.isdir(sessions_dir):
        return None, None, "session directory %s unreadable" % sessions_dir
    try:
        names = os.listdir(sessions_dir)
    except OSError as e:
        return None, None, "session directory unreadable (%s)" % e
    for n in names:
        if not re.match(r"^\d+\.json$", n):
            continue
        try:
            with open(os.path.join(sessions_dir, n)) as f:
                rec = json.load(f)
            pid = int(rec["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            return None, None, "session record %s unreadable" % n
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            pass
        if rec.get("cwd"):
            cwds.append(os.path.realpath(rec["cwd"]))
        if rec.get("sessionId"):
            ids.add(rec["sessionId"])
    return cwds, ids, None


def owner_verdict(row, rows, top, cwds, ids, serr):
    """('dead'|'alive:<why>'|'unknown:<why>')."""
    if serr:
        return "unknown:" + serr
    seen, cur = set(), row["ppid"]
    while cur > 1 and cur not in seen:
        seen.add(cur)
        p = rows.get(cur)
        if p is None:
            return "unknown:ancestor %d not in the process table" % cur
        if is_agent(p["cmd"]):
            return "alive:ancestor pid %d is a claude/codex process" % cur
        cur = p["ppid"]
    real = os.path.realpath(top)
    for c in cwds:
        if c == real or c.startswith(real + "/"):
            return "alive:a live session works in %s" % real
    hit = [u for u in UUID.findall(row["cmd"]) if u in ids]
    if hit:
        return "alive:its command line names live session %s" % hit[0]
    return "dead"


# Processes no cc-reaper path signals, nor any process descended from one: CC_NEVER_KILL_PIDS,
# separated by spaces or commas; unset, the host's default list applies; empty protects no pid.
# The same rule and default as dev-server-reaper.py and _cc_reaper_never_kill in the shell scripts.
NEVER_KILL_DEFAULT = "70987 4565"


def never_kill(pid, rows):
    raw = os.environ.get("CC_NEVER_KILL_PIDS")
    raw = NEVER_KILL_DEFAULT if raw is None else raw
    keep = {int(t) for t in re.split(r"[^0-9]+", raw) if t}
    if not keep:
        return False
    p = pid
    for _ in range(512):
        if p in keep:
            return True
        if p <= 1 or p not in rows:
            return False
        p = rows[p]["ppid"]
    return False


def cmd_devprocs(a):
    apply = a.mode == "apply"
    pat = re.compile(a.match)
    try:
        rows = process_table()
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        print("ERR\tprocess table unreadable (%s); nothing judged" % e)
        print("SUMMARY\tcandidates=0 stopped=0")
        return 0
    cwds, ids, serr = live_sessions(a.sessions_dir)
    me = {os.getpid()}
    cur = os.getppid()
    while cur > 1 and cur in rows and cur not in me:
        me.add(cur)
        cur = rows[cur]["ppid"]
    n = stopped = 0
    stop = []
    for pid in sorted(rows):
        row = rows[pid]
        if pid in me or not pat.search(row["cmd"][:300]):
            continue
        head = row["cmd"][:90]
        if never_kill(pid, rows):
            print("KEEP\t%d\tage=%.1fd\t%s\ton CC_NEVER_KILL_PIDS or descended from it" % (pid, row["age"] / 86400, head))
            continue
        if row["age"] < a.min_age_hours * 3600:
            print("KEEP\t%d\tage=%.1fd\t%s\tyounger than %sh" % (pid, row["age"] / 86400, head, a.min_age_hours))
            continue
        cwd = cwd_of(pid)
        if not cwd:
            print("KEEP\t%d\tage=%.1fd\t%s\tcwd unreadable" % (pid, row["age"] / 86400, head))
            continue
        top, state = worktree_state(cwd, a.idle_days, a.base)
        if top is None or state not in ("merged", "idle"):
            print("KEEP\t%d\tage=%.1fd\t%s\tcwd=%s worktree=%s" % (pid, row["age"] / 86400, head, cwd, state))
            continue
        owner = owner_verdict(row, rows, top, cwds, ids, serr)
        line = "pid=%d age=%.1fd cwd=%s worktree=%s owner=%s cmd=%s" % (
            pid, row["age"] / 86400, cwd, state, owner, head)
        if owner != "dead":
            print("KEEP\t%d\tage=%.1fd\t%s\t%s" % (pid, row["age"] / 86400, head, line))
            continue
        n += 1
        if not apply:
            print("WOULD-STOP\t%d\t%s" % (pid, line))
            continue
        stop.append((pid, row["start"], line))
    for pid, start, line in stop:
        if lstart_of(pid) != start:
            print("KEEP\t%d\tstart time changed since the scan\t%s" % (pid, line))
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            print("STOPPED\t%d\t%s" % (pid, line))
            stopped += 1
            continue
        except OSError as e:
            print("ERR\tSIGTERM %d failed (%s)" % (pid, e))
            continue
        deadline = time.time() + a.grace
        while time.time() < deadline and lstart_of(pid) == start:
            time.sleep(0.2)
        if lstart_of(pid) == start:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        print("STOPPED\t%d\t%s" % (pid, line))
        stopped += 1
    print("SUMMARY\tcandidates=%d stopped=%d" % (n, stopped))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("projects")
    p.add_argument("--root", required=True)
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--match", default="-worktrees-")
    p.set_defaults(fn=cmd_projects)
    r = sub.add_parser("remove")
    r.add_argument("--root", required=True)
    r.add_argument("--list", required=True)
    r.add_argument("--seconds", type=float, default=900)
    r.set_defaults(fn=cmd_remove)
    e = sub.add_parser("evidence")
    e.add_argument("--mode", choices=["shadow", "apply"], default="shadow")
    e.add_argument("--root", action="append", default=[], help="helmway:<dir> or handoffs:<dir>")
    e.add_argument("--days", type=int, default=7)
    e.add_argument("--repo", default="theQuert/stima-api")
    e.add_argument("--gh", default="gh")
    e.add_argument("--limit", type=int, default=20000)
    e.set_defaults(fn=cmd_evidence)
    d = sub.add_parser("devprocs")
    d.add_argument("--mode", choices=["shadow", "apply"], default="shadow")
    d.add_argument("--min-age-hours", type=float, default=168)
    d.add_argument("--idle-days", type=float, default=7)
    d.add_argument("--grace", type=float, default=10)
    d.add_argument("--base", default="origin/main")
    d.add_argument("--sessions-dir", default=os.path.expanduser("~/.claude/sessions"))
    d.add_argument("--match", default=r"(?:^|[\s/])(?:next dev|next-server|\S*proxy\.mjs|vite(?: |$)|react-scripts start|webpack serve)")
    d.set_defaults(fn=cmd_devprocs)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
