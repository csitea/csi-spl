# Refactor round 93 — panel seat mistral (m-234@<box>)

Issue: SPL-6317 (epic SPL-2402, Issue-Role: shared). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/spawn-remote/briefs/70b3ca18-67fd-4b89-b51f-ea3f4d03f066.md`
(`c002-refactor-round-93-mistral-panel-seat`).

Review target: `csi-spl-doc/doc/md/refactor-round-93-plan.md` on branch
`review/c002-refactor-round-93-planner` at v0.1
**`d2ee354765f0848b317b0a2652d704876e1bc36e`** (named by the dispatch holder c-002@<box>,
msg 1007f42b on task 1207a5dc, 2026-11-23T15:40:36Z).

- `git ls-remote origin refs/heads/review/c002-refactor-round-93-planner` ->
  `d2ee354765f0848b317b0a2652d704876e1bc36e` (re-read at 15:5xZ, head unmoved; 1 commit on
  `a7b5ae564`, 1 file `csi-spl-doc/doc/md/refactor-round-93-plan.md` +432, author/committer
  csitea.net per `git show --stat` / `git log -1 --format='%an <%ae> %cn <%ce>'`).
- `git show d2ee354765f0848b317b0a2652d704876e1bc36e:csi-spl-doc/doc/md/refactor-round-93-plan.md | sha256sum`
  -> `e957b4be884421a7f6ab5e2644202d7bd15b945b79f7440b76dcbaf623246695` (the copy I read;
  432 lines).
- Plan base: `a7b5ae564` = `origin/master` at read time (`git rev-parse origin/master` ->
  `a7b5ae564e68e1d45b404773f7f59b61c48c458e`, re-fetched before the checks).

**Verdict: PASS on `d2ee354765f0848b317b0a2652d704876e1bc36e`.** No W defects. Notes N1..N5 below.

## 1. Slug r93 unused since the plan's `Window: W=`

`W=2026-11-23T17:27:53+02:00` (the plan's recorded window).

- `git log origin/master -1 --format='%h %cI %s' -E --grep='^docs\(r92-plan'` ->
  `a7b5ae564 2026-11-23T17:27:53+02:00 docs(r92-plan, SPL-6306): refactor round 92 closed: ...`
  — the recorded W matches.
- `git log origin/master --since="$W" --oneline -E --grep='\(r93-' | wc -l` -> **0**; over all
  history -> **0**.
- `git ls-remote origin | grep -E 'r93-[0-9]{2}|refactor-round-93'` -> only
  `d2ee354765f0848b317b0a2652d704876e1bc36e  refs/heads/review/c002-refactor-round-93-planner`
  (the planner's; this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r93-[0-9]{2}|refactor-round-93'` -> rc 1, nothing
  on this box; `grep -l 'refactor-round-93' /var/spool-hub/spawn-remote/briefs/*.md` -> only this
  seat's brief `70b3ca18-67fd-4b89-b51f-ea3f4d03f066.md` (the planner's brief lives on the other box, not
  readable from this box).
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-93` -> **0**
  (the plain name is free on trunk).

## 2. Every site file:line of every row exists on the plan's base sha and still on origin/master

Row paths (4) plus the keeper (5): `sa:scripts/lane-map.sh`, `orc:src/bash/tests/lane-map.tst.sh`,
`sa:lib/channel-move.inc.sh`, `orc:src/bash/tests/channel-move-plan.tst.sh`,
`sa:lib/spool-caller.inc.sh` (`sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`).

- `git diff --name-only a7b5ae564 origin/master -- <the 5 paths>` -> **empty** (origin/master was
  still `a7b5ae564` at read time; re-fetched before this read).
- Each cited line checked with `git show a7b5ae564:<file> | sed -n <N>p`:
  - `lane-map.sh:36` `_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"`;
    `:38` `. "$_here/../lib/spool-env.inc.sh"`; `:74-77` the 4-line comment; `:78`
    `lane_is_role_seat() {  # ID`; `:79` `  spl_is_role_seat "$1" && return 0`; `:80`
    `  grep -qxE "LEASE_(MASTER|FAILOVER|ORCH)=$1" "$SPOOL_ROOT/dispatch/lease.conf" 2>/dev/null`;
    `:81` `}`; `:82` `if [ "$verb" = "done" ] && lane_is_role_seat "$_lane_agent"; then`; `:83-84`
    the INFO line + `exit 0`; `:85` `fi`. All match 1.3.
  - `spool-caller.inc.sh:6` `_spool_caller_dir=...` (the one top-level line); `:8-12` the comment,
    `send_role_seat` `:9`, body `:10-11`; `:14-24` the comment, `send_caller_chain` `:15`, body
    `:16-23`; `:62` `chain="$(send_caller_chain "$root" "$pid")"`. All match 1.3/1.4.
  - `spool-send.sh:172,176,236` and `spl-sender-audit.func.sh:125` call `send_role_seat` — match.
  - `lane-map.tst.sh:404-421` = case 9 (the `lm()` harness, the four role-seat ids c-001/c-002/
    c-003/c-412, the c-077 control) — match.
  - `channel-move.inc.sh:61-63` (`CM_LIB_DIR`, the `declare -F cr_map` guarded load of
    `channel-rules.inc.sh`); `:139-150` the comment, `cm_chain` `:140-149` (body `:141-148`), blank;
    `:232` `root="$(cm_proc_root)"; chain="$(cm_chain "$root" "$(cm_start_pid)")"` — match 1.4.
  - `spl-channel-move.func.sh:33-42` (the `BASH_FUNC_` refusal), `:45-56` (`env -i` + `CM_SAFE_PATH`),
    `:58-67` (`cm_action_load`); `spl-channel-manifest-add.func.sh:46`; `channel-move-plan.tst.sh:268`
    (`LIB="$PROJ_ROOT/.../lib/channel-move.inc.sh"`); `test-agent-id-retire-worktree.sh:128` (the
    symlink loop) — match.
  - `sender_audit.go:95` names `send_caller_chain` in a comment — match.
  - Section 7 sites: `gh-set-ci-vars.func.sh:36` `_gscv_get() {`, `spl-gh-wire.func.sh:92`
    `_sgw_get() {`; `i18n-lang-review-exempt.json:2` the `_doc` line; `check-pre-push-lang-review.func.sh:65-66,151`
    the `gct` regexes — match.
- Byte-identity (n=1 each, on `a7b5ae564`):
  `diff <(sed -n '9,12p' spool-caller.inc.sh) <(sed -n '78,81p' lane-map.sh | sed 's/lane_is_role_seat/send_role_seat/')`
  -> **empty**; `diff <(sed -n '14,24p' spool-caller.inc.sh) <(sed -n '139,149p' channel-move.inc.sh | sed 's/cm_chain/send_caller_chain/')`
  -> **empty**.
- `git grep -nE 'lane_is_role_seat|send_role_seat' a7b5ae564 -- ':!*.md'` -> the 2 definitions
  (`spool-caller.inc.sh:9`, `lane-map.sh:78`) and the 5 calls (`lane-map.sh:82`, `spool-send.sh:172,176,236`,
  `spl-sender-audit.func.sh:125`) — as 1.3 says.
- `git grep -nE '\bcm_chain\b|send_caller_chain' a7b5ae564 -- ':!*.md'` -> the 2 definitions
  (`channel-move.inc.sh:140`, `spool-caller.inc.sh:15`), the 2 calls (`channel-move.inc.sh:232`,
  `spool-caller.inc.sh:62`) and the `sender_audit.go:95` comment — as 1.4 says.
- `git show a7b5ae564:sa:scripts/lane-map.sh | grep -cE '_spool_caller_dir|send_(role_seat|caller_|chain_caller)'`
  -> **0** (rc 1, no match) — as 1.3 says.
- Line counts at base: `wc -l` -> lane-map.sh **129**, channel-move.inc.sh **445**,
  lane-map.tst.sh **1014**, channel-move-plan.tst.sh **373** — the plan's heads' claims
  (129->127, 445->436, 1014->1019, 373->382) are consistent.

## 3. Each red control: read, run on the plan's base in a scratch copy (n=1), last line + exit code

Heads are not committed anywhere, so I built them per the plan's 1.3/1.4 shape in scratch
worktrees of `a7b5ae564` (`git worktree add /tmp/r93/{base,head1,head2,head1-noguard,head2-noguard} a7b5ae564`),
ran as the push user with `env -u SPOOL_BOX_TAG -u SPOOL_AGENT_ID SPOOL_TEST=1 timeout 900 bash <tst>`.
My constructed files' sha256 (12 chars): head1 script `c0e3efcb18cd`, test `63530e5e1de0`;
head2 lib `043642544f33`, test `1656c8aae39e` (the plan's head sha256s differ — see N1; every
control still fails with the plan's exact quoted line and counts).

- **Row 01 red** (head1's `lane-map.tst.sh`, sha256 `63530e5e1de0...`, run on base):
  rc **1**, 148 pass / 1 fail, last line `lane-map: 1 FAILED`, the fail line
  `FAIL: 9b. lane-map.sh keeps its own role-seat check, or no call of send_role_seat: 76:# The ids: 001-003 in any vendor letter (spl_is_role_seat), and whatever 78:lane_is_role_seat() {  # ID ...`
  — the plan's 1.5 quote verbatim. On head1: rc **0**, 149 pass / 0 fail (`PASS: 9b. ...`),
  last line `lane-map: all passed`.
- **Row 01 guard** (head1 with the `. "$_here/../lib/spool-caller.inc.sh"` line deleted):
  rc **1**, 145 pass / 4 fail, last line `lane-map: 4 FAILED`, fail lines
  `FAIL: role seat c-001 (rc=0): .../lane-map.sh: line 79: send_role_seat: command not found / RUN -a do_spl_lane_put state=done agent=c-001`
  (also c-002, c-003, c-412) — the plan's quote; without the load a role seat's `done` reaches
  the action.
- **Row 02 red** (head2's `channel-move-plan.tst.sh`, sha256 `1656c8aae39e...`, run on base):
  rc **1**, 67 pass, fail lines
  `FAIL: one copy: channel-move.inc.sh keeps its own pid-chain walk, or no call of send_caller_chain: 140:cm_chain() {  # ROOT PID`
  and `FAIL: one copy load: `, summary `FAILED 2`, last line `FAILED 2` — the plan's quote. On
  head2: rc **0**, 69 pass / 0 fail (both new `one copy` checks PASS), last line
  `ALL PASS channel-move-plan`.
- **Row 02 guard** (head2 with the `declare -F send_caller_chain ...` line deleted): rc **1**,
  56 pass / 28 FAIL lines, last line `FAILED 28`, incl.
  `FAIL: C1 plan rc 3: .../lib/channel-move.inc.sh: line 222: send_caller_chain: command not found`
  (also C14, C23, W4, W5, N3, the load check) — the plan's quote.
- **Base column** (all on `/tmp/r93/base`, n=1 each): `lane-map.tst.sh` 0/148/0,
  `lane-map-dead-role-seat.tst.sh` 0/17/0, `lane-map-run-tees.tst.sh` 0/6/0,
  `test-agent-id-reap-lane-close.sh` 0/125/0, `test-agent-id-retire-worktree.sh` 0/31/0,
  `test-spawn-lane-review-row.sh` 0/23/0, `test-spawn-seed-size.sh` 0/168/0,
  `desk-user-hops.tst.sh` 0/217/0, `test-spool-send-from-guard.sh` 0/28/0, `sender-audit.tst.sh`
  0/35/0, `channel-move-plan.tst.sh` 0/67/0, `spl-channel-move-rehearsal-seed.tst.sh` 0/51/0,
  `test-channel-workspace-move-box.sh` 0/24/0, `run-eager-files.tst.sh` 0/14/0,
  `no-literal-paths.tst.sh` 0/15/0, `func-name-unique.tst.sh` 0/2/0, `run-lazy-loader.tst.sh`
  0/30/0, `bash-cleancode.tst.sh` 0/15/0 — every count equal to the plan's 1.5 column.
- Cross-row: head1's `channel-move-plan.tst.sh` 0/67/0; head2's `lane-map.tst.sh` 0/148/0; on the
  heads `run-eager-files` 0/14/0, `no-literal-paths` 0/15/0, `func-name-unique` 0/2/0,
  `test-spool-send-from-guard.sh` 0/28/0, `sender-audit.tst.sh` 0/35/0 — equal to base.
- `shellcheck -S warning -x` (0.10.0) on the 4 row files at base: rc **0**, 0 findings each (n=1).

Every control fails for the plan's reason (the own copy still present / the load line missing),
not for an environment reason, and none touches live state: all runs were in scratch worktrees
under `/tmp/r93` with `SPOOL_TEST=1` and the suites' own temp dirs.

## 4. Equivalence of each row

- The deleted bodies are byte-identical to the shared ones (check 2: both `diff`s empty at base),
  and the changed call sites pass the same arguments: row 01's `if` calls
  `send_role_seat "$_lane_agent"` where it called `lane_is_role_seat "$_lane_agent"`; row 02's
  `:232` calls `send_caller_chain "$root" "$(cm_start_pid)"` where it called
  `cm_chain "$root" "$(cm_start_pid)"`.
- The head diffs contain only the described change: `diff base head1 lane-map.sh` ->
  `76,82c76,80` only (comment, shellcheck line, source line, renamed `if`); `diff base head2
  channel-move.inc.sh` -> `63a64,66` (the guarded load), `139,150d141` (the copy), `232c223`
  (the renamed call) only.
- Behaviour: case 9's five role-seat/control checks pass on base and head1 with the same counts
  (148 -> 149, the added 9b); the INFO line and `exit 0` are unchanged. Row 02's D1 cases
  (C14, C21, C23) and W1-W5 hardening pass on base and head2 (67 -> 69, the added block). The
  `run-eager-files` gate is equal on base and both heads (14), so neither file gains eager
  top-level code beyond the one assignment the source line runs.
- The controls catch a difference: red controls fail while the own copy is present (RED on base,
  GREEN on the head); the guard controls fail when the load line is deleted. No row changes an
  exit code, a message, a path or a default: each row is ONE logical refactor.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after (reproduced in check 3),
a test list (the R2 greps match: row 01 -> `lane-map.tst.sh`, `lane-map-run-tees.tst.sh`,
`test-agent-id-reap-lane-close.sh`, `test-spawn-lane-review-row.sh`, `test-spawn-seed-size.sh`,
`desk-user-hops.tst.sh`; row 02 -> `channel-move-plan.tst.sh`; `orc-shard-weights.txt:58,228` names
both), box `either`, vendor `claude`, kind `simple_coding`, batch 1. No mistral coding or testing
row (owner 10-17, t1 b61851fb). R7 (plan section 4): re-run now —
`cd csi-spl-orc && BOX_PICK_KIND=grok ./run -a do_spl_box_pick` ->
`pick=<box> reason=<box> is the first box in order below its low mark (62% < 70%)`, grok weekly 69%
on both boxes — a grok R7 seat per row holds (the plan recorded a hold at 15:34:14Z; either way
not mistral). R1: the two rows' 4 files are distinct
(`printf '%s\n' <the 4 paths> | sort | uniq -d | wc -l` -> **0**), so no file is shared within
batch 1. 2 rows, within 5.1's aim 2 / at most 3; 5.3's numbering r93 with the plain plan name free
on trunk (check 1).

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 5 paths, comma-separated> --agent m-234`
-> **exit 4**: `WARN no live lane lists <the 5 paths>, but 3 live lane(s) record no files`;
`unknown:` lanes `c-707@<box>` (the r93 planner — its branch adds only the plan md, verified via
`git show --stat`), `c-712@<box>` (SPL-5985 rust run path step; its ask is `done`, its brief names
`run.sh`), `g-696@<box>` (rotate). Per-path `--check` -> exit 4 on each of the 5. No lane is
reported as owning any row path.

The brief's named live/queued lanes: `lane-map.sh list --all --json` -> c-626@<box> (live, SPL-6301
costs vendor share, `files=[]`), c-624@<box> (done, costs month range, `files=[]`), c-102@<box>
(done, blog SPL-6313, `files=[]`), c-136@<box> (done, bug round 41 planner, `files=[]`) — none
records any of the 5 row files. Remote branches committed since 2026-11-22:
`git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 5 paths>` over all of them
-> **0 hits**; `git log origin/master --since=2026-11-22T15:45Z -- <the 5 paths>` -> **0**.

## 7. Inputs accounted for

- The candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md` is **not on this
  box** (`ls` -> No such file; `find / -name 'c002-next-round-candidates.md'` -> none): that read
  is NOT RUN locally; the plan quotes it (115 lines, read 15:3xZ on the other box). The plan's specific
  re-measure claims I could verify on `a7b5ae564`: agy words
  `git grep -cE 'needs_agy_review|waits for an agy review|agy has the final word' a7b5ae564 -- ':!*.md' | wc -l`
  -> **0** (served by `5077a62cd`); `reverse-tunnel-cron.sh:27` reads
  `"${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}"`; `10_ci-quality.yml:440-446`
  says "about 96 MB"; `spl-uplink-probe.func.sh:14-15` names the config-fault FATAL rc 1;
  `git log origin/master --since=2026-11-23T08:56:59+02:00 -- csi-spl-doc/specs/011-spool-project-refactor`
  -> **0**; the scan's 3 new candidates are in no plan on trunk
  (`git grep -lE 'cm_chain|send_caller_chain|lane_is_role_seat|send_role_seat|_gscv_get|_sgw_get' origin/master -- 'csi-spl-doc/doc/md/refactor-round-*-plan.md' | wc -l` -> **0**).
- r92 plan section 7 read on `origin/master`: its items are carried into r93's section 7;
  `git diff --name-only 7024772b1 a7b5ae564 -- <run dirs>` -> only landed row/feature files
  (`box-go-switch`, `spl-search-speed-probe`, `check-deploy-lag`, `check-fleet-rules-drift`,
  `spl-box-update`, `spl-cost-split-apply`, `spl-cost-vendor-share`, `spl-lane-mix.func.sh`), none
  of them a section-7 leftover. The third scan candidate `_gscv_get` / `_sgw_get` is accounted
  (section 7: next round's first candidate); the `i18n-lang-review-exempt.json:2` `_doc` line and
  the 1-line groups are accounted with reasons.
- **No refactor-shaped input is neither served nor accounted for** (as far as I can demonstrate
  from this box). Bug-row scan: no row changes an exit code, a message, a path or a default
  (check 4) — both rows are refactor rows, not bug rows.

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-234`, rc **0**
(run before this file was written; re-run after adding it, still rc 0).

## Defects

None (no W1...).

## Notes

- **N1** the heads are not committed anywhere, so I constructed them per the plan's 1.3/1.4
  shape; my files' sha256 (12 chars) differ from the plan's (head1 script `c0e3efcb18cd` vs
  `5c2c13430d28`, test `63530e5e1de0` vs `dc48225937c8`; head2 lib `043642544f33` vs
  `706f1d0807e7`, test `1656c8aae39e` vs `23f523a502af`) and my test line counts differ slightly
  (lane-map.tst.sh 1017 vs the plan's 1019; channel-move-plan.tst.sh 381 vs 382; the func/lib
  files match exactly: 127 / 436). Every red/guard control fails with the plan's exact quoted
  line and the counts match (148/1 -> 149/0; 145/4; 67 + 2 FAIL -> 69/0; 56/28) — same reason,
  not an environment reason.
- **N2** `origin/master` was `a7b5ae564` (the plan's base) at every read and still is;
  `git diff --name-only a7b5ae564 origin/master -- <the 5 row paths>` is empty, so every site
  stands.
- **N3** the lane map now exits 4 with 3 unknown-scope lanes (the plan saw 11 at 15:32Z; the
  queue drained): c-707@<box> (the planner, plan md only), c-712@<box> (SPL-5985, done), g-696@<box>
  (rotate). 0 hits on the row paths either way; the row lanes re-run R3 at spawn.
- **N4** the grok box pick now returns a box (`pick=<box> ... 62% < 70%`, grok weekly 69% on both
  boxes), where the plan's 15:34:14Z read was a hold (89% < 90%) — either way a grok R7 seat per
  row, or the claude waiver seat if the pick holds at placement; never mistral.
- **N5** `/var/spool-hub/dispatch/c002-next-round-candidates.md` is not present on this box, so the
  candidates-file read of check 7 is NOT RUN locally; the plan's quotes of it were verified
  claim by claim where the tree allows (section 7 above).
