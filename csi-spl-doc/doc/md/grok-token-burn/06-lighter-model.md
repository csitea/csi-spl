# Grok token burn 6/6: a lighter Grok model

SPL-2578, owner HUM-10 topic t1 bd5579e7 (the outside analysis "Ara", also
t1 8308dbff): run the lanes that do not need the heavy model on a lighter
one. Measured 2026-10-20 on sat: **the installed grok CLI offers no lighter
tier, and the one knob it has, reasoning effort, acts on under 1% of
Grok's tokens. Nothing was changed.** The launcher keeps the CLI default.

## 1. What runs today

- No launcher passes a model or an effort:
  `git grep -nE -- '(--model|--effort|--reasoning-effort|grok-4)' csi-spl-orc/src/bash/features/spawn-agents csi-spl-cnf`
  -> no grok line. The live seats run
  `grok --dangerously-skip-permissions --permission-mode bypassPermissions <seed>`
  (`ps -eo args=`, g-002 and g-003).
- So every seat and lane runs the CLI default. `grok models` (CLI 1.0.62)
  -> `grok-4.7 (default)`, `grok-4.7-build-fast`, `grok-4.6`, `grok-4.5`.
- The session files agree: `summary.json` under the agent user's
  `.grok/sessions/` names `current_model_id` and `reasoning_effort`. Of 292
  sessions on sat, 289 ran `grok-4.7` at `high`. The other three were
  probes: two `low` bench runs on 10-03 and one `grok-4.6` one-shot on 10-13.

## 2. What the CLI offers

From the model catalogue the CLI caches (`.grok/models_cache.json`, fetched
2026-10-20):

| model | description in the catalogue | context |
|---|---|---|
| `grok-4.7` | "latest frontier model" (default) | 256k / 500k |
| `grok-4.7-build-fast` | "Fast variant. 2x the price." | 256k / 500k |
| `grok-4.6` | none (the previous generation) | 256k |
| `grok-4.5` | none | 256k |

None of them is marked as lighter or cheaper. The fast one is marked as
dearer. The only cost knob is `--reasoning-effort` (`low`, `medium`,
`high` = default, `xhigh`), from `grok --help`.

## 3. The numbers

**Where the tokens go.** Take the 111 sat grok-4.7 `high` sessions with 20 or
more model calls (`usage.json` per session, 1.46 G tokens). The input, sent
again on every call, is 99.24% of all tokens, and 95.5% of that input is
cached. Output is 0.76%, of which reasoning is 0.52 points. Per call that is
about 111,700 tokens in, 856 out and 585 reasoning. Even a change of effort
that removed every reasoning token would cut the total by under 1%. Batch 1
([1/6](01-start-prompt-size.md), [2/6](02-context-growth.md)) already found
that the cost is in the input.

**An older model, per lane.** The prd record (`fleet_token_burn_events`,
spec 140) holds the one time Grok lanes ran another model. On the PC,
2026-09-20 to 09-22, every lane ran `grok-4.6-build`. From 09-23 on they ran
`grok-4.7-build`, the CLI default after its update (one later lane, on
09-25, ran grok-4.6 again):

| model, PC | lanes | median tokens per lane | output share | uncached share |
|---|---:|---:|---:|---:|
| grok-4.6, started 09-20 .. 09-22 | 14 | 10.55 M | 0.36% | 3.84% |
| grok-4.7, started 09-23 .. 09-24 | 14 | 14.56 M | 0.38% | 7.11% |

That is 1.38x, but the lanes did different tasks on different days, and
their kinds are not on record. The output share is about the same on both
models (0.36% and 0.38%), so what differs is the input: how many calls a
lane makes, how big its context grows, and how much of it misses the cache
(3.84% and 7.11%). The calls and the context follow the task. This is not a
like-for-like comparison, and grok-4.6 is the older model, not a lighter one.

**One call, no task.** One-shot probes (one model call each, a one-line
answer) cost 27,579 .. 27,796 tokens on grok-4.7 (n=4) and 26,608 on
grok-4.6 (n=1). The difference is the system prompt and the tool
definitions.

**No test session was started.** The brief allows at most one short one. One
session cannot give n >= 3 per model, and the 0.76% bound above decides the
effort question without one.

## 4. The commands

Per-session model and effort on sat, read only (with sudo, because the
files belong to the agent user, `$SPOOL_AGENT_USER`):

```bash
sudo python3 -I -c 'import json,glob,os,sys,collections; c=collections.Counter((s.get("current_model_id"),s.get("reasoning_effort")) for s in (json.load(open(f)) for f in glob.glob(os.path.expanduser("~"+sys.argv[1]+"/.grok/sessions/*/*/summary.json")))); print(c)' "$SPOOL_AGENT_USER"
```

Each session's tokens are in `usage.json` next to its `summary.json`
(`session.inputTokens`, `outputTokens`, `cachedReadTokens`,
`reasoningTokens`, `modelCalls`).

Tokens per lane by model on the PC, from the prd record (the table above):

```bash
cd csi-spl-orc && ENV=prd SQL="with a as (select model, agent_id, min(minute_bucket) t0, sum(tokens_in+tokens_out+cache_read+cache_write) tot, sum(tokens_out) tout, sum(tokens_in+cache_write) unc from fleet_token_burn_events where vendor='grok' and box_tag <> 'sat' and agent_id like 'GRK-%' group by 1,2) select model, count(*) n, percentile_cont(0.5) within group (order by tot)/1e6 med_m, round(sum(tout)::numeric*100/sum(tot),2) out_pct, round(sum(unc)::numeric*100/sum(tot),2) unc_pct from a where (model='grok-4.6-build' and t0 < '2026-09-23') or (model='grok-4.7-build' and t0 >= '2026-09-23' and t0 < '2026-09-25') group by 1" ./run -a do_spl_db_query
```

## 5. When to look again

Look again if xAI publishes a cheaper tier or per-model quota rates, or if
`grok models` lists a model described as lighter. Then measure n >= 3 lanes
of one kind on each model. Only if the lighter model costs clearly less per
lane, make the model a cnf choice per task kind in the grok launcher
(`spawn-grok.sh`), keep the orchestrator and dispatcher seats on the
default, and add a test with a red control.
