# Bug round 31 — panel seat mistral (m-642@sat)

Issue: SPL-6136 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-31-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-31-plan.md` on branch
`review/c002-bug-round-31-planner`, at the v0.1 sha the dispatch holder named on
task `dispatch-bug-r31` (c-002@sat, msg da191d7f, 04:2xZ). Rules:
`csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the panel
signs the plan sha; 5.1: 1 to 3 rows; 5.3 numbering and window; 5.4 bugs
priority 2). Form: `csi-spl-doc/doc/md/bug-round-30-plan.md` on origin/master.

**Verdict: PASS on `a370b578614753c566e2f92deb642883a02770bb` (v0.1) and on
`78c13231e745887f3ca054a3f5f12039a9824451` (v0.2), 2026-11-21T04:3xZ — no W.
See the verdict sections at the end of this file.**

## Setup

- STEP 0: `cd csi-spl-orc && sudo -u <PUSH_USER> env AGENT_ID=m-642 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack`
  -> `ACK m-642 read developer-guide.md blob 8b1916cdc5d75c52cc4b3248babef398acf1366b`.
- Read whole: `CLAUDE.md`, `csi-spl-doc/doc/help/how-to-post.md`,
  `csi-spl-doc/doc/md/rounds-rulebook.md` (sections 1-3, 5),
  `csi-spl-doc/doc/md/bug-round-30-plan.md` (the form, v1.0 `b67431a30`),
  `/var/spool-hub/dispatch/c002-next-round-candidates.md` (99 lines),
  the planner's brief `c002-bug-round-31-planner.md`, the plan at the named
  sha (250 lines).
- Reviewed sha: `a370b578614753c566e2f92deb642883a02770bb`.
  `git ls-remote origin review/c002-bug-round-31-planner` ->
  `a370b578614753c566e2f92deb642883a02770bb` (the branch head, matches the
  holder's msg). `git log --oneline -3 a370b5786` -> `a370b5786 docs(b31-plan,
  SPL-6136): ...` on `325a47c76` on `6f1de97d8`. `git diff --stat 325a47c76
  a370b5786` -> `csi-spl-doc/doc/md/bug-round-31-plan.md | 250 +++...`, 1 file,
  250 insertions. `git show a370b5786:csi-spl-doc/doc/md/bug-round-31-plan.md
  | sha256sum` -> `fcd7cc4852f2a4ff521120c3037a9d9aa8b801a73a2c2ce0e893ca5d2335eb08`.
  The plan's own base: `325a47c76`; window `W=2026-11-21T04:35:42+01:00`
  (`0eb0ea462`, the b30 close record).

## Check 1 — slug b31 unused since the plan's W

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b30-plan')` ->
  `W=2026-11-21T04:35:42+01:00` (same as the plan's `Window:` line).
- `git log origin/master --since="$W" --oneline -E --grep='\(b31-' | wc -l` -> `0`;
  row form `--grep='\(b31-[0-9]{2}'` -> `0`.
- `git ls-remote origin | grep -E 'b31-[0-9]{2}|bug-round-31'` ->
  `a370b578614753c566e2f92deb642883a02770bb refs/heads/review/c002-bug-round-31-planner`
  only (the planner's branch, expected; this seat's review branch appears after
  its push). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b31-[0-9]{2}|bug-round-31'` ->
  `c002-bug-round-31-mistral-panel-seat.md`, `c002-bug-round-31-planner.md`
  (this seat's and the planner's; expected).

## Check 2 — every site file:line on the base and on origin/master

Row files: `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh`,
`csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh`,
`csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh`,
`csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh`,
`csi-spl-doc/doc/md/done-claim-check.md`.

- `git cat-file -e 325a47c76:<f>` and `git cat-file -e origin/master:<f>` ->
  all five exist on both (base=yes master=yes for each).
- `git diff --name-only 325a47c76 origin/master -- <the five files>` -> empty
  (rc 0, no drift). `git log --oneline 325a47c76..origin/master` at my 04:31Z
  fetch -> `986ddca84 docs(doc, SPL-6086): ...` only; it touches no row file.
- Every cited file:line printed with `git show 325a47c76:<file> | sed -n <N>p`
  and matches the plan's claim; spot re-read on `origin/master` (identical,
  no drift): `spl-spawn-review-notify.func.sh:78` ->
  `rc=0; spl_review_notify_one ... "${abox:-$box}" "$box" "$dry" || rc=$?`;
  `spl-done-claim-check.func.sh:358` -> the `sed -E` label-cut line
  `s/(^|[^0-9a-zA-Z])(md5|sha-?(1|224|256|384|512))(sum)?[^0-9a-zA-Z]+[0-9a-fA-F]+.../\1 \5/gI`;
  `spl-done-claim-check.tst.sh:130` -> the `sha256` case message.
- Row 01 sites verified on base: `spl-spawn-review-notify.func.sh:21-27`
  (header item 2: routes to the box its cell names, else this box; `SKIP:
  author <id> already retired`; relay via `spool-send.sh --to <id>@<box>`),
  `:78` (`${abox:-$box}`), `:101-107` (`spl_review_notify_branch` greps
  `review/...` only), `:114-130` (`spl_review_notify_authors`; `:120`
  `grep -qE "$line" ... && phrase="$line"` — a line-start `Author:` line wins),
  `:136-145` (`spl_review_notify_state` reads local `registry.tsv` /
  `registry.retired.tsv`), `:150-170` (`spl_review_notify_one`; `:153`
  `[[ "$8" != "$9" ]] || state=...`, `:155` the SKIP log);
  `spl-spawn-review-notify.tst.sh:13-23` (header sections 3-6 incl. the b22-02
  red control), `:104-111` (section 3 red control), section 6 at `:135`
  (`# 6. the Author forms; a local author goes out as its bare id`).
- Row 02 sites verified on base: `spl-done-claim-check.func.sh:19-22` (header:
  md5/sha1..sha512 labels are file hashes, SPL-2332/SPL-5990), `:342-354`
  (comment), `:356-363` (`spl_done_claim_tokens`, sed at `:358`), `:369-382`
  (`spl_done_claim_commits`; `:380` keeps a lettered token when no repos file),
  `:954-971` (`spl_done_claim_note`; `:963` the `not an object in any
  repository (a pre-rebase sha?)` alert); `spl-done-claim-check.tst.sh:130`
  (sha256 case), `:163-164` (verdict list, `sha256=landed`), `:173-174` (2b2
  check); `done-claim-check.md:27-31` (item 2).
- `git show 325a47c76:csi-spl-doc/doc/md/perf-round-17-plan.md | sed -n 200p`
  -> names `spl-spawn-review-notify.func.sh` (as the plan's 3.1 says).
- `git grep -cE 'review-notify|done-claim' 325a47c76 -- csi-spl-doc/doc/md/refactor-round-79-plan.md`
  -> rc 1 (0 hits, as the plan says).
- `git log origin/master --since=2026-11-19 --oneline -- <the four code/test
  files>` -> `f136d78da` (SPL-6074), `a6f5a723d` (b23-02, SPL-5990),
  `3e46a758c` (b22-02, SPL-5976) — all landed, as the plan says.
- `git worktree list | grep -iE 'review-notify|done-claim'` -> 1,
  `c-457-c003-spl6074-done-claim-src-tag-claude-waiver-reviewer` (retired R7
  seat), as the plan says.

## Check 3 — red controls read, sha256sum, run on the base in a scratch copy

- `ls -la /var/spool-hub/dispatch/b31-red-controls/` -> `rc01.sh` 2790 B,
  `rc02.sh` 2049 B (the sizes the plan's 3.2 quotes).
- `sha256sum` -> `d65e368447bd84a983a5a2f86692bb5832ef577714e2678f1245278a4b366187  rc01.sh`,
  `32f36e2b021fb3a47dbce5da597418e894c8bfc2b467149eaef0e744f092efa2  rc02.sh`
  (first 12 hex `d65e368447bd`, `32f36e2b021f` — exactly the values the plan
  quotes).
- `bash /var/spool-hub/dispatch/b31-red-controls/rc01.sh 325a47c76`, n=3
  (04:2xZ), identical output each run, exit 1; last line
  `rc01 sha=325a47c76 wrong=1`:
  `rc01 far: SKIP: author c-442 already retired want=-> c-442@box-b` /
  `rc01 here: PLAN note c-001 -> c-443@box-a want=-> c-443@box-a` /
  `rc01 explicit: PLAN note c-001 -> c-444@box-b want=-> c-444@box-b` /
  `rc01 gone: SKIP: author c-445 already retired want=SKIP: author c-445 already retired`.
  RED exactly for the plan's reason: the brief names `c-442@box-b`, yet the
  bare `Author: c-442` is judged by box-a's retired c-442 and skipped; the
  three controls (live local, explicit box, retired with no box named) are
  right. Not an environment reason: the script `git archive`s the sha into a
  `mktemp -d`, builds its own spool/briefs/registry there and runs with
  `DRY_RUN=1 SPL_SPOOL=/nonexistent SPOOL_ROOT=<fixture>` — it never touches
  the live `/var/spool-hub` (grep of the script: only fixture paths).
- `bash /var/spool-hub/dispatch/b31-red-controls/rc02.sh 325a47c76`, n=3
  (04:2xZ), identical output each run, exit 1; last line
  `rc02 sha=325a47c76 wrong=2`:
  `rc02 prefix: tokens='da931bbcc8d4' want=''` /
  `rc02 first12: tokens='a366e7466e55' want=''` /
  `rc02 label: tokens='' want=''` /
  `rc02 gitsha: tokens='9b680e7b5' want='9b680e7b5'` /
  `rc02 diff: tokens='cc13eac0b 5e137db43' want='cc13eac0b 5e137db43'`.
  RED exactly for the plan's reason: a word between the sha256 label and the
  hash keeps the hash as a sha; the plain label, a real git sha and the shas
  inside `sha256(git diff ...)` are right. Not an environment reason: the
  script exports the sha with `git archive` into `mktemp -d` and only pipes
  fixture lines into `spl_done_claim_tokens`; no live state.

## Check 4 — root cause of each row, read at the cited lines

- Row 01 holds. `:78` passes `${abox:-$box}` — a bare `Author:` id gets this
  box. `:120` makes a line-start `Author:` line the only source once present,
  and `:128` prints an empty box for a bare id. `:153` runs the registry check
  only when `abox == box`, and `:136-145` checks this box's
  `registry.tsv`/`registry.retired.tsv`, where ids are reused across boxes;
  `:155` logs `SKIP: author <id> already retired`. So a live author on the
  other box named bare is skipped — exactly the plan's reading, and rc01's
  `far` case demonstrates it.
- Row 02 holds. `:358`'s sed allows only non-alphanumerics between the label
  and the hex (`(sum)?[^0-9a-zA-Z]+[0-9a-fA-F]+`), so "sha256 prefix `<hex>`"
  is not cut; `:380` keeps any lettered 9..12-hex token when no repos file is
  given; `:963` then alerts `not an object in any repository (a pre-rebase
  sha?)`. Exactly the plan's reading, and rc02's `prefix`/`first12` cases
  demonstrate it.

## Check 5 — row fields (R1/R2/R7, vendor, kind, batch)

- 2 rows (rulebook 5.1: 1 to 3, aim 2 — ok); ids `b31-01`, `b31-02`; window W
  quoted (5.3 — ok); issue SPL-6136 priority 2 (5.4 — ok).
- R1: batch 1 rows share no file — row 01 {`spl-spawn-review-notify.func.sh`,
  `spl-spawn-review-notify.tst.sh`}, row 02 {`spl-done-claim-check.func.sh`,
  `spl-done-claim-check.tst.sh`, `csi-spl-doc/doc/md/done-claim-check.md`} —
  disjoint (verified by listing; neither sources the other).
- R2: test column greps re-run on `325a47c76`:
  `git grep -l -E 'spl-spawn-review-notify|spl_review_notify|do_spl_spawn_review_notify' 325a47c76 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features csi-spl-iac/src/bash/tests`
  -> `orc-shard-weights.txt` (a list, not a test) + `spl-spawn-review-notify.tst.sh`;
  the row 02 pattern -> `orc-shard-weights.txt` + `spl-done-claim-check.tst.sh`.
  Each row's red control fails on the base (check 3) and the plan requires the
  commit body to show exit 0 on the fix (the green half is the lane's, as in
  the b30 form).
- Vendor `claude`, kind `simple_coding`, batch 1 on both rows: no mistral
  coding or testing row (mistral is only this panel). R7 reviewer: the claude
  waiver seat (1a7c70da), fresh session, tree only — the allowed waiver, never
  mistral. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub
  BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (04:2xZ) -> `pick=hold
  reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% ...; <box2> 99%
  ...]: queue the lane, spawn nothing` — matches the plan's section 8.

## Check 6 — R3 lane map on the row paths

- `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh,csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh,csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh,csi-spl-doc/doc/md/done-claim-check.md,csi-spl-doc/doc/md/bug-round-31/seat-mistral.md --agent m-642`
  -> exit 4: no live lane lists any row file; 14 `unknown:` lanes record no
  files (c-146, c-292, c-324, c-461, c-463, c-490, c-506, c-509, c-535, c-538,
  c-812, c-924, c-927, all @`<box2>` — the spec 123 / 033 / 181 / r79 lanes the
  planner's brief lists). None of them touches a row file per the hub map; the
  plan's section 8 asks the holder for their `<box2>` worktree diffs (N1).
  With the plan file itself added to the call, exit 3 names only
  `csi-spl-doc/doc/md/bug-round-31-plan.md` owned by c-651@sat (the planner) —
  not a row file.
- Queue re-run (04:2xZ): `ENV=prd ./run -a do_spl_spawn_queue` -> 19 queued;
  grep of the 19 queued briefs for `review-notify|done-claim` -> 0 hits
  (the plan read 22 at 04:14:53Z; the queue moves, N2).

## Check 7 — inputs accounted

- Re-read `/var/spool-hub/dispatch/c002-next-round-candidates.md` (99 lines,
  `grep -nE '^## |next BUG round|Bug-shaped|bug-shaped'` -> its "next BUG
  round" and "Bug-shaped" entries) and `bug-round-30-plan.md` section 7 (its
  "first inputs for round 31" row, 11 items) on origin/master, plus the b30
  rows' R7 notes.
- Every "next BUG round" / "Bug-shaped" entry is either a row (c-001 7e965718
  bare `Author:` -> row 01; c-001 003e85a2 sha256 prefix -> row 02), served
  (`git log origin/master -E --grep=<key>`: b20-01 `2f634fbd4` for the
  review-go retired-author retry 0f130e27 — accounted in b27 plan
  `bug-round-27-plan.md:167`; b22-02 `3e46a758c`; b26-01 `c540aca24` for the
  SPL-5960 blog.test.mjs:329 alone-run — b27 plan v0.2 `ed9a9b831` records
  candidates line 34 (a)/(b) accounted and line 35 served; b27-01 `656ab3389`,
  b28-02 `4c4e97f75`; b29-01 `ac367b7a5`, b29-02 `ae4898ae1`; b30-01..03;
  `74bd535d8`), or accounted as not-a-row in the plan's sections 4 and 5
  (AltGr picker, blog switcher Enter, done-claim `job` label and c-533's no-sha
  note, review notice `wip/` branches 7717bbb1, lease vendor order 1a36d045,
  orc/iac suites as the agent OS user, /tmp worktrees and overlay mounts,
  b29-01 N1/N2/N6, SPL-6032 N2 topic-loop race, CI-first, SPL-6107 N1, spec 181
  notes, ws-docs-head). The 11-19 08:3xZ sub-items (a) c-091 salvage and
  (b) SPL-5613 stale base sit under the review-go heading, not under a
  "next BUG round"/"Bug-shaped" one, and are recorded accounted in b27 plan
  v0.2 (`ed9a9b831`).
- All 11 of b30 section 7's first inputs for round 31 appear in the plan's
  section 4 (job label, AltGr, blog switcher Enter, test-agent-name-shape:89,
  orc/iac suites as agent user, download iframe, workspace-doc-preamble,
  tasks/forward/multicast forms, b29-01 N1 renewal reading `same`, overlay
  mount, dashless /tmp trees). The b30 R7 notes (a728a1de, 298a5b95, e98cd4d3,
  022a9ae3, e442c7fb) all appear in the plan's section 5.
- No bug-shaped input is neither served nor accounted for.

## Check 8 — dist hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (03:4xZ and again before
  this commit) -> `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-642`, rc 0.

## Verdict

**PASS on `a370b578614753c566e2f92deb642883a02770bb` (v0.1), 2026-11-21T04:3xZ.**
Checks 1-8 all ran with the commands and outputs above; the two red controls
reproduce RED n=3 on the plan's base `325a47c76` for exactly the reasons the
plan gives, with their controls green and no live-state touch; every cited
file:line exists on the base and on origin/master with no drift; the rows are
within 5.1/5.3/5.4, R1-disjoint, R2-complete, claude/`simple_coding`/batch 1
with the claude waiver seat as R7 (grok pick=hold, re-run); no row file is
owned by a live lane; every bug-shaped input is served or accounted for; dist
hygiene clean.

### Defects

- none (no W).

### Notes

- N1: the 14 exit-4 `unknown:` lanes are on `<box2>`; their worktree diffs can
  only be read there. The plan's section 8 item 1 already asks the holder for
  them; this seat could not read `<box2>`'s worktrees from sat.
- N2: the queue count moved between the plan's read (22 queued, 04:14:53Z) and
  this seat's (19 queued, 04:2xZ); the grep of the queued briefs for
  `review-notify|done-claim` is 0 hits at both reads.
- N3: `origin/master` moved from the plan's base `325a47c76` to `986ddca84`
  (one docs commit) during this review; `git diff --name-only 325a47c76
  origin/master -- <the five row files>` is still empty, so no cited line
  drifted.
- N4: the plan's served list names b27-01/b28-02 for "review-go's loop", but
  the retired-author no-retry was b20-01 `2f634fbd4` (SPL-5953, accounted in
  b27 plan `bug-round-27-plan.md:167`); the input is served either way. Wording
  only.

## Panel verdict on v0.2 — PASS (2026-11-21T04:36Z)

- Reviewed sha: `78c13231e745887f3ca054a3f5f12039a9824451` on branch
  `review/c002-bug-round-31-planner`, named by the dispatch holder c-002@sat on
  task `dispatch-bug-r31` (msgs 9821047d 04:28Z, f9c3503b 04:35Z).
  `git ls-remote origin review/c002-bug-round-31-planner` ->
  `78c13231e745887f3ca054a3f5f12039a9824451` (the branch head, matches).
  `git merge-base --is-ancestor a370b5786 78c13231e` -> rc 0 (fast-forward);
  `git log --oneline a370b5786..78c13231e` -> one commit
  (`78c13231e docs(b31-plan, SPL-6136): ... v0.2 ...`);
  `git diff --name-only a370b5786 78c13231e` -> only
  `csi-spl-doc/doc/md/bug-round-31-plan.md`; `git diff --stat` -> 10
  insertions, 7 deletions. `git show 78c13231e:<plan> | sha256sum` ->
  `2e5085910948c55e234f318c694fb22094017804b0edc62e06d8030b3d2d8df7`.
- Delta review (`git diff a370b5786 78c13231e`, 61 lines): plan text only —
  the status line, section 3.1 (the exit-4 list corrected to 14 lanes with
  c-146, which v0.1 missed to a `tail` cut, plus the `<box2>` halves: 0 hits
  against the five row files in every one of the 14 lanes, b31 free on `<box2>`
  too), section 5 (c-533's result body read on `<box2>`: `sha: none`, so the
  no-sha note is a true verdict), section 8 (asked-of-holder answered, review
  history) and the consensus table. `diff` of the `## 3. The rows` ..
  `### 3.1` range between v0.1 and v0.2 -> identical (no row, site, red control
  or fix scope changed); the `One sha` base line is unchanged (`325a47c76`).
- Checks re-run on the v0.2 head (04:36Z): check 1 -> 0 `(b31-` commits since
  W; `git ls-remote origin | grep -E 'b31-[0-9]{2}|bug-round-31'` ->
  `review/c002-bug-round-31-planner` (78c13231e) and this seat's
  `review/c002-bug-round-31-mistral-seat` (e380f83fd), both expected; briefs ->
  the two expected. Check 2 -> `git diff --name-only 325a47c76 origin/master --
  <the five row files>` empty (no drift). Check 3 -> rc01/rc02 re-run on
  `325a47c76`, last lines `rc01 sha=325a47c76 wrong=1` / `rc02 sha=325a47c76
  wrong=2` (RED as before; exit 1 in the n=3 runs above). Check 6 ->
  `lane-map.sh --check <5 row files + seat file> --agent m-642` -> exit 4 with
  exactly 14 `unknown:` lanes (incl. c-146, matching the v0.2 corrected list),
  no row file owned. The `<box2>` worktree diffs quoted in the delta (c-001@
  `<box2>` msgs 977706b2, cfdfc6ed) are not readable from sat — NOT RUN here;
  the hub lane map from this seat's run shows those lanes record no files,
  consistent with the delta's 0 hits.
- Verdict on v0.2: **PASS**, no W. The delta changes no row, no site, no red
  control; it only folds in the other box's halves and corrects the exit-4
  count, which this seat's own lane-map run confirms (14 unknowns).
