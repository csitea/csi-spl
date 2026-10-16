# Grok token burn 2/6: context growth per call, and the cap

SPL-2215, owner HUM-10 topic t1 bd5579e7 (plan msg 0467b8be, analysis items 2
and 8). The pasted analysis guessed that Claude Code compacts its context and
Grok's harness does not, so every Grok turn resends the whole thread.
Measured 2026-10-16: **it is the other way round. Grok compacts and Claude
lanes almost never do. But a Grok session grows about 1.8 times faster per
call, and Grok's compaction comes late, at 204800 tokens. The fix: a lower
cap from the cnf, which Grok applies itself.**

## 1. Context per model call, over a session

`cd csi-spl-orc && ./run -a do_spl_grok_context_growth` (as the box user; it reads the agent user's homes through `sudo -n -u`)
covers lane sessions (`csi-spl-wt/g-*`, `csi-spl-wt/c-*`) touched in the last 7
days with at least 10 calls. The context of a call is the number of tokens the
model read for it:

- grok: the first `_meta.totalTokens` of each `streamStartMs` in
  `updates.jsonl`. There is one stream per model call, and the stream count
  equals `usage.json` `modelCalls` (62 = 62 in session `01a1030b`).
- claude: `input + cache_read + cache_creation` per assistant `message.id`,
  not counting subagent rows.

Run on sat 2026-10-16 ~15:00Z (grok 62 sessions, claude 781):

| call | grok n | grok median ctx | claude n | claude median ctx |
|---:|---:|---:|---:|---:|
| 1 | 62 | 1932 | 781 | 60409 |
| 2 | 62 | 35746 | 781 | 67385 |
| 10 | 62 | 59087 | 781 | 84710 |
| 25 | 36 | 97240 | 603 | 107413 |
| 50 | 23 | 151627 | 449 | 140697 |
| 100 | 12 | 128228 | 209 | 204723 |
| 150 | 6 | 137484 | 98 | 250807 |
| 200 | 3 | 108542 | 33 | 304466 |
| 300 | 1 | 171820 | 8 | 392780 |

| vendor | sessions | calls/session median | input/session median | max ctx median | growth/call c10..c40 | sessions compacted |
|---|---:|---:|---:|---:|---:|---:|
| grok | 62 | 32 | 2078241 | 80643 | 2187 (n=26) | 13 |
| claude | 781 | 58 | 6227718 | 131543 | 1189 (n=488) | 2 |

Grok's call 1 is a small side call. Its real first prompt is call 2; see
[1/6](01-start-prompt-size.md).

What the numbers show:

- **Grok compacts, Claude lanes almost never do.** Grok's contexts fall back
  after call 50: 13 of 62 sessions compacted, always just under 204800
  (202688 -> 32590, 204377 -> 28674, 204654 -> 32982, ...). Only 2 of 781
  claude sessions compacted, and claude lanes run past 300000.
- **Grok grows 1.8 times faster per call** (2187 against 1189 tokens a call).
- A grok session is short (median 32 calls), so its input per session is
  below claude's. The 3-4 times faster burn is not explained by context
  growth. It is a matter of quota and price, which are other lanes of this
  topic.

## 2. What the Grok CLI offers

Grok Build 1.0.60 (`grok --version`), its own docs in `~/.grok/docs/user-guide/`:

- `/compact` and auto-compact: "Grok also auto-compacts once the context
  window hits 85% (tune it with `[session] auto_compact_threshold_percent`)"
  (`04-slash-commands.md`). The model list `~/.grok/models_cache.json` sets
  `grok-4.7` to `context_window` 256000 and `auto_compact_threshold_percent`
  80, which is 204800 tokens. That is where the compactions above happen.
- `session.auto_compact_threshold_percent` (`26-config-reference.md`):
  "Auto-compact when context usage reaches this percent (0-100)." It lives in
  `config.toml`. The `GROK_CONFIG` overlay cannot set it, because it accepts
  only `models`, `features`, `toolset` and `shell_environment_policy`
  (`05-configuration.md`).
- `/context-window <size>` (256k or 500k) and `/new`. There is no CLI flag
  for the threshold (`grok --help`).

Grok already does "the recent turns plus a digest" itself. Its compaction
keeps a summary and the recent messages (`compaction_checkpoints/`). The
cheapest fix is therefore to make it compact earlier, not to rotate sessions
from the harness.

## 3. The fix

- cnf `env.box.grok_cli.auto_compact_threshold_percent: 50` in
  `csi-spl-cnf/csi-spl/all.env.yaml`, which is 128000 tokens.
- `spool-harness.sh` step 5b (`spawn-agents/lib/grok-compact.inc.sh`) writes
  it on every grok launch as
  `auto_compact_threshold_percent = 50  # spool-harness: cnf env.box.grok_cli (SPL-2215)`
  under `[session]` in the agent user's `~/.grok/config.toml`. Every other
  key is kept. A value set by hand (a line without the marker) is also kept.
  An empty cnf value removes our line, so Grok's default applies again.
  `SPOOL_GROK_COMPACT_PCT` overrides the cnf for one launch.
- Tests: `spawn-agents/tests/test-spool-harness.sh` "grok cap". The CONTROL
  removes the value and the line is gone. With step 5b turned off, 4 of its
  checks go red. `src/bash/tests/spl-grok-context-growth.tst.sh` tests the
  measurement, and its CONTROL is a removed cap, which brings the growth back.

## 4. What the cap saves (model), and what is not measured yet

The action replays each grok session's per-call growth. When the context
passes the cap, one compaction call reads it, and the context drops to P =
36062. P is the median size Grok itself produced after a compaction.

| cap (tokens) | % of 256000 | simulated grok input | vs measured | compactions |
|---:|---:|---:|---:|---:|
| 80000 | 31 | 220018893 | -48.9% | 130 |
| 100000 | 39 | 251087475 | -41.7% | 81 |
| 128000 | 50 | 290233741 | -32.6% | 56 |
| 150000 | 59 | 317696653 | -26.2% | 41 |
| 204800 | 80 | 420668692 | -2.3% | 21 |

The 204800 row is Grok's own threshold. It reproduces the measured
430758234 within -2.3%, which is the model's control.

The model assumes that a compaction loses nothing the lane then reads again.
50 is a middle choice, not the deepest cut. If a lane rereads what a
compaction dropped, part of the saving goes. Only live sessions show that.

**Not measured yet:** the same table after the cap. Grok on sat answers
`402 Payment Required: Grok Build usage balance exhausted`. A throwaway-home
run on 2026-10-16 got it, and [1/6](01-start-prompt-size.md) section 4 has
the counts. So no grok session has run with the cap, and it is not proven
that `[session]` beats the model list's 80. When quota is back, the check is
the first table above with `GROWTH_DAYS=1`: grok rows after call 50 must stay
under 128000, and `signals.json` `compactionCount` must rise on long lanes.
