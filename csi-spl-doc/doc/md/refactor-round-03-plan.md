# Refactoring round 03 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6540  
Topic: d727f661-a7db-4e47-a4b0-faa0ef0a30db  
Discussion: d727f661-a7db-4e47-a4b0-faa0ef0a30db (t1 #refactoring, "Refactor round 03", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3), so this round is
  **r03**, plan `refactor-round-03-plan.md` (free: only `refactor-round-3-plan.md` exists,
  so no date suffix), rows `r03-<NN>`, scope `docs(r03-plan, SPL-6540)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574). **Vendor claude
  for every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 02 ([refactor-round-02-plan.md](refactor-round-02-plan.md)
v1.0 `be509a40b`) is closed (`118477b2a`): both `r02-01` (`f36d8f70f`, SPL-6536) and
`r02-02` (`8ff47fd73`, SPL-6537) landed on `origin/master` with cross-vendor agy R7 PASS.
The perf floor (rulebook 4.4), measured on `bfdbd57d5` at 2026-11-25T22:26:49Z (14 days):
perf 36, refactor 109, 24.8%, 5 x 36 = 180 >= 145, floor-met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), continuing directly from
r01-02 (`3582fc44b`) and r02-02 (`8ff47fd73`): a duplicated guard or execution block that
lives in multiple `orc:src/bash/run/` actions delegates to one shared helper in a sibling
file, leaving every log line, exit code, env var, and path unchanged.
**Row 01:** the two `/v1/operator/fleet-load` settings actions in `orc:src/bash/run/` —
`spl-hub-agent-kinds.func.sh:27-40` (`do_spl_hub_agent_kinds`) and
`spl-hub-runner-cpu.func.sh:25-39` (`do_spl_hub_runner_cpu`; r02 plan section 7 #1) —
already share `_spl_hub_fleet_load_error` (r01-02) but still duplicate the exact 11-line
write-mode `ORDERED_BY` / `ORDERED_VIA` / `spl_dry_run` guard, `do_spl_cloud_cnf`,
`spl_hub_operator_url`, `DRY_RUN=1` preview log, and `DRY_RUN=0` `ORDERED_BY` check
(differing in 1 line only: the dry-run action phrase `"switch off the agent kinds [${kinds:-none}]"` vs `"set the runner CPU cap to $set"`). Extracting
`_spl_hub_fleet_load_prep` into `spl-hub-agent-kinds.func.sh` (right before
`_spl_hub_fleet_load_error`, zero top-level code, zero GCP/secret calls inside the helper)
lets `spl-hub-agent-kinds.func.sh` call it directly and lets `spl-hub-runner-cpu.func.sh`
lazy-source `spl-hub-agent-kinds.func.sh` behind a `declare -F _spl_hub_fleet_load_prep`
guard and delegate that entire 11-line sequence to one home.
**Row 02:** the next three single-line periodic cron installers in `orc:src/bash/run/` —
`check-env-order-install-cron.func.sh:52-81` (`do_check_env_order_install_cron`),
`setup-ci-overflow-cron.func.sh:50-80` (`do_setup_ci_overflow_cron`), and
`setup-gh-runner-cpu-budget-cron.func.sh:68-98` (`do_setup_gh_runner_cpu_budget_cron`) —
carry the exact same 30-31 line `check` / `DRY_RUN=1` / `remove` / `install` crontab state
machine that `r02-02` (`8ff47fd73`) extracted into `_spl_simple_cron_apply` in
`setup-box-stats-cron.func.sh` (differing only in the cron label, install OK verb, and
`check-env-order`'s optional missing-line suffix `: prd ahead of dev warns nobody`). All
three delegate directly to the existing `_spl_simple_cron_apply` (zero edits to
`setup-box-stats-cron.func.sh`) by lazy-sourcing `setup-box-stats-cron.func.sh` behind a
`declare -F _spl_simple_cron_apply` guard inside their action functions.
The rows share no file: both are batch 1.

**Status: v1.0 signed** (ready for row execution). Editor: **a-808** (agy). Signed by
cross-vendor panel seat **c-726** (claude, `PASS` on v1.0
`5ebecd6752c7debf085598eef8e33a382766e4a7`, msg `a215cc4e` / holder copy `ffb46a6b`, seat
file `e02ff9e17019f54c691e7662da69f5e6d3a4a340` on
`review/c002-refactor-round-03-claude-seat`; `do_spl_review_line_check` rc 0, `OK 1 of 1`,
msg `608b1354`; holder GO `2d65a1c5` / `a4034b8c`). W1 and N1-N6 from v0.1 PASS
(`7103bcac49235686302754839717971f5aadcbb0`, msg `4d08dd05` / `587381f7`, 8/8 head sha256s
verified, differential harness byte-identical across 40 row-01 cases and 180 row-02 cases)
folded with zero open W; no row, site, batch, test hunk, sha256, or vendor changed between
signed v1.0 `5ebecd675` and this landed sign-off commit.

**One sha:** every count is measured on **`bfdbd57d5`** (`bfdbd57d515fbac4ec5f0cfdf44384ef2f47d9cf`,
`origin/master` at 2026-11-25T22:25:55Z; zero drift on all 11 row/test files to
`origin/master` `83554762f` at 2026-11-25T23:16:15Z,
`git diff --name-only bfdbd57d5 origin/master -- <11 files>` -> empty), n=1 per command
unless stated. Reads are on
`bfdbd57d5` with `git show` / `git grep`. The tests of 1.5 ran in detached scratch
worktrees of `bfdbd57d5` (not committed, removed on exit): "base" unmodified, "head1" =
base with row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's
shape; each red control, guard control, and mutation check (1.5) ran in a detached
worktree of its own. All helper definitions, caller replacements, and test hunks are
reproduced verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2,
all 7 red/guard controls, and all 5 mutation checks byte-for-byte on `bfdbd57d5` and
verify every sha256. Queue, lane map, brief and branch reads are live state and carry
their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-25T22:26:12Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-25T23:34:49+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r02-plan'`:
  `118477b2a1a61038babeefc3567e7390163c5717`
  (`docs(r02-plan, SPL-6526): refactor round 02 closed: r02-01 f36d8f70f and r02-02 8ff47fd73 landed, agy R7 PASS each`),
  read once at the start as 5.3 says (moved from v1.0 `be509a40b` `2026-11-25T22:22:59+02:00`
  by round 02's close record `118477b2a`). Per rulebook 5.3, `W` stays fixed at this
  recorded date (`2026-11-25T23:34:49+02:00`); all later R4, R6, 2.7.5, and `PRUNE_SINCE`
  reads for r03 must use `W=2026-11-25T23:34:49+02:00`.
- `git log origin/master --since="$W" --oneline -E --grep='\(r03-' | wc -l` -> **0**.
- `git ls-remote origin 'refs/heads/review/r03-*' 'refs/heads/*-r03-*' 'refs/heads/*refactor-round-03*' 'refs/heads/wip/*r03*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r03-[0-9]{2}|refactor-round-03'` (on the
  planner/holder box only — neither brief sits in `dispatch/briefs` on the other box;
  panel N5) -> **2** briefs only: this planner's brief and the panel seat's brief
  (`c002-refactor-round-03-claude-panel-seat.md`); 0 `r03-NN` row briefs.
- `git ls-tree --name-only bfdbd57d5 csi-spl-doc/doc/md/ | grep -c refactor-round-03`
  -> **0** (only `refactor-round-3-plan.md` exists, so `refactor-round-03-plan.md` is free
  with no date suffix per rulebook 5.3).

### 1.2 The brief's inputs, re-measured

- **(a) r02 section 7:** re-read on `bfdbd57d5` (`git diff --name-only c567245fa bfdbd57d5`:
  63 files; among r02 section 7's items, only `spl-hub-agent-kinds.func.sh` and
  `spl-hub-runner-cpu.func.sh` changed via `r01-02` `3582fc44b`).
  - `orc:src/bash/run/spl-hub-{agent-kinds,runner-cpu}.func.sh` (`ORDERED_BY` /
    `ORDERED_VIA` / `spl_dry_run` write-mode guard + cnf/url/dry-run prep): clean 2-file
    duplicate with fast pure-bash tests -> measured here as **row 01** (1.3).
  - Additional single-line cron installers matching r02-02's newly landed
    `_spl_simple_cron_apply` (`setup-box-stats-cron.func.sh`, `8ff47fd73`): 9 remaining
    `*-cron*.func.sh` files carry the same `spl_desk_cron_checkout` + read-back pattern;
    the 3 cleanest byte-identical matches (`check-env-order-install-cron.func.sh`,
    `setup-ci-overflow-cron.func.sh`, `setup-gh-runner-cpu-budget-cron.func.sh`) have
    fast pure-bash tests and need zero changes to `_spl_simple_cron_apply` -> measured
    here as **row 02** (1.4); the other 6 cron installers stay in section 7 for `r04`+.
  - All other r02 section 7 candidates (`spl-msg-{dedup,wipe}`, `spl-box-restart-install-cron`
    / `spl-peer-crons`, 5 probe actions, secret-class `gcp-*alert*`, PG-coupled
    `spl-channel-agent-*` and `spl-{accepted-close,desk-poll-ack,review-go}`, etc.) are
    unchanged on `bfdbd57d5` and stay accounted for in section 7.
- **(b) R7 and panel notes:**
  - `r02-01` (`f36d8f70f`, SPL-6536, R7 `a-770`, agy, PASS on `d9199991a`): clean match to
    r02 plan 1.3 head1 verbatim, no refactor follow-up.
  - `r02-02` (`8ff47fd73`, SPL-6537, R7 `a-772`, agy, PASS on `98a132071`): clean match to
    r02 plan 1.4 head2 verbatim, no refactor follow-up; its `_spl_simple_cron_apply`
    helper directly enables row 02 here.
  - `r01-01` (`e108142e8`, R7 `a-697`) and `r01-02` (`3582fc44b`, R7 `a-705`): already
    accounted for in r02 1.2 (b). No refactor row.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 139 lines, read 22:25Z):
  - No `## for refactor round 03` block; unchanged since r02.
  - All earlier refactor-shaped items remain served or out of scope (bug, perf,
    other-repo, or gate-design items), accounted for in section 7.
- **(d) spec 011 tasks:**
  `git log c567245fa..bfdbd57d5 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r02's base; remaining open/partial tasks (T001-T008
  owner-deferred, T018-T021, T023, T025-T028, T031, T034) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `spl-hub-agent-kinds.func.sh` and `spl-hub-runner-cpu.func.sh` share `_spl_hub_fleet_load_prep`

`orc:` = `csi-spl-orc/`. On `bfdbd57d5`:

- `orc:src/bash/run/spl-hub-agent-kinds.func.sh:30-40` (in `do_spl_hub_agent_kinds`) and
  `orc:src/bash/run/spl-hub-runner-cpu.func.sh:29-39` (in `do_spl_hub_runner_cpu`) carry
  the exact same 11-line write-mode `ORDERED_BY` regex check, `ORDERED_VIA` 64-char check,
  `spl_dry_run` parse, `do_spl_cloud_cnf`, `spl_hub_operator_url`, `DRY_RUN=1` preview
  log, and `DRY_RUN=0` `ORDERED_BY` requirement, differing in 1 single line only (the
  dry-run action phrase `"switch off the agent kinds [${kinds:-none}]"` vs `"set the runner CPU cap to $set"`):
  `diff -u <(git show bfdbd57d5:csi-spl-orc/src/bash/run/spl-hub-agent-kinds.func.sh | sed -n '30,40p') <(git show bfdbd57d5:csi-spl-orc/src/bash/run/spl-hub-runner-cpu.func.sh | sed -n '29,39p')`
  -> 1 single differing line (n=1).
- `_spl_hub_fleet_load_prep` and `SPL_FL_DRY_DONE` have **0 collisions** anywhere in the
  repo (`git grep -nE '_spl_hub_fleet_load_prep|SPL_FL_DRY_DONE' origin/master` -> 0).
  Both `.func.sh` files contain only function definitions (zero top-level code) and
  already pair via `_spl_hub_fleet_load_error` in `spl-hub-agent-kinds.func.sh` (r01-02).
  Placing `_spl_hub_fleet_load_prep` in `spl-hub-agent-kinds.func.sh` (immediately before
  `# _spl_hub_fleet_load_error`, `:69`) and adding a
  `declare -F _spl_hub_fleet_load_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-hub-agent-kinds.func.sh"`
  guard inside `do_spl_hub_runner_cpu` keeps both actions lazy under `./run`
  (`run-lazy-loader.tst.sh` and `run-eager-files.tst.sh` unchanged) while keeping
  standalone sourcing of `spl-hub-runner-cpu.func.sh` working. The existing
  `declare -F _spl_hub_fleet_load_error` guard in `_spl_hub_runner_cpu_report` stays
  untouched so direct calls to `_spl_hub_runner_cpu_report` remain standalone-safe.
- `do_gcp_pin_account` and `do_gcp_require_live_account` stay in the two callers; the
  extracted helper touches no credential, token, GCP call, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `_spl_hub_fleet_load_prep` is 17
  lines; `do_spl_hub_agent_kinds` 29 -> 21 lines; `_spl_hub_agent_kinds_list` stays 11
  lines; `_spl_hub_fleet_load_error` stays 11 lines; `_spl_hub_agent_kinds_report` stays
  7 lines; `do_spl_hub_runner_cpu` 30 -> 24 lines; `_spl_hub_runner_cpu_report` stays 9
  lines. None of the 4 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-hub-agent-kinds.func.sh`: replace `:27-40` with
  `local set="${KINDS_OFF-__read__}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" kinds=""`,
  the 3-line `if [[ "$set" != __read__ ]]; then kinds="$(_spl_hub_agent_kinds_list "$set")" || return 1; fi`
  check, `_spl_hub_fleet_load_prep "$set" "$ordby" "$ordvia" "switch off the agent kinds [${kinds:-none}]" || return 1`,
  and `(( SPL_FL_DRY_DONE )) && return 0`; insert `_spl_hub_fleet_load_prep` (with its
  3-line header documenting process global `SPL_FL_DRY_DONE` and
  `# shellcheck disable=SC2034`) immediately before `# _spl_hub_fleet_load_error` (`:69`).
  92 -> 106 lines (`+25 -11`).
- `orc:src/bash/run/spl-hub-runner-cpu.func.sh`: replace `:25-39` with
  `local set="${RUNNER_CPU_PCT-__read__}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}"`,
  the 4-line `RUNNER_CPU_PCT` validation `if` block, `# shellcheck source=spl-hub-agent-kinds.func.sh`,
  `declare -F _spl_hub_fleet_load_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-hub-agent-kinds.func.sh"`,
  `_spl_hub_fleet_load_prep "$set" "$ordby" "$ordvia" "set the runner CPU cap to $set" || return 1`,
  and `(( SPL_FL_DRY_DONE )) && return 0`. 64 -> 58 lines (`+5 -11`).
- `orc:src/bash/tests/hub-agent-kinds.tst.sh`: append section 7 before `:105`
  (`[[ "$fails" -eq 0 ]]`): 6 direct `_spl_hub_fleet_load_prep` checks (read mode,
  dry-run exact message with `ordered_by` and `via`, bad `ORDERED_BY` before cloud cnf,
  `ORDERED_VIA` > 64 chars before cloud cnf, `DRY_RUN=0` missing `ORDERED_BY`, `DRY_RUN=0`
  valid `ORDERED_BY` returning `SPL_FL_DRY_DONE=0`) and 1 one-copy check. 106 -> 153 lines
  (`+47 -0`: 46-line hunk + 1 trailing blank line).
- `orc:src/bash/tests/hub-runner-cpu.tst.sh`: append section 7 before `:92`
  (`[[ "$fails" -eq 0 ]]`): 1 one-copy check and 1 standalone lazy-load check (sourcing
  only `spl-hub-runner-cpu.func.sh` with `RUNNER_CPU_PCT=80` dry run). 93 -> 106 lines
  (`+13 -0`: 12-line hunk + 1 trailing blank line).
- head1's files, sha256 (12 chars): `spl-hub-agent-kinds.func.sh` `d5669d819ac0`,
  `spl-hub-runner-cpu.func.sh` `1e90207feada`, `hub-agent-kinds.tst.sh` `caafd2cde3bc`,
  `hub-runner-cpu.tst.sh` `2f92257b18c7`.
- Note for the row and its reviewer: build `gc1` in a detached git worktree, not a
  single-file temp copy, because the guard loads its sibling via
  `dirname "${BASH_SOURCE[0]}"`. Keep `SPL_FL_DRY_DONE` unexported (panel N3). In
  `hub-agent-kinds.tst.sh` section 7's final one-copy check, the single-copy proof is
  carried by the three `-eq 1` FATAL-line counts alongside `grep -c "_spl_hub_fleet_load_prep " -ge 1`
  (panel N1; verbatim hunk kept byte-identical to signed v0.1).

Verbatim helper, caller, and test hunks (head1 on `bfdbd57d5`):

`orc:src/bash/run/spl-hub-agent-kinds.func.sh` caller replacement (`:27-40`):
```bash
  local set="${KINDS_OFF-__read__}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}" kinds=""
  if [[ "$set" != __read__ ]]; then
    kinds="$(_spl_hub_agent_kinds_list "$set")" || return 1
  fi
  _spl_hub_fleet_load_prep "$set" "$ordby" "$ordvia" "switch off the agent kinds [${kinds:-none}]" || return 1
  (( SPL_FL_DRY_DONE )) && return 0
```

`orc:src/bash/run/spl-hub-agent-kinds.func.sh` helper insertion (immediately before
`# _spl_hub_fleet_load_error <subject_verb> -> log the hub refusal for a` at `:69`,
followed by one blank line):
```bash
# _spl_hub_fleet_load_prep <set> <ordby> <ordvia> <dry_action> -> validate
# write-mode ORDERED_BY/ORDERED_VIA/DRY_RUN, load cloud cnf and operator URL,
# log dry-run (setting SPL_FL_DRY_DONE=1), or verify ORDERED_BY for DRY_RUN=0.
# shellcheck disable=SC2034 # SPL_FL_DRY_DONE is read by callers
_spl_hub_fleet_load_prep() {
  local set="$1" ordby="$2" ordvia="$3" dry_action="$4" dry=1
  SPL_FL_DRY_DONE=0
  if [[ "$set" != __read__ ]]; then
    [[ -z "$ordby" || "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be a HUM-* id, got: '$ordby'"; return 1; }
    [[ ${#ordvia} -le 64 ]] || { do_log "FATAL ORDERED_VIA is at most 64 chars"; return 1; }
    if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  fi
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  if [[ "$set" != __read__ ]] && (( dry )); then
    do_log "OK DRY_RUN would ask the hub $SPL_HUB_URL to $dry_action for the whole instance (ordered_by=${ordby:-<none, REQUIRED for DRY_RUN=0>}${ordvia:+ via $ordvia}), as the $SPL_PROJECT service account. Re-run with DRY_RUN=0."
    SPL_FL_DRY_DONE=1
    return 0
  fi
  [[ "$set" == __read__ || -n "$ordby" ]] || { do_log "FATAL ORDERED_BY (a HUM-* id: who ordered this) is required with DRY_RUN=0"; return 1; }
}
```

`orc:src/bash/run/spl-hub-runner-cpu.func.sh` caller replacement (`:25-39`):
```bash
  local set="${RUNNER_CPU_PCT-__read__}" ordby="${ORDERED_BY:-}" ordvia="${ORDERED_VIA:-}"
  if [[ "$set" != __read__ ]]; then
    [[ "$set" == default || ( "$set" =~ ^[1-9][0-9]*$ && "$set" -le 100 ) ]] \
      || { do_log "FATAL RUNNER_CPU_PCT must be 1..100 or 'default', got: '$set'"; return 1; }
  fi
  # shellcheck source=spl-hub-agent-kinds.func.sh
  declare -F _spl_hub_fleet_load_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep "$set" "$ordby" "$ordvia" "set the runner CPU cap to $set" || return 1
  (( SPL_FL_DRY_DONE )) && return 0
```

`orc:src/bash/tests/hub-agent-kinds.tst.sh` section 7 (inserted immediately before
`[[ "$fails" -eq 0 ]]` at `:105`, followed by one blank line):
```bash
# --- 7. _spl_hub_fleet_load_prep (r03-01 one copy) ------------------------------
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; do_spl_cloud_cnf(){ echo "CNF"; SPL_PROJECT=csi-spl-dev; }
  spl_hub_operator_url(){ echo "URL"; SPL_HUB_URL=https://hub.test; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep __read__ "" "" "change x" || exit 1
  printf "DONE=%s\n" "$SPL_FL_DRY_DONE"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"CNF"* && "$out" == *"URL"* && "$out" == *"DONE=0"* ]] \
  && pass "7. _spl_hub_fleet_load_prep read mode loads cnf/url and sets SPL_FL_DRY_DONE=0" || fail "7. prep read: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; spl_dry_run(){ return 0; }
  do_spl_cloud_cnf(){ SPL_PROJECT=csi-spl-dev; }; spl_hub_operator_url(){ SPL_HUB_URL=https://hub.test; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok HUM-10 c-496 "change x" || exit 1
  printf "DONE=%s\n" "$SPL_FL_DRY_DONE"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"OK DRY_RUN would ask the hub https://hub.test to change x for the whole instance (ordered_by=HUM-10 via c-496), as the csi-spl-dev service account. Re-run with DRY_RUN=0."* && "$out" == *"DONE=1"* ]] \
  && pass "7. _spl_hub_fleet_load_prep dry run logs exact message and sets SPL_FL_DRY_DONE=1" || fail "7. prep dry: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; do_spl_cloud_cnf(){ echo "CNF-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok bob "" "change x"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL ORDERED_BY must be a HUM-* id, got: 'bob'" && "$out" != *"CNF-CALLED"* ]] \
  && pass "7. _spl_hub_fleet_load_prep refuses bad ORDERED_BY before cloud cnf" || fail "7. prep bad by: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; do_spl_cloud_cnf(){ echo "CNF-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok HUM-10 "$(printf '\''a%.0s'\'' {1..65})" "change x"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL ORDERED_VIA is at most 64 chars" && "$out" != *"CNF-CALLED"* ]] \
  && pass "7. _spl_hub_fleet_load_prep refuses ORDERED_VIA over 64 chars before cloud cnf" || fail "7. prep long via: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; spl_dry_run(){ return 1; }
  do_spl_cloud_cnf(){ SPL_PROJECT=csi-spl-dev; }; spl_hub_operator_url(){ SPL_HUB_URL=https://hub.test; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok "" "" "change x"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL ORDERED_BY (a HUM-* id: who ordered this) is required with DRY_RUN=0" ]] \
  && pass "7. _spl_hub_fleet_load_prep requires ORDERED_BY on DRY_RUN=0" || fail "7. prep req by: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; spl_dry_run(){ return 1; }
  do_spl_cloud_cnf(){ SPL_PROJECT=csi-spl-dev; }; spl_hub_operator_url(){ SPL_HUB_URL=https://hub.test; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok HUM-10 "" "change x" || exit 1
  printf "DONE=%s\n" "$SPL_FL_DRY_DONE"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "DONE=0" ]] \
  && pass "7. _spl_hub_fleet_load_prep live write with ORDERED_BY returns 0 with SPL_FL_DRY_DONE=0" || fail "7. prep live: rc=$rc $out"
[[ "$(grep -c "FATAL ORDERED_BY must be a HUM-\* id" "$ak_f")" -eq 1 && "$(grep -c "FATAL ORDERED_VIA is at most 64 chars" "$ak_f")" -eq 1 && "$(grep -c "is required with DRY_RUN=0" "$ak_f")" -eq 1 && "$(grep -c "_spl_hub_fleet_load_prep " "$ak_f")" -ge 1 ]] \
  && pass "7. one copy: spl-hub-agent-kinds.func.sh defines and calls _spl_hub_fleet_load_prep once" || fail "7. kinds prep one copy"
```

`orc:src/bash/tests/hub-runner-cpu.tst.sh` section 7 (inserted immediately before
`[[ "$fails" -eq 0 ]]` at `:92`, followed by one blank line):
```bash
# --- 7. r03-01 _spl_hub_fleet_load_prep one copy and standalone lazy-source -----
own="$(grep -nE "FATAL ORDERED_BY must be a HUM-\* id|FATAL ORDERED_VIA is at most 64 chars|is required with DRY_RUN=0|OK DRY_RUN would ask the hub" "$rc_f" || true)"
[[ -z "$own" ]] && grep -q "_spl_hub_fleet_load_prep " "$rc_f" \
  && pass "7. one copy: spl-hub-runner-cpu.func.sh delegates write-mode prep to _spl_hub_fleet_load_prep" || fail "7. cpu prep one copy: own=[$own]"
out=$(env PROJ_PATH="$PROJ_ROOT" ENV=dev RUNNER_CPU_PCT=80 ORDERED_BY=HUM-10 ORDERED_VIA=c-543 bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ :; }; spl_dry_run(){ return 0; }
  do_spl_cloud_cnf(){ SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
  spl_hub_operator_url(){ SPL_HUB_URL=https://hub.invalid; }
  source "$PROJ_PATH/src/bash/run/spl-hub-runner-cpu.func.sh"
  do_spl_hub_runner_cpu' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "OK DRY_RUN would ask the hub https://hub.invalid to set the runner CPU cap to 80 for the whole instance (ordered_by=HUM-10 via c-543), as the csi-spl-dev service account. Re-run with DRY_RUN=0." && "$out" != *"command not found"* ]] \
  && pass "7. lazy load: spl-hub-runner-cpu.func.sh loads _spl_hub_fleet_load_prep standalone" || fail "7. lazy prep cpu: rc=$rc $out"
```

**Behaviour:** `_spl_hub_fleet_load_prep` executes the exact `ORDERED_BY`, `ORDERED_VIA`,
`spl_dry_run`, `do_spl_cloud_cnf`, `spl_hub_operator_url`, `DRY_RUN=1` log, and
`DRY_RUN=0` `ORDERED_BY` check removed from both actions, in the exact same order; its
only new state is the unexported process global `SPL_FL_DRY_DONE` documented in its header
(unread by other callers). All row-01 and shared suites pass on base and head1 with
identical counts plus the 7 + 2 new checks (1.5).

### 1.4 Row 02's site: `check-env-order-install-cron.func.sh`, `setup-ci-overflow-cron.func.sh`, and `setup-gh-runner-cpu-budget-cron.func.sh` delegate to `_spl_simple_cron_apply`

`orc:` = `csi-spl-orc/`. On `bfdbd57d5`:

- `orc:src/bash/run/check-env-order-install-cron.func.sh:52-81` (30 lines),
  `orc:src/bash/run/setup-ci-overflow-cron.func.sh:50-80` (31 lines), and
  `orc:src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh:68-98` (31 lines) carry the
  exact `current="$(spl_desk_cron_line "$tag")"` + `check` / `DRY_RUN=1` / `remove` /
  `install` crontab state machine that `r02-02` (`8ff47fd73`) already extracted into
  `_spl_simple_cron_apply` (`orc:src/bash/run/setup-box-stats-cron.func.sh:67-105`),
  differing only in the cron label, install OK verb, and `check-env-order`'s optional
  missing-line suffix (`": prd ahead of dev warns nobody"`):
  `diff -u` of `setup-ci-overflow-cron.func.sh:50-80` against
  `setup-gh-runner-cpu-budget-cron.func.sh:68-98` -> 4 single-line log hunks; against
  `check-env-order-install-cron.func.sh:52-81` -> the same 4 log hunks plus 1 line-wrap
  difference on `[[ -n "$ran" && -x "$ran" ]] ||` (n=1 each). Every branch, exit code,
  `spl_desk_cron_*` call, and error line matches `_spl_simple_cron_apply` byte-for-byte
  with **zero edits** to `setup-box-stats-cron.func.sh`.
- All three files already carry the same three top-level `declare -F ... || source` lines
  for `spl-desk-cron-lock`, `spl-desk-install-service`, and `spl-desk-cron-checkout`.
  Lazy-sourcing `setup-box-stats-cron.func.sh` inside each action function behind a
  `declare -F _spl_simple_cron_apply` guard adds zero top-level lines, avoids touching
  `setup-box-stats-cron.func.sh` or `lib/bash/funcs/spl-desk-cron-checkout.func.sh`,
  keeps `run-lazy-loader.tst.sh` and `run-eager-files.tst.sh` unchanged, and works when
  each installer is sourced standalone.
- None of the three installers handles any token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `do_check_env_order_install_cron`
  54 -> 29 lines; `do_setup_ci_overflow_cron` 53 -> 26 lines;
  `do_setup_gh_runner_cpu_budget_cron` 58 -> 31 lines. None of the 4 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:src/bash/run/check-env-order-install-cron.func.sh`: drop unused `current` from
  `local` at `:38`; replace `:52-81` (keeping closing `}` at `:82`) with
  `# shellcheck source=setup-box-stats-cron.func.sh`,
  `declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"`,
  and `_spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" "env order" "runs daily at $at as the box user" ": prd ahead of dev warns nobody"`.
  82 -> 57 lines (`+6 -31`).
- `orc:src/bash/run/setup-ci-overflow-cron.func.sh`: drop unused `current` from `local` at
  `:32`; replace `:50-80` (keeping closing `}` at `:81`) with
  `# shellcheck source=setup-box-stats-cron.func.sh`,
  `declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"`,
  and `_spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" "CI overflow" "ticks every 5 minutes as the box user"`.
  81 -> 54 lines (`+5 -32`).
- `orc:src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh`: drop unused `current` from
  `local` at `:45`; replace `:68-98` (keeping closing `}` at `:99`) with
  `# shellcheck source=setup-box-stats-cron.func.sh`,
  `declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"`,
  and `_spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" "runner CPU budget" "ticks every minute as the box user"`.
  99 -> 72 lines (`+5 -32`).
- `orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh`: append section 5 before
  `:93` (`echo` / `if [ "$fails" -eq 0 ]`): 3 one-copy checks (all three installers), 3
  standalone lazy-load `check`-missing checks (verifying exact label and `check-env-order`'s
  suffix without `command not found`), and 3 standalone `DRY_RUN=0` install checks
  (verifying exact `ok_msg` for all three installers against an isolated stub crontab
  `$T/crontab.s5`). 95 -> 150 lines (`+55 -0`: 54-line hunk + 1 trailing blank line).
  Total edited files: **4** (within rulebook 3.1's max 5; `check-env-order.tst.sh`,
  `route-ci-overflow.tst.sh`, `apply-gh-runner-cpu-budget.tst.sh`, and
  `box-stats-cron.tst.sh` run unmodified in the test column).
- head2's files, sha256 (12 chars): `check-env-order-install-cron.func.sh` `a0a3a3065509`,
  `setup-ci-overflow-cron.func.sh` `5b72fb89a439`,
  `setup-gh-runner-cpu-budget-cron.func.sh` `abe05471b1f7`,
  `setup-gh-runner-cpu-budget-cron.tst.sh` `2a074cdaf4b7`.
- Note for the row and its reviewer: build `gc2a`, `gc2b`, and `gc2c` in detached git
  worktrees, not single-file temp copies, because the guard loads its sibling via
  `dirname "${BASH_SOURCE[0]}"`. Section 5 does not `env -u` ambient `ENV_ORDER_CRON_AT`
  or `*_CRON_ACTION` (panel N2; run with those vars unset, as CI and `do_check_pre_push`
  do; verbatim hunk kept byte-identical to signed v0.1).

Verbatim caller and test hunks (head2 on `bfdbd57d5`):

`orc:src/bash/run/check-env-order-install-cron.func.sh` (replaces `:52-81`, keeping closing
`}` at `:82`; also remove `current` from `local` at `:38`):
```bash
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "env order" "runs daily at $at as the box user" \
    ": prd ahead of dev warns nobody"
```

`orc:src/bash/run/setup-ci-overflow-cron.func.sh` (replaces `:50-80`, keeping closing `}`
at `:81`; also remove `current` from `local` at `:32`):
```bash
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "CI overflow" "ticks every 5 minutes as the box user"
```

`orc:src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh` (replaces `:68-98`, keeping
closing `}` at `:99`; also remove `current` from `local` at `:45`):
```bash
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "runner CPU budget" "ticks every minute as the box user"
```

`orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh` section 5 (inserted
immediately before `echo` / `if [ "$fails" -eq 0 ]` at `:93`, followed by one blank line):
```bash
# 5. _spl_simple_cron_apply delegation (r03-02 one copy) -----------------------
eo_f="$PROJ_ROOT/src/bash/run/check-env-order-install-cron.func.sh"
co_f="$PROJ_ROOT/src/bash/run/setup-ci-overflow-cron.func.sh"
for sib in "$eo_f" "$co_f" "$FUNC"; do
  own="$(grep -nE "the crontab does not read back what was written|is installed and its script is executable|OK DRY_RUN nothing was touched" "$sib" || true)"
  [[ -z "$own" ]] && grep -q "_spl_simple_cron_apply " "$sib" &&
    pass "5. one copy: $(basename "$sib") delegates apply to _spl_simple_cron_apply" || fail "5. one copy $(basename "$sib"): own=[$own]"
done
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/check-env-order.sh"
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh"
chmod +x "$SH/csi-spl-orc/src/bash/scripts/check-env-order.sh" "$SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh"
printf '%s\n' '# keep me' >"$T/crontab.s5"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" ENV_ORDER_CRON_LOG_DIR="$T/log-eo" ENV_ORDER_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/check-env-order-install-cron.func.sh"
  do_check_env_order_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the env order cron is NOT installed (no line tagged csi-spl:env-order): prd ahead of dev warns nobody"* && "$out" != *"command not found"* ]] &&
  pass "5. lazy load: check-env-order-install-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "5. lazy eo (rc=$rc): $out"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" ENV_ORDER_CRON_LOG_DIR="$T/log-eo" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/check-env-order-install-cron.func.sh"
  do_check_env_order_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the env order cron runs daily at 05:23 as the box user:"* ]] &&
  pass "5. env order install keeps exact ok_msg" || fail "5. eo ok (rc=$rc): $out"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" CI_OVERFLOW_CRON_LOG_DIR="$T/log-co" CI_OVERFLOW_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/setup-ci-overflow-cron.func.sh"
  do_setup_ci_overflow_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the CI overflow cron is NOT installed (no line tagged csi-spl:ci-overflow)"* && "$out" != *"command not found"* ]] &&
  pass "5. lazy load: setup-ci-overflow-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "5. lazy co (rc=$rc): $out"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" CI_OVERFLOW_CRON_LOG_DIR="$T/log-co" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/setup-ci-overflow-cron.func.sh"
  do_setup_ci_overflow_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the CI overflow cron ticks every 5 minutes as the box user:"* ]] &&
  pass "5. CI overflow install keeps exact ok_msg" || fail "5. co ok (rc=$rc): $out"
out="$(env -u CPU_BUDGET_GATE_FLOOR_PCT -u CPU_BUDGET_CI_RESERVE_PCT -u CPU_BUDGET_CI_WEIGHT PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" CPU_BUDGET_CRON_LOG_DIR="$T/log-cb" CPU_BUDGET_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh"
  do_setup_gh_runner_cpu_budget_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the runner CPU budget cron is NOT installed (no line tagged csi-spl:gh-runner-cpu-budget)"* && "$out" != *"command not found"* ]] &&
  pass "5. lazy load: setup-gh-runner-cpu-budget-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "5. lazy cb (rc=$rc): $out"
out="$(env -u CPU_BUDGET_GATE_FLOOR_PCT -u CPU_BUDGET_CI_RESERVE_PCT -u CPU_BUDGET_CI_WEIGHT PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" CPU_BUDGET_CRON_LOG_DIR="$T/log-cb" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh"
  do_setup_gh_runner_cpu_budget_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the runner CPU budget cron ticks every minute as the box user:"* ]] &&
  pass "5. runner CPU budget install keeps exact ok_msg" || fail "5. cb ok (rc=$rc): $out"
```

**Behaviour:** all three installers call the existing `_spl_simple_cron_apply` helper with
their exact label, install OK verb, and optional missing-line suffix, emitting
byte-identical log lines and exit codes for every mode (`check`, `DRY_RUN=1`, `remove`,
`install`). All row-02 and shared suites pass on base and head2 with identical counts plus
the 9 new checks in `setup-gh-runner-cpu-budget-cron.tst.sh` (1.5).

### 1.5 Before and on the rows' heads

2026-11-25T22:32:00Z-22:43:54Z, n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal
to base: same rc, pass and fail counts; "-" means that row's head does not touch the
suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/hub-agent-kinds.tst.sh` | 01 | 0 / 24\* / 0 | 0 / 31\* / 0 (+7 new checks) | - |
| `orc:src/bash/tests/hub-runner-cpu.tst.sh` | 01 | 0 / 18\* / 0 | 0 / 20\* / 0 (+2 new checks) | - |
| `orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh` | 02 | 0 / 8 / 0 | - | 0 / 17 / 0 (+9 new checks) |
| `orc:src/bash/tests/check-env-order.tst.sh` | 02 | 0 / 34\* / 0 | - | = |
| `orc:src/bash/tests/route-ci-overflow.tst.sh` | 02 | 0 / 38 / 0 | - | = |
| `orc:src/bash/tests/apply-gh-runner-cpu-budget.tst.sh` | 02 | 0 / 90 / 0 | - | = |
| `orc:src/bash/tests/box-stats-cron.tst.sh` | 02 | 0 / 44 / 0 | - | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

Note (\*): `hub-agent-kinds.tst.sh`, `hub-runner-cpu.tst.sh`, and `check-env-order.tst.sh`
print a final `PASS: all ... assertions` line on rc 0 (counted by `grep -ciE '^ *(ok|pass)'`),
and on failure `hub-agent-kinds.tst.sh` and `hub-runner-cpu.tst.sh` print a final
`FAIL: k assertion(s) in ...` line instead (counted by `grep -ciE '^ *(not ok|fail)'`),
so on a failing run the `PASS: all` line drops and the `FAIL: k` summary adds 1 fail line.
Run every suite and control in a git worktree (not a plain `git archive` export): outside
a git tree, `no-literal-paths.tst.sh` reads `STALE` on base and heads alike (`0/15/0` in a
git worktree).

`shellcheck 0.10.0 -S warning -x` on all 8 edited files (head1: 4 files, head2: 4 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `bfdbd57d5`,
reconstructed from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control a (`rc1a`, head1's `hub-agent-kinds.tst.sh` on base): rc 1, 23 pass,
  8 fail lines (7 assertions: `7. prep read` / `prep dry` / `prep live` rc=1 and
  `prep bad by` / `prep long via` / `prep req by` rc=127 `_spl_hub_fleet_load_prep: command not found`,
  `7. kinds prep one copy`, plus `FAIL: 7 assertion(s)`); head1: rc 0, 31 pass, 0 fail.
- Row 01 red control b (`rc1b`, head1's `hub-runner-cpu.tst.sh` on base): rc 1, 18 pass,
  2 fail lines (1 assertion: `FAIL: 7. cpu prep one copy: own=[29: ... FATAL ORDERED_BY ...]`
  plus `FAIL: 1 assertion(s)`; the standalone dry-run check passes on base, proving
  equivalence); head1: rc 0, 20 pass, 0 fail.
- Row 01 guard control (`gc1`, head1 with the `declare -F _spl_hub_fleet_load_prep`
  lazy-source line deleted in `spl-hub-runner-cpu.func.sh`): rc 1, 17 pass, 3 fail lines
  (`FAIL: 6. lazy cpu` and `FAIL: 7. lazy prep cpu` both rc=1
  `.../spl-hub-runner-cpu.func.sh: line 31: _spl_hub_fleet_load_prep: command not found`,
  plus `FAIL: 2 assertion(s)`).
- Row 02 red control (`rc2`, head2's `setup-gh-runner-cpu-budget-cron.tst.sh` on base):
  rc 1, 14 pass, 3 fail (`FAIL: 5. one copy check-env-order-install-cron.func.sh: own=[60: ...]`,
  `FAIL: 5. one copy setup-ci-overflow-cron.func.sh: own=[59: ...]`,
  `FAIL: 5. one copy setup-gh-runner-cpu-budget-cron.func.sh: own=[77: ...]`; all 6
  standalone lazy-load and install `ok_msg` checks pass on base, proving equivalence);
  head2: rc 0, 17 pass, 0 fail.
- Row 02 guard control a (`gc2a`, head2 with `declare -F _spl_simple_cron_apply` deleted
  in `check-env-order-install-cron.func.sh`): rc 1, 15 pass, 2 fail (`FAIL: 5. lazy eo`
  and `FAIL: 5. eo ok`, both rc=127 `.../check-env-order-install-cron.func.sh: line 53: _spl_simple_cron_apply: command not found`).
- Row 02 guard control b (`gc2b`, head2 with `declare -F _spl_simple_cron_apply` deleted
  in `setup-ci-overflow-cron.func.sh`): rc 1, 15 pass, 2 fail (`FAIL: 5. lazy co` and
  `FAIL: 5. co ok`, both rc=127 `.../setup-ci-overflow-cron.func.sh: line 51: _spl_simple_cron_apply: command not found`).
- Row 02 guard control c (`gc2c`, head2 with `declare -F _spl_simple_cron_apply` deleted
  in `setup-gh-runner-cpu-budget-cron.func.sh`): rc 1, 9 pass, 8 fail (`dry default`,
  `derived log dir`, `install default`, `reinstall`, `check`, `floor 0`, `5. lazy cb`,
  `5. cb ok`, rc=127 `.../setup-gh-runner-cpu-budget-cron.func.sh: line 69: _spl_simple_cron_apply: command not found`).

**Mutation checks** (n=1 each, detached worktrees of `bfdbd57d5` with head1/head2
applied, then one defect injected):
- `m1a` (`spl-hub-agent-kinds.func.sh` passes `"set the runner CPU cap to ${kinds:-none}"`
  instead of `"switch off the agent kinds [${kinds:-none}]"`): `hub-agent-kinds.tst.sh`
  rc 1, 29 pass, 2 fail lines (`FAIL: 1. dry` + `FAIL: 1 assertion(s)`).
- `m1b` (`spl-hub-runner-cpu.func.sh` passes `"switch off the agent kinds [$set]"` instead
  of `"set the runner CPU cap to $set"`): `hub-runner-cpu.tst.sh` rc 1, 17 pass, 3 fail
  lines (`FAIL: 1. dry` + `FAIL: 7. lazy prep cpu` + `FAIL: 2 assertion(s)`).
- `m2a` (`check-env-order-install-cron.func.sh` drops `": prd ahead of dev warns nobody"`):
  `setup-gh-runner-cpu-budget-cron.tst.sh` rc 1, 16 pass, 1 fail (`FAIL: 5. lazy eo (rc=1)`).
- `m2b` (`setup-ci-overflow-cron.func.sh` passes `"box-stats"` instead of `"CI overflow"`):
  `setup-gh-runner-cpu-budget-cron.tst.sh` rc 1, 15 pass, 2 fail (`FAIL: 5. lazy co` +
  `FAIL: 5. co ok`).
- `m2c` (`setup-gh-runner-cpu-budget-cron.func.sh` passes `"box-stats"` instead of
  `"runner CPU budget"`): `setup-gh-runner-cpu-budget-cron.tst.sh` rc 1, 15 pass, 2 fail
  (`FAIL: 5. lazy cb` + `FAIL: 5. cb ok`).

The tests that name the sites (R2): `git grep -lE` over `*.tst.sh` and `features/*/tests/*`
for row 01 (`spl-hub-agent-kinds|spl-hub-runner-cpu|do_spl_hub_agent_kinds|do_spl_hub_runner_cpu|_spl_hub_agent_kinds_list|_spl_hub_agent_kinds_report|_spl_hub_runner_cpu_report|_spl_hub_fleet_load_error`)
-> `hub-agent-kinds.tst.sh`, `hub-runner-cpu.tst.sh`, and `spl-review-go.tst.sh` (fixture
markdown text only at `:1078,1096,1103,1109`, does not source the `.func.sh` files).
Across `csi-spl-api/`, `git grep -n 'do_spl_hub_agent_kinds\|do_spl_hub_runner_cpu' origin/master -- csi-spl-api/`
matches `internal/hub/fleet_load.go:28` and `internal/hub/fleet_load_test.go:238` in Go
comments only (`// member session: the path of csi-spl-orc do_spl_hub_agent_kinds. A token`;
panel W1); row 01 makes no Go change and leaves the hub PATCH body byte-identical, so
`fleet_load_test.go` stays out of row 01's shell test column. For
row 02 (`check-env-order-install-cron|setup-ci-overflow-cron|setup-gh-runner-cpu-budget-cron|do_check_env_order_install_cron|do_setup_ci_overflow_cron|do_setup_gh_runner_cpu_budget_cron|_spl_simple_cron_apply`)
-> `setup-gh-runner-cpu-budget-cron.tst.sh`, `check-env-order.tst.sh`,
`route-ci-overflow.tst.sh`, `apply-gh-runner-cpu-budget.tst.sh`, and
`box-stats-cron.tst.sh` (plus the 9 shared iac/orc gates). 30-char non-header comment grep
across all `*.tst.sh` and `features/` tests -> **0 hits** (10 non-header comments >= 30
chars across the 5 `.func.sh` files, 0 test hits). No new test file is added, so
`orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r03-01-orc-fleet-load-write-guard)` | one fact, one copy (developer guide 2.2.4) | `spl-hub-agent-kinds.func.sh:27-40` and `spl-hub-runner-cpu.func.sh:25-39` duplicate the exact 11-line write-mode `ORDERED_BY`/`ORDERED_VIA`/`spl_dry_run` guard, `do_spl_cloud_cnf`, `spl_hub_operator_url`, `DRY_RUN=1` preview log, and `DRY_RUN=0` `ORDERED_BY` check differing in 1 line only (1.3, r02 section 7 #1) | `orc:src/bash/run/spl-hub-agent-kinds.func.sh:27-40,69`<br>`orc:src/bash/run/spl-hub-runner-cpu.func.sh:25-39`<br>`orc:src/bash/tests/hub-agent-kinds.tst.sh:105`<br>`orc:src/bash/tests/hub-runner-cpu.tst.sh:92` | copies of the `/v1/operator/fleet-load` write-mode prep block 2 -> 1 (`_spl_hub_fleet_load_prep` in `spl-hub-agent-kinds.func.sh`) | 1.3's shape (verbatim blocks in 1.3; header documents process global `SPL_FL_DRY_DONE`; `do_gcp_pin_account` stays in callers). **Red control:** head's `hub-agent-kinds.tst.sh` on parent FAILs 7 checks (`rc1a`, rc 1, 23 pass, 8 fail lines incl. `FAIL: 7 assertion(s)`, `_spl_hub_fleet_load_prep: command not found` + one-copy) and head's `hub-runner-cpu.tst.sh` on parent FAILs one-copy naming `:29` (`rc1b`, rc 1, 18 pass, 2 fail lines), then GREEN (`0/31*/0` and `0/20*/0`); guard control (`gc1`, `declare -F _spl_hub_fleet_load_prep` deleted in `spl-hub-runner-cpu.func.sh`: rc 1, 17 pass, 3 fail lines with `_spl_hub_fleet_load_prep: command not found`), built in a worktree; dry-run action checks catch `m1a`/`m1b` (1.5); outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 7 + 2 new checks. Tests: **`orc:.../hub-agent-kinds.tst.sh`**, **`orc:.../hub-runner-cpu.tst.sh`**, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r03-02-orc-simple-cron-apply-wave2)` | one fact, one copy (developer guide 2.2.4) | `check-env-order-install-cron.func.sh:52-81`, `setup-ci-overflow-cron.func.sh:50-80`, and `setup-gh-runner-cpu-budget-cron.func.sh:68-98` duplicate the exact 30-31 line `check`/`DRY_RUN=1`/`remove`/`install` crontab state machine already hosted in `_spl_simple_cron_apply` (`setup-box-stats-cron.func.sh`, r02-02 `8ff47fd73`), differing only in label, install OK verb, and optional missing-line suffix (1.4) | `orc:src/bash/run/check-env-order-install-cron.func.sh:38,52-81`<br>`orc:src/bash/run/setup-ci-overflow-cron.func.sh:32,50-80`<br>`orc:src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh:45,68-98`<br>`orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh:93` | copies of the single-line periodic cron check/dry-run/remove/install state machine in these 3 installers 3 -> 0 own copies (delegated to existing `_spl_simple_cron_apply` in `setup-box-stats-cron.func.sh`, unmodified) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head's `setup-gh-runner-cpu-budget-cron.tst.sh` on parent FAILs 3 one-copy checks naming `:60`, `:59`, `:77` (`rc2`, rc 1, 14 pass, 3 fail), then GREEN (`0/17/0`); guard controls (`gc2a`, `gc2b`, `gc2c`, `declare -F _spl_simple_cron_apply` deleted in each installer: rc 1, `15/2`, `15/2`, `9/8` with `_spl_simple_cron_apply: command not found`), built in worktrees; label/suffix/ok_msg checks catch `m2a`/`m2b`/`m2c` (1.5); outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 9 new checks in `setup-gh-runner-cpu-budget-cron.tst.sh`. Tests: **`orc:.../setup-gh-runner-cpu-budget-cron.tst.sh`**, `orc:.../check-env-order.tst.sh`, `orc:.../route-ci-overflow.tst.sh`, `orc:.../apply-gh-runner-cpu-budget.tst.sh`, `orc:.../box-stats-cron.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r03-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r03-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row extracts or delegates a duplicated guard or crontab execution block to
a single shared helper; no output, exit code, env var, path or file a caller sees changes
(1.3, 1.4, 1.5). Each: `Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not
its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `spl-hub-agent-kinds.func.sh`, `spl-hub-runner-cpu.func.sh`, `hub-agent-kinds.tst.sh`,
  `hub-runner-cpu.tst.sh`; row 02: `csi-spl-orc` `check-env-order-install-cron.func.sh`,
  `setup-ci-overflow-cron.func.sh`, `setup-gh-runner-cpu-budget-cron.func.sh`,
  `setup-gh-runner-cpu-budget-cron.tst.sh`).
- No row edits `orc:src/bash/run/setup-box-stats-cron.func.sh`,
  `orc:src/bash/run/spl-hub-box-band.func.sh`,
  `orc:lib/bash/funcs/spl-desk-cron-checkout.func.sh`,
  `orc:lib/bash/funcs/spl-desk-cron-lock.func.sh`,
  `orc:src/bash/run/spl-desk-install-service.func.sh`,
  `orc:src/bash/tests/box-stats-cron.tst.sh`,
  `orc:src/bash/tests/check-env-order.tst.sh`,
  `orc:src/bash/tests/route-ci-overflow.tst.sh`,
  `orc:src/bash/tests/apply-gh-runner-cpu-budget.tst.sh`,
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-iac/`, `csi-spl-utl/`, or
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (8 edited + 3 regression-run test files = 11 checked; `box-stats-cron.tst.sh` is
read-only):
`orc:src/bash/run/spl-hub-agent-kinds.func.sh`,
`orc:src/bash/run/spl-hub-runner-cpu.func.sh`,
`orc:src/bash/tests/hub-agent-kinds.tst.sh`,
`orc:src/bash/tests/hub-runner-cpu.tst.sh`;
`orc:src/bash/run/check-env-order-install-cron.func.sh`,
`orc:src/bash/run/setup-ci-overflow-cron.func.sh`,
`orc:src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh`,
`orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh`,
`orc:src/bash/tests/check-env-order.tst.sh`,
`orc:src/bash/tests/route-ci-overflow.tst.sh`,
`orc:src/bash/tests/apply-gh-runner-cpu-budget.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <all 11 paths> --agent a-808`, n=1,
  at 2026-11-25T22:28:22Z: **exit 4** ("no live lane lists <the 11 paths>, but 19 live
  lane(s) record no files"). Verified via `do_spl_lane_map` at 22:26:17Z and 22:34:20Z —
  the 19 `unknown:` lanes, all on the other box: 13 channel/workspace/other-repo seats
  (`c-029`, `c-041`, `c-086`, `c-146`, `c-187`, `c-398`, `c-407`, `c-416`, `c-474`,
  `c-535`, `c-728`, `c-927`, `c-936`), latency action 3 (`c-569`), WUI e2e bfcache red
  (`c-645`), tax-analyst blog post follow-up (`c-737`), WUI Delete key for notes
  (`c-741`), and spec 125 doc/R7 seats (`c-957`, `c-965`). Live lanes on this box
  (`a-808`, `a-812` SPL-6541 blog review, `a-810` spec 196 v0.3, `a-806` spec 150 v1.9,
  `a-801`/`c-780` b47-03 pin-hold weekly quota, `c-718`/`a-767`/`a-823`/`c-722`/`a-789`
  latency actions 3/6/7 — `a-823` checked at 23:16:16Z: SPL-6516 latency action 6 commits
  2+3, 0 overlap, `c-298`/`c-625` Reporting Taxes tab) and panel seat `c-726` touch none
  of the 11 paths (panel also checked R3 at 23:08:44Z and found 0 owning lanes). No live
  lane owns any of the 11 paths; the holder re-reads at placement per R3.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-25T22:26:19Z):
  2 queued, 0 placing:
  - `5b1b7d82` (`c001-s186-m9-n2-qto-sync`, feature): s186 M9 Qto sync; 0 overlap.
  - `a17119df` (spec 196 v0.3, feature, placed as `a-810` by 22:30Z): spec 196 v0.3 doc
    only; 0 overlap.
  None touches any of the 11 paths.
- **Unlanded rows from r02:** **0** (`r02-01` landed `f36d8f70f`, `r02-02` landed
  `8ff47fd73`, and round 02 closed at `118477b2a`).
- **Briefs on this box** modified in the last 24 h matching any of the 5 `.func.sh` paths
  (at 22:29:53Z): only the already-landed `r01-02` author and R7 reviewer briefs (round 01
  closed `cd8cd4cec`); **0 live briefs**.
- **Remote branches committed in the last 24 h** (`git for-each-ref`, at 22:29:53Z):
  `git diff --name-only $(git merge-base bfdbd57d5 <b>) <b> -- <the 11 paths>` -> only
  `origin/review/r01-02` (already landed `3582fc44b` and round 01 closed `cd8cd4cec`,
  awaiting R8 prune); **0 unlanded branches**.
- **Commits in the last 24 h** on the 5 `.func.sh` paths (`git log origin/master --since='24 hours ago'`,
  on `bfdbd57d5` at 22:28:22Z) -> only `r01-02` (`3582fc44b`) on `spl-hub-agent-kinds.func.sh`
  and `spl-hub-runner-cpu.func.sh`; **0** on the 3 cron installers.

## 3. Per row: what the lane does

- **r03-01:** `orc:src/bash/run/spl-hub-agent-kinds.func.sh` inserts
  `_spl_hub_fleet_load_prep` (setting documented process global `SPL_FL_DRY_DONE`) before
  `# _spl_hub_fleet_load_error` (`:69`) and replaces `:27-40` with the `KINDS_OFF` check
  and a call to `_spl_hub_fleet_load_prep`; `orc:src/bash/run/spl-hub-runner-cpu.func.sh`
  lazy-sources sibling `spl-hub-agent-kinds.func.sh` behind a
  `declare -F _spl_hub_fleet_load_prep` guard and replaces `:25-39` with the
  `RUNNER_CPU_PCT` check and a call to `_spl_hub_fleet_load_prep` (keeping
  `_spl_hub_runner_cpu_report`'s `declare -F _spl_hub_fleet_load_error` guard untouched).
  `orc:src/bash/tests/hub-agent-kinds.tst.sh` appends section 7 (6 direct
  `_spl_hub_fleet_load_prep` checks and 1 one-copy check);
  `orc:src/bash/tests/hub-runner-cpu.tst.sh` appends section 7 (1 one-copy check and 1
  standalone lazy-load check).
- **r03-02:** `orc:src/bash/run/check-env-order-install-cron.func.sh` (drop `current` at
  `:38`, replace `:52-81`), `orc:src/bash/run/setup-ci-overflow-cron.func.sh` (drop
  `current` at `:32`, replace `:50-80`), and
  `orc:src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh` (drop `current` at `:45`,
  replace `:68-98`) each lazy-source sibling `setup-box-stats-cron.func.sh` behind a
  `declare -F _spl_simple_cron_apply` guard inside their action function and delegate the
  crontab check/dry-run/remove/install state machine to the existing
  `_spl_simple_cron_apply` (zero edits to `setup-box-stats-cron.func.sh`).
  `orc:src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh` appends section 5 (3
  one-copy checks, 3 standalone lazy-load `check`-missing checks, and 3 standalone
  `DRY_RUN=0` install `ok_msg` checks covering all three installers).

## 4. Panel and reviewers (R7)

- Editor: **a-808** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; brief
  step 5; mistral sits on no review since 2026-11-25): claude panel seat **c-726**,
  signed **PASS** on v1.0 `5ebecd6752c7debf085598eef8e33a382766e4a7` (msg `a215cc4e` /
  holder copy `ffb46a6b`, seat file `csi-spl-doc/doc/md/refactor-round-03/seat-claude.md`
  at `e02ff9e17019f54c691e7662da69f5e6d3a4a340` on
  `review/c002-refactor-round-03-claude-seat`; `do_spl_review_line_check` rc 0, `OK 1 of 1`,
  msg `608b1354`; holder GO `2d65a1c5` / `a4034b8c`; W1 and N1-N6 folded, zero open W).
  The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-25T22:26:44Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `kinds off grok,qwen`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 22:26:52Z (`main=agy backup=claude`; mistral sits on no review), R7 review of a
    claude coding row goes to an **agy seat** per row (claude waiver backup only while agy
    is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 22:26:50Z picked an available box; the
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
| r03-01 | `c002-r03-01-orc-fleet-load-write-guard` | `refactor(r03-01-orc-fleet-load-write-guard, SPL-<row issue>): ...` | `review/r03-01` | 1 |
| r03-02 | `c002-r03-02-orc-simple-cron-apply-wave2` | `refactor(r03-02-orc-simple-cron-apply-wave2, SPL-<row issue>): ...` | `review/r03-02` | 1 |

**r03-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-hub-agent-kinds.func.sh` (insert `_spl_hub_fleet_load_prep`
before `# _spl_hub_fleet_load_error` `:69`, documenting process global `SPL_FL_DRY_DONE`;
replace `:27-40` with the `KINDS_OFF` check and call to `_spl_hub_fleet_load_prep`),
`csi-spl-orc/src/bash/run/spl-hub-runner-cpu.func.sh` (lazy-source sibling
`spl-hub-agent-kinds.func.sh` behind a `declare -F _spl_hub_fleet_load_prep` guard and
replace `:25-39` with the `RUNNER_CPU_PCT` check and call to `_spl_hub_fleet_load_prep`),
`csi-spl-orc/src/bash/tests/hub-agent-kinds.tst.sh` (append section 7 before `:105`: 6
direct `_spl_hub_fleet_load_prep` checks and 1 one-copy check), and
`csi-spl-orc/src/bash/tests/hub-runner-cpu.tst.sh` (append section 7 before `:92`: 1
one-copy check and 1 standalone lazy-load check). NOT `spl-hub-box-band.func.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 01 verbatim,
1.3's shape (verbatim blocks in 1.3); red controls (`rc1a` + `rc1b`, head's tests on
parent) RED then GREEN in the body; guard control (`gc1`, `declare -F _spl_hub_fleet_load_prep`
deleted in `spl-hub-runner-cpu.func.sh`, built in a worktree, not a temp-dir copy);
mutations `m1a` / `m1b` caught by section 1 + section 7 dry-run checks. Gates: the row's
tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 4
files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude; R7 **agy seat** (claude waiver backup only while agy is
out of quota, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief
if the claude backup is used; never mistral; re-checked at placement).

**r03-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/check-env-order-install-cron.func.sh` (drop unused `current` at
`:38`, lazy-source sibling `setup-box-stats-cron.func.sh` behind a
`declare -F _spl_simple_cron_apply` guard inside `do_check_env_order_install_cron`, and
replace `:52-81` with a call to `_spl_simple_cron_apply`),
`csi-spl-orc/src/bash/run/setup-ci-overflow-cron.func.sh` (drop unused `current` at `:32`,
lazy-source sibling `setup-box-stats-cron.func.sh` behind a
`declare -F _spl_simple_cron_apply` guard inside `do_setup_ci_overflow_cron`, and replace
`:50-80` with a call to `_spl_simple_cron_apply`),
`csi-spl-orc/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh` (drop unused `current`
at `:45`, lazy-source sibling `setup-box-stats-cron.func.sh` behind a
`declare -F _spl_simple_cron_apply` guard inside `do_setup_gh_runner_cpu_budget_cron`, and
replace `:68-98` with a call to `_spl_simple_cron_apply`), and
`csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh` (append section 5
before `:93`: 3 one-copy checks, 3 standalone lazy-load `check`-missing checks, and 3
standalone `DRY_RUN=0` install `ok_msg` checks covering all three installers). NOT
`setup-box-stats-cron.func.sh`, NOT `box-stats-cron.tst.sh`, NOT `check-env-order.tst.sh`,
NOT `route-ci-overflow.tst.sh`, NOT `apply-gh-runner-cpu-budget.tst.sh`, NOT
`lib/bash/funcs/spl-desk-cron-checkout.func.sh`, NOT `spl-desk-install-service.func.sh`,
NOT `.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 02
verbatim, 1.4's shape (verbatim blocks in 1.4); red control (`rc2`, head's
`setup-gh-runner-cpu-budget-cron.tst.sh` on parent) RED then GREEN in the body; guard
controls (`gc2a`, `gc2b`, `gc2c`, `declare -F _spl_simple_cron_apply` deleted in each
installer, built in worktrees); mutations `m2a`/`m2b`/`m2c` caught by section 5. Gates:
the row's tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x`
on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude; R7 **agy seat** (claude waiver backup only while agy is
out of quota, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief
if the claude backup is used; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the `/v1/operator/fleet-load` write-mode prep block (1.3) | 2 on `bfdbd57d5` (`spl-hub-agent-kinds`, `spl-hub-runner-cpu`) -> 1 (`_spl_hub_fleet_load_prep`) after row 01 |
| copies of the periodic cron check/dry-run/remove/install block in row 02's 3 installers (1.4) | 3 on `bfdbd57d5` (`check-env-order-install-cron`, `setup-ci-overflow-cron`, `setup-gh-runner-cpu-budget-cron`) -> 0 own copies (delegated to existing `_spl_simple_cron_apply`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spl-hub-agent-kinds.func.sh` +25 -11, `spl-hub-runner-cpu.func.sh` +5 -11, `hub-agent-kinds.tst.sh` +47 -0 (46-line hunk + 1 trailing blank line), `hub-runner-cpu.tst.sh` +13 -0 (12-line hunk + 1 trailing blank line); row 02: `check-env-order-install-cron.func.sh` +6 -31, `setup-ci-overflow-cron.func.sh` +5 -32, `setup-gh-runner-cpu-budget-cron.func.sh` +5 -32, `setup-gh-runner-cpu-budget-cron.tst.sh` +55 -0 (54-line hunk + 1 trailing blank line) |
| measured on | `bfdbd57d5` (zero drift on all 11 row/test files to `83554762f`); n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| Remaining single-line cron installers carrying the `spl_desk_cron_checkout` + read-back pattern: `orc:src/bash/run/spl-orch-rotate-install-cron.func.sh` (89 lines), `spl-spawn-remote-install-cron.func.sh` (93), `spl-unanswered-sweep-install-cron.func.sh` (106), `spl-workspace-delivery-probe-install-cron.func.sh` (95), `spl-dispatch-rotate-install-cron.func.sh` (134), `spl-agent-boot-restore-install-cron.func.sh` (177) | strong candidates for `r04`+ (continuing `_spl_simple_cron_apply` wave 3; note `spl-dispatch-rotate` and `spl-agent-boot-restore` carry extra branches and need line-by-line diffing first); deferred because r03 already carries 2 full, verified rows (rulebook 5.1) | `git grep -l 'spl_desk_cron_checkout' origin/master -- csi-spl-orc/src/bash/run/` and read-back scan on `bfdbd57d5` (9 remaining before row 02 -> 6 left for `r04`+) |
| `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` (158 lines) and `spl-issue-owner-question-diss.func.sh` (162 lines) (duplicate `do_spl_*` driver, `*_plan_path`, `*_read`, `*_query`, and `*_apply` scaffolding; already share `spl_issue_brc_one` via lazy-source at `:140`) | strong candidate for `r04`: pure-bash unit tests (`spl-issue-blocker-rca-close.tst.sh`, `spl-issue-owner-question-diss.tst.sh`); deferred to `r04` because r03 already carries 2 full, verified rows (rulebook 5.1) | 6-line duplicate block scan + file read on `bfdbd57d5` (8 shared multi-line blocks) |
| `orc:src/bash/run/spl-msg-dedup.func.sh:46-65` and `spl-msg-wipe.func.sh:36-55` (20-line tenant/dry-run/confirm/pin/backup preflight) | unchanged since r02 (`git diff c567245fa bfdbd57d5` empty), but `msg-dedup.tst.sh` and `msg-wipe.tst.sh` build `cmd/spool` and run against throwaway `postgres:16-alpine` containers (heavy PG R2 gate) | `git diff c567245fa bfdbd57d5` (empty), r02 7 |
| `orc:src/bash/run/spl-box-restart-install-cron.func.sh` / `spl-peer-crons.func.sh` and `spl-{backfill,fallback,reply,reply-count,topic-reply}-probe.func.sh` | candidates for `r04`+ (the 5 probe actions touch 5+ files; `spl-box-restart` / `spl-peer-crons` differ in `SPL_DESK_CRON_CREATE` handling); unchanged since r02 | `git diff c567245fa bfdbd57d5` (empty), r02 7 |
| `iac:src/bash/run/gcp-{get-alert-incident,list-alert-incidents}.func.sh` (paged Monitoring v3 `timeSeries` curl loop) | passes `-K "${cfg}/auth.curl"` (Bearer access token file); kept out while non-secret `orc` duplicates remain; unchanged since r02 | `git diff c567245fa bfdbd57d5` (empty), r02 7 |
| `orc:src/bash/run/spl-channel-agent-{add,add-op,remove-op}.func.sh` and `spl-{accepted-close,desk-poll-ack,review-go}.func.sh` | each pulls PostgreSQL or 30+ tests into R2; unchanged since r02 | `git diff c567245fa bfdbd57d5` (empty), r02 7 |
| `orc:src/bash/run/spl-hub-box-band.func.sh`, `orc:src/bash/run/spl-wui-perf-report.func.sh`, `csi-spl-utl/**`, secret-class sites (`spl-lane-handover*`, `spl-release-note-bans-*`, `spl-secret-*`, `iac` GH repo parsers), `iac:sec-*.func.sh`, `orc:scripts/*-cron.sh`, Go/WUI duplicates, remaining r91..r02 non-framework groups, and candidates-file non-refactor / already-served items | unchanged on `bfdbd57d5`; each stays out for its r02/r01/r99..r91 section 7 reason | r02 7; 1.2 (a), (c) |

## 8. Changes

- v0.1 (a-808): the rows and every read on `bfdbd57d5`; both heads built in detached
  scratch worktrees; the 16-suite column of 1.5 run on base and each row's head;
  `shellcheck 0.10.0 -S warning -x` and `do_sec_shellcheck` rc 0; all 7 red and guard
  controls (`rc1a`, `rc1b`, `gc1`, `rc2`, `gc2a`, `gc2b`, `gc2c`) and all 5 mutation
  checks (`m1a`, `m1b`, `m2a`, `m2b`, `m2c`) run on detached worktrees and verified RED;
  all helper, caller, and test hunks included verbatim in 1.3 and 1.4. Pushed as
  `7103bcac4` on `review/c002-refactor-round-03-planner`.
- v1.0 (a-808): folded cross-vendor panel `c-726` (claude) PASS findings on v0.1
  `7103bcac49235686302754839717971f5aadcbb0` (msg `4d08dd05` / editor copy `587381f7`,
  seat file `cc9a93f2e74b99c0ee11dc010e56ee421b8d5375` on
  `review/c002-refactor-round-03-claude-seat`; 8/8 head sha256s verified, differential
  harness byte-identical over 40 row-01 cases and 180 row-02 cases; zero row, site, batch,
  test hunk, sha256, or vendor change):
  - **W1** (1.5): documented `csi-spl-api/src/go/spool-hub-api/internal/hub/fleet_load_test.go:238`
    (and `fleet_load.go:28`) comment-only mention of `do_spl_hub_agent_kinds` and why it
    stays out of row 01's shell test column (no Go change, PATCH body byte-identical).
  - **N1** (1.3): clarified that the single-copy proof in `hub-agent-kinds.tst.sh` section
    7 is carried by the three `-eq 1` FATAL-line checks alongside `grep -c "_spl_hub_fleet_load_prep " -ge 1`.
  - **N2** (1.4): noted section 5 runs without `env -u ENV_ORDER_CRON_AT` / `*_CRON_ACTION`.
  - **N3** (1.3): noted R7 should keep `SPL_FL_DRY_DONE` unexported.
  - **N4** (intro, 4, 9): unified panel seat status to v0.1 PASS on `7103bcac4` awaiting
    v1.0 signature.
  - **N5** (1.1): noted the 2-briefs check applies to the planner/holder box only.
  - **N6** (intro, 2.2, 6): refreshed drift check on `origin/master` `83554762f` (0 drift
    on all 11 row/test files) and verified live lane `a-823` (SPL-6516 latency action 6
    commits 2+3, 0 overlap).
  Pushed as `5ebecd675` on `review/c002-refactor-round-03-planner`.
- v1.0 signed (a-808): recorded final cross-vendor panel signature (`c-726` claude
  **PASS** on v1.0 `5ebecd6752c7debf085598eef8e33a382766e4a7`, msg `a215cc4e` / holder
  copy `ffb46a6b`, seat file `e02ff9e17019f54c691e7662da69f5e6d3a4a340` on
  `review/c002-refactor-round-03-claude-seat`; `do_spl_review_line_check` rc 0, `OK 1 of 1`,
  msg `608b1354`; holder GO `2d65a1c5` / `a4034b8c`; zero drift on all 11 row/test files
  to `83554762f`). No row, site, batch, test hunk, sha256, or vendor changed from signed
  v1.0 `5ebecd675`.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-808 (agy): v0.1, v1.0.
- Panel reviewer seat: c-726 (claude, seat `e02ff9e17019f54c691e7662da69f5e6d3a4a340` on
  `review/c002-refactor-round-03-claude-seat`): **PASS** on v1.0
  (`5ebecd6752c7debf085598eef8e33a382766e4a7`, msg `a215cc4e` / holder copy `ffb46a6b`;
  `do_spl_review_line_check` rc 0, `OK 1 of 1`, msg `608b1354`; holder GO `2d65a1c5` /
  `a4034b8c`; all 161 lines of `bash` fenced code blocks byte-identical to v0.1, 8/8 head
  sha256s, 16 suites, 7 red/guard controls, 5 mutations, `shellcheck`, and differential
  harness 40 + 180 cases verified; W1 and N1-N6 folded, zero open W).
- Row R7 seats: section 4 (agy primary; claude waiver backup only if agy is out of quota,
  citing ruling `dc84300a`; never mistral).
