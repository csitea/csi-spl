# Refactor round 97 — panel seat mistral (m-161@sat)

Issue: SPL-6384 (epic SPL-2402, Issue-Role: shared). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-97-mistral-panel-seat.md`
(`c002-refactor-round-97-mistral-panel-seat`).

Review target: `csi-spl-doc/doc/md/refactor-round-97-plan.md` on branch
`review/c002-refactor-round-97-planner` at v0.1
**`dc07c2ee455dfbc4d4efa22351448d6f74d78395`** (named by the dispatch holder c-002@sat on task
`dispatch-refactor-r97`, msg f0f4fb3f).

- `git ls-remote origin refs/heads/review/c002-refactor-round-97-planner` ->
  `dc07c2ee455dfbc4d4efa22351448d6f74d78395` (re-read 2026-11-24T17:0xZ, head unmoved; 1 commit on
  `a626af26c`, the plan file only, 570 lines).
- Plan base: `6d81d4447` = `origin/master` at the plan's read (2026-11-24T15:50:31Z).
  `origin/master` moved to `1aa56088c` at my fetch (SPL-6355 `4b60435b1`/`9b367426f`/`1d6722841`/
  `a626af26c`, SPL-6378 `5fb0e1881`/`1aa56088c`); `git diff --name-only 6d81d4447 origin/master --
  <the 9 row paths>` -> **empty**, so every base line still stands on trunk.

**Verdict: PASS on `dc07c2ee455dfbc4d4efa22351448d6f74d78395`.** One defect W1 (the plan's R7 text
names the claude waiver seat, stale since the 15:52Z ruling — fold into v1.0; it does not change the
rows). Notes N1..N3 below.

## 1. Slug r97 unused since the plan's `Window: W=`

`W=2026-11-24T14:16:54+02:00` (the plan's recorded window).

- The recorded W matches `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r96-plan'` ->
  `9a85c02b584ea512cc78c0d988f7081ce6505294 2026-11-24T14:16:54+02:00 docs(r96-plan, SPL-6358): refactor round 96 closed: ...`
  (the r96 close record).
- `git log origin/master --since="$W" --oneline -E --grep='\(r97-' | wc -l` -> **0**; over all history
  (`git log origin/master --oneline -E --grep='\(r97-' | wc -l`) -> **0**.
- `git ls-remote origin | grep -E 'r97-[0-9]{2}|refactor-round-97'` -> only
  `dc07c2ee455dfbc4d4efa22351448d6f74d78395  refs/heads/review/c002-refactor-round-97-planner`
  (the planner's; this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r97-[0-9]{2}|refactor-round-97'` -> exactly
  `c002-refactor-round-97-mistral-panel-seat.md` and `c002-refactor-round-97-planner.md`.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-97` -> **0**
  (the plain name is free on trunk).

## 2. Every site file:line of every row exists on the plan's base sha and still on origin/master

Row paths (8 edited) plus `iac:src/bash/run/gh-set-ci-vars.func.sh` (read by row 02) = 9.
`orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`, `iac:` = `csi-spl-iac/`.

- `git diff --name-only 6d81d4447 origin/master -- <the 9 paths>` -> **empty** (origin/master =
  `1aa56088c` at my fetch), so every base line still stands on trunk.
- Each cited line checked with `git show <ref>:<file> | sed -n <N>p` on **both** `6d81d4447` and
  `origin/master` (identical output each time):
  - `sa:lib/spool-fleet.inc.sh:29` = `#   spool_fleet_peers_on          0 when reports go to the peers (spec 068 L4):`;
    `:97` = `# 0 when reports go to the peers (spec 068 L4): SPOOL_TO_PEERS=1|0, else a`;
    `:100` = `spool_fleet_peers_on() {`; `:101` = the `case "${SPOOL_TO_PEERS:-}" ...` line;
    `:102-103` = `[ -r "$SPOOL_ROOT/peer/seats" ] &&` + the `sed 's/#.*//' ... | awk '$1 ~ /^[acgmq]-[0-9][0-9][0-9]$/ ...'` line;
    `:104` = `}` — match 1.3.
  - `orc:src/bash/run/spl-unanswered-sweep.func.sh:119` = the `declare -F spl_role_seat ... source .../spool-env.inc.sh`
    lazy-source; `:195-196` = the seat comment with the stale `parsed as spool-send.sh's send_to_peers_on does.`;
    `:197` = `spl_sweep_seated() {`; `:198` = `  local f="${SPOOL_ROOT:-/var/spool-hub}/peer/seats"`;
    `:199` = the identical `[[ -r "$f" ]] && sed ... | awk ...` check; `:200` = `}` — match 1.3.
  - `sa:tests/test-fleet-send.sh:372` = `t_done`; `orc:src/bash/tests/unanswered-sweep.tst.sh:447` =
    the `pass "11. control: no seats file + a local lease: ..."` line — match 1.3.
  - `iac:src/bash/run/gh-set-ci-vars.func.sh:29-33` = `_gscv_repo() {` + `${1:-}` override +
    `git -C "$APP_PATH" remote get-url origin` + the `sed -nE 's#^.*github\.com[:/]...'` parse + `}` — match 1.4.
  - `iac:src/bash/run/gh-prune-actions-caches.func.sh:26-30` = `_gpac_repo() {` + `GH_CACHE_PRUNE_REPO` override +
    the same url line + the same sed line + `}`; `:57` = `  repo="$(_gpac_repo)"` — match 1.4.
  - `iac:src/bash/run/spl-gh-master-ruleset.func.sh:29` = `  local repo; repo="$(_sgmr_repo)"`;
    `:61-65` = `_sgmr_repo() {` + `GH_RULESET_REPO` override + url + sed + `}` — match 1.4.
  - `iac:src/bash/tests/gh-prune-actions-caches.tst.sh:113` = the `5c. GH_CACHE_PRUNE_REPO names the repo` line;
    `:135` = the `CONTROL: the stub serves both pages` line; `iac:src/bash/tests/spl-gh-master-ruleset.tst.sh:97`
    = the `6. no repo -> FATAL, no gh call` line — match 1.4.
  - Section 7 cites: `spl-gh-app-manifest.func.sh:92`, `gh-box-token-check.func.sh:84`,
    `gh-secret-put-gcp-key.func.sh:69` = the secret-class `remote get-url origin` lines
    (`git grep -n 'remote get-url origin' 6d81d4447 -- csi-spl-iac/ ':!*.md'` -> 6 hits: the 3 non-secret
    row sites + these 3 + one test line) — match section 7.
- Byte-identity (n=1, on `6d81d4447`): `spool-fleet.inc.sh:102-103` vs `spl-unanswered-sweep.func.sh:199`
  differ only in `[ -r "$SPOOL_ROOT/..." ]` vs `[[ -r "$f" ]]` with `f="${SPOOL_ROOT:-/var/spool-hub}/peer/seats"`
  — the same check; `gh-set-ci-vars.func.sh:29-33` vs `gh-prune-actions-caches.func.sh:26-30` vs
  `spl-gh-master-ruleset.func.sh:61-65` are identical up to the override env var / `$1` — match 1.3/1.4.
- `git grep -c 'spool_fleet_has_seats' 6d81d4447 -- ':!*.md' | wc -l` -> **0** (no collision for the new name).
- `git grep -nE '_gpac_repo|_sgmr_repo' 6d81d4447 -- ':!*.md'` -> exactly the 2 definitions
  (`gh-prune-actions-caches.func.sh:26`, `spl-gh-master-ruleset.func.sh:61`) and their 2 calls (`:57`, `:29`) — match 1.4.
- `spool-fleet.inc.sh` holds only function definitions: `git show 6d81d4447:.../spool-fleet.inc.sh |
  grep -nE '^[^ #}]' | grep -vE '^[0-9]+:[a-z_]+\(\) \{'` -> only func-def lines with trailing comments
  (`:43`, `:51`, `:67`, `:120`) — lazy-sourcing it is side-effect free, match 1.3.

## 3. Each red control: read, run on the plan's base in a scratch copy (n=1), last line + exit code

Heads are not committed anywhere, so I rebuilt them per the plan's 1.3/1.4 shape in detached
worktrees of `6d81d4447` (`git worktree add /tmp/r97-review/{base,head1,head2,gc1,gc2a,gc2b} 6d81d4447`;
rc controls = base with the head's test file copied over; gc1 = head1 with the
`declare -F spool_fleet_has_seats` line deleted; gc2a/gc2b = head2 with the `declare -F _gscv_repo`
line deleted from each `.func.sh`), ran as the push user with `SPOOL_TEST=1 timeout 270 bash <tst>`
(n=1 each, 2026-11-24T17:0x-17:5xZ; pass lines `grep -ciE '^ *(ok|pass)'`, fail lines
`grep -ciE '^ *(not ok|fail)'`).

Control test sha256 (12 chars): head1 `test-fleet-send.sh` `748fea2d58ff`,
`unanswered-sweep.tst.sh` `27d3d8f0a810`; head2 `gh-prune-actions-caches.tst.sh` `877f7fbb9d04`,
`spl-gh-master-ruleset.tst.sh` `5e645b771583` (see N1).

- **base** `test-fleet-send.sh`: rc **0**, 112 pass / 0 fail, last line
  `-- test-fleet-send.sh: 112 passed, 0 failed`. **base** `unanswered-sweep.tst.sh`: rc **0**, 71/0,
  last `unanswered-sweep: all passed`. **base** `gh-prune-actions-caches.tst.sh`: rc **0**, 15/0, last
  `=== all gh-prune-actions-caches.tst.sh assertions`. **base** `spl-gh-master-ruleset.tst.sh`: rc **0**,
  9/0, last `PASS: all spl-gh-master-ruleset.tst.sh assertions` — the plan's 1.5 base column.
- **rc1a** (head1's `test-fleet-send.sh` on base): rc **1**, 113 pass / 5 fail, last line
  `-- test-fleet-send.sh: 113 passed, 5 failed`; the 5 fails are 4 x
  `spool_fleet_has_seats: command not found` (got 127 on the 4 direct checks) +
  `FAIL - 8. one copy: spool_fleet_peers_on calls spool_fleet_has_seats` — the plan's rc1a quote.
- **rc1b** (head1's `unanswered-sweep.tst.sh` on base): rc **1**, 72 pass / 1 fail, last line
  `unanswered-sweep: 1 failure(s)`; the fail is
  `FAIL: 11. r97-01 one copy: sw_own=[196:# <spool root>/peer/seats, parsed as spool-send.sh's send_to_peers_on does.`
  (+ the `:199` awk line) — the plan's rc1b quote.
- **gc1** (head1 without the `declare -F spool_fleet_has_seats` guard): rc **1**, 64 pass / 9 fail, last
  `unanswered-sweep: 9 failure(s)`, with
  `spl-unanswered-sweep.func.sh: line 199: spool_fleet_has_seats: command not found` — the plan's gc1.
- **rc2a** (head2's `gh-prune-actions-caches.tst.sh` on base): rc **1**, 16 pass / 1 fail, last
  `=== 1 FAILED`; the fail is `FAIL: 8. one copy: own=[26:_gpac_repo() {` + `:28` `remote get-url origin`
  + `:57` `repo="$(_gpac_repo)"]` — the plan's rc2a quote.
- **rc2b** (head2's `spl-gh-master-ruleset.tst.sh` on base): rc **1**, 10 pass / 2 fail lines, last
  `FAIL: 1 assertion(s) in spl-gh-master-ruleset.tst.sh`; the fail is
  `FAIL: 7. one copy: own=[29:  local repo; repo="$(_sgmr_repo)"` + `:61` `_sgmr_repo()` + `:63`
  `remote get-url origin]` plus the summary line — the plan's rc2b quote.
- **gc2a** (head2 without the `declare -F _gscv_repo` in `gh-prune-actions-caches.func.sh`): rc **1**,
  6 pass / 11 fail, last `=== 11 FAILED`, with
  `gh-prune-actions-caches.func.sh: line 52: _gscv_repo: command not found` — the plan's gc2a.
- **gc2b** (head2 without the `declare -F _gscv_repo` in `spl-gh-master-ruleset.func.sh`): rc **1**,
  3 pass / 9 fail lines, last `FAIL: 8 assertion(s) in spl-gh-master-ruleset.tst.sh`, with
  `spl-gh-master-ruleset.func.sh: line 30: _gscv_repo: command not found` — the plan's gc2b.
- **Green on the heads**: head1 `test-fleet-send.sh` rc **0**, 118/0; head1 `unanswered-sweep.tst.sh`
  rc **0**, 73/0; head2 `gh-prune-actions-caches.tst.sh` rc **0**, 17/0; head2
  `spl-gh-master-ruleset.tst.sh` rc **0**, 12/0 — the plan's head column (+6 / +2 / +2 / +3 new checks).

Every control fails for the plan's reason (the own copy still present / the load line missing), not
for an environment reason, and none touches live state: all runs were in scratch worktrees under
`/tmp/r97-review` with `SPOOL_TEST=1`; `t_sandbox` (lib.inc.sh:40-52) sets `SPOOL_ROOT` to a `mktemp -d`
dir and `spool-env.inc.sh:382-388` refuses the live root under `SPOOL_TEST=1`; the iac suites stub
`gh` and use `mktemp -d` (`spl-gh-master-ruleset.tst.sh:20-24`).

## 4. Equivalence of each row

- Row 01: `spool_fleet_peers_on` (`spool-fleet.inc.sh:100-104`) is `case SPOOL_TO_PEERS in 1) return 0 ;;
  0) return 1 ;; esac` then the seat check. Extracting `spool_fleet_has_seats [root]` (readability +
  sed/awk only) and calling it from both sites preserves behaviour exactly: `SPOOL_TO_PEERS=1|0` still
  short-circuits in `spool_fleet_peers_on` only; unset `SPOOL_ROOT` gives `[ -r "/peer/seats" ]` in
  `spool_fleet_peers_on` (`"${SPOOL_ROOT:-}"`) and `/var/spool-hub/peer/seats` in `spl_sweep_seated`
  (`"${SPOOL_ROOT:-/var/spool-hub}"`) — both defaults kept by passing the root explicitly; the
  `SPOOL_TO_PEERS=0` isolation check (rc1b's green counterpart, head1 73/0) proves the sweep does not
  go through `spool_fleet_peers_on`. The stale `:196` comment naming the deleted `send_to_peers_on`
  is dropped. No output, exit code, path or default changes.
- Row 02: `_gscv_repo "${GH_CACHE_PRUNE_REPO:-}"` / `_gscv_repo "${GH_RULESET_REPO:-}"` execute the exact
  override check + `git -C "$APP_PATH" remote get-url origin` + sed pipeline the two deleted helpers
  had (byte-identical bodies, check 2); the `|| return 0` on git failure and the callers' FATAL
  messages are unchanged, so exit codes and messages are identical. `gh-set-ci-vars.func.sh` needs
  zero edits. A set `GH_CI_VARS_REPO` in the caller's environment cannot leak (the 5d/6b/6c checks pass
  on head2). No row changes an exit code, a message, a path or a default: each row is ONE logical
  refactor.
- `shellcheck -S warning -x` on all 8 head files: rc **0** each, 0 findings (n=1 each, 17:5xZ).
- Line-cap (75): the new `spool_fleet_has_seats` is 5 lines, `spool_fleet_peers_on` 4,
  `spl_sweep_seated` 6; `do_gh_prune_actions_caches` and `do_spl_gh_master_ruleset` stay under the cap —
  consistent with the plan's 1.3/1.4 counts.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after (reproduced in check 3), a
test list, box `either`, vendor `claude`, kind `simple_coding`, batch 1. The R2 greps match on
`6d81d4447`: `git grep -lE 'spool_fleet_peers_on|spool_fleet_has_seats|spl_sweep_seated|spl-unanswered-sweep|spool-fleet\.inc\.sh'
6d81d4447 -- '*/tests/*' '*shard-weights*'` -> the row-01 suites of 1.5 (test-fleet-send.sh,
test-desk-user-hops.sh, unanswered-sweep*.tst.sh, enc-*, fleet-lease, dispatch-setup-check, ...);
`git grep -lE 'gh-prune-actions-caches|spl-gh-master-ruleset|_gpac_repo|_sgmr_repo|...|GH_RULESET_REPO'
6d81d4447 -- '*/tests/*' '*shard-weights*'` -> `gh-prune-actions-caches.tst.sh`,
`spl-gh-master-ruleset.tst.sh`, `spl-gh-app.tst.sh` (+ gh-set-ci-vars.tst.sh, spl-gh-wire.tst.sh,
git-env-isolation.tst.sh per the plan). No new test file is added, so `orc-shard-weights.txt` needs no
line. No mistral coding or testing row (owner 10-17, t1 b61851fb): both rows vendor claude. R1: the
two rows' 8 files are distinct (`printf '%s\n' <the 8 paths> | sort | uniq -d | wc -l` -> **0**; row 01
all under `csi-spl-orc`, row 02 all under `csi-spl-iac`), so no file is shared within batch 1.
2 rows, within 5.1's aim 2 / at most 3; 5.3's numbering r97 with the plain plan name free on trunk
(check 1). R7: see W1 — the plan names the claude waiver seat, stale since the 15:52Z ruling; never
mistral either way.

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check
<the 9 paths, comma-separated> --agent m-161` -> **exit 4** at 2026-11-24T17:0xZ:
`WARN no live lane lists <the 9 paths>, but 17 live lane(s) record no files: their scope is unknown,
not free`. The 17 `unknown:` lanes, all on `<other-box>`: c-029, c-041, c-086, c-146, c-187, c-713, c-721,
c-728, c-774 (skills panel editor, doc), c-778 (perf round 19 planner, doc/WUI), c-782 (spec 186 M4
hub), c-859 (spec 065 L11 release notes, api/wui), c-873, c-892, c-927, c-935, c-936. No lane is
reported as owning any row path; none of those scopes (per their brief names) touches
`spool-fleet.inc.sh`, `spl-unanswered-sweep.func.sh`, `test-fleet-send.sh`, `unanswered-sweep.tst.sh`
or the four `iac` gh files. This matches the plan's 2.2 read (exit 4 on all 9 at 15:53Z, 20 unknown
lanes then). The row lanes re-run R3 at spawn.

## 7. Inputs accounted for

- The candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md` (134 lines, read
  17:0xZ; `wc -l` -> 134) — its refactor-shaped items, each re-checked on `6d81d4447`:
  - `:133-134` `## for refactor round 97` (r96-01 R7 g-071 N1: `spl-unanswered-sweep.func.sh:196`
    still names `send_to_peers_on`) -> **row 01**.
  - `:25` reverse-tunnel state-dir literal: served — `reverse-tunnel-cron.sh:27` now reads
    `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}` after deriving via `spl_run_paths`
    (`:24-26`).
  - `:48` agent-boot-restore literal: served — `spl-watchdog.func.sh:541` and
    `spl-agent-boot-restore-install-cron.func.sh:60` use `spl_var_app_subdir`.
  - `:104` `spl-lane-mix.func.sh` agy words: served — `:48`, `:140`, `:404` name
    `do_spl_lang_review_gct` with an agy review optional.
  - `:115` `i18n-lang-review-exempt.json:2` `_doc`: accounted in plan section 7 (doc string, unchanged
    since r94).
  - `:113` the pre-push e2e selector (`_ppe_keys` exact-key vs `msg-menu-<id>`): gate-design input,
    self-marked "not a narrow bug row"; not a one-fact-one-copy refactor row, so not a row input (N3).
  - the rest are bug-, test-, doc-, feature- or secret-shaped — not refactor rows.
- r96 plan section 7 (read on `origin/master`, `refactor-round-96-plan.md:481`): its first candidate
  (the 5 iac origin parsers) is split by this plan correctly — the 2 non-secret `$APP_PATH` ones
  (`_gpac_repo`, `_sgmr_repo`) -> **row 02**, the 3 secret-class ones stay out (plan section 7 row 1,
  verified: `spl-gh-app-manifest.func.sh:92`, `gh-box-token-check.func.sh:84`,
  `gh-secret-put-gcp-key.func.sh:69`); its remaining left-out items (LEASE_ sites, prose/doc strings,
  Go helpers, the 10 bash groups) are carried in r97's section 7 with their reasons.
- Perf floor (rulebook 4.4) re-run at 17:0xZ with the rulebook's own command on current `origin/master`
  -> `perf 29 refactor 100 perf-share 22.5% floor-met` — matches the plan's read (29/100/22.5%,
  5x29=145 >= 129), so this is a refactor round.
- Plan 1.2 (a): `git diff --name-only 48bc8bb6a 6d81d4447 | wc -l` -> **120**,
  `git rev-list --count 48bc8bb6a..6d81d4447` -> **47** (matches the plan). Plan 1.2 (d):
  `git log 6d81d4447 --since=2026-11-24T08:46:44Z --oneline -- csi-spl-doc/specs/011-spool-project-refactor`
  -> **0** (matches). r96 rows landed: `git log origin/master --oneline -E --grep='\(r96-0[12]-'` ->
  `09f137d40`, `90a2c384f` (matches).
- **No refactor-shaped input is neither served nor accounted for.** Each row is ONE logical refactor
  with no behaviour change (check 4): no row changes an exit code, a message, a path or a default.

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-161`, rc **0**
(run at 17:0xZ before this file was written).

## Defects

- **W1** — the plan's R7 text names the **claude waiver seat** for both rows, stale since the ruling
  of 2026-11-24T15:52:44Z (c-001@sat outbox
  `20261124T155244Z--c-001--c-001-sat-orch-re-0b9804ca-owner-dc84300a.json`, owner msg `dc84300a` in
  t1 2d0270fe): "an R7 review of a claude lane goes to an AGY seat, not grok and no longer the claude
  waiver ... Rows already queued as claude waiver seats keep their placement; new ones go to agy."
  The plan v0.1 commit `dc07c2ee` is dated 2026-11-24T16:42:32Z, after that ruling, and still says
  "claude waiver seat" at plan lines **470, 472** (section 4), **507, 527** (section 5 row briefs),
  **560** (section 8) and **569** (section 9). The r97 rows are not queued yet, so their R7 must be an
  **agy seat** (claude backup only while agy is out of quota), never the waiver and never mistral.
  Fold into v1.0: replace the waiver wording at those six lines with the agy seat per the 15:52Z
  ruling. This does not change the rows, their sites or their controls.

## Notes

- **N1** the heads are not committed anywhere, so I rebuilt them per the plan's 1.3/1.4 shape in
  scratch worktrees of `6d81d4447`; my head files' sha256 (12 chars) differ from the plan's claimed
  head sha256s (comment/wording only — e.g. my head1 `spool-fleet.inc.sh` `88bc27ad95bf` vs the plan's
  `2ec8cf1dcb3b`, `test-fleet-send.sh` `748fea2d58ff` vs `c5670dfad1ed`). Every red and guard control
  fails with the plan's exact quoted line and counts (check 3), so the difference is cosmetic. One
  build fix on my side: the row-02 ruleset test's one-copy check must read
  `"$RUN/spl-gh-master-ruleset.func.sh"` (that suite has no `$FUNC`; with `$FUNC` it dies
  `unbound variable`, an environment reason, not the plan's) — control sha256 `5e645b771583` after
  the fix.
- **N2** `origin/master` moved `6d81d4447` -> `1aa56088c` (6 commits: SPL-6355 x4, SPL-6378 x2) between
  the plan's read and mine; `git diff --name-only 6d81d4447 origin/master -- <the 9 row paths>` is
  empty, so every site stands.
- **N3** the candidates file's `:113` e2e-selector item is gate-design shaped (test-credit keys), not
  a one-fact-one-copy refactor row; the plan neither serves nor accounts for it, and it is not
  refactor-shaped, so it is not a missing row input. The plan's 1.2 (e) byte-identical-body scan (10
  groups) is the planner's own scratch script, not in the repo, so I did not re-run the full scan; I
  verified the two row candidates byte-identical directly (check 2) and the section-7 items by direct
  grep (check 7).
