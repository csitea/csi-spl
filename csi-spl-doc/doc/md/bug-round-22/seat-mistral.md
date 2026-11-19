# Bug round 22 (b22): mistral panel seat (m-472)

Seat: m-472, placement `c002-bug-round-22-mistral-panel-seat` (mistral;
docs and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/spawn-remote/briefs/49d9f6d7-39b5-4472-ad9e-00f2d88d733e.md`
(Issue SPL-5970, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `b3b480c9-4576-4f93-8b2b-500aa064cd3e`).

Review target: plan v0.1 `f4f39f7cf698f2dd2dad706570073c4274a3d2c9`, named in the
brief. Provenance: `git ls-remote origin | grep bug-round-22` ->
`f4f39f7cf698f2dd2dad706570073c4274a3d2c9  refs/heads/review/c002-bug-round-22-planner`;
`git show f4f39f7c --stat` -> 1 file, +186,
`csi-spl-doc/doc/md/bug-round-22-plan.md` (186 lines, read in full at that sha);
`git merge-base f4f39f7c 69c9febbb` -> `69c9febbbfae5fe0fab93956e46ee7160021740f`
(one commit on `69c9febbb`, as the brief says).
origin/master at my read: `86babad74` (fetched 2026-11-19T15:2xZ; `git
merge-base --is-ancestor 69c9febbb origin/master` -> exit 0). No later plan
version was named to me (inbox empty at 2026-11-19T15:30:15Z:
`SPOOL_ROOT=/var/spool-hub spool recv --as m-472` -> `[]`), so I sign v0.1.

## Verdict

**PASS on `f4f39f7cf698f2dd2dad706570073c4274a3d2c9`** (plan v0.1, 2 rows, both
measured on `69c9febbb`). Defects W1..: none. Notes N1..N4 below.

## Checks (each with the command run and what it printed, 2026-11-19 15:0x-15:3xZ)

### 1. Slug b22 unused

- `git log origin/master --oneline -E --grep='\(b22-' | wc -l` -> `0`.
- `git log origin/master --oneline -E --grep='\(b22-[0-9]{2}' | wc -l` -> `0` (no row slug on trunk).
- `git ls-remote origin | awk '{print $2}' | grep -E 'b22-[0-9]{2}|bug-round-22'` ->
  one line: `refs/heads/review/c002-bug-round-22-planner` (the planner's branch,
  expected; this seat's review branch did not exist yet at check time). A
  full-line `git ls-remote origin | grep -E 'b22-[0-9]{2}|bug-round-22'` also
  printed `review/c002-bug-round-14-mistral-seat`, but only via its sha hex
  (`...caf29cb22226...` contains `b2222`); its ref name does not match, as the
  awk-on-ref-names run shows.
- `grep -rlE '(^|[^0-9a-f])b22-[0-9]{2}-' /var/spool-hub/dispatch/briefs /var/spool-hub/asks /var/spool-hub/spawn-remote/briefs | wc -l`
  -> `1`: this seat's own brief `49d9f6d7-...md` (it quotes the two row slugs
  `b22-01-...`, `b22-02-...`). `grep -rl 'bug-round-22'` over the same dirs ->
  2 files: the planner's brief `63be24ad-...md` and this seat's brief. No other
  brief or ask names a b22 row. The sat half was read by c-002@sat 15:1xZ per
  the brief (0 files naming `b22-0N` there).

### 2. Every cited site exists on `69c9febbb` and on origin/master

Full paths via `git ls-tree -r --name-only origin/master | grep <name>`; each line
via `git show <ref>:<file> | sed -n <N>p`. Drift check:
`git diff 69c9febbb origin/master -- <file>` -> `0` lines for each of the 8
cited files, so nothing drifted; the lines below are identical on both refs.

- `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh`: `:102` ->
  `[[ -n "$names" ]] || { echo "MISSING ran: names no test (...): '$ran'"; return 3; }`;
  `:258-261` -> the same refusal as `SYNTAX FAIL ran: names no test ...`, `return 1`;
  `:254` -> the syntax regex, `log:` must start with `/` or `~/`; header `:17-20`,
  `:54`, `:59` -> the `@description` lines the plan cites.
- `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh` (482 lines): `:81-83`
  -> the docs-only fixture (`echo a >"$R0/a.md"` + commit); `:139` -> case 5
  `[[ $rc -eq 3 && "$out" == *"names no test"* ]] && pass "5. ..."`; `:180-214` ->
  case 8 (another box, syntax only, ends `:213-214` with the "no test" SYNTAX
  FAIL assertion); `:375` -> case 14's loop over `"bash latest-x.sh"`,
  `"bash test-dir/x.sh"`, `"source tests/test-lib.inc.sh"` asserting rc 3
  "names no test".
- `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh`: header `:8-16` ->
  the two forms (cell, author line/phrase, any case); `:86-92` ->
  `spl_review_notify_placed`; `:105-123` -> `spl_review_notify_authors`, with
  `:113` -> `local phrase='(^|[^A-Za-z])[Aa][Uu][Tt][Hh][Oo][Rr]:?[[:space:]]+'"$l"'-[0-9]{3,}...'`
  and `:122` -> `done < <({ grep -E '^[[:space:]]*\|' "$1" | grep -oE "$cell"; grep -oE "$phrase" "$1"; } 2>/dev/null)`.
- `csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh` (218 lines):
  `:1-70` -> the sandbox (`sends()`, `sent_to()` at `:68-70`); `:132-149` ->
  case 6 (the `(author c-372, ...)` phrase, `Author c-168@boxa.`, the codex and
  unknown-author controls).
- Read-only sites: `spl-accepted-close.func.sh:206-207` -> the journal
  re-verification calling `do_spl_review_line_check`; `spl-push-master.func.sh:317-325`
  -> the review syntax check sourcing `spl-review-line-check.func.sh`.
- `csi-spl-doc/doc/md/rounds-rulebook.md` 2.7.4 (header at `:113`): `:119` ->
  "If no test was executed directly, it must say `ran: none` and cite the
  command output read."
- `csi-spl-doc/specs/157-dispatch-automation/spec.md:430` -> Rule 3 "As built
  (B6, SPL-4109)": the author header matched as a phrase, any case, colon
  optional, anywhere on a line.

### 3. Both rows are real defects; red controls rebuilt and run on `69c9febbb`

Reading the code: row 01 follows from `:102` and `:258-261` —
`_spl_review_line_names` extracts test names from the `ran:` part, `none` yields
none, so the check refuses with exit 3 (and exit 1 under
`REVIEW_LINE_SYNTAX=1`) the very form rulebook 2.7.4 `:119` mandates for a
review with no test executed. Row 02 follows from `:113` + `:122` — the phrase
regex matches "author" anywhere on a line, so "row 01's author c-944" inside a
"never" list matches and c-944 is notified.

Red controls: the planner's scripts are on this box at
`/var/spool-hub/dispatch/b22-red-controls/`; `sha256sum ... | awk '{print
substr($1,1,12), $2}'` -> `278680899d32 rc01.sh`, `3aa159aea3e6 rc01-case.sh`,
`ba52a7b32271 proto01.func.sh`, `7bb24f56638c rc02.sh`, `de82a9cf9196
rc02-case.sh`, `7b43bd89bc5f proto02.func.sh`, with byte sizes 696/1705/26452/
684/1613/11805 — exactly the plan's section 3.2 table. The case files match the
blocks printed in plan section 3.2 (`diff` of the plan's printed block against
`rc01-case.sh` / `rc02-case.sh` shows only added `#` comment lines, no code
difference). Each `rcNN.sh <sha>` builds its run file in a `mktemp -d`
`git archive <sha> csi-spl-orc` copy; the tree was not touched. Run from
`/opt/csi/csi-spl-wt/m-472` as the repo user:

- `bash /var/spool-hub/dispatch/b22-red-controls/rc01.sh 69c9febbb` -> exit 1:
  `FAIL: b22-01: ran: none on a docs-only commit (a.md) -> rc 3: MISSING ran:
  names no test (...): 'none'`;
  `FAIL: b22-01: a docs-only commit, ran: names commands but no test -> rc 3:
  MISSING ...: 'git diff --stat HEAD^ HEAD'`;
  `FAIL: b22-01: the same from another box, REVIEW_LINE_SYNTAX=1 -> rc 1: SYNTAX
  FAIL ran: names no test (...)`;
  `PASS: b22-01 control: ran: none on a commit touching x.sh -> MISSING, exit 3`;
  `b22-01: 3 failure(s)` — exactly the plan's table.
- `bash /var/spool-hub/dispatch/b22-red-controls/rc02.sh 69c9febbb` -> exit 1:
  `PASS: b22-02 control: the Author: line's c-947 is told`;
  `FAIL: b22-02: c-944, named only in the 'never' list as row 01's author, is
  told: 2 note(s): --to c-947 --to c-944`;
  `PASS: b22-02 control: no Author: line, the phrase (author c-372, ...) is
  still told`; `b22-02: 1 failure(s)` — exactly the plan's table.

Both controls FAIL as the plan says; the lines did not drift (check 2), so the
run on `69c9febbb` is also the run on origin/master.

### 4. Row completeness (R2, R7, vendor, kind, batch) and the row 01 fixture

Both rows of the section 3 table carry: defect, evidence, sites file:line, a red
control that fails on `69c9febbb` (check 3 above), a fix scope, a box, vendor
`claude`, R7 reviewer `grok (cross-vendor)` with backup "another non-claude seat
the holder names", kind `simple_coding`, batch 1; the test column is in section
3.1 (`git grep -lE ... -- '*tests/*'` per row). No row is mistral coding or
testing; no R7 reviewer is mistral (rulebook 2.7.2 cross-vendor, and the brief's
never-mistral rule). Row 01's fixture move keeps the cases' intent: cases 5
(`:139`), 8 (`:180-214`) and 14 (`:375`) assert that a `ran:` naming no test is
refused (rc 3 / SYNTAX FAIL rc 1); the red control's PASS line proves the
refusal still fires on a commit touching `x.sh`, so moving those cases onto a
code-touching fixture preserves exactly what they assert, while the docs-only
commit becomes the new positive case (the row's new case).

### 5. R1 (disjoint files) and the lane map

- Row 01 files: `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh`,
  `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh`,
  `csi-spl-doc/doc/md/rounds-rulebook.md`. Row 02 files:
  `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh`,
  `csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh`,
  `csi-spl-doc/specs/157-dispatch-automation/spec.md`. The two sets are
  disjoint (R1, batch 1).
- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-line-check.func.sh,csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh,csi-spl-doc/doc/md/rounds-rulebook.md,csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh,csi-spl-doc/specs/157-dispatch-automation/spec.md --agent m-472`
  -> exit 4: `WARN no live lane lists` the six paths, but 3 live lanes record no
  files: `unknown: c-946@sat ...`, `unknown: c-981@sat ...`, `unknown:
  m-977@sat ...` (see N1). No owning lane is named for any row path.
- Refactor round 67 (`csi-spl-doc/doc/md/refactor-round-67-plan.md` on
  origin/master): its rows touch `csi-spl-iac/` files (`iac:run/tf-state-push.func.sh`,
  `iac:tests/adhoc-harvest-gcp-actions.tst.sh`, `iac:tests/sec-gosec.tst.sh`,
  ...) and `.shellcheck-warning-baseline.txt` — no overlap with the b22 row
  paths (all under `csi-spl-orc/` and `csi-spl-doc/`).

### 6. Section 5: "not a row" backed by a measurement

- Relayed retired-author send: measured in-plan — `grep -aoE 'GO to [^ ]+ failed
  \(rc [0-9]+'` on the box's `review-go/cron.out` -> 0 lines; the cited lines
  exist (`spool-fleet-relay.sh:218-232`, `spl-review-go.func.sh:838-847` — the
  `*)` retry branch at `:846` treats rc 13 as a retry, verified by `sed -n`).
- b20-01 R7 N3 (exit 14 not in the header): "as round 21" — backed by round 21's
  own plan (`bug-round-21-plan.md:98`: `grep -c '14'` on `spool-send.sh:76-110`
  -> 0), not re-measured in this plan.
- Hermetic suites: measured in-plan (n=1 each, commands and outputs printed:
  `ALL PASS` for both users on `check-commit-msg-hygiene.tst.sh`;
  `watcher-read-only.tst.sh` fails only for a user that cannot write the
  worktree).
- sha256-token done-claim: measured in-plan (`spl_done_claim_tokens` ->
  `92fd284d8549`; ledger 5 alerts, none on such a token); `:352` of
  `spl-done-claim-check.func.sh` verified — the `md5` cut regex has no `sha256`
  twin.
- "nothing pushed" flags: measured in-plan (the two outbox bodies and their
  ledger lines).
- r66-02 N1 (shallow APP_PATH): cited from c-426's report 43ab3767, explicitly
  `n=0`, no in-plan measurement — honestly labelled, round 23 input.
- r66-02 N2 (`FATAL no cargo` swallowed): reproduced by reading; I verified
  `spl-cmd-guard-mode.func.sh:39` has `>&2`, `:42` does not, `:72` captures
  `_scg_build` stdout.
- `workflow-tool-checksums.tst.sh:33`: cited from c-443's r67 plan section 7,
  not measured in this plan.
- Relative `log:` path: `spl-review-line-check.func.sh:254` verified — the
  regex wants `/` or `~/`.

So 6 of the 8 items carry an in-plan measurement or a line-read I re-verified;
2 (r66-02 N1, checksums:33) are backed by citation to another lane's report
with n=0 stated, not by a measurement in this plan (N2).

### 7. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-472`, exit 0.

## Defects

W1..: none. Both rows are real defects (check 3), every cited file:line matches
on `69c9febbb` and origin/master (check 2), the slug is unused (check 1), the
rows are complete and disjoint (checks 4-5), and the gate is clean (check 7).

## Notes

- N1: the lane-map check exits 4, not 0: c-946@sat, c-981@sat and m-977@sat
  record no files, so their scope is unknown from the map; their briefs live on
  sat and were not readable from this box. The plan's own 3.1 check recorded
  c-946's scope (the hub calendar, SPL-5963) as not these files, and no live
  lane lists any of the six row paths. The orchestrator re-runs R3 before the
  spawn.
- N2: section 5's r66-02 N1 and `workflow-tool-checksums.tst.sh:33` are backed
  by citation (another lane's report / the r67 plan), not by a measurement in
  this plan; the plan says so itself (n=0). Not a defect of the plan, but the
  panel should know which "not a row" verdicts are measured and which are
  relayed.
- N3: the plan's window and re-measure counts check out:
  `git log origin/master -1 --format=%cI -E --grep='^docs\(b21-plan'` ->
  `2026-11-19T14:26:15+02:00` (the plan's W); `git rev-list --count
  99f30c7a0..69c9febbb` -> `68` (the plan's 68).
- N4: origin/master moved to `86babad74` while I read; all 8 cited files are
  byte-identical between `69c9febbb` and origin/master (`git diff` -> 0 lines
  each), so the red controls run on `69c9febbb` hold for master as well.
