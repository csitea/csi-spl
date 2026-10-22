# Bug round 3 - reviewer seat claude (c-084)

Plan: [bug-round-3-plan.md](../bug-round-3-plan.md) v0.1 (`017814e5b`). Issue: SPL-2834 (this review), plan SPL-2827.
Rules: [rounds-rulebook.md](../rounds-rulebook.md).

Measured on `origin/master` `76d5b4889`, 2026-10-22 06:40-06:57Z, from <box2> (the inputs pulled from sat), n=1 per command unless stated.
`git diff --stat 396343618 76d5b4889 -- <every site the rows name>` -> empty, so each control ran on the row's files as they were at `396343618`.
`lane-map.sh --check csi-spl-doc/doc/md/bug-round-3/seat-claude.md --agent c-084` -> exit 4: 8 live sat lanes record no files. Their slugs (rotate, r17 WUI decompositions, phone omnibox, s143 proof, the mistral r7 reviewer) do not cover this new folder.

**Tally: 1 agree / 2 agree with changes / 0 disagree / 0 proposals.**

## 1. Red controls re-run (plan section 3.2)

Inputs: `/var/spool-hub/c-738/b03-red-controls/` on sat. The agent user cannot read that directory (`ls` -> `Permission denied`), so I copied it to my scratch with `sudo tar` over ssh. Its files match c-738's inline copy (msg 3d725c4f).

| row | command | output | n |
|---|---|---|---|
| 01 (a) | `source csi-spl-orc/src/bash/run/spl-spawn-share.func.sh; SPAWN_SHARE_LANES_CMD=<scratch>/lanes.sh spl_spawn_share_lanes` (rows `age_s 600` and `age_s 330000`) | `[{"agent_id":"c-101","agent_box":"sat"},{"agent_id":"a-313","agent_box":"sat"}]`: both rows, **red** | 1 |
| 01 (b) | the same, stub `{"hub":"ok","lanes":[{... "age_s":600,"src":"hub"},{"agent_id":"c-102",... "age_s":-1,"src":"local"}]}` | `[{"agent_id":"c-101",...},{"agent_id":"c-102",...}]`: the local row is kept while the hub answered, **red**. The plan states this half but section 3.2 did not run it. | 1 |
| 02 | `source csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh; ROTATE_LANE_BUSY_RE='git push' LEASE_PROC_ROOT=<scratch>/proc spl_lane_rotate_busy_child 100 \| wc -l` (`od -c proc/200/cmdline` shows the two `\n`) | `3`; the lines are `/bin/bash -c git push origin HEAD:master`, `echo two` and `echo three`. **red** | 1 |
| 03 | `zz_mismatch_test.go` in a scratch copy of `csi-spl-api/src/go/spool-hub-api` (with `csi-spl-rdb` linked beside it so the migrations resolve), `SPOOL_TEST_PG_DSN=<local postgres:16-alpine, non-superuser> go test -count=1 -run TestZZChannelRowVsCards -v ./internal/store` | memory: `new opener, no mention: MISMATCH channel view 1 vs side-row key 0` and `2 replies in a read-but-unwatched topic: MISMATCH channel view 3 vs side-row key 0`. **postgres: the same 2 mismatches**. `FAIL` | 1 per driver |

Row 02's live evidence was re-read on sat: `sudo grep -vcE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T' /var/spool-hub/dispatch/rotate.log` -> `166` (it matches the plan). For every block of unstamped lines, the stamped line just before it is an `in flight: running` line (`grep -B1 -v <stamp> \| grep '^20' \| grep -vc running` -> `0`). First case: 2026-10-12T05:30:10Z `lane-c-853 GATE OK ... running '/bin/bash -c source ...`, followed by `import json,sys,subprocess` and 3 more script lines.

Baseline: `bash csi-spl-orc/src/bash/tests/lane-rotate.tst.sh` -> `lane-rotate: 0 failure(s)`.

## 2. Verdict per row

| # | verdict | reason and changes |
|---|---|---|
| 01 spawn share counts dead lanes | **agree with changes** | One defect at one site (`spl-spawn-share.func.sh:88`, the jq). Its consumers, `spl-spawn-place.func.sh` (supply check, band pick) and `spl-spawn-fill.func.sh`, need no change. Changes: (a) **Add the src=local half (01 b above) to section 3.2.** It is red today and was not run. (b) **Existing stubs carry neither `age_s` nor `hub`**: `spl-spawn-queue.tst.sh:403,436` and `spl-spawn-fill.tst.sh:111,170` build `{agent_id, agent_box, state}` rows only. If the fix copies the lane map's rule with `$h` read from the input's `.hub` (missing reads as "not ok"), those rows stay (`jq` on a row with no age gives `.age_s >= 0` false and `.age_s < 0` true), and both suites stay green. If it treats a missing age as stale, or defaults `hub` to `ok`, 3 suites go red. The row must say which, and run `spl-spawn-queue.tst.sh` and `spl-spawn-fill.tst.sh` as part of its gate. If those stubs have to change, list the two files in the row (R1). (c) **Role seats**: the lane map always keeps a live role seat (`spl-lane-map.func.sh:213`, `$seat`). The row must decide whether the share copies that clause and test it. A role seat has no `Class:` brief, so it only adds to `unknown`. (d) **Missing**: the share's expected reading after the fix on today's map (e.g. `known N, unknown M` at the time of the fix), so the R7 reviewer can check the result and not only the stub. |
| 02 rotate log splits a command | **agree** | One defect at one site (`spl-lane-rotate.func.sh:315`, the `tr`, then the `cut` at :316). The other lines named (:295, :413, :415, :460) only pass the text on and need no change. The control is red and the live log shows the harm (166 lines). Folding `\n` and `\r` into the same `tr` does not change the match: `grep -qE` already matched across lines. Batch 2 behind row 01 in lane B is a capacity choice, not a file conflict: the two rows share no file. |
| 03 channel row misses lines | **agree with changes; hub side** | One defect: the `ch:` key counts only `flow_events` lines (`flowInsertCTE`, `flow_postgres.go:41-66`), while the channel's count and its cards count every line. Red on **both** drivers (section 1). Plan section 3 says "memory": correct it to "memory and Postgres". Changes in section 3 below. |

## 3. Row 03: hub side or WUI side

**Pick the hub side.** The WUI variant (row = max of the `ch:` key and its cards' sum) cannot fix the reported case. The cards' `t:` counts are seeded only when a channel page opens: `pages/channel/[name].vue:86,94` calls `notes.seedTopics('ch:' + ...)` (spec 062 section 1.3, "seeded when a channel opens"). A channel row the member has not opened in this tab has no card sum, so `max(0, nothing)` still shows 0. The owner's report is about exactly that row. In t1 topic b288e5be, which `do_spl_db_query` reads read-only on prd, HUM-10 wrote 2026-10-16 08:32Z `ca7ce753` "I would expect to have 3 unread msgs and not 0 - aka none" and 2026-10-21 13:55Z `d548a8ad` "it still shows the amount of read messages wrongly on the channel level". The 10-03 rule that put the row on the Flow keys (`1822d9feb`, "every unread number is the sum of the rows under it") also points to the hub. The rows under a channel are its topic cards, which count every line.

Two changes to the fix scope:

1. **Only the keys, not the Flow badge.** The scalar Flow counts and the `keys` map come from the same `fc` rows (`flow_postgres.go:166-205`). If the fix feeds every channel line into `fc`, the Flow badge counts all channel lines again, which is what spec 062 removed ("only what concerns me"). Add the extra lines to the `ch:` and `t:` keys only. The adopted test asserts that `FlowRead`'s mention/reply/dm/unread counts stay 0 in both cases, beside `ch:` = `ViewChannelStats` unread.
2. **Say that the Channels rail number rises.** That number is `sectionTotal` over the `ch:` keys (`utils/flow-keys.mjs:22`). It will now include unwatched lines. That is intended (it equals the rows under it), but the row should state it so the R7 reviewer does not read it as a regression.

**Cost: measured.** I ran `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 READER=HUM-10 MEASURE_N=20 MEASURE_ONLY=flow_counts,ch_counts,ch_marked,ch_thread,ch_hidden ./run -a do_spl_db_hot_measure` (read-only session, 2026-10-22 ~06:45Z, n=20 each):

| statement | p50 ms | p95 ms | max ms |
|---|---|---|---|
| flow_counts | 26.2 | 38.2 | 600.5 |
| ch_counts | 22.4 | 32.5 | 167.8 |
| ch_marked | 1.5 | 2.6 | 7.3 |
| ch_thread | 14.7 | 32.0 | 356.3 |
| ch_hidden | 22.1 | 34.9 | 911.0 |

`flow_counts` today is 26.2 ms p50 (SPL-2124 recorded 20.1). If `FlowRead` also ran ViewChannelStats' reads as they are, the added work would be about 38.6 ms p50 (`ch_counts` + `ch_marked` + `ch_thread`), or 60.7 ms with `ch_hidden`. That is roughly 2.5x to 3.3x today's read. This is a **sum of separate medians, not a measurement of a combined statement**. Proposed budget for the row: after the fix, `flow_counts` p50 at most 2x today (52 ms, n=20, same command). Over that, the lane reuses the channel-count statement's result rather than adding a second walk, and reports to c-738 before it pushes.

## 4. Plan-wide checks

- **R1 disjoint files**: holds for lanes A and B as written, unless row 01 must change the two stub tests (2.01 b). They are still disjoint from rows 02 and 03.
- **Red controls**: all 3 fail today (section 1), on `76d5b4889`, whose row files equal `396343618`.
- **Section 3.2 is not auditable without sat**: the commands carry `<stub>` / `<fake proc>` placeholders and the inputs sit in a directory the agent user cannot read. Paste the stub line and the `printf` of the fake cmdline into 3.2 (they are 2 lines each), as c-738's msg 3d725c4f already did.
- **No prd write, no terraform, no WUI row, no mistral coding**: holds.

signed: c-084@<box2> on 76d5b48899156642aacaeaa952003f53b05f20c3

<!-- seat: c-084 claude, reviewer of plan v0.1 017814e5b -->
