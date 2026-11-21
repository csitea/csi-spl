# Bug round 33 — panel seat mistral (m-729@sat)

Issue: SPL-6160 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-33-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-33-plan.md` on branch
`review/c002-bug-round-33-planner`, at the v0.1 sha the dispatch holder named on
task `dispatch-bug-r33` (c-003@sat, msg 5872b98f, 07:18:34Z: "review target is
plan v0.1 5cb0ae4e5eba40227ec51573b72e496e31c59ab9"). Rules:
`csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the panel
signs the plan sha; 5.1: 1 to 3 rows; 5.3 numbering and window; 5.4 bugs
priority 2). Form: `csi-spl-doc/doc/md/bug-round-32-plan.md` on origin/master.

**Verdict: FAIL on `5cb0ae4e5eba40227ec51573b72e496e31c59ab9` (v0.1). One W (W1,
row 01's site line numbers), seven N.**

Reviewed sha: `5cb0ae4e5eba40227ec51573b72e496e31c59ab9`, the head of
`review/c002-bug-round-33-planner` at my fetch (`git ls-remote origin
review/c002-bug-round-33-planner` -> the same sha, 07:17Z) and the sha the
holder named (msg 5872b98f). `git show 5cb0ae4e5:csi-spl-doc/doc/md/bug-round-33-plan.md | sha256sum`
-> `b55ec363904bd93e4735b153ba36c99e51e901dd80c8f51bb6b66ccd130a5ef6` — the file I
read whole. Plan base sha: `5083f4cf9` (the plan's "One sha"). All checks below
ran on sat between 07:17Z and 07:28Z on 2026-11-21, n as stated.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 32. `<PUSH_USER>`
is the OS user that owns the checkouts and pushes, and `<AGENT_USER>` is the OS
user the agents run as. The public repo names neither.

## Check 1 — slug b33 unused since the plan's `Window: W=`

- `git log origin/master -1 --format=%cI -E --grep='^docs\(b32-plan'` ->
  `2026-11-21T07:57:34+02:00` (commit `8955c8b29`, b32 plan v1.0) — matches the
  plan's `Window: W=2026-11-21T07:57:34+02:00`. `W=2026-11-21T07:57:34+02:00`.
- `git log origin/master --since="$W" --oneline -E --grep='\(b33-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b33-[0-9]{2}|bug-round-33'` ->
  `5cb0ae4e5eba40227ec51573b72e496e31c59ab9  refs/heads/review/c002-bug-round-33-planner`
  only (the planner's; my own review branch did not exist yet at this check).
  Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b33-[0-9]{2}|bug-round-33'` ->
  `c002-bug-round-33-mistral-panel-seat.md`, `c002-bug-round-33-planner.md`
  (this seat's and the planner's; expected).
- `git worktree list | grep -E 'b33|bug-round-33'` -> 3: `c-725` (planner,
  `c-725-c002-bug-round-33-planner`), `m-729` (this seat), and `c-307` whose HEAD
  `656ab3389` merely holds the hex `b338` (not a round, as the plan names).

## Check 2 — every site file:line on the base sha and on origin/master

Row files: `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh`,
`csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`,
`csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh`,
`csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh`; read-only cited:
`lane-issue.inc.sh`, `spl-lane-issue.func.sh`, `spl-issue-status.func.sh`,
`topic_loop_fire.go`, `topic_loop_postgres.go`, `topic_loop_memory.go`.

- `git diff --name-only 5083f4cf9 origin/master -- <all ten files>` -> empty at
  07:26Z (origin/master then `7dc7c4155` + `b7b10a2fd`): no drift.
- Every cited line printed with `git show <sha>:<file> | sed -n <N>p` at both
  `5083f4cf9` and `origin/master` (70 line checks): all exist and are identical
  on both refs, except the W1 pins below. Verified content: `spl-spawn-queue.tst.sh`
  `wc -l` -> 2294, `grep -c do_spl_spawn_enqueue` -> 102 (the plan's counts exact);
  `lane-issue.inc.sh:393-407` `li_hub_read` with the `LI_HUB_STATUS_CMD` seam at
  `:398-400`; `:543-554` `li_review_lane` with the `Issue-Role: shared` grep at
  `:547`; `spl-lane-issue.func.sh:353` appends `Issue:` to `lifetime/brief.md`
  only, `:501-523` `spl_lane_issue_discussion` (card `- Taken by:`), `:966` the
  card's `- scope: %s` line; `spl-issue-status.func.sh:30` the `issue-status`
  printf; `spl-box-quota.func.sh:258` and `:331` the `ak="a$(... sha256sum ...)"`
  derivations, `:290-311` `spl_box_quota_claude_key` (`:304` the hop with
  `$(printf '%q ' "$host" "$ak" "$acct")` on `spool_agent_exec`'s argv, `:308`
  the `mv -f "$c.$$" "$c"` write), `:363-404` `spl_box_quota_usage` (`:377`,
  `:399` writes, `:389` the hop argv); `spl-box-pick.tst.sh:755-830` the cred
  cases 16o/16p; `topic_loop_fire.go:416` the `CountTopicLoopFire` call,
  `topic_loop_postgres.go:180-194` the single conditional `UPDATE ... fires_in_hour < $4 ... RETURNING`,
  `topic_loop_memory.go:172-173` `s.mu.Lock()` held across it.
  `git show 99a2f0255 -- .../topic_loop_postgres.go | grep -c 'UPDATE topic_loops'`
  -> 6: the plan's "since `99a2f0255`" holds.

## Check 3 — red controls read, sha256, run on the base in a scratch copy

- `ls -la /var/spool-hub/dispatch/b33-red-controls/` -> `rc01.sh` 5395 B,
  `rc02.sh` 3117 B. `sha256sum` -> `0d16044948a42cf22cbd40567b9b0f5d85487520c34d93fffbcc53ae5b439b13`
  (rc01), `3576b3fc05ce5b9b725bfb471f38acd6377e14bccbe1170c16f7b187c7b7ee86` (rc02):
  first 12 hex `0d16044948a4` / `3576b3fc05ce` and sizes match the plan's section
  3.2 exactly, so the files on disk are the ones the plan printed (both printed
  in full in the plan; I read them).
- `bash /var/spool-hub/dispatch/b33-red-controls/rc01.sh 5083f4cf9`, n=3 from
  this checkout (07:19Z..07:20Z): RED in 3 of 3, identical output each time;
  last line `rc01 sha=5083f4cf9 wrong=3`, exit 1. Full output:
  `rc01 c655: role=none gate=3 want=shared gate=0` /
  `rc01 disc: role=none gate=3 want=shared gate=0` /
  `rc01 nomark: role=none gate=3 want=shared gate=0` /
  `rc01 hubfail: role=none gate=3 want=none gate=3` /
  `rc01 coding: role=none gate=3 want=none gate=3` — exactly the plan's quote.
  `RC01_PLANT=1 bash rc01.sh 5083f4cf9` -> `wrong=0`, exit 0 (the gate half goes
  green with the line, as the plan says).
- `bash /var/spool-hub/dispatch/b33-red-controls/rc02.sh 5083f4cf9`, n=3:
  RED in 3 of 3, identical; last line `rc02 sha=5083f4cf9 wrong=4`, exit 1.
  Full output: `rc02 acctid: got=kcb23951a2432 want=kcb23951a2432` /
  `rc02 acctmode: got=644 want=600` / `rc02 usagemode: got=644 want=600` /
  `rc02 acctargv: got=1 want=0` / `rc02 usageargv: got=1 want=0` — exactly the
  plan's quote.
- On current `origin/master` (`7dc7c4155`, 07:26Z): `rc01.sh origin/master` ->
  last line `rc01 sha=7dc7c4155 wrong=3`, exit 1; `rc02.sh origin/master` ->
  `rc02 sha=7dc7c4155 wrong=4`, exit 1. Both RED today, for the reason the plan
  gives (not an environment reason): rc01 shows the enqueue leaves the brief
  unshared so `li_gate` refuses (gate=3); rc02 shows 644 kept files under umask
  022 and the token key on the hop's argv.
- Live state: both scripts `mktemp -d` + `git archive <sha> csi-spl-orc`, use a
  temp `SPOOL_ROOT=$T/spool`, stub the hub calls (`LI_HUB_STATUS_CMD`,
  `LI_HUB_CARD_CMD`) and the credential (token `tok-rc02-fixture`), and make no
  network call (`grep -nE '/var/spool-hub|curl|wget|nc |ssh ' rc01.sh rc02.sh`
  -> only comments). Neither touches the live spool, queue, worktree or
  credential. Sat's live quota files: `stat -c '%a'` -> `664` for
  `weekly-quota-reading.tsv{,.account,.usage,...}` (mode only, contents not read),
  matching the plan's 07:06Z read.

## Check 4 — root cause of each row, read at the cited lines

- Row 01 holds. `li_gate` (`lane-issue.inc.sh:578-612`) returns 3 at `:602` when
  the key is wip with no landed citing commit and no end reason, unless
  `li_review_lane` (`:543-554`) passes via the brief's `Issue-Role: shared`
  (`:547`) or a review heading + Author (`:551`). The enqueue's
  `[[ -n "$place" ]]` block (`:135-145`) reads the brief
  (`spl_spawn_place_brief` at `:138`) and writes nothing into it. rc01 proves
  the gate refuses c-655's brief shape (gate=3 on `c655`/`disc`/`nomark`).
  The plan's re-measure (SPL-6086 is an earlier lane's issue, not a discussion
  issue) is consistent with `spl-lane-issue.func.sh:353` (the filed key goes to
  `lifetime/brief.md` only) and `:501-523`/`:966` (a discussion card reads
  `- scope: the topic` + `- Taken by:`); see N5 for the card read itself.
- Row 02 holds. `spl_box_quota_claude_key` (`:290-311`) derives
  `ak="a"+sha256(token)[:12]` (`:258` in the fetcher) and puts it on the hop's
  argv (`:304`) and in `<kept>.account` via a umask-dependent temp+mv (`:308`);
  `spl_box_quota_usage` (`:363-404`) does the same for `<kept>.usage` (`:377`,
  `:399`, argv `:389`). rc02 proves 644 modes and argv exposure on the base.

## Check 5 — per row: control, tests, vendor, kind, batch, R7, R1

- Both rows carry a red control that fails on `5083f4cf9` and on origin/master
  (check 3) and a green half: rc01's `RC01_PLANT=1` -> exit 0; rc02's green half
  is the lane's, as the plan states (no prototype fix on this sha).
- R2 test columns reproduce exactly:
  `git grep -l -E 'spl-spawn-enqueue|do_spl_spawn_enqueue|spl_spawn_q_enqueue' 5083f4cf9 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features csi-spl-iac/src/bash/tests`
  -> 12 files: the 8 tests the plan lists (`spl-spawn-queue`, `spl-spawn-after`,
  `spl-spawn-fill`, `spl-spawn-group`, `spl-security-round-queue`,
  `spl-epic-stall-check`, `spl-reflection-gather`, `alert-issue-tick`) plus the
  4 non-tests (`action-header-tags-baseline.txt`, `brief-reflection.tpl.md`,
  `spawn-an-agent.md`, `lane-issue.inc.sh`); the gate side
  `git grep -l -E 'li_review_lane|li_gate\b' ...` -> `test-lane-issue.sh`,
  `test-lane-issue-remote-desk.sh`, `spl-lane-issue.tst.sh` (plus the lib itself).
  Row 02: `git grep -l -E 'spl-box-quota|spl_box_quota' 5083f4cf9 -- <same dirs>`
  -> `spl-box-pick.tst.sh`, `rotate-weekly-first.tst.sh`,
  `weekly-limit-alert.tst.sh`, `spawn-window.sh` (not a test) — the plan's list.
- Vendor `claude` on both rows; kinds `simple_coding` (01) and `secret` (02);
  batch 1 on both. No mistral coding or testing row (mistral is only this
  panel). R7 reviewer: the claude waiver seat (1a7c70da), fresh session, tree
  only — the allowed waiver, never mistral. The plan's `do_spl_box_pick`
  (07:10:39Z, hold on grok) is quoted from the plan, not re-run by me.
- R1: batch-1 rows share no file — the four files are disjoint and
  `git show 5083f4cf9:csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh | grep -c spl-box-quota`
  -> `0`.

## Check 6 — R3 lane map on the row paths

- `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh,csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh,csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh --agent m-729`
  (07:21Z) -> exit 4: no live lane lists a row file; 16 `unknown:` lanes on `<box2>`
  record no files (c-146, c-461, c-463, c-490, c-506, c-562, c-579, c-598, c-601,
  c-602, c-610, c-634, c-649, c-812, c-924, c-927). With the plan file added ->
  exit 3 naming only `csi-spl-doc/doc/md/bug-round-33-plan.md owned by c-725@sat`
  (the planner; expected). My seat file path
  (`--check csi-spl-doc/doc/md/bug-round-33/seat-mistral.md --agent m-729`) ->
  exit 4, no owner: free.
- Queue (07:22Z): `ENV=prd ./run -a do_spl_spawn_queue` -> `13 queued, 0 placing`
  (matches the plan's 07:08:17Z read). All 13 queued briefs grepped for the four
  row files -> 0 hits (they are s184/s123/s033 lanes).
- The `<box2>` half (26 live worktrees, 0 hits) is NOT RUN from sat; the plan folds
  c-001@`<box2>` msgs e9372b0a / 1bf7b495 (see N4).

## Check 7 — inputs accounted for

- Re-read `/var/spool-hub/dispatch/c002-next-round-candidates.md` (101 lines)
  whole; `bug-round-32-plan.md` line 215 (the 3rd candidate = first row of round
  33: c-655's exit gate) -> row 01 with the holder's pick A; line 239 ("first
  inputs for round 33", 11 items) -> each appears in the plan's section 4.
- The candidates file's "next BUG round" / "Bug-shaped" entries, each mapped:
  served (landing verified with `git log origin/master --oneline -E --grep='\(<row>-'`):
  review-go retired author `2f634fbd4` (b20-01) + `656ab3389` (b27-01);
  Author-in-never-clause `3e46a758c` (b22-02); panel-seat swap `21abdb87e`
  (b27-02), `2547249ec` (b28-01), `ae4898ae1` (b29-02); kept reading across a
  credential copy `ac367b7a5` (b29-01); CI-first `9b680e7b5` (b30-01); done-claim
  sha256 prefix `0e9efb6c2` (b31-02); After: hold `6f2a343bb` (b30-03); bare
  Author: `8b7828a6b` (b31-01); topic-loop R1 hold `4c5633d84` (SPL-6105); spec
  181 ban-list `3f33e9dab` (SPL-6122). Row 02 = b29-01 N2 (candidates line 67).
  Carried with a reason: done-claim `job` label, AltGr/blog-Enter, agent-name-shape,
  `download iframe`/`workspace-doc-preamble` sightings, hex forms, b29-01 N1,
  overlay mount, dashless `/tmp` trees, lease vendor order writer.
- Re-measured by me (not only the plan): `bash csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh`
  -> `all passed` as `<AGENT_USER>` and as `<PUSH_USER>`; `watcher-read-only.tst.sh` -> `81 passed,
  0 failed` as both; `bash csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh`
  -> `ALL PASS` as both; prod messages since 2026-11-21T05:36:00Z with
  `body ~* '\m(tasks|forward|multicast) [0-9a-f]{7,40}\M'` -> count 0
  (`ENV=prd do_spl_db_query`); `grep -n LEASE_VENDOR_ORDER /var/spool-hub/dispatch/lease.conf`
  -> `12:LEASE_VENDOR_ORDER=claude,agy,claude2` (no grok), file last write
  2026-11-21 04:35:13+02:00 — the plan's 07:06Z read holds.
- b31-02 / b32 rows' R7 notes: b31-02's body (`git log -1 --format=%B 0e9efb6c2`)
  -> `review: c-665 claude PASS a7e4e59d4...` (W1/N1/N2 fixed in a7e4e59d4, landed);
  b32-02's body -> `review: c-667 claude PASS 29638f079...`, no W/N. Nothing open
  for this round to serve.
- **No bug-shaped input is neither served nor accounted for** (see N2, N3 for
  two entries the plan's sections 4-5 do not name by their own words).

## Check 8 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (07:18Z) ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-729`, rc 0.

## W defects

- **W1 (row 01, sites/defect cells): the cited line numbers do not match the
  code on `5083f4cf9` (identical on origin/master).**
  - The plan cites `spl-spawn-enqueue.func.sh:127-140` as "the
    `[[ -n "$place" ]]` brief block" and `:131` as the `spl_spawn_place_brief`
    line. Actual: `git show 5083f4cf9:csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh | sed -n '135p'`
    -> `  if [[ -n "$place" ]]; then  # the placer files the lane's issue from this brief: refuse it here, not at placement`;
    the block is `:135-145`, and `sed -n '138p'` ->
    `    local brief; brief="$(SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" spl_spawn_place_brief "${place#*:}")"`.
    `:131` is `if [[ -n "$seat" ]]; then ...` (the seat block), not the brief
    read. The cited range `:127-140` also truncates the block (`:141-145`
    missing).
  - The plan cites `lane-issue.inc.sh:578-616` for `li_gate`. Actual:
    `git show 5083f4cf9:csi-spl-orc/src/bash/features/spawn-agents/lib/lane-issue.inc.sh | wc -l`
    -> `612`; `sed -n '578p'` -> `li_gate() {`, `sed -n '612p'` -> `}`;
    `sed -n '616p'` -> empty (past EOF). `li_gate` is `:578-612`.
  - Fix for v0.2: row 01's sites cell reads `spl-spawn-enqueue.func.sh:135-145`
    (the `[[ -n "$place" ]]` brief block, `spl_spawn_place_brief` at `:138`),
    and `lane-issue.inc.sh:578-612` for `li_gate`. The row's files, red control
    and fix scope are unaffected (rc01 does not depend on these pins).

## N notes

- N1: b32-01 landed `b7b10a2fd` at 2026-11-21T07:23:18Z, after the plan's
  07:00Z..07:11Z measurement, so the plan's "b32-01 none / live (c-649@`<box2>`)" was
  true at read time. Its files (`spl-push-master.func.sh`,
  `spl-push-master.tst.sh`) are not b33 row files; the drift check at 07:26Z is
  still empty.
- N2: the candidates file's entries at lines 78 (After: hold reads the wrong
  box's key, c-001 d77d912f) and 81 (bare `Author:` resolves to this box, c-001
  7e965718) are not named in the plan's sections 4-5; both are landed (b30-03
  `6f2a343bb`, b31-01 `8b7828a6b`), so no row is needed, but the accounting skips
  them by name.
- N3: the tmp-stale-sweep entry (candidates line 64, c-001 82c02da9) is carried
  only under the overlay-mount row's words ("its red control needs a mount,
  which needs root"), not named as the sweep row it is.
- N4: the 16 exit-4 `<box2>` lanes' worktree diffs are NOT RUN from sat (their
  worktrees are on `<box2>`); the plan folds c-001@`<box2>` msgs e9372b0a / 1bf7b495 (0
  hits in all 26 live worktrees). My own lane-map run shows no row file owned
  and all 13 queued briefs name no row file.
- N5: SPL-6086's hub card was NOT re-readable from this box (not in the first
  500 issues of the t1 or csitea lists, `do_spl_issue_list --json` read-only);
  the plan's re-measure (`- scope: the brief of lane c-259`) is unverified here.
  The code-side proof stands regardless: rc01 shows gate=3 on the c-655 brief
  shape, and the plan itself notes the card read can only answer "shared" on
  this tree (`spl-lane-issue.func.sh:353`).
- N6: the plan says the `tasks`/`forward`/`multicast <hex>` forms were "not
  re-queried here"; I re-queried (check 7): count 0 since 2026-11-21T05:36:00Z.
- N7: the plan re-ran only `unanswered-sweep.tst.sh` as both OS users; I also
  ran `watcher-read-only.tst.sh` (81 passed, 0 failed) and the iac
  `check-commit-msg-hygiene.tst.sh` (`ALL PASS`) as both `<AGENT_USER>` and `<PUSH_USER>` — none
  red, so the a9ee75ee "RE-MEASURE FIRST" entry stays not-a-row.

---

## Panel verdict on v0.1 — FAIL (2026-11-21T07:28Z)

- Reviewed sha: `5cb0ae4e5eba40227ec51573b72e496e31c59ab9` (branch head at my
  fetch, named by the holder, msg 5872b98f). Plan file sha256
  `b55ec363904bd93e4735b153ba36c99e51e901dd80c8f51bb6b66ccd130a5ef6`.
- Checks 1-8 above: 1, 3, 4, 5, 6, 7, 8 pass; check 2 fails on the W1 pins only
  (all other cited lines exist and match on both refs).
- W1 must be folded into the next plan version before signing; no row, red
  control, vendor, kind, batch or R7 assignment changes with it.

---

## v0.2 review — PASS on `14de348c08bc46d64106e739a10a6b2b48ba1bfa` (2026-11-21 07:41Z..07:50Z)

Asked by the dispatch holder (c-002@sat, msg 3f91600a, 07:40:56Z): re-check every pin of
v0.2, sign it in this file, report in the same review-line form.

- Branch: `git ls-remote origin review/c002-bug-round-33-planner` ->
  `14de348c08bc46d64106e739a10a6b2b48ba1bfa`; `git merge-base --is-ancestor
  5cb0ae4e5eba40227ec51573b72e496e31c59ab9 FETCH_HEAD` -> yes (fast-forward);
  `git diff --stat 5cb0ae4e5 14de348c0` -> 1 file, +25 -14, only
  `csi-spl-doc/doc/md/bug-round-33-plan.md`. Plan file at v0.2: sha256
  `22854be2c03e71d7f0d6b5398dbde083e80cbd107b06ce4579c1452134f34263`, 303 lines, read whole.
- **W1 fixed, re-verified on `5083f4cf9` and on origin/master (`3174e591a`), identical on
  both refs.** `git show <sha>:csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh | sed -n
  '135p;138p;145p'` -> `if [[ -n "$place" ]]; then ...` / the `spl_spawn_place_brief` read /
  `fi`: the block is `:135-145`, `spl_spawn_place_brief` at `:138`; `:131` is the seat block.
  `lane-issue.inc.sh:578` -> `li_gate() {`, `:612` -> `}`, the file is 612 lines (`:616` is
  past EOF). Row 01's sites cell now reads `:135-145` (`:138`) and `lane-issue.inc.sh:578-612`.
- **The two further pins fixed.** `li_review_lane` is `:543-554` (`:543` `li_review_lane() {`,
  `:547` the `Issue-Role: shared` grep, `:551` the review-heading grep, `:554` `}`; `:555` is
  empty, so v0.1's `:555` was wrong). `spl-box-quota.func.sh:329` ->
  `ak="a$(printf '%s' "$t" | sha256sum | cut -c1-12)"` (v0.1's `:331` was wrong); `:258` is the
  same derivation in the cred fetcher; `spl_box_quota_claude_key` spans `:280-312` (`:280` its
  doc comment, `:304` the argv hop, `:308` the temp+mv).
- Every other cited pin re-printed with `git show <sha>:<file> | sed -n <N>p` on both refs:
  `lane-issue.inc.sh:393-407` (`li_hub_read`, `:393`..`:407`), `spl-lane-issue.func.sh:353`
  (the filed key goes to `lifetime/brief.md` only) and `:501-523`
  (`spl_lane_issue_discussion`), `spl-issue-status.func.sh:30`, `topic_loop_fire.go:416`
  (`CountTopicLoopFire`), `topic_loop_postgres.go:180-194`, `topic_loop_memory.go:172-173`,
  `test-agent-name-shape.sh:89`, `blog.test.mjs:329`, `spl-spawn-queue.tst.sh` = 2294 lines /
  102 `do_spl_spawn_enqueue` lines, and c-655's brief
  `/var/spool-hub/dispatch/briefs/c002-s143-cwv-v02-owner-answers.md:1-9` with `Issue:
  SPL-6086` at `:5` (lines 5-7 = Issue/Class/Kind). All match.
- Check 1 re-run: `W=2026-11-21T07:57:34+02:00` (`8955c8b29`);
  `git log origin/master --since="$W" --oneline -E --grep='\(b33-' | wc -l` -> `0`;
  `git ls-remote origin | grep -E 'b33-[0-9]{2}|bug-round-33'` -> only the planner's and this
  seat's review branches; the briefs dir holds only the two c002 b33 briefs; `git worktree
  list | grep -E 'b33|bug-round-33'` -> c-725 (planner, `14de348c0`), m-729 (this seat), c-307
  (HEAD `656ab3389` merely holds the hex `b338`).
- Check 2 re-run: `git diff --name-only 5083f4cf9 origin/master -- <the ten files>` -> empty at
  07:47Z (origin/master then `3174e591a`): no drift.
- Check 3 re-run: rc01/rc02 sha256 unchanged (`0d16044948a4…`, `3576b3fc05ce…`);
  `bash rc01.sh 5083f4cf9` -> `wrong=3`, exit 1; `RC01_PLANT=1 bash rc01.sh 5083f4cf9` ->
  `wrong=0`, exit 0; `bash rc02.sh 5083f4cf9` -> `wrong=4`, exit 1; on origin/master rc01 ->
  `wrong=3` exit 1, rc02 -> `wrong=4` exit 1. Both RED on both refs, green half green.
- R1/R2 re-run: `git show 5083f4cf9:csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh | grep -c
  spl-box-quota` -> `0`; the row-01 grep -> the same 12 files (8 tests + 4 non-tests); the gate
  grep -> `test-lane-issue.sh`, `test-lane-issue-remote-desk.sh`, `spl-lane-issue.tst.sh` (plus
  lib/run files); the row-02 grep -> `spl-box-pick.tst.sh`, `rotate-weekly-first.tst.sh`,
  `weekly-limit-alert.tst.sh` + `spawn-window.sh`.
- Check 6 re-run: lane-map on the 4 row files -> exit 4, no live lane lists a row file (18
  `unknown:` lanes now, was 16 at 07:21Z: c-668, c-697 added); queue -> `14 queued, 0 placing`;
  the 12 queued/held slugs' briefs grepped for the four row files -> 0 hits.
- Check 7 re-run: `git log origin/master --oneline -E --grep='\(b32-0[12]-|\(b31-02-'` ->
  `b7b10a2fd` (b32-01, SPL-6157), `1fadfb77b` (b32-02, SPL-6159), `0e9efb6c2` (b31-02, SPL-6150)
  all landed, matching v0.2's header and section 4.
- N1-N7 folded: the header names b32-01's landing; section 4 names the After:-hold (b30-03) and
  bare-`Author:` (b31-01) entries and the `/tmp` sweep; section 8 records this seat's FAIL on
  v0.1 (msg 4ccd49c8, seat `d948f650e`) and each N's fold. The diffstat touches only the plan
  file: no row's files, red control or fix scope changed.

**Verdict on v0.2 `14de348c08bc46d64106e739a10a6b2b48ba1bfa`: PASS (2026-11-21T07:50Z). No W.**
Signed by m-729@sat. Notes: none new — the live-lane count moved (16 -> 18 `unknown:` lanes,
13 -> 14 queued) and origin/master moved to `3174e591a` since the v0.1 review, all with no
row file owned or named and no row-file drift: expected live drift, not a defect.
