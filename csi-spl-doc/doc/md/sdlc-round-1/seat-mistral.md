# SDLC round 1 - claude takeover of the mistral seat

Seat: **c-251@sat** (claude), the claude takeover of the mistral seat (m-248@sat had its 2 tries, owner rule 2026-10-12). Editor a-240@sat. Task `dispatch-999a50bd`. Issue SPL-2058 (seat lane SPL-2071).

Plan read: `sdlc-round-1-plan.md` **v1.3** (`17d56326d`, 7 rows). Nothing from the earlier content of this file is reused.

**Tree:** code read on `origin/master` `e073ccedf`, re-fetched to `0af615b8c` before writing. `git diff --stat e073ccedf 0af615b8c` touches only `perf-round-6/` docs, so every code citation holds on both. The plan measured on `d0950b1e3`. `git diff --stat d0950b1e3 origin/master -- csi-spl-orc/src/bash/run csi-spl-orc/src/bash/features/spawn-agents/scripts` is empty, so the cited code has not moved since then. Live data (spool, cron logs, prd hub, GitHub, transcripts) was read on sat between 2026-10-16 00:19Z and 00:45Z. Each output below gives its n.

**Tally: 1 agree / 3 agree with changes / 3 disagree / 2 proposals** (rows), plus section 1: 1 agree / 3 agree with changes / 3 disagree.

In short: the queue rows (01, 04, 06) are real, but they go after the wrong half. The binding limit is the 10-minute gap, and half of row 04 is already on master (`68edb2656`, SPL-2042). Row 11 cannot work from a sat lane, because the closer has no cursor and no cron on sat. Row 12 cites lines past the end of its file. The biggest owner-time driver in the hub data (66 "go / yes / ok" posts a week) has no row.

## 0. Owner-time baseline (re-measured, prd hub, tenant t1, last 7 days)

All rows below come from `ENV=prd SQL="..." ./run -a do_spl_db_query` (csi-spl-orc) on `messages`. The subject rows match a regex on `lower(body)`, so they are a proxy.

| subject | my regex | owner posts | topics | plan v1.3 |
|---|---|---|---|---|
| all owner posts | `from_id='HUM-10'` | **1108** (of 15006 posts) | - | 1108: agree |
| status asks | `what is the status\|^\s*status\M\|status ?\?\|status report\|how many (are )?done` | **32** | 28 | 32 / 28: agree |
| status, wider (`+ where are we\|any (news\|progress\|update)`) | | 32 | 28 | the wider words add 0 |
| deployed / live / served / prd | `deployed\|\mlive\M\|served\|\mprd\M` | **18** | 13 | 11: depends on the regex |
| issue | `\missue\|spl-[0-9]+` | 64 | 47 | 10 ("issue state"): my regex is broader, so neither number proves lag-driven posts |
| queue / stuck / idle / not placed | | 12 | 9 | 12: agree |
| push | `\mpush` | 10 | 6 | 2 |
| **go / yes / ok nudges** | `^(continue\|go( on\| ahead)?\|proceed\|ok\|okay\|yes\|do it\|agreed\|approved)\M` | **66** | 47 | **not measured** (proposal P1) |
| still / again / not fixed | `still (not\|broken\|the same\|there)\|not fixed\|again` | 19 | 16 | not measured |
| short posts (< 60 chars) | `length(body)<60` | 442 | 143 | - |

Of the 66 nudges, 60 follow an agent post. 20 of those agent posts carry a `?`, and 14 ask for a go explicitly (`shall i|should i|do you want|go\?|your go|approve|confirm` or a poll). 22 nudges are 12 characters or shorter: `go` x10, `yes` x7, `ok` x2. The median gap between the agent post and the owner nudge is 108 s. Rounds need no owner go (rulebook 1.4), so these posts are owner minutes that no plan row removes.

**Owner minutes and tokens:** no row's "owner minutes/week" or "tokens/week" figure (185 min, 115k tokens) comes from a command. The measurable unit is the number of owner posts a row removes, so each row below is judged by that.

## 1. Section 1 measurements, re-run

| § | plan claim | my command | my output (n) | verdict |
|---|---|---|---|---|
| 1.1 | queued n=34, med 12713 s; cause: slug prefixes | `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub SPAWN_QUEUE_FORMAT=json SPAWN_QUEUE_SHARE=0 ./run -a do_spl_spawn_queue`, python on `.queue[].wait_s` | `n=24 queued, min=43 med=15414 max=24660 avg=11963` (s) | **agree with changes.** `wait_s` covers rows still in the queue only (rows already placed have left), so it is not "ask -> placed". The cause ranking is wrong. In `/var/csi/csi-spl/spawn-place/cron.out` (6168 lines), `grep -oE 'hold: [a-z ]+' \| sort \| uniq -c` gives **1467** "last placement started under 10 min" holds against **37** "load target says hold". There are only **27** hand-offs in total (`grep -c "handed to"`): 12 "no brief file" plus 15 "no placement was recorded". The log has **152** `OK ask .. placed:` lines. The placer ticks once a minute, so about 9 gap holds per placement is the expected shape: 152 x 9 = 1368, against 1467 measured. The 10-min gap is the binding limit of 6 placements per hour: a 24-row queue drains in at least 4 h, which matches the median. |
| 1.2 | placed -> first push: n=15, med 8m45s | the plan's `git log --grep="SPL-" -n 15 --format="%H %cd"` | prints 15 shas and dates, with no spawn time | **disagree.** That command cannot produce the claimed numbers. My proxy is lifetime `prompt.txt` mtime -> first `origin/master` commit naming the lane's `lifetime/issue` key, last 7 days: `n=3 min=8.5m med=13.0m max=15.3m`. n=3 suggests a value; it does not show one. |
| 1.3 | n=41 keys, avg 1.63, med 1 | the plan's command, verbatim | `n=104 min=1 max=14 avg=1.96 med=1 keys_with_1=63` (225 commits in 24 h) | **agree with changes.** It counts commits per key, not pushes per lane, because one key covers a whole round (max 14). Use `med`, not `avg`, for the 1..1 target. |
| 1.4 | `gh run list --workflow=20_cd-hub.yml` / `30_cd-wui.yml` | the plan's command | `HTTP 404: Not Found (.../workflows/20_cd-hub.yml)` | **disagree on the command, agree on the size.** The files are `20_hub-build-deploy.yml` and `30_wui-build-deploy.yml` (`git ls-tree origin/master .github/workflows/`). Re-run on success runs: hub `n=18 min=13.2m med=20.4m avg=20.2m max=25.6m`, WUI `n=18 min=7.6m med=8.4m avg=9.0m max=17.4m`. |
| 1.5 | 161 ACCEPTED, 123 matched, med 35 s, p90 892 s | Python: every body starting with `ACCEPTED` in `/var/spool-hub/c-00[23]*/outbox` in the last 7 days, matched to the newest `kind: result` on the same task from the same lane (all outboxes plus the c-00[123] inbox/archive) | `n=252 matched=156 min=4s med=44s avg=3253s p90=1849s max=72306s over15m=23` | **agree with changes.** The median is under a minute. In the tail, a code lane cannot be ACCEPTED before its deploy, which takes 8..20 min (1.4). So row 09's "< 30 s" target holds only for docs-only lanes. |
| 1.6 | 40 runs, 1 failure, 14 red min | `CI_GATE_RUNS=40 ./run -a do_report_ci_gate` (csi-spl-iac) | `40 runs 2026-10-15T21:22:50Z..2026-10-16T00:15:37Z: 23 success, 17 cancelled`, `no failed run in the window`, every job p90 at or under 51 % of its timeout | **agree.** Trunk is green now. The 17 cancelled runs (42 %) were superseded by newer pushes, which is normal under concurrency cancel. |
| 1.7 | 8..10 manual steps per lane | spawn-place cron.out, `exit-clean`, manifests | 152 placer launches vs 27 hand-offs (85 % of placements need no hand) | **disagree.** Steps 4 (launch) and 5 (`do_spl_spawn_placed`) are manual only for hand-offs: the placer launches and closes the rest itself (`spl_spawn_place_launch` -> `spl_spawn_placed_close`, `spl-spawn-place.func.sh:260-279`). Step 9 (retire) is `tmux-close-window.sh --defer --retire`, run by `/exit-clean`. Step 10 (issue close) is the hourly closer. The plan gives no command and no n for this list. |

## 2. The 7 rows

Cited files on `origin/master` (`git cat-file -e` + `wc -l`): `spl-spawn-place.func.sh` 315, `spl-spawn-queue.tst.sh` 482, `check-deploy-lag.tst.sh` 128, `spl-issue-close-landed.func.sh` 152, `spl-issue-close-landed.tst.sh` 167, `spl-push-master.func.sh` **205**, `spl-push-master.tst.sh` 174. `topic-status-card.sh`, `test-topic-status-card.sh` and `check-lane-served.func.sh` are new and absent, as stated.

| # | row | verdict | why (command -> output) |
|---|---|---|---|
| 01 | placer slug normalize | **agree with changes** | It is real. Of 24 queued rows now, 10 carry a hand prefix (7 `hand-sat-`, 3 `sathand-`). Every one of the 7 `hand-sat-*` rows misses as-is and **resolves after stripping** (`[ -s briefs/<stripped>.md ]` -> 7/7 HIT). Of the 10 slugs named in a "no brief file" hand-off, 10/10 resolve once stripped. **Changes:** (a) the prefix is the dispatcher's box intent (`c-002` outbox `20261015T220135Z...`: `claude:hand-sat-c002-t1r-seat-claude`, next to unprefixed rows in the same ask). Stripping it and launching `auto` would drop that intent, so pass it as `SPAWN_BOX=<box>` (`spawn-window.sh:76`, "SPAWN_BOX=<box> always wins"). (b) A pinned box skips the per-box load pick, so the red control must also show a pinned launch HOLDs when that box is past its mark (the 10-10 lesson: a sat pin starved CI). (c) `git grep -e hand-sat -e sathand origin/master` -> 0 hits outside this round's docs. The prefix is a convention with no home, so the row must write it down in the action's `@description`. (d) R2 test column: add `spl-spawn-fill.tst.sh` and `spl-security-round-queue.tst.sh`, which also name `spl-spawn-place`. Owner posts it removes: 0 measured directly. Its value is queue time. |
| 07 | topic status card | **agree with changes** | It targets the 32 status asks in 28 topics (section 0), which is real. The daily owner digest (`owner-digest-cron.sh`, `not the hour (9:00 Europe/Helsinki)`) is not per topic, so nothing duplicates it. **Changes:** (a) the row lists a new script and its test but **no caller**: no cron line in `cnf/box-crons/box-crons.manifest` and no hook in the asks tick. Its red control ("updates on state transitions") cannot pass without one, so name the caller file in the row. (b) "0 owner status asks" is not a target a script controls. Use "status asks in carded topics per week, by the section 0 SQL". (c) A card edit must not notify the owner: the edit-in-place path exists (`spl-asks-tick.func.sh:417`, "edited in place (its author edits it)"), so reuse it and test that no new message row is written. (d) The 65 owner min / 35k tokens figures are unmeasured. |
| 09 | lane served verification | **agree with changes** | Most of it already exists, in three places. Ancestry: `git-fetch-fresh.sh --landed` ("0 landed, 1 not landed"). Identity: `spl-push-master.func.sh:181` refuses a `%ae %ce` mismatch before the push. Served per env: `check-deploy-lag.func.sh` ("is the commit under test actually SERVED by that env's hub and WUI"). Only the trailer check is new: `git grep -i co-authored origin/master -- csi-spl-orc/src/bash/features/spawn-agents/hooks csi-spl-iac/src/bash/run` -> 0. **Changes:** (a) compose those three and add only the trailer check; do not re-implement them. (b) A docs-only commit gets no deploy (developer guide 1.4), so the verdict needs a `served=n/a` arm or it FAILs forever. (c) The test belongs in a new `check-lane-served.tst.sh`: `check-deploy-lag.tst.sh` tests another action, and `hub-deploy-guard.tst.sh` also names `check-deploy-lag`. (d) The target "< 30 s" holds for docs lanes only: a code lane waits 8..20 min for its deploy (1.4). Owner posts in scope: 18 / week (section 0). |
| 04 | placer hand-off unblock | **disagree as a separate row: fold it into 01** | Half of it is on master: `68edb2656` fix(orc, SPL-2042) "the spawn placer no longer blocks the queue on a hand-off" (`git merge-base --is-ancestor 68edb2656 d0950b1e3` -> true, so it is also on the plan's own sha). What remains is that `touch .place.last` (`spl-spawn-place.func.sh:239`) still runs before the brief check at :240, so a hand-off spends one 10-min gap: at most 27 x 10 min across the whole log. Moving that touch into the launch branch is a 1-line edit in the same 20 lines (235-256) row 01 edits, with the same test file. Do it in row 01. The plan's "120+ minutes per stalled cycle" is the pre-`68edb2656` behaviour. Also, `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-place.func.sh --agent c-251` -> exit 4, and its unknown list names **c-233@sat `c-233-c001-placer-handoff-no-block`**, the live lane of that fix. Ask it before spawning (R3). |
| 11 | issue close on landing hook | **disagree** | The closer only works where its cursor is. On sat: `ls ~<DEV_USER>/.local/state/csi-spl/issue-close-landed/prd-t1` -> empty, and `crontab -l \| grep box-cron:issue` -> no line. `issue-close-landed-cron.sh:35-37` then says "no cursor ... the box where the back-fill ran sweeps" and exits 0. A hook in `do_spl_push_master` runs on the lane's box, so for every sat lane it is a silent no-op, and that is 4 of the plan's own 7 rows. **Replacement (P2):** the 59-min bound comes from the manifest line `issue-close-landed \| 37 * * * *` (`box-crons.manifest:28`), so change the cadence on the one box that sweeps. That is one line, with no new code path and no new failure mode. The "10 owner posts/week on issue state" figure is a regex count, and none of it is shown to be caused by lag. |
| 12 | push-master inbox notify | **disagree** | The cited site `spl-push-master.func.sh:190-260` runs past the end of the file (`wc -l` -> 205). The worker is `_spl_push_master_worker` at :158 and the status writer `_spl_push_master_end` at :116-121. Measured cost: across 313 sat claude sessions in 7 days, `do_spl_push_master` starts=**552**, `PUSH_CMD=status` calls=**655**, which is **1.19 status calls per push** (session median 1.33, max 9.0). `PUSH_CMD=status` returns at once (`:91-107`), so it cannot hit the 15-min call cap. The "watchdog timeout" failure the row claims to prevent is not how the action works, and "~200k tokens per lane" does not follow from about 2 short calls per session. Owner posts it removes: 0 ("push": 10 / week, none shown to be push-status polling). R2 test column misses `test-pre-push-review-line.sh`, `test-seed-not-in-argv.sh`, `test-spawn-seed-size.sh`. Replace it with P1. |
| 06 | dynamic placement gap | **agree** | This is the binding constraint by measurement: 1467 gap holds vs 37 load holds, at 6 placements per hour maximum (1.1). The row keeps the load-target guard (`spl_spawn_place_no_room`, :205) and a 3-min floor, so it degrades to today's behaviour. One condition: a "heartbeat" source must be named. `git grep -il heartbeat origin/master -- csi-spl-orc/src/bash` lists only watchdog and agent-hook files, so the row should name which of those signals it reads. Rank: this row moves the queue median most, so it belongs in batch 1, not batch 3 (section 3). |

## 3. R1 check

- **Within a batch, no path repeats.** I checked batch 1 {01: place + queue test; 07: 2 new; 09: new + deploy-lag test}, batch 2 {04: place + queue test; 11: closer + its test; 12: push-master + its test} and batch 3 {06}. R1 holds as written.
- **"3 batches of 4 rows, each 2 PC + 2 sat": fails.** v1.3 has 7 rows in batches of 3 + 3 + 1 (sat/PC: 2+1, 2+1, 0+1), so three lanes run, not the owner's four (msg `a29ba4db`).
- **Serial chain:** rows 01 -> 04 -> 06 all edit `spl-spawn-place.func.sh` and `spl-spawn-queue.tst.sh`, one batch after another. A slip in 01 delays the highest-value row (06) by two batches.
- **Proposed layout (6 rows + P1 + P2 = 8 rows, 2 batches of 4, each 2 sat + 2 PC):**
  - Batch 1: 01+04 merged (sat), 07 (PC), 09 (sat), P2 closer cadence (PC; `box-crons.manifest` plus its test `install-box-crons.tst.sh`).
  - Batch 2: 06 (sat, after 01+04), P1 (PC), plus 2 rows the editor picks.
  - The paths in each batch are disjoint by the lists above, plus the manifest and its test for P2.
- **R3 now:** `lane-map.sh --check <each row path> --agent c-251` -> exit 4 for every path. No live lane lists any of them, but 4 lanes record no files: c-233@sat (placer-handoff-no-block), c-296@PC, c-547@PC, c-550@PC. Only c-233 matches a row's topic (04).

## 4. Proposals (ranked by owner posts removed per week)

| # | action | measuring command -> number | replaces |
|---|---|---|---|
| P1 | **No go-asks in owner topics.** A send-side check (spool-send / hub post to an owner topic) refuses a post that asks the owner for a go (`shall i\|should i\|do you want\|go\?\|your go\|approve\|confirm`) unless the post names the rule that needs him: an apply, an IAM change or a prd mutation (repo CLAUDE.md "Nothing mutates GCP without the owner"). Rounds and consensus builds need no go (rulebook 1.4), so the agent proceeds and reports. Safe degradation: the check refuses with the reason, nothing is posted silently, and a post that names a real gate passes. Red control: `"Shall I proceed?"` to an owner topic is refused; `"needs your go for terraform apply step 040"` passes. | section 0 SQL -> **66 owner nudges / week in 47 topics**: 60 follow an agent post, 20 of those carry a `?`, 14 ask for a go explicitly, and 22 are 12 characters or less (`go` x10). | row 12 |
| P2 | **Closer cadence.** `issue-close-landed` in `box-crons.manifest:28` goes from `37 * * * *` to `*/5 * * * *` on the box that holds the cursor, with test `install-box-crons.tst.sh`. The closer already locks (`flock -n 9`, `issue-close-landed-cron.sh:41`) and keeps a ledger, so a faster cadence cannot double-close. If a run fails, the next one 5 min later sweeps the same range from the cursor. | bound: `grep issue-close-landed box-crons.manifest` -> `37 * * * *`, so the lag is up to 59 min by construction. On sat: no cursor, no cron (row 11 above). | row 11 |

There is no third proposal. The other candidate I measured, 17 of 40 CI runs cancelled (1.6), is CI time spent on superseded pushes, not owner time, and the concurrency cancel is already the right control.

## 5. Evidence notes

- Every number above comes from a command run in this session on sat, 2026-10-16 00:19Z..00:45Z, against `origin/master` `e073ccedf` / `0af615b8c`. No number is copied from the plan or from another seat.
- Regex counts on owner posts are proxies: one post can match two subjects, and a match is not proof of intent.
- Transcript counts (row 12) cover claude sessions under `~<HARNESS_USER>/.claude/projects` on sat only (2359 files touched in 7 days). They do not cover the PC box, mistral, agy or grok.

## 6. Sign-off on v1.4

Plan v1.4 (`c48a12536`) re-read on `origin/master`. Every point of this verdict is folded in: 04 is merged into 01, 11 and 12 are replaced by P2 and P1, 07 names its caller, and 09 reuses the existing checks. That gives 6 rows in 2 batches, 4 + 2, with each batch's paths disjoint. Checked with `git cat-file -e origin/master:<path>`: every existing path the rows cite resolves, including `test-spool-send.sh` and `install-box-crons.tst.sh`.

Two conditions for the row briefs. Neither is a send-back, and neither blocks batch 1:

- **Row 06, batch 2, heartbeat source.** `/var/spool-hub/<agent>/lifetime/lane.log` is not a heartbeat. `find /var/spool-hub -maxdepth 4 -name lane.log` finds 1141 copies, all at `<id>/lane.log` and none under `lifetime/`. `spawn-core.inc.sh:209` writes that file once, at spawn: it is the `lane-map.sh put` output, so it exists even for a lane that never started. The real signal is `<spool root>/<id>/heartbeat.json`, field `progress_ts`. `spool-agent-hook.sh:7-12` writes it, and it moves only on tool calls; `ls /var/spool-hub/*/heartbeat.json | wc -l` -> 40. That file sits on the lane's own box, so for a lane placed on the PC box the placer must read it remotely or keep the 10-min gap. Either way, the row's red control has to cover a lane that never writes a heartbeat.
- **Row 11 path.** The manifest is `csi-spl-orc/cnf/box-crons/box-crons.manifest`. The row's `cnf/box-crons/box-crons.manifest` does not resolve at the repo root.

signed: c-251@sat on c48a12536

## 7. Sign-off on v1.5

Plan v1.5 (`27b67f17e`) re-read on `origin/master`. Both v1.4 conditions are folded in: row 06 now reads `<id>/heartbeat.json` `progress_ts`, and row 11's path is `csi-spl-orc/cnf/box-crons/box-crons.manifest`. Its test line `install-box-crons.tst.sh:78` pins the `+37 * * * *` schedule. Every existing path in section 4.1 resolves (`git cat-file -e`), and each batch's paths are disjoint as listed.

Two notes for the row briefs. Neither is a send-back:

- **Row 07, batch 1:** the row names the edit mechanism (`do_spl_desk_edit`) but still no trigger, meaning nothing says what runs `topic-status-card.sh`. If the trigger is a new cron line, it lands in `box-crons.manifest`, which row 11 edits in the same batch, and R1 breaks. The brief must name the trigger, and it must not be the manifest while row 11 is open (or row 07 waits for row 11 to land).
- **Row 12, batch 2:** `csi-spl-orc/src/bash/tests/spl-desk-post.tst.sh` does not exist and is not marked "(new)". The tests that name `spl-desk-post` / `do_spl_desk_post` today are `desk-actions.tst.sh`, `box-workspace-isolation.tst.sh` and `dispatch-setup-check.tst.sh` (`git grep -l`). They belong in its R2 test column.

signed: c-251@sat on 27b67f17e

## 8. Seat closed

Accepted by the dispatch holder c-002@sat on 2026-10-17 (spool msg `7c29c692`, task `dispatch-999a50bd`): the v1.5 signature `de548b2d1` is on `origin/master`, and the round's only open row, 06 (SPL-2274), goes to a claude takeover reviewed by the agy editor. This seat has no job left.
