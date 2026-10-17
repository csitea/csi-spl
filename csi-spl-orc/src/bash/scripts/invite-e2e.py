#!/usr/bin/env python3
"""Invite -> mail -> sign-in -> first message, end to end against a deployed
hub (t1 afa8a4fb, R7 of the issue triage 1457bb6f). Called by
`./run -a do_spl_invite_e2e` (csi-spl-orc), which creates the invite through
the hub's operator route, writes its answer to <state>/invite.json, stages the
mailbox password in a 0600 file and, when a tenant root key is in hand, the
spool CLI for the agent leg.

Steps, each printed `PASS|FAIL|SKIPPED <step> <evidence>` (results.json in the
state dir), as m3-e2e.py:
  1-invite-mailed     the hub stored the invite and its relay took the mail
  2-invite-mail       the invite mail reached the mailbox; its sign-in link
                      names the tenant and carries the invitee as login_hint
  2-plus-delivered    the mail was DELIVERED to the plus-address: a received
                      copy carries Delivered-To, or Gmail filed it under \\Inbox
                      (dev's relay IS the mailbox, so Gmail keeps ONE copy of a
                      self-sent mail, labelled \\Inbox + \\Sent, and no
                      Delivered-To; a copy that was only sent is \\Sent alone)
  3-link-page         the link's page serves (200, text/html)
  4-sign-in           the fresh address signs up (verify mail or debug token)
                      and signs in WITH the tenant: the invite admits it
  5-bound             the session names the tenant; its viewer API opens
  6-agent-answers     the invitee's first message, a task to a box agent, is
                      delivered box-wui signed and the agent's result reaches
                      the invitee's WUI socket. SKIPPED (not PASS) when no
                      tenant root key is in hand: the agent box cannot be pinned

Stdlib only; reuses m3-e2e.py (HTTP, native sign-in, WebSocket, box rig).
Secrets (password files, cookies, tokens) never reach stdout or results.json.

Usage: invite-e2e.py run
Env:   the M3_* names of m3-e2e.py (M3_HUB_URL, M3_AUTH_URL, M3_TENANT,
       M3_STATE, M3_HUMAN_EMAIL = the invitee, M3_IMAP_USER, M3_IMAP_PASS_FILE,
       M3_IMAP_HOST, M3_SPOOL and M3_ROOT_KEY for the agent leg), plus
       INVITE_E2E_MAILDIR  (optional) a directory of .eml files read INSTEAD of
                           IMAP: the stubbed mailbox of the offline tests
       INVITE_E2E_TIMEOUT  seconds to wait for the invite mail (default 240)
"""

import email as emaillib
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.parse
import uuid

_spec = importlib.util.spec_from_file_location(
    "m3e2e", os.path.join(os.path.dirname(os.path.abspath(__file__)), "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)

BOX, AGENT = "box-inv-e2e", "EIV-1"
MAILDIR = os.environ.get("INVITE_E2E_MAILDIR", "")
TIMEOUT = int(os.environ.get("INVITE_E2E_TIMEOUT", "240"))
record, log, http = m3.record, m3.log, m3.http


def skip(step, evidence):
    m3.RESULTS.append({"step": step, "result": "SKIPPED", "evidence": evidence})
    log("SKIPPED %s %s" % (step, json.dumps(evidence, sort_keys=True)))


# ---- the invite mail ------------------------------------------------------------------


def invite_link(raw, rcpt, tenant):
    """(message, link facts) of an invite mail to rcpt, or None. A mail counts
    when it is addressed to rcpt and a text part carries an
    <app>[/<locale>]/login?... link whose tenant is ours."""
    msg = emaillib.message_from_bytes(raw)
    to_header = (msg.get("To") or "").lower()
    if rcpt.lower() not in to_header:
        return None
    for part in msg.walk():
        if part.get_content_maintype() != "text":
            continue
        text = (part.get_payload(decode=True) or b"").decode("utf-8", "replace")
        for word in text.replace('"', " ").replace("<", " ").replace(">", " ").split():
            if not word.startswith("http") or "/login?" not in word:
                continue
            link = word.replace("&amp;", "&")
            u = urllib.parse.urlparse(link)
            q = urllib.parse.parse_qs(u.query)
            if q.get("tenant", [""])[0] != tenant:
                continue
            login_hint = urllib.parse.unquote(q.get("login_hint", [""])[0])
            return msg, {
                "link": link,
                "link_page": "%s://%s%s" % (u.scheme, u.netloc, u.path),
                "link_tenant": q.get("tenant", [""])[0],
                "link_redirect": q.get("redirect", [""])[0],
                "link_login_hint_is_invitee": login_hint.lower() == rcpt.lower(),
            }
    return None


def stub_labels(path):
    """The stub mailbox's Gmail labels of <n>.eml: <n>.labels, one per word."""
    try:
        with open(path[: -len(".eml")] + ".labels") as f:
            return f.read().split()
    except OSError:
        return []


def mailbox_raws(rcpt, seen):
    """(key, raw, gmail labels) of the mails to rcpt not in seen: the stub
    dir or IMAP (X-GM-LABELS, Gmail's IMAP extension)."""
    if MAILDIR:
        out = []
        for n in os.listdir(MAILDIR):
            if n.endswith(".eml") and n not in seen:
                p = os.path.join(MAILDIR, n)
                with open(p, "rb") as f:
                    raw = f.read()
                    msg = emaillib.message_from_bytes(raw)
                    to_header = msg.get("To") or ""
                    # Parse the To header to extract email addresses
                    to_addrs = []
                    if to_header:
                        for addr in emaillib.utils.getaddresses([to_header]):
                            to_addrs.append(addr[1].lower())
                    # Debug: print the To header and parsed addresses
                    print(f"DEBUG: To header: {to_header}", file=sys.stderr)
                    print(f"DEBUG: Parsed addresses: {to_addrs}", file=sys.stderr)
                    print(f"DEBUG: Looking for: {rcpt.lower()}", file=sys.stderr)
                    if rcpt.lower() in to_addrs:
                        out.append((n, raw, stub_labels(p)))
                        seen.add(n)
        return out
    m = m3.imap_open()
    try:
        _, data = m.uid("SEARCH", None, 'TO "%s"' % rcpt.lower())
        out = []
        for uid in reversed(data[0].split()):
            if uid in seen:
                continue
            _, fetched = m.uid("FETCH", uid, "(X-GM-LABELS RFC822)")
            meta = fetched[0][0].decode("utf-8", "replace")
            hit = re.search(r"X-GM-LABELS \(([^)]*)\)", meta)
            labels = (
                [x.strip('"').replace("\\\\", "\\") for x in hit.group(1).split()]
                if hit
                else []
            )
            out.append((uid, fetched[0][1], labels))
        return out
    finally:
        m.logout()


def wait_invite_mail(rcpt, tenant, message_id):
    """Poll for the invite mail. The hub's own Message-ID wins when it is
    known; otherwise the first mail with our tenant's sign-in link."""
    t0, seen = time.time(), set()
    while True:
        for key, raw, labels in mailbox_raws(rcpt, seen):
            seen.add(key)
            hit = invite_link(raw, rcpt, tenant)
            if not hit:
                continue
            msg, ev = hit
            msg_id = msg.get("Message-ID")
            print(f"DEBUG: Email Message-ID: {msg_id}", file=sys.stderr)
            print(f"DEBUG: Expected Message-ID: {message_id}", file=sys.stderr)
            if message_id and msg_id != message_id:
                continue
            ev.update(
                {
                    "mail_from": msg.get("From"),
                    "mail_subject": msg.get("Subject"),
                    "mail_message_id": msg.get("Message-ID"),
                    "mail_after_s": round(time.time() - t0, 1),
                    "delivered_to": msg.get_all("Delivered-To") or [],
                    "gmail_labels": labels,
                }
            )
            return ev
        if time.time() >= t0 + TIMEOUT:
            return None
        time.sleep(1 if MAILDIR else 5)


# ---- the agent leg: one box agent answers the invitee's first message ------------------


def agent_answers(hum, cookie, stamp):
    pub = m3.pin_box(BOX, AGENT)
    wui = m3.view("/v1/wui/pubkey")
    m3.must(
        BOX,
        "hub-pin",
        "--box",
        m3.WUI,
        "--pubkey",
        wui["pubkey"],
        "--root-key",
        m3.ROOT_KEY,
        "--force",
    )
    m3.must(BOX, "hub-sync")
    ws = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    run_b = None
    try:
        ws.send({"type": "hello", "as": "invite-e2e"})
        ws.wait(lambda f: f.get("type") in ("welcome", "error"))
        ws.send({"type": "subscribe", "channel": "lobby"})
        ws.wait(lambda f: f.get("type") == "subscribed")
        run_b = subprocess.Popen(
            [m3.SPOOL, "hub-run"],
            env=m3.box_env(BOX),
            stdout=subprocess.DEVNULL,
            stderr=open(os.path.join(m3.STATE, "hub-run.log"), "a"),
            start_new_session=True,
        )
        online = ws.wait(
            lambda f: (
                f.get("type") == "presence"
                and f.get("peer") == "%s@%s" % (AGENT, BOX)
                and f.get("status") == "online"
            ),
            30,
        )
        task_id = str(uuid.uuid4())
        ws.send({"type": "subscribe", "task_id": task_id})
        ws.wait(lambda f: f.get("type") == "subscribed" and f.get("task_id") == task_id)
        frame = {
            "type": "send",
            "task_id": task_id,
            "channel": "lobby",
            "kind": "task",
            "to": AGENT,
            "msg_id": str(uuid.uuid4()),
            "body": "invite-e2e first message " + stamp,
        }
        ws.send(frame)
        ack = ws.wait(
            lambda f: (
                f.get("msg_id") == frame["msg_id"] and f.get("type") in ("ack", "error")
            )
        )
        got = m3.wait_inbox(BOX, AGENT, lambda m: m.get("msg_id") == frame["msg_id"])
        rc, _, err = m3.on(
            BOX,
            "send",
            "--from",
            AGENT,
            "--to",
            hum,
            "--task",
            task_id,
            "--kind",
            "result",
            "--to-box",
            m3.WUI,
            "--body",
            "invite-e2e answer from %s" % AGENT,
        )
        res = ws.wait(
            lambda f: (
                f.get("type") == "message"
                and f.get("task_id") == task_id
                and ((f.get("env") or {}).get("msg") or {}).get("kind") == "result"
            ),
            20,
        )
        return record(
            "6-agent-answers",
            bool(ack)
            and ack.get("type") == "ack"
            and got is not None
            and got.get("from") == hum
            and rc == 0
            and res is not None,
            {
                "box": BOX,
                "box_pubkey": pub,
                "agent_online": online is not None,
                "ack": ack,
                "agent_inbox_from": (got or {}).get("from"),
                "answer_send_exit": rc,
                "answer_err": err[:200] if rc else "",
                "answer_in_wui": res is not None,
                "task_id": task_id,
            },
        )
    finally:
        ws.close()
        if run_b:
            try:
                os.killpg(run_b.pid, signal.SIGTERM)
            except OSError:
                pass


# ---- the run ------------------------------------------------------------------------------


def done(rc):
    m3.write_results()
    return rc


def invite_step(tenant):
    """Step 1 from the hub's answer the wrapper saved. Returns its mail part or None."""
    inv = m3.read_json("invite.json") or {}
    body = inv.get("body") if isinstance(inv.get("body"), dict) else {}
    mail = body.get("mail") if isinstance(body.get("mail"), dict) else {}
    ok = record(
        "1-invite-mailed",
        inv.get("status") == 201
        and body.get("tenant_id") == tenant
        and mail.get("outcome") == "sent",
        {
            "status": inv.get("status"),
            "role": body.get("role"),
            "mail_outcome": mail.get("outcome"),
            "mail_message_id": mail.get("message_id"),
            "expires_at": body.get("expires_at"),
        },
    )
    return mail if ok else None


def mail_steps(rcpt, tenant, message_id):
    """Steps 2 and 3. Returns the link facts, or None when no mail came."""
    mv = wait_invite_mail(rcpt, tenant, message_id)
    ev = mv or {"mail": "no invite mail to %s within %ds" % (rcpt, TIMEOUT)}
    if not record(
        "2-invite-mail",
        bool(mv) and mv["link_tenant"] == tenant and mv["link_login_hint_is_invitee"],
        {k: v for k, v in ev.items() if k != "link"},
    ):
        return None
    dt = [d.strip().lower() for d in mv["delivered_to"]]
    record(
        "2-plus-delivered",
        rcpt.lower() in dt or "\\Inbox" in mv["gmail_labels"],
        {
            "delivered_to": mv["delivered_to"],
            "gmail_labels": mv["gmail_labels"],
            "invitee": rcpt,
        },
    )
    st, hdrs, _ = http("GET", mv["link"])
    ctype = (hdrs.get("Content-Type") or "") if hdrs else ""
    record(
        "3-link-page",
        st == 200 and ctype.startswith("text/html"),
        {"page": mv["link_page"], "status": st, "type": ctype.split(";")[0]},
    )
    return mv


def bind_steps(rcpt, tenant):
    """Steps 4 and 5. Returns (hum, cookie), or None."""
    st, out, cookie = m3.native_login(rcpt, tenant, "invitee")
    out = out if isinstance(out, dict) else {}
    if not record(
        "4-sign-in",
        st == 200 and bool(cookie),
        {
            "login_status": st,
            "hum": out.get("hum"),
            "error": out.get("error"),
            "verify": m3.read_json("verify-invitee.json"),
        },
    ):
        return None
    m3.write_secret("cookie-human", cookie)
    st, _, sess = http(
        "GET", m3.AUTH + "/api/v1/auth/session", headers={"Cookie": cookie}
    )
    sess = sess if st == 200 and isinstance(sess, dict) else {}
    hum = sess.get("hum", "")
    st_view, _, _ = http("GET", m3.HUB + "/v1/view/topics", headers={"Cookie": cookie})
    m3.write_json("bound.json", {"hum": hum, "tenant": tenant})
    if not record(
        "5-bound",
        hum.startswith("HUM-") and sess.get("t") == tenant and st_view == 200,
        {
            "session_status": st,
            "hum": hum,
            "t": sess.get("t"),
            "view_topics_status": st_view,
        },
    ):
        return None
    return hum, cookie


def run():
    m3.need("M3_HUB_URL", "M3_AUTH_URL", "M3_STATE", "M3_HUMAN_EMAIL")
    if not MAILDIR:
        m3.need("M3_IMAP_USER", "M3_IMAP_PASS_FILE")
    tenant, rcpt = m3.TENANT, m3.HUMAN
    _, _, ver = http("GET", m3.HUB + "/version")
    m3.RESULTS.append(
        {
            "step": "hosts",
            "result": "INFO",
            "evidence": {
                "hub": m3.HUB,
                "auth": m3.AUTH,
                "tenant": tenant,
                "invitee": rcpt,
                "version": ver,
                "mailbox": "stub" if MAILDIR else "imap",
            },
        }
    )
    mail = invite_step(tenant)
    if mail is None or mail_steps(rcpt, tenant, mail.get("message_id", "")) is None:
        return done(1)
    bound = bind_steps(rcpt, tenant)
    if bound is None:
        return done(1)
    if m3.ROOT_KEY and os.path.exists(m3.ROOT_KEY) and m3.SPOOL:
        agent_answers(
            bound[0], bound[1], time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        )
    else:
        skip(
            "6-agent-answers",
            {"why": "no tenant root key in hand: the agent box cannot be pinned"},
        )
    return done(
        0 if all(r["result"] in ("PASS", "INFO", "SKIPPED") for r in m3.RESULTS) else 1
    )


if __name__ == "__main__":
    os.umask(0o077)
    if (sys.argv[1:] or [""])[0] != "run":
        sys.exit("usage: invite-e2e.py run")
    try:
        sys.exit(run())
    except Exception as e:  # noqa: BLE001 - report, keep results so far
        record("aborted", False, {"error": str(e)[:400]})
        m3.write_results()
        sys.exit(1)
