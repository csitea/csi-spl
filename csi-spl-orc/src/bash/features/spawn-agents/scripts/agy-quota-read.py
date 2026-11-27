#!/usr/bin/env python3
"""agy-quota-read.py: agy's quota buckets, read without a model call.

Spec 184 section 10.1 (SPL-6661, measured on agy 1.5.18). agy has no CLI
verb for its quota; its in-process language server answers
RetrieveUserQuotaSummary over loopback Connect HTTP+JSON once a session
exists. So this starts its OWN `agy acp` (never another seat's process),
with a CSRF token of its own in ANTIGRAVITY_SERVER_CSRF_TOKEN, sends the
ACP `initialize` and `session/new` (no prompt: n=3 probes made 0
streamGenerateContent calls), asks each loopback port the process listens
on, closes the session and ends the process.

Prints one line per bucket, TAB separated:
    <bucketId> <remainingFraction> <resetTime or ->
e.g. "gemini-weekly 0.089868 2026-12-03T07:01:52Z", "3p-5h 1.000000 -".
A bucket with no remainingFraction reads 0 (agy leaves the field out when
it is used up: proto3 oneof). Exit 0 with at least one line; exit 4 when
agy could not be read (no binary, no session, no port answered).

Usage: agy-quota-read.py [--agy PATH] [--timeout SECONDS]
"""

import argparse
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.request

RPC = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"


def _jsonrpc(proc, msg_id, method, params, deadline):
    proc.stdin.write(
        (
            json.dumps(
                {"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params}
            )
            + "\n"
        ).encode()
    )
    proc.stdin.flush()
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            return None
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("id") == msg_id:
            return obj
    return None


def _ports(pid):
    try:
        out = subprocess.run(
            ["ss", "-ltnpH"], capture_output=True, text=True, timeout=10
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [
        ln.split()[3].rsplit(":", 1)[1]
        for ln in out.splitlines()
        if f"pid={pid}," in ln and "127.0.0.1:" in ln
    ]


def _ask(port, token):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{RPC}",
        data=b"{}",
        headers={
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
            "x-codeium-csrf-token": token,
        },
    )
    try:
        return json.loads(urllib.request.urlopen(req, timeout=8).read())
    except (OSError, ValueError):
        return None


def buckets(summary):
    """The bucket lines of a RetrieveUserQuotaSummary answer."""
    rows = []
    for group in (summary or {}).get("response", {}).get("groups", []):
        for b in group.get("buckets", []):
            if b.get("bucketId"):
                rows.append(
                    (
                        b["bucketId"],
                        float(b.get("remainingFraction", 0)),
                        b.get("resetTime") or "-",
                    )
                )
    return rows


def read(agy, timeout):
    token = secrets.token_hex(16)
    env = dict(os.environ, ANTIGRAVITY_SERVER_CSRF_TOKEN=token)
    cwd = tempfile.mkdtemp(prefix="agy-quota-")
    deadline = time.time() + timeout
    try:
        proc = subprocess.Popen(
            [agy, "acp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            cwd=cwd,
        )
    except OSError:
        return None
    try:
        if not _jsonrpc(
            proc,
            1,
            "initialize",
            {"protocolVersion": 1, "clientCapabilities": {}},
            deadline,
        ):
            return None
        new = (
            _jsonrpc(proc, 2, "session/new", {"cwd": cwd, "mcpServers": []}, deadline)
            or {}
        )
        sid = (new.get("result") or {}).get("sessionId")
        if not sid:
            return None
        answer = None
        while answer is None and time.time() < deadline:
            for port in _ports(proc.pid):
                answer = _ask(port, token)
                if answer is not None:
                    break
            else:
                time.sleep(0.5)
        _jsonrpc(
            proc, 3, "session/close", {"sessionId": sid}, min(deadline, time.time() + 5)
        )
        return answer
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        try:
            os.rmdir(cwd)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--agy",
        default=os.environ.get("AGY_BIN") or os.path.expanduser("~/.local/bin/agy"),
    )
    ap.add_argument("--timeout", type=float, default=45)
    a = ap.parse_args()
    rows = buckets(read(a.agy, a.timeout))
    if not rows:
        print("agy-quota-read: no quota summary from " + a.agy, file=sys.stderr)
        return 4
    for bid, frac, reset in rows:
        print(f"{bid}\t{frac:.6f}\t{reset}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
