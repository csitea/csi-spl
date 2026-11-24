# Refactoring round 97 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6384  
Topic: 44cd9885-8d4f-451f-8f1f-7b497385002d  
Discussion: 44cd9885-8d4f-451f-8f1f-7b497385002d (t1 #refactoring, "Refactor round 97", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r97**, plan `refactor-round-97-plan.md`, rows `r97-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 96 ([refactor-round-96-plan.md](refactor-round-96-plan.md))
is closed: both rows landed on trunk (r96-01 `09f137d40`, SPL-6370; r96-02 `90a2c384f`,
SPL-6373), and its editor a-025 landed the r96 close record `9a85c02b5` (`Closes: SPL-6358`).
This planner writes no r96 close record and touches no r96 file. The perf floor
(rulebook 4.4), measured on `6d81d4447` at 2026-11-24T15:50:31Z (14 days): perf 29,
refactor 100, 22.5%, 5 x 29 = 145 >= 129, floor-met (matching the holder c-002's read on
`09f137d40`), so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91..r96: a
duplicated helper body that exists in multiple places loses its duplicate copy, and each
caller calls the single home.
**Row 01:** after r96-01 folded `asks_peers_on` and `send_to_peers_on` into
`spool_fleet_peers_on` in `sa:lib/spool-fleet.inc.sh`, `spl_sweep_seated`
(`orc:src/bash/run/spl-unanswered-sweep.func.sh:197-200`) still duplicates the exact
`peer/seats` seat-line existence check (`sed 's/#.*//' "$f" | awk '$1 ~ /^[acgmq]-[0-9][0-9][0-9]$/ && $2 ~ /^[a-z]+$/ { f = 1 } END { exit !f }'`)
and carries the stale `:196` comment naming the deleted `send_to_peers_on` (r96-01 R7
g-071 N1, r96 plan section 7, and the dispatcher candidates file's `for refactor round 97`
entry). Extracting `spool_fleet_has_seats [root]` into `sa:lib/spool-fleet.inc.sh` lets
`spool_fleet_peers_on` delegate its seat check (`spool_fleet_has_seats "${SPOOL_ROOT:-}"`)
and lets `spl_sweep_seated` lazy-source `spool-fleet.inc.sh` behind a
`declare -F spool_fleet_has_seats` guard and call
`spool_fleet_has_seats "${SPOOL_ROOT:-/var/spool-hub}"`, keeping `SPOOL_TO_PEERS`
isolated from the sweep and dropping both the duplicate parser and the stale comment.
**Row 02:** after r96-02 parameterised `_gscv_repo` (`iac:src/bash/run/gh-set-ci-vars.func.sh:29-33`)
to take its optional override as `$1` and folded `_sgw_repo` (`spl-gh-wire.func.sh`) into
it, the two remaining non-secret `$APP_PATH` GitHub origin `<owner>/<repo>` parsers in
`iac:src/bash/run/` — `_gpac_repo` (`gh-prune-actions-caches.func.sh:26-30`, override
`GH_CACHE_PRUNE_REPO`) and `_sgmr_repo` (`spl-gh-master-ruleset.func.sh:61-65`, override
`GH_RULESET_REPO`; r96 plan section 7) — still duplicate the same 3-line parser. Both
actions drop their local helper, lazy-source `gh-set-ci-vars.func.sh` behind a
`declare -F _gscv_repo` guard, and call `_gscv_repo` with their own override var (zero
edits to `gh-set-ci-vars.func.sh`, zero secret-class sites touched). The rows share no
file (orc vs iac): both are batch 1.

**Status: v0.1, for the panel (section 4).** Rows queue once the panel signs the plan sha
and its review line passes `do_spl_review_line_check` (rc 0, rulebook 1.4 / 3.2 / 5.2).
Editor: **a-158** (agy).

**One sha:** every count is measured on **`6d81d4447`** (`6d81d444748398c86657a582efd57db89ed1d715`,
`origin/master` at 2026-11-24T15:50:31Z), n=1 per command unless stated. Reads are on
`6d81d4447` with `git show` / `git grep`. The tests of 1.5 ran in detached scratch
worktrees of `6d81d4447` (not committed, removed on exit): "base" unmodified, "head1" =
base with row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's
shape; each red and guard control (1.5) ran in a detached worktree of its own. Queue,
lane map, brief and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-24T15:50:31Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-24T14:16:54+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r96-plan'`:
  `9a85c02b5` (`docs(r96-plan, SPL-6358): refactor round 96 closed: r96-01 09f137d40 and r96-02 90a2c384f landed, grok R7 PASS each on the reviewed head (patch-id equal)`),
  read once at the start as 5.3 says.
- `git log origin/master --since="$W" --oneline -E --grep='\(r97-' | wc -l` -> **0**
  (over all history -> **0**).
- `git ls-remote origin 'refs/heads/review/r97-*' 'refs/heads/*-r97-*' 'refs/heads/*refactor-round-97*' 'refs/heads/wip/*r97*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r97|refactor-round-97'` -> this plan's
  brief (`c002-refactor-round-97-planner.md`) and the panel seat's
  (`c002-refactor-round-97-mistral-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-97`
  -> **0**: the plain name is free.

### 1.2 The brief's inputs, re-measured

- **(a) r96 section 7:** re-read on `6d81d4447`.
  - `spl_sweep_seated` (`orc:src/bash/run/spl-unanswered-sweep.func.sh:197-200`) and its
    `:196` comment naming `send_to_peers_on`: measured here as **row 01** (1.3).
    `unanswered-sweep.tst.sh` runs cleanly as the push user on `6d81d4447` (0 / 71 / 0,
    no section-12 failure; the earlier note in `c002-next-round-candidates.md:58` does
    not reproduce on `6d81d4447`).
  - The other 5 `iac:src/bash/run/` GitHub origin `<owner>/<repo>` parsers:
    `_gpac_repo` (`gh-prune-actions-caches.func.sh:26-30`) and `_sgmr_repo`
    (`spl-gh-master-ruleset.func.sh:61-65`) are non-secret `$APP_PATH` actions and are
    measured here as **row 02** (1.4). The other 3 (`_sga_repo` in
    `spl-gh-app-manifest.func.sh:90-94`, which writes a 0600 GitHub App `.pem` private
    key and stores it in Secret Manager; `gh_box_token_repo` in
    `gh-box-token-check.func.sh:82-86`, which reads the box GitHub token; and
    `gh_secret_put_gcp_key_repo` in `gh-secret-put-gcp-key.func.sh:67-71`, which writes
    GCP SA keys) are secret-class sites and stay out (section 7).
  - `git diff --name-only 48bc8bb6a 6d81d4447` (120 files across 47 commits: r96 plan /
    rows `09f137d40` & `90a2c384f` / close `9a85c02b5`, b44 plan & `14b6055c2`, spec 192
    v0.1-v0.3, spec 186 build plan & M1 `34ae3ef15` & M9, spec 153 build plan & Q9
    `17296f20a` & Q12 `6d7c9e73d` & 3.30 `37e0b241e`, spec 181 B11 `61869b56f`..`50dbdaa6d`,
    SPL-5070 Nuxt 4 migration `ee4ba63d9`..`6d81d4447`): touches none of r91..r96 section
    7's remaining items, so each stays out for its reason there (section 7).
- **(b) R7 and panel notes:**
  - r96-01 R7 (`g-071`, commit `09f137d40`, read via `git show`): N1
    `orc:src/bash/run/spl-unanswered-sweep.func.sh:196` still names `send_to_peers_on`
    -> directly served by **row 01** (1.3); N2 missing `spool-fleet.inc.sh` broken-tree
    note only.
  - r96-02 R7 (`g-063`, commit `90a2c384f`, read via `git show`): N1-N5 verification
    notes only (comment/layout sha256 deltas, 7-origin `PAIR_MATCH`, sibling lazy-source
    guard verified). No refactor row.
  - r96 panel (`m-028`, recorded in r96 plan v1.0 `dbd127c96`): PASS on `4daa11721`, no W,
    notes N1..N4 verification notes only. No refactor row.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 134 lines, read 15:50Z):
  - Its one new block is `## for refactor round 97` (`:133-134`, r96-01 R7 `g-071` N1:
    `spl-unanswered-sweep.func.sh:196` still names `send_to_peers_on`): served by
    **row 01** (1.3).
  - Earlier refactor-shaped entries checked on `6d81d4447`: `reverse-tunnel-cron.sh:25-27`
    already derives the state dir via `spl_run_paths`; `agent-boot-restore`
    (`spl-watchdog.func.sh:541` and `spl-agent-boot-restore-install-cron.func.sh:60`)
    already use `spl_var_app_subdir`; `spl-lane-mix.func.sh:45-48,140,404` already name
    `do_spl_lang_review_gct` with agy optional. Bug/test entries are not refactor rows.
- **(d) spec 011 tasks:**
  `git log 6d81d4447 --since=2026-11-24T08:46:44Z -- csi-spl-doc/specs/011-spool-project-refactor`
  -> 0; the open tasks (T001-T008 owner-deferred, T018-T021, T023, T027, T034) are each
  wider than one row or await an owner decision.
- **(e) A fresh scan for byte-identical function bodies** on `6d81d4447` over all 1,235
  tracked non-test `*.sh` files under `csi-spl-orc/src/bash`, `csi-spl-orc/lib`,
  `csi-spl-iac/src/bash`, `csi-spl-iac/lib`, `csi-spl-utl/src/bash` and `src/bash`
  (`run.sh` / `print-help.func.sh` excluded; `name() { ... }` bodies whitespace-trimmed,
  own name masked, >= 2 lines or 1 line >= 40 chars):
  - Excluding the intentional `csi-spl-iac/lib/bash/funcs/` <-> `csi-spl-orc/lib/bash/funcs/`
    framework mirror and 1-line local log/assert shims (`say`, `refuse`, `log`, `ok`,
    `no`, `restore_args`, `_frd_log`/`_qdd_log`, `is_held`), the **10** remaining
    cross-file groups (`do_gcp_*_apis_disable`, `spl_uplink_trim`/`ext_api_trim`,
    `spl_secrets_none_get`/`spl_self_host_env_get`, `tf_get` x2, `ndf_link`/`ndp_link`,
    7 `_sec_*_need`, `spl_brx_gh_auth`/`ghrh_gh_auth`, `ghr_in` family,
    `spl_asks_dur`/`spl_fleet_dur`, `_lc_deps`/`_spl_box_leave_deps`) are unchanged from
    r91..r96 section 7 (down from 11 after r96-01 landed), and each stays out for its
    reason there.

### 1.3 Row 01's site: `spl_sweep_seated` and `spool_fleet_peers_on` share `spool_fleet_has_seats` in `spool-fleet.inc.sh`

`orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`. On `6d81d4447`:

- `sa:lib/spool-fleet.inc.sh:100-104`: `spool_fleet_peers_on` checks `SPOOL_TO_PEERS`,
  then tests `[ -r "$SPOOL_ROOT/peer/seats" ] && sed 's/#.*//' "$SPOOL_ROOT/peer/seats" | awk '$1 ~ /^[acgmq]-[0-9][0-9][0-9]$/ && $2 ~ /^[a-z]+$/ { f = 1 } END { exit !f }'`.
- `orc:src/bash/run/spl-unanswered-sweep.func.sh:195-200`: `spl_sweep_seated` sets
  `local f="${SPOOL_ROOT:-/var/spool-hub}/peer/seats"` and runs the exact same
  readability + `sed`/`awk` seat-line existence check, under the stale `:196` comment
  `parsed as spool-send.sh's send_to_peers_on does.` (r96-01 deleted `send_to_peers_on`).
  `diff -u <(printf '%s\n' "$(git show 6d81d4447:csi-spl-orc/src/bash/features/spawn-agents/lib/spool-fleet.inc.sh | sed -n '102,103p' | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g; s/ $//; s#\$SPOOL_ROOT/peer/seats#\$f#g; s/^\[ /[[ /; s/ \]/ ]]/')") <(git show 6d81d4447:csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh | sed -n '199p' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g; s/ $//')`
  -> no hunk (rc 0, n=1): the seat-line existence checks are **identical**.
- `spool_fleet_has_seats` has **0 collisions** anywhere in the repo (`git grep` -> 0);
  `spool-fleet.inc.sh` contains only function definitions (zero top-level code or var
  assignments), so lazy-sourcing it inside `spl_sweep_seated` keeps
  `spl-unanswered-sweep.func.sh` lazy (`run-lazy-loader.tst.sh` and
  `run-eager-files.tst.sh` pass unchanged).
- `spl_sweep_seated` intentionally does **not** check `SPOOL_TO_PEERS` (only
  `peer/seats`), so extracting `spool_fleet_has_seats` (without `SPOOL_TO_PEERS`) and
  having `spool_fleet_peers_on` call `spool_fleet_has_seats "${SPOOL_ROOT:-}"` while
  `spl_sweep_seated` calls `spool_fleet_has_seats "${SPOOL_ROOT:-/var/spool-hub}"`
  preserves both semantics exactly — including `SPOOL_TO_PEERS=0` leaving
  `spl_sweep_seated` unaffected, unset `SPOOL_ROOT` returning 1 in
  `spool_fleet_peers_on` and defaulting to `/var/spool-hub` in `spl_sweep_seated`, and
  passing `$1` explicitly keeping `shellcheck -S warning -x` SC2120-free.
- `spl-unanswered-sweep.func.sh` already resolves its sibling `spawn-agents/lib/` via
  `$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/` at
  `:119`. Line-cap check (`bash-cleancode.tst.sh`, cap 75): `spool_fleet_has_seats` is 5
  lines, `spool_fleet_peers_on` is 4 lines, `spl_sweep_seated` is 6 lines. None of the 4
  files has any entry in `.shellcheck-warning-baseline.txt` or
  `no-literal-paths.baseline`.

Shape (built as head1 of 1.5):
- `sa:lib/spool-fleet.inc.sh`: add the 3-line `spool_fleet_has_seats [root]` header
  bullet above `spool_fleet_peers_on` (`:29`), define `spool_fleet_has_seats()` above
  `spool_fleet_peers_on` (`:97`), and change `spool_fleet_peers_on` to call
  `spool_fleet_has_seats "${SPOOL_ROOT:-}"` (with comment naming `spool_fleet_has_seats`).
  141 -> 152 lines (`+15 -4`).
- `orc:src/bash/run/spl-unanswered-sweep.func.sh`: update `:196` comment to name
  `spool-fleet.inc.sh`'s `spool_fleet_has_seats`, and replace `spl_sweep_seated`'s body
  (`:198-199`) with `# shellcheck source=../features/spawn-agents/lib/spool-fleet.inc.sh`,
  `declare -F spool_fleet_has_seats >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/spool-fleet.inc.sh"`,
  and `spool_fleet_has_seats "${SPOOL_ROOT:-/var/spool-hub}"`. 628 -> 630 lines (`+5 -3`).
- `sa:tests/test-fleet-send.sh`: append 6 assertions before `t_done` (`:372`): 4 direct
  checks of `spool_fleet_has_seats` (seat line in `SPOOL_ROOT` -> 0, no `peer/seats` ->
  1, explicit root arg beats `SPOOL_ROOT` both on and off) and 2 one-copy checks
  (`spool-fleet.inc.sh` defines the `awk.*\[acgmq\]` parser once; `spool_fleet_peers_on`
  calls `spool_fleet_has_seats`). 372 -> 380 lines (`+8 -0`).
- `orc:src/bash/tests/unanswered-sweep.tst.sh`: append 2 checks at the end of section 11
  (after `:447`): `SPOOL_TO_PEERS=0` with a seat line still sends to peers (proving
  `spl_sweep_seated` calls `spool_fleet_has_seats`, not `spool_fleet_peers_on`), and one
  copy (`spl-unanswered-sweep.func.sh` has no `send_to_peers_on` or `awk.*\[acgmq\]`
  anywhere, and calls `spool_fleet_has_seats`). 467 -> 478 lines (`+11 -0`).
- head1's files, sha256 (12 chars): `spool-fleet.inc.sh` `2ec8cf1dcb3b`,
  `spl-unanswered-sweep.func.sh` `6a742249a713`, `test-fleet-send.sh` `c5670dfad1ed`,
  `unanswered-sweep.tst.sh` `34726995b649`.

**Behaviour:** `spool_fleet_has_seats` executes the exact readability + `sed`/`awk`
pipeline removed from `spool_fleet_peers_on` and `spl_sweep_seated`; `SPOOL_TO_PEERS`
stays isolated to `spool_fleet_peers_on`; all row-01 and shared suites pass on base and
head1 with identical counts plus the 6 + 2 new checks (1.5).

### 1.4 Row 02's site: `gh-prune-actions-caches.func.sh` and `spl-gh-master-ruleset.func.sh` share `_gscv_repo`

`iac:` = `csi-spl-iac/`. On `6d81d4447`:

- `iac:src/bash/run/gh-set-ci-vars.func.sh:29-33`: `_gscv_repo` (parameterised in r96-02)
  prints `${1:-}` if non-empty, else runs `git -C "$APP_PATH" remote get-url origin 2>/dev/null`
  and extracts `<owner>/<repo>` with `sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p'`.
  Needs **zero edits** in this row.
- `iac:src/bash/run/gh-prune-actions-caches.func.sh:26-30`: `_gpac_repo` has the exact
  same 3-line body with `GH_CACHE_PRUNE_REPO`; called only at `:57`
  (`do_gh_prune_actions_caches`).
- `iac:src/bash/run/spl-gh-master-ruleset.func.sh:61-65`: `_sgmr_repo` has the exact
  same 3-line body with `GH_RULESET_REPO`; called only at `:29`
  (`do_spl_gh_master_ruleset`).
  `diff -u <(git show 6d81d4447:csi-spl-iac/src/bash/run/gh-set-ci-vars.func.sh | sed -n '29,33p' | sed 's/_gscv_repo/_repo/; s/\${1:-}/${REPO_VAR:-}/; s/"\$1"/"$REPO_VAR"/') <(git show 6d81d4447:csi-spl-iac/src/bash/run/gh-prune-actions-caches.func.sh | sed -n '26,30p' | sed 's/_gpac_repo/_repo/; s/GH_CACHE_PRUNE_REPO/REPO_VAR/g')`
  -> no hunk (rc 0, n=1); the same diff against `spl-gh-master-ruleset.func.sh:61-65`
  (`_sgmr_repo`, `GH_RULESET_REPO`) -> no hunk (rc 0, n=1): all three bodies are
  **identical** up to the override env-var name.
- No other code file or test calls `_gpac_repo` or `_sgmr_repo` (`git grep -nE '_gpac_repo|_sgmr_repo' 6d81d4447 -- ':!*.md'` -> only those 2 definitions and their 2 calls).
- Both actions lazy-source `gh-set-ci-vars.func.sh` behind `declare -F _gscv_repo >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/gh-set-ci-vars.func.sh"`
  and pass their own override var (`_gscv_repo "${GH_CACHE_PRUNE_REPO:-}"` /
  `_gscv_repo "${GH_RULESET_REPO:-}"`):
  1. **Zero env-var leakage:** a set `GH_CI_VARS_REPO` in the caller's environment
     cannot affect either action.
  2. **Zero shellcheck warnings** and **lazy-loader safe**: `shellcheck -S warning -x`,
     `do_sec_shellcheck`, `run-lazy-loader.tst.sh`, `run-eager-files.tst.sh` all exit 0.
- Line-cap check (`bash-cleancode.tst.sh`, cap 75): `do_gh_prune_actions_caches` 40 -> 43
  lines; `do_spl_gh_master_ruleset` 36 -> 39 lines. None of the 4 files has any entry in
  `.shellcheck-warning-baseline.txt`.

Shape (built as head2 of 1.5):
- `iac:src/bash/run/gh-prune-actions-caches.func.sh`: delete `_gpac_repo()` and its
  trailing blank line (`:26-31`), and in `do_gh_prune_actions_caches` replace
  `repo="$(_gpac_repo)"` (`:57`, now `:51`) with a 1-line comment,
  `# shellcheck source=gh-set-ci-vars.func.sh`,
  `declare -F _gscv_repo >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/gh-set-ci-vars.func.sh"`,
  and `repo="$(_gscv_repo "${GH_CACHE_PRUNE_REPO:-}")"`. 89 -> 86 lines (`+4 -7`).
- `iac:src/bash/run/spl-gh-master-ruleset.func.sh`: delete `_sgmr_repo()` and its
  trailing blank line (`:61-66`), and in `do_spl_gh_master_ruleset` replace
  `local repo; repo="$(_sgmr_repo)"` (`:29`) with a 1-line comment,
  `# shellcheck source=gh-set-ci-vars.func.sh`,
  `declare -F _gscv_repo >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/gh-set-ci-vars.func.sh"`,
  and `local repo; repo="$(_gscv_repo "${GH_RULESET_REPO:-}")"`. 96 -> 93 lines (`+4 -7`).
- `iac:src/bash/tests/gh-prune-actions-caches.tst.sh`: add case 5d after `:113` proving
  `GH_CI_VARS_REPO=wrong/leak` does not leak when origin and `GH_CACHE_PRUNE_REPO` are
  absent, and append case 8 (after `:135`) forbidding `_gpac_repo|remote get-url origin`
  in non-comment lines of `gh-prune-actions-caches.func.sh` and requiring
  `_gscv_repo "${GH_CACHE_PRUNE_REPO:-}"`. 138 -> 147 lines (`+9 -0`).
- `iac:src/bash/tests/spl-gh-master-ruleset.tst.sh`: add cases 6b and 6c after `:97`
  proving origin-remote parse (https with `GH_CI_VARS_REPO=wrong/leak` not leaking, and
  ssh), and append case 7 forbidding `_sgmr_repo|remote get-url origin` in non-comment
  lines of `spl-gh-master-ruleset.func.sh` and requiring `_gscv_repo "${GH_RULESET_REPO:-}"`.
  100 -> 117 lines (`+17 -0`).
- head2's files, sha256 (12 chars): `gh-prune-actions-caches.func.sh` `162909aaa718`,
  `spl-gh-master-ruleset.func.sh` `9cf61ad95202`, `gh-prune-actions-caches.tst.sh`
  `8fbc6b728094`, `spl-gh-master-ruleset.tst.sh` `54b0b30593b8`.
- Note for the row and its reviewer: build any red/guard control in a worktree, not a
  copy of either `.func.sh` in a temp dir: the guard loads its sibling
  `gh-set-ci-vars.func.sh` by `dirname "${BASH_SOURCE[0]}"`.

**Behaviour:** `_gscv_repo "${GH_CACHE_PRUNE_REPO:-}"` and
`_gscv_repo "${GH_RULESET_REPO:-}"` execute the exact same override check and
`git remote get-url origin` `sed` pipeline; all row-02 and shared suites pass on base and
head2 with identical counts plus the 2 + 3 new checks (1.5).

### 1.5 Before and on the rows' heads

2026-11-24T16:08:53Z-16:29:28Z (full 25-suite matrix across base, head1 for row 01 +
shared, head2 for row 02 + shared, `shellcheck -S warning -x`, `do_sec_shellcheck`, and
controls `rc1a`/`rc1b`/`gc1`/`rc2a`/`rc2b`/`gc2a`/`gc2b`), plus 16:31Z rerun of
`asks.tst.sh` on head1 under `timeout 600` (after its initial `timeout 180` hit 88/0 on a
loaded box), n=1, as the push user, `SPOOL_TEST=1` with `SPOOL_BOX_TAG` and
`SPOOL_AGENT_ID` unset; pass lines `grep -ciE '^ *(ok|pass)'`, fail lines
`grep -ciE '^ *(not ok|fail)'`. "=" means equal to base: same rc, pass and fail counts;
"-" means that row's head does not touch the suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `sa:tests/test-fleet-send.sh` | 01 | 0 / 112 / 0 | 0 / 118 / 0 (+6 new checks) | - |
| `orc:src/bash/tests/unanswered-sweep.tst.sh` | 01 | 0 / 71 / 0 | 0 / 73 / 0 (+2 new checks) | - |
| `orc:src/bash/tests/unanswered-sweep-defer.tst.sh` | 01 | 0 / 7 / 0 | = | - |
| `orc:src/bash/tests/unanswered-sweep-skip-probe.tst.sh` | 01 | 0 / 4 / 0 | = | - |
| `orc:src/bash/tests/asks.tst.sh` | 01 | 0 / 103 / 0 | = (rerun `timeout 600`) | - |
| `sa:tests/test-spool-send.sh` | 01 | 0 / 78 / 0 | = | - |
| `sa:tests/test-desk-user-hops.sh` | 01 | 0 / 19 / 0 | = | - |
| `orc:src/bash/tests/fleet-relay-desk-moved.tst.sh` | 01 | 0 / 18 / 0 | = | - |
| `orc:src/bash/tests/spool-send-desk-root.tst.sh` | 01 | 0 / 20 / 0 | = | - |
| `orc:src/bash/tests/enc-dirs-untouched.tst.sh` | 01 | 0 / 18 / 0 | = | - |
| `orc:src/bash/tests/fleet-lease.tst.sh` | 01 | 124 / 185 / 0 (rerun `timeout 600`, 0 fail; initial `timeout 180` 117 / 0; row runs `timeout 900`) | 124 / 185 / 0 (rerun `timeout 600`, 0 fail; initial `timeout 180` 117 / 0) | - |
| `iac:src/bash/tests/gh-prune-actions-caches.tst.sh` | 02 | 0 / 15 / 0 | - | 0 / 17 / 0 (+2 new checks) |
| `iac:src/bash/tests/spl-gh-master-ruleset.tst.sh` | 02 | 0 / 9 / 0 | - | 0 / 12 / 0 (+3 new checks) |
| `iac:src/bash/tests/gh-set-ci-vars.tst.sh` | 02 | 0 / 14 / 0 | - | = |
| `iac:src/bash/tests/spl-gh-wire.tst.sh` | 02 | 0 / 19 / 0 | - | = |
| `iac:src/bash/tests/spl-gh-app.tst.sh` | 02 | 0 / 24 / 0 | - | = |
| `iac:src/bash/tests/git-env-isolation.tst.sh` | 02 | 0 / 7 / 0 | - | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |

Note: `spl-gh-master-ruleset.tst.sh` prints a final `PASS: all spl-gh-master-ruleset.tst.sh assertions` summary line counted by `grep -ciE '^ *(ok|pass)'` (9 on base = 8 assertions + summary; 12 on head2 = 11 assertions + summary). `unanswered-sweep-private-scope.tst.sh` also passed on base (`rc 0`, 15:57Z); the Postgres-backed sweep suites (`unanswered-sweep-pg.tst.sh`, `unanswered-sweep-delta-pg.tst.sh`, `unanswered-sweep-narrow-pg.tst.sh`, `enc-cache-writers.tst.sh`) and `dispatch-setup-check.tst.sh` (hit `timeout 60` at 45 pass / 0 fail on base) run in CI `orc-suite` and in the row's own run under `timeout 900`.

`shellcheck -S warning -x` on all 8 row files (base, head1, head2): **rc 0**, no findings
(n=1 each). `do_sec_shellcheck` with newline-separated `SEC_SHELLCHECK_FILES` set to each
row's 4 touched files (head1 and head2): **rc 0**, `no error-level findings`,
`no new findings (baseline holds)` (n=1 each).

**Red and guard controls** (n=1 each, each in its own detached worktree of `6d81d4447`):
- Row 01 red control a (`rc1a`, head1's `test-fleet-send.sh` on base): rc 1, 113 pass, 5
  fail (`spool_fleet_has_seats: command not found` x4, got 127 on the 4 direct checks,
  plus `FAIL - 8. one copy: spool_fleet_peers_on calls spool_fleet_has_seats`); head1:
  rc 0, 118 pass, 0 fail.
- Row 01 red control b (`rc1b`, head1's `unanswered-sweep.tst.sh` on base): rc 1, 72 pass,
  1 fail (`FAIL: 11. r97-01 one copy: sw_own=[196:# <spool root>/peer/seats, parsed as spool-send.sh's send_to_peers_on does.` plus `:199` awk line); head1: rc 0, 73 pass, 0 fail.
- Row 01 guard control (`gc1`, head1 with the `declare -F spool_fleet_has_seats` lazy-source
  guard deleted in `spl-unanswered-sweep.func.sh`): rc 1, 64 pass, 9 fail (all section-11
  seats assertions fail with `spl-unanswered-sweep.func.sh: line 199: spool_fleet_has_seats: command not found`,
  proving `spl_sweep_seated` genuinely lazy-loads and calls `spool_fleet_has_seats`).
- Row 02 red control a (`rc2a`, head2's `gh-prune-actions-caches.tst.sh` on base): rc 1,
  16 pass, 1 fail (`FAIL: 8. one copy: own=[26:_gpac_repo() {` + `:28` `remote get-url origin`
  + `:57` `_gpac_repo`); head2: rc 0, 17 pass, 0 fail.
- Row 02 red control b (`rc2b`, head2's `spl-gh-master-ruleset.tst.sh` on base): rc 1, 10
  pass, 2 fail lines (1 assertion `FAIL: 7. one copy: own=[29:  local repo; repo="$(_sgmr_repo)"`
  + `:61` `_sgmr_repo` + `:63` `remote get-url origin`, plus summary `FAIL: 1 assertion(s)`);
  head2: rc 0, 12 pass, 0 fail.
- Row 02 guard control a (`gc2a`, head2 with `declare -F _gscv_repo` deleted in
  `gh-prune-actions-caches.func.sh`): rc 1, 6 pass, 11 fail
  (`gh-prune-actions-caches.func.sh: line 53: _gscv_repo: command not found`).
- Row 02 guard control b (`gc2b`, head2 with `declare -F _gscv_repo` deleted in
  `spl-gh-master-ruleset.func.sh`): rc 1, 3 pass, 9 fail lines (8 assertions + summary,
  `spl-gh-master-ruleset.func.sh: line 31: _gscv_repo: command not found`).

The tests that name the sites (R2): `git grep -lE` over `*/tests/*` and `*shard-weights*`
for `spool_fleet_peers_on|spool_fleet_has_seats|spl_sweep_seated|spl-unanswered-sweep|spool-fleet\.inc\.sh`
-> the row-01 suites above (plus the PG-backed sweep tests `unanswered-sweep-{pg,delta-pg,narrow-pg,private-scope}.tst.sh`, `enc-cache-writers.tst.sh`, `dispatch-setup-check.tst.sh`, and shared orc/iac gates); for
`gh-prune-actions-caches|spl-gh-master-ruleset|_gpac_repo|_sgmr_repo|do_gh_prune_actions_caches|do_spl_gh_master_ruleset|GH_CACHE_PRUNE_REPO|GH_RULESET_REPO`
-> `gh-prune-actions-caches.tst.sh`, `spl-gh-master-ruleset.tst.sh`, `spl-gh-app.tst.sh`
(plus `gh-set-ci-vars.tst.sh`, `spl-gh-wire.tst.sh`, `git-env-isolation.tst.sh`, and shared
iac/orc gates). 30-char comment grep across `*/tests/*` -> 0 hits for both sites. No new
test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r97-01-orc-fleet-has-seats)` | one fact, one copy (developer guide 2.2.4) | `spool_fleet_peers_on` (`sa:lib/spool-fleet.inc.sh:102-103`) and `spl_sweep_seated` (`orc:src/bash/run/spl-unanswered-sweep.func.sh:197-200`) duplicate the exact `peer/seats` seat-line existence check, and `:196` still names the deleted `send_to_peers_on` (1.3, r96-01 R7 g-071 N1, r96 section 7) | `sa:lib/spool-fleet.inc.sh` (header `:29`, new `spool_fleet_has_seats` before `:97`, `:100-104`)<br>`orc:src/bash/run/spl-unanswered-sweep.func.sh:195-200`<br>`sa:tests/test-fleet-send.sh` (6 checks before `:372`)<br>`orc:src/bash/tests/unanswered-sweep.tst.sh` (2 checks after `:447`) | copies of the `peer/seats` seat-line existence check 2 -> 1; stale `send_to_peers_on` refs 1 -> 0 | 1.3's shape. **Red control:** head's `test-fleet-send.sh` on parent FAILs 5 checks (`rc1a`, rc 1, 113 pass, 5 fail) and head's `unanswered-sweep.tst.sh` on parent FAILs one-copy naming `:196` `send_to_peers_on` and `:199` (`rc1b`, rc 1, 72 pass, 1 fail), then GREEN (118/0 and 73/0); guard control (`gc1`, `declare -F spool_fleet_has_seats` guard deleted: rc 1, 64 pass, 9 fail, `spool_fleet_has_seats: command not found`), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 6 + 2 new checks. Tests: `sa:tests/test-fleet-send.sh`, `orc:.../unanswered-sweep.tst.sh`, `unanswered-sweep-defer.tst.sh`, `unanswered-sweep-skip-probe.tst.sh`, `asks.tst.sh`, `sa:tests/test-spool-send.sh`, `test-desk-user-hops.sh`, `orc:.../fleet-relay-desk-moved.tst.sh`, `spool-send-desk-root.tst.sh`, `enc-dirs-untouched.tst.sh`, `fleet-lease.tst.sh` (`timeout 900`), `dispatch-setup-check.tst.sh` (`timeout 900`), `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r97-02-iac-gh-origin-repo)` | one fact, one copy (developer guide 2.2.4) | after r96-02 parameterised `_gscv_repo` (`gh-set-ci-vars.func.sh:29-33`) on `$1`, the two remaining non-secret `$APP_PATH` origin parsers `_gpac_repo` (`gh-prune-actions-caches.func.sh:26-30`) and `_sgmr_repo` (`spl-gh-master-ruleset.func.sh:61-65`) still duplicate the exact 3-line parser (1.4, r96 section 7) | `iac:src/bash/run/gh-prune-actions-caches.func.sh:26-31,57`<br>`iac:src/bash/run/spl-gh-master-ruleset.func.sh:29,61-66`<br>`iac:src/bash/tests/gh-prune-actions-caches.tst.sh:113,135`<br>`iac:src/bash/tests/spl-gh-master-ruleset.tst.sh:97` | copies of the non-secret `$APP_PATH` GitHub origin `<owner>/<repo>` parser in `iac/src/bash/run/` 3 -> 1 (`_gscv_repo` only) | 1.4's shape. **Red control:** head's `gh-prune-actions-caches.tst.sh` on parent FAILs case 8 naming `:26` `_gpac_repo` (`rc2a`, rc 1, 16 pass, 1 fail) and head's `spl-gh-master-ruleset.tst.sh` on parent FAILs case 7 naming `:29` `_sgmr_repo` (`rc2b`, rc 1, 10 pass, 2 fail lines), then GREEN (17/0 and 12/0); guard controls (`gc2a`/`gc2b`, `declare -F _gscv_repo` deleted: rc 1, 6/11 and 3/9 with `_gscv_repo: command not found`), built in a worktree; outputs in the body. **Behaviour:** the column passes on parent and head with identical counts plus the 2 + 3 new checks. Tests: `iac:.../gh-prune-actions-caches.tst.sh`, `spl-gh-master-ruleset.tst.sh`, `gh-set-ci-vars.tst.sh`, `spl-gh-wire.tst.sh`, `spl-gh-app.tst.sh`, `git-env-isolation.tst.sh`, `no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body diff, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r97-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r97-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row removes a duplicate helper copy and points its callers at the single
home; no output, exit code, env var, path or file a caller sees changes (1.3, 1.4, 1.5).
Each: `Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: `csi-spl-orc`
  `sa:lib/spool-fleet.inc.sh`, `orc:src/bash/run/spl-unanswered-sweep.func.sh`,
  `sa:tests/test-fleet-send.sh`, `orc:src/bash/tests/unanswered-sweep.tst.sh`; row 02:
  `csi-spl-iac` `gh-prune-actions-caches.func.sh`, `spl-gh-master-ruleset.func.sh`,
  `gh-prune-actions-caches.tst.sh`, `spl-gh-master-ruleset.tst.sh`).
- No row edits `iac:src/bash/run/gh-set-ci-vars.func.sh`, `iac:src/bash/run/spl-gh-wire.func.sh`,
  `iac:src/bash/run/spl-gh-app-manifest.func.sh`, `iac:src/bash/run/gh-box-token-check.func.sh`,
  `iac:src/bash/run/gh-secret-put-gcp-key.func.sh`, `sa:scripts/asks.sh`,
  `sa:scripts/spool-send.sh`, `orc:src/bash/run/spl-peer-poll.func.sh`,
  `orc:src/bash/run/spl-watchdog.func.sh`, `.shellcheck-warning-baseline.txt`,
  `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform, `csi-spl-api/` or
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (9, the 8 edited + `iac:src/bash/run/gh-set-ci-vars.func.sh` read by row 02):
`sa:lib/spool-fleet.inc.sh`, `orc:src/bash/run/spl-unanswered-sweep.func.sh`,
`sa:tests/test-fleet-send.sh`, `orc:src/bash/tests/unanswered-sweep.tst.sh`;
`iac:src/bash/run/gh-set-ci-vars.func.sh`, `iac:src/bash/run/gh-prune-actions-caches.func.sh`,
`iac:src/bash/run/spl-gh-master-ruleset.func.sh`, `iac:src/bash/tests/gh-prune-actions-caches.tst.sh`,
`iac:src/bash/tests/spl-gh-master-ruleset.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent a-158`, one call per
  path, n=1, 2026-11-24T15:53:48Z-15:54:49Z: **exit 4 on all 9** ("no live lane lists
  <path>, but 20 live lane(s) record no files"). The 20 `unknown:` lanes, all on the
  other box (`lane-map.sh list`, 15:52:18Z): 9 channel/workspace/tax seats (`c-029`,
  `c-041`, `c-086`, `c-146`, `c-187`, `c-728`, `c-927`, `c-873` firefox seat, `c-892`
  csi-tax), spec 181 B9 follow-up `c-678` (hub invoices/purge), 4 other-repo lanes
  (`c-713`, `c-714`, `c-721`, `c-861`), spec 186 M1 `c-775` / `c-857` (rdb) and M4
  `c-782` (hub), perf round 19 planner `c-778` (doc/WUI), skills panel editor `c-774`
  (doc), and spec 065 L11 release-notes bug `c-859` (api/wui). No lane owns any of the 9
  paths; none of those scopes touches `spool-fleet.inc.sh`,
  `spl-unanswered-sweep.func.sh`, `gh-prune-actions-caches.func.sh`, or
  `spl-gh-master-ruleset.func.sh`.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 15:50:42Z-15:50:52Z):
  25 queued, 0 placing: this round's mistral panel seat
  (`c002-refactor-round-97-mistral-panel-seat`, 1/25), SPL-6385 CI volume editor + 2
  panel seats (2-4/25), perf round 19 & 20 panel seats (5-7/25), spec 186 M3 (held after
  SPL-6345), spec 153 Q2 (held after SPL-6345), other-repo & private-channel seats,
  WUI/spec lanes (12-25/25). None touches any of the 9 paths.
- **Briefs on this box** changed in the last 24 h (170) naming any of the 9 paths or
  their functions (15:54:41Z): **10**, only closed/landed round briefs (`b42`, `r94-01`,
  `r95-02`, `r96-01`, `r96-02` and their R7 briefs) plus the closed bug brief
  `c002-bug-unanswered-sweep-missed-owner-status-ask.md` (lane `a-814` marked `done` 19 h
  ago in `lane-map.sh list --all`, no live/queued lane, no open remote branch).
- **Remote branches committed in the last 24 h** (25 besides master after
  `git fetch --prune origin`, 15:54:41Z):
  `git diff --name-only $(git merge-base 6d81d4447 <b>) <b> -- <the 9 paths>` -> **0 hits**.
- **Commits in the last 24 h** on those 9 paths (`git log 6d81d4447 --since='24 hours ago'`)
  -> **3**: `aea828942` (r95-02), `90a2c384f` (r96-02), `09f137d40` (r96-01), all landed
  and closed.
- **Live or queued lanes named in the brief:** spec 181 B9 follow-up `c-678` (hub), B11
  SPL-6345 (landed `61869b56f`..`50dbdaa6d`), SPL-5070 Nuxt 4 `c-980` (wui, landed
  through `6d81d4447`), phone Back bug SPL-6356 (landed `6c741f5b0`), spec 186 M1
  `c-775`/`c-857` (rdb, landed `34ae3ef15`), M4 `c-782`/`c-888` (hub), M9 (landed), M3
  (queued, wui), spec 153 Q9 (landed `17296f20a`), Q12 (landed `6d7c9e73d`), 3.30 (landed
  `37e0b241e`), Q2 (queued, store), perf rounds 19 (`c-778`) & 20 (`c-084`, panel `m-135`,
  WUI), bug b44-02 (`cmd/spool/hub.go`), other-repo lanes `c-713`/`c-714`/`c-721`, and
  private-channel seats: none on a row path.

## 3. Per row: what the lane does

- **r97-01:** `sa:lib/spool-fleet.inc.sh` gains `spool_fleet_has_seats [root]` (header
  bullet + 5-line function), and `spool_fleet_peers_on` calls
  `spool_fleet_has_seats "${SPOOL_ROOT:-}"`; `orc:src/bash/run/spl-unanswered-sweep.func.sh`
  updates its `:196` comment to name `spool_fleet_has_seats` (removing the stale
  `send_to_peers_on` name), drops its duplicate `sed`/`awk` seat check, lazy-sources
  `spool-fleet.inc.sh` behind a `declare -F spool_fleet_has_seats` guard, and calls
  `spool_fleet_has_seats "${SPOOL_ROOT:-/var/spool-hub}"`. `sa:tests/test-fleet-send.sh`
  adds 4 direct `spool_fleet_has_seats` checks + 2 one-copy checks;
  `orc:src/bash/tests/unanswered-sweep.tst.sh` adds 1 `SPOOL_TO_PEERS=0` isolation check
  + 1 one-copy check proving neither `send_to_peers_on` nor a local `awk.*\[acgmq\]`
  remains in `spl-unanswered-sweep.func.sh`.
- **r97-02:** `iac:src/bash/run/gh-prune-actions-caches.func.sh` deletes `_gpac_repo`,
  lazy-sources `gh-set-ci-vars.func.sh` behind a `declare -F _gscv_repo` guard, and calls
  `_gscv_repo "${GH_CACHE_PRUNE_REPO:-}"`; `iac:src/bash/run/spl-gh-master-ruleset.func.sh`
  deletes `_sgmr_repo`, lazy-sources `gh-set-ci-vars.func.sh` behind a
  `declare -F _gscv_repo` guard, and calls `_gscv_repo "${GH_RULESET_REPO:-}"`.
  `gh-set-ci-vars.func.sh` is untouched. `iac:src/bash/tests/gh-prune-actions-caches.tst.sh`
  adds a `GH_CI_VARS_REPO` no-leak check (5d) and one-copy check (8);
  `iac:src/bash/tests/spl-gh-master-ruleset.tst.sh` adds origin-remote https/ssh +
  `GH_CI_VARS_REPO` no-leak checks (6b, 6c) and one-copy check (7).

## 4. Panel and reviewers (R7)

- Editor: a-158 (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the mistral seat `c002-refactor-round-97-mistral-panel-seat` (queued
  1/25 at 15:50:52Z). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-24T15:50:47Z printed
  `pick=hold reason=waiting: grok weekly >= 95% on <box1>, <box2> [<box1> 99% billing read 16m ago; <box2> 99% banner read 5m ago]: queue the lane, spawn nothing`
  (grok weekly is held at 99% on both boxes): **a claude waiver seat per row** while the
  grok hold stands. The holder re-runs `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` when
  it places the rows, using grok if the hold has lifted, else the claude waiver seat.
  Never mistral on a coding kind or code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r97-01 | `c002-r97-01-orc-fleet-has-seats` | `refactor(r97-01-orc-fleet-has-seats, SPL-<row issue>): ...` | `review/r97-01` | 1 |
| r97-02 | `c002-r97-02-iac-gh-origin-repo` | `refactor(r97-02-iac-gh-origin-repo, SPL-<row issue>): ...` | `review/r97-02` | 1 |

**r97-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spawn-agents/lib/spool-fleet.inc.sh` (header bullet above
`spool_fleet_peers_on`, new `spool_fleet_has_seats` before `spool_fleet_peers_on`, and
`spool_fleet_peers_on` calling `spool_fleet_has_seats "${SPOOL_ROOT:-}"`),
`csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh` (update `:196` comment to name
`spool_fleet_has_seats`; `spl_sweep_seated` lazy-sources `spool-fleet.inc.sh` behind
`declare -F spool_fleet_has_seats` and calls
`spool_fleet_has_seats "${SPOOL_ROOT:-/var/spool-hub}"`),
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-fleet-send.sh` (append 4 direct
`spool_fleet_has_seats` checks + 2 one-copy checks before `t_done`), and
`csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh` (append `SPOOL_TO_PEERS=0` isolation
check + one-copy check after `:447` in section 11). NOT `asks.sh`, NOT `spool-send.sh`,
NOT `spl-peer-poll.func.sh`, NOT `spl-watchdog.func.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other test. Do: plan section 2 row 01 verbatim,
1.3's shape; red controls (`rc1a` + `rc1b`, head's tests on parent) RED then GREEN in the
body; guard control (`gc1`, `declare -F spool_fleet_has_seats` guard deleted in
`spl-unanswered-sweep.func.sh`, built in a worktree). Gates: the row's tests (section 2,
`SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind `simple_coding`,
vendor claude; R7 claude waiver seat while grok weekly >= 95% (re-checked at placement).

**r97-02 brief, Files: ONLY**
`csi-spl-iac/src/bash/run/gh-prune-actions-caches.func.sh` (delete `_gpac_repo` `:26-31`;
in `do_gh_prune_actions_caches`, lazy-source `gh-set-ci-vars.func.sh` behind
`declare -F _gscv_repo` and call `_gscv_repo "${GH_CACHE_PRUNE_REPO:-}"`),
`csi-spl-iac/src/bash/run/spl-gh-master-ruleset.func.sh` (delete `_sgmr_repo` `:61-66`;
in `do_spl_gh_master_ruleset`, lazy-source `gh-set-ci-vars.func.sh` behind
`declare -F _gscv_repo` and call `_gscv_repo "${GH_RULESET_REPO:-}"`),
`csi-spl-iac/src/bash/tests/gh-prune-actions-caches.tst.sh` (case 5d `GH_CI_VARS_REPO`
no-leak check + case 8 one-copy check), and
`csi-spl-iac/src/bash/tests/spl-gh-master-ruleset.tst.sh` (cases 6b/6c origin-remote
parse + `GH_CI_VARS_REPO` no-leak check + case 7 one-copy check). NOT
`gh-set-ci-vars.func.sh`, NOT `spl-gh-wire.func.sh`, NOT `spl-gh-app-manifest.func.sh`,
NOT `gh-box-token-check.func.sh`, NOT `gh-secret-put-gcp-key.func.sh`, or any other test.
Do: plan section 2 row 02 verbatim, 1.4's shape; red controls (`rc2a` + `rc2b`, head's
tests on parent) RED then GREEN in the body; guard controls (`gc2a` + `gc2b`,
`declare -F _gscv_repo` deleted in each `.func.sh`, built in a worktree, not a temp-dir
copy). Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude; R7 claude waiver seat while grok
weekly >= 95% (re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the `peer/seats` seat-line existence check (1.3) | 2 on `6d81d4447` (`spool_fleet_peers_on`, `spl_sweep_seated`) -> 1 (`spool_fleet_has_seats`) after row 01; stale `send_to_peers_on` comment 1 -> 0 |
| copies of the non-secret `$APP_PATH` GitHub origin `<owner>/<repo>` parser in `iac/src/bash/run/` (1.4) | 3 on `6d81d4447` (`_gscv_repo`, `_gpac_repo`, `_sgmr_repo`) -> 1 (`_gscv_repo`) after row 02 |
| lines (`git diff --numstat` of each head) | row 01: `spool-fleet.inc.sh` +15 -4, `spl-unanswered-sweep.func.sh` +5 -3, `test-fleet-send.sh` +8 -0, `unanswered-sweep.tst.sh` +11 -0; row 02: `gh-prune-actions-caches.func.sh` +4 -7, `spl-gh-master-ruleset.func.sh` +4 -7, `gh-prune-actions-caches.tst.sh` +9 -0, `spl-gh-master-ruleset.tst.sh` +17 -0 |
| measured on | `6d81d4447`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| the 3 secret-class `iac:src/bash/run/` GitHub origin `<owner>/<repo>` parsers (`_sga_repo` in `spl-gh-app-manifest.func.sh:90-94`, `gh_box_token_repo` in `gh-box-token-check.func.sh:82-86`, `gh_secret_put_gcp_key_repo` in `gh-secret-put-gcp-key.func.sh:67-71`) | secret-class sites stay out of refactor rounds (brief rule): `spl-gh-app-manifest.func.sh` writes a 0600 GitHub App `.pem` private key and stores it in Secret Manager; `gh-box-token-check.func.sh` reads the box GitHub token; `gh-secret-put-gcp-key.func.sh` writes GCP SA keys (and the latter two also default `${APP_PATH:-.}`) | `git grep -n 'remote get-url origin' 6d81d4447 -- csi-spl-iac/ ':!*.md'` |
| other `peer/seats` readers (`spl_peer_seats` in `orc:src/bash/run/spl-peer-poll.func.sh:115-118`, `spl-watchdog.func.sh:785,935`, `spl-wd-ensure.func.sh:88`, `sa:scripts/spawn-window.sh:425`) | different semantics from boolean existence (`spl_peer_seats` prints every `<id> <harness>` pair from `$PEER_SEATS`; `spl-watchdog.func.sh` lists ids or checks a specific id; `spl-wd-ensure.func.sh` and `spawn-window.sh` test file non-empty / existence only); candidate for a future `spool_fleet_list_seats` row if needed | `git grep -n 'peer/seats' 6d81d4447 -- csi-spl-orc/src/bash/` |
| `orc:src/bash/run/spl-calendar-event-{add,delete,update}.func.sh` (`:203`, `:35`, `:103`) and `spl-human-{email-add,link}.func.sh` (`:104`, `:84`) repeated `AGENT_ID` validation lines | 1-line inline guard statements rather than duplicated helper functions; candidate for r98+ if a shared calendar/human validator helper is warranted | `git grep -nE '\[acgmq\]-\[0-9\]' 6d81d4447 -- csi-spl-orc/src/bash/run/` |
| other `LEASE_(MASTER|FAILOVER|ORCH)` sites (`sa:scripts/lane-age-report.sh:33`, `orc:src/bash/run/spl-box-leave.func.sh:298`, `orc:src/bash/run/spl-lane-backfill-links.func.sh:78`) | not byte-identical to `send_role_seat` (different path vars); unchanged since r94 | r96 7; 1.2 (a) |
| `csi-spl-doc/specs/172-work-chain-enforcement/spec.md:173` (`lane_is_role_seat` prose) and `i18n-lang-review-exempt.json:2` `_doc` | prose / doc strings, not code copies; unchanged since r94 | r96 7; 1.2 (a) |
| Go duplicate helpers in `csi-spl-api/src/go/spool-hub-api` (`internal/store`, `keyd`/`lockkey`) | cross-package or store/security-tier (`PRE_PUSH_TIER=full` Postgres gate, live spec-181 / spec-186 store/hub lanes): not measured here | r96 7; 1.2 (a) |
| the 10 remaining non-framework 2+ line / >=40-char Bash groups (`do_gcp_*_apis_disable`, `spl_uplink_trim`/`ext_api_trim`, `spl_secrets_none_get`/`spl_self_host_env_get`, `tf_get`, `ndf_link`/`ndp_link`, 7 `_sec_*_need`, `spl_brx_gh_auth`/`ghrh_gh_auth`, `ghr_in` family, `spl_asks_dur`/`spl_fleet_dur`, `_lc_deps`/`_spl_box_leave_deps`) | unchanged since r96 (`6d81d4447`), each stays out for its r91..r96 section 7 reason | r96 7, r95 7, r94 7, r93 7, r92 7, r91 7; 1.2 (a), (e) |

## 8. Changes

- v0.1 (a-158): the rows and every read on `6d81d4447`; both heads built in detached
  scratch worktrees; the 25-suite column of 1.5 run on base and each row's head;
  `shellcheck -S warning -x` and `do_sec_shellcheck` rc 0; the red and guard controls
  (`rc1a`, `rc1b`, `gc1`, `rc2a`, `rc2b`, `gc2a`, `gc2b`) RED then GREEN; R3 (2.2) and R7
  (section 4, claude waiver seat while grok weekly >= 95% on both boxes) checked.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-158 (agy): v0.1.
- Panel reviewer seat: `c002-refactor-round-97-mistral-panel-seat` (mistral, queued 1/25 at
  15:50:52Z): **pending** review of v0.1 on `review/c002-refactor-round-97-planner`.
- Row R7 seats: section 4; claude waiver seat per row while grok weekly is held at 99%
  (re-checked with `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at placement).
