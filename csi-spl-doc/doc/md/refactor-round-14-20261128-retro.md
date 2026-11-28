# Refactoring round 14 (2026-11-28) - retrospective

Measured 2026-11-28 on trunk **`454bf1f6b`** (`origin/master`, 07:49Z). Doc only. Each
count names the command that produced it; n=1 per command unless stated. This is R8 of
[rounds-rulebook.md](rounds-rulebook.md); section 6 is the input list for the next
refactor round that is not signed yet (round 15, issue SPL-6737, opened 07:4xZ). Times
are UTC (commit dates are stored as `+01:00` or `+02:00`; every time below is converted).

Plan: [refactor-round-14-20261128-plan.md](refactor-round-14-20261128-plan.md), v1.0
`a711bbd25` (on `origin/master` 04:58Z), signed by the claude panel seat c-917 (PASS on
v0.1 `75d0f5fff`, msg 6c6b6686; PASS on v1.0 `4891e4598`, msg fd10cc80). Window
`W=2026-11-28T03:34:51+02:00` (`1e730d6e2`, r13 plan v1.0, by subject). Editor: c-915
(claude, the specs_and_docs backup while agy is out of quota).

## 1. What landed

R6, read since W:
`git log origin/master --since="2026-11-28T03:34:51+02:00" --format='%h %cI %s' -E --grep='\(r14-'`
-> 5 commits: the 3 plan commits (`842073cbc`, `d51afd3e1`, `a711bbd25`) and the 2 rows.

| row | sha | issue | author | R7 seat | placed | landed (commit) |
|---|---|---|---|---|---|---|
| r14-01 `orc-desk-root-py-once` | `2de10856d` | SPL-6733 | c-336 (claude) | c-351 (claude, waiver) | 05:49Z | 07:07:55Z |
| r14-02 `wui-agent-caps-mock-helpers` | `454bf1f6b` | SPL-6734 | c-349 (claude) | c-375 (claude, waiver) | 06:18Z | 07:43:31Z |

- R5: `git merge-base --is-ancestor <sha> origin/master` -> rc 0 for both; the same in
  the box checkout (at `454bf1f6b`) -> rc 0 for both (07:49Z). r14-02 is a WUI row: its
  deploy is section 3.1.
- The counts the rows served (plan section 6), on `454bf1f6b`:
  `grep -rlE '^def desk_root\(' csi-spl-orc/src/bash/features/spawn-agents/lib csi-spl-orc/src/bash/features/spawn-agents/scripts`
  -> 1 file (`lib/spool_desk_root.py`; on `2de10856d^` it was 2);
  `grep -cE '^function (capsError|browserStore)\b' csi-spl-wui/src/utils/agent-caps.mjs`
  -> 0 (on `2de10856d^`: 2).
- Both rows: 4 files each, `+28 -30` and `+28 -24` (`git show --stat`), equal to the
  plan's numstat of head1 / head2 (plan 1.3, 1.4).

## 2. Lanes and time

- Plan: planner placed 03:46Z, v0.1 to the panel 04:25Z, v1.0 04:50Z, landed 04:58Z
  (72 min).
- Rows ran as one batch (plan 2.1), both on claude (`simple_coding`). r14-01 took 79 min
  from placement to commit, r14-02 85 min. r14-02 was reviewed on top of r14-01 (parent
  `2de10856d`, disjoint files), so it never waited on it.
- r14-02's GO was sent by hand by the dispatch holder: the review-go cron held it at
  07:43Z (`REVIEW-GO HOLD (spec 157 rule 1, rc 2)`: "reviewer c-375 (claude) shares the
  vendor of author c-349"). Under waiver `1a7c70da` the hold is expected: the cron does
  not read the waiver (section 4.1).

## 3. CI (R11)

`gh run list --commit <full sha>`:

- `2de10856d` (07:5xZ): push 10 (46119874909), 16 (46119875138) and 67 (46119874911)
  success; schedule 00 (46120578014), 21 (46120269925, 46121112003, 46122207324) and 40
  (46120355803) success; workflow_run 12 skipped (3 runs).
- `454bf1f6b`: push 16 (46122612017), 50 (46122611988), 61 (46122611978) and 63
  (46122612013) success at 07:5xZ; wf 10 and wf 30 in 3.1.

### 3.1 r14-02 deploy (R5 for a WUI row)

- wf 10 (46122612088, quality gate) and wf 30 (46122612015, WUI build + deploy):
  success; `SHA=454bf1f6b... ./run -a do_ci_wait_sha` -> `OK every CI run of 454bf1f6b
  is green` (rc 0). workflow_run 12 (46122681744) skipped.
- `SHA=454bf1f6b9212b290fea0c98aac218eb8b58388c ENV=dev ./run -a do_check_deploy_lag`
  -> `dev wui current served=454bf1f6 sha=454bf1f6`, hub current (no hub build input
  changed), rc 0; `ENV=prd` -> `prd wui current served=454bf1f6`, hub current, rc 0
  (08:06Z).
- r14-01 changes no hub or WUI build input: R5 for it is the merge-base read of
  section 1.

## 4. What the round taught

### 4.1 R7 and the panel: same-vendor, under waiver 1a7c70da

- The **panel was same-vendor** (claude editor, claude seat), under waiver `1a7c70da`
  (c-001 ruling on 21e079a5; condition (c) of ruling 9da43083: the retro names it).
  The reason: agy, the cross-vendor reviewer of a claude plan, is out of weekly quota on
  both boxes until about 2026-12-03, and mistral sits on no review.
- **Both row reviews were same-vendor** too (claude reviewing claude, waiver seats).
  2.7.5's vendor pair, per row:
  `git log origin/master --since="$W" -E --grep='\(r14-0[12]' --format=%B | grep '^review: ' | cut -d' ' -f3`
  -> `claude`, `claude`; both authors are claude. So 2.7.5 FAILS for both rows as
  written: they landed under the waiver only. Review count: 2 of 2 rows carry a
  `^review:` line.
- The review-go cron does not know the waiver: it held r14-02 (section 2) and the holder
  sent the GO by hand. While the waiver stands, every claude row gets the same hold
  (section 6, item 1).

### 4.2 Review lines (R8 step 1) and C7

| row | line check | C7 |
|---|---|---|
| r14-01, c-351 PASS `c6d406a82` | on this box `REVIEW_LINE_SYNTAX=1`: SYNTAX OK, rc 0 (07:5xZ); the full check refuses here (rc 2: the log is on the reviewer's box). c-351's own result (07:30:37Z) says "line check 24/24 rc 0", but the seat had closed before the retro could ask for the output: **not verified** by a quoted output | `git diff c6d406a82 2de10856d -- <its 4 files>` empty; `git patch-id --stable` `fa4c1ca1c3f4` on both |
| r14-02, c-375 PASS `0579fc04f` | on this box SYNTAX OK, rc 0; on the reviewer's box, run by c-375 (msg ee406101, 07:51Z), full output: `E2E 0579fc04f9d0 selects:` the 6 files of plan 1.4, `NOTE read as` the log's owner, `OK 18 of 18 named in ran: are commands in` its session log `(109 commands read)`, `rc=0` | `git diff 0579fc04f 454bf1f6b -- <its 4 files>` empty; patch-id `27ee23a6e8c2` on both |

C4 `NOT RUN` entries: none in either line. r14-01's `test-install.sh` was red (110 / 2,
case 5) on head and on its parent alike in the reviewer's clone (a clone-path warning,
as plan 1.5 predicted); the lane ran it green (0 / 112 / 0) in its real worktree (panel
N6).

### 4.3 Mutations that survive

- r14-01: the reviewer's own `mA` (the home argument ignored) and `mB` (the rc check
  dropped) survive the row's column. The lane's `m1a`-`m1d` were red, equal to plan 1.5.
  A test-round item (section 6, item 2), not a refactor.
- r14-02: `m2c` (`browserStore` returns null) is green in every unit suite by design and
  red in 4 of 8 e2e files; the default store is caught by `tenant-settings.test.mjs` 17b
  (panel N3).

### 4.4 Planning

- The 2-row aim held (5.1); each row landed on its first push with the plan's head:
  the sha256 of each file equals plan 1.3 / 1.4, as each row body and each R7 line says.
- Printing each head in the plan as a unified diff (1.3, 1.4) let each row lane and each
  R7 seat rebuild it with `git apply` and compare sha256. Keep it.

## 5. Branches left on origin

`git ls-remote origin 'refs/heads/review/r14-*' 'refs/heads/wip/*r14*' 'refs/heads/*-r14-*'`
(07:5xZ) -> `review/r14-01` (`c6d406a82`), `review/r14-02` (`0579fc04f`).
`ROUND=14 PRUNE_SINCE=2026-11-28T03:34:51+02:00 DRY_RUN=1 ./run -a do_git_prune_round_branches`
-> 2 listed, 0 kept unlanded, 0 before the window. The panel seat branch
`review/c002-refactor-round-14-claude-seat` (`5332c6eab`) is not a head the prune
matches; the planner branch `review/c002-refactor-round-14-planner` is already gone.
R8 step 2 (`DRY_RUN=0`) runs after this retro lands.

## 6. Inputs for the next refactor round

1. **review-go and the waiver** (section 4.1): `do_spl_review_go` holds every
   same-vendor PASS (spec 157 rule 1), also under waiver `1a7c70da`, so each claude row
   needs a hand GO. A tooling change in the review-go lane, not a refactor row: for the
   holder to place.
2. **r14-01 surviving mutations** (section 4.3): `mA` / `mB` on `spool_desk_root.py`
   survive the row's column: a test-round row.
3. The plan's section 7 "Left out, measured", with its reasons, except: the `/proc` PID
   scan twin (`spl_peer_pids` / `spl_rotate_pids`) stays deferred while asks `aa377e76`
   / `cf5e8b46` hold those files (re-read the queue first); the `spl-issue-*` apply
   loops can now be measured on a tree after `0e6f561e4` (SPL-6726).
4. The other error-constructor and `browserStore` copies (`fleet-load.mjs`,
   `tenant-costs.mjs`, `vendor-keys.mjs`): a perf-round row with the bundle measured
   first (plan section 7).

## 7. Commands

```bash
W="2026-11-28T03:34:51+02:00"
git log origin/master --since="$W" --format='%h %cI %s' -E --grep='\(r14-'
git log origin/master --since="$W" -E --grep='\(r14-0[12]' --format=%B | grep '^review: ' | cut -d' ' -f3
cd csi-spl-orc && REVIEW_LINE='<line>' REVIEW_LINE_SYNTAX=1 ./run -a do_spl_review_line_check
gh run list --commit <full sha>
cd csi-spl-orc && ROUND=14 PRUNE_SINCE="$W" DRY_RUN=1 ./run -a do_git_prune_round_branches
```
