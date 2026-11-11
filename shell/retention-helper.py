#!/usr/bin/env python3
"""Retention judgements disk-janitor.sh hands to Python (stima-api#7881).

disk-janitor.sh owns the knobs, the modes, the log and the byte report; this file holds the
three rules whose predicate is too long for shell and needs an exact answer:

  projects   ~/.claude/projects/<encoded cwd> directories whose worktree no longer exists
  evidence   ~/.codex/helmway-evidence/<dated dir> and ~/handoffs/i<N>* directories whose
             issue is CLOSED (handoffs also quiet for N days), plus ~/.codex/worktrees entries
             that are clean with every commit on a remote and ~/.codex/archived_sessions entries,
             both only when no process holds anything in them
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
    st = os.lstat(path)
    if st.st_mtime >= cutoff:
        return True
    if not stat.S_ISDIR(st.st_mode):
        return False        # a file or a symlink: only its own mtime counts
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


def _open_parent(root, path):
    """(fd, leaf): a descriptor on the parent directory of `path` and the leaf's name, reached
    without following a symlink. The caller closes the descriptor. Raises OSError when it refuses."""
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
    except BaseException:
        os.close(fd)
        raise
    return fd, parts[-1]


def safe_rmtree(root, path):
    """Remove the directory tree `path` under `root` without ever following a symlink: the root is
    opened O_NOFOLLOW and its ownership and mode are checked on the descriptor, every component
    down to the parent is opened O_NOFOLLOW|O_DIRECTORY relative to the one before, and the leaf
    is removed with shutil.rmtree(dir_fd=...). A path swapped for a symlink after it was listed
    fails the open. Raises OSError (with the reason) when it refuses."""
    fd, leaf = _open_parent(root, path)
    try:
        st = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
        if stat.S_ISLNK(st.st_mode):
            raise OSError("is a symlink")
        if not stat.S_ISDIR(st.st_mode):
            raise OSError("is not a directory")
        shutil.rmtree(leaf, dir_fd=fd)
    finally:
        os.close(fd)


def safe_unlink(root, path):
    """The same walk for one regular file: never a symlink, never a directory."""
    fd, leaf = _open_parent(root, path)
    try:
        if not stat.S_ISREG(os.stat(leaf, dir_fd=fd, follow_symlinks=False).st_mode):
            raise OSError("is not a regular file")
        os.unlink(leaf, dir_fd=fd)
    finally:
        os.close(fd)


def cmd_remove(a):
    """Remove each directory tree (--kind d) or regular file (--kind f) in the NUL-separated list under
    the verified root, by explicit path, within the time budget. One line per path: REMOVED or REFUSED with the reason."""
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
            (safe_unlink if a.kind == "f" else safe_rmtree)(root, p)
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

# An issue is named `i<N>`, `issue-<N>`, `#<N>` or, for an entry inside an evidence directory, a bare
# `<N>-slug` (the real layout is `<date>-<kind>/<N>-<slug>/`). A number that begins a date, a year
# followed by a separator and a month (`2026-11`, `2026_11`, `2026.11`, also after i/issue-/#), is not one.
_NOT_DATE = r"(?!(?:19|20)\d{2}[-_.](?:0[1-9]|1[0-2])(?!\d))"
_NUM = _NOT_DATE + r"(\d{3,6})(?![0-9A-Za-z])"
ENTRY_ISSUE = re.compile(r"^(?:i|issue-?|#)?" + _NUM)
NAME_ISSUE = re.compile(r"(?:^|[-_.])(?:i|issue-?|#)" + _NUM)
MANIFEST_ISSUE = re.compile(r'stima-api#(\d{3,6})|"issue(?:_number)?"\s*:\s*(\d{3,6})')
SQLITE_NAME = re.compile(r"\.sqlite3?(?:-wal|-shm|-journal)?$", re.I)
ROOT_KINDS = ("helmway", "handoffs", "worktrees", "archived")


def issues_of(kind, path):
    """Issue numbers a directory names: handoffs by `i<N>` in the name; helmway-evidence by
    `i<N>`/`issue-<N>`/`#<N>` in the name, by top-level entries named `<N>-slug` or that way, or by a top-level
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


def held_paths(prefixes):
    """Every open file and working directory of every process that lies under one of `prefixes`,
    from ONE system-wide lsof; None when lsof cannot report (then nothing is judged unheld)."""
    exe = os.environ.get("CC_DJ_RET_LSOF", "lsof")
    try:
        out = subprocess.run([exe, "-nP", "-b", "-w", "-Fn"], capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.SubprocessError):
        return None
    names = [ln[1:] for ln in out.stdout.splitlines() if ln.startswith("n/")]
    if not names:
        return None
    pre = [p.rstrip("/") + "/" for p in prefixes]
    return [n for n in names if any((n + "/").startswith(p) for p in pre)]


def is_held(path, held):
    return any(h == path or h.startswith(path + "/") for h in held)


def git_ro(cwd, *args):
    """git that cannot run a repository's configured commands or write its index."""
    cmd = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", cwd] + list(args)
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=60,
                         env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    return out.returncode, out.stdout.strip()


def codex_worktree_verdict(top):
    """(True, reason) when every git worktree under `top` (itself, or one level down: codex keeps
    <id>/<repo>) is clean and has no commit outside the remotes; (False, why) otherwise."""
    if os.path.lexists(os.path.join(top, ".git")):
        found = [top]
        for n in sorted(os.listdir(top)):       # a repository nested in a child, ignored by the outer one
            d = os.path.join(top, n)
            if not os.path.islink(d) and os.path.isdir(d) and os.path.lexists(os.path.join(d, ".git")):
                found.append(d)
    else:
        found = []
        for n in sorted(os.listdir(top)):
            d = os.path.join(top, n)
            if os.path.islink(d) or not os.path.isdir(d) or not os.path.lexists(os.path.join(d, ".git")):
                return False, "%s is not a git worktree" % d
            found.append(d)
    if not found:
        return False, "holds no git worktree"
    for d in found:
        g = os.path.join(d, ".git")
        if os.path.islink(g):
            return False, ".git in %s is a symlink" % d
        rc, out = git_ro(d, "status", "--porcelain", "-unormal")
        if rc != 0:
            return False, "git status failed in %s" % d
        if out:
            return False, "uncommitted changes in %s" % d
        if os.path.isdir(g):
            # A full clone owns its branches and its stash: every ref must be on a remote.
            rc, out = git_ro(d, "rev-list", "--count", "--all", "--not", "--remotes")
            rc2, stash = git_ro(d, "stash", "list")
            if rc2 != 0 or stash:
                return False, "%s has a stash or it cannot be read" % d
        else:
            rc, out = git_ro(d, "rev-list", "--count", "HEAD", "--not", "--remotes")
        if rc != 0 or not out.isdigit():
            return False, "cannot count the commits outside the remotes in %s" % d
        if int(out) != 0:
            return False, "%s commits in %s are on no remote" % (out, d)
    return True, "clean, every commit is on a remote"


def codex_archived_verdict(p):
    """An archived session goes unless it is, or holds, an sqlite database."""
    if SQLITE_NAME.search(os.path.basename(p)):
        return False, "is an sqlite database"
    if os.path.isdir(p):
        for _, dn, fn in os.walk(p, followlinks=False):
            if any(SQLITE_NAME.search(n) for n in dn + fn):
                return False, "holds an sqlite database"
    return True, "archived session"


def cmd_evidence(a):
    """Evidence and codex leftovers, one rule: handoffs `i<N>` and helmway-evidence directories whose
    issue is closed (handoffs also quiet for --days, helmway-evidence for --codex-days, 0 = no age),
    plus ~/.codex/worktrees entries that are clean with every commit on a remote, and
    ~/.codex/archived_sessions entries (never an sqlite file); the last two only when no process
    holds anything in them. Prints one line per directory and a SUMMARY."""
    apply = a.mode == "apply"
    roots = []
    for spec in a.root:
        kind, _, path = spec.partition(":")
        if kind not in ROOT_KINDS:
            print("ERR\tunknown root kind %s" % kind)
            continue
        if not os.path.lexists(path):
            continue                      # nothing there, nothing to clean
        r = real_root(path)
        if r is None:
            print("ERR\tevidence root %s is not a directory, a symlink, or not owned by us / writable by others; skipped" % path)
            continue
        roots.append((kind, r))

    def days_of(kind):
        return a.codex_days if kind in ("helmway", "worktrees", "archived") else a.days

    def young(kind, p):
        """Why an entry is too recent to go (its newest mtime inside is within the age), or None."""
        ds = days_of(kind)
        if ds > 0 and newest_within(p, ds * 86400):
            return "newest file inside is younger than %s days" % ds
        return None

    def aged(kind, why):
        ds = days_of(kind)
        return why + (", quiet for %s+ days" % ds if ds > 0 else "")

    # First pass: what could matter, so gh and lsof are asked only when needed.
    old = []        # (kind, root, p, issue numbers)
    units = []      # (kind, root, p, reason) codex worktrees / archived sessions that pass their own test
    for kind, root in roots:
        try:
            names = sorted(os.listdir(root))
        except OSError as e:
            print("ERR\tcannot list %s (%s)" % (root, e))
            continue
        for n in names:
            p = os.path.join(root, n)
            if os.path.islink(p):
                continue
            if kind == "archived":
                if not (os.path.isdir(p) or os.path.isfile(p)):
                    continue
                try:
                    ok, why = codex_archived_verdict(p)
                    young_why = young(kind, p) if ok else None
                except OSError as e:
                    ok, why, young_why = False, "cannot judge it (%s)" % e, None
                if young_why:
                    ok, why = False, young_why
                (units.append((kind, root, p, aged(kind, why))) if ok else print("KEEP\t%s\t0\t%s" % (p, why)))
                continue
            if not os.path.isdir(p):
                continue
            if kind == "worktrees":
                try:
                    young_why = young(kind, p)
                    ok, why = (False, young_why) if young_why else codex_worktree_verdict(p)
                except (OSError, subprocess.SubprocessError) as e:
                    ok, why = False, "cannot judge it (%s)" % e
                (units.append((kind, root, p, aged(kind, why))) if ok else print("KEEP\t%s\t0\t%s" % (p, why)))
                continue
            if kind == "handoffs" and not re.match(r"^i\d+", n):
                continue
            try:
                if days_of(kind) > 0 and newest_within(p, days_of(kind) * 86400):
                    continue
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
    cands = []      # (kind, root, p, label)
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
        ds = days_of(kind)
        cands.append((kind, root, p, "closed %s%s" % (",".join("#%d" % n for n in sorted(nums)),
                                                   ", quiet for %s+ days" % ds if ds > 0 else "")))
    if units:
        held = held_paths([r for _, r, _, _ in units])      # taken after the slow git work
        for kind, root, p, why in units:
            if held is None:
                print("KEEP\t%s\t0\tlsof cannot report open files; kept" % p)
            elif is_held(p, held):
                print("KEEP\t%s\t0\theld open by a process" % p)
            else:
                cands.append((kind, root, p, why))
    cand = total = removed = 0
    for kind, root, p, label in cands:
        b = disk_bytes(p)
        cand += 1
        total += b
        if not apply:
            print("WOULD-REMOVE\t%s\t%d\t%s" % (p, b, label))
            continue
        # A fresh look right before removing: the entry may have changed since it was listed.
        try:
            ds = days_of(kind)
            changed = False
            if kind == "worktrees":
                changed = not codex_worktree_verdict(p)[0]
            elif kind == "archived":
                changed = not codex_archived_verdict(p)[0]
            changed = changed or (ds > 0 and newest_within(p, ds * 86400))
            if changed or not inside(root, p) or os.path.islink(p):
                print("KEEP\t%s\t0\tchanged since it was listed" % p)
                continue
            if os.path.isdir(p):
                safe_rmtree(root, p)
            else:
                safe_unlink(root, p)
            removed += 1
            print("REMOVED\t%s\t%d\t%s" % (p, b, label))
        except (OSError, subprocess.SubprocessError) as e:
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
    r.add_argument("--kind", choices=["d", "f"], default="d", help="d: directory trees, f: regular files")
    r.set_defaults(fn=cmd_remove)
    e = sub.add_parser("evidence")
    e.add_argument("--mode", choices=["shadow", "apply"], default="shadow")
    e.add_argument("--root", action="append", default=[], help="helmway|handoffs|worktrees|archived:<dir>")
    e.add_argument("--days", type=int, default=7)
    e.add_argument("--codex-days", type=int, default=0)
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
