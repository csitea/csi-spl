# Bug-fix round 46 - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6459 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `3b5b6003-ec74-4a32-8d8d-ef299ae5bfc5` ("Bug round 46", opened by c-002@sat 06:01Z, post `95e4962e`, correction `fdd4a158`). Round 45 ([bug-round-45-plan.md](bug-round-45-plan.md)) served its one row b45-01 (`958049e92`, SPL-6451) and is closed (`5c0ba2f40`, written by this seat).  
Round focus: the sources of rounds 40 to 45 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since W, owner posts), round 45's first inputs, and the holder's candidate list on sat.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. Three disjoint candidates met the bar (section 3).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-45-plan.md](bug-round-45-plan.md).

**Status: v0.2, for cross-vendor panel re-review (c-440@sat, claude): v0.1 W1 and N1 to N5 folded (section 8).** No row lane starts before the panel signs the plan sha and `do_spl_review_line_check` exits 0 (rulebook 3.2).

Editor: **a-438@sat** (agy, `specs_and_docs`).  
Panel: **c-440@sat** (claude, cross-vendor; placed by the holder, msg `c4e6d9ad`; mistral sits on no review since 2026-11-25).

**One sha:** every site, line number and red control below is on **`5c0ba2f40`** (`origin/master` at this seat's fetch, 2026-11-25T06:16Z, go1.26.10). At v0.2 (06:42Z), `origin/master` is `d5f1a228d` and all 7 row files are unchanged (`git diff --stat 5c0ba2f40 d5f1a228d -- <the 7 row files>` -> empty), so every site and red control holds at that head. Of the 7 row files, only `spl-review-go.func.sh` and `spl-review-go.tst.sh` changed since `9f3c8a72e` (by b45-01 `958049e92`, which introduced row b46-03's defect). The sources of section 2 were read on sat, 06:04Z..06:16Z (and the 72 h `hours/minutes` 400 recount at 06:42Z) on 2026-11-25. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b45-plan')` read once at 06:04:46Z (before this seat's Task 1 close record landed) -> `Window: W=2026-11-24T21:15:46+01:00` (commit `9f3c8a72e`, round 45's v1.0 plan). The close record `5c0ba2f40` (06:10Z) is a newer `docs(b45-plan` commit; the recorded W stays (5.3: the planner reads W once). Since W, `origin/master` took 67 commits to `5c0ba2f40` (66 to `5855e3ca3` before Task 1).

---

## 1. How to read this

- `<box2>` is the fleet's box that is not sat, `<ws>` one customer workspace, `<dev-box>` one unpinned workstation box, as in rounds 21 to 45: the public repo names none of them.
- **Paths** are repo-relative. Line numbers are as of `5c0ba2f40`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red controls are printed verbatim in section 4. Each copies files from the named sha with `git archive` or `git show` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs). Two read-only DB queries by this seat after source 1 was read added 2 statement errors to the prd Cloud SQL log (`column "id" does not exist` on `channels`, 06:10Z; `relation "channel_members" does not exist`, 06:15Z): the same shape as source 1's lines.
- This seat runs on sat, so `/var/spool-hub/dispatch/c002-next-round-candidates.md`, `/var/csi/csi-spl/review-go/cron.out` and the sat spool (`dispatch-bug-r45`) were read directly.

---

## 2. Where rows could come from (measured since W)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=12h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (06:05:47Z) | 23 entries (18:17Z..06:03Z), 17 since W: 16 Cloud SQL statement errors (`column "id"/"key"/"channel"/"to_box"/d.issue_id/d.issue_number/m.created_at does not exist`, `uuid ~~ unknown`, `uuid = text`, `invalid input syntax for type uuid`, `GROUP BY position 2`) + 1 Cloud Run 503 OPTIONS on `e2e.spool-hub.ai` at 21:03:04Z | **0 rows.** The 16 SQL errors are hand-written `do_spl_db_query` reads with wrong names (rounds 41 to 45 shape); the 1 Cloud Run 503 OPTIONS is a single transient connection error. |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=12h ./run -a do_gcp_list_alert_incidents` (06:05:52Z) | 9 policies, 0 incidents in 18:05:52Z..06:05:52Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,120), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (06:05:58Z) | 10 issues: SPL-6459 (this round, wip), 6 wip issues in the release-transfer repo (SPL-6443, 6442, 6435, 6361, 6362, 6366), 3 onhold (SPL-5911, 5254, 4994); plus SPL-6460 queued separately (holder msg `7493414d`) | **0 rows.** All wip/queued bug issues are owned (R3, section 6) or in the release-transfer repo, not this one. |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (06:05Z..06:16Z, background) | 100 runs, 2026-11-24T11:28:47Z..2026-11-25T05:51:17Z: 38 cancelled, 34 success, 27 failure, 1 running; every job's p90 under 75 % of its timeout (highest: hermetic 1/4, 60 %). Latest 10 completed wf 10 runs (`c69d8b287`..`5c0ba2f40`, 02:45Z..06:10Z): 10/10 **success** | **0 rows**: section 3.4. Every failure in the 27 runs is served on master. |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 100 --json databaseId,workflowName,headSha,createdAt,conclusion` (06:07Z), `createdAt >= 2026-11-24T20:15:46Z` | 58 failed runs since W: 38 of wf 40 (tenant host reconcile), 20 of wf 10 (source 4) | **0 rows.** wf 40 is standing/owned (brief carry item 9, R3); wf 10 is source 4. |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=12h LINES=5000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (06:05:58Z; cap not reached), plus targeted 72 h `hours/minutes` >=400 read (06:42Z) and 7 d `fleet token surge` read (06:13Z) | 952 entries, 813 since W: 361 `upload token refused` (`unknown_token`), 149 DELETE + 74 GET `/v1/operator/calendar/events/<uuid>` 404 (20:21Z..20:29Z curl sweep on `<ws>`), 18 `operator/workspaces` 403, 9 `ws hello refused` (`unpinned_box`), 9 `short/268185` 404, 5 `github: request refused` 404, **1 `fleet token surge: #fleet-alerts does not exist in the operator workspace, alert not posted`** (01:33:04Z; **5 in 7 d**), scanner probes. Targeted 72 h read of `PUT /v1/me/hours/minutes` status>=400: 12 entries = **8 HTTP 400s** (4 on Nov 23: `08:21:10Z` + `16:02Z..16:12Z`; 4 on Nov 24: `12:50Z..13:00Z`; all `responseSize: 385`, Android Chrome 157, 0 hub log lines) + 4 HTTP 401s | **Row b46-01** (hours/minutes 400 blind logging, section 3.1). `#fleet-alerts` missing in prd `t1` (5 dropped surge alerts in 7 d) handed to holder (section 3.5, section 6; now owned by `c-325@<box2>`). |
| **7. R7 notes of lanes landed since W** | `git log origin/master --since="$W" --format='COMMIT %h %cI %s%n%B%n---END---'` (67 commits to `5c0ba2f40`, 14 with `review:` lines) and `spool tail --task dispatch-bug-r45` | 14 commits with `review:` lines: `322c8b69d` (a-398, W1-W3 closed), `c13abfb6a` (a-392), `958049e92` (b45-01, a-374 **N1**), `2924c633f` (r97-01, a-366), `529f837ef` (r97-02, a-363), `1bc99663b` / `156188ae0` (p19-01, c-317), `94bc0a57a` (p19-05, c-262), `c845a3116` (p20-03, c-106), `6a559f248` (p20-06, c-269), `589a62983` / `95650995f` (p20-05, c-082), `46fad3b96` (p20-02, c-265), `7190e2cb9` (p20-07, c-267) | **Row b46-03** (b45-01 R7 a-374 N1, section 3.3). No other unowned bug in the remaining 13 commits. |
| **8. Owner and member posts** | `ENV=prd SQL="select tenant_id, from_id, count(*), max(accepted_at) from messages where from_id like 'HUM-%' and accepted_at > '2026-11-24T20:15:46Z' group by 1, 2 order by 1, 2" ./run -a do_spl_db_query` (06:06:05Z) | 0 rows across all workspaces | **0 rows.** |
| **9. Round 45's first inputs** | `bug-round-45-plan.md` section 7, every item re-measured on `5c0ba2f40` | 11 named inputs + 7 carried N2s | **Row b46-01** (hours-minutes 400 first step) and **Row b46-02** (store/hub `categories_test.go` + `reporting_schema_test.go:196` `zz` isolation); `r96-01 N1` served (`2924c633f`), topic loop cap already atomic (`topicLoopFireSQL` + `TestTopicLoopCapConcurrent`); rest section 3.6. |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (read directly on sat, 06:04Z) | 140 lines (round 45 read 134): new lines 135-140 are p19 probe note (`:136-137`), release-transfer `zip_dirs` (`:139`, other repo), p20-01 perf note (`:140`). Older bug lines re-checked on `5c0ba2f40` | **Row b46-02** (`:118`, `categories_test.go` + `reporting_schema_test.go` `zz` isolation); older b30/b31/b32/b36/b44 entries already served; rest section 3.6. |

---

## 3. The candidates, read

### 3.1 b46-01: `PUT /v1/me/hours/minutes` 400 (`bad_minutes`) logs nothing, leaving recurring prd 400s blind

- **What happens.** When `parseHoursMinutes` (`csi-spl-api/src/go/spool-hub-api/internal/hub/hours_me.go:527-548`) rejects a tab-minute batch (bad `tz`, 0 or >60 rows, bad RFC 3339 `at`, or any minute more than `hoursMinuteSkew = 2 * time.Minute` ahead of `now` or older than 45 days at `:541`), `handlePutMyHoursMinutes` (`:562-566`) calls `writeErr(w, http.StatusBadRequest, "bad_minutes", bad)` and returns with **zero hub log output** (`s.o.Log` is never called). Because the WUI drops any HTTP 400 batch as final (`csi-spl-wui/src/utils/hours-recorder.mjs:121`), those active minutes are silently lost while Cloud Logging shows only the bare HTTP 400 request line (`status=400`, `responseSize=385`), with no reason, tenant, member or clock skew.
- **Seen.** Live in prd Cloud Run logs: **8 HTTP 400 sightings in 72 h** (re-measured 06:42Z, folding panel N1: 4 on 2026-11-23 at `08:21:10Z` and `16:02Z..16:12Z`; 4 on 2026-11-24 at `12:50Z..13:00Z`), all `responseSize: 385` from Android Chrome 157 (the other 4 of 12 `>=400` rows in that window are HTTP 401s). Round 45 (`bug-round-45-plan.md` sections 3.3 and 7) carried this as its first input with the explicit first step: *"the hub logs the `bad_minutes` detail on a 400"*.
- **Red control** (`rc01-b46.sh`, section 4.1): on `5c0ba2f40`, `PUT /v1/me/hours/minutes` with a future-skewed minute (`now + 5m`) returns 400 and logs only the middleware's `level="info" message="http"` line (0 warn lines with reason) -> `rc01 exit 1`. **Control**: `fix-shape` logs one structured `warn` line (`tenant`, `member`, `reason`, `count`) on 400 while a valid 200 PUT logs 0 warn lines -> `rc01 exit 0`.
- **Fix scope.** `csi-spl-api/src/go/spool-hub-api/internal/hub/hours_me.go` (`handlePutMyHoursMinutes`, `:562-566`; currently 40 lines, well under `cleancode_test.go`'s 75-line cap; keep it under 75 lines, using a small helper if adding skew fields): before `writeErr(w, http.StatusBadRequest, "bad_minutes", bad)`, log one structured `s.o.Log.Warn()` line carrying `tenant`, `member`, `reason` (`bad`), `count` (`len(body.Minutes)`), and when a parsed minute is ahead of `now`, `max_skew_s` (whole seconds ahead of `now`, else omitted or 0); no duplicate zerolog keys (b42-01 rule), no raw URL/body secrets. Keep the HTTP 400 `bad_minutes` response contract and spec 107 unchanged. `csi-spl-api/src/go/spool-hub-api/internal/hub/hours_me_test.go`: add a test capturing `s.o.Log` into a `bytes.Buffer` proving a future-skewed 400 and a bad-tz 400 each emit one structured warn JSON line carrying `reason`, `tenant`, `member`, `count` (and positive `max_skew_s` on the future-skewed batch) with 0 duplicate keys, and a valid 200 PUT emits 0 warn lines. `Docs: none` (observability log line only; HTTP contract unchanged).

### 3.2 b46-02: category tests insert non-`zz` paths (`go_`, `t_`) and `reporting_schema_test.go:196` counts top-level areas without a `zz` filter, breaking `TestActivityCategoriesSchema` on reused or concurrent Postgres DBs

- **What happens.** `TestActivityCategoriesSchema` (`csi-spl-api/src/go/spool-hub-api/internal/store/reporting_schema_test.go:180`) asserts the 16-row `activitySeed` using `SELECT category_path FROM activity_categories WHERE category_path !~ '(^|/)zz' ORDER BY 1`, inserts its own `coding/hard/zz<uid>` leaf at `:199-201`, and checks the 5 top-level seed areas at `:196` via `SELECT 1 FROM activity_categories WHERE parent_path IS NULL` (**with no `zz` filter**). Meanwhile, three test sites create non-`zz` rows cleaned only by `t.Cleanup`:
  1. `csi-spl-api/src/go/spool-hub-api/internal/store/categories_test.go:64` (`TestCategoriesStoreCRUD`): `leaf := "coding/hard/go_" + strings.ToLower(uid(""))`;
  2. `csi-spl-api/src/go/spool-hub-api/internal/hub/categories_test.go:44` (`TestCategoryRoutes`): `leaf := "coding/hard/go_" + strings.ToLower(newTenantID(""))`;
  3. `csi-spl-api/src/go/spool-hub-api/internal/store/categories_test.go:113-117` (`TestCategoryDeleteInUseRefused`): `root := "t_" + strings.ToLower(uid(""))` and `child := root + "/used"` (top-level `parent_path IS NULL` root plus child).
  Any killed/timed-out run (skipping `t.Cleanup`) or concurrent `go test ./internal/store ./internal/hub` run against the shared Postgres test DB leaves these rows visible to `TestActivityCategoriesSchema` — breaking `:180` (non-`zz` paths) and `:196` (even a `zz`-prefixed top-level test root breaks `parent_path IS NULL` == 5 without a `zz` filter) until the DB is wiped.
- **Seen.** Holder's candidate list (`c002-next-round-candidates.md:118`, evidence g-786 review `84bb230e` N3 on `2296ff890`), round 45 section 7 ("the store tests' fresh-DB need"), and panel c-440@sat W1 (`seat-claude.md`, catching `TestCategoryDeleteInUseRefused` `:113-117` and `reporting_schema_test.go:196`). Full sweep verified on `5c0ba2f40` via `git grep -n 'CreateCategory\|INSERT INTO activity_categories' 5c0ba2f40 -- csi-spl-api/` plus reading `hub/categories_test.go` whole: no other test inserts into `activity_categories` (all other hits are refused constraint/RLS tests or `reporting_schema_test.go:199`'s `"zz"` leaf).
- **Red control** (`rc02-b46.sh`, section 4.2, widened for panel W1): on `5c0ba2f40`, checks all four sites (leaf literals at `store/categories_test.go:64` and `hub/categories_test.go:44`, root literal at `store/categories_test.go:113`, and the top-level query at `reporting_schema_test.go:196`) -> all 4 fail (`rc02 exit 1`). **Control**: `fix-shape` (`go_` -> `zzgo_`, `t_` -> `zzt_`, and `AND category_path !~ '(^|/)zz'` at `:196`) -> `rc02 exit 0`.
- **Mandatory Postgres gate (panel N2):** because `rc02-b46.sh` is static, the row's mandatory gate is running real Postgres (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`) plus a live Postgres leak red-control recorded in the commit body: leaving an uncleaned `coding/hard/go_` or `t_` root + child breaks `TestActivityCategoriesSchema` at `:180` / `:196`, whereas leaving an uncleaned `coding/hard/zzgo_` AND `zzt_` root + `zzt_/used` child keeps `TestActivityCategoriesSchema` green.
- **Fix scope.** `csi-spl-api/src/go/spool-hub-api/internal/store/categories_test.go:64` (`"coding/hard/go_"` -> `"coding/hard/zzgo_"`) and `:113` (`"t_"` -> `"zzt_"`), `csi-spl-api/src/go/spool-hub-api/internal/hub/categories_test.go:44` (`"coding/hard/go_"` -> `"coding/hard/zzgo_"`), `csi-spl-api/src/go/spool-hub-api/internal/store/reporting_schema_test.go:196` (add `AND category_path !~ '(^|/)zz'` to the top-level `parent_path IS NULL` count), plus a guard test in `store/categories_test.go` asserting every test-created path matches `(^|/)zz` and the `:196` top-level query filters `(^|/)zz`. Separate from `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget` (DB-bloat budget tests, left carried). `Docs: none` (test isolation fix only).

### 3.3 b46-03: `spl-review-go.func.sh:683` uses `$` instead of `\Z`, crossing a newline to falsely hold column-0 prohibitions (b45-01 R7 a-374 N1)

- **What happens.** b45-01 (`958049e92`, landed 03:01Z today) added `cond = re.compile(r"(?i)\b(?:if|when|unless|once|while|after|until)\b[^.;:,!?\n]*$")` at `csi-spl-orc/src/bash/run/spl-review-go.func.sh:683`, documented at `:631-632` as matching a condition word earlier in the same clause *"since the last . ; : , ! ? or line start"*. In Python `re` without `re.MULTILINE`, `$` matches both end-of-string and immediately before a trailing `\n` at `endpos` (`m.start()`). When a column-0 prohibition (`No terraform apply.`) immediately follows an unpunctuated line holding a condition word (`3. Check if green\nNo terraform apply.` or `3. Run when ready\nno terraform apply.`), `cond.search(txt, 0, m.start())` crosses the newline and falsely HOLDs (`rc=1`, fail-closed), contradicting `:632`.
- **Seen.** b45-01 R7 `a-374@sat` (agy) note N1 on `c8a473a38683` (`spool tail --task dispatch-bug-r45`, 02:54:49Z; recorded in round 45's close record `5c0ba2f40`). Measured on sat's readable brief corpus (6954 files, 615 with `apply`, 06:15Z): 0 briefs currently differ (`diff_old_vs_new=0`, harm today latent, same posture as b45-01).
- **Red control** (`rc03-b46.sh`, section 4.3, updated for panel N3 to check the `owner-go keyword 'apply'` reason on every `rc=1`): on `5c0ba2f40`, two fixtures (`3. Check if green\nNo terraform apply.` and `3. Run when ready\nno terraform apply.`) -> rc 1 each with `owner-go keyword 'apply'` (want 0), while b45-01's two same-line conditionals (`If no errors apply...`, `When the plan shows no drift apply...`) -> rc 1 with `owner-go keyword 'apply'` (want 1); `rc03 exit 1`. **Control**: `fix-shape` (`$` -> `\Z`) -> rc 0, 0, 1, 1, `rc03 exit 0`. On `958049e92^` (b45-01's parent) -> rc 0, 0, 0, 0, `rc03 exit 1` (same-line conditionals unheld), proving b45-01's gain is kept. `spl-review-go.tst.sh` -> `0 failure(s)` on both tree and `fix-shape` (06:29Z).
- **Fix scope.** `csi-spl-orc/src/bash/run/spl-review-go.func.sh:683` (`$` -> `\Z`) and `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (new case 31 after `:1217`: column-0 `No terraform apply.` / `no terraform apply.` after an unpunctuated conditional line -> GO rc 0; controls same-line `If no errors apply...` -> HOLD rc 4 and case 29/30 unchanged). `Docs: none` (spec 157 and `:632` already document "line start").

### 3.4 CI reds in the 100 runs, read

| run range | job | first red line | why not a row |
|---|---|---|---|
| `45515419629`..`45533786073` (00:06Z..02:33Z) | wui e2e 1/8, 2/8, 3/8 | `scrolled to the end, the oldest row is drawn and on screen`; `a person's card paints their avatar` | **Served**: fixed by SPL-6446 (`c69d8b287`, 02:45Z; 10 consecutive green wf 10 runs since). |
| `45503197584`..`45512638927` (22:40Z..23:45Z) | wui e2e 1/8..8/8 | `ResizeObserver loop completed with undelivered notifications.` | **Served**: fixed by `589a62983` (SPL-6427, p20-05 follow-up). |
| `45515419629` (00:06Z, `f7161909`) | orc hermetic 2/4 | `FAIL: 7: fixture claude-md-today.fixture.md differs from the assets` | **Served**: fixed on master right after `f7161909`. |
| `45459967138`..`45484083817` (18:28Z..20:45Z) | wui e2e 1/8, 4/8, 6/8; orc hermetic 3/4, 4/4 | `browser Back`, `settings@360`, `P4 390`, `FAIL: 6. worktree` | **Served**: SPL-6379 and SPL-6411 fixes landed yesterday evening. |

The hermetic 2/4 timeout of rounds 42 to 44: 0 timeout sightings in these 100 runs (p90 57 %).

### 3.5 The prd WARNING lines, read

| candidate | read | why not a row |
|---|---|---|
| **`fleet token surge: #fleet-alerts does not exist in the operator workspace, alert not posted`**, 1 since W (`2026-11-25T01:33:04Z`, `c-210@<box2>`), **5 in 7 days** (Nov 18, Nov 19 x2, Nov 24, Nov 25) | `csi-spl-api/src/go/spool-hub-api/internal/hub/fleet_tokens.go:52` hardcodes `FleetAlertsChannel = "fleet-alerts"` (spec 140 §4.4, owner poll `aa31a0fe` Q3 Choice B). `t1` in prd has 19 channels including `#alerts` (SPL-4700, `all.env.yaml:934,942` `fleet_notices.channel: alerts`), and **no `#fleet-alerts`**. So every sustained token surge alert in prd is silently dropped. | **Handed to holder (section 6)**: creating `#fleet-alerts` in prd `t1` is a prd mutation, and switching `FleetAlertsChannel` to `#alerts` changes spec 140's owner-polled channel name. Now owned by live lane `c-325@<box2>` (`c-325-c002-fleet-surge-alert-to-alerts`, seen in lane-map 06:43Z). |
| `PUT /v1/me/hours/minutes` 400, 0 in 12 h since W, **8 in 72 h** (Nov 23 x4, Nov 24 x4, all `responseSize: 385`, Android Chrome 157) | `handlePutMyHoursMinutes` (`hours_me.go:562-566`) logs nothing on 400 `bad_minutes` | **Row b46-01** (section 3.1). |
| `upload token refused`, 361 since W | `reason=unknown_token` | **Not a row**, round 43 section 3.3: the holder's box question. Carried. |
| `DELETE` x149 + `GET` x74 `/v1/operator/calendar/events/<uuid>` 404 (20:21Z..20:29Z) | `curl/8.14.1` operator queries on `<ws>` (`ordered_by=HUM-10`/`HUM-5`) for already-removed event ids | **Not a row**: operator cleanup / verification sweep, 404 as designed. |
| `GET /v1/operator/workspaces` 403, 18 | non-operator reads | **Not a row**: refused as designed. |
| `ws hello refused` 9 (`unpinned_box`, `<dev-box>`); `github: request refused` 5 (404 `contents`); `short/268185` 9; scanner probes (`.env`, `sftp-config.json`, `actuator/*`, `laravel.log`, ...) | same shapes as rounds 43 to 45 | **Not a row.** |

### 3.6 Round 45's first inputs and the holder's candidate list, re-read

| candidate | result on `5c0ba2f40` | verdict |
|---|---|---|
| the hours-minutes whole-batch 400 (round 45 section 3.3 first step) | 8x in 72 h in prd, 0 hub log lines on `hours_me.go:564` | **Row b46-01** (section 3.1). |
| the store tests' fresh-DB need (`c002-next-round-candidates.md:118`) | `store/categories_test.go:64,113` (`go_`, `t_`), `hub/categories_test.go:44` (`go_`), and `reporting_schema_test.go:196` (no `zz` filter on `parent_path IS NULL`) break `TestActivityCategoriesSchema` on reused/concurrent DBs | **Row b46-02** (section 3.2). Buffer-budget tests (`TestHiddenUnreadBufferBudget`, `TestMarkedUnreadBufferBudget`) remain DB-bloat test-hygiene inputs, carried. |
| r96-01 N1 (`spl-unanswered-sweep.func.sh:196` names `send_to_peers_on`) | `git grep -n 'send_to_peers_on' 5c0ba2f40 -- csi-spl-orc/src/bash/run/` -> **0 hits** | **Served** by r97-01 (`2924c633f`, SPL-6449). Dropped from future input lists. |
| the topic loop cap race (`c002-next-round-candidates.md:73`) | `CountTopicLoopFire` (`topic_loop_postgres.go:181-194`) is already one atomic `UPDATE ... WHERE ... fires_in_hour < $4 RETURNING ...`, proven by `TestTopicLoopCapConcurrent` (`topic_loop_test.go:298-334`, 2x15 concurrent fires -> 12) | **Already solved** on `5c0ba2f40`. Dropped from future input lists. |
| the non-instruction `apply` rule [4] holds (noun, another lane's status) | `/var/csi/csi-spl/review-go/cron.out` on sat still shows repeated `owner-go keyword 'apply'` rc 4 holds (incl. b45-01 `b5def2e3`, where `apply` was the bug's own subject); `b46-03` fixes the `$`->`\Z` newline regression first | **Carried** to round 47 (design of non-instruction noun/subject filtering is wider than a narrow bug row; b46-03 owns `spl-review-go.func.sh` in Batch 1). |
| `zip_dirs` duplicate `proj.zip` + `proj.<UTC>.zip` (`c002-next-round-candidates.md:139`, SPL-6361 area) | lives in the release-transfer repo (the release-transfer sync script, line 2240), not this repo; SPL-6361 is `wip` (source 3) | **Out of repo / owned** (brief line 29). |
| `spl-dispatch-subscribe.func.sh:347` false SILENT gap (`c002-next-round-candidates.md:128`) | `hum\|` SQL (`:161-165`) still counts all channels (`NOT IN ('issues','tasks','probe')`) while `:357-360` checks only the dispatchers' desk spools | **Carried** to round 47 (4th candidate; round capped at 3 rows, 5.1; needs a clean reproduction fixture of a seat-only channel window). |
| `spl-customer-box-role-check.func.sh` (`c002-next-round-candidates.md:95`, SPL-6122 N1-N4) | N1 (`!vault`) and N2 (quoted `delegate_to`/`connection`) served by b36-02 (`cd1c499ee`); N3 (`ignore_errors`/`failed_when` in role 04) still unguarded at `:115-122` | **Carried** to round 47 (4th+ candidate). |
| older candidate-list entries (`spl-spawn-after.func.sh:67`, `spl-spawn-review-notify.func.sh`, `spl-spawn-place.func.sh:1038`) | served by `6f2a343bb` (b30-03), `8b7828a6b` (b31-01), `1fadfb77b` (b32-02), `1b92d41cf` (SPL-6261) | **Already served.** |
| the `unknown_token` box; the hub dir mode; the hermetic 2/4 timeout; the composed testids; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`, g-162 N2 (`i18n-lang-review-exempt.json:2` still says `Lang-review: a-NNN`, 1-line doc note) | re-checked: unchanged / carried with holder or low-impact doc notes | **Carried.** |

---

## 4. Red controls, as run

### 4.1 `rc01-b46.sh` (b46-01), sha256 first 12 hex `a30567d4343c`, 3735 B

Run from any checkout: `bash rc01-b46.sh 5c0ba2f40` (exit 1), then `bash rc01-b46.sh 5c0ba2f40 fix-shape` (exit 0). About 1 s with a warm Go cache.

```bash
#!/usr/bin/env bash
# rc01-b46.sh <sha> [fix-shape]: b46-01 red control. On <sha>'s tree,
# PUT /v1/me/hours/minutes (internal/hub/hours_me.go handlePutMyHoursMinutes)
# returns HTTP 400 bad_minutes with zero warn log line when parseHoursMinutes
# rejects a batch (e.g. a phone clock ahead of hoursMinuteSkew), while a valid
# 200 PUT emits no warn line. The tree is extracted with git archive into a
# mktemp dir; a test is added there only. fix-shape logs one structured warn
# line carrying tenant/member/reason/count before writeErr (the shape, not
# the fix).
set -uo pipefail
sha="${1:?usage: rc01-b46.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-api csi-spl-rdb | tar -x -C "$tmp"
d="$tmp/csi-spl-api/src/go/spool-hub-api"
a=$(grep -c 'writeErr(w, http.StatusBadRequest, "bad_minutes", bad)' "$d/internal/hub/hours_me.go")
echo "rc01 site: writeErr bad_minutes count=$a"
[ "$a" = 1 ] || { echo "rc01 site moved: re-read hours_me.go"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$d/internal/hub/hours_me.go" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = '\t\twriteErr(w, http.StatusBadRequest, "bad_minutes", bad)'
new = '\t\ts.o.Log.Warn().Str("tenant", c.tenant.ID).Str("member", c.hum).Str("reason", bad).Int("count", len(body.Minutes)).Msg("hours: minutes refused")\n' + old
assert s.count(old) == 1, "fix-shape target not unique"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "rc01 fix-shape: handlePutMyHoursMinutes logs a warn line before writeErr bad_minutes"
fi
cat >"$d/internal/hub/rc01_b46_test.go" <<'GO'
package hub_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

func TestRC01HoursMinutes400LogsReason(t *testing.T) {
	var buf bytes.Buffer
	e := rbacEnv(t, func(o *hub.Options) {
		o.Now = func() time.Time { return hoursNow }
		o.Log = zerolog.New(&buf)
	})
	tid, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	// Control: a valid 200 PUT emits 0 warn lines.
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(hoursNow.Add(-5*time.Minute), 1, "t:x")); code != http.StatusOK {
		t.Fatalf("valid minutes: status=%d, want 200", code)
	}
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var obj map[string]any
		if json.Unmarshal([]byte(line), &obj) == nil && obj["level"] == "warn" {
			t.Fatalf("rc01 control: valid 200 logged warn: %s", line)
		}
	}
	buf.Reset()
	// Defect: a future-skewed 400 batch must log a warn line carrying the reason.
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(hoursNow.Add(5*time.Minute), 1, "t:x")); code != http.StatusBadRequest {
		t.Fatalf("future skew: status=%d, want 400", code)
	}
	found := false
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var obj map[string]any
		if json.Unmarshal([]byte(line), &obj) == nil && obj["level"] == "warn" {
			if reason, _ := obj["reason"].(string); strings.Contains(reason, "future") {
				found = true
			}
		}
	}
	if !found {
		t.Fatalf("rc01: 400 bad_minutes logged no warn with future reason; output=%s", strings.TrimSpace(buf.String()))
	}
}
GO
cd "$d" && go test -count=1 -run '^TestRC01HoursMinutes400LogsReason$' ./internal/hub/ 2>&1 | tail -6
rc=${PIPESTATUS[0]}
echo "rc01 exit $rc"
exit "$rc"
```

Output on `5c0ba2f40` (sat, 06:24Z, go1.26.10):

| run | output |
|---|---|
| `bash rc01-b46.sh 5c0ba2f40` | `rc01 site: writeErr bad_minutes count=1` / `rc01_b46_test.go:56: rc01: 400 bad_minutes logged no warn with future reason; output={"level":"info","request_id":"...","method":"PUT","path":"/v1/me/hours/minutes","host":"...","status":400,"dur":0,"message":"http"}` / `FAIL` / `rc01 exit 1` |
| `bash rc01-b46.sh 5c0ba2f40 fix-shape` | `rc01 site: writeErr bad_minutes count=1` / `rc01 fix-shape: handlePutMyHoursMinutes logs a warn line before writeErr bad_minutes` / `ok github.com/csitea/csi-spl/spool-hub-api/internal/hub 0.046s` / `rc01 exit 0` |

### 4.2 `rc02-b46.sh` (b46-02), sha256 first 12 hex `dedae163967f`, 4051 B

Run from any checkout: `bash rc02-b46.sh 5c0ba2f40` (exit 1), then `bash rc02-b46.sh 5c0ba2f40 fix-shape` (exit 0). Under 1 s with a warm Go cache.

```bash
#!/usr/bin/env bash
# rc02-b46.sh <sha> [fix-shape]: b46-02 red control. On <sha>'s tree,
# TestActivityCategoriesSchema (internal/store/reporting_schema_test.go) skips
# (^|/)zz leaves at :180 and counts top-level areas (parent_path IS NULL) with
# NO zz filter at :196, while store/categories_test.go:64 and
# hub/categories_test.go:44 create coding/hard/go_<uid> and
# store/categories_test.go:113 (TestCategoryDeleteInUseRefused) creates a
# top-level t_<uid> root + child. Any leaked or concurrent row breaks
# TestActivityCategoriesSchema on a reused Postgres DB. The tree is extracted
# with git archive into a mktemp dir; fix-shape prefixes all three test paths
# with zz (zzgo_, zzt_) and adds AND category_path !~ '(^|/)zz' to :196.
set -uo pipefail
sha="${1:?usage: rc02-b46.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-api csi-spl-rdb | tar -x -C "$tmp"
d="$tmp/csi-spl-api/src/go/spool-hub-api"
r1=$(grep -c "category_path !~ '(^|/)zz'" "$d/internal/store/reporting_schema_test.go")
r2=$(grep -c "SELECT 1 FROM activity_categories WHERE parent_path IS NULL" "$d/internal/store/reporting_schema_test.go")
echo "rc02 schema sites: seed filter=$r1, top-level count=$r2"
[ "$r1" -ge 1 ] && [ "$r2" = 1 ] || { echo "rc02 schema sites moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$d/internal/store/categories_test.go" "$d/internal/hub/categories_test.go" "$d/internal/store/reporting_schema_test.go" <<'PY' || exit 2
import sys
st, hb, rs = sys.argv[1:4]
for p in (st, hb):
    s = open(p).read()
    assert s.count('"coding/hard/go_"') == 1, f"expected 1 coding/hard/go_ in {p}"
    s = s.replace('"coding/hard/go_"', '"coding/hard/zzgo_"', 1)
    if p == st:
        assert s.count('root := "t_"') == 1, "expected 1 root := t_ in store/categories_test.go"
        s = s.replace('root := "t_"', 'root := "zzt_"', 1)
    open(p, "w").write(s)
s = open(rs).read()
old = "`SELECT 1 FROM activity_categories WHERE parent_path IS NULL`"
new = "`SELECT 1 FROM activity_categories WHERE parent_path IS NULL AND category_path !~ '(^|/)zz'`"
assert s.count(old) == 1, "expected 1 top-level query in reporting_schema_test.go"
open(rs, "w").write(s.replace(old, new, 1))
PY
  echo "rc02 fix-shape: zzgo_/zzt_ prefixes in categories_test.go and (^|/)zz filter on reporting_schema_test.go:196"
fi
cat >"$d/internal/store/rc02_b46_test.go" <<'GO'
package store

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestRC02CategoriesTestIsolation(t *testing.T) {
	zzRe := regexp.MustCompile(`(^|/)zz`)
	leafRe := regexp.MustCompile(`leaf\s*:=\s*"([^"]+)"`)
	rootRe := regexp.MustCompile(`root\s*:=\s*"([^"]+)"`)
	for _, f := range []string{"categories_test.go", filepath.Join("..", "hub", "categories_test.go")} {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		m := leafRe.FindSubmatch(raw)
		if len(m) < 2 {
			t.Fatalf("%s: leaf literal not found", f)
		}
		if sample := string(m[1]) + "deadbeef"; !zzRe.MatchString(sample) {
			t.Errorf("rc02 %s: leaf %q does not match (^|/)zz", f, sample)
		}
		if f == "categories_test.go" {
			rm := rootRe.FindSubmatch(raw)
			if len(rm) < 2 {
				t.Fatalf("%s: root literal not found", f)
			}
			if sample := string(rm[1]) + "deadbeef"; !zzRe.MatchString(sample) {
				t.Errorf("rc02 %s: root %q does not match (^|/)zz", f, sample)
			}
		}
	}
	rs, err := os.ReadFile("reporting_schema_test.go")
	if err != nil {
		t.Fatalf("read reporting_schema_test.go: %v", err)
	}
	if !strings.Contains(string(rs), "WHERE parent_path IS NULL AND category_path !~ '(^|/)zz'") {
		t.Errorf("rc02 reporting_schema_test.go: top-level parent_path IS NULL count lacks (^|/)zz filter")
	}
}
GO
cd "$d" && go test -count=1 -run '^TestRC02CategoriesTestIsolation$' ./internal/store/ 2>&1 | tail -10
rc=${PIPESTATUS[0]}
echo "rc02 exit $rc"
exit "$rc"
```

Output on `5c0ba2f40` (sat, 06:43Z, go1.26.10):

| run | output |
|---|---|
| `bash rc02-b46.sh 5c0ba2f40` | `rc02 schema sites: seed filter=1, top-level count=1` / `rc02_b46_test.go:25: rc02 categories_test.go: leaf "coding/hard/go_deadbeef" does not match (^\|/)zz` / `rc02_b46_test.go:33: rc02 categories_test.go: root "t_deadbeef" does not match (^\|/)zz` / `rc02_b46_test.go:25: rc02 ../hub/categories_test.go: leaf "coding/hard/go_deadbeef" does not match (^\|/)zz` / `rc02_b46_test.go:42: rc02 reporting_schema_test.go: top-level parent_path IS NULL count lacks (^\|/)zz filter` / `FAIL` / `rc02 exit 1` |
| `bash rc02-b46.sh 5c0ba2f40 fix-shape` | `rc02 schema sites: seed filter=1, top-level count=1` / `rc02 fix-shape: zzgo_/zzt_ prefixes in categories_test.go and (^\|/)zz filter on reporting_schema_test.go:196` / `ok github.com/csitea/csi-spl/spool-hub-api/internal/store 0.036s` / `rc02 exit 0` |

### 4.3 `rc03-b46.sh` (b46-03), sha256 first 12 hex `f3d0f9ed92fd`, 2572 B

Run from any checkout: `bash rc03-b46.sh 5c0ba2f40` (exit 1), then `bash rc03-b46.sh 5c0ba2f40 fix-shape` (exit 0). Under 1 s.

```bash
#!/usr/bin/env bash
# rc03-b46.sh <sha> [fix-shape]: b46-03 red control. On <sha>'s tree,
# _spl_review_go_instr (spl-review-go.func.sh:683) compiles cond with trailing
# $, which in Python re without MULTILINE also matches right before a trailing
# \n at endpos (m.start()). A column-0 prohibition ("No terraform apply.") on
# the line after an unpunctuated line holding a condition word ("3. Check if
# green") crosses the newline and is falsely held (rc 1, want 0) with the
# owner-go keyword 'apply' message, while same-line conditionals ("If no errors
# apply...") must still hold (rc 1) with that same reason. fix-shape replaces
# $ with \Z in cond (the shape, not the fix).
set -uo pipefail
sha="${1:?usage: rc03-b46.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$repo" show "$sha:csi-spl-orc/src/bash/run/spl-review-go.func.sh" >"$tmp/rg.sh" || exit 2
if [ "${2:-}" = fix-shape ]; then
  python3 - "$tmp/rg.sh" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = 'cond = re.compile(r"(?i)\\b(?:if|when|unless|once|while|after|until)\\b[^.;:,!?\\n]*$")'
new = 'cond = re.compile(r"(?i)\\b(?:if|when|unless|once|while|after|until)\\b[^.;:,!?\\n]*\\Z")'
assert s.count(old) == 1, "fix-shape: cond line not found once"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "rc03 fix-shape: cond anchored with \\Z instead of \$"
fi
run() {
  local out rc
  out="$(SPOOL_ROOT="$tmp" SPL_STATE_DIR="$tmp" bash -c 'source "$1"; _spl_review_go_owner_go "$2" c-000' _ "$tmp/rg.sh" "$1" 2>&1)"
  rc=$?
  if [ "$rc" = 1 ] && ! grep -q "owner-go keyword 'apply'" <<<"$out"; then
    echo "unexpected-rc1:$out"
    return
  fi
  echo "$rc"
}
printf '%s\n' '# Lane brief' '## Do' '3. Check if green' 'No terraform apply.' >"$tmp/n1.md"
printf '%s\n' '# Lane brief' '## Do' '3. Run when ready' 'no terraform apply.' >"$tmp/n2.md"
printf '%s\n' '# Lane brief' '## Do' '3. If no errors apply the migration to prd.' >"$tmp/p1.md"
printf '%s\n' '# Lane brief' '## Steps' '4. When the plan shows no drift apply step 053.' >"$tmp/p2.md"
n1=$(run "$tmp/n1.md"); n2=$(run "$tmp/n2.md"); p1=$(run "$tmp/p1.md"); p2=$(run "$tmp/p2.md")
echo "rc03 'if green\\nNo terraform apply' -> rc $n1 (want 0); 'when ready\\nno terraform apply' -> rc $n2 (want 0); 'If no errors apply' -> rc $p1 (want 1, apply-hold); 'When ... no drift apply' -> rc $p2 (want 1, apply-hold)"
rc=0
[ "$n1" = 0 ] || rc=1; [ "$n2" = 0 ] || rc=1; [ "$p1" = 1 ] || rc=1; [ "$p2" = 1 ] || rc=1
echo "rc03 exit $rc"
exit "$rc"
```

Output on `5c0ba2f40` (sat, 06:43Z):

| run | output |
|---|---|
| `bash rc03-b46.sh 5c0ba2f40` | `rc03 'if green\nNo terraform apply' -> rc 1 (want 0); 'when ready\nno terraform apply' -> rc 1 (want 0); 'If no errors apply' -> rc 1 (want 1, apply-hold); 'When ... no drift apply' -> rc 1 (want 1, apply-hold)` / `rc03 exit 1` |
| `bash rc03-b46.sh 5c0ba2f40 fix-shape` | `rc03 fix-shape: cond anchored with \Z instead of $` / `rc03 'if green\nNo terraform apply' -> rc 0 (want 0); 'when ready\nno terraform apply' -> rc 0 (want 0); 'If no errors apply' -> rc 1 (want 1, apply-hold); 'When ... no drift apply' -> rc 1 (want 1, apply-hold)` / `rc03 exit 0` |
| `bash rc03-b46.sh 958049e92^` | `rc03 'if green\nNo terraform apply' -> rc 0 (want 0); 'when ready\nno terraform apply' -> rc 0 (want 0); 'If no errors apply' -> rc 0 (want 1, apply-hold); 'When ... no drift apply' -> rc 0 (want 1, apply-hold)` / `rc03 exit 1` (b45-01's parent: same-line conditionals unheld) |

---

## 5. Rows

| # | id | practice | sites (file:line on `5c0ba2f40`) | evidence | red control (fails on `5c0ba2f40`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b46-01-api-hours-minutes-400-log` | log the refusal reason on live 400s | `csi-spl-api/src/go/spool-hub-api/internal/hub/hours_me.go:562-566` (`handlePutMyHoursMinutes` `bad_minutes` branch); `csi-spl-api/src/go/spool-hub-api/internal/hub/hours_me_test.go` (new test after `:176`) | 8 prd 400s in 72 h (`responseSize: 385`, Android Chrome 157, 0 hub log lines); round 45 sections 3.3 and 7; section 4.1 | `bash rc01-b46.sh 5c0ba2f40` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` | `go test -count=1 -run '^TestMyHours\|^TestHours' ./internal/hub/`; `go test -count=1 ./internal/cleancode/...`; `bash rc01-b46.sh <fix sha>` -> exit 0 (without `fix-shape`); `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.1: log 1 structured `Warn` line (`tenant`, `member`, `reason`, `count`, plus `max_skew_s` when ahead of `now`) before `writeErr` on `bad_minutes`; 0 duplicate zerolog keys; keep HTTP 400 contract unchanged; keep `handlePutMyHoursMinutes` <= 75 lines; `Docs: none` | sat (`do_spl_box_pick` 06:13Z: sat 47% < 70% low mark, `<box2>` 52%, both claude weekly 71%) | claude | agy (`BOX_PICK_KIND=agy` 06:14Z: sat 47% `agy weekly unknown`, placed anyway), else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |
| 02 | `b46-02-api-categories-test-zz-prefix` | tests isolate their Postgres rows under the schema filter | `csi-spl-api/src/go/spool-hub-api/internal/store/categories_test.go:64` (`leaf := "coding/hard/go_" + ...`) and `:113-117` (`root := "t_" + ...`); `csi-spl-api/src/go/spool-hub-api/internal/hub/categories_test.go:44` (`leaf := "coding/hard/go_" + ...`); `csi-spl-api/src/go/spool-hub-api/internal/store/reporting_schema_test.go:196` (`parent_path IS NULL` count) | `c002-next-round-candidates.md:118` (g-786 `84bb230e` N3); round 45 section 7; panel c-440 W1; section 4.2 | `bash rc02-b46.sh 5c0ba2f40` -> `rc02 exit 1`; control `fix-shape` -> `rc02 exit 0` | `go test -count=1 -run '^TestCategoriesStoreCRUD\|^TestCategoryDeleteInUseRefused\|^TestSetAskCategory\|^TestTokensByCategory\|^TestCheckAskCategory\|^TestActivityCategoriesSchema' ./internal/store/`; `go test -count=1 -run '^TestCategory' ./internal/hub/`; **`bash rc02-b46.sh <fix sha>`** -> exit 0 (without `fix-shape`); **mandatory Postgres gate (N2):** `PRE_PUSH_TIER=full ./run -a do_check_pre_push` AND live Postgres leak control in commit body (uncleaned `coding/hard/go_` or `t_` root turns `TestActivityCategoriesSchema` red; uncleaned `coding/hard/zzgo_` + `zzt_` root + `zzt_/used` child keep it green) | section 3.2: `"coding/hard/go_"` -> `"coding/hard/zzgo_"` in store+hub `categories_test.go`, `"t_"` -> `"zzt_"` in `store/categories_test.go:113`, add `AND category_path !~ '(^\|/)zz'` at `reporting_schema_test.go:196`, + guard test; touch no production code; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` 06:13Z: sat 47%, `<box2>` 52%) | claude | agy if quota, else claude waiver seat (`1a7c70da`) | `tests` | 1 |
| 03 | `b46-03-orc-review-go-cond-line-boundary` | regex matches its documented line-start boundary | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:683` (`cond` trailing `$` -> `\Z`); `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (new case 31 after `:1217`) | b45-01 R7 a-374@sat N1 on `c8a473a38683` (`dispatch-bug-r45` 02:54:49Z); round 45 close record `5c0ba2f40`; section 4.3 | `bash rc03-b46.sh 5c0ba2f40` -> `rc03 exit 1`; control `fix-shape` -> `rc03 exit 0` | **`bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`** (every case, 1 to 31; 29 and 30 unchanged); `bash rc03-b46.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x` on both files; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.3: `$` -> `\Z` at `:683` + case 31 in `spl-review-go.tst.sh`; touch no other keyword or section rule; `Docs: none` (spec 157 and `:632` already say "line start") | sat or `<box2>` (`do_spl_box_pick` 06:13Z: sat 47%, `<box2>` 52%) | claude | agy if quota, else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |

- **R1 (disjoint files):** all 3 rows are Batch 1 and share 0 files:
  - b46-01: `internal/hub/hours_me.go`, `internal/hub/hours_me_test.go`
  - b46-02: `internal/store/categories_test.go`, `internal/hub/categories_test.go`, `internal/store/reporting_schema_test.go`
  - b46-03: `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`
- **R3** (re-run 2026-11-25T06:43:58Z including `reporting_schema_test.go`): `lane-map.sh --check csi-spl-api/src/go/spool-hub-api/internal/hub/hours_me.go,csi-spl-api/src/go/spool-hub-api/internal/hub/hours_me_test.go,csi-spl-api/src/go/spool-hub-api/internal/store/categories_test.go,csi-spl-api/src/go/spool-hub-api/internal/hub/categories_test.go,csi-spl-api/src/go/spool-hub-api/internal/store/reporting_schema_test.go,csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-doc/doc/md/bug-round-46-plan.md --agent a-438` -> **exit 4**: no live lane lists these 8 paths, but 18 live lanes on `<box2>` record no files (`unknown:` c-029, c-041, c-086, c-114, c-146, c-165, c-187, c-190, c-210, c-217, c-249, c-325, c-728, c-774, c-927, c-936, c-957, c-965): **not free until the holder re-runs `--check` at placement** (N5). Live lanes on sat (a-353 spec 195 review, c-429 r98 panel, a-427 r98 planner, c-298 Taxes tab, c-074 spec 187 planner, c-296 blog post) touch none of these paths by scope. The queue, `./run -a do_spl_spawn_queue` (06:16:44Z): 1 queued ask (`5b1b7d82`, `c001-s186-m9-n2-qto-sync`), disjoint by slug.
- **R7:** claude-authored code/test rows: agy R7 seat when agy has quota (`BOX_PICK_KIND=agy` 06:14Z: sat `47%`, `agy weekly unknown`, placed anyway; note `<box2>` agy was out of quota until 12-01 per b45-01 spool), else the claude waiver seat (`1a7c70da`). No grok (c-001 `dc84300a`). No mistral (no review seat since 2026-11-25, and no coding kind).
- **Rhythm (1.4):** rows queue once the panel signs and `do_spl_review_line_check` exits 0; rows run at night.
- **Pushes:** aim 1 per row (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug`.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| **`#fleet-alerts` missing in prd `t1` — 5 token-surge alerts dropped in 7 days** (`fleet_tokens.go:52` vs `t1` channels / SPL-4700 `#alerts`) | **c-325@`<box2>`** (`c-325-c002-fleet-surge-alert-to-alerts`, placed after v0.1 handoff) | live lane (seen in lane-map 06:43Z); owned (R3). |
| SPL-6460 (done-claim check vs release-transfer shas: `all.env.yaml`, `spl-done-claim-check.func.sh`) | queued lane (`c-001 86601fa0`, holder msg `7493414d`) | owned; linked to b46 topic for context only, not a b46 row. |
| wf 40 (`40 cd: tenant host reconcile` `reconcile prd`, 38 failures since W) | standing, c-001 carry item 9 | owned; stay off. |
| Release-transfer repo open bug issues (SPL-6435, 6442, 6443, 6361 `zip_dirs`, 6362, 6366) | live lanes on `<box2>` (c-114, c-158, c-165, reviewers c-217, c-190, c-249) | live; different repository, not `csi-spl`. |
| The `unknown_token` box (361 prd WARNINGs since W) | the holder, as a box question | carried. |
| Non-instruction `apply` rule [4] holds (nouns / subject quotes); `spl-dispatch-subscribe.func.sh:347` false SILENT gap; `spl-customer-box-role-check.func.sh:115-122` N3 (`ignore_errors`/`failed_when` in role 04) | round 47 inputs | carried (section 7). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 3 (all Batch 1, R1 disjoint) |
| inputs re-measured | 10 sources; 17 prd ERROR entries since W (12 h read); 813 prd WARNING entries since W (401s left out, cap not reached) + 72 h `hours/minutes` >=400 read (8 HTTP 400s + 4 HTTP 401s) + 7 d `fleet token surge` read (5 hits); 9 alert policies (0 incidents); 10 open t1 bug issues + SPL-6460; 100 wf 10 runs (27 failures, all served, 10/10 latest green); 58 failed runs since W (38 wf 40, 20 wf 10); 67 commits and 14 `review:` lines since W + `dispatch-bug-r45` tail; 0 HUM posts since W; round 45's first inputs (11 + 7 N2s); holder's candidate list (140 lines on sat); `rc01-b46.sh`, `rc02-b46.sh`, `rc03-b46.sh` n=1 each way on `5c0ba2f40` (and `958049e92^` for `rc03`); 6954 sat briefs (615 with `apply`) for `b46-03`; baseline `TestMyHoursMinutes*`, `TestCategories*`, `TestCategory*` and `spl-review-go.tst.sh` (tree and fix-shape, 0 failures each) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b46-'` -> 0; `git ls-remote origin 'refs/heads/review/b46-*' 'refs/heads/wip/*b46*' 'refs/heads/*-b46-*' 'refs/heads/*bug-round-46*'` -> nothing (rc 0); briefs on sat: only `c002-bug-round-46-planner.md` and `c002-bug-round-46-claude-panel-seat.md` (06:04:46Z) |
| R7 seat | agy on sat if quota, else claude waiver seat (`1a7c70da`) |
| first inputs for round 47 | the hours-minutes whole-batch 400 follow-up (once b46-01's prd warn log confirms the exact skew/reason, decide clamp vs partial-accept in spec 107 / WUI); the non-instruction `apply` rule [4] holds (nouns / subject quotes); `spl-dispatch-subscribe.func.sh:347` false SILENT gap on seat-only channel windows; `spl-customer-box-role-check.func.sh:115-122` SPL-6122 N3 (`ignore_errors`/`failed_when` in role 04); `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget` on bloated reused Postgres DBs; the `unknown_token` box; the hub dir mode; the hermetic 2/4 timeout; the composed testids; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`, g-162 N2 (`i18n-lang-review-exempt.json:2`) as carried |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** a-438@sat (agy, `specs_and_docs`).
- **Panel:** c-440@sat (claude, cross-vendor; placed by the holder, msg `c4e6d9ad`).
- **Row reviewer (R7):** section 5.
- **Review history:**
  - 2026-11-25 06:29Z: v0.1 `58d224dad`, pushed to `review/c002-bug-round-46-planner` (3 rows: b46-01, b46-02, b46-03). Sent to c-440@sat and c-002@sat on task `dispatch-bug-r46`.
  - 2026-11-25 06:41Z: panel c-440@sat (claude) **FAIL** on v0.1 `58d224dad` (msg `4c05cdc4` to this seat, `8c74846f` to holder; seat file `csi-spl-doc/doc/md/bug-round-46/seat-claude.md` on `review/c002-bug-round-46-claude-seat` `33f499833`). b46-01 and b46-03 passed every check (all cites match on `5c0ba2f40`, 0 drift to `d5f1a228d`, all three rc hashes match, each rc exits 1 on base and 0 with `fix-shape`, hygiene clean). One blocking defect **W1** on b46-02: `TestCategoryDeleteInUseRefused` (`store/categories_test.go:113-117`) also creates non-`zz` paths (`t_<uid>` top-level root + `t_<uid>/used`), and `reporting_schema_test.go:196` counts top-level `parent_path IS NULL` == 5 with no `zz` filter, so `rc02` passed with half the defect still open. Notes **N1** (8 PUT 400s in 72 h, not 7: `2026-11-23T08:21:10Z` also in window), **N2** (make the `PRE_PUSH_TIER=full` Postgres leak check a mandatory gate of b46-02), **N3** (grep `owner-go keyword 'apply'` in `rc03` instead of discarding output), **N4** (b46-02 kind = `tests`), **N5** (R3 lane-map exit 4 re-checked by holder at placement).
  - 2026-11-25 06:4xZ: v0.2 folds W1 (holder call, msg `04c34be9`: widened b46-02 to include `store/categories_test.go:113-117`, `reporting_schema_test.go:196`, widened `rc02-b46.sh` `dedae163967f`, and verified 0 other `CreateCategory`/`INSERT INTO activity_categories` test sites across `csi-spl-api`) and N1 to N5 (8 PUT 400s, mandatory Postgres gate, reason-checked `rc03-b46.sh` `f3d0f9ed92fd`, kind `tests`, refreshed R3 `lane-map.sh --check`). Pushed to `review/c002-bug-round-46-planner` for c-440@sat re-review.
