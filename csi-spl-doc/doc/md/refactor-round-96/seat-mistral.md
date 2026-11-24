# Refactor round 96 — panel seat mistral (m-028@<box>)

Issue: SPL-6358 (epic SPL-2402, Issue-Role: shared). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-96-mistral-panel-seat.md`
(`c002-refactor-round-96-mistral-panel-seat`).

Review target: `csi-spl-doc/doc/md/refactor-round-96-plan.md` on branch
`review/c002-refactor-round-96-planner` at v0.1
**`4daa117212626dff5209a4d47abc1c2fa9b71893`** (named by the planner a-025@<box> on task
`dispatch-refactor-r96`, msg 8f784341).

- `git ls-remote origin refs/heads/review/c002-refactor-round-96-planner` ->
  `4daa117212626dff5209a4d47abc1c2fa9b71893` (re-read at 2026-11-24T09:17Z, head unmoved; 1 commit on
  `48bc8bb6a`, 1 file `csi-spl-doc/doc/md/refactor-round-96-plan.md` +507 per
  `git diff --numstat $(git merge-base FETCH_HEAD origin/master) FETCH_HEAD`, author/committer
  repo-canonical csitea.net address per `git log -1 --format='%an <%ae> %cn <%ce>'`).
- `git show 4daa117212626dff5209a4d47abc1c2fa9b71893:csi-spl-doc/doc/md/refactor-round-96-plan.md | sha256sum`
  -> `5f1de0b86c75ce093810c6001d464c2d98e427057a5243e857a7a2281cb56453` (the copy I read; 507 lines).
- Plan base: `48bc8bb6a` = `origin/master` at the plan's read (2026-11-24T08:46:44Z).
  `origin/master` moved to `ab87b6d8f` at my 09:18Z fetch (3 docs-only commits:
  `387370a79`, `309175d3b`, `ab87b6d8f`); `git diff --name-only 48bc8bb6a origin/master -- <the 9 row
  paths and the wider spawn-agents / iac run+tests / orc run+tests dirs>` -> **empty**, so every base
  line still stands on trunk.

**Verdict: PASS on `4daa117212626dff5209a4d47abc1c2fa9b71893`.** No W defects. Notes N1..N4 below.

## 1. Slug r96 unused since the plan's `Window: W=`

`W=2026-11-24T10:26:25+02:00` (the plan's recorded window).

- The recorded W matches `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r95-plan'` ->
  `8e1b9308e879d1db57863b35c447a92b1d389f64 2026-11-24T10:26:25+02:00 docs(r95-plan, SPL-6348): refactor round 95 closed: ...`
  (the r95 close record).
- `git log origin/master --since="$W" --oneline -E --grep='\(r96-' | wc -l` -> **0**; over all history
  (`git log origin/master --oneline -E --grep='\(r96-' | wc -l`) -> **0**.
- `git ls-remote origin | grep -E 'r96-[0-9]{2}|refactor-round-96'` -> only
  `4daa117212626dff5209a4d47abc1c2fa9b71893  refs/heads/review/c002-refactor-round-96-planner`
  (the planner's; this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r96-[0-9]{2}|refactor-round-96'` -> exactly
  `c002-refactor-round-96-mistral-panel-seat.md` and `c002-refactor-round-96-planner.md`.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-96` -> **0**
  (the plain name is free on trunk).

## 2. Every site file:line of every row exists on the plan's base sha and still on origin/master

Row paths (7 edited) plus the 2 untouched tests (9 total). `orc:` = `csi-spl-orc/`,
`sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`, `iac:` = `csi-spl-iac/`.

- `git diff --name-only 48bc8bb6a origin/master -- <the 9 paths>` -> **empty** (origin/master =
  `ab87b6d8f` at my 09:18Z fetch; the 3 commits since base are docs-only), so every base line still
  stands on trunk.
- Each cited line checked with `git show 48bc8bb6a:<file> | sed -n <N>p`:
  - `sa:scripts/asks.sh:40` = `. "$_here/../lib/spool-fleet.inc.sh"`; `:45` = the peers-switch comment;
    `:46-50` = `asks_peers_on() {` + the 3-line body (`case "${SPOOL_TO_PEERS:-}" ...`,
    `[ -r "$SPOOL_ROOT/peer/seats" ] &&`, `sed ... | awk '$1 ~ /^[acgmq]-[0-9][0-9][0-9]$/ ...'`); `:51` blank;
    `:122` = `if [ -n "$ID" ] && asks_peers_on; then` — match 1.3.
  - `sa:scripts/spool-send.sh:129` = `. "$_here/../lib/spool-fleet.inc.sh"`; `:265-266` = the 2-line comment;
    `:267-271` = `send_to_peers_on() {` + the same 3-line body; `:272` blank; `:401` =
    `  if send_to_peers_on; then` — match 1.3.
  - `sa:lib/spool-fleet.inc.sh:29` = `#   spool_fleet_relay <send args> ...` (header bullet); `:94` =
    `# 0 when this machine can relay: ...` above `spool_fleet_desk_configured` — match 1.3.
  - `sa:tests/test-fleet-send.sh:361` = `t_done` — match 1.3.
  - `iac:src/bash/run/gh-set-ci-vars.func.sh:28-32` = `_gscv_repo() {` + `${GH_CI_VARS_REPO:-}` override +
    `git -C "$APP_PATH" remote get-url origin` + the `sed -nE 's#^.*github\.com[:/]...'` parse; `:70` =
    `  repo="$(_gscv_repo)"` — match 1.4.
  - `iac:src/bash/run/spl-gh-wire.func.sh:49-53` = `_sgw_repo() {` with `GH_WIRE_REPO` in place of
    `GH_CI_VARS_REPO`, same 3-line body; `:54` blank; `:91` = `_sgw_apply() {`; `:100` =
    `declare -F _gscv_set >/dev/null || source .../gh-set-ci-vars.func.sh`; `:112` =
    `  repo="$(_sgw_repo)"` — match 1.4.
  - `iac:src/bash/tests/spl-gh-wire.tst.sh:21` = `#     9. one copy: the repo-variable apply is _gscv_set of gh-set-ci-vars.func.sh`;
    `:173` = `git -C "$T/app" remote set-url origin git@github.com:o/app.git`; `:180-184` = case 9
    (`own="$(grep -nE '_sgw_get|actions/variables/|variable set' "$FUNC" ...)"` + the `_gscv_set` call check)
    — match 1.4.
  - Section 7 cites: `gh-prune-actions-caches.func.sh:26` = `_gpac_repo() {`,
    `spl-gh-app-manifest.func.sh:90` = `_sga_repo() {`, `spl-gh-master-ruleset.func.sh:61` =
    `_sgmr_repo() {`, `gh-box-token-check.func.sh:82` = `gh_box_token_repo() {`,
    `gh-secret-put-gcp-key.func.sh:67` = `gh_secret_put_gcp_key_repo() {`,
    `spl-unanswered-sweep.func.sh:196-197` = the `send_to_peers_on` comment + `spl_sweep_seated() {`,
    `lane-age-report.sh:33`, `spl-box-leave.func.sh:298`, `spl-lane-backfill-links.func.sh:78` =
    the `LEASE_(MASTER|FAILOVER|ORCH)` greps — all match.
- Byte-identity (n=1 each, on `48bc8bb6a`):
  `diff -u <(git show 48bc8bb6a:sa:scripts/asks.sh | sed -n '46,50p' | sed 's/asks_peers_on/spool_fleet_peers_on/') <(git show 48bc8bb6a:sa:scripts/spool-send.sh | sed -n '267,271p' | sed 's/send_to_peers_on/spool_fleet_peers_on/')`
  -> **no hunk, rc 0** (row 01);
  `diff -u <(git show 48bc8bb6a:iac:src/bash/run/gh-set-ci-vars.func.sh | sed -n '28,32p' | sed 's/_gscv_repo/_repo/; s/GH_CI_VARS_REPO/REPO_VAR/g') <(git show 48bc8bb6a:iac:src/bash/run/spl-gh-wire.func.sh | sed -n '49,53p' | sed 's/_sgw_repo/_repo/; s/GH_WIRE_REPO/REPO_VAR/g')`
  -> **no hunk, rc 0** (row 02: identical up to the override env-var name).
- `git grep -nE 'asks_peers_on|send_to_peers_on|spool_fleet_peers_on' 48bc8bb6a -- ':!*.md'` -> exactly
  the 2 definitions (`asks.sh:46`, `spool-send.sh:267`), their 2 calls (`:122`, `:401`), and one comment
  (`spl-unanswered-sweep.func.sh:196`) — match 1.3. `git grep -n 'spool_fleet_peers_on' 48bc8bb6a -- ':!*.md'`
  -> **0** (no collision for the new name).
- `git grep -nE '_gscv_repo|_sgw_repo' 48bc8bb6a -- '*/tests/*'` -> **0 hits** (rc 1) — match 1.4.
- No `.shellcheck-warning-baseline.txt` entry for any of the 7 row files
  (`git grep -nE 'spool-fleet\.inc\.sh|asks\.sh|spool-send\.sh|test-fleet-send\.sh|gh-set-ci-vars|spl-gh-wire' 48bc8bb6a -- .shellcheck-warning-baseline.txt`
  -> rc 1) — match 1.3.
- Line counts at base (`git show 48bc8bb6a:<f> | wc -l`): asks.sh **153**, spool-send.sh **659**,
  spool-fleet.inc.sh **129**, test-fleet-send.sh **361**, gh-set-ci-vars.func.sh **79**,
  spl-gh-wire.func.sh **135**, spl-gh-wire.tst.sh **196** — the plan's head claims (153->146,
  659->651, 129->141, 361->372, 79->80, 135->132, 196->199) are consistent.

## 3. Each red control: read, run on the plan's base in a scratch copy (n=1), last line + exit code

Heads are not committed anywhere, so I rebuilt them per the plan's 1.3/1.4 shape in detached
worktrees of `48bc8bb6a` (`git worktree add /tmp/r96/{base,head1,head2,rc1-wt,gc1-wt,rc2-wt,gc2-wt} 48bc8bb6a`;
`rc1-wt` = base with head1's test file copied over, `rc2-wt` = base with head2's test file copied over,
`gc1-wt` = head1 with the `spool_fleet_peers_on` function deleted from `spool-fleet.inc.sh`,
`gc2-wt` = head2 with the `declare -F _gscv_repo` line deleted), ran as the push user with
`env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID SPOOL_TEST=1 timeout 280 bash <tst>` (n=1 each, 2026-11-24T09:2xZ;
pass lines `grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`).

My head files' sha256 (12 chars): head1 `spool-fleet.inc.sh` `29aacbbef0cf`, `asks.sh` **`40973aba3527`**
(**equal to the plan's**), `spool-send.sh` **`53610547ef08`** (**equal to the plan's**),
`test-fleet-send.sh` `57cbade72f20`; head2 `gh-set-ci-vars.func.sh` `5559d8d45d2d`,
`spl-gh-wire.func.sh` `fa7bece2f920`, `spl-gh-wire.tst.sh` `09d51f2e0e29` (the plan's head sha256s differ
on these 5 — comment/wording only, see N1; every control below fails with the plan's exact quoted line
and counts). Head numstats match the plan exactly: head1 +11 -0 / +1 -8 / +1 -9 / +12 -0 (plan:
+12 -0 / +1 -8 / +1 -9 / +11 -0), head2 +3 -2 / +4 -7 / +8 -5 (plan: identical).
Control test sha256 (full): head1 test
`57cbade72f20896fd0519a89664167e667adc21701a55089af4529c17ee0f4e2`, head2 test
`09d51f2e0e297a71f4c0ec6567c8c64f29503adb7710ed858cf117d27a87d466`; plan
`5f1de0b86c75ce093810c6001d464c2d98e427057a5243e857a7a2281cb56453`.

- **base** `test-fleet-send.sh`: rc **0**, 105 pass / 0 fail, last line
  `-- test-fleet-send.sh: 105 passed, 0 failed`. **base** `spl-gh-wire.tst.sh`: rc **0**, 18/0,
  last line `PASS: all spl-gh-wire.tst.sh assertions`.
- **Row 01 green** (head1): rc **0**, 112 pass / 0 fail, last line
  `-- test-fleet-send.sh: 112 passed, 0 failed`.
- **Row 01 red** (rc1, head1's `test-fleet-send.sh` on base): rc **1**, 105 pass / 7 fail lines, with
  `spool_fleet_peers_on: command not found` x4 (lines 363, 364, 366, 367) plus
  `FAIL - 9. one copy: asks.sh and spool-send.sh keep no own peers switch (want '0', got '6')`,
  `FAIL - 9. one copy: asks.sh calls spool_fleet_peers_on (want '1', got '0')`,
  `FAIL - 9. one copy: spool-send.sh calls spool_fleet_peers_on (want '1', got '0')`; last line
  `-- test-fleet-send.sh: 105 passed, 7 failed` — the plan's 1.5 rc1 quote (rc 1, 105 pass, 7 fail,
  command not found x4 + 3 one-copy FAILs).
- **Row 01 wiring control** (gc1, head1 without `spool_fleet_peers_on` in `spool-fleet.inc.sh`): rc **1**,
  93 pass / 19 fail, 4 `command not found`, last line `-- test-fleet-send.sh: 93 passed, 19 failed` —
  the plan's gc1 (rc 1, 93 pass, 19 fail).
- **Row 02 green** (head2): rc **0**, 19 pass / 0 fail, last line `PASS: all spl-gh-wire.tst.sh assertions`.
- **Row 02 red** (rc2, head2's `spl-gh-wire.tst.sh` on base): rc **1**, 17 pass / 1 fail, the fail line
  `FAIL: 9. one copy: spl-gh-wire.func.sh keeps its own variable apply or repo parse, or no call of _gscv_set/_gscv_repo: 49:_sgw_repo() { 51:  local url; url="$(git -C "$APP_PATH" remote get-url origin 2>/dev/null)" || return 0 112:  repo="$(_sgw_repo)"`
  — the plan's 1.5 rc2 quote verbatim (naming `:49`, `:51`, `:112`).
- **Row 02 guard control** (gc2, head2 with the `declare -F _gscv_repo` line deleted): rc **13**,
  5 pass / 13 fail, including `FAIL: 1. dry run`, `FAIL: 3. set`, `FAIL: 3. re-run`, `FAIL: 7. GH_WIRE_REPO`,
  `FAIL: 8. oap`, each with `.../spl-gh-wire.func.sh: line 108: _gscv_repo: command not found` —
  the plan's gc2 (rc 13, 5 pass, 13 fail, line 108).

Every control fails for the plan's reason (the own copy still present / the load line missing), not for
an environment reason, and none touches live state: all runs were in scratch worktrees under `/tmp/r96`
with `SPOOL_TEST=1` and the suites' own temp dirs; `grep -l '/var/spool-hub' /tmp/r96/*.out | wc -l` -> **0**.

## 4. Equivalence of each row

- The moved bodies are byte-identical to the shared ones (check 2: both `diff`s empty at base), and the
  call sites keep the same semantics: row 01's `asks_peers_on` / `send_to_peers_on` took no arguments and
  `spool_fleet_peers_on` takes none, sourced from the `spool-fleet.inc.sh` both scripts already load
  (`asks.sh:40`, `spool-send.sh:129` — zero new source edges); row 02's `_gscv_repo "${GH_CI_VARS_REPO:-}"`
  (in `do_gh_set_ci_vars`) and `_gscv_repo "${GH_WIRE_REPO:-}"` (in `do_spl_gh_wire`) execute the exact
  override check + `git remote get-url origin` + `sed` pipeline the two deleted functions had, with the
  same env var each caller used before; the `|| return 0` on git failure and the FATAL messages are
  unchanged, so exit codes, messages, paths and defaults are identical.
- The head diffs contain only the described change (numstats in check 3 match the plan's section 6).
- Line-cap check (cap 75): the new `spool_fleet_peers_on` is 5 lines; `_gscv_repo` stays 5 lines;
  `do_spl_gh_wire` grows 32 -> 35 — all under the cap.
- `shellcheck -S warning -x` on the 7 head files (head1's 4, head2's 3): rc **0** each, 0 findings
  (n=1 each, 09:2xZ). The plan's SC2120 point holds: `_gscv_repo` reads `${1:-}` and both callers pass
  an explicit argument.
- Behaviour: spot suites on the heads match the plan's base counts exactly — `asks.tst.sh` head1 rc 0
  103/0, `test-spool-send.sh` head1 rc 0 78/0, `gh-set-ci-vars.tst.sh` head2 rc 0 14/0,
  `git-env-isolation.tst.sh` head2 rc 0 7/0, `route-ci-overflow.tst.sh` head2 rc 0 38/0 (plan 1.5 base:
  103, 78, 14, 7, 38). The controls catch a difference: rc1/rc2 fail while the own copy is present
  (RED on base, GREEN on the head); gc1/gc2 fail when the load line is missing. No row changes an exit
  code, a message, a path or a default: each row is ONE logical refactor.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after (reproduced in check 3), a
test list, box `either`, vendor `claude`, kind `simple_coding`, batch 1. The R2 greps match on
`48bc8bb6a`: `git grep -lE 'asks_peers_on|send_to_peers_on|spool-fleet|asks\.sh|SPOOL_TO_PEERS' 48bc8bb6a -- '*/tests/*'`
-> the 17 row-01 suites of 1.5 plus generic-fixture tests that only invoke `spool-send.sh` /
`asks.sh` (test-spawn-dry-run, box-link-watch, check-fleet-rules-drift, desk-root-readers,
dispatch-lease, dispatch-seed-alias, fleet-lease, spl-issue-close-landed, spl-take, unanswered-sweep —
run in CI's orc-features/orc-suite jobs, as the plan notes);
`git grep -lE 'spl-gh-wire|gh-set-ci-vars|_sgw_|_gscv_|do_spl_gh_wire|do_gh_set_ci_vars' 48bc8bb6a -- '*/tests/*'`
-> `spl-gh-wire.tst.sh`, `gh-set-ci-vars.tst.sh`, `git-env-isolation.tst.sh`, `route-ci-overflow.tst.sh`.
No new test file is added, so `orc-shard-weights.txt` needs no line (`git grep -nE 'asks|spool-send' 48bc8bb6a -- '*shard-weights*'`
-> 2 pre-existing lines: `asks.tst.sh 100`, `spool-send-desk-root.tst.sh 6`). The 30-char comment grep
over `*/tests/*` for comment strings of the 7 site files -> 1 hit, the row-01 test's own header
(`internal/hub/fleet_send_test.go` in `test-fleet-send.sh`), i.e. no additional test holds a site
comment string. No mistral coding or testing row (owner 10-17, t1 b61851fb). R7 (plan section 4): grok
per row — I re-ran `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 09:2xZ ->
`pick=<other-box> reason=every box is at or above its high mark; <other-box> is the least past its band (119% on high 90%, overflow 180%)`,
`grok weekly 92%` on both boxes (not held), matching the plan's 08:46:46Z read; the claude waiver seat
if held at placement — never mistral. R1: the two rows' 7 files are distinct
(`printf '%s\n' <the 7 paths> | sort | uniq -d | wc -l` -> **0**), so no file is shared within
batch 1. 2 rows, within 5.1's aim 2 / at most 3; 5.3's numbering r96 with the plain plan name free
on trunk (check 1).

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 9 paths, comma-separated> --agent m-028`
-> **exit 4** at 2026-11-24T09:19:34Z: `WARN no live lane lists <the 9 paths>, but 12 live lane(s) record no files`;
`unknown:` lanes, all on the other box: c-029, c-041, c-086, c-146, c-187, c-678 (spec 181 B9), c-680
(phone Back bug), c-713, c-714, c-924, c-927, g-565. No lane is reported as owning any row path.

The brief's named live/queued lanes — spec 181 B9 c-678@<other-box>, B11 c-918@sat, SPL-5070 c-980@sat,
SPL-5006 W3 c-978@sat (done 23m ago, landed `48bc8bb6a`), c-680@<other-box>, c-925@sat (done): none touches a
row file — `git -C /opt/csi/csi-spl-wt/<id> diff --name-only origin/master...HEAD` for c-918, c-980,
c-978, c-925 -> 0 hits on the 9 paths; c-678 and c-680 are `unknown:` lanes on the other box whose
scopes (hub invoices/purge; wui Back bug) do not include `spawn-agents` scripts or `iac/src/bash/run/gh-*`.
Remote branches whose diff since `48bc8bb6a` touches a row path: only stale unlanded ones with tips
older than 24 h (`review/c-674-s165-b4` 2026-10-30, `review/c002-bug-round-30-mistral-seat` 2026-11-21,
`wip/c-900-c002-bug-spool-send-desk-root` 2026-10-28, `wip/m-837-s130-*` 2026-10-11 — all touching only
`spool-send.sh`, all lanes gone); `review/r95-02` was pruned after landing as `aea828942`. Spawn queue
(`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 09:19Z): 6 queued, 1 placing — spec 153/186/187/149
planners and a msg-card revoke spec, none on a row path.

## 7. Inputs accounted for

- The candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md` (131 lines, read
  08:51Z and re-checked 09:2xZ; `wc -l` -> 131, unchanged since r95 read it) — its refactor-shaped
  items, each re-checked on `48bc8bb6a`:
  - `asks_peers_on` / `send_to_peers_on` (r95 section 7's first candidate) -> **row 01**.
  - `_gscv_repo` / `_sgw_repo` (r95 section 7's second candidate, eligible after r95-02) -> **row 02**.
  - WUI entry-chunk headroom (`for refactor round 95` block): served by SPL-6342 — accounted in plan 1.2 (c).
  - `LOGIN_STATE_DIR` literal: served — `git grep -n 'LOGIN_STATE_DIR' 48bc8bb6a -- '*.sh'` -> only
    `spl-claude-login.func.sh:29` (`${LOGIN_STATE_DIR:-}` else derived) and a test.
  - reverse-tunnel state dir literal: served — `reverse-tunnel-cron.sh:27` now reads
    `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`.
  - agent-boot-restore literal: served — `spl-watchdog.func.sh:535-541` derives it via
    `spl_var_app_subdir d agent-boot-restore`.
  - `spl-desk-reply.sh:9,19` usage kinds: served — both lines list all kinds
    (`note|result|reject|blocker|msg|feature|bug|alert|question|idea|decision|docs`).
  - agy words: served — `git grep -cE 'needs_agy_review|waits for an agy review|agy has the final word' 48bc8bb6a -- ':!*.md' | wc -l`
    -> **0** (SPL-6174 landed).
  - `i18n-lang-review-exempt.json:2` `_doc`: accounted in plan section 7 (doc string, unchanged since r94).
  - the rest are bug-, test-, doc-, feature- or secret-shaped (review-go retries, placer notices,
    quota reading, /tmp worktree leak, token hash, ban-list, lease vendor order, store race, e2e
    flakes, etc.) — not refactor rows.
- Perf floor (rulebook 4.4) re-run at 09:18Z with the rulebook's own command ->
  `perf 29 refactor 98 perf-share 22.8% floor-met` — matches the plan's read (22.8%, floor-met), so
  this is a refactor round.
- Plan 1.2 (a): `git diff --name-only c4000b25b 48bc8bb6a | wc -l` -> **59** (matches the plan).
- Plan 1.2 (d): `git log 48bc8bb6a --since=2026-11-24T06:06:02Z --oneline -- csi-spl-doc/specs/011-spool-project-refactor`
  -> **0** (matches).
- **No refactor-shaped input is neither served nor accounted for.** Each row is ONE logical refactor
  with no behaviour change (check 4): no row changes an exit code, a message, a path or a default.

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-028`, rc **0**
(run at 08:53Z before this file was written; re-run after adding it, still rc 0 — see the commit).

## Defects

None (no W1...).

## Notes

- **N1** the heads are not committed anywhere, so I rebuilt them per the plan's 1.3/1.4 shape; my
  files' sha256 (12 chars) differ from the plan's on 5 of 7 (head1 `spool-fleet.inc.sh`
  `29aacbbef0cf` vs `616dba760b43`, `test-fleet-send.sh` `57cbade72f20` vs `2c9ced6b5022`; head2
  `gh-set-ci-vars.func.sh` `5559d8d45d2d` vs `aefa845e2afc`, `spl-gh-wire.func.sh` `fa7bece2f920` vs
  `3fda7f60db77`, `spl-gh-wire.tst.sh` `09d51f2e0e29` vs `335537586b84`) — comment/wording only;
  head1 `asks.sh` `40973aba3527` and `spool-send.sh` `53610547ef08` **equal** the plan's. Every red and
  guard/wiring control fails with the plan's exact quoted line and counts (rc1: rc 1, 105/7, command not
  found x4 + 3 one-copy FAILs; gc1: rc 1, 93/19; rc2: rc 1, 17/1, the `:49/:51/:112` quote; gc2: rc 13,
  5/13, line 108 command not found). Same reason, not an environment reason.
- **N2** `origin/master` moved `48bc8bb6a` -> `ab87b6d8f` (3 docs-only commits) between the plan's read
  and mine; `git diff --name-only 48bc8bb6a origin/master -- <the 9 row paths>` is empty, so every site
  stands.
- **N3** the lane map at my read exits 4 with 12 `unknown:` lanes (all on the other box); 0 hits on the
  row paths either way. The only remote branches touching a row path are stale (>24 h old, unlanded,
  lanes gone); the row lanes re-run R3 at spawn.
- **N4** the plan's 1.2 (e) byte-identical-body scan (11 groups) is the planner's own scratch script, not
  in the repo, so I did not re-run the full scan; I verified the two row candidates byte-identical
  directly (check 2) and the section-7 items by direct grep (check 7).
