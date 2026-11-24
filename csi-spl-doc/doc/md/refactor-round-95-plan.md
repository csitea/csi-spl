# Refactoring round 95 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6348  
Topic: 7b9519dd-272f-4862-b55a-0c8b9cd36c1b  
Discussion: 7b9519dd-272f-4862-b55a-0c8b9cd36c1b (t1 #refactoring, "Refactor round 95", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r95**, plan `refactor-round-95-plan.md`, rows `r95-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 94 ([refactor-round-94-plan.md](refactor-round-94-plan.md))
is closed: both rows landed on trunk (r94-01 `ffe718a28`, SPL-6332; r94-02 `70f05ea48`,
SPL-6334), and its editor a-756 landed the r94 close record `0075d4923` (`Closes: SPL-6325`).
This planner writes no r94 close record and touches no r94 file. The perf floor
(rulebook 4.4), measured on `c4000b25b` at 2026-11-24T06:06:02Z (14 days): perf 29,
refactor 97, 23.0%, 5 x 29 = 145 >= 126, floor-met (matching the holder c-002's read on
`11c6582fc`), so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91..r94: a
byte-identical body that exists in two places loses its second copy, and its caller calls
the single home.
**Row 01:** `spl-desk-mirror-settings.func.sh` (orc) keeps `spl_desk_mirror_settings_json`
with a 7-line Python hooks JSON builder that is byte-identical to `smh_hooks_json` of
`spool-mirror-hooks.inc.sh` (r94 section 7's first candidate for this round); the inline
Python heredoc goes, and `spl_desk_mirror_settings_json` loads `spool-mirror-hooks.inc.sh`
behind a `declare -F` guard and delegates to `smh_hooks_json "$1"` (keeping its keeper
file untouched).
**Row 02:** after r94-01 landed `_gscv_get`, `_sgw_apply` (`spl-gh-wire.func.sh`) and
`_gscv_apply` (`gh-set-ci-vars.func.sh`) still share a 12-line byte-identical GitHub
Actions repo-variable read / dry-run / `gh variable set` / read-back tail (r94 section 7's
third candidate, eligible now that r94-01 landed); `gh-set-ci-vars.func.sh` extracts that
12-line body into `_gscv_set`, `_gscv_apply` calls it after JSON validation, and
`_sgw_apply` loads `gh-set-ci-vars.func.sh` behind a `declare -F _gscv_set` guard and
calls `_gscv_set` after its own output validation. The rows share no file (orc vs iac):
both are batch 1.

**Status: v1.0, signed; round closed (section 8).** The panel (m-969, mistral) passed v0.1
`62e2af0eb` with no W; N1..N3 are notes only (seat file
`csi-spl-doc/doc/md/refactor-round-95/seat-mistral.md`, branch
`review/c002-refactor-round-95-mistral-seat`, `ad6f07792`). Rows run by night
(rulebook 1.4). Editor: **a-967** (agy).

**One sha:** every count is measured on **`c4000b25b`** (`origin/master` at
2026-11-24T06:06:02Z), n=1 per command unless stated. Reads are on `c4000b25b` with
`git show` / `git grep`. The tests of 1.5 ran in detached scratch worktrees of
`c4000b25b` (not committed, removed on exit): "base" unmodified, "head1" = base with
row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's shape; each
red and guard control (1.5) ran in a detached worktree of its own. Queue, lane map,
brief and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-24T06:06:02Z, n=1, after a fresh fetch (`git-fetch-fresh.sh --force`):

- **Window: W=2026-11-23T22:49:00+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r94-plan'`:
  `0075d4923` (`docs(r94-plan, SPL-6325): refactor round 94 closed: r94-01 ffe718a28 and r94-02 70f05ea48 landed, grok R7 PASS each on the reviewed head (patch-id equal)`),
  read once at the start as 5.3 says.
- `git log origin/master --since="$W" --oneline -E --grep='\(r95-' | wc -l` -> **0**
  (over all history -> **0**).
- `git ls-remote origin 'refs/heads/review/r95-*' 'refs/heads/*-r95-*' 'refs/heads/*refactor-round-95*' 'refs/heads/wip/*r95*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r95|refactor-round-95'` -> this plan's
  brief (`c002-refactor-round-95-planner.md`) and the panel seat's
  (`c002-refactor-round-95-mistral-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-95`
  -> **0**: the plain name is free.

### 1.2 The brief's inputs, re-measured

- **(a) r94 section 7:** re-read on `c4000b25b`.
  - `smh_hooks_json` / `spl_desk_mirror_settings_json`
    (`sa:lib/spool-mirror-hooks.inc.sh:30-38`,
    `orc:src/bash/run/spl-desk-mirror-settings.func.sh:41-49`), left out of r94 as this
    round's first candidate: measured here as **row 01** (1.3, including its shellcheck-x
    and direct-test behaviour).
  - `_gscv_apply` / `_sgw_apply` 12-line byte-identical apply tail
    (`iac:src/bash/run/gh-set-ci-vars.func.sh:46-57`,
    `iac:src/bash/run/spl-gh-wire.func.sh:101-112`), noted in r94 section 7 as eligible
    after r94-01 landed: measured here as **row 02** (1.4). `_gscv_repo` / `_sgw_repo`
    (different env var names `GH_CI_VARS_REPO` vs `GH_WIRE_REPO`) stays in section 7 so
    row 02 stays a pure byte-identical copy removal with one guarded load.
  - `git diff --name-only 65b1bd21a c4000b25b` (177 files: r94 plan & rows `ffe718a28` /
    `70f05ea48`, b42 plan & `c41b7080e`, SPL-6342 WUI entry-chunk cut `c68cca820`..`e62b847c3`,
    SPL-6347 `/tmp` worktree reap `5e77f4c8b`..`11c6582fc`, spec 181 B3/B7/B8/B9/B12/v0.7,
    SPL-6239 T5/T6, SPL-6318 T10/T11, SPL-6337, SPL-6339, SPL-6346): touches none of
    r94/r93/r92/r91 section 7's other items, so each stays out for its reason there
    (section 7).
- **(b) R7 and panel notes:**
  - r94-01 R7 (`g-788`, commit `ffe718a28`): N1 sha256 differs from plan head1 in comment
    and case-9 wording only (lines 146 / 196 match); `NOT RUN do_check_pre_push` noted
    (author ran it rc 0). Notes only.
  - r94-02 R7 (`g-811`, commit `70f05ea48`): PASS, no change notes.
  - r94 panel (`m-762`, `refactor-round-94/seat-mistral.md` on
    `review/c002-refactor-round-94-mistral-seat`, `f0ef71764`, recorded in r94 plan v1.0):
    PASS on `cea1ce853`, no W, N1..N5 process/verification notes only. No refactor row in
    any of them.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 131 lines, read 06:05Z): 5 new
  blocks since r94 read it (lines 117-131):
  - `for refactor round 95` (lines 124-125, WUI entry-chunk headroom `154.7 KB` vs ceiling
    `155`): **already served** on `c4000b25b` by **SPL-6342** (`c68cca820`, `e5e6253e4`,
    `69dc02d2f`, `e62b847c3`: entry-chunk gzip `154.7 -> 151.9 KB`, -2.8 KB net). Dropped.
  - 4 `for bug round 43` blocks (lines 117-122, 127-131): bug-shaped, not ours.
  - Earlier line 65 (dead `/tmp` worktrees): served by SPL-6347 (`5e77f4c8b`, `11c6582fc`).
  - All other refactor-shaped items are already served or accounted in r90..r94 section 7.
- **(d) spec 011 tasks:**
  `git log c4000b25b --since=2026-11-23T17:37:58Z -- csi-spl-doc/specs/011-spool-project-refactor`
  -> 0; the open tasks (T001-T008 owner-deferred, T018-T021, T023, T027, T034) are each
  wider than one row or await an owner decision.
- **(e) A fresh scan for byte-identical function bodies** on `c4000b25b` over all 1,208
  tracked non-test `*.sh` files under `csi-spl-orc/src/bash`, `csi-spl-orc/lib`,
  `csi-spl-iac/src/bash`, `csi-spl-utl/src/bash` and `src/bash` (`run.sh` /
  `print-help.func.sh` excluded; `name() { ... }` bodies whitespace-trimmed, own name
  masked, >= 2 lines or 1 line >= 40 chars):
  - **12** cross-file groups (11 of 2+ lines, 1 of 1 line >= 40 chars):
    - `smh_hooks_json` / `spl_desk_mirror_settings_json` (7 body lines, orc): **row 01** (1.3).
    - `asks_peers_on` / `send_to_peers_on` (3 body lines, orc `spawn-agents`): both scripts
      already source `spool-fleet.inc.sh`; left in section 7 as a clean candidate for r96.
    - The remaining 10 groups (`do_gcp_*_apis_disable`, `spl_uplink_trim`/`ext_api_trim`,
      `spl_secrets_none_get`/`spl_self_host_env_get`, `tf_get` x2, `ndf_link`/`ndp_link`,
      7 `_sec_*_need`, `spl_brx_gh_auth`/`ghrh_gh_auth`, `ghr_in`/`ghrm_in`/`oss_runner_in`,
      `spl_asks_dur`/`spl_fleet_dur`, `_lc_deps`/`_spl_box_leave_deps`): unchanged from
      r91..r94 section 7, each stays out for its reason there.

### 1.3 Row 01's site: `spl-desk-mirror-settings.func.sh`'s own hooks JSON builder goes

`orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`. On `c4000b25b`:

- `orc:src/bash/run/spl-desk-mirror-settings.func.sh:41-49`: `spl_desk_mirror_settings_json`
  (7-line Python heredoc `:42-48`, building `{"hooks": {"UserPromptSubmit": h, "Stop": h}}`),
  called at `:26` by `do_spl_desk_mirror_settings` and directly at
  `orc:src/bash/tests/desk-mirror-actions.tst.sh:115`.
- `sa:lib/spool-mirror-hooks.inc.sh:30-38`: `smh_hooks_json` (same 7-line Python heredoc
  `:31-37`), called by `smh_qwen_merge` (`:72`), `smh_install` (`:161`, `:166`), and
  `sa:scripts/spool-agent.sh:212`.
  `diff -u <(sed -n 30,38p spool-mirror-hooks.inc.sh | sed 's/  # PY//') <(sed -n 41,49p spl-desk-mirror-settings.func.sh | sed 's/spl_desk_mirror_settings_json/smh_hooks_json/')`
  -> no hunk (rc 0, n=1): function bodies are **byte-identical**.
- `spool-mirror-hooks.inc.sh` is the shared mirror-hooks library (comment `:2-4`: "one copy
  for every launcher", 4 callers across 2 files vs 1 in `spl-desk-mirror-settings.func.sh`);
  it is the keeper and stays **unedited** (its 4 baseline warnings in
  `.shellcheck-warning-baseline.txt:51-52`, `SC2034` x2 and `SC2088` x2, stay untouched).
- `spool-mirror-hooks.inc.sh` has **0 top-level non-comment lines** (functions only:
  `smh_hooks_json`, `smh_agy_merge`, `smh_qwen_merge`, `smh_vibe_merge`,
  `smh_qwen_settings`, `smh_vibe_hooks`, `smh_agy_hooks`, `smh_user_hooked`, `smh_install`)
  and **0 symbol collisions** in `orc/src/bash/run/` or `orc/lib/bash/funcs/`
  (`git grep -nE 'smh_|SMH_' c4000b25b -- csi-spl-orc/src/bash/run/ csi-spl-orc/lib/bash/funcs/` -> 0).
- Who loads `spl-desk-mirror-settings.func.sh`: `./run` (lazy loader; called by
  `spool-install/install.sh:972`) and `desk-mirror-actions.tst.sh:50` (sources
  `"$PROJ_PATH"/src/bash/run/*.func.sh` directly, no temp-dir copy). Putting the
  `declare -F smh_hooks_json` guard **inside** `spl_desk_mirror_settings_json` (rather than
  at top level) keeps `run-eager-files.tst.sh` and `func-name-unique.tst.sh` untouched,
  preserves `desk-mirror-actions.tst.sh:115`'s direct call to
  `spl_desk_mirror_settings_json`, and leaves `do_spl_desk_mirror_settings`'s
  `do_require_bin python3` check (`:20`) intact.
- Shellcheck check (measured in 1.5): `shellcheck -S warning -x` on
  `spl-desk-mirror-settings.func.sh` sourcing `spool-mirror-hooks.inc.sh` exits **rc 0**
  (0 findings; warnings in sourced files are not attributed to the sourcing file), and
  `do_sec_shellcheck` on the 2 touched files exits **rc 0**.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-desk-mirror-settings.func.sh`: replace the 7-line Python heredoc
  (`:42-48`) inside `spl_desk_mirror_settings_json` with 4 lines: a 1-line comment
  (`# build the hooks object via smh_hooks_json of spool-mirror-hooks.inc.sh, its one copy`),
  `# shellcheck source=../features/spawn-agents/lib/spool-mirror-hooks.inc.sh`,
  `declare -F smh_hooks_json >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-mirror-hooks.inc.sh"`,
  and `smh_hooks_json "$1"`. 49 -> 46 lines (`+4 -7`).
- `orc:src/bash/tests/desk-mirror-actions.tst.sh`: extend header `:12` to name the
  delegation (`+2 -1`), and add 4 lines after `:119` (end of section 3): check that
  non-comment lines of `spl-desk-mirror-settings.func.sh` hold no
  `UserPromptSubmit|EOF_PY|shlex\.quote` (filtering `^[0-9]+:[[:space:]]*#` because `:4`
  is a `# @description` comment naming `UserPromptSubmit`), and that it calls
  `smh_hooks_json "$1"`. 130 -> 135 lines (`+6 -1`).
- head1's files, sha256 (12 chars): func `188b2b116620`, test `bc6effe980f2`.
- Note for the row and its reviewer: build any red/guard control in a worktree, not a
  copy of `spl-desk-mirror-settings.func.sh` in a temp dir: the guard resolves
  `spool-mirror-hooks.inc.sh` via `dirname "${BASH_SOURCE[0]}"`.

**Behaviour:** `smh_hooks_json` has the deleted Python heredoc byte for byte, called with
the same `"$1"`; sections 1-4 of `desk-mirror-actions.tst.sh` pass on base and head1 with
identical counts plus the new one-copy assertion (1.5).

### 1.4 Row 02's site: `spl-gh-wire.func.sh`'s own repo-variable apply tail goes

`iac:` = `csi-spl-iac/`. On `c4000b25b`:

- `iac:src/bash/run/gh-set-ci-vars.func.sh:42-58`: `_gscv_apply` validates JSON (`:44-45`),
  then runs `:46-57` (12 lines: read via `_gscv_get`, unchanged check, `DRY_RUN`
  would-create / would-update branches, `gh variable set`, read-back verify, `OK ... set`).
- `iac:src/bash/run/spl-gh-wire.func.sh:91-113`: `_sgw_apply` validates non-empty / regex
  (`:93-97`), loads `gh-set-ci-vars.func.sh` (`:98-100`, added by r94-01), then runs
  `:101-112` (the exact same 12 lines).
  `diff -u <(sed -n 46,57p gh-set-ci-vars.func.sh) <(sed -n 101,112p spl-gh-wire.func.sh)`
  -> no hunk (rc 0, n=1): those 12 lines are **byte-identical**.
- `_gscv_set` has **0 collisions** anywhere in the repo
  (`git grep -n '_gscv_set' c4000b25b -- ':!*.md'` -> 0). Neither `_gscv_apply` nor
  `_sgw_apply` is called outside its own file (`route-ci-overflow.func.sh:112` calls
  `do_gh_set_ci_vars` only).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `_gscv_set` is 14 lines, `_gscv_apply`
  shrinks from 17 to 6 lines, `_sgw_apply` shrinks from 23 to 12 lines.

Shape (built as head2 of 1.5):
- `iac:src/bash/run/gh-set-ci-vars.func.sh`: extract `:46-57` into `_gscv_set() { local repo="$1" name="$2" want="$3" dry="$4" have; ... }`
  immediately above `_gscv_apply`, drop `have` from `_gscv_apply`'s `local` line, and have
  `_gscv_apply` call `_gscv_set "$repo" "$name" "$want" "$dry"`. 73 -> 79 lines (`+9 -3`).
- `iac:src/bash/run/spl-gh-wire.func.sh`: in `_sgw_apply`, drop unused `have` from `local`
  (`:92`), update `:98-100` to comment `# apply one repo variable via _gscv_set of gh-set-ci-vars.func.sh, its one copy`
  and `declare -F _gscv_set >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/gh-set-ci-vars.func.sh"`,
  and replace `:101-112` (12 lines) with `_gscv_set "$repo" "$name" "$want" "$dry"`.
  146 -> 135 lines (`+4 -15`).
- `iac:src/bash/tests/spl-gh-wire.tst.sh`: update header `:21` and case 9 (`:180-184`) to
  guard the full apply path: non-comment lines of `spl-gh-wire.func.sh` hold no
  `_sgw_get|actions/variables/|variable set` (filtering `^[0-9]+:[[:space:]]*#` because
  `:5` is a `# @description` comment naming `gh variable set`), and the file calls
  `_gscv_set "$repo" "$name" "$want" "$dry"`. 196 -> 196 lines (`+6 -6`).
- head2's files, sha256 (12 chars): `gh-set-ci-vars.func.sh` `26a373f902b6`,
  `spl-gh-wire.func.sh` `7817ad138e1b`, `spl-gh-wire.tst.sh` `b64bc10e82d6`.
- Note for the row and its reviewer: build any red/guard control in a worktree, not a
  copy of `spl-gh-wire.func.sh` in a temp dir: the guard loads its sibling by
  `dirname "${BASH_SOURCE[0]}"`.

**Behaviour:** `_gscv_set` executes the exact 12 lines removed from `_gscv_apply` and
`_sgw_apply`, with the same 4 positional arguments `"$repo" "$name" "$want" "$dry"`;
`gh-set-ci-vars.tst.sh`, `spl-gh-wire.tst.sh`, `git-env-isolation.tst.sh`, and
`route-ci-overflow.tst.sh` pass on base and head2 with identical counts (1.5).

### 1.5 Before and on the rows' heads

2026-11-24T06:13:38Z-06:22:12Z (full 21-suite column on base, head1 and head2, plus
`shellcheck` and `do_sec_shellcheck`) and 06:23:46Z-06:26:00Z (re-run of the 4 suites
affected by the comment-filtered one-copy grep in head1 / head2, plus `shellcheck` and
all 4 controls `rc1`/`gc1`/`rc2`/`gc2`), n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, `timeout 900` each; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to
base: same rc, pass and fail counts.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/desk-mirror-actions.tst.sh` | 01 | 0 / 18 / 0 | 0 / 19 / 0 (one-copy adds 1) | = |
| `orc:src/bash/tests/tests-hermetic.tst.sh` | 01 | 0 / 9 / 0 | = | = |
| `orc:src/bash/tests/vibe-heartbeat.tst.sh` (keeper's user) | 01 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/agent-mcp.tst.sh` | 01 | 0 / 77 / 0 | = | = |
| `sa:tests/test-spool-agent.sh` (keeper's user) | 01 | 0 / 68 / 0 | = | = |
| `sa:tests/test-spool-harness.sh` (keeper's user) | 01 | 0 / 85 / 0 | = | = |
| `sa:tests/test-agent-hook-main-checkout.sh` | 01 | 0 / 69 / 0 | = | = |
| `orc:src/bash/features/spool-install/tests/test-install.sh` | 01 | 0 / 112 / 0 | = | = |
| `orc:src/bash/features/spool-install/tests/test-y12-vibe-push-guard.sh` | 01 | 0 / 11 / 0 | = | = |
| `iac:src/bash/tests/spl-gh-wire.tst.sh` | 02 | 0 / 18 / 0 | = | = (case 9 updated in place) |
| `iac:src/bash/tests/gh-set-ci-vars.tst.sh` | 02 | 0 / 14 / 0 | = | = |
| `iac:src/bash/tests/git-env-isolation.tst.sh` | 02 | 0 / 7 / 0 | = | = |
| `orc:src/bash/tests/route-ci-overflow.tst.sh` | 02 | 0 / 38 / 0 | = | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

`shellcheck -S warning -x` on all 5 row files (base, head1, head2): rc 0, no findings
(n=1 each). `do_sec_shellcheck` with `SEC_SHELLCHECK_FILES` set to each row's touched
files (head1: 2 files; head2: 3 files): rc 0, `no error-level findings` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `c4000b25b`):
- Row 01 red control (`rc1`, head1's `desk-mirror-actions.tst.sh` on base): rc 1, 17 pass,
  2 fail lines (1 assertion + summary `FAIL: 1 assertion(s)`),
  `FAIL: 3. one copy: spl-desk-mirror-settings.func.sh keeps its own hooks JSON builder, or no call of smh_hooks_json: 42:  python3 - "$1" <<'EOF_PY' 44:p = shlex.quote(sys.argv[1]) 47:print(json.dumps({"hooks": {"UserPromptSubmit": h, "Stop": h}}, indent=2, sort_keys=True)) 48:EOF_PY`;
  head1: rc 0, 19 pass, 0 fail.
- Row 01 guard control (`gc1`, head1 with the `declare -F smh_hooks_json` line deleted):
  rc 1, 17 pass, 2 fail lines (1 assertion + summary),
  `FAIL: 3. settings: .../spl-desk-mirror-settings.func.sh: line 44: smh_hooks_json: command not found`
  (printed twice: once for `do_spl_desk_mirror_settings`, once for the direct
  `spl_desk_mirror_settings_json` call).
- Row 02 red control (`rc2`, head2's `spl-gh-wire.tst.sh` on base): rc 1, 16 pass, 1 fail,
  `FAIL: 9. one copy: spl-gh-wire.func.sh keeps its own variable read/write, or no call of _gscv_set: 108:  gh variable set "$name" --repo "$repo" --body "$want" >/dev/null \`;
  head2: rc 0, 18 pass, 0 fail.
- Row 02 guard control (`gc2`, head2 with the `declare -F _gscv_set` line deleted):
  rc 9, 8 pass, 9 fail (including `FAIL: 1. dry run`, `FAIL: 3. set`, `FAIL: 3. re-run`),
  with `.../spl-gh-wire.func.sh: line 100: _gscv_set: command not found`.

The tests that name the sites (R2): `git grep -lE` over `*/tests/*` and `*shard-weights*`
for `spool-mirror-hooks|smh_hooks_json|smh_install|spl-desk-mirror-settings|spl_desk_mirror_settings|do_spl_desk_mirror_settings`
-> `desk-mirror-actions.tst.sh`, `tests-hermetic.tst.sh`, `vibe-heartbeat.tst.sh`,
`agent-mcp.tst.sh`, `test-agent-hook-main-checkout.sh`, `test-install.sh`,
`test-y12-vibe-push-guard.sh` (plus keeper users `test-spool-agent.sh`,
`test-spool-harness.sh` and the shared orc/iac gates); for
`spl-gh-wire|gh-set-ci-vars|_sgw_|_gscv_|do_spl_gh_wire|do_gh_set_ci_vars` ->
`spl-gh-wire.tst.sh`, `gh-set-ci-vars.tst.sh`, `git-env-isolation.tst.sh`,
`route-ci-overflow.tst.sh` (plus the shared iac/orc gates). 30-char comment grep across
`*/tests/*` -> 0 hits for both sites. No new test file is added, so `orc-shard-weights.txt`
needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r95-01-orc-mirror-hooks-json)` | one fact, one copy (developer guide 2.2.4) | `spl-desk-mirror-settings.func.sh` keeps a 7-line Python hooks JSON builder byte-identical to `smh_hooks_json` of `spool-mirror-hooks.inc.sh` (1.3, r94 section 7) | `orc:src/bash/run/spl-desk-mirror-settings.func.sh:41-49`<br>`orc:src/bash/tests/desk-mirror-actions.tst.sh` (header `:12`, 1 check after `:119`) | definitions of the terminal mirror hooks JSON builder body 2 -> 1 | 1.3's shape. **Red control:** the head's test on the parent FAILs the new section-3 one-copy check (1.5), then GREEN; the guard control (the `declare -F smh_hooks_json` line deleted: `3. settings` fails with `smh_hooks_json: command not found`), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the new check. Tests: `orc:.../desk-mirror-actions.tst.sh`, `tests-hermetic.tst.sh`, `vibe-heartbeat.tst.sh`, `agent-mcp.tst.sh`, `sa:tests/test-spool-agent.sh`, `test-spool-harness.sh`, `test-agent-hook-main-checkout.sh`, `orc:.../spool-install/tests/test-install.sh`, `test-y12-vibe-push-guard.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r95-02-iac-gh-wire-var-apply)` | one fact, one copy (developer guide 2.2.4) | after r94-01, `_sgw_apply` (`spl-gh-wire.func.sh`) and `_gscv_apply` (`gh-set-ci-vars.func.sh`) still share a 12-line byte-identical read / dry-run / `gh variable set` / read-back tail (1.4, r94 section 7) | `iac:src/bash/run/gh-set-ci-vars.func.sh:42-58`<br>`iac:src/bash/run/spl-gh-wire.func.sh:91-113`<br>`iac:src/bash/tests/spl-gh-wire.tst.sh:21,180-184` | copies of the 12-line GitHub Actions variable apply body 2 -> 1 | 1.4's shape. **Red control:** the head's test on the parent FAILs case 9 naming `:108` `gh variable set` (1.5), then GREEN; the guard control (the `declare -F _gscv_set` line deleted: 9 checks fail with `_gscv_set: command not found`), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with identical counts. Tests: `iac:.../spl-gh-wire.tst.sh`, `gh-set-ci-vars.tst.sh`, `git-env-isolation.tst.sh`, `no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `orc:.../route-ci-overflow.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r95-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r95-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row removes a byte-identical copy and points its caller at the single home;
no output, exit code, path or file a caller sees changes (1.3, 1.4, 1.5). Each:
`Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `spl-desk-mirror-settings.func.sh` and `desk-mirror-actions.tst.sh`; row 02:
  `csi-spl-iac` `gh-set-ci-vars.func.sh`, `spl-gh-wire.func.sh`, and `spl-gh-wire.tst.sh`).
- No row edits `sa:lib/spool-mirror-hooks.inc.sh` (row 01's keeper) or
  `.shellcheck-warning-baseline.txt`, `sa:scripts/spool-agent.sh`,
  `sa:scripts/spool-harness.sh`, `orc:src/bash/features/spool-install/install.sh`,
  `iac:src/bash/tests/gh-set-ci-vars.tst.sh`, `orc:src/bash/run/route-ci-overflow.func.sh`,
  `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform, `csi-spl-api/` or
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (7, the 5 edited + row 01's keeper + `gh-set-ci-vars.tst.sh`):
`orc:src/bash/run/spl-desk-mirror-settings.func.sh`,
`orc:src/bash/tests/desk-mirror-actions.tst.sh`,
keeper `sa:lib/spool-mirror-hooks.inc.sh`;
`iac:src/bash/run/gh-set-ci-vars.func.sh`, `iac:src/bash/run/spl-gh-wire.func.sh`,
`iac:src/bash/tests/spl-gh-wire.tst.sh`, `iac:src/bash/tests/gh-set-ci-vars.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent a-967`, one call per
  path, n=1, 2026-11-24T06:10:34Z-06:10:51Z: **exit 4 on all 7** ("no live lane lists
  <path>, but 10 live lane(s) record no files"). The 10 `unknown:` lanes, all on the
  other box (`lane-map.sh list --all`, 06:06:32Z): the 6 private-channel seats c-029,
  c-041, c-146, c-187, c-924, c-927 (`*-rotate`), the workspace seat c-086 (`*-rotate`),
  spec 181 row B13 c-384 (hub + wui), and R7 reviewers g-554 (B9) and g-565 (B11). No
  lane owns any of the 7 paths; none of those scopes touches `spl-desk-mirror-settings`
  or `iac/src/bash/run/`.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 06:06:10Z-06:06:32Z):
  2 queued, 0 placing: this round's mistral panel seat
  (`c002-refactor-round-95-mistral-panel-seat`) and bug round 43's planner
  (`c002-bug-round-43-planner`, doc only). Share line: refactor 1 of 14 known live lanes,
  7% (band 10-20%: UNDER); phase day; last 24 h 10% (band 20-30%: UNDER). Re-checked at
  06:27Z: 0 queued, 0 placing (panel seat live as m-969).
- **Briefs on this box** changed in the last 24 h (136) naming any of the 7 paths or their
  functions (06:10:51Z): **4**, only the closed/landed r94-01 / r94-02 / b42 planner
  briefs (`c002-r94-01-iac-gh-wire-var-get.md`, `hand-<box>-c002-r94-01-grok-reviewer.md`,
  `c002-r94-02-orc-ksr-role-seat.md`, `c002-bug-round-42-planner.md`). None live.
- **Remote branches committed in the last 24 h** (15 besides master after
  `git fetch --prune origin`, 06:10:51Z):
  `git diff --name-only $(git merge-base c4000b25b <b>) <b> -- <the 7 paths>` -> **0 hits**.
- **Commits in the last 24 h** on those 7 paths (`git log c4000b25b --since='24 hours ago'`)
  -> **1**: `ffe718a28` (r94-01, already landed and closed).
- **Live or landed lanes named in the brief:** spec 181 B9 c-916 (landed `c4000b25b`, R7
  g-554), B11 c-918 (signin relay, R7 g-565), B13 c-384 (hub + wui, R7 g-445); SPL-6239
  T6 c-478 (landed `c5fa1ded8`, R7 g-547); SPL-6346 c-925 (landed `75b20a488`); bug round
  43 planner (doc only); the 6 private-channel seats and c-086: none on a row path.

## 3. Per row: what the lane does

- **r95-01:** `spl-desk-mirror-settings.func.sh`'s `spl_desk_mirror_settings_json` builds
  the terminal mirror hooks JSON through `smh_hooks_json` of `spool-mirror-hooks.inc.sh`,
  its one copy, loaded behind a `declare -F` guard when the function runs. The new
  section-3 check in `desk-mirror-actions.tst.sh` proves the inline Python copy is gone
  (filtering comment lines); section 3 and the guard control prove the guard loads it.
- **r95-02:** `gh-set-ci-vars.func.sh` extracts the 12-line GitHub Actions repo-variable
  read / dry-run / `gh variable set` / read-back tail into `_gscv_set`; `_gscv_apply`
  calls it after JSON validation, and `spl-gh-wire.func.sh`'s `_sgw_apply` updates its
  `declare -F` guard to `_gscv_set` and calls `_gscv_set` after its output validation.
  Updated case 9 of `spl-gh-wire.tst.sh` proves neither `actions/variables/` nor
  `variable set` remains in non-comment lines of `spl-gh-wire.func.sh`; cases 1, 3, 4, 7,
  8 and the guard control prove the guard loads it.

## 4. Panel and reviewers (R7)

- Editor: a-967 (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the mistral seat `c002-refactor-round-95-mistral-panel-seat` (queued
  1/2 at 06:06:10Z, live as m-969 at 06:27Z). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-24T06:06:04Z printed
  `pick=<box> reason=every box is at or above its high mark; <box> is the least past its band (95% on high 90%, overflow 180%)`,
  grok weekly 89% on both boxes (not held): **a grok R7 seat per row**. The rows run by
  night (rulebook 1.4); the holder re-runs the pick when it places them, and a hold then
  gives the row a **claude waiver seat**, as r90..r94's section 4 say. Never a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r95-01 | `c002-r95-01-orc-mirror-hooks-json` | `refactor(r95-01-orc-mirror-hooks-json, SPL-<row issue>): ...` | `review/r95-01` | 1 |
| r95-02 | `c002-r95-02-iac-gh-wire-var-apply` | `refactor(r95-02-iac-gh-wire-var-apply, SPL-<row issue>): ...` | `review/r95-02` | 1 |

**r95-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-desk-mirror-settings.func.sh` (inside
`spl_desk_mirror_settings_json` `:41-49`: replace the 7-line Python heredoc `:42-48` with
the 1-line comment, `# shellcheck source=../features/spawn-agents/lib/spool-mirror-hooks.inc.sh`,
`declare -F smh_hooks_json` guard, and `smh_hooks_json "$1"`) and
`csi-spl-orc/src/bash/tests/desk-mirror-actions.tst.sh` (header `:12` and 1 one-copy
check after `:119`, filtering `#` comment lines). NOT `spool-mirror-hooks.inc.sh`, NOT
`.shellcheck-warning-baseline.txt`, NOT `spool-agent.sh`, `spool-harness.sh`,
`install.sh`, or any other test. Do: plan section 2 row 01 verbatim, 1.3's shape; the red
control (the head's test on the parent) RED then GREEN in the body; the guard control
(the `declare -F smh_hooks_json` line deleted: `3. settings` fails, built in a worktree,
not a temp-dir copy). Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r95-02 brief, Files: ONLY**
`csi-spl-iac/src/bash/run/gh-set-ci-vars.func.sh` (extract `:46-57` into `_gscv_set`,
called by `_gscv_apply` after JSON validation),
`csi-spl-iac/src/bash/run/spl-gh-wire.func.sh` (in `_sgw_apply` `:91-113`: drop unused
`have`, switch `declare -F` guard to `_gscv_set`, replace `:101-112` with
`_gscv_set "$repo" "$name" "$want" "$dry"`), and
`csi-spl-iac/src/bash/tests/spl-gh-wire.tst.sh` (header `:21` and case 9 `:180-184`,
filtering `#` comment lines). NOT `gh-set-ci-vars.tst.sh`, NOT `route-ci-overflow.func.sh`
or any other test. Do: plan section 2 row 02 verbatim, 1.4's shape; the red control (the
head's test on the parent) RED then GREEN in the body; the guard control (the
`declare -F _gscv_set` line deleted: 9 checks fail, built in a worktree, not a temp-dir
copy). Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| definitions of the terminal mirror hooks JSON builder body (1.3) | 2 on `c4000b25b` (`smh_hooks_json`, `spl_desk_mirror_settings_json`) -> 1 after row 01 |
| copies of the 12-line GitHub Actions variable apply body (1.4) | 2 on `c4000b25b` (`_gscv_apply`, `_sgw_apply`) -> 1 (`_gscv_set`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: func +4 -7, test +6 -1; row 02: `gh-set-ci-vars` +9 -3, `spl-gh-wire` +4 -15, test +6 -6 |
| measured on | `c4000b25b`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `asks_peers_on` / `send_to_peers_on` (`sa:scripts/asks.sh:46-50`, `sa:scripts/spool-send.sh:267-271`, 3-line body, byte-identical) | clean candidate for r96 (this round aims at 2 rows, 5.1): both scripts already source `sa:lib/spool-fleet.inc.sh`, so a shared `spool_fleet_peers_on` helper needs no new source edge; wider test surface (`asks.tst.sh`, `test-fleet-send.sh`, `spool-send` suites) not measured here | 1.2 (e) on `c4000b25b` |
| `_gscv_repo` / `_sgw_repo` (`iac:src/bash/run/gh-set-ci-vars.func.sh:28-32`, `iac:src/bash/run/spl-gh-wire.func.sh:49-53`, 3-line origin parse differing only in env var `GH_CI_VARS_REPO` vs `GH_WIRE_REPO`) | candidate for r96 after row 02: needs a parameterised override arg and a `declare -F` load in `do_spl_gh_wire`; left out so row 02 stays pure byte-identical copy removal with one load guard | `diff -u` with var-name substitution rc 0 on `c4000b25b` |
| WUI entry-chunk headroom (`c002-next-round-candidates.md:124-125`, `for refactor round 95`) | already served on `c4000b25b` by SPL-6342 (`c68cca820`..`e62b847c3`, `154.7 -> 151.9 KB`) | 1.2 (c); `git log --grep='SPL-6342'` |
| other `LEASE_(MASTER|FAILOVER|ORCH)` sites (`sa:scripts/lane-age-report.sh:33`, `orc:src/bash/run/spl-box-leave.func.sh:298`, `orc:src/bash/run/spl-lane-backfill-links.func.sh:78`) | not byte-identical to `send_role_seat` (different path vars); unchanged since r94 | r94 7; 1.2 (a) |
| `csi-spl-doc/specs/172-work-chain-enforcement/spec.md:173` (`lane_is_role_seat` prose) and `i18n-lang-review-exempt.json:2` `_doc` | prose / doc strings, not code copies; unchanged since r94 | r94 7; 1.2 (a) |
| Go duplicate helpers in `csi-spl-api/src/go/spool-hub-api` (`internal/store`, `keyd`/`lockkey`) | cross-package or store/security-tier (`PRE_PUSH_TIER=full` Postgres gate, live spec-181 store lanes): not measured here | r94 7; 1.2 (a) |
| the 10 remaining 2+ line / >=40-char Bash groups (`do_gcp_*_apis_disable`, `spl_uplink_trim`/`ext_api_trim`, `spl_secrets_none_get`/`spl_self_host_env_get`, `tf_get`, `ndf_link`/`ndp_link`, 7 `_sec_*_need`, `spl_brx_gh_auth`/`ghrh_gh_auth`, `ghr_in` family, `spl_asks_dur`/`spl_fleet_dur`, `_lc_deps`/`_spl_box_leave_deps`) | unchanged since r94 (`c4000b25b`), each stays out for its r91..r94 section 7 reason | r94 7, r93 7, r92 7, r91 7; 1.2 (a), (e) |

## 8. Changes

- v0.1 (a-967): the rows and every read on `c4000b25b`; both heads built in detached
  scratch worktrees; the 21-suite column of 1.5 run on base and both heads; `shellcheck`
  and `do_sec_shellcheck` rc 0; the red and guard controls RED; R3 (2.2) and R7
  (section 4) checked.
- v1.0 (a-967): the panel seat m-969 (mistral) **PASS** on `62e2af0eb`
  (`62e2af0eb03e7cd7a27fc96cd46693683c2cb76b`), no W, notes N1..N3 (msgs `ae949187`,
  `2ad363ae`; seat file `refactor-round-95/seat-mistral.md` on
  `review/c002-refactor-round-95-mistral-seat`, `ad6f07792`). Its review line passed the
  holder c-002's `do_spl_review_line_check` at 06:5xZ: rc 0 (`2 of 2 ran:` in vibe session
  log `unified/c942623c-bed1-b4b5-b9b6-6f18f21d858d`, reviewer m-969; holder GO msg
  `8006c9ee`). v0.1 landed on `origin/master` as `3854cd50f`
  (`3854cd50f92de4895729638c2548a7c769cb5485`; `git patch-id --stable` `d0224f32f656`
  equal to `62e2af0eb`). Notes folded (no row change):
  - N1: the seat built its own heads in scratch worktrees from 1.3 / 1.4 (`head1` func
    `188b2b116620` and `head2` `spl-gh-wire` `7817ad138e1b` match the plan's sha256; the
    other 3 differ in comment/wording only: `head1` test `+7 -1` / 136 lines vs `+6 -1` /
    135, `head2` `gh-set-ci-vars` `+10 -4` / `_gscv_set` 15 lines vs `+9 -3` / 14, `head2`
    test `52715b54fcc9` vs `b64bc10e82d6`), and all 4 red and guard controls reproduce the
    plan's exact quoted lines and counts (`rc1` rc 1 17/2, `gc1` rc 1 17/2 line 44, `rc2`
    rc 1 16/1 `:108`, `gc2` rc 9 8/9 line 100).
  - N2: `origin/master` equaled `c4000b25b` at the seat's read (06:46Z) and moved to
    `15c05df0f` -> `3854cd50f` at v1.0; `git diff --name-only c4000b25b origin/master --
    <the 7 paths>` is empty (re-read 06:59Z), so every site stands.
  - N3: the lane map at the seat's read exited 4 with the same 10 unknown-scope lanes (0
    hits on the 7 paths; spawn queue 3 queued, 0 placing, 1 held at 06:45Z); row lanes
    re-run R3 at spawn.
  Text unchanged except the status line and sections 8 and 9.
- Round closed (a-967 writes the record), no version bump: both rows landed, read on
  `origin/master` `c581dc43d` (`2026-11-24T08:24Z`, n=1 each; both rows already on
  `aea828942` and untouched by `c581dc43d`):
  - r95-01 `719d1415c` (`719d1415cf0018014abdfed0af9935e3fb169cef`, SPL-6352, committed
    `2026-11-24T07:42:55Z`): R7 `g-658` grok **PASS** on `1e7fc77b8`
    (`1e7fc77b8013b340b6ae94344b9920dec164296f`); `git patch-id --stable` `644bc216f304`
    on both. CI on `719d1415c`: all push workflows **success** — gate 10 (`45350173078`),
    15 (`45350172916`), 25 (`45350172993`), 26 (`45350172969`), 64 (`45350173081`),
    67 (`45350173003`); scheduled gate 10 (`45350465299`) **success**; 5 skipped
    workflow 12 runs. Diff (`git show --numstat`): `spl-desk-mirror-settings.func.sh`
    `+4 -7` (sha256 `188b2b116620`, plan head1), `desk-mirror-actions.tst.sh` `+6 -1`
    (sha256 `95c1a444fecc`), matching plan 1.3 / 6. R7 notes (`g-658`): N1 test sha256
    `95c1a444fecc` differs from plan head1 `bc6effe980f2` in wording only (func sha256
    matches plan); N2 y12 test file unchanged `c4000b25b` through head, full column not
    re-run by reviewer (author and CI gate 10 `45350173078` ran it); N3 author brief path
    absent on reviewer's box. None asks for a change.
  - r95-02 `aea828942` (`aea828942f2cbd6caba45f7b433932f6f9b9cd2a`, SPL-6354, committed
    `2026-11-24T07:53:35Z`): R7 `g-663` grok **PASS** on `0c9123c12`
    (`0c9123c127c1778e08bea9e8b969b2d91732a403`, `review/r95-02`); `git patch-id --stable`
    `3f3d00c688e3` on both. CI on `aea828942`: all push workflows **success** — gate 10
    (`45351552381`), 15 (`45351552336`), 25 (`45351552318`), 26 (`45351552337`),
    64 (`45351552304`), 67 (`45351552285`); scheduled 21 (`45351641242`, `45355015672`)
    and 40 (`45351576311`, `45354975799`) **success**; 6 skipped workflow 12 runs. Diff
    (`git show --numstat`): `gh-set-ci-vars.func.sh` `+10 -4` (sha256 `952dbb451da4`),
    `spl-gh-wire.func.sh` `+4 -15` (sha256 `7817ad138e1b`, plan head2),
    `spl-gh-wire.tst.sh` `+6 -6` (sha256 `97117a95cdf0`), matching plan 1.4 / 6
    (`gh-set-ci-vars.func.sh` `+10 -4` vs `+9 -3` by comment and layout only, as panel
    note N1 noted). R7 notes (`g-663`): N1 `gh-set-ci-vars.func.sh` and
    `spl-gh-wire.tst.sh` sha256s differ from plan head2 (`26a373f902b6`, `b64bc10e82d6`)
    by comment and layout only (`spl-gh-wire.func.sh` matches plan); author and CI gate 10
    `45351552381` ran the full column. None asks for a change.
  - `git merge-base --is-ancestor <row> origin/master` rc 0 and box checkout ancestry rc 0
    for both; R6 (`git log origin/master --since="2026-11-23T22:49:00+02:00"
    --format='%H %cI %s' -E --grep='\(r95-'`) returns both rows (`719d1415c`, `aea828942`)
    and the 2 plan commits (`3854cd50f`, `afcf1649b`). Panel seat m-969 also signed v1.0
    `afcf1649b` (PASS msg `9df0b5c5`, seat file `fbebfbf9a` on
    `review/c002-refactor-round-95-mistral-seat`). **R7 vendor:** both seats grok
    (section 4: `g-658`, `g-663`); no claude waiver seat was needed. Post-land `git grep`
    on `c581dc43d` (excluding `*.md`): terminal mirror hooks JSON builder body 2 -> 1
    (`smh_hooks_json` at `sa:lib/spool-mirror-hooks.inc.sh:30`, sole `UserPromptSubmit`
    JSON build at `:36`; `spl-desk-mirror-settings.func.sh` calls `smh_hooks_json "$1"`
    at `:45` behind `declare -F` at `:44`); GitHub Actions repo-variable apply body
    2 -> 1 (`_gscv_set` at `iac:src/bash/run/gh-set-ci-vars.func.sh:42`, sole executable
    `gh variable set` at `:51`; called by `_gscv_apply` at `:63` and `_sgw_apply` at
    `spl-gh-wire.func.sh:101` behind `declare -F` at `:100`). Neither row touches a path
    outside its brief's Files (`git show --stat`: 2 files for r95-01, 3 files for r95-02;
    row 01's keeper `spool-mirror-hooks.inc.sh` untouched).

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-967 (agy): v0.1, v1.0, close record.
- Panel reviewer seat: m-969 (mistral, `c002-refactor-round-95-mistral-panel-seat`):
  **PASS** on v0.1 (`62e2af0eb`), no W, notes N1-N3; **PASS** on v1.0 (`afcf1649b`). Seat
  file `refactor-round-95/seat-mistral.md` (`review/c002-refactor-round-95-mistral-seat`,
  `ad6f07792` -> `fbebfbf9a`, section 8).
- Row R7 seats: section 4; both grok: g-658 (r95-01), g-663 (r95-02) (section 8, round
  closed).
