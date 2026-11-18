# Bug-fix round 16 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5869 (this plan, the round's discussion issue).  
Discussion: t1 #spool-hub-bugs `10f8c08e-ff66-42bd-a8fa-7db615e8e14f` ("Bug round 16", opener msg a14cadd5, opened by c-002@sat 2026-11-18T08:27:13Z). Requested by c-001 spawn-share f1b76a63: bug 19% of the live lanes, no bug row queued. Round 15 ([bug-round-15-plan.md](bug-round-15-plan.md) v1.0, 3 rows) is served: b15-01 `fb16a1537`, b15-02 `7d05e4bea`, b15-03 `3ef117edd` on `origin/master`, quality gate 44258982546 + 44261383265 on `330bfc390` success, all ACCEPTED.  
Round focus: one defect live on `origin/master` today, found in this box's cron logs. Since SPL-5860 (`2fe3729e3`) the idle filler opens a topic of its own for an issue that links only the default topic, then links the issue to it. The open is a note from the desk to itself on its own box, which the spool client delivers locally and never sends to the hub; the hub then refuses the link (`unknown_discussion`), and the filler queues nothing. 8 ticks on sat since 06:00Z, the same issue each time.  
Round size: at most 10 items (rulebook 1.1); this round has 1. Every other input was re-measured and is fixed, not reproduced, not code, or owned (sections 4 to 6).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (round size, push caps, bands, R1-R16), linked here, not copied.  
Model: [bug-round-15-plan.md](bug-round-15-plan.md) (same shape, same 5 sources).

**Status: v0.2** (for the panel). v0.2 folds in the <box2> answers (c-001@<box2> msg 8eed1ff2, relayed by the holder c-003@sat, msg abccb587): the b16 slug is unused there, <box2> runs no `spawn-fill` cron, and no lane there lists the row's files (sections 2, 3.1, 8). The row, its sites and its red control are unchanged from v0.1 (`526155e00`).  
Editor: **c-401@sat** (claude, `specs_and_docs`).  
Panel: asked of the dispatch holder (section 8).

**One sha:** every count and every red control below is measured on **`714a4fc82`** (`origin/master`, committed 2026-11-18T08:27:09Z), on sat, between 08:30Z and 08:45Z on 2026-11-18. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else. The row has a **red control** that fails on `714a4fc82` and passes after the fix (section 3.2).
- **Paths** are repo-relative. Line numbers are as of `714a4fc82`.
- **Box:** the preferred box. The placer may move the row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules and R14. The row is bash tooling (`simple_coding`). The lane mix picks claude (08:41:45Z: `pick=claude launcher=/claude-spawn kind=simple_coding reason=kind simple_coding: main claude, backup agy`). The bug rows of rounds 10 to 15 all went to claude, so R14 agrees. Mistral writes no code.
- **Subject** (R6 reads it): `fix(b16-01-<slug>, SPL-<row issue>): ...`.
- **R7 line:** rulebook 2.7.4 (box-free form in the commit body).

---

## 2. Where the rows come from (measured on `714a4fc82`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 and csitea since round 15 was planned** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-18T05:41:52Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (08:32:06Z), then the csitea messages read whole | t1 6, all 6 `[spool-probe]`; csitea 2 (a poll answer, and at 07:55:39Z "The morning meeting usually starts at 9:30 CAT, and now it's something else ... some kind of problem with the setting of the times") | **0 rows.** The meeting-time report is answered in its own topic `40c3f89d` by its seat c-060 (07:56:43Z: "every meeting I imported yesterday sits 2 hours too early"; 08:13:45Z: a question to the owner before the fix): owned (section 6). |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (08:31Z..08:38Z) | 100 runs 2026-11-17T14:45:13Z .. 2026-11-18T08:27:52Z: 68 success, 28 cancelled, 2 failure, 2 running. Every timeout headroom line `ok` (highest p90: 57 %) | 2 failed runs, first reds: `TestDemoPostQuotaPerDay` x1 (68cd3332) and wui e2e 2/8 `4j Shift+O opens the issue` x1 (013cb71b), both seen by rounds 14 and 15, still one sighting each. Every failed job is green again on `f284b414` (run 44263008046). **0 rows** (section 5). |
| **3. Skipped or disabled tests** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 714a4fc82 -- "$d" \| wc -l; done`; then `git diff 2fe3729e3 714a4fc82 -G '<the same pattern>' --stat` | api 199, wui 17, orc 10, iac 21, utl 0 (round 15: the same) | The diff names only `bug-round-15-plan.md` (its source 3 row quotes the pattern). **0 rows.** |
| **4. Box cron logs and GC notes, last 24 h** | sat: an awk over the 39 `/var/csi/csi-spl{,-desk-cron}/*/cron.{out,log}` changed in the last 24 h, for `unbound variable\|command not found\|syntax error\|Traceback\|panic:\|status 141\|No such file or directory\|operand expected\|Permission denied\|FATAL\|ERROR`, each line keyed by the last ISO timestamp above it in its own file (reset per file, `spool-env` WARN lines skipped), counted per distinct line after 2026-11-17T08:30Z. The two files with no timestamps (`spawn-fill`, `review-go`) read by line number. Then the filler's own `WARN SPL-<n>:` lines in `spawn-fill/cron.out`, and `is not writable, logging to` per hour | 24 distinct keyed lines over 8 crons; `spawn-fill/cron.out` (46430 lines): 16 `WARN SPL-65:` lines | **1 row.** Row 01: `spawn-fill/cron.out` lines 46212..46402, 8 ticks: `WARN SPL-65: the hub did not link topic abf8b18b-f369-409b-854c-3fdace831625: spool: hub refused: unknown_discussion (no such discussion: abf8b18b-...)`, then `WARN SPL-65: no discussion of its own for the lane: not queued`, then `OK 0 row(s) queued`. The rest: section 5 (GitHub rate limit, network, a fixed brief mode, day-log WARN before b15-03 can act) and section 6 (box-update, env-order, review-go). The `lane-rotate` `cmdline` lines (10, last 2026-11-17T19:39:07Z) and the `dispatch-rotate` `spl-rotate-lib` line (1, 17:48:36Z) predate b14-02 (`0a5a8fbb3`, 2026-11-18T05:04:27Z); the `lane-rotate` `((: -: syntax error` line (2026-11-17T08:44:18Z) predates b13-01. gc-sat's notes name no other defect. **The live evidence is sat's alone.** <box2> (c-001 msg 8eed1ff2, read only): it runs no `spawn-fill` cron (`crontab -l` of its three users -> 0 such lines, no `/etc/cron.d` entry, no `*fill*` var dir), and `unknown_discussion` occurs in no log there today; the filler runs on sat only, so row 01's defect shows only there. |
| **5. Open defect issues, round 15's leftovers, the holder's candidate list, refactor round 35's left-out bug items** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select number, status, assignee, ... from issues where tenant_id='t1' and ... status in ('eval','todo','wip','blocked','onhold','qas') and kind='issue' and ('bug' = any(labels) or title ~* '(bug:\|broken\|...\|flake)') order by number desc" ./run -a do_spl_db_query` (08:3xZ, round 15's query); the R7 lines in the bodies of `fb16a1537`, `7d05e4bea`, `3ef117edd`; the panel seat file on `review/c002-bug-round-15-mistral-seat` (N1-N5); `refactor-round-35-plan.md` sections 2 ("Left out") and 6; `/var/spool-hub/dispatch/c002-next-round-candidates.md`; round 15 sections 4 to 6, each re-read on `714a4fc82` | 23 issues matched (the same 23 as round 15); 3 R7 lines; 5 seat notes; 13 candidate notes | **0 rows of their own; row 01 is SPL-5860's follow-up N1 made concrete.** Round 15 section 6 kept "SPL-5860 N1: the live hub path of `do_spl_spawn_fill` untested, N2: it ends rc 0 when a row's open or link fails" with c-325's lane; SPL-5860 is `done` and c-325 is retired (`/var/spool-hub/c-325` gone), and source 4 shows the untested path failing live. The R7 lines of b15-01..03 carry no N item; the seat's N1-N5 confirm its plan (section 4). The candidate list's notes and refactor round 35's left-out bug items: their files are unchanged since round 15 (`git diff --stat 2fe3729e3 714a4fc82 -- <their files>` -> empty), re-read in section 4. |

In the commands of this table, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 3. The row

| # | defect | evidence | sites file:line | red control (fails on `714a4fc82`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b16-01-orc-spawn-fill-topic-open-reaches-hub)` | `spl_spawn_fill_topic` opens the lane's topic with `spl_spawn_fill_hub open`: `spool send --from <desk> --to <desk> --to-box <desk box> --task <topic> --kind note`, through `spl_desk_spool`, which leaves `SPOOL_MIRROR_LOCAL` unset. The spool client delivers a send whose `--to-box` is its own box locally and skips the hub unless the mirror is on (`csi-spl-api/src/go/spool-hub-api/internal/hubclient/flush.go:65-73`). A topic exists on the hub only when a hub message carries its task id (`topicAccessRead` in `internal/store/channels_postgres.go`: `FROM messages WHERE tenant_id = $1 AND task_id = $2`). So `spl_spawn_fill_hub link` is refused with `unknown_discussion`, the issue is not queued, and the next tick tries again: an issue whose only link is the default topic is never filled, and each tick leaves one more self-note in the desk's own inbox. The probes that need a same-box send on the hub already set the mirror (`spl-box-msg-probe.func.sh:78`, `spl-box-file-probe.func.sh:54`, `spl-file-door-probe.func.sh:58`). | (1) sat `/var/csi/csi-spl/spawn-fill/cron.out` lines 46212..46402: 8 ticks, each `WARN SPL-65: the hub did not link topic abf8b18b-f369-409b-854c-3fdace831625: spool: hub refused: unknown_discussion (no such discussion: abf8b18b-...)`, `WARN SPL-65: no discussion of its own for the lane: not queued`, `OK 0 row(s) queued`. (2) The desk's spool (the t1 prd desk `sat` under the `<HARNESS_USER>` state root, `.../cloud/prd/desk/t1/sat/spool/c-002/`): 8 `outbox` and 8 `inbox` files `<ts>--c-002--spawn-fill-spl-65-the-discussion-<id>.json`, 20261118T060030Z .. 20261118T082034Z, each `from c-002 to c-002 task_id abf8b18b-...`; the newest inbox copy has the newest outbox copy's msg_id (`8cd8060f`): delivered locally. (3) prd, read only (08:3xZ): `select ... from messages where task_id='abf8b18b-f369-409b-854c-3fdace831625'` -> 0 rows in any tenant; `... where from_id='c-002' and to_id='c-002' and ts > now() - interval '4 hours'` -> 0 rows. (4) The id is the filler's own (`spl_spawn_fill_topic_id SPL-65` -> `abf8b18b-f369-409b-854c-3fdace831625`, red control below). (5) SPL-5860's own body (`2fe3729e3`): "Not verified against a live hub: the open (desk self-note) and the link run only against the test stub SPAWN_FILL_HUB_CMD"; its follow-up N1 (round 15 section 6). (6) The red control below on `714a4fc82`. | `csi-spl-orc/src/bash/run/spl-spawn-fill.func.sh:357-373` (`spl_spawn_fill_hub`, the `open` case `:366` and the call `:372`), `:326-342` (`spl_spawn_fill_topic`, its comment `:321-325`); test `csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh` (a new case after case 9, `:266`) | The editor's script `rc01.sh <repo root>` (section 3.2). It sources `spl-desk-up.func.sh` (for the real `spl_desk_spool`) and `spl-spawn-fill.func.sh`, stubs `spl_lane_issue_desk`, `spl_desk_issue_once` and `spl_desk_dir`, and puts a fake `spool` on `SPL_SPOOL` that keeps the client's same-box rule: a `send` whose `--to-box` equals `SPOOL_BOX_ID` is `local` and reaches no hub unless `SPOOL_MIRROR_LOCAL=1` (or it is a `--channel` post); `issue link --discussion <t>` is refused with `unknown_discussion` unless a hub send carried `<t>`. It runs `spl_spawn_fill_hub open` then `link` for SPL-65 with `DESK_BOX=sat DESK_AGENT=c-002`. On `714a4fc82`: `open rc=0 link rc=1 send: local link: spool: hub refused: unknown_discussion (no such discussion: abf8b18b-f369-409b-854c-3fdace831625)`, `RESULT: FAIL`: the live line. A prototype that runs the `open` call with `SPOOL_MIRROR_LOCAL=1` (on a `git archive` copy): `open rc=0 link rc=0 send: hub`, `RESULT: PASS`. PASS requires `link rc=0` with the fake `spool` unchanged. | The open reaches the hub; how is the lane's call, e.g. `SPOOL_MIRROR_LOCAL=1` on the `open` call only, as the probes do (the link and every other desk call keep it unset; `spl_desk_spool`'s comment says why a desk keeps it off), or another send form the hub stores. The fix stays in `spl-spawn-fill.func.sh`; `spl_desk_spool` (`spl-desk-up.func.sh`) is not edited: refactor round 35 row 06 owns that file. Keep the topic id, the retry reuse, the brief, the ask and the enqueue as they are; a refused open or link still queues nothing. The suite case drives `spl_spawn_fill_hub` through `spl_desk_spool` with a fake `SPL_SPOOL`, as the red control does: the existing `SPAWN_FILL_HUB_CMD` stub (`:86-94`) bypasses `spl_desk_spool` and cannot see its env, which is why case 9 was green. The lane checks and says in its body whether the mirrored copy lands in the desk's inbox once or twice. Live proof after the land (R5): the next sat tick for SPL-65 logs `INFO SPL-65 linked only the default topic: opened topic abf8b18b-... and linked it` and queues the ask. Test column: `git grep -lE 'spl-spawn-fill(\.func)?\|do_spl_spawn_fill\b' -- '*tests/*'` -> `spl-spawn-fill.tst.sh`, `desk-user-hops.tst.sh`, `spl-epic-stall-check.tst.sh`, `spl-spawn-group.tst.sh`, `spl-spawn-share.tst.sh` (orc; `orc-shard-weights.txt` is data). Docs: `Docs: none (the filler's topic now reaches the hub, as SPL-5860 and the fleet rules index row already say; no rule changes)`, or the lane's line. | sat | claude | a cross-vendor seat if one places (agy or grok); else the claude waiver seat, as for rounds 11 to 15 (waiver 1a7c70da). The holder decides at placement | simple_coding | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** row 01 alone: `csi-spl-orc/src/bash/run/spl-spawn-fill.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh`.
- **Off limits:** every live lane's files, and refactor round 35's row files (`refactor-round-35-plan.md` section 3, r61-01..06: `spl-uplink-probe.func.sh`, `spl-box-quota.func.sh`, `spl-lane-rotate.func.sh`, `spl-watchdog.func.sh`, `install-box-crons.func.sh`, `spl-box-state-backup.func.sh`, `external-api-health.func.sh`, `spl-spawn-place.func.sh`, `spl-workspace-docs-purge.func.sh`, `prune-docker-images-install-cron.func.sh`, `setup-reverse-tunnel.func.sh`, `spl-desk-up.func.sh`, `spl-m3-e2e.func.sh`, `spl-desk-install-service.func.sh`, `no-literal-paths.baseline`). Row 01 reads `spl-desk-up.func.sh` (its red control sources it) and edits none of them.
- **Waits (R3):** none. The last commit on the row's files is SPL-5860's `2fe3729e3` (landed; its lane c-325 is retired).
- **How the files were checked (2026-11-18, from sat):**
  - 08:40:58Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-fill.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh,csi-spl-doc/doc/md/fleet-rules-index.md,csi-spl-doc/doc/md/bug-round-16-plan.md --agent c-401` -> exit 4: no live lane lists these files; 12 lanes on <box2> record no files: c-054 and c-714 (blog drafts), c-060, c-390, c-468, c-528, c-545, c-570, c-596, c-669, c-924, c-927 (`rotate` lanes), the same set rounds 15 and 35 met. **Exit 4 is not free, and this plan did not clear it**; their briefs are on <box2>. On <box2> (c-001 msg 8eed1ff2), `lane-map.sh --check <the two row files> --agent c-001` -> exit 4: no lane lists them, the no-file lanes it names are all on sat (c-176, c-197, c-401, c-406, c-762), and a grep of its worktrees for `spawn-fill` -> 0. The orchestrator re-runs the check before the spawn (R3) and asks an exit-4 lane first.
  - R1 against the other rounds (the holder c-003@sat, msg b065bf95): `grep -c spl-spawn-fill` over `perf-round-16-plan.md`, `perf-round-16/editor.md`, `perf-round-16/seat-mistral.md` and `refactor-round-35-plan.md` on `origin/master` -> 0 each (the editor's re-run: 0 each).
  - 08:41:24Z every live sat worktree (`git worktree list`, the 18 with a spool dir): `git diff --name-only origin/master...HEAD` plus `git status --porcelain`, matched against `spl-spawn-fill`, `fleet-rules-index`, `bug-round-16` -> 0 hits each.
  - 08:41:08Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 0 queued, 0 placing (refactor round 35's rows are not queued yet).
  - Briefs under `/var/spool-hub/dispatch/briefs` changed since 2026-11-17T22:00Z that name `spl-spawn-fill`: 2, SPL-5860's lane and its reviewer (`c002-bug-spawn-fill-same-box-issue-links-backlog.md`, `c002-spl5860-spawn-fill-topic-claude-waiver-reviewer.md`), landed as `2fe3729e3`.
- **Slug b16 is unused as a round id** (08:41:35Z, sat): `git log origin/master --grep='(b16-'` -> 0; `git log origin/master -E --grep='\bb16-[0-9]{2}-'` -> 0; `git ls-remote origin | grep -cE 'b16-[0-9]{2}|bug-round-16'` -> 0; `grep -rlE '(^|[^0-9a-f])b16-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs` (5959 files), `/var/spool-hub/asks` (9080) and `/var/spool-hub/spawn-remote/briefs` (199) -> 0 files; `bug-round-16` -> 1 file, this planner's own brief. After this plan's pushes, `--grep='(b16-'` matches the plan's commits (`docs(b16-plan, ...)`) and `ls-remote` the planner's review branch; the row form `--grep='\(b16-[0-9]{2}'` stays 0 until the row lands. On <box2> (c-001 msg 8eed1ff2), over dispatch/briefs, asks and spawn-remote: `b16-[0-9]{2}|bug-round-16` -> 11 raw hits, all hex inside UUIDs, 0 slugs; `bug-round-16` -> 0.

### 3.2 Red control run on `714a4fc82`

| row | command (repo untouched) | output on `714a4fc82` | output with a prototype fix (on a `git archive` copy) | who |
|---|---|---|---|---|
| 01 | `bash rc01.sh <repo root>` (a `git archive 714a4fc82 csi-spl-orc` copy) | `open rc=0 link rc=1 send: local link: spool: hub refused: unknown_discussion (no such discussion: abf8b18b-f369-409b-854c-3fdace831625)` / `RESULT: FAIL` | `open rc=0 link rc=0 send: hub link:` / `RESULT: PASS` | editor c-401 |

The script is in `/var/spool-hub/dispatch/b16-red-controls/` on sat and goes to the row lane with its brief; the lane turns it into a suite case. The prototype only shows that PASS is reachable; the lane writes its own fix. The fake `spool` models the client's same-box rule as `flush.go:65-73` has it on `714a4fc82`; it is not the real binary (the desk-cron `bin/spool` is older than its sources, section 4).

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| SPL-5860 N2: `do_spl_spawn_fill` ends rc 0 when a row's open or link fails | `spl-spawn-fill.func.sh:285-304` (`spl_spawn_fill_queue`), `:297` | A failed row logs its WARN and the tick ends `OK 0 row(s) queued`, rc 0, by design: the filler is best effort and retries next tick, as its other `WARN ... no fill this tick` paths (`:78`, `:83`, `:84`, `:88`) do. | No failing behaviour of its own; row 01 removes the failure the rc would have reported. |
| b12-02 R7 N4: `do_tf_apply_target`, `do_tf_destroy`, `do_tf_destroy_target`, `do_tf_destroy_local_step_bucket` drop terraform's exit status | the editor's `rcN4.sh` on a `git archive 714a4fc82` copy: each action with a stub terraform whose apply / destroy / plan exits 3, under `./run`'s `set -u -o pipefail`, called plainly as `execute_step` does (`csi-spl-iac/src/bash/run/run.sh:170`) | `do_tf_apply: after-call rc=3`; the other four: `after-call: NOT RUN process rc=3` (n=1 each) | Not reproduced: terraform's status reaches the run, as round 14 read. The four leave by `set -e` (the run's POST hook and ERROR line are skipped): a style point for a refactor round, not a lost status. |
| b12-02 R7 N2, N3: `terraform init` / `output` without `-input=false` (`tf-apply.func.sh:29,41`, `tf-apply-target.func.sh:50`, `tf-destroy.func.sh:29`, `tf-destroy-target.func.sh:39`, `tf-destroy-local-step-bucket.func.sh:60`); `do_tf_log_open`'s `${1:?}` (`csi-spl-iac/lib/bash/funcs/tf-log-mask.func.sh:25`) | read on `714a4fc82` | Every caller passes the path; terraform runs in the tf-runner container. No failing run. | As round 14 section 4. |
| SPL-5825 W1, N2, N3, N4; SPL-5824 W1, N1, N2; SPL-5828 N1, N2; r34 row 01 N1, N2; SPL-5850 N1 | as round 14 section 4; `git diff --stat 2fe3729e3 714a4fc82 -- <their files>` -> empty | unchanged | As round 14 section 4. r34 row 01 N1/N2 are test-coverage gaps with no failing behaviour: input for a test round, not a bug row. |
| b15-01 side effect: a lane with no lifetime dir is warned on more than one tick (round 15 section 4) | `WARN rotation` lines in sat `lane-rotate/cron.log` after 2026-11-17T08:30Z, per id and pid | 172 distinct sessions; 1 warned twice: c-077 pid 967773, the case round 15 found (2026-11-17T19:0xZ) | No repeat since. |
| Round 15's seat notes N1-N5 (m-345, `review/c002-bug-round-15-mistral-seat`) | read | N1/N2 the slug greps match the plan's own commits and branch; N3 the lane map; N4 rc01's race count; N5 rc03's variant line. | They confirm the plan; no defect. |
| desk-cron `bin/spool` older than its sources | every orc cron line (`spool-env: WARN ... built 2026-10-31T02:27:08Z, last source commit 2026-11-18T04:02:44Z`) | As in rounds 12 to 15. | As before. |

---

## 5. Not reproduced, or not code

| candidate | command | result |
|---|---|---|
| `TestDemoPostQuotaPerDay` (68cd3332), wui e2e 2/8 `4j Shift+O opens the issue` (013cb71b) | `do_report_ci_gate` above | 1 sighting each in 100 runs, below the R11 flake bar. Watch. |
| GitHub API rate limit: `ci-red-note` and `restore-drill-red-note` `FATAL gh run list failed: HTTP 403: API rate limit exceeded` | an awk over both cron logs for `API rate limit exceeded`, keyed by the last timestamp above | Today 08:00Z, 08:07Z, 08:10Z, 08:20Z; earlier on 2026-11-05, 11-12, 11-15, 11-16 and 11-17. `gh api rate_limit` (as `<DEV_USER>`, 08:3xZ): `limit 5000, remaining 4533`: the hour reset. The fleet shares one GitHub user, and these crons fail their tick while its hour is spent. No code defect named: who spends the hour is a measurement for a perf round, not a bug row. |
| Network: `restore-drill-red-note` `dial tcp ...: i/o timeout` (1, 02:37Z), `issue-close-landed` `git fetch origin/master failed` (1, 2026-11-17T17:35Z) | source 4 | Once each in 24 h. |
| `spawn-fill` `cat: /var/spool-hub/dispatch/briefs/reflection-2026-11-1<n>.md: Permission denied` (10 in the file, the last two for `reflection-2026-11-16.md`, lines 43894, 43907) | `ls -l /var/spool-hub/dispatch/briefs/reflection-2026-11-1*.md` | The 11-13..11-16 briefs are `0600`, the 11-17 one `0660`: SPL-5826 (`0d54d27ec`, 2026-11-17T20:01Z) queues it 0660, and no such line since. The four old files are box state, not code. |
| Day-log fallback after b15-03: `WARN log .../csi-spl-desk-cron/csi-spl-orc/dat/log/bash/csi-spl-orc.20261118.log is not writable, logging to /tmp/run-log-<uid>` (136 lines in hour 08Z) | per-hour count over the cron logs; `ls -l` of the day files | Expected until midnight: b15-03 sets the group when it CREATES the day's file, and `csi-spl-orc.20261118.log` was created before it landed (`<HARNESS_USER>:<HARNESS_USER>`). Both box checkouts hold `3ef117edd` (`merge-base --is-ancestor` -> yes). Re-check after 2026-11-19T00:00Z: the 20261119 file's group, and 0 WARN lines. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| Owner report: the Outlook-imported meetings sit 2 hours early (csitea topic `40c3f89d`, msg 0abcb9ef) | c-060, the topic's seat (SPL-5784; spec 180 v0.3.0, `f284b4148`, "the one-off import's 2 h shift") | Found and answered in its topic; a question to the owner is open there. |
| `box-update` `FATAL Command 'do_spl_box_update' failed` (2, last 2026-11-17T22:00:03Z) | SPL-5847, `wip`, c-002 | As rounds 14 and 15. |
| `env-order` exit 2 (`ENV_ORDER UNKNOWN`, 2026-11-18T03:30:37Z) | the infra steps | By design, as round 14. |
| SPL-5751, 5609, 5411, 5396, 5368, 5254, 5232, 5104, 4994, 4934, 5386, 5217, 5180, 4120, 4416, 4224, 4849, 4301, 3811, 1046, 342, 5016 | as round 15 section 6 | Held by their owners (the same 23 open issues with SPL-5847). |
| `review-go` `REFUSED (rc 8) review line check failed (rc 1): FATAL the line has no '\| log: <id>[@<box>]:<path>'` (line 28227 of 28820) | the review line's author, through `do_spl_review_go` | The gate doing its job on a line without `log:`. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 (a defect fix, red control run on `714a4fc82`) |
| vendor | claude 1 (the lane mix picks claude; R14) |
| R7 | a cross-vendor seat if one places, else the claude waiver seat |
| box (preferred) | sat 1 |
| batches | 1 (no wait) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-401@sat (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder on task `dispatch-bug-r16`, with at least one non-claude seat (rounds 14 and 15: a mistral doc seat).
- **Asked of the holder with the plan:** the b16 slug grep on <box2> (briefs, asks, spawn-remote briefs); whether <box2>'s `spawn-fill` log shows row 01's `unknown_discussion` lines; whether perf round 16 or refactor round 35 will touch `spl-spawn-fill.func.sh` or its test, for R1. All three are answered (review history).
- **Review history:**
  - 2026-11-18 08:46Z: the editor pushed v0.1 (`526155e00`, also landed on `origin/master`) to `review/c002-bug-round-16-planner` and sent the result to the holder c-003@sat (msg 456a4c19).
  - 2026-11-18: the holder queued a mistral panel seat (`c002-bug-round-16-mistral-panel-seat`, ask f746424a, target `526155e00`) and answered R1 (msg b065bf95); it relayed the <box2> answers (msg abccb587). v0.2 folds them in. The seat was placed as m-411@sat (c-001 0ee123d0, holder msg 16e1ddfb) on `526155e00`; the editor named v0.2 to it.
