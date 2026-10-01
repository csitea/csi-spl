#!/usr/bin/env python3
"""agent-identity.py - the one identity map of the box's agents.

One record per agent, $SPOOL_ROOT/agents/<ID>.json, and an index.json whose
hash changes exactly when a record does. Every value comes from the agent's
PROCESS - its environment (SPOOL_AGENT_ID), its own session file or resume
argument, its cwd, its place in a tmux pane's process tree - never from a
window name or a registry row: those are what drifted (2026-10-01: windows
shifted names after every spawn; a reboot resumed seven neighbours' sessions).

Usage: agent-identity.py --dir DIR [--proc-root ROOT] CMD [ARGS]
  facts           the live facts, one JSON object per agent process
  record [--apply] merge the live facts into the records; without --apply only
                  print what would change (PLAN), with it write (WRITE) and
                  refresh index.json. Idempotent: an unchanged record is not
                  rewritten and keeps its updated_at.
  check           the map vs the live box as one table; exit 1 on any drift
  reconcile [--tag T] [--apply]
                  record (written with --apply), then print one
                  RENAME<TAB>pane<TAB>old<TAB>new per agent window whose name
                  is not the one derived from its record; the caller renames
  set-title ID T  set ID's title (what riname does); reconcile then renames
  hash            the hash of the records as they are on disk
  alive ID        print the pid and exit 0 when ID's record names a live process
                  that still IS that agent: the pid exists with the recorded start
                  time, is that agent's CLI (argv, else comm), and carries
                  SPOOL_AGENT_ID=ID. A reader that cannot wait for the next record
                  (the dispatch lease) falls back to its own /proc walk.

stdin (facts, record, check): the tmux panes, one per line,
  session<TAB>window_id<TAB>pane_id<TAB>pane_pid<TAB>window_name

A record outlives its process: alive turns false and session_id / worktree
stay, so a restore can start that session again under its own id.
"""
import argparse
import hashlib
import json
import os
import pwd
import re
import sys
import tempfile
import time

KINDS = ("claude", "grok", "agy", "qwen")
LOADERS = ("node", "nodejs", "bun", "deno")
ID_RE = re.compile(r"^(CLE|GRK|AGY|QWN)-[0-9]+$")
NAME_ID_RE = re.compile(r"(?<![A-Za-z0-9])((?:CLE|GRK|AGY|QWN)-[0-9]+)(?![0-9])")
BADGES = (">", "?", "!")
VOLATILE = ("updated_at",)          # never part of the hash, never a reason to rewrite
FIELDS = ("v", "id", "kind", "session_id", "session_name", "worktree", "title", "model", "permission_mode",
          "user", "pid", "proc_start", "tmux_session", "window_id", "pane_id", "alive", "updated_at")


class Proc:
    def __init__(self, root):
        self.root = root

    def read(self, pid, name, binary=False):
        try:
            with open(os.path.join(self.root, str(pid), name), "rb" if binary else "r") as fh:
                return fh.read()
        except OSError:
            return b"" if binary else ""

    def argv(self, pid):
        return [a.decode("utf-8", "replace") for a in self.read(pid, "cmdline", True).split(b"\0") if a]

    def environ(self, pid):
        env = {}
        for kv in self.read(pid, "environ", True).split(b"\0"):
            k, sep, v = kv.decode("utf-8", "replace").partition("=")
            if sep:
                env[k] = v
        return env

    def stat(self, pid):
        """(ppid, start) from /proc/<pid>/stat, parsed past the comm."""
        s = self.read(pid, "stat")
        try:
            rest = s[s.rindex(")") + 2:].split()
            return rest[1], rest[19]
        except (ValueError, IndexError):
            return "", ""

    def uid(self, pid):
        for line in self.read(pid, "status").splitlines():
            if line.startswith("Uid:"):
                try:
                    return int(line.split()[1])
                except (IndexError, ValueError):
                    return None
        return None

    def cwd(self, pid):
        try:
            return os.readlink(os.path.join(self.root, str(pid), "cwd"))
        except OSError:
            return ""

    def pids(self):
        try:
            return sorted((d for d in os.listdir(self.root) if d.isdigit()), key=int)
        except OSError:
            return []


def kind_of(argv):
    if not argv:
        return ""
    base = os.path.basename(argv[0])
    if base in LOADERS or base.startswith("ld-linux"):
        base = os.path.basename(argv[1]) if len(argv) > 1 else ""
    return base if base in KINDS else ""


def flag(argv, name):
    for i, a in enumerate(argv[:-1]):
        if a == name:
            return argv[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    if argv and argv[-1].startswith(name + "="):
        return argv[-1].split("=", 1)[1]
    return ""


def user_of(uid):
    try:
        return pwd.getpwuid(uid).pw_name if uid is not None else ""
    except KeyError:
        return str(uid)


def homes(proc, pid, env):
    out = []
    if env.get("HOME"):
        out.append(env["HOME"])
    uid = proc.uid(pid)
    if uid is not None:
        try:
            h = pwd.getpwuid(uid).pw_dir
            if h not in out:
                out.append(h)
        except KeyError:
            pass
    return out


def claude_session(proc, pid, env, start):
    """(session_id, cwd, name) from the process's own ~/.claude/sessions/<pid>.json,
    refusing a file a recycled pid inherited (procStart must match). name is
    the session's title (--name, /rename)."""
    for h in homes(proc, pid, env):
        try:
            with open(os.path.join(h, ".claude", "sessions", "%s.json" % pid)) as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        want = str(d.get("procStart", "") or "")
        if want and want != start:
            continue
        if d.get("sessionId"):
            return str(d["sessionId"]), str(d.get("cwd", "") or ""), str(d.get("name", "") or "")
    return "", "", ""


def strip_name(name):
    """'tag: CLE-07 > some title' -> ('CLE-07', 'some title'); no id -> ('', name)."""
    n = name
    m = re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*: (.*)$", n)   # the box tag (display only)
    if m:
        n = m.group(1)
    if n[:2] in ("> ", "? ", "! "):                          # a badge an older writer put first
        n = n[2:]
    m = re.match(r"^((?:CLE|GRK|AGY|QWN)-[0-9]+)(?: (.*))?$", n)
    if not m:
        return "", name
    rest = m.group(2) or ""
    if rest in BADGES:
        rest = ""
    elif rest[:2] in ("> ", "? ", "! "):
        rest = rest[2:]
    return m.group(1), rest.strip()


def read_panes(stream):
    panes = []
    for line in stream:
        f = line.rstrip("\n").split("\t")
        if len(f) >= 5 and f[3].isdigit():
            panes.append({"session": f[0], "window_id": f[1], "pane_id": f[2], "pane_pid": f[3], "name": f[4]})
    return panes


def facts(proc, panes):
    """One dict per live agent process whose id the process itself carries.
    Returns (facts, skipped) - skipped names each agent process left out and why."""
    by_pid = {p["pane_pid"]: p for p in panes}
    agents, parents = {}, {}
    for pid in proc.pids():
        k = kind_of(proc.argv(pid))
        ppid, start = proc.stat(pid)
        parents[pid] = ppid
        if k:
            agents[pid] = (k, start)
    out, skipped = [], []
    for pid, (kind, start) in agents.items():
        # Only the outermost agent process of a tree (a CLI may run helpers
        # under the same argv[0]).
        p, inner = parents.get(pid, ""), False
        seen = set()
        while p and p not in seen and p != "0":
            seen.add(p)
            if p in agents:
                inner = True
                break
            p = parents.get(p, "")
        if inner:
            continue
        argv, env = proc.argv(pid), proc.environ(pid)
        aid = env.get("SPOOL_AGENT_ID", "") or env.get("MCP_BOT_AGENT_ID", "")
        if not ID_RE.match(aid):
            skipped.append((pid, kind, "its environment carries no agent id (unreadable, or not a fleet agent)"))
            continue
        sid, cwd, sname = "", "", ""
        if kind == "claude":
            sid, cwd, sname = claude_session(proc, pid, env, start)
        if not sid:
            sid = flag(argv, "--session-id") or flag(argv, "--resume") or flag(argv, "--conversation")
        cwd = cwd or proc.cwd(pid)
        pane, p, seen = None, pid, set()
        while p and p not in seen and p != "0":
            seen.add(p)
            if p in by_pid:
                pane = by_pid[p]
                break
            p = parents.get(p, "")
        perm = flag(argv, "--permission-mode") or ("bypassPermissions" if "--dangerously-skip-permissions" in argv else "")
        out.append({
            "id": aid, "kind": kind, "session_id": sid or None, "worktree": cwd or None,
            "model": flag(argv, "--model") or None, "permission_mode": perm or None,
            "user": user_of(proc.uid(pid)), "pid": int(pid), "proc_start": start,
            "tmux_session": pane["session"] if pane else None,
            "window_id": pane["window_id"] if pane else None,
            "pane_id": pane["pane_id"] if pane else None,
            "window_name": pane["name"] if pane else None,
            "session_name": sname or None,
        })
    return out, skipped


def load(d):
    recs = {}
    try:
        names = os.listdir(d)
    except OSError:
        return recs
    for n in names:
        if not n.endswith(".json") or n == "index.json":
            continue
        try:
            with open(os.path.join(d, n)) as fh:
                r = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(r, dict) and ID_RE.match(str(r.get("id", ""))) and n == r["id"] + ".json":
            recs[r["id"]] = r
    return recs


def canon(r):
    return json.dumps({k: r.get(k) for k in FIELDS if k not in VOLATILE}, sort_keys=True, separators=(",", ":"))


def map_hash(recs):
    h = hashlib.sha256()
    for i in sorted(recs):
        h.update(canon(recs[i]).encode())
        h.update(b"\n")
    return "sha256:" + h.hexdigest()


def write_json(path, obj):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(obj, fh, indent=1, sort_keys=True)
            fh.write("\n")
        os.chmod(tmp, 0o664)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def now_utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def merge(recs, live):
    """The records as they should be: (new_records, changes, conflicts).
    changes: [(id, [changed fields])]; conflicts: {id: [pids]} - an id two live
    processes carry is never recorded (which one is the agent is unknowable)."""
    per_id = {}
    for f in live:
        per_id.setdefault(f["id"], []).append(f)
    conflicts = {i: sorted(x["pid"] for x in fs) for i, fs in per_id.items() if len(fs) > 1}
    new, changes = {}, []
    for i in sorted(set(recs) | set(per_id)):
        old = recs.get(i)
        if i in conflicts:
            if old:
                new[i] = old
            continue
        if i in per_id:
            f = per_id[i][0]
            r = dict(old or {})
            # The title is what a human named the work: the session's own
            # name (/rename, --name) with any tag and id stripped - the id in
            # it is ignored, the record's id comes from the environment. Else
            # the record's title; else, once, the window name when it carries
            # this same id.
            title = (old or {}).get("title")
            # ... only when that session name CHANGED since the last record:
            # a title set by riname (set-title) is not undone on every pass by
            # a session name nobody touched since.
            if f.get("session_name") and f["session_name"] != (old or {}).get("session_name"):
                nid, t = strip_name(f["session_name"])
                t = t if nid else re.sub(r"^[A-Za-z0-9][A-Za-z0-9._-]*: ", "", f["session_name"]).strip()
                if t:
                    title = t
            if title is None:
                nid, t = strip_name(f.get("window_name") or "")
                title = t if nid == i else ""
            r.update({k: f[k] for k in ("id", "kind", "session_id", "session_name", "worktree", "model", "permission_mode",
                                         "user", "pid", "proc_start", "tmux_session", "window_id", "pane_id")})
            r["title"] = title
            r["alive"] = True
        else:
            r = dict(old)
            r["alive"] = False
        r["v"] = 1
        if old is None or canon(old) != canon(r):
            diff = [k for k in FIELDS if k not in VOLATILE and (old or {}).get(k) != r.get(k)]
            r["updated_at"] = now_utc()
            changes.append((i, diff))
        new[i] = r
    return new, changes, conflicts


def cmd_record(args, proc):
    live, skipped = facts(proc, read_panes(sys.stdin))
    recs = load(args.dir)
    new, changes, conflicts = merge(recs, live)
    verb = "WRITE" if args.apply else "PLAN"
    for pid, kind, why in skipped:
        print("SKIP pid %s (%s): %s" % (pid, kind, why))
    for i, pids in sorted(conflicts.items()):
        print("CONFLICT %s: carried by %d live processes (pids %s) - not recorded" % (i, len(pids), " ".join(map(str, pids))))
    for i, diff in changes:
        print("%s %s: %s" % (verb, i, ", ".join(diff) if diff else "new"))
    if args.apply:
        os.makedirs(args.dir, exist_ok=True)
        for i, _ in changes:
            write_json(os.path.join(args.dir, i + ".json"), {k: new[i].get(k) for k in FIELDS})
        write_json(os.path.join(args.dir, "index.json"),
                   {"v": 1, "hash": map_hash(load(args.dir)), "records": len(new), "reconciled_at": now_utc()})
    print("%s: %d live agent(s), %d record(s), %d change(s), %d conflict(s), %d skipped"
          % ("record" if args.apply else "record (dry run)", len(live), len(new), len(changes), len(conflicts), len(skipped)))
    return 0


def cmd_check(args, proc):
    panes = read_panes(sys.stdin)
    live, skipped = facts(proc, panes)
    recs = load(args.dir)
    per_id = {}
    for f in live:
        per_id.setdefault(f["id"], []).append(f)
    drift = 0
    rows = []
    for i in sorted(set(recs) | set(per_id)):
        r, fs = recs.get(i), per_id.get(i, [])
        why = []
        if len(fs) > 1:
            why.append("carried by %d live processes" % len(fs))
        f = fs[0] if fs else None
        if f and not r:
            why.append("live but not in the map")
        if r and r.get("alive") and not f:
            why.append("map says alive, no live process")
        if r and f:
            for k in ("pid", "session_id", "pane_id", "window_id"):
                if r.get(k) != f.get(k):
                    why.append("%s map=%s live=%s" % (k, r.get(k), f.get(k)))
        if f and f.get("window_name") is not None:
            nid, _ = strip_name(f["window_name"])
            if nid != i:
                why.append("window named %s" % (nid or repr(f["window_name"])))
        if f and not f.get("pane_id"):
            why.append("in no tmux pane")
        drift += 1 if why else 0
        rows.append((i, str((f or r or {}).get("pid") or "-"), (f or {}).get("pane_id") or (r or {}).get("pane_id") or "-",
                     ((f or {}).get("session_id") or (r or {}).get("session_id") or "-")[:8],
                     "alive" if f else ("gone" if r else "-"), "DRIFT: " + "; ".join(why) if why else "ok"))
    print("%-10s %-8s %-6s %-9s %-6s %s" % ("ID", "PID", "PANE", "SESSION", "STATE", "VERDICT"))
    for row in rows:
        print("%-10s %-8s %-6s %-9s %-6s %s" % row)
    for pid, kind, why in skipped:
        print("note: pid %s (%s) not mapped: %s" % (pid, kind, why))
    idx = {}
    try:
        with open(os.path.join(args.dir, "index.json")) as fh:
            idx = json.load(fh)
    except (OSError, ValueError):
        pass
    if recs and idx.get("hash") != map_hash(recs):
        print("DRIFT: index.json hash %s != records %s (a record changed outside record)" % (idx.get("hash"), map_hash(recs)))
        drift += 1
    print("check: %d agent(s), %d drift(s), map %s, last record %s" % (len(rows), drift, map_hash(recs), idx.get("reconciled_at", "never")))
    return 1 if drift else 0


def badge_of(name):
    """The state badge a window name carries right after its id ('' if none)."""
    n = re.sub(r"^[A-Za-z0-9][A-Za-z0-9._-]*: ", "", name)
    if n[:2] in ("> ", "? ", "! "):
        return n[0]
    m = re.match(r"^(?:CLE|GRK|AGY|QWN)-[0-9]+ ([>?!])(?: |$)", n)
    return m.group(1) if m else ""


def want_name(tag, aid, badge, title):
    out = " ".join(x for x in (aid, badge, title) if x)
    return "%s: %s" % (tag, out) if tag else out


def cmd_reconcile(args, proc):
    """Every agent window's name, derived from its record: '<tag>: <ID>
    [badge] <title>'. Only windows holding a recorded agent are touched; the
    badge is kept when the window already carries that id (the badge loop
    owns it). Prints one RENAME<TAB>pane<TAB>old<TAB>new per window to fix;
    the caller performs it (compare-and-set)."""
    live, skipped = facts(proc, read_panes(sys.stdin))
    recs = load(args.dir)
    new, changes, conflicts = merge(recs, live)
    if args.apply:
        os.makedirs(args.dir, exist_ok=True)
        for i, _ in changes:
            write_json(os.path.join(args.dir, i + ".json"), {k: new[i].get(k) for k in FIELDS})
        if changes or not os.path.exists(os.path.join(args.dir, "index.json")):
            write_json(os.path.join(args.dir, "index.json"),
                       {"v": 1, "hash": map_hash(load(args.dir)), "records": len(new), "reconciled_at": now_utc()})
    renames = 0
    for f in sorted(live, key=lambda x: x["id"]):
        if f["id"] in conflicts or not f.get("pane_id") or f.get("window_name") is None:
            continue
        r = new.get(f["id"]) or {}
        cur = f["window_name"]
        nid, _ = strip_name(cur)
        want = want_name(args.tag, f["id"], badge_of(cur) if nid == f["id"] else "", r.get("title") or "")
        if cur != want:
            print("RENAME\t%s\t%s\t%s" % (f["pane_id"], cur, want))
            renames += 1
    for i, pids in sorted(conflicts.items()):
        print("CONFLICT %s: carried by %d live processes (pids %s) - its windows left alone" % (i, len(pids), " ".join(map(str, pids))))
    print("reconcile: %d live agent(s), %d record change(s), %d window(s) to rename, %d conflict(s), %d skipped"
          % (len(live), len(changes), renames, len(conflicts), len(skipped)))
    return 0


def cmd_set_title(args, proc):
    """Set ID's title (riname): the next reconcile names its window from it."""
    recs = load(args.dir)
    r = recs.get(args.id)
    if not r:
        print("set-title: %s is not in the map (run record first)" % args.id)
        return 4
    title = re.sub(r"[\x00-\x1f#]", "", args.title).strip()[:60]
    if r.get("title") != title:
        r["title"] = title
        r["updated_at"] = now_utc()
        write_json(os.path.join(args.dir, args.id + ".json"), {k: r.get(k) for k in FIELDS})
        recs[args.id] = r
        write_json(os.path.join(args.dir, "index.json"),
                   {"v": 1, "hash": map_hash(recs), "records": len(recs), "reconciled_at": now_utc()})
    print("set-title: %s -> %s" % (args.id, title))
    return 0


def cmd_alive(args, proc):
    r = load(args.dir).get(args.id)
    if not r or not r.get("alive") or not r.get("pid"):
        return 1
    pid = str(r["pid"])
    _, start = proc.stat(pid)
    if not start or start != r.get("proc_start"):
        return 1
    # The process must still BE that agent's CLI: the same kind by argv (or by
    # comm, the rule the dispatch lease's /proc walk uses), so a shell that
    # merely inherited the env id never counts as alive.
    kind = r.get("kind") or "claude"
    if kind_of(proc.argv(pid)) != kind and proc.read(pid, "comm").strip() != kind:
        return 1
    env = proc.environ(pid)
    if (env.get("SPOOL_AGENT_ID") or env.get("MCP_BOT_AGENT_ID")) != args.id:
        return 1
    print(pid)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", required=True)
    ap.add_argument("--proc-root", default=os.environ.get("AI_PROC_ROOT", "/proc"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("facts")
    r = sub.add_parser("record")
    r.add_argument("--apply", action="store_true")
    sub.add_parser("check")
    rc = sub.add_parser("reconcile")
    rc.add_argument("--tag", default="")
    rc.add_argument("--apply", action="store_true")
    sub.add_parser("hash")
    st = sub.add_parser("set-title")
    st.add_argument("id")
    st.add_argument("title")
    a = sub.add_parser("alive")
    a.add_argument("id")
    args = ap.parse_args()
    proc = Proc(args.proc_root)
    if args.cmd == "facts":
        live, skipped = facts(proc, read_panes(sys.stdin))
        for f in live:
            print(json.dumps(f, sort_keys=True))
        return 0
    if args.cmd == "record":
        return cmd_record(args, proc)
    if args.cmd == "check":
        return cmd_check(args, proc)
    if args.cmd == "reconcile":
        return cmd_reconcile(args, proc)
    if args.cmd == "set-title":
        return cmd_set_title(args, proc)
    if args.cmd == "hash":
        print(map_hash(load(args.dir)))
        return 0
    return cmd_alive(args, proc)


if __name__ == "__main__":
    sys.exit(main())
