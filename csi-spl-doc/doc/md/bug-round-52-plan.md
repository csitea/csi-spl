# Bug-fix round 52 - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6606 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `dde6a5a5-a103-4dfa-94bb-06f5108cd0fc` ("Bug round 52", opened by c-002@sat 14:58Z 2026-11-26, post `b2c5b7fb`). Bug round 51 ([bug-round-51-plan.md](bug-round-51-plan.md), plan v1.1 `ae8fd2278`, editor a-048@sat) served all three rows b51-01 (`49f7f487a`, SPL-6598), b51-02 (`ba36f4d24`, SPL-6599), and b51-03 (`a5bb05350`, SPL-6600) and recorded close (`2485f3956`, written by a-048@sat; no b51 record is written here).  
Round focus: the owner-ordered SPL-5254 phone Back land-guard fix, the c-001-ruled `review-go` relay C4 test-column gate (`ee10c09a`), the `spawn-remote.sh` `handle()` ack-race fix (`e1db57c6` / `42ac9aad`), plus full audit of all 10 sources (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes & automation logs since W, owner posts, round 51's first inputs, and the holder's candidate list on sat).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows (aim at 2, cap 3). Three small, disjoint Batch 1 candidates met the bar (section 3) — 1 owner order plus 2 explicit c-001 live-incident rulings — while bug share is UNDER (live 19% vs 30-40% night band, 24 h 12% vs 20-30% band, `23:00Z`, `do_spl_spawn_share`).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-51-plan.md](bug-round-51-plan.md).

**Status: v0.1 draft for cross-vendor panel review (`c-129@sat`, claude).**

Editor: **a-264@sat** (agy, `specs_and_docs`).  
Panel: **c-129@sat** (claude, cross-vendor; placed on `dispatch-bug-r52`, msg `bf1826bf`, live in `do_spl_lane_map` at `22:59Z`; mistral sits on no review since 2026-11-25).

**One sha:** every site, line number and red control below is on **`ecc05e480`** (`origin/master`, `2026-11-27T00:52:26+02:00` / `2026-11-26T22:52:26Z`, `test(api, SPL-6623): two hub queue tests read strict FIFO at priority 3 (spec 150 B15a)`). The sources of section 2 were read on sat, `22:59Z..23:13Z` on 2026-11-26. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b51-plan')` read once at `22:59:32Z` -> `Window: W=2026-11-26T17:48:03+02:00` (commit `2485f3956`, round 51's close record; `15:48:03Z`). Note: round 51's plan v1.1 was `ae8fd2278` (`13:00:10Z`, the queue-time W); slug `b52` is proven free (`0` matching commits) under BOTH `2485f3956` and `ae8fd2278`. Twenty-seven commits landed between `2485f3956` and `ecc05e480` (and 24 between `ae8fd2278` and `2485f3956`, including `b51-01`..`b51-03`).

---

## 1. How to read this

- `<box2>` is the fleet's box that is not sat and `<dev-box>` one unpinned workstation box, as in rounds 21 to 51: the public repo names none of them.
- **Paths** are repo-relative. Line numbers are as of `ecc05e480`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red controls are printed verbatim in section 4. Each is self-contained (zero box paths, runnable on any machine including `<box2>`), copies files from the named sha with `git archive` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout or live spool. Each site guard checks function names only, so `bash rc0N-b52.sh <fix sha>` (without `fix-shape`) exits 0 on a valid fix.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs).
- This seat runs on sat, so `/var/spool-hub/dispatch/c002-next-round-candidates.md`, `/var/spool-hub/dispatch/automation.log`, author/reviewer briefs under `/var/spool-hub/dispatch/briefs/`, and `c-001`/`c-002` archives/outboxes were read directly; sat-only evidence is quoted inline below so any reviewer can audit it directly.

---

## 2. Where rows could come from (measured since W `2485f3956`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=10h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (`23:00Z`) | 56 entries in 10 h (**29 since W** `15:48:03Z`: 22 Cloud SQL `spool_hub_rt` ad-hoc SQL errors — `operator does not exist`, `column "id"/"key"/"epic"/"discussion_id"/"c.id" does not exist`, `relation "topics"/"issue_comments" does not exist`, `ORDER BY position 2`, `invalid regular expression`; 7 Cloud Run HTTP 503 `malformed HTTP response or connection to the instance had an error`) | **0 rows**: section 3.4 (ad-hoc SQL + transient Cloud Run instance recycles during deploys; 0 alert incidents). |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=10h ./run -a do_gcp_list_alert_incidents` (`23:00:17Z`) | 9 policies, 0 incidents in `13:00:17Z..23:00:17Z` | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,120), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (`23:00:32Z`) | 4 issues: SPL-6633 (`wip`, prio 2, `c-339@<box2>` nightly reflection brief budget), SPL-6605 (`wip`, prio 2, `c-119@sat` sorted snackbar), **SPL-5254** (`onhold`, prio 2, phone Back popstate land guard), SPL-4994 (`onhold`, prio 1, hidden workspace terraform) — plus SPL-6606 (this round, prio 2) | **Row b52-01** (SPL-5254, owner order HUM-10 `452c25df` poll `8c3f32b4` A; section 3.1). SPL-6633 and SPL-6605 have live owners (R3). |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (`22:59:30Z..23:04:48Z`, background) | 100 runs, `2026-11-26T00:12:49Z..2026-11-26T22:52:47Z`: 78 success, 17 cancelled, 4 failure, 1 running; every job's p90 under 75% of its timeout (highest: hermetic 3/4, 61%). **3 failed runs since W (`15:48:03Z`)**: `45878486725` (`18:45:46Z` on `5ef798c0`, `wui: browser e2e 3/8` single sighting `FAIL S3 1440px dark: shaded row 2 has notes to open`, green since); `45882558631` (`19:17:42Z` on `4609bb49`) & `45886801673` (`19:51:58Z` on `075c1bab`, `hub: gofmt, go vet, go test, smoke, GCS gate` `internal/action 90.4% < floor 91.6 - 1.0`, **already served** by `81fea84a1`). Last green across all failed jobs: `45905322386` (`652d956e`, `22:31:24Z`) | **0 rows**: section 3.4. Trunk is green. |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 40 --json databaseId,workflowName,headSha,createdAt,conclusion` (`23:00:30Z`), `createdAt >= 2026-11-26T15:48:03Z`; `do_check_deploy_lag` (`23:00:54Z..23:01:00Z`) | **2 failed non-wf10 runs since W**: `45882558835` (`19:17:42Z`, wf 20 on `4609bb49`) & `45886801975` (`19:51:58Z`, wf 20 on `075c1bab`, same `internal/action` coverage floor failure — **served** by `81fea84a1`). `do_check_deploy_lag`: dev and prd wui both `current` (`8b816847`, `n=0`); dev and prd hub `pending` (`served=e92fc8d2`, `n=4`, oldest `3a36e494`, catch-up roll due via wf 21) | **0 rows.** |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=10h LINES=5000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (`23:00Z`; cap not reached) | 1636 entries in 10 h (**1349 since W** `15:48:03Z`): 560 `unpinned_box`, 551 `unknown_token`, 122 `context canceled` (deploy/client cancels), 20+ scanner 404s (`/wp-login.php`, `/robots.txt`, `/v1/.env`, `edit.php`, etc.), 10 `/v1/release-notes/<sha>` 404s, 7 HTTP 403 `/v1/operator/workspaces`, 7 blank-reason warnings, 6 HTTP 404 `/v1/dashboard`, 5 HTTP 404 `/v1/view/netvisor/forecast`, 2 HTTP 400 `/v1/view/search`, 2 `gcal events.list` errors, **0** `hours/minutes` 400s since W | **0 rows**: section 3.4. |
| **7. R7 notes & automation logs since W** | `git log 2485f3956..ecc05e480 --format=%B`, `c-001`/`c-002` spool archives (`14:00Z..23:00Z`), `a-104` `db300104`, `a-099` `02ccf2c7`, `a-113` `c2a02a11`, `c-123` `8e965469`, `c-001@<box2>` `42ac9aad`, and `/var/spool-hub/dispatch/automation.log` tail | 27 commits (`2485f3956..ecc05e480`), all landed R7 PASSes clean or already folded (`SPL-6613` W1 folded in `e92fc8d22`). `a-104` N1 (`db300104`, b51-03 R7): `## At brief time` `DRY_RUN=0` false hold on `spl-review-go.func.sh`. `automation.log` tail shows 4 more rc 4 owner-go false holds (`20:27Z`, `21:30Z`, `21:57Z`, `22:12Z`) on `apply`/`Apply`/`DRY_RUN=0`. Pre-W (`14:23Z..15:29Z`) live incidents ruled for b52 by c-001: **`ee10c09a`** (review-go relay C4 gap: GO `d8bfb277` on `a-099` + GO `245ec817` on `a-113`), **`e1db57c6`** (`MessageCard.vue` select box `8e965469` + `spawn-remote.sh` `handle()` race `42ac9aad`) | **Rows b52-02 and b52-03** (sections 3.2 and 3.3). `a-104` N1 & owner-go false holds carried to round 53 (same file as b52-02). |
| **8. Owner and member posts** | `ENV=prd SQL="select tenant_id, from_id, count(*), max(accepted_at) from messages where from_id like 'HUM-%' and accepted_at > '2026-11-26T12:00:00Z' group by 1, 2 order by 1, 2" ./run -a do_spl_db_query` (`23:00:53Z`) | 0 rows across all workspaces after `12:00:00Z` (note: owner HUM-10's SPL-5254 poll answer `452c25df` / `8c3f32b4` A was logged earlier in `c002-next-round-candidates.md:154`) | **0 new rows** beyond SPL-5254 (Row b52-01). |
| **9. Round 51's first inputs** | `bug-round-51-plan.md` section 7 and section 3.5, re-measured on `ecc05e480` | `b51-03` landed (`a5bb05350`), unblocking `spl-review-go.func.sh`. All carried items verified still present on `ecc05e480`: `review-go` `DRY_RUN=0` false hold on `do_rdb_migration_next` (`spl-review-go.func.sh:756,806`), `a-767` N2 + `a-823` N2 (`spool-agent-hook.sh:140,807-813`), `a-769` N1 (`check-pre-push-lint.func.sh:618-643`) & N2 (`tenant-host-reserve.tst.sh`), `c-625` N1-N3, `a-995` N1 (`cron_test.go:209-229`) | **Carried** to round 53 (round 52 fills its 3-row cap with the owner order + two c-001 b52 rulings; section 3.5). |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (167 lines, read on sat `22:59Z`, from `:153` on) | `:154` SPL-5254 owner order -> **Row b52-01**; `:159-163` review-go relay C4 (`ee10c09a`) -> **Row b52-02**; `:167` `spawn-remote.sh` `handle()` race (`e1db57c6` / `42ac9aad`) -> **Row b52-03**; `:166` `MessageCard.vue` select box (`8e965469`, unproven rule, shared WUI file) -> **Carried** to b53; `:155` seat-rotation poke (`a1a5d394` / `2f3a505e`, cause unchecked on `<box2>`) -> **Carried** to b53; `:156` declined asks `1154207f` (**Queued** `c8ed77c7`), `503b3087` (**Served** `652d956ef` SPL-6620), `a4b540f6` (`spool-mirror.py:795`, **Carried**); `:157` review-go `DRY_RUN=0` false hold -> **Carried** to b53 (same file as b52-02) | **Rows b52-01, b52-02, b52-03**; rest accounted in section 3.5. |

---

## 3. The candidates, read

### 3.1 b52-01: Phone Back off level 1 (`useMobileStack.ts:382-398`) applies its level on any `router.afterEach` (cancelled/aborted/unrelated nav) and `mobile-back-wait.test.mjs` does not assert zero stale `#lobby` reads (SPL-5254, owner order)

- **What happens.** Follow-up of done SPL-5232 (`d70f6c5fb`, R7 reviewer `c-531@sat` msg `4fe0af88`, original brief `/var/spool-hub/dispatch/briefs/c002-bug-spl5232-popstate-land-guard.md`, owner HUM-10 t1 `3fbb2b1b` msg `452c25df` poll `8c3f32b4` answered A: *"Queue it now as a bug row (re-measure on master first; the bug share is under its band)"*). Verified still unfixed on `ecc05e480` (`git log origin/master --grep SPL-5254` -> 0):
  1. **W3** (`csi-spl-wui/src/composables/useMobileStack.ts:382-398`):
     ```ts
     function listenPopState(router: ReturnType<typeof useRouter>) {
       window.addEventListener('popstate', (e) => {
         moved()
         inPlaceUntil = 0
         if (isMobile.value) backs.value++
         const tagged = mobileTaggedLevel(e.state)
         if (tagged === null) return
         /* SPL-5232 (utils mobilePopWaitsRoute): off level 1, the page mounts on the route it lands on */
         const lags = router.resolve(router.options.history.location).fullPath !== router.currentRoute.value.fullPath
         const seq = ++popSeq
         if (!mobilePopWaitsRoute(tagged, level.value, lags)) return applyLevel(tagged)
         /* no navigation ever follows (a guard that hangs): the level still moves */
         const land = () => { off(); clearTimeout(late); if (seq === popSeq) applyLevel(tagged) }
         const off = router.afterEach(land)
         const late = setTimeout(land, POP_ROUTE_WAIT_MS)
       })
     }
     ```
     Because `land` accepts no parameters, it ignores both `to.fullPath` and vue-router's `failure`:
     - **Two quick popstates off level 1:** pop 1 starts navigating to `/channel/alerts`; pop 2 fires to `/channel/general` (`seq === popSeq` for pop 2); vue-router cancels nav 1 and calls `afterEach(to=/channel/alerts, from=/channel/lobby, failure=cancelled)`. Pop 2's `land` runs immediately and calls `applyLevel(2)` while `router.currentRoute.value` is still `/channel/lobby` — reproducing the exact stale-route mount SPL-5232 meant to prevent.
     - **Aborted navigation:** a `beforeEach` guard returning `false` calls `afterEach(to, from, failure=aborted)` while staying on the old route; `land` immediately calls `applyLevel(2)`. (Merely ignoring `failure` without clearing the 3 s fallback timer would still apply level 2 after 3 s.)
     - **Unrelated completed route:** a prior in-flight navigation completing to `/channel/other` triggers `land` before the pop's own target route resolves.
     - **Untagged popstate:** `if (tagged === null) return` runs BEFORE `++popSeq`, leaving a prior pop's `land` still armed with `seq === popSeq`.
  2. **W2** (`csi-spl-wui/tests/e2e/mobile-back-wait.test.mjs:91-101,180-191`):
     `plantSlow(page, SLOW_MS, 'alerts')` skips non-`'alerts'` calls via `if (name && a[0] !== name) return orig(...a)` without recording `selectChannel` invocations, and `slowBack` never asserts that only `'alerts'` was opened (no stale `'lobby'` read). Thus no e2e catches a regression of the SPL-5232 stale-mount guard.
- **Seen.** SPL-5232 R7 `c-531@sat` (`4fe0af88`), SPL-5254 (`onhold` since 2026-11-11), owner HUM-10 t1 `3fbb2b1b` (`452c25df`, poll `8c3f32b4` A). Reproduced live on `ecc05e480` via `rc01-b52.sh` (`23:09Z`): Probes A (`two_pops_nav1_cancelled`), B (`aborted_guard`), C (`unrelated_route_first`), D (`untagged_cancels`), and E (`w2_e2e_selectChannel_assert`) all fail (`rc01 exit 1`). Baseline `node --test csi-spl-wui/tests/unit/mobile-stack.test.mjs` -> `42 pass, 0 fail`.
- **Red control** (`rc01-b52.sh`, section 4.1): self-contained (extracts `useMobileStack.ts`, `mobile-stack.mjs`, `mobile-stack.test.mjs`, `mobile-back-wait.test.mjs` from `ecc05e480` into `mktemp -d`; drives the actual `listenPopState` in Node with a mock `window` + vue-router, zero `node_modules`). On `ecc05e480`: A `premature=1`, B `immediate=1 after_timer=1`, C `premature=1`, D `untagged_cancels=false`, E `records=false asserts=false` -> `rc01 exit 1`. **Control (`fix-shape`):** adds pure `mobilePopAfterNav` to `mobile-stack.mjs`, wires it + `popFailureKind` + early `++popSeq` into `listenPopState`, and records/asserts `['alerts']` in `mobile-back-wait.test.mjs` -> A..F all pass -> `rc01 exit 0`.
- **Fix scope.**
  - `csi-spl-wui/src/utils/mobile-stack.mjs:147-149`: add pure helper `mobilePopAfterNav({ target, to, redirectedFrom, failure })` returning `'land' | 'cancel' | 'wait'` (1 object param, <= 75 lines): `'cancel'` on `'aborted'` when `to === target || redirectedFrom === target`; `'wait'` on `'cancelled'`, `'other'`, or mismatched target; `'land'` on `null`/`'duplicated'` matching `target` (or `redirectedFrom === target`).
  - `csi-spl-wui/src/composables/useMobileStack.ts:377-398`: add `popFailureKind(failure)` using the already-imported `isNavigationFailure` / `NavigationFailureType`; bump `const seq = ++popSeq` BEFORE `if (tagged === null) return`; resolve `target = router.resolve(router.options.history.location).fullPath`; wait in `router.afterEach((to, _from, failure) => ...)` using `mobilePopAfterNav` (`'land'` applies & clears timer, `'cancel'` unsubscribes & clears timer without applying, `'wait'` stays subscribed); keep the `POP_ROUTE_WAIT_MS` (3 s) fallback timer for a genuinely hanging guard. Keep every function <= 75 lines and <= 5 params.
  - `csi-spl-wui/tests/unit/mobile-stack.test.mjs`: add unit tests for `mobilePopAfterNav` (cancelled nav1 -> `'wait'`, aborted target -> `'cancel'`, aborted other -> `'wait'`, unrelated route -> `'wait'`, exact target / redirect / duplicated target -> `'land'`).
  - `csi-spl-wui/tests/e2e/mobile-back-wait.test.mjs:91-101,180-194`: record every `selectChannel(name)` call during the Back off level 1 in `plantSlow` and assert `calls.join(',') === 'alerts'` in `slowBack` (author + R7 prove W2 red control in Chrome by temporarily returning `false` from `mobilePopWaitsRoute` on a scratch bundle -> `#lobby` read caught red, then green on fix). Note: **never** touch `stores/channel.ts`. Keep `Docs: none` (bug fix to internal SPL-5232 route-wait guard and its e2e; spec 087 3.4 already states the Back behaviour) or add one line to spec 087 if needed. Use existing issue **SPL-5254** (or link it per holder placement).

### 3.2 b52-02: `do_spl_review_go` (`spl-review-go.func.sh:864-866`) sends `GO <sha>` on `do_spl_review_line_check` rc 0 without verifying the author brief's required tests appear in `ran:` (C4, c-001 ruling `ee10c09a`)

- **What happens.** `_spl_review_go_one` (`csi-spl-orc/src/bash/run/spl-review-go.func.sh:839-876`) resolves `$abrief` at `:858` and runs `do_spl_review_line_check` at `:864`, which only checks that whatever tests the reviewer chose to list in `ran:` were actually run in the reviewer's log (plus the WUI e2e map). Nothing compares the **author brief's required tests** (`*.tst.sh`, `test-*.sh` excl. `*.inc.sh`, `*.test.mjs`, `rc[0-9][0-9]*.sh`, exact `do_check_pre_push`, unconditional `PRE_PUSH_TIER=full`, `shellcheck`) against `ran:` (rulebook 2.7.7 C4, `rounds-rulebook.md:126`).
  As a result, the relay sent automatic `GO <sha>` messages on reviews missing required tests (**n=2 live misses on 2026-11-26**):
  1. `14:23:48Z` GO `d8bfb277` to `c-068@<box2>` on `a-099` PASS `02ccf2c7` (`85644770a`, landed `92830c078` before holder send-back): brief `c002-6e8c1cdb-wui-loops-dialog-radio-title-drag.md:45` required `cd csi-spl-iac && ./run -a do_check_pre_push`, while `a-099`'s `ran:` had only `do_check_pre_push_lint ; do_check_dist_hygiene`.
  2. `14:59:04Z` GO `245ec817` to `c-076@sat` on `a-113` PASS `c2a02a11` (`6767a387e`, spec 153 Q3): brief `c002-s153-q3-queue-route-holds.md:43` required `cd csi-spl-iac && ./run -a do_check_pre_push; this row touches the store/hub: run it with PRE_PUSH_TIER=full.`, while `a-113`'s `ran:` had only `./run -a do_check_pre_push_lint`.
  3. Earlier `04:4xZ` GOs on `b49-01`, `b49-02`, and `r05-02` omitted `do_check_pre_push` and 3 iac `*.tst.sh` tests named in the brief.
- **Zero false holds on passing round rows (empirically audited on sat `23:06Z`):**
  Audited the proposed extractor against 7 real `(abrief, review line)` pairs from 2026-11-26 on sat:
  - Both evidence misses (`a-099` loops part 1, `a-113` s153 Q3) -> **HOLD** (`missing: do_check_pre_push, PRE_PUSH_TIER=full`).
  - All 3 passing b51 rows (`b51-01` `a-088` 8/8, `b51-02` `a-096` 7/7, `b51-03` `a-104` 7/7) -> **0 missing (GO)**.
  - Passing r08 rows (`r08-01` `a-230` 23/23, `r08-02` `a-242` 14/14): initially flagged sibling-row exclusions (`r08-01:37` ``NOT `test-y16-git-pager-off.sh` ``; `r08-02:35` ``NOT `cron-tagged-line.tst.sh` ``); stripping inline `NOT`/`never`/`except`/`excluding`/`stay off` file tokens + non-instruction headings (`## Never`, `## Files you must NOT touch`, `## Why`, `## At queue/brief time`, `## Lane-map clearance`, fenced blocks, `>` quotes) brings both to **0 missing (GO)**.
  - Existing test fixture note: `spl-review-go.tst.sh:1148` (case 27) places `` `spl-billing-sa.tst.sh` `` inside `## Do` solely to test joined-name owner-go parsing while its default `line` has `ran: bash spl-x.tst.sh`; update case 27 `:1148-1151` to include `spl-billing-sa.tst.sh` in its test line/log (keeping the owner-go assertion unchanged) so all 35 existing cases remain green.
- **Seen.** c-001 explicit ruling `ee10c09a` (`14:43:52Z`, *"please make it a bug round 52 row"*), `a7f0d4b7`, `c002-next-round-candidates.md:159-163`. `b51-03` (`a5bb05350`, SPL-6600) has already landed, so `spl-review-go.func.sh` and `spl-review-go.tst.sh` are **free for Batch 1**. Reproduced live on `ecc05e480` (`rc02-b52.sh` `23:18Z`): all 3 missing-test probes return `rc=0 gos=1` (GO) on `ecc05e480` and `rc=12 gos=0` (HOLD naming the missing tests) on `fix-shape`, with both controls passing `rc=0 gos=1`. Baseline `spl-review-go.tst.sh` -> `0 failure(s)`, `spl-accepted-close.tst.sh` -> `0 failure(s)`.
- **Red control** (`rc02-b52.sh`, section 4.2): self-contained (extracts `csi-spl-orc` review-go files into `mktemp -d`, builds a temp git repo + spool root, runs `do_spl_review_go` with `REVIEW_GO_MSG`). Probes: `red_a099_missing_pre_push`, `red_a113_missing_full_tier`, `red_round_missing_tst_and_rc` (all want HOLD `rc != 0, gos=0` naming the missing test), plus `ctrl_all_present` and `ctrl_exclusions_ignored` (both want GO `rc=0, gos=1`). On `ecc05e480`: all 3 red probes send GO (`rc02 exit 1`). **Control (`fix-shape`):** adds `_spl_review_go_c4_missing` (<= 75 lines) wired into `_spl_review_go_one` after `do_spl_review_line_check` (skipping `DOCS-ONLY`), holding `rc 12` -> all 5 cases match -> `rc02 exit 0`.
- **Fix scope.**
  - `csi-spl-orc/src/bash/run/spl-review-go.func.sh`: add `_spl_review_go_c4_missing <abrief> <line>` (<= 75 lines) and wire it in `_spl_review_go_one` right after `do_spl_review_line_check` (`:866`), skipped when `do_spl_review_line_check` output contains `DOCS-ONLY `; on missing required test(s), call `_spl_review_go_hold "$@" 12 "review ran: misses brief-named test(s) (C4): $why"; return 12`. Document check `[12]` in the `@description` header. Keep `_spl_review_go_one` <= 75 lines (38 -> 42 lines).
  - `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`: keep case 27 (`:1148-1151`) passing by adding `spl-billing-sa.tst.sh` to its stub line/log; add case 36 after case 35 (`:1456`) covering `do_check_pre_push` missing (when only `do_check_pre_push_lint` ran, a-099 shape), `PRE_PUSH_TIER=full` missing (a-113 shape), named `*.tst.sh`/`rc*.sh`/`shellcheck` missing (round row shape), all-present GO control, exclusion controls (`NOT`, `## Never`, `## Files you must NOT touch`, conditional `If ... PRE_PUSH_TIER=full`), and `DOCS-ONLY` skip control. `Docs: none` (enforces existing rulebook C4 gate in spec 157 rule 1 automation).

### 3.3 b52-03: `spawn-remote.sh` `handle()` / `handle_issue()` / `note_cancel()` (`:274-282,484-491,682-691`) read `$f` in 4 separate disk calls after marking `$STATE/seen`, so a mid-read ack turns valid requests into `REJECTED bad kind ''` and `reply()` (`:255-261`) mints a random task id on empty `$task`

- **What happens.** `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh` reads an incoming spool JSON file `$f` with **four separate disk reads** in three handlers — `handle()` (`:277-282`), `handle_issue()` (`:486-491`), and `note_cancel()` (`:684-691`):
  ```bash
  msg="$(jq -r '.msg_id // ""' "$f" 2>/dev/null)"
  [[ "$msg" =~ ^[0-9A-Za-z-]{8,64}$ ]] || return 0
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"
  from="$(jq -r '.from // ""' "$f")"; task="$(jq -r '.task_id // ""' "$f")"
  body="$(body_of "$f" | strip_from_agent)"
  ```
  When the receiving role seat runs `spool recv --as c-001 --ack` between the first `jq` and the later reads (moving `$f` from `inbox/` to `archive/`), `$msg` has ALREADY been appended to `$STATE/seen` (blocking any retry from `archive/` on the next pass), while the subsequent reads see a missing file (`from=""` or `task=""`, `body=""`):
  - In `handle()`: `task=""` and `kind=""` -> logs `REJECTED ... spawn-remote: bad kind ''` (or `REFUSED ... sender is not an agent id` if moved right after `.msg_id`), NEVER spawns the lane, and calls `reply "$me" "$from" "" refused ...`.
  - In `reply()` (`:255-261`): `send ... --task ""` passes an empty `--task` to `spool-send.sh`, which mints a **brand-new random task UUID** on the wire (breaking request/reply correlation — the requester waits until timeout on its original task).
  - In `note_cancel()` (`:684-691`): the same mid-read ack marks `$msg` seen and logs `CANCELLED ... ignored (not the holder, or a bad task)`, permanently dropping a spawn cancellation!
  - In `handle_issue()` (`:486-491`): identical race drops remote issue placement/end requests permanently.
- **Seen.** Live incident today (`2026-11-26T15:19:02Z`, `<box2>` `serve.log:3728`, `c-001@<box2>` root-cause `42ac9aad`, c-001 go `e1db57c6`, `c002-next-round-candidates.md:167`): b52's own panel spawn request `82416aaf` (task `f41bc755`) was acked by `c-001@<box2>` at `15:19:02.405Z` mid-`handle()`, logging `REJECTED 82416aaf c-001@sat spawn-remote: bad kind ''` and replying on minted task `765fe1de`. Reproduced live on `ecc05e480` (`rc03-b52.sh` `23:12Z`): Cases A (`handle_ack_race`), A2 (`handle_archive_fallback`), B (`note_cancel_ack_race`), and C (`reply_empty_task`) all fail on `ecc05e480` (`rc03 exit 1`) and all pass on `fix-shape` (`rc03 exit 0`). Baseline `test-spawn-remote.sh` -> `127 passed, 0 failed`; `spawn-remote-cron.tst.sh` -> `fails=0`.
- **Red control** (`rc03-b52.sh`, section 4.3): self-contained (extracts `spawn-agents` from `ecc05e480` into `mktemp -d`; uses a 1-shot `jq` shim that moves the inbox JSON to `archive/` immediately after a `.msg_id` file read, reproducing the exact `15:19:02Z` ack race).
  - **Case A (`handle_ack_race`):** file in `inbox/` moves to `archive/` on first `.msg_id` read -> requires `calls=1, rej=0, good_task=1, minted=0`. On `ecc05e480`: `calls=0, good_task=0` (RED).
  - **Case A2 (`handle_archive_fallback`):** file already moved to `archive/` before `handle()` starts -> requires `calls=1, good_task=1`. On `ecc05e480`: `calls=0, good_task=0` (RED).
  - **Case B (`note_cancel_ack_race`):** cancel in `inbox/` moves to `archive/` on first `.msg_id` read -> requires `cancelled_recorded=1`. On `ecc05e480`: `cancelled_recorded=0` (RED).
  - **Case C (`reply_empty_task`):** `reply c-001 c-001@sat "" refused ...` -> requires `sent=0` (refused, never mints random task). On `ecc05e480`: `sent=1` (RED).
  - **Control (`fix-shape`):** adds `read_msg_fields` (single atomic `cat` with `archive/` fallback, parses `msg`/`from`/`task`/`body` from that in-memory snapshot BEFORE writing `$STATE/seen`), uses it in `handle()`, `handle_issue()`, and `note_cancel()`, and guards `reply()` on `[ -n "$task" ]` -> A, A2, B, C all pass -> `rc03 exit 0`.
- **Fix scope.**
  - `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh`:
    - Add helper `read_msg_fields <me> <file>` (~14 lines): reads `$f` once into memory (`cat -- "$f"`), falling back to `$SPOOL_ROOT/$me/archive/${f##*/}` if vanished; if still empty/unreadable, returns 1 WITHOUT touching `$STATE/seen` so the next tick retries; parses `msg_id`, `from`, `task_id`, `body` (through `strip_from_agent`) from the in-memory snapshot and validates `msg_id`.
    - Wire `read_msg_fields` into `handle()` (`:274-282`, shrinks 73 -> 71 lines <= 75), `handle_issue()` (`:484-491`, shrinks 50 -> 48 lines), and `note_cancel()` (`:682-691`, shrinks 17 -> 15 lines), recording `$msg` in `$STATE/seen` ONLY after `read_msg_fields` succeeds.
    - Guard `reply()` (`:255-261`, 7 -> 8 lines): `[ -n "$task" ] || { say "WARN reply to $to skipped: empty task"; return 0; }` so an empty task never mints a phantom task UUID.
  - `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`: add case 16 proving `handle()` survives an inbox->archive move mid-read (and archive fallback), `note_cancel()` survives the same ack race, a vanished unreadable file is NOT marked in `$STATE/seen`, and `reply()` refuses an empty task without sending. `Docs: none` (fixes internal TOCTOU race and empty-task reply bug in `spawn-remote.sh`).

### 3.4 CI reds and prd WARNING / ERROR lines, read

| source / item | read | why not a row |
|---|---|---|
| wf 10 (`10_ci-quality.yml`, 100 runs `22:59Z..23:04Z`) | 3 failed runs since W (`15:48:03Z`): `45878486725` (`5ef798c0`, `wui: browser e2e 3/8` single sighting `S3 1440px dark: shaded row 2 has notes to open`, green since); `45882558631` (`4609bb49`) & `45886801673` (`075c1bab`, `internal/action` coverage floor 90.4% < 91.6 - 1.0) | **Served / single sighting**: `internal/action` floor fixed by `81fea84a1`; last green `45905322386` (`652d956e`, `22:31:24Z`). Trunk is green. |
| Other master workflows (`gh run list --status failure`, `23:00Z`) | 2 failures since W: `45882558835` & `45886801975` (wf 20 on `4609bb49`/`075c1bab`, same `internal/action` coverage floor) | **Served** by `81fea84a1`. |
| Cloud SQL `spool_hub_rt` ad-hoc SQL errors (22 since W) | Exploratory `do_spl_db_query` queries (`relation "topics"/"issue_comments" does not exist`, `column "id"/"key"/"epic"/"discussion_id" does not exist`, `operator does not exist`); no repo code runs them | **Not a row**: ad-hoc operator/agent SQL. |
| Cloud Run HTTP 503 (`malformed HTTP response or connection to the instance had an error`, 7 since W) | Transient Cloud Run instance recycles during hub deploys (`v4.2.7`..`v4.3.4`); 0 alert incidents | **Not a row.** |
| prd WARNINGs (1349 since W: 560 `unpinned_box`, 551 `unknown_token`, 122 `context canceled`, scanner 404s, expected 403/404s, 0 `hours/minutes` 400s) | Carried `unknown_token` box question + `<dev-box>` unpinned retries + deploy-time cancels + expected scanner/non-member 403/404s | **Not a row** (`unknown_token` stays carried with holder). |

### 3.5 Round 51's first inputs, recent R7 notes, and the candidate list, re-read

| candidate | result on `ecc05e480` | verdict |
|---|---|---|
| **SPL-5254** (owner order HUM-10 `452c25df`, poll `8c3f32b4` A; phone Back popstate land guard, SPL-5232 R7 W2 + W3) | reproduced live on `ecc05e480` (`useMobileStack.ts:382-398`, `mobile-back-wait.test.mjs:91-101`; `git log --grep SPL-5254` -> 0); `rc01-b52.sh` exit 1 -> `fix-shape` exit 0 | **Row b52-01** (section 3.1). |
| **review-go relay C4 test-column check** (`c-001` ruling `ee10c09a`, `a7f0d4b7`, `c002-next-round-candidates.md:159-163`, n=2 today: GO `d8bfb277` on `a-099`, GO `245ec817` on `a-113`) | `b51-03` landed (`a5bb05350`), so `spl-review-go.func.sh` is free; reproduced live on `ecc05e480`; 0 false holds on b51-01..03 and r08-01..02; `rc02-b52.sh` exit 1 -> `fix-shape` exit 0 | **Row b52-02** (section 3.2). |
| **`spawn-remote.sh` `handle()` ack race** (`c-001` `e1db57c6`, `c-001@<box2>` `42ac9aad`, `c002-next-round-candidates.md:167`, live hit `15:19:02Z` on b52 panel `82416aaf`) | reproduced live on `ecc05e480` (`spawn-remote.sh:255-261,274-282,484-491,682-691`); `rc03-b52.sh` exit 1 -> `fix-shape` exit 0 | **Row b52-03** (section 3.3). |
| `MessageCard.vue` M3 select box (`c-123` `8e965469`, `c-001` `e1db57c6`, `c002-next-round-candidates.md:166`) | `MessageCard.vue:1121` still has `content-visibility: auto` on `.msg:not(:focus-within)`; root cause still unproven ("unproven which rule" per `c-123`), and b52 is at its rulebook 5.1 cap of 3 rows | **Carried** as first input #1 for round 53 (isolate exact CSS/DOM reflow rule in Chrome first). |
| `review-go` owner-go false holds (`do_rdb_migration_next` `b4952880`; `a-104` N1 `## At brief time` `db300104`; another round's `DRY_RUN=0` `3748a973`; backticks/identifiers/prose `apply`/`Apply`, 4 more rc 4 holds in `automation.log` `20:27Z..22:12Z`) | verified still present at `spl-review-go.func.sh:711,756,806`; edits `spl-review-go.func.sh` (b52-02's file, R1) and round is at 3-row cap | **Carried** as first input #2 for round 53 (places only after b52-02 lands). |
| Seat-rotation poke reports exit 0 without reaching the new pane (`c-001` `a1a5d394` + `2f3a505e`, `c-001@<box2>` `5ea525c1`, `c-971@<box2>` `9d9cc643`, spec 060, `c002-next-round-candidates.md:155`) | cause still unchecked on `<box2>` (no local `<box2>` tmux/sidecar logs on sat); round at 3-row cap | **Carried** as first input #3 for round 53 (trace sidecar pane resolution & retiring-window close on `<box2>` first). |
| Earlier declined bug asks (`c002-next-round-candidates.md:156`, handover `55c662b8`): `1154207f`, `503b3087`, `a4b540f6` | `503b3087` (blog picture check) **Served** by `652d956ef` (SPL-6620); `1154207f` (fence restart rotation reads) **Queued** as ask `c8ed77c7` (`c003-b450-fence-restart-rotation-reads`); `a4b540f6` (`spool-mirror.py:795` `first_sighting` dangling `.mirror`) verified still present | `503b3087` **Served**; `1154207f` **Queued** (R3); `a4b540f6` **Carried** to round 53. |
| `a-767` N2 (`spool-agent-hook.sh:807-813` stale `stop_denies`) & `a-823` N2 (`PreInvocation` in `EVENTS` at `:140`) | verified still present on `ecc05e480`; round at 3-row cap | **Carried** to round 53. |
| `a-769` N1 (`check-pre-push-lint.func.sh:618-643` `_ppl_run_timed` returns 124 vs 137) & N2 (`tenant-host-reserve.tst.sh` symlink control) | verified still present on `ecc05e480` (0 `symlink` hits in `tenant-host-reserve.tst.sh`); round at 3-row cap | **Carried** to round 53. |
| `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`); `a-995` N1 (`internal/taskcron/cron_test.go:209-229` malformed step tokens `*/`, `*/1/2`, `*/99999` in `TestRefusals`, 0 hits on `ecc05e480`); `a-911` N2; `a-790` N1; `hours/minutes` whole-batch 400 follow-up (0 sightings since W); `c-708` N1; `a-683` N3; `a-490` N1; `a-480` N1; `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget`; `unknown_token` box; hub dir mode; hermetic 2/4 timeout; composed testids; `i18n-lang-review-exempt.json:2`; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` | unchanged / carried (round at rulebook 5.1 cap of 3) | **Carried** to round 53. |

---

## 4. Red controls, as run

### 4.1 `rc01-b52.sh` (b52-01, SPL-5254), sha256 first 12 hex `642aa582b7a6`, 15243 B

Run from any checkout: `bash rc01-b52.sh ecc05e480` (exit 1), then `bash rc01-b52.sh ecc05e480 fix-shape` (exit 0). Under 3 s each. Self-contained (zero box paths, zero `node_modules`).

```bash
#!/usr/bin/env bash
# rc01-b52.sh <sha> [fix-shape]: b52-01 (SPL-5254) red control.
# Follow-up of SPL-5232 R7 findings W3 + W2 (owner HUM-10 t1 3fbb2b1b msg
# 452c25df, poll 8c3f32b4 answer A):
#   - W3 (csi-spl-wui/src/composables/useMobileStack.ts listenPopState):
#     a popstate off level 1 registers `router.afterEach(land)` where `land`
#     takes no arguments, ignoring navigation failures and `to.fullPath`.
#     Two quick popstates cancel nav 1 and its `afterEach` (with failure)
#     runs pop 2's `land` while `seq === popSeq`, applying level 2 before
#     pop 2's route resolves (stale mount). An aborted navigation (guard
#     returning false) and an unrelated completed route also trigger `land`
#     prematurely. And an untagged popstate returns before bumping `popSeq`.
#   - W2 (csi-spl-wui/tests/e2e/mobile-back-wait.test.mjs): `plantSlow`
#     returns `orig(...a)` for non-`'alerts'` channels without recording or
#     asserting `selectChannel` calls, so no e2e catches a stale `#lobby` read.
# Extracts mobile-stack files from <sha> into mktemp -d. Self-contained (no box paths).
set -uo pipefail
sha="${1:?usage: rc01-b52.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" \
  csi-spl-wui/src/composables/useMobileStack.ts \
  csi-spl-wui/src/utils/mobile-stack.mjs \
  csi-spl-wui/tests/unit/mobile-stack.test.mjs \
  csi-spl-wui/tests/e2e/mobile-back-wait.test.mjs | tar -x -C "$tmp"

ts="$tmp/csi-spl-wui/src/composables/useMobileStack.ts"
mjs="$tmp/csi-spl-wui/src/utils/mobile-stack.mjs"
utst="$tmp/csi-spl-wui/tests/unit/mobile-stack.test.mjs"
e2e_test="$tmp/csi-spl-wui/tests/e2e/mobile-back-wait.test.mjs"

a=$(grep -c '^function listenPopState(' "$ts")
b=$(grep -c '^export function mobilePopWaitsRoute(' "$mjs")
c=$(grep -c '^const plantSlow =' "$e2e_test")
echo "rc01 sites: listenPopState=$a mobilePopWaitsRoute=$b plantSlow=$c"
[ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] || { echo "rc01 sites moved"; exit 2; }

if [ "${2:-}" = fix-shape ]; then
  python3 - "$mjs" "$ts" "$e2e_test" <<'PY' || exit 2
import sys
mjs_p, ts_p, e2e_test_p = sys.argv[1:4]

# 1. Pure decision helper in mobile-stack.mjs
s = open(mjs_p).read()
anchor = """export function mobilePopWaitsRoute(tagged, level, routeLags) {
  return level === 1 && tagged !== null && tagged > 1 && routeLags
}"""
added = anchor + """

/**
 * SPL-5254 (follow-up of SPL-5232 R7 W3): an afterEach while a popstate off
 * level 1 waits for its route.
 *   'land'   - this pop's route resolved (or redirected from it, or duplicated
 *              already at it): apply the level now
 *   'cancel' - this pop's navigation was aborted by a guard: stop waiting and
 *              do not apply the level (not even on the fallback timer)
 *   'wait'   - another navigation finished, was cancelled, or failed: keep
 *              waiting for this pop's own route
 * @param {{ target: string, to: string, redirectedFrom?: string|null, failure: 'aborted'|'cancelled'|'duplicated'|'other'|null }} s
 * @returns {'land'|'cancel'|'wait'}
 */
export function mobilePopAfterNav(s) {
  const mine = s.to === s.target || (Boolean(s.redirectedFrom) && s.redirectedFrom === s.target)
  if (s.failure === 'aborted') return mine ? 'cancel' : 'wait'
  if (s.failure === 'cancelled' || s.failure === 'other') return 'wait'
  return mine ? 'land' : 'wait'
}"""
assert s.count(anchor) == 1, f"mjs anchor count={s.count(anchor)}"
open(mjs_p, "w").write(s.replace(anchor, added, 1))

# 2. Wire mobilePopAfterNav into useMobileStack.ts listenPopState
t = open(ts_p).read()
imp_old = "  mobilePopWaitsRoute,\n"
imp_new = "  mobilePopAfterNav,\n  mobilePopWaitsRoute,\n"
assert t.count(imp_old) == 1, f"ts imp count={t.count(imp_old)}"
t = t.replace(imp_old, imp_new, 1)

old_fn = """/** browser Back / Forward, and pop() -> history.back() */
function listenPopState(router: ReturnType<typeof useRouter>) {
  window.addEventListener('popstate', (e) => {
    moved()
    inPlaceUntil = 0
    if (isMobile.value) backs.value++
    const tagged = mobileTaggedLevel(e.state)
    if (tagged === null) return
    /* SPL-5232 (utils mobilePopWaitsRoute): off level 1, the page mounts on the route it lands on */
    const lags = router.resolve(router.options.history.location).fullPath !== router.currentRoute.value.fullPath
    const seq = ++popSeq
    if (!mobilePopWaitsRoute(tagged, level.value, lags)) return applyLevel(tagged)
    /* no navigation ever follows (a guard that hangs): the level still moves */
    const land = () => { off(); clearTimeout(late); if (seq === popSeq) applyLevel(tagged) }
    const off = router.afterEach(land)
    const late = setTimeout(land, POP_ROUTE_WAIT_MS)
  })
}"""
new_fn = """function popFailureKind(failure: unknown): 'aborted' | 'cancelled' | 'duplicated' | 'other' | null {
  if (!failure) return null
  if (isNavigationFailure(failure, NavigationFailureType.aborted)) return 'aborted'
  if (isNavigationFailure(failure, NavigationFailureType.cancelled)) return 'cancelled'
  if (isNavigationFailure(failure, NavigationFailureType.duplicated)) return 'duplicated'
  return 'other'
}

/** browser Back / Forward, and pop() -> history.back() */
function listenPopState(router: ReturnType<typeof useRouter>) {
  window.addEventListener('popstate', (e) => {
    moved()
    inPlaceUntil = 0
    if (isMobile.value) backs.value++
    const seq = ++popSeq
    const tagged = mobileTaggedLevel(e.state)
    if (tagged === null) return
    /* SPL-5232 / SPL-5254: off level 1, the page mounts only after its own route resolves */
    const target = router.resolve(router.options.history.location).fullPath
    const lags = target !== router.currentRoute.value.fullPath
    if (!mobilePopWaitsRoute(tagged, level.value, lags)) return applyLevel(tagged)
    const done = (apply: boolean) => { off(); clearTimeout(late); if (apply && seq === popSeq) applyLevel(tagged) }
    const off = router.afterEach((to, _from, failure) => {
      if (seq !== popSeq) return done(false)
      const step = mobilePopAfterNav({ target, to: to.fullPath, redirectedFrom: to.redirectedFrom?.fullPath ?? null, failure: popFailureKind(failure) })
      if (step === 'land') done(true)
      else if (step === 'cancel') done(false)
    })
    /* no navigation ever follows (a guard that hangs): the level still moves */
    const late = setTimeout(() => done(true), POP_ROUTE_WAIT_MS)
  })
}"""
assert t.count(old_fn) == 1, f"ts fn count={t.count(old_fn)}"
open(ts_p, "w").write(t.replace(old_fn, new_fn, 1))

# 3. W2 in mobile-back-wait.test.mjs: record every selectChannel call and assert ['alerts']
e = open(e2e_test_p).read()
e_old = """const plantSlow = (p, ms, only = '') => vue(p, ([wait, name]) => {
  const ch = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('channel')
  const orig = ch.selectChannel
  ch.selectChannel = async (...a) => {
    if (name && a[0] !== name) return orig(...a)
    ch.selectChannel = orig
    ch.loading = true
    await new Promise((r) => setTimeout(r, wait))
    return orig(...a)
  }
}, [ms, only])"""
e_new = """const plantSlow = (p, ms, only = '') => vue(p, ([wait, name]) => {
  const ch = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('channel')
  const orig = ch.selectChannel
  const calls = []
  window.__selectChannels = calls
  ch.selectChannel = async (...a) => {
    calls.push(a[0])
    if (name && a[0] !== name) return orig(...a)
    ch.selectChannel = orig
    ch.loading = true
    await new Promise((r) => setTimeout(r, wait))
    return orig(...a)
  }
}, [ms, only])
const channelCalls = (p) => vue(p, () => window.__selectChannels || [])"""
assert e.count(e_old) == 1, f"e2e_test plantSlow count={e.count(e_old)}"
e = e.replace(e_old, e_new, 1)
e_old2 = "    ok(`${how}: Back returns to #alerts and the feed loads`, pressed && back.path === '/channel/alerts' && !back.busy, back)"
e_new2 = e_old2 + "\n    const chCalls = await channelCalls(page)\n    ok(`${how}: Back off level 1 opens only #alerts, no stale #lobby read (SPL-5254)`, chCalls.join(',') === 'alerts', chCalls)"
assert e.count(e_old2) == 1, f"e2e_test assert count={e.count(e_old2)}"
open(e2e_test_p, "w").write(e.replace(e_old2, e_new2, 1))
PY
  echo "rc01 fix-shape: mobilePopAfterNav + listenPopState route/failure guard + mobile-back-wait selectChannel assertion"
fi

# Drive the real listenPopState extracted from <sha>'s useMobileStack.ts with a
# mock vue-router and window in Node (zero node_modules, < 1 s).
node --input-type=module - "$mjs" "$ts" "$e2e_test" <<'NODE'
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const [mjsPath, tsPath, e2e_testPath] = process.argv.slice(2)
const ms = await import(pathToFileURL(mjsPath).href)
const tsSrc = fs.readFileSync(tsPath, 'utf8')

// Slice from `let popSeq = 0` to `function routeAligner` (or `function install`)
const i0 = tsSrc.indexOf('let popSeq = 0')
const i1 = tsSrc.indexOf('function routeAligner')
if (i0 < 0 || i1 < 0 || i1 <= i0) {
  console.error('rc01 harness: cannot locate listenPopState slice')
  process.exit(2)
}
let block = tsSrc.slice(i0, i1)
// Strip simple TS type annotations so Node runs the actual function verbatim
block = block
  .replace(/\(router:\s*ReturnType<typeof useRouter>\)/g, '(router)')
  .replace(/\(failure:\s*unknown\)\s*:[^{]+(?=\{)/g, '(failure) ')
  .replace(/\(apply:\s*boolean\)/g, '(apply)')
  .replace(/\(e:\s*PopStateEvent\)/g, '(e)')
  .replace(/\bconst POP_ROUTE_WAIT_MS = \d+/g, 'const POP_ROUTE_WAIT_MS = 40')

const NavigationFailureType = { aborted: 4, cancelled: 8, duplicated: 16 }
const isNavigationFailure = (err, type) => Boolean(err && err.__isNavFailure && (type === undefined || (err.type & type) !== 0))
const makeFail = (type) => ({ __isNavFailure: true, type })

function buildHarness() {
  let popHandler = null
  const afterHooks = []
  const applied = []
  const level = { value: 1 }
  const isMobile = { value: true }
  const backs = { value: 0 }
  let inPlaceUntil = 0
  const moved = () => {}
  const applyLevel = (lv) => { applied.push(lv); level.value = lv }
  const win = { addEventListener: (ev, fn) => { if (ev === 'popstate') popHandler = fn } }
  const router = {
    options: { history: { location: '/channel/lobby' } },
    currentRoute: { value: { fullPath: '/channel/lobby' } },
    resolve: (loc) => ({ fullPath: loc }),
    afterEach: (fn) => {
      afterHooks.push(fn)
      return () => { const i = afterHooks.indexOf(fn); if (i >= 0) afterHooks.splice(i, 1) }
    },
  }
  const exportsList = Object.keys(ms)
  const fn = new Function(
    'window', 'moved', 'isMobile', 'backs', 'level', 'applyLevel',
    'isNavigationFailure', 'NavigationFailureType', 'inPlaceUntil',
    ...exportsList,
    `${block}\nreturn listenPopState;`
  )
  const listenPopState = fn(
    win, moved, isMobile, backs, level, applyLevel,
    isNavigationFailure, NavigationFailureType, inPlaceUntil,
    ...exportsList.map((k) => ms[k])
  )
  listenPopState(router)
  const firePop = (loc, lv) => {
    router.options.history.location = loc
    popHandler({ state: lv === null ? {} : { [ms.MOBILE_LEVEL_KEY]: lv } })
  }
  const fireAfter = (toPath, failure = undefined, redirectedFrom = null) => {
    const to = { fullPath: toPath, redirectedFrom: redirectedFrom ? { fullPath: redirectedFrom } : undefined }
    const from = { fullPath: router.currentRoute.value.fullPath }
    if (!failure) router.currentRoute.value = { fullPath: toPath }
    for (const h of [...afterHooks]) h(to, from, failure)
  }
  return { firePop, fireAfter, applied, level, afterHooks }
}

const sleep = (msWait) => new Promise((r) => setTimeout(r, msWait))
let rc = 0

// A (W3): two quick popstates off level 1; nav1 cancelled fires afterEach while pop2 is pending
{
  const h = buildHarness()
  h.firePop('/channel/alerts', 2)
  h.firePop('/channel/general', 2)
  h.fireAfter('/channel/alerts', makeFail(NavigationFailureType.cancelled))
  const premature = h.applied.length
  h.fireAfter('/channel/general', undefined)
  const ok = premature === 0 && h.applied.length === 1 && h.applied[0] === 2
  console.log(`rc01 A(two_pops_nav1_cancelled): premature=${premature} (want 0) final=[${h.applied}] (want [2])`)
  if (!ok) rc = 1
}

// B (W3): aborted navigation (guard returns false) must NOT apply level (neither immediately nor after fallback timer)
{
  const h = buildHarness()
  h.firePop('/channel/alerts', 2)
  h.fireAfter('/channel/alerts', makeFail(NavigationFailureType.aborted))
  const imm = h.applied.length
  await sleep(80)
  const afterWait = h.applied.length
  const ok = imm === 0 && afterWait === 0
  console.log(`rc01 B(aborted_guard): immediate=${imm} (want 0) after_timer=${afterWait} (want 0)`)
  if (!ok) rc = 1
}

// C (W3): unrelated navigation finishing first must NOT apply level before target resolves
{
  const h = buildHarness()
  h.firePop('/channel/alerts', 2)
  h.fireAfter('/channel/other', undefined)
  const premature = h.applied.length
  h.fireAfter('/channel/alerts', undefined)
  const ok = premature === 0 && h.applied.length === 1 && h.applied[0] === 2
  console.log(`rc01 C(unrelated_route_first): premature=${premature} (want 0) final=[${h.applied}] (want [2])`)
  if (!ok) rc = 1
}

// D (Controls): normal single pop, redirect from target, hanging-guard fallback timer, untagged pop cancels prior wait
{
  const h1 = buildHarness()
  h1.firePop('/channel/alerts', 2)
  h1.fireAfter('/channel/alerts', undefined)
  const ok1 = h1.applied.length === 1 && h1.applied[0] === 2

  const h2 = buildHarness()
  h2.firePop('/m/123', 3)
  h2.fireAfter('/channel/alerts?topic=t', undefined, '/m/123')
  const ok2 = h2.applied.length === 1 && h2.applied[0] === 3

  const h3 = buildHarness()
  h3.firePop('/channel/alerts', 2)
  await sleep(80)
  const ok3 = h3.applied.length === 1 && h3.applied[0] === 2

  const h4 = buildHarness()
  h4.firePop('/channel/alerts', 2)
  h4.firePop('/channel/lobby', null)
  h4.fireAfter('/channel/alerts', undefined)
  const ok4 = h4.applied.length === 0

  console.log(`rc01 D(controls): normal=${ok1} redirect=${ok2} fallback=${ok3} untagged_cancels=${ok4}`)
  if (!(ok1 && ok2 && ok3 && ok4)) rc = 1
}

// E (W2): mobile-back-wait.test.mjs records selectChannel calls and asserts no stale #lobby read
{
  const esrc = fs.readFileSync(e2e_testPath, 'utf8')
  const records = /\.push\s*\(\s*a\[0\]/.test(esrc) || /selectChannel[\s\S]{0,400}push\s*\(/.test(esrc)
  const asserts = /__selectChannels|channelCalls|selectChannels/.test(esrc) && /alerts/.test(esrc)
  const ok = records && asserts
  console.log(`rc01 E(w2_e2e_selectChannel_assert): records=${records} asserts=${asserts} (want true true)`)
  if (!ok) rc = 1
}

process.exit(rc)
NODE
r_node=$?

# F: existing mobile-stack unit suite stays green
node --test "$utst" >"$tmp/utst.out" 2>&1; r_unit=$?
echo "rc01 F(unit_suite): rc=$r_unit (want 0) [$(grep -E '^ℹ (tests|pass|fail) ' "$tmp/utst.out" | paste -sd' ')]"

rc=0
[ "$r_node" = 0 ] && [ "$r_unit" = 0 ] || rc=1
echo "rc01 exit $rc"
exit "$rc"
```

Output on `ecc05e480` (sat, `23:09Z`):

| run | output |
|---|---|
| `bash rc01-b52.sh ecc05e480` | `rc01 sites: listenPopState=1 mobilePopWaitsRoute=1 plantSlow=1` / `rc01 A(two_pops_nav1_cancelled): premature=1 (want 0) final=[2] (want [2])` / `rc01 B(aborted_guard): immediate=1 (want 0) after_timer=1 (want 0)` / `rc01 C(unrelated_route_first): premature=1 (want 0) final=[2] (want [2])` / `rc01 D(controls): normal=true redirect=true fallback=true untagged_cancels=false` / `rc01 E(w2_e2e_selectChannel_assert): records=false asserts=false (want true true)` / `rc01 F(unit_suite): rc=0 (want 0)` / `rc01 exit 1` |
| `bash rc01-b52.sh ecc05e480 fix-shape` | `rc01 sites: listenPopState=1 mobilePopWaitsRoute=1 plantSlow=1` / `rc01 fix-shape: mobilePopAfterNav + listenPopState route/failure guard + mobile-back-wait selectChannel assertion` / `rc01 A(two_pops_nav1_cancelled): premature=0 (want 0) final=[2] (want [2])` / `rc01 B(aborted_guard): immediate=0 (want 0) after_timer=0 (want 0)` / `rc01 C(unrelated_route_first): premature=0 (want 0) final=[2] (want [2])` / `rc01 D(controls): normal=true redirect=true fallback=true untagged_cancels=true` / `rc01 E(w2_e2e_selectChannel_assert): records=true asserts=true (want true true)` / `rc01 F(unit_suite): rc=0 (want 0)` / `rc01 exit 0` |

### 4.2 `rc02-b52.sh` (b52-02, review-go C4), sha256 first 12 hex `1aad8be673cb`, 11166 B

Run from any checkout: `bash rc02-b52.sh ecc05e480` (exit 1), then `bash rc02-b52.sh ecc05e480 fix-shape` (exit 0). Under 5 s each. Self-contained (zero box paths).

```bash
#!/usr/bin/env bash
# rc02-b52.sh <sha> [fix-shape]: b52-02 red control (c-001 ruling ee10c09a).
# On <sha>'s tree, do_spl_review_go (csi-spl-orc/src/bash/run/spl-review-go.func.sh)
# sends `GO <sha>` whenever `do_spl_review_line_check` exits 0, without
# comparing the author brief's required tests (`*.tst.sh`, `test-*.sh`,
# `*.test.mjs`, `rc[0-9][0-9]*.sh`, `do_check_pre_push`, unconditional
# `PRE_PUSH_TIER=full`, `shellcheck`) against the review line's `ran:` (C4,
# rounds-rulebook.md:126). Evidence n=2 on 2026-11-26: GO d8bfb277 on a-099
# (missing `do_check_pre_push`) and GO 245ec817 on a-113 (missing
# `do_check_pre_push` and `PRE_PUSH_TIER=full`), plus b49-01/r05-02.
# Extracts csi-spl-orc from <sha> into mktemp -d. Self-contained (no box paths).
set -uo pipefail
sha="${1:?usage: rc02-b52.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" \
  csi-spl-orc/lib/bash/funcs \
  csi-spl-orc/src/bash/run/spl-review-go.func.sh \
  csi-spl-orc/src/bash/run/spl-review-line-check.func.sh \
  csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh \
  csi-spl-orc/src/bash/run/spl-review-go-install-cron.func.sh \
  csi-spl-orc/src/bash/features/spawn-agents/lib \
  csi-spl-orc/src/bash/tests/spl-review-go.tst.sh | tar -x -C "$tmp"

fn="$tmp/csi-spl-orc/src/bash/run/spl-review-go.func.sh"
a=$(grep -c '^_spl_review_go_one()' "$fn")
b=$(grep -c '^_spl_review_go_owner_go()' "$fn")
c=$(grep -c '^_spl_review_go_instr()' "$fn")
echo "rc02 sites: one=$a owner_go=$b instr=$c"
[ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] || { echo "rc02 sites moved"; exit 2; }

if [ "${2:-}" = fix-shape ]; then
  python3 - "$fn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
anchor = '  (( rc == 0 )) || { _spl_review_go_hold "$@" 8 "review line check failed (rc $rc): $(tail -n2 <<<"$why" | paste -sd\' \')"; return 8; }\n'
hook = anchor + '''  if [[ "$why" != *"DOCS-ONLY "* ]]; then
    why="$(_spl_review_go_c4_missing "$abrief" "$line")" ||
      { _spl_review_go_hold "$@" 12 "review ran: misses brief-named test(s) (C4): $why"; return 12; }
  fi
'''
helper = r'''
# _spl_review_go_c4_missing <author brief> <review line>: rc 0 when every test
# the author brief's instruction text requires (*.tst.sh, test-*.sh excl
# *.inc.sh, *.test.mjs, rc[0-9][0-9]*.sh, exact do_check_pre_push, unconditional
# PRE_PUSH_TIER=full, shellcheck) is named in the line's ran:; else prints the
# missing comma-separated list on stdout and returns 1 (b52-02, rulebook C4).
_spl_review_go_c4_missing() {
  python3 - "$1" "$2" <<'EOF_PY'
import re, sys
brief_path, line = sys.argv[1:3]
if " ran: " not in line:
    sys.exit(0)
ran = line.split(" ran: ", 1)[1].split(" | read: ", 1)[0].split(" | log: ", 1)[0]
try:
    lines = open(brief_path, encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    sys.exit(0)
NARR = re.compile(r"(?i)^(why|what happened|symptoms?|evidence|background|history|trace|observed|measured|at (?:queue|brief) time|lane-map clearance)\b")
NEVER = re.compile(r"(?i)^(never|don['\u2019]t|do not|out of scope|files you must not touch|must not touch|owned elsewhere)\b")
out, skip, fence = [], 0, False
FENCE_RX = re.compile(r"\s*(?:" + "`" * 3 + r"|~~~)")
for l in lines:
    if FENCE_RX.match(l):
        fence = not fence
        continue
    h = None if fence else re.match(r"(#{1,6})\s+(.*)", l)
    if h:
        if skip and len(h.group(1)) > skip:
            continue
        t = h.group(2).strip()
        skip = len(h.group(1)) if NARR.match(t) or NEVER.match(t) else 0
        if skip:
            continue
    elif fence or skip or re.match(r"\s*>", l):
        continue
    cleaned = re.sub(r"(?i)\b(?:not|never|except|excluding|stay off)\s+`?[A-Za-z0-9._/-]+\.(?:tst\.sh|test\.mjs|sh)`?", "", l)
    out.append(cleaned)
txt = "\n".join(out)
req = []
for m in re.findall(r"(?<![\w/.-])(?:[A-Za-z0-9._-]+/)*([A-Za-z0-9._-]+\.(?:tst\.sh|test\.mjs)|test-[A-Za-z0-9._-]+\.sh|rc[0-9]{2}[A-Za-z0-9._-]*\.sh)(?![\w.-])", txt):
    if not m.endswith(".inc.sh") and m not in req:
        req.append(m)
if re.search(r"(?<![\w])do_check_pre_push(?![\w])", txt):
    req.append("do_check_pre_push")
for l in out:
    if "PRE_PUSH_TIER=full" in l and not re.search(r"(?i)\b(?:if|when|unless)\b.*PRE_PUSH_TIER=full", l):
        req.append("PRE_PUSH_TIER=full")
        break
if re.search(r"(?<![\w.-])shellcheck(?![\w.-])", txt):
    req.append("shellcheck")
miss = []
for item in req:
    if item == "do_check_pre_push":
        ok = bool(re.search(r"(?<![\w])do_check_pre_push(?![\w])", ran))
    elif item == "PRE_PUSH_TIER=full":
        ok = "PRE_PUSH_TIER=full" in ran
    elif item == "shellcheck":
        ok = bool(re.search(r"(?<![\w.-])shellcheck(?![\w.-])", ran))
    else:
        ok = bool(re.search(r"(?<![\w.-])" + re.escape(item) + r"(?![\w.-])", ran))
    if not ok:
        miss.append(item)
if miss:
    print(", ".join(miss))
    sys.exit(1)
EOF_PY
}
'''
assert s.count(anchor) == 1, f"anchor count={s.count(anchor)}"
s = s.replace(anchor, hook, 1)
fn_anchor = "# _spl_review_go_tip <branch>:"
assert s.count(fn_anchor) == 1, f"fn_anchor count={s.count(fn_anchor)}"
s = s.replace(fn_anchor, helper + "\n" + fn_anchor, 1)
open(p, "w").write(s)
PY
  echo "rc02 fix-shape: _spl_review_go_c4_missing wired in _spl_review_go_one after do_spl_review_line_check (rc 12)"
fi

# Build a minimal throwaway git repo + spool root and drive do_spl_review_go
mkdir -p "$tmp/repo" "$tmp/origin.git" "$tmp/spool/dispatch/briefs" "$tmp/spool/c-002/archive" "$tmp/spool/c-222/lifetime" "$tmp/spool/a-111/lifetime" "$tmp/bin"
git init -q --bare "$tmp/origin.git"
git -C "$tmp/repo" init -q -b master
git -C "$tmp/repo" config user.name "Test"
git -C "$tmp/repo" config user.email "test@example.com"
git -C "$tmp/repo" remote add origin "$tmp/origin.git"
echo hi >"$tmp/repo/a.sh"
git -C "$tmp/repo" add a.sh && git -C "$tmp/repo" commit -q -m "base"
git -C "$tmp/repo" push -q origin master
git -C "$tmp/repo" checkout -q -b review/c-222-test
echo fix >>"$tmp/repo/a.sh"
git -C "$tmp/repo" add a.sh && git -C "$tmp/repo" commit -q -m "fix"
git -C "$tmp/repo" push -q origin review/c-222-test
SHA="$(git -C "$tmp/repo" rev-parse HEAD)"

cat >"$tmp/spool/dispatch/lease.conf" <<'EOF'
LEASE_MACHINE=boxa
LEASE_ORCH=c-001
EOF
cat >"$tmp/bin/fake-send" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/sends.log"
EOF
chmod +x "$tmp/bin/fake-send"

# Reviewer brief assigning c-222 on review/c-222-test
cat >"$tmp/spool/a-111/lifetime/brief.md" <<EOF
# R7 reviewer
| author | review branch | sha | task |
|---|---|---|---|
| c-222@boxa | \`review/c-222-test\` | ${SHA:0:9} | dispatch-c4 |
EOF
# Reviewer session log recording all test commands so do_spl_review_line_check exits 0
cat >"$tmp/a-111.jsonl" <<'EOF'
{"type":"tool_use","name":"run_command","args":{"CommandLine":"node --test foo.test.mjs; bash spl-spawn-queue.tst.sh; bash foo.tst.sh; bash bar.tst.sh; bash own.tst.sh; bash rc01-b52.sh; shellcheck -S warning a.sh; PRE_PUSH_TIER=full ./run -a do_check_pre_push; ./run -a do_check_pre_push_lint; ./run -a do_check_dist_hygiene"}}
EOF

run_case() {
  local lbl="$1" want_go="$2" want_tok="$3" abrief_txt="$4" ran_txt="$5" mid="$6"
  rm -f "$tmp/sends.log" "$tmp/spool/dispatch/automation.log"
  printf '%s\n' "$abrief_txt" >"$tmp/spool/c-222/lifetime/brief.md"
  local mf="$tmp/spool/c-002/archive/20261126T120000Z--a-111--${mid}.json"
  local rline="review: a-111@boxa agy PASS $SHA ran: $ran_txt | read: ok | log: a-111@boxa:$tmp/a-111.jsonl"
  python3 - "$mf" "$mid" "$rline" <<'PY'
import json, sys
json.dump({"v":1,"msg_id":sys.argv[2],"task_id":"dispatch-c4","from":"a-111@boxa","to":"c-002","kind":"result","ts":"2026-11-26T12:00:00Z","body":sys.argv[3]}, open(sys.argv[1],"w"))
PY
  local out r gos=0 tok_ok=1
  out="$(env SPOOL_ROOT="$tmp/spool" LEASE_MACHINE=boxa REVIEW_LINE_BOX=boxa REVIEW_GO_REPO="$tmp/repo" \
    REVIEW_GO_SEND="$tmp/bin/fake-send" REVIEW_GO_MSG="$mf" REVIEW_GO_NOW="2026-11-26T12:05:00Z" DRY_RUN=0 \
    bash -c '
      set -uo pipefail
      do_log() { echo "$*"; }
      do_require_bin() { command -v "$1" >/dev/null; }
      source "$1"; source "$2"; source "$3"
      do_spl_dispatch_lease() { echo "c-002@boxa 10"; }
      do_spl_review_go' _ \
      "$tmp/csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh" \
      "$tmp/csi-spl-orc/src/bash/run/spl-review-line-check.func.sh" \
      "$fn" 2>&1)"; r=$?
  grep -q -- "--to c-222" "$tmp/sends.log" 2>/dev/null && gos=1
  if [ -n "$want_tok" ]; then
    grep -qF "$want_tok" "$tmp/sends.log" 2>/dev/null || grep -qF "$want_tok" <<<"$out" || tok_ok=0
  fi
  echo "rc02 $lbl: rc=$r gos=$gos (want_go=$want_go) tok_ok=$tok_ok"
  if [ "$want_go" = 1 ]; then
    [ "$r" = 0 ] && [ "$gos" = 1 ] || rc=1
  else
    [ "$r" != 0 ] && [ "$gos" = 0 ] && [ "$tok_ok" = 1 ] || rc=1
  fi
}

rc=0
# RED 1 (Evidence 1: a-099 loops part 1 — ran: has do_check_pre_push_lint, lacks do_check_pre_push)
run_case "red_a099_missing_pre_push" 0 "do_check_pre_push" \
  $'## Do\n1. Run `node --test foo.test.mjs` and `cd csi-spl-iac && ./run -a do_check_pre_push`.' \
  "node --test foo.test.mjs ; do_check_pre_push_lint ; do_check_dist_hygiene" \
  "11111111-1111-4111-8111-111111111111"

# RED 2 (Evidence 2: a-113 s153 Q3 — ran: lacks PRE_PUSH_TIER=full)
run_case "red_a113_missing_full_tier" 0 "PRE_PUSH_TIER=full" \
  $'## Do\n1. `bash spl-spawn-queue.tst.sh`.\n2. `cd csi-spl-iac && ./run -a do_check_pre_push`; this row touches the store/hub: run it with PRE_PUSH_TIER=full.' \
  "bash spl-spawn-queue.tst.sh; cd csi-spl-iac && ./run -a do_check_pre_push" \
  "22222222-2222-4222-8222-222222222222"

# RED 3 (Evidence 3: round row — ran: omits bar.tst.sh and rc01-b52.sh)
run_case "red_round_missing_tst_and_rc" 0 "bar.tst.sh" \
  $'## Do\n1. Run `bash rc01-b52.sh <sha>`, `foo.tst.sh`, `bar.tst.sh`, `shellcheck -S warning a.sh`, and `cd csi-spl-iac && ./run -a do_check_pre_push`.' \
  "bash foo.tst.sh; shellcheck -S warning a.sh; cd csi-spl-iac && ./run -a do_check_pre_push" \
  "33333333-3333-4333-8333-333333333333"

# CTRL 1: all required items present in ran: -> GO
run_case "ctrl_all_present" 1 "" \
  $'## Do\n1. Run `bash rc01-b52.sh <sha>`, `foo.tst.sh`, `bar.tst.sh`, `shellcheck -S warning a.sh`, and `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.' \
  "bash rc01-b52.sh; bash foo.tst.sh; bash bar.tst.sh; shellcheck -S warning a.sh; PRE_PUSH_TIER=full ./run -a do_check_pre_push" \
  "44444444-4444-4444-8444-444444444444"

# CTRL 2: NOT / Never / Files you must NOT touch / conditional PRE_PUSH_TIER=full -> GO
run_case "ctrl_exclusions_ignored" 1 "" \
  $'## Do\n1. Edit a.sh, NOT `bar.tst.sh`. Run `bash own.tst.sh` and `do_check_pre_push`.\n2. If change 3 needs a migration, run `PRE_PUSH_TIER=full`.\n## Files you must NOT touch\n`foo.tst.sh`\n## Never\nNever edit `rc01-b52.sh`.' \
  "bash own.tst.sh; ./run -a do_check_pre_push" \
  "55555555-5555-4555-8555-555555555555"

echo "rc02 exit $rc"
exit "$rc"
```

Output on `ecc05e480` (sat, `23:18Z`):

| run | output |
|---|---|
| `bash rc02-b52.sh ecc05e480` | `rc02 sites: one=1 owner_go=1 instr=1` / `rc02 red_a099_missing_pre_push: rc=0 gos=1 (want_go=0) tok_ok=0` / `rc02 red_a113_missing_full_tier: rc=0 gos=1 (want_go=0) tok_ok=0` / `rc02 red_round_missing_tst_and_rc: rc=0 gos=1 (want_go=0) tok_ok=0` / `rc02 ctrl_all_present: rc=0 gos=1 (want_go=1) tok_ok=1` / `rc02 ctrl_exclusions_ignored: rc=0 gos=1 (want_go=1) tok_ok=1` / `rc02 exit 1` |
| `bash rc02-b52.sh ecc05e480 fix-shape` | `rc02 sites: one=1 owner_go=1 instr=1` / `rc02 fix-shape: _spl_review_go_c4_missing wired in _spl_review_go_one after do_spl_review_line_check (rc 12)` / `rc02 red_a099_missing_pre_push: rc=12 gos=0 (want_go=0) tok_ok=1` / `rc02 red_a113_missing_full_tier: rc=12 gos=0 (want_go=0) tok_ok=1` / `rc02 red_round_missing_tst_and_rc: rc=12 gos=0 (want_go=0) tok_ok=1` / `rc02 ctrl_all_present: rc=0 gos=1 (want_go=1) tok_ok=1` / `rc02 ctrl_exclusions_ignored: rc=0 gos=1 (want_go=1) tok_ok=1` / `rc02 exit 0` |

### 4.3 `rc03-b52.sh` (b52-03, spawn-remote atomic read), sha256 first 12 hex `8d2ec920278d`, 12260 B

Run from any checkout: `bash rc03-b52.sh ecc05e480` (exit 1), then `bash rc03-b52.sh ecc05e480 fix-shape` (exit 0). Under 4 s each. Self-contained (zero box paths).

```bash
#!/usr/bin/env bash
# rc03-b52.sh <sha> [fix-shape]: b52-03 red control (c-001 e1db57c6 / c-001@<box2> 42ac9aad).
# On <sha>'s tree, spawn-remote.sh handle() (:274-282), handle_issue() (:484-491),
# and note_cancel() (:682-691) read the inbox JSON file with separate jq / body_of
# calls and append msg_id to $STATE/seen before reading .from / .task_id / .body.
# If the agent acks the message (moving inbox -> archive) between the first jq and
# the next read (live hit 2026-11-26T15:19:02Z on 82416aaf, serve.log:3728),
# handle() sees task="" and body="" -> `REJECTED ... bad kind ''` while $msg is
# already in $STATE/seen, and reply() calls spool-send with --task "" which mints
# a brand-new task id. Same race in note_cancel() drops the cancel permanently.
# Extracts spawn-agents from <sha> into mktemp -d. Self-contained (no box paths).
set -uo pipefail
sha="${1:?usage: rc03-b52.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" \
  csi-spl-orc/lib/bash/funcs \
  csi-spl-orc/src/bash/features/spawn-agents/lib \
  csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh | tar -x -C "$tmp"

sr="$tmp/csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh"
a=$(grep -c '^handle()' "$sr")
b=$(grep -c '^handle_issue()' "$sr")
c=$(grep -c '^note_cancel()' "$sr")
d=$(grep -c '^reply()' "$sr")
echo "rc03 sites: handle=$a handle_issue=$b note_cancel=$c reply=$d"
[ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] && [ "$d" = 1 ] || { echo "rc03 sites moved"; exit 2; }

if [ "${2:-}" = fix-shape ]; then
  python3 - "$sr" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()

# 1. Guard reply() against empty task
old_rep = '''reply() {  # INBOX_ID TO TASK STATUS LINES...
  local me="$1" to="$2" task="$3" st="$4" body rc; shift 4
  body="$(printf '%s\\n' "$MAGIC_REP" "status: $st" "$@")"'''
new_rep = '''reply() {  # INBOX_ID TO TASK STATUS LINES...
  local me="$1" to="$2" task="$3" st="$4" body rc; shift 4
  [ -n "$task" ] || { say "WARN reply to $to skipped: empty task"; return 0; }
  body="$(printf '%s\\n' "$MAGIC_REP" "status: $st" "$@")"'''
assert s.count(old_rep) == 1, f"reply count={s.count(old_rep)}"
s = s.replace(old_rep, new_rep, 1)

# 2. Add atomic single-read helper with archive/ fallback; parse once before seen
helper = '''# Read one spool message JSON atomically into a snapshot (falling back to
# archive/ if acked mid-tick) and unpack msg_id, from, task_id, body in one jq
# pass (b52-03). rc 1 when unreadable (not marked seen; next tick retries).
read_msg_fields() {  # INBOX_ID FILE -> sets _M_MSG _M_FROM _M_TASK _M_BODY
  local me="$1" f="$2" raw arch hdr
  raw="$(cat -- "$f" 2>/dev/null)" || true
  if [ -z "$raw" ]; then
    arch="$SPOOL_ROOT/$me/archive/${f##*/}"
    raw="$(cat -- "$arch" 2>/dev/null)" || true
  fi
  [ -n "$raw" ] || return 1
  hdr="$(jq -r '[.msg_id // "", .from // "", .task_id // ""] | @tsv' <<<"$raw" 2>/dev/null)" || return 1
  IFS=$'\\t' read -r _M_MSG _M_FROM _M_TASK <<<"$hdr"
  _M_BODY="$(jq -r '.body // ""' <<<"$raw" 2>/dev/null | strip_from_agent)" || return 1
  [[ "$_M_MSG" =~ ^[0-9A-Za-z-]{8,64}$ ]] || return 1
}

'''
old_h = '''handle() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from task body holder kind title workdir slug brief out rc id pane reason requester expires retry
  local topic scope files started warn lane
  msg="$(jq -r '.msg_id // ""' "$f" 2>/dev/null)"
  [[ "$msg" =~ ^[0-9A-Za-z-]{8,64}$ ]] || return 0
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"
  from="$(jq -r '.from // ""' "$f")"; task="$(jq -r '.task_id // ""' "$f")"
  body="$(body_of "$f" | strip_from_agent)"'''
new_h = helper + '''handle() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from task body holder kind title workdir slug brief out rc id pane reason requester expires retry
  local topic scope files started warn lane _M_MSG="" _M_FROM="" _M_TASK="" _M_BODY=""
  read_msg_fields "$me" "$f" || return 0
  msg="$_M_MSG" from="$_M_FROM" task="$_M_TASK" body="$_M_BODY"
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"'''
assert s.count(old_h) == 1, f"handle count={s.count(old_h)}"
s = s.replace(old_h, new_h, 1)

old_hi = '''handle_issue() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from task body id key topic expires brief t row op token
  msg="$(jq -r '.msg_id // ""' "$f" 2>/dev/null)"
  [[ "$msg" =~ ^[0-9A-Za-z-]{8,64}$ ]] || return 0
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"
  from="$(jq -r '.from // ""' "$f")"; task="$(jq -r '.task_id // ""' "$f")"
  body="$(body_of "$f" | strip_from_agent)"'''
new_hi = '''handle_issue() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from task body id key topic expires brief t row op token _M_MSG="" _M_FROM="" _M_TASK="" _M_BODY=""
  read_msg_fields "$me" "$f" || return 0
  msg="$_M_MSG" from="$_M_FROM" task="$_M_TASK" body="$_M_BODY"
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"'''
assert s.count(old_hi) == 1, f"handle_issue count={s.count(old_hi)}"
s = s.replace(old_hi, new_hi, 1)

old_nc = '''note_cancel() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from body task holder
  msg="$(jq -r '.msg_id // ""' "$f" 2>/dev/null)"
  [[ "$msg" =~ ^[0-9A-Za-z-]{8,64}$ ]] || return 0
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"
  from="$(jq -r '.from // ""' "$f" 2>/dev/null)"
  holder="$(orch_holder)"
  body="$(body_of "$f" | strip_from_agent)"'''
new_nc = '''note_cancel() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from body task holder _M_MSG="" _M_FROM="" _M_TASK="" _M_BODY=""
  read_msg_fields "$me" "$f" || return 0
  msg="$_M_MSG" from="$_M_FROM" body="$_M_BODY"
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"
  holder="$(orch_holder)"'''
assert s.count(old_nc) == 1, f"note_cancel count={s.count(old_nc)}"
s = s.replace(old_nc, new_nc, 1)

open(p, "w").write(s)
PY
  echo "rc03 fix-shape: read_msg_fields single atomic read with archive/ fallback + reply empty-task guard"
fi

# Sandbox: machine A (receiver home), machine B (requester sat)
A="$tmp/home" B="$tmp/sat" WORK="$tmp/work"
mkdir -p "$A/c-001/inbox" "$A/c-001/archive" "$A/dispatch" "$B/c-001/inbox" "$WORK" "$tmp/bin" "$tmp/racebin"
printf 'SPOOL_DESK_BOX=home\n' >"$A/box.env"
printf 'LEASE_ORCH=c-001\n' >"$A/dispatch/lease.conf"
printf 'c-001@sat 1790995313\n' >"$A/dispatch/lease.orch"

# Stub spool-send.sh in $tmp/csi-spl-orc/.../scripts so reply() writes to $B/c-001/inbox
cat >"$tmp/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" <<EOF
#!/usr/bin/env bash
task="" kind="" body=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --task) task="\$2"; shift 2 ;;
    --kind) kind="\$2"; shift 2 ;;
    --body) body="\$2"; shift 2 ;;
    --no-ask|--no-poke) shift ;;
    *) shift 2 ;;
  esac
done
[ -n "\$task" ] || task="MINTED-RANDOM-TASK"
printf '%s\t%s\n' "\$kind" "\$task" >>"$tmp/replies.tsv"
EOF
cat >"$tmp/spawn-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/spawn.calls"
echo "c-009 %42"
EOF
REAL_JQ="$(command -v jq)"
# 1-shot jq shim: when jq is called with a .msg_id query on a file inside
# $A/c-001/inbox/, after running the real jq call it simulates `spool recv --ack`
# moving that file into archive/ right between the msg_id read and the next read
# (the exact 2026-11-26T15:19:02Z race on 82416aaf).
cat >"$tmp/racebin/jq" <<EOF
#!/usr/bin/env bash
"$REAL_JQ" "\$@"; r=\$?
has_mid=0
for a in "\$@"; do
  [[ "\$a" == *".msg_id"* ]] && has_mid=1
done
if [ "\$has_mid" = 1 ]; then
  for a in "\$@"; do
    if [[ "\$a" == "$A/c-001/inbox/"*.json && -f "\$a" ]]; then
      mv -- "\$a" "$A/c-001/archive/\${a##*/}" 2>/dev/null || true
    fi
  done
fi
exit \$r
EOF
chmod +x "$tmp/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" "$tmp/spawn-stub" "$tmp/racebin/jq"

cnt() { local n=0; [ -f "$1" ] && n=$(grep -c -- "$2" "$1" 2>/dev/null || true); echo "${n:-0}"; }
rc=0

# Source spawn-remote.sh functions from the scripts dir so ../lib/*.inc.sh resolve
# (serve() line 701 prepends /usr/bin to PATH, so we drive handle/note_cancel/reply directly)
sr_lib="$(dirname "$sr")/sr_lib.sh"
sed '/^case "\${1:-}" in$/,$d' "$sr" >"$sr_lib"

# Case A (RED 1): handle() ack-race (inbox -> archive right after .msg_id read)
TASK_A="f41bc755-1111-4111-8111-111111111111"
MSG_A="82416aaf-2b2b-454a-955c-728677879f58"
python3 - "$A/c-001/inbox/$MSG_A.json" "$MSG_A" "$TASK_A" "$WORK" <<'PY'
import json, sys
body = f"spawn-request v1\nkind: claude\ntitle: auto\nworkdir: {sys.argv[4]}\nslug: b52-panel\n---\n# brief\n"
json.dump({"v":1,"msg_id":sys.argv[2],"task_id":sys.argv[3],"from":"c-001@sat","to":"c-001","kind":"task","ts":"2026-11-26T15:19:02Z","body":body}, open(sys.argv[1],"w"))
PY
rm -f "$tmp/replies.tsv" "$tmp/spawn.calls" "$A/spawn-remote/serve.log" "$A/spawn-remote/seen"
env SPOOL_ROOT="$A" SPAWN_REMOTE_WINDOW_CMD="$tmp/spawn-stub" PATH="$tmp/racebin:$PATH" \
  bash -c 'source "$1"; mkdir -p "$STATE/briefs"; handle c-001 "$2"' _ "$sr_lib" "$A/c-001/inbox/$MSG_A.json" >"$tmp/a.out" 2>&1 || true
callsA=$([ -f "$tmp/spawn.calls" ] && wc -l <"$tmp/spawn.calls" || echo 0)
bad_taskA=$(cnt "$tmp/replies.tsv" "MINTED-RANDOM-TASK")
good_taskA=$(cnt "$tmp/replies.tsv" "$TASK_A")
rejA=$(cnt "$A/spawn-remote/serve.log" "REJECTED")
echo "rc03 A(handle_ack_race): calls=$callsA (want 1) rej=$rejA (want 0) good_task=$good_taskA (want 1) minted=$bad_taskA (want 0)"
[ "$callsA" = 1 ] && [ "$rejA" = 0 ] && [ "$good_taskA" = 1 ] && [ "$bad_taskA" = 0 ] || rc=1

# Case A2 (control): handle() when file already moved to archive/ before handle() starts
TASK_A2="f41bc755-2222-4222-8222-222222222222"
MSG_A2="82416aaf-2222-4222-8222-222222222222"
python3 - "$A/c-001/archive/$MSG_A2.json" "$MSG_A2" "$TASK_A2" "$WORK" <<'PY'
import json, sys
body = f"spawn-request v1\nkind: claude\ntitle: auto\nworkdir: {sys.argv[4]}\nslug: b52-panel-2\n---\n# brief\n"
json.dump({"v":1,"msg_id":sys.argv[2],"task_id":sys.argv[3],"from":"c-001@sat","to":"c-001","kind":"task","ts":"2026-11-26T15:19:02Z","body":body}, open(sys.argv[1],"w"))
PY
rm -f "$tmp/replies.tsv" "$tmp/spawn.calls" "$A/spawn-remote/serve.log" "$A/spawn-remote/seen"
env SPOOL_ROOT="$A" SPAWN_REMOTE_WINDOW_CMD="$tmp/spawn-stub" \
  bash -c 'source "$1"; mkdir -p "$STATE/briefs"; handle c-001 "$2"' _ "$sr_lib" "$A/c-001/inbox/$MSG_A2.json" >"$tmp/a2.out" 2>&1 || true
callsA2=$([ -f "$tmp/spawn.calls" ] && wc -l <"$tmp/spawn.calls" || echo 0)
good_taskA2=$(cnt "$tmp/replies.tsv" "$TASK_A2")
echo "rc03 A2(handle_archive_fallback): calls=$callsA2 (want 1) good_task=$good_taskA2 (want 1)"
[ "$callsA2" = 1 ] && [ "$good_taskA2" = 1 ] || rc=1

# Case B (RED 2): note_cancel() ack-race -> cancel MUST still record task in $STATE/cancelled
TASK_B="c41bc755-3333-4333-8333-333333333333"
MSG_B="c2416aaf-3333-4333-8333-333333333333"
python3 - "$A/c-001/inbox/$MSG_B.json" "$MSG_B" "$TASK_B" <<'PY'
import json, sys
body = f"spawn-cancel v1\ntask: {sys.argv[3]}\n---\n"
json.dump({"v":1,"msg_id":sys.argv[2],"task_id":sys.argv[3],"from":"c-001@sat","to":"c-001","kind":"note","ts":"2026-11-26T15:19:03Z","body":body}, open(sys.argv[1],"w"))
PY
rm -f "$A/spawn-remote/cancelled" "$A/spawn-remote/seen"
env SPOOL_ROOT="$A" PATH="$tmp/racebin:$PATH" \
  bash -c 'source "$1"; mkdir -p "$STATE/briefs"; note_cancel c-001 "$2"' _ "$sr_lib" "$A/c-001/inbox/$MSG_B.json" >"$tmp/b.out" 2>&1 || true
gotB=$(cnt "$A/spawn-remote/cancelled" "$TASK_B")
echo "rc03 B(note_cancel_ack_race): cancelled_recorded=$gotB (want 1)"
[ "$gotB" = 1 ] || rc=1

# Case C (RED 3): reply() refuses empty task (never mints random task id)
rm -f "$tmp/replies.tsv"
outC="$(env SPOOL_ROOT="$A" bash -c 'source "$1"; reply c-001 c-001@sat "" refused "reason: test"' _ "$sr_lib" 2>&1)"
sentC=$([ -f "$tmp/replies.tsv" ] && wc -l <"$tmp/replies.tsv" || echo 0)
echo "rc03 C(reply_empty_task): sent=$sentC (want 0) [$outC]"
[ "$sentC" = 0 ] || rc=1

echo "rc03 exit $rc"
exit "$rc"
```

Output on `ecc05e480` (sat, `23:12Z`):

| run | output |
|---|---|
| `bash rc03-b52.sh ecc05e480` | `rc03 sites: handle=1 handle_issue=1 note_cancel=1 reply=1` / `rc03 A(handle_ack_race): calls=0 (want 1) rej=0 (want 0) good_task=0 (want 1) minted=0 (want 0)` / `rc03 A2(handle_archive_fallback): calls=0 (want 1) good_task=0 (want 1)` / `rc03 B(note_cancel_ack_race): cancelled_recorded=0 (want 1)` / `rc03 C(reply_empty_task): sent=1 (want 0) []` / `rc03 exit 1` |
| `bash rc03-b52.sh ecc05e480 fix-shape` | `rc03 sites: handle=1 handle_issue=1 note_cancel=1 reply=1` / `rc03 fix-shape: read_msg_fields single atomic read with archive/ fallback + reply empty-task guard` / `rc03 A(handle_ack_race): calls=1 (want 1) rej=0 (want 0) good_task=1 (want 1) minted=0 (want 0)` / `rc03 A2(handle_archive_fallback): calls=1 (want 1) good_task=1 (want 1)` / `rc03 B(note_cancel_ack_race): cancelled_recorded=1 (want 1)` / `rc03 C(reply_empty_task): sent=0 (want 0) [spawn-remote: WARN reply to c-001@sat skipped: empty task]` / `rc03 exit 0` |

---

## 5. Rows

| # | id | practice | sites (file:line on `ecc05e480`) | evidence | red control (fails on `ecc05e480`) | test column (R2; R7 must run EVERY entry in `ran:`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b52-01-wui-popstate-land-guard-spl5254` | Phone Back off level 1 applies its level only when its own route resolves (ignoring cancelled/unrelated `afterEach` and cancelling on aborted guard), and `mobile-back-wait.test.mjs` asserts zero stale `#lobby` reads | `csi-spl-wui/src/utils/mobile-stack.mjs:147-149`; `csi-spl-wui/src/composables/useMobileStack.ts:377-398`; `csi-spl-wui/tests/unit/mobile-stack.test.mjs:207-218`; `csi-spl-wui/tests/e2e/mobile-back-wait.test.mjs:91-101,180-194` | Owner order HUM-10 t1 `3fbb2b1b` msg `452c25df` poll `8c3f32b4` A; SPL-5254 (`onhold`); SPL-5232 (`d70f6c5fb`) R7 `c-531@sat` (`4fe0af88`) W2 + W3; section 4.1 | `bash rc01-b52.sh ecc05e480` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` (plus Chrome W2 red control on scratch bundle with `mobilePopWaitsRoute` returning `false`) | `cd csi-spl-wui && pnpm run typecheck`; `node --test csi-spl-wui/tests/unit/mobile-stack.test.mjs`; `node --test csi-spl-wui/tests/unit/cleancode.test.mjs`; `bash rc01-b52.sh <fix sha>` -> exit 0 (without `fix-shape`); `cd csi-spl-iac && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` (on `ecc05e480` selects 10 files: `mobile-back-wait.test.mjs`, `release-notes.test.mjs`, `top-bar-mobile.test.mjs`, `calendar-phone-peek.test.mjs`, `issues-crud-modal.test.mjs`, `workspace-doctree.test.mjs`, `users-admin.test.mjs`, `version-v-prefix.test.mjs`, `tenant-switcher.test.mjs`, `thread-jump-edit.test.mjs` — run all selected files against generated mock bundle); `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.1: add `mobilePopAfterNav` in `mobile-stack.mjs`; add `popFailureKind`, early `++popSeq`, and target/failure check in `useMobileStack.ts` `listenPopState` (keep 3 s fallback); add unit cases in `mobile-stack.test.mjs`; record/assert `selectChannel` calls `['alerts']` in `mobile-back-wait.test.mjs`; never touch `stores/channel.ts`; cite **SPL-5254**; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` claude `23:01Z`: sat 107% / 92% weekly pick, `<box2>` 205% / 92% weekly) | claude (WUI never mistral) | agy (preferred; non-secret-class, `BOX_PICK_KIND=agy` `23:01Z`: sat 107% pick, both `agy weekly unknown`, placed anyway), else claude waiver fallback (`c-001` `77ba5669`) | `simple_coding` | 1 |
| 02 | `b52-02-orc-review-go-c4-test-column` | `do_spl_review_go` verifies every test required by the author brief's instruction text (`*.tst.sh`, `test-*.sh`, `*.test.mjs`, `rc[0-9][0-9]*.sh`, exact `do_check_pre_push`, unconditional `PRE_PUSH_TIER=full`, `shellcheck`) is named in `ran:`, holding `rc 12` naming missing tests | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:839-876`; `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh:1148-1151` & new case 36 after `:1456` | c-001 ruling `ee10c09a` (`a7f0d4b7`); n=2 live misses 2026-11-26: GO `d8bfb277` (`a-099` `02ccf2c7`, landed `92830c078` missing `do_check_pre_push`) + GO `245ec817` (`a-113` `c2a02a11`, missing `do_check_pre_push` & `PRE_PUSH_TIER=full`), plus `b49-01`/`r05-02`; `b51-03` landed `a5bb05350`; 0 false holds on b51-01..03 & r08-01..02; section 4.2 | `bash rc02-b52.sh ecc05e480` -> `rc02 exit 1`; control `fix-shape` -> `rc02 exit 0` | `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`; `bash csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh`; `bash rc02-b52.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x csi-spl-orc/src/bash/run/spl-review-go.func.sh csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `bash csi-spl-iac/src/bash/tests/action-header-tags.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.2: add `_spl_review_go_c4_missing` (<= 75 lines), wire into `_spl_review_go_one` after `do_spl_review_line_check` (skip `DOCS-ONLY`), hold `rc 12` naming missing tests, document `[12]` in header; update case 27 `:1148-1151` fixture line/log for `spl-billing-sa.tst.sh`; add case 36 covering missing `do_check_pre_push`, missing `PRE_PUSH_TIER=full`, missing `*.tst.sh`/`rc*.sh`/`shellcheck`, all-present GO, `NOT`/Never/`Files you must NOT touch`/conditional exclusions, and `DOCS-ONLY` skip; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` `23:01Z`: sat pick) | claude | agy (preferred; non-secret-class), else claude waiver fallback (`c-001` `77ba5669`) | `simple_coding` | 1 |
| 03 | `b52-03-orc-spawn-remote-handle-atomic-read` | `spawn-remote.sh` `handle()`, `handle_issue()`, and `note_cancel()` read the message JSON once atomically (with `archive/` fallback) before marking `$STATE/seen`, and `reply()` refuses an empty `--task` | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh:255-261,274-282,484-491,682-691`; `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh` (new case 16 at end) | c-001 `e1db57c6`, `c-001@<box2>` `42ac9aad`, live hit `2026-11-26T15:19:02Z` on b52 panel request `82416aaf` (`serve.log:3728`, minted task `765fe1de`); `c002-next-round-candidates.md:167`; section 4.3 | `bash rc03-b52.sh ecc05e480` -> `rc03 exit 1`; control `fix-shape` -> `rc03 exit 0` | `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`; `bash csi-spl-orc/src/bash/tests/spawn-remote-cron.tst.sh`; `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-lane-issue-remote-desk.sh`; `bash rc03-b52.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.3: add `read_msg_fields` (single atomic `cat` + `archive/` fallback, unpacks `msg`/`from`/`task`/`body` from snapshot, returns 1 without touching `$STATE/seen` when unreadable); wire into `handle()` (73 -> 71 lines <= 75), `handle_issue()` (50 -> 48 lines), and `note_cancel()` (17 -> 15 lines); guard `reply()` on `[ -n "$task" ]` (7 -> 8 lines); add case 16 in `test-spawn-remote.sh` covering mid-read inbox->archive move for `handle()` and `note_cancel()`, archive fallback, unreadable-not-seen, and empty-task `reply()` refusal; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` `23:01Z`: sat pick) | claude | agy (preferred; non-secret-class), else claude waiver fallback (`c-001` `77ba5669`) | `simple_coding` | 1 |

- **R1 (disjoint files):** all three rows are Batch 1 and share 0 files:
  - b52-01: `csi-spl-wui/src/utils/mobile-stack.mjs`, `csi-spl-wui/src/composables/useMobileStack.ts`, `csi-spl-wui/tests/unit/mobile-stack.test.mjs`, `csi-spl-wui/tests/e2e/mobile-back-wait.test.mjs`
  - b52-02: `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`
  - b52-03: `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spawn-remote.sh`
- **R3** (checked `2026-11-26T23:03:38Z`): `lane-map.sh --check csi-spl-wui/src/composables/useMobileStack.ts,csi-spl-wui/src/utils/mobile-stack.mjs,csi-spl-wui/tests/unit/mobile-stack.test.mjs,csi-spl-wui/tests/e2e/mobile-back-wait.test.mjs,csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh,csi-spl-doc/doc/md/bug-round-52-plan.md --agent a-264` -> **exit 4**: 0 live lanes list these paths, and 20 live lanes on `<box2>` record no files (`unknown:` at `23:03:38Z`: `c-029`, `c-041`, `c-068`, `c-079`, `c-086`, `c-146`, `c-187`, `c-211`, `c-264`, `c-339`, `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-904`, `c-927`, `c-936`, `c-957`, `c-971`): **not free until the holder re-runs `--check` at placement**. By `do_spl_lane_map` scopes (`22:59Z`), live lanes on sat (`c-119`/`a-262` SPL-6605 `MessageFeed.vue` snackbar, `c-171` CI A6 workflows, `a-260` r09 planner, `c-197` s150 B15a, `c-195`/`a-240` s150 B14, `a-934` spec 182 planner, `c-129` b52 panel) and `<box2>` (`c-342` r09 panel, `c-339` SPL-6633 reflection brief budget, `c-068` loops dialog, `c-264` s158 P2, `c-244` CI A8, `c-904` s187 S1, private workspace seats) touch none of these 8 row files. The queue (`do_spl_spawn_queue`, `23:00Z`, 78 queued asks, incl. 7 bug asks `9ad7f690`, `c921839d`, `6e647b48`, `625e0dcd`, `6ecb3881`, `077e04ae`, `c8ed77c7`) is disjoint by slug; r09 has not published a plan yet, so the holder re-checks R3 at placement.
- **R7:** claude-authored code rows (all 3 non-secret-class): prefer **agy** R7 seat (`BOX_PICK_KIND=agy ./run -a do_spl_box_pick` `23:01Z`: sat 107% pick, `<box2>` 205%, both `agy weekly unknown`, placed anyway), else claude waiver fallback citing `c-001` `77ba5669`. No grok (`c-001` `dc84300a`). No mistral (no review seat since 2026-11-25, no coding kind, never WUI). Every test in the row's R2 test column (including `cd csi-spl-iac && ./run -a do_check_pre_push`, `rc0N-b52.sh <fix sha>`, and for b52-01 all `do_check_pre_push_e2e`-selected e2e files) MUST appear in R7's `ran:` (rulebook C4).
- **Rhythm (1.4) & c-001 ruling `b1141868`:** rows queue once the panel signs and `do_spl_review_line_check` exits 0; all b51 rows have already landed (`49f7f487a`, `ba36f4d24`, `a5bb05350`); rows run at night through the placer load guard.
- **Pushes:** aim 1 per row (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug` (and b52-01 rides existing **SPL-5254**, priority 2).

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| Bug round 51 close record (`bug-round-51-plan.md`, SPL-6578) | `a-048@sat` | b51 rows landed (`49f7f487a`, `ba36f4d24`, `a5bb05350`), close record landed (`2485f3956`); stay off. |
| Refactor round 08 (`26c6b91ed`, closed) and live refactor round 09 (`a-260@sat` planner, `c-342@<box2>` panel) | live lanes | owned; stay off. |
| Live bug lanes: SPL-6605 (`c-119@sat` / `a-262@sat` sorted snackbar, `MessageFeed.vue`), SPL-6633 (`c-339@<box2>` nightly reflection brief budget) | live lanes | owned; stay off. |
| Queued bug asks (`9ad7f690` SPL-6615, `625e0dcd` SPL-6616, `6ecb3881` SPL-6617, `c921839d`/`6e647b48` s166 B8 reflection, `077e04ae` qto sync, `c8ed77c7` fence restart rotation reads) | queued | owned; stay off. |
| Live feature / CI / private workspace lanes (`c-171@sat` CI A6, `c-244@<box2>` CI A8, `c-197@sat` s150 B15a, `c-195@sat`/`a-240@sat` s150 B14, `c-068@<box2>` loops dialog, `c-264@<box2>` s158 P2, `a-934@sat` s182 planner, `c-904@<box2>` s187 S1, private workspace seats) | live lanes per `do_spl_lane_map` | owned; stay off. |
| The `unknown_token` box (551 prd WARNINGs since W) | the holder, as a box question | carried. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 3 (all Batch 1, R1 disjoint; within rulebook 5.1 cap of 3; bug share UNDER: live 19% vs 30-40% night band, 24 h 12% vs 20-30% band) |
| inputs re-measured | 10 sources; 56 prd ERROR entries in 10 h (29 since W: 22 ad-hoc Cloud SQL, 7 transient Cloud Run 503s); 1636 prd WARNING entries in 10 h (401s left out, cap not reached; 1349 since W; 0 `hours/minutes` 400s); 9 alert policies (0 incidents); 4 open t1 bug-labelled issues + SPL-6606 (SPL-5254 taken as b52-01, SPL-6633 & SPL-6605 live, SPL-4994 onhold terraform); 100 wf 10 runs (78 success, 17 cancelled, 4 failure, 1 running; 3 failed since W: 2 served by `81fea84a1`, 1 single sighting green since); 2 failed non-wf10 master runs since W (both wf 20 on `4609bb49`/`075c1bab`, served by `81fea84a1`); 27 commits in `2485f3956..ecc05e480` + `c-001`/`c-002` archives + `automation.log` tail + 7 real `(abrief, review line)` C4 audit pairs; 0 HUM posts after `12:00:00Z`; round 51's first inputs; holder's candidate list (167 lines on sat); `rc01-b52.sh` (`642aa582b7a6`, 15243 B), `rc02-b52.sh` (`1aad8be673cb`, 11166 B), and `rc03-b52.sh` (`8d2ec920278d`, 12260 B) n=1 each way on `ecc05e480` (`shellcheck -S warning` rc 0 on all 3); baselines `mobile-stack.test.mjs` (`42/42`), `spl-review-go.tst.sh` (`0 failure(s)`), `spl-accepted-close.tst.sh` (`0 failure(s)`), `test-spawn-remote.sh` (`127/127`), `spawn-remote-cron.tst.sh` (`fails=0`), `bash-cleancode.tst.sh` (`7578 functions in 1263 files`, all assertions), `action-header-tags.tst.sh` (`ALL PASS`) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b52-'` -> 0 (also 0 since `ae8fd2278`); `git ls-remote origin 'refs/heads/review/b52-*' 'refs/heads/wip/*b52*' 'refs/heads/*-b52-*' 'refs/heads/*bug-round-52*'` -> nothing (rc 0); briefs on sat matching `*b52*` / `*bug-round-52*`: only `hand-sat-c002-bug-round-52-planner.md` and `c002-bug-round-52-claude-panel-seat.md` (`22:59Z`) |
| R7 seat | agy preferred (non-secret-class; `BOX_PICK_KIND=agy` `23:01Z`: sat 107% pick, both boxes `agy weekly unknown`, placed anyway), else claude waiver fallback (`c-001` `77ba5669`) |
| first inputs for round 53 | `MessageCard.vue` M3 select box (`c-123` `8e965469`, `c-001` `e1db57c6`: `MessageCard.vue:1121` `content-visibility: auto` on `.msg:not(:focus-within)`, 4/4 miss at 1280x800 when clicking 2nd box while 1st holds focus — isolate exact rule in Chrome first); `review-go` owner-go false holds (`do_rdb_migration_next` `b4952880`, `a-104` N1 `## At brief time` `db300104`, another round's `DRY_RUN=0` `3748a973`, prose/backtick/identifier `apply`/`Apply`, 4 more rc 4 holds `20:27Z..22:12Z`; edits `spl-review-go.func.sh`, b52-02's file, so places only after b52-02 lands); seat-rotation poke reporting exit 0 without reaching the new pane (`c-001` `a1a5d394` + `2f3a505e`, spec 060, cause unchecked on `<box2>`); `a-767` N2 (`spool-agent-hook.sh:807-813` stale `stop_denies`) & `a-823` N2 (`PreInvocation` at `:140`); `a-769` N1 (`check-pre-push-lint.func.sh:618-643` `_ppl_run_timed` 124 vs 137) & N2 (`tenant-host-reserve.tst.sh` symlink control); `a4b540f6` (`spool-mirror.py:795` dangling `.mirror`); `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`); `a-995` N1 (`internal/taskcron/cron_test.go:209-229` malformed step tokens in `TestRefusals`); plus carried b51 items (`a-911` N2, `a-790` N1, `hours/minutes` whole-batch 400 follow-up, `c-708` N1, `a-683` N3, `a-490` N1, `a-480` N1, `TestHiddenUnreadBufferBudget`/`TestMarkedUnreadBufferBudget`, `unknown_token` box, hub dir mode, hermetic 2/4 timeout, composed testids, `i18n-lang-review-exempt.json:2`, SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** a-264@sat (agy, `specs_and_docs`).
- **Panel:** c-129@sat (claude, cross-vendor; placed on `dispatch-bug-r52`, msg `bf1826bf`).
- **Row reviewer (R7):** section 5.
- **Review history:**
  - 2026-11-26 23:18Z: v0.1 drafted on `ecc05e480`, pushed to `review/c002-bug-round-52-planner` (3 rows: b52-01, b52-02, b52-03), sent to panel `c-129@sat` and holder `c-002@sat` on task `dispatch-bug-r52`.
