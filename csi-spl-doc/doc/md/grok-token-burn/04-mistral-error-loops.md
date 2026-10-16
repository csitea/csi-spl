# Grok token burn 4/6: Mistral error loops, re-fed output, and the cap

SPL-2217, owner HUM-10 topic t1 bd5579e7 (plan msg 0467b8be, analysis item 4).
The pasted analysis guessed that Mistral lanes inflate their context with error
loops whose output is fed back every turn. Measured 2026-10-16: **every tool
result is fed back on every later turn, failed or not. Error loops are a small
share (7.7% of input). The big share is long output in general: tool results
ride along for 48.7% of all input, bash results for 24.6%. The fix: a vibe
hook that caps a long bash result to its head and tail, plus the path of the
full log. Replayed on the same sessions, it removes 9.8% of all input.**

## 1. How vibe feeds a tool result back

vibe (mistral-vibe 2.26.0) records each model call in its session journal
(`~/.vibe/logs/session/unified/<session>/journal/*.jsonl`): an `action_intent`
of kind `completion` with the messages new since the last call, and an
`action_result` with the call's `usage`. The `input_tokens` of every call is
the whole context, so a result of T tokens is paid again by every later call
until the context drops by half (a compaction). vibe's shell tool keeps the
first 16000 bytes of stdout and of stderr (`MAX_OUTPUT_BYTES` in
`mistralai_vibe_local_harness/vibe/_shell_tools.py`): the head, while a test
run's verdict is at its tail.

## 2. What it cost, per lane

`cd csi-spl-orc && VIBE_LOOP_SINCE=2026-10-15T18 VIBE_LOOP_CAP=4000 ./run -a do_spl_vibe_loop_cost`
(script `spawn-agents/scripts/vibe-loop-cost.py`), run on sat 2026-10-16
~18:20Z over 35 vibe sessions of 10 lanes, 1211 model calls. Tokens are vibe's
own counts; "re-fed" is chars / 3.3 times the later calls a result rides in
(3.3 chars per token: the input-token step between two calls against the
result sizes fed between them, n = 210, median 3.0).

| lane | sessions | calls | input | cached | failed calls | error loops (calls) | loop re-fed | bash re-fed | all results re-fed | cap 4000 removes |
|---|---|---|---|---|---|---|---|---|---|---|
| m-254 | 3 | 191 | 13,204,495 | 12,292,736 | 37 | 4 (12) | 157,743 | 3,550,333 | 8,136,359 | 1,701,539 |
| m-259 | 4 | 260 | 14,573,834 | 12,911,744 | 80 | 8 (27) | 205,946 | 3,562,688 | 8,357,170 | 1,429,695 |
| m-260 | 2 | 275 | 29,816,718 | 26,948,864 | 189 | 10 (147) | 6,001,944 | 7,375,753 | 9,542,312 | 1,893,946 |
| m-261 | 2 | 175 | 13,128,280 | 10,883,712 | 49 | 6 (27) | 236,457 | 4,280,885 | 8,762,757 | 2,487,634 |
| m-294 | 4 | 160 | 8,680,946 | 6,555,520 | 44 | 3 (16) | 29,757 | 1,841,781 | 4,815,430 | 852,951 |
| 5 more (m-213, m-244, m-246, m-248, m-283) | 20 | 150 | 6,828,781 | 5,531,008 | 23 | 2 (6) | 12,353 | 568,957 | 2,352,534 | 100,753 |
| **all** | 35 | 1211 | 86,233,054 | 75,123,584 | 422 | 33 (235) | 6,644,204 (7.7%) | 21,180,400 (24.6%) | 41,966,568 (48.7%) | 8,466,522 (9.8%) |

An error loop is the same failing tool with the same last error line 3 or more
times. One loop is most of the loop cost: m-260 ran
`spl-cost-rollup-daily.tst.sh` 61 times with "N failure(s)" as its last line,
re-fed ~4.9M tokens. The others are a few pnpm, `do_spl_push_master`,
`do_sec_shellcheck` and `edit old_str not found` repeats, each under 0.12M.
87% of the input was served from vibe's prompt cache. Not measured: m-595 ran
on the other box; the same action runs there.

## 3. The fix: spool-install step Y15, the output cap

A non-strict vibe `post_tool` hook on `*bash`
(`spool-install/assets/vibe-output-cap/vibe-output-cap.py`). A result longer
than `VIBE_OUTPUT_CAP_CHARS` (4000) is written whole to
`$XDG_STATE_HOME/vibe-tool-output/<session>/<call>.log` (kept 2 days), and
the model sees the return code, the first quarter and the last three quarters
of the budget, cut at lines, and the log path. vibe's post_tool `deny`
replaces the model-visible result; the command already ran. A failing hook
prints nothing, so vibe keeps the result (fail open); `VIBE_OUTPUT_CAP_CHARS=0`
turns it off. Only bash: a `read_file` is a deliberate read.

Install: `spool-install` step 6e, or for both users of a box
`cd csi-spl-orc && DRY_RUN=0 ./run -a do_spl_vibe_output_cap_install`.
vibe reads `hooks.toml` when a session starts.

Test: `bash csi-spl-orc/src/bash/tests/spool-install-y15-vibe-output-cap.tst.sh`.
Through vibe's own `load_hooks_file` and `compile_foreign_hooks`, a 50 KB
failing test log reaches the model as 4208 chars that keep `returncode: 1`, the
`FAIL` line at its tail and the log path. Control: on origin/master 3e70c267c
(before Y15) the same path feeds all 53008 chars to the model.

## 4. What it does not do

- It does not stop a loop. The takeover ladder (asks a06bd808 / M1b) stops a
  lane after N failures; the cap lowers the tokens each failure costs.
- It does not shorten results already in a running session; a new session
  picks up the hook.
- It does not count prompt-cache pricing: whether a cached token costs less
  is the provider's rule, not measured here.
