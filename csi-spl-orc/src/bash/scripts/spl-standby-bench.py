#!/usr/bin/env python3
"""spec 070 L1, the standby benchmark driver (called by do_spl_standby_bench).

argv: N EFFORT BUDGET_S CALL_TIMEOUT_S THINKING <vendor:model>...
env:  BENCH_CWD (the agents' empty cwd), BENCH_ROWS (JSONL out), BENCH_REPORT_PATH,
      BENCH_SHA, BENCH_STAMP, BENCH_CLAUDE_VER, BENCH_GROK_VER, BENCH_SKIPPED
Starts one headless standby per vendor:model (claude stream-json, grok ACP stdio),
a warm-up turn, then N call responses; stops each agent's process group.
exit: 0 ok, 2 a model has fewer than 20 good calls, 3 an agent survived its stop.
"""

import json, os, queue, signal, subprocess, sys, threading, time

N, EFFORT, BUDGET, TMO, THINKING = (
    int(sys.argv[1]),
    sys.argv[2],
    float(sys.argv[3]),
    float(sys.argv[4]),
    sys.argv[5],
)
PLAN = sys.argv[6:]
signal.signal(
    signal.SIGTERM, lambda *_: sys.exit(143)
)  # a stopped bench still stops its agents (finally)
CWD, ROWS, REPORT = (
    os.environ["BENCH_CWD"],
    os.environ["BENCH_ROWS"],
    os.environ["BENCH_REPORT_PATH"],
)

SYSTEM = (
    "You are a standby agent on a team message board. Answer the newest post in about 80 tokens, "
    "from the topic text only. If work is needed, say what is known now and what you will check. "
    "Never call a tool. Plain text, no preamble."
)
TAIL = "\n".join(
    [
        "[HUM-1] The nightly export to the archive bucket failed twice this week.",
        "[c-201] Both failures were at 02:10Z; the job retried once and gave up.",
        "[c-202] The disk on the build box was at 91% at the time.",
        "[HUM-1] Is that related, or a coincidence?",
        "[c-201] The export writes a 6 GB temp file before upload, so 91% is close to the limit.",
        "[c-203] The retention job that cleans the temp dir runs at 03:00Z, after the export.",
    ]
)
QUESTIONS = [
    "Should we move the retention job before the export?",
    "What is the quickest way to confirm the disk theory?",
    "Can the export stream instead of writing a temp file?",
    "Who owns the retention job?",
    "Will tonight's export fail again?",
    "Is 6 GB the usual size of the temp file?",
    "Should we raise the disk alert threshold?",
    "What did the retry change between the two attempts?",
    "Could a second job have filled the disk at 02:10Z?",
    "How much free space does the export need to be safe?",
    "Do we lose data when the export fails?",
    "Can we rerun the failed export by hand now?",
    "What should the post-mortem name as the cause?",
    "Is the archive bucket itself healthy?",
    "Would a bigger disk fix this for good?",
    "What is the next step, in one line?",
    "Should the job alert someone when it gives up?",
    "How long does a normal export take?",
    "Can the temp dir live on another volume?",
    "Is anything else scheduled near 02:00Z?",
    "What would you check first?",
    "Summarise the topic for someone who just joined.",
    "Does the retry back off, or retry at once?",
    "Is this safe to leave until Monday?",
]


def prompt_for(i):
    q = QUESTIONS[i % len(QUESTIONS)]
    return f"Topic so far:\n{TAIL}\n\nNew post (msg {i + 1:04d}) from HUM-1: {q}\nAnswer in about 80 tokens."


class Agent:
    """One headless agent process: lines in on stdin, NDJSON out on stdout, stamped on read."""

    def __init__(self, argv):
        self.p = subprocess.Popen(
            argv,
            cwd=CWD,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        self.q = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            self.q.put((time.monotonic(), line))
        self.q.put((time.monotonic(), None))

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def next(self, deadline):
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("turn timeout")
        try:
            t, line = self.q.get(timeout=left)
        except queue.Empty:
            raise TimeoutError("turn timeout")
        if line is None:
            raise EOFError("agent exited")
        try:
            return t, json.loads(line)
        except ValueError:
            return t, {}

    def stop(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(self.p.pid, sig)
            except ProcessLookupError:
                break
            try:
                self.p.wait(3)
                break
            except subprocess.TimeoutExpired:
                continue
        try:
            os.killpg(self.p.pid, 0)
            return False  # something in the group survived
        except ProcessLookupError:
            return True


class Claude:
    vendor = "claude"

    def __init__(self, model):
        self.model = model
        self.a = Agent(
            [
                "claude",
                "-p",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--model",
                model,
                "--effort",
                EFFORT,
                "--tools",
                "",
                "--strict-mcp-config",
                "--setting-sources",
                "",
                "--no-session-persistence",
                "--system-prompt",
                SYSTEM,
                "--settings",
                json.dumps({"alwaysThinkingEnabled": THINKING == "on"}),
            ]
        )

    def ready(self):
        pass

    def turn(self, text):
        r = {
            "first": None,
            "last": None,
            "end": None,
            "out_tokens": None,
            "model": None,
            "tools": 0,
            "chars": 0,
        }
        t0 = time.monotonic()
        dl = t0 + TMO
        self.a.send({"type": "user", "message": {"role": "user", "content": text}})
        while True:
            t, o = self.a.next(dl)
            if o.get("type") == "stream_event":
                ev = o.get("event", {})
                if ev.get("type") == "message_start":
                    r["model"] = ev.get("message", {}).get("model") or r["model"]
                elif (
                    ev.get("type") == "content_block_start"
                    and ev.get("content_block", {}).get("type") == "tool_use"
                ):
                    r["tools"] += 1
                elif (
                    ev.get("type") == "content_block_delta"
                    and ev.get("delta", {}).get("type") == "text_delta"
                ):
                    if r["first"] is None:
                        r["first"] = t - t0
                    r["last"] = t - t0
                    r["chars"] += len(ev["delta"].get("text", ""))
                elif ev.get("type") == "message_delta":
                    r["out_tokens"] = (ev.get("usage") or {}).get(
                        "output_tokens", r["out_tokens"]
                    )
            elif o.get("type") == "result":
                r["end"] = t - t0
                r["out_tokens"] = (o.get("usage") or {}).get(
                    "output_tokens", r["out_tokens"]
                )
                if o.get("is_error"):
                    r["error"] = str(o.get("result") or o.get("subtype"))[:200]
                return r


class Grok:
    vendor = "grok"

    def __init__(self, model):
        self.model = model
        self.id = 0
        self.a = Agent(
            [
                "grok",
                "agent",
                "--no-leader",
                "-m",
                model,
                "--reasoning-effort",
                EFFORT,
                "stdio",
            ]
        )

    def call(self, method, params, on=None):
        self.id += 1
        rid = self.id
        t0 = time.monotonic()
        dl = t0 + TMO
        self.a.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            t, o = self.a.next(dl)
            if (
                "method" in o and "id" in o
            ):  # the agent asks (a permission): refuse, no tool runs
                self.a.send(
                    {
                        "jsonrpc": "2.0",
                        "id": o["id"],
                        "result": {"outcome": {"outcome": "cancelled"}},
                    }
                )
                if on:
                    on(t - t0, {"tool": True})
                continue
            if o.get("id") == rid and ("result" in o or "error" in o):
                if "error" in o:
                    raise RuntimeError(f"{method}: {json.dumps(o['error'])[:200]}")
                return t - t0, o["result"]
            if on and o.get("method") == "session/update":
                on(t - t0, o["params"].get("update", {}))

    def ready(self):
        self.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
        _, res = self.call("session/new", {"cwd": CWD, "mcpServers": []})
        self.sid = res["sessionId"]
        self.call(
            "session/set_config_option",
            {"sessionId": self.sid, "configId": "model", "value": self.model},
        )
        self.call(
            "session/set_config_option",
            {"sessionId": self.sid, "configId": "reasoning_effort", "value": EFFORT},
        )

    def turn(self, text):
        r = {
            "first": None,
            "last": None,
            "end": None,
            "out_tokens": None,
            "model": None,
            "tools": 0,
            "chars": 0,
        }

        def on(dt, u):
            if u.get("tool") or u.get("sessionUpdate") == "tool_call":
                r["tools"] += 1
            elif (
                u.get("sessionUpdate") == "agent_message_chunk"
                and u.get("content", {}).get("type") == "text"
            ):
                if r["first"] is None:
                    r["first"] = dt
                r["last"] = dt
                r["chars"] += len(u["content"].get("text", ""))

        r["end"], res = self.call(
            "session/prompt",
            {"sessionId": self.sid, "prompt": [{"type": "text", "text": text}]},
            on,
        )
        meta = res.get("_meta") or {}
        r["model"], r["out_tokens"], r["reasoning_tokens"] = (
            meta.get("modelId"),
            meta.get("outputTokens"),
            meta.get("reasoningTokens"),
        )
        return r


def pct(xs, p):
    xs = sorted(xs)
    return xs[max(0, -(-len(xs) * p // 100) - 1)] if xs else None  # nearest rank


rows, summary, leaks = [], [], []
with open(ROWS, "w") as out:
    for entry in PLAN:
        vendor, model = entry.split(":", 1)
        s = {
            "vendor": vendor,
            "model": model,
            "reported": set(),
            "ok": [],
            "errors": 0,
            "tools": 0,
        }
        t0 = time.monotonic()
        agent = None
        try:
            agent = (Claude if vendor == "claude" else Grok)(model)
            agent.ready()
            w = agent.turn("Warm-up: reply with the single word ready.")
            s["start_s"], s["warm_s"] = (
                round(time.monotonic() - t0, 3),
                round(w["end"], 3),
            )
            for i in range(N):
                try:
                    r = agent.turn(prompt_for(i))
                except TimeoutError as e:
                    r = {"error": str(e)}
                r.update({"vendor": vendor, "requested": model, "i": i})
                out.write(json.dumps(r, sort_keys=True) + "\n")
                out.flush()
                rows.append(r)
                if r.get("error") or r.get("first") is None:
                    s["errors"] += 1
                else:
                    s["ok"].append(r)
                    s["reported"].add(r.get("model") or "?")
                s["tools"] += r.get("tools", 0)
                if "turn timeout" in str(r.get("error")):
                    break  # a stuck agent: stop this model
        except Exception as e:
            s["fatal"] = f"{type(e).__name__}: {e}"[:200]
        finally:
            if agent and not agent.a.stop():
                leaks.append(entry)
        summary.append(s)
        print(
            f"BENCH {entry} ok={len(s['ok'])} errors={s['errors']} {s.get('fatal', '')}".rstrip(),
            flush=True,
        )


def f3(x):
    return "-" if x is None else f"{x:.2f}"


def stat(s, k):
    xs = [r[k] for r in s["ok"] if r.get(k) is not None]
    return xs


lines = [
    "# 070 L1: the standby benchmark",
    "",
    "Spec 070 section 6.2 asks whether a warm standby agent's call response reaches its",
    f"first token in ~{BUDGET:g} s p95 (hop 4). This is the measurement (Q1, and Q11 if it does not fit).",
    "Written by `ENV=dev DRY_RUN=0 ./run -a do_spl_standby_bench` (csi-spl-orc); rerun it to refresh.",
    "",
    "| field | value |",
    "|---|---|",
    f"| run (UTC) | {os.environ['BENCH_STAMP']} |",
    f"| tree | `{os.environ['BENCH_SHA']}` |",
    "| env | dev, no workspace (an empty scratch dir), no hub, no spool: the model call alone |",
    f"| claude CLI | {os.environ['BENCH_CLAUDE_VER']} |",
    f"| grok CLI | {os.environ['BENCH_GROK_VER']} |",
    f"| n per model | {N} call responses after one warm-up turn, sent one at a time to ONE standby |",
    f"| effort | {EFFORT}; claude extended thinking {THINKING}; grok has no off switch (its lowest reasoning effort is used) |",
    f"| runs as | the agent user, never the human's; every agent stopped at the end: {'yes' if not leaks else 'NO: ' + ', '.join(leaks)} |",
    "",
    "## 1. Results (seconds from the stdin write)",
    "",
    "| vendor | model (reported) | n ok | errors | first token p50 | p95 | max | last token p50 | p95 | max | output tokens p50 | p95 | tool calls | start + warm-up |",
    "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
]
for s in summary:
    ft, lt, ot = stat(s, "first"), stat(s, "last"), stat(s, "out_tokens")
    s["p95"] = pct(ft, 95) if len(ft) >= 20 else None
    lines.append(
        f"| {s['vendor']} | {s['model']} ({', '.join(sorted(s['reported'])) or '-'}) | {len(s['ok'])} | {s['errors']} | "
        f"{f3(pct(ft, 50))} | **{f3(pct(ft, 95))}** | {f3(max(ft) if ft else None)} | {f3(pct(lt, 50))} | {f3(pct(lt, 95))} | "
        f"{f3(max(lt) if lt else None)} | {pct(ot, 50) if ot else '-'} | {pct(ot, 95) if ot else '-'} | {s['tools']} | "
        f"{f3(s.get('start_s'))} + {f3(s.get('warm_s'))} |"
    )
fatals = [
    f"- {s['vendor']}:{s['model']} stopped early: {s['fatal']}"
    for s in summary
    if s.get("fatal")
]
if fatals:
    lines += [""] + fatals
lines += [
    "",
    "## 2. Verdict per vendor",
    "",
    f"Fits = the first token p95 <= {BUDGET:g} s with n >= 20 and no tool call. The full call response",
    "(the last token) is shown against hops 4 + 5 together (1.5 s) for the record.",
    "",
    "| vendor | fastest model by first-token p95 | p95 | fits ~"
    + f"{BUDGET:g} s? | last token p95 <= 1.5 s? |",
    "|---|---|---:|---|---|",
]
verdicts = {}
for vendor in dict.fromkeys(s["vendor"] for s in summary):
    cands = [s for s in summary if s["vendor"] == vendor and s.get("p95") is not None]
    if not cands:
        lines.append(
            f"| {vendor} | - | - | **unmeasured** (fewer than 20 good calls) | - |"
        )
        verdicts[vendor] = None
        continue
    b = min(cands, key=lambda s: s["p95"])
    fits = b["p95"] <= BUDGET and b["tools"] == 0
    lt95 = pct(stat(b, "last"), 95)
    verdicts[vendor] = fits
    lines.append(
        f"| {vendor} | {b['model']} | {f3(b['p95'])} | **{'yes' if fits else 'no'}** | {'yes' if lt95 is not None and lt95 <= 1.5 else 'no'} ({f3(lt95)}) |"
    )
good = [v for v, ok in verdicts.items() if ok]
lines += [
    "",
    "## 3. What it answers",
    "",
    "- **Q1** (the standby model per vendor): the fastest model per vendor in section 2. "
    + (
        f"It fits for: {', '.join(good)}."
        if good
        else "No vendor's warm turn fits the budget on this run."
    ),
    "- **Q11**: "
    + (
        "not raised for " + ", ".join(good) + "."
        if good and len(good) == len(verdicts)
        else "raised for "
        + ", ".join(v for v, ok in verdicts.items() if not ok)
        + ": a warm standby turn does not reach the first token in budget; options (a), (b), (c) of section 6.2 are the owner's."
    ),
    "",
    "## 4. Method",
    "",
    "- claude: `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages "
    f'--model <m> --effort {EFFORT} --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence --system-prompt <short> '
    f"--settings '{{\"alwaysThinkingEnabled\":{str(THINKING == 'on').lower()}}}'`; "
    "one user message per stdin line. First / last token = the first / last `text_delta`; output tokens from the turn's usage (thinking included).",
    f"- grok: `grok agent --no-leader -m <m> --reasoning-effort {EFFORT} stdio` (ACP JSON-RPC), then `session/new` and "
    "`session/set_config_option` (model, reasoning_effort). First / last token = the first / last `agent_message_chunk`; "
    "output tokens from the prompt result (reasoning included). A permission request is answered `cancelled`, so no tool runs.",
    '- Each call: a fixed ~170-token synthetic topic tail + a new post, "about 80 tokens, no tool". The session keeps its history, '
    "so call 20 carries ~19 earlier turns: an upper bound on a fresh standby's context (W7).",
    "- Times are stamped on read, in the bench process, from the moment the line is written to the agent's stdin (hop 3 included).",
    "- p50 / p95 are nearest-rank. Raw rows: the state dir, `standby-bench/<run>.jsonl` (not committed).",
]
if os.environ.get("BENCH_SKIPPED", "").strip():
    lines += [
        "",
        "Skipped on this box: "
        + "; ".join(x for x in os.environ["BENCH_SKIPPED"].splitlines() if x)
        + ".",
    ]
lines += [
    "",
    f"<!-- last-edit: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} -->",
    "",
]
with open(REPORT, "w") as fh:
    fh.write("\n".join(lines))
print(f"REPORT {REPORT}")
print(f"ROWS {ROWS}")
sys.exit(3 if leaks else (0 if all(s.get("p95") is not None for s in summary) else 2))
