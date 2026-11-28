# Refactoring round 15 (2026-11-28) - plan (2 rows)

Epic: SPL-2402
Spec: csi-spl-doc/specs/011-spool-project-refactor
Class: refactor
Kind: specs_and_docs
Issue: SPL-6737
Topic: bc3dab9a-48b0-434c-b2d9-f666155c08da
Discussion: bc3dab9a-48b0-434c-b2d9-f666155c08da (t1 #refactoring, "Refactor round 15", opened by c-002)
Window: W=2026-11-28T10:07:47+02:00

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, after 99 comes 01 (rulebook 5.3). The older cycle already created
  `refactor-round-15-plan.md`, `refactor-round-15-retro.md` and `refactor-round-15/` on
  `origin/master`, so this round carries its open date (rulebook 5.3): plan
  `refactor-round-15-20261128-plan.md`, retro `refactor-round-15-20261128-retro.md`,
  seat dir `refactor-round-15-20261128/`, Qto doc title the same, rows `r15-<NN>`,
  commit scope `docs(r15-plan, SPL-6737)`.
- owner 10-17 (t1 b61851fb, msg 91bf8278): no mistral coding or testing rows; mistral
  sits on no review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 14
([refactor-round-14-20261128-plan.md](refactor-round-14-20261128-plan.md), SPL-6723) is
closed on `origin/master`: `r14-01` `2de10856d` (SPL-6733) and `r14-02` `454bf1f6b`
(SPL-6734), close commit `e6e9b2fd8`, retro
[refactor-round-14-20261128-retro.md](refactor-round-14-20261128-retro.md). That retro's
section 6 and r14's section 7 are this plan's first inputs. The perf floor (rulebook 4.4),
re-measured on `e6e9b2fd8`: `perf 31 refactor 118 perf-share 20.8% floor-met`
(5 x 31 = 155 >= 149), so this is a refactor round (the brief's read on `2de10856d`
printed `perf 32 refactor 117 perf-share 21.5%`; the 14-day window has moved since).

Both rows are **one fact, one copy** (developer guide 2.2.4), web UI only, non-secret,
zero-PG, with zero behaviour change. Each moves a byte-identical function into a module
its two callers **already import**, so neither adds an import edge (r14-02's shape), and
each lands with a test that is RED on its parent:
- **Row 01 (`mockForbidden` once, 3 `csi-spl-wui` files):**
  `src/utils/monitoring-lanes.mjs:433-439` is byte for byte
  `src/utils/monitoring-tokens.mjs:238-244`, the mock hub's 403 for a fleet read by a
  non-admin. monitoring-lanes already imports monitoring-tokens (`:16`). The row exports
  it there and imports it. Guarded by a new check in `tests/unit/monitoring-lanes.test.mjs`.
- **Row 02 (the calendar write error key once, 5 `csi-spl-wui` files):**
  `src/components/CalendarEventDialog.vue:383-393` and
  `src/components/CalendarPhoneSheet.vue:503-513` carry the same 11-line `errorKey`, the
  i18n key of a refused save or delete. Both already import
  `src/utils/calendar-event-form.mjs`, which holds the form's other `calendar_event.error_*`
  keys. The row hosts it there as `calWriteErrorKey`, declares it in
  `src/types/calendar-shims.d.ts`, and both components import it. Guarded by 2 new checks
  in `tests/unit/calendar-event-form.test.mjs`.

The two rows share no file: both are **Batch 1**.

**Status: draft v0.1, for the panel.** Editor: **c-008** (claude, the specs_and_docs
backup: agy is out of weekly quota on both boxes until about 2026-12-03 and paused on
this box until 2026-11-28T12:13:21Z, `do_spl_lane_mix` at 09:31:08Z). Panel: the claude
seat `hand-sat-c002-refactor-round-15-claude-panel-seat` (queued, `7d1a5d04`, 67/103 at
09:17:56Z), a same-vendor panel under waiver `1a7c70da` (section 9).

**One sha:** every count is measured on **`e6e9b2fd8`**
(`e6e9b2fd87686e8a46a8a7d3fff374aeb2bf6c9e`, `origin/master` at 2026-11-28T09:17:46Z),
n=1 per command unless stated. The tests of 1.5 ran in scratch clones of `e6e9b2fd8`
(not committed): "base" unmodified, "head1" = base + row 01 as in 1.3, "head2" = base +
row 02 as in 1.4; each red control and mutation ran on its own copy. 1.3 and 1.4 print
each head as a unified diff against `e6e9b2fd8`, so a panel or R7 seat can rebuild head1
and head2 with `git apply` and check the sha256 values (r14 retro 4.4: keep it). Queue,
lane map, brief and branch reads are live state and carry their own times.

## 1. Baseline

### 1.1 Window, slug proof and old-cycle leftovers (rulebook 5.3)

2026-11-28T09:17:46Z, n=1, after a fresh fetch:

- **Window: W=2026-11-28T10:07:47+02:00**, from
  `git log origin/master --format='%H %cI %s' | grep -E '^[0-9a-f]+ \S+ docs\(r14-(plan|close)' | head -1`
  (subject filter, as the brief says: row bodies quote plan scopes):
  `e6e9b2fd87686e8a46a8a7d3fff374aeb2bf6c9e`
  (`docs(r14-plan, SPL-6723): refactor round 14 closed: r14-01 2de10856d and r14-02 454bf1f6b landed, claude R7 PASS each under waiver 1a7c70da, retro written`).
  It is the r14 **close** commit by c-915, which landed before this planner started; the
  r14 plan v1.0 commit `a711bbd25` (`W` the brief quoted at queue time,
  `2026-11-28T06:57:17+02:00`) is older. Read once; every later R4, R6, 2.7.5 and
  `PRUNE_SINCE` read for r15 uses this W.
- **Perf floor (rulebook 4.4):** the 4.4 command on `e6e9b2fd8` ->
  `perf 31 refactor 118 perf-share 20.8% floor-met`.
- **Slug proof since W:**
  `git log origin/master --since="2026-11-28T10:07:47+02:00" --oneline -E --grep='\(r15-' | wc -l`
  -> **0**.
- **Remote heads:**
  `git ls-remote origin 'refs/heads/review/r15-*' 'refs/heads/wip/*r15*' 'refs/heads/*-r15-*' 'refs/heads/*refactor-round-15*'`
  -> **0** lines. So `r15-01` and `r15-02` are free. This plan's own branch is
  `review/c002-refactor-round-15-planner` (not matched by `review/r15-*`).
- **Old-cycle files:** `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep refactor-round-15`
  -> 3: `refactor-round-15-plan.md`, `refactor-round-15-retro.md`, `refactor-round-15/`.
  The dated names of this round match 0 entries.
- **Briefs on the planner box** (`ls -la /var/spool-hub/dispatch/briefs | grep -E 'r15|round-15'`):
  besides this planner's brief and the panel seat's
  (`hand-sat-c002-refactor-round-15-claude-panel-seat.md`, 2026-11-28T09:36:56 box time,
  +02:00), 29 old-cycle leftovers, all mtime 2026-11-18T12:51 box time (before W): the
  brief's list (`c002-r15-seat-claude.md`, `c002-r15-seat-mistral.md`, `c296-r15-retro.md`,
  `c653-r15-03-agy-review.md`, `c003-refactor-r14-retro-r15-plan.md`, the 3 `g001-r15-*`
  and 18 `g002-r15-*` row and review briefs) and the bug / perf round 15 briefs
  (`c001-perf-round-15-planner.md`, `c002-bug-round-15-planner.md`,
  `c002-bug-round-15-mistral-panel-seat.md`, `c002-perf-round-15-mistral-panel-seat.md`).
  No other r15 head, file or brief exists for this cycle.

### 1.2 The brief's inputs, re-measured on `e6e9b2fd8`

- **(a) r14 section 7 and the r14 retro, section 6:**
  1. `spl_peer_pids` (`orc:src/bash/run/spl-peer-restart.func.sh`) /
     `spl_rotate_pids` (`orc:src/bash/run/spl-rotate-lib.func.sh`), deferred three times:
     **still deferred (R3).** `cf5e8b46` (s184 L5) has landed
     (`566080ade`, SPL-6727, `git log origin/master -- <the 2 files>`), so it holds them no
     more; but `aa377e76` (`claude:c001-s179-b5-paused-seats-free`) is still queued (34/103)
     and HELD after `c001-s179-b4-spawn-pause-hold` (`do_spl_spawn_queue` at 09:17:56Z),
     and its brief names `spl-rotate-lib.func.sh` (`grep -oE 'spl-(peer-restart|rotate-lib)[a-z._-]*'`
     -> 1 line). Section 7.
  2. `spl-issue-{blocker-rca-close,owner-question-diss}.func.sh` apply loops (r14 retro
     6.3: "can now be measured on a tree after `0e6f561e4`"): **measured, not identical.**
     `spl_issue_brc_apply` reads the issue's status with `spl_desk_issue_run get ... 2>/dev/null | python3 ...`
     and skips when the status moved off the plan's; `spl_issue_oq_apply` reads it with
     `2>&1` (stderr mixed into the JSON that python parses) and skips only `done` / `diss`.
     A shared loop would change one of them. Section 7.
  3. The rest of r14 section 7 (the other error-constructor and `browserStore` copies,
     `issueQuery`, `_read_json`, the Go cross-package / secret-class / route-family twins,
     the lane-handover, gcp key loop, probe and cron-preamble families): unchanged on
     `e6e9b2fd8`; the scans of (e) re-find each one. Section 7.
  4. r14 retro 6.1 (review-go does not read the waiver): a tooling change for the holder,
     not a refactor row. 6.2 (`mA` / `mB` survive on `spool_desk_root.py`): a test-round
     row.
- **(b) R7 notes of the r14 rows** (read in full on this box: `dispatch/` and
  `c-002/archive`):
  - r14-01, c-351 PASS msg 62a3c602 on `c6d406a82`: N1 (a parent named wrong in the body),
    N3 / N4 (equivalence and install checks, both OK), N5 / N6 (environment, hygiene);
    N2 = `mA` / `mB` survive, the retro's 6.2. None is a refactor.
  - r14-02, c-375 PASS msg 84deee4d on `0579fc04f`: N1 (the row brief missing on the
    reviewer's box), N2 (the one-copy import regex needs a name order) and N3 (a proxy
    regex) are test-strength notes, N4 / N5 OK reads, N6 a harness note, N7 `m2c` not
    re-run. None is a refactor row. **Taken into this plan:** N2 and N3 shape the row
    tests: row 01's import check names only `mockForbidden`, and row 02's names only
    `calWriteErrorKey`, so a reordered import stays green (mutation `m2g`, 1.5), and
    neither check uses a proxy line.
  - r14 panel notes: all folded into r14 v1.0 (`a711bbd25`).
- **(c) The dispatcher's candidates file** (`/var/spool-hub/dispatch/c002-next-round-candidates.md`,
  221 lines, mtime 2026-11-28T05:41:59 box time): unchanged since r14 read it (221
  lines then); nothing new, so r14 1.2 (c) stands: no refactor item.
- **(d) spec 011 tasks:** `git log a711bbd25..e6e9b2fd8 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> 0; its open tasks are as r13 1.2 (d) said: each wider than one row or waiting on
  the owner.
- **(e) A duplicate scan of its own** (scripts in the planner's scratch dir, on a
  `git archive` of `e6e9b2fd8`): (1) bash function bodies of 3 lines or more, own name
  masked, across files, over `csi-spl-{orc,iac,utl}/src` and `src/` (tests left out);
  (2) python function bodies by AST over `csi-spl-{orc,iac,utl}`; (3) WUI function bodies
  (`function` declarations, signature included, own name masked) over `csi-spl-wui/src`.
  Outcome:
  - WUI: `mockForbidden` in `monitoring-tokens.mjs:238` = `monitoring-lanes.mjs:433`
    (7 lines) -> **row 01** (1.3). `errorKey` in `CalendarPhoneSheet.vue:503` =
    `CalendarEventDialog.vue:383` (11 lines) -> **row 02** (1.4). The other WUI hits (the
    calendar `save` / `remove` / `addIssue`, the `mockStore`, `mockErr`, `dec`,
    `disconnect`, `load` twins, the error constructors): section 7.
  - bash: the `lib/bash/funcs` twins across orc / iac / utl (per-module copies of the
    framework), `_sec_<tool>_need` in 8 `iac:src/bash/run/sec-*.func.sh` files, the
    `net-dns-*` `*_link` pair, the sweep scripts' `scan_held`, `tf_get` and
    `spl_self_host_env_get` / `spl_secrets_none_get`: section 7.
  - python: the probes' `http` / `session_cookie` / `finish` and `_read_json`: section 7.

### 1.3 Row 01's site: `mockForbidden` once, in `monitoring-tokens.mjs`

`wui:` = `csi-spl-wui/`. On `e6e9b2fd8`:

- `wui:src/utils/monitoring-tokens.mjs` (306 lines, last changed `0d5a567e6`
  2026-10-31; Monitoring -> Tokens, spec 140) and `wui:src/utils/monitoring-lanes.mjs`
  (503 lines, `905bcdcb2` 2026-11-12; Monitoring -> Lanes, spec 153) each define
  `mockForbidden()` (`:238-244`, `:433-439`), byte for byte: an Error 'only an admin of
  the operator workspace reads the fleet' with `status` 403, `token` 'forbidden',
  `permission` 'operator.workspaces'. One call each (`monitoring-tokens.mjs:258`,
  `monitoring-lanes.mjs:463`), each wrapped in `mockRefused` of `act-as-mock.mjs`.
- `monitoring-lanes.mjs:16` already imports `lagSeconds` and `TOKENS_MOCK_OPERATOR_KEY`
  from `./monitoring-tokens.mjs`. The row exports `mockForbidden` there (with the `/** */`
  doc `util-docs.test.mjs` asks of an export), adds it to that import and deletes the
  lanes copy. **No new import edge**, so no chunk moves.
- No `src/types/*.d.ts` declares either module (`ls src/types | grep -i monitor` -> 0);
  both are `.mjs` read only by `.mjs`, `.vue` and `.ts` files that import what they use.
- Nuxt auto-imports every `src/utils` export by name:
  `git grep -nE 'export (async )?(function|const|let) (mockForbidden|calWriteErrorKey)\b' e6e9b2fd8 -- csi-spl-wui`
  -> 0, so the new export collides with none. `monitoring-invoices.mjs:78` keeps its own,
  different `mockForbidden(path)` (another message, wraps `mockRefused` itself): a local
  declaration, which shadows any auto-import in its file.
- Why not `mockStore` too (`monitoring-tokens.mjs:246` = `monitoring-lanes.mjs:441` =
  `monitoring-invoices.mjs:86` = `monitoring-lane-console.mjs:88`, 3 lines): exporting it
  from monitoring-tokens collides with the exported `mockStore` of
  `monitoring-paid.mjs:281` under the auto-import; hosting it in monitoring-paid needs new
  edges (monitoring-paid imports monitoring-tokens and monitoring-lanes, so they would
  import it back). Section 7.
- Non-secret, zero-PG: mock-hub code only (`NUXT_PUBLIC_USE_MOCK`).
- **CI parts:** `csi-spl-orc/src/bash/scripts/ci-doc-only.sh e6e9b2fd8 HEAD` on head1
  committed in a scratch clone -> `parts=iac orc wui` (3 paths).
- **E2E the pre-push map selects** (`cd csi-spl-iac && WUI_E2E_RANGE=HEAD^..HEAD ./run -a do_check_pre_push_e2e`
  on head1 committed in a scratch clone, rc 0): `tests/e2e/monitoring-costs.test.mjs`,
  `monitoring-lanes-phone.test.mjs`, `monitoring-takeover.test.mjs`,
  `monitoring-lane-id-links.test.mjs` (12 more `CUT ... budget` lines).
  `do_spl_review_line_check` fails a review line whose `ran:` does not name each of them
  (rulebook 2.7.4): the row's R7 runs all 4.

Shape (head1, `git diff --numstat e6e9b2fd8 head1`):
`monitoring-lanes.mjs` +1 -9 (503 -> 495), `monitoring-tokens.mjs` +6 -1 (306 -> 311),
`monitoring-lanes.test.mjs` +7 -0 (287 -> 294).
sha256 (12 chars): `monitoring-lanes.mjs` `b7c79a5a699f`, `monitoring-tokens.mjs` `19fa832894bc`,
`monitoring-lanes.test.mjs` `ee2d000c0af7`.

head1 as a diff against `e6e9b2fd8` (`git apply` it there; `index` lines dropped;
`git apply --check` on a clean base -> rc 0):

```diff
diff --git a/csi-spl-wui/src/utils/monitoring-lanes.mjs b/csi-spl-wui/src/utils/monitoring-lanes.mjs
--- a/csi-spl-wui/src/utils/monitoring-lanes.mjs
+++ b/csi-spl-wui/src/utils/monitoring-lanes.mjs
@@ -13,7 +13,7 @@
 
 import { mockRefused } from './act-as-mock.mjs'
 import { isoSeconds } from './iso-seconds.mjs'
-import { lagSeconds, TOKENS_MOCK_OPERATOR_KEY } from './monitoring-tokens.mjs'
+import { lagSeconds, mockForbidden, TOKENS_MOCK_OPERATOR_KEY } from './monitoring-tokens.mjs'
 import { emptySheetFilters, sheetFiltersActive, sheetRowMatches } from './column-sheet.mjs'
 
 /** Polling while the tab is open and the browser tab visible (decision P4). */
@@ -430,14 +430,6 @@ export async function readLanes(api, s) {
   }
 }
 
-function mockForbidden() {
-  const e = /** @type {Error & { status?: number, token?: string, permission?: string }} */ (new Error('only an admin of the operator workspace reads the fleet'))
-  e.status = 403
-  e.token = 'forbidden'
-  e.permission = 'operator.workspaces'
-  return e
-}
-
 function mockStore() {
   try { return typeof localStorage === 'undefined' ? null : localStorage } catch { return null }
 }
diff --git a/csi-spl-wui/src/utils/monitoring-tokens.mjs b/csi-spl-wui/src/utils/monitoring-tokens.mjs
--- a/csi-spl-wui/src/utils/monitoring-tokens.mjs
+++ b/csi-spl-wui/src/utils/monitoring-tokens.mjs
@@ -235,7 +235,12 @@ export function sortAgents(rows, opts = {}) {
   })
 }
 
-function mockForbidden() {
+/**
+ * The mock's refusal of an operator fleet read: 403 forbidden, permission
+ * operator.workspaces, as the hub answers a non-admin. monitoring-lanes.mjs
+ * uses this copy (r15-01).
+ */
+export function mockForbidden() {
   const e = /** @type {Error & { status?: number, token?: string, permission?: string }} */ (new Error('only an admin of the operator workspace reads the fleet'))
   e.status = 403
   e.token = 'forbidden'
diff --git a/csi-spl-wui/tests/unit/monitoring-lanes.test.mjs b/csi-spl-wui/tests/unit/monitoring-lanes.test.mjs
--- a/csi-spl-wui/tests/unit/monitoring-lanes.test.mjs
+++ b/csi-spl-wui/tests/unit/monitoring-lanes.test.mjs
@@ -182,6 +182,13 @@ describe('the mock', () => {
   it('403 operator.workspaces unless the operator admin opted in', () => {
     assert.throws(() => mockFleetLanes(store({})), (e) => e.status === 403 && e.permission === 'operator.workspaces')
   })
+  it('one copy (r15-01): the 403 is monitoring-tokens.mjs mockForbidden, which this file imports', () => {
+    const lanes = read('src/utils/monitoring-lanes.mjs')
+    assert.doesNotMatch(lanes, /^function mockForbidden\(/m, 'monitoring-lanes.mjs defines no mockForbidden of its own')
+    assert.match(lanes, /^import \{[^}]*\bmockForbidden\b[^}]*\} from '\.\/monitoring-tokens\.mjs'$/m)
+    assert.equal((read('src/utils/monitoring-tokens.mjs').match(/^export function mockForbidden\(/gm) || []).length, 1)
+    assert.throws(() => mockFleetLanes(store({})), (e) => e.token === 'forbidden' && e.message === 'only an admin of the operator workspace reads the fleet')
+  })
   it('three lanes: a linked topic with issues, a foreign topic, none', () => {
     const v = fleetLanesOf(mockFleetLanes(store(OP), new Date('2026-10-24T10:00:00Z')))
     assert.equal(v.lanes.length, 3)
```

**Behaviour:** none changes: the same Error (message, `status`, `token`, `permission`),
thrown from the same two calls through the same `mockRefused`. `monitoring-tokens.test.mjs`
(23 checks) and `monitoring-lanes.test.mjs` (26 on base, 27 on head1) pass, as do the 17
other suites that name either module (1.5).

### 1.4 Row 02's site: the calendar write error key once, in `calendar-event-form.mjs`

On `e6e9b2fd8`:

- `wui:src/components/CalendarEventDialog.vue` (496 lines, last changed `c6eaf5cb8`
  2026-11-02; the desktop event dialog, spec 089) and
  `wui:src/components/CalendarPhoneSheet.vue` (887 lines, `eaba06240` 2026-11-19; the phone
  sheet, whose writes are "as the 089 dialog's", its comment at `:502`) each define
  `errorKey(e)` (`:383-393`, `:503-513`), byte for byte: 401 -> `error_signed_out`, token
  `private_owner_only` -> `error_private_owner`, token `demo_read_only` -> `error_demo`,
  403 -> `error_forbidden`, 404 -> `error_not_found`, 400 -> `error_bad`, else
  `error_save` (all under `calendar_event.`). Two calls each, in `save()` and `remove()`
  (`EventDialog :421, :442`, `PhoneSheet :540, :561`).
- Both import a block of names from `~/utils/calendar-event-form.mjs` (`EventDialog
  :265-268`, `PhoneSheet :334-337`); that module (414 lines, `028909908` 2026-11-01) is
  pure (it imports only `date-iso`, `date-iso-zone`, `calendar-year`, `iso-seconds`) and
  already returns the form's other `calendar_event.error_*` keys (`calReminderError`
  `:305`, `calFormBody` `:358-364`). The row adds `calWriteErrorKey` there, after
  `calReminderError` (the naming of the other util error keys: `loopErrorKey`,
  `userErrorKey`, `tenantSettingsErrorKey`), declares it in
  `wui:src/types/calendar-shims.d.ts` (`:62-102` declares that module's exports), adds it to
  both import blocks, renames the 4 calls and deletes the 2 copies. **No new import edge.**
- `calendar-events-api.mjs` (the API calls) is the other module both import; it is not the
  host because it imports `msg-ai-actions.mjs` and holds no i18n key.
- Not in the row: the other twins of the pair (`save` 26 lines, `remove` 19, `addIssue`
  13, `changed` 3): they read each component's own refs and emits, so one copy is a
  composable, wider than one row. Section 7.
- Non-secret, zero-PG: the i18n key of an error the client already has; the hub call,
  its body and the error object are not touched.
- **CI parts:** `ci-doc-only.sh e6e9b2fd8 HEAD` on head2 -> `parts=iac orc wui` (5 paths).
- **E2E the pre-push map selects** (same command on head2, rc 0):
  `tests/e2e/calendar-phone-peek.test.mjs`, `calendar-event-fields.test.mjs`,
  `calendar-phone-sheet.test.mjs`, `calendar-events.test.mjs`, `calendar.test.mjs`,
  `calendar-phone.test.mjs`, `calendar-drag.test.mjs`, `calendar-phone-day.test.mjs`,
  `calendar-undo.test.mjs`, `calendar-synced.test.mjs`, `open-parent-section.test.mjs`
  (97 more `CUT ... budget` lines). The row's R7 runs all 11.

Shape (head2, `git diff --numstat e6e9b2fd8 head2`):
`CalendarEventDialog.vue` +3 -15 (496 -> 484), `CalendarPhoneSheet.vue` +3 -14
(887 -> 876), `calendar-shims.d.ts` +1 -0 (152 -> 153), `calendar-event-form.mjs` +17 -0
(414 -> 431), `calendar-event-form.test.mjs` +27 -1 (401 -> 427).
sha256 (12 chars): `CalendarEventDialog.vue` `da66778622c6`, `CalendarPhoneSheet.vue` `555b698d57a7`,
`calendar-shims.d.ts` `26d3b2e68217`, `calendar-event-form.mjs` `890988d3bd57`,
`calendar-event-form.test.mjs` `a97a791dca45`.

head2 as a diff against `e6e9b2fd8` (`index` lines dropped; `git apply --check` -> rc 0):

```diff
diff --git a/csi-spl-wui/src/components/CalendarEventDialog.vue b/csi-spl-wui/src/components/CalendarEventDialog.vue
--- a/csi-spl-wui/src/components/CalendarEventDialog.vue
+++ b/csi-spl-wui/src/components/CalendarEventDialog.vue
@@ -264,7 +264,7 @@
 import type { CalendarItem } from '~/utils/calendar-mock.mjs'
 import {
   CAL_COLORS, CAL_DESCRIPTION_MAX, CAL_ISSUE_KEYS_MAX, CAL_LOCATION_MAX, CAL_REMINDERS_MAX, CAL_REMINDER_UNITS, CAL_TITLE_MAX,
-  calAudienceSwitched, calCanSetPrivate, calFormBody, calFormCopy, calFormFromEvent, calHourAfter, calIssueKey, calNewReminder, calOwnerChoices, calReminderAmount, calReminderError,
+  calAudienceSwitched, calCanSetPrivate, calFormBody, calFormCopy, calFormFromEvent, calHourAfter, calIssueKey, calNewReminder, calOwnerChoices, calReminderAmount, calReminderError, calWriteErrorKey,
 } from '~/utils/calendar-event-form.mjs'
 import type { CalReminderRow } from '~/utils/calendar-event-form.mjs'
 import { knownTimeZones } from '~/utils/date-iso.mjs'
@@ -380,18 +380,6 @@ function startMoved() {
   if (form.value.end <= form.value.start && !form.value.endDays) form.value.end = calHourAfter(form.value.start)
 }
 
-function errorKey(e: { status?: number, token?: string }) {
-  const code = Number(e?.status) || 0
-  const token = String(e?.token || '')
-  if (code === 401) return 'calendar_event.error_signed_out'
-  if (token === 'private_owner_only') return 'calendar_event.error_private_owner'
-  if (token === 'demo_read_only') return 'calendar_event.error_demo'
-  if (code === 403) return 'calendar_event.error_forbidden'
-  if (code === 404) return 'calendar_event.error_not_found'
-  if (code === 400) return 'calendar_event.error_bad'
-  return 'calendar_event.error_save'
-}
-
 function changed() {
   window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
 }
@@ -418,7 +406,7 @@ async function save() {
     emit('saved', ev as CalendarItem)
     emit('update:open', false)
   } catch (e) {
-    error.value = errorKey(e as { status?: number, token?: string })
+    error.value = calWriteErrorKey(e as { status?: number, token?: string })
   } finally {
     busy.value = false
   }
@@ -439,7 +427,7 @@ async function remove() {
     emit('deleted', ev as CalendarItem)
     emit('update:open', false)
   } catch (e) {
-    error.value = errorKey(e as { status?: number, token?: string })
+    error.value = calWriteErrorKey(e as { status?: number, token?: string })
     confirmDelete.value = false
   } finally {
     busy.value = false
diff --git a/csi-spl-wui/src/components/CalendarPhoneSheet.vue b/csi-spl-wui/src/components/CalendarPhoneSheet.vue
--- a/csi-spl-wui/src/components/CalendarPhoneSheet.vue
+++ b/csi-spl-wui/src/components/CalendarPhoneSheet.vue
@@ -333,7 +333,7 @@
 import type { CalendarItem } from '~/utils/calendar-mock.mjs'
 import {
   CAL_COLORS, CAL_DESCRIPTION_MAX, CAL_ISSUE_KEYS_MAX, CAL_LOCATION_MAX, CAL_REMINDERS_MAX, CAL_REMINDER_UNITS, CAL_TITLE_MAX,
-  calAudienceSwitched, calCanSetPrivate, calFormBody, calFormCopy, calFormFromEvent, calHourAfter, calIssueKey, calNewReminder, calOwnerChoices, calReminderAmount, calReminderError,
+  calAudienceSwitched, calCanSetPrivate, calFormBody, calFormCopy, calFormFromEvent, calHourAfter, calIssueKey, calNewReminder, calOwnerChoices, calReminderAmount, calReminderError, calWriteErrorKey,
 } from '~/utils/calendar-event-form.mjs'
 import type { CalForm, CalReminderRow } from '~/utils/calendar-event-form.mjs'
 import { calPhoneHourPreset, calPhoneNextFullHour } from '~/utils/calendar-phone-nav.mjs'
@@ -500,17 +500,6 @@ function refreshOwners() {
 const { onViewport, dy, dragging, sheetStyle, dragStart, dragMove, dragEnd, onWindowKey, onKeydown } = useCalendarPhoneSheetGestures({ sheetEl, bodyEl, busy, cancel })
 
 /* ---- the writes, as the 089 dialog's ---- */
-function errorKey(e: { status?: number, token?: string }) {
-  const code = Number(e?.status) || 0
-  const token = String(e?.token || '')
-  if (code === 401) return 'calendar_event.error_signed_out'
-  if (token === 'private_owner_only') return 'calendar_event.error_private_owner'
-  if (token === 'demo_read_only') return 'calendar_event.error_demo'
-  if (code === 403) return 'calendar_event.error_forbidden'
-  if (code === 404) return 'calendar_event.error_not_found'
-  if (code === 400) return 'calendar_event.error_bad'
-  return 'calendar_event.error_save'
-}
 function changed() {
   window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
 }
@@ -537,7 +526,7 @@ async function save() {
     emit('saved', ev as CalendarItem)
     emit('update:open', false)
   } catch (e) {
-    error.value = errorKey(e as { status?: number, token?: string })
+    error.value = calWriteErrorKey(e as { status?: number, token?: string })
   } finally {
     busy.value = false
   }
@@ -558,7 +547,7 @@ async function remove() {
     emit('deleted', ev as CalendarItem)
     emit('update:open', false)
   } catch (e) {
-    error.value = errorKey(e as { status?: number, token?: string })
+    error.value = calWriteErrorKey(e as { status?: number, token?: string })
     confirmDelete.value = false
   } finally {
     busy.value = false
diff --git a/csi-spl-wui/src/types/calendar-shims.d.ts b/csi-spl-wui/src/types/calendar-shims.d.ts
--- a/csi-spl-wui/src/types/calendar-shims.d.ts
+++ b/csi-spl-wui/src/types/calendar-shims.d.ts
@@ -84,6 +84,7 @@ declare module '~/utils/calendar-event-form.mjs' {
   export function calDefaultZone(): string
   export function calReminderAmount(raw: unknown): string
   export function calReminderError(row: CalReminderRow): string
+  export function calWriteErrorKey(e: { status?: number, token?: string } | null | undefined): string
   export function calNewReminder(rows: CalReminderRow[]): CalReminderRow | null
   export function calStored(ev: Item | null | undefined): boolean
   export function calSynced(ev: Item | null | undefined): boolean
diff --git a/csi-spl-wui/src/utils/calendar-event-form.mjs b/csi-spl-wui/src/utils/calendar-event-form.mjs
--- a/csi-spl-wui/src/utils/calendar-event-form.mjs
+++ b/csi-spl-wui/src/utils/calendar-event-form.mjs
@@ -309,6 +309,23 @@ export function calReminderError(row) {
   return n > CAL_REMINDER_UNITS[row.unit] ? 'calendar_event.error_reminder_max' : ''
 }
 
+/**
+ * The i18n key of a refused save or delete: signed out, a private event of
+ * someone else, the read-only demo, forbidden, gone, a bad body, else the
+ * plain save error. The dialog and the phone sheet both show it (r15-02).
+ */
+export function calWriteErrorKey(e) {
+  const code = Number(e?.status) || 0
+  const token = String(e?.token || '')
+  if (code === 401) return 'calendar_event.error_signed_out'
+  if (token === 'private_owner_only') return 'calendar_event.error_private_owner'
+  if (token === 'demo_read_only') return 'calendar_event.error_demo'
+  if (code === 403) return 'calendar_event.error_forbidden'
+  if (code === 404) return 'calendar_event.error_not_found'
+  if (code === 400) return 'calendar_event.error_bad'
+  return 'calendar_event.error_save'
+}
+
 /** The form's next reminder row: 10 minutes, or null when it holds 5 already. */
 export function calNewReminder(rows) {
   return (rows || []).length >= CAL_REMINDERS_MAX ? null : { amount: '10', unit: 'minutes' }
diff --git a/csi-spl-wui/tests/unit/calendar-event-form.test.mjs b/csi-spl-wui/tests/unit/calendar-event-form.test.mjs
--- a/csi-spl-wui/tests/unit/calendar-event-form.test.mjs
+++ b/csi-spl-wui/tests/unit/calendar-event-form.test.mjs
@@ -25,10 +25,11 @@
 //   `web` in is public, and the signed-out read answers public events only
 import { afterEach, beforeEach, describe, it } from 'node:test'
 import assert from 'node:assert/strict'
+import { readFileSync } from 'node:fs'
 import { setTimeZoneSource } from '../../src/utils/date-iso.mjs'
 import {
   CAL_COLORS, CAL_ISSUE_KEYS_MAX, CAL_PUBLIC_WIRE, calAudienceSwitched, calCanSetPrivate, calDiscussionRef, calEditable, calFormBody, calFormCopy, calFormFromEvent, calHourAfter, calIsPublic, calIssueKey, calIssueKeys, calNewReminder,
-  calOwnerChoices, calOwnerId, calReminderAmount, calReminderError, calRoadmapHref, calStored, calSynced, calWallToUtc,
+  calOwnerChoices, calOwnerId, calReminderAmount, calReminderError, calRoadmapHref, calStored, calSynced, calWallToUtc, calWriteErrorKey,
 } from '../../src/utils/calendar-event-form.mjs'
 import { mockCalendarCreate, mockCalendarDelete, mockCalendarEvents, mockCalendarUpdate, mockWebCalendarEvents } from '../../src/utils/calendar-mock.mjs'
 
@@ -399,3 +400,28 @@ describe('mock workspace writes', () => {
     assert.equal(week().find((x) => x.id === 's1').title, 'Standup')
   })
 })
+
+describe('r15-02: a refused write, one copy', () => {
+  it('maps the hub refusal to its key: 401 first, then the token, then the status', () => {
+    const k = (status, token) => calWriteErrorKey({ status, token })
+    assert.equal(k(401, 'private_owner_only'), 'calendar_event.error_signed_out')
+    assert.equal(k(403, 'private_owner_only'), 'calendar_event.error_private_owner')
+    assert.equal(k(403, 'demo_read_only'), 'calendar_event.error_demo')
+    assert.equal(k(403, 'forbidden'), 'calendar_event.error_forbidden')
+    assert.equal(k(404), 'calendar_event.error_not_found')
+    assert.equal(k(400), 'calendar_event.error_bad')
+    assert.equal(k(409, 'synced_read_only'), 'calendar_event.error_save')
+    assert.equal(calWriteErrorKey(new Error('offline')), 'calendar_event.error_save')
+    assert.equal(calWriteErrorKey(null), 'calendar_event.error_save')
+  })
+  it('the dialog and the phone sheet import it and define no errorKey of their own', () => {
+    const read = (rel) => readFileSync(new URL('../../' + rel, import.meta.url), 'utf8')
+    for (const v of ['src/components/CalendarEventDialog.vue', 'src/components/CalendarPhoneSheet.vue']) {
+      const src = read(v)
+      assert.doesNotMatch(src, /^function errorKey\(/m, v)
+      assert.match(src, /^import \{[^}]*\bcalWriteErrorKey\b[^}]*\} from '~\/utils\/calendar-event-form\.mjs'$/m, v)
+      assert.equal((src.match(/calWriteErrorKey\(e as/g) || []).length, 2, v + ': the save and the delete')
+    }
+    assert.equal((read('src/utils/calendar-event-form.mjs').match(/^export function calWriteErrorKey\(/gm) || []).length, 1)
+  })
+})
```

**Behaviour:** none changes: the same 7 branches in the same order, the same keys, the
same 4 call sites (each keeps its `e as { status?: number, token?: string }` cast). In
`CalendarPhoneSheet.vue` the comment `/* ---- the writes, as the 089 dialog's ---- */`
now heads `changed()`, the first of the writes' helpers left there.

### 1.5 Before and on the rows' heads

Base and heads 2026-11-28T09:2xZ-09:4xZ, n=1, as the planner's user in the scratch clones,
node v20.19.2, `node --test tests/unit/<x>.test.mjs` in `csi-spl-wui`, stdin from
`/dev/null`; pass / fail from the `# pass` / `# fail` footer (the 4 framework suites
print one `ok` line). "=" means equal to base.

**Row 01** (every unit suite that names `monitoring-tokens`, `monitoring-lanes` or
`mockForbidden`: `git grep -lE` over `tests/unit`, 19 files; plus 4 framework suites):

| suite | base rc / pass / fail | head1 |
|---|---|---|
| `wui:tests/unit/column-sheet.test.mjs` | 0 / 12 / 0 | = |
| `wui:tests/unit/cost-allocations.test.mjs` | 0 / 44 / 0 | = |
| `wui:tests/unit/cost-entries-sort-filter.test.mjs` | 0 / 11 / 0 | = |
| `wui:tests/unit/cost-entries.test.mjs` | 0 / 65 / 0 | = |
| `wui:tests/unit/hr-costs.test.mjs` | 0 / 9 / 0 | = |
| `wui:tests/unit/hr-payroll.test.mjs` | 0 / 7 / 0 | = |
| `wui:tests/unit/hr-worker.test.mjs` | 0 / 6 / 0 | = |
| `wui:tests/unit/monitoring-invoices.test.mjs` | 0 / 7 / 0 | = |
| `wui:tests/unit/monitoring-lane-console.test.mjs` | 0 / 12 / 0 | = |
| `wui:tests/unit/monitoring-lane-links.test.mjs` | 0 / 13 / 0 | = |
| `wui:tests/unit/monitoring-lanes-sort-filter.test.mjs` | 0 / 27 / 0 | = |
| `wui:tests/unit/monitoring-lanes-unknown.test.mjs` | 0 / 3 / 0 | = |
| `wui:tests/unit/monitoring-lanes-url.test.mjs` | 0 / 12 / 0 | = |
| `wui:tests/unit/monitoring-lanes.test.mjs` | 0 / 26 / 0 | 0 / 27 / 0 |
| `wui:tests/unit/monitoring-paid.test.mjs` | 0 / 21 / 0 | = |
| `wui:tests/unit/monitoring-tokens.test.mjs` | 0 / 23 / 0 | = |
| `wui:tests/unit/monitoring-topics.test.mjs` | 0 / 17 / 0 | = |
| `wui:tests/unit/paid-items-sort-filter.test.mjs` | 0 / 10 / 0 | = |
| `wui:tests/unit/read-gates.test.mjs` | 0 / 6 / 0 | = |
| `wui:tests/unit/util-docs.test.mjs` | 0 / 4 / 0 | = |
| `wui:tests/unit/unused-exports.test.mjs` | 0 / 1 / 0 | = |
| `wui:tests/unit/mjs-shims-exist.test.mjs` | 0 / 1 / 0 | = |
| `wui:tests/unit/swallow-reasons.test.mjs` | 0 / 1 / 0 | = |

`unused-exports`: base `3621 exports in 596 files, 30 unused, all listed in ALLOW (33 <= cap 33)`,
head1 `3622 exports ...`, the same 30 unused.

**Row 02** (every unit suite that names `CalendarPhoneSheet`, `CalendarEventDialog`,
`calendar-event-form`, `calendar-shims`, `errorKey` or `calendar_event.error`: 4 files;
plus the framework, i18n, font and focus suites):

| suite | base rc / pass / fail | head2 |
|---|---|---|
| `wui:tests/unit/calendar-calm-cards.test.mjs` | 0 / 27 / 0 | = |
| `wui:tests/unit/calendar-drag.test.mjs` | 0 / 21 / 0 | = |
| `wui:tests/unit/calendar-event-form.test.mjs` | 0 / 38 / 0 | 0 / 40 / 0 |
| `wui:tests/unit/calendar-phone-sheet-gestures.test.mjs` | 1 / 0 / 1 | = |
| `wui:tests/unit/focus-tokens.test.mjs` | 0 / 10 / 0 | = |
| `wui:tests/unit/font-size.test.mjs` | 0 / 11 / 0 | = |
| `wui:tests/unit/i18n-no-raw-text.test.mjs` | 0 / 7 / 0 | = |
| `wui:tests/unit/i18n-parity.test.mjs` | 0 / 1 / 0 | = |
| `wui:tests/unit/i18n-untranslated.test.mjs` | 0 / 5 / 0 | = |
| `wui:tests/unit/mjs-shims-exist.test.mjs` | 0 / 1 / 0 | = |
| `wui:tests/unit/swallow-reasons.test.mjs` | 0 / 1 / 0 | = |
| `wui:tests/unit/unused-exports.test.mjs` | 0 / 1 / 0 | = |
| `wui:tests/unit/util-docs.test.mjs` | 0 / 4 / 0 | = |

`calendar-phone-sheet-gestures.test.mjs` is red on base and head2 alike: `Cannot find
package 'vue'` (no `node_modules` on this box's checkouts, and the brief forbids
installs). The row lane and its R7 run it.

**Not run by the planner** (no `node_modules`): `calendar-phone-sheet-gestures.test.mjs`,
`cleancode.test.mjs`, `pnpm run typecheck` (it alone proves the `calendar-shims.d.ts`
line), the e2e files of 1.3 and 1.4, `cd csi-spl-iac && ./run -a do_check_pre_push`.
The row lane and its R7 run them.

**Red controls** (each head's test file copied onto base, n=1):
- `rc1` (head1's `monitoring-lanes.test.mjs` on base): rc 1, 26 pass, 1 fail (`one copy
  (r15-01): the 403 is monitoring-tokens.mjs mockForbidden, which this file imports`);
  head1: rc 0, 27 pass.
- `rc2` (head2's `calendar-event-form.test.mjs` on base): rc 1, 0 pass, 1 fail
  (`SyntaxError: The requested module '../../src/utils/calendar-event-form.mjs' does not
  provide an export named 'calWriteErrorKey'`: the file does not load); head2: rc 0, 40
  pass. With the export alone added to base (no fold), the one-copy check is what stays
  red: mutation `m2a` shows that check catching a second copy.

**Mutations** (one defect planted in a copy of the final head, n=1):
- `m1a` (an own `mockForbidden` copy back in monitoring-lanes, its import dropped):
  monitoring-lanes rc 1, 26 / 1 (`one copy ...`); monitoring-tokens 0 / 23 / 0.
- `m1b` (`mockForbidden` drops `permission`): monitoring-lanes rc 1, 26 / 1 (`403
  operator.workspaces unless the operator admin opted in`); monitoring-tokens rc 1, 22 / 1.
- `m1c` (the message changes by one letter): monitoring-lanes rc 1, 26 / 1 (`one copy
  ...`, its message assert); monitoring-tokens 0 / 23 / 0 (it checks status and
  permission only).
- `m1d` (`mockForbidden` not exported): monitoring-lanes rc 1, `SyntaxError: The requested
  module './monitoring-tokens.mjs' does not provide an export named 'mockForbidden'`.
- `m2a` (CalendarEventDialog gets back a `function errorKey`, delegating): rc 1, 39 / 1
  (`the dialog and the phone sheet import it and define no errorKey of their own`).
- `m2b` (the token check moved before 401): rc 1, 39 / 1 (`maps the hub refusal to its key:
  401 first, then the token, then the status`).
- `m2c` (the `demo_read_only` line dropped): rc 1, 39 / 1 (the same check).
- `m2d` (`calWriteErrorKey` not exported): rc 1, the `SyntaxError` of `rc2`.
- `m2e` (PhoneSheet's `save` shows `error_save` whatever the refusal, the call kept):
  0 / 40 / 0, **green**: the unit suite reads the source and the mapping, not what the
  sheet shows, and no e2e file names a `calendar_event.error_*` key
  (`grep -lE 'calendar_event\.error|error_private_owner|error_demo|error_forbidden|error_signed_out' tests/e2e/*.mjs`
  -> 0). The row lane says which e2e goes red on it, or that none does: a required
  result field of the r15-02 brief; a gap that predates the row (the old copies behave
  the same), a test-round input.
- `m2f` (PhoneSheet drops `calWriteErrorKey` from its import, calls kept): rc 1, 39 / 1
  (`the dialog and the phone sheet import it ...`). In the built app it is a
  `ReferenceError` only if the auto-import does not supply the name; `pnpm run typecheck`
  is the gate that decides (not run here).
- `m2g` (the import reordered, `calWriteErrorKey` first, no second copy): 0 / 40 / 0,
  **green by design** (c-375 N2, 1.2 (b)).

The tests that name the sites (R2), `git grep -lE` over `*/tests/*` on `e6e9b2fd8`:
- Row 01 (`monitoring-tokens|monitoring-lanes|mockForbidden`) -> the 19 unit suites above
  (**`tests/unit/monitoring-lanes.test.mjs`** edited) and 13 e2e files
  (`cost-allocation`, `monitoring-costs`, `monitoring-head-actions-row`,
  `monitoring-invoices`, `monitoring-lane-console`, `monitoring-lane-id-links`,
  `monitoring-lanes-like-events`, `monitoring-lanes-phone`, `monitoring-lanes-url`,
  `monitoring-takeover`, `monitoring-tokens`, `monitoring-topics-like-lanes`,
  `reporting-costs-labels`); the R7 runs the 4 the map selects (1.3) and says which of
  the others it ran.
- Row 02 (`CalendarPhoneSheet|CalendarEventDialog|calendar-event-form|calendar-shims|errorKey|calendar_event\.error`)
  -> the 4 unit suites above (**`tests/unit/calendar-event-form.test.mjs`** edited) and
  the e2e `calendar-event-fields`, `calendar-events`, `calendar-phone-sheet` (all in the
  map's 11, 1.4).
- R2's comment rule: `git grep -nF` of the 30-character strings in the comments at the
  sites (`the writes, as the 089 dialog`, `only an admin of the operator workspace reads
  the fleet`) over `*/tests/*` -> 0 each.
- No new test file, so no shard-weights line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r15-01-wui-monitoring-mock-forbidden-once)` | one fact, one copy (developer guide 2.2.4) | `monitoring-lanes.mjs:433-439` is byte for byte `mockForbidden` of `monitoring-tokens.mjs:238-244`, a module it already imports (`:16`) (1.3) | `wui:src/utils/monitoring-tokens.mjs:238`<br>`wui:src/utils/monitoring-lanes.mjs:16,433-440`<br>`wui:tests/unit/monitoring-lanes.test.mjs:184` | copies of `mockForbidden` in the pair 2 -> 1 (`grep -cE '^(export )?function mockForbidden\(' <the 2 files>` 1 + 1 -> 1 + 0) | 1.3's shape (head1 diff). **Red control:** head1's `monitoring-lanes.test.mjs` on base: rc 1, 26 pass, 1 FAIL (the one-copy check), then GREEN on head1 (rc 0, 27). Mutations `m1a`-`m1d` (1.5); outputs in the body. **Behaviour:** none changes (1.3). Tests: **`wui:tests/unit/monitoring-lanes.test.mjs`**, `monitoring-tokens.test.mjs` and the rest of 1.5's row 01 column, `util-docs`, `unused-exports`, `mjs-shims-exist`, `swallow-reasons`, `cleancode.test.mjs`, `pnpm run typecheck`, the 4 e2e files of 1.3 (`BASE_URL=<generated mock bundle> pnpm run test:e2e`), `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r15-02-wui-calendar-write-error-key-once)` | one fact, one copy (developer guide 2.2.4) | `CalendarEventDialog.vue:383-393` and `CalendarPhoneSheet.vue:503-513` carry the same `errorKey`; both already import `calendar-event-form.mjs`, which holds the form's other error keys (1.4) | `wui:src/utils/calendar-event-form.mjs:311`<br>`wui:src/types/calendar-shims.d.ts:86`<br>`wui:src/components/CalendarEventDialog.vue:267,383-394,421,442`<br>`wui:src/components/CalendarPhoneSheet.vue:336,503-513,540,561`<br>`wui:tests/unit/calendar-event-form.test.mjs:27,31,401` | copies of the write error key 2 -> 1 (`grep -c '^function errorKey(' <the 2 .vue>` 1 + 1 -> 0 + 0; `grep -c '^export function calWriteErrorKey(' calendar-event-form.mjs` 0 -> 1) | 1.4's shape (head2 diff). **Red control:** head2's `calendar-event-form.test.mjs` on base: rc 1 (the missing export), then GREEN on head2 (rc 0, 40). Mutations `m2a`-`m2g` (1.5); outputs in the body. **Behaviour:** none changes (1.4). Tests: **`wui:tests/unit/calendar-event-form.test.mjs`**, `calendar-calm-cards`, `calendar-drag`, `calendar-phone-sheet-gestures`, the i18n, font, focus and framework suites of 1.5, `cleancode.test.mjs`, `pnpm run typecheck`, the 11 e2e files of 1.4, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`wui:` = `csi-spl-wui/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4) on the
`origin/master` it starts from and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `refactor(r15-NN-<slug>, SPL-<row issue>): ...`; review
branch `review/r15-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows fold internal helper copies with zero change to any output, exit
code, env var, path or page a caller sees ->
`Docs: none (internal helper consolidation; no behaviour changes)`. The developer guide
2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: disjoint file sets (row 01: 3 `wui:` files of
  Monitoring; row 02: 5 `wui:` files of the calendar).
- Neither row edits `act-as-mock.mjs`, `monitoring-invoices.mjs`, `monitoring-paid.mjs`,
  `monitoring-lane-console.mjs`, `calendar-events-api.mjs`, `calendar-mock.mjs`, any other
  `.vue`, a locale file, `spool-client*.mjs`, `csi-spl-api/`, `csi-spl-cnf/`, terraform,
  `csi-spl-orc/` or `csi-spl-iac/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths checked: the 8 edited files plus `monitoring-tokens.test.mjs` (in row 01's column).

- **Lane map, every machine:** `lane-map.sh --check <the 9 paths> --agent c-008`, n=1,
  at 2026-11-28T09:22:51Z: **exit 4**, 0 owned, "25 live lane(s) record no files", all
  on the other box: 18 `-rotate` seats and `c-383` (spec 153 Q1, the placer's bypass
  line), `c-387` and `c-418` (claude waiver reviewer seats), `c-400` (spec 153 Q4, the
  Queue tab), `c-410` (omnibox multicast), `c-412` (spec 184 D1 docs), `c-995` (blog
  draft). Their briefs on this box, grep
  `monitoring-(tokens|lanes)|mockForbidden|calendar-event-form|calendar-shims|CalendarPhoneSheet|CalendarEventDialog|errorKey`:
  0 for each but `c-383` (1: its `Spec:` line names `153-monitoring-lanes-tab`, no row
  file) and `c-400` (2: the `Spec:` line, and Q4's files "a new
  `<wui>/utils/monitoring-queue.mjs` (with its mock, as `monitoring-lanes.mjs:28` does)":
  a new file, no row file). **Serialization note:** Q4's new mock may copy
  `mockForbidden` a third time. If row 01 lands first, Q4's lane can import it from
  `monitoring-tokens.mjs` (an edge it decides); either order rebases cleanly, since Q4
  edits none of row 01's files. The holder may forward this to `c-400`.
- **Live lanes on this box:** the 192 worktrees of `git worktree list` other than this
  one: `git diff --name-only $(merge-base) HEAD` plus `git status --porcelain`, grepped for
  the 8 row files and the 2 test files, at 09:23:37Z -> 1 hit:
  `/opt/csi/csi-spl-wt/g-962-r4620` (`monitoring-lanes.mjs`, `monitoring-lanes.test.mjs`),
  the leftover worktree of g-962 (`registry.retired.tsv`: retired 2026-11-15), whose
  SPL-4620 commits landed on 2026-11-03 (`3221bc9e1`, `c95674e04`). Not a live lane.
- **Spawn queue** (`do_spl_spawn_queue`, 2026-11-28T09:17:56Z, 103 queued, 102 slugs):
  the brief of each slug grepped as above -> **0** hits; one slug has no brief on this
  box, `c001-spl5020-dev030-switch` (by its name, the dev 030 terraform step, no WUI
  file).
- **Remote branches committed in the last 48 h** (145, at 09:24:39Z):
  `git diff --name-only $(git merge-base origin/master <b>) <b>` grepped for the row files
  -> **0**.
- **Commits in the last 7 days** on the 8 row files and `monitoring-tokens.test.mjs`
  (`git log origin/master --since='7 days ago' -- <files>`) -> **0**.

## 3. Per row: what the lane does

- **r15-01:** applies 1.3's head1 diff on its `origin/master`: exports `mockForbidden`
  from `wui:src/utils/monitoring-tokens.mjs` with a `/** */` doc, imports it in
  `wui:src/utils/monitoring-lanes.mjs` (`:16`) and deletes its copy (`:433-440`), and adds
  the one-copy check after the 403 check of `describe('the mock')` in
  `wui:tests/unit/monitoring-lanes.test.mjs` (`:184`).
- **r15-02:** applies 1.4's head2 diff: adds `calWriteErrorKey` with a `/** */` doc after
  `calReminderError` in `wui:src/utils/calendar-event-form.mjs`, declares it in
  `wui:src/types/calendar-shims.d.ts`, adds it to the import block of both components,
  renames their 4 `errorKey(` calls and deletes their 2 copies, and adds the `node:fs`
  import, the name to the import list and the `describe('r15-02: ...')` block at the end
  of `wui:tests/unit/calendar-event-form.test.mjs`.

## 4. Reviewers (R7)

- Editor: **c-008** (claude). The panel seat signs the plan sha (rulebook 3.2,
  section 9).
- **Row reviewers (code R7), cross-vendor first (2.7.2):**
  `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix` at 2026-11-28T09:31:08Z:
  `agy paused in instance settings until 2026-11-28T12:13:21Z: usage limit` (and agy's
  weekly quota is out until about 2026-12-03 per the brief), grok and qwen off, mistral
  sits on no review, codex not signed in -> `pick=claude`. So each claude row's R7 is the
  **claude waiver seat** (waiver `1a7c70da`), until agy can sit; the holder re-checks at
  placement and moves R7 to an agy seat once agy is back. Never mistral. While the waiver
  stands, the review-go cron holds each same-vendor PASS (r14 retro 4.1): the holder
  sends the GO by hand.
- Row vendor: `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 09:31:08Z ->
  `pick=claude` (main claude; mistral writes no code). Both rows: **claude** (R14).
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries its plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites of 1.3 / 1.4, its R7 seat, "re-measure first", and the plan's
`Window: W=2026-11-28T10:07:47+02:00` for its R4 slug check.

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r15-01 | `c002-r15-01-wui-monitoring-mock-forbidden-once` | `refactor(r15-01-wui-monitoring-mock-forbidden-once, SPL-<row issue>): ...` | `review/r15-01` | 1 |
| r15-02 | `c002-r15-02-wui-calendar-write-error-key-once` | `refactor(r15-02-wui-calendar-write-error-key-once, SPL-<row issue>): ...` | `review/r15-02` | 1 |

Before placing either: R4's slug check reads since W, for both rows at once:
`git log origin/master --since="2026-11-28T10:07:47+02:00" --oneline -E --grep='\(r15-' | wc -l`
must print 0 (it printed 0 at 2026-11-28T09:17Z, `origin/master` `e6e9b2fd8`), and
`git ls-remote origin 'refs/heads/review/r15-*' 'refs/heads/wip/*r15*' 'refs/heads/*-r15-*'`
must print nothing (it printed nothing then).

**r15-01 brief, Files: ONLY**
`csi-spl-wui/src/utils/monitoring-tokens.mjs`, `csi-spl-wui/src/utils/monitoring-lanes.mjs`
and `csi-spl-wui/tests/unit/monitoring-lanes.test.mjs` (1.3's head1 diff). NOT
`monitoring-invoices.mjs`, NOT `monitoring-paid.mjs`, NOT `monitoring-lane-console.mjs`,
NOT `act-as-mock.mjs`, NOT `mockStore` anywhere, NOT any other file. Do: plan section 2
row 01 verbatim, 1.3's shape; red control (head1's test on its parent: rc 1, 26 pass, 1
FAIL) RED then GREEN in the body; the 4 mutations `m1a`-`m1d` of 1.5 shown RED in the
body. Gates: `pnpm run typecheck`, the row's unit tests (1.5), `cleancode.test.mjs`,
`BASE_URL=<generated mock bundle> pnpm run test:e2e` on the 4 e2e files of 1.3 (re-list
them with `do_check_pre_push_e2e` on the row's own sha), `cd csi-spl-iac && ./run -a do_check_pre_push`.
The initial JS budget is CI's (`ci_initial_gzip_kb`): the row adds no import edge, so the
entry chunk should not move; state the generate build's initial gzip KB before and after
if you build it, and whether the build log prints a `Duplicated imports` warning naming
`mockForbidden` (expected: none, 1.3). `Docs: none (internal helper consolidation; no
behaviour changes)`. Kind `simple_coding`, vendor claude; R7 the claude waiver seat under
waiver `1a7c70da` while agy cannot sit (re-checked at placement); never mistral.

**r15-02 brief, Files: ONLY**
`csi-spl-wui/src/utils/calendar-event-form.mjs`, `csi-spl-wui/src/types/calendar-shims.d.ts`,
`csi-spl-wui/src/components/CalendarEventDialog.vue`,
`csi-spl-wui/src/components/CalendarPhoneSheet.vue` and
`csi-spl-wui/tests/unit/calendar-event-form.test.mjs` (1.4's head2 diff). NOT
`calendar-events-api.mjs`, NOT `calendar-mock.mjs`, NOT the components' `save` /
`remove` / `addIssue` / `changed`, NOT a locale file, NOT any other file. Do: plan
section 2 row 02 verbatim, 1.4's shape; red control (head2's test on its parent: rc 1)
RED then GREEN in the body; the mutations `m2a`-`m2d` and `m2f` of 1.5 shown RED in the
body, `m2g` green. `m2e` is green in the unit suite by design: say which e2e catches it,
or that none does (a required result field). Gates: `pnpm run typecheck` (it alone proves
the `calendar-shims.d.ts` line and `m2f`; the planner could not run it, 1.5), the row's
unit tests (1.5, `calendar-phone-sheet-gestures.test.mjs` included),
`cleancode.test.mjs`, `BASE_URL=<generated mock bundle> pnpm run test:e2e` on the 11 e2e
files of 1.4, `cd csi-spl-iac && ./run -a do_check_pre_push`. The same build notes as
r15-01 (initial gzip KB if built; no `Duplicated imports` warning naming
`calWriteErrorKey`). `Docs: none (internal helper consolidation; no behaviour changes)`.
Kind `simple_coding`, vendor claude; R7 the claude waiver seat under waiver `1a7c70da`
while agy cannot sit (re-checked at placement); never mistral.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`, both web UI) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of `mockForbidden` in `monitoring-tokens.mjs` + `monitoring-lanes.mjs` (row 01) | 2 on `e6e9b2fd8` -> 1 (`monitoring-invoices.mjs`'s different `mockForbidden(path)` stays, section 7) |
| copies of the calendar write error key (row 02) | 2 on `e6e9b2fd8` -> 1 (`calWriteErrorKey`) |
| lines (`git diff --numstat` of each head) | row 01: +14 -10 over 3 files; row 02: +51 -30 over 5 files (1.3, 1.4) |
| CI parts (`ci-doc-only.sh` on each head's range) | row 01 `iac orc wui`; row 02 `iac orc wui` |
| measured on | `e6e9b2fd8`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-peer-restart.func.sh` (`spl_peer_pids`) and `orc:src/bash/run/spl-rotate-lib.func.sh` (`spl_rotate_pids`) | the same `/proc` scan with a different matcher; deferred a fourth time (R3): `cf5e8b46` landed (`566080ade`), but queued ask `aa377e76` (34/103, HELD after `c001-s179-b4-spawn-pause-hold`) names `spl-rotate-lib.func.sh` | `do_spl_spawn_queue` 09:17:56Z; its brief, grep (n=1) |
| `spl-issue-{blocker-rca-close,owner-question-diss}.func.sh` apply loops (r14 retro 6.3) | not identical: the status read is `2>/dev/null` in one and `2>&1` (stderr parsed as JSON) in the other, and the skip rule differs (status moved vs done / diss); one loop changes one of them. The `2>&1` read is a bug-round note (a stderr line makes the read "" and the item moves), not a refactor | the two files on `e6e9b2fd8`, read in full |
| `mockStore` (`monitoring-tokens.mjs:246`, `monitoring-lanes.mjs:441`, `monitoring-invoices.mjs:86`, `monitoring-lane-console.mjs:88`; exported by `monitoring-paid.mjs:281`) | 3 lines; an export from `monitoring-tokens.mjs` collides with `monitoring-paid.mjs`'s exported `mockStore` under the Nuxt auto-import, and hosting it in `monitoring-paid.mjs` adds edges back into a module that imports them | WUI body scan; `grep '^import'` of the 5 files |
| `mockForbidden(path)` of `monitoring-invoices.mjs:78` | not identical: another message ('... manages workspaces') and it wraps `mockRefused` itself | WUI body scan, read |
| the calendar pair's other twins: `save` (26 lines), `remove` (19), `addIssue` (13), `changed` (3) of `CalendarPhoneSheet.vue` / `CalendarEventDialog.vue` | they read each component's own refs and emits: one copy is a composable, wider than one row (a later round, with an e2e that shows a refused write, see `m2e`) | WUI body scan |
| `_sec_<tool>_need` in 8 `iac:src/bash/run/sec-*.func.sh` (and `_sec_scan_need` of `sec-scan.func.sh`, the same body written longer) | 8 sites (max 5 per row), each a security gate's fail-closed check: a gate row (R9) with its own red control, split over two rounds | bash body scan (3-line floor) |
| `ndp_link` / `ndf_link` (`orc:src/bash/run/net-dns-pin-and-mask.func.sh:49`, `net-dns-fast-failover.func.sh:71`) | 4 lines in two box DNS actions that source nothing in common: a fold adds a source edge for 4 lines | bash body scan |
| `scan_held` (`utl:src/bash/scripts/review-worktree-sweep.sh:70`, `playwright-artifacts-sweep.sh:49`) | 3 lines in two standalone sweep scripts that source nothing; each writes its own temp file | bash body scan |
| `tf_get` (`orc:src/bash/scripts/tf-import-table.sh:28`, `tf-030-import-existing-cloud-run.sh:56`) | the 030 importer is copied alone into the terraform container (its usage block): standalone by design | bash body scan, the file's header |
| `spl_self_host_env_get` / `spl_secrets_none_get` | the second lives in the secrets check: secret-class | bash body scan |
| `mockErr` (`join-tokens-mock.mjs:7` = `embed-admin-mock.mjs:9`; `tenant-users-mock.mjs:9` = `tenant-settings-mock.mjs:11` = `sender-allow-mock.mjs:7`), `dec` (`note-links.mjs:48` = `app-link-label.mjs:105`) | no module the copies share already holds such a helper: each fold adds an import edge, and `dec`'s natural host (`tenant-host-core.mjs`, imported by both) is first-screen code: bundle measured first (a perf-round row) | WUI body scan; `grep '^import'` |
| `disconnect` (`MarketingXAccounts.vue:125` = `MarketingLinkedInPages.vue:129`), `load` (`tenant-settings/split.vue:132` = `general.vue:130`; `HoursSettings.vue:80` = `BlockerIssueSetting.vue:53`), `act` (`HrWorkerCard.vue:199` = `HrPayrollCard.vue:152`) | component state (refs, the api, emits): a composable each, not a pure helper | WUI body scan |
| r14 section 7's other items (the error constructors and `browserStore` of `fleet-load.mjs` / `tenant-costs.mjs` / `vendor-keys.mjs`, `issueQuery`, `_read_json`, Go, the lane-handover, gcp key, probe and cron-preamble families) | unchanged on `e6e9b2fd8`, with r14's reasons | r14 plan section 7; scans 1.2 (e) (n=1) |
| r14 retro 6.1 (review-go and the waiver), 6.2 (`mA` / `mB`), c-351 N2, c-375 N2 / N3 | tooling for the holder; test-round rows | the retro; the two R7 messages |

## 8. Changes

- v0.1 (c-008): the rows and every read on `e6e9b2fd8`; both heads built in scratch
  clones; the column of 1.5 run on base and each head; both red controls and the
  mutations as 1.5 says. Pushed to `review/c002-refactor-round-15-planner`.

## 9. Consensus

Same-vendor panel, waiver 1a7c70da (c-001 ruling on 21e079a5): agy, the cross-vendor
reviewer of a claude plan, is out of quota on both boxes until about 2026-12-03 (and
paused on this box until 2026-11-28T12:13:21Z, `do_spl_lane_mix` at 09:31:08Z), so the
panel seat is claude. The r15 retro names this.

| seat | vendor | role | plan sha | verdict | review line / note |
|---|---|---|---|---|---|
| `c-008` | claude | editor | v0.1 | author | section 8 |
| claude panel seat (`hand-sat-c002-refactor-round-15-claude-panel-seat`) | claude | panel | v0.1 (pending) | pending | same-vendor panel, waiver 1a7c70da (c-001 ruling on 21e079a5) |

No row lane starts before the panel signs the plan sha and its review line passes
`do_spl_review_line_check` (rc 0), confirmed by the dispatch lease holder.
