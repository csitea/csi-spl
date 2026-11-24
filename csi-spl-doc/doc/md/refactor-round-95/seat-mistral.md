# Refactor round 95 — panel seat mistral (m-969@<box>)

Issue: SPL-6348 (epic SPL-2402, Issue-Role: shared). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-95-mistral-panel-seat.md`
(`c002-refactor-round-95-mistral-panel-seat`).

Review target: `csi-spl-doc/doc/md/refactor-round-95-plan.md` on branch
`review/c002-refactor-round-95-planner` at v0.1
**`62e2af0eb03e7cd7a27fc96cd46693683c2cb76b`** (named by the dispatch holder c-002@<box> on task
`dispatch-refactor-r95`).

- `git ls-remote origin refs/heads/review/c002-refactor-round-95-planner` ->
  `62e2af0eb03e7cd7a27fc96cd46693683c2cb76b` (re-read at 2026-11-24T06:46Z, head unmoved; 1 commit on
  `c4000b25b`, 1 file `csi-spl-doc/doc/md/refactor-round-95-plan.md` +484 per
  `git diff --numstat c4000b25b 62e2af0e`, author/committer csitea.net per
  `git log -1 --format='%an <%ae> %cn <%ce>'`).
- `git show 62e2af0eb03e7cd7a27fc96cd46693683c2cb76b:csi-spl-doc/doc/md/refactor-round-95-plan.md | sha256sum`
  -> `2dd5c01f4aeb7a3d39748c4c39ef789d7e46203bfe3f27131cd91fc74231189d` (the copy I read; 484 lines).
- Plan base: `c4000b25b` = `origin/master` at the plan's read (2026-11-24T06:06:02Z).
  `origin/master` is still `c4000b25b8eeb6c8e2e5a252c480fd9fb5e2f18a` at my 06:46Z re-fetch
  (`git rev-parse origin/master`), so base == trunk at my read.

**Verdict: PASS on `62e2af0eb03e7cd7a27fc96cd46693683c2cb76b`.** No W defects. Notes N1..N3 below.

## 1. Slug r95 unused since the plan's `Window: W=`

`W=2026-11-23T22:49:00+02:00` (the plan's recorded window).

- The recorded W matches `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r94-plan'` ->
  `0075d4923ec2a8bc106721135f736b0eae767ff4 2026-11-23T22:49:00+02:00 docs(r94-plan, SPL-6325): refactor round 94 closed: ...`
  (the r94 close record).
- `git log origin/master --since="$W" --oneline -E --grep='\(r95-' | wc -l` -> **0**; over all history
  (`git log origin/master --oneline -E --grep='\(r95-' | wc -l`) -> **0**.
- `git ls-remote origin | grep -E 'r95-[0-9]{2}|refactor-round-95'` -> only
  `62e2af0eb03e7cd7a27fc96cd46693683c2cb76b  refs/heads/review/c002-refactor-round-95-planner`
  (the planner's; this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r95-[0-9]{2}|refactor-round-95'` -> exactly
  `c002-refactor-round-95-mistral-panel-seat.md` and `c002-refactor-round-95-planner.md`.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-95` -> **0**
  (the plain name is free on trunk).

## 2. Every site file:line of every row exists on the plan's base sha and still on origin/master

Row paths (5) plus the keeper and the untouched test (7 total): `orc:src/bash/run/spl-desk-mirror-settings.func.sh`,
`orc:src/bash/tests/desk-mirror-actions.tst.sh`, keeper
`sa:lib/spool-mirror-hooks.inc.sh` (`orc:` = `csi-spl-orc/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`);
`iac:src/bash/run/gh-set-ci-vars.func.sh`, `iac:src/bash/run/spl-gh-wire.func.sh`,
`iac:src/bash/tests/spl-gh-wire.tst.sh`, `iac:src/bash/tests/gh-set-ci-vars.tst.sh` (`iac:` = `csi-spl-iac/`).

- `git diff --name-only c4000b25b origin/master -- <the 7 paths>` -> **empty** (`origin/master` =
  `c4000b25b` at my 06:46Z fetch), so every base line still stands on trunk.
- Each cited line checked with `git show c4000b25b:<file> | sed -n <N>p`:
  - `spl-desk-mirror-settings.func.sh:20` = `do_require_bin python3 || return 1`; `:26` =
    `json="$(spl_desk_mirror_settings_json "$py")" || return 1`; `:41-49` =
    `spl_desk_mirror_settings_json() {` with the 7-line Python heredoc `:42-48`
    (`python3 - "$1" <<'EOF_PY'` .. `EOF_PY`) building `{"hooks": {"UserPromptSubmit": h, "Stop": h}}` — match 1.3.
  - `spool-mirror-hooks.inc.sh:2-4` = the "one copy for every launcher" comment; `:30-38` =
    `smh_hooks_json() {  # PY` with the same 7-line heredoc `:31-37`; calls at `:72` (`smh_qwen_merge`),
    `:161`, `:166` (`smh_install`), and `sa:scripts/spool-agent.sh:212`
    (`hooks_json() { smh_hooks_json "$MIRROR_PY"; }`) — match 1.3.
  - `desk-mirror-actions.tst.sh:12` (header), `:50` (sources `"$PROJ_PATH"/src/bash/run/*.func.sh`
    directly), `:115` (the direct `spl_desk_mirror_settings_json "$T/absent.py"` call), `:119`
    (end of section 3) — match 1.3.
  - `gh-set-ci-vars.func.sh:28-32` = `_gscv_repo` (env `GH_CI_VARS_REPO`); `:42-58` = `_gscv_apply`:
    `:44-45` JSON validation, `:46-57` the 12-line apply tail (read via `_gscv_get`, unchanged check,
    `DRY_RUN` branches, `gh variable set`, read-back, `OK ... set`) — match 1.4.
  - `spl-gh-wire.func.sh:49-53` = `_sgw_repo` (env `GH_WIRE_REPO`); `:91-113` = `_sgw_apply`:
    `:92` `local ... have`, `:93-97` non-empty/regex validation, `:98-100` the r94-01
    `declare -F _gscv_get` guarded source of `gh-set-ci-vars.func.sh`, `:101-112` the same 12 lines —
    match 1.4.
  - `spl-gh-wire.tst.sh:21` = `#     9. one copy: the repo-variable read is _gscv_get of gh-set-ci-vars.func.sh`;
    `:180-184` = case 9 (`own="$(grep -nE '_sgw_get|actions/variables/' "$FUNC")"` + the `_gscv_get` call check)
    — match 1.4.
  - `route-ci-overflow.func.sh:112` = `SPOOL_CI_RUNNER="$want" DRY_RUN="$dry" do_gh_set_ci_vars || return 1`
    (calls `do_gh_set_ci_vars` only) — match 1.4.
  - `.shellcheck-warning-baseline.txt:51-52` (repo root) =
    `SC2034|csi-spl-orc/src/bash/features/spawn-agents/lib/spool-mirror-hooks.inc.sh|2` and
    `SC2088|...spool-mirror-hooks.inc.sh|2` — the keeper's 4 baseline warnings, match 1.3.
- Byte-identity (n=1 each, on `c4000b25b`):
  `diff -u <(git show c4000b25b:sa:lib/spool-mirror-hooks.inc.sh | sed -n 30,38p | sed 's/  # PY//') <(git show c4000b25b:orc:src/bash/run/spl-desk-mirror-settings.func.sh | sed -n 41,49p | sed 's/spl_desk_mirror_settings_json/smh_hooks_json/')`
  -> **no hunk, rc 0** (row 01);
  `diff -u <(git show c4000b25b:iac:src/bash/run/gh-set-ci-vars.func.sh | sed -n 46,57p) <(git show c4000b25b:iac:src/bash/run/spl-gh-wire.func.sh | sed -n 101,112p)`
  -> **no hunk, rc 0** (row 02: the 12-line apply tails are byte-identical).
- `git grep -cE 'smh_|SMH_' c4000b25b -- csi-spl-orc/src/bash/run/ csi-spl-orc/lib/bash/funcs/` -> **0**
  (no symbol collision for the keeper in run/ or lib); `git grep -n '_gscv_set' c4000b25b -- ':!*.md'`
  -> **0** (no collision for the new name).
- Callers on base: `smh_hooks_json` -> `spool-mirror-hooks.inc.sh:30` (def), `:72`, `:161`, `:166`,
  `spool-agent.sh:212`; `spl_desk_mirror_settings_json` -> `spl-desk-mirror-settings.func.sh:26`, `:41`
  (def), `desk-mirror-actions.tst.sh:115`; `_gscv_apply`/`_sgw_apply` -> only their own files
  (`gh-set-ci-vars.func.sh:42,:68`, `spl-gh-wire.func.sh:91,:135`) — match 1.3/1.4.
- Line counts at base (`git show c4000b25b:<f> | wc -l`): spl-desk-mirror-settings.func.sh **49**,
  desk-mirror-actions.tst.sh **130**, spool-mirror-hooks.inc.sh **173**, gh-set-ci-vars.func.sh **73**,
  spl-gh-wire.func.sh **146**, spl-gh-wire.tst.sh **196**, gh-set-ci-vars.tst.sh **108** — the plan's
  head claims (49->46, 130->135, 73->79, 146->135, 196->196) are consistent.

## 3. Each red control: read, run on the plan's base in a scratch copy (n=1), last line + exit code

Heads are not committed anywhere, so I built them per the plan's 1.3/1.4 shape in detached
worktrees of `c4000b25b` (`git worktree add /tmp/r95/{base,head1,head1-noguard,head2,head2-noguard,rc1-wt,rc2-wt} c4000b25b`;
`rc1-wt` = base with head1's test file copied over, `rc2-wt` = base with head2's test file copied over),
ran as the push user with `env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID SPOOL_TEST=1 timeout 900 bash <tst>`
(n=1 each, re-run at 2026-11-24T06:46Z; pass lines `grep -ciE '^ *(ok|pass)'`, fail lines
`grep -ciE '^ *(not ok|fail)'`). My constructed files' sha256 (12 chars): head1 func `188b2b116620`
(**equal to the plan's**), head1 test `6993602851b6`; head2 gh-set-ci-vars `b339ee75b746`,
spl-gh-wire `7817ad138e1b` (**equal to the plan's**), test `52715b54fcc9` (the plan's head sha256s
differ on 3 of 5 files — see N1; every control below fails with the plan's exact quoted line and counts).
Control test sha256 (full): head1 test
`6993602851b62e46887123ace9e4988422ab3847c53ba5de9ce66e558582fb0b`, head2 test
`52715b54fcc92a315ee33a49c42187202c7bd731b5ff7678d125fdb742cd45c3`; plan
`2dd5c01f4aeb7a3d39748c4c39ef789d7e46203bfe3f27131cd91fc74231189d`.

- **base** `desk-mirror-actions.tst.sh`: rc **0**, 18 pass / 0 fail, last line
  `PASS: all desk-mirror-actions.tst.sh assertions`. **base** `spl-gh-wire.tst.sh`: rc **0**, 18/0,
  last line `PASS: all spl-gh-wire.tst.sh assertions`.
- **Row 01 green** (head1): rc **0**, 19 pass / 0 fail (the one-copy check adds 1), last line
  `PASS: all desk-mirror-actions.tst.sh assertions`.
- **Row 01 red** (rc1, head1's `desk-mirror-actions.tst.sh` on base): rc **1**, 17 pass / 2 fail lines
  (1 assertion + summary `FAIL: 1 assertion(s)`), the fail line
  `FAIL: 3. one copy: spl-desk-mirror-settings.func.sh keeps its own hooks JSON builder, or no call of smh_hooks_json: 42:  python3 - "$1" <<'EOF_PY' 44:p = shlex.quote(sys.argv[1]) 47:print(json.dumps({"hooks": {"UserPromptSubmit": h, "Stop": h}}, indent=2, sort_keys=True)) 48:EOF_PY`
  — the plan's 1.5 quote verbatim.
- **Row 01 guard** (gc1, head1-noguard with the `declare -F smh_hooks_json` line deleted): rc **1**,
  17 pass / 2 fail, `FAIL: 3. settings: .../spl-desk-mirror-settings.func.sh: line 44: smh_hooks_json: command not found`
  (printed twice: once for `do_spl_desk_mirror_settings`, once for the direct
  `spl_desk_mirror_settings_json` call) — the plan's quote.
- **Row 02 green** (head2): rc **0**, 18 pass / 0 fail, last line
  `PASS: all spl-gh-wire.tst.sh assertions`.
- **Row 02 red** (rc2, head2's `spl-gh-wire.tst.sh` on base): rc **1**, 16 pass / 1 fail, the fail line
  `FAIL: 9. one copy: spl-gh-wire.func.sh keeps its own variable read/write, or no call of _gscv_set: 108:  gh variable set "$name" --repo "$repo" --body "$want" >/dev/null \`
  — the plan's 1.5 quote (naming `:108`).
- **Row 02 guard** (gc2, head2-noguard with the `declare -F _gscv_set` line deleted): rc **9**,
  8 pass / 9 fail (including `FAIL: 1. dry run`, `FAIL: 3. set`, `FAIL: 3. re-run`), with
  `.../spl-gh-wire.func.sh: line 100: _gscv_set: command not found` — the plan's quote.

Every control fails for the plan's reason (the own copy still present / the load line missing),
not for an environment reason, and none touches live state: all runs were in scratch worktrees
under `/tmp/r95` with `SPOOL_TEST=1` and the suites' own temp dirs;
`grep -l '/var/spool-hub' /tmp/r95/re-*.out | wc -l` -> **0**.

## 4. Equivalence of each row

- The deleted bodies are byte-identical to the shared ones (check 2: both `diff`s empty at base),
  and the changed call sites pass the same arguments: row 01's `spl_desk_mirror_settings_json "$1"`
  becomes `smh_hooks_json "$1"` with the same `"$1"`; row 02's two 12-line tails become one
  `_gscv_set "$repo" "$name" "$want" "$dry"` call with the same 4 positional arguments in both
  `_gscv_apply` and `_sgw_apply`.
- The head diffs contain only the described change: head1 func `+4 -7` (49 -> 46 lines), head1 test
  `+7 -1` (130 -> 136); head2 gh-set-ci-vars `+10 -4` (73 -> 79), spl-gh-wire `+4 -15` (146 -> 135),
  test `+6 -6` (196 -> 196) — measured with `git diff --numstat` inside each head worktree
  (plan section 6: +4 -7 / +6 -1 / +9 -3 / +4 -15 / +6 -6; the two deltas are N1).
- Line-cap check (cap 75): in my head2, `_gscv_set` is 15 lines (plan says 14 — one extra comment
  line, N1), `_gscv_apply` shrinks 17 -> 6, `_sgw_apply` 23 -> 12 — all under the cap.
- `shellcheck -S warning -x` on the 5 head files (head1 func + test, head2's 3): rc **0** each,
  0 findings (n=1 each, re-run 06:46Z).
- Behaviour: the affected suites pass on base and on the heads with identical counts plus the new
  one-copy assertion (check 3: 18/0 -> 19/0 for row 01; 18/0 -> 18/0 with case 9 updated in place
  for row 02). The controls catch a difference: the red controls fail while the own copy is present
  (RED on base, GREEN on the head); the guard controls fail when the load line is deleted. No row
  changes an exit code, a message, a path or a default: each row is ONE logical refactor.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after (reproduced in check 3),
a test list, box `either`, vendor `claude`, kind `simple_coding`, batch 1. The R2 greps match on
`c4000b25b`: `git grep -lE 'spool-mirror-hooks|smh_hooks_json|smh_install|spl-desk-mirror-settings|spl_desk_mirror_settings|do_spl_desk_mirror_settings' c4000b25b -- '*/tests/*'`
-> `desk-mirror-actions.tst.sh`, `tests-hermetic.tst.sh`, `vibe-heartbeat.tst.sh`, `agent-mcp.tst.sh`,
`test-agent-hook-main-checkout.sh`, `test-install.sh`, `test-y12-vibe-push-guard.sh` (plus the keeper
users `test-spool-agent.sh`, `test-spool-harness.sh` and the shared gates);
`git grep -lE 'spl-gh-wire|gh-set-ci-vars|_sgw_|_gscv_|do_spl_gh_wire|do_gh_set_ci_vars' c4000b25b -- '*/tests/*'`
-> `spl-gh-wire.tst.sh`, `gh-set-ci-vars.tst.sh`, `git-env-isolation.tst.sh`, `route-ci-overflow.tst.sh`
(plus the shared iac/orc gates). No new test file is added, so `orc-shard-weights.txt` needs no line:
`git grep -nE 'spl-gh-wire|gh-set-ci-vars|desk-mirror|spool-mirror-hooks' c4000b25b -- '*shard-weights*'`
-> 1 pre-existing line (`orc-shard-weights.txt:111: desk-mirror-actions.tst.sh 10`). The only 30+-char
comment naming a site under `*/tests/*` is the cited header `spl-gh-wire.tst.sh:21` (row 02's own site).
No mistral coding or testing row (owner 10-17, t1 b61851fb). R7 (plan section 4): grok per row
(`BOX_PICK_KIND=grok` pick at the plan's 06:06:04Z: grok weekly 89% on both boxes, not held), or the
claude waiver seat if held at placement — never mistral. R1: the two rows' 5 files are distinct
(`printf '%s\n' <the 5 paths> | sort | uniq -d | wc -l` -> **0**), so no file is shared within
batch 1. 2 rows, within 5.1's aim 2 / at most 3; 5.3's numbering r95 with the plain plan name free
on trunk (check 1).

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 7 paths, comma-separated> --agent m-969`
-> **exit 4**: `WARN no live lane lists <the 7 paths>, but 10 live lane(s) record no files`;
`unknown:` lanes, all on the other box: c-029, c-041, c-086, c-146, c-187, c-384 (spec 181 B13),
c-924, c-927, g-554 (B9 R7), g-565 (B11 R7). No lane is reported as owning any row path.

The brief's named live/queued lanes — spec 181 B9 c-916, B11 c-918, B13 c-384, SPL-6239 T6 c-478,
SPL-6346 c-925, bug round 43's planner: briefs changed in the last 24 h naming any of the 7 paths or
their functions -> exactly 4, only the closed/landed r94-01 / r94-02 / b42 planner briefs
(`c002-r94-01-iac-gh-wire-var-get.md`, `hand-<box>-c002-r94-01-grok-reviewer.md`,
`c002-r94-02-orc-ksr-role-seat.md`, `c002-bug-round-42-planner.md`); none live. Remote branches
committed in the last 24 h: `git diff --name-only $(git merge-base c4000b25b origin/<b>) origin/<b> -- <the 7 paths>`
over all of them -> **0 hits**; `git log c4000b25b --since='24 hours ago' -- <the 7 paths>` -> **1**:
`ffe718a28` (r94-01, already landed and closed). Spawn queue
(`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 06:45Z): 3 queued, 0 placing, 1 held
(spec 181 B9 follow-up waiting on SPL-6341); no queued row touches a row path.

## 7. Inputs accounted for

- The candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md` (131 lines, read
  06:4xZ on this box) — its refactor-shaped items, each re-checked on `c4000b25b`:
  - WUI entry-chunk headroom (`for refactor round 95` block): served by SPL-6342
    (`c68cca820`..`e62b847c3`, entry-chunk gzip 154.7 -> 151.9 KB) — accounted in plan 1.2 (c).
  - dead `/tmp` worktrees: served by SPL-6347 (`5e77f4c8b`, `11c6582fc`).
  - `spl-watchdog` `LOGIN_STATE_DIR` literal: gone as a literal default —
    `git grep -n 'LOGIN_STATE_DIR' c4000b25b -- '*.sh'` -> only `spl-claude-login.func.sh:29`
    (`[[ -n "${LOGIN_STATE_DIR:-}" ]] && ...`, else derived from `SPL_VAR_APP_DIR`) and a test — served.
  - reverse-tunnel state dir: `setup-reverse-tunnel.func.sh:41,49` derives it via
    `spl_var_app_subdir dir reverse-tunnel` (`$SPL_VAR_APP_DIR`) — served.
  - `spl-desk-reply.sh:9,19` usage lists all kinds
    (`note|result|reject|blocker|msg|feature|bug|alert|question|idea|decision|docs`) — served.
  - agy words: `git grep -cE 'needs_agy_review|waits for an agy review|agy has the final word' c4000b25b -- ':!*.md' | wc -l`
    -> **0** — served (SPL-6308).
  - `asks_peers_on` / `send_to_peers_on` (`sa:scripts/asks.sh:46-50`, `sa:scripts/spool-send.sh:267-271`):
    `diff -u` of the two 5-line bodies with the name substituted -> **no hunk, rc 0** (byte-identical);
    both scripts already source `spool-fleet.inc.sh` — accounted in plan section 7 (r96 candidate).
  - `i18n-lang-review-exempt.json:2` (`csi-spl-wui/i18n/i18n-lang-review-exempt.json`) = the `_doc`
    line — accounted in plan section 7.
  - the rest are bug-, test-, doc- or feature-shaped.
- Perf floor (rulebook 4.4) re-run at 06:46Z, the rulebook's own command
  (`git fetch -q origin master && git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk ...`)
  -> `perf 29 refactor 97 perf-share 23.0% floor-met` — matches the plan's read (23.0%, floor-met),
  so this is a refactor round.
- Plan 1.2 (a): `git diff --name-only 65b1bd21a c4000b25b | wc -l` -> **177** (matches the plan).
- Plan 1.2 (d): `git log c4000b25b --since=2026-11-23T17:37:58Z --oneline -- csi-spl-doc/specs/011-spool-project-refactor`
  -> **0** (matches).
- **No refactor-shaped input is neither served nor accounted for.** Each row is ONE logical
  refactor with no behaviour change (check 4): no row changes an exit code, a message, a path
  or a default.

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-969`, rc **0**
(run before this file was written at 06:4xZ; re-run after adding it, still rc 0 — see the commit).

## Defects

None (no W1...).

## Notes

- **N1** the heads are not committed anywhere, so I constructed them per the plan's 1.3/1.4
  shape; my files' sha256 (12 chars) differ from the plan's on 3 of 5 (head1 test
  `6993602851b6` vs `bc6effe980f2`, numstat `+7 -1` vs the plan's `+6 -1`, 136 vs 135 lines;
  head2 gh-set-ci-vars `b339ee75b746` vs `26a373f902b6`, `+10 -4` vs `+9 -3`, `_gscv_set` 15 vs 14
  lines — one extra comment line; head2 test `52715b54fcc9` vs `b64bc10e82d6`); head1 func
  `188b2b116620` and head2 spl-gh-wire `7817ad138e1b` **equal** the plan's. Every red/guard
  control fails with the plan's exact quoted line and counts (rc1: rc 1, 17/2, the `:42/:44/:47/:48`
  quote; gc1: rc 1, 17/2, `smh_hooks_json: command not found` at line 44; rc2: rc 1, 16/1, the
  `:108 gh variable set` quote; gc2: rc 9, 8/9, `_gscv_set: command not found` at line 100).
  Same reason, not an environment reason.
- **N2** `origin/master` == the plan's base `c4000b25b` at my read (06:46Z fetch), so
  `git diff --name-only c4000b25b origin/master -- <the 7 paths>` is empty and every site stands.
- **N3** the lane map at my read exits 4 with the same 10 unknown-scope lanes the plan saw at
  06:10Z (the 8 `*-rotate` seats on the other box plus c-384 and the two R7 reviewers g-554/g-565).
  0 hits on the row paths either way; the row lanes re-run R3 at spawn.
