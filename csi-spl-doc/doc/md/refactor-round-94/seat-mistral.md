# Refactor round 94 — panel seat mistral (m-762@<box>)

Issue: SPL-6325 (epic SPL-2402, Issue-Role: shared). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-94-mistral-panel-seat.md`
(`c002-refactor-round-94-mistral-panel-seat`).

Review target: `csi-spl-doc/doc/md/refactor-round-94-plan.md` on branch
`review/c002-refactor-round-94-planner` at v0.1
**`cea1ce85384702249cbfc1c4b8d5703aa47d0f7d`** (named by the dispatch holder c-002@<box>,
msg 4ce76616 on task dispatch-refactor-r94, 2026-11-23T17:59:46Z).

- `git ls-remote origin refs/heads/review/c002-refactor-round-94-planner` ->
  `cea1ce85384702249cbfc1c4b8d5703aa47d0f7d` (re-read at 18:0xZ, head unmoved; 1 commit on
  `65b1bd21a`, 1 file `csi-spl-doc/doc/md/refactor-round-94-plan.md` +462, author/committer
  csitea.net per `git log -1 --format='%an <%ae> %cn <%ce>'`).
- `git show cea1ce85384702249cbfc1c4b8d5703aa47d0f7d:csi-spl-doc/doc/md/refactor-round-94-plan.md | sha256sum`
  -> `df7ddf9577f4117a31628faca943624a8a8c5cab9949e86b6ca24e197ab54214` (the copy I read;
  462 lines).
- Plan base: `65b1bd21a` = `origin/master` at the plan's read (2026-11-23T17:37:58Z).
  `origin/master` is now `2d4354486` (the r93 close record, committed 2026-11-23T19:44:39+02:00);
  re-fetched before every check below.

**Verdict: PASS on `cea1ce85384702249cbfc1c4b8d5703aa47d0f7d`.** No W defects. Notes N1..N5 below.

## 1. Slug r94 unused since the plan's `Window: W=`

`W=2026-11-23T18:16:45+02:00` (the plan's recorded window).

- The recorded W matches `git log -1 --format='%H %cI %s' 16fbe330e` ->
  `16fbe330e4c62b5c5d082cee74e61547b5308f11 2026-11-23T18:16:45+02:00 docs(r93-plan, SPL-6317): refactor round 93 plan v0.1 for the panel: ...`
  (the newest `docs(r93-plan` commit at the plan's 17:37:58Z read). Today the newest is
  `2d4354486` (the r93 close record, landed after that read), as the plan itself notes.
- `git log origin/master --since="$W" --oneline -E --grep='\(r94-' | wc -l` -> **0**; with
  `--since` from the close record's date -> **0**; over all history -> **1**:
  `ae4898ae1` (`fix(b29-02-orc-place-panel-seat-digit-suffix, SPL-6093)`, committed
  2026-11-20T21:26:23+01:00, before W; its body quotes the test-fixture slug
  `r94-spec-panel-seat-3` of `spl-spawn-queue.tst.sh`) — not a round-94 commit.
- `git ls-remote origin | grep -E 'r94-[0-9]{2}|refactor-round-94'` -> only
  `cea1ce85384702249cbfc1c4b8d5703aa47d0f7d  refs/heads/review/c002-refactor-round-94-planner`
  (the planner's; this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r94-[0-9]{2}|refactor-round-94'` -> exactly
  `c002-refactor-round-94-mistral-panel-seat.md` and `c002-refactor-round-94-planner.md`.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-94` -> **0**
  (the plain name is free on trunk).

## 2. Every site file:line of every row exists on the plan's base sha and still on origin/master

Row paths (4) plus the keepers (6 total): `iac:src/bash/run/spl-gh-wire.func.sh`,
`iac:src/bash/tests/spl-gh-wire.tst.sh`, keeper `iac:src/bash/run/gh-set-ci-vars.func.sh`;
`sa:scripts/kill-your-self-report.sh`, `sa:tests/test-kill-your-self-gate.sh`, keeper
`sa:lib/spool-caller.inc.sh` (`iac:` = `csi-spl-iac/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`).

- `git diff --name-only 65b1bd21a origin/master -- <the 6 paths>` -> **empty** (re-fetched before
  this read; `origin/master` = `2d4354486`), so every base line still stands on trunk.
- Each cited line checked with `git show 65b1bd21a:<file> | sed -n <N>p`:
  - `spl-gh-wire.func.sh:90-96` = the 2-line comment (`:90-91`), `_sgw_get` (`:92-95`, body
    `:93-94`), blank `:96`; the two calls `:105` and `:114` are
    `have="$(_sgw_get "$repo" "$name")"` — match 1.3.
  - `gh-set-ci-vars.func.sh:34-39` = the same comment (`:34-35`), `_gscv_get` (`:36-39`, body
    `:37-38`); calls `:46`, `:55` — match 1.3.
  - `route-ci-overflow.func.sh:109-110` = the `declare -F do_gh_set_ci_vars` guarded source of
    `gh-set-ci-vars.func.sh` — match 1.3.
  - `spl-gh-wire.tst.sh:19-20` (item 8 header), `:29` (`FUNC="$PROJ_ROOT/src/bash/run/spl-gh-wire.func.sh"`),
    `:106` (the `bash -c ... source` line), `:179` (`# --- CONTROLs`) — match 1.3.
  - `kill-your-self-report.sh:63` (`_here` via `readlink -f`), `:65` `. "$_here/../lib/spool-env.inc.sh"`,
    `:67` `agent-state.inc.sh`, `:69` `lane-issue.inc.sh`; `:147-148` the 2-line comment,
    `:149-152` `ksr_is_seat` (body `:150-151`), `:153` blank; calls `:156`
    (`ksr_is_seat "$1" && return 0`) and `:178` (`if ksr_is_seat "${ID%@*}"; then`) — match 1.4.
  - `spool-caller.inc.sh:6` (the one top-level line `_spool_caller_dir`), `:8` comment,
    `:9-12` `send_role_seat` (body `:10-11`) — match 1.4.
  - `test-kill-your-self-gate.sh:120-121` (the `LEASE_MASTER=c-777` holder check and the
    `c-002` rotation check), `:131` (the rotation `eq` line) — match 1.4.
  - `test-lane-issue.sh:59` (`cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$CTL/"`),
    `enc-dirs-untouched.tst.sh:57` (scans `kill-your-self-report.sh`) — match 1.4.
  - Section 7 sites: `spool-mirror-hooks.inc.sh:30-38` (`smh_hooks_json`), `spl-desk-mirror-settings.func.sh:41-49`
    (`spl_desk_mirror_settings_json`); `.shellcheck-warning-baseline.txt:51-52`
    (`SC2034|...spool-mirror-hooks.inc.sh|2`, `SC2088|...|2`); `desk-mirror-actions.tst.sh:115`
    (calls `spl_desk_mirror_settings_json` directly); `lane-age-report.sh:33`, `spl-box-leave.func.sh:298`,
    `spl-lane-backfill-links.func.sh:78` (the other `LEASE_(MASTER|FAILOVER|ORCH)` sites, each on a
    different path var `$R` / `$LEASE_CONF` / `${SPOOL_ROOT:-...}`); `gh-set-ci-vars.func.sh:28-32`
    (`_gscv_repo`), `spl-gh-wire.func.sh:49-53` (`_sgw_repo`), applies `:46-57` vs `:105-116`;
    `specs/172-work-chain-enforcement/spec.md:173` (prose naming `lane_is_role_seat`;
    `git grep -n lane_is_role_seat 65b1bd21a -- csi-spl-doc/specs/ | wc -l` -> 1);
    `i18n-lang-review-exempt.json:2` (the `_doc` line) — all match section 7.
- Byte-identity (n=1 each, on `65b1bd21a`):
  `diff -u <(git show 65b1bd21a:gh-set-ci-vars.func.sh | sed -n 34,39p) <(git show 65b1bd21a:spl-gh-wire.func.sh | sed -n 90,95p | sed 's/_sgw_get/_gscv_get/')`
  -> **no hunk, rc 0** (row 01);
  `diff -u <(git show 65b1bd21a:spool-caller.inc.sh | sed -n 9,12p | sed 's/  # ID//') <(git show 65b1bd21a:kill-your-self-report.sh | sed -n 149,152p | sed 's/ksr_is_seat/send_role_seat/; s/  # ID (bare)//')`
  -> **no hunk, rc 0** (row 02: the bodies `:10-11` / `:150-151` are byte-identical).
- `git grep -nE '_gscv_get|_sgw_get' 65b1bd21a -- ':!*.md'` -> the 2 definitions
  (`gh-set-ci-vars.func.sh:36`, `spl-gh-wire.func.sh:92`) and the 4 calls (`:46`, `:55`, `:105`,
  `:114`), no test names — as 1.3 says.
- `git grep -n 'ksr_is_seat' 65b1bd21a -- ':!*.md'` -> the 1 definition (`:149`) and 2 calls
  (`:156`, `:178`); `-- '*.md'` -> 0 — as 1.4 says.
- `send_role_seat` callers on base: `lane-map.sh:80` (r93-01), `spool-send.sh:172,176,236`,
  `spl-sender-audit.func.sh:125` — as 1.4 says.
- No name collision: `git show 65b1bd21a:spl-gh-wire.func.sh | grep -cE '_gscv_|do_gh_set_ci_vars'` -> 0;
  `git show 65b1bd21a:kill-your-self-report.sh | grep -cE '_spool_caller_dir|send_(role_seat|caller_|chain_caller)'` -> 0.
- Line counts at base: `wc -l` -> spl-gh-wire.func.sh **150**, spl-gh-wire.tst.sh **189**,
  kill-your-self-report.sh **313**, test-kill-your-self-gate.sh **157** — the plan's head claims
  (150->146, 189->196, 313->309, 157->162) are consistent.

## 3. Each red control: read, run on the plan's base in a scratch copy (n=1), last line + exit code

Heads are not committed anywhere, so I built them per the plan's 1.3/1.4 shape in detached
worktrees of `65b1bd21a` (`git worktree add /tmp/r94/{base,head1,head2,head1-noguard,head2-noguard} 65b1bd21a`),
ran as the push user with `env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID SPOOL_TEST=1 timeout 900 bash <tst>`.
My constructed files' sha256 (12 chars): head1 func `37c1f6e71482`, test `177803487ac9`;
head2 script `0b4355d6242a` (**equal to the plan's**), test `a17d88482869` (the plan's head
sha256s differ on 3 of 4 files — see N1; line counts match exactly: 146 / 196 / 309 / 162, and
every control below fails with the plan's exact quoted line and counts).

- **Row 01 red** (rc1, head1's `spl-gh-wire.tst.sh` run on base): rc **1**, 16 pass / 1 fail,
  the fail line
  `FAIL: 9. one copy: spl-gh-wire.func.sh keeps its own variable read, or no call of _gscv_get: 92:_sgw_get() {  # <repo> <name> 93:  local v; v="$(gh api "repos/$1/actions/variables/$2" --jq .value 2>/dev/null)" && printf '%s\n' "$v" 105:  have="$(_sgw_get "$repo" "$name")" 114:  have="$(_sgw_get "$repo" "$name")"`
  — the plan's 1.5 quote (its `93:  local v; ...` is the same line truncated). On head1:
  rc **0**, 18 pass / 0 fail, last line `PASS: all spl-gh-wire.tst.sh assertions`.
- **Row 01 guard** (gc1, head1 with the `declare -F _gscv_get` line deleted): rc **3**,
  15 pass / 3 fail — `FAIL: 3. set`, `FAIL: 3. re-run`, `FAIL: 4. update` — with
  `.../spl-gh-wire.func.sh: line 100: _gscv_get: command not found` and
  `line 109: _gscv_get: command not found` — the plan's quote verbatim.
- **Row 02 red** (rc2, head2's `test-kill-your-self-gate.sh` run on base): rc **1**, 36 pass /
  1 fail, last line `-- test-kill-your-self-gate.sh: 36 passed, 1 failed`, the fail line
  `FAIL - one copy: kill-your-self-report.sh keeps no ksr_is_seat and calls send_role_seat twice (want '|2', got '149:ksr_is_seat() {  # ID (bare)|0')`
  — the plan's quote (its `...` truncates the `|0`). On head2: rc **0**, 37 pass / 0 fail,
  last line `-- test-kill-your-self-gate.sh: 37 passed, 0 failed`.
- **Row 02 guard** (gc2, head2 with the `. "$_here/../lib/spool-caller.inc.sh"` line deleted):
  rc **1**, 25 pass / 12 fail, last line `-- test-kill-your-self-gate.sh: 25 passed, 12 failed`,
  including `FAIL - a refusal is one line`, `FAIL - a peer REJECT after ACCEPTED: runs`,
  `FAIL - holder REJECT after ACCEPTED: ...` x2, with
  `.../kill-your-self-report.sh: line 151: send_role_seat: command not found` (line 151 in my
  head2-noguard; the plan's 149 — my 2-line source insert shifts it, see N1) — the plan's quote.

Every control fails for the plan's reason (the own copy still present / the load line missing),
not for an environment reason, and none touches live state: all runs were in scratch worktrees
under `/tmp/r94` with `SPOOL_TEST=1` and the suites' own temp dirs.

## 4. Equivalence of each row

- The deleted bodies are byte-identical to the shared ones (check 2: both `diff`s empty at
  base), and the changed call sites pass the same arguments: row 01's two reads become
  `have="$(_gscv_get "$repo" "$name")"` where they called `_sgw_get` with the same `"$repo" "$name"`;
  row 02's `:156` calls `send_role_seat "$1"` and `:178` calls `send_role_seat "${ID%@*}"` where
  they called `ksr_is_seat` with the same argument.
- The head diffs contain only the described change: head1's `spl-gh-wire.func.sh` is
  `90,96d89` + `97a90,92` (the 3 guard lines) + `105c97` / `114c106` (the renamed calls) only;
  head2's `kill-your-self-report.sh` is `69a70,71` (the 2 source lines), `147,153c72` (the
  1-line comment), `156c158`, `178c180` only.
- Behaviour: the full 20-suite column of 1.5 re-run on base, head1 and head2 (n=1 each, same
  run form as check 3), pass/fail counted with `grep -ciE '^ *(ok|pass)'` /
  `grep -ciE '^ *(not ok|fail)'`:

  | suite | base rc/pass/fail | head1 | head2 |
  |---|---|---|---|
  | `iac:.../spl-gh-wire.tst.sh` | 0 / 17 / 0 | 0 / 18 / 0 (case 9 adds 1) | = |
  | `iac:.../gh-set-ci-vars.tst.sh` | 0 / 14 / 0 | = | = |
  | `iac:.../git-env-isolation.tst.sh` | 0 / 7 / 0 | = | = |
  | `iac:.../no-box-path-source.tst.sh` | 0 / 10 / 0 | = | = |
  | `iac:.../action-header-tags.tst.sh` | 0 / 6 / 0 | = | = |
  | `iac:.../param-required.tst.sh` | 0 / 17 / 0 | = | = |
  | `orc:.../route-ci-overflow.tst.sh` | 0 / 38 / 0 | = | = |
  | `sa:tests/test-kill-your-self-gate.sh` | 0 / 36 / 0 | = | 0 / 37 / 0 (one-copy adds 1) |
  | `sa:tests/test-kill-your-self-report.sh` | 0 / 31 / 0 | = | = |
  | `sa:tests/test-kill-your-self-result.sh` | 0 / 20 / 0 | = | = |
  | `sa:tests/test-lane-issue.sh` | 0 / 206 / 0 | = | = |
  | `sa:tests/test-spool-send-from-guard.sh` | 0 / 28 / 0 | = | = |
  | `orc:.../sender-audit.tst.sh` | 0 / 35 / 0 | = | = |
  | `orc:.../lane-map.tst.sh` | 0 / 149 / 0 | = | = |
  | `orc:.../enc-dirs-untouched.tst.sh` | 0 / 18 / 0 | = | = |
  | `orc:.../run-eager-files.tst.sh` | 0 / 14 / 0 | = | = |
  | `orc:.../no-literal-paths.tst.sh` | 0 / 15 / 0 | = | = |
  | `orc:.../func-name-unique.tst.sh` | 0 / 2 / 0 | = | = |
  | `iac:.../run-lazy-loader.tst.sh` | 0 / 30 / 0 | = | = |
  | `iac:.../bash-cleancode.tst.sh` | 0 / 15 / 0 | = | = |

  Every count equals the plan's 1.5 column. `shellcheck -S warning -x` on the 4 row files in
  each of base / head1 / head2: rc **0**, 0 findings, 12 runs (n=1 each).
- The controls catch a difference: the red controls fail while the own copy is present (RED on
  base, GREEN on the head); the guard controls fail when the load line is deleted. No row
  changes an exit code, a message, a path or a default: each row is ONE logical refactor.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after (reproduced in check
3), a test list (the R2 greps match: row 01 -> `spl-gh-wire.tst.sh`, `gh-set-ci-vars.tst.sh`,
`git-env-isolation.tst.sh`, `route-ci-overflow.tst.sh` on `65b1bd21a`, plus the iac gates
`no-box-path-source`, `action-header-tags`, `param-required`, `run-lazy-loader`, `bash-cleancode`;
row 02 -> `test-kill-your-self-gate.sh`, `test-kill-your-self-report.sh`,
`test-kill-your-self-result.sh`, `test-lane-issue.sh`, `channel-move-plan.tst.sh`,
`enc-dirs-untouched.tst.sh`, `lane-map.tst.sh`, plus the keeper's users
`test-spool-send-from-guard.sh` and `sender-audit.tst.sh` and the shared gates). No new test
file is added, so `orc-shard-weights.txt` needs no line
(`git grep -nE 'spl-gh-wire|kill-your-self-gate' 65b1bd21a -- '*shard-weights*'` -> none).
Box `either`, vendor `claude`, kind `simple_coding`, batch 1 for both rows. No mistral coding or
testing row (owner 10-17, t1 b61851fb). R7 (plan section 4): re-run now —
`cd csi-spl-orc && BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 17:5xZ printed
`pick=<box> ... grok weekly 71%` on both boxes and at 18:30:45Z `pick=<box> reason=every box is
at or above its high mark ... grok weekly 71%` — a grok R7 seat per row holds (the plan recorded
`68% < 70%` at 17:38:52Z); either way grok or the claude waiver seat, never mistral. R1: the
two rows' 4 files are distinct (`printf '%s\n' <the 4 paths> | sort | uniq -d | wc -l` -> **0**),
so no file is shared within batch 1. 2 rows, within 5.1's aim 2 / at most 3; 5.3's numbering
r94 with the plain plan name free on trunk (check 1).

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 6 paths, comma-separated> --agent m-762`
-> **exit 4**: `WARN no live lane lists <the 6 paths>, but 10 live lane(s) record no files`;
`unknown:` lanes, all on the other box: c-029, c-041, c-086, c-146, c-187, c-261 (spec 181 B2),
c-279 (spec 181 B12), c-924, c-927, g-280 (all `*-rotate` seats except the two spec-181 rows).
No lane is reported as owning any row path.

The brief's named live/queued lanes, `lane-map.sh list --all --json` at 18:2xZ: r93-01 c-727
(done), r93-02 c-259 (done), SPL-5985 c-712 (done), SPL-6323 c-264 (done), contacts flake
c-738 + g-757 (live, `files=[]`), spec 181 c-261 / c-279 + g-754 (live/done, `files=[]`),
SPL-6318 a-729 (live, `files=[]`), SPL-6319 a-731 (done), c-707 (done), a-756 (live, the
planner), m-762 (this seat): none records any of the 6 row files. Remote branches committed in
the last 24 h: `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 6 paths>`
over all of them -> **0 hits**; `git log origin/master --since='24 hours ago' -- <the 6 paths>`
-> **0**.

## 7. Inputs accounted for

- The candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md` (115 lines, read
  18:0xZ on this box) — its refactor-shaped items, each re-checked on `origin/master`:
  - reverse-tunnel cron literal: `reverse-tunnel-cron.sh:27` now reads
    `"${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}"` — served.
  - wf 10 disk comment: `10_ci-quality.yml:440-446` now says "only about 96 MB of it is left" —
    served.
  - uplink probe comment: `spl-uplink-probe.func.sh:14-15` now names the config-fault
    `FATAL with rc 1` — served.
  - `spl-lane-mix.func.sh` agy words:
    `git grep -cE 'needs_agy_review|waits for an agy review|agy has the final word' origin/master -- ':!*.md' | wc -l`
    -> **0** — served.
  - r34 row 05 R7 N3 literals (`spl-watchdog.func.sh:72,:1311`, `spl-lane-rotate.func.sh:112`):
    `git grep -nE '/var/[a-z]' origin/master -- spl-watchdog.func.sh spl-lane-rotate.func.sh`
    -> one `@example` line only (`spl-watchdog.func.sh:76`, a doc example, not a default);
    `:72` now names `<SPL_VAR_APP_DIR>/agent-login-check` — served.
  - SPL-6107 N1 (`spl-desk-reply.sh:9,19` usage kinds): the script now lives at
    `csi-spl-orc/src/bash/scripts/spl-desk-reply.sh`, and `:9`/`:19` list
    `note|result|reject|blocker|msg|feature|bug|alert|question|idea|decision|docs` — served.
  - b12-02 N2/N3/N4 (`-input=false`, `tf-log-mask` `${1:?}`, dropped rc): accounted as bug rows
    in r84 7, carried by r90 7 (`parse-metadata.func.sh ${1:?} lines, terraform -input=false,
    dropped rc | bug rows | r84 7`).
  - b37's `_ppe_keys` / `msg-menu` e2e selector: accounted in r88 7 (`test rows, a gate-design
    item | r83 7; candidates file`).
  - `i18n-lang-review-exempt.json:2` `_doc`: accounted in this plan's section 7.
  - the rest are bug-, test-, doc- or feature-shaped.
- r93 plan section 7 read on `origin/master`: `_gscv_get` / `_sgw_get` -> this plan's row 01;
  the `i18n-lang-review-exempt.json:2` line and the 1-line groups -> this plan's section 7;
  the agy words -> served (0 hits above); every other r92/r91 item: `git diff --name-only
a7b5ae564 65b1bd21a` -> 35 files (the plan's 1.2 (a) count), none of them a section-7 leftover.
- `git log origin/master --since=2026-11-23T15:28:34Z -- csi-spl-doc/specs/011-spool-project-refactor`
  -> **0** (the plan's 1.2 (d)).
- The scan's new candidates are in no earlier plan:
  `git grep -lE 'ksr_is_seat|smh_hooks_json|spl_desk_mirror_settings_json' origin/master -- 'csi-spl-doc/doc/md/refactor-round-*-plan.md'`
  -> none; `_gscv_get|_sgw_get` and `send_role_seat` -> only `refactor-round-93-plan.md`.
- **No refactor-shaped input is neither served nor accounted for.** Each row is ONE logical
  refactor with no behaviour change (check 4): no row changes an exit code, a message, a path
  or a default.

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-762`, rc **0**
(run before this file was written; re-run after adding it, still rc 0).

## Defects

None (no W1...).

## Notes

- **N1** the heads are not committed anywhere, so I constructed them per the plan's 1.3/1.4
  shape; my files' sha256 (12 chars) differ from the plan's on 3 of 4 (head1 func
  `37c1f6e71482` vs `52ffd2f53550`, test `177803487ac9` vs `ac01a5e55120`; head2 test
  `a17d88482869` vs `a9be7f6850a3`; head2 script `0b4355d6242a` **equals** the plan's). Line
  counts match exactly (146 / 196 / 309 / 162). Every red/guard control fails with the plan's
  exact quoted line and counts (16/1 -> 18/0; 15/3 with `command not found` at lines 100/109;
  36/1 -> 37/0; 25/12); gc2's `command not found` is at line 151 in my head2-noguard vs the
  plan's 149 — my 2-line source insert shifts it. Same reason, not an environment reason.
- **N2** `origin/master` moved `65b1bd21a` -> `2d4354486` (the r93 close record) during the
  review; `git diff --name-only 65b1bd21a origin/master -- <the 6 row/keeper paths>` is empty
  (re-read 18:2xZ), so every site stands.
- **N3** the lane map at my read exits 4 with 10 unknown-scope lanes (the plan saw 9 at
  17:41Z): the 8 `*-rotate` seats on the other box plus c-261 and c-279 (spec 181) and g-280.
  0 hits on the row paths either way; the row lanes re-run R3 at spawn.
- **N4** the grok box pick at my reads: 17:5xZ `pick=<box> ... grok weekly 71%` on both boxes,
  18:30:45Z `pick=<box> reason=every box is at or above its high mark; ... grok weekly 71%` —
  a grok R7 seat per row holds (the plan recorded `68% < 70%` at 17:38:52Z); either way grok or
  the claude waiver seat, never mistral.
- **N5** the candidates file is present on this box (115 lines, read); every refactor-shaped
  item in it was re-checked against the tree claim by claim (section 7 above).
