# 070 L1: the standby benchmark

Spec 070 section 6.2 asks whether a warm standby agent's call response reaches its
first token in ~0.9 s p95 (hop 4). This is the measurement (Q1, and Q11 if it does not fit).
Written by `ENV=dev DRY_RUN=0 ./run -a do_spl_standby_bench` (csi-spl-orc); rerun it to refresh.

| field | value |
|---|---|
| run (UTC) | 20261003T192939Z |
| tree | `febc0e46e8b5f3fa885aa7382f2375c339579aa2` |
| env | dev, no workspace (an empty scratch dir), no hub, no spool: the model call alone |
| claude CLI | 2.1.288 (Claude Code) |
| grok CLI | grok 1.0.46 (2765805b9442) [stable] |
| n per model | 20 call responses after one warm-up turn, sent one at a time to ONE standby |
| effort | low; claude extended thinking off; grok has no off switch (its lowest reasoning effort is used) |
| runs as | the agent user, never the human's; every agent stopped at the end: yes |

## 1. Results (seconds from the stdin write)

| vendor | model (reported) | n ok | errors | first token p50 | p95 | max | last token p50 | p95 | max | output tokens p50 | p95 | tool calls | start + warm-up |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| claude | haiku (claude-haiku-4-5-20251001) | 20 | 0 | 0.58 | **0.69** | 0.71 | 1.86 | 2.08 | 2.12 | 92 | 111 | 0 | 1.57 + 1.57 |
| claude | sonnet (claude-sonnet-5-5) | 20 | 0 | 0.78 | **0.92** | 1.03 | 2.31 | 2.62 | 2.78 | 141 | 164 | 0 | 2.18 + 2.17 |
| grok | grok-4.7-build-fast (grok-4.7-build-fast) | 20 | 0 | 2.20 | **4.07** | 5.00 | 3.22 | 4.23 | 5.00 | 160 | 274 | 0 | 2.53 + 2.08 |
| grok | grok-4.7 (grok-4.7) | 20 | 0 | 2.64 | **4.79** | 5.73 | 3.69 | 6.12 | 6.23 | 176 | 338 | 0 | 2.79 + 2.46 |

## 2. Verdict per vendor

Fits = the first token p95 <= 0.9 s with n >= 20 and no tool call. The full call response
(the last token) is shown against hops 4 + 5 together (1.5 s) for the record.

| vendor | fastest model by first-token p95 | p95 | fits ~0.9 s? | last token p95 <= 1.5 s? |
|---|---|---:|---|---|
| claude | haiku | 0.69 | **yes** | no (2.08) |
| grok | grok-4.7-build-fast | 4.07 | **no** | no (4.23) |

## 3. What it answers

- **Q1** (the standby model per vendor): the fastest model per vendor in section 2. It fits for: claude.
- **Q11**: raised for grok: a warm standby turn does not reach the first token in budget; options (a), (b), (c) of section 6.2 are the owner's.

## 4. Method

- claude: `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --model <m> --effort low --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence --system-prompt <short> --settings '{"alwaysThinkingEnabled":false}'`; one user message per stdin line. First / last token = the first / last `text_delta`; output tokens from the turn's usage (thinking included).
- grok: `grok agent --no-leader -m <m> --reasoning-effort low stdio` (ACP JSON-RPC), then `session/new` and `session/set_config_option` (model, reasoning_effort). First / last token = the first / last `agent_message_chunk`; output tokens from the prompt result (reasoning included). A permission request is answered `cancelled`, so no tool runs.
- Each call: a fixed ~170-token synthetic topic tail + a new post, "about 80 tokens, no tool". The session keeps its history, so call 20 carries ~19 earlier turns: an upper bound on a fresh standby's context (W7).
- Times are stamped on read, in the bench process, from the moment the line is written to the agent's stdin (hop 3 included).
- p50 / p95 are nearest-rank. Raw rows: the state dir, `standby-bench/<run>.jsonl` (not committed).

## 5. Reading (hand-written, this run)

- **First token fits for claude haiku** (0.69 s p95, n=20); sonnet sits on the line (0.92 s p95). Both grok models miss it by 3..4 s (4.07 / 4.79 s p95, n=20 each).
- **The full answer does not fit yet.** Haiku's last token is 2.08 s p95 at ~92 output tokens (p50): ~1.3 s of streaming against hop 5's 0.6 s. With section 6.1's other hops (0.40 + 0.16 + 0.01 + 0.40 + 0.30 s) the R1 sum is ~3.35 s p95: over 3 s by ~0.35 s. A tighter cap (~40 tokens) or Q11 (b), first words visible, closes it; the owner's call.
- **Thinking must be off.** An aborted earlier run (tree `70d01299`, haiku, effort low, thinking on by default) spent ~500 output tokens before the first text: ~5 s first token on the rows read (n=12 run, stopped). `--effort low` alone does not turn it off.
- **grok spends its time before the first text**: its turns report reasoning tokens even at the lowest effort, and the CLI sends its own ~16k+ token prompt (a probe turn reported 15.9k input tokens); no system-prompt override exists on `grok agent stdio` in 1.0.46 (*unchecked* beyond `--help`).
- **W1 holds for both**: start + warm-up is 3..5 s, paid once per standby, off the critical path.

<!-- last-edit: 2026-10-03T19:33:47Z -->
