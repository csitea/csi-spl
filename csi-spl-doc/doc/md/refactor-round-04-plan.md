# Refactoring round 04 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6547  
Topic: e05f594f-6f3c-458f-abfb-291966db4632  
Discussion: e05f594f-6f3c-458f-abfb-291966db4632 (t1 #refactoring, "Refactor round 04", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3), so this round is
  **r04**, plan `refactor-round-04-plan.md` (free: only `refactor-round-4-plan.md` exists,
  so no date suffix), rows `r04-<NN>`, scope `docs(r04-plan, SPL-6547)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574). **Vendor claude
  for every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 03 ([refactor-round-03-plan.md](refactor-round-03-plan.md)
v1.0 `fffd329fd`) is closed (`ffba81845`): both `r03-01` (`3f1383643`, SPL-6545) and
`r03-02` (`0fcaa450b`, SPL-6546) landed on `origin/master` with cross-vendor agy R7 PASS.
The perf floor (rulebook 4.4), measured on `ffba81845` at 2026-11-26T00:47:49Z (14 days):
perf 36, refactor 111, 24.5%, 5 x 36 = 180 >= 147, floor-met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), continuing directly from
r02-02 (`8ff47fd73`) and r03-02 (`0fcaa450b`) and taking the top two candidates from r03
section 7: duplicated `orc:src/bash/run/` scaffolding delegates to one shared helper in a
sibling file, leaving every log line, env var, and path unchanged (row 01 also tightens a
pre-existing `ISSUE_PLAN` file in `oq` to `0600`, enforcing the `0600` contract already
documented at `oq:72`, and returns 1 if that `chmod` fails).
**Row 01:** the two Postgres-read-then-desk-diss issue cleanup actions in
`orc:src/bash/run/` — `spl-issue-blocker-rca-close.func.sh` and
`spl-issue-owner-question-diss.func.sh` (r03 section 7 #2) — already share
`spl_issue_brc_one` (r90-02) but still duplicate three complete blocks: (a) the 14-line
plan-read / verdicts / count-log / dry-run-or-apply driver (`brc:41-54` vs `oq:39-52`),
(b) the 7-line `*_plan_path` state-dir/0600-plan creator (`brc:71-77` vs `oq:73-79`), and
(c) the 8-line `spl_psql_ro` + `spl_sql_proxy_stop` + `FATAL read-only query` body
(`brc:90-97` vs `oq:93-100`). Extracting `_spl_issue_brc_run_plan` and parameterising
`spl_issue_brc_plan_path [SUBDIR]` and `_spl_issue_brc_query [SQL_FN]` in
`spl-issue-blocker-rca-close.func.sh` lets `spl-issue-owner-question-diss.func.sh` drop
`spl_issue_oq_plan_path` and delegate all three blocks behind `declare -F` lazy-source
guards while keeping `do_spl_cloud_cnf` ordering and `spl_issue_oq_apply`'s distinct
re-read check and `r90-02` `spl_issue_brc_one` call untouched.
**Row 02:** the next three single-line periodic cron installers in `orc:src/bash/run/` —
`spl-spawn-remote-install-cron.func.sh:58-92`,
`spl-unanswered-sweep-install-cron.func.sh:71-105`, and
`spl-workspace-delivery-probe-install-cron.func.sh:64-94` (r03 section 7 #1) — carry the
exact same 31-35 line `check` / `DRY_RUN=1` / `remove` / `install` crontab state machine
hosted in `_spl_simple_cron_apply` (`setup-box-stats-cron.func.sh:67-105`), differing only
in omitting the trailing word `" cron"` after the job subject (`"the spawn receiver"`,
`"the unanswered sweep"`, `"the delivery probe"`). Adding an optional 11th parameter
`noun="${11- cron}"` (defaulting to `" cron"` when unset, so all six wave-1 and wave-2
callers stay untouched and byte-identical) lets all three wave-3 installers lazy-source
`setup-box-stats-cron.func.sh` and pass `""` as arg 11.
The rows share no file: both are batch 1.

**Status: v0.2 (folded panel FAIL W1, W2 and N1-N6; awaiting panel re-review).** Editor:
**a-852** (agy). Cross-vendor claude panel seat **c-804** returned FAIL on v0.1
(`4ded3bf46`, seat commit `16df4c069`) for W1 and W2; v0.2 folds W1 (option a), W2, and
N1-N6 on `review/c002-refactor-round-04-planner` for re-review before v1.0 signing and
landing.

**One sha:** every count is measured on **`ffba81845`** (`ffba818456f9b6f171c0fac34a2d7c6d94918a02`,
`origin/master` at 2026-11-26T00:47:49Z), n=1 per command unless stated. Reads are on
`ffba81845` with `git show` / `git grep`. The tests of 1.5 ran in detached scratch
worktrees of `ffba81845` (not committed, removed on exit): "base" unmodified, "head1" =
base with row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's
shape; each red control, guard control, and mutation check (1.5) ran in a detached
worktree of its own. All helper definitions, caller replacements, and test hunks are
reproduced verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2,
all 8 red/guard controls, and all 5 mutation checks byte-for-byte on `ffba81845` and
verify every sha256. Queue, lane map, brief and branch reads are live state and carry
their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-26T00:47:49Z, n=1, after a fresh fetch (`git-fetch-fresh.sh --force`):

- **Window: W=2026-11-26T02:43:46+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r03-plan'`:
  `ffba818456f9b6f171c0fac34a2d7c6d94918a02`
  (`docs(r03-plan, SPL-6540): refactor round 03 closed: r03-01 3f1383643 and r03-02 0fcaa450b landed, agy R7 PASS each`),
  read once at the start as 5.3 says (moved from v1.0 `fffd329fd` `2026-11-26T01:27:29+02:00`
  by round 03's close record `ffba81845`). Per rulebook 5.3, `W` stays fixed at this
  recorded date (`2026-11-26T02:43:46+02:00`); all later R4, R6, 2.7.5, and `PRUNE_SINCE`
  reads for r04 must use `W=2026-11-26T02:43:46+02:00`.
- `git log origin/master --since="$W" --oneline -E --grep='\(r04-' | wc -l` -> **0**.
- `git ls-remote origin 'refs/heads/review/r04-*' 'refs/heads/*-r04-*' 'refs/heads/*refactor-round-04*' 'refs/heads/wip/*r04*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r04-[0-9]{2}|refactor-round-04'` (local to
  the planner/holder box only, not on the panel seat's box; re-confirmed by the dispatch
  holder at 01:4xZ) -> **2** briefs only: this planner's brief and the panel seat's brief
  (`c002-refactor-round-04-claude-panel-seat.md`); 0 `r04-NN` row briefs.
- `git ls-tree --name-only ffba81845 csi-spl-doc/doc/md/ | grep -c refactor-round-04`
  -> **0** (only `refactor-round-4-plan.md` exists, so `refactor-round-04-plan.md` is free
  with no date suffix per rulebook 5.3).

### 1.2 The brief's inputs, re-measured

- **(a) r03 section 7:** re-read on `ffba81845` (`git diff --name-only bfdbd57d5 ffba81845`:
  50 files; none of the r03 section 7 candidates changed since `bfdbd57d5`).
  - `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and
    `spl-issue-owner-question-diss.func.sh`: 3 duplicated multi-line blocks (`do_spl_*`
    plan-read/verdicts/dry-run-or-apply driver, `*_plan_path`, and `_*_query`), pure-bash
    unit tests, already paired via `spl_issue_brc_one` (r90-02) -> measured here as
    **row 01** (1.3). The remaining `*_read` (`brc:81-86` vs `oq:83-89`) and `*_apply`
    (`brc:126-151` vs `oq:136-162`) scaffolding also listed in r03 section 7 #2 stay out
    of r04 and are accounted for in section 7 as `r05`+ candidates.
  - Remaining single-line cron installers matching `_spl_simple_cron_apply`
    (`setup-box-stats-cron.func.sh`): 6 remained after r03-02 (`0fcaa450b`). The 3
    cleanest pure-bash wave-3 matches (`spl-spawn-remote-install-cron.func.sh`,
    `spl-unanswered-sweep-install-cron.func.sh`,
    `spl-workspace-delivery-probe-install-cron.func.sh`) match `_spl_simple_cron_apply`
    byte-for-byte once an optional 11th parameter `noun="${11- cron}"` allows omitting
    `" cron"` -> measured here as **row 02** (1.4); `spl-orch-rotate-install-cron.func.sh`
    (whose test `orch-rotate.tst.sh` is 1,255 lines), `spl-dispatch-rotate-install-cron.func.sh`
    (two-line rotate+heal installer), and `spl-agent-boot-restore-install-cron.func.sh`
    (retire/removed marker branches) stay in section 7 for `r05`+.
  - All other r03 section 7 items (`spl-msg-{dedup,wipe}`, `spl-box-restart-install-cron`
    / `spl-peer-crons`, 5 probe actions, secret-class `gcp-*alert*`, PG-coupled
    `spl-channel-agent-*` and `spl-{accepted-close,desk-poll-ack,review-go}`, etc.) remain
    unchanged on `ffba81845` and stay accounted for in section 7.
- **(b) R7 notes of r03-01 and r03-02:**
  - `r03-01` (`3f1383643`, SPL-6545, R7 `a-838`, agy, PASS on `0caad6b18`): clean match to
    r03 plan 1.3 head1 verbatim, no refactor follow-up.
  - `r03-02` (`0fcaa450b`, SPL-6546, R7 `a-841`, agy, PASS on `26776d8b1`; author `c-784`
    note relayed to `a-808` and recorded in r03 section 8): `orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh:83-91`
    section 4 "red control" copies `setup-gh-runner-cpu-budget-cron.func.sh` into `$T/nofloor.func.sh`,
    where its relative `dirname "${BASH_SOURCE[0]}"` sources fail even on an unmodified
    copy, making section 4 vacuous. That is a test-bug fix, not a refactor row (brief:
    "bug rows and test rows are not yours"), so it is accounted for in section 7 and stays
    out of r04.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, local to the holder/planner
  box only and not on the panel seat's box; 142 lines, 31,775 bytes, read 00:47Z and
  re-confirmed by the dispatch holder at 01:4xZ):
  - Only addition since r03 is a bug-round-48 `spl-review-go.func.sh` false-hold item
    (lines 141-142, bug-shaped).
  - All earlier items remain served or out of scope (bug, perf, doc, test-hardening, or
    other-repo items), accounted for in section 7.
- **(d) spec 011 tasks:**
  `git log bfdbd57d5..ffba81845 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r03's base; remaining open/partial tasks (T001-T008
  owner-deferred, T018-T021, T023, T025-T028, T031, T034) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` share `_spl_issue_brc_run_plan`, `spl_issue_brc_plan_path`, and `_spl_issue_brc_query`

`orc:` = `csi-spl-orc/`. On `ffba81845`:

- Three blocks are duplicated between `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh`
  and `orc:src/bash/run/spl-issue-owner-question-diss.func.sh`:
  1. Plan-read, verdicts, candidate-count log, and dry-run/apply dispatch (`brc:41-54` vs
     `oq:39-52`, 14 lines each): `diff -u` -> 4 diff lines (2 differing function-name lines:
     `spl_issue_brc_read`/`verdicts`/`apply` vs `spl_issue_oq_read`/`verdicts`/`apply`, n=1).
  2. Plan file creation (`brc:71-77` vs `oq:73-79`, 7 lines each): `diff -u` -> 6 diff
     lines (function name, state subdir `issue-blocker-rca` vs `issue-owner-question`,
     and `brc`'s explicit `&& chmod 600 "$p"` after `(umask 077; : >"$p")`). Base `oq:77`
     omits `chmod 600 "$p"`, so a pre-existing `0644` `ISSUE_PLAN` stayed `644` on base
     and is now tightened to `600` on head1 (enforcing the `0600` contract already
     documented at `oq:72`, and returning 1 if `chmod` fails, n=1).
  3. Read-only SQL query execution and proxy stop (`brc:90-97` vs `oq:93-100`, 8 lines
     each): `diff -u` -> 4 diff lines (function name and `spl_issue_brc_sql` vs
     `spl_issue_oq_sql`, n=1).
- `_spl_issue_brc_run_plan` has **0 collisions** anywhere in the repo
  (`git grep -nE '_spl_issue_brc_run_plan' origin/master` -> 0). Both `.func.sh` files
  contain only function definitions (zero top-level code) and already pair via
  `spl_issue_brc_one` (`oq:140`, r90-02). Placing `_spl_issue_brc_run_plan` in
  `spl-issue-blocker-rca-close.func.sh`, adding an optional `[SUBDIR]` arg (default
  `issue-blocker-rca`, passed explicitly by `do_spl_issue_blocker_rca_close` so
  `shellcheck` SC2120 stays clean) to `spl_issue_brc_plan_path`, and adding an optional
  `[SQL_FN]` arg (default `spl_issue_brc_sql`) to `_spl_issue_brc_query` lets
  `spl-issue-owner-question-diss.func.sh` drop `spl_issue_oq_plan_path` completely and
  delegate all three blocks behind `declare -F` lazy-source guards (`do_spl_issue_owner_question_diss`
  guards `_spl_issue_brc_run_plan`; `_spl_issue_oq_query` guards `_spl_issue_brc_query`;
  `spl_issue_oq_apply` keeps its existing `declare -F spl_issue_brc_one` guard and
  `if spl_issue_brc_one "$key" "$why"; then` line untouched so standalone calls and the
  existing `r90-02` assertion in `spl-issue-owner-question-diss.tst.sh:74` remain intact).
- `do_spl_cloud_cnf` stays in `do_spl_issue_blocker_rca_close` before `plan_path` and in
  `spl_issue_oq_read` for `oq`, preserving exact execution order and test stubs. Lazy-load
  note (N4): sourcing `spl-issue-blocker-rca-close.func.sh` inside
  `do_spl_issue_owner_question_diss` when `_spl_issue_brc_run_plan` is undefined also
  (re)defines `spl_issue_brc_one` (previously sourced only inside `spl_issue_oq_apply`
  when `spl_issue_brc_one` was undefined). Verified on `ffba81845`:
  `git grep -n 'spl_issue_brc_one *()' ffba81845` -> 1 hit
  (`spl-issue-blocker-rca-close.func.sh:154`, its own definition); no test or caller stubs
  `spl_issue_brc_one` alone, so no separate stub or guard is needed. Neither file handles
  credentials or secrets directly (non-secret; DB auth stays in `spl_db_query_rc`).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `do_spl_issue_blocker_rca_close`
  21 -> 8 lines; `_spl_issue_brc_run_plan` is 17 lines; `spl_issue_brc_plan_path` 7 -> 8
  lines; `_spl_issue_brc_query` stays 8 lines; `do_spl_issue_owner_question_diss` 20 -> 9
  lines; `spl_issue_oq_plan_path` 7 -> deleted; `_spl_issue_oq_query` 8 -> 5 lines; all
  other functions unchanged (max 27 lines). None of the 4 edited files has any entry in
  `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt`, or `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh`: replace `:35-55` with
  `do_spl_issue_blocker_rca_close` delegating to `_spl_issue_brc_run_plan` plus the
  `_spl_issue_brc_run_plan` helper; update `spl_issue_brc_plan_path` (`:69-77`) to accept
  optional `[SUBDIR]` (default `issue-blocker-rca`); update `_spl_issue_brc_query`
  (`:88-97`) to accept optional `[SQL_FN]` (default `spl_issue_brc_sql`). 158 -> 168 lines
  (`+20 -10`).
- `orc:src/bash/run/spl-issue-owner-question-diss.func.sh`: replace `:34-53` with
  `do_spl_issue_owner_question_diss` lazy-sourcing `spl-issue-blocker-rca-close.func.sh`
  and calling `spl_issue_brc_plan_path issue-owner-question` + `_spl_issue_brc_run_plan`;
  delete `spl_issue_oq_plan_path` (`:71-80`); replace `_spl_issue_oq_query` (`:91-100`)
  with a 5-line lazy-source delegator to `_spl_issue_brc_query spl_issue_oq_sql`.
  162 -> 137 lines (`+9 -34`).
- `orc:src/bash/tests/spl-issue-blocker-rca-close.tst.sh`: append 4 checks before `:130`
  (`[[ $fails -eq 0 ]]`): direct `spl_issue_brc_plan_path` subdir +
  `_spl_issue_brc_run_plan` dry/live check, direct `_spl_issue_brc_query` custom `SQL_FN`
  success and error checks (both stopping proxy), and 1 one-copy check. 130 -> 176 lines
  (`+46 -0`).
- `orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh`: append 4 checks before `:89`
  (`[[ $fails -eq 0 ]]`): 1 one-copy check (no `spl_issue_oq_plan_path`, no duplicated
  `OK DRY_RUN nothing was moved. PLAN`, no duplicated `FATAL read-only query on`, calls
  all three brc helpers), 1 standalone `IN_ORC_RUN=spl-issue-owner-question-diss` dry-run
  check asserting the default `issue-owner-question` subdir (0700 dir, 0600 file), 1
  standalone `_spl_issue_oq_query` lazy-load check asserting `spl_issue_oq_sql` is passed
  to `spl_psql_ro` and proxy stops, and 1 red-then-green plan-mode check asserting a
  pre-existing `0644` `ISSUE_PLAN` is tightened to `0600` (base: `644`, head1: `600`).
  89 -> 124 lines (`+35 -0`).
- head1's files, sha256 (12 chars): `spl-issue-blocker-rca-close.func.sh` `c9476da5a155`,
  `spl-issue-owner-question-diss.func.sh` `3cfae296d937`,
  `spl-issue-blocker-rca-close.tst.sh` `29126e34f396`,
  `spl-issue-owner-question-diss.tst.sh` `fcd6c8c7efbd`.
- Note for the row and its reviewer: build `gc1a`, `gc1b`, `m1a`, and `m1b` in detached
  git worktrees, not single-file temp copies, because the lazy-source guards load their
  sibling via `dirname "${BASH_SOURCE[0]}"`.

Verbatim helper, caller, and test hunks (head1 on `ffba81845`):

`orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` (`:35-55` replacement):
```bash
do_spl_issue_blocker_rca_close() {
  local dry=1 plan
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_issue_brc_check "$dry" || return 1
  do_spl_cloud_cnf || return 1
  plan="$(spl_issue_brc_plan_path issue-blocker-rca)" || return 1
  _spl_issue_brc_run_plan "$dry" "$plan" spl_issue_brc_read spl_issue_brc_verdicts spl_issue_brc_apply
}

# _spl_issue_brc_run_plan DRY PLAN READ_FN VERDICTS_FN APPLY_FN -> read rows
# into a temp file, write verdicts to PLAN, log counts, and either preview
# (DRY=1) or run APPLY_FN (DRY=0).
_spl_issue_brc_run_plan() {
  local dry="$1" plan="$2" read_fn="$3" verdicts_fn="$4" apply_fn="$5" rows rc=0
  rows="$(mktemp)"
  if "$read_fn" >"$rows" && "$verdicts_fn" <"$rows" >"$plan"; then
    do_log "INFO $(grep -c . "$plan" || true) candidates: $(cut -f3 "$plan" | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
    if (( dry )); then
      cat "$plan"
      do_log "OK DRY_RUN nothing was moved. PLAN $plan"
    else
      "$apply_fn" "$plan" || rc=1
    fi
  else
    rc=1
  fi
  rm -f "$rows"
  return $rc
}
```

`orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` (`:69-77` replacement):
```bash
# spl_issue_brc_plan_path [SUBDIR] -> ISSUE_PLAN, or a fresh name in a 0700
# state dir (default subdir issue-blocker-rca). The plan holds titles
# (workspace data): 0600, never in git.
spl_issue_brc_plan_path() {
  local sub="${1:-issue-blocker-rca}"
  local p="${ISSUE_PLAN:-${SPL_STATE_DIR}/${sub}/${TENANT_ID}-$(date -u +%Y%m%dT%H%M%SZ).plan.tsv}"
  mkdir -p "$(dirname "$p")" || return 1
  [[ -n "${ISSUE_PLAN:-}" ]] || chmod 700 "$(dirname "$p")"
  (umask 077; : >"$p") && chmod 600 "$p" || return 1
  printf '%s\n' "$p"
}
```

`orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` (`:88-97` replacement):
```bash
# _spl_issue_brc_query [SQL_FN]: the read, once $dsn is the local login. Stops the proxy.
# shellcheck disable=SC2154 # dsn: bound by spl_db_query_rc, via dynamic scope
_spl_issue_brc_query() {
  local sql_fn="${1:-spl_issue_brc_sql}" out qrc
  out="$(spl_psql_ro "$dsn" "$("$sql_fn")")"
  qrc=$?
  spl_sql_proxy_stop
  [[ $qrc == 0 ]] || { do_log "FATAL read-only query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; return 1; }
  [[ -z "$out" ]] || printf '%s\n' "$out"
}
```

`orc:src/bash/run/spl-issue-owner-question-diss.func.sh` (`:34-53` replacement; also
delete `spl_issue_oq_plan_path` at `:71-80`):
```bash
do_spl_issue_owner_question_diss() {
  local dry=1 plan
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_issue_oq_check || return 1
  # shellcheck source=spl-issue-blocker-rca-close.func.sh
  declare -F _spl_issue_brc_run_plan >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-issue-blocker-rca-close.func.sh"
  plan="$(spl_issue_brc_plan_path issue-owner-question)" || return 1
  _spl_issue_brc_run_plan "$dry" "$plan" spl_issue_oq_read spl_issue_oq_verdicts spl_issue_oq_apply
}
```

`orc:src/bash/run/spl-issue-owner-question-diss.func.sh` (`:91-100` replacement):
```bash
# _spl_issue_oq_query: callback for spl_db_query_rc; delegates to _spl_issue_brc_query.
_spl_issue_oq_query() {
  # shellcheck source=spl-issue-blocker-rca-close.func.sh
  declare -F _spl_issue_brc_query >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-issue-blocker-rca-close.func.sh"
  _spl_issue_brc_query spl_issue_oq_sql
}
```

`orc:src/bash/tests/spl-issue-blocker-rca-close.tst.sh` (inserted immediately before
`[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }` at `:130`,
followed by one blank line):
```bash
# --- r04-01 shared helpers (_spl_issue_brc_run_plan, plan_path subdir, query) ---
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" TENANT_ID=t1 SPL_STATE_DIR="$T/state/sub" bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }
  source "$PROJ_ROOT/src/bash/run/spl-issue-blocker-rca-close.func.sh"
  p="$(spl_issue_brc_plan_path issue-owner-question)" || exit 1
  printf "P=%s MODE=%s DMODE=%s\n" "$p" "$(stat -c %a "$p")" "$(stat -c %a "$(dirname "$p")")"
  r_fn(){ printf "SPL-1\ttodo\thello\n"; }
  v_fn(){ awk -F"\t" -v OFS="\t" "{print \$1,\$2,\"MOVE\",\"w\",\$3}"; }
  a_fn(){ echo "APPLIED:$1"; }
  _spl_issue_brc_run_plan 1 "$p" r_fn v_fn a_fn || exit 1
  _spl_issue_brc_run_plan 0 "$p" r_fn v_fn a_fn || exit 1' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"P=$T/state/sub/issue-owner-question/t1-"*"MODE=600 DMODE=700"* &&
  "$out" == *"OK DRY_RUN nothing was moved. PLAN $T/state/sub/issue-owner-question/t1-"* &&
  "$out" == *"APPLIED:$T/state/sub/issue-owner-question/t1-"* ]] &&
  pass "r04-01: spl_issue_brc_plan_path accepts subdir and _spl_issue_brc_run_plan drives dry and live runs" ||
  fail "r04-01 plan_path/run_plan (rc=$rc): $out"

out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }
  spl_psql_ro(){ printf "DSN=%s SQL=%s\n" "$1" "$2"; }
  spl_sql_proxy_stop(){ echo "STOPPED"; }
  my_sql(){ echo "SELECT 42;"; }
  source "$PROJ_ROOT/src/bash/run/spl-issue-blocker-rca-close.func.sh"
  dsn=pg://local _spl_issue_brc_query my_sql' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"STOPPED"* && "$out" == *"DSN=pg://local SQL=SELECT 42;"* ]] &&
  pass "r04-01: _spl_issue_brc_query runs caller SQL_FN and stops proxy" ||
  fail "r04-01 query ok (rc=$rc): $out"

out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }
  spl_psql_ro(){ echo "boom"; return 2; }
  spl_sql_proxy_stop(){ echo "STOPPED"; }
  my_sql(){ echo "SELECT 42;"; }
  source "$PROJ_ROOT/src/bash/run/spl-issue-blocker-rca-close.func.sh"
  SPL_SQL_CONN=c SPL_DB_NAME=d dsn=pg://local _spl_issue_brc_query my_sql' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"STOPPED"* && "$out" == *"FATAL read-only query on c/d failed: boom"* ]] &&
  pass "r04-01: _spl_issue_brc_query stops proxy and logs FATAL on psql error" ||
  fail "r04-01 query fail (rc=$rc): $out"

brc_f="$PROJ_ROOT/src/bash/run/spl-issue-blocker-rca-close.func.sh"
[[ "$(grep -c 'OK DRY_RUN nothing was moved. PLAN' "$brc_f")" -eq 1 &&
  "$(grep -c 'FATAL read-only query on' "$brc_f")" -eq 1 &&
  "$(grep -c '_spl_issue_brc_run_plan ' "$brc_f")" -ge 1 ]] &&
  pass "r04-01 one copy: spl-issue-blocker-rca-close.func.sh hosts the single plan-run and query helpers" ||
  fail "r04-01 brc one copy"
```

`orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh` (inserted immediately before
`[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }` at `:89`,
followed by one blank line):
```bash
# --- r04-01 shared helpers delegation and standalone lazy-source ----------------
oq_f="$PROJ_ROOT/src/bash/run/spl-issue-owner-question-diss.func.sh"
own_r04="$(grep -nE 'spl_issue_oq_plan_path|OK DRY_RUN nothing was moved\. PLAN|FATAL read-only query on' "$oq_f" || true)"
[[ -z "$own_r04" ]] &&
  grep -q '_spl_issue_brc_run_plan "$dry" "$plan" spl_issue_oq_read spl_issue_oq_verdicts spl_issue_oq_apply' "$oq_f" &&
  grep -q 'spl_issue_brc_plan_path issue-owner-question' "$oq_f" &&
  grep -q '_spl_issue_brc_query spl_issue_oq_sql' "$oq_f" &&
  pass "r04-01 one copy: spl-issue-owner-question-diss.func.sh delegates plan_path, run_plan and query to brc helpers" ||
  fail "r04-01 oq one copy: own=[$own_r04]"

: >"$T/desk.log"
SNIPPET="${STUBS}do_spl_issue_owner_question_diss" in_orc "${base[@]}" IN_ORC_RUN=spl-issue-owner-question-diss \
  SPL_STATE_DIR="$T/state/oq-solo" >"$T/o" 2>&1; rc=$?
p_solo="$(ls "$T/state/oq-solo/issue-owner-question/"t1-*.plan.tsv 2>/dev/null || true)"
[[ $rc -eq 0 && -n "$p_solo" && "$(stat -c %a "$T/state/oq-solo/issue-owner-question")" == 700 &&
  "$(stat -c %a "$p_solo")" == 600 ]] && grep -q "OK DRY_RUN nothing was moved. PLAN $p_solo" "$T/o" &&
  pass "r04-01 standalone dry run: loads brc helpers and writes 0600 plan under issue-owner-question (0700)" ||
  fail "r04-01 oq solo dry (rc=$rc): $(cat "$T/o")"

out=$(env PROJ_ROOT="$PROJ_ROOT" "${base[@]}" bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }
  spl_psql_ro(){ printf "DSN=%s SQL=%s\n" "$1" "$2"; }
  spl_sql_proxy_stop(){ echo "STOPPED"; }
  source "$PROJ_ROOT/src/bash/run/spl-issue-owner-question-diss.func.sh"
  dsn=pg://local _spl_issue_oq_query' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"STOPPED"* && "$out" == *"DSN=pg://local"* && "$out" == *"assignee = 'HUM-10'"* && "$out" != *"command not found"* ]] &&
  pass "r04-01 standalone query: _spl_issue_oq_query lazy-loads _spl_issue_brc_query and passes spl_issue_oq_sql" ||
  fail "r04-01 oq solo query (rc=$rc): $out"

(umask 022; : >"$T/plan.tsv"; chmod 644 "$T/plan.tsv")
run
[[ $RC -eq 0 && "$(stat -c %a "$T/plan.tsv")" == 600 ]] &&
  pass "r04-01 plan mode: an existing 0644 ISSUE_PLAN is tightened to 0600" ||
  fail "r04-01 existing plan mode (rc=$RC): $(stat -c %a "$T/plan.tsv")"
```

**Behaviour:** one intentional tightening — routing `oq` through `spl_issue_brc_plan_path`
runs `(umask 077; : >"$p") && chmod 600 "$p" || return 1`, so `oq`'s plan file is now
`0600` also when `ISSUE_PLAN` names a pre-existing file (enforcing the `0600` contract
already stated at `oq:72`; measured on a pre-existing `0644` `ISSUE_PLAN`: base `rc=0,
mode=644`, head1 `rc=0, mode=600`, n=1 each), and a `chmod` failure on an existing file
now returns 1 where base returned 0. All other commands, file modes (`0700` dir, `0600`
fresh plan), log lines, proxy stop, exit codes, `do_spl_cloud_cnf` ordering, and
`spl_issue_oq_apply`'s distinct re-read check stay unchanged. All row-01 and shared
suites pass on base and head1 with identical counts plus the 4 + 4 new checks (1.5).

### 1.4 Row 02's site: `_spl_simple_cron_apply` optional `[noun]` and wave-3 delegation for `spl-spawn-remote-install-cron`, `spl-unanswered-sweep-install-cron`, and `spl-workspace-delivery-probe-install-cron`

`orc:` = `csi-spl-orc/`. On `ffba81845`:

- `orc:src/bash/run/spl-spawn-remote-install-cron.func.sh:58-92` (35 lines),
  `orc:src/bash/run/spl-unanswered-sweep-install-cron.func.sh:71-105` (35 lines), and
  `orc:src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh:64-94` (31 lines)
  carry the exact `current="$(spl_desk_cron_line "$tag")"` + `check` / `DRY_RUN=1` /
  `remove` / `install` crontab state machine hosted in `_spl_simple_cron_apply`
  (`orc:src/bash/run/setup-box-stats-cron.func.sh:67-105`), differing only in the job
  subject omitting `" cron"` (`"spawn receiver"`, `"unanswered sweep"`, `"delivery probe"`),
  the install OK verb, and optional missing-line suffix:
  `diff -u` of `spl-spawn-remote-install-cron.func.sh:58-92` against
  `spl-unanswered-sweep-install-cron.func.sh:71-105` -> 8 diff lines (the 4 log lines);
  against `spl-workspace-delivery-probe-install-cron.func.sh:64-94` -> 11 diff lines (the
  same 4 log lines plus `if [[ -z "$current" ]]` vs `[[ -n "$current" ]] ||` formatting,
  n=1 each).
- Adding an optional 11th parameter `noun="${11- cron}"` (single dash `-`, NOT `:-`, so
  an unset 11th arg defaults to `" cron"` while an explicit `""` yields empty `noun`,
  producing `subj="${label}${noun}"`) in `_spl_simple_cron_apply` preserves **100%
  backward compatibility** with all 6 existing wave-1 and wave-2 callers
  (`setup-box-stats-cron`, `check-disk-headroom-install-cron`, `setup-go-cache-prune-cron`,
  `check-env-order-install-cron`, `setup-ci-overflow-cron`,
  `setup-gh-runner-cpu-budget-cron`) with **zero edits** to those 5 sibling files.
- All three wave-3 installers lazy-source `setup-box-stats-cron.func.sh` behind a
  `declare -F _spl_simple_cron_apply` guard inside their action functions, adding zero
  top-level lines, keeping `run-lazy-loader.tst.sh` and `run-eager-files.tst.sh`
  unchanged, and working when sourced standalone (with `spl-desk-install-service.func.sh`,
  which defines `spl_desk_cron_src`). None of the four edited `.func.sh` files handles any
  token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `do_setup_box_stats_cron` stays 29
  lines; `_spl_simple_cron_apply` 39 -> 40 lines; `do_spl_spawn_remote_install_cron`
  59 -> 29 lines; `do_spl_unanswered_sweep_install_cron` 69 -> 39 lines;
  `do_spl_workspace_delivery_probe_install_cron` 63 -> 36 lines. None of
  the 5 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:src/bash/run/setup-box-stats-cron.func.sh`: update `_spl_simple_cron_apply`
  (`:64-105`) to accept optional 11th arg `noun="${11- cron}"`, define
  `local subj="${label}${noun}"`, and substitute `$label cron` with `$subj` on the four
  log lines. 105 -> 107 lines (`+9 -7`).
- `orc:src/bash/run/spl-spawn-remote-install-cron.func.sh`: drop unused `current` from
  `local` at `:43`; replace `:58-92` (keeping closing `}` at `:93`) with lazy-source +
  `_spl_simple_cron_apply` passing `"spawn receiver"`, `"runs every minute as the box user"`,
  `": spawn requests to this box wait for ever"`, `""`. 93 -> 63 lines (`+6 -36`).
- `orc:src/bash/run/spl-unanswered-sweep-install-cron.func.sh`: drop unused `current`
  from `local` at `:52`; replace `:71-105` (keeping closing `}` at `:106`) with
  lazy-source + `_spl_simple_cron_apply` passing `"unanswered sweep"`,
  `"runs every ${every}m as the box user"`, `": a missed human post is never looked at again"`,
  `""`. 106 -> 76 lines (`+6 -36`).
- `orc:src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh`: drop unused
  `current` from `local` at `:48`; replace `:64-94` (keeping closing `}` at `:95`) with
  lazy-source + `_spl_simple_cron_apply` passing `"delivery probe"`,
  `"runs every ${every}m as the box user"`, `""`, `""`. 95 -> 68 lines (`+5 -32`).
- `orc:src/bash/tests/box-stats-cron.tst.sh`: append section 5 before `:273` (`echo` /
  `if [ "$fails" -eq 0 ]`): 1 direct empty-noun `_spl_simple_cron_apply` check (verifying
  check-missing, install, check-ok, remove omit `" cron"`), 3 one-copy checks (all three
  wave-3 installers), 3 hermetic (`env -u`) standalone lazy-load `check`-missing checks,
  and 3 hermetic standalone `DRY_RUN=0` install `ok_msg` checks against an isolated stub
  crontab `$T/crontab.s5`. 275 -> 367 lines (`+92 -0`). Total edited files: **5** (within
  rulebook 3.1's max 5; all other wave-1, wave-2, and wave-3 test files run unmodified in
  the test column).
- head2's files, sha256 (12 chars): `setup-box-stats-cron.func.sh` `a8f432f1ec34`,
  `spl-spawn-remote-install-cron.func.sh` `ade87c1e55a7`,
  `spl-unanswered-sweep-install-cron.func.sh` `58b1daf259b0`,
  `spl-workspace-delivery-probe-install-cron.func.sh` `a87a26a30b2e`,
  `box-stats-cron.tst.sh` `1b6142ee1ab6`.
- Note for the row and its reviewer: build `gc2a`, `gc2b`, `gc2c`, and `m2a`-`m2c` in
  detached git worktrees, not single-file temp copies, because the lazy-source guard loads
  its sibling via `dirname "${BASH_SOURCE[0]}"`.

Verbatim helper, caller, and test hunks (head2 on `ffba81845`):

`orc:src/bash/run/setup-box-stats-cron.func.sh` (`:64-105` replacement):
```bash
# _spl_simple_cron_apply <act> <tag> <src> <trunk> <script> <logdir> <line>
#   <label> <ok_msg> [miss_why] [noun] -> run check, dry-run, remove, or
#   install for a single-line tagged crontab action. noun defaults to " cron"
#   when unset; pass "" when <label> already names the job without "cron".
_spl_simple_cron_apply() {
  local act="$1" tag="$2" src="$3" trunk="$4" script="$5" logdir="$6" line="$7"
  local label="$8" ok_msg="$9" miss_why="${10:-}" noun="${11- cron}" current
  local subj="${label}${noun}"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    if [[ -z "$current" ]]; then
      do_log "FAIL the $subj is NOT installed (no line tagged $tag)$miss_why"
      return 1
    fi
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the $subj is installed and its script is executable"
    return 0
  fi

  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    [[ "$act" == install ]] && spl_desk_cron_checkout_dry "$src" "$trunk"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the $subj is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$script" ]] || { do_log "FATAL $script is missing or not executable in $src (is it on trunk yet?)"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  current="$(spl_desk_cron_line "$tag")"
  [[ "$current" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK the $subj $ok_msg:"
  spl_desk_cron_say "$line"
}
```

`orc:src/bash/run/spl-spawn-remote-install-cron.func.sh` (replaces `:58-92`, keeping
closing `}` at `:93`; also remove `current` from `local` at `:43`):
```bash
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "spawn receiver" "runs every minute as the box user" \
    ": spawn requests to this box wait for ever" ""
```

`orc:src/bash/run/spl-unanswered-sweep-install-cron.func.sh` (replaces `:71-105`, keeping
closing `}` at `:106`; also remove `current` from `local` at `:52`):
```bash
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "unanswered sweep" "runs every ${every}m as the box user" \
    ": a missed human post is never looked at again" ""
```

`orc:src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh` (replaces `:64-94`,
keeping closing `}` at `:95`; also remove `current` from `local` at `:48`):
```bash
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "delivery probe" "runs every ${every}m as the box user" "" ""
```

`orc:src/bash/tests/box-stats-cron.tst.sh` section 5 (inserted immediately before `echo` /
`if [ "$fails" -eq 0 ]` at `:273`, followed by one blank line):
```bash
# 5. _spl_simple_cron_apply empty noun and wave-3 delegation (r04-02 one copy) --
out="$(env PROJ_ROOT="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" T="$T" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }
  source "$PROJ_ROOT/src/bash/run/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply check "csi-spl:widget" "$T" master "$T/demo.sh" "$T/wlog" "* * * * * $T/demo.sh # csi-spl:widget" "widget" "runs every 1m" ": no widget" ""
  echo "rc1=$?"
  _spl_simple_cron_apply install "csi-spl:widget" "$T" master "$T/demo.sh" "$T/wlog" "* * * * * $T/demo.sh # csi-spl:widget" "widget" "runs every 1m" ": no widget" ""
  echo "rc2=$?"
  _spl_simple_cron_apply check "csi-spl:widget" "$T" master "$T/demo.sh" "$T/wlog" "* * * * * $T/demo.sh # csi-spl:widget" "widget" "runs every 1m" ": no widget" ""
  echo "rc3=$?"
  _spl_simple_cron_apply remove "csi-spl:widget" "$T" master "$T/demo.sh" "$T/wlog" "* * * * * $T/demo.sh # csi-spl:widget" "widget" "runs every 1m" ": no widget" ""
  echo "rc4=$?"' 2>&1)"
[[ "$out" == *"FAIL the widget is NOT installed (no line tagged csi-spl:widget): no widget"* && "$out" == *"rc1=1"* \
  && "$out" == *"OK the widget runs every 1m:"* && "$out" == *"rc2=0"* \
  && "$out" == *"OK the widget is installed and its script is executable"* && "$out" == *"rc3=0"* \
  && "$out" == *"OK the widget is out of the crontab"* && "$out" == *"rc4=0"* \
  && "$out" != *"widget cron"* ]] &&
  cmp -s "$T/crontab" "$T/crontab.orig" &&
  pass "5. _spl_simple_cron_apply empty noun omits ' cron' across check, install and remove" || fail "5. empty noun: $out"

sr_f="$PROJ_ROOT/src/bash/run/spl-spawn-remote-install-cron.func.sh"
us_f="$PROJ_ROOT/src/bash/run/spl-unanswered-sweep-install-cron.func.sh"
dp_f="$PROJ_ROOT/src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh"
for sib in "$sr_f" "$us_f" "$dp_f"; do
  own="$(grep -nE "the crontab does not read back what was written|is installed and its script is executable|OK DRY_RUN nothing was touched" "$sib" || true)"
  [[ -z "$own" ]] && grep -q "_spl_simple_cron_apply " "$sib" &&
    pass "5. one copy: $(basename "$sib") delegates apply to _spl_simple_cron_apply" || fail "5. one copy $(basename "$sib"): own=[$own]"
done

mkdir -p "$SH/csi-spl-orc/src/bash/features/spawn-agents/scripts"
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh"
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/unanswered-sweep-cron.sh"
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/workspace-delivery-probe-cron.sh"
chmod +x "$SH/csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh" \
  "$SH/csi-spl-orc/src/bash/scripts/unanswered-sweep-cron.sh" \
  "$SH/csi-spl-orc/src/bash/scripts/workspace-delivery-probe-cron.sh"
printf '%s\n' '# keep me' >"$T/crontab.s5"

out="$(env -u CRON_REMOVE -u SPAWN_REMOTE_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" SPAWN_REMOTE_CRON_LOG_DIR="$T/log-sr" SPAWN_REMOTE_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-remote-install-cron.func.sh"
  do_spl_spawn_remote_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the spawn receiver is NOT installed (no line tagged csi-spl:spawn-remote): spawn requests to this box wait for ever"* && "$out" != *"command not found"* ]] &&
  pass "5. lazy load: spl-spawn-remote-install-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "5. lazy sr (rc=$rc): $out"

out="$(env -u CRON_REMOVE -u SPAWN_REMOTE_CRON_ACTION PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" SPAWN_REMOTE_CRON_LOG_DIR="$T/log-sr" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-spawn-remote-install-cron.func.sh"
  do_spl_spawn_remote_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the spawn receiver runs every minute as the box user:"* ]] &&
  pass "5. spawn receiver install keeps exact ok_msg" || fail "5. sr ok (rc=$rc): $out"

out="$(env -u ENV -u SWEEP_CRON_ACTION -u SWEEP_CRON_EVERY -u SWEEP_CRON_OFFSET -u SWEEP_CRON_MIN_AGE -u SWEEP_CRON_ESCALATE_AGE PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" SWEEP_CRON_LOG_DIR="$T/log-us" SWEEP_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep-install-cron.func.sh"
  do_spl_unanswered_sweep_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the unanswered sweep is NOT installed (no line tagged csi-spl:unanswered-sweep): a missed human post is never looked at again"* && "$out" != *"command not found"* ]] &&
  pass "5. lazy load: spl-unanswered-sweep-install-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "5. lazy us (rc=$rc): $out"

out="$(env -u ENV -u SWEEP_CRON_ACTION -u SWEEP_CRON_EVERY -u SWEEP_CRON_OFFSET -u SWEEP_CRON_MIN_AGE -u SWEEP_CRON_ESCALATE_AGE PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" SWEEP_CRON_LOG_DIR="$T/log-us" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep-install-cron.func.sh"
  do_spl_unanswered_sweep_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the unanswered sweep runs every 1m as the box user:"* ]] &&
  pass "5. unanswered sweep install keeps exact ok_msg" || fail "5. us ok (rc=$rc): $out"

out="$(env -u ENV -u PROBE_CRON_ACTION -u PROBE_CRON_EVERY -u PROBE_CRON_OFFSET -u PROBE_PRD_GO PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" PROBE_CRON_LOG_DIR="$T/log-dp" PROBE_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh"
  do_spl_workspace_delivery_probe_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the delivery probe is NOT installed (no line tagged csi-spl:delivery-probe-dev)"* && "$out" != *"command not found"* ]] &&
  pass "5. lazy load: spl-workspace-delivery-probe-install-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "5. lazy dp (rc=$rc): $out"

out="$(env -u ENV -u PROBE_CRON_ACTION -u PROBE_CRON_EVERY -u PROBE_CRON_OFFSET -u PROBE_PRD_GO PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" PROBE_CRON_LOG_DIR="$T/log-dp" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh"
  do_spl_workspace_delivery_probe_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the delivery probe runs every 10m as the box user:"* ]] &&
  pass "5. delivery probe install keeps exact ok_msg" || fail "5. dp ok (rc=$rc): $out"
```

**Behaviour:** all six wave-1 and wave-2 callers omit arg 11 and keep `noun=" cron"`,
emitting byte-identical output; all three wave-3 installers pass `""` as arg 11 and emit
their exact subject, install OK verb, and optional missing-line suffix across `check`,
`DRY_RUN=1`, `remove`, and `install`. All row-02, wave-1, wave-2, and shared suites pass
on base and head2 with identical counts plus the 10 new checks in `box-stats-cron.tst.sh`
(1.5).

### 1.5 Before and on the rows' heads

2026-11-26T00:55:30Z-01:08:12Z (and head1 re-run at 01:45:30Z-01:47:38Z after adding the
W1 `ISSUE_PLAN` mode check), n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal
to base: same rc, pass and fail counts; "-" means that row's head does not touch the
suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/spl-issue-blocker-rca-close.tst.sh` | 01 | 0 / 18 / 0 | 0 / 22 / 0 (+4 new checks) | - |
| `orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh` | 01 | 0 / 11 / 0 | 0 / 15 / 0 (+4 new checks) | - |
| `orc:src/bash/tests/box-stats-cron.tst.sh` | 02 | 0 / 44 / 0 | - | 0 / 54 / 0 (+10 new checks) |
| `orc:src/bash/tests/spawn-remote-cron.tst.sh` | 02 | 0 / 8 / 0 | - | = |
| `orc:src/bash/tests/unanswered-sweep.tst.sh` | 02 | 0 / 73 / 0 | - | = |
| `orc:src/bash/tests/workspace-delivery-probe.tst.sh` | 02 | 0 / 28 / 0 | - | = |
| `orc:src/bash/tests/check-disk-headroom.tst.sh` | 02 | 0 / 43 / 0 | - | = |
| `orc:src/bash/tests/prune-go-build-cache.tst.sh` | 02 | 0 / 58 / 0 | - | = |
| `orc:src/bash/tests/check-env-order.tst.sh` | 02 | 0 / 34\* / 0 | - | = |
| `orc:src/bash/tests/route-ci-overflow.tst.sh` | 02 | 0 / 38 / 0 | - | = |
| `orc:src/bash/tests/apply-gh-runner-cpu-budget.tst.sh` | 02 | 0 / 90 / 0 | - | = |
| `orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh` | 02 | 0 / 17 / 0 | - | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

Note (\*): `check-env-order.tst.sh` prints a trailing `PASS: all ...` line counted by
`grep -ciE '^ *(ok|pass)'`. On failing control runs (`m1a`, `rc2`), multi-line `$out`
dumps printed by `fail "..."` include `OK ...` log lines on their own lines, which
`grep -ciE '^ *(ok|pass)'` also counts (documented per control below). Run every suite
and control in a git worktree (not a plain `git archive` export): outside a git tree,
`no-literal-paths.tst.sh` reads `STALE` on base and heads alike (`0/15/0` in a git
worktree).

`shellcheck 0.10.0 -S warning -x` on all 9 edited files (head1: 4 files, head2: 5 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `ffba81845`,
reconstructed from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control a (`rc1a`, head1's `spl-issue-blocker-rca-close.tst.sh` on base):
  rc 1, 19 pass, 3 fail (`FAIL: r04-01 plan_path/run_plan` because `spl_issue_brc_plan_path`
  ignores the `issue-owner-question` subdir and `_spl_issue_brc_run_plan` is undefined,
  `FAIL: r04-01 query ok` because base `_spl_issue_brc_query` ignores `my_sql` and runs
  `spl_issue_brc_sql` with unbound `TENANT_ID`, `FAIL: r04-01 brc one copy`); head1:
  rc 0, 22 pass, 0 fail.
- Row 01 red control b (`rc1b`, head1's `spl-issue-owner-question-diss.tst.sh` on base):
  rc 1, 13 pass, 2 fail (`FAIL: r04-01 oq one copy: own=[38: plan="$(spl_issue_oq_plan_path)" ...]`
  and `FAIL: r04-01 existing plan mode (rc=0): 644`; the standalone dry-run and
  `_spl_issue_oq_query` checks pass on base, proving equivalence); head1: rc 0, 15 pass,
  0 fail.
- Row 01 guard control a (`gc1a`, head1 with `declare -F _spl_issue_brc_run_plan` deleted
  in `spl-issue-owner-question-diss.func.sh`): rc 1, 13 pass, 2 fail
  (`FAIL: r90-02 sourced alone` and `FAIL: r04-01 oq solo dry`, both rc=1
  `spl-issue-owner-question-diss.func.sh: line 39: spl_issue_brc_plan_path: command not found`).
- Row 01 guard control b (`gc1b`, head1 with `declare -F _spl_issue_brc_query` deleted in
  `spl-issue-owner-question-diss.func.sh`): rc 1, 14 pass, 1 fail
  (`FAIL: r04-01 oq solo query (rc=127): spl-issue-owner-question-diss.func.sh: line 73: _spl_issue_brc_query: command not found`).
- Row 02 red control (`rc2`, head2's `box-stats-cron.tst.sh` on base): rc 1, 53 total
  `grep -ciE '^ *(ok|pass)'` lines (50 real `PASS:` + 3 `OK` lines dumped inside
  `5. empty noun`'s failure output; panel matched the total 53),
  4 fail (`FAIL: 5. empty noun: FAIL the widget cron is NOT installed ...`,
  `FAIL: 5. one copy spl-spawn-remote-install-cron.func.sh: own=[70: ...]`,
  `FAIL: 5. one copy spl-unanswered-sweep-install-cron.func.sh: own=[83: ...]`,
  `FAIL: 5. one copy spl-workspace-delivery-probe-install-cron.func.sh: own=[73: ...]`;
  all 6 standalone lazy-load and install `ok_msg` checks pass on base, proving
  equivalence); head2: rc 0, 54 pass, 0 fail.
- Row 02 guard control a (`gc2a`, head2 with `declare -F _spl_simple_cron_apply` deleted
  in `spl-spawn-remote-install-cron.func.sh`): rc 1, 52 pass, 2 fail (`FAIL: 5. lazy sr`
  and `FAIL: 5. sr ok`, both rc=127
  `spl-spawn-remote-install-cron.func.sh: line 59: _spl_simple_cron_apply: command not found`).
- Row 02 guard control b (`gc2b`, head2 with `declare -F _spl_simple_cron_apply` deleted
  in `spl-unanswered-sweep-install-cron.func.sh`): rc 1, 52 pass, 2 fail
  (`FAIL: 5. lazy us` and `FAIL: 5. us ok`, both rc=127
  `spl-unanswered-sweep-install-cron.func.sh: line 72: _spl_simple_cron_apply: command not found`).
- Row 02 guard control c (`gc2c`, head2 with `declare -F _spl_simple_cron_apply` deleted
  in `spl-workspace-delivery-probe-install-cron.func.sh`): rc 1, 52 pass, 2 fail
  (`FAIL: 5. lazy dp` and `FAIL: 5. dp ok`, both rc=127
  `spl-workspace-delivery-probe-install-cron.func.sh: line 65: _spl_simple_cron_apply: command not found`).

**Mutation checks** (n=1 each, detached worktrees of `ffba81845` with head1/head2
applied, then one defect injected):
- `m1a` (`spl-issue-owner-question-diss.func.sh` drops `issue-owner-question` from
  `spl_issue_brc_plan_path`): `spl-issue-owner-question-diss.tst.sh` rc 1, 14 `ok|pass`
  lines (13 `PASS:` + 1 `OK DRY_RUN ...` dumped inside `oq solo dry`'s failure output), 2
  fail (`FAIL: r04-01 oq one copy` + `FAIL: r04-01 oq solo dry`).
- `m1b` (`_spl_issue_oq_query` drops `spl_issue_oq_sql` from `_spl_issue_brc_query`):
  `spl-issue-owner-question-diss.tst.sh` rc 1, 13 pass, 2 fail (`FAIL: r04-01 oq one copy`
  + `FAIL: r04-01 oq solo query`).
- `m2a` (`spl-spawn-remote-install-cron.func.sh` omits 11th arg `""`, falling back to
  `" cron"`): `box-stats-cron.tst.sh` rc 1, 52 pass, 2 fail (`FAIL: 5. lazy sr` +
  `FAIL: 5. sr ok`).
- `m2b` (`spl-unanswered-sweep-install-cron.func.sh` replaces arg 10 `miss_why` with
  `""`, keeping arg 11 `""`): `box-stats-cron.tst.sh` rc 1, 53 pass, 1 fail
  (`FAIL: 5. lazy us`).
- `m2c` (`spl-workspace-delivery-probe-install-cron.func.sh` omits 11th arg `""`, falling
  back to `" cron"`): `box-stats-cron.tst.sh` rc 1, 52 pass, 2 fail (`FAIL: 5. lazy dp` +
  `FAIL: 5. dp ok`).

The tests that name the sites (R2): `git grep -lE` over `*.tst.sh` and `features/*/tests/*`
for row 01 (`spl-issue-blocker-rca-close|spl-issue-owner-question-diss|do_spl_issue_blocker_rca_close|do_spl_issue_owner_question_diss|spl_issue_brc_|spl_issue_oq_`)
-> `spl-issue-blocker-rca-close.tst.sh` and `spl-issue-owner-question-diss.tst.sh` (0 hits
in `csi-spl-api/` or `csi-spl-iac/`). For row 02 (`setup-box-stats-cron|do_setup_box_stats_cron|_spl_simple_cron_apply|spl-spawn-remote-install-cron|do_spl_spawn_remote_install_cron|spl-unanswered-sweep-install-cron|do_spl_unanswered_sweep_install_cron|spl-workspace-delivery-probe-install-cron|do_spl_workspace_delivery_probe_install_cron`)
-> `box-stats-cron.tst.sh`, `spawn-remote-cron.tst.sh`, `unanswered-sweep.tst.sh`,
`workspace-delivery-probe.tst.sh`, `setup-gh-runner-cpu-budget-cron.tst.sh`, plus the
wave-1/wave-2 callers' suites (`check-disk-headroom.tst.sh`, `prune-go-build-cache.tst.sh`,
`check-env-order.tst.sh`, `route-ci-overflow.tst.sh`, `apply-gh-runner-cpu-budget.tst.sh`);
`dispatch-setup-check.tst.sh:456` (example CLI string only) and `spl-box-deploy.tst.sh:57`
(stub function definition only) do not source any of the edited `.func.sh` files and stay
out of the test column. 30-char non-header comment grep across all `*.tst.sh` and
`features/` tests -> **0 hits** (37 non-header comments >= 30 chars across the 6 `.func.sh`
files, 0 test hits). No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r04-01-orc-issue-diss-shared-helpers)` | one fact, one copy (developer guide 2.2.4) | `spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` already share `spl_issue_brc_one` (r90-02) but duplicate the 14-line plan-read/verdicts/dry-run-or-apply driver (`brc:41-54` vs `oq:39-52`), 7-line `*_plan_path` (`brc:71-77` vs `oq:73-79`), and 8-line `_*_query` (`brc:90-97` vs `oq:93-100`) (1.3, r03 section 7 #2) | `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh:35-55,69-77,88-97`<br>`orc:src/bash/run/spl-issue-owner-question-diss.func.sh:34-53,71-80,91-100`<br>`orc:src/bash/tests/spl-issue-blocker-rca-close.tst.sh:130`<br>`orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh:89` | copies of plan-run driver, plan-path creator, and read-only SQL query wrapper across the 2 actions 2 -> 1 each (hosted in `spl-issue-blocker-rca-close.func.sh`) | 1.3's shape (verbatim blocks in 1.3; `do_spl_cloud_cnf` ordering and `spl_issue_oq_apply`'s distinct re-read check and `r90-02` `spl_issue_brc_one` call untouched; sourcing `brc` in `do_spl_issue_owner_question_diss` also redefines `spl_issue_brc_one`, verified 0 stubs on `ffba81845`). **Red control:** head's `spl-issue-blocker-rca-close.tst.sh` on parent FAILs 3 checks (`rc1a`, rc 1, 19 pass, 3 fail) and head's `spl-issue-owner-question-diss.tst.sh` on parent FAILs 2 checks (`rc1b`, rc 1, 13 pass, 2 fail: one-copy naming `:38` + pre-existing 0644 `ISSUE_PLAN` staying `644`), then GREEN (`0/22/0` and `0/15/0`); guard controls (`gc1a` rc 1 13/2, `gc1b` rc 1 14/1, `declare -F` lines deleted in `oq`, built in worktrees); mutations `m1a`/`m1b` caught (rc 1 14\*/2, 13/2) (1.5); outputs in the body. **Behaviour:** one intentional tightening — `oq`'s plan file is now `0600` also when `ISSUE_PLAN` names a pre-existing file (base `644` -> head1 `600`, enforcing `oq:72`; `chmod` failure returns 1); all other behaviour unchanged, column passes on parent and head with identical counts plus 4 + 4 new checks. Tests: **`orc:.../spl-issue-blocker-rca-close.tst.sh`**, **`orc:.../spl-issue-owner-question-diss.tst.sh`**, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r04-02-orc-simple-cron-apply-wave3)` | one fact, one copy (developer guide 2.2.4) | `spl-spawn-remote-install-cron.func.sh:58-92`, `spl-unanswered-sweep-install-cron.func.sh:71-105`, and `spl-workspace-delivery-probe-install-cron.func.sh:64-94` duplicate the exact 31-35 line `check`/`DRY_RUN=1`/`remove`/`install` crontab state machine hosted in `_spl_simple_cron_apply` (`setup-box-stats-cron.func.sh:67-105`), differing only in omitting `" cron"` after the job subject (1.4, r03 section 7 #1) | `orc:src/bash/run/setup-box-stats-cron.func.sh:64-105`<br>`orc:src/bash/run/spl-spawn-remote-install-cron.func.sh:43,58-92`<br>`orc:src/bash/run/spl-unanswered-sweep-install-cron.func.sh:52,71-105`<br>`orc:src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh:48,64-94`<br>`orc:src/bash/tests/box-stats-cron.tst.sh:273` | copies of the single-line periodic cron check/dry-run/remove/install state machine in these 3 installers 3 -> 0 own copies (delegated to `_spl_simple_cron_apply` with optional 11th arg `noun="${11- cron}"`; 6 existing callers untouched) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head's `box-stats-cron.tst.sh` on parent FAILs 4 checks (`rc2`, rc 1, 53\* total `ok\|pass` lines = 50 `PASS:` + 3 `OK` in failure dump, 4 fail: empty-noun + 3 one-copy naming `:70`, `:83`, `:73`), then GREEN (`0/54/0`); guard controls (`gc2a`, `gc2b`, `gc2c`, `declare -F _spl_simple_cron_apply` deleted in each wave-3 installer: rc 1, `52/2` each with `_spl_simple_cron_apply: command not found`), built in worktrees; mutations `m2a`/`m2b` (arg 10 `""`)/`m2c` caught (rc 1 `52/2`, `53/1`, `52/2`) (1.5); outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 10 new checks in `box-stats-cron.tst.sh`. Tests: **`orc:.../box-stats-cron.tst.sh`**, `orc:.../spawn-remote-cron.tst.sh`, `orc:.../unanswered-sweep.tst.sh`, `orc:.../workspace-delivery-probe.tst.sh`, `orc:.../check-disk-headroom.tst.sh`, `orc:.../prune-go-build-cache.tst.sh`, `orc:.../check-env-order.tst.sh`, `orc:.../route-ci-overflow.tst.sh`, `orc:.../apply-gh-runner-cpu-budget.tst.sh`, `orc:.../setup-gh-runner-cpu-budget-cron.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r04-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r04-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 extracts/delegates duplicated bash scaffolding and adds one intentional
tightening (`oq`'s plan file is now `0600` also when `ISSUE_PLAN` names a pre-existing
file, enforcing the `0600` contract already documented at `oq:72`, and `chmod` failure
returns 1); no doc file changes -> `Docs: none (internal helper extraction; oq
pre-existing ISSUE_PLAN chmod 600 tightening already documented at oq:72)`. Row 02
delegates duplicated cron scaffolding with no change to any output, exit code, env var,
path, or file a caller sees (1.4, 1.5) -> `Docs: none (internal helper delegation; no
behaviour changes)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `spl-issue-blocker-rca-close.func.sh`, `spl-issue-owner-question-diss.func.sh`,
  `spl-issue-blocker-rca-close.tst.sh`, `spl-issue-owner-question-diss.tst.sh`; row 02:
  `csi-spl-orc` `setup-box-stats-cron.func.sh`, `spl-spawn-remote-install-cron.func.sh`,
  `spl-unanswered-sweep-install-cron.func.sh`,
  `spl-workspace-delivery-probe-install-cron.func.sh`, `box-stats-cron.tst.sh`).
- No row edits `orc:src/bash/run/check-disk-headroom-install-cron.func.sh`,
  `orc:src/bash/run/setup-go-cache-prune-cron.func.sh`,
  `orc:src/bash/run/check-env-order-install-cron.func.sh`,
  `orc:src/bash/run/setup-ci-overflow-cron.func.sh`,
  `orc:src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh`,
  `orc:src/bash/run/spl-orch-rotate-install-cron.func.sh`,
  `orc:src/bash/run/spl-dispatch-rotate-install-cron.func.sh`,
  `orc:src/bash/run/spl-agent-boot-restore-install-cron.func.sh`,
  `orc:lib/bash/funcs/spl-desk-cron-checkout.func.sh`,
  `orc:lib/bash/funcs/spl-desk-cron-lock.func.sh`,
  `orc:src/bash/run/spl-desk-install-service.func.sh`,
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-iac/`, `csi-spl-utl/`, or
  `csi-spl-wui/`.
- Note (N2): live lane `a-835` (`a-835-rotate`) has no remote branch on origin and
  records no files in the lane map; see 2.2 for R3 verification.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (9 edited + 3 wave-3 regression-run test files = 12 checked; the wave-1 and wave-2
regression tests are read-only):
`orc:src/bash/run/spl-issue-blocker-rca-close.func.sh`,
`orc:src/bash/run/spl-issue-owner-question-diss.func.sh`,
`orc:src/bash/tests/spl-issue-blocker-rca-close.tst.sh`,
`orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh`;
`orc:src/bash/run/setup-box-stats-cron.func.sh`,
`orc:src/bash/run/spl-spawn-remote-install-cron.func.sh`,
`orc:src/bash/run/spl-unanswered-sweep-install-cron.func.sh`,
`orc:src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh`,
`orc:src/bash/tests/box-stats-cron.tst.sh`,
`orc:src/bash/tests/spawn-remote-cron.tst.sh`,
`orc:src/bash/tests/unanswered-sweep.tst.sh`,
`orc:src/bash/tests/workspace-delivery-probe.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <all 12 paths + spl-orch-rotate-install-cron> --agent a-852`,
  n=1, at 2026-11-26T00:50:51Z: **exit 4** ("no live lane lists <the paths>, but 18 live
  lane(s) record no files"). Verified via `do_spl_lane_map` at 00:47:53Z — the 18
  `unknown:` lanes, all on the other box: 13 channel/workspace/other-repo seats (`c-029`,
  `c-041`, `c-086`, `c-146`, `c-187`, `c-398`, `c-407`, `c-416`, `c-474`, `c-535`, `c-728`,
  `c-927`, `c-936`), WUI notes Delete key (`c-741`), spec 125 doc/R7 seats (`c-957`,
  `c-965`), r03 panel seat (`c-726`, closing), and b48 panel seat (`c-776`). Live lanes on
  this box (`a-852`, `a-808` r03 closing, `a-846` b48 planner — checked its draft plan
  paths at 00:51Z: `spl-review-go.func.sh`, `spl-customer-box-role-check.func.sh`,
  `tf-plan-pending.func.sh`, 0 overlap — `a-835` (`a-835-rotate`, SPL-6542 WUI notes
  Delete key; has no remote branch on origin: `git ls-remote origin '*a-835*' | wc -l` ->
  0, and records no files in the lane map, so its paths could not be verified from origin;
  holder re-checks R3 at placement), `a-826` / `c-722` SPL-6517 latency action 7, `c-298`
  / `c-625` Reporting Taxes tab) and panel seat
  `c-804` touch none of the 12 paths. No live lane owns any of the 12 paths; the holder
  re-reads at placement per R3.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-26T00:47:57Z):
  1 queued, 0 placing:
  - `5b1b7d82` (`c001-s186-m9-n2-qto-sync`, feature): s186 M9 Qto sync; 0 overlap.
  None touches any of the 12 paths.
- **Unlanded rows from r03:** **0** (`r03-01` landed `3f1383643`, `r03-02` landed
  `0fcaa450b`, and round 03 closed at `ffba81845`).
- **Briefs on this box** modified in the last 24 h matching any of the 6 `.func.sh` paths
  (at 00:51Z): only the already-landed `r02-02` author/R7 briefs and `r03-02` brief (both
  rounds closed); **0 live briefs**.
- **Remote branches committed in the last 24 h** (`git for-each-ref`, at 00:51Z):
  `git diff --name-only $(git merge-base ffba81845 <b>) <b> -- <the 12 paths>` -> only
  `origin/review/r02-02` (already landed `8ff47fd73` and round 02 closed `118477b2a`,
  awaiting R8 prune); **0 unlanded branches**.
- **Commits in the last 24 h** on the 12 paths (`git log origin/master --since='24 hours ago'`,
  on `ffba81845` at 00:51Z) -> only `r02-02` (`8ff47fd73`, `setup-box-stats-cron` +
  `box-stats-cron.tst.sh`) and `r97-01` (`2924c633f`, `unanswered-sweep.tst.sh`); **0**
  unlanded changes.

## 3. Per row: what the lane does

- **r04-01:** `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` extracts
  `_spl_issue_brc_run_plan` (called by `do_spl_issue_blocker_rca_close`), adds optional
  `[SUBDIR]` (default `issue-blocker-rca`, passed explicitly by the caller for clean
  SC2120) to `spl_issue_brc_plan_path`, and adds optional `[SQL_FN]` (default
  `spl_issue_brc_sql`) to `_spl_issue_brc_query`.
  `orc:src/bash/run/spl-issue-owner-question-diss.func.sh` lazy-sources
  `spl-issue-blocker-rca-close.func.sh` in `do_spl_issue_owner_question_diss` (calling
  `spl_issue_brc_plan_path issue-owner-question` and `_spl_issue_brc_run_plan`) and in
  `_spl_issue_oq_query` (calling `_spl_issue_brc_query spl_issue_oq_sql`), drops
  `spl_issue_oq_plan_path`, and leaves `do_spl_cloud_cnf` ordering and `spl_issue_oq_apply`
  (including `r90-02`'s `spl_issue_brc_one` call) untouched. Routing `oq` through
  `spl_issue_brc_plan_path` intentionally tightens a pre-existing `ISSUE_PLAN` file to
  `0600` (enforcing `oq:72`, returning 1 if `chmod` fails), and sourcing `brc` in
  `do_spl_issue_owner_question_diss` also redefines `spl_issue_brc_one` (verified 0 stubs
  anywhere on `ffba81845`, so no separate stub/guard is needed).
  `orc:src/bash/tests/spl-issue-blocker-rca-close.tst.sh` appends 4 helper and one-copy
  checks; `orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh` appends 4 checks
  (one-copy, standalone lazy-load dry-run and query, and pre-existing `0644` `ISSUE_PLAN`
  tightened to `0600`).
- **r04-02:** `orc:src/bash/run/setup-box-stats-cron.func.sh` adds optional 11th arg
  `noun="${11- cron}"` (defaulting to `" cron"` when unset, so all 6 wave-1 and wave-2
  callers stay untouched) and `local subj="${label}${noun}"` to `_spl_simple_cron_apply`.
  `orc:src/bash/run/spl-spawn-remote-install-cron.func.sh` (drop `current` at `:43`,
  replace `:58-92`), `orc:src/bash/run/spl-unanswered-sweep-install-cron.func.sh` (drop
  `current` at `:52`, replace `:71-105`), and
  `orc:src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh` (drop `current` at
  `:48`, replace `:64-94`) each lazy-source `setup-box-stats-cron.func.sh` behind a
  `declare -F _spl_simple_cron_apply` guard inside their action function and delegate
  with `""` as arg 11. `orc:src/bash/tests/box-stats-cron.tst.sh` appends section 5
  (1 direct empty-noun check, 3 one-copy checks, 3 hermetic standalone lazy-load
  `check`-missing checks, and 3 hermetic standalone `DRY_RUN=0` install `ok_msg` checks).

## 4. Panel and reviewers (R7)

- Editor: **a-852** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; brief
  step 5; mistral sits on no review since 2026-11-25): claude panel seat **c-804**
  (live on the other box, queued with this planner). Returned FAIL on v0.1 (`4ded3bf46`,
  seat commit `16df4c069`) for W1 and W2; pending re-review of v0.2 on
  `review/c002-refactor-round-04-planner`. The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-26T00:49:10Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `grok off in instance settings`, `qwen off in instance settings`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 00:49:10Z (`main=agy backup=claude`; mistral sits on no review), R7 review of a
    claude coding row goes to an **agy seat** per row (claude waiver backup only while agy
    is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 00:49:10Z picked an available box; the
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
| r04-01 | `c002-r04-01-orc-issue-diss-shared-helpers` | `refactor(r04-01-orc-issue-diss-shared-helpers, SPL-<row issue>): ...` | `review/r04-01` | 1 |
| r04-02 | `c002-r04-02-orc-simple-cron-apply-wave3` | `refactor(r04-02-orc-simple-cron-apply-wave3, SPL-<row issue>): ...` | `review/r04-02` | 1 |

**r04-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-issue-blocker-rca-close.func.sh` (extract
`_spl_issue_brc_run_plan`, add optional `[SUBDIR]` to `spl_issue_brc_plan_path` passing
`issue-blocker-rca` from `do_spl_issue_blocker_rca_close`, add optional `[SQL_FN]` to
`_spl_issue_brc_query`),
`csi-spl-orc/src/bash/run/spl-issue-owner-question-diss.func.sh` (lazy-source
`spl-issue-blocker-rca-close.func.sh` in `do_spl_issue_owner_question_diss` and
`_spl_issue_oq_query`, drop `spl_issue_oq_plan_path`, delegate plan-path, plan-run, and
query; leave `do_spl_cloud_cnf` ordering and `spl_issue_oq_apply` untouched),
`csi-spl-orc/src/bash/tests/spl-issue-blocker-rca-close.tst.sh` (append 4 helper and
one-copy checks before `:130`), and
`csi-spl-orc/src/bash/tests/spl-issue-owner-question-diss.tst.sh` (append 4 checks before
`:89`: one-copy, standalone lazy-load dry-run and query, and pre-existing `0644`
`ISSUE_PLAN` tightened to `0600`). NOT `.shellcheck-warning-baseline.txt`, or any other
file. Do: plan section 2 row 01 verbatim, 1.3's shape (verbatim blocks in 1.3; note that
`oq` pre-existing `ISSUE_PLAN` is now tightened to `0600` per `oq:72`, and sourcing `brc`
in `do_spl_issue_owner_question_diss` also redefines `spl_issue_brc_one`, verified 0 stubs
on `ffba81845`); red controls (`rc1a` + `rc1b`, head's tests on parent, with `rc1b`
catching both one-copy and existing `0644` plan mode) RED then GREEN in the body; guard
controls (`gc1a` + `gc1b`, `declare -F` lines deleted in `oq`, built in worktrees);
mutations `m1a`/`m1b` caught by section tests. Gates: the row's tests (section 2,
`SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (internal helper extraction;
oq pre-existing ISSUE_PLAN chmod 600 tightening already documented at oq:72)`. Kind
`simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota,
valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the
claude backup is used; never mistral; re-checked at placement).

**r04-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/setup-box-stats-cron.func.sh` (add optional 11th arg
`noun="${11- cron}"` and `local subj="${label}${noun}"` to `_spl_simple_cron_apply` at
`:64-105`),
`csi-spl-orc/src/bash/run/spl-spawn-remote-install-cron.func.sh` (drop `current` at `:43`,
lazy-source `setup-box-stats-cron.func.sh` and replace `:58-92` with
`_spl_simple_cron_apply` passing `""` as arg 11),
`csi-spl-orc/src/bash/run/spl-unanswered-sweep-install-cron.func.sh` (drop `current` at
`:52`, lazy-source `setup-box-stats-cron.func.sh` and replace `:71-105` with
`_spl_simple_cron_apply` passing `""` as arg 11),
`csi-spl-orc/src/bash/run/spl-workspace-delivery-probe-install-cron.func.sh` (drop
`current` at `:48`, lazy-source `setup-box-stats-cron.func.sh` and replace `:64-94` with
`_spl_simple_cron_apply` passing `""` as arg 11), and
`csi-spl-orc/src/bash/tests/box-stats-cron.tst.sh` (append section 5 before `:273`: 1
direct empty-noun check, 3 one-copy checks, 3 hermetic standalone lazy-load
`check`-missing checks, and 3 hermetic standalone `DRY_RUN=0` install `ok_msg` checks).
NOT `check-disk-headroom-install-cron.func.sh`, NOT `setup-go-cache-prune-cron.func.sh`,
NOT `check-env-order-install-cron.func.sh`, NOT `setup-ci-overflow-cron.func.sh`, NOT
`setup-gh-runner-cpu-budget-cron.func.sh`, NOT `spl-orch-rotate-install-cron.func.sh`,
NOT `spl-desk-install-service.func.sh`, NOT `.shellcheck-warning-baseline.txt`, or any
other file. Do: plan section 2 row 02 verbatim, 1.4's shape (verbatim blocks in 1.4); red
control (`rc2`, head's `box-stats-cron.tst.sh` on parent) RED then GREEN in the body;
guard controls (`gc2a`, `gc2b`, `gc2c`, `declare -F _spl_simple_cron_apply` deleted in
each wave-3 installer, built in worktrees); mutations `m2a`/`m2b`/`m2c` caught by section
5. Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude; R7 **agy seat** (claude waiver
backup only while agy is out of quota, valid only under ruling `dc84300a` — cite ruling
`dc84300a` in the row brief if the claude backup is used; never mistral; re-checked at
placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of plan-run driver, plan-path creator, and read-only SQL query wrapper across `spl-issue-blocker-rca-close` and `spl-issue-owner-question-diss` (1.3) | 2 each on `ffba81845` -> 1 each (hosted in `spl-issue-blocker-rca-close.func.sh`) after row 01 |
| copies of the periodic cron check/dry-run/remove/install block in row 02's 3 wave-3 installers (1.4) | 3 on `ffba81845` (`spl-spawn-remote`, `spl-unanswered-sweep`, `spl-workspace-delivery-probe`) -> 0 own copies (delegated to `_spl_simple_cron_apply`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spl-issue-blocker-rca-close.func.sh` +20 -10, `spl-issue-owner-question-diss.func.sh` +9 -34, `spl-issue-blocker-rca-close.tst.sh` +46 -0, `spl-issue-owner-question-diss.tst.sh` +35 -0; row 02: `setup-box-stats-cron.func.sh` +9 -7, `spl-spawn-remote-install-cron.func.sh` +6 -36, `spl-unanswered-sweep-install-cron.func.sh` +6 -36, `spl-workspace-delivery-probe-install-cron.func.sh` +5 -32, `box-stats-cron.tst.sh` +92 -0 |
| measured on | `ffba81845`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` `*_read` (`brc:81-86` vs `oq:83-89`) and `*_apply` (`brc:126-151` vs `oq:136-162`) scaffolding (r03 section 7 #2 remainder) | left out of r04-01 because `spl_issue_oq_read` calls `do_spl_cloud_cnf` inside `*_read` (whereas `brc` calls it in `do_spl_issue_blocker_rca_close` before `plan_path`, relied on by `oq` test stubs) and `spl_issue_oq_apply` carries distinct re-read / status-check semantics (`diff -u` of `brc:126-151` vs `oq:136-162` -> 15 differing lines); `r05`+ candidates once r04-01 lands | file reads and `diff -u` on `ffba81845` (`brc:81-86` vs `oq:83-89`; `brc:126-151` vs `oq:136-162`: 15 diff lines, n=1) |
| Remaining cron installers carrying `spl_desk_cron_checkout` + read-back: `orc:src/bash/run/spl-orch-rotate-install-cron.func.sh` (89 lines), `spl-dispatch-rotate-install-cron.func.sh` (134 lines, 2 lines rotate+heal), `spl-agent-boot-restore-install-cron.func.sh` (177 lines, retire/removed markers) | `spl-orch-rotate-install-cron` is a direct `_spl_simple_cron_apply` wave-4 candidate (with `noun=""`, once r04-02 lands; deferred here because row 02 already hits rulebook 3.1's 5-file cap and `orch-rotate.tst.sh` is 1,255 lines); `spl-dispatch-rotate` (2-line crontab) and `spl-agent-boot-restore` (retire/removed branches) need separate inspection | file reads on `ffba81845` (3 left after row 02) |
| `orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh:83-91` section 4 vacuous red control (`r03-02` author `c-784` note / `r03` section 8) | test-bug fix, not a refactor row (brief: "bug rows and test rows are not yours"); belongs in a bug round | file read on `ffba81845` (`:83-91` copies `$FUNC` into `$T/nofloor.func.sh`, breaking relative `dirname "${BASH_SOURCE[0]}"` sources) |
| `orc:src/bash/run/spl-msg-dedup.func.sh:46-65` and `spl-msg-wipe.func.sh:36-55` (20-line tenant/dry-run/confirm/pin/backup preflight) | unchanged since r03; `msg-dedup.tst.sh` and `msg-wipe.tst.sh` build `cmd/spool` and run against throwaway `postgres:16-alpine` containers (heavy PG R2 gate) | `git diff bfdbd57d5 ffba81845` (empty), r03 7 |
| `orc:src/bash/run/spl-box-restart-install-cron.func.sh` / `spl-peer-crons.func.sh` and `spl-{backfill,fallback,reply,reply-count,topic-reply}-probe.func.sh` | candidates for `r05`+ (the 5 probe actions touch 5+ files; `spl-box-restart` / `spl-peer-crons` differ in `SPL_DESK_CRON_CREATE` handling); unchanged since r03 | `git diff bfdbd57d5 ffba81845` (empty), r03 7 |
| `iac:src/bash/run/gcp-{get-alert-incident,list-alert-incidents}.func.sh` (paged Monitoring v3 `timeSeries` curl loop) | passes `-K "${cfg}/auth.curl"` (Bearer access token file, secret-class); kept out while non-secret `orc` duplicates remain | `git diff bfdbd57d5 ffba81845` (empty), r03 7 |
| `orc:src/bash/run/spl-channel-agent-{add,add-op,remove-op}.func.sh` and `spl-{accepted-close,desk-poll-ack,review-go}.func.sh` | each pulls PostgreSQL or 30+ tests into R2; `spl-review-go.func.sh` is also targeted by live b48 planner `a-846` | `git diff bfdbd57d5 ffba81845` (empty), b48 plan check, r03 7 |
| `orc:src/bash/run/spl-hub-box-band.func.sh`, `orc:src/bash/run/spl-wui-perf-report.func.sh`, `csi-spl-utl/**`, secret-class sites, `iac:sec-*.func.sh`, `orc:scripts/*-cron.sh`, Go/WUI duplicates, spec 011 deferred/owner-decision tasks, and candidates-file non-refactor / already-served items | unchanged on `ffba81845`; each stays out for its r03/r02/r01/r99..r91 section 7 reason | r03 7; 1.2 (a), (c), (d) |

## 8. Changes

- v0.1 (a-852): the rows and every read on `ffba81845`; both heads built in detached
  scratch worktrees; the 21-suite column of 1.5 run on base and each row's head;
  `shellcheck 0.10.0 -S warning -x` and `do_sec_shellcheck` rc 0; all 8 red and guard
  controls (`rc1a`, `rc1b`, `gc1a`, `gc1b`, `rc2`, `gc2a`, `gc2b`, `gc2c`) and all 5
  mutation checks (`m1a`, `m1b`, `m2a`, `m2b`, `m2c`) run on detached worktrees and
  verified RED; all helper, caller, and test hunks included verbatim in 1.3 and 1.4.
  Pushed to `review/c002-refactor-round-04-planner` (`4ded3bf46`).
- v0.2 (a-852): folded cross-vendor claude panel FAIL (`c-804`, seat commit `16df4c069`)
  and dispatch holder send-back:
  - **W1 (option a):** named `oq`'s pre-existing `ISSUE_PLAN` `chmod 600` tightening
    (base `644` -> head1 `600`, enforcing `oq:72`, `chmod` failure returns 1) in intro,
    1.3 (bullet 2, Shape, Behaviour), section 2 row 01, section 2 Docs, section 3, and
    section 5; added the red-then-green check to `spl-issue-owner-question-diss.tst.sh`
    (re-verified head1 in detached worktree at 01:47Z: sha256 `fcd6c8c7efbd`, 124 lines,
    `+35 -0`, `0/15/0`, `rc1b` `1/13/2` catching `644`, `gc1a` `1/13/2`, `gc1b` `1/14/1`,
    `m1a` `1/14*/2`, `m1b` `1/13/2`, 11/11 suites green, `shellcheck` + `do_sec_shellcheck`
    rc 0).
  - **W2:** added section 7 row (and 1.2 (a) note) accounting for `brc`/`oq` `*_read`
    (`brc:81-86` vs `oq:83-89`) and `*_apply` (`brc:126-151` vs `oq:136-162`, 15 diff
    lines) scaffolding as `r05`+ candidates.
  - **N1-N6:** noted holder-box locality and holder 01:4xZ confirmation for briefs (N1)
    and candidates file (N3); noted `a-835` has no origin branch (`ls-remote` -> 0) and
    records no files in 2.1 and 2.2 (N2); noted `spl_issue_brc_one` redefinition on
    `oq` lazy-load with 0 stubs on `ffba81845` (N4); clarified `m2b` replaces arg 10 with
    `""` keeping arg 11 `""` (N5) and `rc2` 53 total `ok|pass` lines = 50 `PASS:` + 3 `OK`
    (N6). Confirmed 0 drift on all 12 row/test paths from `ffba81845` to `origin/master`
    `7e7962df5`.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-852 (agy): v0.1 (`4ded3bf46`), v0.2.
- Panel reviewer seat: c-804 (claude):
  - v0.1 `4ded3bf46a50baf4ace5e7919ea9720857af5db7`: **FAIL** (W1, W2; seat commit `16df4c069`).
  - v0.2: pending re-review on `review/c002-refactor-round-04-planner`.
- Row R7 seats: section 4; agy seat per row (claude waiver backup only while agy is out
  of quota under ruling `dc84300a`; never mistral).
