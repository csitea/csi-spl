#!/usr/bin/env python3
"""file-stream-follow.py - the box file follower of spec 160 (row B1, F1).

Follows the allow-listed files of this box with `tail -F` semantics (by
name: a rotation, a truncation and a file that goes missing are survived),
masks every line before it is queued, and pushes the queued lines as
`file_streams_push` frames (spec 160 3.3) until the hub acks them. Run by
do_spl_file_stream_follow as the box's agent user, never as root.

  file-stream-follow.py            the long-lived loop: one process per box
                                   (flock; a second start exits 0), a tick
                                   every FILE_STREAMS_TICK_S, exits after
                                   FILE_STREAMS_RUN_S so a code change
                                   reaches it (the minute cron restarts it)
  file-stream-follow.py --ticks N  N ticks, then exit (tests)
  file-stream-follow.py --denied P print the deny reason of path P and exit
                                   0, or exit 1 when P is not denied

Which files (spec 160 3.2): FILE_STREAMS_ALLOW, a JSON list of
{id, path} (cnf env.box.file_streams.allow). The deny list below wins over
it. Every open and reopen goes O_PATH first, then the fd is checked (its
real path against the deny list, a regular file, one link), then reopened
for reading through /proc/self/fd/N and compared by dev and inode: a name
swapped for a symlink, a device or a hardlink is refused before any byte of
it is read.

Masking (spec 160 3.1): every line passes spool_redact.redact(), the box's
one redaction list, with the PEM state on top of it: a key block spans
lines, so from its BEGIN line on every line is masked, across ticks and
restarts (the state is saved with the offset), up to PEM_MAX_LINES lines,
then while the lines are pure base64. An unmasked line never reaches the
queue file or the wire. First sight starts at the last START_LINES lines;
the PEM state is first run over up to 1 MiB above them, so a key whose
BEGIN line is above the start still masks its body.

Env (all set by do_spl_file_stream_follow from the cnf):
  FILE_STREAMS_ALLOW        JSON list of {id, path}; default []
  FILE_STREAMS_STATE_DIR    state.json, queue.jsonl, follow.lock;
                            default $HOME/.local/state/csi-spl/file-streams
  FILE_STREAMS_START_LINES  first sight starts at the last N lines (200)
  FILE_STREAMS_TICK_S       seconds between ticks (2)
  FILE_STREAMS_RUN_S        the loop exits after it (3600)
  FILE_STREAMS_PEM_MAX_LINES  the PEM cap (200)
  FILE_STREAMS_LINE_BYTES   longer lines are cut (2048)
  FILE_STREAMS_RATE_PER_MIN lines per stream per minute, the rest dropped (600)
  FILE_STREAMS_QUEUE_MAX    queued lines, the oldest dropped past it (20000)
  FILE_STREAMS_MAX          streams per box, the extra entries refused (8)
  FILE_STREAMS_PUSH_LINES   lines per frame (1000; a frame stays <= 1 MiB)
  FILE_STREAMS_PUSH_CMD     a shell command that reads one frame on stdin
                            and prints the hub's ack; empty = queue only
  FILE_STREAMS_DENY_EXTRA   more denied roots, `:`-separated (the cnf spool
                            roots, the workspace bases, every desk dir)
  SPOOL_ROOT                the box spool root, default /var/spool-hub:
                            denied, and the follower does not start when it
                            is not a directory
"""

import fcntl
import fnmatch
import glob
import json
import os
import pwd
import re
import stat
import subprocess
import sys
import time

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.realpath(__file__)),
        "..",
        "features",
        "spawn-agents",
        "lib",
    ),
)
from spool_redact import redact  # noqa: E402  (the one redaction list)

DEFAULT_SPOOL_ROOT = "/var/spool-hub"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
PEM_BEGIN_RE = re.compile(r"-----BEGIN [A-Z0-9 ]*KEY(?: BLOCK)?-----")
PEM_END_RE = re.compile(r"-----END [A-Z0-9 ]*KEY(?: BLOCK)?-----")
PEM_PRIVATE_BEGIN_RE = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY")
B64_LINE_RE = re.compile(r"^[A-Za-z0-9+/=]{1,76}$")
PEM_MASK = "<redacted:private-key>"
FRAME_MAX_BYTES = 1 << 20
READ_MAX_BYTES = 4 << 20
PRIME_BYTES = 1 << 20
DENIED_NAMES = (
    "id_*",
    "*.key",
    "*.pem",
    "*.p12",
    "*.pfx",
    ".env",
    ".env.*",
    "*_history",
    ".*history",
)
DENIED_SEGMENTS = ("keys", "inbox", "outbox")
SYSTEM_ROOTS = ("/proc", "/sys", "/dev")
SYSTEM_FILES = ("/etc/shadow", "/etc/gshadow")
# The security files of spec 160 3.8.10 (owner msg 7f673aef; Q7 A: no cnf
# key lifts one, an exception only here with its reason, none today).
SECURITY_FILES = (
    "/etc/passwd",
    "/etc/passwd-",
    "/etc/group",
    "/etc/group-",
    "/etc/shadow-",
    "/etc/gshadow-",
    "/etc/subuid",
    "/etc/subuid-",
    "/etc/subgid",
    "/etc/subgid-",
    "/etc/sudoers",
    "/etc/krb5.keytab",
    "/etc/environment",
    "/etc/crontab",
)
SECURITY_ROOTS = (
    "/etc/sudoers.d",
    "/etc/pam.d",
    "/etc/security",
    "/etc/ssh",
    "/etc/ssl/private",
    "/etc/letsencrypt",
    "/etc/sssd",
    "/var/lib/sss",
    "/etc/wireguard",
    "/etc/openvpn",
    "/etc/NetworkManager/system-connections",
    "/etc/cron.d",
    "/var/spool/cron",
)
# matched against the first segment under /var/log (a file or a dir)
SECURITY_LOGS = (
    "auth.log*",
    "secure*",
    "btmp*",
    "wtmp*",
    "lastlog*",
    "faillog*",
    "tallylog*",
    "sudo.log*",
    "fail2ban.log*",
    "pacct*",
    "audit",
    "journal",
    "private",
    "sudo-io",
    "installer",
    "account",
    "sssd",
)


def env_int(name, default):
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def say(msg):
    print(f"file-streams: {msg}", flush=True)


# ---------------------------------------------------------------- config


def spool_root():
    return os.environ.get("SPOOL_ROOT") or DEFAULT_SPOOL_ROOT


def agent_home():
    return os.environ.get("HOME") or pwd.getpwuid(os.getuid()).pw_dir


def state_dir():
    return os.environ.get("FILE_STREAMS_STATE_DIR") or os.path.join(
        agent_home(), ".local", "state", "csi-spl", "file-streams"
    )


def entry_problem(e):
    if not isinstance(e, dict) or not ID_RE.match(str(e.get("id", ""))):
        return "bad id"
    p = str(e.get("path", ""))
    if not (p.startswith("/") or p.startswith("$HOME/")):
        return "bad path"
    if p.count("*") > 1 or "*" in os.path.dirname(p):
        return "bad path"
    return ""


def read_allow():
    """-> [(id, path, problem)], one entry per id, in cnf order."""
    try:
        raw = json.loads(os.environ.get("FILE_STREAMS_ALLOW") or "[]")
    except ValueError:
        say("refused the allow-list: not JSON")
        return []
    out, seen, limit = [], set(), env_int("FILE_STREAMS_MAX", 8)
    for e in raw if isinstance(raw, list) else []:
        why = entry_problem(e)
        sid = str(e.get("id", "")) if isinstance(e, dict) else ""
        if not why and sid in seen:
            continue
        if not why and len(seen) >= limit:
            why = "over the stream limit"
        seen.add(sid)
        out.append(
            (sid or "-", str(e.get("path", "")) if isinstance(e, dict) else "", why)
        )
    return out


def resolve_name(path):
    """The name to open: $HOME expanded; a `*` in the last segment picks the
    newest match (by mtime, then name). None when nothing matches."""
    if path.startswith("$HOME/"):
        path = os.path.join(agent_home(), path[len("$HOME/") :])
    if "*" not in path:
        return path
    best = None
    for m in glob.glob(path):
        try:
            k = (os.lstat(m).st_mtime, m)
        except OSError:
            continue
        if best is None or k > best:
            best = k
    return best[1] if best else None


# ---------------------------------------------------------------- deny list


def under(path, root):
    root = root.rstrip("/") or "/"
    return path == root or path.startswith(root + "/")


class DenyContext:
    """The roots the deny list needs, resolved once per process."""

    def __init__(self):
        self.agent_homes = set()
        try:
            self.agent_homes.add(os.path.normpath(pwd.getpwuid(os.getuid()).pw_dir))
        except KeyError:
            pass
        if os.environ.get("HOME"):
            self.agent_homes.add(os.path.normpath(os.environ["HOME"]))
        self.agent_homes.discard("/")
        self.other_homes = set()
        for pw in pwd.getpwall():
            h = os.path.normpath(pw.pw_dir or "/")
            if h != "/" and h not in self.agent_homes:
                self.other_homes.add(h)
        roots = (DEFAULT_SPOOL_ROOT, spool_root())  # ctl:default-root
        self.spool_roots = {os.path.normpath(r) for r in roots}
        for r in (os.environ.get("FILE_STREAMS_DENY_EXTRA") or "").split(":"):
            if r.strip():
                self.spool_roots.add(os.path.normpath(r.strip()))
        self.state_dir = os.path.normpath(state_dir())


def security_file(p):
    """3.8.10's class: is the normalised path `p` a security file?"""
    if p in SECURITY_FILES or any(under(p, r) for r in SECURITY_ROOTS):
        return True
    if not under(p, "/var/log") or p == "/var/log":
        return False
    first = p[len("/var/log/") :].split("/")[0]
    return any(fnmatch.fnmatch(first, g) for g in SECURITY_LOGS)


def spl_file_stream_denied(path, ctx):
    """The deny list of spec 160 3.2: the reason `path` is refused, or ""."""
    p = os.path.normpath(path if path.startswith("/") else os.path.abspath(path))
    p = "/" + p.lstrip("/")  # ctl:leading-slashes (normpath keeps a leading //)
    if any(under(p, r) for r in SYSTEM_ROOTS):
        return "system path"
    if p in SYSTEM_FILES or fnmatch.fnmatch(p, "/etc/ssh/ssh_host_*_key"):
        return "system secret"
    if security_file(p):  # ctl:security-file
        return "security file"
    mine = [h for h in ctx.agent_homes if under(p, h)]
    for h in mine:
        rel = p[len(h.rstrip("/")) + 1 :]
        if p != h and rel.startswith("."):  # ctl:home-dot
            return "home dot entry"
    if under(p, "/root") or (under(p, "/home") and not mine):
        return "another home"
    for h in ctx.other_homes:
        if under(p, h) and not any(under(a, h) and a != h for a in mine):
            return "another home"
    for r in ctx.spool_roots:  # ctl:spool-root
        if under(p, r):
            return "spool root"
    if under(p, ctx.state_dir):
        return "follower state"
    segs = p.split("/")
    if any(s in DENIED_SEGMENTS for s in segs[:-1]):
        return "secret dir"
    if any(fnmatch.fnmatch(segs[-1], g) for g in DENIED_NAMES):
        return "secret name"
    return ""


class Refused(Exception):
    pass


class Missing(Exception):
    pass


def open_checked(name, ctx):
    """Open first, then check the opened file (spec 160 3.2, W2 + N3):
    -> (read fd, its stat). Raises Missing or Refused(<reason>); a refusal
    closes every fd before any byte is read."""
    try:
        pfd = os.open(name, os.O_PATH | os.O_CLOEXEC)  # ctl:o-path
    except (FileNotFoundError, NotADirectoryError):
        raise Missing()
    except OSError:
        raise Refused("unreadable")
    try:
        real = os.readlink(f"/proc/self/fd/{pfd}")
        why = spl_file_stream_denied(real, ctx)  # ctl:deny-on-fd
        if why or spl_file_stream_denied(name, ctx):
            raise Refused("denied path")
        st = os.fstat(pfd)
        if not stat.S_ISREG(st.st_mode):  # ctl:regular
            raise Refused("not a regular file")
        if st.st_nlink != 1:  # ctl:hardlink
            raise Refused("hardlink")
        try:
            rfd = os.open(
                f"/proc/self/fd/{pfd}",
                os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK | os.O_CLOEXEC,
            )
        except OSError:
            raise Refused("unreadable")
        st2 = os.fstat(rfd)
        if (st2.st_dev, st2.st_ino) != (st.st_dev, st.st_ino):
            os.close(rfd)
            raise Refused("unreadable")
        return rfd, st2
    finally:
        os.close(pfd)


# ---------------------------------------------------------------- masking


def mask_line(st, text, pem_max):
    """-> [(text, marker, {kind: n})] for one line, with the PEM state of
    spec 160 3.1 kept in `st` (pem_open, pem_lines)."""
    out = []
    if st.get("pem_open"):  # ctl:pem-state
        in_cap = st["pem_lines"] < pem_max  # ctl:pem-cap
        if in_cap or B64_LINE_RE.match(text) or PEM_END_RE.search(text):
            st["pem_lines"] += 1
            if PEM_END_RE.search(text):
                st["pem_open"] = False
            return [(PEM_MASK, False, {})]
        st["pem_open"] = False
        out.append(("-- masked block cut at cap --", True, {}))
    m = PEM_BEGIN_RE.search(text)
    if m and not PEM_END_RE.search(text, m.end()):  # ctl:pem-open
        st["pem_open"], st["pem_lines"] = True, 1
        out.append((PEM_MASK, False, {"private-key": 1}))
        return out
    masked, counts = redact(text)  # ctl:redact
    if PEM_PRIVATE_BEGIN_RE.search(masked):
        masked, counts = PEM_MASK, {"private-key": 1}
    out.append((masked, False, counts))
    return out


def cut_line(text, limit):
    b = text.encode("utf-8", "replace")
    if len(b) <= limit:
        return text
    return b[:limit].decode("utf-8", "ignore") + f" [cut {len(b) - limit} bytes]"


# ---------------------------------------------------------------- follower


class Follower:
    def __init__(self):
        self.dir = state_dir()
        self.ctx = DenyContext()
        self.start_lines = env_int("FILE_STREAMS_START_LINES", 200)
        self.pem_max = env_int("FILE_STREAMS_PEM_MAX_LINES", 200)
        self.line_bytes = env_int("FILE_STREAMS_LINE_BYTES", 2048)
        self.rate = env_int("FILE_STREAMS_RATE_PER_MIN", 600)
        self.queue_max = env_int("FILE_STREAMS_QUEUE_MAX", 20000)
        self.push_lines = env_int("FILE_STREAMS_PUSH_LINES", 1000)
        self.push_cmd = os.environ.get("FILE_STREAMS_PUSH_CMD", "")
        self.state = self.load_json(
            os.path.join(self.dir, "state.json"), {"streams": {}}
        )
        self.state.setdefault("streams", {})
        self.queue = self.load_queue()
        self.announce_pending = True
        self.pushed = 0
        self.push_rc = 0
        self.ticks = 0
        self.last_line = ""

    # -- the state dir
    @staticmethod
    def load_json(path, default):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return default

    def load_queue(self):
        out, seen = [], set()
        try:
            with open(os.path.join(self.dir, "queue.jsonl"), encoding="utf-8") as f:
                for ln in f:
                    try:
                        q = json.loads(ln)
                    except ValueError:
                        continue
                    if (q.get("k"), q.get("seq")) not in seen:
                        seen.add((q.get("k"), q.get("seq")))
                        out.append(q)
        except OSError:
            pass
        return out

    def write_atomic(self, name, text):
        tmp = os.path.join(self.dir, f".{name}.{os.getpid()}")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, os.path.join(self.dir, name))

    def save(self):
        # The queue first: a crash between the two re-reads the lines under
        # the same seq, and load_queue keeps one copy of each.
        self.write_atomic(
            "queue.jsonl",
            "".join(json.dumps(q, sort_keys=True) + "\n" for q in self.queue),
        )
        self.write_atomic(
            "state.json", json.dumps(self.state, sort_keys=True, indent=1)
        )

    # -- one stream
    def enqueue(self, sid, st, text, marker, counts):
        st["seq"] = st.get("seq", 0) + 1
        self.queue.append(
            {
                "k": sid,
                "seq": st["seq"],
                "at": utc_now(),
                "text": text,
                "marker": marker,
                "r": counts,
            }
        )

    def set_status(self, st, status, reason=""):
        if (st.get("status"), st.get("reason", "")) == (status, reason):
            return False
        st["status"], st["reason"] = status, reason
        self.announce_pending = True
        return True

    def refuse(self, sid, st, reason):
        if self.set_status(st, "refused", reason):
            say(f"refused {sid}: {reason}")
            self.enqueue(sid, st, f"-- refused: {reason} --", True, {})

    def went_missing(self, sid, st):
        if self.set_status(st, "missing"):
            self.enqueue(sid, st, "-- file missing --", True, {})

    def take_line(self, sid, st, raw, minute):
        text = raw.decode("utf-8", "replace").rstrip("\r")
        for out, marker, counts in mask_line(st, text, self.pem_max):
            if not marker:
                if st.get("rate_min") != minute:
                    st["rate_min"], st["rate_n"] = minute, 0
                if st["rate_n"] >= self.rate:
                    st["dropped_tick"] = st.get("dropped_tick", 0) + 1
                    continue
                st["rate_n"] += 1
            self.enqueue(sid, st, cut_line(out, self.line_bytes), marker, counts)

    def tail_start(self, fd, size):
        """The offset of the last start_lines lines of the file."""
        n, pos, buf = self.start_lines, size, b""
        if n <= 0:
            return size
        while pos > 0:
            step = min(65536, pos)
            pos -= step
            buf = os.pread(fd, step, pos) + buf
            idx = len(buf) - 1 if buf.endswith(b"\n") else len(buf)
            found = 0
            while found < n:
                idx = buf.rfind(b"\n", 0, idx)
                if idx < 0:
                    break
                found += 1
            if found == n:
                return pos + idx + 1
        return 0

    def prime_pem(self, fd, start, st):
        """Run the PEM state over the bytes above a first-sight start."""
        if start <= 0:
            return
        lo = max(0, start - PRIME_BYTES)
        chunk = os.pread(fd, start - lo, lo)
        if lo > 0:
            chunk = chunk[chunk.find(b"\n") + 1 :]
        for raw in chunk.split(b"\n")[:-1]:
            mask_line(st, raw.decode("utf-8", "replace").rstrip("\r"), self.pem_max)

    def follow(self, sid, path, minute):
        st = self.state["streams"].setdefault(sid, {})
        name = resolve_name(path)
        if name is None:
            return self.went_missing(sid, st)
        try:
            fd, fst = open_checked(name, self.ctx)
        except Missing:
            return self.went_missing(sid, st)
        except Refused as r:
            return self.refuse(sid, st, str(r))
        try:
            self.read_new(sid, st, name, fd, fst, minute)
        finally:
            os.close(fd)

    def read_new(self, sid, st, name, fd, fst, minute):
        was = st.get("status")
        self.set_status(st, "following")
        ident = [fst.st_dev, fst.st_ino]
        if st.get("ident") is None:
            st["offset"] = self.tail_start(fd, fst.st_size)  # ctl:first-sight
            st["pem_open"], st["pem_lines"] = False, 0
            self.prime_pem(fd, st["offset"], st)
        elif was == "missing":  # ctl:back-from-missing
            # a recreated file is new even when it got the freed inode back
            # with the old size (same ident, size == offset: nothing read)
            st["offset"], st["pem_open"], st["pem_lines"] = 0, False, 0
        elif st.get("ident") != ident or st.get("name") != name:  # ctl:by-name
            if was != "missing":
                self.enqueue(sid, st, "-- file rotated --", True, {})
            st["offset"], st["pem_open"], st["pem_lines"] = 0, False, 0
        elif fst.st_size < st.get("offset", 0):  # ctl:truncate
            self.enqueue(sid, st, "-- file truncated --", True, {})
            st["offset"], st["pem_open"], st["pem_lines"] = 0, False, 0
        st["ident"], st["name"] = ident, name
        off = st.get("offset", 0)
        data = (
            os.pread(fd, min(fst.st_size - off, READ_MAX_BYTES), off)
            if fst.st_size > off
            else b""
        )
        lines = data.split(b"\n")
        rest = lines.pop()
        used = len(data) - len(rest)
        for raw in lines:
            self.take_line(sid, st, raw, minute)
        if len(rest) >= self.line_bytes:
            self.take_line(sid, st, rest, minute)
            used = len(data)
        st["offset"] = off + used  # ctl:offset

    def end_tick(self):
        for sid, st in self.state["streams"].items():
            n = st.pop("dropped_tick", 0)
            if n:
                st["dropped"] = st.get("dropped", 0) + n
                self.enqueue(sid, st, f"-- dropped {n} lines --", True, {})
        over = len(self.queue) - self.queue_max
        if over > 0:
            for q in self.queue[:over]:
                st = self.state["streams"].setdefault(q["k"], {})
                st["dropped"] = st.get("dropped", 0) + 1
            self.queue = self.queue[over:]

    # -- the wire (spec 160 3.3)
    def send(self, frame):
        if not self.push_cmd:
            return False
        try:
            p = subprocess.run(
                ["/bin/sh", "-c", self.push_cmd],
                input=json.dumps(frame),
                capture_output=True,
                text=True,
                timeout=20,
            )
        except (OSError, subprocess.TimeoutExpired):
            self.push_rc = 124
            return False
        self.push_rc = p.returncode
        if p.returncode != 0:
            return False
        for ln in p.stdout.splitlines():
            try:
                if json.loads(ln).get("type") == "ack":
                    return True
            except (ValueError, AttributeError):
                continue
        return False

    def announce(self, allow):
        if not self.announce_pending:
            return
        streams = [
            {
                "stream_key": sid,
                "path": path,
                "state": self.state["streams"].get(sid, {}).get("status", "refused"),
            }
            for sid, path, _ in allow
        ]
        if self.send(
            {"type": "lane", "lane_op": "file_streams_announce", "streams": streams}
        ):
            self.announce_pending = False

    def frame(self, sid):
        """The next push frame of stream sid: its oldest queued lines, at most
        push_lines of them and under 1 MiB."""
        batch, size = [], 0
        for q in sorted(
            (q for q in self.queue if q["k"] == sid), key=lambda q: q["seq"]
        )[: self.push_lines]:
            size += len(json.dumps(q))
            if batch and size > FRAME_MAX_BYTES - 4096:
                break
            batch.append(q)
        red = {}
        for q in batch:
            for k, n in (q.get("r") or {}).items():
                red[k] = red.get(k, 0) + n
        return batch, {
            "type": "lane",
            "lane_op": "file_streams_push",
            "stream_key": sid,
            "lines": [
                {
                    "seq": q["seq"],
                    "at": q["at"],
                    "text": q["text"],
                    "marker": q["marker"],
                }
                for q in batch
            ],
            "dropped": self.state["streams"].get(sid, {}).get("dropped", 0),
            "redactions": red,
        }

    def push(self):
        for sid in sorted({q["k"] for q in self.queue}):
            while True:
                batch, frame = self.frame(sid)
                if not batch or not self.send(frame):  # ctl:keep-on-fail
                    break
                sent = {q["seq"] for q in batch}
                self.queue = [
                    q for q in self.queue if not (q["k"] == sid and q["seq"] in sent)
                ]
                self.state["streams"].setdefault(sid, {})["dropped"] = 0
                self.pushed += len(batch)

    def tick(self):
        allow = read_allow()
        minute = int(time.time()) // 60
        self.pushed, self.push_rc = 0, 0
        for sid, path, why in allow:
            if why:
                self.refuse(sid, self.state["streams"].setdefault(sid, {}), why)
            else:
                self.follow(sid, path, minute)
        self.end_tick()
        self.save()
        self.announce(allow)
        self.push()
        self.save()
        n = {"following": 0, "missing": 0, "refused": 0}
        for sid, _, _ in allow:
            n[self.state["streams"].get(sid, {}).get("status", "refused")] += 1
        line = (
            f"tick streams={len(allow)} following={n['following']} missing={n['missing']} "
            f"refused={n['refused']} queued={len(self.queue)} pushed={self.pushed} push_rc={self.push_rc}"
        )
        # One line a change, else one every 300 ticks: the cron log of a
        # 2 s loop stays small.
        self.ticks += 1
        if line != self.last_line or self.ticks % 300 == 1:
            say(line)
        self.last_line = line


def main(argv):
    if len(argv) == 3 and argv[1] == "--denied":
        why = spl_file_stream_denied(argv[2], DenyContext())
        if why:
            print(why)
            return 0
        return 1
    ticks = None
    if len(argv) == 3 and argv[1] == "--ticks" and argv[2].isdigit():
        ticks = int(argv[2])
    elif len(argv) != 1:
        print(
            "usage: file-stream-follow.py [--ticks N | --denied PATH]", file=sys.stderr
        )
        return 2
    if os.getuid() == 0:
        say("FATAL refusing to run as root")
        return 2
    if not os.path.isdir(spool_root()):  # ctl:root-dir
        say(f"FATAL the spool root {spool_root()} is not a directory: not started")
        return 2
    d = state_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    lock = open(os.path.join(d, "follow.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        say("another follower holds the lock: exit")
        return 0
    try:
        os.nice(10)
    except OSError:
        pass
    f = Follower()
    tick_s = max(0.2, float(os.environ.get("FILE_STREAMS_TICK_S") or 2))
    end = time.time() + env_int("FILE_STREAMS_RUN_S", 3600)
    done = 0
    while True:
        f.tick()
        done += 1
        if (ticks is not None and done >= ticks) or (
            ticks is None and time.time() >= end
        ):
            return 0
        time.sleep(tick_s)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
