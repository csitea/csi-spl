# Bug round 34 — panel seat mistral (m-785@sat)

Issue: SPL-6179 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-34-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-34-plan.md` on branch
`review/c002-bug-round-34-planner`, at the v0.1 sha the planner named as a plan
version: the commit subject of the branch head reads "bug round 34 plan v0.1 ...
for the panel" and the plan's section 8 records "v0.1, pushed to
`review/c002-bug-round-34-planner` for the panel". Rules:
`csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the panel
signs the plan sha; 5.1: 1 to 3 rows; 5.3 numbering and window; 5.4 bugs
priority 2). Form: `csi-spl-doc/doc/md/bug-round-33-plan.md` on origin/master.

**Verdict: PASS on `05e6be867d09253512a67b845459448ae70a62de` (v0.1). No W. Three N.**

Reviewed sha: `05e6be867d09253512a67b845459448ae70a62de`, the head of
`review/c002-bug-round-34-planner` at my fetch (`git ls-remote origin
refs/heads/review/c002-bug-round-34-planner` -> that sha, nothing else). The
plan's base is `31a976ffb` ("One sha" line 18); `Window: W=2026-11-21T11:45:44+02:00`
(line 19). origin/master at my fetch: `f43fc60f1ce22f8e5f7a662bbca4f579dd31a56b`
(one commit past the base, `f43fc60f1 docs(spec-183, SPL-6172)`, a spec doc only).
All checks below run on sat 2026-11-21 ~10:2xZ..10:4xZ unless a line says otherwise.

## Check 1 — slug b34 unused since the plan's W

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b33-plan')` ->
  `W=2026-11-21T11:45:44+02:00` (commit `eb7c8cc54`), the value the plan records.
- `git log origin/master --since="$W" --oneline -E --grep='\(b34-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b34-[0-9]{2}|bug-round-34'` ->
  `05e6be867d09253512a67b845459448ae70a62de\trefs/heads/review/c002-bug-round-34-planner`
  only (the planner's branch; expected. This seat's review branch did not exist
  yet at this check). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b34-[0-9]{2}|bug-round-34'` ->
  `c002-bug-round-34-mistral-panel-seat.md`, `c002-bug-round-34-planner.md`
  (this seat's and the planner's; expected).

## Check 2 — every site file:line on the base sha and on origin/master

Row files: `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh`,
`csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`; read-only cited:
`csi-spl-orc/src/bash/features/spawn-agents/lib/lane-issue.inc.sh`,
`csi-spl-orc/src/bash/run/spl-lane-issue.func.sh`.

- `git diff --name-only 31a976ffb origin/master` -> only
  `csi-spl-doc/specs/183-agent-topic-pdf-export/spec.md` (the `f43fc60f1` commit).
  `git diff --name-only 31a976ffb origin/master -- <the four files above>` ->
  empty: no row file drifted.
- Every cited line printed with `git show <sha>:<file> | sed -n <N>p` at both
  `31a976ffb` and `origin/master`; all exist and are identical on both refs:
  - `spl-spawn-enqueue.func.sh:166` `# SPL-6167 (bug round 33 row 01, the holder's option A, msg 08e9399f): a`;
    `:177` `# nothing and logs one WARN, never a guess.`;
    `:178` `spl_spawn_q_enqueue_shared() {  # ID BRIEF`;
    `:185` `  ! grep -qiE '^[-*_ >]*Issue[- ]Role[*_ ]*:' "$brief" || return 0`;
    `:186` `  if ! spl_spawn_q_issue_card "$key" >/dev/null; then`;
    `:190` `  printf 'Issue-Role: shared\\n' >>"$brief" ||`;
    `:193` `}`.
  - `lane-issue.inc.sh:543` `li_review_lane() {`;
    `:547` `  if grep -qiE '^[-*_ >]*Issue[- ]Role[*_ ]*:[*_` + "`" + ` ]*shared([^A-Za-z]|$)' "$life/brief.md" 2>/dev/null; then`;
    `:554` `}`.
  - `spl-lane-issue.func.sh:353` `  if [[ -w "$life/brief.md" ]] && ! li_key_from_brief "$life/brief.md" >/dev/null; then printf '\nIssue: %s\n' "$key" >>`.
  - `spl-spawn-queue.tst.sh`: `git show <sha>:... | wc -l` -> `2345` on both refs
    (the plan's count exact); `:2291` `# SPL-6167 (bug round 33 row 01, rc01): a docs lane placed on an issue it`.
  - Not-rows cites also verified on both refs: `spl-box-quota.func.sh:307`,
    `test-agent-name-shape.sh:89`, `blog.test.mjs:329`.

## Check 3 — red control read, sha256, run on the base in a scratch copy

- `ls -la /var/spool-hub/dispatch/b34-red-controls/` -> `rc01.sh` 4871 B;
  `sha256sum` -> `e6781be1f863d056d689e7b42b5aa0b570e8993c70ce91d7d3c78a8a62f9af7d`
  (first 12 hex `e6781be1f863`, the plan's claim).
- Read whole: `mktemp -d` + `trap 'rm -rf -- "$T"' EXIT`, `git archive "$full"
  csi-spl-orc | tar -x -C "$T"` (no worktree of the repo), a fake
  `SPOOL_ROOT=$T/spool`, the hub reads stubbed through `LI_HUB_CARD_CMD` /
  `LI_HUB_STATUS_CMD`, no hub call, no network, no live queue, worktree, spool,
  state file or credential. It never touches live state.
- `bash /var/spool-hub/dispatch/b34-red-controls/rc01.sh 31a976ffb` from this
  checkout, n=3: RED 3 of 3, the same output each run, last line
  `rc01 sha=31a976ffb wrong=3`, exit 1:
  `rc01 nl: got=shared/0 want=shared/0` /
  `rc01 nonl: got=none/3 want=shared/0` /
  `rc01 lastln: got=0 want=1` /
  `rc01 twice: got=2 want=1` — identical to the plan's section 3.2 table.
- `RC01_PLANT=1 bash .../rc01.sh 31a976ffb`, n=1: last line
  `rc01 sha=31a976ffb wrong=0`, exit 0.
- It fails for the plan's reason, not an environment one: on a brief with no
  trailing newline the append glues (`nonl` role=none, gate exit 3), the
  brief's last line is changed (`lastln` 0), and a re-queue appends twice
  (`twice` 2); the newline-terminated control passes (`nl` shared/0).

## Check 4 — root cause of the row, read at the cited lines on `31a976ffb`

`spl-spawn-enqueue.func.sh:178-193`: the guard at `:185` is `^`-anchored and the
append at `:190` is `printf 'Issue-Role: shared\n' >>"$brief"` with no newline
first, so on a brief whose last byte is not a newline the line glues to it.
`lane-issue.inc.sh:543-554`: `li_review_lane`'s grep at `:547` is `^`-anchored,
so the glued line does not match and the gate refuses the wip key (exit 3).
`spl-lane-issue.func.sh:353`: the placer's twin append writes `\n` first. The
plan's reading holds.

## Check 5 — row fields (R2 control, tests, vendor, kind, batch, R7, R1)

- Red control fails today and passes after: check 3 (RED 3/3 exit 1 on
  `31a976ffb`; planted append exit 0).
- Test column: `git grep -l -E 'spl-spawn-enqueue|do_spl_spawn_enqueue|spl_spawn_q_enqueue'
  31a976ffb -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features
  csi-spl-iac/src/bash/tests` -> the 8 tests the plan names
  (`spl-spawn-queue.tst.sh`, `spl-spawn-after.tst.sh`, `spl-spawn-fill.tst.sh`,
  `spl-spawn-group.tst.sh`, `spl-security-round-queue.tst.sh`,
  `spl-epic-stall-check.tst.sh`, `spl-reflection-gather.tst.sh`,
  `alert-issue-tick.tst.sh`) plus the 4 non-test files (`action-header-tags-baseline.txt`,
  `brief-reflection.tpl.md`, `spawn-an-agent.md`, `lane-issue.inc.sh`). Gate side:
  `git grep -l -E 'li_review_lane|li_gate\b' 31a976ffb --
  csi-spl-orc/src/bash/features/spawn-agents/tests csi-spl-orc/src/bash/tests` ->
  `test-lane-issue.sh`, `test-lane-issue-remote-desk.sh`, `spl-lane-issue.tst.sh`.
  Both lists match the plan's section 3.1.
- Row 01: vendor `claude`, kind `simple_coding`, batch 1, box sat or the other
  box (no pin). No mistral coding or testing row (the only row is claude's).
  R7 reviewer: the claude waiver seat, never mistral; re-run
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` ->
  `pick=hold reason=waiting: grok weekly >= 95% or unknown on <box1>, <box2> [<box1> unknown (no reading); <box2> unknown (no reading)]: queue the lane, spawn nothing`
  (box names written as the plan writes them, `<box1>`/`<box2>`)
  (matches the plan's 10:04:45Z read).
- R1: one row in batch 1, so no two rows of the batch share a file.
- Live exposure re-measured on sat: `find /var/spool-hub/dispatch/briefs
  -maxdepth 1 -type f -name '*.md' | wc -l` -> 6408 (the plan read 6401 at 10:02Z);
  of them, `tail -c1` non-empty -> 26 (the plan's 26); of those 26,
  `Kind: specs_and_docs` + `Issue: SPL-` -> 0; of those 26, modified in the last
  48 h -> 0. The plan's "no lane is caught today" holds.

## Check 6 — R3 lane map on the row paths

- `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh,csi-spl-orc/src/bash/features/spawn-agents/lib/lane-issue.inc.sh,csi-spl-orc/src/bash/run/spl-lane-issue.func.sh --agent m-785`
  -> exit 4: `WARN no live lane lists <the four paths>, but 18 live lane(s)
  record no files: their scope is unknown, not free`. No exit-3 owner. The 18
  unknown lanes are all on the other box (c-146, c-461, c-463, c-490, c-506,
  c-562, c-579, c-706, c-740, c-744, c-745, c-747, c-749, c-751, c-752, c-812,
  c-924, c-927, all qualified `@<box2>`). The plan accounts for exactly this: section 6
  records the sat half and section 8 item 1 asks the holder for the other box's
  half (worktree diffs + status paths matched against the row files).
- Queue: `SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` ->
  `16 queued, 0 placing` (the plan read 15 at 10:04:45Z). The 11 queued briefs
  that name files (spec 184 M0/C1/I1/L1/A1/H1, spec 033 T026, spec 123 L4-L7):
  `grep -lE 'spl-spawn-enqueue|spl-spawn-queue\.tst|lane-issue-and-docs'` over
  their brief files -> none.

## Check 7 — inputs accounted for

- b33 plan's "first inputs for round 34" row (bug-round-33-plan.md line 271 on
  origin/master): 13 items, each present in the b34 plan's section 4 (done-claim
  `job` label; AltGr picker + blog switcher Enter; `blog.test.mjs:329`;
  `test-agent-name-shape.sh:89`; the orc/iac suites as the agent OS user;
  `gcp-billing-invoices.tst.sh` + `workspace-doc-preamble.test.mjs`;
  `tasks|forward|multicast <hex>`; b29-01 N1 on the other box; the overlay mount;
  the other box's 8 dashless `/tmp` trees; the lease vendor order writer; the
  topic loop's `!inserted` branch).
- b33 rows' R7 notes: c-763 N1-N4 and c-761 N1-N3, all seven in the b34 plan's
  section 4 (N3 of c-763 is row 01; N4 is test-shaped; c-761 N1-N3 carried).
- Candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md`:
  bug-shaped entries served — verified landed on origin/master:
  `git log origin/master --oneline -E --grep='\(b(20-01|22-02|27-01|27-02|28-01|29-01|29-02|30-01|30-02|30-03|31-01|31-02|32-02|33-01)-'`
  -> `2f634fbd4`, `3e46a758c`, `656ab3389`, `21abdb87e`, `2547249ec`,
  `ac367b7a5`, `ae4898ae1`, `9b680e7b5`, `b341f7bb8` + `82d1b51da`,
  `6f2a343bb`, `8b7828a6b`, `0e9efb6c2`, `1fadfb77b`, `d42ec95e8` (b33-02
  `22f50f64f` in section 4). Topic-loop cap race: not a race on this tree
  (round 33 section 5). Spec 181 B6 ban-list limits: owned by spec 181's lanes
  (R3). The unanswered-sweep user-dependent red: carried via the "orc/iac
  suites as the agent OS user" row; its premise re-checked:
  `git diff --name-only 5083f4cf9 31a976ffb -- unanswered-sweep.tst.sh
  watcher-read-only.tst.sh check-commit-msg-hygiene.tst.sh` -> empty.
- Section 2's CI row re-run: `CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a
  do_report_ci_gate` -> the same reds the plan names (orc hermetic 2/4 x2:
  `75da57eb` 03:45:33Z, `ad950c0e` 03:28:28Z, `hub_cloudtranslate_user` not
  covered; wui e2e 6/8 x1: `44832401773`, `workspace-doc-preamble.test.mjs`);
  last green per failed job `44891251445` on `31a976ff` 09:47:39Z.
- Done-claim log and lease.conf re-read: `wc -l
  /var/csi/csi-spl/done-claim-check/cron.log` -> 46873 (plan: 46856 at 10:0xZ),
  `grep -ciE 'job [0-9a-f]{7}'` -> 0; `grep -n LEASE_VENDOR_ORDER
  /var/spool-hub/dispatch/lease.conf` -> `12:LEASE_VENDOR_ORDER=claude,agy,claude2`,
  mtime 2026-11-21 04:35:13Z. Both plan rows hold.

## Check 8 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-785`, exit 0 — re-run after adding this seat file: clean.

## Defects

None. No W.

## Notes

- N1: the candidates file grew after the plan's read: 101 lines at the plan's
  10:02Z measure, 106 now (mtime 2026-11-21 12:12:19+02:00). The added block
  "from SPL-6174 (c-744@<box2> fd3e8f82, head 473495da4, 2026-11-21 10:3xZ)" ends
  with one Bug-shaped entry (SPL-6174 links t1 topic `3e2c61b1` because
  `csi-rel c36682ea` is `unknown_discussion` in t1: the commit-links part cannot
  see a cross-workspace discussion) that the plan neither serves nor accounts
  for. It postdates the plan's 10:02Z read, so it is not a plan defect; it is a
  first input for round 35.
- N2: counts moved since the plan's measures, re-measured values hold: briefs
  6401 -> 6408 (26 without trailing newline, 0 of them `specs_and_docs` with an
  `Issue: SPL-` line, 0 modified in the last 48 h); queue 15 -> 16 queued, the
  11 file-naming queued briefs unchanged and none names a row file.
- N3: origin/master moved one commit past the plan's base (`f43fc60f1`, a
  spec-183 doc only); no row file drifted (`git diff --name-only 31a976ffb
  origin/master -- <row files>` empty), and every cited line is identical on
  both refs.
