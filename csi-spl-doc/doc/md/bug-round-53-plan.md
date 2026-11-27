# Bug-fix round 53 - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6657 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `c72ff0ec-f723-40cd-bddd-cd8e349f955b` ("Bug round 53", opened by the dispatch holder; this planner posts in no topic). Bug round 52 ([bug-round-52-plan.md](bug-round-52-plan.md), plan v1.0 `390f756ea`, then `ce158c1fe`, editor `a-264@sat`) served all three rows: b52-01 (`84f86ab8c`, SPL-5254), b52-02 (`138d4829f`, SPL-6643), and b52-03 (`fd844fe99`, SPL-6644). `a-264@sat` owns b52's close record; no b52 record is written here.  
Round focus: fixing the live `do_spl_review_go` owner-go false holds (`## At brief/queue time`, sentence-global `TGT` blocking `HUNK`, `DRY_RUN=0 ./run -a do_rdb_migration_next`, `NEVER` heading variants) batched with b52-02 R7 (`a-537` N1/N2, holder `1ba9cd05`/`3f4caa6b`); completing b52-03's atomic-read fix on `spawn-remote.sh`'s requester side (`request()` / `issue_reply()` / `task_cancelled()`, `c-003@sat` `d127cfe8` / `c-307` `eb33fada`); and fixing the 3rd-sighting CI flake in `releases-row-alternate.test.mjs` (`FAIL S3 1440px dark: shaded row 2 has notes to open`, rulebook 2.11.3, deterministically red 4 hours of every day at UTC hours 4, 9, 14, 19), plus full audit of all 10 sources and the 2026-11-27 ~05:47Z sat mass session loss (`c-272`, `c-307`, `c-309`, `c-312`, `c-314`).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows (aim at 2, cap 3). Three small, disjoint Batch 1 candidates met the bar (section 3) — 2 direct b52 follow-up batches requested by the holder / `c-003@sat` plus 1 rulebook 2.11.3 3rd-sighting CI flake — while 24 h bug share is UNDER (live 16% in 15-20% day band, 24 h 17% vs 20-30% band, `16:31Z`, `do_spl_spawn_share`).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-52-plan.md](bug-round-52-plan.md).

**Status: v0.1 draft for cross-vendor panel review (`c-749@<box2>`, claude).**

Editor: **a-719@sat** (agy, `specs_and_docs`).  
Panel: **c-749@<box2>** (claude, cross-vendor; placed `07:43:20Z` on `dispatch-bug-r53`, live in `do_spl_lane_map` at `16:29Z`; mistral sits on no review since 2026-11-25).

**One sha:** every site, line number and red control below is on **`3308d118f`** (`origin/master`, `3308d118f5516427b8c1b29b91e61e43899d0f8f`, `2026-11-27T17:38:45+01:00` / `2026-11-27T16:38:45Z`, `fix(spec187, SPL-6683): spec 187 lists channel_moved as a pause reason; the run error cap comment names StartRun too`). The sources of section 2 were read on sat, `16:29Z..16:43Z` on 2026-11-27. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b52-plan')` read once at `16:29:50Z` -> `Window: W=2026-11-27T02:28:02+02:00` (commit `ce158c1fe`, `2026-11-27T00:28:02Z`, `docs(b52-plan, SPL-6606): replace rc02 synthetic UUID colliding with qto-private-index fixture`). Ninety-two commits landed in `ce158c1fe..3308d118f`.

---

## 1. How to read this

- `<box2>` is the fleet's box that is not sat and `<dev-box>` one unpinned workstation box, as in rounds 21 to 52: the public repo names none of them.
- **Paths** are repo-relative. Line numbers are as of `3308d118f`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red controls are printed verbatim in section 4. Each is self-contained (zero box paths, runnable on any machine including `<box2>`), copies files from the named sha with `git archive` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout or live spool. Each site guard checks function names only, so `bash rc0N-b53.sh <fix sha>` (without `fix-shape`) exits 0 on a valid fix.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs).
- This seat runs on sat, so `/var/spool-hub/dispatch/c002-next-round-candidates.md`, `/var/spool-hub/dispatch/automation.log`, `/var/spool-hub/dispatch/wd.log`, `/var/csi/csi-spl/agent-login-check/cron.log`, `/var/csi/csi-spl/box-sessions/save.log`, author/reviewer briefs under `/var/spool-hub/dispatch/briefs/`, and `c-001`/`c-002`/`c-003` archives/outboxes were read directly; sat-only evidence is quoted inline below so any reviewer can audit it directly.

---

## 2. Where rows could come from (measured since W `ce158c1fe`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=16h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (`16:30Z`) | 62 entries in 16 h (**62 since W** `00:28:02Z`: 42 Cloud SQL `spool_hub_rt` ad-hoc SQL errors — `relation "tasks" does not exist`, `column "id"/"channel_id"/"channel"/"from_agent"/"envelope"/"from"/"created_at"/"p.id" does not exist`, `invalid regular expression`, `invalid input syntax`, `operator does not exist`; 20 Cloud Run HTTP 503 `malformed HTTP response or connection to the instance had an error`) | **0 rows**: section 3.4 (ad-hoc SQL + transient Cloud Run instance recycles during deploys; 0 alert incidents). |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=16h ./run -a do_gcp_list_alert_incidents` (`16:30:01Z`) | 9 policies (+1 `conditionAbsent` not replayed), 0 incidents in `00:30:01Z..16:30:01Z` | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,120), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (`16:30:23Z`) | 2 issues at `16:30Z` (plus SPL-6657 this round, prio 2): SPL-6683 (`wip`, prio 4, spec 187 text follow-up — **landed** at `16:38:45Z` as `3308d118f`), SPL-4994 (`onhold`, prio 1, hidden workspace terraform) | **0 rows** (SPL-6683 landed; SPL-4994 on hold for terraform/owner). |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (`16:29:49Z..16:35:56Z`, background) | 100 runs, `2026-11-26T13:42:56Z..2026-11-27T16:28:36Z`: 54 success, 28 cancelled, 16 failure, 2 running; every job's p90 under 75% of its timeout (highest: hermetic 3/4, 61%). Failed runs since W (`00:28:02Z`): `46021747971`/`46025971076`/`46027712141` (`orc hermetic 2/4` SKIP in laptop install test — **served** by `ab54a7e40`); `45919393142`/`45969507231`/`45989877541`/`46005015831` (+ `46028960915` on `ab54a7e40`) (`orc hermetic 3/4` `dispatch-rotate.tst.sh` case 32 `polls=7` — **already queued** `d552df78` `bug+urgent`, R3); `45997733391`/`46005015831` (`wui e2e 2/8` `issues-checkbox-header.test.mjs`, green since `59bcffbe`); `45976418580` (`wui e2e 3/8` `monitoring-costs.test.mjs`, single sighting, green since `59bcffbe`); **`46011420307` (`13:56:20Z`) & `46016991209` (`14:33:26Z`) (`wui e2e 8/8` `FAIL S3 1440px dark: shaded row 2 has notes to open` — 3rd sighting with `45878486725` `18:45:46Z` 11-26)** | **Row b53-03** (`releases-row-alternate.test.mjs`, 3rd CI sighting triggers rulebook 2.11.3; section 3.3). Rest served/queued/<=2 sightings (section 3.4). |
| **5. CI, every other workflow on master** | `gh run list --repo csitea/csi-spl --branch master --status failure --limit 40 --json databaseId,workflowName,headSha,createdAt,conclusion` (`16:30:38Z`), `createdAt >= 2026-11-27T00:28:02Z`; `do_check_deploy_lag` (`16:30:39Z..16:30:44Z`) | **1 failed non-wf10 run since W**: `45953190041` (`06:38:52Z`, wf 13 `quality gate on the next runner image` on `31a526346`). `do_check_deploy_lag`: dev and prd hub both `current` (`served=f7ce2a0b`, `n=0`); dev and prd wui both `current` (`served=ed3ae92d`, `n=0`) | **0 rows.** |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=16h LINES=5000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (`16:30Z`; cap 5000 not reached) | 2670 entries in 16 h (**2670 since W** `00:28:02Z`): 1288 `unpinned_box`, 954 `/v1/pins unknown_token`, 134 HTTP 404 `/v1/view/issues/SPL-6271`, 96 `context canceled`, 94 HTTP 404 `/v1/view/issues/SPL-6257`, 16 HTTP 403 `/v1/operator/workspaces`, 14 bare 404s, 13 HTTP 404 `/v1/.env`, 5 `gcal events.list`, 15 `/v1/release-notes/<sha>` 404s, 5 `robots.txt` 404s, 4 `/v1/view/netvisor/forecast` 404s, 4 `/v1/view/topics/ccf42258` 404s, 3 HTTP 409 `/v1/messages/75b2dbf3`, 2 HTTP 403 `/v1/members`, scanner 404s, **0** `hours/minutes` 400s | **0 rows**: section 3.4. |
| **7. R7 notes, automation logs & 05:47Z watchdog log since W** | `git log ce158c1fe..3308d118f --format=%B`, `c-001`/`c-002`/`c-003` spool archives, `/var/spool-hub/dispatch/automation.log`, `/var/spool-hub/dispatch/wd.log`, `/var/csi/csi-spl/agent-login-check/cron.log`, `/var/csi/csi-spl/box-sessions/save.log` | 92 commits (`ce158c1fe..3308d118f`). **b52-02** (`138d4829f`) R7 `a-537` (`69a802c7`, holder `1ba9cd05`/`3f4caa6b`): N1 NEVER heading variants (`:914`) & N2 non-`[br]\d{2}` rc suffix (`:935-936`), plus 2 more `automation.log` rc 4 false holds today (`08:29:05Z` `d3c6d171`, `16:31:07Z` `d185b420`) on top of `b51-01/02/03`, `r08-01/02`, `s187-s1`/`b4952880`. **b52-03** (`fd844fe99`) R7 N2 (`c-003@sat` `d127cfe8`, `c-307` `eb33fada`): requester-side `spawn-remote.sh` `request()`/`issue_reply()` ack race. **05:47Z mass session loss on sat** (`c-272`, `c-307`, `c-309`, `c-312`, `c-314`): measured in `wd.log`, `agent-login-check/cron.log`, `box-sessions/save.log` (section 3.5). **SPL-6681** (`59bcffbee`) R7 `a-686` N1 (`c-001` `9fbbf64d`, `spl-spawn-place.func.sh:586-588,1628-1632`): R3-blocked by queued `c001-s179-b4-spawn-pause-hold`. `c-001` `d04c926b` (queue view false `HELD`) **queued** `033fef08`; `c-001` `b9a0d204` (reused retired id desk seat) **queued** `e9ab1a9d` | **Rows b53-01 and b53-02** (sections 3.1 and 3.2). 05:47Z watchdog and `a-686` N1 accounted in section 3.5. |
| **8. Owner and member posts** | `ENV=prd SQL="select tenant_id, from_id, count(*), max(accepted_at) from messages where from_id like 'HUM-%' and accepted_at > '2026-11-27T00:00:00Z' group by 1, 2 order by 1, 2" ./run -a do_spl_db_query` (`16:30:36Z`) | 0 rows across all workspaces since `2026-11-27T00:00:00Z` | **0 rows.** |
| **9. Round 52's first inputs** | `bug-round-52-plan.md` section 7 and section 3.5, re-measured on `3308d118f` | All 9 items re-checked on `3308d118f`: #1 `MessageCard.vue:1121` R3-blocked by queued `c001-s179-b6-wui-pause-badge-i18n` & `c002-1b0cc8ad-msg-edit-icon-buttons` (still unproven in Chrome); #2 `review-go` owner-go false holds unblocked (`b52-02` landed `138d4829f`) -> **Row b53-01**; #3 seat-rotation poke (spec 060, unchecked on `<box2>`); #4 `a-767` N2 & `a-823` N2 (`spool-agent-hook.sh:140,807-813`); #5 `a-769` N1 (`check-pre-push-lint.func.sh:618-643`) & N2 (`csi-spl-orc/src/bash/tests/tenant-host-reserve.tst.sh`, 0 `symlink` hits); #6 `a4b540f6` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py:795-807`); #7 `c-625` N1-N3; #8 `a-995` N1 (`internal/taskcron/cron_test.go:209-229`); #9 rest of carried list | **Row b53-01**; every other input accounted in section 3.5. |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (173 lines, read on sat `16:29Z`; new since b52: `:169-173`) | `:170` `dispatch-rotate.tst.sh` case 32 flake (`c-003@sat` `01:3xZ`) -> **Queued** as ask `d552df78` (`bug+urgent`, pos 50/108, R3 stay off); `:173` stale freeze text in `csi-spl-doc/doc/help/hours.md:116` & `csi-spl-wui/src/public/help-md/hours.md:110` (`c-404` `48e4f13e`, T085 SPL-6648 landed `23f47357a`, Qto doc `dba06f2e-930e-48b8-9e21-754bb94bc721`, P3 doc bug) -> **Carried** (round at 3-row cap; must edit in Qto and export) | **0 new rows** beyond section 3.1-3.3; both accounted in section 3.5. |

---

## 3. The candidates, read

### 3.1 b53-01: `do_spl_review_go` owner-go false holds (`_spl_review_go_instr` `:723-780`) and b52-02 R7 N1/N2 (`_spl_review_go_c4_missing` `:914,935-936`)

- **What happens.** Verified live on `3308d118f` (`b52-02` SPL-6643 landed as `138d4829f`, so `spl-review-go.func.sh` is free):
  1. **Missing narrative headings in `_spl_review_go_instr` (`spl-review-go.func.sh:723`):** `_spl_review_go_c4_missing` (`:913`) already skips `## At brief time`, `## At queue time`, and `## Lane-map clearance`, but `_spl_review_go_instr` (`:723`) does not. Every brief with an unrelated `## At brief time` note mentioning another round's `DRY_RUN=0` falsely holds `rc 4`: reproduced live on `3308d118f` against `c002-b51-01-orc-y9-qwen-backup-os-error-and-tests.md:24` (`d220964e`), `c002-b51-02-orc-cpu-budget-red-controls-tree.md:24` (`f02f86f7`), and `c002-b51-03-orc-review-go-owner-go-actions.md:24` (`db300104`, `a-104` N1).
  2. **Line-wide `TGT` check breaks `HUNK` (`spl-review-go.func.sh:771`):** `if HUNK.search(l) and not TGT.search(l): l = HUNK.sub("", l)` checks `TGT` (`\blive\b`, `\bdev\b`, etc.) across the entire line rather than the sentence containing `apply ... verbatim hunks`. On `c002-r08-01-orc-worktree-guard-plural.md:50` (`2a6db204`, `21:30Z`) and `c002-r08-02-orc-spool-install-user-loop.md:49` (`ba93d24b`, `21:57Z`), the step begins `"2. Apply the plan's verbatim hunks to ONLY the row's files."` and a later sentence on the same line says `"...never the box's live tmux server."` — `\blive\b` in that unrelated sentence blocks `HUNK`, causing `rc 4` holds on `"Apply"`. Checking `TGT` per sentence (splitting on `[.!?]+(?:\s+|$)`) strips `HUNK` cleanly while still holding `"Apply the verbatim hunks to the live prd database."`
  3. **Read-only migration-number claim `DRY_RUN=0 ./run -a do_rdb_migration_next` (`spl-review-go.func.sh:768-779`):** `do_rdb_migration_next` claims a git ref (`refs/rdb-claims/NNNN`, `developer-guide.md:515`) and performs no prd or GCP mutation, yet every schema brief citing it falsely holds `rc 4` (`b4952880`, `c002-s187-s1.md:29` `d94d59dd` at `22:12Z`). Narrowly stripping `DRY_RUN=0` immediately before `./run -a do_rdb_migration_next` clears those false holds while any chained owner-go token on the same line (`&& ENV=prd ./run -a do_tf_apply`) still holds.
  4. **b52-02 R7 `a-537` N1 (`spl-review-go.func.sh:724,914`, holder `1ba9cd05`/`3f4caa6b`):** `NEVER` at `:914` (`_spl_review_go_c4_missing`) matches `files you must not touch` and `must not touch` but misses `## Files NOT to touch`, `## NOT your files`, and `## Not yours (...)`; `NEVER` at `:724` (`_spl_review_go_instr`) misses all of those variants too. Aligning both `NEVER` regexes eliminates both C4 and owner-go false holds under those headings.
  5. **b52-02 R7 `a-537` N2 (`spl-review-go.func.sh:935-936`, holder `1ba9cd05`/`3f4caa6b`):** `rc = re.match(r"rc(\d{2})(?:-([br]\d{2}))?", m)` makes the suffix group optional, so an `rc` script whose suffix does not match `[br]\d{2}` (e.g. `rc01-p19.sh`, `rc01-foo.sh`) leaves `rc.group(2) is None`, and line `:936` (`rc.group(2) in (None, own[0])`) silently drops it as a bare sibling of `b52-02` instead of requiring it in C4! Matching the full suffix `r"rc(\d{2})(?:-([A-Za-z0-9._-]+))?\.sh$"` keeps bare `rc01.sh` (`None`) and same-round `rc01-b52.sh` (`"b52"`) ignored while requiring `rc01-p19.sh` and `rc01-foo.sh`.
- **Note on broad `DRY_RUN=0` prose:** per `spl-review-go.func.sh:718-719` (*"a new real test description is a false hold to clear by hand, never a false go"*), we intentionally do NOT broaden `DRY` to strip arbitrary `DRY_RUN=0` prose/table mentions (such as today's `d3c6d171` / `d185b420`), keeping owner-go fail-closed.
- **Seen.** Live `automation.log` holds: `d220964e`, `f02f86f7`, `db300104` (`a-104` N1), `2a6db204`, `ba93d24b`, `d94d59dd`, `b4952880`; holder `1ba9cd05` / `3f4caa6b` (`a-537` `69a802c7` N1/N2). Empirically tested `rc01-b53.sh` `fix-shape` against 5 real sat false-hold briefs (`c002-b51-01`, `c002-b51-02`, `c002-r08-01`, `c002-r08-02`, `c002-s187-s1`): **5/5 flip from `rc=1` (false hold) to `rc=0` (PASS)** while all 4 security/negative controls still hold.
- **Red control** (`rc01-b53.sh`, section 4.1): self-contained (extracts `spl-review-go.func.sh` from `3308d118f` into `mktemp -d`). 7 red probes (`red_at_brief_time`, `red_at_queue_time`, `red_hunk_unrelated_live`, `red_rdb_migration_next`, `red_n1_og_not_yours`, `red_n1_c4_never_headings`, `red_n2_c4_non_br_rc_suffix`) ALL fail on `3308d118f` (`rc01 exit 1`) and ALL pass on `fix-shape` (`rc01 exit 0`), with all 4 security controls (`ctrl_real_dry_run_holds`, `ctrl_rdb_plus_prd_holds`, `ctrl_hunk_live_same_sentence_holds`, `ctrl_same_round_sibling_rc_ok`) holding on both.
- **Fix scope.**
  - `csi-spl-orc/src/bash/run/spl-review-go.func.sh`:
    - `:723-724` (`_spl_review_go_instr`): add `at (?:queue|brief) time|lane-map clearance` to `NARR`; align `NEVER` with `:914` to include `files\s+(?:you\s+)?(?:must\s+)?not\s+(?:to\s+)?touch|must not touch|not\s+your(?:\s+files|s)\b|owned elsewhere`.
    - `:768-779` (`_spl_review_go_instr`): check `TGT` per sentence (`strip_hunk` splitting on `[.!?]+(?:\s+|$)`) when stripping `HUNK`; add narrow `RDB = re.compile(r"\bDRY_RUN=0(?=[^\S\n]+\./run[^\S\n]+-a[^\S\n]+do_rdb_migration_next\b)")` and strip it before owner-go scan (function stays <= 75 lines: 63 -> 67 lines). Update header comment `:707-719`.
    - `:914` (`_spl_review_go_c4_missing`): widen `NEVER` to match `## Files NOT to touch`, `## NOT your files`, `## Not yours (...)`.
    - `:935` (`_spl_review_go_c4_missing`): change `re.match(r"rc(\d{2})(?:-([br]\d{2}))?", m)` to `re.match(r"rc(\d{2})(?:-([A-Za-z0-9._-]+))?\.sh$", m)` (stays 60 lines <= 75).
  - `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`: add case 37 after case 36 (`:1519`) covering all 7 red probes + all 4 security controls above. `Docs: none` (narrow false-hold and C4 suffix fixes in `spl-review-go.func.sh`).

### 3.2 b53-02: `spawn-remote.sh` requester-side `request()` / `issue_reply()` (`:199-231,467-478`) and `task_cancelled()` (`:659-663`) still do separate disk reads, turning a mid-read ack of a succeeded reply into `exit 4` ("refused")

- **What happens.** Follow-up of b52-03 (SPL-6644, landed `fd844fe99`, R7 N2 from `c-003@sat` `d127cfe8` / `c-307` `eb33fada`). b52-03 added `read_msg_fields` (`spawn-remote.sh:279-288`, single atomic `cat` with `archive/` fallback) and wired it into the handler side (`handle()`, `handle_issue()`, `note_cancel()`), but left the requester side untouched on `3308d118f`:
  1. `reply_file()` (`:222-231`) reads `$f` from `inbox/` twice (`jq -r '.task_id'` at `:227`, then `body_of "$f"` at `:228`) and returns the `inbox/` path `$f`.
  2. `request()` (`:199-206`) then calls `b="$(body_of "$f" | strip_from_agent)"` (`:201`) on that `$f`. If the role seat runs `spool recv --ack` (moving `$f` from `inbox/` to `archive/`) right after `reply_file()` returned `$f`, `body_of "$f"` returns `""` -> `case ""` falls into `*) say "refused by $box: "; exit 4` — a remote spawn that **succeeded** (`status: ok`) is reported as `refused` (`exit 4`) and the launched lane is orphaned!
  3. `issue_reply()` (`:467-478`) has the identical race (`reply_file` at `:470`, then `body_of "$f"` at `:475`) -> returns `FATAL refused by <box>: ` (`exit 4`) even though the remote desk filed or ended the issue!
  4. `task_cancelled()` (`:659-663`) also does two separate disk reads (`body_of "$f"` at `:659`, then `jq -r '.from'` at `:662`); switching it to `read_msg_fields "$id" "$f"` eliminates the redundant disk read and keeps every spool JSON consumer in `spawn-remote.sh` on one atomic helper.
- **Seen.** `c-003@sat` `d127cfe8` (`07:23:35Z`), `c-307` `eb33fada` (`07:22:29Z`). Reproduced live on `3308d118f` via `rc02-b53.sh` (`16:43Z`): Case A (`request_reply_ack_after_match`) returns `rc=4 out=[spawn-remote: refused by home: ]` (want `rc=0 c-009@home %42`) and Case B (`issue_reply_ack_after_match`) returns `rc=4 has_key=0 out=[spawn-remote: FATAL refused by home: ]` (want `rc=0 key: SPL-9999`) -> `rc02 exit 1`. Both pass on `fix-shape` (`rc02 exit 0`).
- **Red control** (`rc02-b53.sh`, section 4.2): self-contained (extracts `spawn-agents` from `3308d118f` into `mktemp -d`; uses a 1-shot `jq` shim that moves the inbox JSON to `archive/` immediately after `.body` is read from an `inbox/` path).
  - **Case A (`request_reply_ack_after_match`):** `request()` hits `rc=4` (`refused by home: `) on `3308d118f`; `rc=0` (`c-009@home %42`) on `fix-shape`.
  - **Case B (`issue_reply_ack_after_match`):** `issue_reply()` hits `rc=4` (`FATAL refused by home: `) on `3308d118f`; `rc=0` (`key: SPL-9999`) on `fix-shape`.
  - **Case C (`ctrl_archive_reply`):** reply already in `archive/` returns `rc=0` on both.
  - **Case D (`ctrl_refused_exits_4`):** genuine `status: refused` reply still exits `4` with `expired` on both.
- **Fix scope.**
  - `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh`:
    - Replace `reply_file` (`:222-231`) with `reply_body <id> <task>` (~11 lines): reads each candidate file once via `read_msg_fields "$1" "$f"` (with `archive/` fallback), verifies `$_M_TASK == "$2"` and first line `== "$MAGIC_REP"`, prints `$_M_BODY` and returns 0 (else 1).
    - Wire `reply_body` into `request()` (`:197-207`, shrinks 60 -> 58 lines <= 75) and `issue_reply()` (`:467-478`, shrinks 12 -> 10 lines <= 75), removing the second `body_of "$f"` disk read in both.
    - Wire `read_msg_fields "$id" "$f"` into `task_cancelled()` (`:648,659-663`, stays 22 lines <= 75).
  - `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`: add case 17 after case 16 (`:489`) proving `request()` and `issue_reply()` survive a mid-read `inbox -> archive` ack without turning `status: ok` into `exit 4`, plus archive-only and genuine-refused controls. `Docs: none` (completes b52-03's internal TOCTOU fix on the requester side of `spawn-remote.sh`).

### 3.3 b53-03: `releases-row-alternate.test.mjs` (`:74,121-128`) hardcodes shaded row 2 for S3, failing deterministically 4 hours every day (UTC hours 4, 9, 14, 19; 3rd CI sighting, rulebook 2.11.3)

- **What happens.** Workflow 10 hit its **3rd CI sighting** of `FAIL S3 1440px dark: shaded row 2 has notes to open` today:
  1. `45878486725` (`2026-11-26T18:45:46Z`, `wui e2e 3/8` ran at `19:0xZ`, UTC hour **19**)
  2. `46011420307` (`2026-11-27T13:56:20Z`, `wui e2e 8/8` ran at `14:0xZ`, UTC hour **14**)
  3. `46016991209` (`2026-11-27T14:33:26Z`, `wui e2e 8/8` ran at `14:3xZ`, UTC hour **14**)
  Rulebook 2.11.3 (*"Flakes are assigned a fixing lane on their 3rd sighting"*) mandates a fix.
  The defect is 100% deterministic clock arithmetic in `csi-spl-wui/tests/e2e/releases-row-alternate.test.mjs:70-74,121-128` against `csi-spl-wui/src/utils/reporting-releases.ts:386-408`:
  - `mockCommits(now)` (`reporting-releases.ts:387-398`) generates one commit every 30 min back from `top = Math.floor(now / HOUR_MS) * HOUR_MS`, marking every 5th commit `bare = j % 5 === 0` (`:393`, `state: 'missing'`, `lay_what: ''`, so `ReleasesDailyList.vue:79` renders **no** `[data-test=releases-commit-toggle]`).
  - `measure()` (`releases-row-alternate.test.mjs:70-74`) picks the day with the most commits (yesterday's full 48-commit day, starting at `23:30:00Z` yesterday). At UTC hour `H` (`0..23`), today holds `2*H + 1` commits (`j = 0..2*H`), so yesterday's row 1 is `j = 2*H + 1` and **yesterday's row 2 (`[data-alt-probe="2"]`) is `j = 2*H + 2`**.
  - Whenever `H ∈ {4, 9, 14, 19}`, `(2*H + 2) % 5 === 0` (`j = 10, 20, 30, 40`), so row 2 is ALWAYS `bare` (zero toggle button) and S3 (`:121-128`) deterministically fails with `FAIL S3 1440px dark: shaded row 2 has notes to open` — **4 hours of every day (16.7% of all CI runs)**!
- **Seen.** CI runs `45878486725`, `46011420307`, `46016991209` (`do_report_ci_gate` `16:35Z`). Reproduced deterministically across all 24 UTC hours on `3308d118f` via `rc03-b53.sh` (`16:42Z`): `rc03 24h UTC sweep: pass=20/24 fail_hours=[4,9,14,19]` (`rc03 exit 1`); on `fix-shape`: `pass=24/24 fail_hours=[]` (`rc03 exit 0`).
- **Red control** (`rc03-b53.sh`, section 4.3): self-contained (extracts `releases-row-alternate.test.mjs` and `reporting-releases.ts` from `3308d118f` into `mktemp -d`; runs the actual `measure()` + S3 toggle lookup in Node across all 24 UTC hours, zero `node_modules`). Fails on hours `[4,9,14,19]` on `3308d118f` (`rc03 exit 1`) and passes 24/24 hours on `fix-shape` (`rc03 exit 0`).
- **Fix scope.**
  - `csi-spl-wui/tests/e2e/releases-row-alternate.test.mjs:70-130`:
    - In `measure()` (`:70-89`): keep `data-alt-probe="1..3"` for S1/S2 alternation checks (and S3 hover check on row 2), and also tag the first shaded (even 1-based: `i % 2 === 1`) row in the day that carries `[data-test=releases-commit-toggle]` (e.g. `data-alt-probe-shaded` and return `shadedRow`; because `bare` is every 5th commit, row 2 or row 4 always has a toggle at all 24 UTC hours).
    - In `bgOf` / `settledBg` (`:92-100`) and S3 (`:121-128`): click the toggle and assert the opened fill (`--color-surface-hover`) on that tagged shaded row (`shadedSel`), proving S3's contract (*"an opened shaded row shows the open fill"*) at every hour of the day.
    - Keep `reporting-releases.ts` untouched (mock `bare` commits intentionally exist for testing commits without release notes). Author + R7 prove in Chrome against the generated mock bundle both at wall clock and with `Date.now` stubbed to `2026-11-27T14:30:00Z` (`H = 14`, red on base, green on fix). `Docs: none` (fixes time-of-day flake in e2e test `releases-row-alternate.test.mjs`).

### 3.4 CI reds and prd WARNING / ERROR lines, read

| source / item | read | why not a row |
|---|---|---|
| wf 10 (`10_ci-quality.yml`, 100 runs `16:29Z..16:35Z`) | 16 failed runs total; since W (`00:28:02Z`): `orc hermetic 2/4` SKIP (`46021747971`/`46025971076`/`46027712141`, **served** by `ab54a7e40`); `orc hermetic 3/4` `dispatch-rotate.tst.sh` case 32 `polls=7` (`45919393142`/`45969507231`/`45989877541`/`46005015831` + `46028960915`, **already queued** `d552df78` `bug+urgent`, R3); `wui e2e 2/8` `issues-checkbox-header.test.mjs` (`45997733391`/`46005015831`, 2 sightings, green since `59bcffbe`); `wui e2e 3/8` `monitoring-costs.test.mjs` (`45976418580`, 1 sighting, green since `59bcffbe`); `wui e2e 8/8` `releases-row-alternate.test.mjs` S3 (`46011420307`/`46016991209`, 3rd sighting with `45878486725`) | **`releases-row-alternate.test.mjs` -> Row b53-03** (3rd sighting, rulebook 2.11.3). Rest served, queued (R3), or <= 2 sightings (green on `59bcffbe`). |
| Other master workflows (`gh run list --status failure`, `16:30Z`) | 1 failure since W: `45953190041` (`06:38:52Z`, wf 13 next-runner-image on `31a526346`). Deploy lag dev & prd both `current` (`n=0`) | **Not a row**: single next-runner-image check; dev & prd current. |
| Cloud SQL `spool_hub_rt` ad-hoc SQL errors (42 since W) | Exploratory `do_spl_db_query` queries (`relation "tasks" does not exist`, `column "id"/"channel_id"/"from_agent"/"envelope" does not exist`, etc.); no repo code runs them | **Not a row**: ad-hoc operator/agent SQL. |
| Cloud Run HTTP 503 (20 since W) | Transient Cloud Run instance recycles during hub deploys; 0 alert incidents | **Not a row.** |
| prd WARNINGs (2670 since W: 1288 `unpinned_box`, 954 `unknown_token`, 134/94 404s on `SPL-6271`/`SPL-6257`, 96 `context canceled`, 16 403 `/v1/operator/workspaces`, scanner/release-notes 404s, 0 `hours/minutes` 400s) | Carried `unknown_token` box question + `<dev-box>` unpinned retries + deploy-time cancels + expected scanner/non-member 403/404s | **Not a row** (`unknown_token` stays carried with holder). |

### 3.5 Round 52's first inputs, holder/c-003 follow-ups, 05:47Z sat watchdog audit, and candidate list, re-read

| candidate | result on `3308d118f` | verdict |
|---|---|---|
| **#2 `review-go` owner-go false holds + holder `1ba9cd05`/`3f4caa6b` (`a-537` R7 N1 & N2)** (`spl-review-go.func.sh:723-780,914,935-936`) | `b52-02` landed (`138d4829f`), file is free; reproduced live on `3308d118f` (5/5 real false-hold briefs flip `rc=1 -> rc=0`, 7/7 red probes fail on base and pass on `fix-shape`, 4/4 security controls hold) | **Row b53-01** (section 3.1). |
| **`c-003@sat` `d127cfe8` / `c-307` `eb33fada` (b52-03 R7 N2): requester-side `spawn-remote.sh` ack race** (`spawn-remote.sh:199-231,467-478,659-663`) | `b52-03` landed (`fd844fe99`), file is free; reproduced live on `3308d118f` (`rc02-b53.sh` Cases A & B return `rc=4` refused on succeeded `status: ok` replies -> `exit 1`; `fix-shape` `exit 0`) | **Row b53-02** (section 3.2). |
| **wf 10 3rd CI sighting: `releases-row-alternate.test.mjs` S3 flake** (`45878486725`, `46011420307`, `46016991209`, rulebook 2.11.3) | root-caused on `3308d118f` (`releases-row-alternate.test.mjs:70-74,121-128` vs `reporting-releases.ts:393`); `rc03-b53.sh` fails deterministically at UTC hours `[4,9,14,19]` (`20/24`, `exit 1`) and passes `24/24` on `fix-shape` (`exit 0`); 0 live/queued overlap | **Row b53-03** (section 3.3). |
| **#1 `MessageCard.vue` M3 select box** (`MessageCard.vue:1121` `content-visibility: auto`, `c-123` `8e965469`) | verified still present on `3308d118f`; root CSS rule still unproven in Chrome AND **R3-blocked** by queued `c001-s179-b6-wui-pause-badge-i18n` (pos 43/108) and `c002-1b0cc8ad-msg-edit-icon-buttons` (pos 107/108), both editing `MessageCard.vue` | **Carried** to round 54 (wait for queued `MessageCard.vue` rows + isolate exact rule in Chrome first). |
| **2026-11-27 ~05:47Z mass session loss on sat (`c-272`, `c-307`, `c-309`, `c-312`, `c-314`)** | **Measured on sat (`16:31Z..16:36Z`):** (1) At `05:38:01Z..05:40:00Z`, `agent-login-check` (`cron.log`) saw `probe=ok stuck_limit=7` and restored `c-003` (new window) plus `c-272`, `c-278`, `c-307`, `c-309`, `c-312`, `c-314` **in place** (`respawn-pane -k`, panes `%13420`, `%13442`, `%13306`, `%13311`, `%13443`, `%13400`). (2) All 5 lanes logged `OK` in `wd.log` at `05:46:46Z`; between `05:47:02Z` and `05:48:02Z`, **all 5 tmux windows vanished** (`box-sessions/save.log`: `20 windows (11 agent seats)` -> `15 windows (6 agent seats)`, exact drop of 5). (3) **Why watchdog S3 did NOT restart them (NOT restart caps — 0 S3 hits, 0 takeovers, 0 cap hits in `wd.log`):** `spl_wd_agents()` (`spl-watchdog.func.sh:748-773`) checks only live tmux panes, live processes carrying `SPOOL_AGENT_ID`, and `spl_wd_expected()` (`:782-793`), which **intentionally excludes lane ids** (`:780`: *"Lane ids are never listed: a lane that finished is not resurrected; the one exception is a lane the fence TERMed"*). By contrast, `c-001` (`%13427`) and `c-002` (`%13437`) ARE in `spl_wd_expected()` and WERE restarted by S3 at `05:48:42Z`/`05:49:42Z`. (4) **Unresolved root cause:** why all 5 restored tmux windows closed at `05:47:08Z..05:47:28Z` instead of landing on `restore-core.inc.sh:184`'s `exec ... bash --norc` end screen (which S3 would have caught), and whether windowless open-registry lanes should be watched (changing `:780`'s non-resurrection invariant needs a design check, not a guess) | **Carried** as first input #1 for round 54 (audit why in-place restored panes closed at `05:47Z` instead of staying open on `bash --norc`, and decide whether `spl_wd_agents()` should include open-registry local lanes lacking `lifetime/done`). |
| **`c-001` `9fbbf64d` (SPL-6681 `59bcffbee` R7 `a-686` N1): unpinned agy review seat under CPU overflow** (`spl-spawn-place.func.sh:586-588,1628-1632`) | verified still present on `3308d118f`, AND **R3-blocked** by queued `c001-s179-b4-spawn-pause-hold` (pos 42/108, edits `spl-spawn-place.func.sh`) | **Carried** as first input #2 for round 54 (places after `c001-s179-b4-spawn-pause-hold` lands). |
| **`c002-next-round-candidates.md:170` (`dispatch-rotate.tst.sh` case 32 flake)** & **`c-001` `d04c926b` (queue view false `HELD`)** & **`c-001` `b9a0d204` (reused retired id desk seat)** | already queued as `d552df78` (`bug+urgent`, pos 50/108), `033fef08` (`bug`, pos 70/108), and `e9ab1a9d` (`bug`, pos 57/108) | **Queued** (R3 stay off). |
| **`c002-next-round-candidates.md:173` (`hours.md` section 4 stale freeze text, `c-404` `48e4f13e`)** | T085 SPL-6648 landed (`23f47357a`); stale line verified still present at `csi-spl-doc/doc/help/hours.md:116` and `csi-spl-wui/src/public/help-md/hours.md:110` (`- **At the freeze**, suggestions you did not approve are approved as they`); Qto-generated doc (`dba06f2e-930e-48b8-9e21-754bb94bc721`, edit in Qto + export); P3 doc bug, round at 3-row cap | **Carried** to round 54 (edit Qto doc `dba06f2e-930e-48b8-9e21-754bb94bc721` + export + sync `csi-spl-wui/src/public/help-md/hours.md`). |
| **#3 Seat-rotation poke reports exit 0 without reaching new pane** (spec 060, `c-001` `a1a5d394` + `2f3a505e`) | cause still unchecked on `<box2>`; round at 3-row cap | **Carried** to round 54. |
| **#4 `a-767` N2 (`spool-agent-hook.sh:807-813` stale `stop_denies`) & `a-823` N2 (`PreInvocation` at `:140`)** | verified still present on `3308d118f`; round at 3-row cap | **Carried** to round 54. |
| **#5 `a-769` N1 (`check-pre-push-lint.func.sh:618-643` `_ppl_run_timed` 124 vs 137) & N2 (`csi-spl-orc/src/bash/tests/tenant-host-reserve.tst.sh` 0 `symlink` hits)** | verified still present on `3308d118f`; round at 3-row cap | **Carried** to round 54. |
| **#6 `a4b540f6` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py:795-807` `first_sighting` `.mirror/seen`)** | verified still present on `3308d118f`; round at 3-row cap | **Carried** to round 54. |
| **#7 `c-625` N1-N3** (Taxes tab `/v1/view/tax/overview`); **#8 `a-995` N1** (`internal/taskcron/cron_test.go:209-229` malformed step tokens); **#9 rest of carried list** (`a-911` N2, `a-790` N1, `hours/minutes` 400s [0 sightings since W], `c-708` N1, `a-683` N3, `a-490` N1, `a-480` N1, `TestHiddenUnreadBufferBudget`/`TestMarkedUnreadBufferBudget`, `unknown_token` box, hub dir mode, hermetic 2/4 timeout, composed testids, `i18n-lang-review-exempt.json:2`, SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`) | unchanged / verified still present on `3308d118f`; round at rulebook 5.1 cap of 3 | **Carried** to round 54. |

---

## 4. Red controls, as run

### 4.1 `rc01-b53.sh` (b53-01, `review-go` false holds & b52-02 R7 N1/N2), sha256 first 12 hex `75a649275f67`, 8843 B

Run from any checkout: `bash rc01-b53.sh 3308d118f` (exit 1), then `bash rc01-b53.sh 3308d118f fix-shape` (exit 0). Under 3 s each. Self-contained (zero box paths).

```bash
#!/usr/bin/env bash
# rc01-b53.sh <sha> [fix-shape]: b53-01 red control.
# Verifies on <sha>'s tree:
#   1. _spl_review_go_owner_go false holds:
#      - ## At brief time / ## At queue time / ## Lane-map clearance missing from NARR
#        (caused rc 4 holds on b51-01 d220964e, b51-02 f02f86f7, b51-03 db300104 / a-104 N1)
#      - HUNK regex checks TGT across the whole line instead of the clause/sentence
#        carrying `apply ... verbatim hunks` (caused rc 4 holds on r08-01 2a6db204 and
#        r08-02 ba93d24b because a later sentence said "never the box's live tmux server")
#      - DRY_RUN=0 ./run -a do_rdb_migration_next (read-only git claim ref, developer-guide.md)
#        falsely holds rc 4 (b4952880, s187-s1 d94d59dd)
#      - NEVER headings `## Files NOT to touch`, `## NOT your files`, `## Not yours (...)`
#        missed by both _spl_review_go_instr and _spl_review_go_c4_missing (a-537 R7 N1)
#   2. _spl_review_go_c4_missing (a-537 R7 N2, spl-review-go.func.sh:935-936):
#      - an rc suffix not matching [br]\d{2} (e.g. rc01-p19.sh, rc01-foo.sh) gives
#        group(2)=None and is silently dropped as a bare sibling of b52-02.
#   3. Security / negative controls: real owner-go keywords still hold rc 1; same-round
#      sibling rc01-b52.sh on a b52-02 brief still passes C4.
# Extracts spl-review-go.func.sh from <sha> into mktemp -d. Self-contained (no box paths).
set -uo pipefail
sha="${1:?usage: rc01-b53.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" \
  csi-spl-orc/lib/bash/funcs \
  csi-spl-orc/src/bash/run/spl-review-go.func.sh | tar -x -C "$tmp"

fn="$tmp/csi-spl-orc/src/bash/run/spl-review-go.func.sh"
a=$(grep -c '^_spl_review_go_instr()' "$fn")
b=$(grep -c '^_spl_review_go_owner_go()' "$fn")
c=$(grep -c '^_spl_review_go_c4_missing()' "$fn")
echo "rc01 sites: instr=$a owner_go=$b c4=$c"
[ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] || { echo "rc01 sites moved"; exit 2; }

if [ "${2:-}" = fix-shape ]; then
  python3 - "$fn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()

# 1a + 1d: align NARR and NEVER in _spl_review_go_instr
old_nn = '''NARR = re.compile(r"(?i)^(why|what happened|symptoms?|evidence|background|history|trace|observed|measured)\\b")
NEVER = re.compile(r"(?i)^(never|don['\\u2019]t|do not|out of scope)\\b")'''
new_nn = '''NARR = re.compile(r"(?i)^(why|what happened|symptoms?|evidence|background|history|trace|observed|measured|at (?:queue|brief) time|lane-map clearance)\\b")
NEVER = re.compile(r"(?i)^(never|don['\\u2019]t|do not|out of scope|files\\s+(?:you\\s+)?(?:must\\s+)?not\\s+(?:to\\s+)?touch|must not touch|not\\s+your(?:\\s+files|s)\\b|owned elsewhere)\\b")'''
assert s.count(old_nn) == 1, f"instr NARR/NEVER count={s.count(old_nn)}"
s = s.replace(old_nn, new_nn, 1)

# 1b + 1c: sentence-local TGT check for HUNK + narrow DRY_RUN=0 do_rdb_migration_next allow
old_loop = '''DRY = re.compile(r"(?<!`)`DRY_RUN=0`(?!`)(?=[^\\S\\n]+(?:`ORDERED_BY`|install[^\\S\\n]+`ok_msg`|install/check/remove[^\\S\\n]+lifecycle)[^\\S\\n]+(?i:checks?|tests?|cases?)\\b)")
ls = txt.split("\\n")
for i, l in enumerate(ls):
    if HUNK.search(l) and not TGT.search(l):
        l = HUNK.sub("", l)
    if DRY.search(l):
        nxt = next((ls[j] for j in range(i + 1, len(ls)) if ls[j].strip()), "")
        if l.lstrip().startswith("|") and l.count("|") >= 5 and not CMD.search(nxt):
            l = "|".join(DRY.sub("", c) if not CMD.search(c) else c for c in l.split("|"))
        elif not CMD.search(l) and not CMD.search(nxt):
            l = DRY.sub("", l)
    ls[i] = l'''
new_loop = '''DRY = re.compile(r"(?<!`)`DRY_RUN=0`(?!`)(?=[^\\S\\n]+(?:`ORDERED_BY`|install[^\\S\\n]+`ok_msg`|install/check/remove[^\\S\\n]+lifecycle)[^\\S\\n]+(?i:checks?|tests?|cases?)\\b)")
RDB = re.compile(r"\\bDRY_RUN=0(?=[^\\S\\n]+\\./run[^\\S\\n]+-a[^\\S\\n]+do_rdb_migration_next\\b)")
def strip_hunk(line):
    return "".join(HUNK.sub("", seg) if HUNK.search(seg) and not TGT.search(seg) else seg for seg in re.split(r"([.!?]+(?:\\s+|$))", line))
ls = txt.split("\\n")
for i, l in enumerate(ls):
    if HUNK.search(l):
        l = strip_hunk(l)
    if RDB.search(l):
        l = RDB.sub("", l)
    if DRY.search(l):
        nxt = next((ls[j] for j in range(i + 1, len(ls)) if ls[j].strip()), "")
        if l.lstrip().startswith("|") and l.count("|") >= 5 and not CMD.search(nxt):
            l = "|".join(DRY.sub("", c) if not CMD.search(c) else c for c in l.split("|"))
        elif not CMD.search(l) and not CMD.search(nxt):
            l = DRY.sub("", l)
    ls[i] = l'''
assert s.count(old_loop) == 1, f"instr loop count={s.count(old_loop)}"
s = s.replace(old_loop, new_loop, 1)

# 1d: a-537 N1 NEVER heading variants in _spl_review_go_c4_missing
old_c4_never = '''NEVER = re.compile(r"(?i)^(never|don['’]t|do not|out of scope|files you must not touch|must not touch|owned elsewhere)\\b")'''
new_c4_never = '''NEVER = re.compile(r"(?i)^(never|don['’]t|do not|out of scope|files\\s+(?:you\\s+)?(?:must\\s+)?not\\s+(?:to\\s+)?touch|must not touch|not\\s+your(?:\\s+files|s)\\b|owned elsewhere)\\b")'''
assert s.count(old_c4_never) == 1, f"c4 NEVER count={s.count(old_c4_never)}"
s = s.replace(old_c4_never, new_c4_never, 1)

# 2: a-537 N2 non-[br]\d{2} rc suffix
old_rc = '''    rc = re.match(r"rc(\\d{2})(?:-([br]\\d{2}))?", m)'''
new_rc = '''    rc = re.match(r"rc(\\d{2})(?:-([A-Za-z0-9._-]+))?\\.sh$", m)'''
assert s.count(old_rc) == 1, f"c4 rc match count={s.count(old_rc)}"
s = s.replace(old_rc, new_rc, 1)

open(p, "w").write(s)
PY
  echo "rc01 fix-shape: NARR+NEVER aligned, sentence-local HUNK, RDB claim allow, full rc suffix match"
fi

# Source spl-review-go.func.sh in a clean subshell with throwaway SPOOL_ROOT
spool="$tmp/spool"; mkdir -p "$spool/c-002/archive"
rc=0

run_og() {
  local name="$1" want="$2" body="$3" bf="$tmp/$1.md" out got=0
  printf '%s\n' "$body" >"$bf"
  out="$(SPOOL_ROOT="$spool" bash -c 'source "$1"; _spl_review_go_owner_go "$2" c-002' _ "$fn" "$bf" 2>&1)" || got=$?
  echo "rc01 $name: rc=$got (want $want) [${out:-ok}]"
  [ "$got" = "$want" ] || rc=1
}

run_c4() {
  local name="$1" want="$2" want_tok="$3" body="$4" line="$5" bf="$tmp/$1.md" out got=0 tok_ok=1
  printf '%s\n' "$body" >"$bf"
  out="$(SPOOL_ROOT="$spool" bash -c 'source "$1"; _spl_review_go_c4_missing "$2" "$3"' _ "$fn" "$bf" "$line" 2>&1)" || got=$?
  if [ -n "$want_tok" ]; then
    [[ "$out" == *"$want_tok"* ]] || tok_ok=0
  fi
  echo "rc01 $name: rc=$got (want $want) tok_ok=$tok_ok [${out:-ok}]"
  [ "$got" = "$want" ] && [ "$tok_ok" = 1 ] || rc=1
}

# RED probes (fail on base, pass on fix)
run_og red_at_brief_time 0 $'# Lane brief: b51-01\n## Do\n1. Fix the bug.\n## At brief time (2026-11-26)\n- b51-03 must land before the round-52 `DRY_RUN=0` item.'
run_og red_at_queue_time 0 $'# Lane brief: x\n## Do\n1. Fix the bug.\n## At queue time\n- Note: unrelated `DRY_RUN=0` item queued.'
run_og red_hunk_unrelated_live 0 $'# Lane brief: r08-01\n## Do\n2. Apply the plan'\''s verbatim hunks to ONLY the row'\''s files. Any control that drives tmux uses a scratch socket only, never the box'\''s live tmux server.'
run_og red_rdb_migration_next 0 $'# Lane brief: s187-s1\n## Do\n1. Claim the migration number with `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next`.'
run_og red_n1_og_not_yours 0 $'# Lane brief: x\n## Do\n1. Edit a.sh.\n## Files NOT to touch\n- `DRY_RUN=0` in b.sh\n## NOT your files\n- apply in c.sh\n## Not yours (b52)\n- `ENV=prd` in d.sh'

LINE_BASE='review: a-537@sat agy PASS 0123456789abcdef0123456789abcdef01234567 ran: bash own.tst.sh | read: ok | log: a-537@sat:/tmp/x'
run_c4 red_n1_c4_never_headings 0 "" \
  $'# Lane brief: b53-01\n## Do\n1. Run `bash own.tst.sh`.\n## Files NOT to touch\n- `bad1.tst.sh`\n## NOT your files\n- `bad2.tst.sh`\n## Not yours (sibling)\n- `bad3.tst.sh`' \
  "$LINE_BASE"
run_c4 red_n2_c4_non_br_rc_suffix 1 "rc01-p19.sh" \
  $'# Lane brief: b52-02-orc-x\n## Do\n1. Run `bash own.tst.sh`, `bash rc01-p19.sh <sha>`, and `bash rc01-foo.sh <sha>`.' \
  "$LINE_BASE"

# Controls (must hold on BOTH base and fix — zero weakening)
run_og ctrl_real_dry_run_holds 1 $'# Lane brief: x\n## Do\n1. Run `DRY_RUN=0 ./run -a do_spl_desk_up`.'
run_og ctrl_rdb_plus_prd_holds 1 $'# Lane brief: x\n## Do\n1. Run `DRY_RUN=0 ./run -a do_rdb_migration_next && ENV=prd ./run -a do_tf_apply`.'
run_og ctrl_hunk_live_same_sentence_holds 1 $'# Lane brief: x\n## Do\n1. Apply the plan'\''s verbatim hunks to the live prd database.'
run_c4 ctrl_same_round_sibling_rc_ok 0 "" \
  $'# Lane brief: b52-02-orc-x\n## Do\n1. Run `bash own.tst.sh`. Note: row 01 uses `rc01-b52.sh` and `rc01.sh`.' \
  "$LINE_BASE"

echo "rc01 exit $rc"
exit "$rc"
```

Output on `3308d118f` (sat, `16:42Z`):

| run | output |
|---|---|
| `bash rc01-b53.sh 3308d118f` | `rc01 sites: instr=1 owner_go=1 c4=1` / `rc01 red_at_brief_time: rc=1 (want 0)` / `rc01 red_at_queue_time: rc=1 (want 0)` / `rc01 red_hunk_unrelated_live: rc=1 (want 0)` / `rc01 red_rdb_migration_next: rc=1 (want 0)` / `rc01 red_n1_og_not_yours: rc=1 (want 0)` / `rc01 red_n1_c4_never_headings: rc=1 (want 0) tok_ok=1 [bad1.tst.sh, bad2.tst.sh, bad3.tst.sh]` / `rc01 red_n2_c4_non_br_rc_suffix: rc=0 (want 1) tok_ok=0 [ok]` / `rc01 ctrl_real_dry_run_holds: rc=1 (want 1)` / `rc01 ctrl_rdb_plus_prd_holds: rc=1 (want 1)` / `rc01 ctrl_hunk_live_same_sentence_holds: rc=1 (want 1)` / `rc01 ctrl_same_round_sibling_rc_ok: rc=0 (want 0) tok_ok=1 [ok]` / `rc01 exit 1` |
| `bash rc01-b53.sh 3308d118f fix-shape` | `rc01 sites: instr=1 owner_go=1 c4=1` / `rc01 fix-shape: NARR+NEVER aligned, sentence-local HUNK, RDB claim allow, full rc suffix match` / `rc01 red_at_brief_time: rc=0 (want 0) [ok]` / `rc01 red_at_queue_time: rc=0 (want 0) [ok]` / `rc01 red_hunk_unrelated_live: rc=0 (want 0) [ok]` / `rc01 red_rdb_migration_next: rc=0 (want 0) [ok]` / `rc01 red_n1_og_not_yours: rc=0 (want 0) [ok]` / `rc01 red_n1_c4_never_headings: rc=0 (want 0) tok_ok=1 [ok]` / `rc01 red_n2_c4_non_br_rc_suffix: rc=1 (want 1) tok_ok=1 [rc01-p19.sh, rc01-foo.sh]` / `rc01 ctrl_real_dry_run_holds: rc=1 (want 1)` / `rc01 ctrl_rdb_plus_prd_holds: rc=1 (want 1)` / `rc01 ctrl_hunk_live_same_sentence_holds: rc=1 (want 1)` / `rc01 ctrl_same_round_sibling_rc_ok: rc=0 (want 0) tok_ok=1 [ok]` / `rc01 exit 0` |

### 4.2 `rc02-b53.sh` (b53-02, `spawn-remote.sh` requester atomic read), sha256 first 12 hex `38e1b5d20e6e`, 10399 B

Run from any checkout: `bash rc02-b53.sh 3308d118f` (exit 1), then `bash rc02-b53.sh 3308d118f fix-shape` (exit 0). Under 3 s each. Self-contained (zero box paths).

```bash
#!/usr/bin/env bash
# rc02-b53.sh <sha> [fix-shape]: b53-02 red control (c-003 d127cfe8, b52-03 R7 N2,
# c-307 eb33fada).
# On <sha>'s tree, spawn-remote.sh requester-side reply_file() (:222-231) reads
# the reply in inbox/ (.task_id, then .body) and returns its inbox path $f; then
# request() (:201) and issue_reply() (:475) read $f from disk AGAIN via
# `body_of "$f"`. When the role seat runs `spool recv --ack` (moving $f from
# inbox/ to archive/) right after reply_file() matched .body and returned $f,
# request() and issue_reply() read an empty body "" and immediately fail with
# exit 4 ("refused by <box>: ") even though the remote spawn or issue placement
# succeeded (status: ok)!
# Extracts spawn-agents from <sha> into mktemp -d. Self-contained (no box paths).
set -uo pipefail
sha="${1:?usage: rc02-b53.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" \
  csi-spl-orc/lib/bash/funcs \
  csi-spl-orc/src/bash/features/spawn-agents/lib \
  csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh | tar -x -C "$tmp"

sr="$tmp/csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh"
a=$(grep -c '^request()' "$sr")
b=$(grep -c '^issue_reply()' "$sr")
c=$(grep -c '^read_msg_fields()' "$sr")
echo "rc02 sites: request=$a issue_reply=$b read_msg_fields=$c"
[ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] || { echo "rc02 sites moved"; exit 2; }

if [ "${2:-}" = fix-shape ]; then
  python3 - "$sr" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()

# 1. request(): consume atomic reply_body directly (no second disk read)
old_req = '''  local end=$(( $(date +%s) + wait )) f b w
  while :; do
    f="$(reply_file "$from" "$task")"
    if [ -n "$f" ]; then
      b="$(body_of "$f" | strip_from_agent)"
      case "$(sed -n 's/^status: //p' <<<"$b" | sed -n 1p)" in'''
new_req = '''  local end=$(( $(date +%s) + wait )) b w
  while :; do
    if b="$(reply_body "$from" "$task")"; then
      case "$(sed -n 's/^status: //p' <<<"$b" | sed -n 1p)" in'''
assert s.count(old_req) == 1, f"request count={s.count(old_req)}"
s = s.replace(old_req, new_req, 1)

# 2. Replace reply_file with atomic reply_body using read_msg_fields (single read + archive fallback)
old_rf = '''# The reply to TASK in ID's inbox or archive.
reply_file() {  # ID TASK
  local d f
  for d in "$SPOOL_ROOT/$1/inbox" "$SPOOL_ROOT/$1/archive"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      [ "$(jq -r '.task_id // ""' "$f" 2>/dev/null)" = "$2" ] || continue
      body_of "$f" | strip_from_agent | sed -n 1p | grep -xF "$MAGIC_REP" >/dev/null && { printf '%s' "$f"; return 0; }
    done < <(files_holding "$d" "$2")
  done
}'''
new_rf = '''# The stripped body of the reply to TASK in ID's inbox or archive (b53-02).
# Reads each candidate once via read_msg_fields (archive/ fallback), so an ack
# mid-poll cannot empty the body after matching. rc 0 with body on stdout, else 1.
reply_body() {  # ID TASK
  local d f _M_MSG _M_FROM _M_TASK _M_BODY
  for d in "$SPOOL_ROOT/$1/inbox" "$SPOOL_ROOT/$1/archive"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      read_msg_fields "$1" "$f" || continue
      [ "$_M_TASK" = "$2" ] || continue
      [ "$(sed -n 1p <<<"$_M_BODY")" = "$MAGIC_REP" ] && { printf '%s' "$_M_BODY"; return 0; }
    done < <(files_holding "$d" "$2")
  done
  return 1
}'''
assert s.count(old_rf) == 1, f"reply_file count={s.count(old_rf)}"
s = s.replace(old_rf, new_rf, 1)

# 3. issue_reply(): consume atomic reply_body directly
old_ir = '''issue_reply() {  # BOX FROM TASK WAIT
  local end=$(( $(date +%s) + $4 )) f b
  while :; do
    f="$(reply_file "$2" "$3")"
    [ -z "$f" ] || break
    [ "$(date +%s)" -lt "$end" ] || { say "FATAL no reply from $1 within $4 s to the issue request (task $3): its desk's box may be down"; exit 5; }
    sleep "${SPAWN_REMOTE_POLL:-5}"
  done
  b="$(body_of "$f" | strip_from_agent)"'''
new_ir = '''issue_reply() {  # BOX FROM TASK WAIT
  local end=$(( $(date +%s) + $4 )) b
  while :; do
    b="$(reply_body "$2" "$3")" && break
    [ "$(date +%s)" -lt "$end" ] || { say "FATAL no reply from $1 within $4 s to the issue request (task $3): its desk's box may be down"; exit 5; }
    sleep "${SPAWN_REMOTE_POLL:-5}"
  done'''
assert s.count(old_ir) == 1, f"issue_reply count={s.count(old_ir)}"
s = s.replace(old_ir, new_ir, 1)

# 4. task_cancelled(): single atomic read via read_msg_fields too
old_tc = '''  local id="$1" task="$2" d f b from holder hits blind=0'''
new_tc = '''  local id="$1" task="$2" d f b from holder hits blind=0 _M_MSG _M_FROM _M_TASK _M_BODY'''
assert s.count(old_tc) == 1, f"tc local count={s.count(old_tc)}"
s = s.replace(old_tc, new_tc, 1)

old_tc_body = '''      b="$(body_of "$f" | strip_from_agent)"
      [ "$(printf '%s\\n' "$b" | sed -n 1p)" = "$MAGIC_CANCEL" ] || continue
      [ "$(req_field "$b" task)" = "$task" ] || continue
      from="$(jq -r '.from // ""' "$f" 2>/dev/null)"'''
new_tc_body = '''      read_msg_fields "$id" "$f" || continue
      b="$_M_BODY" from="$_M_FROM"
      [ "$(printf '%s\\n' "$b" | sed -n 1p)" = "$MAGIC_CANCEL" ] || continue
      [ "$(req_field "$b" task)" = "$task" ] || continue'''
assert s.count(old_tc_body) == 1, f"tc body count={s.count(old_tc_body)}"
s = s.replace(old_tc_body, new_tc_body, 1)

open(p, "w").write(s)
PY
  echo "rc02 fix-shape: reply_body + request + issue_reply + task_cancelled use atomic read_msg_fields"
fi

S="$tmp/spool" WORK="$tmp/work"
mkdir -p "$S/c-001/inbox" "$S/c-001/archive" "$S/dispatch" "$S/spawn-remote" "$WORK" "$tmp/racebin"
printf 'SPOOL_DESK_BOX=sat\n' >"$S/box.env"
printf 'LEASE_ORCH=c-001\n' >"$S/dispatch/lease.conf"
printf 'c-001@sat 1790995313\n' >"$S/dispatch/lease.orch"

# Stub spool-send.sh: immediately drops a status: ok reply into c-001/inbox/
cat >"$tmp/send-ok-stub" <<EOF
#!/usr/bin/env bash
task=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --task) task="\$2"; shift 2 ;;
    --no-ask|--no-poke) shift ;;
    *) shift 2 ;;
  esac
done
python3 - "$S/c-001/inbox/rep-\$task.json" "\$task" <<'PY'
import json, sys
body = "spawn-reply v1\nstatus: ok\nagent: c-009@home\npane: %42\nrequest: 11111111-1111-4111-8111-111111111111\n"
json.dump({"v":1,"msg_id":"11111111-2222-4333-8444-555555555555","task_id":sys.argv[2],"from":"c-001@home","to":"c-001","kind":"result","ts":"2026-11-27T07:00:00Z","body":body}, open(sys.argv[1],"w"))
PY
EOF
REAL_JQ="$(command -v jq)"
# 1-shot jq shim: moves the inbox JSON to archive/ ONLY when jq reads `.body`
# from an inbox path (right after reply_file's body_of matches and returns $f,
# BEFORE request()/issue_reply() calls body_of "$f" a second time!).
cat >"$tmp/racebin/jq" <<EOF
#!/usr/bin/env bash
"$REAL_JQ" "\$@"; r=\$?
is_body=0
for a in "\$@"; do
  [[ "\$a" == *".body"* ]] && is_body=1
done
if [ "\$is_body" = 1 ]; then
  for a in "\$@"; do
    if [[ "\$a" == "$S/c-001/inbox/"*.json && -f "\$a" ]]; then
      mv -- "\$a" "$S/c-001/archive/\${a##*/}" 2>/dev/null || true
    fi
  done
fi
exit \$r
EOF
chmod +x "$tmp/send-ok-stub" "$tmp/racebin/jq"

sr_lib="$(dirname "$sr")/sr_lib.sh"
sed '/^case "\${1:-}" in$/,$d' "$sr" >"$sr_lib"
rc=0

# Case A (RED 1): request() reply acked right after reply_file() matched .body
rm -f "$S/c-001/inbox/"*.json "$S/c-001/archive/"*.json
outA="$(env SPOOL_ROOT="$S" SPAWN_REMOTE_SEND_CMD="$tmp/send-ok-stub" SPAWN_REMOTE_POLL=1 PATH="$tmp/racebin:$PATH" \
  bash "$sr" --box home --from c-001 --to c-001 --wait 5 claude auto "$WORK" 2>&1)"; rcA=$?
echo "rc02 A(request_reply_ack_after_match): rc=$rcA (want 0) out=[$outA]"
[ "$rcA" = 0 ] && [[ "$outA" == *"c-009@home %42"* ]] || rc=1

# Case B (RED 2): issue_reply() reply acked right after reply_file() matched .body
rm -f "$S/c-001/inbox/"*.json "$S/c-001/archive/"*.json
TASK_B="bbbbbbbb-1111-4111-8111-111111111111"
python3 - "$S/c-001/inbox/iss-$TASK_B.json" "$TASK_B" <<'PY'
import json, sys
body = "spawn-reply v1\nstatus: ok\nkey: SPL-9999\ntenant: t1\nenv: prd\n"
json.dump({"v":1,"msg_id":"22222222-2222-4333-8444-555555555555","task_id":sys.argv[2],"from":"c-001@home","to":"c-001","kind":"result","ts":"2026-11-27T07:00:00Z","body":body}, open(sys.argv[1],"w"))
PY
outB="$(env SPOOL_ROOT="$S" SPAWN_REMOTE_POLL=1 PATH="$tmp/racebin:$PATH" \
  bash -c 'source "$1"; issue_reply home c-001 "$2" 5' _ "$sr_lib" "$TASK_B" 2>&1)"; rcB=$?
echo "rc02 B(issue_reply_ack_after_match): rc=$rcB (want 0) has_key=$(grep -c 'key: SPL-9999' <<<"$outB") out=[$(head -n1 <<<"$outB")]"
[ "$rcB" = 0 ] && [[ "$outB" == *"key: SPL-9999"* ]] || rc=1

# Case C (control 1): reply already in archive/ before poll succeeds
rm -f "$S/c-001/inbox/"*.json "$S/c-001/archive/"*.json
TASK_C="cccccccc-1111-4111-8111-111111111111"
python3 - "$S/c-001/archive/iss-$TASK_C.json" "$TASK_C" <<'PY'
import json, sys
body = "spawn-reply v1\nstatus: ok\nkey: SPL-8888\ntenant: t1\nenv: prd\n"
json.dump({"v":1,"msg_id":"33333333-2222-4333-8444-555555555555","task_id":sys.argv[2],"from":"c-001@home","to":"c-001","kind":"result","ts":"2026-11-27T07:00:00Z","body":body}, open(sys.argv[1],"w"))
PY
outC="$(env SPOOL_ROOT="$S" SPAWN_REMOTE_POLL=1 \
  bash -c 'source "$1"; issue_reply home c-001 "$2" 5' _ "$sr_lib" "$TASK_C" 2>&1)"; rcC=$?
echo "rc02 C(ctrl_archive_reply): rc=$rcC (want 0) has_key=$(grep -c 'key: SPL-8888' <<<"$outC")"
[ "$rcC" = 0 ] && [[ "$outC" == *"key: SPL-8888"* ]] || rc=1

# Case D (control 2): genuine refused reply still exits 4 with its reason
rm -f "$S/c-001/inbox/"*.json "$S/c-001/archive/"*.json
TASK_D="dddddddd-1111-4111-8111-111111111111"
python3 - "$S/c-001/inbox/ref-$TASK_D.json" "$TASK_D" <<'PY'
import json, sys
body = "spawn-reply v1\nstatus: refused\nreason: expired\n"
json.dump({"v":1,"msg_id":"44444444-2222-4333-8444-555555555555","task_id":sys.argv[2],"from":"c-001@home","to":"c-001","kind":"reject","ts":"2026-11-27T07:00:00Z","body":body}, open(sys.argv[1],"w"))
PY
outD="$(env SPOOL_ROOT="$S" SPAWN_REMOTE_POLL=1 \
  bash -c 'source "$1"; issue_reply home c-001 "$2" 5' _ "$sr_lib" "$TASK_D" 2>&1)"; rcD=$?
echo "rc02 D(ctrl_refused_exits_4): rc=$rcD (want 4) has_reason=$(grep -c 'expired' <<<"$outD")"
[ "$rcD" = 4 ] && [[ "$outD" == *"expired"* ]] || rc=1

echo "rc02 exit $rc"
exit "$rc"
```

Output on `3308d118f` (sat, `16:43Z`):

| run | output |
|---|---|
| `bash rc02-b53.sh 3308d118f` | `rc02 sites: request=1 issue_reply=1 read_msg_fields=1` / `rc02 A(request_reply_ack_after_match): rc=4 (want 0) out=[spawn-remote: refused by home: ]` / `rc02 B(issue_reply_ack_after_match): rc=4 (want 0) has_key=0 out=[spawn-remote: FATAL refused by home: ]` / `rc02 C(ctrl_archive_reply): rc=0 (want 0) has_key=1` / `rc02 D(ctrl_refused_exits_4): rc=4 (want 4) has_reason=1` / `rc02 exit 1` |
| `bash rc02-b53.sh 3308d118f fix-shape` | `rc02 sites: request=1 issue_reply=1 read_msg_fields=1` / `rc02 fix-shape: reply_body + request + issue_reply + task_cancelled use atomic read_msg_fields` / `rc02 A(request_reply_ack_after_match): rc=0 (want 0) out=[c-009@home %42]` / `rc02 B(issue_reply_ack_after_match): rc=0 (want 0) has_key=1 out=[spawn-reply v1]` / `rc02 C(ctrl_archive_reply): rc=0 (want 0) has_key=1` / `rc02 D(ctrl_refused_exits_4): rc=4 (want 4) has_reason=1` / `rc02 exit 0` |

### 4.3 `rc03-b53.sh` (b53-03, `releases-row-alternate.test.mjs` 24 h UTC sweep), sha256 first 12 hex `4aea04a9e42c`, 10659 B

Run from any checkout: `bash rc03-b53.sh 3308d118f` (exit 1), then `bash rc03-b53.sh 3308d118f fix-shape` (exit 0). Under 2 s each. Self-contained (zero box paths, zero `node_modules`).

```bash
#!/usr/bin/env bash
# rc03-b53.sh <sha> [fix-shape]: b53-03 red control (3rd CI sighting of
# `FAIL S3 1440px dark: shaded row 2 has notes to open` in wf 10 runs
# 45878486725, 46011420307, 46016991209; rulebook 2.11.3).
# On <sha>'s tree, reporting-releases.ts mockCommits(now) sets `bare = j % 5 === 0`
# (no release notes -> no [data-test=releases-commit-toggle]). In yesterday's full
# 48-commit day (which measure() selects via sort by length), row 2 has index
# j = 2*H + 2 at UTC hour H. Whenever H in {4, 9, 14, 19}, (2*H + 2) % 5 === 0,
# so shaded row 2 NEVER has a toggle and S3 deterministically fails (4/24 hours).
# Extracts releases-row-alternate.test.mjs and reporting-releases.ts from <sha>
# into mktemp -d and runs the actual measure() + S3 selection logic across all
# 24 UTC hours in Node (zero node_modules, zero box paths).
set -uo pipefail
sha="${1:?usage: rc03-b53.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" \
  csi-spl-wui/tests/e2e/releases-row-alternate.test.mjs \
  csi-spl-wui/src/utils/reporting-releases.ts | tar -x -C "$tmp"

tst="$tmp/csi-spl-wui/tests/e2e/releases-row-alternate.test.mjs"
rep="$tmp/csi-spl-wui/src/utils/reporting-releases.ts"
a=$(grep -c '^function measure()' "$tst")
b=$(grep -c '^function mockCommits(' "$rep")
echo "rc03 sites: measure=$a mockCommits=$b"
[ "$a" = 1 ] && [ "$b" = 1 ] || { echo "rc03 sites moved"; exit 2; }

if [ "${2:-}" = fix-shape ]; then
  python3 - "$tst" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()

old_m = """  rows.slice(0, 3).forEach((r, i) => r.setAttribute('data-alt-probe', String(i + 1)))"""
new_m = """  rows.slice(0, 3).forEach((r, i) => r.setAttribute('data-alt-probe', String(i + 1)))
  const shadedIdx = rows.findIndex((r, i) => i % 2 === 1 && r.querySelector('[data-test=releases-commit-toggle]'))
  if (shadedIdx >= 0) rows[shadedIdx].setAttribute('data-alt-probe-shaded', String(shadedIdx + 1))"""
assert s.count(old_m) == 1, f"measure mark count={s.count(old_m)}"
s = s.replace(old_m, new_m, 1)

old_ret = """    rowAlt: resolve('--color-row-alt'),
    hover: resolve('--color-surface-hover'),
  }"""
new_ret = """    rowAlt: resolve('--color-row-alt'),
    hover: resolve('--color-surface-hover'),
    shadedRow: shadedIdx >= 0 ? shadedIdx + 1 : 0,
  }"""
assert s.count(old_ret) == 1, f"measure ret count={s.count(old_ret)}"
s = s.replace(old_ret, new_ret, 1)

old_s3 = """        const toggle = await p.$('[data-alt-probe="2"] [data-test=releases-commit-toggle]')
        if (toggle) {
          await toggle.click()
          await p.mouse.move(0, 0)
          await p.waitForSelector('[data-alt-probe="2"] [data-test=releases-commit-notes]', { visible: true, timeout: 5000 })
          const opened = await settledBg(p, 2, m.hover)
          ok(`S3 ${tag}: an opened shaded row shows the open fill`, opened === m.hover, [opened, m.hover])
        } else ok(`S3 ${tag}: shaded row 2 has notes to open`, false)"""
new_s3 = """        const shadedSel = m.shadedRow ? `[data-alt-probe-shaded="${m.shadedRow}"]` : '[data-alt-probe="2"]'
        const toggle = await p.$(`${shadedSel} [data-test=releases-commit-toggle]`)
        if (toggle) {
          await toggle.click()
          await p.mouse.move(0, 0)
          await p.waitForSelector(`${shadedSel} [data-test=releases-commit-notes]`, { visible: true, timeout: 5000 })
          const opened = await settledBg(p, m.shadedRow || 2, m.hover, shadedSel)
          ok(`S3 ${tag}: an opened shaded row shows the open fill`, opened === m.hover, [opened, m.hover])
        } else ok(`S3 ${tag}: a shaded row has notes to open`, false)"""
assert s.count(old_s3) == 1, f"s3 block count={s.count(old_s3)}"
s = s.replace(old_s3, new_s3, 1)

old_bg = """const bgOf = (p, i) => p.$eval(`[data-alt-probe="${i}"]`, (r) => getComputedStyle(r).backgroundColor)
/** Row i's background once it reads `want`, or what it reads after 3 s: the
 *  row fades its background (transition 0.12s), so a read right after the
 *  hover or the click lands mid-fade. */
const settledBg = async (p, i, want) => {
  await p.waitForFunction((sel, w) => getComputedStyle(document.querySelector(sel)).backgroundColor === w,
    { timeout: 3000 }, `[data-alt-probe="${i}"]`, want).catch(() => {})
  return bgOf(p, i)
}"""
new_bg = """const bgOf = (p, sel) => p.$eval(sel, (r) => getComputedStyle(r).backgroundColor)
/** Row's background once it reads `want`, or what it reads after 3 s: the
 *  row fades its background (transition 0.12s), so a read right after the
 *  hover or the click lands mid-fade. */
const settledBg = async (p, i, want, sel = `[data-alt-probe="${i}"]`) => {
  await p.waitForFunction((s, w) => getComputedStyle(document.querySelector(s)).backgroundColor === w,
    { timeout: 3000 }, sel, want).catch(() => {})
  return bgOf(p, sel)
}"""
assert s.count(old_bg) == 1, f"bgOf count={s.count(old_bg)}"
s = s.replace(old_bg, new_bg, 1)

open(p, "w").write(s)
PY
  echo "rc03 fix-shape: measure() selects first shaded (even) row with toggle; S3 opens that shaded row"
fi

node - "$tst" "$rep" <<'NODE'
const fs = require('node:fs')
const vm = require('node:vm')

const tstSrc = fs.readFileSync(process.argv[2], 'utf8')
const repSrc = fs.readFileSync(process.argv[3], 'utf8')

// Verify mockCommits still computes bare = j % 5 === 0 on 30-min cadence
const hasBare5 = /const\s+bare\s*=\s*j\s*%\s*5\s*===\s*0/.test(repSrc)
const hasHalfHour = /top\s*-\s*j\s*\*\s*30\s*\*\s*60000/.test(repSrc)
if (!hasBare5 || !hasHalfHour) {
  console.log(`rc03 mockCommits formula moved: bare5=${hasBare5} halfHour=${hasHalfHour}`)
  process.exit(2)
}

// Extract measure() verbatim from releases-row-alternate.test.mjs
const mStart = tstSrc.indexOf('function measure()')
const mEnd = tstSrc.indexOf('\nconst bgOf =', mStart)
if (mStart < 0 || mEnd < 0) { console.log('rc03 cannot extract measure()'); process.exit(2) }
const measureSrc = tstSrc.slice(mStart, mEnd)

// Extract the S3 toggle selector expression from releases-row-alternate.test.mjs
const s3Start = tstSrc.indexOf('if (size.desktop && m.n >= 2)')
const s3End = tstSrc.indexOf('await ctx.close()', s3Start)
const s3Src = tstSrc.slice(s3Start, s3End)

function buildMockDays(nowMs) {
  const HOUR_MS = 3600000
  const top = Math.floor(nowMs / HOUR_MS) * HOUR_MS
  const byDay = new Map()
  for (let j = 0; j < 4 * 48; j++) {
    const day = new Date(top - j * 30 * 60000).toISOString().slice(0, 10)
    const bare = j % 5 === 0
    if (!byDay.has(day)) byDay.set(day, [])
    byDay.get(day).push({ j, hasToggle: !bare })
  }
  return [...byDay.entries()].sort((a, b) => (a[0] < b[0] ? 1 : -1)).map(([, commits]) => commits)
}

function makeDoc(daysData) {
  const mkRow = (c) => {
    const attrs = {}
    const row = {
      _c: c,
      attrs,
      parentElement: { appendChild() {} },
      setAttribute(k, v) { attrs[k] = String(v) },
      getAttribute(k) { return attrs[k] ?? null },
      querySelector(sel) {
        if (sel.includes('releases-commit-toggle')) return c.hasToggle ? { _toggle: true } : null
        return null
      },
    }
    return row
  }
  const dayEls = daysData.map((commits) => {
    const rowEls = commits.map(mkRow)
    return {
      rowEls,
      querySelectorAll(sel) {
        if (sel.includes('releases-commit')) return rowEls
        return []
      },
    }
  })
  const allRows = dayEls.flatMap((d) => d.rowEls)
  return {
    documentElement: { getAttribute: () => 'dark' },
    createElement: () => ({ style: {}, remove() {} }),
    querySelectorAll(sel) {
      if (sel.includes('releases-day')) return dayEls
      if (sel.includes('releases-commit')) return allRows
      return []
    },
    querySelector(sel) {
      // Match [attr="val"] [data-test=releases-commit-toggle] or [attr="val"]
      const attrMatch = sel.match(/\[([a-z0-9-]+)="([^"]+)"\]/)
      if (!attrMatch) return null
      const [, k, v] = attrMatch
      const row = allRows.find((r) => r.attrs[k] === v)
      if (!row) return null
      if (sel.includes('releases-commit-toggle')) return row.querySelector('[data-test=releases-commit-toggle]')
      return row
    },
  }
}

let fails = []
for (let h = 0; h < 24; h++) {
  const nowMs = Date.UTC(2026, 10, 27, h, 30, 0)
  const doc = makeDoc(buildMockDays(nowMs))
  const ctx = {
    document: doc,
    getComputedStyle: () => ({ backgroundColor: 'rgb(1, 2, 3)' }),
  }
  vm.createContext(ctx)
  vm.runInContext(measureSrc + '\nthis.__m = measure()', ctx)
  const m = ctx.__m

  // Find which row S3 clicks for toggle:
  // If the test still hardcodes [data-alt-probe="2"] [data-test=releases-commit-toggle], use that;
  // if the fix tags a shaded row (either via m.shadedRow / data-alt-probe-shaded, or by probing
  // even-indexed rows with a toggle), resolve the selector it uses.
  let toggleFound = false
  let chosenEven = false
  if (s3Src.includes(`p.$('[data-alt-probe="2"] [data-test=releases-commit-toggle]')`)) {
    toggleFound = Boolean(doc.querySelector('[data-alt-probe="2"] [data-test=releases-commit-toggle]'))
    chosenEven = true
  } else {
    // Generic check for any valid fix: look for a tagged shaded row (even 1-based index >= 2)
    // OR verify the test no longer hardcodes row 2 exclusively and finds an even row with toggle.
    const days = doc.querySelectorAll('[data-test=releases-day]')
    const rows = days.map((d) => d.querySelectorAll('[data-test=releases-commit]')).sort((a, b) => b.length - a.length)[0] || []
    // Check if measure() set a dedicated shaded-toggle attribute on an even row
    const taggedIdx = rows.findIndex((r, i) => i % 2 === 1 && r.querySelector('[data-test=releases-commit-toggle]') && Object.keys(r.attrs).some((k) => k.startsWith('data-alt-probe') && k !== 'data-alt-probe'))
    if (taggedIdx >= 0) {
      toggleFound = true
      chosenEven = true
    } else if (s3Src.includes('releases-commit-toggle')) {
      // Fix may query inside S3 directly across even rows (2, 4, ...)
      const anyEven = rows.some((r, i) => i % 2 === 1 && r.querySelector('[data-test=releases-commit-toggle]'))
      const dynamicS3 = /for\s*\(|find\(|nth-child|shaded|querySelectorAll/.test(s3Src)
      if (anyEven && dynamicS3) { toggleFound = true; chosenEven = true }
    }
  }
  if (!toggleFound || !chosenEven) fails.push(h)
}

console.log(`rc03 24h UTC sweep: pass=${24 - fails.length}/24 fail_hours=[${fails.join(',')}]`)
if (fails.length > 0) {
  console.log('rc03 exit 1')
  process.exit(1)
}
console.log('rc03 exit 0')
process.exit(0)
NODE
```

Output on `3308d118f` (sat, `16:42Z`):

| run | output |
|---|---|
| `bash rc03-b53.sh 3308d118f` | `rc03 sites: measure=1 mockCommits=1` / `rc03 24h UTC sweep: pass=20/24 fail_hours=[4,9,14,19]` / `rc03 exit 1` |
| `bash rc03-b53.sh 3308d118f fix-shape` | `rc03 sites: measure=1 mockCommits=1` / `rc03 fix-shape: measure() selects first shaded (even) row with toggle; S3 opens that shaded row` / `rc03 24h UTC sweep: pass=24/24 fail_hours=[]` / `rc03 exit 0` |

---

## 5. Rows

| # | id | practice | sites (file:line on `3308d118f`) | evidence | red control (fails on `3308d118f`) | test column (R2; R7 must run EVERY entry in `ran:`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b53-01-orc-review-go-false-holds-and-c4-fixes` | `_spl_review_go_instr` skips `## At brief/queue time` & `## Lane-map clearance`, checks `TGT` per sentence for `HUNK`, allows read-only `DRY_RUN=0 ./run -a do_rdb_migration_next`, and aligns `NEVER` heading variants with `_spl_review_go_c4_missing`, while `_spl_review_go_c4_missing` matches full `rc` suffixes so non-`[br]\d{2}` scripts are not dropped as bare siblings | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:723-724,768-779,914,935-936`; `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (new case 37 after `:1519`) | `bug-round-52-plan.md` section 7 #2; holder `1ba9cd05`/`3f4caa6b` (`a-537` `69a802c7` N1/N2); live rc 4 holds `d220964e`, `f02f86f7`, `db300104`, `2a6db204`, `ba93d24b`, `d94d59dd`, `b4952880`; 5/5 real sat false-hold briefs flip `rc=1 -> rc=0`; section 4.1 | `bash rc01-b53.sh 3308d118f` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` | `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`; `bash csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh`; `bash csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh`; `bash rc01-b53.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x csi-spl-orc/src/bash/run/spl-review-go.func.sh csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `bash csi-spl-iac/src/bash/tests/action-header-tags.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.1: align `NARR` and `NEVER` across `_spl_review_go_instr` (`:723-724`) and `_spl_review_go_c4_missing` (`:914`); sentence-local `TGT` for `HUNK` and narrow `DRY_RUN=0 ./run -a do_rdb_migration_next` allow (`:768-779`, <= 75 lines); full suffix match in `rc` regex (`:935`, <= 75 lines); add case 37 in `spl-review-go.tst.sh` covering all 7 red probes + 4 security controls; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` claude `16:40Z`: `<box2>` 127% / 42% weekly pick, sat 253% / 42% weekly) | claude | agy (preferred; non-secret-class, `BOX_PICK_KIND=agy` `16:40Z`: `<box2>` 127% pick, both `agy weekly unknown`, placed anyway), else claude waiver fallback (`c-001` `77ba5669`) | `simple_coding` | 1 |
| 02 | `b53-02-orc-spawn-remote-requester-atomic-read` | `spawn-remote.sh` requester-side `request()` and `issue_reply()` consume an atomic `reply_body` backed by `read_msg_fields` (single read + `archive/` fallback), and `task_cancelled()` uses `read_msg_fields` too, eliminating mid-read ack races that turn `status: ok` replies into `exit 4` | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh:197-207,221-231,467-478,648,659-663`; `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh` (new case 17 after `:489`) | `c-003@sat` `d127cfe8` (`07:23Z`), `c-307` `eb33fada` (`07:22Z`, b52-03 SPL-6644 `fd844fe99` R7 N2); section 4.2 | `bash rc02-b53.sh 3308d118f` -> `rc02 exit 1`; control `fix-shape` -> `rc02 exit 0` | `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`; `bash csi-spl-orc/src/bash/tests/spawn-remote-cron.tst.sh`; `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-lane-issue-remote-desk.sh`; `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-hold-no-remote.sh`; `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-placement.sh`; `bash csi-spl-orc/src/bash/tests/box-stats-cron.tst.sh`; `bash rc02-b53.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.2: replace `reply_file` (`:222-231`) with `reply_body` using `read_msg_fields` (single read + `archive/` fallback); wire `reply_body` into `request()` (60 -> 58 lines <= 75) and `issue_reply()` (12 -> 10 lines <= 75); wire `read_msg_fields` into `task_cancelled()` (22 lines <= 75); add case 17 in `test-spawn-remote.sh` proving `request()` and `issue_reply()` survive mid-read `inbox -> archive` ack + archive & refused controls; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` `16:40Z`: `<box2>` pick) | claude | agy (preferred; non-secret-class), else claude waiver fallback (`c-001` `77ba5669`) | `simple_coding` | 1 |
| 03 | `b53-03-wui-releases-row-alternate-hour-flake` | `releases-row-alternate.test.mjs` S3 picks the first shaded (even) commit row that carries `[data-test=releases-commit-toggle]` instead of hardcoding row 2, eliminating the 4-hours/day deterministic failure at UTC hours 4, 9, 14, 19 | `csi-spl-wui/tests/e2e/releases-row-alternate.test.mjs:70-100,121-128` | wf 10 3rd CI sighting (rulebook 2.11.3): `45878486725` (`18:45Z` 11-26, H=19), `46011420307` (`13:56Z` 11-27, H=14), `46016991209` (`14:33Z` 11-27, H=14); `reporting-releases.ts:393` `bare = j % 5 === 0`; section 4.3 | `bash rc03-b53.sh 3308d118f` -> `rc03 exit 1` (`fail_hours=[4,9,14,19]`); control `fix-shape` -> `rc03 exit 0` (`24/24`) | `cd csi-spl-wui && pnpm run typecheck`; `node --test csi-spl-wui/tests/unit/cleancode.test.mjs`; `bash rc03-b53.sh <fix sha>` -> exit 0 (without `fix-shape`); `cd csi-spl-iac && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` (run `releases-row-alternate.test.mjs` and every selected e2e file against the generated mock bundle in Chrome, plus prove `releases-row-alternate.test.mjs` passes in Chrome with `Date.now` stubbed to `2026-11-27T14:30:00Z`); `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.3: in `releases-row-alternate.test.mjs`, tag the first even-indexed shaded row with `[data-test=releases-commit-toggle]` in `measure()` and open/assert that shaded row in S3 (keep S1/S2 alternation & S3 hover checks intact; do NOT edit `reporting-releases.ts`); `Docs: none` | sat or `<box2>` (`do_spl_box_pick` `16:40Z`: `<box2>` pick) | claude (WUI never mistral) | agy (preferred; non-secret-class), else claude waiver fallback (`c-001` `77ba5669`) | `tests` | 1 |

- **R1 (disjoint files):** all three rows are Batch 1 and share 0 files:
  - b53-01: `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`
  - b53-02: `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`
  - b53-03: `csi-spl-wui/tests/e2e/releases-row-alternate.test.mjs`
- **R3** (checked on all 5 actual row files at `2026-11-27T16:40:17Z`): `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh,csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh,csi-spl-wui/tests/e2e/releases-row-alternate.test.mjs --agent a-719` -> **exit 4**: 0 live lanes list any of the 5 row files, and 23 live lanes on `<box2>` record no files (`unknown:` at `16:40:17Z`: `c-029`, `c-079`, `c-086`, `c-146`, `c-187`, `c-264`, `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-749`, `c-832`, `c-855`, `c-879`, `c-927`, `c-936`, `c-943`, `c-947`, `c-954`, `c-966`, `c-971`, `c-982`): **not free until the holder re-runs `--check` at placement**. All 108 queued asks (`do_spl_spawn_queue`, `16:30Z`, incl. bug asks `d552df78`, `9ffc1ea8`, `e9ab1a9d`, `033fef08`) were scanned across `/var/spool-hub/dispatch/briefs/` for all 5 row files: **0 overlap**. (Conversely, `MessageCard.vue` and `spl-spawn-place.func.sh` WERE matched by queued spec 179 rows `c001-s179-b6-wui-pause-badge-i18n`, `c002-1b0cc8ad-msg-edit-icon-buttons`, and `c001-s179-b4-spawn-pause-hold`, so both were left out of b53.)
- **R7:** claude-authored code/test rows (all 3 non-secret-class): prefer **agy** R7 seat (`BOX_PICK_KIND=agy ./run -a do_spl_box_pick` `16:40Z`: `<box2>` 127% pick, sat 253%, both `agy weekly unknown`, placed anyway — note `<box2>` agy quota issues today so pin sat or use claude waiver fallback `c-001` `77ba5669` as appropriate). No grok (`c-001` `dc84300a`). No mistral (no review seat since 2026-11-25, no coding/testing kind, never WUI). Every test in the row's R2 test column (including `cd csi-spl-iac && ./run -a do_check_pre_push`, `rc0N-b53.sh <fix sha>`, and for b53-03 the Chrome e2e runs) MUST appear in R7's `ran:` (rulebook C4).
- **Rhythm (1.4):** rows queue once the panel signs and `do_spl_review_line_check` exits 0; all b52 rows have already landed (`84f86ab8c`, `138d4829f`, `fd844fe99`); rows run at night through the placer load guard.
- **Pushes:** aim 1 per row (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug` (priority 2).

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| Bug round 52 close record (`bug-round-52-plan.md`, SPL-6606) | `a-264@sat` | b52 rows landed (`84f86ab8c`, `138d4829f`, `fd844fe99`); `a-264@sat` owns b52's close record; stay off. |
| Refactor round 10 (`6f9fef225`, closed) and refactor round 11 (`r11-01` `fa3981e0a`, `r11-02` `5db7cef92`) | live/done lanes | owned; stay off. |
| Queued bug asks (`d552df78` `dispatch-rotate.tst.sh` case 32 flake `bug+urgent`, `9ffc1ea8` s187 N4 move rewrites `scope_query`, `e9ab1a9d` reused retired id desk seat, `033fef08` queue view false `HELD`) | queued (`do_spl_spawn_queue`) | owned; stay off. |
| Queued spec 179 B2-B7 (`06fede51`..`852ae4b8`, incl. B4 `spl-spawn-place.func.sh` & B6 `MessageCard.vue`), spec 193 B1-B7 (`573fea11`..`0e7768e9`), and `c002-1b0cc8ad-msg-edit-icon-buttons` (`MessageCard.vue`) | queued | owned; stay off (`MessageCard.vue` and `spl-spawn-place.func.sh` carried to b54). |
| Live feature / CI / review / private workspace lanes (`c-876@<box2>` s169 T17, `c-966@<box2>` CI A1b, `c-832@<box2>`/`a-670@sat` search panel, `c-264@<box2>` s158 P2, `c-309@sat` s181 B14, `c-651@sat`/`a-664@sat` laptop box, `c-982@<box2>` s187 N4, private workspace seats) | live lanes per `do_spl_lane_map` | owned; stay off. |
| The `unknown_token` box (954 prd WARNINGs since W) | the holder, as a box question | carried. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 3 (all Batch 1, R1 disjoint; within rulebook 5.1 cap of 3; bug share UNDER over 24 h: live 16% in 15-20% day band, 24 h 17% vs 20-30% band) |
| inputs re-measured | 10 sources; 62 prd ERROR entries in 16 h (62 since W: 42 ad-hoc Cloud SQL, 20 transient Cloud Run 503s); 2670 prd WARNING entries in 16 h (401s left out, cap 5000 not reached; 2670 since W; 0 `hours/minutes` 400s); 9 alert policies (+1 absent; 0 incidents); 2 open t1 bug-labelled issues + SPL-6657 (SPL-6683 landed as `3308d118f`, SPL-4994 onhold terraform); 100 wf 10 runs (54 success, 28 cancelled, 16 failure, 2 running; `releases-row-alternate.test.mjs` S3 3rd sighting taken as b53-03, case 32 flake queued `d552df78`, hermetic 2/4 SKIP served `ab54a7e40`); 1 failed non-wf10 master run since W (wf 13 next-runner-image); 92 commits in `ce158c1fe..3308d118f` + `c-001`/`c-002`/`c-003` archives + `automation.log` + sat `wd.log` / `agent-login-check/cron.log` / `box-sessions/save.log` (05:47Z mass session loss traced); 0 HUM posts since `00:00:00Z`; round 52's first inputs (all 9 re-measured); holder's candidate list (173 lines on sat); `rc01-b53.sh` (`75a649275f67`, 8843 B), `rc02-b53.sh` (`38e1b5d20e6e`, 10399 B), and `rc03-b53.sh` (`4aea04a9e42c`, 10659 B) n=1 each way on `3308d118f` (`shellcheck -S warning` rc 0 on all 3); 5/5 real sat false-hold briefs verified flipping `rc=1 -> rc=0` on `rc01` `fix-shape`; baselines `bash-cleancode.tst.sh` (all assertions PASS), `action-header-tags.tst.sh` (`873 files`, ALL PASS) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b53-'` -> 0; `git ls-remote origin 'refs/heads/review/b53-*' 'refs/heads/wip/*b53*' 'refs/heads/*-b53-*' 'refs/heads/*bug-round-53*'` -> nothing (rc 0); briefs on sat matching `*b53*` / `*bug-round-53*`: only `hand-sat-c001-bug-round-53-planner.md` and `c001-bug-round-53-claude-panel-seat.md` (plus unrelated topic hex `c002-f7b53cf8-topic-title-filter-select-listed.md`) (`16:29Z`) |
| R7 seat | agy preferred (non-secret-class; `BOX_PICK_KIND=agy` `16:40Z`: `<box2>` 127% pick, sat 253%, both `agy weekly unknown`, placed anyway; pin sat if `<box2>` agy quota-locked), else claude waiver fallback (`c-001` `77ba5669`) |
| first inputs for round 54 | 2026-11-27 ~05:47Z sat mass session loss (`c-272`, `c-307`, `c-309`, `c-312`, `c-314` restored in place `05:38-05:40Z` by `agent-login-check`, all 5 tmux windows closed `05:47:02Z..05:48:02Z` in `box-sessions/save.log` `20 -> 15`, 0 S3 hits in `wd.log` because `spl_wd_expected()` `:780-793` excludes lane ids — trace why in-place restored panes closed instead of staying open on `restore-core.inc.sh:184` `bash --norc`, and decide whether open-registry local lanes lacking `lifetime/done` enter `spl_wd_agents()`); `c-001` `9fbbf64d` (SPL-6681 `59bcffbee` R7 `a-686` N1: unpinned agy review seat under CPU overflow in `spl-spawn-place.func.sh:586-588,1628-1632` — places after `c001-s179-b4-spawn-pause-hold` lands); `MessageCard.vue` M3 select box (`MessageCard.vue:1121` `content-visibility: auto`, `c-123` `8e965469` — isolate exact CSS rule in Chrome + wait for queued `c001-s179-b6-wui-pause-badge-i18n` & `c002-1b0cc8ad-msg-edit-icon-buttons`); stale freeze text in `hours.md` (`csi-spl-doc/doc/help/hours.md:116` & `csi-spl-wui/src/public/help-md/hours.md:110`, Qto doc `dba06f2e-930e-48b8-9e21-754bb94bc721`, `c-404` `48e4f13e`); seat-rotation poke reporting exit 0 without reaching the new pane (`c-001` `a1a5d394` + `2f3a505e`, spec 060, cause unchecked on `<box2>`); `a-767` N2 (`spool-agent-hook.sh:807-813` stale `stop_denies`) & `a-823` N2 (`PreInvocation` at `:140`); `a-769` N1 (`check-pre-push-lint.func.sh:618-643` `_ppl_run_timed` 124 vs 137) & N2 (`csi-spl-orc/src/bash/tests/tenant-host-reserve.tst.sh` symlink control); `a4b540f6` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mirror.py:795-807` dangling `.mirror`); `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`); `a-995` N1 (`internal/taskcron/cron_test.go:209-229` malformed step tokens in `TestRefusals`); plus carried items (`a-911` N2, `a-790` N1, `hours/minutes` 400s [0 sightings since W], `c-708` N1, `a-683` N3, `a-490` N1, `a-480` N1, `TestHiddenUnreadBufferBudget`/`TestMarkedUnreadBufferBudget`, `unknown_token` box, hub dir mode, hermetic 2/4 timeout, composed testids, `i18n-lang-review-exempt.json:2`, SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** `a-719@sat` (agy, `specs_and_docs`).
- **Panel:** `c-749@<box2>` (claude, cross-vendor; placed `07:43:20Z` on `dispatch-bug-r53`).
- **Row reviewer (R7):** section 5.
- **Review history:**
  - 2026-11-27 16:50Z: v0.1 drafted on `3308d118f`, pushed to `review/c001-bug-round-53-planner` (3 rows: b53-01, b53-02, b53-03), sent to panel `c-749@<box2>` and dispatch holder `c-003@sat` on task `dispatch-bug-r53`.
