# Bug round 35 — panel seat mistral (m-852@<box2>)

Issue: SPL-6185 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/spawn-remote/briefs/d293b537-45fd-47b3-af3d-0ddfa8f14b33.md`.
Review target: `csi-spl-doc/doc/md/bug-round-35-plan.md` on branch
`review/c002-bug-round-35-planner`, at the plan version sha
`bcc61dd7641063115cddf55e9209d6dbce125261` (v0.1: the branch head at my fetch and
the planner's commit subject names "bug round 35 plan v0.1 ... on e1ee705d8";
`git ls-remote origin refs/heads/review/c002-bug-round-35-planner` -> that sha,
nothing else). Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and
5 (3.2: the panel signs the plan sha; 5.1: 1 to 3 rows; 5.3 numbering and
window; 5.4 bugs priority 2). Form: `csi-spl-doc/doc/md/bug-round-34-plan.md`
on origin/master (seat form: `csi-spl-doc/doc/md/bug-round-34/seat-mistral.md`,
`069d1544b`).

**Verdict: PASS on `bcc61dd7641063115cddf55e9209d6dbce125261` (v0.1). No W.
Notes N1-N4.**

Reviewed sha: `bcc61dd7641063115cddf55e9209d6dbce125261`. The plan's base is
`e1ee705d83f434bb61d2b5d772567d102acd45a8` ("One sha" line 20);
`Window: W=2026-11-21T13:53:55+02:00` (line 21). origin/master at my fetch:
`05848e16c9bf6ee4100f45a1550b36a01c558311`. All checks run on <box2>
2026-11-21 ~14:0xZ..14:2xZ unless a line says otherwise; every command below was
run by me and its output is quoted as printed.

## Check 1 — slug b35 unused since the plan's W

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b34-plan')` ->
  `W=2026-11-21T13:53:55+02:00` (commit `4cd8415f0`), the value the plan records.
- `git log origin/master --since="$W" --oneline -E --grep='\(b35-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b35-[0-9]{2}|bug-round-35'` ->
  `bcc61dd7641063115cddf55e9209d6dbce125261\trefs/heads/review/c002-bug-round-35-planner`
  only (the planner's branch; expected. This seat's review branch did not exist
  yet at this check). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b35-[0-9]{2}|bug-round-35'` ->
  empty (0). With the plan's looser pattern
  `ls /var/spool-hub/dispatch/briefs | grep -E 'b35|bug-round-35'` ->
  `c002-b3fb351c-ui-view-rethink.md` only, the false match the plan names (`b35`
  inside a topic id). The planner's and this seat's briefs are uuid-named under
  `/var/spool-hub/spawn-remote/briefs/` on this box, not in `dispatch/briefs`.
- `git worktree list | grep -E 'b35-[0-9]{2}|bug-round-35'` -> this seat's only
  (`/opt/csi/csi-spl-wt/m-852 ... [m-852-c002-bug-round-35-mistral-panel-seat]`).

## Check 2 — every site file:line on the base sha and on origin/master

Row files: `csi-spl-iac/src/bash/run/check-pre-push.func.sh`,
`csi-spl-orc/src/bash/tests/changed-tests.sh`,
`csi-spl-iac/src/bash/tests/check-pre-push.tst.sh`,
`csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh`,
`csi-spl-doc/doc/md/pre-push-gate.md`; read-only cited:
`csi-spl-orc/src/bash/tests/tf-030-import-existing-cloud-run.tst.sh`,
`csi-spl-iac/src/bash/run/check-pre-push-cross.func.sh`.

- `git diff --name-only e1ee705d8 origin/master -- <the seven files above>` ->
  empty: no row file drifted between the plan's base and current origin/master.
- Every cited line printed with `git show <sha>:<file> | sed -n <N>p` at both
  `e1ee705d8` and `origin/master`; all exist and are identical on both refs:
  - `check-pre-push.func.sh:222` `_pp_paths() {  # <part>`; `:232`
    `orc)        echo "csi-spl-orc" ;;`; `:238` `*)          echo "" ;;`;
    `:1351` `# wui: an edit to an existing e2e/bench file is not a wui input (CLE-77946:`;
    `:1357` `done` (the part-selection loop `for p in blog iac orc wui-vendor wui api`
    at `:1350`).
  - `changed-tests.sh:79` (blank, `keys` header at `:80`), `:99` `done`;
    `:117` `  if [[ -n "$hits" ]]; then`; `:126`
    `printf 'ignore\t%s\t%s\n' "$f" "outside ${orc%/}, no orc test names it"`;
    `:127` `fi`.
  - `tf-030-import-existing-cloud-run.tst.sh` — the plan cites it by basename; its
    real path is `csi-spl-orc/src/bash/tests/tf-030-import-existing-cloud-run.tst.sh`
    (`git ls-tree -r e1ee705d8 | grep tf-030` -> also
    `csi-spl-iac/src/bash/tests/tf-030-hub-self-sign.tst.sh`,
    `csi-spl-orc/src/bash/run/tf-030-import-existing-cloud-run.func.sh`,
    `csi-spl-orc/src/bash/scripts/tf-030-import-existing-cloud-run.sh`; there is
    NO `csi-spl-iac/src/bash/tests/tf-030-import-existing-cloud-run.tst.sh`).
    At that path: `:24` `PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)`, `:26`
    `STEP=030-cloud-run-hub`, `:28`
    `STEP_DIR="$APP_ROOT/csi-spl-iac/src/terraform/$STEP"`, `:105`
    `[[ -z "$missing" ]] && pass "$e: every $STEP resource is covered" || fail "$e: resources not covered: $missing"`.
  - `check-pre-push-cross.func.sh`: `_PPX_MAP` at `:33` (header comment at `:12`).
  - `check-pre-push.tst.sh`, `run-all-tests-changed.tst.sh`, `pre-push-gate.md`,
    `check-pre-push-scope.tst.sh`, `csi-spl-orc/src/bash/scripts/tf-030-import-existing-cloud-run.sh`:
    `git cat-file -e e1ee705d8:<path>` -> exists on base for each.
  - Section 5's cite: `csi-spl-api/src/go/spool-hub-api/internal/hub/release_links.go:189-192`
    (`RelayHashOnly` comment + field) and `:244-249` (`store.RelayTaskHashRe.MatchString(l.TaskID)`)
    exist on both refs.

## Check 3 — red control read, sha256, run on the base in a scratch copy

- `/var/spool-hub/dispatch/b35-red-controls/` does NOT exist on <box2> (it is on
  sat): `ls /var/spool-hub/dispatch/b35-red-controls/` -> "No such file or
  directory". The plan prints rc01.sh in full (section 3.2) for a seat on the
  other box, so I rebuilt it: extracted the ` ```bash ` block from
  `git show bcc61dd76:csi-spl-doc/doc/md/bug-round-35-plan.md` -> 3008 B (the
  plan's claim), `sha256sum` ->
  `d8e9d1fd6fca90ea1845c2fdbc0d330658422f06733c431cff24294940153683`, first 12 hex
  `d8e9d1fd6fca` = the plan's recorded claim. The printed copy is faithful.
- Read whole: it makes `mktemp -d` + `trap rm -rf`, `git clone -q --shared
  --no-checkout` of the cwd's toplevel into the temp dir, checks out the sha
  there, appends one comment line to the step-030 file, commits in the temp
  clone, and asks that tree's own gate with `PRE_PUSH_PLAN=1` (plan mode: prints
  and exits 0, nothing runs) and its own orc map
  (`ORC_TEST_BASE`/`ORC_TEST_FILES bash src/bash/tests/changed-tests.sh`). No
  network, no push, nothing installed; all writes stay in the temp clone. It
  never touches live state.
- Run on the plan's base, n=3, from this worktree
  (`sudo -u <PUSH_USER> bash rc01.sh e1ee705d8`, each ~5 s): RED 3 of 3, identical output
  each time, exit 1:
  `plan(tf): PRE_PUSH_PLAN mode=fast tier=fast parts=hygiene stale-tree owner-orders commit-links lint-tf lint-trufflehog lint-gitleaks iac` /
  `rc01 part: got=no want=yes` / `rc01 test: got=no want=yes` /
  `plan(orc): PRE_PUSH_PLAN mode=fast tier=fast parts=hygiene stale-tree owner-orders commit-links lint-syntax lint-shellcheck lint-trufflehog lint-gitleaks lint-sigpipe orc iac-cross` /
  `rc01 ctrl: got=yes/yes want=yes/yes` /
  `rc01 sha=e1ee705d8 src=ad950c0e8 tf=csi-spl-iac/src/terraform/030-cloud-run-hub/03-runtime-sa.tf wrong=2`.
  Exactly the plan's recorded output. It fails for the plan's reason (a step-030
  tf change selects `iac`+`lint-tf` but not `orc`, and the orc map does not run
  the guarding test), not for an environment reason; the control `ctrl` holds.
- On the red-making shas' own gate code, n=1 each:
  `bash rc01.sh ad950c0e8 ad950c0e8` -> `wrong=2`, `tf=.../03-runtime-sa.tf`,
  exit 1; `bash rc01.sh 4baf28e8f 4baf28e8f` -> `wrong=2`,
  `tf=.../08-hub-self-sign.tf`, exit 1. Both match the plan.
- The red-making shas exist and are as the plan says:
  `git log -1 --format='%h %s' ad950c0e8` -> `ad950c0e8 feat(iac, SPL-6132): ... grant the hub runtime SA roles/cloudtranslate.user in step 030 ...`;
  `4baf28e8f` -> `chore(iac, SPL-6152): step 030 lets the hub runtime SA sign as itself ...`;
  fixes `4a1c86baa fix(orc, SPL-6132): ... (master red at ad950c0e8)` and
  `c7c2247b6 chore(orc, SPL-6152): ... (master red at 54dcbdae5)`;
  `git merge-base --is-ancestor 4a1c86baa origin/master` and same for `c7c2247b6`
  -> both on master. (`54dcbdae5` is the docs commit directly on top of
  `4baf28e8f`, the master head when that red ran.)

## Check 4 — root cause at the cited lines

- `check-pre-push.func.sh:222-238` (`_pp_paths`): the `orc` row (`:232`) echoes
  only `csi-spl-orc`; the selection loop (`:1350-1357`) appends a part when
  `_pp_touches "$sel" $(_pp_paths "$p")`. A change under
  `csi-spl-iac/src/terraform/030-cloud-run-hub/` touches `csi-spl-iac` (the `iac`
  row) but not `csi-spl-orc`, so `orc` is not selected. The plan's reading holds;
  rc01's `plan(tf)` line shows exactly `... lint-tf ... iac` with no `orc`.
- `changed-tests.sh:79-99` (`keys`): for an outside-orc path the map greps the
  orc `*.tst.sh` files for the file's basename/stem/function names; `:117-127`
  is the outside-orc branch and `:126` prints
  `ignore ... outside csi-spl-orc, no orc test names it`. The tf-030 test names
  its step (`STEP=030-cloud-run-hub`, `:26`), never a `.tf` basename, so no hit.
  The plan's reading holds; rc01's `test: got=no` shows it.
- The iac side's mirror map exists: `check-pre-push-cross.func.sh:33` `_PPX_MAP=(`,
  header `:12`. The orc side has no such map. Holds.

## Check 5 — row fields (R1, R2, vendor, kind, batch, R7)

- Row 01 has: a red control that fails today (rc01 exit 1, `wrong=2`, verified
  above) and a defined green half (`part`/`test` must turn `yes`, `ctrl` stays;
  the RED-then-GREEN proof is the row lane's commit body — the plan says so
  honestly, no green half exists at plan time); a test list (section 3.1);
  vendor `claude`; kind `simple_coding`; batch 1. R1: batch 1 holds row 01
  alone, so no file is shared in the batch. No mistral coding or testing row
  (row 01's vendor is claude). R7 reviewer: "claude waiver seat, fresh session,
  tree only, unless `do_spl_box_pick` picks grok when the row is queued" — the
  plan's `BOX_PICK_KIND=grok` run at 12:43:48Z gave `pick=hold` (grok weekly
  >= 95%), so no grok; never mistral. Holds.
- Section 3.1's test-column greps re-run on the base, exact match with the plan:
  `git grep -l -E 'changed-tests\.sh' e1ee705d8 -- '*.tst.sh' '*/tests/*.sh'` ->
  `check-pre-push-recheck-narrow.tst.sh`, `check-pre-push.tst.sh` (both
  csi-spl-iac), `local-hub-e2e.tst.sh`, `od-pool-stub.inc.sh`,
  `run-all-tests-changed.tst.sh`, `run-all-tests.sh` (all csi-spl-orc);
  `git grep -l -E '_pp_paths|PRE_PUSH_PLAN' e1ee705d8 -- '*.tst.sh'` -> the 8
  iac files the plan lists.
- The five orc tests that read iac terraform:
  `git grep -l -E 'csi-spl-iac/src/terraform|/src/terraform/' e1ee705d8 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features/*/tests`
  -> `check-fleet-rules-drift.tst.sh`, `check-hub-image-regress.tst.sh`,
  `tf-030-import-existing-cloud-run.tst.sh`, `tf-import-existing.tst.sh`,
  `tf-plan-ref.tst.sh` — exactly the plan's five.

## Check 6 — R3 lane map

- `bash .../lane-map.sh --check csi-spl-iac/src/bash/run/check-pre-push.func.sh,csi-spl-orc/src/bash/tests/changed-tests.sh,csi-spl-iac/src/bash/tests/check-pre-push.tst.sh,csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh,csi-spl-doc/doc/md/pre-push-gate.md,csi-spl-doc/doc/md/bug-round-35-plan.md --agent m-852`
  -> `WARN no live lane lists <them>, but 11 live lane(s) record no files`,
  `FATAL ... status 4`, exit 4. The 11 unknown lanes, all @sat: c-760, c-778,
  c-789, c-799, c-801, c-809 (b34-01), c-811, c-835, c-838 (this planner),
  c-840, m-785 (b34 mistral seat). No lane owns a row file (no exit 3); per the
  rule exit 4 means ask-first, not free. The plan recorded exit 4 with 13 unknown
  lanes "all on <box2>" from sat at 12:41:05Z; from <box2> the same check now shows
  11 unknown, all @sat (see N3).
- Spawn queue re-read:
  `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue`
  -> `16 queued, 0 placing` (plan: 14 at 12:41Z). Ask `82ce3159`
  (`hand-sat-c001-s123-l3w-translate-env-cnf-030`) is at 14/16, as the plan says.
  Grepping the queued briefs visible on this box
  (`grep -lE 'check-pre-push\.func|changed-tests\.sh|check-pre-push\.tst|run-all-tests-changed|pre-push-gate\.md|terraform/030' /var/spool-hub/dispatch/briefs/<queued slugs>`)
  -> no hit. The l3w brief itself lives on sat, not readable from <box2> (NOT RUN
  here); the plan's sat-side read found it hits `terraform/030` only, no row
  file — consistent with row 01's "read only" on step 030.

## Check 7 — inputs accounted for

- The candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md`
  is on sat, not on this box: `ls` -> "No such file or directory". NOT RUN from
  <box2>; the plan's section 5 accounts its 4 entries from SPL-6174 on. I verified
  the plan's SPL-6174 computation myself:
  `python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "spool-task:dispatch-c36682ea"))'`
  -> `3e2c61b1-219e-5811-81a4-4fe82287ca30`, the relay hash the plan names, and
  `release_links.go:189-192,244-249` carries the `relay_hash_only` flag.
- b34 plan's "first inputs for round 35" row
  (`git show origin/master:csi-spl-doc/doc/md/bug-round-34-plan.md | sed -n '340p'`)
  lists 14 items; each appears in the b35 plan's section 4 table with a verdict:
  b33-01 N1, the done-claim `job` label, the AltGr picker + blog switcher Enter,
  `blog.test.mjs:329`, `test-agent-name-shape.sh:89`, the orc/iac suites as the
  agent OS user, `gcp-billing-invoices.tst.sh` + `workspace-doc-preamble.test.mjs`,
  the `tasks|forward|multicast <hex>` forms, b29-01 N1 on the other box, the
  overlay mount, the other box's 8 dashless `/tmp` trees, the lease vendor order
  writer, the topic loop's `!inserted` branch + card read's hub path, the
  trailing-newline briefs. All 14 accounted; none is left unserved and
  unaccounted.
- b34 rows' R7 notes: `spool tail --task dispatch-bug-r34` from <box2> -> "no
  messages visible to this box in the local spool" — NOT RUN from <box2>. The plan
  read it on sat at 12:36Z: 0 R7 lines on b34-01/b34-02. The queue now holds
  `c002-b34-01-claude-waiver-reviewer` (8/16), consistent with "none seen yet".
- No bug-shaped input is left unaccounted on what I could read from this box.

## Check 8 — distribution hygiene

- `cd csi-spl-iac && sudo -u <PUSH_USER> ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-852`,
  exit 0 — re-run after adding this seat file: clean, exit 0.

## Defects

None. No W.

## Notes

- N1: the plan's defect column cites the guarding test by basename
  (`tf-030-import-existing-cloud-run.tst.sh:24-28`, `:105`); its real path is
  `csi-spl-orc/src/bash/tests/tf-030-import-existing-cloud-run.tst.sh`, not under
  `csi-spl-iac/src/bash/tests/` (that path does not exist on base or master:
  `git show e1ee705d8:csi-spl-iac/src/bash/tests/tf-030-import-existing-cloud-run.tst.sh`
  -> "does not exist"). The sites column lists the test by basename only, so no
  cited file:line is wrong; the cited lines exist at the real path on both refs.
- N2: the plan's section 4 row "b34-01, b34-02 ... 0" was measured at 12:44Z and
  was true then; since then b34-02 landed on master:
  `git log origin/master --since="$W" --oneline -E --grep='\(b34-0[12]-'` -> 1,
  `0d0797fde fix(b34-02-orc-enqueue-shared-line-own-line, SPL-6181)`. Its files
  (`spl-spawn-enqueue.func.sh` etc.) are disjoint from row 01's files, so no R1
  or R3 impact; the plan scopes its claim to "at this plan's fetch", so this is
  drift, not an error.
- N3: the lane map's unknown-lane list differs by the querying box: from sat at
  12:41:05Z the plan saw 13 unknown lanes "all on <box2>"; from <box2> now I see 11,
  all @sat. Both runs exit 4 and no lane lists a row file. The holder's
  `<box2>` half (plan section 8 item 1) is exactly what this seat's view covers.
- N4: not runnable from <box2> (files/topics live on sat): the candidates file
  `/var/spool-hub/dispatch/c002-next-round-candidates.md`, the sat copy of
  `/var/spool-hub/dispatch/b35-red-controls/rc01.sh` (rebuilt from the plan's
  printed block instead; sha256 matches the plan's claim), the l3w queued brief,
  and spool topics `dispatch-bug-r34` / `dispatch-bug-r35` / the round's
  discussion. Each is marked NOT RUN above where it applies.
