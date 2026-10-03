#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 070 L1, the standby benchmark: can a warm standby agent's
# @description call response reach its first token in ~0.9 s p95 (spec 070
# @description section 6.2, Q1, Q11)? Per vendor:model in BENCH_MODELS whose
# @description CLI is on this box (grok only when `grok models` says logged in):
# @description   1. starts ONE standby agent headless (W1) in an empty scratch dir
# @description      (no workspace): claude in print mode with stream-json in and
# @description      out, a replaced short system prompt and no tools; grok as
# @description      `grok agent stdio` (ACP), model + reasoning effort set on the
# @description      session. Both run as the agent user, never the human's
# @description   2. sends the warm-up turn (W2), not counted
# @description   3. sends BENCH_N (>= 20) call responses, one at a time: a short
# @description      synthetic topic tail + a new post, "about 80 tokens, no tool"
# @description   4. records per call: first token, last token, turn end (seconds
# @description      from the stdin write), output tokens, reported model, tools
# @description   5. stops the agent (its whole process group) before the next
# @description Writes the raw rows (JSONL) to the state dir and the report
# @description (p50 / p95 / max per vendor and model, n, the tree sha, the CLI
# @description versions, a verdict per vendor) to BENCH_REPORT. Model calls
# @description only: no hub, no spool, no cloud. Dry run unless DRY_RUN=0.
# @param ENV - required: dev (the bench is dev only, spec 070 section 10)
# @param BENCH_N (optional) - call responses per model, >= 20, default 20
# @param BENCH_MODELS (optional) - vendor:model list, default
# @param                           "claude:haiku claude:sonnet grok:grok-4.7-build-fast grok:grok-4.7"
# @param BENCH_EFFORT (optional) - low (default) | medium | high
# @param BENCH_THINKING (optional) - off (default: claude's extended thinking off, W6) | on
# @param BENCH_BUDGET_S (optional) - the first-token p95 budget, default 0.9 (hop 4)
# @param BENCH_CALL_TIMEOUT (optional) - seconds per turn, default 60
# @param BENCH_REPORT (optional) - default the spec 070 standby-bench.md in this tree
# @param SPOOL_AGENT_USER (optional) - the agent user; default from the box.env
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_standby_bench
#------------------------------------------------------------------------------
do_spl_standby_bench() {
  do_require_bin python3 || return 1
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev (the standby bench is dev only), got: '${ENV:-}'"; return 1; }
  local dry=1 d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 1; }
  [[ "$d" == 0 ]] && dry=0
  local n="${BENCH_N:-20}" effort="${BENCH_EFFORT:-low}" thinking="${BENCH_THINKING:-off}" budget="${BENCH_BUDGET_S:-0.9}" tmo="${BENCH_CALL_TIMEOUT:-60}"
  local models="${BENCH_MODELS:-claude:haiku claude:sonnet grok:grok-4.7-build-fast grok:grok-4.7}"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 20 && n <= 500 )) || { do_log "FATAL BENCH_N must be 20..500 (spec 070 L1: n >= 20), got: '$n'"; return 1; }
  [[ "$effort" =~ ^(low|medium|high)$ ]] || { do_log "FATAL BENCH_EFFORT must be low, medium or high, got: '$effort'"; return 1; }
  [[ "$thinking" =~ ^(on|off)$ ]] || { do_log "FATAL BENCH_THINKING must be on or off, got: '$thinking'"; return 1; }
  [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { do_log "FATAL BENCH_BUDGET_S must be seconds, got: '$budget'"; return 1; }
  [[ "$tmo" =~ ^[0-9]+$ ]] && (( tmo >= 1 )) || { do_log "FATAL BENCH_CALL_TIMEOUT must be whole seconds >= 1, got: '$tmo'"; return 1; }
  local m
  for m in $models; do
    [[ "$m" =~ ^(claude|grok):[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { do_log "FATAL BENCH_MODELS entry is not <claude|grok>:<model>: '$m'"; return 1; }
  done

  # the agents run as the agent user, never as the human's (spec 070 L1 brief)
  local agent_user="${SPOOL_AGENT_USER:-}" box_env="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  [[ -n "$agent_user" || ! -r "$box_env" ]] || agent_user="$(sed -n 's/^\(export \)\{0,1\}SPOOL_AGENT_USER=//p' "$box_env" | tail -1 | tr -d "\"'")"
  [[ -n "$agent_user" ]] || { do_log "FATAL the agent user is unknown: set SPOOL_AGENT_USER (or SPOOL_AGENT_USER= in $box_env)"; return 1; }
  [[ "$(id -un)" == "$agent_user" ]] || { do_log "FATAL run the bench as the agent user ($agent_user), not as $(id -un): its agents run as the user that starts them"; return 1; }

  # which vendors this box has: a CLI on PATH, and for grok a login
  local -a plan=() skipped=()
  local vendor have_claude=0 have_grok=0 login
  command -v claude >/dev/null 2>&1 && have_claude=1
  if command -v grok >/dev/null 2>&1; then
    # captured first: `grok models | grep -q` dies of SIGPIPE under pipefail
    login="$(timeout 30 grok models 2>&1)" || true
    [[ "${login,,}" == *"logged in"* ]] && have_grok=1 || skipped+=("grok: CLI present, not logged in ($(head -1 <<<"$login" | cut -c1-120))")
  fi
  (( have_claude )) || skipped+=("claude: no CLI on PATH")
  for m in $models; do
    vendor="${m%%:*}"
    if [[ "$vendor" == claude && $have_claude -eq 1 ]] || [[ "$vendor" == grok && $have_grok -eq 1 ]]; then plan+=("$m"); else skipped+=("$m: vendor not available"); fi
  done
  for vendor in qwen gemini agy codex; do
    command -v "$vendor" >/dev/null 2>&1 && skipped+=("$vendor: CLI present, no headless adapter in L1")
  done
  local s
  for s in "${skipped[@]}"; do do_log "INFO skip $s"; done
  (( ${#plan[@]} )) || { do_log "FATAL no vendor CLI available for BENCH_MODELS='$models'"; return 1; }

  local state="${SPL_STATE_DIR:-$HOME/.local/share/csi-spl/cloud/$ENV}/standby-bench"
  local report="${BENCH_REPORT:-$PROJ_PATH/../csi-spl-doc/specs/070-three-second-response/standby-bench.md}"
  if (( dry )); then
    do_log "INFO DRY_RUN would: start one standby per ${plan[*]} as $agent_user, a warm-up turn, then $n call responses each (effort $effort, thinking $thinking, budget ${budget}s p95 first token)"
    do_log "INFO DRY_RUN would write the rows under $state and the report to $report"
    do_log "OK DRY_RUN nothing was started. Re-run with DRY_RUN=0 to bench."
    return 0
  fi

  mkdir -p "$state" || return 1
  local stamp sha dirty="" cwd rc=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  # read-only git on this tree, which may belong to another user (a lane worktree)
  sha="$(git -c safe.directory='*' -C "$PROJ_PATH" rev-parse HEAD 2>/dev/null || echo unknown)"
  [[ -z "$(git -c safe.directory='*' -C "$PROJ_PATH/.." status --porcelain 2>/dev/null)" ]] || dirty="+dirty"
  cwd="$(mktemp -d "${TMPDIR:-/tmp}/spl-standby-bench.XXXXXX")" || return 1
  local claude_ver="-" grok_ver="-"
  (( have_claude )) && claude_ver="$(claude --version 2>/dev/null | head -1)"
  (( have_grok )) && grok_ver="$(grok --version 2>/dev/null | head -1)"
  BENCH_CWD="$cwd" BENCH_ROWS="$state/$stamp.jsonl" BENCH_REPORT_PATH="$report" BENCH_SHA="${sha}${dirty}" \
    BENCH_STAMP="$stamp" BENCH_CLAUDE_VER="$claude_ver" BENCH_GROK_VER="$grok_ver" BENCH_SKIPPED="$(printf '%s\n' "${skipped[@]}")" \
    python3 - "$n" "$effort" "$budget" "$tmo" "$thinking" "${plan[@]}" <<'EOF_PY' || rc=$?
import json, os, queue, signal, statistics, subprocess, sys, threading, time

N, EFFORT, BUDGET, TMO, THINKING = int(sys.argv[1]), sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
PLAN = sys.argv[6:]
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))   # a stopped bench still stops its agents (finally)
CWD, ROWS, REPORT = os.environ["BENCH_CWD"], os.environ["BENCH_ROWS"], os.environ["BENCH_REPORT_PATH"]

SYSTEM = ("You are a standby agent on a team message board. Answer the newest post in about 80 tokens, "
          "from the topic text only. If work is needed, say what is known now and what you will check. "
          "Never call a tool. Plain text, no preamble.")
TAIL = "\n".join([
    "[HUM-1] The nightly export to the archive bucket failed twice this week.",
    "[c-201] Both failures were at 02:10Z; the job retried once and gave up.",
    "[c-202] The disk on the build box was at 91% at the time.",
    "[HUM-1] Is that related, or a coincidence?",
    "[c-201] The export writes a 6 GB temp file before upload, so 91% is close to the limit.",
    "[c-203] The retention job that cleans the temp dir runs at 03:00Z, after the export.",
])
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
        self.p = subprocess.Popen(argv, cwd=CWD, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1, start_new_session=True)
        self.q = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
    def _read(self):
        for line in self.p.stdout:
            self.q.put((time.monotonic(), line))
        self.q.put((time.monotonic(), None))
    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n"); self.p.stdin.flush()
    def next(self, deadline):
        left = deadline - time.monotonic()
        if left <= 0: raise TimeoutError("turn timeout")
        try: t, line = self.q.get(timeout=left)
        except queue.Empty: raise TimeoutError("turn timeout")
        if line is None: raise EOFError("agent exited")
        try: return t, json.loads(line)
        except ValueError: return t, {}
    def stop(self):
        try: self.p.stdin.close()
        except Exception: pass
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try: os.killpg(self.p.pid, sig)
            except ProcessLookupError: break
            try: self.p.wait(3); break
            except subprocess.TimeoutExpired: continue
        try: os.killpg(self.p.pid, 0); return False      # something in the group survived
        except ProcessLookupError: return True

class Claude:
    vendor = "claude"
    def __init__(self, model):
        self.model = model
        self.a = Agent(["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--include-partial-messages", "--model", model, "--effort", EFFORT, "--tools", "",
                        "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
                        "--system-prompt", SYSTEM, "--settings", json.dumps({"alwaysThinkingEnabled": THINKING == "on"})])
    def ready(self): pass
    def turn(self, text):
        r = {"first": None, "last": None, "end": None, "out_tokens": None, "model": None, "tools": 0, "chars": 0}
        t0 = time.monotonic(); dl = t0 + TMO
        self.a.send({"type": "user", "message": {"role": "user", "content": text}})
        while True:
            t, o = self.a.next(dl)
            if o.get("type") == "stream_event":
                ev = o.get("event", {})
                if ev.get("type") == "message_start":
                    r["model"] = ev.get("message", {}).get("model") or r["model"]
                elif ev.get("type") == "content_block_start" and ev.get("content_block", {}).get("type") == "tool_use":
                    r["tools"] += 1
                elif ev.get("type") == "content_block_delta" and ev.get("delta", {}).get("type") == "text_delta":
                    if r["first"] is None: r["first"] = t - t0
                    r["last"] = t - t0; r["chars"] += len(ev["delta"].get("text", ""))
                elif ev.get("type") == "message_delta":
                    r["out_tokens"] = (ev.get("usage") or {}).get("output_tokens", r["out_tokens"])
            elif o.get("type") == "result":
                r["end"] = t - t0
                r["out_tokens"] = (o.get("usage") or {}).get("output_tokens", r["out_tokens"])
                if o.get("is_error"): r["error"] = str(o.get("result") or o.get("subtype"))[:200]
                return r

class Grok:
    vendor = "grok"
    def __init__(self, model):
        self.model = model; self.id = 0
        self.a = Agent(["grok", "agent", "--no-leader", "-m", model, "--reasoning-effort", EFFORT, "stdio"])
    def call(self, method, params, on=None):
        self.id += 1; rid = self.id; t0 = time.monotonic(); dl = t0 + TMO
        self.a.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            t, o = self.a.next(dl)
            if "method" in o and "id" in o:        # the agent asks (a permission): refuse, no tool runs
                self.a.send({"jsonrpc": "2.0", "id": o["id"], "result": {"outcome": {"outcome": "cancelled"}}})
                if on: on(t - t0, {"tool": True})
                continue
            if o.get("id") == rid and ("result" in o or "error" in o):
                if "error" in o: raise RuntimeError(f"{method}: {json.dumps(o['error'])[:200]}")
                return t - t0, o["result"]
            if on and o.get("method") == "session/update": on(t - t0, o["params"].get("update", {}))
    def ready(self):
        self.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
        _, res = self.call("session/new", {"cwd": CWD, "mcpServers": []})
        self.sid = res["sessionId"]
        self.call("session/set_config_option", {"sessionId": self.sid, "configId": "model", "value": self.model})
        self.call("session/set_config_option", {"sessionId": self.sid, "configId": "reasoning_effort", "value": EFFORT})
    def turn(self, text):
        r = {"first": None, "last": None, "end": None, "out_tokens": None, "model": None, "tools": 0, "chars": 0}
        def on(dt, u):
            if u.get("tool") or u.get("sessionUpdate") == "tool_call": r["tools"] += 1
            elif u.get("sessionUpdate") == "agent_message_chunk" and u.get("content", {}).get("type") == "text":
                if r["first"] is None: r["first"] = dt
                r["last"] = dt; r["chars"] += len(u["content"].get("text", ""))
        r["end"], res = self.call("session/prompt", {"sessionId": self.sid, "prompt": [{"type": "text", "text": text}]}, on)
        meta = res.get("_meta") or {}
        r["model"], r["out_tokens"], r["reasoning_tokens"] = meta.get("modelId"), meta.get("outputTokens"), meta.get("reasoningTokens")
        return r

def pct(xs, p):
    xs = sorted(xs)
    return xs[max(0, -(-len(xs) * p // 100) - 1)] if xs else None   # nearest rank

rows, summary, leaks = [], [], []
with open(ROWS, "w") as out:
    for entry in PLAN:
        vendor, model = entry.split(":", 1)
        s = {"vendor": vendor, "model": model, "reported": set(), "ok": [], "errors": 0, "tools": 0}
        t0 = time.monotonic(); agent = None
        try:
            agent = (Claude if vendor == "claude" else Grok)(model)
            agent.ready()
            w = agent.turn("Warm-up: reply with the single word ready.")
            s["start_s"], s["warm_s"] = round(time.monotonic() - t0, 3), round(w["end"], 3)
            for i in range(N):
                try: r = agent.turn(prompt_for(i))
                except TimeoutError as e:
                    r = {"error": str(e)}
                r.update({"vendor": vendor, "requested": model, "i": i})
                out.write(json.dumps(r, sort_keys=True) + "\n"); out.flush(); rows.append(r)
                if r.get("error") or r.get("first") is None: s["errors"] += 1
                else: s["ok"].append(r); s["reported"].add(r.get("model") or "?")
                s["tools"] += r.get("tools", 0)
                if "turn timeout" in str(r.get("error")): break  # a stuck agent: stop this model
        except Exception as e:
            s["fatal"] = f"{type(e).__name__}: {e}"[:200]
        finally:
            if agent and not agent.a.stop(): leaks.append(entry)
        summary.append(s)
        print(f"BENCH {entry} ok={len(s['ok'])} errors={s['errors']} {s.get('fatal', '')}".rstrip(), flush=True)

def f3(x): return "-" if x is None else f"{x:.2f}"
def stat(s, k): xs = [r[k] for r in s["ok"] if r.get(k) is not None]; return xs
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
    f"| env | dev, no workspace (an empty scratch dir), no hub, no spool: the model call alone |",
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
    lines.append(f"| {s['vendor']} | {s['model']} ({', '.join(sorted(s['reported'])) or '-'}) | {len(s['ok'])} | {s['errors']} | "
                 f"{f3(pct(ft, 50))} | **{f3(pct(ft, 95))}** | {f3(max(ft) if ft else None)} | {f3(pct(lt, 50))} | {f3(pct(lt, 95))} | "
                 f"{f3(max(lt) if lt else None)} | {pct(ot, 50) if ot else '-'} | {pct(ot, 95) if ot else '-'} | {s['tools']} | "
                 f"{f3(s.get('start_s'))} + {f3(s.get('warm_s'))} |")
fatals = [f"- {s['vendor']}:{s['model']} stopped early: {s['fatal']}" for s in summary if s.get("fatal")]
if fatals: lines += [""] + fatals
lines += ["", "## 2. Verdict per vendor", "",
          f"Fits = the first token p95 <= {BUDGET:g} s with n >= 20 and no tool call. The full call response",
          "(the last token) is shown against hops 4 + 5 together (1.5 s) for the record.", "",
          "| vendor | fastest model by first-token p95 | p95 | fits ~" + f"{BUDGET:g} s? | last token p95 <= 1.5 s? |", "|---|---|---:|---|---|"]
verdicts = {}
for vendor in dict.fromkeys(s["vendor"] for s in summary):
    cands = [s for s in summary if s["vendor"] == vendor and s.get("p95") is not None]
    if not cands:
        lines.append(f"| {vendor} | - | - | **unmeasured** (fewer than 20 good calls) | - |"); verdicts[vendor] = None; continue
    b = min(cands, key=lambda s: s["p95"])
    fits = b["p95"] <= BUDGET and b["tools"] == 0
    lt95 = pct(stat(b, "last"), 95)
    verdicts[vendor] = fits
    lines.append(f"| {vendor} | {b['model']} | {f3(b['p95'])} | **{'yes' if fits else 'no'}** | {'yes' if lt95 is not None and lt95 <= 1.5 else 'no'} ({f3(lt95)}) |")
good = [v for v, ok in verdicts.items() if ok]
lines += ["", "## 3. What it answers", "",
          "- **Q1** (the standby model per vendor): the fastest model per vendor in section 2. " +
          (f"It fits for: {', '.join(good)}." if good else "No vendor's warm turn fits the budget on this run."),
          "- **Q11**: " + ("not raised for " + ", ".join(good) + "." if good and len(good) == len(verdicts) else
                          "raised for " + ", ".join(v for v, ok in verdicts.items() if not ok) +
                          ": a warm standby turn does not reach the first token in budget; options (a), (b), (c) of section 6.2 are the owner's."),
          "", "## 4. Method", "",
          "- claude: `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages "
          f"--model <m> --effort {EFFORT} --tools \"\" --strict-mcp-config --setting-sources \"\" --no-session-persistence --system-prompt <short> "
          f"--settings '{{\"alwaysThinkingEnabled\":{str(THINKING == 'on').lower()}}}'`; "
          "one user message per stdin line. First / last token = the first / last `text_delta`; output tokens from the turn's usage (thinking included).",
          f"- grok: `grok agent --no-leader -m <m> --reasoning-effort {EFFORT} stdio` (ACP JSON-RPC), then `session/new` and "
          "`session/set_config_option` (model, reasoning_effort). First / last token = the first / last `agent_message_chunk`; "
          "output tokens from the prompt result (reasoning included). A permission request is answered `cancelled`, so no tool runs.",
          "- Each call: a fixed ~170-token synthetic topic tail + a new post, \"about 80 tokens, no tool\". The session keeps its history, "
          "so call 20 carries ~19 earlier turns: an upper bound on a fresh standby's context (W7).",
          "- Times are stamped on read, in the bench process, from the moment the line is written to the agent's stdin (hop 3 included).",
          "- p50 / p95 are nearest-rank. Raw rows: the state dir, `standby-bench/<run>.jsonl` (not committed).",
          ]
if os.environ.get("BENCH_SKIPPED", "").strip():
    lines += ["", "Skipped on this box: " + "; ".join(x for x in os.environ["BENCH_SKIPPED"].splitlines() if x) + "."]
lines += ["", f"<!-- last-edit: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} -->", ""]
with open(REPORT, "w") as fh: fh.write("\n".join(lines))
print(f"REPORT {REPORT}"); print(f"ROWS {ROWS}")
sys.exit(3 if leaks else (0 if all(s.get("p95") is not None for s in summary) else 2))
EOF_PY
  rmdir "$cwd" 2>/dev/null || rm -rf "$cwd"
  case $rc in
    0) do_log "OK the bench ran: report $report" ;;
    2) do_log "FAIL a model has fewer than 20 good calls: see $report"; return 1 ;;
    3) do_log "FATAL an agent process survived its stop: check ps"; return 1 ;;
    *) do_log "FATAL the bench driver failed (rc=$rc)"; return 1 ;;
  esac
}
