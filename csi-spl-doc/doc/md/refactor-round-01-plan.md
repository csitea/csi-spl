# Refactoring round 01 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6520  
Topic: ccd57113-e7f1-4854-8897-f3925c8f95a6  
Discussion: ccd57113-e7f1-4854-8897-f3925c8f95a6 (t1 #refactoring, "Refactor round 01", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3; holder ruling
  `83dd3a25`), so this round is **r01**, plan `refactor-round-01-plan.md` (free: only
  `refactor-round-1-plan.md` exists, so no date suffix), rows `r01-<NN>`, scope
  `docs(r01-plan, SPL-6520)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574). **Vendor claude
  for every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 99 ([refactor-round-99-plan.md](refactor-round-99-plan.md))
is closed (`7a8ebd3cc`: `r99-01` `05129cff9`, `r99-02` `83a6b0d7d`), and round 98 is
fully landed (`r98-02` SPL-6466 = `60bc1836d`). The perf floor (rulebook 4.4), measured
on `fe1f82671` at 2026-11-25T16:13:17Z (14 days): perf 36, refactor 105, 25.5%,
5 x 36 = 180 >= 141, floor-met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91..r99: a
duplicated setup or error-reporting block that lives in multiple `orc:src/bash/run/`
actions moves to a single shared helper, and each caller delegates to that one home.
**Row 01:** the two read-only Cloud Run hub window diagnostics in `orc:src/bash/run/` —
`spl-hub-request-minutes.func.sh:35-39` (`do_spl_hub_request_minutes`) and
`spl-hub-run-metrics.func.sh:17-21` (`do_spl_hub_run_metrics`; r99 plan section 7) —
already share `spl_hub_request_minutes_check_args` in
`spl-hub-request-minutes.func.sh:49`, yet duplicate the exact 5-line service-name
lookup (`env.hub.service_name`), GCP SA pin + live-account check, and UTC window end
(`until`) calculation. Extracting `spl_hub_request_minutes_prep <since> <minutes>` into
`spl-hub-request-minutes.func.sh` (right below `spl_hub_request_minutes_check_args`,
setting process globals `SPL_HUB_REQ_SVC` and `SPL_HUB_REQ_UNTIL`) lets
`spl-hub-request-minutes.func.sh` call it directly and lets
`spl-hub-run-metrics.func.sh` lazy-source `spl-hub-request-minutes.func.sh` behind a
`declare -F spl_hub_request_minutes_prep` guard and replace the 5-line block with 2
lines.
**Row 02:** the two instance-wide `/v1/operator/fleet-load` actions in `orc:src/bash/run/`
— `spl-hub-agent-kinds.func.sh:71-83` (`_spl_hub_agent_kinds_report`) and
`spl-hub-runner-cpu.func.sh:56-68` (`_spl_hub_runner_cpu_report`; r99 plan section 7) —
duplicate the exact `detail` jq extraction and 400 / 401|403 / 404 / wildcard non-200
error-reporting branches. Extracting `_spl_hub_fleet_load_error <subject_verb>` into
`spl-hub-agent-kinds.func.sh` (zero top-level code) lets `spl-hub-agent-kinds.func.sh`
call it directly and lets `spl-hub-runner-cpu.func.sh` lazy-source
`spl-hub-agent-kinds.func.sh` behind a `declare -F _spl_hub_fleet_load_error` guard and
delegate all non-200 error logging to one home (`spl-hub-box-band.func.sh:119-121` stays
out because it has no `404)` branch).
The rows share no file: both are batch 1.

**Status: v0.1 draft** (submitted for cross-vendor claude panel review by **c-650**).
Editor: **a-649** (agy).

**One sha:** every count is measured on **`fe1f82671`** (`fe1f82671852a18e322a712a64a18037afdca7ce`,
`origin/master` at 2026-11-25T16:11:57Z; zero drift on all 7 row/test files to
`origin/master` `991ce5bc5` at 2026-11-25T16:25:11Z,
`git diff --name-only fe1f82671 991ce5bc5 -- <7 files>` -> empty), n=1 per command unless
stated. Reads are on `fe1f82671` with `git show` / `git grep`. The tests of 1.5 ran in
detached scratch worktrees of `fe1f82671` (not committed, removed on exit): "base"
unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" = base with row
02 applied in 1.4's shape; each red control, guard control, and mutation check (1.5) ran
in a detached worktree of its own. Both helper definitions and all three test hunks are
reproduced verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2,
all 5 controls, and all 4 mutation checks byte-for-byte on `fe1f82671` and verify every
sha256. Queue, lane map, brief and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-25T16:12:47Z (re-checked on `991ce5bc5` at 16:25:11Z), n=1, after a fresh fetch
(`git-fetch-fresh.sh`):

- **Window: W=2026-11-25T14:48:03+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r99-plan'`:
  `7a8ebd3ccb673042ee643381875f22eec38aab63`
  (`docs(r99-plan, SPL-6469): refactor round 99 closed: r99-01 05129cff9 and r99-02 83a6b0d7d landed, agy R7 PASS each`),
  read once at the start as 5.3 says. Per rulebook 5.3, `W` stays fixed at this recorded
  date (`2026-11-25T14:48:03+02:00`); all later R4, R6, 2.7.5, and `PRUNE_SINCE` reads
  for r01 must use `W=2026-11-25T14:48:03+02:00`.
- `git log origin/master --since="$W" --oneline -E --grep='\(r01-' | wc -l` -> **0**
  (re-verified on `991ce5bc5` at 16:25:11Z: windowed count **0**; pre-wrap all-history
  subject grep returns 11 commits from 2026-10-16..18, `test(r01-01-...)`..`test(r01-12-...)`,
  all older than `W` and outside the window per rulebook 5.3).
- `git ls-remote origin 'refs/heads/review/r01-*' 'refs/heads/*-r01-*' 'refs/heads/*refactor-round-01*' 'refs/heads/wip/*r01*'`
  -> nothing (before this plan's review branch and the panel seat branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r01-[0-9]{2}|refactor-round-01'` (on the
  planner's box) -> **0** (this planner's brief and panel seat `c-650`'s brief keep their
  pre-ruling placement slugs per holder ruling `83dd3a25`, while their body and review
  branch names are updated to `r01`).
- `git ls-tree --name-only fe1f82671 csi-spl-doc/doc/md/ | grep -c refactor-round-01`
  -> **0** (only `refactor-round-1-plan.md` exists, so `refactor-round-01-plan.md` is free
  with no date suffix per rulebook 5.3).

### 1.2 The brief's inputs, re-measured

- **(a) r99 section 7:** re-read on `fe1f82671`.
  - `orc:src/bash/run/spl-hub-{request-minutes,run-metrics}.func.sh` (`svc` +
    `do_gcp_pin_account` + `do_gcp_require_live_account` + `until` setup, `:35-39` and
    `:17-21`): byte-identical 5-line duplicate -> measured here as **row 01** (1.3).
  - `orc:src/bash/run/spl-hub-{agent-kinds,runner-cpu}.func.sh` (non-200
    `/v1/operator/fleet-load` error reporting, `:71-83` and `:56-68`): clean duplicate
    with fast pure-bash tests -> measured here as **row 02** (1.4).
  - `git diff --name-only f2cb19298 fe1f82671` (49 commits, 134 files): among r99 section
    7's items, only `spl-review-go.{func,tst}.sh` (`7d3be08fd`, SPL-6505) and r99-02's own
    served `spl-wui-perf-*.{func,tst}.sh` changed; none of the other remaining candidates
    changed, and each stays accounted for in section 7.
- **(b) R7 and panel notes:**
  - r99-01 R7 (`a-565`, agy, PASS on `70ffbbb69`, landed `05129cff9`): N1 noted the
    commit body cited pre-rebase start sha `ee271d80e` while parent was `fca53c766`
    (non-blocking). No refactor row.
  - r99-02 R7 (`a-562`, agy, PASS on `392592f73`, landed `83a6b0d7d`): N1-N4 verification
    notes only. No refactor row.
  - r98-02 R7 (`a-473`, agy, PASS on `2e37534c6`, landed `60bc1836d`): N1 confirmed
    `do_spl_cost_gcp_window` is the sole window-prep copy. No refactor row.
  - r99 panel (`c-396`, claude, recorded in r99 plan v1.0 `f8b2d8f1d`): PASS on
    `853b9368f`; W1, W2, and N1-N6 already folded into `f8b2d8f1d`. No refactor row.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 140 lines, read 16:11Z):
  - No `## for refactor round 100` or `## for refactor round 01` block; unchanged at 140
    lines since r98/r99.
  - All earlier refactor-shaped items remain served on `fe1f82671` (`r97-01` `2924c633f`,
    `SPL-6342` `c68cca820`/`69dc02d2f`, `SPL-6341` `76471cb9e`, `LOGIN_STATE_DIR`,
    `spl-desk-reply.sh`, `reverse-tunnel-cron.sh`, `agent-boot-restore`,
    `spl-lane-mix.func.sh`), and the remaining entries are bug, perf, other-repo, or
    gate-design items, not refactor rows (section 7).
- **(d) spec 011 tasks:**
  `git log f2cb19298..fe1f82671 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r99's base; the remaining open/partial tasks (T001-T008
  owner-deferred, T018-T021, T023, T025-T028, T031, T034) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `spl-hub-request-minutes.func.sh` and `spl-hub-run-metrics.func.sh` share `spl_hub_request_minutes_prep`

`orc:` = `csi-spl-orc/`. On `fe1f82671`:

- `orc:src/bash/run/spl-hub-request-minutes.func.sh:35-39` (in
  `do_spl_hub_request_minutes`) and `orc:src/bash/run/spl-hub-run-metrics.func.sh:17-21`
  (in `do_spl_hub_run_metrics`) each contain the exact same 5 lines:
  ```bash
    svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
    [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL env.hub.service_name is not set in $SPL_CNF"; return 1; }
    do_gcp_pin_account "$SPL_CNF" || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
    until="$(date -u -d "$since + $minutes minutes" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  ```
- `diff -u <(git show fe1f82671:csi-spl-orc/src/bash/run/spl-hub-request-minutes.func.sh | sed -n '35,39p') <(git show fe1f82671:csi-spl-orc/src/bash/run/spl-hub-run-metrics.func.sh | sed -n '17,21p')`
  -> no hunk (rc 0, n=1): the two copies are **byte-identical**.
- `spl_hub_request_minutes_prep`, `SPL_HUB_REQ_SVC`, and `SPL_HUB_REQ_UNTIL` have
  **0 collisions** anywhere in the repo (`git grep` -> 0). Both `.func.sh` files contain
  only function definitions (zero top-level code), and `spl-hub-run-metrics.func.sh:13`
  already calls `spl_hub_request_minutes_check_args` defined in
  `spl-hub-request-minutes.func.sh:49`. Placing `spl_hub_request_minutes_prep` immediately
  below `spl_hub_request_minutes_check_args` (`:55`) and adding a
  `declare -F spl_hub_request_minutes_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-hub-request-minutes.func.sh"`
  guard immediately before `spl_hub_request_minutes_check_args` (`:13`) in
  `spl-hub-run-metrics.func.sh` keeps both actions lazy under `./run`
  (`run-lazy-loader.tst.sh` and `run-eager-files.tst.sh` unchanged) while also making
  standalone sourcing of `spl-hub-run-metrics.func.sh` work without pre-sourcing
  `spl-hub-request-minutes.func.sh`.
- Neither extracted block handles any token, credential, or `-K` curl file (non-secret;
  the access-token fetch in `spl-hub-run-metrics.func.sh:22-25` is untouched).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `spl_hub_request_minutes_prep` is 9
  lines; `do_spl_hub_request_minutes` 23 -> 20 lines; `do_spl_hub_run_metrics` 32 -> 31
  lines; `spl_hub_request_minutes_table` stays 66 lines. None of the 3 files has any entry
  in `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt`, or `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-hub-request-minutes.func.sh`: replace `:35-39` with
  `spl_hub_request_minutes_prep "$since" "$minutes" || return 1` and
  `svc="$SPL_HUB_REQ_SVC" until="$SPL_HUB_REQ_UNTIL"`; insert
  `spl_hub_request_minutes_prep` (with its 4-line header documenting process globals
  `SPL_HUB_REQ_SVC` and `SPL_HUB_REQ_UNTIL`, and `# shellcheck disable=SC2034`) right
  after `spl_hub_request_minutes_check_args` (`:55`). 126 -> 137 lines (`+16 -5`).
- `orc:src/bash/run/spl-hub-run-metrics.func.sh`: insert
  `# shellcheck source=spl-hub-request-minutes.func.sh` and
  `declare -F spl_hub_request_minutes_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-hub-request-minutes.func.sh"`
  above `spl_hub_request_minutes_check_args` (`:13`), and replace `:17-21` with
  `spl_hub_request_minutes_prep "$since" "$minutes" || return 1` and
  `svc="$SPL_HUB_REQ_SVC" until="$SPL_HUB_REQ_UNTIL"`. 75 -> 74 lines (`+4 -5`).
- `orc:src/bash/tests/spl-hub-request-minutes.tst.sh`: append section 5 before `:97`
  (`echo` / `ALL PASS`): 3 direct `spl_hub_request_minutes_prep` checks (valid YAML +
  pinned account + exact `until`, missing `service_name` refused before pin, pin failure
  stops before live check), 2 one-copy checks (`spl-hub-request-minutes.func.sh` defines
  and calls it once; `spl-hub-run-metrics.func.sh` has neither the FATAL nor the
  `date -u -d` calculation and calls `spl_hub_request_minutes_prep`), 1 standalone
  lazy-load check (sourcing only `spl-hub-run-metrics.func.sh`), and 2 end-to-end wiring
  checks (both `do_spl_hub_request_minutes` and `do_spl_hub_run_metrics` with stubbed
  `gcloud`/`curl` asserting exact `service_name="hub-test"` and `2026-10-15T07:40:00Z`
  passed through). 98 -> 165 lines (`+67 -0`).
- head1's files, sha256 (12 chars): `spl-hub-request-minutes.func.sh` `d614c9dd9f63`,
  `spl-hub-run-metrics.func.sh` `adf9375567fa`,
  `spl-hub-request-minutes.tst.sh` `fc7d9b8407d5`.
- Note for the row and its reviewer: standalone-sourcing `spl-hub-run-metrics.func.sh`
  fails on base with `spl_hub_request_minutes_check_args: command not found` (`rc1`), so
  the `declare -F spl_hub_request_minutes_prep` guard adds standalone-source capability;
  under `./run`, `run.sh`'s lazy stub loader defines stubs for both functions, and the
  existing suites source `.func.sh` eagerly. Build `gc1` in a worktree, not a single-file
  temp copy, because the guard loads its sibling via `dirname "${BASH_SOURCE[0]}"`.

Verbatim helper and test hunks (head1 on `fe1f82671`):

`orc:src/bash/run/spl-hub-request-minutes.func.sh` (inserted immediately after
`spl_hub_request_minutes_check_args` closing `}` at `:55`, preceded by one blank line):
```bash
# spl_hub_request_minutes_prep <since> <minutes> -> resolve env.hub.service_name
# from SPL_CNF, pin and verify GCP_ACCOUNT, and compute the UTC window end;
# sets process globals SPL_HUB_REQ_SVC and SPL_HUB_REQ_UNTIL.
# shellcheck disable=SC2034 # SPL_HUB_REQ_* globals are read by callers
spl_hub_request_minutes_prep() {
  local svc until
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL env.hub.service_name is not set in $SPL_CNF"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  until="$(date -u -d "$1 + $2 minutes" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  SPL_HUB_REQ_SVC="$svc" SPL_HUB_REQ_UNTIL="$until"
}
```

`orc:src/bash/tests/spl-hub-request-minutes.tst.sh` section 5 (inserted immediately before
`echo` and `(( fails == 0 )) && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }`
at `:97`, followed by one blank line):
```bash
# --- 5. spl_hub_request_minutes_prep (r01-01 one copy) --------------------------------
printf 'env:\n  hub:\n    service_name: hub-test\n' >"$T/ok.yaml"
printf 'env:\n  hub: {}\n' >"$T/nosvc.yaml"
out=$(env SPL_CNF="$T/ok.yaml" PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }
  do_gcp_pin_account(){ GCP_ACCOUNT="sa@test.iam.gserviceaccount.com"; echo "pin:$1"; }
  do_gcp_require_live_account(){ echo "live:$1"; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-request-minutes.func.sh"
  spl_hub_request_minutes_prep 2026-10-15T07:15:00Z 25 || exit 1
  printf "%s|%s\n" "$SPL_HUB_REQ_SVC" "$SPL_HUB_REQ_UNTIL"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"pin:$T/ok.yaml"* && "$out" == *"live:sa@test.iam.gserviceaccount.com"* && "$out" == *"hub-test|2026-10-15T07:40:00Z"* ]] \
  && pass "5. spl_hub_request_minutes_prep resolves svc, pins account and computes until" || fail "5. prep ok: rc=$rc $out"
out=$(env SPL_CNF="$T/nosvc.yaml" PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }
  do_gcp_pin_account(){ echo "PIN-CALLED"; }
  do_gcp_require_live_account(){ echo "LIVE-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-request-minutes.func.sh"
  spl_hub_request_minutes_prep 2026-10-15T07:15:00Z 25' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL env.hub.service_name is not set in $T/nosvc.yaml"* && "$out" != *"PIN-CALLED"* ]] \
  && pass "5. spl_hub_request_minutes_prep refuses missing service_name before pin" || fail "5. prep nosvc: rc=$rc $out"
out=$(env SPL_CNF="$T/ok.yaml" PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }
  do_gcp_pin_account(){ return 1; }
  do_gcp_require_live_account(){ echo "LIVE-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-request-minutes.func.sh"
  spl_hub_request_minutes_prep 2026-10-15T07:15:00Z 25' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" != *"LIVE-CALLED"* ]] \
  && pass "5. spl_hub_request_minutes_prep stops when pin fails" || fail "5. prep pin fail: rc=$rc $out"
[[ "$(grep -c "FATAL env.hub.service_name is not set in" "$FN")" -eq 1 && "$(grep -c "spl_hub_request_minutes_prep " "$FN")" -ge 1 ]] \
  && pass "5. one copy: spl-hub-request-minutes.func.sh defines and calls spl_hub_request_minutes_prep once" || fail "5. fn one copy"
own="$(grep -nE "FATAL env\.hub\.service_name is not set in|date -u -d \"\\\$since \+ \\\$minutes" "$FM" || true)"
[[ -z "$own" ]] && grep -q "spl_hub_request_minutes_prep " "$FM" \
  && pass "5. one copy: spl-hub-run-metrics.func.sh delegates window prep to spl_hub_request_minutes_prep" || fail "5. fm one copy: own=[$own]"
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" ENV=dev REQ_SINCE=2026-10-15T07:15:00Z REQ_MINUTES=25 bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  do_spl_cloud_cnf(){ SPL_CNF="$T/nosvc.yaml"; SPL_PROJECT=csi-spl-dev; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-run-metrics.func.sh"
  do_spl_hub_run_metrics' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL env.hub.service_name is not set in $T/nosvc.yaml"* && "$out" != *"command not found"* ]] \
  && pass "5. lazy load: spl-hub-run-metrics.func.sh loads spl_hub_request_minutes_prep standalone" || fail "5. lazy metrics: rc=$rc $out"
mkdir -p "$T/stub2"
printf '#!/bin/sh\necho "gcloud $*" >>"$STUB_LOG"\nif [ "$1" = auth ]; then echo tok-1; else echo "[]"; fi\n' >"$T/stub2/gcloud"
printf '#!/bin/sh\necho "curl $*" >>"$STUB_LOG"\necho "{\"timeSeries\":[]}"\n' >"$T/stub2/curl"
chmod +x "$T/stub2/gcloud" "$T/stub2/curl"
: >"$T/calls2.log"
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" T="$T" STUB_LOG="$T/calls2.log" PATH="$T/stub2:$PATH" ENV=dev REQ_SINCE=2026-10-15T07:15:00Z REQ_MINUTES=25 bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf(){ SPL_CNF="$T/ok.yaml"; SPL_PROJECT=csi-spl-dev; }
  do_gcp_pin_account(){ GCP_ACCOUNT="sa@test.iam.gserviceaccount.com"; }
  do_gcp_require_live_account(){ return 0; }
  do_spl_hub_request_minutes' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"service=hub-test (2026-10-15T07:15:00Z .. 2026-10-15T07:40:00Z)"* ]] \
  && grep -q 'service_name="hub-test".*timestamp<"2026-10-15T07:40:00Z"' "$T/calls2.log" \
  && pass "5. do_spl_hub_request_minutes wires svc and until into gcloud logging read" || fail "5. minutes wire: rc=$rc $out $(cat "$T/calls2.log")"
: >"$T/calls2.log"
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" T="$T" STUB_LOG="$T/calls2.log" PATH="$T/stub2:$PATH" ENV=dev REQ_SINCE=2026-10-15T07:15:00Z REQ_MINUTES=25 bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf(){ SPL_CNF="$T/ok.yaml"; SPL_PROJECT=csi-spl-dev; }
  do_gcp_pin_account(){ GCP_ACCOUNT="sa@test.iam.gserviceaccount.com"; }
  do_gcp_require_live_account(){ return 0; }
  do_spl_hub_run_metrics' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"service=hub-test (2026-10-15T07:15:00Z .. 2026-10-15T07:40:00Z)"* ]] \
  && grep -q 'service_name="hub-test".*interval\.endTime=2026-10-15T07:40:00Z' "$T/calls2.log" \
  && pass "5. do_spl_hub_run_metrics wires svc and until into Monitoring curl" || fail "5. metrics wire: rc=$rc $out $(cat "$T/calls2.log")"
```

**Behaviour:** `spl_hub_request_minutes_prep` executes the exact `yq` lookup, non-empty
check, `do_gcp_pin_account`, `do_gcp_require_live_account`, and UTC `date -u -d` end
computation removed from both actions, in the exact same order; its only new state is the
two process globals `SPL_HUB_REQ_SVC` and `SPL_HUB_REQ_UNTIL` documented in its header;
all row-01 and shared suites pass on base and head1 with identical counts plus the 8 new
checks (1.5).

### 1.4 Row 02's site: `spl-hub-agent-kinds.func.sh` and `spl-hub-runner-cpu.func.sh` share `_spl_hub_fleet_load_error`

`orc:` = `csi-spl-orc/`. On `fe1f82671`:

- `orc:src/bash/run/spl-hub-agent-kinds.func.sh:71-83` (`_spl_hub_agent_kinds_report`)
  and `orc:src/bash/run/spl-hub-runner-cpu.func.sh:56-68` (`_spl_hub_runner_cpu_report`)
  each extract `detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"`
  and carry the exact same 3 error branches (`400`, `401|403`, `404`) plus the same
  wildcard `*)` shape differing only in `"the instance agent kinds were"` vs
  `"the instance runner CPU cap was"`:
  ```bash
    400) do_log "FATAL the hub refused the setting (400): $detail. Nothing changed."; return 1 ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. $detail"; return 1 ;;
    404) do_log "FATAL the hub answered 404 ($detail): no operator workspace, or a hub without this door yet. Nothing changed."; return 1 ;;
  ```
- `diff -u <(git show fe1f82671:csi-spl-orc/src/bash/run/spl-hub-agent-kinds.func.sh | sed -n '78,80p') <(git show fe1f82671:csi-spl-orc/src/bash/run/spl-hub-runner-cpu.func.sh | sed -n '63,65p')`
  -> no hunk (rc 0, n=1): all three named error branches are **byte-identical**.
- `_spl_hub_fleet_load_error` has **0 collisions** anywhere in the repo (`git grep` -> 0).
  Both `.func.sh` files contain only function definitions (zero top-level code). Hosting
  `_spl_hub_fleet_load_error` in `spl-hub-agent-kinds.func.sh` and lazy-sourcing
  `spl-hub-agent-kinds.func.sh` inside `_spl_hub_runner_cpu_report` behind
  `declare -F _spl_hub_fleet_load_error >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-hub-agent-kinds.func.sh"`
  avoids touching `lib/bash/funcs/spl-hub-operator.func.sh` (which 38+ actions and 30+
  test files depend on), keeps both actions lazy under `./run` (`run-lazy-loader.tst.sh`
  and `run-eager-files.tst.sh` unchanged), and works standalone.
- `spl-hub-box-band.func.sh:110-123` (`_spl_hub_box_band_report`) stays out: its `case`
  has no `404)` branch (`404` falls into `*) FATAL box <box> band was not read or changed (http 404): ...`),
  so delegating it to `_spl_hub_fleet_load_error` would change its 404 message (behaviour
  change; section 7).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `_spl_hub_fleet_load_error` is 11
  lines; `_spl_hub_agent_kinds_report` 13 -> 7 lines; `_spl_hub_runner_cpu_report` 13 -> 9
  lines. None of the 4 files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:src/bash/run/spl-hub-agent-kinds.func.sh`: define
  `_spl_hub_fleet_load_error <subject_verb>` above `# _spl_hub_agent_kinds_report` (`:69`),
  and simplify `_spl_hub_agent_kinds_report` (`:71-83`) to handle `200` and delegate every
  non-200 status to `_spl_hub_fleet_load_error "the instance agent kinds were"`. 83 -> 92
  lines (`+19 -10`).
- `orc:src/bash/run/spl-hub-runner-cpu.func.sh`: simplify `_spl_hub_runner_cpu_report`
  (`:56-68`) to handle `200`, lazy-source `spl-hub-agent-kinds.func.sh` behind a
  `declare -F _spl_hub_fleet_load_error` guard, and delegate every non-200 status to
  `_spl_hub_fleet_load_error "the instance runner CPU cap was"`. 68 -> 64 lines (`+7 -11`).
- `orc:src/bash/tests/hub-agent-kinds.tst.sh`: append section 6 before `:78` (`PASS: all`):
  4 direct `_spl_hub_fleet_load_error` checks (`400`, `401`, `404`, `500`), 2 end-to-end
  `do_spl_hub_agent_kinds` checks (`404` and `500` asserting the exact
  `"the instance agent kinds were"` message), and 1 one-copy check. 79 -> 106 lines
  (`+27 -0`).
- `orc:src/bash/tests/hub-runner-cpu.tst.sh`: append section 6 before `:69` (`PASS: all`):
  2 end-to-end `do_spl_hub_runner_cpu` checks (`404` and `500` asserting the exact
  `"the instance runner CPU cap was"` message), 1 one-copy check (0 copies of the
  400/401-403/404 strings in `spl-hub-runner-cpu.func.sh` and calls
  `_spl_hub_fleet_load_error`), and 1 standalone lazy-load check (sourcing only
  `spl-hub-runner-cpu.func.sh`). 70 -> 93 lines (`+23 -0`).
- head2's files, sha256 (12 chars): `spl-hub-agent-kinds.func.sh` `52d20bac44d7`,
  `spl-hub-runner-cpu.func.sh` `74a3db121695`,
  `hub-agent-kinds.tst.sh` `918e59626f4d`,
  `hub-runner-cpu.tst.sh` `d7f616c6c177`.
- Note for the row and its reviewer: under `./run`, `run.sh`'s lazy stub loader defines a
  stub for `_spl_hub_fleet_load_error`, so the `declare -F _spl_hub_fleet_load_error`
  guard acts only on the standalone-source path outside `./run` (the existing suites
  source `.func.sh` eagerly). Build `gc2` in a worktree, not a single-file temp copy.

Verbatim helper and test hunks (head2 on `fe1f82671`):

`orc:src/bash/run/spl-hub-agent-kinds.func.sh` (replaces `:69-83`):
```bash
# _spl_hub_fleet_load_error <subject_verb> -> log the hub refusal for a
# non-200 /v1/operator/fleet-load response (400, 401/403, 404, or other)
# using SPL_HUB_OP_STATUS, SPL_HUB_OP_BODY and GCP_ACCOUNT, and return 1.
_spl_hub_fleet_load_error() {
  local detail
  detail="$(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  case "$SPL_HUB_OP_STATUS" in
    400) do_log "FATAL the hub refused the setting (400): $detail. Nothing changed." ;;
    401|403) do_log "FATAL the hub refused the operator id token ($SPL_HUB_OP_STATUS): is $GCP_ACCOUNT in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. $detail" ;;
    404) do_log "FATAL the hub answered 404 ($detail): no operator workspace, or a hub without this door yet. Nothing changed." ;;
    *) do_log "FATAL $1 not read or changed (http $SPL_HUB_OP_STATUS): $detail" ;;
  esac
  return 1
}

# _spl_hub_agent_kinds_report <set> <ordered_by> <ordered_via> -> the hub's
# answer as one OK line, or the refusal
_spl_hub_agent_kinds_report() {
  if [[ "$SPL_HUB_OP_STATUS" == 200 ]]; then
    do_log "OK $ENV instance agent kinds: $(jq -r '"off [\(.agent_kinds_off // [] | join(","))], paused [\((.agent_kinds_paused // {}) | to_entries | map("\(.key) until \(.value.until) (\(.value.reason))") | join("; "))]"' <<<"$SPL_HUB_OP_BODY")$([[ "$1" != __read__ ]] && echo " (set by ordered_by=$2${3:+ via $3}, $GCP_ACCOUNT)")"
    return 0
  fi
  _spl_hub_fleet_load_error "the instance agent kinds were"
}
```

`orc:src/bash/run/spl-hub-runner-cpu.func.sh` (replaces `:54-68`):
```bash
# _spl_hub_runner_cpu_report <set> <ordered_by> <ordered_via> -> the hub's
# answer as one OK line, or the refusal
_spl_hub_runner_cpu_report() {
  if [[ "$SPL_HUB_OP_STATUS" == 200 ]]; then
    do_log "OK $ENV instance runner CPU cap: $(jq -r '"\(.runner_cpu_pct // "absent (hub before rdb 0152)")% in force, stored \(.stored.runner_cpu_pct // "unset")"' <<<"$SPL_HUB_OP_BODY")$([[ "$1" != __read__ ]] && echo " (set by ordered_by=$2${3:+ via $3}, $GCP_ACCOUNT)")"
    return 0
  fi
  # shellcheck source=spl-hub-agent-kinds.func.sh
  declare -F _spl_hub_fleet_load_error >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_error "the instance runner CPU cap was"
}
```

`orc:src/bash/tests/hub-agent-kinds.tst.sh` section 6 (inserted immediately before
`[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }`
at `:78`, followed by one blank line):
```bash
# --- 6. _spl_hub_fleet_load_error (r01-02 one copy) -----------------------------
out=$(env PROJ_ROOT="$PROJ_ROOT" SPL_HUB_OP_STATUS=400 SPL_HUB_OP_BODY='{"detail":"bad val"}' GCP_ACCOUNT=sa@example.test bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"; _spl_hub_fleet_load_error "x was"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL the hub refused the setting (400): bad val. Nothing changed." ]] \
  && pass "6. _spl_hub_fleet_load_error handles 400" || fail "6. err 400: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" SPL_HUB_OP_STATUS=401 SPL_HUB_OP_BODY='{"error":"unauth"}' GCP_ACCOUNT=sa@example.test bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"; _spl_hub_fleet_load_error "x was"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL the hub refused the operator id token (401): is sa@example.test in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. unauth" ]] \
  && pass "6. _spl_hub_fleet_load_error handles 401" || fail "6. err 401: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" SPL_HUB_OP_STATUS=404 SPL_HUB_OP_BODY='{"error":"no_op"}' GCP_ACCOUNT=sa@example.test bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"; _spl_hub_fleet_load_error "x was"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL the hub answered 404 (no_op): no operator workspace, or a hub without this door yet. Nothing changed." ]] \
  && pass "6. _spl_hub_fleet_load_error handles 404" || fail "6. err 404: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" SPL_HUB_OP_STATUS=500 SPL_HUB_OP_BODY='{"detail":"boom"}' GCP_ACCOUNT=sa@example.test bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"; _spl_hub_fleet_load_error "x was"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL x was not read or changed (http 500): boom" ]] \
  && pass "6. _spl_hub_fleet_load_error handles wildcard status with subject_verb" || fail "6. err 500: rc=$rc $out"
run STUB_CODE=404 STUB_BODY='{"error":"no_op"}'; rc=$?
[[ $rc -eq 1 ]] && grep -qxF 'FATAL the hub answered 404 (no_op): no operator workspace, or a hub without this door yet. Nothing changed.' "$T/o" \
  && pass "6. agent-kinds 404 fails with exact message" || fail "6. kinds 404: rc=$rc $(cat "$T/o")"
run STUB_CODE=500 STUB_BODY='{"detail":"boom"}'; rc=$?
[[ $rc -eq 1 ]] && grep -qxF 'FATAL the instance agent kinds were not read or changed (http 500): boom' "$T/o" \
  && pass "6. agent-kinds 500 fails with exact subject_verb message" || fail "6. kinds 500: rc=$rc $(cat "$T/o")"
ak_f="$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
[[ "$(grep -c "FATAL the hub refused the setting (400):" "$ak_f")" -eq 1 && "$(grep -c "SPOOL_HUB_OPERATOR_EMAILS?" "$ak_f")" -eq 1 && "$(grep -c "FATAL the hub answered 404 (" "$ak_f")" -eq 1 && "$(grep -c "_spl_hub_fleet_load_error " "$ak_f")" -ge 1 ]] \
  && pass "6. one copy: spl-hub-agent-kinds.func.sh defines and calls _spl_hub_fleet_load_error once" || fail "6. kinds one copy"
```

`orc:src/bash/tests/hub-runner-cpu.tst.sh` section 6 (inserted immediately before
`[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }`
at `:69`, followed by one blank line):
```bash
# --- 6. r01-02 one copy and standalone lazy-source ------------------------------
run STUB_CODE=404 STUB_BODY='{"error":"no_op"}'; rc=$?
[[ $rc -eq 1 ]] && grep -qxF 'FATAL the hub answered 404 (no_op): no operator workspace, or a hub without this door yet. Nothing changed.' "$T/o" \
  && pass "6. runner-cpu 404 fails with exact message" || fail "6. cpu 404: rc=$rc $(cat "$T/o")"
run STUB_CODE=500 STUB_BODY='{"detail":"boom"}'; rc=$?
[[ $rc -eq 1 ]] && grep -qxF 'FATAL the instance runner CPU cap was not read or changed (http 500): boom' "$T/o" \
  && pass "6. runner-cpu 500 fails with exact subject_verb message" || fail "6. cpu 500: rc=$rc $(cat "$T/o")"
rc_f="$PROJ_ROOT/src/bash/run/spl-hub-runner-cpu.func.sh"
own="$(grep -nE "FATAL the hub refused the setting \(400\):|SPOOL_HUB_OPERATOR_EMAILS\?|FATAL the hub answered 404 \(" "$rc_f" || true)"
[[ -z "$own" ]] && grep -q "_spl_hub_fleet_load_error " "$rc_f" \
  && pass "6. one copy: spl-hub-runner-cpu.func.sh delegates errors to _spl_hub_fleet_load_error" || fail "6. cpu one copy: own=[$own]"
out=$(env PROJ_PATH="$PROJ_ROOT" ENV=dev bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ :; }
  do_spl_cloud_cnf(){ SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
  spl_hub_operator_url(){ SPL_HUB_URL=https://hub.invalid; }
  do_gcp_pin_account(){ GCP_ACCOUNT=sa@example.test; }
  do_gcp_require_live_account(){ :; }
  spl_hub_operator_call(){ SPL_HUB_OP_STATUS=400; SPL_HUB_OP_BODY="{\"detail\":\"bad\"}"; }
  source "$PROJ_PATH/src/bash/run/spl-hub-runner-cpu.func.sh"
  do_spl_hub_runner_cpu' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL the hub refused the setting (400): bad. Nothing changed." && "$out" != *"command not found"* ]] \
  && pass "6. lazy load: spl-hub-runner-cpu.func.sh loads _spl_hub_fleet_load_error standalone" || fail "6. lazy cpu: rc=$rc $out"
```

**Behaviour:** on `200`, both reporters emit the exact same `OK` line (avoiding the
previously unused `detail` `jq` call on the 200 path); on any non-200 status (`400`,
`401`, `403`, `404`, or `*`), `_spl_hub_fleet_load_error` extracts `detail` with the
exact same `jq` expression, logs the byte-identical `FATAL` message, and returns 1; all
row-02 and shared suites pass on base and head2 with identical counts plus the 7 + 4 new
checks (1.5).

### 1.5 Before and on the rows' heads

2026-11-25T16:18:10Z-16:24:51Z, n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal
to base: same rc, pass and fail counts; "-" means that row's head does not touch the
suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/spl-hub-request-minutes.tst.sh` | 01 | 0 / 54 / 0 | 0 / 62 / 0 (+8 new checks) | - |
| `orc:src/bash/tests/spl-hub-load-test.tst.sh` | 01 | 0 / 50 / 0 | = | - |
| `orc:src/bash/tests/hub-agent-kinds.tst.sh` | 02 | 0 / 17 / 0 | - | 0 / 24 / 0 (+7 new checks) |
| `orc:src/bash/tests/hub-runner-cpu.tst.sh` | 02 | 0 / 14 / 0 | - | 0 / 18 / 0 (+4 new checks) |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

Note: `hub-agent-kinds.tst.sh` and `hub-runner-cpu.tst.sh` print a final
`PASS: all <name> assertions` summary line on rc 0 (counted by `^ *(ok|pass)`) and
`FAIL: <n> assertion(s) in <name>` on rc 1 (counted by `^ *(not ok|fail)`), so base
`17` = 16 assertions + 1 summary (`head2` `24` = 23 + 1), and base `14` = 13 + 1 (`head2`
`18` = 17 + 1). `spl-hub-request-minutes.tst.sh` prints `ALL PASS` on rc 0 and
`<n> FAILED` on rc 1 (neither matched by `^ *(ok|pass)` or `^ *(not ok|fail)`).

`shellcheck -S warning -x` on all 7 row files (head1: 3 files, head2: 4 files): **rc 0**,
no findings (n=1 each). `do_sec_shellcheck` with newline-separated `SEC_SHELLCHECK_FILES`
set to each row's touched files: **rc 0**, `no error-level findings`,
`no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `fe1f82671`,
reconstructed from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control (`rc1`, head1's `spl-hub-request-minutes.tst.sh` on base): rc 1, 56
  pass, 6 fail (`FAIL: 5. prep ok` rc 1, `prep nosvc` / `prep pin fail` rc 127 each
  `spl_hub_request_minutes_prep: command not found`, `FAIL: 5. fn one copy`,
  `FAIL: 5. fm one copy: own=[18: ...]`, `FAIL: 5. lazy metrics: rc=1 .../spl-hub-run-metrics.func.sh: line 13: spl_hub_request_minutes_check_args: command not found`;
  the 2 wiring checks pass on base, proving equivalence); head1: rc 0, 62 pass, 0 fail.
- Row 01 guard control (`gc1`, head1 with the `declare -F spl_hub_request_minutes_prep`
  lazy-source line deleted in `spl-hub-run-metrics.func.sh`): rc 1, 61 pass, 1 fail
  (`FAIL: 5. lazy metrics: rc=1 .../spl-hub-run-metrics.func.sh: line 14: spl_hub_request_minutes_check_args: command not found`).
- Row 02 red control a (`rc2a`, head2's `hub-agent-kinds.tst.sh` on base): rc 1, 18 pass,
  6 fail lines (5 assertions: `FAIL: 6. err 400`/`401`/`404`/`500` each rc 127
  `_spl_hub_fleet_load_error: command not found`, `FAIL: 6. kinds one copy`, plus summary
  `FAIL: 5 assertion(s) in hub-agent-kinds.tst.sh`; the 2 end-to-end 404/500 checks pass
  on base, proving equivalence); head2: rc 0, 24 pass, 0 fail.
- Row 02 red control b (`rc2b`, head2's `hub-runner-cpu.tst.sh` on base): rc 1, 16 pass,
  2 fail lines (1 assertion: `FAIL: 6. cpu one copy: own=[63: ...]`, plus summary
  `FAIL: 1 assertion(s) in hub-runner-cpu.tst.sh`; the 2 end-to-end 404/500 checks and
  standalone check pass on base because base handles 400 inline); head2: rc 0, 18 pass,
  0 fail.
- Row 02 guard control (`gc2`, head2 with the `declare -F _spl_hub_fleet_load_error`
  lazy-source line deleted in `spl-hub-runner-cpu.func.sh`): rc 1, 16 pass, 2 fail lines
  (`FAIL: 6. lazy cpu: rc=127 .../spl-hub-runner-cpu.func.sh: line 62: _spl_hub_fleet_load_error: command not found`,
  plus summary `FAIL: 1 assertion(s) in hub-runner-cpu.tst.sh`).

**Mutation checks** (n=1 each, detached worktrees of `fe1f82671` with head1/head2
applied, then one defect injected):
- `m1a` (`spl-hub-request-minutes.func.sh` passes `1` instead of `"$minutes"`):
  `spl-hub-request-minutes.tst.sh` rc 1, 61 pass, 1 fail (`FAIL: 5. minutes wire: ... (2026-10-15T07:15:00Z .. 2026-10-15T07:16:00Z)`).
- `m1b` (`spl-hub-run-metrics.func.sh` passes `1` instead of `"$minutes"`):
  `spl-hub-request-minutes.tst.sh` rc 1, 61 pass, 1 fail (`FAIL: 5. metrics wire: ... (2026-10-15T07:15:00Z .. 2026-10-15T07:16:00Z)`).
- `m2a` (`spl-hub-agent-kinds.func.sh` passes `"the instance runner CPU cap was"`):
  `hub-agent-kinds.tst.sh` rc 1, 22 pass, 2 fail lines (`FAIL: 6. kinds 500: rc=1 FATAL the instance runner CPU cap was not read or changed (http 500): boom`, plus summary).
- `m2b` (`spl-hub-runner-cpu.func.sh` passes `"the instance agent kinds were"`):
  `hub-runner-cpu.tst.sh` rc 1, 16 pass, 2 fail lines (`FAIL: 6. cpu 500: rc=1 FATAL the instance agent kinds were not read or changed (http 500): boom`, plus summary).

The tests that name the sites (R2): `git grep -lE` over `*.tst.sh` and `features/*/tests/*`
for `spl-hub-(request-minutes|run-metrics|agent-kinds|runner-cpu)|do_spl_hub_(request_minutes|run_metrics|agent_kinds|runner_cpu)|spl_hub_request_minutes_check_args|_spl_hub_(agent_kinds|runner_cpu)_report`
-> `spl-hub-request-minutes.tst.sh`, `spl-hub-load-test.tst.sh` (stubs
`do_spl_hub_run_metrics:75`), and `canary-hub-deploy.tst.sh` (comment only at `:185`) for
row 01; `hub-agent-kinds.tst.sh`, `hub-runner-cpu.tst.sh`, and `spl-review-go.tst.sh`
(fixture prose only at `:1078,:1096,:1103,:1109`) for row 02 (plus the 9 shared iac/orc
gates, including `gcloud-account-pinned.tst.sh`). 30-char non-separator comment grep
within site lines +/- 3 across all `*.tst.sh` and `test-*.sh` -> **0 hits**. No new test
file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r01-01-orc-hub-window-prep)` | one fact, one copy (developer guide 2.2.4) | `spl-hub-request-minutes.func.sh:35-39` and `spl-hub-run-metrics.func.sh:17-21` duplicate the exact 5-line `env.hub.service_name` lookup, GCP SA pin + live check, and UTC `until` calculation (1.3, r99 section 7) | `orc:src/bash/run/spl-hub-request-minutes.func.sh:35-39,55`<br>`orc:src/bash/run/spl-hub-run-metrics.func.sh:13,17-21`<br>`orc:src/bash/tests/spl-hub-request-minutes.tst.sh:97` | copies of the hub window service/pin/until setup 2 -> 1 (`spl_hub_request_minutes_prep` in `spl-hub-request-minutes.func.sh`) | 1.3's shape (verbatim blocks in 1.3; header documents process globals `SPL_HUB_REQ_SVC`, `SPL_HUB_REQ_UNTIL`). **Red control:** head's `spl-hub-request-minutes.tst.sh` on parent FAILs 6 checks (`rc1`, rc 1, 56 pass, 6 fail, `spl_hub_request_minutes_prep: command not found` + one-copy `:18` + standalone `spl_hub_request_minutes_check_args: command not found`), then GREEN (62/0); guard control (`gc1`, `declare -F spl_hub_request_minutes_prep` deleted in `spl-hub-run-metrics.func.sh`: rc 1, 61 pass, 1 fail with `spl_hub_request_minutes_check_args: command not found`; proves standalone-source path outside `./run`), built in a worktree; wiring checks catch `m1a`/`m1b` (1.5); outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 8 new checks. Tests: **`orc:.../spl-hub-request-minutes.tst.sh`**, `orc:.../spl-hub-load-test.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r01-02-orc-fleet-load-error)` | one fact, one copy (developer guide 2.2.4) | `spl-hub-agent-kinds.func.sh:71-83` and `spl-hub-runner-cpu.func.sh:56-68` duplicate the exact `detail` extraction and 400 / 401\|403 / 404 / wildcard non-200 `/v1/operator/fleet-load` error reporting (1.4, r99 section 7) | `orc:src/bash/run/spl-hub-agent-kinds.func.sh:69-83`<br>`orc:src/bash/run/spl-hub-runner-cpu.func.sh:54-68`<br>`orc:src/bash/tests/hub-agent-kinds.tst.sh:78`<br>`orc:src/bash/tests/hub-runner-cpu.tst.sh:69` | copies of the `/v1/operator/fleet-load` non-200 error reporter 2 -> 1 (`_spl_hub_fleet_load_error` in `spl-hub-agent-kinds.func.sh`) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head's `hub-agent-kinds.tst.sh` on parent FAILs 5 checks (`rc2a`, rc 1, 18 pass, 6 fail lines, `_spl_hub_fleet_load_error: command not found` + one-copy) and head's `hub-runner-cpu.tst.sh` on parent FAILs one-copy naming `:63` (`rc2b`, rc 1, 16 pass, 2 fail lines), then GREEN (24/0 and 18/0); guard control (`gc2`, `declare -F _spl_hub_fleet_load_error` deleted in `spl-hub-runner-cpu.func.sh`: rc 1, 16 pass, 2 fail lines with `_spl_hub_fleet_load_error: command not found`; proves standalone-source path outside `./run`), built in a worktree; per-caller 500 checks catch `m2a`/`m2b` (1.5); outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 7 + 4 new checks. Tests: `orc:.../hub-agent-kinds.tst.sh`, `orc:.../hub-runner-cpu.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r01-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r01-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row extracts a duplicated setup or error-reporting block into one shared
helper and points its callers at that single home; no output, exit code, env var, path or
file a caller sees changes (1.3, 1.4, 1.5). Each: `Docs: none (<why>)`. The developer
guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `spl-hub-request-minutes.func.sh`, `spl-hub-run-metrics.func.sh`,
  `spl-hub-request-minutes.tst.sh`; row 02: `csi-spl-orc` `spl-hub-agent-kinds.func.sh`,
  `spl-hub-runner-cpu.func.sh`, `hub-agent-kinds.tst.sh`, `hub-runner-cpu.tst.sh`).
- No row edits `orc:src/bash/run/spl-hub-box-band.func.sh`,
  `orc:lib/bash/funcs/spl-hub-operator.func.sh`,
  `orc:src/bash/tests/hub-box-band.tst.sh`,
  `orc:src/bash/tests/spl-hub-load-test.tst.sh`,
  `orc:src/bash/tests/canary-hub-deploy.tst.sh`,
  `orc:src/bash/tests/spl-review-go.tst.sh`, `.shellcheck-warning-baseline.txt`,
  `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform, `csi-spl-api/`,
  `csi-spl-iac/`, `csi-spl-utl/`, or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (7, the 3 edited by row 01 + the 4 edited by row 02):
`orc:src/bash/run/spl-hub-request-minutes.func.sh`,
`orc:src/bash/run/spl-hub-run-metrics.func.sh`,
`orc:src/bash/tests/spl-hub-request-minutes.tst.sh`;
`orc:src/bash/run/spl-hub-agent-kinds.func.sh`,
`orc:src/bash/run/spl-hub-runner-cpu.func.sh`,
`orc:src/bash/tests/hub-agent-kinds.tst.sh`,
`orc:src/bash/tests/hub-runner-cpu.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <all 7 paths> --agent a-649`, n=1,
  at 2026-11-25T16:15:51Z: **exit 4** ("no live lane lists <the 7 paths>, but 22 live
  lane(s) record no files"). Verified via `do_spl_lane_map --all` at 16:16:15Z — the 22
  `unknown:` lanes, all on the other box: channel/workspace/other-repo seats (`c-029`,
  `c-041`, `c-086`, `c-146`, `c-187`, `c-398`, `c-407`, `c-416`, `c-426`, `c-474`,
  `c-535`, `c-566`, `c-728`, `c-927`, `c-936`), latency actions 2/3/4 (`c-561`, `c-569`,
  `c-571` on spool/hub messaging), GitHub token rate-limit bug (`c-476`), OpenAPI
  `comment_edited` bug (`c-529`, already landed `f80d7bd9c`/`96c48c9e6`), and spec 125
  doc/R7 seats (`c-957`, `c-965`). Live lanes on this box (`a-649`, `c-650` panel seat,
  `c-612`/`a-646` spec 192 L1, `c-609`/`a-637` WUI topic select box, `c-298`/`c-625`
  Reporting Taxes tab, `c-615`/`a-635` latency action 1, `c-638`/`a-473` r98-02 land,
  `a-607`/`a-628` R7 reviewers) touch none of the 7 paths. No live lane owns any of the
  7 paths; the holder re-reads at placement per R3.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 16:13:21Z): 9 queued,
  0 placing: this round's claude panel seat (`0c7f810b`, subsequently placed as `c-650`),
  `c002-bug-placer-review-seat-overflow-pass`, `c001-s186-m9-n2-qto-sync`, latency
  actions 5/6/7 (`a2082bff`, `22511683`, `5095c1c5`),
  `c002-orc-y9-agy-qwen-render-all-rule-parts`, a queued blog edit lane, and
  `c002-wui-notes-delete-key-selected`. None touches any of the 7 paths.
- **Unlanded rows from r98/r99:** none (r98-02 landed `60bc1836d`; r99-01 `05129cff9`,
  r99-02 `83a6b0d7d`, r99 closed `7a8ebd3cc`).
- **Briefs on this box** changed in the last 24 h matching any of the 7 paths (16:15:42Z):
  **0 briefs**.
- **Remote branches committed in the last 24 h** (`git for-each-ref`, 16:15:42Z):
  `git diff --name-only $(git merge-base fe1f82671 <b>) <b> -- <the 7 paths>` -> **0 hits**.
- **Commits in the last 24 h** on those 7 paths (`git log fe1f82671 --since='24 hours ago'`)
  -> **0**.

## 3. Per row: what the lane does

- **r01-01:** `orc:src/bash/run/spl-hub-request-minutes.func.sh` inserts
  `spl_hub_request_minutes_prep <since> <minutes>` after
  `spl_hub_request_minutes_check_args` (`:55`), documenting and setting process globals
  `SPL_HUB_REQ_SVC` and `SPL_HUB_REQ_UNTIL`, and replaces `:35-39` with
  `spl_hub_request_minutes_prep "$since" "$minutes" || return 1` +
  `svc="$SPL_HUB_REQ_SVC" until="$SPL_HUB_REQ_UNTIL"`;
  `orc:src/bash/run/spl-hub-run-metrics.func.sh` adds a
  `declare -F spl_hub_request_minutes_prep` lazy-source of sibling
  `spl-hub-request-minutes.func.sh` above `spl_hub_request_minutes_check_args` (`:13`)
  and replaces `:17-21` with the same 2 lines.
  `orc:src/bash/tests/spl-hub-request-minutes.tst.sh` appends section 5 (3 direct
  `spl_hub_request_minutes_prep` checks, 2 one-copy checks, 1 standalone lazy-load check,
  and 2 end-to-end `svc`/`until` wiring checks covering both actions).
- **r01-02:** `orc:src/bash/run/spl-hub-agent-kinds.func.sh` inserts
  `_spl_hub_fleet_load_error <subject_verb>` above `# _spl_hub_agent_kinds_report` (`:69`)
  and simplifies `_spl_hub_agent_kinds_report` (`:71-83`) to delegate every non-200
  status to `_spl_hub_fleet_load_error "the instance agent kinds were"`;
  `orc:src/bash/run/spl-hub-runner-cpu.func.sh` simplifies `_spl_hub_runner_cpu_report`
  (`:56-68`) to lazy-source sibling `spl-hub-agent-kinds.func.sh` behind a
  `declare -F _spl_hub_fleet_load_error` guard and delegate every non-200 status to
  `_spl_hub_fleet_load_error "the instance runner CPU cap was"`.
  `orc:src/bash/tests/hub-agent-kinds.tst.sh` appends section 6 (4 direct
  `_spl_hub_fleet_load_error` checks for 400/401/404/500, 2 end-to-end 404/500 checks,
  and 1 one-copy check); `orc:src/bash/tests/hub-runner-cpu.tst.sh` appends section 6 (2
  end-to-end 404/500 checks, 1 one-copy check, and 1 standalone lazy-load check).

## 4. Panel and reviewers (R7)

- Editor: **a-649** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; brief
  step 5; mistral sits on no review since 2026-11-25): claude panel seat **c-650**
  (already placed on this box, ask `0c7f810b`). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-25T16:13:54Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `kinds off grok,qwen`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 16:14:04Z (`main=agy backup=claude`; mistral sits on no review), R7 review of a
    claude coding row goes to an **agy seat** per row (claude waiver backup only while agy
    is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 16:14:01Z picked an available box; the
    holder re-checks agy capacity at row placement and uses the claude waiver backup only
    if agy is out of quota.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r01-01 | `c002-r01-01-orc-hub-window-prep` | `refactor(r01-01-orc-hub-window-prep, SPL-<row issue>): ...` | `review/r01-01` | 1 |
| r01-02 | `c002-r01-02-orc-fleet-load-error` | `refactor(r01-02-orc-fleet-load-error, SPL-<row issue>): ...` | `review/r01-02` | 1 |

**r01-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-hub-request-minutes.func.sh` (add
`spl_hub_request_minutes_prep` after `spl_hub_request_minutes_check_args` `:55`,
documenting process globals `SPL_HUB_REQ_SVC` and `SPL_HUB_REQ_UNTIL`; replace `:35-39`
with `spl_hub_request_minutes_prep "$since" "$minutes" || return 1` and
`svc="$SPL_HUB_REQ_SVC" until="$SPL_HUB_REQ_UNTIL"`),
`csi-spl-orc/src/bash/run/spl-hub-run-metrics.func.sh` (insert
`declare -F spl_hub_request_minutes_prep` lazy-source of sibling
`spl-hub-request-minutes.func.sh` above `spl_hub_request_minutes_check_args` `:13`;
replace `:17-21` with the same 2 lines), and
`csi-spl-orc/src/bash/tests/spl-hub-request-minutes.tst.sh` (append section 5 before
`:97`: 3 direct checks, 2 one-copy checks, 1 standalone lazy-load check, and 2 end-to-end
`svc`/`until` wiring checks). NOT `spl-hub-load-test.tst.sh`, NOT
`canary-hub-deploy.tst.sh`, NOT `.shellcheck-warning-baseline.txt`, or any other file.
Do: plan section 2 row 01 verbatim, 1.3's shape (verbatim blocks in 1.3); red control
(`rc1`, head's test on parent) RED then GREEN in the body; guard control (`gc1`,
`declare -F spl_hub_request_minutes_prep` deleted in `spl-hub-run-metrics.func.sh`, built
in a worktree, not a temp-dir copy; proves standalone-source path outside `./run`, while
under `./run` the lazy index emits stubs for both functions and the suites source
`.func.sh` eagerly). Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude; R7 **agy seat** (claude waiver
backup only while agy is out of quota, valid only under ruling `dc84300a` — cite ruling
`dc84300a` in the row brief if the claude backup is used; never mistral; re-checked at
placement).

**r01-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-hub-agent-kinds.func.sh` (add `_spl_hub_fleet_load_error`
above `# _spl_hub_agent_kinds_report` `:69`; simplify `_spl_hub_agent_kinds_report`
`:71-83` to delegate non-200 errors to `_spl_hub_fleet_load_error "the instance agent kinds were"`),
`csi-spl-orc/src/bash/run/spl-hub-runner-cpu.func.sh` (simplify
`_spl_hub_runner_cpu_report` `:56-68` to lazy-source sibling `spl-hub-agent-kinds.func.sh`
behind a `declare -F _spl_hub_fleet_load_error` guard and delegate non-200 errors to
`_spl_hub_fleet_load_error "the instance runner CPU cap was"`),
`csi-spl-orc/src/bash/tests/hub-agent-kinds.tst.sh` (append section 6 before `:78`: 4
direct checks for 400/401/404/500, 2 end-to-end 404/500 checks, and 1 one-copy check),
and `csi-spl-orc/src/bash/tests/hub-runner-cpu.tst.sh` (append section 6 before `:69`: 2
end-to-end 404/500 checks, 1 one-copy check, and 1 standalone lazy-load check). NOT
`spl-hub-box-band.func.sh`, NOT `lib/bash/funcs/spl-hub-operator.func.sh`, NOT
`hub-box-band.tst.sh`, NOT `spl-review-go.tst.sh`, NOT `.shellcheck-warning-baseline.txt`,
or any other file. Do: plan section 2 row 02 verbatim, 1.4's shape (verbatim blocks in
1.4); red controls (`rc2a` + `rc2b`, head's tests on parent) RED then GREEN in the body;
guard control (`gc2`, `declare -F _spl_hub_fleet_load_error` deleted in
`spl-hub-runner-cpu.func.sh`, built in a worktree, not a temp-dir copy; proves
standalone-source path outside `./run`). Gates: the row's tests (section 2,
`SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude; R7 **agy seat** (claude waiver backup only while agy is
out of quota, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row
brief if the claude backup is used; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the hub window service/pin/until setup (1.3) | 2 on `fe1f82671` (`spl-hub-request-minutes`, `spl-hub-run-metrics`) -> 1 (`spl_hub_request_minutes_prep`) after row 01 |
| copies of the `/v1/operator/fleet-load` non-200 error reporter (1.4) | 2 on `fe1f82671` (`spl-hub-agent-kinds`, `spl-hub-runner-cpu`) -> 1 (`_spl_hub_fleet_load_error`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spl-hub-request-minutes.func.sh` +16 -5, `spl-hub-run-metrics.func.sh` +4 -5, `spl-hub-request-minutes.tst.sh` +67 -0; row 02: `spl-hub-agent-kinds.func.sh` +19 -10, `spl-hub-runner-cpu.func.sh` +7 -11, `hub-agent-kinds.tst.sh` +27 -0, `hub-runner-cpu.tst.sh` +23 -0 |
| measured on | `fe1f82671` (zero drift on all 7 row/test files to `991ce5bc5`); n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-hub-box-band.func.sh:110-123` (`_spl_hub_box_band_report`) | has no `404)` branch (`404` falls into `*) FATAL box <box> band was not read or changed (http 404): ...`), so delegating to `_spl_hub_fleet_load_error` would change its 404 output (behaviour change, not refactor) | `diff -u` on `fe1f82671` (1.4) |
| `orc:src/bash/run/spl-hub-{agent-kinds,runner-cpu}.func.sh` (`ORDERED_BY`/`ORDERED_VIA`/`spl_dry_run` write-mode guard, `:30-32,40-42` vs `:29-31,39-41`) | candidate for `r02` once `r01-02` lands (touching the same two files; keep one logical refactor per row) | `git show fe1f82671` |
| `orc:src/bash/run/spl-msg-dedup.func.sh:46-65` and `spl-msg-wipe.func.sh:36-55` (20-line tenant/dry-run/confirm/pin/backup preflight) | strong candidate for `r02`, but `msg-dedup.tst.sh` and `msg-wipe.tst.sh` build `cmd/spool` and run against throwaway `postgres:16-alpine` containers (heavy PG R2 gate) | read `msg-dedup.tst.sh`, `msg-wipe.tst.sh` on `fe1f82671` |
| `orc:src/bash/run/spl-msg-move.func.sh` and `spl-topic-move.func.sh` (desk setup, dry-run, and JSON output block) | strong candidate for `r02` (fast pure-bash tests); left for next round under 5.1's 2-row cadence | read both `.func.sh` on `fe1f82671` |
| `orc:src/bash/run/{check-disk-headroom-install-cron,setup-box-stats-cron,setup-go-cache-prune-cron}.func.sh` (cron action/every/off/dry-run/check/write blocks) | strong 3-file candidate for `r02` (fast tests); left for next round under 5.1's 2-row cadence (note `check-disk-headroom-install-cron:36` adds `(( every == 1 )) && off=0` and `:56` adds `DRY_RUN=0`) | read all 3 `.func.sh` on `fe1f82671` |
| `iac:src/bash/run/gcp-{get-alert-incident,list-alert-incidents}.func.sh` (paged Monitoring v3 `timeSeries` curl loop, `:71-82`, `:89-100`) | clean 12-line duplicate, but passes `-K "${cfg}/auth.curl"` (Bearer access token file); kept out while non-secret `orc` duplicates remain | read both `.func.sh` on `fe1f82671` |
| `orc:src/bash/run/spl-channel-agent-{add,add-op,remove-op}.func.sh` (`AGENT_BOX` + `AGENTS` validation/dedup) | `dispatch-inbound-pg.tst.sh:141` directly sources `spl-channel-agent-add-op.func.sh`, pulling a PostgreSQL test into R2; unchanged since r99 | r99 7; 1.2 (a) |
| `orc:src/bash/run/spl-box-restart-install-cron.func.sh` / `spl-peer-crons.func.sh` and `spl-{backfill,fallback,reply,reply-count,topic-reply}-probe.func.sh` | candidates for `r02`+ (the 5 probe actions touch 5+ files); unchanged since r99 | r99 7; 1.2 (a) |
| `orc:src/bash/run/{spl-accepted-close,spl-desk-poll-ack,spl-review-go}.func.sh` (`_spl_*_holder`) | `spl-review-go.func.sh` changed in `7d3be08fd` (SPL-6505), and moving the helper to `spl-dispatch-lease.func.sh` pulls 30+ tests (incl. PG) into R2 | r99 7; 1.2 (a) |
| `orc:src/bash/run/spl-wui-perf-report.func.sh:69-75`, `csi-spl-utl/**`, secret-class sites (`spl-lane-handover*`, `spl-release-note-bans-*`, `spl-secret-*`, `iac` GH repo parsers), `iac:sec-*.func.sh`, `orc:scripts/*-cron.sh`, Go/WUI duplicates, remaining r91..r98 non-framework groups, and candidates-file non-refactor / already-served items | unchanged on `fe1f82671`; each stays out for its r99/r98..r91 section 7 reason | r99 7; 1.2 (a), (c) |

## 8. Changes

- v0.1 (a-649): the rows and every read on `fe1f82671` (zero drift on all 7 row/test
  files to `991ce5bc5`); both heads built in detached scratch worktrees; the 13-suite
  column of 1.5 run on base and each row's head; `shellcheck -S warning -x` and
  `do_sec_shellcheck` rc 0; all 5 red and guard controls (`rc1`, `gc1`, `rc2a`, `rc2b`,
  `gc2`) and all 4 mutation checks (`m1a`, `m1b`, `m2a`, `m2b`) RED then GREEN; R3 (2.2)
  and R7 (section 4) checked; numbering `r01` confirmed per rulebook 5.3 and holder ruling
  `83dd3a25`.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-649 (agy): v0.1.
- Panel reviewer seat: c-650 (claude): pending v0.1 review.
- Row R7 seats: section 4 (agy per row, claude waiver backup only under ruling `dc84300a`;
  never mistral).
