# Refactoring round 96 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6358  
Topic: 1884ed4c-65ee-4a10-b393-d45507a93d99  
Discussion: 1884ed4c-65ee-4a10-b393-d45507a93d99 (t1 #refactoring, "Refactor round 96", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r96**, plan `refactor-round-96-plan.md`, rows `r96-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 95 ([refactor-round-95-plan.md](refactor-round-95-plan.md))
is closed: both rows landed on trunk (r95-01 `719d1415c`, SPL-6352; r95-02 `aea828942`,
SPL-6354), and its editor a-967 landed the r95 close record `8e1b9308e` (`Closes: SPL-6348`).
This planner writes no r95 close record and touches no r95 file. The perf floor
(rulebook 4.4), measured on `48bc8bb6a` at 2026-11-24T08:47:33Z (14 days): perf 29,
refactor 98, 22.8%, 5 x 29 = 145 >= 127, floor-met (matching the holder c-002's read on
`48bc8bb6a`), so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91..r95: a
duplicated helper body that exists in two places loses its duplicate copy, and each
caller calls the single home.
**Row 01:** `asks.sh` (`asks_peers_on`) and `spool-send.sh` (`send_to_peers_on`) in
`csi-spl-orc/src/bash/features/spawn-agents/scripts/` carry a 3-line byte-identical peers
switch (`SPOOL_TO_PEERS` override + `$SPOOL_ROOT/peer/seats` seat-line check; r95 section
7's first candidate for this round). Both scripts already source `sa:lib/spool-fleet.inc.sh`:
the one copy moves into `spool_fleet_peers_on` in `spool-fleet.inc.sh` (zero new source
edges), both local copies go, both scripts call `spool_fleet_peers_on`, and
`test-fleet-send.sh` guards both direct behaviour and one-copy.
**Row 02:** after r94-01 landed `_gscv_get` and r95-02 landed `_gscv_set`, `_gscv_repo`
(`gh-set-ci-vars.func.sh`) and `_sgw_repo` (`spl-gh-wire.func.sh`) still share the same
3-line GitHub `<owner>/<repo>` override + `git remote get-url origin` parser, differing
only in override env var name (`GH_CI_VARS_REPO` vs `GH_WIRE_REPO`; r95 section 7's second
candidate, eligible now that r95-02 landed). `_gscv_repo` takes its override as `$1`
(`do_gh_set_ci_vars` passes `"${GH_CI_VARS_REPO:-}"`, keeping shellcheck SC2120 clean and
preventing env-var leakage), `_sgw_repo` goes from `spl-gh-wire.func.sh`, `do_spl_gh_wire`
loads `gh-set-ci-vars.func.sh` behind a `declare -F _gscv_repo` guard and calls
`_gscv_repo "${GH_WIRE_REPO:-}"`, and `spl-gh-wire.tst.sh` guards both one-copy and
`GH_CI_VARS_REPO` isolation. The rows share no file (orc vs iac): both are batch 1.

**Status: v0.1, draft for panel review.** Panel seat m-028 (mistral,
`c002-refactor-round-96-mistral-panel-seat`, live) reviews this draft on
`review/c002-refactor-round-96-planner`. Rows queue once the panel signs and
`do_spl_review_line_check` exits 0 (rulebook 1.4 / 5.2). Editor: **a-025** (agy).

**One sha:** every count is measured on **`48bc8bb6a`** (`origin/master` at
2026-11-24T08:46:44Z), n=1 per command unless stated. Reads are on `48bc8bb6a` with
`git show` / `git grep`. The tests of 1.5 ran in detached scratch worktrees of
`48bc8bb6a` (not committed, removed on exit): "base" unmodified, "head1" = base with
row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's shape; each
red and guard control (1.5) ran in a detached worktree of its own. Queue, lane map,
brief and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-24T08:46:44Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-24T10:26:25+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r95-plan'`:
  `8e1b9308e` (`docs(r95-plan, SPL-6348): refactor round 95 closed: r95-01 719d1415c and r95-02 aea828942 landed, grok R7 PASS each on the reviewed head (patch-id equal)`),
  read once at the start as 5.3 says.
- `git log origin/master --since="$W" --oneline -E --grep='\(r96-' | wc -l` -> **0**
  (over all history -> **0**).
- `git ls-remote origin 'refs/heads/review/r96-*' 'refs/heads/*-r96-*' 'refs/heads/*refactor-round-96*' 'refs/heads/wip/*r96*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r96|refactor-round-96'` -> this plan's
  brief (`c002-refactor-round-96-planner.md`) and the panel seat's
  (`c002-refactor-round-96-mistral-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-96`
  -> **0**: the plain name is free.

### 1.2 The brief's inputs, re-measured

- **(a) r95 section 7:** re-read on `48bc8bb6a`.
  - `asks_peers_on` / `send_to_peers_on` (`sa:scripts/asks.sh:46-50`,
    `sa:scripts/spool-send.sh:267-271`), left out of r95 as this round's first candidate:
    measured here as **row 01** (1.3).
  - `_gscv_repo` / `_sgw_repo` (`iac:src/bash/run/gh-set-ci-vars.func.sh:28-32`,
    `iac:src/bash/run/spl-gh-wire.func.sh:49-53`), noted in r95 section 7 as eligible
    after r95-02 landed: measured here as **row 02** (1.4).
  - `git diff --name-only c4000b25b 48bc8bb6a` (59 files across 14 commits: r95 plan /
    rows `719d1415c` & `aea828942` / close `8e1b9308e`, b43 plan & `c581dc43d`, spec 181
    B13 SPL-6341 `bb9a478ff`..`76471cb9e`, Nuxt 3 osv-scanner ignore renewal `3eec1eb89`,
    SPL-5006 W3 `48bc8bb6a`): touches none of r95/r94/r93/r92/r91 section 7's other
    items, so each stays out for its reason there (section 7).
- **(b) R7 and panel notes:**
  - r95-01 R7 (`g-658`, commit `719d1415c`, read via `git show`): N1 test sha256
    `95c1a444fecc` vs plan `bc6effe980f2` wording only (func sha256 `188b2b116620`
    matches plan); N2 y12 file unchanged `c4000b25b` through head, column not re-run by
    reviewer; N3 author brief path absent on reviewer's box. Notes only.
  - r95-02 R7 (`g-663`, commit `aea828942`, read via `git show` and r95 close record
    `8e1b9308e`; the reviewer's per-seat report file is on the other box): N1
    `gh-set-ci-vars.func.sh` and `spl-gh-wire.tst.sh` sha256s differ from plan head2 by
    comment/layout only (`spl-gh-wire.func.sh` matches plan). Notes only.
  - r95 panel (`m-969`, recorded in r95 plan v1.0 `afcf1649b`): PASS on `62e2af0eb`, no W,
    notes N1..N3 verification notes only. No refactor row in any of them.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 131 lines, read 08:46Z):
  unchanged since r95 read it (still 131 lines; its last blocks are the 4 `for bug round
  43` items and the already-served `for refactor round 95` SPL-6342 WUI entry-chunk item).
  No new refactor-shaped item.
- **(d) spec 011 tasks:**
  `git log 48bc8bb6a --since=2026-11-24T06:06:02Z -- csi-spl-doc/specs/011-spool-project-refactor`
  -> 0; the open tasks (T001-T008 owner-deferred, T018-T021, T023, T027, T034) are each
  wider than one row or await an owner decision.
- **(e) A fresh scan for byte-identical function bodies** on `48bc8bb6a` over all 1,208
  tracked non-test `*.sh` files under `csi-spl-orc/src/bash`, `csi-spl-orc/lib`,
  `csi-spl-iac/src/bash`, `csi-spl-utl/src/bash` and `src/bash` (`run.sh` /
  `print-help.func.sh` excluded; `name() { ... }` bodies whitespace-trimmed, own name
  masked, >= 2 lines or 1 line >= 40 chars):
  - **11** cross-file groups (10 of 2+ lines, 1 of 1 line >= 40 chars; down from 12 on
    r95's `c4000b25b` after r95-01 landed):
    - `asks_peers_on` / `send_to_peers_on` (3 body lines, orc `spawn-agents`): **row 01**
      (1.3).
    - The remaining 10 groups (`do_gcp_*_apis_disable`, `spl_uplink_trim`/`ext_api_trim`,
      `spl_secrets_none_get`/`spl_self_host_env_get`, `tf_get` x2, `ndf_link`/`ndp_link`,
      7 `_sec_*_need`, `spl_brx_gh_auth`/`ghrh_gh_auth`, `ghr_in`/`ghrm_in`/`oss_runner_in`,
      `spl_asks_dur`/`spl_fleet_dur`, `_lc_deps`/`_spl_box_leave_deps`): unchanged from
      r91..r95 section 7, each stays out for its reason there.

### 1.3 Row 01's site: `asks.sh`'s and `spool-send.sh`'s peers switch moves into `spool-fleet.inc.sh`

`orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`. On `48bc8bb6a`:

- `sa:scripts/asks.sh:46-50`: `asks_peers_on` (3-line body: `SPOOL_TO_PEERS` 1|0 override,
  else `[ -r "$SPOOL_ROOT/peer/seats" ]` + `sed`/`awk` seat-line check), called only at
  `:122` (`if [ -n "$ID" ] && asks_peers_on; then`).
- `sa:scripts/spool-send.sh:267-271`: `send_to_peers_on` (same 3-line body), called only
  at `:401` (`if send_to_peers_on; then`).
  `diff -u <(sed -n '46,50p' asks.sh | sed 's/asks_peers_on/spool_fleet_peers_on/') <(sed -n '267,271p' spool-send.sh | sed 's/send_to_peers_on/spool_fleet_peers_on/')`
  -> no hunk (rc 0, n=1): function bodies are **byte-identical**.
- No other code file or test calls `asks_peers_on` or `send_to_peers_on`
  (`git grep -nE 'asks_peers_on|send_to_peers_on|spool_fleet_peers_on' 48bc8bb6a -- ':!*.md'`
  -> only the 2 definitions, their 2 calls, and one comment in
  `orc:src/bash/run/spl-unanswered-sweep.func.sh:196`, noted in section 7).
- Both `asks.sh` (`:40`) and `spool-send.sh` (`:129`) already source
  `$_here/../lib/spool-fleet.inc.sh`: moving the one copy into `spool_fleet_peers_on` in
  `sa:lib/spool-fleet.inc.sh` adds **zero new source edges**.
- `spool_fleet_peers_on` has **0 collisions** anywhere in the repo (`git grep` -> 0); its
  body is 5 lines (well under `bash-cleancode.tst.sh`'s 75-line cap). None of the 4 files
  has any entry in `.shellcheck-warning-baseline.txt`.
- Shellcheck check (measured in 1.5): `shellcheck -S warning -x` on all 4 files exits
  **rc 0** (0 findings), and `do_sec_shellcheck` on the 4 touched files exits **rc 0**
  (`no error-level findings`, `no new findings (baseline holds)`).

Shape (built as head1 of 1.5):
- `sa:lib/spool-fleet.inc.sh`: add the `spool_fleet_peers_on` bullet to the header doc
  block (above `spool_fleet_relay`, `:29`) and add `spool_fleet_peers_on()` with its
  3-line comment above `spool_fleet_desk_configured` (`:94`). 129 -> 141 lines (`+12 -0`).
- `sa:scripts/asks.sh`: delete the comment + `asks_peers_on()` + blank line (`:45-51`),
  and replace `asks_peers_on` with `spool_fleet_peers_on` at `:122` (now `:115`).
  153 -> 146 lines (`+1 -8`).
- `sa:scripts/spool-send.sh`: delete the 2-line comment + `send_to_peers_on()` + blank
  line (`:265-272`), and replace `send_to_peers_on` with `spool_fleet_peers_on` at `:401`
  (now `:393`). 659 -> 651 lines (`+1 -9`).
- `sa:tests/test-fleet-send.sh`: append 7 assertions before `t_done` (end of section 8):
  4 direct unit checks of `spool_fleet_peers_on` (`SPOOL_TO_PEERS=1` -> 0,
  `SPOOL_TO_PEERS=0` -> 1, unset with seat line in `$A/peer/seats` -> 0, unset with no
  `$B/peer/seats` -> 1; note `-u SPOOL_TO_PEERS` precedes `SPOOL_ROOT=...` in `env`), and
  3 one-copy checks (no non-comment `asks_peers_on|send_to_peers_on|awk.*\[acgmq\]` in
  `asks.sh` or `spool-send.sh`, and both call `spool_fleet_peers_on`). 361 -> 372 lines
  (`+11 -0`).
- head1's files, sha256 (12 chars): `spool-fleet.inc.sh` `616dba760b43`, `asks.sh`
  `40973aba3527`, `spool-send.sh` `53610547ef08`, `test-fleet-send.sh` `2c9ced6b5022`.

**Behaviour:** `spool_fleet_peers_on` executes the exact 3 lines removed from `asks.sh`
and `spool-send.sh`, sourced from the same `spool-fleet.inc.sh` both scripts already load;
all 17 row-01 suites + 4 shared gates pass on base and head1 with identical counts plus
the 7 new checks in `test-fleet-send.sh` (1.5).

### 1.4 Row 02's site: `spl-gh-wire.func.sh`'s own origin repo parser goes

`iac:` = `csi-spl-iac/`. On `48bc8bb6a`:

- `iac:src/bash/run/gh-set-ci-vars.func.sh:28-32`: `_gscv_repo` returns `GH_CI_VARS_REPO`
  if non-empty, else runs `git -C "$APP_PATH" remote get-url origin 2>/dev/null` and
  extracts `<owner>/<repo>` with `sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p'`.
  Called only at `:70` (`do_gh_set_ci_vars`).
- `iac:src/bash/run/spl-gh-wire.func.sh:49-53`: `_sgw_repo` has the exact same 3-line
  body with `GH_WIRE_REPO` in place of `GH_CI_VARS_REPO`. Called only at `:112`
  (`do_spl_gh_wire`).
  `diff -u <(sed -n '28,32p' gh-set-ci-vars.func.sh | sed 's/_gscv_repo/_repo/; s/GH_CI_VARS_REPO/REPO_VAR/g') <(sed -n '49,53p' spl-gh-wire.func.sh | sed 's/_sgw_repo/_repo/; s/GH_WIRE_REPO/REPO_VAR/g')`
  -> no hunk (rc 0, n=1): bodies are **identical** up to the override env-var name.
- Parameterising `_gscv_repo` to read its override from `"${1:-}"` — and having
  `do_gh_set_ci_vars` pass `"${GH_CI_VARS_REPO:-}"` while `do_spl_gh_wire` passes
  `"${GH_WIRE_REPO:-}"` — achieves two things at once:
  1. **Zero env-var leakage:** when `GH_WIRE_REPO` is unset in `do_spl_gh_wire`, a set
     `GH_CI_VARS_REPO` in the caller's environment cannot hijack `do_spl_gh_wire`.
  2. **Zero shellcheck warnings:** an optional-arg `_gscv_repo` called with no args from
     `do_gh_set_ci_vars` triggers `SC2120` in `shellcheck -S warning -x` (measured and
     confirmed before switching `do_gh_set_ci_vars` to `_gscv_repo "${GH_CI_VARS_REPO:-}"`,
     which cleared `SC2120` to rc 0).
- `_sgw_apply` (`:91-102`) keeps its own `declare -F _gscv_set` guard so direct callers of
  `_sgw_apply` stay self-contained; `do_spl_gh_wire` adds its own `declare -F _gscv_repo`
  guard right before calling `_gscv_repo "${GH_WIRE_REPO:-}"`.
- No test calls `_gscv_repo` or `_sgw_repo` directly (`git grep` -> 0 hits in `*/tests/*`).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `_gscv_repo` stays 5 lines,
  `do_spl_gh_wire` is 35 lines (from 32).

Shape (built as head2 of 1.5):
- `iac:src/bash/run/gh-set-ci-vars.func.sh`: add 1-line comment above `_gscv_repo`, switch
  `:29` from `${GH_CI_VARS_REPO:-}` / `$GH_CI_VARS_REPO` to `${1:-}` / `$1`, and switch
  `:70` (`do_gh_set_ci_vars`) from `repo="$(_gscv_repo)"` to
  `repo="$(_gscv_repo "${GH_CI_VARS_REPO:-}")"`. 79 -> 80 lines (`+3 -2`).
- `iac:src/bash/run/spl-gh-wire.func.sh`: delete `_sgw_repo()` and its trailing blank line
  (`:49-54`), and in `do_spl_gh_wire` replace `repo="$(_sgw_repo)"` (`:112`, now `:106`)
  with a 1-line comment, `# shellcheck source=gh-set-ci-vars.func.sh`,
  `declare -F _gscv_repo >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/gh-set-ci-vars.func.sh"`,
  and `repo="$(_gscv_repo "${GH_WIRE_REPO:-}")"`. 135 -> 132 lines (`+4 -7`).
- `iac:src/bash/tests/spl-gh-wire.tst.sh`: update header `:21` to name both `_gscv_set`
  and `_gscv_repo`, add 1 assertion in case 7 after `:173` proving
  `GH_CI_VARS_REPO=wrong/leak` does not leak into `do_spl_gh_wire`, and extend case 9
  (`:180-184`) to forbid `_sgw_get|_sgw_repo|actions/variables/|variable set|remote get-url origin`
  in non-comment lines of `spl-gh-wire.func.sh` and require both
  `_gscv_set "$repo" "$name" "$want" "$dry"` and `_gscv_repo "${GH_WIRE_REPO:-}"`.
  196 -> 199 lines (`+8 -5`).
- head2's files, sha256 (12 chars): `gh-set-ci-vars.func.sh` `aefa845e2afc`,
  `spl-gh-wire.func.sh` `3fda7f60db77`, `spl-gh-wire.tst.sh` `335537586b84`.
- Note for the row and its reviewer: build any red/guard control in a worktree, not a
  copy of `spl-gh-wire.func.sh` in a temp dir: the guard loads its sibling by
  `dirname "${BASH_SOURCE[0]}"`.

**Behaviour:** `_gscv_repo "${GH_CI_VARS_REPO:-}"` and `_gscv_repo "${GH_WIRE_REPO:-}"`
execute the exact same override check and `git remote get-url origin` `sed` pipeline;
`gh-set-ci-vars.tst.sh`, `spl-gh-wire.tst.sh`, `git-env-isolation.tst.sh`, and
`route-ci-overflow.tst.sh` pass on base and head2 with identical counts plus the new
isolation check in `spl-gh-wire.tst.sh` (1.5).

### 1.5 Before and on the rows' heads

2026-11-24T08:58:47Z-09:05:44Z (full 29-suite matrix on base, head1 and initial head2,
plus `shellcheck` and controls `rc1`/`gc1`), and 09:06:47Z-09:09:49Z (updated SC2120-free
head2 across all 12 row-02/shared suites, `shellcheck -S warning -x`, `do_sec_shellcheck`
on both heads, and `rc2`/`gc2`), n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, `timeout 900` each; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to
base: same rc, pass and fail counts.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `sa:tests/test-fleet-send.sh` | 01 | 0 / 105 / 0 | 0 / 112 / 0 (+7 new checks) | = |
| `orc:src/bash/tests/asks.tst.sh` | 01 | 0 / 103 / 0 | = | = |
| `sa:tests/test-spool-send.sh` | 01 | 0 / 78 / 0 | = | = |
| `sa:tests/test-spool-send-relay-outbox.sh` | 01 | 0 / 37 / 0 | = | = |
| `sa:tests/test-spool-send-wrong-box.sh` | 01 | 0 / 43 / 0 | = | = |
| `sa:tests/test-spool-send-topic.sh` | 01 | 0 / 17 / 0 | = | = |
| `sa:tests/test-spool-send-from-guard.sh` | 01 | 0 / 28 / 0 | = | = |
| `sa:tests/test-spool-send-owner-topic.sh` | 01 | 0 / 42 / 0 | = | = |
| `sa:tests/test-spool-send-empty-body.sh` | 01 | 0 / 20 / 0 | = | = |
| `sa:tests/test-desk-user-hops.sh` | 01 | 0 / 19 / 0 | = | = |
| `sa:tests/test-spool-cli-gomaxprocs.sh` | 01 | 0 / 7 / 0 | = | = |
| `sa:tests/test-spool-notify-orch.sh` | 01 | 0 / 35 / 0 | = | = |
| `sa:tests/test-spool-kinds.sh` | 01 | 0 / 48 / 0 | = | = |
| `sa:tests/test-spool-test-guard.sh` | 01 | 0 / 20 / 0 | = | = |
| `orc:src/bash/tests/desk-user-hops.tst.sh` | 01 | 0 / 217 / 0 | = | = |
| `orc:src/bash/tests/fleet-relay-desk-moved.tst.sh` | 01 | 0 / 18 / 0 | = | = |
| `orc:src/bash/tests/spool-send-desk-root.tst.sh` | 01 | 0 / 20 / 0 | = | = |
| `iac:src/bash/tests/spl-gh-wire.tst.sh` | 02 | 0 / 18 / 0 | = | 0 / 19 / 0 (+1 isolation; case 9 updated) |
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

`shellcheck -S warning -x` on all 7 row files (base, head1, final head2): **rc 0**, no
findings (n=1 each). `do_sec_shellcheck` with newline-separated `SEC_SHELLCHECK_FILES` set
to each row's touched files (head1: 4 scripts; head2: 3 scripts): **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `48bc8bb6a`):
- Row 01 red control (`rc1`, head1's `test-fleet-send.sh` on base): rc 1, 105 pass, 7 fail
  (`spool_fleet_peers_on: command not found` x4, plus
  `FAIL - 8. one copy: asks.sh and spool-send.sh keep no own peers switch`,
  `FAIL - 8. one copy: asks.sh calls spool_fleet_peers_on`,
  `FAIL - 8. one copy: spool-send.sh calls spool_fleet_peers_on`); head1: rc 0, 112 pass,
  0 fail.
- Row 01 wiring control (`gc1`, head1 with `spool_fleet_peers_on` omitted from
  `spool-fleet.inc.sh`): `test-fleet-send.sh` rc 1, 93 pass, 19 fail (all section-8
  peers routing assertions fail alongside the direct checks, proving `spool-send.sh`
  genuinely dispatches through `spool_fleet_peers_on`).
- Row 02 red control (`rc2`, head2's `spl-gh-wire.tst.sh` on base): rc 1, 17 pass, 1 fail,
  `FAIL: 9. one copy: spl-gh-wire.func.sh keeps its own variable apply or repo parse, or no call of _gscv_set/_gscv_repo: 49:_sgw_repo() { 51:  local url; url="$(git -C "$APP_PATH" remote get-url origin 2>/dev/null)" || return 0 112:  repo="$(_sgw_repo)"`;
  head2: rc 0, 19 pass, 0 fail.
- Row 02 guard control (`gc2`, head2 with the `declare -F _gscv_repo` line deleted in
  `spl-gh-wire.func.sh`): rc 13, 5 pass, 13 fail (including `FAIL: 1. dry run`,
  `FAIL: 3. set`, `FAIL: 7. GH_WIRE_REPO`, `FAIL: 8. oap`), with
  `.../spl-gh-wire.func.sh: line 108: _gscv_repo: command not found`.

The tests that name the sites (R2): `git grep -lE` over `*/tests/*` and `*shard-weights*`
for `asks_peers_on|send_to_peers_on|spool-fleet|asks\.sh|SPOOL_TO_PEERS` and `spool-send`
direct suites -> the 17 row-01 suites above (plus the shared orc/iac gates; other tests
that only invoke `spool-send.sh` as a generic fixture run in CI's `orc-features` /
`orc-suite` jobs); for
`spl-gh-wire|gh-set-ci-vars|_sgw_|_gscv_|do_spl_gh_wire|do_gh_set_ci_vars` ->
`spl-gh-wire.tst.sh`, `gh-set-ci-vars.tst.sh`, `git-env-isolation.tst.sh`,
`route-ci-overflow.tst.sh` (plus the shared iac/orc gates). 30-char comment grep across
`*/tests/*` -> 0 hits for both sites. No new test file is added, so `orc-shard-weights.txt`
needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r96-01-orc-fleet-peers-on)` | one fact, one copy (developer guide 2.2.4) | `asks_peers_on` (`sa:scripts/asks.sh:46-50`) and `send_to_peers_on` (`sa:scripts/spool-send.sh:267-271`) duplicate the 3-line peers switch byte for byte; both scripts already source `sa:lib/spool-fleet.inc.sh` (1.3, r95 section 7) | `sa:lib/spool-fleet.inc.sh` (header `:29`, new `spool_fleet_peers_on` before `:94`)<br>`sa:scripts/asks.sh:45-51,122`<br>`sa:scripts/spool-send.sh:265-272,401`<br>`sa:tests/test-fleet-send.sh` (7 checks before `:361`) | definitions of the `SPOOL_TO_PEERS` / `peer/seats` peers switch 2 -> 1 | 1.3's shape. **Red control:** head's `test-fleet-send.sh` on parent FAILs all 7 new checks (rc 1, 105 pass, 7 fail, 1.5), then GREEN (rc 0, 112 pass, 0 fail); wiring control (omitting `spool_fleet_peers_on` from `spool-fleet.inc.sh`: rc 1, 93 pass, 19 fail), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 7 new checks. Tests: `sa:tests/test-fleet-send.sh`, `orc:.../asks.tst.sh`, `sa:tests/test-spool-send.sh`, `test-spool-send-relay-outbox.sh`, `test-spool-send-wrong-box.sh`, `test-spool-send-topic.sh`, `test-spool-send-from-guard.sh`, `test-spool-send-owner-topic.sh`, `test-spool-send-empty-body.sh`, `test-desk-user-hops.sh`, `test-spool-cli-gomaxprocs.sh`, `test-spool-notify-orch.sh`, `test-spool-kinds.sh`, `test-spool-test-guard.sh`, `orc:.../desk-user-hops.tst.sh`, `fleet-relay-desk-moved.tst.sh`, `spool-send-desk-root.tst.sh`, `orc:.../no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r96-02-iac-gh-wire-repo-parse)` | one fact, one copy (developer guide 2.2.4) | after r95-02, `_sgw_repo` (`spl-gh-wire.func.sh:49-53`) and `_gscv_repo` (`gh-set-ci-vars.func.sh:28-32`) still duplicate the 3-line override + `git remote get-url origin` parser, differing only in env var name (1.4, r95 section 7) | `iac:src/bash/run/gh-set-ci-vars.func.sh:28-32,70`<br>`iac:src/bash/run/spl-gh-wire.func.sh:49-54,112`<br>`iac:src/bash/tests/spl-gh-wire.tst.sh:21,173,180-184` | copies of the GitHub origin `<owner>/<repo>` parser in this pair 2 -> 1 | 1.4's shape. **Red control:** head's `spl-gh-wire.tst.sh` on parent FAILs case 9 naming `:49` `_sgw_repo`, `:51` `remote get-url origin`, `:112` (rc 1, 17 pass, 1 fail, 1.5), then GREEN (rc 0, 19 pass, 0 fail); guard control (the `declare -F _gscv_repo` line deleted: rc 13, 5 pass, 13 fail with `_gscv_repo: command not found`), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 1 new isolation check. Tests: `iac:.../spl-gh-wire.tst.sh`, `gh-set-ci-vars.tst.sh`, `git-env-isolation.tst.sh`, `no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `orc:.../route-ci-overflow.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r96-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r96-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row removes a duplicate helper copy and points its callers at the single
home; no output, exit code, path or file a caller sees changes (1.3, 1.4, 1.5). Each:
`Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `sa:lib/spool-fleet.inc.sh`, `sa:scripts/asks.sh`, `sa:scripts/spool-send.sh`,
  `sa:tests/test-fleet-send.sh`; row 02: `csi-spl-iac` `gh-set-ci-vars.func.sh`,
  `spl-gh-wire.func.sh`, `spl-gh-wire.tst.sh`).
- No row edits `orc:src/bash/run/spl-unanswered-sweep.func.sh`, `orc:src/bash/tests/asks.tst.sh`,
  `iac:src/bash/tests/gh-set-ci-vars.tst.sh`, `orc:src/bash/run/route-ci-overflow.func.sh`,
  any other `iac:src/bash/run/*gh*.func.sh`, `.shellcheck-warning-baseline.txt`,
  `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform, `csi-spl-api/` or
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (9, the 7 edited + `orc:src/bash/tests/asks.tst.sh` + `iac:src/bash/tests/gh-set-ci-vars.tst.sh`):
`sa:lib/spool-fleet.inc.sh`, `sa:scripts/asks.sh`, `sa:scripts/spool-send.sh`,
`sa:tests/test-fleet-send.sh`, `orc:src/bash/tests/asks.tst.sh`;
`iac:src/bash/run/gh-set-ci-vars.func.sh`, `iac:src/bash/run/spl-gh-wire.func.sh`,
`iac:src/bash/tests/spl-gh-wire.tst.sh`, `iac:src/bash/tests/gh-set-ci-vars.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent a-025`, one call per
  path, n=1, 2026-11-24T08:49:23Z-08:49:48Z: **exit 4 on all 9** ("no live lane lists
  <path>, but 11 live lane(s) record no files"). The 11 `unknown:` lanes, all on the
  other box (`lane-map.sh list --all`, 08:47:35Z): the 6 private-channel seats c-029,
  c-041, c-146, c-187, c-924, c-927 (`*-rotate`), the workspace seat c-086 (`*-rotate`),
  spec 181 B9 follow-up c-678 (hub invoices/purge), phone Back bug c-680 (wui), and R7
  reviewers g-565 (B11) and g-666 (SPL-5006 W3). No lane owns any of the 9 paths; none
  of those scopes touches `spawn-agents/lib/spool-fleet.inc.sh`, `asks.sh`,
  `spool-send.sh`, or `iac/src/bash/run/gh-*` / `spl-gh-wire.func.sh`.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 08:46:51Z-08:47:25Z):
  6 queued, 0 placing: this round's mistral panel seat
  (`c002-refactor-round-96-mistral-panel-seat`, 1/6), spec 186 v0.6 + build planners for
  specs 186, 153, 187, and spec 149 delete-synced-in-google (all doc/spec lanes). Share
  line: refactor 3 of 16 known live lanes, 18% (band 10-20%: ok); phase day; last 24 h
  10% (band 20-30%: UNDER). Re-checked at 09:09:03Z: 5 queued, 0 placing (panel seat live
  as m-028).
- **Briefs on this box** changed in the last 24 h (150) naming any of the 9 paths or their
  functions (08:49:48Z): **9**, only closed/landed round briefs (`b42`, `r93-01`,
  `r94-01`, `r94-02`, `r95-02`, their R7 briefs), `tmp-inodes-box-op`, and
  `reflection-2026-11-23.md`. None live on any row path.
- **Remote branches committed in the last 24 h** (19 besides master after
  `git fetch --prune origin`, 08:49:48Z):
  `git diff --name-only $(git merge-base 48bc8bb6a <b>) <b> -- <the 9 paths>` -> **1 hit**,
  only `origin/review/r95-02` (already landed on trunk as `aea828942`, waiting for R8
  prune); **0 live or unlanded branches**.
- **Commits in the last 24 h** on those 9 paths (`git log 48bc8bb6a --since='24 hours ago'`)
  -> **2**: `ffe718a28` (r94-01) and `aea828942` (r95-02), both landed and closed.
- **Live or queued lanes named in the brief:** spec 181 B9 follow-up c-678 (hub), B11
  c-918 (signin relay; R7 g-565), SPL-5070 Nuxt 4 c-980 (wui), SPL-5006 W3 c-978 (landed
  `48bc8bb6a`, tf 053 apply pending; R7 g-666), phone Back bug c-680 (wui), cost-labels
  agy review bug c-925, A2UI eval a-023 (doc only), spec 186 v0.6 and 186/153/187/149
  planners (queued, doc only), the 6 private-channel seats and c-086: none on a row path.

## 3. Per row: what the lane does

- **r96-01:** `sa:lib/spool-fleet.inc.sh` gains `spool_fleet_peers_on` (the 3-line
  `SPOOL_TO_PEERS` / `peer/seats` peers switch, with its header bullet); `sa:scripts/asks.sh`
  deletes `asks_peers_on` and calls `spool_fleet_peers_on`; `sa:scripts/spool-send.sh`
  deletes `send_to_peers_on` and calls `spool_fleet_peers_on` (both already source
  `spool-fleet.inc.sh`). `sa:tests/test-fleet-send.sh` adds 4 direct `spool_fleet_peers_on`
  assertions and 3 one-copy assertions proving neither script keeps its own peers switch
  and both call `spool_fleet_peers_on`.
- **r96-02:** `iac:src/bash/run/gh-set-ci-vars.func.sh`'s `_gscv_repo` takes its optional
  override as `$1` (`do_gh_set_ci_vars` passes `"${GH_CI_VARS_REPO:-}"`, keeping
  shellcheck SC2120 clean); `iac:src/bash/run/spl-gh-wire.func.sh` deletes `_sgw_repo`
  and in `do_spl_gh_wire` loads `gh-set-ci-vars.func.sh` behind a `declare -F _gscv_repo`
  guard and calls `_gscv_repo "${GH_WIRE_REPO:-}"`. `iac:src/bash/tests/spl-gh-wire.tst.sh`
  adds a case-7 check proving `GH_CI_VARS_REPO` does not leak into `do_spl_gh_wire`, and
  extends case 9 to prove neither `_sgw_repo` nor `remote get-url origin` remains in
  non-comment lines of `spl-gh-wire.func.sh` and that it calls `_gscv_repo "${GH_WIRE_REPO:-}"`.

## 4. Panel and reviewers (R7)

- Editor: a-025 (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the mistral seat `c002-refactor-round-96-mistral-panel-seat` (queued
  1/6 at 08:46:51Z, live as m-028 at 09:09:03Z). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-24T08:46:46Z printed
  `pick=<box> reason=every box is at or above its high mark; <box> is the least past its band (127% on high 90%, overflow 180%)`,
  grok weekly 92% on both boxes (not held): **a grok R7 seat per row**. The holder
  re-runs the pick when it places the rows, and a hold then gives the row a **claude
  waiver seat**, as r90..r95's section 4 say. Never a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r96-01 | `c002-r96-01-orc-fleet-peers-on` | `refactor(r96-01-orc-fleet-peers-on, SPL-<row issue>): ...` | `review/r96-01` | 1 |
| r96-02 | `c002-r96-02-iac-gh-wire-repo-parse` | `refactor(r96-02-iac-gh-wire-repo-parse, SPL-<row issue>): ...` | `review/r96-02` | 1 |

**r96-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spawn-agents/lib/spool-fleet.inc.sh` (header bullet above
`spool_fleet_relay` and new `spool_fleet_peers_on` before `spool_fleet_desk_configured`),
`csi-spl-orc/src/bash/features/spawn-agents/scripts/asks.sh` (delete `asks_peers_on`
`:45-51` and call `spool_fleet_peers_on` at `:122`),
`csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh` (delete
`send_to_peers_on` `:265-272` and call `spool_fleet_peers_on` at `:401`), and
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-fleet-send.sh` (append 4 direct
`spool_fleet_peers_on` checks + 3 one-copy checks before `t_done`). NOT
`spl-unanswered-sweep.func.sh`, NOT `asks.tst.sh`, NOT `.shellcheck-warning-baseline.txt`,
or any other test. Do: plan section 2 row 01 verbatim, 1.3's shape; the red control (the
head's `test-fleet-send.sh` on the parent) RED then GREEN in the body; the wiring control
(head without `spool_fleet_peers_on` in `spool-fleet.inc.sh`, built in a worktree). Gates:
the row's tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x`
on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r96-02 brief, Files: ONLY**
`csi-spl-iac/src/bash/run/gh-set-ci-vars.func.sh` (`_gscv_repo` `:28-32` reads override
from `$1` with 1-line comment; `do_gh_set_ci_vars` `:70` calls
`_gscv_repo "${GH_CI_VARS_REPO:-}"`),
`csi-spl-iac/src/bash/run/spl-gh-wire.func.sh` (delete `_sgw_repo` `:49-54`; in
`do_spl_gh_wire` `:112`, add `declare -F _gscv_repo` guard loading `gh-set-ci-vars.func.sh`
and call `_gscv_repo "${GH_WIRE_REPO:-}"`; keep `_sgw_apply`'s `declare -F _gscv_set`
guard), and `csi-spl-iac/src/bash/tests/spl-gh-wire.tst.sh` (header `:21`, case-7
`GH_CI_VARS_REPO` no-leak check after `:173`, and case 9 `:180-184` guarding both
`_gscv_set` and `_gscv_repo`, filtering `#` comment lines). NOT `gh-set-ci-vars.tst.sh`,
NOT `route-ci-overflow.func.sh`, NOT any other `iac/src/bash/run/*gh*.func.sh` or other
test. Do: plan section 2 row 02 verbatim, 1.4's shape; the red control (the head's test
on the parent) RED then GREEN in the body; the guard control (the `declare -F _gscv_repo`
line deleted: 13 checks fail, built in a worktree, not a temp-dir copy). Gates: the row's
tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 3
files, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| definitions of the `SPOOL_TO_PEERS` / `peer/seats` peers switch (1.3) | 2 on `48bc8bb6a` (`asks_peers_on`, `send_to_peers_on`) -> 1 (`spool_fleet_peers_on`) after row 01 |
| copies of the GitHub origin `<owner>/<repo>` parser in the `gh-set-ci-vars` / `spl-gh-wire` pair (1.4) | 2 on `48bc8bb6a` (`_gscv_repo`, `_sgw_repo`) -> 1 (`_gscv_repo`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spool-fleet.inc.sh` +12 -0, `asks.sh` +1 -8, `spool-send.sh` +1 -9, `test-fleet-send.sh` +11 -0; row 02: `gh-set-ci-vars` +3 -2, `spl-gh-wire` +4 -7, `spl-gh-wire.tst.sh` +8 -5 |
| measured on | `48bc8bb6a`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| the other 5 `iac:src/bash/run/` GitHub origin `<owner>/<repo>` parsers (`_gpac_repo` in `gh-prune-actions-caches.func.sh:26-30`, `_sga_repo` in `spl-gh-app-manifest.func.sh:90-94`, `_sgmr_repo` in `spl-gh-master-ruleset.func.sh:61-65` using `$APP_PATH`; `gh_box_token_repo` in `gh-box-token-check.func.sh:82-86` and `gh_secret_put_gcp_key_repo` in `gh-secret-put-gcp-key.func.sh:67-71` using `${APP_PATH:-.}`) | clean candidate for r97+: the 3 non-secret `$APP_PATH` actions (or a shared `iac/lib/bash/funcs/` helper for non-secret callers) can fold into one origin-repo parser; `gh-secret-put-gcp-key.func.sh` is secret-class and stays separate; left out of r96-02 so r96-02 stays in the already-wired 2-action pair (3 files) | `git grep -n 'remote get-url origin' 48bc8bb6a -- csi-spl-iac/` |
| `spl_sweep_seated` (`orc:src/bash/run/spl-unanswered-sweep.func.sh:197-200`) and its `:196` comment naming `send_to_peers_on` | does not check `SPOOL_TO_PEERS` (not byte-identical to `spool_fleet_peers_on`) and `unanswered-sweep.tst.sh` carries an open candidate note (`c002-next-round-candidates.md:58`); updating the `:196` comment or extracting a shared `peer/seats` parser is a small follow-up for r97+ | `git grep -nE 'peer/seats|send_to_peers_on' 48bc8bb6a` |
| other `LEASE_(MASTER|FAILOVER|ORCH)` sites (`sa:scripts/lane-age-report.sh:33`, `orc:src/bash/run/spl-box-leave.func.sh:298`, `orc:src/bash/run/spl-lane-backfill-links.func.sh:78`) | not byte-identical to `send_role_seat` (different path vars); unchanged since r94 | r95 7; 1.2 (a) |
| `csi-spl-doc/specs/172-work-chain-enforcement/spec.md:173` (`lane_is_role_seat` prose) and `i18n-lang-review-exempt.json:2` `_doc` | prose / doc strings, not code copies; unchanged since r94 | r95 7; 1.2 (a) |
| Go duplicate helpers in `csi-spl-api/src/go/spool-hub-api` (`internal/store`, `keyd`/`lockkey`) | cross-package or store/security-tier (`PRE_PUSH_TIER=full` Postgres gate, live spec-181 store lanes): not measured here | r95 7; 1.2 (a) |
| the 10 remaining 2+ line / >=40-char Bash groups (`do_gcp_*_apis_disable`, `spl_uplink_trim`/`ext_api_trim`, `spl_secrets_none_get`/`spl_self_host_env_get`, `tf_get`, `ndf_link`/`ndp_link`, 7 `_sec_*_need`, `spl_brx_gh_auth`/`ghrh_gh_auth`, `ghr_in` family, `spl_asks_dur`/`spl_fleet_dur`, `_lc_deps`/`_spl_box_leave_deps`) | unchanged since r95 (`48bc8bb6a`), each stays out for its r91..r95 section 7 reason | r95 7, r94 7, r93 7, r92 7, r91 7; 1.2 (a), (e) |

## 8. Changes

- v0.1 (a-025): the rows and every read on `48bc8bb6a`; both heads built in detached
  scratch worktrees; the 29-suite column of 1.5 run on base and both heads; `shellcheck`
  and `do_sec_shellcheck` rc 0 (with `_gscv_repo` parameterised via `$1` to stay
  SC2120-free and leak-free); the red and guard/wiring controls RED; R3 (2.2) and R7
  (section 4) checked.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-025 (agy): v0.1 (pending panel sign).
- Panel reviewer seat: m-028 (mistral, `c002-refactor-round-96-mistral-panel-seat`):
  pending review of v0.1 on `review/c002-refactor-round-96-planner`.
- Row R7 seats: section 4 (grok per row unless held at placement, else claude waiver).
