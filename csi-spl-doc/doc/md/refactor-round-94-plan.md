# Refactoring round 94 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6325  
Topic: 28a5b09d-850e-4674-aa82-053050fb43a0  
Discussion: 28a5b09d-850e-4674-aa82-053050fb43a0 (t1 #refactoring, "Refactor round 94", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r94**, plan `refactor-round-94-plan.md`, rows `r94-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 93 ([refactor-round-93-plan.md](refactor-round-93-plan.md))
is closed: both rows landed on trunk (r93-02 `61eb9d23b`, SPL-6321; r93-01 `65b1bd21a`,
SPL-6320), and its editor c-707 landed the r93 close record `2d4354486` (`Closes: SPL-6317`)
after this plan's window read (1.1).
This planner writes no r93 close record and touches no r93 file. The perf floor
(rulebook 4.4), measured on `65b1bd21a` at 2026-11-23T17:38:52Z (14 days): perf 29,
refactor 107, 21.3%, 5 x 29 = 145 >= 136, floor-met (and measured by the holder c-002
on `61eb9d23b`: perf 29, refactor 106, 21.5%, floor-met), so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91..r93: a
function body that exists twice under two names loses its second copy, and its caller
calls the first.
**Row 01:** `spl-gh-wire.func.sh` (iac) keeps `_sgw_get`, byte-identical to `_gscv_get`
of `gh-set-ci-vars.func.sh` (r93 section 7's first candidate for this round); the copy
goes and `_sgw_apply` loads `gh-set-ci-vars.func.sh` behind a `declare -F` guard and
calls `_gscv_get`.
**Row 02:** `kill-your-self-report.sh` (orc) keeps `ksr_is_seat`, the last remaining
byte-identical copy of `send_role_seat` of `spool-caller.inc.sh` (after r93-01 removed
`lane_is_role_seat`); the copy goes, the script sources `spool-caller.inc.sh` beside
`spool-env.inc.sh`, and `ksr_reviewer` and `ksr_gate` call `send_role_seat`. Neither
row edits its keeper file. The rows share no file: both are batch 1.

**Status: v1.0, signed.** The panel (m-762, mistral) passed v0.1 `cea1ce853` with no W;
N1..N5 are notes only (seat file `csi-spl-doc/doc/md/refactor-round-94/seat-mistral.md`,
branch `review/c002-refactor-round-94-mistral-seat`, `f0ef71764`). Rows run by night
(rulebook 1.4). Editor: **a-756** (agy).

**One sha:** every count is measured on **`65b1bd21a`** (`origin/master` at
2026-11-23T17:37:58Z, r93-01 landed), n=1 per command unless stated. `origin/master`
then moved to `b741e6871` (`2d4354486` r93 close record, `b741e6871` SPL-6319 WUI);
`git diff --name-only 65b1bd21a b741e6871` touches none of this plan's 6 row/keeper
paths, so every site read stands. Reads are on
`65b1bd21a` with `git show` / `git grep`. The tests of 1.5 ran in detached scratch
worktrees of `65b1bd21a` (not committed, removed right after the runs): "base"
unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" = base with row
02 applied in 1.4's shape; each red and guard control (1.5) ran in a detached worktree
of its own. Queue, lane map, brief and branch reads are live state and carry their own
time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-23T17:37:58Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-23T18:16:45+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r93-plan'`:
  `16fbe330e` (`docs(r93-plan, SPL-6317): refactor round 93 plan v0.1 for the panel: ...`),
  read once at the start as 5.3 says (c-707's r93 close record `2d4354486` landed after this read; the window stays the
  recorded one per rulebook 5.3, and `--since` from `2d4354486` is also 0).
- `git log origin/master --since="$W" --oneline -E --grep='\(r94-' | wc -l` -> **0**.
  Over all history -> **1**: `ae4898ae1` (`fix(b29-02-orc-place-panel-seat-digit-suffix, SPL-6093)`),
  dated before `W`, whose commit body quotes a test fixture slug
  `r94-spec-panel-seat-3` from `spl-spawn-queue.tst.sh`; not a round-94 commit.
- `git ls-remote origin 'refs/heads/review/r94-*' 'refs/heads/*-r94-*' 'refs/heads/*refactor-round-94*' 'refs/heads/wip/*r94*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r94|refactor-round-94'` -> this plan's
  brief (`c002-refactor-round-94-planner.md`) and the panel seat's
  (`c002-refactor-round-94-mistral-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-94`
  -> 0: the plain name is free.

### 1.2 The brief's inputs, re-measured

- **(a) r93 section 7:** re-read on `65b1bd21a`.
  - `_gscv_get` / `_sgw_get` (`iac:src/bash/run/gh-set-ci-vars.func.sh:36`,
    `spl-gh-wire.func.sh:92`), left out of r93 as this round's first candidate: measured
    here as **row 01** (1.3).
  - `git diff --stat a7b5ae564 65b1bd21a` (35 files: r93 plan, r93-01 `lane-map.sh` +
    test, r93-02 `channel-move.inc.sh` + test, SPL-5985 `run.sh` + `spl-run-path` Rust
    step + wf 10, SPL-6316 WUI contacts settings, SPL-6323 `spl-cost-split-apply`):
    touches none of r93/r92/r91 section 7's other items, so every one stays out for its
    reason there (section 7).
- **(b) R7 and panel notes:**
  - r93-01 R7 (g-274, body of `65b1bd21a`): N1 author brief absent on reviewer's box
    (process); N2 `csi-spl-doc/specs/172-work-chain-enforcement/spec.md:173` still names
    `lane_is_role_seat` in prose (not a call; doc note, section 7).
  - r93-02 R7 (g-740, body of `61eb9d23b`): N1 test line count 383 vs 382 from section
    banner at `:369`; N2 lib sha256 differs from plan head2 in wording only. Notes only.
  - r93 panel (m-234, `refactor-round-93/seat-mistral.md` on
    `review/c002-refactor-round-93-mistral-seat`, `3f99a8a5c`): PASS on `d2ee35476`,
    no W, notes N1-N5 (process/verification notes only; N5 notes the candidates file is
    not on the other box). No refactor row in any of them.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 115 lines, read 17:37Z):
  unchanged since r93 read it (last entry 2026-11-23 14:2xZ, `i18n-lang-review-exempt.json:2`
  `_doc`, accounted in section 7); every earlier refactor-shaped item is served or
  accounted in r90..r93 section 7; the rest are bug-, test-, doc- or feature-shaped.
- **(d) spec 011 tasks:**
  `git log origin/master --since=2026-11-23T15:28:34Z -- csi-spl-doc/specs/011-spool-project-refactor`
  -> 0; the open tasks (T001-T008 owner-deferred, T018-T021, T023, T027, T034) are each
  wider than one row or await an owner decision.
- **(e) A fresh scan for byte-identical function bodies** on `65b1bd21a` over all 1,203
  tracked `*.sh` files under `csi-spl-orc/src/bash`, `csi-spl-orc/lib`,
  `csi-spl-iac/src/bash`, `csi-spl-utl/src/bash` and `src/bash` (tests and copies of
  `run.sh` / `print-help.func.sh` excluded; `name() { ... }` bodies whitespace-trimmed,
  own name masked, >= 2 lines or 1 line >= 40 chars):
  - **13** groups of 2+ lines: 10 are r91..r93 section 7 items (unchanged, reasons hold),
    and 3 are not yet served:
    - `_gscv_get` / `_sgw_get` (2 body lines, iac): **row 01** (1.3, from r93 section 7).
    - `send_role_seat` / `ksr_is_seat` (2 body lines, orc `spawn-agents`): **row 02** (1.4).
    - `smh_hooks_json` / `spl_desk_mirror_settings_json` (7 body lines, orc): third
      candidate, left for r95 in section 7 (shellcheck baseline and direct test call
      noted there).
  - A companion scan of 944 non-test Go files under `csi-spl-api/src/go/spool-hub-api`
    found small cross-package / store / `keyd`-`lockkey` helpers (section 7: cross-package
    or store-tier, left out here).

### 1.3 Row 01's site: `spl-gh-wire.func.sh`'s own repo-variable read goes

`iac:` = `csi-spl-iac/`. On `65b1bd21a`:

- `iac:src/bash/run/spl-gh-wire.func.sh:90-96`: 2-line comment (`:90-91`), `_sgw_get`
  (`:92-95`, body `:93-94`) and blank `:96`; called twice in `_sgw_apply`, at `:105`
  and `:114`.
- `iac:src/bash/run/gh-set-ci-vars.func.sh:34-39`: the same 2-line comment (`:34-35`)
  and `_gscv_get` (`:36-39`, body `:37-38`), called at `:46` and `:55`.
  `diff -u <(sed -n 34,39p gh-set-ci-vars.func.sh) <(sed -n 90,95p spl-gh-wire.func.sh | sed 's/_sgw_get/_gscv_get/')`
  -> no hunk (rc 0, n=1): comment and function are **byte-identical** but for the name.
- `gh-set-ci-vars.func.sh` came first (`25e1254fb`, 2026-10-04T11:32:02+03:00;
  `spl-gh-wire.func.sh` `6fa7d5959`, 2026-10-04T11:43:24+03:00), and
  `orc:src/bash/run/route-ci-overflow.func.sh:109-110` already sources
  `gh-set-ci-vars.func.sh` behind a `declare -F` guard: `gh-set-ci-vars.func.sh` is the
  keeper, so `_sgw_get` goes.
- `git grep -nE '_gscv_get|_sgw_get' 65b1bd21a -- ':!*.md'` -> only the 2 definitions
  and 4 calls above; no test names either.
- `gh-set-ci-vars.func.sh` has no top-level code (functions only) and defines only
  `do_gh_set_ci_vars` and `_gscv_*`; none collides with `spl-gh-wire.func.sh`
  (`grep -nE '_gscv_|do_gh_set_ci_vars' spl-gh-wire.func.sh` -> 0) or with
  `spl-gh-wire.tst.sh`'s stubs (`do_log`, `gh`, `gcloud`).
- Who loads `spl-gh-wire.func.sh`: `./run` (the lazy loader) and `spl-gh-wire.tst.sh:29,106`
  (sources `$PROJ_ROOT/src/bash/run/spl-gh-wire.func.sh` directly, no temp-dir copy).
  Putting the guard inside `_sgw_apply` protects both `do_spl_gh_wire` and any direct
  call of `_sgw_apply` when the file is sourced alone. `_sgw_apply` goes from 20 to 23
  lines (cap 75, `bash-cleancode.tst.sh`).

Shape (built as head1 of 1.5):
- `iac:src/bash/run/spl-gh-wire.func.sh`: `:90-96` go; in `_sgw_apply`, before the
  first read (`:105` on base) add 3 lines: a 1-line comment (read one repo variable via
  `_gscv_get` of `gh-set-ci-vars.func.sh`, its one copy),
  `# shellcheck source=gh-set-ci-vars.func.sh`, and
  `declare -F _gscv_get >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/gh-set-ci-vars.func.sh"`;
  both calls (`:105`, `:114` on base) become `have="$(_gscv_get "$repo" "$name")"`.
  150 -> 146 lines (`+5 -9`).
- `iac:src/bash/tests/spl-gh-wire.tst.sh`: add 1 header line after `:19` (`9. one copy: ...`)
  and 6 lines before `# --- CONTROLs` (`:179` on base): `spl-gh-wire.func.sh` holds no
  `_sgw_get` and no `actions/variables/` line, and calls `_gscv_get "$repo" "$name"`.
  189 -> 196 lines (`+7 -0`).
- head1's files, sha256 (12 chars): func `52ffd2f53550`, test `ac01a5e55120`.
- Note for the row and its reviewer: build any red/guard control in a worktree, not a
  copy of `spl-gh-wire.func.sh` in a temp dir: the guard loads its sibling by
  `dirname "${BASH_SOURCE[0]}"`.

**Behaviour:** `_gscv_get` has the deleted `_sgw_get` body byte for byte, called with
the same `"$repo" "$name"`; cases 0-8 and both CONTROLs of `spl-gh-wire.tst.sh` pass on
base and head1 with the same counts (1.5).

### 1.4 Row 02's site: `kill-your-self-report.sh`'s own role-seat check goes

`sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`. On `65b1bd21a`:

- `sa:scripts/kill-your-self-report.sh:147-153`: 2-line comment (`:147-148`),
  `ksr_is_seat` (`:149-152`, body `:150-151`) and blank `:153`; called twice: `:156` in
  `ksr_reviewer` (`ksr_is_seat "$1" && return 0`) and `:178` in `ksr_gate`
  (`if ksr_is_seat "${ID%@*}"; then`). The script already sets `_here` via `readlink -f`
  at `:63` and sources `$_here/../lib/spool-env.inc.sh` (`:65`), `agent-state.inc.sh`
  (`:67`) and `lane-issue.inc.sh` (`:69`).
- `sa:lib/spool-caller.inc.sh:8-12`: comment (`:8`) and `send_role_seat` (`:9-12`, body
  `:10-11`).
  `diff -u <(sed -n 9,12p spool-caller.inc.sh | sed 's/  # ID//') <(sed -n 149,152p kill-your-self-report.sh | sed 's/ksr_is_seat/send_role_seat/; s/  # ID (bare)//')`
  -> no hunk (rc 0, n=1): body is **byte-identical**. `send_role_seat` is the shared
  home (SPL-5136 `bf414adef`), already called by `spool-send.sh:172,176,236`,
  `spl-sender-audit.func.sh:125` and `lane-map.sh:80` (r93-01 `65b1bd21a`);
  `ksr_is_seat` is the last remaining byte-identical copy in the tree (section 7 checks
  the other 3 `LEASE_(MASTER|FAILOVER|ORCH)` sites, which use different variables).
- `spool-caller.inc.sh` has one top-level line (`:6`, `_spool_caller_dir`), needs
  `spool-env.inc.sh` first (already sourced at `:65`), and defines only
  `send_role_seat`, `send_caller_chain`, `send_caller_env_id`, `send_caller_pane_id`,
  `send_caller_id`, `send_chain_caller`: none collides with `kill-your-self-report.sh`,
  `agent-state.inc.sh` or `lane-issue.inc.sh` (`grep -nE '_spool_caller_dir|send_(role_seat|caller_|chain_caller)'` -> 0).
- `git grep -n 'ksr_is_seat' 65b1bd21a -- ':!*.md'` -> only the 1 definition and 2 calls
  above (`git grep -n 'ksr_is_seat' 65b1bd21a -- '*.md'` -> 0).
- Who runs `kill-your-self-report.sh`: `/exit-clean` and `/kill-your-self`,
  `tmux-close-window.sh:647`, `test-kill-your-self-gate.sh`, `test-kill-your-self-report.sh`,
  `test-kill-your-self-result.sh`, and `test-lane-issue.sh` (whose `$CTL` copy at `:59`
  copies both `$T_FEAT/scripts` and `$T_FEAT/lib`, so `$_here/../lib/spool-caller.inc.sh`
  resolves there too). `enc-dirs-untouched.tst.sh:57` scans it as a W-reader (no
  `encrypted/` path or recursive walk added).

Shape (built as head2 of 1.5):
- `sa:scripts/kill-your-self-report.sh`: after `:69` add 2 lines:
  `# shellcheck source=../lib/spool-caller.inc.sh` and
  `. "$_here/../lib/spool-caller.inc.sh"`; replace `:147-153` with a 1-line comment
  (`# Role-seat ids live in send_role_seat of spool-caller.inc.sh (their one copy).`);
  replace both calls (`:156`, `:178` on base) with `send_role_seat "$1"` and
  `send_role_seat "${ID%@*}"`. 313 -> 309 lines (`+5 -9`).
- `sa:tests/test-kill-your-self-gate.sh`: after `:131` (the `c-002` role-seat rotation
  check; `:120-121` already covers the `LEASE_MASTER=c-777` `ksr_reviewer` path) add 5
  lines (blank, comment, `own`, `calls` on non-comment lines, `eq`): `"$R"` holds no
  `ksr_is_seat` and no `LEASE_(MASTER|FAILOVER|ORCH)` line, and makes 2 non-comment
  calls to `send_role_seat`. 157 -> 162 lines (`+5 -0`).
- head2's files, sha256 (12 chars): script `0b4355d6242a`, test `a9be7f6850a3`.

**Behaviour:** `send_role_seat` has the deleted `ksr_is_seat` body byte for byte, with
the same bare agent id argument; both `ksr_reviewer` (`LEASE_MASTER=c-777`, `c-001`,
`c-002`) and `ksr_gate` (`c-002` rotation) paths pass on base and head2 with identical
counts (1.5).

### 1.5 Before and on the rows' heads

2026-11-23T17:42:53Z-17:51:00Z (the full 20-suite column on base, head1 and head2, plus
rc1/gc1) and 17:52:07Z-17:52:20Z (updated head2 one-copy check excluding comment lines,
plus rc2/gc2/gc1 detail), n=1, as the push user, `SPOOL_TEST=1` with `SPOOL_BOX_TAG`
and `SPOOL_AGENT_ID` unset, `timeout 900` each; pass lines `grep -ciE '^ *(ok|pass)'`,
fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to base: same rc, pass and
fail counts.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `iac:src/bash/tests/spl-gh-wire.tst.sh` | 01 | 0 / 17 / 0 | 0 / 18 / 0 (case 9 adds 1) | = |
| `iac:src/bash/tests/gh-set-ci-vars.tst.sh` | 01 | 0 / 14 / 0 | = | = |
| `iac:src/bash/tests/git-env-isolation.tst.sh` | 01 | 0 / 7 / 0 | = | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01 | 0 / 17 / 0 | = | = |
| `orc:src/bash/tests/route-ci-overflow.tst.sh` | 01 | 0 / 38 / 0 | = | = |
| `sa:tests/test-kill-your-self-gate.sh` | 02 | 0 / 36 / 0 | = | 0 / 37 / 0 (one-copy adds 1) |
| `sa:tests/test-kill-your-self-report.sh` | 02 | 0 / 31 / 0 | = | = |
| `sa:tests/test-kill-your-self-result.sh` | 02 | 0 / 20 / 0 | = | = |
| `sa:tests/test-lane-issue.sh` | 02 | 0 / 206 / 0 | = | = |
| `sa:tests/test-spool-send-from-guard.sh` (keeper's user) | 02 | 0 / 28 / 0 | = | = |
| `orc:src/bash/tests/sender-audit.tst.sh` (keeper's user) | 02 | 0 / 35 / 0 | = | = |
| `orc:src/bash/tests/lane-map.tst.sh` (keeper's user) | 02 | 0 / 149 / 0 | = | = |
| `orc:src/bash/tests/enc-dirs-untouched.tst.sh` | 02 | 0 / 18 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |

`shellcheck -S warning -x` on the 4 row files, base, head1 and head2: rc 0, no findings
(n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `65b1bd21a`):
- Row 01 red control (`rc1`, head1's `spl-gh-wire.tst.sh` on base): rc 1, 16 pass, 1 fail,
  `FAIL: 9. one copy: spl-gh-wire.func.sh keeps its own variable read, or no call of _gscv_get: 92:_sgw_get() {  # <repo> <name> 93:  local v; ... 105:  have="$(_sgw_get "$repo" "$name")" 114:  have="$(_sgw_get "$repo" "$name")"`;
  head1: rc 0, 18 pass, 0 fail.
- Row 01 guard control (`gc1`, head1 with the `declare -F _gscv_get` line deleted):
  rc 3, 15 pass, 3 fail (`FAIL: 3. set`, `FAIL: 3. re-run`, `FAIL: 4. update`), with
  `.../spl-gh-wire.func.sh: line 100: _gscv_get: command not found` and `line 109: _gscv_get: command not found`.
- Row 02 red control (`rc2`, head2's `test-kill-your-self-gate.sh` on base): rc 1, 36
  pass, 1 fail,
  `FAIL - one copy: kill-your-self-report.sh keeps no ksr_is_seat and calls send_role_seat twice (want '|2', got '149:ksr_is_seat() {  # ID (bare) ...')`;
  head2: rc 0, 37 pass, 0 fail.
- Row 02 guard control (`gc2`, head2 with the `spool-caller.inc.sh` source line deleted):
  rc 1, 25 pass, 12 fail (including `a refusal is one line`, `a peer REJECT after ACCEPTED`,
  `holder REJECT after ACCEPTED` x2, `the same id as the lease.conf dispatch holder: runs`,
  `the rotation retires a role seat: runs`), with
  `.../kill-your-self-report.sh: line 149: send_role_seat: command not found`.

The tests that name the sites (R2): `git grep -lE` over `*/tests/*` and `*shard-weights*`
for `spl-gh-wire|gh-set-ci-vars|_sgw_get|_gscv_get|do_spl_gh_wire|do_gh_set_ci_vars` ->
`spl-gh-wire.tst.sh`, `gh-set-ci-vars.tst.sh`, `git-env-isolation.tst.sh`,
`route-ci-overflow.tst.sh` (plus iac gates `no-box-path-source`, `action-header-tags`,
`param-required`, `run-lazy-loader`, `bash-cleancode`); for
`kill-your-self-report|ksr_is_seat|send_role_seat|spool-caller` ->
`test-kill-your-self-gate.sh`, `test-kill-your-self-report.sh`,
`test-kill-your-self-result.sh`, `test-lane-issue.sh`, `enc-dirs-untouched.tst.sh`,
`lane-map.tst.sh`, `channel-move-plan.tst.sh` (plus `spool-caller`'s other users
`test-spool-send-from-guard.sh` and `sender-audit.tst.sh`, and the shared orc/iac gates
above). No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r94-01-iac-gh-wire-var-get)` | one fact, one copy (developer guide 2.2.4) | `spl-gh-wire.func.sh` keeps `_sgw_get`, a byte-identical copy of `_gscv_get` of `gh-set-ci-vars.func.sh` (1.3, r93 section 7) | `iac:src/bash/run/spl-gh-wire.func.sh:90-96,105,114`<br>`iac:src/bash/tests/spl-gh-wire.tst.sh` (header, case 9) | definitions of the GitHub Actions variable read body 2 -> 1 | 1.3's shape. **Red control:** the head's test on the parent FAILs case 9 (1.5), then GREEN; the guard control (the `declare -F _gscv_get` line deleted: 3 checks fail, `3. set`, `3. re-run`, `4. update`, with `_gscv_get: command not found`), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with the same counts but case 9. Tests: `iac:.../spl-gh-wire.tst.sh`, `gh-set-ci-vars.tst.sh`, `git-env-isolation.tst.sh`, `no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `orc:.../route-ci-overflow.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r94-02-orc-ksr-role-seat)` | one fact, one copy (developer guide 2.2.4) | `kill-your-self-report.sh` keeps `ksr_is_seat`, the last byte-identical copy of `send_role_seat` of `spool-caller.inc.sh` (1.4) | `sa:scripts/kill-your-self-report.sh:69,147-153,156,178`<br>`sa:tests/test-kill-your-self-gate.sh` (1 check after `:131`) | definitions of the role-seat check body 2 -> 1 | 1.4's shape. **Red control:** the head's test on the parent FAILs the one-copy check (1.5), then GREEN; the guard control (the `spool-caller.inc.sh` source line deleted: 12 checks fail with `send_role_seat: command not found`); outputs in the body. **Behaviour:** the column passes on parent and head with the same counts but the new check. Tests: `sa:tests/test-kill-your-self-gate.sh`, `test-kill-your-self-report.sh`, `test-kill-your-self-result.sh`, `test-lane-issue.sh`, `test-spool-send-from-guard.sh`, `orc:.../sender-audit.tst.sh`, `lane-map.tst.sh`, `enc-dirs-untouched.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r94-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r94-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row removes a copy and points its caller at the other; no output, exit
code, path or file a caller sees changes (1.3, 1.4, 1.5). Each:
`Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-iac`
  `spl-gh-wire.func.sh` and its test; row 02: `csi-spl-orc` `kill-your-self-report.sh`
  and `test-kill-your-self-gate.sh`).
- No row edits `iac:src/bash/run/gh-set-ci-vars.func.sh` or its test (row 01's keeper),
  `sa:lib/spool-caller.inc.sh` (row 02's keeper), `sa:lib/spool-env.inc.sh`,
  `sa:lib/agent-state.inc.sh`, `sa:lib/lane-issue.inc.sh`, `sa:scripts/lane-map.sh`,
  `sa:scripts/spool-send.sh`, `orc:src/bash/run/route-ci-overflow.func.sh`,
  `orc:src/bash/run/spl-sender-audit.func.sh`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (6): `iac:src/bash/run/spl-gh-wire.func.sh`, `iac:src/bash/tests/spl-gh-wire.tst.sh`,
keeper `iac:src/bash/run/gh-set-ci-vars.func.sh`; `sa:scripts/kill-your-self-report.sh`,
`sa:tests/test-kill-your-self-gate.sh`, keeper `sa:lib/spool-caller.inc.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent a-756`, one call per
  path, n=1, 2026-11-23T17:40:51Z-17:41:11Z: **exit 4 on all 6** ("no live lane lists
  <path>, but 9 live lane(s) record no files"). The 9 `unknown:` lanes, all on the
  other box (`lane-map.sh list --all`, 17:41:12Z): the private-channel seats c-029,
  c-041, c-146, c-187, c-924, c-927 (`*-rotate`), the workspace seat c-086 (`*-rotate`),
  spec 181 row B2 c-261 (hub Go) and spec 181 row B12 c-279 (rdb + hub Go). No lane is
  reported as owning any of the 6; none of those scopes touches `iac/src/bash/run` or
  `kill-your-self-report.sh`.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 17:38:17Z-17:38:47Z):
  8 queued, 0 placing: this round's mistral panel seat (`c002-refactor-round-94-mistral-panel-seat`),
  the queued cloud-costs page bug (ask 43048246), and 6 spec 181 feature rows
  (B3, B13, B7, B8, B9, B11, 5 held on prerequisites). None names a row path. Share
  line: refactor 4 of 20 known live lanes, 20% (band 10-20%: ok); phase day; last 24 h
  14% (band 20-30%: UNDER).
- **Briefs on this box** changed in the last 24 h (124) naming a row file or function
  (`grep -lE 'spl-gh-wire|do_spl_gh_wire|_sgw_get|_gscv_get|gh-set-ci-vars|ksr_is_seat|test-kill-your-self-gate|kill-your-self-report\.sh|spool-caller\.inc\.sh'`,
  17:40:49Z): **4**, only the landed r93-01 / r93-02 briefs and their reviewers (which
  name `spool-caller.inc.sh` as keeper / off limits). None live.
- **Remote branches committed in the last 24 h** (17 besides master after
  `git fetch --prune origin`, 17:40:49Z-17:41:04Z):
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 6 paths>` ->
  **0 hits**.
- **Commits in the last 24 h** on those 6 paths (`git log origin/master --since='24 hours ago'`)
  -> **0**.
- **Live or landed lanes named in the brief:** r93-01 c-727 (landed `65b1bd21a`),
  r93-02 c-259 (landed `61eb9d23b`, done), r93 editor c-707 (r93 plan doc only),
  SPL-5985 c-712 (landed `b09bdbeb6`, `ef80e6a01`), SPL-6323 c-264 (landed `1356c11a2`,
  done), `TestContactsSyncLogsNoValues` flake c-738 + g-757 (Go api test), spec 181 B2
  c-261 + g-754 and B12 c-279 + queued B3/B7/B8/B9/B11/B13, spec 181 v0.7 a-749,
  SPL-6318 a-729 + c-736 (spec 071), SPL-6319 a-731 + g-280 (WUI contact delete dialog),
  queued cloud-costs page bug (ask 43048246), the private-channel seats and c-086:
  none on a row path.

## 3. Per row: what the lane does

- **r94-01:** `spl-gh-wire.func.sh`'s `_sgw_apply` reads GitHub Actions repo variables
  through `_gscv_get` of `gh-set-ci-vars.func.sh`, its one copy, loaded behind a
  `declare -F` guard when the file is sourced alone. Case 9 of `spl-gh-wire.tst.sh`
  proves the copy is gone; cases 1, 3, 4 and the guard control prove the guard loads it.
- **r94-02:** `kill-your-self-report.sh`'s `ksr_reviewer` and `ksr_gate` check role-seat
  ids through `send_role_seat` of `spool-caller.inc.sh`, the one copy, sourced beside
  `spool-env.inc.sh`. The new check of `test-kill-your-self-gate.sh` proves `ksr_is_seat`
  is gone; the `LEASE_MASTER=c-777` and `c-002` checks and the guard control prove the
  source line loads it.

## 4. Panel and reviewers (R7)

- Editor: a-756 (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the mistral seat `c002-refactor-round-94-mistral-panel-seat` (queued 1/8 at
  17:38:17Z, live as m-762 at 17:56Z). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-23T17:38:52Z printed
  `pick=<box> reason=<box> is the first box in order below its low mark (68% < 70%)`,
  grok weekly 71% on both boxes: **a grok R7 seat per row**. The rows run by night
  (rulebook 1.4); the holder re-runs the pick when it places them, and a hold then gives
  the row a **claude waiver seat**, as r90..r93's section 4 say. Never a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r94-01 | `c002-r94-01-iac-gh-wire-var-get` | `refactor(r94-01-iac-gh-wire-var-get, SPL-<row issue>): ...` | `review/r94-01` | 1 |
| r94-02 | `c002-r94-02-orc-ksr-role-seat` | `refactor(r94-02-orc-ksr-role-seat, SPL-<row issue>): ...` | `review/r94-02` | 1 |

**r94-01 brief, Files: ONLY**
`csi-spl-iac/src/bash/run/spl-gh-wire.func.sh` (`:90-96` go; in `_sgw_apply`, comment,
`# shellcheck source=gh-set-ci-vars.func.sh`, `declare -F _gscv_get` guard before the
first read; both `_sgw_get` calls at `:105`, `:114` renamed to `_gscv_get`) and
`csi-spl-iac/src/bash/tests/spl-gh-wire.tst.sh` (header line and case 9). NOT
`gh-set-ci-vars.func.sh` or its test, NOT `route-ci-overflow.func.sh` or any other test.
Do: plan section 2 row 01 verbatim, 1.3's shape; the red control (the head's test on the
parent) RED then GREEN in the body; the guard control (the `declare -F _gscv_get` line
deleted: 3 checks fail, built in a worktree, not a temp-dir copy). Gates: the row's
tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 2
files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r94-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spawn-agents/scripts/kill-your-self-report.sh` (source
`spool-caller.inc.sh` after `:69`; `:147-153` replaced by 1-line comment; `:156` and
`:178` call `send_role_seat`) and
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-kill-your-self-gate.sh` (one-copy
check after `:131`). NOT `spool-caller.inc.sh`, `spool-env.inc.sh`, `agent-state.inc.sh`,
`lane-issue.inc.sh`, `lane-map.sh`, `spool-send.sh` or any other test. Do: plan section
2 row 02 verbatim, 1.4's shape; the red control (the head's test on the parent) RED then
GREEN in the body; the guard control (the `spool-caller.inc.sh` source line deleted: 12
checks fail) RED. Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| definitions of the GitHub Actions variable read body (1.3) | 2 on `65b1bd21a` (`_gscv_get`, `_sgw_get`) -> 1 after row 01 |
| definitions of the role-seat check body (1.4) | 2 on `65b1bd21a` (`send_role_seat`, `ksr_is_seat`) -> 1 after row 02 |
| lines (`git diff --numstat` of each head) | row 01: func +5 -9, test +7 -0; row 02: script +5 -9, test +5 -0 |
| measured on | `65b1bd21a`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `smh_hooks_json` / `spl_desk_mirror_settings_json` (`sa:lib/spool-mirror-hooks.inc.sh:30-38`, `orc:src/bash/run/spl-desk-mirror-settings.func.sh:41-49`, 7-line Python hooks JSON builder, byte-identical) | third candidate: this round aims at 2 rows (5.1), so it is the next refactor round's first candidate; note for r95: `spool-mirror-hooks.inc.sh` carries 4 baseline shellcheck warnings (`.shellcheck-warning-baseline.txt:51-52`: `SC2034` x2, `SC2088` x2) and `desk-mirror-actions.tst.sh:115` calls `spl_desk_mirror_settings_json` directly, so the wrapper/load and shellcheck-x behaviour need measuring there | 1.2 (e); `diff -u` rc 0; `shellcheck -S warning -x spool-mirror-hooks.inc.sh` rc 1 |
| other `LEASE_(MASTER|FAILOVER|ORCH)` sites (`sa:scripts/lane-age-report.sh:33`, `orc:src/bash/run/spl-box-leave.func.sh:298`, `orc:src/bash/run/spl-lane-backfill-links.func.sh:78`) | not byte-identical to `send_role_seat`: each reads a different path var (`$R`, `$LEASE_CONF`, `${SPOOL_ROOT:-/var/spool-hub}`) | `git grep -nE 'LEASE_\(MASTER\|FAILOVER\|ORCH\)' 65b1bd21a -- ':!*.md'` |
| `_gscv_repo` / `_sgw_repo` (`gh-set-ci-vars.func.sh:28-32`, `spl-gh-wire.func.sh:49-53`) and `_gscv_apply` / `_sgw_apply` (`:46-57` vs `:105-116`) | near-identical (`GH_CI_VARS_REPO` vs `GH_WIRE_REPO`; shared apply tail after per-action validation): needs a parameterised helper shape, not measured here; candidate after r94-01 lands | read on `65b1bd21a` |
| `csi-spl-doc/specs/172-work-chain-enforcement/spec.md:173` (r93-01 R7 g-274 N2) | prose naming `lane_is_role_seat`, not code | `git grep -n lane_is_role_seat 65b1bd21a -- csi-spl-doc/specs/` -> 1 line |
| `i18n-lang-review-exempt.json:2` `_doc` (candidates file, r93 section 7) | doc string in a WUI data file, not a code copy; unchanged since `a7b5ae564` | 1.2 (a), (c) |
| Go duplicate helpers in `csi-spl-api/src/go/spool-hub-api` (`internal/store`: `checkContactIDs`/`checkNoteIDs`, `contactPGErr`/`notePGErr`, `nullStr`/`nullText`/`nullIfEmpty`; `keyd`/`lockkey`: `readPID`, `harden`, `Wipe`) | cross-package or store/security-tier (`PRE_PUSH_TIER=full` Postgres gate, plus live contacts/spec-181 store lanes): not measured here | 1.2 (e) |
| every other r93 / r92 / r91 section 7 item (the 10 remaining 2+ line Bash groups and the 1-line groups) | unchanged since `a7b5ae564` (1.2 (a)), each stays out for its reason there | r93 7, r92 7, r91 7; 1.2 (a), (e) |

## 8. Changes

- v0.1 (a-756): the rows and every read on `65b1bd21a`; both heads built in detached
  scratch worktrees; the 20-suite column of 1.5 run on base and both heads; the red and
  guard controls RED; R3 (2.2) and R7 (section 4) checked.
- v1.0 (a-756): the panel seat m-762 (mistral) **PASS** on `cea1ce853`
  (`cea1ce85384702249cbfc1c4b8d5703aa47d0f7d`), no W, notes N1..N5 (msgs `3fb9812d`,
  `fdf97e1e`; seat file `refactor-round-94/seat-mistral.md` on
  `review/c002-refactor-round-94-mistral-seat`, `f0ef71764`). Its review line passed the
  holder c-002's `do_spl_review_line_check` at 18:4xZ: rc 0 (`OK 2 of 2 named in ran: are
  commands in` vibe session log `unified/7f4aef21-fb62-4b10-98f3-1042ce8b0c43`, reviewer
  m-762; holder GO msg `53720109`). Notes folded (no row change):
  - N1: the seat built its own heads in scratch worktrees from 1.3 / 1.4; line counts
    match (146 / 196 / 309 / 162; head2 script sha256 `0b4355d6242a` matches, the other 3
    differ in comments/wording only) and every red and guard control fails with the plan's
    quoted lines and counts (`gc2` at line 151 vs 149 from the 2-line source insert
    position).
  - N2: `origin/master` moved `65b1bd21a` -> `2d4354486` (r93 close record) during the
    review and is `a4d7dd474` at v1.0; `git diff --name-only 65b1bd21a origin/master --
    <the 6 paths>` is empty (re-read 18:41Z), so every site stands.
  - N3: the lane map at the seat's read exited 4 with 10 unknown-scope lanes (vs 9 at
    17:41Z), 0 hits on the 6 paths either way; row lanes re-run R3 at spawn.
  - N4: `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at the seat's reads printed grok
    weekly 71% on both boxes (`reason=every box is at or above its high mark`), vs
    `68% < 70%` at 17:38:52Z; a grok R7 seat per row holds (or the claude waiver seat if
    the pick holds at placement, never mistral).
  - N5: the candidates file (115 lines) was re-checked claim by claim against the tree;
    none is left unserved and unaccounted.
  Text unchanged except the status line and sections 8 and 9.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-756 (agy): v0.1, v1.0.
- Panel reviewer seat: m-762 (mistral, `c002-refactor-round-94-mistral-panel-seat`):
  **PASS** on v0.1 (`cea1ce853`), no W, notes N1-N5. Seat file
  `refactor-round-94/seat-mistral.md` (`review/c002-refactor-round-94-mistral-seat`,
  `f0ef71764`, section 8).
- Row R7 seats: section 4.
