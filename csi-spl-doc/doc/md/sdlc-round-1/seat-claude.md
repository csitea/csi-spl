# SDLC round 1 - claude seat verdict

Seat: **c-247@sat** (claude). Plan read: `sdlc-round-1-plan.md` v0.1 (e95587ea2). Issue: SPL-2058 (seat lane SPL-2066). Task `dispatch-999a50bd`, editor a-240@sat.

**Tree:** code read on `fd7e80e2b`; `origin/master` moved to `3e4c39855` while I measured, and `git diff --stat fd7e80e2b 3e4c39855 -- csi-spl-orc/src/bash/run csi-spl-orc/src/bash/features/spawn-agents/scripts .github/workflows` is empty, so every code citation holds on both. Live data (spool, cron logs, hub, GitHub) read 2026-10-15 23:29Z..23:38Z on sat. n per command is given with its output. Every number below comes from a command I ran in this session.

**Tally: 0 agree / 4 agree with changes / 8 disagree / 3 proposals.**

The pattern behind the 8 "disagree" verdicts: 4 rows rebuild something already on master (02, 03, 08, 10), 2 contradict an owner rule or a design decision (07, 08), 2 cite a site that does not do what the row says (05, 06), and 5 rows cite a test file that does not exist. No row's owner-minutes or token figure comes from a command: the plan's 265 owner min/week and 164k tokens/week are unchecked estimates. Section 0 below gives the hub measurement the plan's intro asks for.

## 0. Owner-time baseline (the plan's ranking key, not measured in v0.1)

The plan ranks by owner minutes "measured from the hub (HUM-10 messages ...)". Measured on prd, tenant t1, the last 7 days:

`ENV=prd SQL="SELECT ts::date, count(*) FILTER (WHERE from_id='HUM-10') ... FROM messages WHERE tenant_id='t1' AND ts > now()-interval '7 days' GROUP BY 1" ./run -a do_spl_db_query`

-> owner posts per day 10-09..10-15: 187, 201, 138, 100, 156, 140, 186 (**1108 in 7 days**).

Owner posts by subject, the same 7 days (regex on the body, so this is a proxy, n = posts):

| subject (regex) | owner posts | rows that touch it |
|---|---|---|
| status asks (`what is the status`, `^status`, `status ?`, `status report`, `how many done`) | **32, in 28 topics** (29 under 60 chars) | none (proposal P1) |
| `review` | 14 | 05, 06 |
| queue / stuck / idle / not placed | 12 | 01, 03, 04 |
| deployed / live / served / prd | 11 | 09 |
| issue state | 10 | 11 |
| quota / weekly limit | 6 | 03 |
| re-run / flake | 2 | 08 |
| push status | 2 | 12 |
| close / retire / orphan | 1 | 10 |

The status asks are answered fast (agent reply after the owner's status ask: median 50.5 s, avg 59.7 s, n=26, same query joined to the next non-owner post in the topic), so the cost is the owner's own post and read, 32 times a week, and no row in the plan removes it.

## 1. Section 1 measurements, re-run

| § | plan claim | my command | my output | verdict |
|---|---|---|---|---|
| 1.1 | 19 queued, avg 9050 s, med 9640 s; root causes: prefixes, 10-min gap, `unknown` pick | `SPAWN_QUEUE_FORMAT=json SPAWN_QUEUE_SHARE=0 ./run -a do_spl_spawn_queue`, same python | `count=22 min=779 max=21651 avg=10710 med=12713` | **agree with changes.** `wait_s` of rows still queued is survivor-biased (rows already placed are gone), so it is not "ask -> placed". The ranking of causes is wrong: in `/var/csi/csi-spl/spawn-place/cron.out` (6119 lines) the holds are `grep -oE 'hold: [a-z ]+' \| sort \| uniq -c` -> **1418** "last placement started under 10 min" vs **37** "fleet load target says hold", and `grep -c "no brief file for"` -> **12** hand-offs. The 10-min gap is the binding constraint, not the prefix. |
| 1.2 | n=6, avg 955 s placed -> first push | the plan's python, verbatim | `n=4`: m-244, m-244@sat (552 s), c-233, c-233@sat (811 s) | **disagree.** It counts each lane twice (`<id>` and `<id>@sat` dirs) and compares two mtimes that mean other things: `status` is the LAST push's end, `lane.log` is its last write. n=4 is 2 lanes. |
| 1.3 | n=53, avg 1.81 commits per key, 36 of 53 at 1 | the plan's command, verbatim | `n=48 min=1 max=14 avg=2.02 median=1 distribution={1: 32, 2: 8, 3: 3, 4: 1, 5: 1, 8: 1, 9: 1, 14: 1}`; 4 of 100 subjects carry no key | **agree with changes.** It counts commits per key, not pushes per item; the 14 is a round-doc key (plans and seat files), not a code item. |
| 1.4 | hub avg 20.1 min (n=10), WUI avg 9.9 min (n=8) | `gh run list --workflow <wf> --branch master --limit 40 --json conclusion,createdAt,updatedAt` | wf20: n=40, 38 success, 2 failure; success min 792 s, med 1222 s, avg 1184 s, max 1539 s. wf30: n=40, 37 success, 2 cancelled, 1 failure; success min 420 s, med 498 s, avg 536 s, max 1045 s | **agree** (wf30 med 8.3 min, not 9.9). |
| 1.5 | result -> ACCEPTED avg 528 s, n=4 | python over `/var/spool-hub/c-00[23]/outbox/2026101[3-6]*.json` (ACCEPTED bodies) joined to the last `kind: result` from that lane on the same task in `c-00[23]/{archive,inbox}` | 161 ACCEPTED, 123 matched: **min 5 s, med 35 s, avg 320 s, p90 892 s, max 4709 s** | **agree with changes.** n=4 hand-picked lanes is not a distribution; the median lane waits 35 s and the tail (p90 15 min) is what row 09 can shorten. |
| 1.6 | 40 runs: 20 success, 18 cancelled, 1 failure, red 14 min | `CI_GATE_RUNS=40 ./run -a do_report_ci_gate` (csi-spl-iac) | window 19:36Z..23:29Z: 22 success, 16 cancelled, 2 running, "no failed run in the window"; every job's p90 under 54 % of its timeout | **agree** that red time is low. The flake re-run need it states is already covered (row 08). |
| 1.7 | 8-10 hand steps per lane, "trace of outboxes" | no command given; checked steps 9 and 10 in code | step 9 is automated: `tmux-close-window.sh --defer --retire` (used by /exit-clean, line 66) and the `agent-id-reap.sh` cron; step 10 is the hourly `do_spl_issue_close_landed` | **disagree.** No command, no n; 2 of the 10 steps are already automated. |

## 2. The 12 rows

File check: `git cat-file -e origin/master:<path>`, lines `git show origin/master:<path> | wc -l`. The real test column comes from `git grep -l <symbol> origin/master -- '*tests/*'`.

| row | cited files | verdict | evidence (command -> output) and the change |
|---|---|---|---|
| 01 placer slug normalize | `spl-spawn-place.func.sh` OK (315 lines, `spl_spawn_place_brief` at 249-256); **`tests/spl-spawn-place.tst.sh` MISSING**, real test `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` | **agree with changes** | `grep -c "no brief file for hand-" cron.out` -> **7** (plan: 12; 12 is every hand-off). Queue now: 7 of 22 rows not placer-launchable, all `claude:hand-sat-*`, waits 7547..20979 s, and the brief exists without the prefix for all 3 I checked (`c002-box-beats-read-cap.md`, `c002-desk-doctree-caller-guard.md`, `c002-token-burn-cli-push.md`). The prefix is **deliberate**: c-002's QUEUE posts say "claude on sat (hand-place)". Stripping it and launching `auto` throws that pin away. Changes: (a) parse `hand-<box>-` / `<box>hand-` as a box pin and launch on that box (or, once SPL-2035's quota skip covers `unknown`, have the dispatcher stop using the prefix); (b) **a hand-off must not touch `.place.last`**: line 239 touches it before the brief check, so each of the 12 hand-offs also burned a 10-min placement slot; (c) test in `spl-spawn-queue.tst.sh`. Owner posts it touches: 12/week (queue/stuck). The plan's "150.8 -> <10 min" is not reachable while the gap gives 1418 holds. |
| 02 spawn-remote brief sync | both files OK (340, 159) | **disagree** | It is already built: `spawn-remote.sh:110-119` reads the brief here and sends its text in the request; `:210-218` writes it on the target, `chmod 600` plus `setfacl u:$SPOOL_AGENT_USER:r`. The cited "4 manual copies (920ccbfc)" was a request for c-001@PC to copy **a-586's 16 output files** to sat, not a brief (c-002 outbox 2026-10-15T19:59:40Z). Cross-box copy requests in c-00[123] outboxes 10-13..10-16: python regex `cop(y\|ied)\|scp\|rsync\|pull ... files\|brief\|dir ... to\|from <box>` -> **n=1**. Nothing to automate. |
| 03 box-pick quota failover | both OK (201, 427) | **disagree** | Already landed: `8b427556c feat(orc, SPL-2035): the box pick skips a box at its vendor's weekly limit` (2026-10-15); `spl-box-pick.func.sh:46-54` skips at >= 90 %, `:191` holds with "queue the lane, spawn nothing" when every box is over; test cases 16+ in `spl-box-pick.tst.sh`. What is left is "usage unknown -> placed anyway" (`:187`), and that is already queued as its own bug ask `claude:hand-sat-c002-box-pick-quota-unknown-<PC>` (slug ends in the PC box name) (wait 13809 s). A row here would duplicate a queued lane. |
| 04 enqueue brief check | `spl-spawn-enqueue.func.sh` OK (57); **`tests/spl-spawn-enqueue.tst.sh` MISSING**, real test `tests/spl-spawn-queue.tst.sh` | **disagree** | `:28-29` already refuses a malformed `SPAWN_PLACE`. Queue now: **0 of 22** rows with a vendor outside {claude, grok, agy, qwen, mistral}; the 7 rows with no brief are the deliberate `hand-sat-` pins of row 01, so "fail fast on no brief" would refuse the dispatcher's hand-place. **R1:** with the real test path it shares `spl-spawn-queue.tst.sh` with row 01 in batch 1. Fold a vendor-membership check into row 01. |
| 05 reviewer auto-assign | `spawn-window.sh` OK (473), but `:125-135` is the tries journal and `grep -ni review spawn-window.sh` -> 0 lines; **`tests/test-reviewer-pick.sh` MISSING** | **disagree** | R7 is not failing: `git log origin/master --since='4 days ago' --format=%B \| grep -c '^review: '` -> **38**, `grep -c 'same vendor'` -> **0**. Reviewer per row goes in the brief (R4, R7.2), which the dispatcher writes; spawn-window never parses briefs, and making the launcher depend on panel-seat liveness adds a failure point to every spawn. Owner minutes: 0 (dispatcher work). |
| 06 review-line remote verify | both OK (189, 156) | **disagree** | It contradicts the design: `spl-review-line-check.func.sh:62` "run it on $2 (**never fetched**)". The row's cache would relay reviewer session journals (transcripts) across boxes, which carry exactly what R7.2.4 keeps on the reviewer's box. Its "safe degradation" (fall back to syntax plus a warning) is the silent fallback 8772dd8f forbids. Measured: review lines by box (4 days) -> sat 27, PC 10. Alternative if needed: the reviewer runs `do_spl_review_line_check` on its own box and pastes its `OK` line into the review message, so nothing is fetched. |
| 07 dev-guide auto-ack | `dev-guide-ack.inc.sh` OK (91); **`tests/test-dev-guide-ack.sh` MISSING**, real tests `tests/dev-guide-ack.tst.sh`, `features/spawn-agents/tests/test-pre-push-dev-guide.sh` | **disagree (out)** | Owner msg 56d7073e: every coder "must agree that they have read" the guide; a stamp written by the launcher is an ack nobody gave, so the row removes the control. Measured: `grep -h 'has not confirmed reading the developer guide' /var/spool-hub/*/lifetime/push-master/log \| wc -l` -> **0** over 22 push logs (plan: 3). |
| 08 CI flake auto-retry | `scripts/ci-red-note-cron.sh` OK (65); **`tests/ci-red-note.tst.sh` MISSING** (it is tested only in `tests/install-box-crons.tst.sh`) | **disagree (out)** | The infra case is already on master: `.github/workflows/12_ci-rerun-setup-flake.yml` plus `do_ci_rerun_setup_flake` reruns failed jobs once when they all died at "Set up job". For test flakes the owner wrote 2026-10-14 11:40 (hub, t1) "all of those flaky tests must be converted to non-flaky", and R11 2.11.3 gives a flake a fixing lane at its 3rd sighting. An auto-retry hides the sightings both depend on. `do_report_ci_gate` (40 runs): "no failed run in the window". |
| 09 lane landed+served verify | `check-deploy-lag.func.sh` OK (158), test OK (128) | **agree with changes** | Worth having: owner posts on deployed/live 11/week, and the owner's 10-15 05:08 rule (live = on master AND served in dev and prd) is what it checks. Changes: (a) a **new** action `check-lane-served.func.sh` / `do_check_lane_served` that calls `do_check_deploy_lag` per env plus the ancestor, `%ae %ce --no-mailmap` and anchored-trailer checks, rather than an edit to lines 100-160 of the lag check; (b) it is evidence for the dispatcher, who still judges Done and writes ACCEPTED, never an auto-ACCEPT; (c) target the tail: result -> ACCEPTED is median 35 s and **p90 892 s** (n=123), not "8.8 min -> 30 s". |
| 10 lane retire auto-chain | both OK (276, 145) | **disagree** | Already built: `tmux-close-window.sh:66` `--agent c-007 --defer --retire  # /exit-clean: then retire the id`, `:128` `--retire`; `agent-id-reap.sh` retires any id dead longer than 6 h from cron; `lane-scratch-reap.sh` covers /tmp. Owner posts on close/retire: 1/week. |
| 11 issue close on landing | both OK (152, 167) | **agree with changes** | Cheap, and it removes a real wait (developer guide 1.4: a landed issue stays open until the hourly closer runs). Changes: run the closer for **the keys of the landed shas only**, under the closer's own lock, and only after the landed check (`git merge-base --is-ancestor`), because the closer is cursor-based (`ISSUE_CLOSE_SINCE`, ledger `closed.tsv`), and a second writer racing the hourly run on that cursor is a new failure. Keep the hourly run. Owner posts on issue state: 10/week (regex, broad). |
| 12 push-master inbox notify | both OK (205, 174) | **agree with changes (rank last)** | The claim "10-15 status calls per push" is not reproduced. Claude transcripts modified in the last 2 days (`find ... -name '*.jsonl' -mtime -2 -path '*csi-spl-wt*' \| head -400`, tool_use commands): **182** sessions with a push, **347** `do_spl_push_master` starts, **369** `PUSH_CMD=status` calls -> per start **median 1.0, avg 1.4, max 7.0**. Vibe/m- transcripts are not in that set, and m-986's loop was one lane. A spool `note` on the verdict is fine, but it saves tokens, not owner minutes. Keep `PUSH_CMD=status` as the source of truth: the note is a doorbell. |

## 3. R1 and the batch shape

- As written: every batch has 4 rows on disjoint paths and 2 sat + 2 PC (batch 1: 01 sat, 02 PC, 03 PC, 04 sat; batch 2: 05 sat, 06 PC, 07 PC, 08 sat; batch 3: 09 sat, 10 PC, 11 PC, 12 sat). **R1 holds on paper.**
- On the real paths: rows 01 and 04 both test in `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` (the only test that names `spl_spawn_place` and `do_spl_spawn_enqueue`), so **batch 1 breaks R1** once the 5 missing test files are replaced by the real ones. Dropping 04 (or folding it into 01) fixes it.
- Vendor: rows 04, 07 and 11 are `simple_coding`, whose main vendor in the fleet split is mistral, not claude. Fine once v1.0 says why (R14), but the plan does not say.
- R1.1 caps a round at 10 rows; owner msg 6c1ed812 overrides it to 12, as the plan states. With 8 rows out, v1.0 can hold 4 surviving rows plus my 3 proposals, 7 in all, without padding.

## 4. Proposals (ranked by owner posts removed)

| # | action | measuring command -> number | target | replaces |
|---|---|---|---|---|
| P1 | **Topic status card.** Each owner topic that has an issue gets one card, kept up to date by the hub (edited in place, not a new post): issue key and state, lane id@box, queue position or "running since", landed sha, served dev/prd (row 09's check). It updates on queued / placed / landed / served / blocked. The owner reads it instead of asking. | `ENV=prd do_spl_db_query`: HUM-10 posts in t1, 7 days, matching `(what is the status\|^status\|status \?\|status report\|how many done)` -> **32 posts in 28 topics** (29 under 60 chars) | 0 status asks on topics with a card; red control: a topic whose lane landed shows `served dev/prd` on the card without an agent post | row 07 |
| P2 | **A hand-off never blocks the placer.** On a row it cannot launch, `spl_spawn_place_take` hands it to the orch **without** touching `.place.last`, and the next tick moves on to the next launchable row, so it stops "placing one at a time" behind an acked row. | `grep -c "no brief file for" cron.out` -> **12** hand-offs, each one also starting a 10-min gap (`spl-spawn-place.func.sh:239` touch before the brief check at `:240-241`); queue: 7 of 22 rows unlaunchable, waits 7547..20979 s | hand-offs cost 0 placement slots; red control: a head with no brief followed by a launchable row places the second one on the same tick | row 04 (also clears the R1 clash with row 01) |
| P3 | **The placement gap follows the lane, not the clock.** Replace the fixed `SPAWN_PLACE_GAP_MIN=10` with "the last placed lane has its first heartbeat (or 10 min passed)", with a 3-min floor, and keep the load target and the 40 ceiling as the guards. The fixed 10 min came from the PC overload of 10-11, which the load target now holds. | `grep -oE 'hold: [a-z ]+' cron.out \| sort \| uniq -c` -> **1418** gap holds vs **37** load-target holds: the clock held while the load target said room. 22 rows queued, median wait 12713 s | queue median under 1 h at the same load; red control: with the load target saying hold, nothing places whatever the heartbeat says | row 06 |

Owner minutes for P1-P3: not measurable by a command. The numbers above are owner **posts**, and for P2/P3 the owner topics where "queue/stuck/idle" appears, 12/week.

## 5. Status

Verdict sent to a-240@sat on `dispatch-999a50bd`. I stay up for v1.0 signing and then as an R7 row reviewer (cross-vendor: I review non-claude rows).

signed: c-247@sat on 4083c5af1 (v1.1: send-back points 1-5 folded, rows 02/05/08/10 dropped; R1 checked: no path in two rows of one batch; batches 2 and 3 run fewer than 2+2 lanes because 8 rows remain)
