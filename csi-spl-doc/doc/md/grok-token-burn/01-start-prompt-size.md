# Grok token burn 1/6: the start-of-session prompt per vendor

SPL-2214, owner HUM-10 topic t1 bd5579e7 (plan msg 0467b8be). The pasted
analysis guessed that Grok's session starts with a bigger prompt than Claude's.
Measured 2026-10-16: **it does not. Grok's first call carries about half of
Claude's, so nothing was trimmed.**

## 1. What a session sends on its first model call

`cd csi-spl-orc && ./run -a do_spl_token_start_size` reads each lane session's
first call from the harness's own counter. For claude that is the first
assistant row's `usage`, input + cache_creation + cache_read. For grok it is
`_meta.totalTokens` on the first `tool_call` of `updates.jsonl`, which is the
prompt plus a few output tokens. The first streamed chunk only carries a
partial count (1937 against 31845 in the same session).

Run on sat (all lane sessions of the agent user, `TOKEN_START_ROWS=0`):

| window (`TOKEN_START_SINCE` .. `UNTIL`) | grok n, min / p50 / max | claude n, min / p50 / max |
|---|---|---|
| 2026-10-04 .. 10-07 | 44, 32262 / 32784 / 33029 | 47, 35686 / 54695 / 55965 |
| 2026-10-11 .. 10-14 | 62, 31723 / 31936 / 32204 | 223, 57066 / 59108 / 60793 |
| 2026-10-13T12:00 .. 10-14T06:00 | 15, 31794 / 31852 / 32204 | 230, 57066 / 59114 / 61023 |
| 2026-10-01 .. 10-16 | 108, 31723 / 32120 / 33029 | 1160, 35686 / 59866 / 64765 |

## 2. What the grok start is made of

From one grok lane session dir on sat (`~/.grok/sessions/<dir>/<id>/`, 10-13):

| part | bytes |
|---|---|
| `system_prompt.txt`, grok's own | 7206 |
| `tool_definitions.json`, 26 tools (image and video tools ~9.3 KB of it) | 54759 |
| `prompt_context.json` agents files: `~/.claude/CLAUDE.md` 29219, project `CLAUDE.md` 9615, `AGENTS.md` 523 | 39357 |
| the seed (`lifetime/prompt.txt`) | ~9000 |

Claude loads the same two CLAUDE.md files. Grok adds no file Claude lacks.

## 3. The seed is the same text for every vendor

`spawn-agents/tests/test-spawn-seed-size.sh` builds each kind's seed. Every
kind's seed states claude's sentences, none more or less, apart from how the
harness retitles itself (and vibe's teardown line). It is at most 400 bytes
over claude's: grok +135, agy +134, qwen +135, mistral +315 (2026-10-16). A
grok-only sentence turns it red (control in the test, and checked by planting
one in `spawn-grok.sh`).

## 4. Seen on the way

- prd `fleet_token_burn_events` was empty because the box CLI verb
  `spool fleet-tokens push` did not exist. It landed in 513738af5
  ([spec 140 tasks](../../../specs/140-token-burn/tasks.md), "Push on in the cron").
- Grok on sat has answered `402 Payment Required: Grok Build usage balance
  exhausted` in 67 lane sessions since 2026-10-14 (24, 27 and 16 per day),
  and in 9 between 10-07 and 10-10. Those sessions spend 0 tokens. A new
  grok measurement needs quota first.
