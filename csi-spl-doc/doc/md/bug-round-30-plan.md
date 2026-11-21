# Bug-fix round 30 - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6108 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `edac9537-e7fe-421d-a517-d04c084e7782` ("Bug round 30", opener msg 70a2b366, opened by c-003@sat ~21:49Z). Round 29 ([bug-round-29-plan.md](bug-round-29-plan.md) v1.0 `cf39b5581`, 2 rows) is served: b29-01 `ac367b7a5` (SPL-6089), b29-02 `ae4898ae1` (SPL-6093); SPL-6080 done. Bug share at queue time: 4 of 27 known live lanes, 14% (band 30-40%: under).  
Round focus: three orc defects that break a written rule or leave work for good: the placer takes a `ci` row first only when it is the queue's head (row 01), no sweep ever removes a dead lane's `/tmp` worktree (row 02), and an `After:` row slug placed on another box is released on this box's lane of the same id (row 03, added in v0.2).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Three inputs give a live, unowned defect with a red control that fails on `origin/master` (the 3rd came from the holder after v0.1, msg e86b574b); every other input is accounted for in sections 2, 4, 5 and 6.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-29-plan.md](bug-round-29-plan.md) (same shape, same 5 sources).

**Status: v1.0, the panel passed v0.2 `2c3e1932a` with no W (section 8); landed as `b67431a30` (holder GO 394cb574).**

**Round closed** (c-448, the editor; dispatch holder c-002@sat): all three rows landed. b30-01 `9b680e7b5` (SPL-6125, R7 c-504 claude waiver seat PASS on `3d51b9937`), b30-02 `b341f7bb8` + `82d1b51da` (SPL-6128, R7 c-529 PASS on `62f445325`, then its W1 held blocking by the holder, PASS on the fix `a6e88f960`), b30-03 `6f2a343bb` + test `252de9ad2` (SPL-6129, R7 c-531 PASS on `c724b4ef6`); each reviewed sha's `git patch-id --stable` equals its landed one (`5342022ff`, `d6f666083`, `50f545f70`, `975898a1f`). Read at 03:3xZ on `ad950c0e8`: `git merge-base --is-ancestor <sha> origin/master` -> rc 0 for all four row commits; `rc01.sh`, `rc02.sh` and `rc03.sh ad950c0e8` -> `wrong=0`, rc 0 each (n=1). CI, wf 10 (quality gate): `success` on `9b680e7b5`; `cancelled` on `82d1b51da` and on `252de9ad2` (each a later push's head); `pending` on `ad950c0e8` at 03:3xZ; wf 15, 25, 26 and 64 `success` on every row head.

Editor: **c-448@`<box2>`** (claude, `specs_and_docs`; agy, the kind's main, is out: a-233 on its agy limit until 11-24).  
Panel: m-551@sat (mistral, the b30 panel seat, ask `c002-bug-round-30-mistral-panel-seat`): **PASS** on v0.1 `26492502f` (msg b5e0931a, seat file `4d2764cbf`), no W; **PASS** on v0.2 `2c3e1932a` (msg 5b2cb473, seat file `d729bdb5a`), no W (section 8).

**One sha:** every count below is measured on **`4ad1b80a8`** (`origin/master` at this seat's fetch of 00:52Z), on `<box2>`, between 00:52Z and 01:05Z on 2026-11-21, unless a row says otherwise. n=1 per command unless stated. The worktree sits on `4ad1b80a8` itself.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b29-plan')` -> `Window: W=2026-11-20T21:05:53+02:00` (commit `cf39b5581`, b29 v1.0), the value the brief quotes.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 29. `<PUSH_USER>` is the OS user that owns the checkouts and pushes, `<AGENT_USER>` the OS user the agents run as (the public repo names neither).

---

## 1. How to read this

- Round 29 measured on `cbbc11996`. This plan re-measures what changed since (`git rev-list --count cbbc11996..4ad1b80a8` -> 63 commits; `git rev-list --count --since="$W" 4ad1b80a8` -> 55), round 29's first inputs for round 30 (its section 7), the holder's candidates file (sent whole by c-002@sat, msg f04410a0: it lives on sat only), the b29-01 R7 notes (c-334, the brief), and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `4ad1b80a8`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `4ad1b80a8`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since round 29** | `cd csi-spl-orc && sudo -u <PUSH_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|leak)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%'), count(*) filter (where body ~* '(altgr\|enter\|picker\|switcher\|kind pick)') from messages where ts > '2026-11-20T18:18:20Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (00:57:47Z), then the same filters listing each post | t1: 41 posts, 2 with a bug word, 24 `[spool-probe]`, 1 picker / switcher word; csitea: 6 posts, 0 bug words, 1 picker word; a third tenant: 1 post, 0 | **0 rows** from new reports. t1's two owner bug reports are served: the phone workspace switcher's scroll (topic b08c3fa8, 21:18:53Z) by `7032f150b` (SPL-6106, 23:28Z), and "does not work on the topic levels neither" (topic 703f2ce5, 22:07:18Z, Export to PDF on a phone) by `7f4ab4743` (SPL-6110, 00:39Z); both commit bodies quote the topic. The csitea picker hit is a poll answer (21:11:53Z), not the AltGr or Enter question. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (started 00:52Z) | wf 10: 100 runs (2026-11-20T09:58Z..2026-11-21T00:51Z): 59 success, 31 cancelled, 7 failure, 3 running. Failed runs since round 29's read (18:15Z): 44795738015 (`cc13eac0b`) and 44799218697 (`7a0e5df68`), first red `TestTopicLoopSweepPickIndexOnly` (hub pg); 44832401773 (`5f1e27bc7`, 22:51Z), first red `tests/e2e/workspace-doc-preamble.test.mjs` (exit 1, then exit 1 on retry). Newest completed runs: 44844503795 (`28f802950`, 00:32Z) and 44839070705 (`2b7bb502a`) `success` | **0 rows** from a red. The pg red is spec 182's (`7a0e5df68` test(orc, SPL-6033) and `ea426e41f` SPL-6030 touch that index), green since 19:2xZ. The e2e red is n=1 on a seat-state commit, after `5dff872e3` (SPL-6083, c-488's live WUI Qto doc view header lane, 21:44Z) changed that header; green since: R3, left with that lane (section 6). `gcp-billing-invoices.tst.sh` `download iframe`: 1 sighting in this window (44725157504, the one round 29 counted as the 2nd), no 3rd. `grep -c agent-name-shape <the report>` -> 0. |
| **3. Skipped or disabled tests** | `git diff cbbc11996 4ad1b80a8 -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 1 file: `csi-spl-doc/doc/md/bug-round-29-plan.md` (its text quotes `t.Skip`) | **0 rows.** No test file was skipped. |
| **4. Box cron logs** | `<box2>`: `/var/csi/csi-spl/done-claim-check/cron.log` from the first run after round 29's read (line 54115, 18:20:01Z) to 00:5xZ: `grep -c START`, `grep -cP '\talert\t'`, `grep -cE 'job [0-9a-f]{6,}'`, the `STOP ... rc=` codes | 30 runs: **29 `rc=124`** (each stopped at the 600 s cap), 1 running; 0 `job <hex>`; 6 alert rows: 3 on `00b915582` (c-975, a-045: spec 182 L3, a commit not on `origin/master`, `git merge-base --is-ancestor` -> 1), 3 `no-sha` (c-049, c-256) | **0 rows.** The `job` label input did not occur. The `00b915582` alerts are true answers (an unlanded sha of a live lane). The `rc=124` timeouts are the run-time defect round 29 handed to the holder as a perf input (section 6). |
| **5. Round 29's first inputs, the holder's candidates, the R7 notes** | round 29 section 7; the candidates file (84 lines as sent, its "next BUG round" and "Bug-shaped" entries); b29-01 R7 N1, N2, N6 (c-334 msg on 2421505485b8, PASS no W) | 10 + 17 + 3 inputs | **3 rows**: 01 from the candidates file's 22:1xZ entry (c-001 b96b804a, the CI-first rule), 02 from round 29's section 6 / 7 input (dead lanes' `/tmp` worktrees, c-001 82c02da9), 03 from the holder's 01:1xZ entry (c-001 d77d912f, sent as msg e86b574b after v0.1). The others: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `4ad1b80a8`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b30-01-orc-place-ci-row-first)` | **The placer takes a `ci` row first only when it is the queue's head.** The rule (fleet rules index, SPL-1817 row): "The placer takes a `ci` row first, then a flagged one ..., then a priority 1 head as it is ..., then the class furthest under its band". The queue's order is priority first, then class (`askPositions`, `fleet_ask.go:293`, spec 150 3.4, owner poll Q5 A), so a `ci` row on an unset discussion (3) sits behind every priority 1 or 2 row. `spl_spawn_place_band` (`spl-spawn-place.func.sh:439`) tests `class == "ci"` on HEAD only (`:441`); the band pick then maps `ci` to `bug` (`:454`, `def cls`), so a `ci` row behind the head is taken only when bug is the class furthest under its band, and never ahead of a priority 1 head (`:442`). | c-001 b96b804a (candidates file 22:1xZ, n=1, not re-measured by the holder): ask da2ca42f, class ci, at position 14 of 37 on 2026-11-20 23:3xZ. Re-measured on `<box2>` 00:56:17Z: `./run -a do_spl_spawn_queue` -> 35 queued, 0 of class ci (that ask has left the queue): **latent now**, live at the next trunk red. Code read on `4ad1b80a8` (the lines left). | `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:434-441` (`spl_spawn_place_band`'s comment and its HEAD test), `:45-48` (the action's @description, 3b. BANDS); the test `csi-spl-orc/src/bash/tests/spl-spawn-place-argmax.tst.sh` (section 1, band pick, `:77`); read only: `spl-spawn-place-owner-prio.tst.sh` (the priority 1 head), `csi-spl-api/.../store/fleet_ask.go` (`askPositions`) | `bash /var/spool-hub/dispatch/b30-red-controls/rc01.sh 4ad1b80a8` (section 3.2) -> `rc01 behind: took=refac-2 want=ci-3` / `rc01 behind-p1: took=feat-1 want=ci-2` / `rc01 head: took=ci-1 want=ci-1` / `rc01 none: took=refac-2 want=refac-2` / `rc01 sha=4ad1b80a8 wrong=2`, exit 1, n=3 (00:55Z). | `spl-spawn-place.func.sh` and `spl-spawn-place-argmax.tst.sh` only. `spl_spawn_place_band` takes the first queued `ci` row of ROWS by position (any position, any priority) before the flagged head, the priority 1 head, the review seat and the bands, and logs it (`INFO ci row: ask <id> ... first, ahead of the queue's order (SPL-1817)`). A `ci` row the placer cannot launch (`_l` false: held, no brief) is not taken by this step: the walk of `spl_spawn_place_take_next` stays as it is. The hub's order (`askPositions`) does not change: the rule is the placer's (the row's text), and the queue keeps priority first (spec 150 3.4). The suite: rc01's four cases (behind and behind-p1 red on `4ad1b80a8`; head and none controls). Commit body: rc01 on the fix -> exit 0 (`wrong=0`), on `4ad1b80a8` -> exit 1. The comment and the @description say "a ci row, wherever it stands". Docs: the SPL-1817 row already says it; `Docs: none (the rule's text is unchanged; the code now does what it says)`. | sat | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |
| 02 `fix(b30-02-orc-wt-dead-sweep-tmp-worktrees)` | **No sweep ever removes a dead lane's `/tmp` worktree.** `tmp-stale-sweep.sh` keeps a lane dir that is a linked worktree as `KEEP worktree` (`:141`) and says so (`:18-21`): it goes only when `workdirs.tsv` lists it, and `do_wt_dead_sweep` takes only worktrees under its `WT_ROOT` (`wt-dead-sweep.sh:129`, `[[ "${wt%/*}" == "$wt_root" ]] \|\| continue`). The retire lists the lane's own worktree, only when its dir is named for the id (`agent-id-retire.sh` `wt_list`), and `/var/tmp` entries (step 9), never a `/tmp/<id>-<rest>` worktree a seat made for a red control or a review. So such a tree stays for good. | c-001 82c02da9 (n=1, sat): 41 under `/tmp`, all grok review seats idle 110-191 h; 30 removed by hand (`/tmp` inodes 81% -> 48%). Re-measured on `<box2>` 00:54Z: `git -C <main checkout> worktree list \| awk '$1 ~ /^\/tmp\//' \| wc -l` -> **27**, all grok seats (`g-201-spl5595-review` .. `g546-spl5693-rv`); for each: 0 rows in `workdirs.tsv` (`awk -F'\t' '$1==p'`), 0 `registry.tsv` rows for its id, newest file 113 to 126 h old; `df -i /tmp` -> 51%. 19 are named `<agent-id>-<rest>`, 8 have no dash after the letter (`g273-...`, `g375-...`, `g539-...`, `g546-...`). | `csi-spl-orc/src/bash/scripts/wt-dead-sweep.sh:6-24` (header), `:118-124` (`list_dirs`), `:129-133` (the root filter and the id); the test `csi-spl-orc/src/bash/tests/box-disk-sweep.tst.sh` (section 2, dead worktrees, `:150-170`); comment only: `csi-spl-orc/src/bash/scripts/tmp-stale-sweep.sh:18-21`; read only: `box-disk-sweep.sh:267` (the `worktrees` step), `wt-dead-sweep-landed-by-patch.tst.sh`, `wt-dead-sweep-stale-dirs.tst.sh`, `wt-dirty-salvage.tst.sh` | `bash /var/spool-hub/dispatch/b30-red-controls/rc02.sh 4ad1b80a8` (section 3.2) -> `rc02 tmp dead planned: no want=yes` / `rc02 tmp alive kept: no want=no` / `rc02 tmp dashless untouched: no want=no` / `rc02 tmp non-id untouched: no want=no` / `rc02 wt-root dead planned: yes want=yes` / `rc02 default off: no tmp line: no want=no` / `rc02 sha=4ad1b80a8 wrong=1`, exit 1, n=3 (00:56Z). | `wt-dead-sweep.sh`, `box-disk-sweep.tst.sh` and the `tmp-stale-sweep.sh` comment only. A new knob `WT_SWEEP_TMP_ROOT` (unset = off, today's behaviour; the sweep-change rule: ships default-off): a linked worktree of `WT_REPO` directly under it whose name is `<agent-id>-<rest>` (`[acgmq]-[0-9]{3}-`, the `lane_ere` of `tmp-stale-sweep.sh:67`) is judged like one under `WT_ROOT`, with the id = the name's `<agent-id>` prefix: every check stays (role seat, alive record, cwd in use, dirty + salvage, on trunk or landed by patch, `WT_SWEEP_AGE_H`), the removal is `git worktree remove` (no `--force`) and `git branch -d`. A name with no such prefix is never touched (the 8 dashless trees stay: a later row if it is wanted). Not wired into `box-disk-sweep.sh`: turning it on is the holder's call after a dry run on each box (`WT_SWEEP_TMP_ROOT=/tmp ./run -a do_wt_dead_sweep`, its PLAN lines). The suite: rc02's six cases (the first red on `4ad1b80a8`). Commit body: rc02 on the fix -> exit 0, on `4ad1b80a8` -> exit 1, and the dry run's `DONE would-remove=<n>` on `<box2>`. Docs: the script headers, or `Docs: none (<why>)`. | sat | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |
| 03 `fix(b30-03-orc-after-slug-far-box-key)` | **An `After:` row slug placed on another box is judged by this box's lane of the same id.** `spl_spawn_after_key` (`spl-spawn-after.func.sh:57`) reads a slug's lane from `.place.slugs` as `<id>@<box>` and, with no key there, calls `li_key_of_agent "$SPOOL_ROOT" "${agent%@*}"` (`:67`): the `@<box>` is dropped, so it reads THIS box's `<spool>/<id>/lifetime/issue`, whoever holds that id here. Ids are reused across boxes, so the key of another lane is returned; the hub fallback `spl_spawn_after_hub_key` (`:86`, which filters by `agent_box`) is never reached. The file's own header (`:18-21`) says the lifetime file is read "for a lane of this box". A landed key there releases the dependent row before its prerequisite lands. | c-001 d77d912f (holder msg e86b574b, n=1, read from code and the sat placer log, not re-run): at 00:44Z P07 (c-463) was released; its `After:` P05 is `c-461@<box2>` with an empty key in sat's `.place.slugs` (line 407), and sat's c-461 is spec 123 P03 (SPL-6078, landed `1dc8b02e1`, `4ad1b80a8`); sat placer log `cron.out` line 145248. Re-measured on `<box2>` 01:1xZ: `<spool>/c-461/lifetime/issue` -> `SPL-6117`, its brief's heading `spec 123 row P05` and `After: c002-s123-p03-project-cost-mask`; `git log origin/master -E --grep='SPL-6117'` -> 0: **P05 has not landed**, so the release was early. The sat log line was not read here (sat only). | `csi-spl-orc/src/bash/run/spl-spawn-after.func.sh:64-73` (the `.place.slugs` read and the `li_key_of_agent` call), `:18-21` (the header's rule); the test `csi-spl-orc/src/bash/tests/spl-spawn-after.tst.sh` (section 6b, a slug placed on another box, `:302`); read only: `csi-spl-orc/src/bash/features/spawn-agents/lib/lane-issue.inc.sh:83` (`li_key_of_agent`), `spl-spawn-place.func.sh` (`ASKS_BOX`) | `bash /var/spool-hub/dispatch/b30-red-controls/rc03.sh 4ad1b80a8` (section 3.2) -> `rc03 far: key=SPL-6078 want=SPL-6100` / `rc03 here: key=SPL-6078 want=SPL-6078` / `rc03 bare: key=SPL-6078 want=SPL-6078` / `rc03 sha=4ad1b80a8 wrong=1`, exit 1, n=3 (01:12Z). | `spl-spawn-after.func.sh` and `spl-spawn-after.tst.sh` only. `li_key_of_agent` is called only when the `.place.slugs` agent is bare (no `@`) or its box is this box (`ASKS_BOX`); an agent of another box goes straight to `spl_spawn_after_hub_key` (held while the hub has no key, as today). `lane-issue.inc.sh` does not change. The suite: rc03's three cases in section 6b (far red on `4ad1b80a8`; here and bare controls). Commit body: rc03 on the fix -> exit 0, on `4ad1b80a8` -> exit 1. The header says the box check. Docs: the header, or `Docs: none (<why>)`. | sat | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01, 02 and 03, disjoint. Row 01: `spl-spawn-place.func.sh`, `spl-spawn-place-argmax.tst.sh`. Row 02: `wt-dead-sweep.sh`, `box-disk-sweep.tst.sh`, `tmp-stale-sweep.sh` (comment). Row 03: `spl-spawn-after.func.sh`, `spl-spawn-after.tst.sh`. Row 01's file sources row 03's at run time; they share no file, so either may land first.
- **Test column (R2):**
  - Row 01: `git grep -l 'spl_spawn_place_band\|place_band' 4ad1b80a8 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` -> `spl-spawn-place-argmax.tst.sh`, `spl-spawn-place-owner-prio.tst.sh`; and `spl-spawn-queue.tst.sh` (sections 10 and 20, the queue's order), `rc01.sh`.
  - Row 02: `git grep -l 'wt-dead-sweep' 4ad1b80a8 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features csi-spl-utl` -> `box-disk-sweep.tst.sh`, `wt-dead-sweep-landed-by-patch.tst.sh`, `wt-dead-sweep-stale-dirs.tst.sh`, `wt-dirty-salvage.tst.sh` (and `orc-shard-weights.txt`, a list, not a test); and `rc02.sh`.
  - Row 03: `spl-spawn-after.tst.sh` (it sources `spl-spawn-after.func.sh` through the placer); `git grep -l 'spl_spawn_after_key\|spl-spawn-after' ba7acd634 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` -> `spl-spawn-place-supply.tst.sh`; and `rc03.sh`.
- **Off limits** for the row lanes: every live and queued lane's files (below); `csi-spl-api/` (the hub's order), `agent-id-retire.sh`, `workdir-register.sh`, `lane-issue.inc.sh`, `csi-spl-utl/src/bash/scripts/workdir-sweep.sh` (read only). Row 02 removes nothing on a box: it ships off.
- **How the files were checked (2026-11-21, `<box2>`):**
  - 00:57:04Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-place-argmax.tst.sh,csi-spl-orc/src/bash/scripts/wt-dead-sweep.sh,csi-spl-orc/src/bash/tests/box-disk-sweep.tst.sh,csi-spl-doc/doc/md/bug-round-30-plan.md --agent c-448` -> `WARN no live lane lists` them; exit 4 for 3 sat lanes that record no files: `c-461-c002-s123-p03-project-cost-mask` (spec 123 P03, hub cost code, landed `4ad1b80a8`), `c-476-rotate` (an orchestrator rotation branch), `review/c002-bug-round-30-mistral-seat` (m-551, this round's panel seat, its seat file only). Sat half (c-002@sat msg 8bac2908, 01:0xZ, `grep -E 'spl-spawn-place\|spawn-place-argmax\|wt-dead-sweep\|box-disk-sweep\|tmp-stale-sweep'`): c-461 `origin/master...HEAD` 0 files, 0 dirty hits; c-476 0 files, 0 dirty hits; m-551 1 file (its seat file), 0 row-file hits, 0 dirty hits.
  - 01:13:13Z, row 03's files: `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-after.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-after.tst.sh --agent c-448` -> `WARN no live lane lists` them; exit 4 for c-461@sat and m-551@sat only, whose committed files are 0 and the seat file (holder, above): neither is a row 03 file. `git log origin/master --since=2026-11-19 -- <both files>` -> 0; `refactor-round-78-plan.md` names neither (`grep -c spl-spawn-after` -> 0).
  - 00:56:17Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `35 queued, 0 placing`; no slug names a placer or a sweep (`grep -iE 'place\|sweep\|disk\|wt-dead\|tmp'` over the 35 placements -> 0). The queued briefs are on sat: the holder's grep of the 35 (`briefs/<slug>.md`, the pattern above) -> 0 hits (msg 8bac2908).
  - Since round 29's sha: `git log origin/master --since=2026-11-20T12:00Z -- <the four row files>` -> `ae4898ae1` (b29-02) and `2547249ec` (b28-01), both landed and closed. Refactor round 78's plan (`refactor-round-78-plan.md` v1.0) names none of them (`grep -cE 'spl-spawn-place\|spawn-place-argmax\|wt-dead-sweep\|box-disk-sweep'` -> 0).
- **Slug b30 is unused as a round id** (`<box2>`, 00:52Z, on `4ad1b80a8`): `git log origin/master --since="$W" --oneline -E --grep='\(b30-'` -> 2, both the panel seat's state commit and its revert (`b86bcc246`, `5f1e27bc7`, `docs(b30-plan, ...)`); the row form `--grep='\(b30-[0-9]{2}'` -> 0. `git ls-remote origin 'refs/heads/review/b30-*' 'refs/heads/wip/*b30*' 'refs/heads/*-b30-*'` -> nothing (the remote holds `review/c002-bug-round-30-mistral-seat`, the seat's). `git worktree list \| grep -E 'b30\|bug-round-30'` -> 1, this planner's own (`c-448-c002-bug-round-30-planner`). sat's half (c-002@sat msg f04410a0): the briefs grep `b30-[0-9]{2}\|bug-round-30` -> 2 (this planner's and its mistral panel seat's), 0 row briefs; `git worktree list \| grep -cE 'b30-[0-9]{2}\|bug-round-30'` -> 1, the panel seat's (m-551), 0 row worktrees: **b30 is free on both boxes.**

### 3.2 Red controls run on `4ad1b80a8`

The three files are on `<box2>` in `/var/spool-hub/dispatch/b30-red-controls/`, and printed below so a seat on sat can rebuild them. `rc01.sh` 2488 B, `rc02.sh` 2365 B, `rc03.sh` 2021 B (`sha256sum` first 12 hex `a366e7466e55`, `e9277ae4c346`, `da931bbcc8d4`). Each exports `csi-spl-orc` of the sha with `git archive` (no worktree, nothing installed) and needs bash, git, jq (rc01, rc03) and python3 (rc02, the sweep's own alive check). rc02 builds its own fixture repo and rc03 its own spool in a temp dir; none reads a live queue, worktree, spool or credential.

| row | command | output on `4ad1b80a8` | who |
|---|---|---|---|
| 01 | `bash rc01.sh 4ad1b80a8`, from a checkout, n=3 (00:55Z) | RED in 3 of 3: `rc01 behind: took=refac-2 want=ci-3` / `rc01 behind-p1: took=feat-1 want=ci-2` / `rc01 head: took=ci-1 want=ci-1` / `rc01 none: took=refac-2 want=refac-2` / `rc01 sha=4ad1b80a8 wrong=2`, exit 1. Read: a `ci` row behind the head loses to the band pick (refactor under its band) and to a priority 1 head; a `ci` head and the plain band pick are right, as they must stay. | editor c-448 |
| 02 | `bash rc02.sh 4ad1b80a8`, from a checkout, n=3 (00:56Z) | RED in 3 of 3: `rc02 tmp dead planned: no want=yes` / `rc02 tmp alive kept: no want=no` / `rc02 tmp dashless untouched: no want=no` / `rc02 tmp non-id untouched: no want=no` / `rc02 wt-root dead planned: yes want=yes` / `rc02 default off: no tmp line: no want=no` / `rc02 sha=4ad1b80a8 wrong=1`, exit 1. Read: the same dead, clean, merged, idle tree is planned under `WT_ROOT` and ignored under the `/tmp` root; the controls (alive, dashless, non-id, default off) are right, as they must stay. | editor c-448 |
| 03 | `bash rc03.sh 4ad1b80a8`, from a checkout, n=3 (01:12Z) | RED in 3 of 3: `rc03 far: key=SPL-6078 want=SPL-6100` / `rc03 here: key=SPL-6078 want=SPL-6078` / `rc03 bare: key=SPL-6078 want=SPL-6078` / `rc03 sha=4ad1b80a8 wrong=1`, exit 1. Read: the slug placed as `c-461@box-b` gets box-a's own c-461 key, not the hub's row of box-b; the same id on this box and a bare id read the local file, as they must. | editor c-448 |

No prototype fix was written: each change is its row lane's, with its own red controls. There is no green control on this sha: the green half is the lane's.

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha>: b30-01 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree), sources its spawn-place functions and asks spl_spawn_place_band
# which queued row it takes. The rule (fleet rules index, SPL-1817 row): "The
# placer takes a `ci` row first, then a flagged one, then a priority 1 head".
# The share is a fixture (SPAWN_PLACE_SHARE): refactor under its band, bug and
# feature over theirs. Cases:
#   behind     : head feature prio 2, refactor prio 3, ci prio 3 at position 3
#                -> must take the ci row (RED when it takes another)
#   behind-p1  : head feature prio 1, ci prio 3 at position 2 -> the ci row (RED)
#   head       : ci at position 1 -> the ci row (control)
#   none       : no ci row -> the band pick, refactor (control)
set -uo pipefail
sha="${1:?usage: rc01.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$C" || exit 2
mkdir -p "$C/spool/asks"
share='{"known":4,"unknown":0,"bypasses":[],"by":{"refactor":{"n":0,"pct":0,"lo":20,"hi":30,"verdict":"under"},"bug":{"n":2,"pct":50,"lo":20,"hi":30,"verdict":"over"},"feature":{"n":2,"pct":50,"lo":40,"hi":100,"verdict":"in"}}}'
row() { printf '{"ask_id":"%s","state":"queued","class":"%s","priority":%s,"position":%s,"placement":"claude:%s"}' "$1" "$2" "$3" "$4" "$1"; }
ask() {  # ROWS-JSON -> the ask_id picked
  (cd "$C/csi-spl-orc" && PROJ_PATH="$PWD" SPOOL_ROOT="$C/spool" SPAWN_PLACE_SHARE="$share" bash -c 'set -uo pipefail
    do_log() { :; }
    for f in lib/bash/funcs/*.func.sh; do source "$f"; done
    source src/bash/features/spawn-agents/lib/spool-asks.inc.sh 2>/dev/null
    spool_asks_dir() { echo "$SPOOL_ROOT/asks"; }
    source src/bash/run/spl-spawn-share.func.sh; source src/bash/run/spl-spawn-place.func.sh
    spl_spawn_place_band "$(jq -c ".[0]" <<<"$1")" "$1" | jq -r .ask_id' _ "$1" 2>/dev/null)
}
bad=0
check() {  # NAME WANT ROWS
  local got; got="$(ask "$3")"
  echo "rc01 $1: took=${got:-none} want=$2"
  [[ "$got" == "$2" ]] || bad=$((bad + 1))
}
check behind    ci-3   "[$(row feat-1 feature 2 1),$(row refac-2 refactor 3 2),$(row ci-3 ci 3 3)]"
check behind-p1 ci-2   "[$(row feat-1 feature 1 1),$(row ci-2 ci 3 2)]"
check head      ci-1   "[$(row ci-1 ci 3 1),$(row refac-2 refactor 3 2)]"
check none      refac-2 "[$(row feat-1 feature 2 1),$(row refac-2 refactor 3 2)]"
echo "rc01 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha>: b30-02 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree) and runs its scripts/wt-dead-sweep.sh as a DRY RUN on a fixture
# repo with clean, merged worktrees idle for 5 days. WT_SWEEP_TMP_ROOT is the
# knob the fix adds (off by default); <sha> without the fix ignores it.
#   T/g-901-review : a dead lane's /tmp worktree -> must be PLANned (RED when not)
#   T/g-902-review : its agent record says alive -> KEEP alive (control)
#   T/g903-review  : no <agent-id>- prefix       -> no PLAN line (control)
#   T/x-review     : not an agent id             -> no PLAN line (control)
#   W/g-904        : under WT_ROOT, dead         -> PLANned on both (control)
#   the same run without WT_SWEEP_TMP_ROOT       -> no /tmp line (default off)
set -uo pipefail
sha="${1:?usage: rc02.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$C" || exit 2
R="$C/repo" W="$C/repo-wt" T="$C/tmp" S="$C/spool"
mkdir -p "$W" "$T" "$S/agents"
git init -q -b master "$R" && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
for p in "$T/g-901-review" "$T/g-902-review" "$T/g903-review" "$T/x-review" "$W/g-904"; do
  git -C "$R" worktree add -q --detach "$p" master
done
printf '{"alive": true}\n' >"$S/agents/g-902.json"
find "$T" "$W" -exec touch -h -d '5 days ago' {} +
run() { SPOOL_ROOT="$S" WT_REPO="$R" WT_ROOT="$W" WT_TRUNK=master WT_SALVAGE=0 DRY_RUN=1 "$@" \
  bash "$C/csi-spl-orc/src/bash/scripts/wt-dead-sweep.sh" 2>&1; }
on="$(run env WT_SWEEP_TMP_ROOT="$T")"; off="$(run env)"
bad=0
chk() {  # NAME WANT(yes|no) PATTERN TEXT
  local got=no; grep -qE "$3" <<<"$4" && got=yes
  echo "rc02 $1: $got want=$2"; [[ "$got" == "$2" ]] || bad=$((bad + 1))
}
chk "tmp dead planned"        yes "PLAN remove .* $T/g-901-review( |\$)" "$on"
chk "tmp alive kept"          no  "PLAN remove .* $T/g-902-review( |\$)" "$on"
chk "tmp dashless untouched"  no  "PLAN remove .* $T/g903-review( |\$)"  "$on"
chk "tmp non-id untouched"    no  "PLAN remove .* $T/x-review( |\$)"     "$on"
chk "wt-root dead planned"    yes "PLAN remove .* $W/g-904( |\$)"        "$on"
chk "default off: no tmp line" no " $T/"                                  "$off"
echo "rc02 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

`rc03.sh`, as run:

```bash
#!/usr/bin/env bash
# rc03.sh <sha>: b30-03 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree), sources lane-issue.inc.sh and spl-spawn-after.func.sh and asks
# spl_spawn_after_key which issue key an After: row slug waits on. The placer
# runs on box-a (ASKS_BOX); this box's spool holds c-461/lifetime/issue =
# SPL-6078 (box-a's own c-461, another lane). .place.slugs names the slug's
# lane with no key; the hub's lane map (SPAWN_AFTER_LANES_CMD) has the lane's
# row with its key. Cases:
#   far   : slug p05 placed as c-461@box-b -> the hub's SPL-6100 (RED when it
#           reads box-a's SPL-6078)
#   here  : slug p03 placed as c-461@box-a -> box-a's SPL-6078 (control)
#   bare  : slug p02 placed as c-461 (no box) -> SPL-6078 (control, today's form)
set -uo pipefail
sha="${1:?usage: rc03.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$C" || exit 2
S="$C/spool"; mkdir -p "$S/asks" "$S/c-461/lifetime"
echo SPL-6078 >"$S/c-461/lifetime/issue"
printf 'p05\tc-461@box-b\t\np03\tc-461@box-a\t\np02\tc-461\t\n' >"$S/asks/.place.slugs"
printf '%s\n' '{"hub":"ok","lanes":[{"agent_id":"c-461","agent_box":"box-b","branch":"c-461-p05","issue_key":"SPL-6100"},{"agent_id":"c-461","agent_box":"box-a","branch":"c-461-p03","issue_key":"SPL-6078"}]}' >"$C/lanes.json"
key() {  # SLUG -> the key
  (cd "$C/csi-spl-orc" && PROJ_PATH="$PWD" SPOOL_ROOT="$S" ASKS_BOX=box-a SPAWN_AFTER_LANES_CMD="cat $C/lanes.json" bash -c 'set -uo pipefail
    do_log() { :; }
    spool_asks_dir() { echo "$SPOOL_ROOT/asks"; }
    spl_spawn_place_brief() { :; }
    source src/bash/run/spl-spawn-after.func.sh
    spl_spawn_after_key "$1"' _ "$1" 2>/dev/null)
}
bad=0
for c in "far p05 SPL-6100" "here p03 SPL-6078" "bare p02 SPL-6078"; do
  set -- $c; got="$(key "$2")"
  echo "rc03 $1: key=${got:-none} want=$3"
  [[ "$got" == "$3" ]] || bad=$((bad + 1))
done
echo "rc03 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

---

## 4. Round 29's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b29-01, b29-02 | `git log origin/master --oneline -E --grep='\(b29-0[12]-'` | landed `ac367b7a5`, `ae4898ae1` | Served (SPL-6080 done). b29-01's R7 notes: section 5. |
| The done-claim `job` label (a row if a `job <hex>` token alone alerts) | source 4 | `<box2>`: 30 runs since 18:20Z, 0 `job <hex>` | **Not a row**: the condition did not occur. Stays an input. |
| `test-agent-name-shape.sh:89` (a row once seen red) | source 2 | `grep -c agent-name-shape <the report>` -> 0 | **Not a row**: not seen red. Stays an input. |
| SPL-5850 N1: an AltGr letter may pick a kind (`csi-spl-wui/src/utils/kind-picker-keys.ts`) | source 1: the 2 picker-word posts are a poll answer and the switcher bug | no rule, no owner word | **No rule it breaks, no owner word.** Carried. |
| The desktop blog switcher's Enter on its one match | source 1 | no rule, no owner word | **A product question, no rule.** Carried. |
| The orc/iac suites as the agent OS user, if seen red | as `<AGENT_USER>` on `4ad1b80a8`, 01:0xZ: `bash csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh` -> rc 0, `ALL PASS`; `bash csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh` -> rc 0, `81 passed, 0 failed` | not red (n=1 each) | **Not reproduced**, as in rounds 27 to 29. Stays an input if seen red with its user and tree. |
| `gcp-billing-invoices.tst.sh` `download iframe` at its 3rd sighting | source 2 | still 2 sightings (44570765247, 44725157504); none since | **Not a row**: no 3rd sighting. |
| `unanswered-sweep.tst.sh` section / case 12 if L2b closes without it | `git log origin/master -- csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh` | `74bd535d8` `test(orc, SPL-6033): unanswered-sweep test pins ACK_DEFER_S=0` (19:07Z): the cause was the gate's `APP_PATH` reading cnf `desk_ack_defer_s`; red with `APP_PATH` or `ACK_DEFER_S=300`, green in all three envs (its body) | **Fixed** by spec 182's lane. Dropped as an input. |
| SPL-6073 R7 N1's `tasks <hex>` form, if printed again | prod messages since 18:18:20Z (729): `body ~* '\mtasks [0-9a-f]{7,40}\M'` -> 2, `'\mask[-_]ids? [0-9a-f]{7,40}\M'` -> 0 | printed again: c-001 bd23ce00 and 017824cb (19:29Z, 19:30Z, one text sent twice): "tasks 91992830, forward 82dc7a90, multicast 032d8010, ..." | **Not a row this round** (it would be a third row): 1 text in 6.5 h, and `tasks` in `ID_WORD_RE` (`csi-spl-wui/src/utils/commit-links.ts:41`) would unlink 1 of its 3 hex ids; `forward <hex>` and `multicast <hex>` stay linked. Carried with that count: a row once it is the round's best input, and its scope then names the other words. |
| Dead lanes' `/tmp` worktrees and overlay mounts | section 3 | 27 on `<box2>`, unlisted, dead, 113-126 h idle | **Row 02** (the worktrees). The overlay mounts: section 6. |

---

## 5. The holder's candidates and the brief's notes, re-measured; not a row this round

| candidate | command | result |
|---|---|---|
| **CI-first rule does not hold in the spawn queue** (c-001 b96b804a) | section 3 | **Row 01.** Its fix idea "class ci outranks priority" in `askPositions` is not taken: the queue's order is the owner's (poll Q5 A, priority first) and the rule names the placer; the row fixes the placer. |
| **Dead lanes' `/tmp` worktrees** (c-001 82c02da9) | section 3; sat (holder msg 8bac2908): `git -C <main checkout> worktree list \| grep -c '^/tmp/'` -> 10, after c-001's hand clean | **Row 02.** |
| **The `After:` hold reads the wrong box's key** (c-001 d77d912f, holder msg e86b574b) | section 3 | **Row 03.** |
| **b29-01 N2: a token hash at rest and on an argv** (c-334) | `spl-box-quota.func.sh:258,266` (the 12-hex prefix), `:304,:376` (the `spool_agent_exec` command string carries `$ak`); on `<box2>`: `stat -c %a` of `<kept file>.account` -> 664, of its three parent dirs (`.local`, `.local/state`, `.local/state/csi-spl`) -> 700 each, owner `<PUSH_USER>`; 6 `ps` samples over 1 s while the box ran -> 0 processes with that argv | **Not a row**: the file is unreadable to any other user (700 parents, n=1 box), and the argv is a 48-bit hash prefix that lives for one call (0 of 6 samples saw it). No harm measured; a hardening input for a refactor round (memory only, or 0600 and off the argv). Note: `28f802950` (SPL-6112) added the `:376` use. |
| **b29-01 N1: the profile account same/differs across a real renewal** (PENDING in the landed body) | `<box2>`: `<kept file>.account` holds 1 line, written 21:20:17Z (after the b29-01 land), the `<AGENT_USER>` credential's mtime 19:58:33Z; the kept claude row's key (column 10) equals the cache's account key (printed `row-key==cache-key`, no key shown) | **Not measurable yet**: no renewal since the land (the next is ~03:58Z by the 8 h expiry). Carried: a b31 row if it reads `differs` (b29-01 then drops a true reading at every renewal). The measurement needs no token: one more line in `.account` with a new access-token key and the same account key = `same`. |
| **b29-01 N6: the anthropic host in the caller's SPL_CNF** | the same row: its key column is filled, so the caller that kept it found the host (n=1, `<box2>`) | **Not a row**: works on `<box2>` for the caller that wrote the row. Whether every caller (`weekly-limit-alert`) loads the merged cnf stays untraced; an input if a box shows a kept row with no key after a fresh reading. |
| **Topic loop hourly cap race** (SPL-6032 R7 c-297 N2) | `csi-spl-api/.../store/topic_loop_postgres.go:181-194` (`topicLoopFireSQL`) | **Not a bug**: the cap check and the count are one `UPDATE ... WHERE fires_in_hour < $4`; a concurrent fire waits on the row lock and re-checks the WHERE (its comment, `:176-180`). No count-before-insert. The memory store is a test double. N1 (the `!inserted` branch untested) is a test round input. |
| **review-go's "found locally only" / GO to a retired author / done-claim sha256 prefix / review-notify `author` in a never-list / blog e2e alone / panel-seat slug forms** | as in round 29 | **Served** in rounds 20 to 29 (round 29 section 5 has each commit). |
| **orc/iac suites not hermetic to the OS user** (c-947 75843c44) | section 4 | **Not reproduced.** |
| **Rows A and B of the reflection; `fallback_postgres.go:83-86`; the SPL-5824 / 5825 / 5828 / r63-01 / p18-02 notes; SPL-6107 N1** | the file | **Not bugs this round**: detectors and coverage gaps (a test round's input), literal paths and comment or usage wording (refactor inputs), as rounds 27 to 29 read them. |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row's file (lane map 00:57:04Z, queue 00:56:17Z); the sat halves are asked of the holder. |
| `workspace-doc-preamble.test.mjs` red, n=1 (44832401773, 22:51Z) | c-488@sat (WUI Qto doc view header, `5dff872e3`), live | 1 sighting, green since; a fixing lane at the 3rd (rulebook 2.11.3). |
| done-claim check run time: 29 of 29 finished `<box2>` runs since 18:20Z stopped at the 600 s cap (`rc=124`) | the holder: a perf round input (round 29 section 6) | No wrong answer seen, so not a bug row. |
| Overlay mounts left on dead `/tmp` worktrees (c-001 82c02da9: `node_modules` still mounted) | the next round's input | Not read on `<box2>` this round; row 02's `git worktree remove` refuses a tree with a mount in use, so the mounts are a separate row with their own red control. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 3 |
| inputs re-measured | 5 sources; 10 round 29 inputs, 16 holder candidates, 3 R7 notes; 48 human posts since 18:18Z (24 probes, 2 with a bug word, each read); 100 CI runs; 1 cron log (30 runs); 3 red controls (n=3 each); 2 suites re-run as the agent OS user; 729 prod messages for the commit-links forms; 27 `/tmp` worktrees |
| first inputs for round 31 | the done-claim `job` label if it alerts alone; the AltGr picker if a rule or the owner says how it must pick; the desktop blog switcher's Enter on its one match if a rule or the owner says Enter must pick; `test-agent-name-shape.sh:89` if seen red; the orc/iac suites as the agent OS user if seen red, with user and tree; `gcp-billing-invoices.tst.sh` `download iframe` at its 3rd sighting; `workspace-doc-preamble.test.mjs` at its 3rd sighting; the `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms (1 text in 6.5 h) if printed again; b29-01 N1 if the renewal reads `differs`; the overlay mounts of dead `/tmp` worktrees; the 8 dashless `/tmp` seat worktrees (`g273-...`) if row 02's prefix rule leaves them |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-448@`<box2>` (claude, `specs_and_docs`).
- **Panel:** m-551@sat, the b30 mistral panel seat (ask `c002-bug-round-30-mistral-panel-seat`). All three rows are orc bash; no WUI file, so a mistral seat may sit (developer guide 5.1).
- **Asked of the holder with v0.1, answered** (c-002@sat msg 8bac2908, folded in sections 3.1 and 5): (1) the 3 exit-4 lanes of section 3.1 (c-461, c-476-rotate, m-551): each worktree's `git diff --name-only origin/master...HEAD` and dirty paths against the row files; (2) the 35 queued briefs (`/var/spool-hub/dispatch/briefs` on sat): `grep -lE 'spl-spawn-place\|spawn-place-argmax\|wt-dead-sweep\|box-disk-sweep\|tmp-stale-sweep'`; (3) sat's `/tmp` worktree count since c-001's hand clean (row 02's other half).
- **Row reviewer (R7):** rows 01, 02 and 03: the claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (00:58:29Z) -> `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% billing read 28m ago; <box2> 99% billing read 28m ago]: queue the lane, spawn nothing`. No mistral backup on any row: both are coding kinds (`simple_coding`), and mistral takes none of them, as main or backup; an absent seat gets a replacement claude waiver seat (rulebook 2.7.3).
- **Review history:**
  - 2026-11-21 01:05Z: the editor pushed v0.1 (`26492502f`) to `review/c002-bug-round-30-planner` and reported to the holder (msg 88619639); the holder pointed m-551@sat at it (msg 8bac2908).
  - 2026-11-21 01:1xZ: v0.2, one commit on `26492502f` (a fast-forward of the review branch): row 03 added from the holder's candidate (msg e86b574b, which says the panel re-reviews), the holder's sat halves folded (sections 3.1, 5, 8). This file is the only one it touches. Rows 01 and 02 unchanged.
  - 2026-11-21 01:1xZ: m-551@sat **PASS** on v0.1 `26492502f30952d72ff2c52adaa806553577fb87` (msg b5e0931a; seat file `4d2764cbf`), no W. It re-ran rc01 and rc02 (RED 3 of 3 each), read all 23 cited lines on `4ad1b80a8`, and rebuilt both rc files from section 3.2 (sha256 match). N1: the holder's d77d912f candidate came after the measurement: v0.2's row 03 already takes it. N2: the plan reaches `origin/master` with this v1.0 commit. N3: section 2 of `box-disk-sweep.tst.sh` ends at `:170` (`:171` is blank).
  - 2026-11-21 01:2xZ: m-551@sat **PASS** on v0.2 `2c3e1932a988818f9aa21f57bed23f019dd57fec` (msg 5b2cb473; seat file `d729bdb5a`), no W: the fast-forward, the delta (plan file only, +66 -18), row 03's 9 cited lines, rc03 rebuilt (sha256 match) and RED 3 of 3, no drift in the 14 cited files at `7270e861f`, row 03's lane map, hygiene clean. N1 answered by row 03, N2 and N3 as above. Line check on `<box2>`: `REVIEW_LINE_SYNTAX=1 ./run -a do_spl_review_line_check` -> `SYNTAX OK` once the line's `seat-file: <branch> <sha>` part is left out (with it, `SYNTAX FAIL`); the full check runs on sat, where the `log:` is.
  - 2026-11-21 01:2xZ: v1.0, one commit on `2c3e1932a` (a fast-forward of the review branch): the status line, the panel line, N3's range (`:150-170`) and sections 8 and 9 record the PASS. This file is the only one it touches. No row changed.
  - 2026-11-21 01:40Z: v1.0 landed as `b67431a30` (holder GO 394cb574); the holder queued the rows as bug asks 2fdeb25e, 4c52df53, fec4e37c.
  - 2026-11-21 03:3xZ: round closed, no version bump: the 3 rows landed, b30-01 `9b680e7b5` (SPL-6125), b30-02 `b341f7bb8` `82d1b51da` (SPL-6128), b30-03 `6f2a343bb` `252de9ad2` (SPL-6129). Status line and sections 8 and 9 only.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-448@`<box2>` | v1.0, landed `b67431a30`; round closed, rows 01-03 landed |
| Panel | m-551@sat (mistral) | **PASS** on v0.1 `26492502f` (msg b5e0931a) and on v0.2 `2c3e1932a` (msg 5b2cb473), no W |
