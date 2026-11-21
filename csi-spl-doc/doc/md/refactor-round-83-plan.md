# Refactoring round 83 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6178  
Topic: b78ef261-3c6b-4075-877d-5a1b99c69537  
Discussion: b78ef261-3c6b-4075-877d-5a1b99c69537 (t1 #refactoring, "Refactor round 83", opener msg a656e48c)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r83**, plan `refactor-round-83-plan.md`, rows `r83-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 82 ([refactor-round-82-plan.md](refactor-round-82-plan.md),
v1.0 `0b6b9a1d9`) is still open: r82-01 (c-751) and r82-02 (c-752) build on the other box,
neither on trunk (1.1). This round does not wait for r82-01 and stays off its files; its
row 02 edits r82-02's test file and therefore places only after r82-02 lands (2.1). The
perf floor (rulebook 4.4), the holder's read on `80c5eed0d`:
`perf 29 refactor 108 perf-share 21.2% floor-met`, so this is a refactor round.

**Row 01** gives the reply action's kind set one copy: today it is written twice, in the
check of `spl-desk-reply.func.sh` and again in `test-spool-kinds.sh` (r82 section 7, first
candidate (a)). **Row 02** makes the three `parse-metadata.func.sh` copies one text (their
`@example` lines name a different module's action) and pins them in
`run-sh-parity.tst.sh` beside r82-02's `validate-params` loop (r82 section 7, first
candidate (b)).

**Status: v1.0.** The panel sent v0.1 `52681174d` back (m-780@sat FAIL, W1 W2) and passed
v0.2 `46c97cac5` with no W (m-780@sat, mistral; seat file
`csi-spl-doc/doc/md/refactor-round-83/seat-mistral.md`, folded in from `85d68ca9e`). The
holder's GO: c-002@sat msg 40c1752f, its `do_spl_review_line_check` rc 0 (OK 2 of 2).
Section 8. Editor: **c-778** (claude).

**One sha:** every count is measured on **`eb7c8cc54`** (`origin/master` at
2026-11-21T09:46:46Z), n=1 per command unless stated. Reads are on that sha with
`git show` / `git grep`. **Every test named below was RUN** on scratch copies of that sha
(`git archive eb7c8cc54`, then `git init` + one commit, so the tests that need a git tree
have one): "base" is the copy unmodified; "head" is a copy with the row's change applied in
1.3's / 1.4's shape; the red controls copy only the head's test file into the base (row
01) or the row's parent (row 02). Nothing of it is committed. `origin/master` moved to
`31a976ffb` during the reads; no row file changed
(`git diff --name-only eb7c8cc54 31a976ffb -- <the 7 row paths and spool-env.inc.sh>` ->
empty). Queue, lane map, brief and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-21T10:15:35+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r82-plan'` -> commit
  `0b6b9a1d9` "refactor round 82 plan v1.0 records the panel's v0.1 PASS ...". Every later
  read of r83 uses this W.
- **`r83` is free** (2026-11-21T09:46:46Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r83-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r83-*' 'refs/heads/wip/*r83*' 'refs/heads/*-r83-*' 'refs/heads/*refactor-round-83*'`
    -> **nothing**. This planner's review branch is pushed after that read.
  - `grep -rlE 'r83-[0-9]{2}|refactor-round-83' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
    (as root) on this lane's box -> **2 files**: this planner's brief and the panel seat's
    (`c002-refactor-round-83-mistral-panel-seat.md`).
  - Control: the same log read with `(r82-` since W -> 1 line (`0b6b9a1d9`, the r82 plan
    itself), so the read sees a used id.
- **No `refactor-round-83*` file** exists under `csi-spl-doc/doc/md` on `eb7c8cc54`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-83` -> 0), so the plan takes the
  plain name (5.3 "Files").
- **r82 on trunk:** `git log eb7c8cc54 --since="$W" -E --grep='\(r82-'` -> the plan only;
  no r82 row has landed. `git ls-remote origin 'refs/heads/review/r82-*'` -> nothing yet.

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`, `utl:` = `csi-spl-utl/`; `lib:` =
`lib/bash/funcs/`, `tests:` = `src/bash/tests/`, `sa:` = `orc:src/bash/features/spawn-agents/`.

| input | source | on `eb7c8cc54` | here |
|---|---|---|---|
| (a) the reply-kind set `result\|reject\|blocker\|msg\|$SPOOL_NOTE_KINDS` written twice | r82 section 7, "first candidate for r83" | `git grep -nE 'result\|reject\|blocker\|msg' eb7c8cc54 -- csi-spl-orc/` -> 3 lines: `orc:src/bash/run/spl-desk-reply.func.sh:550` (the check), `sa:tests/test-spool-kinds.sh:57` (the copy, added by r81-01 `3174e591a`), `orc:src/bash/scripts/spl-desk-reply.sh:9` (the usage text, another order, which section 4 of the test already reads) | **row 01**, but NOT in `spool-env.inc.sh` as r82 suggested: the six queued spec 184 rows name that file as L1's (2.2). The set gets its one home in the reply action's own file |
| (b) `parse-metadata.func.sh`, 3 copies | r82 section 7, "first candidate for r83" | 111 lines each; `md5sum` orc = utl, iac differs; `diff iac orc` -> **1 hunk, `:7-8`**, the two `@example` lines (iac names `src/bash/run/tf-state-show.func.sh`, an iac-only action; orc and utl name `src/bash/run/tf-030-import-existing-cloud-run.func.sh`, an orc-only action, so utl's example names no file of utl). No action file name is in all three modules' `src/bash/run/` (`comm -12` of the three listings -> 0) | **row 02**, with a module-neutral example that is a real file of every module (1.4); `after: r82-02` |
| the Cloud Translation lane c-744 | the brief | its brief lists `iac:src/bash/run/check-pre-push-lang-review.func.sh`, its test, `csi-spl-doc/doc/md/pre-push-gate.md`, `fleet-rules-index.md` and the spawn-an-agent CLAUDE.md asset: no row path, not `spool-env.inc.sh` (2.2) | free of c-744 |
| r82-01 / r82-02 R7 notes | the brief | neither row landed (1.1), so no review line exists yet | nothing to take yet; the r83 editor reads them when they land |
| r82 panel N1-N4 (seat file `csi-spl-doc/doc/md/refactor-round-82/seat-mistral.md`) | the brief | N1 row 01's empty-argument path, N2 three citations, N3 live-state drift, N4 the candidates file and a `git init` copy: all folded into r82 v1.0 (r82 section 8), none names a new site | nothing to take |
| the candidates file (`<spool>/dispatch/c002-next-round-candidates.md`) | the brief | on this box, re-read for v0.2 at 2026-11-21T10:44:36Z: **109 lines** (`wc -l`; mtime 10:43:31Z). v0.1 read 101 lines at 09:46:46Z; lines 102-106 (SPL-6174's follow-ups, c-744; mtime 10:12:19Z, panel W1) and 107-109 (SPL-6174's re-review, c-002) came after that read. Grep G1 below -> **8 lines**: `:1`, `:25`, `:48` (literal paths, accounted for by the r82 panel, N4), `:51` (a bug-shaped item that names a refactor round), `:74` (the `!inserted` test), `:76` (served: r81-01 `3174e591a`), `:104` (new), `:109` (new; it matches only as "not refactor"). Lines 101-109 one by one: `:101` and `:106` bug-shaped (bug rounds'); `:103` and `:108` headings, `:102` and `:107` blank; `:104` and `:105` deferred (section 7); `:109` feature- or bug-shaped by its own text (the gct check covers only the WUI locale files), not a refactor | nothing taken: `:74`, `:104` and `:105` recorded in section 7 |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0 | left out (section 7), r65 to r82's reasons hold |

The two greps the table and section 7 cite, as run (a table cell would have to escape
the `|`, which is how v0.1's pattern broke, W2):

- G1, the candidates file (10:44:36Z): `grep -nE '[Rr]efactor|[Tt]est-shaped' <spool>/dispatch/c002-next-round-candidates.md`
  -> 8 lines, `:1 :25 :48 :51 :74 :76 :104 :109`.
- G2, the lane-mix text (origin/master `17e8b2459`): `git grep -nE 'final word|agy review|needs_agy_review' origin/master -- csi-spl-orc/src/bash/run/spl-lane-mix.func.sh`
  -> 9 lines, `:46 :48 :136 :138 :392 :401 :402 :411 :417`.

### 1.3 Row 01's sites: the reply-kind set

`orc:src/bash/run/spl-desk-reply.func.sh` (789 lines), `_spl_desk_reply_check_args`
(`:544`, called once, `:192`):

```text
:548   # spec 033 K.3 E3 (owner Q4 B): today's kinds plus the ones that route as a note
:549   { [[ -n "${SPOOL_NOTE_KINDS:-}" ]] && declare -F spool_kind_in >/dev/null; } || source ".../spool-env.inc.sh"
:550   spool_kind_in "result|reject|blocker|msg|$SPOOL_NOTE_KINDS" "$kind" || { do_log "FATAL DESK_KIND must be ..."; return 1; }
```

and `sa:tests/test-spool-kinds.sh` (64 lines), section 4:

```text
:56   # want = the set do_spl_desk_reply checks (spl-desk-reply.func.sh, spool_kind_in).
:57   want="$(tr '|' '\n' <<<"result|reject|blocker|msg|$SPOOL_NOTE_KINDS" | sort -u | paste -sd' ')"
```

**What is wrong.** The test's `want` is the action's set retyped. A kind added to the
action and not to the test (or the reverse) makes section 4 compare the usage text with
the wrong set, and nothing says the two copies are one fact. r81-01 (`3174e591a`) added
section 4 with this copy (`git show 3174e591a -- <test> | grep -c '^+.*result|reject|blocker|msg'` -> 1).

**Why not `spool-env.inc.sh`.** r82 section 7 proposed a `SPOOL_REPLY_KINDS` there. That
file is the L1 file of spec 184: six queued rows (2.2) name `sa:lib/spool-env.inc.sh`
(`c002-s184-l1-resolver-and-model-args`: "two new functions only"). R3 keeps this round
off a queued lane's file, and the set has one reader, the reply action, so it lives there.
(That shape was measured too: green 47, red 4 FAIL; not taken.)

**The shape:**

```text
# _spl_desk_reply_kinds: the |-joined kinds do_spl_desk_reply takes, today's
# plus the ones that route as a note (spec 033 K.3 E3, owner Q4 B). The one
# copy of the set: tests/test-spool-kinds.sh reads it from here.
_spl_desk_reply_kinds() { printf '%s\n' "result|reject|blocker|msg|$SPOOL_NOTE_KINDS"; }
```

before `:542`, and `:550` checks `spool_kind_in "$(_spl_desk_reply_kinds)" "$kind"`; the
`:548` comment moves into the new function's header; `:549` (the lazy source) and the
FATAL text are unchanged. The file 789 -> 793 lines (`wc -l` of the head);
`_spl_desk_reply_check_args` 1 line shorter. The set keeps the unbraced
`$SPOOL_NOTE_KINDS` spelling: the test greps for it.

**The test.** Section 4 of `test-spool-kinds.sh` sources the reply action
(`. "$T_REPO/csi-spl-orc/src/bash/run/spl-desk-reply.func.sh"`: it defines functions only;
every other top-level line is inside a heredoc), takes `want` from
`_spl_desk_reply_kinds`, and gains three cases:

```text
rk="$(declare -F _spl_desk_reply_kinds >/dev/null && _spl_desk_reply_kinds)"
eq "4. _spl_desk_reply_kinds is result, reject, blocker, msg and the note kinds" "result|reject|blocker|msg|${SPOOL_NOTE_KINDS}" "$rk"
lit='result|reject|blocker|msg|$SPOOL''_NOTE_KINDS'
eq "4. the reply set is written once, in _spl_desk_reply_kinds" 1 "$(grep -rhF -- "$lit" <orc src> <orc lib> | grep -c '_spl_desk_reply_kinds() {')"
eq "4. ...and nowhere else" 1 "$(grep -rhF -- "$lit" <orc src> <orc lib> | wc -l)"
want="$(tr '|' '\n' <<<"$rk" | sort -u | paste -sd' ')"
```

(the lane may word it otherwise; the three checks stay, and the test's own expected value
keeps the braced `${SPOOL_NOTE_KINDS}` so its own grep does not count it).

**Behaviour.** Measured on base and head, n=1: `_spl_desk_reply_check_args body <kind>`
with `SPOOL_NOTE_KINDS` unset (so the lazy source runs) for the 13 kinds plus `bogus` and
`""` -> the same 15 codes on both (`task=1`, the 12 reply kinds `0`, `bogus=1`,
`empty=1`; `cmp` of the two outputs -> equal), and the FATAL line for `bogus` reads as
before (`FATAL DESK_KIND must be result, reject, blocker, msg or note, feature, ..., got: 'bogus'`).

### 1.4 Row 02's sites: the three `parse-metadata.func.sh` copies

`iac:`, `orc:`, `utl:lib/parse-metadata.func.sh` (111 lines each). `:7-8`:

```text
iac      # @example do_parse_metadata "src/bash/run/tf-state-show.func.sh"
         # @example do_parse_metadata "src/bash/run/tf-state-show.func.sh" "param"
orc, utl # @example do_parse_metadata "src/bash/run/tf-030-import-existing-cloud-run.func.sh"
         # @example do_parse_metadata "src/bash/run/tf-030-import-existing-cloud-run.func.sh" "param"
```

**The change:** in all three copies the two lines name
`lib/bash/funcs/parse-metadata.func.sh`, the file itself: it is in every module and its
header carries the tags the function reads. Measured from each module's root, n=1 each:
`source lib/bash/funcs/parse-metadata.func.sh; do_parse_metadata "lib/bash/funcs/parse-metadata.func.sh" "param"`
-> the two `param=` lines, rc 0, in iac, orc and utl. Afterwards `md5sum` of the three ->
one value. Comment lines only.

**The tests.**

- `iac:tests/run-sh-parity.tst.sh` (44 lines on `eb7c8cc54`): r82-02 adds a `cmp` loop of
  the `validate-params.func.sh` copies before `:33` (r82 1.4). This row turns that loop
  into `for h in validate-params parse-metadata; do ... "$h.func.sh" ...; done` and names
  `parse-metadata.func.sh` in the Purpose header (`:3-11`). **It edits r82-02's file, so it
  starts from an origin/master that carries r82-02 and re-reads the loop there.**
- `iac:tests/comment-refs-exist.tst.sh` (261 lines) `:228-231`, "site 4", asserts that
  orc's example is the 030 action (`grep -q 'src/bash/run/tf-030-import-existing-cloud-run.func.sh' "$pm"`):
  it would fail on the new text. The row replaces `:230-231` with a module-neutral check:
  ```text
  ex=$(sed -nE 's/^# @example do_parse_metadata "([^"]+)"$/\1/p' "$pm")
  [[ -n "$ex" && -f "$APP_ROOT/csi-spl-orc/$ex" ]] \
    && pass "site 4 example is a real file ($ex)" || fail "site 4 example is not a file of orc: '$ex'"
  ```
  `:229` (no `zip-jira-ticket`) stays. The file's comment scan accepts the new name:
  `parse-metadata.func.sh` is tracked.

**The tests that name the site** (R2): `git grep -lE 'parse-metadata\.func|do_parse_metadata'`
over the three modules' tests -> `iac:tests/action-header-tags.tst.sh`,
`comment-refs-exist.tst.sh`, `param-required.tst.sh` (run by each module's own, so all
three), `run-lazy-loader.tst.sh`, `run-log-nofork.tst.sh`, `run-top-pad.tst.sh`,
`orc:tests/asks.tst.sh`, `parse-metadata-nofork.tst.sh`, `run-root-dispatch.tst.sh`, plus
`run-sh-parity.tst.sh` (the pin). `git grep -nE 'tf-state-show\.func\.sh|tf-030-import-existing-cloud-run\.func\.sh'`
over the tests -> `comment-refs-exist.tst.sh:220,230` (`:220` is site 3, about the 030
action's own file, unchanged), `gcp-tf-shared-bodies.tst.sh:55` and
`tf-030-import-existing-cloud-run.tst.sh:147` (each the action file itself, not the
example): no other test reads the example text.

### 1.5 Before and on the row's head

2026-11-21T09:5xZ-10:0xZ, n=1, `SPOOL_TEST=1`; pass lines `grep -ciE '^ *(ok|pass)'`,
fail lines `grep -ciE '^ *(not ok|fail)'` (a final summary line counts as one). Row 01:
"before" = base, "head" = base + 1.3. Row 02: its parent is a copy of base with r82-01's
and r82-02's planned shapes applied (r82 1.3, 1.4), committed; "head" = that + 1.4.

| suite | row | before rc / pass | head rc / pass / fail | note |
|---|---|---|---|---|
| `sa:tests/test-spool-kinds.sh` | 01 | 0 / 45 | 0 / 48 / 0 | +3, section 4. **Red:** head's test on base: rc 1, 44 pass, 4 FAIL: `_spl_desk_reply_kinds is ... (want 'result\|reject\|...', got '')`, `the reply set is written once, in _spl_desk_reply_kinds (want '1', got '0')`, and the two section 4 usage checks (`want ''`) |
| `orc:tests/desk-actions.tst.sh` | 01 | 0 / 294 | 0 / 294 / 0 | `:288` checks that the reply takes each good kind |
| `orc:tests/spl-review-go.tst.sh` | 01 | 0 / 184 | 0 / 184 / 0 | |
| `orc:tests/spl-take-auto.tst.sh` | 01 | 0 / 83 | 0 / 83 / 0 | |
| `orc:tests/wd-situations.tst.sh` | 01 | 0 / 324 | 0 / 324 / 0 | |
| `orc:tests/desk-reply-human-to-human.tst.sh` | 01 | 0 / 18 | 0 / 18 / 0 | |
| `orc:tests/desk-reply-sha-on-master.tst.sh` | 01 | 0 / 11 | 0 / 11 / 0 | |
| `orc:tests/spl-desk-reply-ref.tst.sh` | 01 | 0 / 9 | 0 / 9 / 0 | |
| `iac:tests/run-sh-parity.tst.sh` | 02 | 0 / 8 (parent, r82-02's loop in) | 0 / 10 / 0 | +2. **Red:** head's test on the parent: rc 1, 7 pass, 3 FAIL lines (`iac and orc parse-metadata.func.sh differ`, `iac and utl ...`, the summary) |
| `iac:tests/comment-refs-exist.tst.sh` | 02 | 0 / 21 | 0 / 21 / 0 | The new site 4 check also passes on the parent (030 is a real orc file): it generalises the old check and is not this row's red. **Its control:** orc's example planted as `lib/bash/funcs/no-such.func.sh` on head: rc 1, `FAIL: site 4 example is not a file of orc: '...no-such.func.sh'` (and the scan's own `FAIL ... no-such.func.sh`) |
| `iac:`, `orc:`, `utl:tests/param-required.tst.sh` | 02 | 0 / 17 each | 0 / 17 / 0 each | |
| `iac:tests/action-header-tags.tst.sh` | 02 | 0 / 6 | 0 / 6 / 0 | |
| `iac:tests/run-lazy-loader.tst.sh` | 02 | 0 / 30 | 0 / 30 / 0 | |
| `iac:tests/run-log-nofork.tst.sh` | 02 | 0 / 22 | 0 / 22 / 0 | |
| `iac:tests/run-top-pad.tst.sh` | 02 | 0 / 19 | 0 / 19 / 0 | |
| `orc:tests/asks.tst.sh` | 02 | 0 / 103 | 0 / 103 / 0 | |
| `orc:tests/parse-metadata-nofork.tst.sh` | 02 | 0 / 15 | 0 / 15 / 0 | |
| `orc:tests/run-root-dispatch.tst.sh` | 02 | 0 / 15 | 0 / 15 / 0 | |
| `iac:tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 | 0 / 15 / 0 (each row's head) | |

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r83-01-orc-desk-reply-kinds-one-copy)` | one fact, one copy (developer guide 2.2.4) | the reply action's kind set is retyped in its test, so the two can drift unseen (1.3); r82 section 7's first candidate (a) | `orc:src/bash/run/spl-desk-reply.func.sh:542,548,550`<br>`orc:src/bash/features/spawn-agents/tests/test-spool-kinds.sh:56-57` | 2 copies -> 1 | `_spl_desk_reply_kinds` before `:542`; `:550` reads it (1.3). Section 4 of the test sources the action and takes `want` from it, + 3 cases. **Red control:** head's test on the parent FAILs 4 (1.5), then GREEN (48); outputs in the body. **Behaviour:** 1.3's 15-kind probe equal on parent and head; the 7 suites of 1.5 as on the parent. Tests: `test-spool-kinds.sh`, `desk-actions.tst.sh`, `spl-review-go.tst.sh`, `spl-take-auto.tst.sh`, `wd-situations.tst.sh`, `desk-reply-human-to-human.tst.sh`, `desk-reply-sha-on-master.tst.sh`, `spl-desk-reply-ref.tst.sh`, `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r83-02-parse-metadata-one-text)` | one helper, one text (the `run.sh` parity of SPL-2756, r82-02's loop) | the three copies differ in their `@example` lines, each naming a file another module lacks; nothing pins the copies (1.4); r82 section 7's first candidate (b) | `iac:lib/bash/funcs/parse-metadata.func.sh:7-8`<br>`orc:lib/bash/funcs/parse-metadata.func.sh:7-8`<br>`utl:lib/bash/funcs/parse-metadata.func.sh:7-8`<br>`iac:src/bash/tests/run-sh-parity.tst.sh` (r82-02's loop, Purpose header)<br>`iac:src/bash/tests/comment-refs-exist.tst.sh:230-231` | 3 copies, 2 md5s -> 1 | The 6 lines name `lib/bash/funcs/parse-metadata.func.sh` (`md5sum` of the copies -> one value). r82-02's `cmp` loop takes `parse-metadata` too; site 4 of `comment-refs-exist.tst.sh` checks the example is a file of orc (1.4). **Red control:** head's `run-sh-parity.tst.sh` on the parent FAILs 2 (1.5), then GREEN (10); the planted `no-such` example FAILs site 4; outputs in the body. **Behaviour:** comment lines only (`git diff -U0 -- <3 libs> \| grep -E '^[-+][^-+]' \| grep -vcE '^[-+]\s*#'` -> 0). Tests: the 13 suites of 1.5's row 02 lines (in the worktree, `SPOOL_TEST=1`), `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 2 (after r82-02) |

**Re-measure first:** each row lane re-runs its site reads (row 01's `:542-550` and the
test's `:56-57`; row 02's `diff` of the copies and r82-02's loop as landed) on the
`origin/master` it starts from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r83-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r83-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 moves a set into a named function and changes no kind the action takes
(1.3's probe); row 02 changes comment lines and tests only. Each: `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: row 01.** Its two files are on no other row, live lane or queued row (2.2).
- **Batch 2: row 02, `after: r82-02`** (`SPAWN_AFTER=c002-r82-02-orc-validate-params-parity`).
  It edits `run-sh-parity.tst.sh`, r82-02's file, and extends the loop r82-02 adds; it is
  never placed while r82-02 is unlanded (R16: within 30 minutes of r82-02's land). Its
  other four files are free now.
- No row edits `sa:lib/spool-env.inc.sh` (spec 184 L1, queued),
  `orc:src/bash/scripts/spl-desk-reply.sh` (its usage text, r81-01's), any
  `validate-params.func.sh` (r82-02), any `gcp-account-pin.func.sh` or
  `gcloud-account-pinned.tst.sh` (r82-01), the `${1:?}` lines of `parse-metadata.func.sh`
  (`:15`, `:90`, `:98`, `:105` per copy, section 7), any `run.sh`, a migration,
  `csi-spl-cnf/`, terraform or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Row paths (7): `orc:src/bash/run/spl-desk-reply.func.sh`,
`sa:tests/test-spool-kinds.sh`, `iac:`, `orc:`, `utl:lib/bash/funcs/parse-metadata.func.sh`,
`iac:src/bash/tests/run-sh-parity.tst.sh`, `iac:src/bash/tests/comment-refs-exist.tst.sh`.
(`sa:lib/spool-env.inc.sh`, r82's suggested home for row 01, was checked as well, 1.3.)

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-778`, one call per
  path, 2026-11-21T09:59:41Z, n=1: **status 4 on all 8** ("no live lane lists <path>, but
  18 live lane(s) record no files"). The **18 `unknown:` lanes**, all on the other box:
  eight `rotate` seats (c-146, c-463, c-506, c-562, c-706, c-812, c-924, c-927), spec 123
  P05 c-461 and L3 c-740, spec 033 T025/T027 c-490 (WUI), WUI c-579 and c-749, Cloud
  Translation c-744, spec 190 c-745 and c-747, r82-01 c-751 and r82-02 c-752. The briefs of
  the ten non-rotate lanes on this box (`grep` of the row basenames): **0 hits**, except
  r82-02's, which names `run-sh-parity.tst.sh` as its own (row 02 waits for it, 2.1) and
  `parse-metadata.func.sh` as off limits to itself. c-744's listed files: 1.2. No live
  lane lists a row path.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 10:01:22Z): **16
  queued**: 3 agy WAITs, spec 184 (6, held after SPL-6036), spec 033 T026, spec 123 L4-L7
  (4, held). Their briefs: the six spec 184 ones name `sa:lib/spool-env.inc.sh` (L1, "two
  new functions only"), which is why row 01 does not use it; none names a row path. The
  live share line: refactor 5 of 28 known live lanes, 17% (band 10-20%: ok).
- **Briefs on this box** changed in the last 24 h naming `test-spool-kinds`,
  `spool-env.inc.sh` or `spl-desk-reply.func`: the six spec 184 ones (above), this one,
  r82's planner, and the briefs of lanes that have landed (s033 T024 and its reviewer,
  r81-01 and its reviewer, r77-02).
- **Remote branches committed in the last 24 h** (88 besides master, 10:0xZ):
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 8 paths>` -> 3
  branches: `review/r81-01` and `review/c002-s033-t024-cli-orc-kinds` (`git cherry` -> all
  `-`, on trunk), `review/c002-bug-round-30-mistral-seat` (its 7 unlanded commits touch
  only `bug-round-30/seat-mistral.md`). **0 unlanded hits.**
- **Commits since W** on the row paths (`git log origin/master --since="$W" -- <paths>`)
  -> **0**.
- **Live lanes named in the brief**: r82-01, r82-02 (2.1); bug round 33 row 01 c-749@sat
  (`spl-spawn-enqueue.func.sh`, `spl-spawn-queue.tst.sh`); c-744 (1.2); spec 123, spec
  190, spec 183 P4 (terraform 031/030, cnf), spec 189, spec 033, the WUI notes lanes,
  the release-tooling lane, the private-workspace seats: none on a row path by its listed
  files.

## 3. Per row: what the lane does

- **r83-01:** the reply action's kind set moves into `_spl_desk_reply_kinds`;
  `test-spool-kinds.sh` reads it from there and proves it has one copy.
- **r83-02:** the three `parse-metadata.func.sh` copies take one module-neutral example;
  `run-sh-parity.tst.sh` pins them; `comment-refs-exist.tst.sh` site 4 checks the example
  is a real file.

## 4. Panel and reviewers (R7)

- Editor: c-778 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** requested of the dispatch lease holder (c-002@sat, task
  `dispatch-refactor-r83`): one **cross-vendor** doc seat, the queued mistral seat
  `c002-refactor-round-83-mistral-panel-seat` (agy, the main vendor for plan reviews, is out
  until about 11-24). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-21T10:08:24Z printed
  `pick=hold reason=waiting: grok weekly >= 95% or unknown on <both boxes> ...: queue the
  lane, spawn nothing`. So each row takes a fresh **claude waiver seat** (1a7c70da), as
  r63 to r82. Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r83-01 | `c002-r83-01-orc-desk-reply-kinds-one-copy` | `refactor(r83-01-orc-desk-reply-kinds-one-copy, SPL-<row issue>): ...` | `review/r83-01` | 1 |
| r83-02 | `c002-r83-02-parse-metadata-one-text` | `refactor(r83-02-parse-metadata-one-text, SPL-<row issue>): ...` | `review/r83-02` | 2, `SPAWN_AFTER=c002-r82-02-orc-validate-params-parity` |

**r83-01 brief, Files: ONLY** `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh`
(`_spl_desk_reply_kinds` before `:542`; the `:548` comment moves; `:550` reads it) and
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-kinds.sh` (section 4,
`:56-57`). NOT `spool-env.inc.sh` (spec 184 L1, queued), NOT `spl-desk-reply.sh`, NOT the
FATAL text, NOT `spl-desk-post.func.sh`'s own set (`:126`, a different set: `task` in,
`reject` out). Do: plan section 2 row 01 verbatim, 1.3's shape; the red control (head's
test on the parent) RED then GREEN in the body; 1.3's 15-kind probe on parent and head,
equal. Gates: the 8 suites of 1.5's row 01 lines plus `bash-cleancode.tst.sh` (each, rc
and pass lines in the body, `SPOOL_TEST=1`, in the worktree),
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind `simple_coding`,
vendor claude.

**r83-02 brief, Files: ONLY** `csi-spl-iac/lib/bash/funcs/parse-metadata.func.sh`,
`csi-spl-orc/lib/bash/funcs/parse-metadata.func.sh`,
`csi-spl-utl/lib/bash/funcs/parse-metadata.func.sh` (`:7-8` each),
`csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh` (r82-02's loop takes `parse-metadata`,
its Purpose header) and `csi-spl-iac/src/bash/tests/comment-refs-exist.tst.sh` (`:230-231`,
site 4). Placed only after r82-02 is on origin/master. NOT any `validate-params.func.sh`,
NOT the `${1:?}` lines (`:15`, `:90`, `:98`, `:105`), NOT any `run.sh`, NOT `:220` (site
3). Do: plan section 2 row 02 verbatim, 1.4's shape; the red controls (head's
`run-sh-parity.tst.sh` on the parent; the planted `no-such` example) RED then GREEN in the
body. Gates: the 13 suites of 1.5's row 02 lines (in the worktree, `SPOOL_TEST=1`),
`bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: row 01; batch 2: row 02 (after r82-02) |
| copies of the reply-kind set in `csi-spl-orc/src` + `lib` (`grep -rhF 'result\|reject\|blocker\|msg\|$SPOOL_NOTE_KINDS'`) | 2 on `eb7c8cc54` -> 1 after row 01 |
| distinct `parse-metadata.func.sh` texts (`md5sum` of the 3 copies) | 2 on `eb7c8cc54` -> 1 after row 02, pinned by `run-sh-parity.tst.sh` |
| measured on | `eb7c8cc54`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| a `SPOOL_REPLY_KINDS` in `spool-env.inc.sh` (r82's suggested home) | the six queued spec 184 rows own that file (L1); the set has one reader | 1.3, 2.2 |
| `spl-desk-post.func.sh:126`'s set `task\|result\|blocker\|msg\|$SPOOL_NOTE_KINDS` | a different set (the post takes `task`, not `reject`) with one copy and no test copy: nothing to fold | `git grep` 1.2 |
| `spl-desk-reply.sh:9` usage `--kind` text | another order, and `test-spool-kinds.sh` section 4 already checks it against the set (r81-01); a generated usage line would change the help text | 1.2 |
| `parse-metadata.func.sh`, the 4 `${1:?}` lines per copy (`:15`, `:90`, `:98`, `:105`) | 12 lines over 3 files, over the 5-site cap; whether any caller reaches the empty path is not measured here. A candidate for r84 once row 02 has made the copies one text (one edit then serves all three) | `git show eb7c8cc54:<file> \| grep -n ':?'` |
| `topic_loop_fire.go` `!inserted` branch (SPL-6032 R7 N1, candidates `:74`); `spl-spawn-place-argmax.tst.sh:181-212` section 9 guard cases (b30-01 R7 N1, candidates `:94`) | test rows: a missing test case each, not a refactor of the code; for a test row | r82 7 |
| `gcp-account-pin.func.sh:159`, `validate-params.func.sh:13`, the other `local x="${N:?}"` lines, `tf-each-target.func.sh:14`, the cost sites, the tenant-dir and backup sites, `terraform init -input=false`, the desk hop's env | r82 section 7's reasons hold (already returns, guarded caller, beside r82 rows or spec 123 lanes, behaviour, secret-class) | r82 7 |
| candidates `:104`: `spl-lane-mix.func.sh` (G2, 9 lines) and `csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh` still say "agy has the final word" / "waits for an agy review" (`flag=needs_agy_review`) (SPL-6174, c-744) | it is stale only once SPL-6174 lands (`git log origin/master --grep='SPL-6174'` -> 0 at 10:37Z) and the fleet language rule follows it: the global "Spawn an agent" rule still says agy has the final word. Renaming the flag changes `do_spl_lane_mix`'s output, so it is a behaviour change, not a refactor. A candidate for r84 once SPL-6174 lands and the rule text changes | G2 (1.2) |
| candidates `:105`: `workspace-rules.md:33-34`, spec 176's cite of `spawn-an-agent.md:61` (the file's claim, not re-measured here), and the wf 10 job name `"wui: new locale text carries its agy language review"` (`10_ci-quality.yml:2043`) | doc and CI text that follows the same rule change; renaming a CI job changes the required-check name. For SPL-6174's lane or a doc row after it lands, not a code refactor | `git grep -n 'spawn-an-agent.md' -- csi-spl-doc/doc/md/workspace-rules.md` -> `:33`; `git grep -n 'agy language review' -- .github/workflows` -> `:2029`, `:2043` (origin/master `17e8b2459`) |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, or the full sweep; the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-778): first draft. Row 01 gives the reply action's kind set one copy, in a
  function of the action's own file (not `spool-env.inc.sh`: spec 184 L1 is queued on it);
  row 02 makes the three `parse-metadata.func.sh` copies one text with a module-neutral
  example and pins them after r82-02. Every named test run on base and the row's head
  (1.5). Window W and the r83 slug proof recorded.

- 2026-11-21 10:37Z: m-780@sat **FAIL** on v0.1 `52681174d193bda93841007ef23a8c458651d917`
  (seat file `6f09ce9ff` on `review/c002-refactor-round-83-mistral-seat`), 2 W, N1-N4; the
  holder's send-back c-002@sat msg 12f23814.
  - **W1**: the candidates file grew 101 -> 106 lines at 10:12:19Z, after v0.1's read and
    before its commit, so "did not grow" was false at commit time. Fixed: 1.2 re-reads it
    (109 lines at 10:44:36Z: it grew again at 10:43:31Z, after a first v0.2 draft), accounts for lines 101-109 one by one, and section 7 defers
    `:104` and `:105` with their reasons.
  - **W2**: 1.2's grep, written inside a table cell with `\|`, matches a literal `|` when
    copied raw under `-E`, so it prints 0 lines. Fixed: the greps leave the tables (G1, G2
    under 1.2's table), with their real output (G1 8 lines). (The `-i ... |N1` form prints 17 lines today, since `N1` names many
    review notes, so it is not used.)
  - **N1** (queue 16 -> 15; `review/c002-r82-01`, `review/c002-r82-02` appeared, r82-02 on
    `run-sh-parity.tst.sh`): live state; row 02's `after: r82-02` covers it. No change.
  - **N2**: the red control prints 44 pass, not 43. Fixed in 1.5 (43 was the v0.1 draft's
    `spool-env.inc.sh` shape, not the shipped one; this lane's own red output reads
    `44 passed, 4 failed`).
  - **N3**, **N4**: agreed (the growth came between the read and the commit; the scratch
    copies need `git init` + one commit, as 1.5 says). No change.
- v0.2 (c-778): W1, W2 and N2 folded. No row, file, red control or fix scope changed.

- 2026-11-21 11:24Z: m-780@sat **PASS** on v0.2 `46c97cac55805c0277f3bc4a8e097150697b3139`,
  no W (seat file `85d68ca9e` on `review/c002-refactor-round-83-mistral-seat`, msg 768011e1).
  It re-ran G1 (8 lines, 109 lines in the file), G2 (9 lines), the three red controls (test-spool-kinds 44 pass 4 FAIL, run-sh-parity 7 pass 3 FAIL, the planted comment-refs-exist site) and the 15-kind probe (base and head identical).
  - **N1** live drift since the plan's reads: master moved, r82-01 and r82-02 landed,
    `run-sh-parity.tst.sh` grew 44 -> 55 lines. Covered by row 02's `after: r82-02`; the
    row's builder reads the file on its own base. No change.
  - **N2** SPL-6174 landed (4 commits on master) after this plan's 10:37Z read of 0, so
    candidates `:104` and `:105` are now live: they stay deferred in section 7, as r84
    candidates. No change.
  - **N3** `lane-map.sh --check` exit 3 on `run-sh-parity.tst.sh` names c-778@sat and
    m-785@sat: planner and panel seats whose branches carried the r82-02 pick, no files
    recorded. The other 6 row paths are free. Row 02's builder re-checks at its start.
    No change.
  - **N4** the red controls are hermetic (`SPOOL_TEST=1`, a mktemp `SPOOL_ROOT`); the
    scratch copies need `git init` + one commit, as 1.5 says. Agreed, no change.
- v1.0 (c-778), on the holder's GO (c-002@sat, msg 40c1752f; its review-line check rc 0, OK 2
  of 2): the PASS and N1-N4 recorded, the seat file folded in. No row changed: the plan's
  rows, files, red controls and fix scope read as in v0.2 (`git diff 46c97cac5 <v1.0> --
  <this file>` touches only the status line and sections 8 and 9). The v0.1 and v0.2 commits
  land rebased on master, with new shas; the plan file before this edit is byte-identical to
  `46c97cac5`'s.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-778 (claude): v1.0.
- Panel reviewer seat: m-780@sat (mistral): FAIL on v0.1 `52681174d`; **PASS** on v0.2
  `46c97cac5`, no W (section 8; seat file folded in).
- Panel delta: **m-780 (mistral) PASS** on v1.0
  `ee0908f7f08ae43bc46df3acd2a1022a69ff859b` (msg 7f8b8079; seat file `dd394eb87` on
  `review/c002-refactor-round-83-mistral-seat`, folded in; the holder c-002@sat's line check
  rc 0, msg 830f526b), no W: v1.0 changes no row (`git diff -U0 46c97cac5 ee0908f7f` on this
  file: 3 hunks, the status line and sections 8 and 9).
- Row R7 seats: section 4.
