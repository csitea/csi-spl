# Refactor round 83 — panel seat mistral (m-780@<box>)

Issue: SPL-6178 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-83-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/refactor-round-83-plan.md` on branch
`review/c002-refactor-round-83-planner`, at the v0.1 sha the dispatch holder named
(spool msg a9972069-406d-4150-8b92-b1c4f1447656, 2026-11-21T10:1xZ, task
`dispatch-refactor-r83`): `52681174d193bda93841007ef23a8c458651d917`.
`git ls-remote origin | grep round-83` ->
`52681174d193bda93841007ef23a8c458651d917  refs/heads/review/c002-refactor-round-83-planner`
(head matches; `git log -1 --format='%H %cI %s'` ->
`52681174d193bda93841007ef23a8c458651d917 2026-11-21T12:13:02+02:00 docs(r83-plan, SPL-6178): refactor round 83 plan v0.1, two rows: ...`).
Re-review target named by the dispatch holder c-002@<box> (spool msg
`0b5a423d-1251-4686-bde6-fae8e46c2b9f`, 2026-11-21T11:03:59Z, task `dispatch-refactor-r83`):
plan v0.2 head `46c97cac55805c0277f3bc4a8e097150697b3139` —
`git ls-remote origin review/c002-refactor-round-83-planner` ->
`46c97cac55805c0277f3bc4a8e097150697b3139  refs/heads/review/c002-refactor-round-83-planner`
(matches). Plan change since v0.1: `git diff 35a429979 46c97cac5 --
csi-spl-doc/doc/md/refactor-round-83-plan.md` -> 1 file, +37 -5 (commits `294e82f76`,
`46c97cac5`; the range `52681174d..46c97cac5` also holds the r82-01/r82-02 picks,
`git cherry` marks both `-`). Editor c-778@<box>. Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5
(3.2 the panel signs the plan sha; 5.1 1 to 3 rows; 5.3 numbering and window). Form:
`csi-spl-doc/doc/md/refactor-round-82-plan.md` and `refactor-round-82/seat-mistral.md`
(on origin/master). Measured base `eb7c8cc54` (the plan's own "One sha");
`origin/master` at my reads `31a976ffb` (`git log -1 --format='%H %cI %s' origin/master` ->
`31a976ffb... 2026-11-21T11:46:53+02:00 chore(cnf, SPL-6172): ...`). Every file:line
below was checked with `git show <sha>:<file> | sed -n <N>p` on both shas.

## Verdict

**FAIL** on `52681174d193bda93841007ef23a8c458651d917`. The 2 rows pass every row check
(1-6, 8): sites exist on base and trunk, both red controls fail for the plan's reason and
go green, behaviour is identical, lane map is clean, vendors are claude with waiver R7
seats. The defects are in the input accounting: W1 (section 7 misses refactor/doc-shaped
inputs the candidates file gained at 2026-11-21T10:12:19Z, 43 s before the plan's own
commit) and W2 (1.2's grep as written prints 0 lines, not the 6 it lists). Both are
one-line fixes for the editor's v1.0. Notes N1-N4 below.

### 1. Slug r83 unused since the plan's `Window: W=`

W recorded `2026-11-21T10:15:35+01:00`; its source verified:
`git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r82-plan'` ->
`0b6b9a1d98f04ebe16de02e17bf0899feafa866f 2026-11-21T10:15:35+01:00 docs(r82-plan, SPL-6166): ...`
— matches the plan's 1.1 exactly.

- `git log origin/master --since="$W" --oneline -E --grep='\(r83-' | wc -l` -> **0**; the
  same grep over all history (no `--since`) -> **0**. Control: `(r82-` since W -> **1**
  line (`0b6b9a1d9`, the r82 plan itself), so the read sees a used id.
- `git ls-remote origin | grep -E 'r83-[0-9]{2}|refactor-round-83'` -> one line:
  `52681174d...  refs/heads/review/c002-refactor-round-83-planner` (the planner's,
  expected; my seat branch is pushed after this read). The 5.3 pattern set
  `git ls-remote origin 'refs/heads/review/r83-*' 'refs/heads/wip/*r83*' 'refs/heads/*-r83-*' 'refs/heads/*refactor-round-83*'`
  -> the same one line.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r83-[0-9]{2}|refactor-round-83'` -> exactly
  the 2 expected files (`c002-refactor-round-83-planner.md`,
  `c002-refactor-round-83-mistral-panel-seat.md`); `ls /var/spool-hub/spawn-remote/briefs | grep ...`
  -> none (rc 1).
- `git ls-tree eb7c8cc54 csi-spl-doc/doc/md | grep -c refactor-round-83` -> **0**, so the
  plain plan name is right (rulebook 5.3 "Files").

### 2. Every site file:line of every row exists on the base sha and on origin/master

Every cited line printed with `git show eb7c8cc54:<file> | sed -n <N>p` and
`git show origin/master:<file> | sed -n <N>p`: all **SAME** on both shas, none empty.

- row 01 sites `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh`: `:192` the one caller
  (`_spl_desk_reply_check_args "$body" "$kind" "$to" "$task" "${files[@]}" || return 1`),
  `:542` the check's header comment, `:544` `_spl_desk_reply_check_args() {`, `:548` the
  spec 033 comment, `:549` the lazy source of `spool-env.inc.sh`, `:550`
  `spool_kind_in "result|reject|blocker|msg|$SPOOL_NOTE_KINDS" "$kind" || { do_log "FATAL DESK_KIND ..."; return 1; }`.
- row 01 test `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-kinds.sh`:
  `:56` the section-4 comment, `:57` the retyped `want="$(tr '|' '\n' <<<"result|reject|blocker|msg|$SPOOL_NOTE_KINDS" ...)"`.
- `csi-spl-orc/src/bash/run/spl-desk-post.func.sh:126` -> the post's own set
  `task|result|blocker|msg|$SPOOL_NOTE_KINDS` (a different set, as 2.1 says);
  `csi-spl-orc/src/bash/scripts/spl-desk-reply.sh:9` -> the usage `--kind` line.
- row 02 sites, all three `lib/bash/funcs/parse-metadata.func.sh` copies: `:7-8` the two
  `@example` lines (iac names `src/bash/run/tf-state-show.func.sh`; orc and utl name
  `src/bash/run/tf-030-import-existing-cloud-run.func.sh`), `:15`, `:90`, `:98`, `:105`
  the four `${1:?}` lines (left out, section 7).
- `csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh`: `:3-11` Purpose, `:33` the root-copy
  check (the run.sh loop's `done` is `:32`).
- `csi-spl-iac/src/bash/tests/comment-refs-exist.tst.sh`: `:220` site 3 (the 030 action's
  own file), `:228-231` site 4 (`pm=...`, the zip-jira-ticket check `:229`, the
  030-example check `:230-231`).
- Line counts on both shas: spl-desk-reply.func.sh 789, test-spool-kinds.sh 64,
  parse-metadata.func.sh 111 each, run-sh-parity.tst.sh 44, comment-refs-exist.tst.sh 261
  — all match the plan.
- Copies on base: `git show eb7c8cc54:<f> | md5sum` -> parse-metadata iac
  `e44bb21be1384cad75b5c2a7ef20dd4c`, orc = utl `200cca5d374171814c495c2c96013ec0`
  (2 distinct texts); `diff` iac vs orc -> **1 hunk `7,8c7,8`**, the two `@example` lines
  only. `git grep -nE 'result\|reject\|blocker\|msg' eb7c8cc54 -- csi-spl-orc/` -> **3
  lines** (func.sh:550, test:57, spl-desk-reply.sh:9); the set literal
  `result|reject|blocker|msg|$SPOOL_NOTE_KINDS` appears in orc src+lib in **2** files
  (func.sh:550, test:57) — matches section 6. `git show 3174e591a -- <test> | grep -c
  '^+.*result|reject|blocker|msg'` -> **1** (r81-01 added the copy).
- No action file name is common to all three modules' `src/bash/run/`: `comm -12` of the
  three listings filtered to `*.func.sh` -> **0** (the raw comm's 2 hits are `run.sh`,
  the framework, and the `help` dir — not actions).
- The module-neutral example works from each module root on base, n=1 each:
  `source lib/bash/funcs/parse-metadata.func.sh; do_parse_metadata "lib/bash/funcs/parse-metadata.func.sh" "param"`
  -> the two `param=` lines, rc 0, in iac, orc and utl.
- Drift: `git diff --name-only eb7c8cc54 origin/master -- <the 7 row paths + spool-env.inc.sh>`
  -> **empty** (rc 0); `git log origin/master --since="$W" -- <the 8 paths> | wc -l` -> **0**.

### 3. Red controls, run on the plan's base in a scratch copy

Scratch: `git archive eb7c8cc54 | tar -x -C /tmp/r83-base` + `git init` + `git add -A` +
one commit (a staged index, so `git grep`-based controls are not blind), run with
`SPOOL_TEST=1`; each test's `t_sandbox` (lib.inc.sh:40-55) sets its own `SPOOL_ROOT` under
`mktemp -d` and the guard refuses the live root under `SPOOL_TEST=1`. Nothing touched
`/var/spool-hub`. sha256sums at base (`git show eb7c8cc54:<f> | sha256sum`):

- `977881c85972cde3564b0d3fb8080908ddf03c2bd8298f2d5aa4332b82c2ca25  csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-kinds.sh`
- `f5f2ce79245ba1ea197541089bee2297380b36ed5e2a5c02a950d210d4036d29  csi-spl-orc/src/bash/run/spl-desk-reply.func.sh`
- `5a4786de38c2607a51ae3bd791eb52486a641fe22ef9cd0fee5fa6b6cc2b81bd  csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh`
- `80aa864ff6a35dd5b8aa5050a8473e781db8f9ed55960e98fed58af960afb8c9  csi-spl-iac/src/bash/tests/comment-refs-exist.tst.sh`
- `49f8f851bc75fbec628927d1f3a9cf4b277776b26d6079c136463dfc59a8c413  csi-spl-iac/lib/bash/funcs/parse-metadata.func.sh`
- `484df2c5acda22d4762f1f47530981c1ca2ffae5576005b72ae4a0565a7e0ce3  csi-spl-orc/lib/bash/funcs/parse-metadata.func.sh`
- `484df2c5acda22d4762f1f47530981c1ca2ffae5576005b72ae4a0565a7e0ce3  csi-spl-utl/lib/bash/funcs/parse-metadata.func.sh`

(run-sh-parity's sum matches the r82 panel's recorded sum for the same base file.)

Before (unmodified base, n=1): `SPOOL_TEST=1 bash .../test-spool-kinds.sh` -> rc **0**,
45 pass 0 fail (matches plan 1.5); `SPOOL_TEST=1 bash csi-spl-iac/src/bash/tests/desk-actions.tst.sh`
-> rc **0**, 294 pass 0 fail (spot check, matches 1.5).

- **Row 01, red control** (head's test-spool-kinds.sh — section 4 sources the reply
  action, takes `want` from `_spl_desk_reply_kinds`, +3 cases — copied into the unmodified
  base): rc **1**, last line `FAIL - ... 4 failed` (44 pass, 4 FAIL lines):
  `FAIL - 4. _spl_desk_reply_kinds is result, reject, blocker, msg and the note kinds (want 'result|reject|...', got '')`,
  `FAIL - 4. the reply set is written once, in _spl_desk_reply_kinds (want '1', got '0')`,
  and the two section-4 usage checks with `want ''`. It fails for exactly the plan's
  reason (the function does not exist on the parent, so `rk` is empty), not for an
  environment reason. **Green** (1.3's shape applied: `_spl_desk_reply_kinds` before
  `:542`, `:548` comment moved into its header, `:550` reads `"$(_spl_desk_reply_kinds)"`,
  file 789 -> 793 lines): rc **0**, 48 pass 0 fail, 10/10 section-4 lines ok.
  (Plan 1.5 says "43 pass, 4 FAIL" for the red; I measured 44 pass + 4 FAIL = 48 lines —
  the FAIL lines and rc match exactly; the pass-count difference is the summary-line
  counting, N3.)
- **Row 02, red control** (head's run-sh-parity.tst.sh — the `for h in validate-params
  parse-metadata` loop — copied into the parent = base + r82-02's validate-params loop
  and orc copy unified, parent run: rc 0, 8 pass): rc **1**, 7 pass, 3 FAIL lines:
  `FAIL: iac and orc parse-metadata.func.sh differ -- diff ...`,
  `FAIL: iac and utl parse-metadata.func.sh differ -- diff ...`, and the summary
  `FAIL: 2 assertion(s) in run-sh-parity.tst.sh`. Fails for the plan's reason (the copies
  differ on base), not an environment reason. **Green** (head = parent + the three
  copies' `:7-8` naming `lib/bash/funcs/parse-metadata.func.sh`, md5 of the three -> one
  value `4a1af2ec...`): rc **0**, 10 pass 0 fail, both parse-metadata `PASS` lines.
  `comment-refs-exist.tst.sh` on head (site 4 replaced with the module-neutral check):
  rc **0**, 21 pass 0 fail, `PASS: site 4 example is a real file (lib/bash/funcs/parse-metadata.func.sh)`.
  **Its control:** orc's example planted as `lib/bash/funcs/no-such.func.sh` on head:
  rc **1**, `FAIL: site 4 example is not a file of orc: 'lib/bash/funcs/no-such.func.sh'`
  (plus the scan's own FAIL and the summary).

### 4. Equivalence of each row

- **Row 01:** `spool_kind_in "$(_spl_desk_reply_kinds)" "$kind"` expands to the same string
  as the retyped literal (the `printf '%s\n'`'s trailing newline is stripped by `$(...)`).
  Measured on base and head, n=1: `_spl_desk_reply_check_args body <kind> "" ""` for the
  13 kinds plus `bogus` and `""` -> `task=1`, the 12 reply kinds `0`, `bogus=1`, empty
  `=1`; `cmp` of the two 15-line outputs -> **IDENTICAL**. The FATAL line for `bogus` on
  head reads as before: `FATAL DESK_KIND must be result, reject, blocker, msg or note,
  feature, bug, alert, question, idea, decision, docs, got: 'bogus'`. No exit code,
  message, path or default changes; the control (check 3) catches a difference.
- **Row 02:** `diff -U0` base vs head over the 3 libs | `grep -E '^[-+][^-+]' | grep -vcE
  '^[-+]\s*#'` -> **0** non-comment changed lines; only the two `@example` comment lines
  per copy change (`7,8c7,8`). The cmp loop catches any difference (the file's own
  planted-drift control proves `cmp -s` sees a one-byte change). No behaviour change.

### 5. Row fields (R2, R7, R1)

Each row has a control that fails today and passes after (check 3), a test list (plan
1.5), vendor **claude**, kind **simple_coding**, batches **1** (row 01) and **2, after
r82-02** (row 02). No mistral coding or testing row. R7 reviewer per row: a fresh
**claude waiver seat** (1a7c70da) — `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at
2026-11-21T10:29:29Z printed `pick=hold reason=waiting: grok weekly >= 95% or unknown
on <box>, <box> ...: queue the lane, spawn nothing` (same as the plan's 10:08:24Z read) —
cross-vendor or waiver, never mistral. R1: `comm -12` of row 01's file set
(spl-desk-reply.func.sh, test-spool-kinds.sh) and row 02's (3 parse-metadata copies,
run-sh-parity.tst.sh, comment-refs-exist.tst.sh) -> **0** shared files; batch 1 holds
row 01 alone.

### 6. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 8 paths, comma-separated> --agent m-780`
-> **exit 4**, 18 `unknown:` lanes: c-146, c-461 (s123-p05), c-463, c-490 (s033),
c-506, c-562, c-579 (wui), c-706, c-740 (s123-l3), c-744 (gct), c-745, c-747 (s190),
c-749 (wui notes), c-751 (r82-01), c-752 (r82-02), c-812, c-924, c-927 — the same 18 the
plan listed. Per path individually: exit 4 on all, no exit 3 — no live lane lists a row
path. `review/r82-02` (fetched, head `b8fab6fd3`) touches `run-sh-parity.tst.sh` — a
row-02 path — which is exactly why row 02 is batch 2 with
`SPAWN_AFTER=c002-r82-02-orc-validate-params-parity` (2.1); `review/r82-01` touches no
row path. The 7 spec 184 briefs in `/var/spool-hub/dispatch/briefs` name
`lib/spool-env.inc.sh` (L1, "two new functions only"), so row 01's choice to keep the set
in the reply action's own file is right. b33-01 (c-749 on this box) is done
(`d42ec95e8` on trunk). Spawn queue at 10:2xZ: 15 queued, 0 placing; share refactor 5 of
28 known live lanes, 17% (band 10-20%: ok).

### 7. Inputs accounted for

The candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md` is on this
box: `wc -l` -> **106** now, mtime 2026-11-21T10:12:19Z. The plan's 1.2 read it at
2026-11-21T09:46:46Z as **101 lines** and wrote "the file did not grow since the r82
panel's read" — that was true at 09:46:46Z but **false at the plan's own commit**
(2026-11-21T10:13:02Z, 43 s after the file grew). The new section "from SPL-6174"
(lines 102-106, added 10:12:19Z) carries refactor/doc-shaped items the plan neither
serves nor accounts for:

- line 104: `spl-lane-mix.func.sh` lines 46, 138, 402 and its test still say "agy has the
  final word" / "waits for an agy review", stale after owner 36b3ff7f — "Refactor/doc row
  once SPL-6174 lands". Verified on origin/master: `git grep -n 'agy has the final
  word\|waits for an agy review' origin/master -- csi-spl-orc/src/bash/run/spl-lane-mix.func.sh`
  -> 4 hits (`:46`, `:136`, `:138`, `:402`). Lane map on that path: exit 4, no owner.
- line 105: `workspace-rules.md:34`, spec 176's cite of `spawn-an-agent.md:61`, and the
  wf 10 job name still saying "agy language review" — doc rows, also unaccounted.

Served items re-verified on origin/master: candidates `:1` (watchdog/rotate `/var`
literals) — `git grep -n '/var/' origin/master -- spl-watchdog.func.sh spl-lane-rotate.func.sh reverse-tunnel-cron.sh`
outside comments -> none; `:25` reverse-tunnel-cron.sh:23 -> gone; `:48`
agent-boot-restore literal -> gone (r79-01 family, `75da57eb4`); `:29` wf10 comment
`:443-446` now says "only about 96 MB of it is left" (`75da57eb4`); `:76` SPL-6107 N1
served by r81-01 `3174e591a` (`spl-desk-reply.sh:9,19` now list all 12 kinds). `:74`
(`topic_loop_fire.go` `!inserted`) and `:94` (argmax s9 guard cases) stay in section 7 as
test rows, as the plan says. r82 section 7's items are carried by reference ("r82 7").

Row behaviour-change scan: neither row changes an exit code, a message, a path or a
default (check 4) — both are ONE logical refactor each, no bug row hidden in them.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean
over the tracked tree of /opt/csi/csi-spl-wt/m-780`, exit 0 (re-run after this file was
added: clean).

## Defects

- **W1 (plan 1.2 and section 7):** the candidates file grew 101 -> 106 lines at
  2026-11-21T10:12:19Z, 43 s before the plan's v0.1 commit (10:13:02Z), so the 1.2 claim
  "the file did not grow since the r82 panel's read" was already false when committed.
  The new lines 102-106 ("from SPL-6174") carry refactor/doc-shaped inputs —
  `spl-lane-mix.func.sh:46,138,402` + test stale agy text (line 104, verified present on
  origin/master, no lane owns the path) and the `workspace-rules.md:34` / spec 176 /
  wf10-job-name doc items (line 105) — that section 7 neither serves nor accounts for.
  Check 7 asks exactly for this: named here. Fix for v1.0: one section-7 row
  ("left out: the SPL-6174 follow-ups at candidates :104-105, gated on SPL-6174 landing,
  c-744 live").
- **W2 (plan 1.2):** the grep as written, `grep -niE 'refactor\|test-shaped\|N1' <file>`,
  prints **0** lines (with `-E`, `\|` is a literal pipe) — not the 6 lines (`:1`, `:25`,
  `:48`, `:74`, `:76`, `:94`) the plan lists as its output. The listed lines come from
  plain alternation `grep -niE 'refactor|test-shaped|N1'`, which today also matches
  `:104` (the W1 item). A command whose printed output is quoted as something else is a
  false ran-claim; fix the command or the output in v1.0.

## Notes

- **N1:** live state moved between the plan's reads and mine (all carry their own times):
  spawn queue 16 -> 15 queued; `review/r82-01` (`1b5724549`) and `review/r82-02`
  (`b8fab6fd3`) branches appeared after the plan's 2.2 scan — r82-02's touches
  `run-sh-parity.tst.sh`, accounted by the SPAWN_AFTER in 2.1; the share line refactor
  5/28 17% ok both times. The holder's re-check before placing is the one that counts.
- **N2:** row 01's red control pass count: plan 1.5 says "43 pass, 4 FAIL"; I measured
  44 pass + 4 FAIL (48 lines total, rc 1 both). The 4 FAIL lines and the rc match the
  plan exactly; only the pass-line count differs (summary-line counting).
- **N3:** the plan's 1.2 "did not grow" claim was true at its 09:46:46Z read (file mtime
  was then 2026-11-21T06:39Z, 101 lines — the same count the r82 panel read); the growth
  at 10:12:19Z is what W1 records. The plan's "Not re-checked item by item here" is
  honest about the method; the defect is that the claim was not re-checked before the
  10:13:02Z commit.
- **N4:** scratch copies need a staged git index (`git init` + `git add -A` + one
  commit) or `git grep`-based controls are blind on an empty index; with it staged, the
  base reads match the plan's 1.5 exactly (45 pass rc 0; 294 pass rc 0 spot check).

## Re-review: verdict on v0.2 `46c97cac55805c0277f3bc4a8e097150697b3139` — PASS

Read in full at the sha (`git show 46c97cac5:csi-spl-doc/doc/md/refactor-round-83-plan.md`
-> 428 lines). Base sha unchanged `eb7c8cc54`; `origin/master` at my reads `51de076f3`
(`git log -1 --format='%H %cI %s' origin/master` -> `51de076f3... 2026-11-21T12:5xZ+01:00
docs(b34-plan, SPL-6179): ...`). The v0.1 defects are fixed and I verified each fix
empirically:

- **W1 fixed.** Plan 1.2 re-reads the candidates file at 2026-11-21T10:44:36Z: `wc -l
  /var/spool-hub/dispatch/c002-next-round-candidates.md` -> **109**, `stat -c %y` ->
  `2026-11-21 12:43:31 +0200` (= 10:43:31Z, as the plan says). G1 as written, `grep -nE
  '[Rr]efactor|[Tt]est-shaped' <file>` -> **8 lines** `:1 :25 :48 :51 :74 :76 :104 :109` —
  exactly the plan's quoted output. `sed -n '101,109p'` -> `:101` bug-shaped (spec-version
  lane exit-clean), `:102` blank, `:103` heading "from SPL-6174", `:104` the
  spl-lane-mix stale-agy line, `:105` the workspace-rules/wf10 line, `:106` bug-shaped
  (SPL-6174 links t1), `:107` blank, `:108` heading "from SPL-6174 re-review", `:109` the
  gct-coverage N4 line — matching the plan's one-by-one accounting. Section 7 carries
  `:104` and `:105` with reasons (deferred, behaviour change, r84 candidate).
- **W2 fixed.** G1/G2 left the tables with their real output; G2 re-run by me:
  `git grep -nE 'final word|agy review|needs_agy_review' origin/master --
  csi-spl-orc/src/bash/run/spl-lane-mix.func.sh` -> **9 lines** `:46 :48 :136 :138 :392
  :401 :402 :411 :417` — matches the plan.
- **N2 fixed.** Plan 1.5's red row now says 44 pass / 4 FAIL; my run below measured
  exactly 44 pass + 4 FAIL, rc 1.

Checks 1-8 re-run on `46c97cac5` (command -> output):

1. Slug: `git log origin/master --since="$W" --oneline -E --grep='\(r83-' | wc -l` ->
   **0**; all history -> **0**. `git ls-remote origin | grep -E 'r83-[0-9]{2}|refactor-round-83'`
   -> exactly the 2 expected branches (planner `46c97cac5...`, my seat `6f09ce9ff...`).
   `ls /var/spool-hub/dispatch/briefs | grep -E 'r83-[0-9]{2}|refactor-round-83'` -> the
   2 expected files. `git ls-tree eb7c8cc54 csi-spl-doc/doc/md | grep -c refactor-round-83`
   -> **0**. W source: `git log -1 --format='%h %cI' 0b6b9a1d9` ->
   `0b6b9a1d9 2026-11-21T10:15:35+01:00` = the plan's W. Control `(r82-` since W ->
   **4** now (r82 rows landed since the plan's read; was 1 at 09:46Z) — the read still
   sees used ids (N1).
2. Sites: every cited line re-printed on `eb7c8cc54` via `git show <sha>:<f> | sed -n <N>p`:
   spl-desk-reply.func.sh `:192,:542,:544,:548,:550` (caller, header, def, spec-033
   comment, the `spool_kind_in "result|reject|blocker|msg|$SPOOL_NOTE_KINDS"` check),
   test-spool-kinds.sh `:56-57`, parse-metadata copies `:7-8` (iac names
   `tf-state-show.func.sh`, orc/utl name `tf-030-import-existing-cloud-run.func.sh`) and
   `:15,:90,:98,:105`, comment-refs-exist.tst.sh `:220,:228-231`, run-sh-parity.tst.sh
   base 44 lines. Line counts base/master: 789/789, 64/64, 111/111 x3, run-sh-parity
   **44/55**, comment-refs-exist 261/261, spool-env.inc.sh 1151/1151.
   `git diff --name-only eb7c8cc54 origin/master -- <the 7 row paths + spool-env.inc.sh>`
   -> **only** `csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh` (r82-02 landed,
   `17e8b2459`; master's copy has the validate-params loop — the drift the plan's
   `after: r82-02` covers). md5 at base: iac `e44bb21b...`, orc = utl `200cca5d...`
   (2 distinct texts, as the plan says).
3. Red controls, scratch `/tmp/r83v02/{base,head01,parent,head02}` (`git archive` +
   `git init` + one commit; `SPOOL_TEST=1`; hermetic — `t_sandbox` sets a mktemp
   `SPOOL_ROOT`, the guard refuses the live root; nothing touched `/var/spool-hub`).
   sha256 at base, unchanged from v0.1: test-spool-kinds `977881c8...`,
   spl-desk-reply.func.sh `f5f2ce79...`, run-sh-parity `5a4786de...`,
   comment-refs-exist `80aa864f...`, parse-metadata iac `49f8f851...`, orc = utl
   `484df2c5...`.
   - Row 01: base test on base -> rc **0**, 45 pass 0 fail, last line
     `-- test-spool-kinds.sh: 45 passed, 0 failed`. Head test on head (1.3's shape:
     `_spl_desk_reply_kinds` before `:542`, `:550` reads it, file 789 -> 793 lines;
     test section 4 sources the action, +3 cases) -> rc **0**, 48 pass 0 fail.
     **Red** (head's test copied into unmodified base) -> rc **1**, 44 pass 4 FAIL, last
     line `-- test-spool-kinds.sh: 44 passed, 4 failed`; FAIL lines:
     `4. _spl_desk_reply_kinds is ... (want 'result|reject|blocker|msg|note|...', got '')`,
     `4. the reply set is written once, in _spl_desk_reply_kinds (want '1', got '0')`,
     and the two section-4 usage checks with `want ''`. Fails for the plan's reason (the
     function is absent on base), not an environment reason.
   - Row 02: parent = `git archive origin/master` (carries r82-02's loop). **Red A**
     (head's run-sh-parity — `for h in validate-params parse-metadata` — on parent) ->
     rc **1**, 7 pass, 3 FAIL lines: `FAIL: iac and orc parse-metadata.func.sh differ`,
     `FAIL: iac and utl parse-metadata.func.sh differ`, `FAIL: 2 assertion(s) in
     run-sh-parity.tst.sh` (last line). **Green A** (head = parent + the 3 copies' `:7-8`
     naming `lib/bash/funcs/parse-metadata.func.sh`; md5 of the three -> one value
     `4a1af2ec...`) -> rc **0**, 10 pass 0 fail, last `PASS: all run-sh-parity.tst.sh
     assertions`. **Green B** (comment-refs-exist site 4 replaced with the module-neutral
     check, on head) -> rc **0**, 21 pass 0 fail, `PASS: site 4 example is a real file
     (lib/bash/funcs/parse-metadata.func.sh)`. **Red B** (orc's example planted as
     `lib/bash/funcs/no-such.func.sh` on head) -> rc **1**,
     `FAIL: site 4 example is not a file of orc: 'lib/bash/funcs/no-such.func.sh'` plus
     the scan's own 2 dangling-ref FAILs and the summary.
4. Equivalence: row 01, 15-kind probe (`_spl_desk_reply_check_args body <kind> "" ""`,
   `SPOOL_NOTE_KINDS` unset, framework funcs stubbed) on base and head -> `cmp` of the
   two outputs **IDENTICAL** (`task=1`, the 12 reply kinds `0`, `bogus=1`, empty `=1`);
   the FATAL line for `bogus` on head reads as before (`FATAL DESK_KIND must be result,
   reject, blocker, msg or note, feature, ..., got: 'bogus'`). Row 02: the plan's
   comment-only command `git diff -U0 -- <3 libs> | grep -E '^[-+][^-+]' | grep -vcE
   '^[-+]\s*#'` -> **0**; the module-neutral example runs rc 0 from each module root
   (the two `param=` lines, iac/orc/utl). No exit code, message, path or default changes
   in either row; the controls catch a difference (check 3).
5. Row fields: both rows vendor **claude**, kind **simple_coding**, batches **1** (row 01)
   and **2, after r82-02** (row 02); each has a fail-today/pass-after control (check 3)
   and a test list (1.5). No mistral coding or testing row. R7: `BOX_PICK_KIND=grok
   ./run -a do_spl_box_pick` re-run now -> `pick=hold reason=waiting: grok weekly >= 95%
   or unknown on <box>, <box> ...: queue the lane, spawn nothing` (same as the plan's
   10:08:24Z read) -> each row takes a fresh **claude waiver seat** (1a7c70da), never
   mistral. R1: row 01's and row 02's file sets share **0** files; one row per batch.
6. R3 lane map: `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
   --check <the 7 row paths, comma-separated> --agent m-780` -> **exit 3**:
   `csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh` owned by `c-778@<box>`
   (c-778-c002-refactor-round-83-planner) and `m-785@<box>`
   (m-785-c002-bug-round-34-mistral-panel-seat), both "changed in its worktree; no files
   recorded"; the other 6 row paths print nothing (free). Both owners are planner/panel
   seats whose branches carry the r82-02 pick; row 02's `after: r82-02` covers the file
   and r82-02 has now landed on master (N3).
7. Inputs: G1's 8 lines all accounted — `:1/:25/:48` literal paths (r82 panel N4:
   `git show origin/master:csi-spl-doc/doc/md/refactor-round-82/seat-mistral.md` N4
   "every refactor-shaped item ... served or accounted for"), `:51` bug-shaped, `:74`
   test row (section 7), `:76` served by r81-01 `3174e591a`, `:104/:105` deferred in
   section 7, `:109` not refactor by its own text. Section 7's measurements re-run:
   `git grep -n 'spawn-an-agent.md' origin/master -- csi-spl-doc/doc/md/workspace-rules.md`
   -> `:33`; `git grep -n 'agy language review' origin/master -- .github/workflows` ->
   `:2029`, `:2043`; r82 plan section 7 exists (`git show origin/master:...82-plan.md |
   grep -n '^## 7'` -> `:381`). `git log origin/master --grep='SPL-6174' | wc -l` ->
   **4** now (`c081de61a`, `4d95cd4c3`, `197c8ac6d`, `63ff3e425` — landed after the plan's
   10:37Z read of 0; N2). The deferral still holds: `spl-lane-mix.func.sh` still carries
   the 9 agy lines (G2 above), the global rule asset
   `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/20-spawn-an-agent.md:41`
   now says gct "replaces the agy final word", and renaming the flag changes
   `do_spl_lane_mix`'s output — a behaviour change, not a refactor row. No
   refactor-shaped input is left unserved and unaccounted.
8. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene:
   clean over the tracked tree of /opt/csi/csi-spl-wt/m-780`, exit 0.

**Defects on v0.2: none.** W1, W2 and the N2 count from the v0.1 FAIL are fixed and
verified above.

**Notes on v0.2:**

- **N1:** live drift since the plan's reads: `origin/master` `31a976ffb` -> `51de076f3`;
  r82-01/r82-02 landed (`714df2994`, `17e8b2459` per `0e7b783c7`'s message);
  run-sh-parity.tst.sh 44 -> 55 lines (the only row-file drift, covered by `after:
  r82-02`); the W-derivation `git log -1 ... --grep='^docs\(r82-plan'` now returns
  `0e7b783c7` (2026-11-21T11:50:02+01:00, the r82 "round closed" commit) — W itself is
  unchanged (`0b6b9a1d9` = 10:15:35+01:00).
- **N2:** SPL-6174 has landed (4 commits) since the plan's 10:37Z read; section 7's
  "`git log origin/master --grep='SPL-6174'` -> 0 at 10:37Z" is time-stamped and was true
  then. `:104`/`:105` are now live candidates for r84 / SPL-6174's follow-up lane,
  exactly as the plan defers them.
- **N3:** lane-map exit is 3 (not 4) now: run-sh-parity.tst.sh is changed in
  c-778@<box>'s and m-785@<box>'s worktrees with no files recorded — both are
  planner/panel seats carrying the r82-02 pick, not row lanes; no live lane lists any of
  the other 6 row paths.
- **N4:** the red controls are hermetic as in v0.1 (`SPOOL_TEST=1`, `t_sandbox` mktemp
  `SPOOL_ROOT`, `spool_test_guard` refuses the live root); the scratch copies needed
  `git init` + one commit or `git grep`-based controls are blind on an empty index.

## State history

- 2026-11-21T10:3xZ commit `6f09ce9ff` on `review/c002-refactor-round-83-mistral-seat`:
  full review of `52681174d193bda93841007ef23a8c458651d917` (checks 1-8 above), verdict
  FAIL, W1-W2, N1-N4.
- 2026-11-21T11:xxZ commit on `review/c002-refactor-round-83-mistral-seat`: re-review of
  v0.2 `46c97cac55805c0277f3bc4a8e097150697b3139` (section above), verdict **PASS**, no
  W, N1-N4.

Seed STEP 0: `cd csi-spl-orc && sudo -u <push user> env AGENT_ID=m-780 DEV_GUIDE_ACK=yes
./run -a do_dev_guide_ack` -> `ACK m-780 read developer-guide.md blob 8b1916cdc...`.
Read whole this session: `CLAUDE.md`, `csi-spl-doc/doc/help/how-to-post.md`,
`csi-spl-doc/doc/md/developer-guide.md`, `csi-spl-doc/doc/md/rounds-rulebook.md`
(sections 1-5), the plan at `52681174d` (via `git show <sha>:csi-spl-doc/doc/md/refactor-round-83-plan.md`),
`refactor-round-82-plan.md` and `refactor-round-82/seat-mistral.md` (origin/master, the
form), `/var/spool-hub/dispatch/c002-next-round-candidates.md`, both r83 briefs, and the
row site and test files at `eb7c8cc54` via `git show` / `git grep`.
