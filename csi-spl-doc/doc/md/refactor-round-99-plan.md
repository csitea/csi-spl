# Refactoring round 99 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6469  
Topic: 06db64f5-ecc8-4efc-b145-ee12097c131f  
Discussion: 06db64f5-ecc8-4efc-b145-ee12097c131f (t1 #refactoring, "Refactor round 99", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r99**, plan `refactor-round-99-plan.md`, rows `r99-<NN>`.
  (Per rulebook 5.3, after r99 comes `r01`.)
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574). **Vendor claude
  for every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 98 ([refactor-round-98-plan.md](refactor-round-98-plan.md))
has landed row 01 (`5adcd5fdd`, SPL-6465) on `origin/master`; row 02 (SPL-6466,
`review/r98-02` `2e37534c6`) has its agy R7 PASS (`a-473`) and holder GO, not yet landed
at base `f2cb19298`. This planner writes no r98 close record, touches no r98 file, and
stays off r98-02's 5 `csi-spl-iac` cost files. The perf floor (rulebook 4.4), measured on
`f2cb19298` at 2026-11-25T08:23:18Z (14 days): perf 36, refactor 102, 26.1%,
5 x 36 = 180 >= 138, floor-met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91..r98: a
duplicated validation or setup block that lives in multiple `orc:src/bash/run/` actions
moves to a single shared helper, and each caller delegates to that one home.
**Row 01:** the two operator human-account write actions in `orc:src/bash/run/` —
`spl-human-link.func.sh:83-84` (`_spl_human_link_body`) and
`spl-human-email-add.func.sh:103-104` (`_spl_human_email_add_body`; r98 plan section 7) —
duplicate the exact 2-line order-actor check validating required `ORDERED_BY`
(`^HUM-[0-9]+$`) and strict 3-digit `AGENT_ID` (`^[acgmq]-[0-9]{3}$`). Extracting
`_spl_human_require_order <ordered_by> <agent>` into `spl-human-link.func.sh` (which has
zero top-level code or variable assignments, unlike `spl-human-email-add.func.sh:70`)
lets `spl-human-link.func.sh` call it directly and lets `spl-human-email-add.func.sh`
lazy-source `spl-human-link.func.sh` behind a `declare -F _spl_human_require_order` guard
and call `_spl_human_require_order "$ordby" "$agent" || return 1`.
**Row 02:** the three WUI browser timing actions in `orc:src/bash/run/` —
`spl-wui-perf-flow-events.func.sh:36-48` (`do_spl_wui_perf_flow_events`),
`spl-wui-perf-first-load.func.sh:38-50` (`do_spl_wui_perf_first_load`), and
`spl-wui-perf-first-load-net.func.sh:39-51` (`do_spl_wui_perf_first_load_net`) — already
share `spl_pf_validate` in `spl-wui-perf-flow-events.func.sh:69`, yet duplicate the exact
13-line WUI origin, member email, password-file, timing-script and Chrome binary setup
block. Extracting `spl_pf_env <tenant> <wui_override> <email_override> <script> [label]`
into `spl-wui-perf-flow-events.func.sh` (right below `spl_pf_validate`, setting process
globals `SPL_PF_WUI`, `SPL_PF_EMAIL`, `SPL_PF_PW_FILE`, `SPL_PF_PROOF_JS` and
`SPL_PF_CHROME`) lets `spl-wui-perf-flow-events.func.sh` call it directly and lets
`spl-wui-perf-first-load.func.sh` and `spl-wui-perf-first-load-net.func.sh` lazy-source
`spl-wui-perf-flow-events.func.sh` behind a `declare -F spl_pf_env` guard and replace the
13-line block with 2 lines.
The rows share no file: both are batch 1.

**Status: closed.** Both rows landed on `origin/master` with cross-vendor agy R7 PASS
(`r99-01` `05129cff9` SPL-6492, `r99-02` `83a6b0d7d` SPL-6493; section 8). Editor:
**a-482** (agy). Plan v1.0 (`f8b2d8f1d`) was signed by cross-vendor panel seat **c-396**
(claude, `PASS` on v0.2 `853b9368f3f58e9b6a175796121c94e4a0674dcd`, msgs
`a043ca44`/`7d3cf642`, seat file `a8450306bb192c5b5719209d458974657219b078` on
`review/c002-refactor-round-99-claude-seat`; `do_spl_review_line_check` rc 0 confirmed
`74782011`; holder GO `6615a1f0`/`92d045b2`). No row, site, batch, test hunk, or vendor
changed between signed v0.2 and v1.0.

**One sha:** every count is measured on **`f2cb19298`** (`f2cb192985464f4ef0023195235ca49196b8d531`,
`origin/master` at 2026-11-25T08:23:18Z; zero drift on all 10 row/test files to
`origin/master` `208e5f757` at 2026-11-25T09:17Z, `git diff --name-only f2cb19298 208e5f757 -- <10 files>` -> empty),
n=1 per command unless stated. Reads are on `f2cb19298` with `git show` / `git grep`. The
tests of 1.5 ran in detached scratch worktrees of `f2cb19298` (not committed, removed on
exit): "base" unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" =
base with row 02 applied in 1.4's shape; each red control, guard control, and mutation
check (1.5) ran in a detached worktree of its own. Both helper definitions and all four
test hunks are reproduced verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct
head1, head2, all 7 controls, and all 6 row-02 mutation checks byte-for-byte on
`f2cb19298` and verify every sha256. Queue, lane map, brief and branch reads are live
state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-25T08:18:11Z (re-checked on `f2cb19298` at 08:22:39Z), n=1, after a fresh fetch
(`git-fetch-fresh.sh`):

- **Window: W=2026-11-25T09:01:01+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r98-plan'`:
  `f0df3782b` (`docs(r98-plan, SPL-6457): refactor round 98 plan v1.0, signed by c-429 (claude) PASS on 52d5d4c17, N6-N7 folded`),
  read once at the start as 5.3 says. Per rulebook 5.3, `W` stays fixed at this recorded
  date (`2026-11-25T09:01:01+02:00`) even after r98's close record lands; all later R4,
  R6, 2.7.5, and `PRUNE_SINCE` reads for r99 must use `W=2026-11-25T09:01:01+02:00`.
- `git log origin/master --since="$W" --oneline -E --grep='\(r99-' | wc -l` -> **0**
  (re-verified on `208e5f757` at 09:17Z: windowed count **0**; all-history `--grep` returns
  1: `0e918d4b9`, `ci(r10-10-push-master-review-line, SPL-1907)`, whose body quotes
  `refactor(r99-01-x)` as test case 8 text; all-history subject grep
  `git log origin/master --format=%s | grep -cE '\(r99-'` -> **0**; N1).
- `git ls-remote origin 'refs/heads/review/r99-*' 'refs/heads/*-r99-*' 'refs/heads/*refactor-round-99*' 'refs/heads/wip/*r99*'`
  -> nothing (before this plan's review branch and the panel seat branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r99|refactor-round-99'` (on the planner's
  box) -> this plan's planner brief and the panel seat's brief
  (`c002-refactor-round-99-claude-panel-seat.md`), no other.
- `git ls-tree --name-only f2cb19298 csi-spl-doc/doc/md/ | grep -c refactor-round-99`
  -> **0**: the plain name is free.

### 1.2 The brief's inputs, re-measured

- **(a) r98 section 7:** re-read on `f2cb19298`.
  - `orc:src/bash/run/spl-human-email-add.func.sh:103-104` and
    `orc:src/bash/run/spl-human-link.func.sh:83-84`: the 2 operator human-account write
    actions duplicate the exact 2-line `ORDERED_BY` + strict 3-digit `AGENT_ID` check ->
    measured here as **row 01** (1.3).
  - `orc:src/bash/run/{spl-accepted-close,spl-desk-poll-ack,spl-review-go}.func.sh`
    (`_spl_*_holder`): `spl-review-go.func.sh` was actively edited by live lane `c-460`
    (`b46-03`, SPL-6464, landed `f2cb19298`), and moving the helper into
    `spl-dispatch-lease.func.sh` pulls 30+ tests (including slow `fleet-lease.tst.sh` and
    PG suites) into R2; stays out (section 7).
  - `git diff --name-only 7084439f1 f2cb19298` (15 commits, 21 files: r97 close
    `5855e3ca3`, b45 close `5c0ba2f40`, SPL-6460 `d5f1a228d`, b46 plan `8dcba2c4d`..`b1aea77d5`,
    r98 plan `b1a48dacf`..`f0df3782b`, SPL-6461 `8916db13f`, r98-01 `5adcd5fdd`, spec 195
    v0.3 `de1db7f52`, spec 187 plan `793976347`..`ea62874c6`, b46-03 `f2cb19298`): touches
    none of r91..r98 section 7's other remaining items, so each stays out for its reason
    there (section 7).
- **(b) R7 and panel notes:**
  - r98-01 R7 (`a-466`, agy, PASS on `7ebee3dd9`, landed `5adcd5fdd`): N1 noted the red
    controls ran on `f0df3782b` and reproduced on `8916db13f`. No refactor row.
  - r98-02 R7 (`a-473`, agy, PASS on `2e37534c6`, unlanded at base): N1 confirmed
    `do_spl_cost_gcp_window` is the sole window-prep copy. No refactor row.
  - r98 panel (`c-429`, claude, recorded in r98 plan v1.0 `f0df3782b`): PASS on
    `52d5d4c17`; W1, W2, and N1-N7 already folded into `f0df3782b`. No refactor row.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 140 lines, read 08:18Z):
  - No `## for refactor round 99` block; unchanged since r98 (140 lines).
  - All earlier refactor-shaped items remain served on `f2cb19298` (`r97-01` `2924c633f`,
    `SPL-6342` `c68cca820`/`69dc02d2f`, `SPL-6341` `76471cb9e`, `LOGIN_STATE_DIR`,
    `spl-desk-reply.sh`, `reverse-tunnel-cron.sh`, `agent-boot-restore`,
    `spl-lane-mix.func.sh`), and the remaining entries are bug, perf, other-repo, or
    gate-design items, not refactor rows (section 7).
- **(d) spec 011 tasks:**
  `git log f2cb19298 --since=2026-11-25T05:38:47Z --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r98's base; the remaining open/partial tasks (T001-T008
  owner-deferred, T018-T021, T023, T025-T028, T031, T034) are each wider than one row or
  await an owner decision.
- **(e) Fresh duplicate scan** on `f2cb19298` over tracked non-test `*.func.sh` under
  `csi-spl-orc/{src,lib}` and `csi-spl-iac/{src,lib}`:
  - Cross-file block scan surfaced the 13-line WUI origin + member email + `pw-human` +
    timing script + Chrome binary setup block duplicated across
    `orc:src/bash/run/spl-wui-perf-flow-events.func.sh:36-48`,
    `orc:src/bash/run/spl-wui-perf-first-load.func.sh:38-50`, and
    `orc:src/bash/run/spl-wui-perf-first-load-net.func.sh:39-51` -> measured here as
    **row 02** (1.4).
  - Other newly scanned candidates (`spl-channel-agent-{add,add-op,remove-op}.func.sh`,
    `gcp-{get-alert-incident,list-alert-incidents}.func.sh`,
    `spl-hub-{request-minutes,run-metrics}.func.sh`,
    `spl-hub-{agent-kinds,runner-cpu}.func.sh`, `spl-msg-move`/`spl-topic-move`,
    `spl-msg-dedup`/`spl-msg-wipe`, `spl-box-restart-install-cron`/`spl-peer-crons`,
    probe actions, `check-disk-headroom-install-cron`/`setup-box-stats-cron`/`setup-go-cache-prune-cron`)
    are recorded with measurements in section 7.

### 1.3 Row 01's site: `spl-human-link.func.sh` and `spl-human-email-add.func.sh` share `_spl_human_require_order`

`orc:` = `csi-spl-orc/`. On `f2cb19298`:

- `orc:src/bash/run/spl-human-link.func.sh:83-84` (in `_spl_human_link_body`) and
  `orc:src/bash/run/spl-human-email-add.func.sh:103-104` (in `_spl_human_email_add_body`)
  each contain the exact same 2 lines:
  ```bash
    [[ "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be the HUM-* id of the human who ordered it, got: '$ordby'"; return 1; }
    [[ "$agent" =~ ^[acgmq]-[0-9]{3}$ ]] || { do_log "FATAL AGENT_ID must be an agent id like c-042, got: '$agent'"; return 1; }
  ```
- `diff -u <(git show f2cb19298:csi-spl-orc/src/bash/run/spl-human-email-add.func.sh | sed -n '103,104p') <(git show f2cb19298:csi-spl-orc/src/bash/run/spl-human-link.func.sh | sed -n '83,84p')`
  -> no hunk (rc 0, n=1): the two copies are **byte-identical**.
- `_spl_human_require_order` has **0 collisions** anywhere in the repo (`git grep` -> 0).
  `spl-human-link.func.sh` contains only function definitions (zero top-level code or
  variable assignments), whereas `spl-human-email-add.func.sh:70` assigns top-level
  `_SPL_HUMAN_EMAIL_MASK_JQ`. Hosting `_spl_human_require_order` in
  `spl-human-link.func.sh` and lazy-sourcing `spl-human-link.func.sh` inside
  `_spl_human_email_add_body` behind
  `declare -F _spl_human_require_order >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-human-link.func.sh"`
  avoids top-level side effects and keeps `run-lazy-loader.tst.sh` and
  `run-eager-files.tst.sh` unchanged.
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `_spl_human_require_order` is 5
  lines; `_spl_human_link_body` 12 -> 11 lines; `_spl_human_email_add_body` 14 -> 15
  lines. None of the 4 files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-human-link.func.sh`: define
  `_spl_human_require_order <ordered_by> <agent>` with its 3-line comment immediately
  above `# _spl_human_link_body:` (`:74`), and replace `:83-84` in
  `_spl_human_link_body` with `_spl_human_require_order "$ordby" "$agent" || return 1`.
  88 -> 96 lines (`+10 -2`).
- `orc:src/bash/run/spl-human-email-add.func.sh`: replace `:103-104` in
  `_spl_human_email_add_body` with `# shellcheck source=spl-human-link.func.sh`,
  `declare -F _spl_human_require_order >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-human-link.func.sh"`,
  and `_spl_human_require_order "$ordby" "$agent" || return 1`. 108 -> 109 lines (`+3 -2`).
- `orc:src/bash/tests/spl-human-link.tst.sh`: append section 5 before `:79` (`ALL PASS`):
  4 direct `_spl_human_require_order` checks (accepts `HUM-10` + `c-308`; refuses empty
  `ORDERED_BY` with exact FATAL; refuses legacy `CLE-1` with exact FATAL; refuses 4-digit
  `c-1234` with exact FATAL) and 1 one-copy check (each FATAL string appears once in
  `spl-human-link.func.sh`, which calls `_spl_human_require_order`). 79 -> 92 lines
  (`+13 -0`).
- `orc:src/bash/tests/spl-human-email-add.tst.sh`: append section 6 before `:88`
  (`ALL PASS`): 1 one-copy check (`spl-human-email-add.func.sh` contains neither FATAL
  string and calls `_spl_human_require_order`) plus 1 standalone lazy-load check
  (sourcing only `spl-cloud-cnf.func.sh` and `spl-human-email-add.func.sh` — without
  pre-sourcing `spl-human-link.func.sh` — invokes `do_spl_human_email_add` with
  `AGENT_ID=HUM-10` and asserts rc 1, `FATAL AGENT_ID must be an agent id like c-042`,
  and no `command not found`). 88 -> 101 lines (`+13 -0`).
- head1's files, sha256 (12 chars): `spl-human-link.func.sh` `c7392841cb5e`,
  `spl-human-email-add.func.sh` `bc27dae0a4af`,
  `spl-human-link.tst.sh` `8861cb134fce`,
  `spl-human-email-add.tst.sh` `54af08d7ff54`.
- Note for the row and its reviewer: under `./run`, `run.sh`'s lazy stub loader defines a
  stub for `_spl_human_require_order`, so the `declare -F _spl_human_require_order` guard
  acts only on the standalone-source path outside `./run` (the existing suites source
  `.func.sh` eagerly; N5). `_spl_calendar_require_actor` (`spl-calendar-event-add.func.sh:196-200`)
  is not a third copy (accepts `{3,}` digits and legacy ids, optional `ORDERED_BY`,
  different FATAL; N6). Build `gc1` in a worktree, not a single-file temp copy, because
  the guard loads its sibling `spl-human-link.func.sh` via `dirname "${BASH_SOURCE[0]}"`.

Verbatim helper and test hunks (head1 on `f2cb19298`):

`orc:src/bash/run/spl-human-link.func.sh` (inserted immediately above
`# _spl_human_link_body:` at `:74`, followed by one blank line):
```bash
# _spl_human_require_order <ordered_by> <agent>: validate required ORDERED_BY
# (HUM-*) and strict 3-digit AGENT_ID for operator human-account write actions
# (human-email-add, human-link); logs FATAL and returns 1 on mismatch.
_spl_human_require_order() {
  local ordby="$1" agent="$2"
  [[ "$ordby" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL ORDERED_BY must be the HUM-* id of the human who ordered it, got: '$ordby'"; return 1; }
  [[ "$agent" =~ ^[acgmq]-[0-9]{3}$ ]] || { do_log "FATAL AGENT_ID must be an agent id like c-042, got: '$agent'"; return 1; }
}
```

`orc:src/bash/tests/spl-human-link.tst.sh` section 5 (inserted immediately before
`(( fails == 0 )) && echo "ALL PASS: spl-human-link" || { echo "FAILED: $fails"; exit 1; }`
at `:79`, followed by one blank line):
```bash
# --- 5. _spl_human_require_order (r99-01 one copy) ----------------------------
out=$(bash -c 'do_log(){ echo "$*"; }; source "'"$PROJ_ROOT"'/src/bash/run/spl-human-link.func.sh"; _spl_human_require_order HUM-10 c-308' 2>&1); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && pass "5. _spl_human_require_order accepts HUM-* and 3-digit agent id" || fail "5. order ok: rc=$rc $out"
out=$(bash -c 'do_log(){ echo "$*"; }; source "'"$PROJ_ROOT"'/src/bash/run/spl-human-link.func.sh"; _spl_human_require_order "" c-308' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL ORDERED_BY must be the HUM-* id of the human who ordered it, got: ''"* ]] && pass "5. _spl_human_require_order refuses empty ORDERED_BY" || fail "5. empty ordby: rc=$rc $out"
out=$(bash -c 'do_log(){ echo "$*"; }; source "'"$PROJ_ROOT"'/src/bash/run/spl-human-link.func.sh"; _spl_human_require_order HUM-10 CLE-1' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL AGENT_ID must be an agent id like c-042, got: 'CLE-1'"* ]] && pass "5. _spl_human_require_order refuses legacy AGENT_ID" || fail "5. legacy agent: rc=$rc $out"
out=$(bash -c 'do_log(){ echo "$*"; }; source "'"$PROJ_ROOT"'/src/bash/run/spl-human-link.func.sh"; _spl_human_require_order HUM-10 c-1234' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL AGENT_ID must be an agent id like c-042, got: 'c-1234'"* ]] && pass "5. _spl_human_require_order refuses 4-digit AGENT_ID" || fail "5. 4-digit agent: rc=$rc $out"
link_f="$PROJ_ROOT/src/bash/run/spl-human-link.func.sh"
[[ "$(grep -c "ORDERED_BY must be the HUM-\* id of the human who ordered it" "$link_f")" -eq 1 && "$(grep -c "AGENT_ID must be an agent id like c-042" "$link_f")" -eq 1 && "$(grep -c "_spl_human_require_order " "$link_f")" -ge 1 ]] \
  && pass "5. one copy: spl-human-link.func.sh defines and calls _spl_human_require_order once" || fail "5. link one copy"
```

`orc:src/bash/tests/spl-human-email-add.tst.sh` section 6 (inserted immediately before
`(( fails == 0 )) && echo "ALL PASS: spl-human-email-add" || { echo "FAILED: $fails"; exit 1; }`
at `:88`, followed by one blank line):
```bash
# --- 6. r99-01 one copy and standalone lazy-source ----------------------------
add_f="$PROJ_ROOT/src/bash/run/spl-human-email-add.func.sh"
own="$(grep -nE "ORDERED_BY must be the HUM-\* id of the human who ordered it|AGENT_ID must be an agent id like c-042" "$add_f" || true)"
[[ -z "$own" ]] && grep -q "_spl_human_require_order " "$add_f" \
  && pass "6. one copy: spl-human-email-add.func.sh delegates to _spl_human_require_order" || fail "6. one copy add: own=[$own]"
out=$(env PROJ_PATH="$PROJ_ROOT" ENV=dev HUMAN_ID=HUM-26 EMAIL=a@example.org ORDERED_BY=HUM-10 AGENT_ID=HUM-10 bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ :; }
  source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-human-email-add.func.sh"
  do_spl_human_email_add' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL AGENT_ID must be an agent id like c-042"* && "$out" != *"command not found"* ]] \
  && pass "6. lazy load: spl-human-email-add.func.sh loads _spl_human_require_order standalone" || fail "6. lazy add: rc=$rc $out"
```

**Behaviour:** `_spl_human_require_order "$ordby" "$agent"` executes the exact two regex
checks and `do_log "FATAL ..."; return 1` messages removed from both actions, in the exact
same validation order (after `HUMAN_ID` and `EMAIL` / `LINKED_HUMAN_ID`); all row-01 and
shared suites pass on base and head1 with identical counts plus the 5 + 2 new checks
(1.5).

### 1.4 Row 02's site: `spl-wui-perf-{flow-events,first-load,first-load-net}.func.sh` share `spl_pf_env`

`orc:` = `csi-spl-orc/`. On `f2cb19298`:

- `orc:src/bash/run/spl-wui-perf-flow-events.func.sh:36-48` (in
  `do_spl_wui_perf_flow_events`), `orc:src/bash/run/spl-wui-perf-first-load.func.sh:38-50`
  (in `do_spl_wui_perf_first_load`), and
  `orc:src/bash/run/spl-wui-perf-first-load-net.func.sh:39-51` (in
  `do_spl_wui_perf_first_load_net`) duplicate the exact 13-line setup block resolving the
  WUI origin (`PF_WUI_URL` / `PFL_WUI_URL`, default `https://$SPL_FQDN` for `t1` else
  `https://$tenant.$SPL_FQDN`), member email (`PF_EMAIL` / `PFL_EMAIL`, else
  `$st/human-email`, else `m3-e2e-human@example.com`), password file `$st/pw-human`,
  timing e2e script `$APP_PATH/$SPL_ORG_APP-wui/tests/e2e/<script>`, and Chrome binary
  `${CHROME_PATH:-/usr/bin/google-chrome}`:
  ```bash
    local wui="${PF_WUI_URL:-}"
    if [[ -z "$wui" ]]; then
      [[ "$tenant" == t1 ]] && wui="https://$SPL_FQDN" || wui="https://$tenant.$SPL_FQDN"
    fi
    local st="$SPL_STATE_DIR/m3-e2e/$tenant" email="${PF_EMAIL:-}"
    [[ -n "$email" ]] || { [[ -s "$st/human-email" ]] && email="$(<"$st/human-email")"; }
    [[ -n "$email" ]] || email=m3-e2e-human@example.com
    local pwf="$st/pw-human"
    [[ -s "$pwf" ]] || { do_log "FATAL no password for $email at $pwf: run do_spl_m3_e2e once for $ENV/$tenant"; return 1; }
    local proof_js="$APP_PATH/$SPL_ORG_APP-wui/tests/e2e/perf-flow-events.timing.mjs"
    [[ -f "$proof_js" ]] || { do_log "FATAL no timing e2e at $proof_js"; return 1; }
    local chrome="${CHROME_PATH:-/usr/bin/google-chrome}"
    [[ -x "$chrome" ]] || { do_log "FATAL no Chrome at $chrome (set CHROME_PATH)"; return 1; }
  ```
- `diff -u` of `spl-wui-perf-flow-events.func.sh:36-48` against
  `spl-wui-perf-first-load.func.sh:38-50` (substituting the script basename) -> no hunk
  (rc 0, n=1); against `spl-wui-perf-first-load-net.func.sh:39-51` (substituting script
  basename, `PF_` -> `PFL_`, and `"timing e2e"` -> `"first-load e2e"`) -> no hunk (rc 0,
  n=1).
- `spl_pf_env` and process globals `SPL_PF_WUI`, `SPL_PF_EMAIL`, `SPL_PF_PW_FILE`,
  `SPL_PF_PROOF_JS`, `SPL_PF_CHROME` have **0 collisions** anywhere in the repo
  (`git grep` -> 0). All three `.func.sh` files contain only function definitions (zero
  top-level code), and `spl-wui-perf-first-load.func.sh:35` and
  `spl-wui-perf-first-load-net.func.sh:36` already call `spl_pf_validate` defined in
  `spl-wui-perf-flow-events.func.sh:69`. Placing `spl_pf_env` immediately below
  `spl_pf_validate` in `spl-wui-perf-flow-events.func.sh` and adding a
  `declare -F spl_pf_env >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-wui-perf-flow-events.func.sh"`
  guard immediately before `spl_pf_validate` in both sibling files keeps all three actions
  lazy under `./run` (`run-lazy-loader.tst.sh` and `run-eager-files.tst.sh` unchanged)
  while also making standalone sourcing work without pre-sourcing
  `spl-wui-perf-flow-events.func.sh`.
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `spl_pf_env` is 16 lines;
  `do_spl_wui_perf_flow_events` 38 -> 27 lines; `do_spl_wui_perf_first_load` 39 -> 30
  lines; `do_spl_wui_perf_first_load_net` 40 -> 31 lines. None of the 5 files has any
  entry in `.shellcheck-warning-baseline.txt`, `no-literal-paths.baseline`,
  `action-header-tags-baseline.txt`, or `param-required-baseline.txt`.
- `spl-wui-perf-report.func.sh` stays out: it hits the hub API (`spl_cnf_api_fqdn`), takes
  `PERF_PW_FILE`, uses no Chrome or `.timing.mjs`, and prints `"no readable password file"`
  to stdout (section 7).

Shape (built as head2 of 1.5):
- `orc:src/bash/run/spl-wui-perf-flow-events.func.sh`: replace `:36-48` with
  `spl_pf_env "$tenant" "${PF_WUI_URL:-}" "${PF_EMAIL:-}" "perf-flow-events.timing.mjs" || return 1`
  and `local wui="$SPL_PF_WUI" email="$SPL_PF_EMAIL" pwf="$SPL_PF_PW_FILE" proof_js="$SPL_PF_PROOF_JS" chrome="$SPL_PF_CHROME"`;
  append `spl_pf_env` (with its 4-line header documenting process globals `SPL_PF_WUI`,
  `SPL_PF_EMAIL`, `SPL_PF_PW_FILE`, `SPL_PF_PROOF_JS`, `SPL_PF_CHROME`, and
  `# shellcheck disable=SC2034`) after `spl_pf_validate` (`:76`). 76 -> 87 lines
  (`+24 -13`).
- `orc:src/bash/run/spl-wui-perf-first-load.func.sh`: insert
  `# shellcheck source=spl-wui-perf-flow-events.func.sh` and
  `declare -F spl_pf_env >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-wui-perf-flow-events.func.sh"`
  above `spl_pf_validate` (`:35`), and replace `:38-50` with
  `spl_pf_env "$tenant" "${PF_WUI_URL:-}" "${PF_EMAIL:-}" "perf-first-load.timing.mjs" || return 1`
  and the 1-line `local` unpack. 68 -> 59 lines (`+4 -13`).
- `orc:src/bash/run/spl-wui-perf-first-load-net.func.sh`: insert the same 2-line lazy
  guard above `spl_pf_validate` (`:36`), and replace `:39-51` with
  `spl_pf_env "$tenant" "${PFL_WUI_URL:-}" "${PFL_EMAIL:-}" "perf-first-load-net.timing.mjs" "first-load" || return 1`
  and the 1-line `local` unpack. 76 -> 67 lines (`+4 -13`).
- `orc:src/bash/tests/spl-wui-perf-flow-events.tst.sh`: append section 4 before `:69`
  (`OK spl-wui-perf-flow-events`): 4 direct `spl_pf_env` checks (dev `t1` defaults, prd
  `e2e` tenant host + `human-email`, missing script with custom `first-load` label,
  missing Chrome), 1 one-copy check (`spl-wui-perf-flow-events.func.sh` contains each
  FATAL string once and calls `spl_pf_env`), 1 override check (`in_orc` with
  `PF_WUI_URL=https://o.example.test PF_EMAIL=o@example.test` asserts `BASE=` and
  `EMAIL=` in `$T/calls.log`; W1), and 1 missing-script label check (`in_orc APP_PATH="$T/no-wui"`
  asserts rc 1, `FATAL no timing e2e at`, and node never called; W2). 69 -> 102 lines
  (`+33 -0`).
- `orc:src/bash/tests/spl-wui-perf-first-load.tst.sh`: append section 4 before `:71`
  (`OK spl-wui-perf-first-load`): 2 one-copy checks (`spl-wui-perf-first-load.func.sh` and
  `spl-wui-perf-first-load-net.func.sh` contain none of `FATAL no password for `,
  `FATAL no Chrome at `, or `FATAL no (timing|first-load) e2e at `, and both call
  `spl_pf_env`), 2 standalone lazy-load checks (sourcing only the target `.func.sh`
  without `spl-wui-perf-flow-events.func.sh` invokes each action with `TENANT_ID=nopw` and
  asserts rc 1, `FATAL no password for `, and no `command not found`), 2 override checks
  (`do_spl_wui_perf_first_load` with `PF_WUI_URL`/`PF_EMAIL` via `in_orc`, and
  `do_spl_wui_perf_first_load_net` via the stub-node harness with `PFL_WUI_URL`/`PFL_EMAIL`
  set while `PF_WUI_URL`/`PF_EMAIL` carry distinct sentinel values; W1), and 2
  missing-script label checks (`do_spl_wui_perf_first_load` asserting `FATAL no timing e2e at`,
  and `do_spl_wui_perf_first_load_net` asserting `FATAL no first-load e2e at`, both with
  node never called; W2). 71 -> 116 lines (`+45 -0`).
- head2's files, sha256 (12 chars): `spl-wui-perf-flow-events.func.sh` `4c554e0add30`,
  `spl-wui-perf-first-load.func.sh` `7983dab7a90e`,
  `spl-wui-perf-first-load-net.func.sh` `5e82d6661aaf`,
  `spl-wui-perf-flow-events.tst.sh` `739e49914c92`,
  `spl-wui-perf-first-load.tst.sh` `c19274f92900`.
- Note for the row and its reviewer: standalone-sourcing `first-load` or `first-load-net`
  fails on base with `spl_pf_validate: command not found` (`rc2b`), so the
  `declare -F spl_pf_env` guard adds standalone-source capability; under `./run`,
  `run.sh`'s lazy stub loader defines stubs for both `spl_pf_validate` and `spl_pf_env`,
  and the existing suites source `.func.sh` eagerly (N5). Build `gc2a` / `gc2b` in a
  worktree, not a single-file temp copy.

Verbatim helper and test hunks (head2 on `f2cb19298`):

`orc:src/bash/run/spl-wui-perf-flow-events.func.sh` (appended after `spl_pf_validate` at
`:76`, preceded by one blank line):
```bash
# spl_pf_env <tenant> <wui_override> <email_override> <script> [label] ->
# resolve WUI origin, member email, password file, timing script and Chrome
# binary for the WUI perf timing actions, setting process globals
# SPL_PF_WUI, SPL_PF_EMAIL, SPL_PF_PW_FILE, SPL_PF_PROOF_JS and SPL_PF_CHROME.
# shellcheck disable=SC2034 # SPL_PF_* globals are read by callers
spl_pf_env() {
  local tenant="$1" wui="$2" email="$3" script="$4" label="${5:-timing}"
  if [[ -z "$wui" ]]; then
    [[ "$tenant" == t1 ]] && wui="https://$SPL_FQDN" || wui="https://$tenant.$SPL_FQDN"
  fi
  local st="$SPL_STATE_DIR/m3-e2e/$tenant"
  [[ -n "$email" ]] || { [[ -s "$st/human-email" ]] && email="$(<"$st/human-email")"; }
  [[ -n "$email" ]] || email=m3-e2e-human@example.com
  local pwf="$st/pw-human"
  [[ -s "$pwf" ]] || { do_log "FATAL no password for $email at $pwf: run do_spl_m3_e2e once for $ENV/$tenant"; return 1; }
  local proof_js="$APP_PATH/$SPL_ORG_APP-wui/tests/e2e/$script"
  [[ -f "$proof_js" ]] || { do_log "FATAL no $label e2e at $proof_js"; return 1; }
  local chrome="${CHROME_PATH:-/usr/bin/google-chrome}"
  [[ -x "$chrome" ]] || { do_log "FATAL no Chrome at $chrome (set CHROME_PATH)"; return 1; }
  SPL_PF_WUI="$wui" SPL_PF_EMAIL="$email" SPL_PF_PW_FILE="$pwf" SPL_PF_PROOF_JS="$proof_js" SPL_PF_CHROME="$chrome"
}
```

`orc:src/bash/tests/spl-wui-perf-flow-events.tst.sh` section 4 (inserted immediately
before `((fails == 0)) && echo "OK spl-wui-perf-flow-events: all checks passed" || { echo "FAIL spl-wui-perf-flow-events: $fails check(s)"; exit 1; }`
at `:69`, followed by one blank line):
```bash
# --- 4. spl_pf_env (r99-02 one copy) ----------------------------------------------
out=$(env APP_PATH="$APP_ROOT" SPL_ORG_APP=csi-spl ENV=dev SPL_FQDN=dev.example.test SPL_STATE_DIR="$T/state/dev" CHROME_PATH="$T/stub/chrome" PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-wui-perf-flow-events.func.sh"
  spl_pf_env t1 "" "" perf-flow-events.timing.mjs || exit 1
  printf "%s|%s|%s|%s|%s\n" "$SPL_PF_WUI" "$SPL_PF_EMAIL" "$SPL_PF_PW_FILE" "$(basename "$SPL_PF_PROOF_JS")" "$SPL_PF_CHROME"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "https://dev.example.test|m3-e2e-human@example.com|$T/state/dev/m3-e2e/t1/pw-human|perf-flow-events.timing.mjs|$T/stub/chrome" ]] \
  && pass "4. spl_pf_env resolves dev t1 defaults and sets SPL_PF_* globals" || fail "4. env dev: rc=$rc $out"
out=$(env APP_PATH="$APP_ROOT" SPL_ORG_APP=csi-spl ENV=prd SPL_FQDN=example.test SPL_STATE_DIR="$T/state/prd" CHROME_PATH="$T/stub/chrome" PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-wui-perf-flow-events.func.sh"
  spl_pf_env e2e "" "" perf-first-load-net.timing.mjs first-load || exit 1
  printf "%s|%s\n" "$SPL_PF_WUI" "$SPL_PF_EMAIL"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "https://e2e.example.test|sys+e2e@example.test" ]] \
  && pass "4. spl_pf_env resolves prd tenant host and human-email" || fail "4. env prd: rc=$rc $out"
out=$(env APP_PATH="$APP_ROOT" SPL_ORG_APP=csi-spl ENV=dev SPL_FQDN=dev.example.test SPL_STATE_DIR="$T/state/dev" CHROME_PATH="$T/stub/chrome" PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-wui-perf-flow-events.func.sh"
  spl_pf_env t1 "" "" missing.timing.mjs first-load' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no first-load e2e at "*"missing.timing.mjs" ]] \
  && pass "4. spl_pf_env refuses missing timing script with label" || fail "4. env script: rc=$rc $out"
out=$(env APP_PATH="$APP_ROOT" SPL_ORG_APP=csi-spl ENV=dev SPL_FQDN=dev.example.test SPL_STATE_DIR="$T/state/dev" CHROME_PATH="$T/no-chrome" PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-wui-perf-flow-events.func.sh"
  spl_pf_env t1 "" "" perf-flow-events.timing.mjs' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no Chrome at $T/no-chrome (set CHROME_PATH)"* ]] \
  && pass "4. spl_pf_env refuses missing Chrome" || fail "4. env chrome: rc=$rc $out"
flow_f="$PROJ_ROOT/src/bash/run/spl-wui-perf-flow-events.func.sh"
[[ "$(grep -c "FATAL no password for " "$flow_f")" -eq 1 && "$(grep -c "FATAL no Chrome at " "$flow_f")" -eq 1 && "$(grep -c "spl_pf_env " "$flow_f")" -ge 1 ]] \
  && pass "4. one copy: spl-wui-perf-flow-events.func.sh defines and calls spl_pf_env once" || fail "4. flow one copy"
in_orc ENV=dev PF_WUI_URL=https://o.example.test PF_EMAIL=o@example.test >/dev/null 2>&1; c=$(cat "$T/calls.log")
grep -q 'BASE=https://o.example.test .*EMAIL=o@example.test' <<<"$c" \
  && pass "4. flow-events honors PF_WUI_URL and PF_EMAIL overrides" || fail "4. flow overrides: $c"
out=$(in_orc APP_PATH="$T/no-wui" ENV=dev 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no timing e2e at $T/no-wui/csi-spl-wui/tests/e2e/perf-flow-events.timing.mjs"* && ! -s "$T/calls.log" ]] \
  && pass "4. flow-events missing script prints timing label and never calls node" || fail "4. flow script label: rc=$rc $out"
```

`orc:src/bash/tests/spl-wui-perf-first-load.tst.sh` section 4 (inserted immediately
before `((fails == 0)) && echo "OK spl-wui-perf-first-load: all checks passed" || { echo "FAIL spl-wui-perf-first-load: $fails check(s)"; exit 1; }`
at `:71`, followed by one blank line):
```bash
# --- 4. r99-02 one copy and standalone lazy-source --------------------------------
for f in spl-wui-perf-first-load.func.sh spl-wui-perf-first-load-net.func.sh; do
  fp="$PROJ_ROOT/src/bash/run/$f"
  own="$(grep -nE "FATAL no password for |FATAL no Chrome at |FATAL no (timing|first-load) e2e at " "$fp" || true)"
  [[ -z "$own" ]] && grep -q "spl_pf_env " "$fp" \
    && pass "4. one copy: $f delegates env setup to spl_pf_env" || fail "4. one copy $f: own=[$own]"
done
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" T="$T" ENV=dev TENANT_ID=nopw CHROME_PATH="$T/stub/chrome" bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  do_spl_cloud_cnf(){ SPL_ORG_APP=csi-spl; SPL_STATE_DIR="$T/state/$ENV"; SPL_FQDN=dev.example.test; mkdir -p "$SPL_STATE_DIR"; }
  source "$PROJ_PATH/src/bash/run/spl-wui-perf-first-load.func.sh"
  do_spl_wui_perf_first_load' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no password for "* && "$out" != *"command not found"* ]] \
  && pass "4. lazy load: spl-wui-perf-first-load.func.sh loads spl_pf_env standalone" || fail "4. lazy first-load: rc=$rc $out"
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" T="$T" ENV=dev TENANT_ID=nopw CHROME_PATH="$T/stub/chrome" bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  do_spl_cloud_cnf(){ SPL_ORG_APP=csi-spl; SPL_STATE_DIR="$T/state/$ENV"; SPL_FQDN=dev.example.test; mkdir -p "$SPL_STATE_DIR"; }
  source "$PROJ_PATH/src/bash/run/spl-wui-perf-first-load-net.func.sh"
  do_spl_wui_perf_first_load_net' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no password for "* && "$out" != *"command not found"* ]] \
  && pass "4. lazy load: spl-wui-perf-first-load-net.func.sh loads spl_pf_env standalone" || fail "4. lazy first-load-net: rc=$rc $out"
in_orc ENV=dev PF_WUI_URL=https://o.example.test PF_EMAIL=o@example.test >/dev/null 2>&1; c=$(cat "$T/calls.log")
grep -q 'BASE=https://o.example.test .*EMAIL=o@example.test' <<<"$c" \
  && pass "4. first-load honors PF_WUI_URL and PF_EMAIL overrides" || fail "4. first-load overrides: $c"
out=$(in_orc APP_PATH="$T/no-wui" ENV=dev 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no timing e2e at $T/no-wui/csi-spl-wui/tests/e2e/perf-first-load.timing.mjs"* && ! -s "$T/calls.log" ]] \
  && pass "4. first-load missing script prints timing label and never calls node" || fail "4. first-load script label: rc=$rc $out"
: >"$T/calls.log"
env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" STUB_LOG="$T/calls.log" T="$T" PATH="$T/stub:$PATH" CHROME_PATH="$T/stub/chrome" \
  ENV=dev PF_WUI_URL=https://wrong.example.test PF_EMAIL=wrong@example.test PFL_WUI_URL=https://o.example.test PFL_EMAIL=o@example.test bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf(){ SPL_ORG_APP=csi-spl; SPL_STATE_DIR="$T/state/$ENV"; SPL_FQDN=dev.example.test; mkdir -p "$SPL_STATE_DIR"; }
  do_spl_wui_perf_first_load_net' >/dev/null 2>&1; c=$(cat "$T/calls.log")
grep -q 'BASE=https://o.example.test .*EMAIL=o@example.test' <<<"$c" \
  && pass "4. first-load-net honors PFL_WUI_URL and PFL_EMAIL overrides" || fail "4. first-load-net overrides: $c"
: >"$T/calls.log"
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/no-wui" STUB_LOG="$T/calls.log" T="$T" PATH="$T/stub:$PATH" CHROME_PATH="$T/stub/chrome" ENV=dev bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf(){ SPL_ORG_APP=csi-spl; SPL_STATE_DIR="$T/state/$ENV"; SPL_FQDN=dev.example.test; mkdir -p "$SPL_STATE_DIR"; }
  do_spl_wui_perf_first_load_net' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no first-load e2e at $T/no-wui/csi-spl-wui/tests/e2e/perf-first-load-net.timing.mjs"* && ! -s "$T/calls.log" ]] \
  && pass "4. first-load-net missing script prints first-load label and never calls node" || fail "4. first-load-net script label: rc=$rc $out"
```

**Behaviour:** `spl_pf_env` executes the exact origin default, email fallback, `pw-human`
check, timing-script check (preserving `"timing"` vs `"first-load"` in the FATAL), and
Chrome check removed from all three actions, in the exact same order; its only new state
is the five process globals `SPL_PF_WUI`, `SPL_PF_EMAIL`, `SPL_PF_PW_FILE`,
`SPL_PF_PROOF_JS` and `SPL_PF_CHROME` documented in its header;
`spl-wui-perf-first-load-net.tst.sh` remains untouched and green; all row-02 and shared
suites pass on base and head2 with identical counts plus the 7 + 8 new checks (1.5).

### 1.5 Before and on the rows' heads

2026-11-25T08:32:42Z-08:38:23Z (base, head1 + shared, controls `rc1a`/`rc1b`/`gc1`) and
2026-11-25T09:19:16Z-09:23:24Z (v0.2 head2 + 11 suites, `shellcheck -S warning -x`,
`do_sec_shellcheck`, controls `rc2a`/`rc2b`/`gc2a`/`gc2b`, and mutations
`m2`/`m2_flow`/`m2_fl`/`m3`/`m3_flow`/`m3_fl`), n=1, as the push user,
`SPOOL_TEST=1` with `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`;
pass lines `grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`.
"=" means equal to base: same rc, pass and fail counts; "-" means that row's head does
not touch the suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/spl-human-link.tst.sh` | 01 | 0 / 20 / 0 | 0 / 25 / 0 (+5 new checks) | - |
| `orc:src/bash/tests/spl-human-email-add.tst.sh` | 01 | 0 / 21 / 0 | 0 / 23 / 0 (+2 new checks) | - |
| `orc:src/bash/tests/spl-wui-perf-flow-events.tst.sh` | 02 | 0 / 30 / 0 | - | 0 / 37 / 0 (+7 new checks) |
| `orc:src/bash/tests/spl-wui-perf-first-load.tst.sh` | 02 | 0 / 34 / 0 | - | 0 / 42 / 0 (+8 new checks) |
| `orc:src/bash/tests/spl-wui-perf-first-load-net.tst.sh` | 02 | 0 / 39 / 0 | - | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

Note: the three `spl-wui-perf-*.tst.sh` suites print a final `OK <name>: all checks passed`
summary line on rc 0 (and `FAIL <name>: <n> check(s)` on rc 1), which
`grep -ciE '^ *(ok|pass)'` and `grep -ciE '^ *(not ok|fail)'` count (e.g.,
`spl-wui-perf-flow-events.tst.sh` 30 on base = 29 assertions + 1 summary; 37 on head2 =
36 + 1; `spl-wui-perf-first-load.tst.sh` 34 on base = 33 + 1; 42 on head2 = 41 + 1;
`spl-wui-perf-first-load-net.tst.sh` 39 = 38 + 1). The two `spl-human-*.tst.sh` suites
print `ALL PASS: ...` on rc 0 (not counted) and `FAILED: <n>` on rc 1 (counted as 1 extra
fail line).

`shellcheck -S warning -x` on all 9 row files (base, head1, head2): **rc 0**, no findings
(n=1 each). `do_sec_shellcheck` with newline-separated `SEC_SHELLCHECK_FILES` set to each
row's touched files (head1: 4 files, head2: 5 files): **rc 0**, `no error-level findings`,
`no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `f2cb19298`,
reconstructed from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control a (`rc1a`, head1's `spl-human-link.tst.sh` on base): rc 1, 20 pass,
  6 fail lines (5 assertions: `FAIL: 5. order ok` / `empty ordby` / `legacy agent` /
  `4-digit agent` each rc 127 `_spl_human_require_order: command not found`, `FAIL: 5. link one copy`,
  plus summary `FAILED: 5`); head1: rc 0, 25 pass, 0 fail.
- Row 01 red control b (`rc1b`, head1's `spl-human-email-add.tst.sh` on base): rc 1, 22
  pass, 2 fail lines (1 assertion: `FAIL: 6. one copy add: own=[103: ...]`, plus summary
  `FAILED: 1`; the standalone check passes on base because base validates inline); head1:
  rc 0, 23 pass, 0 fail.
- Row 01 guard control (`gc1`, head1 with the `declare -F _spl_human_require_order`
  lazy-source line deleted in `spl-human-email-add.func.sh`): rc 1, 22 pass, 2 fail lines
  (`FAIL: 6. lazy add: rc=1 .../spl-human-email-add.func.sh: line 104: _spl_human_require_order: command not found`,
  plus `FAILED: 1`).
- Row 02 red control a (`rc2a`, head2's `spl-wui-perf-flow-events.tst.sh` on base): rc 1,
  31 pass, 6 fail lines (5 assertions: `FAIL: 4. env dev` / `env prd` rc 1 and
  `env script` / `env chrome` rc 127 each `spl_pf_env: command not found`,
  `FAIL: 4. flow one copy`, plus summary `FAIL spl-wui-perf-flow-events: 5 check(s)`; the
  2 override and missing-script checks pass on base, proving equivalence); head2: rc 0,
  37 pass, 0 fail.
- Row 02 red control b (`rc2b`, head2's `spl-wui-perf-first-load.tst.sh` on base): rc 1,
  37 pass, 5 fail lines (4 assertions: `FAIL: 4. one copy spl-wui-perf-first-load.func.sh: own=[46: ...]`,
  `FAIL: 4. one copy spl-wui-perf-first-load-net.func.sh: own=[47: ...]`,
  `FAIL: 4. lazy first-load: rc=1 .../spl-wui-perf-first-load.func.sh: line 35: spl_pf_validate: command not found`,
  `FAIL: 4. lazy first-load-net: rc=1 .../spl-wui-perf-first-load-net.func.sh: line 36: spl_pf_validate: command not found`,
  plus summary `FAIL spl-wui-perf-first-load: 4 check(s)`; the 4 override and
  missing-script checks pass on base, proving equivalence); head2: rc 0, 42 pass, 0 fail.
- Row 02 guard control a (`gc2a`, head2 with the `declare -F spl_pf_env` lazy-source line
  deleted in `spl-wui-perf-first-load.func.sh`): rc 1, 40 pass, 2 fail lines
  (`FAIL: 4. lazy first-load: rc=1 .../spl-wui-perf-first-load.func.sh: line 36: spl_pf_validate: command not found`,
  plus `FAIL spl-wui-perf-first-load: 1 check(s)`).
- Row 02 guard control b (`gc2b`, head2 with the `declare -F spl_pf_env` lazy-source line
  deleted in `spl-wui-perf-first-load-net.func.sh`): rc 1, 40 pass, 2 fail lines
  (`FAIL: 4. lazy first-load-net: rc=1 .../spl-wui-perf-first-load-net.func.sh: line 37: spl_pf_validate: command not found`,
  plus `FAIL spl-wui-perf-first-load: 1 check(s)`).

**Row 02 mutation checks (W1, W2)** (n=1 each, detached worktrees of `f2cb19298` with head2
applied, then one defect injected):
- `m2` (`spl-wui-perf-first-load-net.func.sh` passes `${PF_WUI_URL:-}`/`${PF_EMAIL:-}`
  instead of `PFL_*`): `spl-wui-perf-first-load.tst.sh` rc 1, 40 pass, 2 fail lines
  (`FAIL: 4. first-load-net overrides: ... BASE=https://wrong.example.test ... EMAIL=wrong@example.test`).
- `m2_flow` (`spl-wui-perf-flow-events.func.sh` passes `"" ""` instead of `PF_*`):
  `spl-wui-perf-flow-events.tst.sh` rc 1, 35 pass, 2 fail lines
  (`FAIL: 4. flow overrides: ... BASE=https://dev.example.test ...`).
- `m2_fl` (`spl-wui-perf-first-load.func.sh` passes `"" ""` instead of `PF_*`):
  `spl-wui-perf-first-load.tst.sh` rc 1, 40 pass, 2 fail lines
  (`FAIL: 4. first-load overrides: ... BASE=https://dev.example.test ...`).
- `m3` (`spl-wui-perf-first-load-net.func.sh` drops 5th arg `"first-load"`):
  `spl-wui-perf-first-load.tst.sh` rc 1, 40 pass, 2 fail lines
  (`FAIL: 4. first-load-net script label: rc=1 FATAL no timing e2e at ...`).
- `m3_flow` (`spl-wui-perf-flow-events.func.sh` passes `"first-load"`):
  `spl-wui-perf-flow-events.tst.sh` rc 1, 35 pass, 2 fail lines
  (`FAIL: 4. flow script label: rc=1 FATAL no first-load e2e at ...`).
- `m3_fl` (`spl-wui-perf-first-load.func.sh` passes `"first-load"`):
  `spl-wui-perf-first-load.tst.sh` rc 1, 40 pass, 2 fail lines
  (`FAIL: 4. first-load script label: rc=1 FATAL no first-load e2e at ...`).

The tests that name the sites (R2): `git grep -lE` over `*.tst.sh` and `features/*/tests/*`
for `spl-human-(email-add|link)|do_spl_human_(email_add|link)|_spl_human_(email_add|link)_body|spl-wui-perf-(flow-events|first-load)|do_spl_wui_perf_(flow_events|first_load)|spl_pf_validate`
-> `spl-human-link.tst.sh`, `spl-human-email-add.tst.sh` for row 01;
`spl-wui-perf-flow-events.tst.sh`, `spl-wui-perf-first-load.tst.sh`,
`spl-wui-perf-first-load-net.tst.sh` for row 02 (plus the 8 shared iac/orc gates). 30-char
non-separator comment grep within site lines +/- 3 across all `*.tst.sh` and `test-*.sh`
-> **0 hits**. No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r99-01-orc-human-order-actor)` | one fact, one copy (developer guide 2.2.4) | `spl-human-link.func.sh:83-84` and `spl-human-email-add.func.sh:103-104` duplicate the exact 2-line required `ORDERED_BY` + strict 3-digit `AGENT_ID` check (1.3, r98 section 7) | `orc:src/bash/run/spl-human-link.func.sh:74,83-84`<br>`orc:src/bash/run/spl-human-email-add.func.sh:103-104`<br>`orc:src/bash/tests/spl-human-link.tst.sh:79`<br>`orc:src/bash/tests/spl-human-email-add.tst.sh:88` | copies of the human-operator `ORDERED_BY` + strict 3-digit `AGENT_ID` guard 2 -> 1 (`_spl_human_require_order` in `spl-human-link.func.sh`) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head's `spl-human-link.tst.sh` on parent FAILs 5 checks (`rc1a`, rc 1, 20 pass, 6 fail lines, `_spl_human_require_order: command not found` + one-copy) and head's `spl-human-email-add.tst.sh` on parent FAILs one-copy naming `:103` (`rc1b`, rc 1, 22 pass, 2 fail lines), then GREEN (25/0 and 23/0); guard control (`gc1`, `declare -F _spl_human_require_order` deleted in `spl-human-email-add.func.sh`: rc 1, 22 pass, 2 fail lines with `_spl_human_require_order: command not found`; proves standalone-source path outside `./run`), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 5 + 2 new checks. Tests: `orc:.../spl-human-link.tst.sh`, `spl-human-email-add.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r99-02-orc-wui-perf-env)` | one fact, one copy (developer guide 2.2.4) | `spl-wui-perf-flow-events.func.sh:36-48`, `spl-wui-perf-first-load.func.sh:38-50`, and `spl-wui-perf-first-load-net.func.sh:39-51` duplicate the exact 13-line WUI origin, member email, `pw-human`, timing-script and Chrome binary setup block (1.4) | `orc:src/bash/run/spl-wui-perf-flow-events.func.sh:36-48,76`<br>`orc:src/bash/run/spl-wui-perf-first-load.func.sh:35,38-50`<br>`orc:src/bash/run/spl-wui-perf-first-load-net.func.sh:36,39-51`<br>`orc:src/bash/tests/spl-wui-perf-flow-events.tst.sh:69`<br>`orc:src/bash/tests/spl-wui-perf-first-load.tst.sh:71` | copies of the WUI perf timing origin/email/password/script/Chrome setup 3 -> 1 (`spl_pf_env` in `spl-wui-perf-flow-events.func.sh`) | 1.4's shape (verbatim blocks in 1.4; header documents process globals `SPL_PF_WUI`, `SPL_PF_EMAIL`, `SPL_PF_PW_FILE`, `SPL_PF_PROOF_JS`, `SPL_PF_CHROME`). **Red control:** head's `spl-wui-perf-flow-events.tst.sh` on parent FAILs 5 checks (`rc2a`, rc 1, 31 pass, 6 fail lines, `spl_pf_env: command not found` + one-copy) and head's `spl-wui-perf-first-load.tst.sh` on parent FAILs 4 checks (`rc2b`, rc 1, 37 pass, 5 fail lines, one-copy `:46`/`:47` + standalone `spl_pf_validate: command not found`), then GREEN (37/0 and 42/0); guard controls (`gc2a`/`gc2b`, `declare -F spl_pf_env` deleted in first-load/first-load-net: rc 1, 40 pass, 2 fail lines each with `spl_pf_validate: command not found`; proves standalone-source path outside `./run`), built in a worktree; per-caller `PF_*`/`PFL_*` override checks and missing-script `"timing"`/`"first-load"` label checks catch `m2`/`m2_flow`/`m2_fl` and `m3`/`m3_flow`/`m3_fl` (1.5); outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 7 + 8 new checks. Tests: `orc:.../spl-wui-perf-flow-events.tst.sh`, `spl-wui-perf-first-load.tst.sh`, `spl-wui-perf-first-load-net.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r99-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r99-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row extracts a duplicated validation/setup block into one shared helper and
points its callers at that single home; no output, exit code, env var, path or file a
caller sees changes (1.3, 1.4, 1.5). Each: `Docs: none (<why>)`. The developer guide
2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `spl-human-link.func.sh`, `spl-human-email-add.func.sh`, `spl-human-link.tst.sh`,
  `spl-human-email-add.tst.sh`; row 02: `csi-spl-orc` `spl-wui-perf-flow-events.func.sh`,
  `spl-wui-perf-first-load.func.sh`, `spl-wui-perf-first-load-net.func.sh`,
  `spl-wui-perf-flow-events.tst.sh`, `spl-wui-perf-first-load.tst.sh`).
- No row edits `orc:src/bash/run/spl-wui-perf-report.func.sh`,
  `orc:src/bash/tests/spl-wui-perf-first-load-net.tst.sh`,
  `orc:src/bash/run/spl-calendar-event-*.func.sh`, any `csi-spl-iac` cost file (r98-02),
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-utl/`, or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (9, the 4 edited by row 01 + the 5 edited by row 02):
`orc:src/bash/run/spl-human-link.func.sh`,
`orc:src/bash/run/spl-human-email-add.func.sh`,
`orc:src/bash/tests/spl-human-link.tst.sh`,
`orc:src/bash/tests/spl-human-email-add.tst.sh`;
`orc:src/bash/run/spl-wui-perf-flow-events.func.sh`,
`orc:src/bash/run/spl-wui-perf-first-load.func.sh`,
`orc:src/bash/run/spl-wui-perf-first-load-net.func.sh`,
`orc:src/bash/tests/spl-wui-perf-flow-events.tst.sh`,
`orc:src/bash/tests/spl-wui-perf-first-load.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <all 9 paths> --agent a-482`, n=1,
  re-checked at 2026-11-25T09:17:27Z (N4): **exit 4** ("no live lane lists <the 9 paths>,
  but 16 live lane(s) record no files"). The 16 `unknown:` lanes, all on the other box:
  channel/workspace and other-repo seats (`c-029`, `c-041`, `c-086`, `c-146`, `c-165`,
  `c-187`, `c-249`, `c-341`, `c-728`, `c-927`, `c-935`, `c-936`), this round's claude
  panel seat (`c-396`), spec/other-repo seats (`c-957`, `c-965`), and skills editor
  `c-774`. No live lane owns any of the 9 paths; the holder re-reads at placement per R3.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, re-checked 09:17:32Z):
  8 queued, 0 placing: `c002-api-store-hr-code-collision-flake`,
  `c002-issue-comment-edit-mark`, a queued other-repo bug lane,
  `c002-orc-box-link-watch-doc-hub-log-is-box-log`, `c001-s186-m9-n2-qto-sync`, and 3
  spec planner/answer lanes (specs 112, 149, 039). None touches any of the 9 paths.
- **Unlanded r98-02** (`review/r98-02` `2e37534c6`): touches only 5 `csi-spl-iac` cost
  files (`spl-cost-gcp.func.sh`, `spl-estate-cost-read.{func,tst}.sh`,
  `spl-vm-cost-per-day.{func,tst}.sh`), disjoint from all 9 paths.
- **Briefs on this box** changed in the last 24 h matching any of the 9 paths (08:22:24Z):
  3 briefs (`c002-r98-01-orc-calendar-actor.md` — landed `5adcd5fdd`, cited human files
  only in its NOT-touch list; `c002-bug-wui-perf-flow-events-m390-nav.md` and its R7
  `c003-spl6386-r7-claude-waiver-reviewer.md` — SPL-6386, already landed `8d348dbe1` on
  `perf-flow-events.timing.mjs`). **0 active or queued briefs** touch any of the 9 paths.
- **Remote branches committed in the last 24 h** (`git fetch --prune origin`, 08:22:25Z):
  `git diff --name-only $(git merge-base f2cb19298 <b>) <b> -- <the 9 paths>` -> **0 hits**.
- **Commits in the last 24 h** on those 9 paths (`git log f2cb19298 --since='24 hours ago'`)
  -> **0**.

## 3. Per row: what the lane does

- **r99-01:** `orc:src/bash/run/spl-human-link.func.sh` gains
  `_spl_human_require_order <ordered_by> <agent>` above `# _spl_human_link_body:` (`:74`),
  and `_spl_human_link_body` replaces `:83-84` with
  `_spl_human_require_order "$ordby" "$agent" || return 1`;
  `orc:src/bash/run/spl-human-email-add.func.sh` (`:103-104`) drops its duplicate 2-line
  check, lazy-sources `spl-human-link.func.sh` behind a
  `declare -F _spl_human_require_order` guard, and calls
  `_spl_human_require_order "$ordby" "$agent" || return 1`.
  `orc:src/bash/tests/spl-human-link.tst.sh` appends section 5 (4 direct
  `_spl_human_require_order` checks + 1 one-copy check);
  `orc:src/bash/tests/spl-human-email-add.tst.sh` appends section 6 (1 one-copy check + 1
  standalone lazy-load check).
- **r99-02:** `orc:src/bash/run/spl-wui-perf-flow-events.func.sh` appends
  `spl_pf_env <tenant> <wui_override> <email_override> <script> [label]` after
  `spl_pf_validate` (`:76`), documenting and setting process globals `SPL_PF_WUI`,
  `SPL_PF_EMAIL`, `SPL_PF_PW_FILE`, `SPL_PF_PROOF_JS` and `SPL_PF_CHROME`, and replaces
  `:36-48` with `spl_pf_env` + 1-line `local` unpack;
  `orc:src/bash/run/spl-wui-perf-first-load.func.sh` (`:35`, `:38-50`) and
  `orc:src/bash/run/spl-wui-perf-first-load-net.func.sh` (`:36`, `:39-51`) add a
  `declare -F spl_pf_env` lazy-source of sibling `spl-wui-perf-flow-events.func.sh` above
  `spl_pf_validate` and replace their 13-line setup blocks with `spl_pf_env` + 1-line
  `local` unpack (passing `"first-load"` as the label in `first-load-net`).
  `orc:src/bash/tests/spl-wui-perf-flow-events.tst.sh` appends section 4 (4 direct
  `spl_pf_env` checks, 1 one-copy check, 1 `PF_WUI_URL`/`PF_EMAIL` override check, and 1
  missing-script `"timing"` label check);
  `orc:src/bash/tests/spl-wui-perf-first-load.tst.sh` appends section 4 (2 one-copy
  checks, 2 standalone lazy-load checks, 2 per-caller override checks covering `PF_*` on
  `first-load` and `PFL_*` on `first-load-net`, and 2 missing-script label checks covering
  `"timing"` on `first-load` and `"first-load"` on `first-load-net`).

## 4. Panel and reviewers (R7)

- Editor: **a-482** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; brief
  step 5; mistral sits on no review since 2026-11-25): claude panel seat **c-396**
  (`c002-refactor-round-99-claude-panel-seat`, ask `ad83e2d9`), signed **PASS** on v0.2
  `853b9368f3f58e9b6a175796121c94e4a0674dcd` (seat file
  `csi-spl-doc/doc/md/refactor-round-99/seat-claude.md` at
  `a8450306bb192c5b5719209d458974657219b078` on
  `review/c002-refactor-round-99-claude-seat`; `do_spl_review_line_check` rc 0). The seat
  reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-25T08:19:07Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `kinds off grok,qwen`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 08:23:18Z (`main=agy backup=claude`; mistral sits on no review), R7 review of a
    claude coding row goes to an **agy seat** per row (claude waiver backup only while agy
    is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 08:19:18Z picked an available box; the
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
| r99-01 | `c002-r99-01-orc-human-order-actor` | `refactor(r99-01-orc-human-order-actor, SPL-<row issue>): ...` | `review/r99-01` | 1 |
| r99-02 | `c002-r99-02-orc-wui-perf-env` | `refactor(r99-02-orc-wui-perf-env, SPL-<row issue>): ...` | `review/r99-02` | 1 |

**r99-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-human-link.func.sh` (add `_spl_human_require_order` above
`# _spl_human_link_body:` `:74`, replace `:83-84` with
`_spl_human_require_order "$ordby" "$agent" || return 1`),
`csi-spl-orc/src/bash/run/spl-human-email-add.func.sh` (replace `:103-104` with
`declare -F _spl_human_require_order` lazy-source of sibling `spl-human-link.func.sh` and
`_spl_human_require_order "$ordby" "$agent" || return 1`),
`csi-spl-orc/src/bash/tests/spl-human-link.tst.sh` (append section 5: 4 direct
`_spl_human_require_order` checks + 1 one-copy check before `:79`), and
`csi-spl-orc/src/bash/tests/spl-human-email-add.tst.sh` (append section 6: 1 one-copy
check + 1 standalone lazy-load check before `:88`). NOT `spl-calendar-event-*.func.sh`,
NOT `spl-human-behaviour.func.sh`, NOT `spl-human-locale.func.sh`, NOT
`spl-human-pseudonym.func.sh`, NOT `spl-human-theme.func.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 01 verbatim,
1.3's shape (verbatim blocks in 1.3); red controls (`rc1a` + `rc1b`, head's tests on
parent) RED then GREEN in the body; guard control (`gc1`,
`declare -F _spl_human_require_order` deleted in `spl-human-email-add.func.sh`, built in a
worktree, not a temp-dir copy; proves standalone-source path outside `./run`, while under
`./run` the lazy index emits the stub and the suites source `.func.sh` eagerly). Gates: the
row's tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on
the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude; R7 **agy seat** (claude waiver backup only while agy is
out of quota, which is same-vendor to the claude author under rulebook 2.7.2 and valid
only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the claude
backup is used; never mistral; re-checked at placement).

**r99-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-wui-perf-flow-events.func.sh` (append `spl_pf_env` after
`spl_pf_validate` `:76`, documenting in its header that it sets process globals
`SPL_PF_WUI`, `SPL_PF_EMAIL`, `SPL_PF_PW_FILE`, `SPL_PF_PROOF_JS`, `SPL_PF_CHROME`;
replace `:36-48` with `spl_pf_env` + 1-line `local` unpack),
`csi-spl-orc/src/bash/run/spl-wui-perf-first-load.func.sh` (insert
`declare -F spl_pf_env` lazy-source of sibling `spl-wui-perf-flow-events.func.sh` above
`spl_pf_validate` `:35`; replace `:38-50` with `spl_pf_env` + 1-line `local` unpack),
`csi-spl-orc/src/bash/run/spl-wui-perf-first-load-net.func.sh` (insert same lazy-source
above `spl_pf_validate` `:36`; replace `:39-51` with `spl_pf_env` passing `"first-load"` +
1-line `local` unpack), `csi-spl-orc/src/bash/tests/spl-wui-perf-flow-events.tst.sh`
(append section 4: 4 direct `spl_pf_env` checks, 1 one-copy check, 1 `PF_WUI_URL`/`PF_EMAIL`
override check, and 1 missing-script `"timing"` label check before `:69`), and
`csi-spl-orc/src/bash/tests/spl-wui-perf-first-load.tst.sh` (append section 4: 2 one-copy
checks, 2 standalone lazy-load checks, 2 per-caller override checks for `first-load`
`PF_*` and `first-load-net` `PFL_*`, and 2 missing-script label checks asserting
`"timing"` vs `"first-load"` before `:71`). NOT `spl-wui-perf-report.func.sh`,
NOT `spl-wui-perf-first-load-net.tst.sh`, NOT `.shellcheck-warning-baseline.txt`, or any
other file. Do: plan section 2 row 02 verbatim, 1.4's shape (verbatim blocks in 1.4); red
controls (`rc2a` + `rc2b`, head's tests on parent) RED then GREEN in the body; guard
controls (`gc2a` + `gc2b`, `declare -F spl_pf_env` deleted in first-load/first-load-net,
built in a worktree, not a temp-dir copy; proves standalone-source path outside `./run`,
which base lacks because `spl_pf_validate` is not sourced standalone; under `./run` the
lazy index emits stubs for both functions and the suites source `.func.sh` eagerly).
Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
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
| copies of the human-operator `ORDERED_BY` + strict 3-digit `AGENT_ID` guard (1.3) | 2 on `f2cb19298` (`spl-human-link`, `spl-human-email-add`) -> 1 (`_spl_human_require_order`) after row 01 |
| copies of the WUI perf timing origin/email/password/script/Chrome setup (1.4) | 3 on `f2cb19298` (`spl-wui-perf-flow-events`, `spl-wui-perf-first-load`, `spl-wui-perf-first-load-net`) -> 1 (`spl_pf_env`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spl-human-link.func.sh` +10 -2, `spl-human-email-add.func.sh` +3 -2, `spl-human-link.tst.sh` +13 -0, `spl-human-email-add.tst.sh` +13 -0; row 02: `spl-wui-perf-flow-events.func.sh` +24 -13, `spl-wui-perf-first-load.func.sh` +4 -13, `spl-wui-perf-first-load-net.func.sh` +4 -13, `spl-wui-perf-flow-events.tst.sh` +33 -0, `spl-wui-perf-first-load.tst.sh` +45 -0 |
| measured on | `f2cb19298` (zero drift on all 10 row/test files to `208e5f757`); n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-wui-perf-report.func.sh:69-75` | hits the hub API (`spl_cnf_api_fqdn`), takes `PERF_PW_FILE`, uses no Chrome or `.timing.mjs`, and prints `"no readable password file"` to stdout rather than `do_log FATAL`; different semantics from row 02 | `git show f2cb19298:csi-spl-orc/src/bash/run/spl-wui-perf-report.func.sh` |
| `orc:src/bash/run/spl-channel-agent-{add,add-op,remove-op}.func.sh` (`AGENT_BOX` + `AGENTS` validation/dedup, `:32-37`, `:67-76`, `:39-48`) | strong candidate for `r01`, but `orc:src/bash/tests/dispatch-inbound-pg.tst.sh:141` directly sources `spl-channel-agent-add-op.func.sh`, pulling a PostgreSQL test into R2 | `git grep -n 'channel-agent' f2cb19298 -- csi-spl-orc/src/bash/tests/` |
| `iac:src/bash/run/gcp-{get-alert-incident,list-alert-incidents}.func.sh` (paged Monitoring v3 `timeSeries` curl loop, `:71-82`, `:89-100`) | clean 12-line duplicate in `csi-spl-iac`, good candidate for `r01` (verify non-secret classification of the `auth.curl` `-K` loop at plan time) | `git show f2cb19298:csi-spl-iac/src/bash/run/gcp-get-alert-incident.func.sh` |
| `orc:src/bash/run/spl-hub-{request-minutes,run-metrics}.func.sh` (`svc` + `do_gcp_pin_account` + `until` setup, `:35-39`, `:17-21`) | 5-line duplicate, single test file `spl-hub-request-minutes.tst.sh`; strong small candidate for `r01` | fresh scan (1.2 (e)) |
| `orc:src/bash/run/spl-hub-{agent-kinds,runner-cpu}.func.sh`, `spl-msg-move`/`spl-topic-move`, `spl-msg-dedup`/`spl-msg-wipe`, `spl-box-restart-install-cron`/`spl-peer-crons`, `check-disk-headroom-install-cron`/`setup-box-stats-cron`/`setup-go-cache-prune-cron`, `spl-{backfill,fallback,reply,reply-count,topic-reply}-probe.func.sh` | newly scanned duplicate blocks (5+ lines); each is a candidate for `r01`+ after test-column measurement (note the 5 probe actions touch 5+ files) | fresh scan (1.2 (e)) |
| `orc:src/bash/run/{spl-accepted-close,spl-desk-poll-ack,spl-review-go}.func.sh` (`_spl_accepted_close_holder:104`, `_spl_poll_ack_holder:136`, `_spl_review_go_holder:162`) | `spl-review-go.func.sh` was touched by live lane `c-460` (`b46-03`, landed `f2cb19298`) and moving the helper to `spl-dispatch-lease.func.sh` pulls 30+ tests (incl. PG) into R2 | `git grep -n '_holder()' f2cb19298 -- csi-spl-orc/src/bash/run/` |
| `csi-spl-utl/src/bash/run/cron-heartbeat-snitch.func.sh:202` (`_chs_send`) and `reboot-required-check.func.sh:83` (`_rrc_send`), plus `csi-spl-utl/src/bash/scripts/*-sweep.sh` | touching `csi-spl-utl/**` classifies as `parts=all` in CI (`utl-suite.tst.sh:4`); unchanged since r98 | r98 7; 1.2 (a) |
| `orc:src/bash/run/spl-lane-handover{,-agy,-mistral}.func.sh`, `orc:src/bash/run/spl-release-note-bans-{check,seed}.func.sh`, `iac:src/bash/run/spl-secret-{rotate,version-disable-old}.func.sh`, and the 3 `iac` GitHub repo parsers (`_sga_repo`, `gh_box_token_repo`, `gh_secret_put_gcp_key_repo`) | secret-class / session-key-adjacent sites stay out of refactor rounds (brief rule) | r98 7; 1.2 (a), (e) |
| `iac:src/bash/run/sec-*.func.sh` (`_sec_*_root` x8, `_sec_*_need` x7) and `orc:src/bash/scripts/*-cron.sh` (`check_tools` x14) | >5 sites per group and security-gate actions (`PRE_PUSH_TIER=full`, R9); unchanged since r98 | r98 7; 1.2 (a) |
| Go duplicate helpers in `csi-spl-api/src/go/spool-hub-api` and TS helpers in `csi-spl-wui` | `csi-spl-api` requires `PRE_PUSH_TIER=full` Postgres gate and dev/prd deploy lag; `csi-spl-wui` requires Chrome e2e, Firebase deploy lag, and overlaps active WUI lanes (`c-298`, `c-296`) | r98 7; 1.2 (a) |
| the 10 remaining non-framework Bash groups from r91..r98, other `peer/seats` / `LEASE_*` / prose sites, and the already-served `for refactor round 95` WUI entry-chunk item | unchanged on `f2cb19298`; each stays out for its r91..r98 section 7 reason | r98 7..r91 7; 1.2 (a), (c) |

## 8. Changes

- v0.1 (a-482): the rows and every read on `f2cb19298`; both heads built in detached
  scratch worktrees; the 13-suite column of 1.5 run on base and each row's head;
  `shellcheck -S warning -x` and `do_sec_shellcheck` rc 0; all 7 red and guard controls
  (`rc1a`, `rc1b`, `gc1`, `rc2a`, `rc2b`, `gc2a`, `gc2b`) RED then GREEN; R3 (2.2) and
  R7 (section 4) checked.
- v0.2 (a-482): folds claude panel seat `c-396` FAIL on v0.1 (`e6845b257`, seat file
  `6ab29281b`):
  - **W1:** added per-caller `PF_WUI_URL`/`PF_EMAIL` (`flow-events`, `first-load`) and
    `PFL_WUI_URL`/`PFL_EMAIL` (`first-load-net`, with `PF_*` set to sentinel values)
    stub-node override checks in `spl-wui-perf-flow-events.tst.sh` section 4 and
    `spl-wui-perf-first-load.tst.sh` section 4 (keeping row 02 at 5 files). Verified
    mutations `m2`, `m2_flow`, `m2_fl` all FAIL (1.5).
  - **W2:** added per-action missing-script label checks asserting `FATAL no timing e2e at`
    for `flow-events`/`first-load` and `FATAL no first-load e2e at` for `first-load-net`,
    with node never called. Verified mutations `m3`, `m3_flow`, `m3_fl` all FAIL (1.5).
  - **N1, N4, N5, N6:** fixed all-history grep wording in 1.1 (`0e918d4b9` body quote vs
    windowed count 0 and subject count 0; N1); refreshed R3 lane-map (09:17:27Z, 16
    unknown) and spawn-queue (09:17:32Z, 8 queued) reads in 2.2 (N4); documented the
    standalone vs `./run` stub path in 1.3, 1.4, and section 5 (N5); noted
    `_spl_calendar_require_actor` exclusion in 1.3 (N6). Re-ran all 11 row-02/shared
    suites, `shellcheck -S warning -x`, `do_sec_shellcheck`, `rc2a`/`rc2b`/`gc2a`/`gc2b`,
    and `m2`–`m3_fl` on `f2cb19298` (zero drift on all 10 row/test files to `208e5f757`).

- v1.0 (a-482): recorded cross-vendor panel signature (`c-396` claude PASS on v0.2
  `853b9368f3f58e9b6a175796121c94e4a0674dcd`, seat `a8450306bb192c5b5719209d458974657219b078`,
  `do_spl_review_line_check` rc 0 `74782011`, holder GO `6615a1f0`/`92d045b2`; seat did
  not run `do_sec_shellcheck` or planner-box N2/N3 re-checks). No row, site, batch, test
  hunk, or vendor changed from v0.2.
- **Closed** (a-482, close record, no version bump): both rows landed and verified on
  `origin/master` `be15957aa` (`2026-11-25T12:44Z`, n=1 each; zero drift on all 9 row
  files between each row's land and `be15957aa`):
  - r99-01 `05129cff9` (`05129cff999b8f8de75082f6a4a35434621f83ed`, SPL-6492, author
    `c-540` claude, committed `2026-11-25T14:06:32+02:00`): R7 `a-565` agy **PASS** on
    `70ffbbb69` (`70ffbbb69ca229900243b376f2f1a93c8a25d8e7`, msg `6dace887`;
    `do_spl_review_line_check` rc 0, `OK 10 of 10`); `git patch-id --stable`
    `ec1b6c86672fe3ced7e85b10ea36cedd85b12960` equal on both, `git diff 70ffbbb69
    05129cff9 -- <4 files>` empty (C7). CI on `05129cff9`: push workflows 15
    (`45610957963`), 25 (`45610958076`), 26 (`45610958104`), 64 (`45610957598`), 67
    (`45610958391`) **success**; 4 skipped workflow 12 runs (`45611023474`,
    `45611067112`, `45611104737`, `45611401866`); direct gate 10 (`45610957986`)
    cancelled (superseded by `3646f12ec`). R11 green gate 10: completed run
    `45612708180` on `3646f12ec95930b2fccbfecdcf78c7a2e3ca0376` **success**
    (`git merge-base --is-ancestor 05129cff9 3646f12ec` rc 0). Diff (`git show
    --numstat`, exact 4 files): `orc:src/bash/run/spl-human-link.func.sh` `+10 -2`
    (sha256 `c7392841cb5e`), `orc:src/bash/run/spl-human-email-add.func.sh` `+3 -2`
    (sha256 `bc27dae0a4af`), `orc:src/bash/tests/spl-human-link.tst.sh` `+13 -0`
    (sha256 `8861cb134fce`), `orc:src/bash/tests/spl-human-email-add.tst.sh` `+13 -0`
    (sha256 `54af08d7ff54`), matching plan 1.3 head1 / section 6 verbatim. R7 note
    (`a-565`): N1 commit body cites pre-rebase start sha `ee271d80e` for red controls
    while parent is `fca53c766` (4 files identical, `rc1a`/`rc1b` reproduce on
    `fca53c766`); non-blocking.
  - r99-02 `83a6b0d7d` (`83a6b0d7d6f4b27c40c7c3278b2d362cea4125f5`, SPL-6493, author
    `c-542` claude, committed `2026-11-25T14:03:04+02:00`): R7 `a-562` agy **PASS** on
    `392592f73` (`392592f73f1e083a0c0ab8bb6d904f62c7ce971b`, msg `efa34025`;
    `do_spl_review_line_check` rc 0, `OK 11 of 11`); `git patch-id --stable`
    `e890194c33b1b789e126d4a20c3d3c1ee80eaf69` equal on both, `git diff 392592f73
    83a6b0d7d -- <5 files>` empty (C7). CI on `83a6b0d7d`: all 6 push workflows
    **success** — gate 10 (`45610426566`), 15 (`45610426399`), 25 (`45610426692`), 26
    (`45610426553`), 64 (`45610426349`), 67 (`45610426398`); 5 skipped workflow 12 runs
    (`45610509089`, `45610544523`, `45610565584`, `45610724922`, `45610828242`); also
    covered by R11 green gate 10 run `45612708180` on `3646f12ec` (rc 0). Diff (`git
    show --numstat`, exact 5 files): `orc:src/bash/run/spl-wui-perf-flow-events.func.sh`
    `+24 -13` (sha256 `4c554e0add30`), `orc:src/bash/run/spl-wui-perf-first-load.func.sh`
    `+4 -13` (sha256 `7983dab7a90e`),
    `orc:src/bash/run/spl-wui-perf-first-load-net.func.sh` `+4 -13` (sha256
    `5e82d6661aaf`), `orc:src/bash/tests/spl-wui-perf-flow-events.tst.sh` `+33 -0`
    (sha256 `739e49914c92`), `orc:src/bash/tests/spl-wui-perf-first-load.tst.sh` `+45 -0`
    (sha256 `c19274f92900`), matching plan 1.4 head2 / section 6 verbatim. R7 notes
    (`a-562`): N1-N4 verification notes only (no blocking items).
  - **R5, R6, 2.7.5, and post-land verification on `be15957aa`:** `git merge-base
    --is-ancestor <row> origin/master` rc 0 and box checkout (`be15957aa`) ancestry rc 0
    for both (both `csi-spl-orc` Bash only, no hub or WUI deploy required). R6 (`git log
    origin/master --since="2026-11-25T09:01:01+02:00" --grep='(r99-' --format='%H %cI
    %s'`) returns both rows (`05129cff9`, `83a6b0d7d`) and the 3 plan commits
    (`f8b2d8f1d`, `fb998f15f`, `5e14aeaf1`). Review count (2.7.5): 2 of 2 (`review:
    a-565 agy PASS`, `review: a-562 agy PASS`), both cross-vendor to their claude
    authors; no claude waiver seat was needed. Post-land `git grep` on `be15957aa`
    (`csi-spl-orc/src/bash/run/`): human-operator `ORDERED_BY` + strict 3-digit
    `AGENT_ID` guard copies 2 -> 1 (`_spl_human_require_order` at
    `spl-human-link.func.sh:77`, sole `ORDERED_BY` FATAL at `:79` and strict 3-digit
    `AGENT_ID` FATAL at `:80`; called at `spl-human-link.func.sh:92` and
    `spl-human-email-add.func.sh:105` behind `declare -F _spl_human_require_order` at
    `:104`; `spl-calendar-event-add.func.sh:198` stays separate as noted in 1.3); WUI
    perf timing setup copies 3 -> 1 (`spl_pf_env` at
    `spl-wui-perf-flow-events.func.sh:72`, sole `FATAL no password for ` at `:81` and
    `FATAL no Chrome at ` at `:85` across `spl-wui-perf-*.func.sh`; called at
    `spl-wui-perf-flow-events.func.sh:36`, `spl-wui-perf-first-load.func.sh:40` behind
    `declare -F spl_pf_env` at `:36`, and `spl-wui-perf-first-load-net.func.sh:41` behind
    `declare -F spl_pf_env` at `:37`).
  - **Round close & teardown:** holder `c-002` confirmed both rows ACCEPTED (msg
    `8aa0b57c`). Teardown list: `c-540` (r99-01 author), `c-542` (r99-02 author),
    `a-565` (r99-01 R7), `a-562` (r99-02 R7), `c-396` (panel seat), `a-482` (editor);
    `lane-map.sh` at `12:44Z` shows all 5 non-editor seats already gone. Remote branches
    remaining on `origin` for R8 prune (`PRUNE_SINCE=2026-11-25T09:01:01+02:00`):
    `review/r99-01` (`70ffbbb69`), `review/r99-02` (`392592f73`), and
    `review/c002-refactor-round-99-claude-seat` (`a8450306b`).

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-482 (agy): v0.1, v0.2, v1.0, close record.
- Panel reviewer seat: c-396 (claude, `c002-refactor-round-99-claude-panel-seat`, seat
  `a8450306bb192c5b5719209d458974657219b078` on `review/c002-refactor-round-99-claude-seat`):
  FAIL on v0.1 (`e6845b257`, W1-W2); **PASS** on v0.2
  (`853b9368f3f58e9b6a175796121c94e4a0674dcd`, msgs `a043ca44`/`7d3cf642`; all 9 sha256
  prefixes, all 7 controls, all 6 mutations, 8 shared gates, `shellcheck`, and
  `do_check_dist_hygiene` reproduced; `do_spl_review_line_check` rc 0 confirmed
  `74782011`; `do_sec_shellcheck` and planner-box N2/N3 not run by seat).
- Row R7 seats: section 4; both agy: a-565 (r99-01), a-562 (r99-02) (section 8, round
  closed).
