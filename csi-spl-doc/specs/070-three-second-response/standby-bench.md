# 070 L1: the standby benchmark

Spec 070 section 6.2 asks whether a warm standby agent's call response reaches its
first token in ~0.9 s p95 (hop 4). This is the measurement (Q1, and Q11 if it does not fit).
Written by `ENV=dev DRY_RUN=0 ./run -a do_spl_standby_bench` (csi-spl-orc); rerun it to refresh.

| field | value |
|---|---|
| run (UTC) | 20261014T034503Z |
| tree | `a409baab1528b6a6b956b444e98b7314388526b5+dirty` |
| env | dev, no workspace (an empty scratch dir), no hub, no spool: the model call alone |
| claude CLI | 2.1.292 (Claude Code) |
| grok CLI | grok 1.0.52 (0920c8169e27) |
| n per model | 20 call responses after one warm-up turn, sent one at a time to ONE standby |
| effort | low; claude extended thinking off; grok has no off switch (its lowest reasoning effort is used) |
| runs as | the agent user, never the human's; every agent stopped at the end: yes |

## 1. Results (seconds from the stdin write)

| vendor | model (reported) | n ok | errors | first token p50 | p95 | max | last token p50 | p95 | max | output tokens p50 | p95 | tool calls | start + warm-up |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| claude | haiku (-) | 0 | 20 | - | **-** | - | - | - | - | - | - | 0 | 0.54 + 0.54 |
| claude | sonnet (-) | 0 | 20 | - | **-** | - | - | - | - | - | - | 0 | 0.78 + 0.78 |
| grok | grok-4.7-build-fast (-) | 0 | 0 | - | **-** | - | - | - | - | - | - | 0 | - + - |
| grok | grok-4.7 (-) | 0 | 0 | - | **-** | - | - | - | - | - | - | 0 | - + - |

- grok:grok-4.7-build-fast stopped early: RuntimeError: session/prompt: {"code": -32603, "message": "Internal error", "data": {"message": "API error (status 402 Payment Required): Grok Build usage balance exhausted", "http_status": 402}}
- grok:grok-4.7 stopped early: RuntimeError: session/prompt: {"code": -32603, "message": "Internal error", "data": {"message": "API error (status 402 Payment Required): Grok Build usage balance exhausted", "http_status": 402}}

## 2. Verdict per vendor

Fits = the first token p95 <= 0.9 s with n >= 20 and no tool call. The full call response
(the last token) is shown against hops 4 + 5 together (1.5 s) for the record.

| vendor | fastest model by first-token p95 | p95 | fits ~0.9 s? | last token p95 <= 1.5 s? |
|---|---|---:|---|---|
| claude | - | - | **unmeasured** (fewer than 20 good calls) | - |
| grok | - | - | **unmeasured** (fewer than 20 good calls) | - |

## 3. What it answers

- **Q1** (the standby model per vendor): the fastest model per vendor in section 2. No vendor's warm turn fits the budget on this run.
- **Q11**: raised for claude, grok: a warm standby turn does not reach the first token in budget; options (a), (b), (c) of section 6.2 are the owner's.

## 4. Method

- claude: `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --model <m> --effort low --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence --system-prompt <short> --settings '{"alwaysThinkingEnabled":false}'`; one user message per stdin line. First / last token = the first / last `text_delta`; output tokens from the turn's usage (thinking included).
- grok: `grok agent --no-leader -m <m> --reasoning-effort low stdio` (ACP JSON-RPC), then `session/new` and `session/set_config_option` (model, reasoning_effort). First / last token = the first / last `agent_message_chunk`; output tokens from the prompt result (reasoning included). A permission request is answered `cancelled`, so no tool runs.
- Each call: a fixed ~170-token synthetic topic tail + a new post, "about 80 tokens, no tool". The session keeps its history, so call 20 carries ~19 earlier turns: an upper bound on a fresh standby's context (W7).
- Times are stamped on read, in the bench process, from the moment the line is written to the agent's stdin (hop 3 included).
- p50 / p95 are nearest-rank. Raw rows: the state dir, `standby-bench/<run>.jsonl` (not committed).

Skipped on this box: qwen: CLI present, no headless adapter in L1; gemini: CLI present, no headless adapter in L1; agy: CLI present, no headless adapter in L1; mistral (vibe): CLI present, no headless adapter in L1.

<!-- last-edit: 2026-10-14T03:45:10Z -->
