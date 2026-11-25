# Refactoring round 98 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6457  
Topic: 9e18d782-1d68-467e-bf4d-d7e64ae260d1  
Discussion: 9e18d782-1d68-467e-bf4d-d7e64ae260d1 (t1 #refactoring, "Refactor round 98", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r98**, plan `refactor-round-98-plan.md`, rows `r98-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25. **Vendor claude for every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 97 ([refactor-round-97-plan.md](refactor-round-97-plan.md))
landed both of its rows on trunk (r97-01 `2924c633f`, SPL-6449; r97-02 `529f837ef`,
SPL-6450), and its close record (`5855e3ca3`, SPL-6458) landed separately after this
plan's base `7084439f1`. This planner writes no r97 close record and touches no r97 file.
The perf floor (rulebook 4.4), measured on `7084439f1` at 2026-11-25T05:38:51Z (14 days):
perf 36, refactor 101, 26.3%, 5 x 36 = 180 >= 137, floor-met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91..r97: a
duplicated validation/preparation block that exists in multiple places moves to a single
shared helper, and each caller calls that single home.
**Row 01:** the three calendar event write actions in `orc:src/bash/run/` —
`spl-calendar-event-add.func.sh:203-204` (`_spl_calendar_event_body`),
`spl-calendar-event-delete.func.sh:35-36` (`_spl_calendar_event_each`), and
`spl-calendar-event-update.func.sh:103-104` (`_spl_calendar_update_body`; r97 plan
section 7) — duplicate the exact 2-line actor check validating `AGENT_ID` (new
`^[acgmq]-[0-9]{3,}$` or legacy `^(CLE|AGY|GRK|QWN)-[0-9]+$`) and optional `ORDERED_BY`
(`^HUM-[0-9]+$`). Extracting `_spl_calendar_require_actor <agent> <ordered_by>` into
`spl-calendar-event-add.func.sh` (which already holds the calendar helper functions
`_spl_calendar_event_link` and `_spl_calendar_reminders`, with zero top-level code) lets
`spl-calendar-event-add.func.sh` call it directly and lets
`spl-calendar-event-delete.func.sh` and `spl-calendar-event-update.func.sh` lazy-source
`spl-calendar-event-add.func.sh` behind a `declare -F _spl_calendar_require_actor` guard
and call `_spl_calendar_require_actor "$agent" "$ordby" || return 1`.
**Row 02:** the two GCP daily cost read actions in `iac:src/bash/run/` —
`spl-estate-cost-read.func.sh:56-66` (`do_spl_estate_cost_read`) and
`spl-vm-cost-per-day.func.sh:47-57` (`do_spl_vm_cost_per_day`) — duplicate the exact
11-line UTC `DAY` validation (default yesterday UTC, `YYYY-MM-DD` regex + `date -u -d`
calendar round-trip), `do_resolve_oap ORG`, `do_resolve_oap APP`,
`do_spl_cost_gcp_cnf || return 1`, and trailing `COST_REREAD_DAYS` UTC day window loop.
Extracting `do_spl_cost_gcp_window` into `iac:lib/bash/funcs/spl-cost-gcp.func.sh`
(lazily stub-loaded by `csi-spl-iac/run` and sourced directly by both tests) sets process
globals `COST_WINDOW_DAY` and `COST_WINDOW_DAYS=()`, and both actions replace the 11-line
block with `do_spl_cost_gcp_window || return 1`, `local day="${COST_WINDOW_DAY}"` (plus
`tmp` in `spl-vm-cost-per-day.func.sh`), and `local -a days=("${COST_WINDOW_DAYS[@]}")`.
The rows share no file (orc vs iac): both are batch 1.

**Status: v0.2, revised draft for panel re-review.** Panel seat **c-429** (claude,
cross-vendor; `c002-refactor-round-98-claude-panel-seat`) reviewed v0.1 (`caf5a790e`) on
branch `review/c002-refactor-round-98-planner` and returned FAIL (`348c10658`, W1 and W2,
plus notes N1-N5; both rows confirmed behaviour-preserving). This v0.2 folds W1, W2, and
N1-N5 and awaits c-429's re-review. Rows queue only after the panel signs v1.0 and the
holder confirms `do_spl_review_line_check` rc 0 and places them (rulebook 1.4 / 5.2).
Editor: **a-427** (agy).

**One sha:** every count is measured on **`7084439f1`** (`7084439f15cfdc93915fa52161c3f8c58e1483ae`,
`origin/master` at 2026-11-25T05:38:47Z), n=1 per command unless stated. Reads are on
`7084439f1` with `git show` / `git grep`. The tests of 1.5 ran in detached scratch
worktrees of `7084439f1` (not committed, removed on exit): "base" unmodified, "head1" =
base with row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's
shape; each red and guard control (1.5) ran in a detached worktree of its own. Both helper
definitions and all four test hunks are reproduced verbatim in 1.3 and 1.4 so any panel or
R7 seat can reconstruct head1, head2, and all 7 controls byte-for-byte on `7084439f1` and
verify every sha256. Queue, lane map, brief and branch reads are live state and carry
their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-25T05:38:47Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-24T19:33:57+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r97-plan'`:
  `3364c37cf` (`docs(r97-plan, SPL-6384): refactor round 97 plan v1.0, signed by m-161 (mistral) PASS on dc07c2ee4, W1 and N1-N3 folded`),
  read once at the start as 5.3 says. Note (N1): after base `7084439f1`, the r97 close
  record `5855e3ca3` (`docs(r97-plan, SPL-6458)`, `2026-11-25T07:50:08+02:00`) landed on
  `origin/master`. Per rulebook 5.3, `W` stays fixed at this recorded date
  (`2026-11-24T19:33:57+02:00`); all later R4, R6, 2.7.5, and `PRUNE_SINCE` reads for
  r98 must use `W=2026-11-24T19:33:57+02:00`, not a fresh derivation.
- `git log origin/master --since="$W" --oneline -E --grep='\(r98-' | wc -l` -> **0**
  (over all history -> **0**).
- `git ls-remote origin 'refs/heads/review/r98-*' 'refs/heads/*-r98-*' 'refs/heads/*refactor-round-98*' 'refs/heads/wip/*r98*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r98|refactor-round-98'` -> this plan's
  brief (`c002-refactor-round-98-planner.md`) and the panel seat's
  (`c002-refactor-round-98-claude-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-98`
  -> **0**: the plain name is free.

### 1.2 The brief's inputs, re-measured

- **(a) r97 section 7:** re-read on `7084439f1`.
  - `orc:src/bash/run/spl-calendar-event-{add,delete,update}.func.sh` (`:203-204`,
    `:35-36`, `:103-104`): the 3 calendar write actions duplicate the exact 2-line
    `AGENT_ID` + optional `ORDERED_BY` check -> measured here as **row 01** (1.3).
    `spl-human-{email-add,link}.func.sh` (`:103-104`, `:83-84`) enforce strictly 3-digit
    agent ids (`^[acgmq]-[0-9]{3}$`, rejecting legacy `CLE-*` and 4+ digits) and required
    non-empty `ORDERED_BY` with a different FATAL wording (`ORDERED_BY must be the HUM-* id of the human who ordered it`),
    so merging them into row 01 would change behaviour; they stay out (section 7).
  - `git diff --name-only 6d81d4447 7084439f1` (269 files across 117 commits: r97 plan
    `3364c37cf` & rows `2924c633f` / `529f837ef`, b45-01 `958049e92`, p19 rows
    `94bc0a57a`..`1bc99663b`, SPL-451 cnf env JSON schema `3cc0cb218` & `787a3814a`,
    spec 193 v1.0-v1.2, spec 195 v0.1-v0.2, spec 112 v1.3, spec 149 2.11, spec 039
    v0.11.1, spec 154 v1.7 / SPL-6454, SPL-6456, SPL-6446, SPL-6447, SPL-6439): touches
    none of r91..r97 section 7's remaining items, so each stays out for its reason there
    (section 7).
- **(b) R7 and panel notes:**
  - r97-01 R7 (`a-366`, agy, PASS on `2924c633f`, report + spool `dispatch-refactor-r97`):
    N1 `sa:lib/spool-fleet.inc.sh:29,100` writes `[root]` in comments while the body uses
    `${1:-}/peer/seats` (non-blocking; every caller passes `$1` explicitly); N2 convert
    review line to box-free form (done on land). No refactor row.
  - r97-02 R7 (`a-363`, agy, PASS on `529f837ef`, report + spool `dispatch-refactor-r97`):
    N1 commit body re-measurement sha vs rebase parent; N2 temp clone pre-push env note.
    No refactor row.
  - r97 panel (`m-161`, mistral, recorded in r97 plan v1.0 `3364c37cf`): PASS on
    `dc07c2ee4`; W1 (code R7 = agy seat per ruling `dc84300a`) and N1..N3 already folded
    into r97 plan v1.0. No refactor row.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 140 lines, read 05:39Z):
  - No `## for refactor round 98` block.
  - Earlier refactor-shaped entries verified on `7084439f1`:
    - `for refactor round 97` (`spl-unanswered-sweep.func.sh:196`): served by r97-01
      (`2924c633f`).
    - `for refactor round 95` (`c002-next-round-candidates.md:124-125`, WUI entry-chunk
      gzip headroom `ci_initial_gzip_kb` 154.7 on `c41b7080e`, ceiling 155, blocker on
      SPL-6341 B13 / eager-core split): verified **served on `7084439f1`** by `c68cca820`
      (`refactor(wui, SPL-6342): the hub socket's code leaves the entry chunk, -3.0 KB
      first-load gzip`) and `69dc02d2f` (`docs(perf, SPL-6342)`), both ancestors of
      `7084439f1`, which lowered `metrics.ci_initial_gzip_kb` in
      `csi-spl-doc/specs/027-ui-performance-budget/contracts/perf-budgets.json` from
      154.7 KB to 151.9 KB (~3.1 KB headroom under the 155.0 KB ceiling; SPL-6341 B13 also
      landed in `76471cb9e`, ancestor of `7084439f1`). Recorded in section 7 too (W2).
    - `LOGIN_STATE_DIR` (`orc:src/bash/run/spl-watchdog.func.sh:72,1323`): already uses
      `spl_claude_login_state_dir` from `spl-claude-login.func.sh`.
    - `spl-desk-reply.sh:9,19`: already lists all 12 kinds.
    - `reverse-tunnel-cron.sh`, `agent-boot-restore`, `spl-lane-mix.func.sh`: already
      served.
  - Remaining entries (bug round 43 `SILENT` / `review-go`, perf round 19/20 retained
    nodes & strip geometry, other-repo `zip_dirs`, e2e selector gate) are bug, perf,
    other-repo, or gate-design items, not refactor rows.
- **(d) spec 011 tasks:**
  `git log 7084439f1 --since=2026-11-24T15:50:31Z --oneline -- csi-spl-doc/specs/011-spool-project-refactor`
  -> 2 commits (`3cc0cb218`, `787a3814a`, both SPL-451 closing T025 cnf env JSON schema);
  the remaining open tasks (T001-T008 owner-deferred, T018-T021, T023, T027, T034) are
  each wider than one row or await an owner decision.
- **(e) Fresh duplicate scan** on `7084439f1` over tracked non-test `*.sh` under
  `csi-spl-orc/{src,lib}`, `csi-spl-iac/{src,lib}`, `csi-spl-utl/src/bash` and `src/bash`,
  plus Go (`csi-spl-api`) and TS (`csi-spl-wui`):
  - The 10 remaining non-framework Bash function groups from r91..r97 section 7 are
    unchanged on `7084439f1` (section 7).
  - Cross-file block scan surfaced the 11-line UTC `DAY` validation + OAP resolve +
    `do_spl_cost_gcp_cnf` + trailing `COST_REREAD_DAYS` window builder duplicated between
    `iac:src/bash/run/spl-estate-cost-read.func.sh:56-66` and
    `iac:src/bash/run/spl-vm-cost-per-day.func.sh:47-57` -> measured here as **row 02**
    (1.4).
  - Other newly scanned candidates (`_chs_send`/`_rrc_send` in `csi-spl-utl`,
    `playwright-artifacts-sweep.sh`/`review-worktree-sweep.sh` in `csi-spl-utl`,
    `_spl_*_holder` in `csi-spl-orc`, `spl-lane-handover*.func.sh`, `sec-*.func.sh`,
    `*-cron.sh` `check_tools`, `csi-spl-api` Go and `csi-spl-wui` TS helpers) are
    recorded with measurements in section 7.

### 1.3 Row 01's site: `spl-calendar-event-{add,delete,update}.func.sh` share `_spl_calendar_require_actor`

`orc:` = `csi-spl-orc/`. On `7084439f1`:

- `orc:src/bash/run/spl-calendar-event-add.func.sh:203-204` (in `_spl_calendar_event_body`),
  `orc:src/bash/run/spl-calendar-event-delete.func.sh:35-36` (in `_spl_calendar_event_each`),
  and `orc:src/bash/run/spl-calendar-event-update.func.sh:103-104` (in
  `_spl_calendar_update_body`) each contain the exact same 2 lines:
  ```bash
    [[ "$agent" =~ ^[acgmq]-[0-9]{3,}$ || "$agent" =~ ^(CLE|AGY|GRK|QWN)-[0-9]+$ ]] || { do_log "FATAL AGENT_ID must be an agent id like c-042, got: '$agent'"; return 1; }
    [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
  ```
- `diff -u <(git show 7084439f1:csi-spl-orc/src/bash/run/spl-calendar-event-add.func.sh | sed -n '203,204p') <(git show 7084439f1:csi-spl-orc/src/bash/run/spl-calendar-event-delete.func.sh | sed -n '35,36p')`
  -> no hunk (rc 0, n=1); the same diff against
  `spl-calendar-event-update.func.sh:103-104` -> no hunk (rc 0, n=1): all three copies
  are **byte-identical**.
- `_spl_calendar_require_actor` has **0 collisions** anywhere in the repo (`git grep` ->
  0). `spl-calendar-event-add.func.sh` contains only function definitions (zero top-level
  code or var assignments) and already hosts the calendar helpers
  `_spl_calendar_event_link` and `_spl_calendar_reminders`, so lazy-sourcing it inside
  `_spl_calendar_event_each` (`spl-calendar-event-delete.func.sh`) and
  `_spl_calendar_update_body` (`spl-calendar-event-update.func.sh`) behind
  `declare -F _spl_calendar_require_actor >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-calendar-event-add.func.sh"`
  keeps all three actions lazy (`run-lazy-loader.tst.sh` and `run-eager-files.tst.sh`
  pass unchanged).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `_spl_calendar_require_actor` is 5
  lines; `_spl_calendar_event_body` 40 -> 39 lines; `_spl_calendar_event_each` 32 -> 33
  lines; `_spl_calendar_update_body` 29 -> 30 lines. None of the 5 files has any entry in
  `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt`, or `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-calendar-event-add.func.sh`: define
  `_spl_calendar_require_actor <agent> <ordered_by>` with its 3-line comment immediately
  above `_spl_calendar_event_body` (`:193`), and replace `:203-204` in
  `_spl_calendar_event_body` with `_spl_calendar_require_actor "$agent" "$ordby" || return 1`.
  235 -> 243 lines (`+10 -2`).
- `orc:src/bash/run/spl-calendar-event-delete.func.sh`: replace `:35-36` in
  `_spl_calendar_event_each` with `# shellcheck source=spl-calendar-event-add.func.sh`,
  `declare -F _spl_calendar_require_actor >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-calendar-event-add.func.sh"`,
  and `_spl_calendar_require_actor "$agent" "$ordby" || return 1`. 99 -> 100 lines
  (`+3 -2`).
- `orc:src/bash/run/spl-calendar-event-update.func.sh`: replace `:103-104` in
  `_spl_calendar_update_body` with the same 3 lines. 127 -> 128 lines (`+3 -2`).
- `orc:src/bash/tests/spl-calendar-event-add.tst.sh`: append section 8 before `:158`
  (`ALL PASS`): 3 direct `_spl_calendar_require_actor` checks (accepts new `c-840` +
  `HUM-10` and legacy `CLE-1` + empty; refuses bad `AGENT_ID=HUM-10` with exact FATAL;
  refuses bad `ORDERED_BY=bob` with exact FATAL) and 1 one-copy check (each FATAL string
  appears once in `spl-calendar-event-add.func.sh`, which calls
  `_spl_calendar_require_actor`). 158 -> 169 lines (`+11 -0`).
- `orc:src/bash/tests/spl-calendar-event-change.tst.sh`: append section 6 before `:111`
  (`ALL PASS`): 2 one-copy checks (neither `spl-calendar-event-delete.func.sh` nor
  `spl-calendar-event-update.func.sh` contains `AGENT_ID must be an agent id` or
  `ORDERED_BY must be a HUM-\* id`, and both call `_spl_calendar_require_actor`) plus 2
  standalone lazy-load checks (sourcing only `spl-cloud-cnf.func.sh` and the target
  `.func.sh` — without pre-sourcing `spl-calendar-event-add.func.sh` — invokes
  `do_spl_calendar_event_delete` / `do_spl_calendar_event_update` with `AGENT_ID=HUM-10`
  and asserts rc 1, `FATAL AGENT_ID must be an agent id`, and no `command not found`).
  111 -> 133 lines (`+22 -0`).
- head1's files, sha256 (12 chars): `spl-calendar-event-add.func.sh` `d71d9d3dfa83`,
  `spl-calendar-event-delete.func.sh` `9667ab90e009`,
  `spl-calendar-event-update.func.sh` `9331b997770a`,
  `spl-calendar-event-add.tst.sh` `2ec18079688e`,
  `spl-calendar-event-change.tst.sh` `6ceaed529f18`.
- Note for the row and its reviewer (N4): under `./run`, `run.sh`'s lazy stub loader
  always defines a stub for `_spl_calendar_require_actor`, so the
  `declare -F _spl_calendar_require_actor >/dev/null || source ...` guard acts only on
  the standalone-source path outside `./run` (`spl-calendar-event-update.func.sh:62,111`
  already calls `_spl_calendar_event_link` and `_spl_calendar_reminders` from
  `spl-calendar-event-add.func.sh` unguarded). Thus `gc1a` and `gc1b` prove the
  standalone-source path. Build any guard control (`gc1a`/`gc1b`) in a worktree, not a
  temp-dir copy of a single `.func.sh`: the guard loads its sibling
  `spl-calendar-event-add.func.sh` by `dirname "${BASH_SOURCE[0]}"`.

Verbatim helper and test hunks (head1 on `7084439f1`, W1):

`orc:src/bash/run/spl-calendar-event-add.func.sh` (inserted immediately above
`# _spl_calendar_event_body:` at `:193`, followed by one blank line):
```bash
# _spl_calendar_require_actor <agent> <ordered_by>: validate AGENT_ID and
# optional ORDERED_BY for the calendar event write actions (add, delete/pin,
# update); logs FATAL and returns 1 on mismatch.
_spl_calendar_require_actor() {
  local agent="$1" ordby="$2"
  [[ "$agent" =~ ^[acgmq]-[0-9]{3,}$ || "$agent" =~ ^(CLE|AGY|GRK|QWN)-[0-9]+$ ]] || { do_log "FATAL AGENT_ID must be an agent id like c-042, got: '$agent'"; return 1; }
  [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
}
```

`orc:src/bash/tests/spl-calendar-event-add.tst.sh` section 8 (inserted immediately before
`(( fails == 0 )) && echo "ALL PASS: spl-calendar-event-add" || { echo "FAILED: $fails"; exit 1; }`
at `:158`, followed by one blank line):
```bash
# --- 8. _spl_calendar_require_actor (r98-01 one copy) --------------------------
out=$(bash -c 'do_log(){ echo "$*"; }; source "'"$PROJ_ROOT"'/src/bash/run/spl-calendar-event-add.func.sh"; _spl_calendar_require_actor c-840 HUM-10 && _spl_calendar_require_actor CLE-1 ""' 2>&1); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && pass "8. _spl_calendar_require_actor accepts new/legacy agent and optional HUM-*" || fail "8. actor ok: rc=$rc $out"
out=$(bash -c 'do_log(){ echo "$*"; }; source "'"$PROJ_ROOT"'/src/bash/run/spl-calendar-event-add.func.sh"; _spl_calendar_require_actor HUM-10 ""' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL AGENT_ID must be an agent id like c-042, got: 'HUM-10'"* ]] && pass "8. _spl_calendar_require_actor refuses bad AGENT_ID" || fail "8. bad agent: rc=$rc $out"
out=$(bash -c 'do_log(){ echo "$*"; }; source "'"$PROJ_ROOT"'/src/bash/run/spl-calendar-event-add.func.sh"; _spl_calendar_require_actor c-840 bob' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL ORDERED_BY must be a HUM-* id, got: 'bob'"* ]] && pass "8. _spl_calendar_require_actor refuses bad ORDERED_BY" || fail "8. bad ordby: rc=$rc $out"
add_f="$PROJ_ROOT/src/bash/run/spl-calendar-event-add.func.sh"
[[ "$(grep -c "AGENT_ID must be an agent id" "$add_f")" -eq 1 && "$(grep -c "ORDERED_BY must be a HUM-\* id" "$add_f")" -eq 1 && "$(grep -c "_spl_calendar_require_actor " "$add_f")" -ge 1 ]] \
  && pass "8. one copy: spl-calendar-event-add.func.sh defines and calls _spl_calendar_require_actor once" || fail "8. add one copy"
```

`orc:src/bash/tests/spl-calendar-event-change.tst.sh` section 6 (inserted immediately
before `(( fails == 0 )) && echo "ALL PASS: spl-calendar-event-change" || { echo "FAILED: $fails"; exit 1; }`
at `:111`, followed by one blank line):
```bash
# --- 6. r98-01 one copy and standalone lazy-source -----------------------------
for f in spl-calendar-event-delete.func.sh spl-calendar-event-update.func.sh; do
  fp="$PROJ_ROOT/src/bash/run/$f"
  own="$(grep -nE "AGENT_ID must be an agent id|ORDERED_BY must be a HUM-\* id" "$fp" || true)"
  [[ -z "$own" ]] && grep -q "_spl_calendar_require_actor " "$fp" \
    && pass "6. one copy: $f delegates to _spl_calendar_require_actor" || fail "6. one copy $f: own=[$own]"
done
out=$(env PROJ_PATH="$PROJ_ROOT" ENV=dev TENANT_ID=wa EVENT_IDS="$A" AGENT_ID=HUM-10 bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ :; }
  source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-calendar-event-delete.func.sh"
  do_spl_calendar_event_delete' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL AGENT_ID must be an agent id"* && "$out" != *"command not found"* ]] \
  && pass "6. lazy load: spl-calendar-event-delete.func.sh loads _spl_calendar_require_actor standalone" || fail "6. lazy delete: rc=$rc $out"
out=$(env PROJ_PATH="$PROJ_ROOT" ENV=dev TENANT_ID=wa EVENT_ID="$A" AGENT_ID=HUM-10 TITLE=x bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ :; }
  source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-calendar-event-update.func.sh"
  do_spl_calendar_event_update' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL AGENT_ID must be an agent id"* && "$out" != *"command not found"* ]] \
  && pass "6. lazy load: spl-calendar-event-update.func.sh loads _spl_calendar_require_actor standalone" || fail "6. lazy update: rc=$rc $out"
```

**Behaviour:** `_spl_calendar_require_actor "$agent" "$ordby"` executes the exact two
regex tests and `do_log "FATAL ..."; return 1` messages removed from all three actions;
all row-01 and shared suites pass on base and head1 with identical counts plus the 4 + 4
new checks (1.5).

### 1.4 Row 02's site: `spl-estate-cost-read.func.sh` and `spl-vm-cost-per-day.func.sh` share `do_spl_cost_gcp_window` in `spl-cost-gcp.func.sh`

`iac:` = `csi-spl-iac/`. On `7084439f1`:

- `iac:src/bash/run/spl-estate-cost-read.func.sh:56-66` (in `do_spl_estate_cost_read`)
  and `iac:src/bash/run/spl-vm-cost-per-day.func.sh:47-57` (in `do_spl_vm_cost_per_day`)
  duplicate the exact 11-line UTC `DAY` validation + OAP resolve + cnf load + trailing
  `COST_REREAD_DAYS` day-window loop:
  ```bash
    local day="${DAY:-$(date -u -d yesterday +%F)}"
    if [[ ! "${day}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$(date -u -d "${day}" +%F 2>/dev/null)" != "${day}" ]]; then
      do_log "FATAL DAY must be a UTC day YYYY-MM-DD, got: ${day}"; return 1
    fi

    do_resolve_oap ORG
    do_resolve_oap APP
    do_spl_cost_gcp_cnf || return 1
    local -a days=()
    local i
    for ((i = COST_REREAD_DAYS - 1; i >= 0; i--)); do days+=("$(date -u -d "${day} -${i} day" +%F)"); done
  ```
  (with `local i tmp` on `:56` of `spl-vm-cost-per-day.func.sh`, where `tmp` is assigned
  on `:58`).
- `diff -u <(git show 7084439f1:csi-spl-iac/src/bash/run/spl-estate-cost-read.func.sh | sed -n '56,66p') <(git show 7084439f1:csi-spl-iac/src/bash/run/spl-vm-cost-per-day.func.sh | sed -n '47,57p' | sed 's/local i tmp/local i/')`
  -> no hunk (rc 0, n=1): the two 11-line blocks are **identical** up to the unrelated
  `tmp` local declaration.
- `do_spl_cost_gcp_window` has **0 collisions** anywhere in the repo (`git grep` -> 0).
  `iac:lib/bash/funcs/spl-cost-gcp.func.sh` is already the shared library for GCP cost
  actions (`do_spl_cost_gcp_cnf`, `do_gcp_bq_api`, `do_gcp_bq_error`): in `csi-spl-iac/run`
  it is lazily stub-loaded (`csi-spl-iac/src/bash/run/run.sh:883-891`, `_RUN_INDEX_AWK`: a
  functions-only file is not sourced at start; each of its functions gets a stub that
  sources the file on first call, N2), and both tests (`spl-estate-cost-read.tst.sh` and
  `spl-vm-cost-per-day.tst.sh`) source it directly, so neither action needs an extra
  `source` line.
- Shellcheck detail verified on head2: because `do_spl_cost_gcp_cnf` (`spl-cost-gcp.func.sh:29`)
  takes an optional `$1` cnf dir used only by tests (`@param $1 (optional)`), calling
  `do_spl_cost_gcp_cnf || return 1` with zero arguments inside the same file triggers
  `SC2120` unless `:28` updates `# shellcheck disable=SC2034` to
  `# shellcheck disable=SC2034,SC2120 # COST_* globals read by callers; optional $1 cnf dir used by tests`
  (matching the repo idiom at `orc:lib/bash/funcs/spl-cloud-cnf.func.sh:608`). That
  preserves zero-arg calls (`$# == 0`) identically to base and passes both
  `shellcheck -S warning -x` and `do_sec_shellcheck` with zero new findings.
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `do_spl_cost_gcp_window` is 14 lines;
  `do_spl_estate_cost_read` 39 -> 31 lines; `do_spl_vm_cost_per_day`
  34 -> 26 lines. None of the 5 files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `iac:lib/bash/funcs/spl-cost-gcp.func.sh`: update `:28` to
  `# shellcheck disable=SC2034,SC2120 # COST_* globals read by callers; optional $1 cnf dir used by tests`,
  and insert `do_spl_cost_gcp_window()` (with `@description` / `@example` header
  documenting process globals `COST_WINDOW_DAY` and `COST_WINDOW_DAYS`, N3, and
  `# shellcheck disable=SC2034`) above `do_gcp_bq_api` (`:64`), setting
  `COST_WINDOW_DAY="${day}"` and populating `COST_WINDOW_DAYS=()` across
  `COST_REREAD_DAYS - 1 .. 0`. 101 -> 124 lines (`+24 -1`).
- `iac:src/bash/run/spl-estate-cost-read.func.sh`: replace `:56-66` with
  `do_spl_cost_gcp_window || return 1`, `local day="${COST_WINDOW_DAY}"`, and
  `local -a days=("${COST_WINDOW_DAYS[@]}")`. 279 -> 271 lines (`+3 -11`).
- `iac:src/bash/run/spl-vm-cost-per-day.func.sh`: replace `:47-57` with
  `do_spl_cost_gcp_window || return 1`, `local day="${COST_WINDOW_DAY}" tmp`, and
  `local -a days=("${COST_WINDOW_DAYS[@]}")`. 158 -> 150 lines (`+3 -11`).
- `iac:src/bash/tests/spl-estate-cost-read.tst.sh`: append section 8 before `:247`
  (`PASS: all ...`): 2 direct `do_spl_cost_gcp_window` checks (`DAY=2026-10-09` with
  `ENV=prd` cnf sets `COST_WINDOW_DAY=2026-10-09` and the 5-day trailing
  `COST_WINDOW_DAYS` `2026-10-05..2026-10-09`; `DAY=2026-02-30` returns 1 with exact
  `FATAL DAY must be a UTC day YYYY-MM-DD, got: 2026-02-30`) and 1 one-copy check
  (`$F` contains neither `FATAL DAY must be a UTC day` nor `COST_REREAD_DAYS - 1`, and
  calls `do_spl_cost_gcp_window`). 248 -> 264 lines (`+16 -0`).
- `iac:src/bash/tests/spl-vm-cost-per-day.tst.sh`: append section 6 before `:188`
  (`PASS: all ...`): 1 one-copy check (`$F` contains neither `FATAL DAY must be a UTC day`
  nor `COST_REREAD_DAYS - 1`, and calls `do_spl_cost_gcp_window`). 189 -> 194 lines
  (`+5 -0`).
- head2's files, sha256 (12 chars): `spl-cost-gcp.func.sh` `b1ddd1ea1c94`,
  `spl-estate-cost-read.func.sh` `c8e2c0b78ffd`,
  `spl-vm-cost-per-day.func.sh` `a8f4dae10e4d`,
  `spl-estate-cost-read.tst.sh` `21782c35e31e`,
  `spl-vm-cost-per-day.tst.sh` `d81229828708`.

Verbatim helper and test hunks (head2 on `7084439f1`, W1, N3):

`iac:lib/bash/funcs/spl-cost-gcp.func.sh` (inserted immediately above the `#---...`
separator of `do_gcp_bq_api` at `:64`, followed by one blank line):
```bash
#------------------------------------------------------------------------------
# @description Validate DAY (default yesterday UTC), resolve ORG/APP, load cnf
# @description env.cost (do_spl_cost_gcp_cnf), and build the trailing
# @description COST_REREAD_DAYS UTC day window, setting process globals
# @description COST_WINDOW_DAY and COST_WINDOW_DAYS.
# @example do_spl_cost_gcp_window || return 1
#------------------------------------------------------------------------------
# shellcheck disable=SC2034 # COST_WINDOW_DAY / COST_WINDOW_DAYS are read by callers
do_spl_cost_gcp_window() {
  local day="${DAY:-$(date -u -d yesterday +%F)}" i
  if [[ ! "${day}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$(date -u -d "${day}" +%F 2>/dev/null)" != "${day}" ]]; then
    do_log "FATAL DAY must be a UTC day YYYY-MM-DD, got: ${day}"; return 1
  fi
  do_resolve_oap ORG
  do_resolve_oap APP
  do_spl_cost_gcp_cnf || return 1
  COST_WINDOW_DAY="${day}"
  COST_WINDOW_DAYS=()
  for ((i = COST_REREAD_DAYS - 1; i >= 0; i--)); do
    COST_WINDOW_DAYS+=("$(date -u -d "${day} -${i} day" +%F)")
  done
}
```

`iac:src/bash/tests/spl-estate-cost-read.tst.sh` section 8 (inserted immediately before
`[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }` at
`:247`, followed by one blank line):
```bash
# --- 8. do_spl_cost_gcp_window (r98-02 one copy) -----------------------------------
out=$(env APP_PATH="$APP_ROOT" ENV=prd DAY=2026-10-09 LIB="$LIB" bash -c '
  do_log(){ echo "$*"; }; do_resolve_oap(){ case "$1" in ORG) ORG=csi ;; APP) APP=spl ;; esac; }
  source "$LIB"; do_spl_cost_gcp_window || exit 1
  printf "%s|%s\n" "$COST_WINDOW_DAY" "${COST_WINDOW_DAYS[*]}"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "2026-10-09|2026-10-05 2026-10-06 2026-10-07 2026-10-08 2026-10-09" ]] \
  && pass "8. do_spl_cost_gcp_window sets COST_WINDOW_DAY and trailing COST_WINDOW_DAYS" || fail "8. window ok: rc=$rc $out"
out=$(env APP_PATH="$APP_ROOT" ENV=prd DAY=2026-02-30 LIB="$LIB" bash -c '
  do_log(){ echo "$*"; }; do_resolve_oap(){ case "$1" in ORG) ORG=csi ;; APP) APP=spl ;; esac; }
  source "$LIB"; do_spl_cost_gcp_window' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL DAY must be a UTC day YYYY-MM-DD, got: 2026-02-30"* ]] \
  && pass "8. do_spl_cost_gcp_window refuses bad DAY" || fail "8. window bad day: rc=$rc $out"
own="$(grep -nE "FATAL DAY must be a UTC day|COST_REREAD_DAYS - 1" "$F" || true)"
[[ -z "$own" ]] && grep -q "do_spl_cost_gcp_window" "$F" \
  && pass "8. one copy: spl-estate-cost-read.func.sh delegates window prep to do_spl_cost_gcp_window" || fail "8. estate one copy: own=[$own]"
```

`iac:src/bash/tests/spl-vm-cost-per-day.tst.sh` section 6 (inserted immediately before
`[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }` at
`:188`, followed by one blank line):
```bash
# --- 6. r98-02 one copy ------------------------------------------------------------
own="$(grep -nE "FATAL DAY must be a UTC day|COST_REREAD_DAYS - 1" "$F" || true)"
[[ -z "$own" ]] && grep -q "do_spl_cost_gcp_window" "$F" \
  && pass "6. one copy: spl-vm-cost-per-day.func.sh delegates window prep to do_spl_cost_gcp_window" || fail "6. vm one copy: own=[$own]"
```

**Behaviour:** `do_spl_cost_gcp_window` executes the exact UTC `DAY` validation,
`do_resolve_oap ORG`/`APP`, `do_spl_cost_gcp_cnf || return 1`, and `COST_REREAD_DAYS`
loop removed from both actions; its only new state is the two process globals
`COST_WINDOW_DAY` and `COST_WINDOW_DAYS` documented in its header (N3);
`gcp-billing-export-setup.func.sh` and `gcp-billing-invoices-fetch.func.sh` remain
untouched and green; all row-02 and shared suites pass on base and head2 with identical
counts plus the 3 + 1 new checks (1.5).

### 1.5 Before and on the rows' heads

2026-11-25T05:59:40Z-06:03:43Z (full 15-suite matrix across base, head1 for row 01 +
shared, head2 for row 02 + shared, `shellcheck -S warning -x`, `do_sec_shellcheck`, and
controls `rc1a`/`rc1b`/`gc1a`/`gc1b`/`rc2a`/`rc2b`/`gc2`), n=1, as the push user,
`SPOOL_TEST=1` with `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`
(needed by `gcp-billing-invoices.tst.sh`'s no-terminal refusal case when launched under a
PTY); pass lines `grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`.
"=" means equal to base: same rc, pass and fail counts; "-" means that row's head does
not touch the suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/spl-calendar-event-add.tst.sh` | 01 | 0 / 66 / 0 | 0 / 70 / 0 (+4 new checks) | - |
| `orc:src/bash/tests/spl-calendar-event-change.tst.sh` | 01 | 0 / 33 / 0 | 0 / 37 / 0 (+4 new checks) | - |
| `orc:src/bash/tests/spl-calendar-event-update.tst.sh` | 01 | 0 / 34 / 0 | = | - |
| `iac:src/bash/tests/spl-estate-cost-read.tst.sh` | 02 | 0 / 33 / 0 | - | 0 / 36 / 0 (+3 new checks) |
| `iac:src/bash/tests/spl-vm-cost-per-day.tst.sh` | 02 | 0 / 30 / 0 | - | 0 / 31 / 0 (+1 new check) |
| `iac:src/bash/tests/gcp-billing-export-setup.tst.sh` | 02 | 0 / 30 / 0 | - | = |
| `iac:src/bash/tests/gcp-billing-invoices.tst.sh` | 02 | 0 / 69 / 0 | - | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

Note: `spl-estate-cost-read.tst.sh` and `spl-vm-cost-per-day.tst.sh` print a final
`PASS: all <script> assertions` summary line on rc 0 (and `FAIL: <n> assertion(s) in ...`
on rc 1), which `grep -ciE '^ *(ok|pass)'` and `grep -ciE '^ *(not ok|fail)'` count
(e.g., `spl-estate-cost-read.tst.sh` 33 on base = 32 assertions + 1 summary; 36 on head2
= 35 assertions + 1 summary; `spl-vm-cost-per-day.tst.sh` 30 on base = 29 + 1; 31 on
head2 = 30 + 1). The calendar suites print `ALL PASS: ...` on rc 0 (not counted) and
`FAILED: <n>` on rc 1 (counted as 1 extra fail line).

`shellcheck -S warning -x` on all 10 row files (base, head1, head2): **rc 0**, no
findings (n=1 each). `do_sec_shellcheck` with newline-separated `SEC_SHELLCHECK_FILES`
set to each row's 5 touched files (head1 and head2): **rc 0**, `no error-level findings`,
`no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `7084439f1`,
reconstructed from the verbatim blocks in 1.3 and 1.4; `gc1a`/`gc1b` prove the
standalone-source path outside `./run`, N4; head2 `b1ddd1ea1c94` and controls `rc2a`,
`rc2b`, `gc2` re-verified 2026-11-25T06:37:55Z-06:38:53Z after N3's header line update):
- Row 01 red control a (`rc1a`, head1's `spl-calendar-event-add.tst.sh` on base): rc 1,
  66 pass, 5 fail lines (4 assertions: `FAIL: 8. actor ok: rc=127 ... _spl_calendar_require_actor: command not found`,
  `bad agent` rc 127, `bad ordby` rc 127, `FAIL: 8. add one copy`, plus summary
  `FAILED: 4`); head1: rc 0, 70 pass, 0 fail.
- Row 01 red control b (`rc1b`, head1's `spl-calendar-event-change.tst.sh` on base): rc 1,
  35 pass, 3 fail lines (2 assertions: `FAIL: 6. one copy spl-calendar-event-delete.func.sh: own=[35: ...]`
  and `FAIL: 6. one copy spl-calendar-event-update.func.sh: own=[103: ...]`, plus summary
  `FAILED: 2`; the 2 standalone lazy-load checks pass on base because base validates
  inline); head1: rc 0, 37 pass, 0 fail.
- Row 01 guard control a (`gc1a`, head1 with the `declare -F _spl_calendar_require_actor`
  lazy-source line deleted in `spl-calendar-event-delete.func.sh`): rc 1, 36 pass, 2 fail
  lines (`FAIL: 6. lazy delete: rc=1 .../spl-calendar-event-delete.func.sh: line 36: _spl_calendar_require_actor: command not found`,
  plus `FAILED: 1`).
- Row 01 guard control b (`gc1b`, head1 with the `declare -F _spl_calendar_require_actor`
  lazy-source line deleted in `spl-calendar-event-update.func.sh`): rc 1, 36 pass, 2 fail
  lines (`FAIL: 6. lazy update: rc=1 .../spl-calendar-event-update.func.sh: line 104: _spl_calendar_require_actor: command not found`,
  plus `FAILED: 1`).
- Row 02 red control a (`rc2a`, head2's `spl-estate-cost-read.tst.sh` on base): rc 1, 32
  pass, 4 fail lines (3 assertions: `FAIL: 8. window ok: rc=1 ... do_spl_cost_gcp_window: command not found`,
  `FAIL: 8. window bad day: rc=127 ... do_spl_cost_gcp_window: command not found`,
  `FAIL: 8. estate one copy: own=[58: ... FATAL DAY must be a UTC day ...]`, plus summary
  `FAIL: 3 assertion(s)`); head2: rc 0, 36 pass, 0 fail.
- Row 02 red control b (`rc2b`, head2's `spl-vm-cost-per-day.tst.sh` on base): rc 1, 29
  pass, 2 fail lines (1 assertion: `FAIL: 6. vm one copy: own=[49: ... FATAL DAY must be a UTC day ...]`,
  plus summary `FAIL: 1 assertion(s)`); head2: rc 0, 31 pass, 0 fail.
- Row 02 guard control (`gc2`, head2 with `do_spl_cost_gcp_window` renamed to
  `do_spl_cost_gcp_window_disabled` in `spl-cost-gcp.func.sh`): `spl-estate-cost-read.tst.sh`
  rc 1, 7 pass, 29 fail lines (`spl-estate-cost-read.func.sh: line 56: do_spl_cost_gcp_window: command not found`);
  `spl-vm-cost-per-day.tst.sh` rc 1, 10 pass, 21 fail lines
  (`spl-vm-cost-per-day.func.sh: line 47: do_spl_cost_gcp_window: command not found`).

The tests that name the sites (R2): `git grep -lE` over `*.tst.sh` for
`spl-calendar-event-(add|delete|update)|spl-cost-gcp|spl-estate-cost-read|spl-vm-cost-per-day`
-> `spl-calendar-event-add.tst.sh`, `spl-calendar-event-change.tst.sh` (via
`do_spl_calendar_event_delete` / `do_spl_calendar_event_update`),
`spl-calendar-event-update.tst.sh` for row 01; `spl-estate-cost-read.tst.sh`,
`spl-vm-cost-per-day.tst.sh`, `gcp-billing-export-setup.tst.sh`,
`gcp-billing-invoices.tst.sh` for row 02 (plus the 8 shared iac/orc gates). 30-char
non-separator, non-shellcheck comment grep across all `*.tst.sh` -> hits only inside
already-included suites (`spl-calendar-event-change.tst.sh` and
`spl-vm-cost-per-day.tst.sh`). No new test file is added, so `orc-shard-weights.txt`
needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r98-01-orc-calendar-actor)` | one fact, one copy (developer guide 2.2.4) | `spl-calendar-event-add.func.sh:203-204`, `spl-calendar-event-delete.func.sh:35-36`, and `spl-calendar-event-update.func.sh:103-104` duplicate the exact 2-line `AGENT_ID` + optional `ORDERED_BY` check (1.3, r97 section 7) | `orc:src/bash/run/spl-calendar-event-add.func.sh:193,203-204`<br>`orc:src/bash/run/spl-calendar-event-delete.func.sh:35-36`<br>`orc:src/bash/run/spl-calendar-event-update.func.sh:103-104`<br>`orc:src/bash/tests/spl-calendar-event-add.tst.sh:158`<br>`orc:src/bash/tests/spl-calendar-event-change.tst.sh:111` | copies of the calendar write `AGENT_ID` + optional `ORDERED_BY` guard 3 -> 1 (`_spl_calendar_require_actor` in `spl-calendar-event-add.func.sh`) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head's `spl-calendar-event-add.tst.sh` on parent FAILs 4 checks (`rc1a`, rc 1, 66 pass, 5 fail lines, `_spl_calendar_require_actor: command not found` + one-copy) and head's `spl-calendar-event-change.tst.sh` on parent FAILs both one-copy checks naming `:35` and `:103` (`rc1b`, rc 1, 35 pass, 3 fail lines), then GREEN (70/0 and 37/0); guard controls (`gc1a`/`gc1b`, `declare -F _spl_calendar_require_actor` deleted in delete/update: rc 1, 36 pass, 2 fail lines each with `_spl_calendar_require_actor: command not found`; proves standalone-source path outside `./run`, N4), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 4 + 4 new checks. Tests: `orc:.../spl-calendar-event-add.tst.sh`, `spl-calendar-event-change.tst.sh`, `spl-calendar-event-update.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r98-02-iac-cost-window-prep)` | one fact, one copy (developer guide 2.2.4) | `spl-estate-cost-read.func.sh:56-66` and `spl-vm-cost-per-day.func.sh:47-57` duplicate the exact 11-line UTC `DAY` validation, `do_resolve_oap ORG`/`APP`, `do_spl_cost_gcp_cnf`, and trailing `COST_REREAD_DAYS` day-window loop (1.4) | `iac:lib/bash/funcs/spl-cost-gcp.func.sh:28,64`<br>`iac:src/bash/run/spl-estate-cost-read.func.sh:56-66`<br>`iac:src/bash/run/spl-vm-cost-per-day.func.sh:47-57`<br>`iac:src/bash/tests/spl-estate-cost-read.tst.sh:247`<br>`iac:src/bash/tests/spl-vm-cost-per-day.tst.sh:188` | copies of the UTC `DAY` + OAP + `do_spl_cost_gcp_cnf` + `COST_REREAD_DAYS` window prep 2 -> 1 (`do_spl_cost_gcp_window` in `spl-cost-gcp.func.sh`) | 1.4's shape (verbatim blocks in 1.4; header documents process globals `COST_WINDOW_DAY` / `COST_WINDOW_DAYS`, N3). **Red control:** head's `spl-estate-cost-read.tst.sh` on parent FAILs 3 checks (`rc2a`, rc 1, 32 pass, 4 fail lines, `do_spl_cost_gcp_window: command not found` + one-copy `:58`) and head's `spl-vm-cost-per-day.tst.sh` on parent FAILs one-copy naming `:49` (`rc2b`, rc 1, 29 pass, 2 fail lines), then GREEN (36/0 and 31/0); guard control (`gc2`, `do_spl_cost_gcp_window` renamed in `spl-cost-gcp.func.sh`: `spl-estate-cost-read.tst.sh` rc 1 7/29 and `spl-vm-cost-per-day.tst.sh` rc 1 10/21 with `do_spl_cost_gcp_window: command not found`), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 3 + 1 new checks. Tests: `iac:.../spl-estate-cost-read.tst.sh`, `spl-vm-cost-per-day.tst.sh`, `gcp-billing-export-setup.tst.sh`, `gcp-billing-invoices.tst.sh` (`</dev/null`), `no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r98-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r98-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row extracts a duplicated guard/window block into one shared helper and
points its callers at the single home; no output, exit code, env var, path or file a
caller sees changes (1.3, 1.4, 1.5). Each: `Docs: none (<why>)`. The developer guide
2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `spl-calendar-event-add.func.sh`, `spl-calendar-event-delete.func.sh`,
  `spl-calendar-event-update.func.sh`, `spl-calendar-event-add.tst.sh`,
  `spl-calendar-event-change.tst.sh`; row 02: `csi-spl-iac`
  `lib/bash/funcs/spl-cost-gcp.func.sh`, `spl-estate-cost-read.func.sh`,
  `spl-vm-cost-per-day.func.sh`, `spl-estate-cost-read.tst.sh`,
  `spl-vm-cost-per-day.tst.sh`).
- No row edits `orc:src/bash/run/spl-human-email-add.func.sh`,
  `orc:src/bash/run/spl-human-link.func.sh`,
  `orc:src/bash/tests/spl-calendar-event-update.tst.sh`,
  `iac:src/bash/run/gcp-billing-export-setup.func.sh`,
  `iac:src/bash/run/gcp-billing-invoices-fetch.func.sh`,
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-utl/`, or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (10, the 5 edited by row 01 + the 5 edited by row 02):
`orc:src/bash/run/spl-calendar-event-add.func.sh`,
`orc:src/bash/run/spl-calendar-event-delete.func.sh`,
`orc:src/bash/run/spl-calendar-event-update.func.sh`,
`orc:src/bash/tests/spl-calendar-event-add.tst.sh`,
`orc:src/bash/tests/spl-calendar-event-change.tst.sh`;
`iac:lib/bash/funcs/spl-cost-gcp.func.sh`,
`iac:src/bash/run/spl-estate-cost-read.func.sh`,
`iac:src/bash/run/spl-vm-cost-per-day.func.sh`,
`iac:src/bash/tests/spl-estate-cost-read.tst.sh`,
`iac:src/bash/tests/spl-vm-cost-per-day.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent a-427`, one call per
  path and comma-separated, n=1, 2026-11-25T05:48:37Z-05:50:35Z: **exit 4 on all 10**
  ("no live lane lists <path>, but 17 live lane(s) record no files"). The 17 `unknown:`
  lanes, all on the other box (`lane-map.sh list`, 05:48:37Z): channel/workspace seats
  (`c-029`, `c-041`, `c-086`, `c-114`, `c-146`, `c-165`, `c-187`, `c-190`, `c-210`,
  `c-217`, `c-249`, `c-728`, `c-927`, `c-936`, `c-957`, `c-965` — other-repo, spec 195,
  spec 125, channel/workspace seats) and skills editor `c-774`. No lane owns any of the
  10 paths; none of those scopes touches `spl-calendar-event-*.func.sh`,
  `spl-cost-gcp.func.sh`, `spl-estate-cost-read.func.sh`, or
  `spl-vm-cost-per-day.func.sh`.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 05:39Z): 3 queued,
  0 placing: this round's claude panel seat (`c002-refactor-round-98-claude-panel-seat`),
  `c002-r97-close-record`, and `c001-s186-m9-n2-qto-sync`. None touches any of the 10
  paths.
- **Briefs on this box** changed in the last 24 h naming any of the 10 paths (05:48:40Z):
  **0**.
- **Remote branches committed in the last 24 h** (`git fetch --prune origin`, 05:48:45Z):
  `git diff --name-only $(git merge-base 7084439f1 <b>) <b> -- <the 10 paths>` -> **0 hits**.
- **Commits in the last 24 h** on those 10 paths (`git log 7084439f1 --since='24 hours ago'`)
  -> **0**.
- **Live cost-adjacent lane checked:** `c-298` (Taxes tab, spec 143) brief verified on
  this box: targets `csi-spl-wui/src/pages/reporting/costs/*` and hub route/store, NOT
  `csi-spl-iac` cost actions. Other active lanes (`c-296` blog, spec 154, spec 186,
  `c002-r97-close-record`) touch none of the 10 paths.

## 3. Per row: what the lane does

- **r98-01:** `orc:src/bash/run/spl-calendar-event-add.func.sh` gains
  `_spl_calendar_require_actor <agent> <ordered_by>` above `_spl_calendar_event_body`
  (`:193`), and `_spl_calendar_event_body` replaces `:203-204` with
  `_spl_calendar_require_actor "$agent" "$ordby" || return 1`;
  `orc:src/bash/run/spl-calendar-event-delete.func.sh` (`:35-36`) and
  `orc:src/bash/run/spl-calendar-event-update.func.sh` (`:103-104`) drop their duplicate
  2-line checks, lazy-source `spl-calendar-event-add.func.sh` behind a
  `declare -F _spl_calendar_require_actor` guard, and call
  `_spl_calendar_require_actor "$agent" "$ordby" || return 1`.
  `orc:src/bash/tests/spl-calendar-event-add.tst.sh` appends 3 direct
  `_spl_calendar_require_actor` checks + 1 one-copy check;
  `orc:src/bash/tests/spl-calendar-event-change.tst.sh` appends 2 one-copy checks + 2
  standalone lazy-load checks for delete and update.
- **r98-02:** `iac:lib/bash/funcs/spl-cost-gcp.func.sh` updates `:28` to
  `# shellcheck disable=SC2034,SC2120` and gains `do_spl_cost_gcp_window` above
  `do_gcp_bq_api` (`:64`), documenting and setting process globals `COST_WINDOW_DAY` and
  `COST_WINDOW_DAYS=()` (N3);
  `iac:src/bash/run/spl-estate-cost-read.func.sh` (`:56-66`) and
  `iac:src/bash/run/spl-vm-cost-per-day.func.sh` (`:47-57`) replace their 11-line UTC
  `DAY` validation + OAP resolve + `do_spl_cost_gcp_cnf` + `COST_REREAD_DAYS` window
  blocks with `do_spl_cost_gcp_window || return 1`, `local day="${COST_WINDOW_DAY}"`
  (plus `tmp` in vm), and `local -a days=("${COST_WINDOW_DAYS[@]}")`.
  `iac:src/bash/tests/spl-estate-cost-read.tst.sh` appends 2 direct
  `do_spl_cost_gcp_window` checks + 1 one-copy check;
  `iac:src/bash/tests/spl-vm-cost-per-day.tst.sh` appends 1 one-copy check.

## 4. Panel and reviewers (R7)

- Editor: **a-427** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; brief
  step 5; mistral sits on no review since 2026-11-25): **c-429** (claude,
  `c002-refactor-round-98-claude-panel-seat`), reviewing v0.1 on
  `review/c002-refactor-round-98-planner` (seat file
  `csi-spl-doc/doc/md/refactor-round-98/seat-claude.md`, branch
  `review/c002-refactor-round-98-claude-seat`). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-25T05:38:57Z ->
    `pick=hold` (grok weekly >= 95% or unknown on both boxes; `do_spl_lane_mix` also
    reports `kinds off grok,qwen`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`, replacing `5fb1bdab`) and `do_spl_lane_mix`
    (`code_review`: `main=agy backup=claude`), R7 review of a claude coding row goes to
    an **agy seat** per row (claude backup only while agy is out of quota; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 2026-11-25T05:39:00Z picked an
    available box; the holder re-checks agy capacity at row placement and uses the claude
    backup only if agy is out of quota.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r98-01 | `c002-r98-01-orc-calendar-actor` | `refactor(r98-01-orc-calendar-actor, SPL-<row issue>): ...` | `review/r98-01` | 1 |
| r98-02 | `c002-r98-02-iac-cost-window-prep` | `refactor(r98-02-iac-cost-window-prep, SPL-<row issue>): ...` | `review/r98-02` | 1 |

**r98-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-calendar-event-add.func.sh` (add
`_spl_calendar_require_actor` above `_spl_calendar_event_body` `:193`, replace `:203-204`
with `_spl_calendar_require_actor "$agent" "$ordby" || return 1`),
`csi-spl-orc/src/bash/run/spl-calendar-event-delete.func.sh` (replace `:35-36` with
`declare -F _spl_calendar_require_actor` lazy-source of sibling
`spl-calendar-event-add.func.sh` and `_spl_calendar_require_actor "$agent" "$ordby" || return 1`),
`csi-spl-orc/src/bash/run/spl-calendar-event-update.func.sh` (replace `:103-104` with the
same 3 lines), `csi-spl-orc/src/bash/tests/spl-calendar-event-add.tst.sh` (append section
8: 3 direct `_spl_calendar_require_actor` checks + 1 one-copy check before `:158`), and
`csi-spl-orc/src/bash/tests/spl-calendar-event-change.tst.sh` (append section 6: 2
one-copy checks + 2 standalone lazy-load checks for delete and update before `:111`). NOT
`spl-human-email-add.func.sh`, NOT `spl-human-link.func.sh`, NOT
`spl-calendar-event-update.tst.sh`, NOT `.shellcheck-warning-baseline.txt`, or any other
file. Do: plan section 2 row 01 verbatim, 1.3's shape (verbatim blocks in 1.3); red
controls (`rc1a` + `rc1b`, head's tests on parent) RED then GREEN in the body; guard
controls (`gc1a` + `gc1b`, `declare -F _spl_calendar_require_actor` deleted in
delete/update, built in a worktree, not a temp-dir copy; note `declare -F` acts only on
the standalone-source path outside `./run`, as `spl-calendar-event-update.func.sh:62,111`
already calls `add`'s helpers unguarded under `./run`, N4). Gates: the row's tests
(section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 5 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude backup only while agy is out of quota, which is
same-vendor to the claude author under rulebook 2.7.2 and valid only under ruling
`dc84300a` — cite ruling `dc84300a` in the row brief if the claude backup is used, N5;
never mistral; re-checked at placement).

**r98-02 brief, Files: ONLY**
`csi-spl-iac/lib/bash/funcs/spl-cost-gcp.func.sh` (update `:28` to
`# shellcheck disable=SC2034,SC2120`, add `do_spl_cost_gcp_window` above `do_gcp_bq_api`
`:64`, documenting in its header that it sets process globals `COST_WINDOW_DAY` and
`COST_WINDOW_DAYS=()`, N3),
`csi-spl-iac/src/bash/run/spl-estate-cost-read.func.sh` (replace `:56-66` with
`do_spl_cost_gcp_window || return 1`, `local day="${COST_WINDOW_DAY}"`,
`local -a days=("${COST_WINDOW_DAYS[@]}")`),
`csi-spl-iac/src/bash/run/spl-vm-cost-per-day.func.sh` (replace `:47-57` with
`do_spl_cost_gcp_window || return 1`, `local day="${COST_WINDOW_DAY}" tmp`,
`local -a days=("${COST_WINDOW_DAYS[@]}")`),
`csi-spl-iac/src/bash/tests/spl-estate-cost-read.tst.sh` (append section 8: 2 direct
`do_spl_cost_gcp_window` checks + 1 one-copy check before `:247`), and
`csi-spl-iac/src/bash/tests/spl-vm-cost-per-day.tst.sh` (append section 6: 1 one-copy
check before `:188`). NOT `gcp-billing-export-setup.func.sh`, NOT
`gcp-billing-invoices-fetch.func.sh`, NOT `.shellcheck-warning-baseline.txt`, or any
other file. Do: plan section 2 row 02 verbatim, 1.4's shape (verbatim blocks in 1.4); red
controls (`rc2a` + `rc2b`, head's tests on parent) RED then GREEN in the body; guard
control (`gc2`, `do_spl_cost_gcp_window` renamed in `spl-cost-gcp.func.sh`, built in a
worktree). Gates: the row's tests (section 2, `SPOOL_TEST=1`, `</dev/null` on
`gcp-billing-invoices.tst.sh`, in the worktree), `shellcheck -S warning -x` on the 5
files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude; R7 **agy seat** (claude backup only while agy is out of
quota, which is same-vendor to the claude author under rulebook 2.7.2 and valid only
under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the claude backup is
used, N5; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the calendar write `AGENT_ID` + optional `ORDERED_BY` guard (1.3) | 3 on `7084439f1` (`spl-calendar-event-add`, `spl-calendar-event-delete`, `spl-calendar-event-update`) -> 1 (`_spl_calendar_require_actor`) after row 01 |
| copies of the UTC `DAY` + OAP + `do_spl_cost_gcp_cnf` + `COST_REREAD_DAYS` window prep (1.4) | 2 on `7084439f1` (`spl-estate-cost-read`, `spl-vm-cost-per-day`) -> 1 (`do_spl_cost_gcp_window`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spl-calendar-event-add.func.sh` +10 -2, `spl-calendar-event-delete.func.sh` +3 -2, `spl-calendar-event-update.func.sh` +3 -2, `spl-calendar-event-add.tst.sh` +11 -0, `spl-calendar-event-change.tst.sh` +22 -0; row 02: `spl-cost-gcp.func.sh` +24 -1, `spl-estate-cost-read.func.sh` +3 -11, `spl-vm-cost-per-day.func.sh` +3 -11, `spl-estate-cost-read.tst.sh` +16 -0, `spl-vm-cost-per-day.tst.sh` +5 -0 |
| measured on | `7084439f1`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-human-email-add.func.sh:103-104` and `spl-human-link.func.sh:83-84` (`AGENT_ID` + `ORDERED_BY` guards) | different semantics from calendar actions: strictly 3-digit new agent ids (`^[acgmq]-[0-9]{3}$`, rejecting legacy `CLE-*` and 4+ digits) and required non-empty `ORDERED_BY` with a different FATAL wording (`ORDERED_BY must be the HUM-* id of the human who ordered it`); candidate for a separate small human-actor helper in r99+ | `git grep -n 'AGENT_ID must be\|ORDERED_BY must be' 7084439f1 -- csi-spl-orc/src/bash/run/` |
| `csi-spl-utl/src/bash/run/cron-heartbeat-snitch.func.sh:202` (`_chs_send`) and `reboot-required-check.func.sh:83` (`_rrc_send`) | 21-line bodies identical up to override var and missing-bin label, but touching `csi-spl-utl/**` classifies as `parts=all` in CI (`utl-suite.tst.sh:4`); strong candidate for a future round when `parts=all` CI time is budgeted | `git grep -n '^_chs_send()\|^_rrc_send()' 7084439f1 -- csi-spl-utl/src/bash/run/` |
| `csi-spl-utl/src/bash/scripts/{playwright-artifacts-sweep,review-worktree-sweep,workdir-sweep}.sh` (`scan_held` `:49,:70`, `is_held` `:54,:91,:123`, `say`/`refuse`/`as_root`/`as_owner`) | tests copy the script to `$T/ctl.sh` for red controls (breaking sibling source without changing test layout) and `csi-spl-utl/**` triggers `parts=all` | `git grep -n '^scan_held()\|^is_held()' 7084439f1 -- csi-spl-utl/src/bash/scripts/` |
| `orc:src/bash/run/{spl-accepted-close,spl-desk-poll-ack,spl-review-go}.func.sh` (`_spl_accepted_close_holder:104`, `_spl_poll_ack_holder:136`, `_spl_review_go_holder:162`) | 8-line bodies identical up to remote verb, but `spl-dispatch-lease.func.sh` pulls 30 tests into R2 (including slow `fleet-lease.tst.sh` and PG tests) and `spl-review-go.tst.sh:430` / `test-desk-user-hops.sh` stub the local helper names directly; good candidate for r99 with 1-line wrapper preservation | `git grep -n '_holder()' 7084439f1 -- csi-spl-orc/src/bash/run/` |
| `orc:src/bash/run/spl-lane-handover{,-agy,-mistral}.func.sh` | transcript-handling and key-material scan (session/secret-adjacent) with wide test surface | fresh scan (1.2 (e)) |
| `iac:src/bash/run/sec-*.func.sh` (`_sec_*_root` x8, `_sec_*_need` x7) and `orc:src/bash/scripts/*-cron.sh` (`check_tools` x14) | >5 sites per group and security-gate actions (`PRE_PUSH_TIER=full`, R9) | r97 7; 1.2 (e) |
| the 3 secret-class `iac:src/bash/run/` GitHub origin `<owner>/<repo>` parsers (`_sga_repo` in `spl-gh-app-manifest.func.sh:90-94`, `gh_box_token_repo` in `gh-box-token-check.func.sh:82-86`, `gh_secret_put_gcp_key_repo` in `gh-secret-put-gcp-key.func.sh:67-71`) | secret-class sites stay out of refactor rounds (brief rule); unchanged since r97 | r97 7; 1.2 (a) |
| other `peer/seats` readers (`spl_peer_seats`, `spl-watchdog.func.sh`, `spl-wd-ensure.func.sh`, `spawn-window.sh`) and `sa:lib/spool-fleet.inc.sh:29,100` `[root]` comment (r97-01 R7 N1) | different semantics from boolean existence (and `:29,100` `[root]` is a non-blocking doc nit, not a duplicate-code row); unchanged since r97 | r97 7; 1.2 (a), (b) |
| other `LEASE_(MASTER|FAILOVER|ORCH)` sites, `specs/172` prose (`:173`), `i18n-lang-review-exempt.json:2` `_doc` | non-identical path vars or prose/doc strings; unchanged since r94..r97 | r97 7; 1.2 (a) |
| Go duplicate helpers in `csi-spl-api/src/go/spool-hub-api` (`internal/hub`, `internal/hubclient`, `internal/store`, `keyd`/`lockkey`) and TS helpers in `csi-spl-wui` (`issueQuery`, `moveIndex`/`cycleIndex`, `capsError`, `browserStore`) | `csi-spl-api` hub/store requires `PRE_PUSH_TIER=full` Postgres gate and dev/prd deploy lag; `csi-spl-wui` requires Chrome e2e, Firebase deploy lag, and overlaps active WUI lanes (`c-298` Taxes tab, `c-296` blog) | r97 7; 1.2 (a), (e) |
| `for refactor round 95` (`c002-next-round-candidates.md:124-125`, WUI entry-chunk gzip headroom / eager-core split, `ci_initial_gzip_kb` 154.7 on `c41b7080e`, ceiling 155, blocker on SPL-6341 B13) | already served on `7084439f1` by SPL-6342 (`c68cca820` + `69dc02d2f`: `live-ws.mjs` lazy-loaded, `perf-budgets.json` `ci_initial_gzip_kb` 154.7 -> 151.9 KB, ~3.1 KB under the 155.0 KB ceiling; SPL-6341 B13 also landed in `76471cb9e`); any further WUI entry-chunk cut requires Chrome e2e + CI-node budget measurement and overlaps live WUI lanes (W2) | `git merge-base --is-ancestor c68cca820 7084439f1`, `git show 7084439f1:csi-spl-doc/specs/027-ui-performance-budget/contracts/perf-budgets.json` |
| the 10 remaining non-framework 2+ line / >=40-char Bash groups (`do_gcp_*_apis_disable`, `spl_uplink_trim`/`ext_api_trim`, `spl_secrets_none_get`/`spl_self_host_env_get`, `tf_get`, `ndf_link`/`ndp_link`, 7 `_sec_*_need`, `spl_brx_gh_auth`/`ghrh_gh_auth`, `ghr_in` family, `spl_asks_dur`/`spl_fleet_dur`, `_lc_deps`/`_spl_box_leave_deps`) | unchanged on `7084439f1`, each stays out for its r91..r97 section 7 reason | r97 7..r91 7; 1.2 (a), (e) |

## 8. Changes

- v0.1 (a-427): the rows and every read on `7084439f1`; both heads built in detached
  scratch worktrees; the 15-suite column of 1.5 run on base and each row's head;
  `shellcheck -S warning -x` and `do_sec_shellcheck` rc 0; the red and guard controls
  (`rc1a`, `rc1b`, `gc1a`, `gc1b`, `rc2a`, `rc2b`, `gc2`) RED then GREEN; R3 (2.2) and
  R7 (section 4) checked.
- v0.2 (a-427): folded panel seat `c-429` (claude) FAIL on v0.1 `caf5a790e` (seat file
  `348c10658`): W1 (added verbatim helper definitions and all 4 test hunks as code blocks
  in 1.3 and 1.4 so every head1/head2 sha256 and all 7 red/guard controls are directly
  reproducible on `7084439f1`), W2 (accounted for candidates-file `for refactor round 95`
  WUI entry-chunk item in 1.2 (c) and section 7, verified served on `7084439f1` by
  SPL-6342 `c68cca820`/`69dc02d2f` and SPL-6341 `76471cb9e`), N1 (noted `5855e3ca3` r97
  close record landed after base while `W` stays fixed at `2026-11-24T19:33:57+02:00` for
  all R4/R6/prune reads), N2 (`spl-cost-gcp.func.sh` is lazily stub-loaded by
  `csi-spl-iac/run` via `_RUN_INDEX_AWK` at `run.sh:883-891`), N3 (documented process
  globals `COST_WINDOW_DAY` and `COST_WINDOW_DAYS` in `do_spl_cost_gcp_window`'s header
  and re-verified head2 `b1ddd1ea1c94` + suites + `rc2a`/`rc2b`/`gc2`), N4 (`declare -F`
  guard and `gc1a`/`gc1b` prove the standalone-source path outside `./run`; `update` calls
  `add`'s helpers unguarded at `:62,:111`), N5 (cited ruling `dc84300a` in both row briefs
  for any same-vendor claude R7 backup).

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-427 (agy): v0.1 (`caf5a790e`), v0.2 (folding c-429 W1, W2, N1-N5).
- Panel reviewer seat: c-429 (claude, `c002-refactor-round-98-claude-panel-seat`):
  FAIL on v0.1 (`caf5a790e`, seat file `348c10658`, W1 + W2 + N1-N5; rows confirmed
  behaviour-preserving); pending re-review of v0.2 on
  `review/c002-refactor-round-98-planner`.
- Row R7 seats: section 4; **agy seat** per row (claude backup only while agy is out of
  quota, under ruling `dc84300a`; never mistral; re-checked at placement).
