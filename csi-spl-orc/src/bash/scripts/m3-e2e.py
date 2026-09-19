#!/usr/bin/env python3
"""M3 end to end against a deployed hub (spec 014 acceptance, 005 SC-001,
006 T011c dev part). Called by `./run -a do_spl_m3_e2e` (csi-spl-orc), which
stages the tenant root key, builds the spool CLI and seats the human.

Two box clients on this machine (own SPOOL_ROOT + key each, pinned by the
tenant root key) talk to the hub's /v1/ws; one signed-in member human and one
non-member talk to /v1/wui/ws with their session cookie. Every step prints
`PASS|FAIL <step> <evidence>` and the run writes results.json in the state dir.

Stdlib only. Secrets (root key, passwords, session cookies) live in 0600 files
under the state dir and never reach stdout, argv or results.json.

Usage: m3-e2e.py auth-check | run
Env:   M3_HUB_URL      https://<api host>        (box + tenant API; specs/026: one
                       host, the tenant comes from the session / the box pin)
       M3_TENANT       the tenant (default: the first label of M3_HUB_URL, the
                       legacy <tenant>.<fqdn> form)
       M3_OTHER_TENANT (optional) a tenant the humans and boxes are NOT in, for
                       the 026 controls (default t1, or e2e when M3_TENANT is t1)
       M3_AUTH_URL     https://<fqdn>            (/api/v1/auth/*, cookie domain)
       M3_STATE        run state dir (0700)
       M3_SPOOL        spool CLI
       M3_ROOT_KEY     tenant root private key file (0600)
       M3_HUMAN_EMAIL  member human (seated by invite)
       M3_OUTSIDER_EMAIL  never-invited human (the door control)
       M3_IMAP_USER, M3_IMAP_PASS_FILE, M3_IMAP_HOST  (optional) a hub with no
                       debug tokens (prd): the verify mail is read over IMAP from
                       this mailbox (the relay's own, csi-rel's verify_relay_e2e
                       pattern; plus-addresses land in it). The token in its link
                       is consumed through the hub's verify API, and the link's
                       WUI page is probed and recorded (not gated).
"""
import base64
import email as emaillib
import imaplib
import re
import hashlib
import json
import os
import queue
import secrets
import shutil
import signal
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BOX_A, BOX_B = "box-e2e-a", "box-e2e-b"
AGENT_A, AGENT_B = "EZA-1", "EZB-1"
WUI = "box-wui"

HUB = os.environ.get("M3_HUB_URL", "").rstrip("/")
TENANT = os.environ.get("M3_TENANT", "") or (urllib.parse.urlparse(HUB).hostname or "").split(".")[0]
OTHER = os.environ.get("M3_OTHER_TENANT", "") or ("e2e" if TENANT == "t1" else "t1")
AUTH = os.environ.get("M3_AUTH_URL", "").rstrip("/")
STATE = os.environ.get("M3_STATE", "")
SPOOL = os.environ.get("M3_SPOOL", "")
ROOT_KEY = os.environ.get("M3_ROOT_KEY", "")
HUMAN = os.environ.get("M3_HUMAN_EMAIL", "")
OUTSIDER = os.environ.get("M3_OUTSIDER_EMAIL", "")
IMAP_USER = os.environ.get("M3_IMAP_USER", "")
IMAP_PASS_FILE = os.environ.get("M3_IMAP_PASS_FILE", "")
IMAP_HOST = os.environ.get("M3_IMAP_HOST", "imap.gmail.com")
IMAP_TIMEOUT = int(os.environ.get("M3_IMAP_TIMEOUT", "240"))
VERIFY_LINK = re.compile(r"(https?://[^\s\"'<>]*/verify-email)\?token=([0-9a-f]{64})")

RESULTS = []


def log(msg):
    print(msg, flush=True)


def record(step, ok, evidence):
    RESULTS.append({"step": step, "result": "PASS" if ok else "FAIL", "evidence": evidence})
    log("%s %s %s" % ("PASS" if ok else "FAIL", step, json.dumps(evidence, sort_keys=True)))
    return ok


def write_results():
    p = os.path.join(STATE, "results.json")
    with open(p, "w") as f:
        json.dump({"hub": HUB, "results": RESULTS}, f, indent=1, sort_keys=True)
    log("results: %s" % p)


# ---- HTTP ---------------------------------------------------------------------

def http(method, url, body=None, headers=None):
    """(status, headers, parsed-or-raw body). Never raises on HTTP status."""
    h = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=20)
        status, hdrs, raw = r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        status, hdrs, raw = e.code, e.headers, e.read()
    try:
        out = json.loads(raw.decode()) if raw else None
    except ValueError:
        out = raw.decode(errors="replace")
    return status, hdrs, out


def session_cookie(hdrs):
    """name=value of the session cookie a login set (never printed)."""
    for v in hdrs.get_all("Set-Cookie") or []:
        pair = v.split(";", 1)[0]
        if pair.startswith("spool_session") and "=" in pair and pair.split("=", 1)[1]:
            return pair
    return ""


def secret_file(name):
    return os.path.join(STATE, name)


def read_secret(name):
    try:
        with open(secret_file(name)) as f:
            return f.read().strip()
    except OSError:
        return ""


def write_secret(name, value):
    p = secret_file(name)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(value + "\n")


def native_login(email, tenant, tag):
    """Sign in with the native provider (015). A stored password is tried
    first; register + debug-token verify only when it does not work, which
    keeps a re-run inside the per-IP form ceiling. Returns (status, body, cookie)."""
    pw_name = "pw-%s" % tag
    pw = read_secret(pw_name)
    body = {"email": email, "password": pw}
    if tenant:
        body["tenant"] = tenant
    if pw:
        st, h, out = http("POST", AUTH + "/api/v1/auth/login", body)
        if st == 200 or (st == 403 and isinstance(out, dict) and out.get("error") == "not_allowed"):
            return st, out, session_cookie(h)
        if st == 429:
            return st, out, ""
    pw = secrets.token_urlsafe(18)
    seen = imap_uids(email) if IMAP_USER else set()
    st, _, out = http("POST", AUTH + "/api/v1/auth/register", {"email": email, "password": pw, "name": "m3-e2e " + tag})
    if st != 202 or not isinstance(out, dict):
        return st, {"step": "register", "body": out}, ""
    token, ev = out.get("debug_token", ""), {"email": email, "register": st, "via": "debug_token",
                                            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if not token and IMAP_USER:
        token, mail_ev = imap_verify_token(email, seen)
        ev.update(mail_ev)
        ev["via"] = "imap"
    if not token:
        write_json("verify-%s.json" % tag, ev)
        return st, {"step": "register", "body": out, "mail": ev}, ""
    st, _, out = http("POST", AUTH + "/api/v1/auth/email/verify", {"token": token})
    ev["hub_verify_api"] = st
    write_json("verify-%s.json" % tag, ev)
    if st != 204:
        return st, {"step": "verify", "body": out}, ""
    write_secret(pw_name, pw)
    body["password"] = pw
    st, h, out = http("POST", AUTH + "/api/v1/auth/login", body)
    return st, out, session_cookie(h)


def write_json(name, obj):
    """A non-secret evidence file in the state dir (never a token or password)."""
    with open(os.path.join(STATE, name), "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)


def read_json(name):
    try:
        with open(os.path.join(STATE, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# ---- the verify mail over IMAP (hubs without debug tokens: prd) -----------------------

def imap_open():
    with open(IMAP_PASS_FILE) as f:
        pw = f.read().strip()
    m = imaplib.IMAP4_SSL(IMAP_HOST, 993, timeout=30)
    m.login(IMAP_USER, pw)
    m.select('"[Gmail]/All Mail"', readonly=True)
    return m


def imap_uids(rcpt):
    """UIDs of the mails already addressed to rcpt, so only a NEW mail counts."""
    m = imap_open()
    try:
        _, data = m.uid("SEARCH", None, 'TO "%s"' % rcpt)
        return set(data[0].split())
    finally:
        m.logout()


def imap_verify_token(rcpt, seen):
    """Poll the mailbox for a new verify mail to rcpt. Returns (token, evidence);
    the evidence names the sender, subject, message id, the link's page (host +
    path, no query) and that page's HTTP status, never the token."""
    t0 = time.time()
    while time.time() < t0 + IMAP_TIMEOUT:
        m = imap_open()
        try:
            _, data = m.uid("SEARCH", None, 'TO "%s"' % rcpt)
            for uid in reversed(data[0].split()):
                if uid in seen:
                    continue
                _, fetched = m.uid("FETCH", uid, "(RFC822)")
                msg = emaillib.message_from_bytes(fetched[0][1])
                for part in msg.walk():
                    if part.get_content_maintype() != "text":
                        continue
                    hit = VERIFY_LINK.search((part.get_payload(decode=True) or b"").decode("utf-8", "replace"))
                    if hit:
                        page = hit.group(1)
                        st_page, hdrs, _ = http("GET", page)  # the bare page: consumes nothing
                        return hit.group(2), {"mail_from": msg.get("From"), "mail_subject": msg.get("Subject"),
                                              "mail_message_id": msg.get("Message-ID"),
                                              "mail_after_s": round(time.time() - t0, 1), "link_page": page,
                                              "link_page_status": st_page,
                                              "link_page_type": (hdrs.get("Content-Type") or "").split(";")[0]}
        finally:
            m.logout()
        time.sleep(5)
    return "", {"mail": "no verify mail to %s within %ds" % (rcpt, IMAP_TIMEOUT)}


# ---- WebSocket client (TLS or plain), one reader thread ------------------------

def mask_frame(payload, opcode=1):
    mask = os.urandom(4)
    data = bytearray(payload)
    for i in range(len(data)):
        data[i] ^= mask[i % 4]
    n = len(payload)
    if n < 126:
        hdr = bytes([0x80 | opcode, 0x80 | n])
    elif n < 65536:
        hdr = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack("!H", n)
    else:
        hdr = bytes([0x80 | opcode, 0x80 | 127]) + struct.pack("!Q", n)
    return hdr + mask + bytes(data)


def read_frame(recv):
    b0, b1 = recv(1)[0], recv(1)[0]
    opcode, ln = b0 & 0x0F, b1 & 0x7F
    if ln == 126:
        ln = struct.unpack("!H", recv(2))[0]
    elif ln == 127:
        ln = struct.unpack("!Q", recv(8))[0]
    mask = recv(4) if b1 & 0x80 else None
    payload = bytearray(recv(ln))
    if mask:
        for i in range(ln):
            payload[i] ^= mask[i % 4]
    return opcode, bytes(payload)


class WS:
    """Browser-like client of /v1/wui/ws. Frames land in self.q."""

    def __init__(self, url, cookie=""):
        u = urllib.parse.urlparse(url)
        port = u.port or (443 if u.scheme == "wss" else 80)
        raw = socket.create_connection((u.hostname, port), timeout=20)
        if u.scheme == "wss":
            raw = ssl.create_default_context().wrap_socket(raw, server_hostname=u.hostname)
        self.s = raw
        key = base64.b64encode(os.urandom(16)).decode()
        lines = ["GET %s HTTP/1.1" % (u.path or "/"), "Host: %s" % u.hostname, "Upgrade: websocket",
                 "Connection: Upgrade", "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13"]
        if cookie:
            lines.append("Cookie: " + cookie)
        self.s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.s.recv(4096)
            if not chunk:
                raise RuntimeError("no websocket upgrade response")
            buf += chunk
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        self.status = head.split(b"\r\n", 1)[0].decode()
        if " 101 " not in self.status + " ":
            raise RuntimeError("upgrade refused: %s %s" % (self.status, self.buf[:200].decode(errors="replace")))
        want = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        if want.encode() not in head:
            raise RuntimeError("bad Sec-WebSocket-Accept")
        self.q = queue.Queue()
        self.seen = []
        self.closed = None
        self.wlock = threading.Lock()
        threading.Thread(target=self._reader, daemon=True).start()

    def _recv(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _reader(self):
        self.s.settimeout(None)
        try:
            while True:
                op, payload = read_frame(self._recv)
                if op == 8:
                    self.closed = payload
                    return
                if op == 9:
                    with self.wlock:
                        self.s.sendall(mask_frame(payload, 10))
                    continue
                if op == 1:
                    f = json.loads(payload.decode())
                    self.seen.append(f)
                    self.q.put(f)
        except Exception as e:  # noqa: BLE001 - reader ends with the socket
            self.closed = self.closed or str(e).encode()

    def send(self, obj):
        with self.wlock:
            self.s.sendall(mask_frame(json.dumps(obj).encode()))

    def wait(self, pred, timeout=20):
        """First frame matching pred (errors too, when pred accepts them)."""
        end = time.time() + timeout
        while time.time() < end:
            try:
                f = self.q.get(timeout=max(0.05, end - time.time()))
            except queue.Empty:
                break
            if pred(f):
                return f
        return None

    def any_seen(self, pred):
        return next((f for f in self.seen if pred(f)), None)

    def close(self):
        try:
            with self.wlock:
                self.s.sendall(mask_frame(struct.pack("!H", 1000), 8))
            self.s.close()
        except OSError:
            pass


def ws_url(path):
    return "ws" + HUB[len("http"):] + path


# ---- boxes -------------------------------------------------------------------------

def box_env(box, hub=None, box_id=None, tenant=None):
    """Env of one box: its own spool root + keys under STATE/<box>. box_id
    overrides the id (a replay clone runs as the box it copies); tenant is the
    SPOOL_TENANT it names (specs/026 X-Spool-Tenant, default TENANT)."""
    d = os.path.join(STATE, box)
    e = dict(os.environ)
    e.update({"SPOOL_ROOT": d + "/spool", "SPOOL_KEYS_DIR": d + "/keys", "SPOOL_BOX_ID": box_id or box,
              "SPOOL_HUB_URL": hub or HUB, "SPOOL_TENANT": tenant or TENANT})
    return e


def on(box, *args, hub=None, timeout=60, box_id=None, tenant=None):
    """Run the spool CLI as a box: (exit code, stdout, stderr)."""
    p = subprocess.run([SPOOL] + list(args), env=box_env(box, hub, box_id, tenant), capture_output=True, text=True,
                       timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def must(box, *args, **kw):
    rc, out, err = on(box, *args, **kw)
    if rc != 0:
        raise RuntimeError("spool %s as %s -> exit %d: %s" % (" ".join(args[:1]), box, rc, err or out))
    return out


def inbox(box, agent):
    """Every message in the agent's inbox (recv without --ack)."""
    out = must(box, "recv", "--as", agent)
    return json.loads(out) if out else []


def wait_inbox(box, agent, pred, timeout=25):
    end = time.time() + timeout
    while time.time() < end:
        m = next((m for m in inbox(box, agent) if pred(m)), None)
        if m:
            return m
        time.sleep(0.5)
    return None


def pin_box(box, agent):
    d = os.path.join(STATE, box)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "spool", agent), mode=0o700)
    pub = must(box, "keygen")
    must(box, "hub-pin", "--box", box, "--pubkey", pub, "--root-key", ROOT_KEY, "--force")
    return pub


def view(path):
    """GET a viewer read as the member human: its session cookie opens a
    session door (010 FR-009) and is ignored by a door-off hub."""
    st, _, out = http("GET", HUB + path, headers={"Cookie": read_secret("cookie-human")})
    if st != 200:
        raise RuntimeError("GET %s -> %s %s" % (path, st, out))
    return out


def thread(task):
    return view("/v1/view/threads/" + task).get("messages", [])


# ---- fake hub: replays chosen envelopes to a real `spool hub-sync` -------------------

class FakeHub(socketserver.ThreadingMixIn, socketserver.TCPServer):
    """Speaks just enough of /v1/ws + GET /v1/pins for one role=box session:
    challenge, welcome, the pins it is given, then the recv frames it is
    given, then queue_end. The box under test runs its normal Dial + receive
    (verify against its LOCAL pin) code; this is how a forged envelope reaches
    it, since the real hub refuses to store one."""
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, pins, envs):
        self.pins, self.envs = pins, envs
        super().__init__(("127.0.0.1", 0), FakeHubHandler)


class FakeHubHandler(socketserver.BaseRequestHandler):
    def handle(self):
        s = self.request
        buf = b""
        while b"\r\n\r\n" not in buf:
            c = s.recv(4096)
            if not c:
                return
            buf += c
        head, rest = buf.split(b"\r\n\r\n", 1)
        line = head.split(b"\r\n", 1)[0].decode()
        hdrs = {}
        for h in head.split(b"\r\n")[1:]:
            k, _, v = h.decode().partition(":")
            hdrs[k.strip().lower()] = v.strip()
        if line.startswith("GET /v1/pins"):
            body = json.dumps({"pins": self.server.pins}).encode()
            s.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
            return
        if not line.startswith("GET /v1/ws"):
            s.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        acc = base64.b64encode(hashlib.sha1((hdrs["sec-websocket-key"] + GUID).encode()).digest())
        s.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + acc + b"\r\n\r\n")
        state = {"buf": rest}

        def recv(n):
            while len(state["buf"]) < n:
                c = s.recv(65536)
                if not c:
                    raise EOFError
                state["buf"] += c
            out, state["buf"] = state["buf"][:n], state["buf"][n:]
            return out

        def send(obj):
            p = json.dumps(obj).encode()
            n = len(p)
            hdr = bytes([0x81, n]) if n < 126 else (bytes([0x81, 126]) + struct.pack("!H", n) if n < 65536 else bytes([0x81, 127]) + struct.pack("!Q", n))
            s.sendall(hdr + p)

        send({"type": "challenge", "nonce": secrets.token_hex(16)})
        try:
            read_frame(recv)  # hello: not checked, this hub only replays
            exp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600))
            send({"type": "welcome", "roster": {}, "upload_token": "fake", "upload_token_expires_at": exp})
            for e in self.server.envs:
                send({"type": "recv", "env": e})
            send({"type": "queue_end", "count": len(self.server.envs)})
            while True:
                op, _ = read_frame(recv)
                if op == 8:
                    return
        except (EOFError, OSError):
            return


def replay_to_box(box, envs, pins):
    """Clone box's spool root + keys, run hub-sync against a FakeHub that
    replays envs. (exit code, stderr, inbox ids written)."""
    clone = box + "-replay"
    src, dst = os.path.join(STATE, box), os.path.join(STATE, clone)
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst, symlinks=True)
    for sub in ("inbox", "archive"):  # an empty inbox, so a written copy is visible
        d = os.path.join(dst, "spool", AGENT_B, sub)
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
    srv = FakeHub(pins, envs)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        before = {m["msg_id"] for m in inbox(clone, AGENT_B)}
        rc, out, err = on(clone, "hub-sync", hub="http://127.0.0.1:%d" % srv.server_address[1], timeout=30, box_id=box)
        after = {m["msg_id"] for m in inbox(clone, AGENT_B)}
    finally:
        srv.shutdown()
        srv.server_close()
    return rc, (err or out)[-300:], sorted(after - before)


# ---- the run -----------------------------------------------------------------------------

def need(*names):
    miss = [n for n in names if not os.environ.get(n)]
    if miss:
        sys.exit("m3-e2e: missing env %s" % " ".join(miss))


def auth_check():
    """exit 0 = the member human signs in to the tenant; 3 = invite it first.

    Never signs in WITH the tenant before an invite exists (the marker file
    `invited` or M3_INVITED=1): on a zero-member tenant with bootstrap on,
    that first sign-in would make this test account the tenant's OWNER."""
    need("M3_HUB_URL", "M3_AUTH_URL", "M3_STATE", "M3_HUMAN_EMAIL")
    tenant = TENANT
    if os.environ.get("M3_INVITED") == "1":
        write_secret("invited", HUMAN)
    if read_secret("invited") != HUMAN:
        log("auth-check: no invite recorded for %s in %s: invite first" % (HUMAN, tenant))
        return 3
    st, out, cookie = native_login(HUMAN, tenant, "human")
    if st == 200 and cookie:
        write_secret("cookie-human", cookie)
        log("auth-check: member session for tenant %s (hum %s)" % (tenant, (out or {}).get("hum", "?")))
        return 0
    if st == 403 and isinstance(out, dict) and out.get("error") == "not_allowed":
        log("auth-check: %s is not a member of %s (403 not_allowed): invite needed" % (HUMAN, tenant))
        return 3
    log("auth-check: login -> %s %s" % (st, json.dumps(out)[:300]))
    return 1


def run():
    need("M3_HUB_URL", "M3_AUTH_URL", "M3_STATE", "M3_SPOOL", "M3_ROOT_KEY", "M3_HUMAN_EMAIL", "M3_OUTSIDER_EMAIL")
    tenant = TENANT
    st, _, ver = http("GET", HUB + "/version")
    log("hub %s version %s" % (HUB, json.dumps(ver)))
    RESULTS.append({"step": "hosts", "result": "INFO", "evidence": {"hub": HUB, "auth": AUTH, "version": ver}})
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())

    # -- door: which view door the hub runs (an anonymous read answers 401 view_door
    # behind a token or session door; 200 only with the lde/dev door off)
    st_anon, _, out_anon = http("GET", HUB + "/v1/view/threads")
    door_on = st_anon == 401
    RESULTS.append({"step": "door", "result": "INFO", "evidence": {"anonymous_view_threads": st_anon,
                    "error": (out_anon or {}).get("error") if isinstance(out_anon, dict) else None}})
    log("INFO door %s" % json.dumps(RESULTS[-1]["evidence"]))

    # -- 0. boxes: two keys, root-signed pins, the hub's box-wui key pinned ------------------
    pub_a, pub_b = pin_box(BOX_A, AGENT_A), pin_box(BOX_B, AGENT_B)
    wui = view("/v1/wui/pubkey")
    must(BOX_A, "hub-pin", "--box", WUI, "--pubkey", wui["pubkey"], "--root-key", ROOT_KEY, "--force")
    for b in (BOX_B, BOX_A, BOX_B):  # second hello refreshes each box's roster copy
        must(b, "hub-sync")
    roster = {b["box_id"]: b for b in view("/v1/view/roster")["boxes"]}
    pins = {p: open(os.path.join(STATE, BOX_B, "spool", "pins", "box-%s.pub" % p)).read().strip()
            for p in (BOX_A, WUI) if os.path.exists(os.path.join(STATE, BOX_B, "spool", "pins", "box-%s.pub" % p))}
    record("0-boxes", roster.get(BOX_A, {}).get("agents") == [AGENT_A] and roster.get(BOX_B, {}).get("agents") == [AGENT_B]
           and wui.get("dispatch") is True and pins.get(WUI) == wui["pubkey"],
           {"box_a": pub_a, "box_b": pub_b, "box_wui_pubkey": wui["pubkey"], "dispatch": wui.get("dispatch"),
            "roster_agents": {k: v.get("agents") for k, v in roster.items() if k in (BOX_A, BOX_B)},
            "box_b_local_box_wui_pin_matches_hub": pins.get(WUI) == wui["pubkey"]})

    # -- a. box-a -> box-b spool send, visible in the viewer API (005 SC-001) -----------------
    rc, out, err = on(BOX_A, "send", "--from", AGENT_A, "--to", AGENT_B, "--kind", "task", "--body", "m3-e2e a->b " + stamp)
    sa = json.loads(out) if rc == 0 else {"exit": rc, "err": err}
    rep = json.loads(must(BOX_B, "hub-sync"))
    got = next((m for m in inbox(BOX_B, AGENT_B) if m.get("msg_id") == sa.get("msg_id")), None)
    listed = any(t["task_id"] == sa.get("task_id") for t in view("/v1/view/threads")["threads"]) if rc == 0 else False
    msgs = thread(sa["task_id"]) if rc == 0 else []
    record("a-box-to-box", rc == 0 and got is not None and listed and len(msgs) == 1,
           {"send": sa, "box_b_sync": rep, "box_b_inbox_has_it": got is not None, "view_threads_lists_task": listed,
            "view_thread_messages": len(msgs), "delivery_state": msgs[0]["deliveries"] if msgs else None})
    t_sc001 = sa.get("task_id")

    # -- humans ---------------------------------------------------------------------------------------
    cookie = read_secret("cookie-human")
    st, _, sess = http("GET", AUTH + "/api/v1/auth/session", headers={"Cookie": cookie})
    hum = (sess or {}).get("hum", "") if st == 200 else ""
    mv = read_json("verify-human.json")
    if mv and mv.get("via") == "imap":
        # prd: the native sign-up went through a REAL mailbox. Gated: the mail
        # arrived and the hub's verify API took its token. Recorded: whether the
        # link's WUI page serves (it 404s until the apex serves the WUI).
        record("h-verify-mail", mv.get("hub_verify_api") == 204 and bool(mv.get("mail_message_id")),
               {k: mv.get(k) for k in ("email", "at", "mail_from", "mail_subject", "mail_message_id", "mail_after_s",
                                       "hub_verify_api", "link_page", "link_page_status", "link_page_type")})
    record("h-member-session", st == 200 and hum.startswith("HUM-") and (sess or {}).get("t") == tenant,
           {"session_status": st, "hum": hum, "t": (sess or {}).get("t"), "p": (sess or {}).get("p")})

    # box-b goes live (hub-run) AFTER the browser is up, so presence is observed live
    ws = WS(ws_url("/v1/wui/ws"), cookie)
    ws.send({"type": "hello", "as": "m3-e2e"})
    wel = ws.wait(lambda f: f.get("type") in ("welcome", "error"))
    record("h-welcome-is-session", bool(wel) and wel.get("as") == hum,
           {"welcome_as": (wel or {}).get("as"), "session_hum": hum})
    ws.send({"type": "subscribe", "channel": "lobby"})
    ws.wait(lambda f: f.get("type") == "subscribed")
    run_b = subprocess.Popen([SPOOL, "hub-run"], env=box_env(BOX_B), stdout=subprocess.DEVNULL,
                             stderr=open(os.path.join(STATE, "hub-run-b.log"), "a"), start_new_session=True)
    peer_b = "%s@%s" % (AGENT_B, BOX_B)
    online = ws.wait(lambda f: f.get("type") == "presence" and f.get("peer") == peer_b and f.get("status") == "online", 30)
    try:
        def send_wait(frame, timeout=20):
            frame.setdefault("msg_id", str(uuid.uuid4()))
            ws.send(frame)
            return ws.wait(lambda f: f.get("msg_id") == frame["msg_id"] and f.get("type") in ("ack", "error"), timeout)

        # -- b. #lobby: ambient note reaches no box; a leading @mention does ------------------
        amb = send_wait({"type": "send", "task_id": str(uuid.uuid4()), "channel": "lobby", "kind": "note",
                         "body": "m3-e2e ambient " + stamp})
        men = send_wait({"type": "send", "task_id": str(uuid.uuid4()), "channel": "lobby", "kind": "note",
                         "body": "@%s m3-e2e mention %s" % (AGENT_B, stamp)})
        mid = send_wait({"type": "send", "task_id": str(uuid.uuid4()), "channel": "lobby", "kind": "note",
                         "body": "m3-e2e mid-body @%s %s" % (AGENT_B, stamp)})
        got_men = wait_inbox(BOX_B, AGENT_B, lambda m: m.get("msg_id") == (men or {}).get("msg_id"))
        time.sleep(3)
        ids_b = {m["msg_id"] for m in inbox(BOX_B, AGENT_B)}
        amb_rows = thread(amb["task_id"])[0]["deliveries"] if amb and amb.get("type") == "ack" else None
        # the browser audience's own row (to_box box-wui) is expected; no BOX may have one
        record("b-lobby-ambient-not-routed", bool(amb) and amb.get("type") == "ack" and amb["msg_id"] not in ids_b
               and amb_rows is not None and all(r["to_box"] == WUI for r in amb_rows),
               {"ack": amb, "in_box_b_inbox": bool(amb) and amb.get("msg_id") in ids_b, "deliveries": amb_rows})
        record("b-lobby-mention-routed", bool(men) and men.get("type") == "ack" and men.get("to_box") == BOX_B and got_men is not None
               and got_men.get("from") == hum,
               {"ack": men, "box_b_inbox": got_men})
        # Observation, not a gate: spec 014 FR-006 dispatches on a LEADING mention only and
        # channels-v1 section 4.6 never routes an unsigned browser envelope, so a mid-body
        # mention from a human stays in the browser.
        RESULTS.append({"step": "b-obs-mid-body-mention", "result": "OBSERVED",
                        "evidence": {"ack": mid, "in_box_b_inbox": bool(mid) and mid.get("msg_id") in ids_b}})
        log("OBS  b-obs-mid-body-mention %s" % json.dumps(RESULTS[-1]["evidence"], sort_keys=True))

        # -- c. @agent task: box-wui SIGNED, box verifies on its own pin, result back ------------
        t_task = str(uuid.uuid4())
        ws.send({"type": "subscribe", "task_id": t_task})
        ws.wait(lambda f: f.get("type") == "subscribed" and f.get("task_id") == t_task)
        task = send_wait({"type": "send", "task_id": t_task, "channel": "lobby", "kind": "task", "to": AGENT_B,
                          "body": "m3-e2e task: report the box id " + stamp})
        got_task = wait_inbox(BOX_B, AGENT_B, lambda m: m.get("msg_id") == (task or {}).get("msg_id"))
        stored = thread(t_task)
        env = stored[0]["env"] if stored else {}
        record("c-task-signed-and-verified", bool(task) and task.get("type") == "ack" and task.get("to_box") == BOX_B
               and got_task is not None and got_task.get("kind") == "task" and got_task.get("from") == hum
               and env.get("from_box") == WUI and bool(env.get("sig")),
               {"ack": task, "stored_env_from_box": env.get("from_box"), "stored_env_to_box": env.get("to_box"),
                "stored_env_sig_len": len(env.get("sig") or ""), "box_b_inbox": got_task,
                "verified_by": "spool hub-run receive() against $SPOOL_ROOT/pins/box-box-wui.pub"})
        rc, out, err = on(BOX_B, "send", "--from", AGENT_B, "--to", hum, "--task", t_task, "--kind", "result",
                          "--to-box", WUI, "--body", "m3-e2e result: I am %s on %s" % (AGENT_B, BOX_B))
        res = json.loads(out) if rc == 0 else {"exit": rc, "err": err}
        frame = ws.wait(lambda f: f.get("type") == "message" and f.get("task_id") == t_task
                        and (f.get("envelope") or {}).get("kind") == "result", 20)
        kinds = [m["env"]["msg"]["kind"] for m in thread(t_task)]
        record("c-result-in-wui-thread", rc == 0 and frame is not None and kinds == ["task", "result"],
               {"send": res, "wui_frame_msg_id": (frame or {}).get("envelope", {}).get("msg_id"), "thread_kinds": kinds})

        # -- d. DM (no channel) human <-> agent -------------------------------------------------------------------
        t_dm = str(uuid.uuid4())
        ws.send({"type": "subscribe", "task_id": t_dm})
        ws.wait(lambda f: f.get("type") == "subscribed" and f.get("task_id") == t_dm)
        dm = send_wait({"type": "send", "task_id": t_dm, "kind": "note", "to": AGENT_B, "body": "m3-e2e dm " + stamp})
        got_dm = wait_inbox(BOX_B, AGENT_B, lambda m: m.get("msg_id") == (dm or {}).get("msg_id"))
        rc, out, err = on(BOX_B, "send", "--from", AGENT_B, "--to", hum, "--task", t_dm, "--kind", "note",
                          "--to-box", WUI, "--body", "m3-e2e dm reply " + stamp)
        dm_back = ws.wait(lambda f: f.get("type") == "message" and f.get("task_id") == t_dm
                          and (f.get("envelope") or {}).get("from") == AGENT_B, 20)
        dm_list = view("/v1/view/threads?dm=true&peer=" + AGENT_B)["threads"]
        dm_row = next((t for t in dm_list if t["task_id"] == t_dm), None)
        record("d-dm-round-trip", bool(dm) and dm.get("type") == "ack" and got_dm is not None and rc == 0 and dm_back is not None
               and dm_row is not None and dm_row.get("channel") is None,
               {"ack": dm, "box_b_inbox": got_dm is not None, "reply_rc": rc, "wui_frame": dm_back is not None,
                "view_dm_row": dm_row})
    finally:
        os.killpg(run_b.pid, signal.SIGTERM)
        run_b.wait(timeout=15)
    offline = ws.wait(lambda f: f.get("type") == "presence" and f.get("peer") == peer_b and f.get("status") == "offline", 30)
    record("d-presence", online is not None and offline is not None,
           {"online": online, "offline": offline})
    ws.close()

    # -- e1. CONTROL: forged / unsigned envelopes are refused by the box (exit 78) ------------------------
    pins_list = [{"box_id": WUI, "pubkey": wui["pubkey"]}, {"box_id": BOX_A, "pubkey": pub_a}, {"box_id": BOX_B, "pubkey": pub_b}]
    genuine = dict(env)
    genuine["msg"] = dict(env["msg"])
    genuine["msg"]["msg_id"] = str(uuid.uuid4())  # a new id changes the signed bytes: forged
    tampered = dict(env)
    tampered["msg"] = dict(env["msg"], body=env["msg"]["body"] + " (tampered)")
    unsigned = dict(env, sig="")
    ok_rc, ok_err, ok_new = replay_to_box(BOX_B, [env], pins_list)
    outcomes = {}
    for name, e in (("tampered_body", tampered), ("unsigned", unsigned), ("new_msg_id", genuine)):
        rc, err, new = replay_to_box(BOX_B, [e], pins_list)
        outcomes[name] = {"exit": rc, "written": new, "err": err[-160:]}
    record("e1-forged-refused-by-box", ok_rc == 0 and all(o["exit"] == 78 and not o["written"] for o in outcomes.values()),
           {"control_genuine_env": {"exit": ok_rc, "written": len(ok_new)}, "forged": outcomes})

    # -- e2. CONTROL: a non-member human is refused -------------------------------------------------------------------
    st_t, out_t, _ = native_login(OUTSIDER, tenant, "outsider")
    st_n, out_n, cookie_o = native_login(OUTSIDER, "", "outsider")
    ev = {"login_with_tenant": [st_t, (out_t or {}).get("error") if isinstance(out_t, dict) else out_t],
          "login_without_tenant": st_n}
    ok = st_t == 403 and isinstance(out_t, dict) and out_t.get("error") == "not_allowed" and st_n == 200 and cookie_o
    if cookie_o:
        try:
            wo = WS(ws_url("/v1/wui/ws"), cookie_o)
            wo.send({"type": "hello", "as": hum})  # tries to pass as the member
            w2 = wo.wait(lambda f: f.get("type") in ("welcome", "error"))
            mid_o = str(uuid.uuid4())
            wo.send({"type": "send", "msg_id": mid_o, "task_id": str(uuid.uuid4()), "channel": "lobby", "kind": "task",
                     "to": AGENT_B, "body": "m3-e2e outsider task " + stamp})
            r2 = wo.wait(lambda f: f.get("msg_id") == mid_o and f.get("type") in ("ack", "error"))
            wo.close()
            ev.update({"ws_upgrade": "101", "dispatch": r2})
            ok = ok and (r2 or {}).get("error") == "dispatch_unauthenticated"
            # Door off (dev today): an id-shaped hello.as is taken as asserted
            # (wui-live-ws.md section 3.1), so a non-member can post browser-only
            # notes AS a member's HUM id. Recorded, not gated: the fix is the
            # session door (010 T019), not this script.
            RESULTS.append({"step": "e2-obs-asserted-id", "result": "OBSERVED",
                            "evidence": {"hello_as": hum, "welcome_as": (w2 or {}).get("as")}})
            log("OBS  e2-obs-asserted-id %s" % json.dumps(RESULTS[-1]["evidence"]))
        except RuntimeError as e:  # a session door answers 401 view_door at the upgrade
            ev["ws_upgrade"] = str(e)[:200]
            ok = ok and "401" in str(e)
    ov = read_json("verify-outsider.json")
    if ov:
        ev["outsider_verify"] = {k: ov.get(k) for k in ("via", "mail_message_id", "hub_verify_api")}
    record("e2-non-member-refused", bool(ok), ev)

    # -- e3. CONTROL: the view door refuses anonymous and non-member readers ---------------------------------
    if door_on:
        st_o, _, out_o = http("GET", HUB + "/v1/view/threads", headers={"Cookie": cookie_o} if cookie_o else None)
        err_a = (out_anon or {}).get("error") if isinstance(out_anon, dict) else None
        err_o = (out_o or {}).get("error") if isinstance(out_o, dict) else None
        record("e3-view-door", st_anon == 401 and err_a == "view_door" and st_o == 401 and err_o == "view_door" and bool(cookie_o),
               {"anonymous": [st_anon, err_a], "non_member_session": [st_o, err_o]})
    else:
        RESULTS.append({"step": "e3-view-door", "result": "OBSERVED",
                        "evidence": {"door": "off", "anonymous_view_threads": st_anon}})
        log("OBS  e3-view-door door off: anonymous read -> %s (the 401 control needs a token or session door)" % st_anon)

    # -- i. CONTROLS (specs/026): the tenant comes from the identity, never from a
    # request parameter or a header; a box pinned here cannot act as another tenant
    if "active_tenant" in (sess or {}):
        base = view("/v1/view/roster")
        ids = sorted(b["box_id"] for b in base["boxes"])
        st_p, _, ro = http("GET", HUB + "/v1/view/roster?tenant=" + OTHER,
                           headers={"Cookie": cookie, "X-Spool-Tenant": OTHER})
        ids_p = sorted(b["box_id"] for b in (ro or {}).get("boxes", [])) if st_p == 200 else None
        rc_o, _, err_o = on(BOX_A, "hub-sync", tenant=OTHER, timeout=60)
        rc_s, _, _ = on(BOX_A, "hub-sync")  # the same box as itself (positive control)
        record("i-tenant-from-identity",
               sess.get("active_tenant") == tenant and ids_p == ids and rc_s == 0 and rc_o != 0,
               {"active_tenant": sess.get("active_tenant"), "tenants": sess.get("tenants"), "other": OTHER,
                "roster_naming_other": [st_p, ids_p == ids], "box_as_itself": rc_s,
                "box_naming_other": [rc_o, err_o[-160:]]})
    else:
        RESULTS.append({"step": "i-tenant-from-identity", "result": "OBSERVED",
                        "evidence": {"hub": "predates specs/026 (no active_tenant in the session)"}})

    # -- the viewer thread of SC-001 for the WUI screenshot ----------------------------------------------------
    RESULTS.append({"step": "info", "result": "INFO", "evidence": {"sc001_task_id": t_sc001, "task_thread": t_task,
                                                                   "dm_thread": t_dm, "hum": hum, "tenant": tenant}})
    write_results()
    return 0 if all(r["result"] in ("PASS", "OBSERVED", "INFO") for r in RESULTS) else 1


if __name__ == "__main__":
    os.umask(0o077)
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "auth-check":
        sys.exit(auth_check())
    if cmd == "run":
        try:
            sys.exit(run())
        except Exception as e:  # noqa: BLE001 - report, keep results so far
            record("aborted", False, {"error": str(e)[:400]})
            write_results()
            sys.exit(1)
    sys.exit("usage: m3-e2e.py auth-check | run")
