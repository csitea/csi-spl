#!/usr/bin/env python3
"""spool-mcp-probe.py - drive an agent's spool MCP server the way its CLI does
(stdio JSON-RPC), and print ONE JSON line of what it measured.

  spool-mcp-probe.py --cmd <server argv...> --as <ID> [--control-as <OTHER>]
                     [--to <ID> --to-box <box> --n <N>] [--file]

Run as the AGENT user: the server command is started with MCP_BOT_AGENT_ID=<ID>
exactly as a CLI started by the box spawner would start it.

  1. initialize + tools/list: the five tool names, and whether from / as are
     optional (a seated server) or required (an older, unseated one)
  2. CONTROL (--control-as): spool_recv as=<OTHER> must be REFUSED. It never
     acks, so even an unseated server that answers only reads.
  3. spool_recv of the own seat (no args): ok, and how many are waiting
  4. latency (--n, needs --to/--to-box): N spool_send notes; each call's wall
     time from the request to the result. A result means the hub acked the
     frame (delivery sent / queued) or the local mailbox took it (local).
  5. --file: spool_put_file -> spool_send with the file_id -> spool_get_file
     into a new path; the bytes' sha256 must match
Exit 0 when every check held, 1 otherwise, 2 usage.
"""

import argparse
import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

TOOLS = [
    "spool_get_file",
    "spool_issue",
    "spool_put_file",
    "spool_recv",
    "spool_send",
    "spool_tail",
]  # spool_issue: specs/039


class Server:
    def __init__(self, argv, agent):
        env = dict(os.environ, MCP_BOT_AGENT_ID=agent)
        self.p = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
            bufsize=1,
        )
        self.n = 0

    def rpc(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self.n += 1
            msg["id"] = self.n
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        if notify:
            return None
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError(
                    "server closed: " + self.p.stderr.read().strip()[-400:]
                )
            r = json.loads(line)
            if r.get("id") == self.n:
                if "error" in r:
                    raise RuntimeError(json.dumps(r["error"]))
                return r["result"]

    def call(self, name, args):
        t0 = time.perf_counter()
        r = self.rpc("tools/call", {"name": name, "arguments": args})
        ms = (time.perf_counter() - t0) * 1000
        text = "".join(c.get("text", "") for c in r.get("content", []))
        return text, bool(r.get("isError")), ms

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", nargs="+", required=True)
    ap.add_argument("--as", dest="agent", required=True)
    ap.add_argument("--control-as", default="")
    ap.add_argument("--to", default="")
    ap.add_argument("--to-box", default="")
    ap.add_argument("--task", default="")
    ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--file", action="store_true")
    a = ap.parse_args()
    if (a.n or a.file) and not (a.to and a.to_box):
        ap.error("--n / --file need --to and --to-box")

    out = {"as": a.agent, "cmd": a.cmd, "ok": True, "checks": {}}

    def check(name, cond, detail=""):
        out["checks"][name] = {"ok": bool(cond), "detail": detail}
        out["ok"] = out["ok"] and bool(cond)

    t0 = time.perf_counter()
    s = Server(a.cmd, a.agent)
    try:
        s.rpc(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "spool-mcp-probe", "version": "1"},
            },
        )
        s.rpc("notifications/initialized", notify=True)
        out["start_ms"] = round((time.perf_counter() - t0) * 1000, 1)
        tools = {t["name"]: t for t in s.rpc("tools/list")["tools"]}
        check("tools", sorted(tools) == TOOLS, ",".join(sorted(tools)))
        req = {
            n: tools.get(n, {}).get("inputSchema", {}).get("required", [])
            for n in ("spool_send", "spool_recv")
        }
        check(
            "seated_schema",
            "from" not in req["spool_send"] and "as" not in req["spool_recv"],
            json.dumps(req),
        )

        if a.control_as:
            text, err, _ = s.call("spool_recv", {"as": a.control_as})
            check(
                "control_other_inbox_refused",
                err and "seated as " + a.agent in text,
                text[:200],
            )

        text, err, ms = s.call("spool_recv", {})
        try:
            waiting = len(json.loads(text))
        except ValueError:
            waiting = None
        check(
            "own_recv",
            not err and waiting is not None,
            text[:200] if err else "%d waiting, %.1f ms" % (waiting, ms),
        )

        task = a.task
        if a.n:
            lat, deliveries = [], []
            for k in range(1, a.n + 1):
                args = {
                    "to": a.to,
                    "to_box": a.to_box,
                    "kind": "note",
                    "body": "spool-mcp latency probe %d/%d from %s" % (k, a.n, a.agent),
                }
                if task:
                    args["task_id"] = task
                text, err, ms = s.call("spool_send", args)
                if err:
                    check("send_%d" % k, False, text[:200])
                    break
                r = json.loads(text)
                task = task or r["task_id"]
                lat.append(ms)
                deliveries.append(r["delivery"])
            if lat:
                srt = sorted(lat)
                out["send_ms"] = {
                    "n": len(lat),
                    "p50": round(statistics.median(lat), 1),
                    "min": round(srt[0], 1),
                    "max": round(srt[-1], 1),
                    "all": [round(x, 1) for x in lat],
                }
                out["deliveries"] = deliveries
                check(
                    "sends",
                    len(lat) == a.n
                    and all(d in ("sent", "queued", "local") for d in deliveries),
                    ",".join(deliveries),
                )

        if a.file:
            # both users must reach it: the box user reads the source and writes
            # the dest (the server runs as the box user), the agent reads the dest
            d = tempfile.mkdtemp(prefix="spool-mcp-probe-", dir="/var/tmp")
            os.chmod(d, 0o777)
            try:
                src = os.path.join(d, "probe.bin")
                data = (
                    os.urandom(4096) + ("probe %s %s" % (a.agent, time.time())).encode()
                )
                with open(src, "wb") as f:
                    f.write(data)
                os.chmod(src, 0o644)
                want = hashlib.sha256(data).hexdigest()
                text, err, put_ms = s.call("spool_put_file", {"path": src})
                fid = "" if err else json.loads(text).get("file_id", "")
                check("put_file", not err and fid == want, text[:200])
                if fid:
                    args = {
                        "to": a.to,
                        "to_box": a.to_box,
                        "kind": "note",
                        "file_ids": [fid],
                        "body": "spool-mcp file probe from %s" % a.agent,
                    }
                    if task:
                        args["task_id"] = task
                    text, err, send_ms = s.call("spool_send", args)
                    check("send_with_file", not err, text[:200])
                    dest = os.path.join(d, "back.bin")
                    text, err, get_ms = s.call(
                        "spool_get_file", {"file_id": fid, "dest": dest}
                    )
                    got = (
                        hashlib.sha256(open(dest, "rb").read()).hexdigest()
                        if not err and os.path.exists(dest)
                        else ""
                    )
                    check("get_file_sha256", got == want, text[:200])
                    out["file_ms"] = {
                        "put": round(put_ms, 1),
                        "send": round(send_ms, 1),
                        "get": round(get_ms, 1),
                    }
            finally:
                shutil.rmtree(d, ignore_errors=True)
        out["task_id"] = task
    except Exception as e:  # noqa: BLE001 - reported, never raised
        check("server", False, str(e)[:400])
    finally:
        s.close()
    print(json.dumps(out, sort_keys=True))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
