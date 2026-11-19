# Bug round 23 (b23): mistral panel seat (m-033)

Seat: m-033@sat, placement `c002-bug-round-23-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-23-mistral-panel-seat.md`
(Issue SPL-5983, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `24459bd1-9f26-4867-ac59-3d41f179a8b1`).

Review target: plan v0.1 `05c8b15bfe97fd9fca9fb2cd98b31af3d59c5a8c`, named in the
brief. Provenance: `git ls-remote origin | grep bug-round-23` ->
`05c8b15bfe97fd9fca9fb2cd98b31af3d59c5a8c  refs/heads/review/c002-bug-round-23-planner`;
`git log --oneline 23864a224..05c8b15bf | wc -l` -> `1` and
`git rev-parse 05c8b15bf^` -> `23864a22465b2c8409da9129614d07bc8a3ffc2f` (one commit
on `23864a224`, as the brief says); `git show 05c8b15bf --stat` -> 1 file,
`csi-spl-doc/doc/md/bug-round-23-plan.md`, +199 (read in full at that sha).
origin/master at my read: `a97766b47` (moved past `23864a224` during the read,
N1). No later plan version was named to me (inbox empty at 2026-11-19T20:0xZ:
`SPOOL_ROOT=/var/spool-hub spool recv --as m-033` -> `[]`), so I sign v0.1.

## Verdict

**PASS on `05c8b15bfe97fd9fca9fb2cd98b31af3d59c5a8c`** (plan v0.1, 2 rows, both
defects real with red controls RED on `23864a224` and reachable GREEN under the
plan's fix scopes). Defects W1..: none. Notes N1..N7 below.

## Checks (each with the command run and what it printed, 2026-11-19 19:5x-20:0xZ)

### 1. Slug b23 unused

- `git log origin/master --oneline -E --grep='\(b23-[0-9]{2}' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b23-[0-9]{2}|bug-round-23'` -> one line,
  `05c8b15bfe97fd9fca9fb2cd98b31af3d59c5a8c  refs/heads/review/c002-bug-round-23-planner`
  (the planner's branch, expected; my seat branch did not exist yet at check
  time). Nothing else matched.
- sat half: `ls /var/spool-hub/dispatch/briefs/ | grep -E 'b23-[0-9]{2}' | wc -l`
  -> `0`; `ls /var/spool-hub/dispatch/briefs/ | grep -c 'bug-round-23'` -> `2`
  (`c002-bug-round-23-planner.md`, `c002-bug-round-23-mistral-panel-seat.md`,
  both expected); `ls -d /opt/csi/csi-spl-wt/*b23* 2>/dev/null | wc -l` -> `0`
  (no b23 worktrees on sat).

### 2. Every cited site file:line exists on `23864a224` and on origin/master

- `git diff 23864a224 origin/master -- <each of the six cited files>` -> empty
  for all six (`spl-review-go.func.sh`, `spl-review-go.tst.sh`,
  `specs/157-dispatch-automation/spec.md`, `spl-done-claim-check.func.sh`,
  `spl-done-claim-check.tst.sh`, `done-claim-check.md`): no drift between the
  plan's measurement sha and current origin/master (`a97766b47`).
- Each cited line read with `git show <ref>:<file> | sed -n <N>p` on both refs,
  no MISSING: row 01 `spl-review-go.func.sh:17,36,569,571,577,578,592,600,743,744`,
  `spl-review-go.tst.sh:454,481` (case 14's two-prose-author refusal
  `Author c-222@boxa (claude), with author c-333@boxa` is at `:469`),
  `spec.md:250` (the prose-brief bullet); row 02
  `spl-done-claim-check.func.sh:14,19,339,349,352,51,56,69,70`,
  `spl-done-claim-check.tst.sh:128,160,169`, `done-claim-check.md:25,27`.

### 3. Each row is a real defect; red controls rebuilt and run

Code read at the cited lines on `23864a224`:

- Row 01: `spl-review-go.func.sh:569`
  `named = re.findall(r"(?i)\bauthor:?[ \t]+([acgmq]-[0-9]{3,})...", text)` matches
  the line-start `Author: <id>` line AND every prose "author <id>";
  `:578` `if len({i for i, _ in named}) != 1 or not said: sys.exit(1)`; the rc 3
  hold is `:743` via `_spl_review_go_unplaced` (`:592-600`, `why` branch
  `:571-577`). A brief with a line-start `Author:` line plus a prose mention of
  another lane's author reads two ids -> rc 1 -> review-go holds rc 3. Follows
  from the code.
- Row 02: `spl-done-claim-check.func.sh:352` cuts the token after an
  `md5(sum)?` label only; `sha256`/`sha256sum`/`sha1sum`/`SHA-256` labels are not
  cut, so the 9..12-hex file-hash prefix survives the
  `grep -xE '[0-9a-f]{9,12}|[0-9a-f]{40}'` and is read as a git sha. Follows from
  the code.

Red controls rebuilt from the plan's section 3.2 fences (extracted with
`sed -n '87,113p'` / `'119,138p'` of the plan at `05c8b15bf`) into a throwaway
dir `/tmp/b23-rc.XhdVsm` (never in the tree), run from this checkout on
`23864a224`:

- `bash rc01.sh 23864a224` ->
  `FAIL: b23-01: Author: c-981 line, prose 'author c-414' -> rc 1 '' (review-go holds rc 3)`;
  3 controls PASS (two `Author:` lines two ids -> rc 1; no `Author:` line, two
  prose authors -> rc 1; no `Author:` line, one prose author -> row c-222);
  `b23-01: 1 failure(s)`, exit 1. Matches the plan's printed output.
- `bash rc02.sh 23864a224` -> 4 FAIL (`'rc01.sh sha256sum -> 92fd284d8549'`,
  `'sha256 92fd284d8549 of rc01.sh'`, `'SHA-256: 92fd284d8549'`,
  `'sha1sum=4a5f55c8a4f3'` each read as a git sha); 2 controls PASS (md5 label
  -> no sha; `sha: 3e46a758ce7a` still names a git sha); `b23-02: 4 failure(s)`,
  exit 1. Matches the plan's printed output.

### 4. Fix scopes

- Row 01 prototype (per the plan: after `:569`, `lined = re.findall(r"(?im)^[ \t]*author:[ \t]+<id>...", text)` and `named = lined or named`):
  `RC_PROTO=proto01.func.sh bash rc01.sh 23864a224` -> 4 PASS, `b23-01: 0 failure(s)`,
  exit 0. The line-start `Author:` line wins and the prose form is dropped; the
  case-14 shape (no `Author:` line, two prose authors) stays rc 1; two
  `Author:` lines with two ids stay rc 1. The plan's scope claim holds.
- Row 02 prototype (label `md5(sum)?` widened to
  `(md5|sha-?(1|224|256|384|512))(sum)?`, back-reference `\3` -> `\5`):
  `RC_PROTO=proto02.func.sh bash rc02.sh 23864a224` -> 6 PASS, `b23-02: 0 failure(s)`,
  exit 0. Only the `sha<N>` labels are cut; a bare `sha:` label still names the
  git sha `3e46a758ce7a`. The plan's scope claim holds.
- Row 01's rc 3 -> rc 2 claim: the code order at `:743` (author empty -> hold
  rc 3) then `:744` (`[[ "${author%%-*}" != "${rid%%-*}" ]]` -> hold rc 2
  "shares the vendor of author") means a fixed row for a same-vendor waiver
  seat reaches the vendor check and holds rc 2, not rc 3; a GO needs rc 0 past
  it. The observed waiver seats are same-vendor (claude-claude), so the plan's
  claim holds: rc 3 -> rc 2, no GO.

### 5. Row completeness (defect, R2 control, test list, vendor, kind, batch, R7)

Both rows in the plan's section 3 table carry all fields: defect + evidence +
sites + red control + fix scope + box + vendor `claude` + R7 reviewer `grok`
(cross-vendor to the claude authors; backup another non-claude seat the holder
names) + kind `simple_coding` + batch 1. No mistral coding or testing row; no
R7 reviewer is mistral. Test column re-run: `git grep -lE '_spl_review_go_row|do_spl_review_go' -- '*tests*'` ->
`csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`,
`csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh` (plus
`orc-shard-weights.txt`, a shard list); `git grep -l 'spl_done_claim' -- csi-spl-orc/src/bash/tests/` ->
`csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh`. Matches plan 3.1.

### 6. R1 disjoint files; lane map

- Plan 3.1 row files: row 01 `spl-review-go.func.sh`, `spl-review-go.tst.sh`,
  `specs/157-dispatch-automation/spec.md`; row 02 `spl-done-claim-check.func.sh`,
  `spl-done-claim-check.tst.sh`, `done-claim-check.md` — disjoint, batch 1.
- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-doc/specs/157-dispatch-automation/spec.md,csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh,csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh,csi-spl-doc/doc/md/done-claim-check.md --agent m-033`
  -> `WARN no live lane lists <the six paths>, but 10 live lane(s) record no
  files: their scope is unknown, not free`, exit 4. The 10 unknown lanes:
  c-049, c-060, c-443, c-484, c-521, c-536 (the planner), c-542 (r68-01),
  c-812, c-924, c-927 (all @<box2>). No live lane lists any row path; exit 4
  means ask-first, not free (N2).
- Refactor round 68 overlap: r68 plan v0.2 `2d9900128` (`review/c002-refactor-round-68-planner`)
  names none of the six row files (`grep -c` each -> 0); its rows' Files: ONLY
  are `orc:tests/release-stable.tst.sh` (r68-01) and `sa:tests/test-agent-watch.sh`,
  `sa:tests/test-agent-top.sh` (r68-02). No overlap with b23 rows.

### 7. Sections 4, 5, 6: is each "not a row" backed by a measurement in the plan?

- Section 4, b22-01/b22-02: yes — `git log origin/master --oneline -E --grep='\(b22-0[12]-'`
  -> `ddd59b510`, `b144fea59` (b22-01), `3e46a758c` (b22-02), all on origin/master.
- Section 4, the four round-22 leftover items: command "as round 22", result
  "unchanged" — NOT a fresh measurement in this plan; backed by round 22's plan
  by reference (N3).
- Section 5, retired-author retry: measurement is on `<box2>` (cron.out tail;
  `grep -ac 'review-go.*rc=3' automation.log` -> 6, newest 2026-11-09), stated
  in the plan, not re-runnable from sat; "no observed case, no red control" is
  stated honestly (N5).
- Section 5, hermetic suites: the plan says "Not re-measured this round; no sat
  output" — NOT backed by a fresh measurement; it defers to round 24 with sat's
  output (N4).
- Section 5, r66-02 N1: re-run here — `source csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh; APP_PATH=/app spl_run_paths`
  -> `SPL_VAR_ORG_DIR=/var/`, `SPL_VAR_APP_DIR=/var//app`; mechanism reproduced,
  n=0 observed cases, as the plan says.
- Section 5, r66-02 N2: `git show 23864a224:csi-spl-orc/src/bash/run/spl-cmd-guard-mode.func.sh | sed -n '39p;42p'`
  -> `:39` has `>&2`, `:42` `do_log "FATAL no cargo ..."` does not. Confirmed.
- Section 5, iac `gcp-billing-invoices.tst.sh` flake: n=1 run reference
  (44570765247, green on the next run), cross-referenced from section 2 source 2.
- Section 6, `issues-ctxmenu` flake: `git log origin/master --oneline -3 -- csi-spl-wui/tests/e2e/issues-ctxmenu.test.mjs`
  -> `b6c01b230`, `43b290114`, `cf945aa32`, matching the plan; the lane-map check
  is recorded in the plan. Backed.
- Section 6, live lanes: points at section 3.1 (reference, covered by check 6).

### 8. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-033`,
  exit 0.

## Notes

- N1: origin/master moved past the plan's measurement sha during my read
  (`23864a224` -> `a97766b47`, the r68 plan commit). All six cited files are
  byte-identical between the two refs (`git diff 23864a224 origin/master --
  <files>` empty), so no cited line drifted; the red controls were run on
  `23864a224` as the plan specifies.
- N2: the lane-map check exits 4, not 0: no live lane lists the six row paths,
  but 10 live lanes record no files (c-049, c-060, c-443, c-484, c-521, c-536,
  c-542, c-812, c-924, c-927, all @<box2>), so their scope is unknown. Per the
  rule, exit 4 is ask-first, never free; the plan already has the orchestrator
  re-run the check before the spawn (R3). Not a plan defect: the plan recorded
  the same exit 4 at its own run time (then for c-946@sat only).
- N3: section 4's four round-22 leftover items are "not a row" by reference to
  round 22's plan ("as round 22"), not by a measurement in this plan.
- N4: section 5's hermetic-suite item is explicitly not re-measured this round;
  its "not a row" rests on round 22's measurement plus the missing sat output,
  and the plan hands it to round 24. Honest, but not a fresh measurement.
- N5: section 5's retired-author item's counts (6 rc=3 in automation.log,
  newest 2026-11-09) are measured on `<box2>`, not re-runnable from sat; the
  plan says so and claims no red control.
- N6: both prototypes were rebuilt exactly as the plan describes (proto01:
  `lined`/`named = lined or named` after `:569`; proto02: label widened to
  `(md5|sha-?(1|224|256|384|512))(sum)?` with `\3` -> `\5`) and reach 0 failures
  with all controls intact, so PASS is reachable under the stated fix scopes
  (R2). The lanes write their own fixes and suite cases, as the plan says.
- N7: the plan's window is real: `git log origin/master -1 --format=%cI -E --grep='^docs\(b22-plan'`
  -> `2026-11-19T16:37:15+01:00`, matching the plan's `Window: W=...`.

## Signatures

- 2026-11-19: m-033@sat signs plan v0.1 `05c8b15bfe97fd9fca9fb2cd98b31af3d59c5a8c` — **PASS**.
