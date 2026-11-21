# Bug round 34 — panel seat mistral (m-785@sat)

Issue: SPL-6179 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-34-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-34-plan.md` on branch
`review/c002-bug-round-34-planner`, at the plan-version shas the dispatch holder
named on task `dispatch-bug-r34`: v0.1 `05e6be867...` (the planner's commit
subject and plan section 8), then v0.2 `1bd6972bf...` and v0.3
`4e296278c8e2a799c383b9e11acc499fc7a5c115` (holder msgs ed6a7078 and
1c337d42/10:25:36Z, "NEW REVIEW TARGET, replaces v0.2"). Rules:
`csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the panel
signs the plan sha; 5.1: 1 to 3 rows; 5.3 numbering and window; 5.4 bugs
priority 2). Form: `csi-spl-doc/doc/md/bug-round-33-plan.md` on origin/master.

**Verdict: PASS on `05e6be867d09253512a67b845459448ae70a62de` (v0.1) and PASS on
`4e296278c8e2a799c383b9e11acc499fc7a5c115` (v0.3, the current review target). No W. Notes N1-N5.**

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

---

# v0.3 review — `4e296278c8e2a799c383b9e11acc499fc7a5c115`

**Verdict: PASS on `4e296278c8e2a799c383b9e11acc499fc7a5c115` (v0.3, the review
target the holder named at 10:25:36Z, replacing v0.2 `1bd6972bf`). No W. Notes
N1-N5 (N1-N3 above stand; N4, N5 below).**

v0.3 = 2 rows, batch 1: row 01 `fix(b34-01-store-doc-asset-held-locked-doc)`
(store, `complex_coding`, claude) and row 02 `fix(b34-02-orc-enqueue-shared-line-own-line)`
(orc bash, `simple_coding`, claude) — row 02 is v0.1's row, unchanged. Base still
`31a976ffb`, `Window: W=2026-11-21T11:45:44+02:00`. Checks run on sat
2026-11-21 ~10:3xZ..10:5xZ.

## v0.3 Check 1 — slug

- `git log origin/master --since="$W" --oneline -E --grep='\(b34-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b34-[0-9]{2}|bug-round-34'` ->
  `4aac09e75b3e755137296554c5b0fe5439acb8fa refs/heads/review/c002-bug-round-34-mistral-seat`
  (this seat's, expected) and
  `4e296278c8e2a799c383b9e11acc499fc7a5c115 refs/heads/review/c002-bug-round-34-planner`
  (the planner's, expected). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b34-[0-9]{2}|bug-round-34'` ->
  the planner's and this seat's briefs only.

## v0.3 Check 2 — every site file:line on `31a976ffb` and on origin/master

- `git diff --name-only 31a976ffb origin/master` ->
  `csi-spl-doc/specs/183-agent-topic-pdf-export/spec.md`,
  `csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh`,
  `csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh`,
  `csi-spl-orc/lib/bash/funcs/gcp-account-pin.func.sh` (the `f43fc60f1` and
  `714df2994` commits). Row files: `git diff --name-only 31a976ffb origin/master
  -- <workspace_docs_assets.go, file_retention.go, wsdoc_assets.go, rls.go,
  0256_...sql, wsdoc_assets_orphan_sweep_test.go, spl-spawn-enqueue.func.sh,
  spl-spawn-queue.tst.sh>` -> empty.
- Every cited line printed with `git show <sha>:<file> | sed -n <N>p` at both
  refs, identical on both:
  - `store/workspace_docs_assets.go:63` comment `// DocAssetHeld reports whether...`;
    `:66` `func (s *Postgres) DocAssetHeld(ctx context.Context, tenant, fileID string) (bool, error) {`;
    `:68` `err := s.queryRowTenant(ctx, tenant, ` + backtick + `SELECT EXISTS (SELECT 1 FROM workspace_doc_item i,`;
    `:73` `}`.
  - `hub/file_retention.go:30` `FileOrphanGrace = 24 * time.Hour`;
    `:94` `return r, s.sweepOwnAssets(ctx, now, &r)`;
    `:111` `func (s *Server) sweepOwnAssets(...) error {`;
    `:151` `if kept, err := s.fileKept(ctx, tenant, id); err != nil || kept {`;
    `:195` `func (s *Server) orphanDelete(...) (bool, error) {`;
    `:200` same fileKept line.
  - `hub/wsdoc_assets.go:310` `func (s *Server) fileKept(...) (bool, error) {`;
    `:316` `}`.
  - `store/rls.go:80` `// WithHuman marks ctx as read by hum...`;
    `:86` `func WithHuman(ctx context.Context, hum string) context.Context {`;
    `:102` `func humanScope(ctx context.Context) string {`;
    `:107` `return ", set_config('app.doc_human_id', '" + hum + "', true)"`.
  - `0256_workspace_doc_restricted_to_human.sql:52` `DROP POLICY IF EXISTS human_lock ON workspace_doc;`;
    `:53` `CREATE POLICY human_lock ON workspace_doc AS RESTRICTIVE`;
    `:57` the `OR restricted_to_human = NULLIF(current_setting('app.doc_human_id', true), ''));` line;
    `:59` `DROP POLICY IF EXISTS human_lock ON workspace_doc_item;`;
    `:60` `CREATE POLICY human_lock ON workspace_doc_item AS RESTRICTIVE`;
    `:62` `WITH CHECK (true);`.
  - Row 02's orc cites as in the v0.1 section above (`:178`, `:185`, `:186`,
    `:190`, `:193`; `lane-issue.inc.sh:543/:547/:554`; `spl-lane-issue.func.sh:353`;
    `spl-spawn-queue.tst.sh` 2345 lines, `:2291`).
- `0143_messages_search_index.sql` carries the pattern the row names:
  `grep -nE 'NOLOGIN|SECURITY DEFINER' 0143...sql` -> `:45` `CREATE ROLE
  spool_search_reader NOLOGIN NOBYPASSRLS;`, `:79` `LANGUAGE sql STABLE SECURITY
  DEFINER ROWS 200`.
- Migrations on `31a976ffb` end at `0305_cost_entry_covers.sql`;
  `git ls-remote origin 'refs/rdb-claims/*'` -> `... refs/rdb-claims/0306`
  (claimed, c-745's), so the plan's "0306 is c-745's" holds.

## v0.3 Check 3 — red controls read, sha256, run on the base in a scratch copy

- `/var/spool-hub/dispatch/b34-red-controls/rc01-pg/`: `rc01pg.sh` 1964 B,
  `sha256sum` -> `17f39bc880adf251e026f9e7e63bfc3d9952ab689d65aa0bb0cd1ab4e879f9b0`
  (first 12 `17f39bc880ad`, the plan's claim); `b34_rc_asset_held_test.go` 1839 B,
  -> `fe0adcc73aa57a699bb62139b473add904df0851f9202da55bd98d2c397eff3b` (first 12
  `fe0adcc73aa5`, the plan's claim). `rc02.sh` 4871 B, ->
  `15e47f56c771e391c3b95db9e69bed9878e182269617a26208b4ece3a89d3416`; it is
  v0.1's `rc01.sh` renamed with its labels (the old `rc01.sh` is gone; diff modulo
  the `rcNN` labels is empty).
- Read whole: both export the sha with `git archive` into `mktemp -d` (trap
  `rm -rf`), stub or fixture everything, and touch no live state. `rc01pg.sh`
  runs the throwaway store test under the repo's `hub-live-stack.sh`, which
  migrates a throwaway Postgres 16 (cached `postgres:16-alpine` image on this
  box, never pulled) and exports `SPOOL_TEST_PG_DSN`; fixture tenant/docs only,
  no live database, no hub, no network.
- `bash .../rc01-pg/rc01pg.sh 31a976ffb` from this checkout, n=2: RED 2 of 2,
  the same output each run, last line `rc01pg sha=31a976ffb exit=1`, exit 1:
  `rcpg open: held=true want=true` / `rcpg lockedhuman: held=true want=true` /
  `rcpg lockedsweep: held=false want=true` / `rcpg unnamed: held=false want=false` /
  `rcpg wrong=1` — identical to the plan's table. It fails for the plan's reason:
  with no human on the context, rdb 0256's `human_lock` hides the locked doc's
  root item, so `DocAssetHeld` reads false and the sweep deletes the picture.
- `bash .../rc02.sh 31a976ffb`, n=1: RED, last line `rc02 sha=31a976ffb wrong=3`,
  exit 1 (`nonl got=none/3`, `lastln got=0`, `twice got=2`, `nl` control
  `shared/0`). `RC02_PLANT=1 ... rc02.sh 31a976ffb`, n=1: `wrong=0`, exit 0.

## v0.3 Check 4 — root cause of each row

- Row 01, read at `31a976ffb`: `DocAssetHeld` (`store/workspace_docs_assets.go:66-73`)
  runs `queryRowTenant` with no human; `humanScope` (`store/rls.go:102-107`)
  returns "" without one, so `app.doc_human_id` is unset; 0256:53-57 hides a
  `restricted_to_human` doc from everyone but its human (fail closed), and
  0256:59-62 passes an item only when its doc is visible. So the sweep's
  `fileKept` -> `DocAssetHeld` read (`hub/wsdoc_assets.go:310-316`,
  `hub/file_retention.go:151/:200`) sees no locked doc's root item and deletes
  its picture after `FileOrphanGrace` (`:30`, 24 h). The plan's reading holds.
  The caveat also holds: both `human_lock` policies are `AS RESTRICTIVE` with no
  `TO` clause (`:53`, `:60`), so they narrow every role, a NOBYPASSRLS definer
  owner too.
- Row 02: as in the v0.1 section above (`:185` guard and `:190` append are
  `^`-anchored / newline-less; `lane-issue.inc.sh:547` `^`-anchored;
  `spl-lane-issue.func.sh:353` writes `\n` first).

## v0.3 Check 5 — row fields

- Row 01: red control fails today (rc01pg RED n=2, exit 1); test column
  `git grep -l -E 'DocAssetHeld|fileKept|SweepFiles|sweepOwnAssets' 31a976ffb --
  csi-spl-api` -> exactly the plan's list: tests `hub/file_retention_test.go`,
  `hub/wsdoc_assets_orphan_sweep_test.go`, `hub/wsdoc_assets_test.go`,
  `channelmove/asset_locs_test.go`, `channelmove/objects_test.go` + 6 non-test
  files; `git grep -l DocAssetHeld 31a976ffb -- '*/store/*_test.go' | wc -l` -> 0
  (the plan's "no Postgres store test reads DocAssetHeld today"). Vendor claude,
  kind `complex_coding`, batch 1, box sat or `<box2>` (no pin). R7: claude waiver
  seat; `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` re-run -> `pick=hold ...`
  (grok weekly unknown/>=95% on both boxes). Suite runs under `PRE_PUSH_TIER=full`
  (a migration) — the plan says so.
- Row 02: as v0.1 (rc02 RED exit 1, plant exit 0; test column matches; claude,
  `simple_coding`, batch 1; R7 claude waiver).
- No mistral coding or testing row (both rows claude); no WUI file in either row,
  so a mistral panel seat may sit (developer guide 5.1). R1: batch 1 rows share
  no file — row 01 edits `store/workspace_docs_assets.go` + its new test + a new
  migration + `hub/wsdoc_assets_orphan_sweep_test.go`; row 02 edits
  `spl-spawn-enqueue.func.sh` + `spl-spawn-queue.tst.sh`; the two hub files c-745
  edits (`hub/file_retention.go`, `hub/wsdoc_assets.go`) are read-only in row 01.
- 2 rows, within 5.1's 1 to 3; issue priority 2 in the header (5.4); numbering and
  window as v0.1 (5.3).

## v0.3 Check 6 — R3 lane map

- `lane-map.sh --check <the six row paths> --agent m-785` -> exit 4: `WARN no
  live lane lists` them, `17 live lane(s) record no files: their scope is
  unknown, not free` (all on `<box2>`; was 18 at the plan's 10:15:51Z check, one
  lane closed since). No exit-3 owner. The plan records the sat half (worktree
  diff+status scan: 2 stale hits, `g-962-r4620` and `/tmp/g-418-red-master`,
  both retired) and asks the holder for the `<box2>` half (section 8 item 1,
  answered msg 42c66c91 with the "not proof of absence" caveat).
- Queue: `do_spl_spawn_queue` -> `16 queued, 0 placing`; the 11 file-naming
  queued briefs (spec 184 x6, spec 033 T026, spec 123 L4-L7): none names a row
  file (grep over their briefs).

## v0.3 Check 7 — inputs accounted for

Same as the v0.1 section (b33's 13 first-inputs, c-763 N1-N4 / c-761 N1-N3 all
in section 4; candidates file's bug-shaped entries served — landed shas
verified — or carried; spec 181 owned by its lanes; CI reds re-run and matching).
The new input since v0.1 is the holder's pick (msg 0a22e4ec, from c-001
8bd74383 re c-745's repro): it is row 01, re-measured by the planner (rc01pg
RED 3/3) and by me (RED n=2). N1 above (the candidates file's post-read
SPL-6174 entry) still stands as a round-35 input.

## v0.3 Check 8 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> clean, exit 0, re-run
  after this section was added.

## v0.3 Notes

- N4: c-745's review branch was not yet on origin at my check (`git ls-remote
  origin 'refs/heads/review/c002-s190*'` -> empty; the planner's 10:24Z note
  says the push was still in its pre-push hook), so the plan's claim that
  c-745's branch does not touch `store/workspace_docs_assets.go` is NOT
  verified by me from this box. The plan's mitigation covers the risk: row 01
  keeps both hub files c-745 edits read-only, and the holder's answer
  (msg 42c66c91) records the `<box2>` half with the "not proof of absence"
  caveat.
- N5: row 01's red control has no green half at plan time (the fix has two
  routes and the migration does not exist yet); the plan delegates the
  RED-then-GREEN proof to the row lane's commit body (C2), which is the
  rulebook's requirement. Row 02's control has its planted green (RC02_PLANT,
  exit 0, verified).
