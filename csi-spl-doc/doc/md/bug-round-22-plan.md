# Bug-fix round 22 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5970 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `b3b480c9-4576-4f93-8b2b-500aa064cd3e` ("Bug round 22", opener msg 52598fbe, opened by c-002@sat 14:5xZ). Round 21 ([bug-round-21-plan.md](bug-round-21-plan.md) v1.0, 2 rows) is closed: b21-01 landed `fee4cb861` (SPL-5962), b21-02 landed `1ce9158a1` (SPL-5964), quality gate 44542235891 success; SPL-5957 done; its topic `148f6fe9` archived (R6 post 7ede2c1b). Bug share: c-001 spawn-share e15a6a68 (bug 18%).  
Round focus: two review automations that read a reviewer's line or a brief's text: the R7 line check refuses the `ran: none` form the rulebook asks for, and the review notify tells an id named in a brief's "never" list that its reviewer started.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Two inputs give a live, unowned defect with a red control that fails on `origin/master`: 2 rows.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-21-plan.md](bug-round-21-plan.md) and [bug-round-20-plan.md](bug-round-20-plan.md) (same shape, same 5 sources).

**Status: v1.0**, signed by the panel (m-472@`<box2>`, mistral, PASS on v0.1 `f4f39f7cf`, 0 warnings).  
Editor: **c-459@`<box2>`** (claude, `specs_and_docs`).  
Panel: m-472@`<box2>` (mistral), placed by c-001 (ask ccbc95cb) for the dispatch holder (section 8).

**One sha:** every count below is measured on **`69c9febbb`** (`origin/master`, committed 2026-11-19T15:46:15+01:00), on `<box2>`, between 14:53Z and 15:15Z on 2026-11-19, unless a row says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b21-plan')` -> `Window: W=2026-11-19T14:26:15+02:00`.

`<box2>` is the fleet's box that is not sat, as in round 21.

---

## 1. How to read this

- Round 21 measured on `99f30c7a0`. This plan re-measures what changed since (`git rev-list --count 99f30c7a0..69c9febbb` -> 68 commits) and every input the brief names, and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `69c9febbb`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `69c9febbb`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since 12:00Z** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-19T12:00:00Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (15:02Z), then the 4 t1 non-probe posts, the 1 csitea hit and that hit's topic (12 messages) read | t1 22 (18 `[spool-probe]`, 0 hits), csitea 82 (1 hit) | **0 rows.** t1: two `status` asks, a pricing question, "can we close this discussion". csitea: the one hit is topic `23fc5fee` 13:51Z, "does not work on facebook" (the blog share row): c-002@sat answered that Facebook takes only a URL, and the owner's follow-ups (a longer teaser) went to lane c-433@`<box2>`, SPL-5968, a live lane of the brief (R3). |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (15:00Z) | 100 runs (2026-11-18T14:56Z..2026-11-19T14:46Z): 55 success, 23 failure, 21 cancelled, 1 running; every timeout headroom line `ok` | **0 rows.** Every failed job's last green is 44542235891 on `1ce9158a` (14:18Z); the newest failed run is 44538401080 (13:56Z). The reds: `wui 2/8` (phone 320 card-size control) and `wui 7/8` (right-click menu), 9 each, owned by c-922's lane `ci-red-wui-e2e-spl5888-menu-and-phone-bar` (c-426's land report 43ab3767); `orc 1/4` 4, `orc 3/4` 3, `wui 8/8` 2, `orc 2/4` 1, `iac` 1, all green since. |
| **3. Skipped or disabled tests** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 69c9febbb -- "$d" \| wc -l; done`; `git diff 99f30c7a0 69c9febbb -G '<the same pattern>' --stat` | api 200, wui 18, orc 10, iac 21, utl 0 (round 21: the same) | **0 rows.** The diff names no file. |
| **4. Box cron logs, last 24 h** | `<box2>`: each `/var/csi/csi-spl{,-desk-cron}/*/cron.{out,log}` changed in the last 24 h (`find -maxdepth 3 -mmin -1440`): its last 3000 lines, a line matching `unbound variable\|command not found\|syntax error\|Traceback\|panic:\|status 141\|operand expected\|Permission denied` counted only after a timestamp of the last 24 h (15:02Z) | 38 logs, 0 hits | **0 rows.** Undated, the same tails hold older hits: `status 141` of `tee >(do_mask_private_keys ...)` 2026-11-17 21:36..22:00Z in 10 logs, and `spl_private_has_tokens: command not found` of 2026-11-15 in 2 logs; none in the window. sat's logs: the holder's (section 8). |
| **5. Round 21's first inputs, the holder's candidate list, the r66-02 notes, the review line** | round 21 sections 5 and 7; the brief's summary of `/var/spool-hub/dispatch/c002-next-round-candidates.md` (on sat, not read from `<box2>`); c-426's report 43ab3767 (prd db); m-423's line c8fecac2 (prd db) | 9 inputs | **2 rows**: 01 from the review line (c8fecac2), 02 from the holder's list (c-001 364398a4). The other 7: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `69c9febbb`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b22-01-orc-review-line-docs-only-ran-none)` | `do_spl_review_line_check` refuses every R7 line whose `ran:` names no test: `MISSING ran: names no test ...`, exit 3 (`spl-review-line-check.func.sh:102`), and `SYNTAX FAIL ran: names no test` with `REVIEW_LINE_SYNTAX=1` (`:258-261`). That includes the form the rulebook asks for when no test applies: "If no test was executed directly, it must say `ran: none` and cite the command output read" (rulebook 2.7.4). So a genuine review of a docs-only change (a spec, a plan) fails the check in both forms, and so does every reader of the check: `do_spl_accepted_close`'s journal re-verification (`spl-accepted-close.func.sh:206-207`: no automatic ACCEPTED) and `do_spl_push_master`'s review syntax check (`spl-push-master.func.sh:317-325`). | m-423@`<box2>`'s spec 107 v2.12 review, msg c8fecac2 (SPL-5886, 14:28:57Z), a PASS on `03f8ee98389d...`, whose diff touches only `csi-spl-doc/specs/107-hours-tracking/spec.md` and `tasks.md` (its `read:`). On `<box2>` (the log's box), n=1 each: `REVIEW_LINE='<its line>' ./run -a do_spl_review_line_check` -> `MISSING ran: names no test ...: 'git ls-remote origin ... ; LEASE_CMD=show ./run -a do_spl_dispatch_lease'`, exit 3; the same line with `ran: none` -> `MISSING ran: names no test ...: 'none'`, exit 3. The brief's reading (the `seat-file:` segment and the relative `log:` path) is not what fails on the log's box: the check stops at `:102` before it reads the log. The relative path: section 5. | `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:102` (full check), `:258-261` (syntax check), header `:17-20`, `:54`, `:59`; test `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh` (cases 5 `:139`, 8 `:180-214` and 14 `:375`, whose "names no test" lines sit on the docs-only fixture commit `a.md`, `:81-83`; and a new case); doc `csi-spl-doc/doc/md/rounds-rulebook.md` 2.7.4 (through its Qto doc, then `do_spl_doctree_export_md`); read only: `spl-accepted-close.func.sh`, `spl-push-master.func.sh` | `bash rc01.sh 69c9febbb` (section 3.2): the suite's fixture (`spl-review-line-check.tst.sh:1-88`) plus a case on its docs-only fixture commit: `FAIL: b22-01: ran: none on a docs-only commit (a.md) -> rc 3: MISSING ran: names no test ...: 'none'`; `FAIL: ... ran: names commands but no test -> rc 3`; `FAIL: the same from another box, REVIEW_LINE_SYNTAX=1 -> rc 1: SYNTAX FAIL ran: names no test ...`; `b22-01: 3 failure(s)`. Its control passes: `ran: none` on a commit that touches `x.sh` -> MISSING, exit 3. | When the line's sha is a commit in `REVIEW_LINE_REPO` whose change set touches only docs (`*.md`, `csi-spl-doc/`), a `ran:` that names no test (`none` included) passes both checks; a sha that touches anything else keeps the rule (a test must be named; the e2e map still asks for its files). Which change set (the commit's own, or the range from its merge base with trunk, for a review branch of several commits) is the lane's to choose and to state; the control commit stays refused either way. Cases 5, 8 and 14 move their "names no test" lines onto a fixture commit that touches code, so they keep testing the refusal. The header and rulebook 2.7.4 say which shas need a test. | `<box2>` (the evidence's log is there) or sat | claude | grok (cross-vendor), backup: another non-claude seat the holder names | `simple_coding` | 1 |
| 02 `fix(b22-02-orc-review-notify-author-line-wins)` | `spl_review_notify_authors` takes an id after the word "author" anywhere in a brief (`spl-spawn-review-notify.func.sh:113`, `:122`), so an id named as ANOTHER lane's author is told "Your R7 reviewer ... started on `<branch>` ... Push nothing more to `<branch>`" too. The b21-02 R7 seat's brief has the line `Author: c-947@sat` and, in its "never" list, "Never the author c-947, never the round's panel seat m-923, planner c-912, or row 01's author c-944 / reviewer c-409": the function returns c-947 AND c-944, so row 01's author gets b21-02's reviewer note when the placer's hook (`spl_review_notify_placed`, `:86-92`) runs on that brief. | The brief `/var/spool-hub/spawn-remote/briefs/6e753791-...md` (spawn request 6e753791, c-001@sat 13:42:35Z), read on `<box2>`: the function sourced at `69c9febbb` and run on it -> `c-947 sat` and `c-944`. The holder's list cites c-001 364398a4 for the observed case (on sat, not re-read from `<box2>`: that the note reached c-944 is c-001's report, not this plan's measurement). Scan of every brief on `<box2>` (`scan02.sh`, section 3.2): 2004 reviewer briefs, 796 with a line-start `Author: <id>` line, 2 whose result holds an id that is not on that line: this one (c-944) and one whose `Author:` line names a role seat. | `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh:105-123` (the parse; the fix at `:122`), header `:8-16`; test `csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh` (case 6 `:132-149`, and a new case beside it); doc `csi-spl-doc/specs/157-dispatch-automation/spec.md:430` (Rule 3, "As built (B6)") | `bash rc02.sh 69c9febbb` (section 3.2): the suite's sandbox (`spl-spawn-review-notify.tst.sh:1-70`) plus a brief of the b21-02 seat's shape: `FAIL: b22-02: c-944, named only in the 'never' list as row 01's author, is told: 2 note(s): --to c-947 --to c-944`; `b22-02: 1 failure(s)`. Its controls pass: the `Author:` line's c-947 is told; a brief with no `Author:` line keeps the phrase form (`(author c-372, ...)` told). | A brief that has a line-start `Author: <id>` line names its authors on those lines: the phrase form elsewhere in that brief is context and is not read. A brief with no such line reads the phrase form as today (case 6: `(author c-372, vendor claude)` and `Author c-168@boxa.` without a colon); the table cell form is unchanged (case 3 has both a line and a cell). The header and spec 157 `:430` say so. Live proof (R5): the next review seat placed on a brief with a "never" list tells only its author (automation.log: one `review-notify` line per author). | sat (the placer runs there) or `<box2>` | claude | grok (cross-vendor), backup: another non-claude seat the holder names | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** both rows; their files are disjoint.
  - Row 01: `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh`, `csi-spl-doc/doc/md/rounds-rulebook.md` (2.7.4, through the Qto doc). It reads `spl-accepted-close.func.sh` and `spl-push-master.func.sh` and edits neither.
  - Row 02: `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh`, `csi-spl-doc/specs/157-dispatch-automation/spec.md`.
- **Test column (R2):**
  - Row 01: `git grep -lE 'spl-review-line-check\|do_spl_review_line_check\|_spl_review_line_' -- '*tests/*'` (among them `spl-review-line-check.tst.sh` and `spawn-agents/tests/test-pre-push-review-line.sh`); the lane runs every file it prints. Case 12 needs `csi-spl-iac` beside `csi-spl-orc` (the e2e map) in any copy it runs in.
  - Row 02: `git grep -lE 'spl-spawn-review-notify\|do_spl_spawn_review_notify\|spl_review_notify_' -- '*tests/*'`; the lane runs every file it prints.
- **Off limits** for the row lanes: every live lane's files (below); `spl-accepted-close.func.sh`, `spl-push-master.func.sh`, `spl-spawn-place.func.sh` (read only; each fix stays in its own file).
- **How the files were checked (2026-11-19, `<box2>`):**
  - 14:59:39Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-line-check.func.sh,csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh,csi-spl-doc/specs/157-dispatch-automation/spec.md,csi-spl-doc/doc/md/rounds-rulebook.md,csi-spl-doc/doc/md/bug-round-22-plan.md --agent c-459` -> `WARN no live lane lists` them; exit 4 for one lane that records no files: c-946@sat (`c-946-c002-wui-calendar-member-sees-other-members-entries`, SPL-5963, the hub calendar per the brief): not these files. The orchestrator re-runs the check before the spawn (R3).
  - 14:59:46Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 0 queued, 0 placing.
  - The brief's live lanes (c-414 SPL-5966, c-433 SPL-5968, refactor round 67's rows) name none of these files in their scopes, and the lane map lists none of the files.
- **Slug b22 is unused as a round id** (`<box2>`, 14:53:55Z):
  - `git log origin/master --since="$W" --oneline -E --grep='\(b22-'` -> 0;
  - `git ls-remote origin 'refs/heads/review/b22-*' 'refs/heads/wip/*b22*' 'refs/heads/*-b22-*'` -> nothing; `git ls-remote origin \| grep -cE 'b22-[0-9]{2}\|bug-round-22'` -> 0;
  - `grep -rlE '(^|[^0-9a-f])b22-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs`, `/var/spool-hub/asks` and `/var/spool-hub/spawn-remote/briefs` -> 0 files; `bug-round-22` -> 1 file, this planner's brief.
  - sat (c-002@sat msg 2edabf91, run 15:1xZ): `grep -rlE 'b22-0[0-9]'` over sat's `dispatch/briefs`, `dispatch/asks` and `spawn-remote/briefs` -> 0 files; `git ls-remote origin \| grep -cE 'b22-0[0-9]'` -> 0; `git log origin/master -E --grep='\(b22-[0-9]'` -> 0.

  After this plan's pushes, `--grep='(b22-'` matches the plan's commits (`docs(b22-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b22-[0-9]{2}'` stays 0 until a row lands.

### 3.2 Red controls run on `69c9febbb`

The scripts are on `<box2>` in `/var/spool-hub/dispatch/b22-red-controls/` (`sha256sum`, first 12 hex): `rc01.sh` (696 B, `278680899d32`), `rc01-case.sh` (1705 B, `3aa159aea3e6`), `proto01.func.sh` (`ba52a7b32271`), `rc02.sh` (684 B, `7bb24f56638c`), `rc02-case.sh` (1613 B, `de82a9cf9196`), `proto02.func.sh` (`7b43bd89bc5f`). Each `rcNN.sh <sha>` takes a `git archive <sha> csi-spl-orc` copy, builds `rcNN-run.tst.sh` from the suite's own fixture lines plus `rcNN-case.sh`, and runs it; `RC_PROTO=<file>` first puts a prototype function file in the copy. Run from any checkout of this repository; the checkout is not touched. Both case files are printed below, so a seat on sat can rebuild them.

| row | command | output on `69c9febbb` | output with a prototype fix | who |
|---|---|---|---|---|
| 01 | `bash rc01.sh 69c9febbb` | `FAIL: b22-01: ran: none on a docs-only commit (a.md) -> rc 3: MISSING ran: names no test (...): 'none'` / `FAIL: b22-01: a docs-only commit, ran: names commands but no test -> rc 3` / `FAIL: b22-01: the same from another box, REVIEW_LINE_SYNTAX=1 -> rc 1: SYNTAX FAIL ran: names no test (...)` / `PASS: b22-01 control: ran: none on a commit touching x.sh -> MISSING, exit 3` / `b22-01: 3 failure(s)` | `RC_PROTO=proto01.func.sh bash rc01.sh 69c9febbb` (the checker plus `_spl_review_line_docs_only`: the sha's own change set, `git diff-tree --root -r`, only `*.md` / `csi-spl-doc/` paths, called before both refusals) -> 3 PASS, the control PASS, `b22-01: 0 failure(s)`. The whole suite on that copy: cases 5, 8 and 14 fail, as expected (their "names no test" lines sit on the docs-only commit, which the fix scope moves), and case 12 fails only because the copy has no `csi-spl-iac` (the e2e map) | editor c-459 |
| 02 | `bash rc02.sh 69c9febbb` | `PASS: b22-02 control: the Author: line's c-947 is told` / `FAIL: b22-02: c-944, named only in the 'never' list as row 01's author, is told: 2 note(s): --to c-947 --to c-944` / `PASS: b22-02 control: no Author: line, the phrase (author c-372, ...) is still told` / `b22-02: 1 failure(s)` | `RC_PROTO=proto02.func.sh bash rc02.sh 69c9febbb` (`:122`: with a line-start `Author: <id>` line, only those lines; else the phrase as today) -> 3 PASS, `b22-02: 0 failure(s)`; the whole `spl-spawn-review-notify.tst.sh` on that copy: `spl-spawn-review-notify: 0 failure(s)` | editor c-459 |

The prototypes only show that PASS is reachable; each lane writes its own fix and its own suite case.

The b22-01 case, as run (`rc01-case.sh`, appended after line 88 of `spl-review-line-check.tst.sh`, whose `chk`, `line`, `$R0` and `$SHA` it uses):

```bash
J22="$T/b22.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff --stat HEAD^ HEAD"}}]}}' >"$J22"
out="$(chk REVIEW_LINE="$(line "none" "$J22")")"; rc=$?
[[ $rc -eq 0 ]] && pass "b22-01: ran: none on a docs-only commit (a.md) -> rc 0" || fail "b22-01: ran: none on a docs-only commit (a.md) -> rc $rc: $(head -c 160 <<<"$out")"
out="$(chk REVIEW_LINE="$(line "git diff --stat HEAD^ HEAD" "$J22")")"; rc=$?
[[ $rc -eq 0 ]] && pass "b22-01: a docs-only commit, ran: names commands but no test -> rc 0" || fail "b22-01: a docs-only commit, ran: names commands but no test -> rc $rc: $(head -c 160 <<<"$out")"
out="$(chk REVIEW_LINE="review: m-159@box-b mistral PASS $SHA ran: none | read: 9 PASS | log: m-159@box-b:$J22" REVIEW_LINE_SYNTAX=1)"; rc=$?
[[ $rc -eq 0 ]] && pass "b22-01: the same from another box, REVIEW_LINE_SYNTAX=1 -> rc 0" || fail "b22-01: the same from another box, REVIEW_LINE_SYNTAX=1 -> rc $rc: $(head -c 160 <<<"$out")"
echo 'echo x' >"$R0/x.sh"; git -C "$R0" add x.sh && git -C "$R0" -c user.name=t -c user.email=t@example.com commit -qm x
SHA="$(git -C "$R0" rev-parse HEAD)"
out="$(chk REVIEW_LINE="$(line "none" "$J22")")"; rc=$?
[[ $rc -eq 3 && "$out" == *"names no test"* ]] && pass "b22-01 control: ran: none on a commit touching x.sh -> MISSING, exit 3" || fail "b22-01 control: code commit (rc $rc: $(head -c 160 <<<"$out"))"
echo "b22-01: ${fails} failure(s)"
[ "$fails" -eq 0 ]
```

The b22-02 case, as run (`rc02-case.sh`, appended after line 70 of `spl-spawn-review-notify.tst.sh`, whose `reset`, `brief`, `run`, `sends` and `sent_to` it uses):

```bash
reset; mkdir -p "$T/s/c-947" "$T/s/c-944"
b="$(brief c002-b21-02-claude-waiver-reviewer "# Lane brief: R7 reviewer for SPL-5964 (b21-02), claude, review only
Author: c-947@boxa
Author brief: /x/briefs/c002-b21-02-orc-pre-push-msg-sweep-skips-master.md
Read only the tree. Never the author c-947, never the round's panel seat m-923, planner c-912, or row 01's author c-944 / reviewer c-409.
Branch \`review/c-947-b21-02-x\`, head \`3f9b35db004b771da44285115faabc2bd46d7fbd\`.
Report on task dispatch-bug-r21.")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=c-500@boxa; rc=$?
sent_to c-947 && pass "b22-02 control: the Author: line's c-947 is told" || fail "b22-02 control: c-947 not told: $(cat "$T/s/sends.log")"
! sent_to c-944 && [[ "$(sends)" == 1 ]] && pass "b22-02: c-944, named only in the 'never' list, is not told (1 note)" ||
  fail "b22-02: c-944, named only in the 'never' list as row 01's author, is told: $(sends) note(s): $(grep -o -- '--to [^ ]*' "$T/s/sends.log" | paste -sd' ')"
reset; b="$(brief c002-phr2-reviewer "You are a READ-ONLY reviewer (author c-372, vendor claude).")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500; rc=$?
sent_to c-372 && pass "b22-02 control: no Author: line, the phrase (author c-372, ...) is still told" || fail "b22-02 control: phrase form lost: $(cat "$T/out")"
echo "b22-02: ${fails} failure(s)"
[ "$fails" -eq 0 ]
```

---

## 4. Round 21's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b21-01, b21-02 | `git log origin/master --oneline -E --grep='\(b21-0[12]-'` | landed `fee4cb861`, `1ce9158a1`; gate 44542235891 success (the brief) | Served (round 21 closed). |
| Round 21 sections 4 to 6 (the holder's older items, the c-091 staged index, the desk-cron `bin/spool` WARN) | as round 21 | unchanged | Closed as round 21 says. The `bin/spool` WARN is still printed by every orc run on `<box2>` (`built 2026-10-31T02:29:14Z`). |

---

## 5. Not a row this round, or no red control yet

| candidate | command | result |
|---|---|---|
| **The relayed retired-author send** (round 21 section 7: review-go retries a GO to a retired author on another box) | `sed -n 218,232p csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh`; `spl-review-go.func.sh:838-847`; `<box2>`'s `/var/csi/csi-spl/review-go/cron.out`: `grep -aoE 'GO to [^ ]+ failed \(rc [0-9]+'` -> 0 lines | **Not a row: no observed case and no red control.** The relay maps a hub roster miss (`unknown_agent`, `cannot resolve to_box`) to exit 3, so `spool-send.sh` exits 13, and review-go treats 13 as a retry (`:846`) until `REVIEW_GO_MAX_AGE` (60 min). But the relay's exit 3 also covers transient desk and sidecar failures (`:95`, `:98`, `:142`, `:187`), so 13 alone does not mean "retired". The review-go cron runs where the dispatch lease is (sat); `<box2>`'s log has no failed GO. First input for round 23: the holder reads sat's `review-go/cron.out` for `failed (rc 13)`; with a case, the control is a relay stub that answers `unknown_agent`. |
| **b20-01 R7 N3: the `spool-send.sh` header does not list exit 14** | as round 21 | **Not a bug row: wording only** (round 21 section 5). |
| **Suites not hermetic to the OS user** (holder's list; c-001 a9ee75ee: `check-commit-msg-hygiene.tst.sh` cases 6 and 8, `watcher-read-only.tst.sh`) | `<box2>`, n=1 each, worktree at `69c9febbb`: `bash csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh` as the agent user, as `<DEV_USER>`, and with an empty `HOME` / `XDG_STATE_HOME` -> `ALL PASS` all three; `bash csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh` as `<DEV_USER>` -> 81 passed, 0 failed; as the agent user -> `mkdir: cannot create directory '.../csi-spl-api/src/go/spool-hub-api/bin': Permission denied`, `FAIL - cannot build spool`, 0 passed, 1 failed | **Not reproduced as described on `<box2>`.** Cases 6 and 8 pass for both users. `watcher-read-only` fails only for a user that cannot write the worktree: `t_spool_bin` builds the spool binary into the source tree's `bin/`, not into the test's temp dir (developer guide 2.12.2); `git grep -l t_spool_bin -- csi-spl-orc` -> 24 files. c-001's a9ee75ee is on sat and was not read here: with sat's failing output, it is round 23's row (or a 3rd row here, if the panel asks). |
| **The done-claim check reads a sha256sum prefix as a git sha** (c-001 95722c63) | `spl_done_claim_tokens <<<'rc01.sh sha256sum -> 92fd284d8549...'` at `69c9febbb` -> `92fd284d8549` (the same after `sha256`); after `md5` -> nothing (`spl-done-claim-check.func.sh:352`); `<box2>`'s ledger (`/var/csi/csi-spl/done-claim-check/cron.log`): 5 alerts on 2026-11-19, none on such a token | **Mechanism reproduced, no observed alert on `<box2>`.** The `md5` label cut (SPL-2332) has no `sha256` twin. A planner or seat result (the usual writer of a `sha256sum` line) is verdict `seat` and never alerts; c-001's 95722c63 case is on sat and was not read here. First input for round 23, with that case's message id. |
| **The done-claim check flags a result that says "nothing pushed"** (c-414's 5af1b025 and 992da5c3, alerts at 14:20Z and 14:40Z) | the two message bodies (`<box2>` outbox) and their ledger lines | **Not a bug: by design.** Both results name lane-branch shas that are on no trunk, which is what the check exists to report (owner D2, SPL-2265); reading "not pushed" in prose is the language parsing the action's header rules out. The holder answered both (3e633efc). |
| **r66-02 N1: a shallow APP_PATH gives `SPL_VAR_ORG_DIR=/var/`** | c-426's report 43ab3767 | **No red control in this plan**: no case observed (n=0). Round 23 input, with a reproduction. |
| **r66-02 N2: `FATAL no cargo` in `_scg_build` is swallowed** | `spl-cmd-guard-mode.func.sh:42`: `do_log "FATAL no cargo ..."` writes to stdout, which `bin="$(_scg_build)"` (`:72`) captures; the rust-home FATAL at `:39` has `>&2` | **Reproduced by reading; a lost diagnostic only**: the run still fails (`FAIL the spl-cmd-guard build failed`) and do_log's log file keeps the line. A one-token `>&2`, wording-class, for whichever lane next edits the file. |
| **`workflow-tool-checksums.tst.sh:33` computes a guard it never asserts** (c-443's r67 plan section 7) | as cited | **A test-coverage gap with no failing behaviour: not a bug row** (the brief). Input for a test round. |
| **The review line's relative `log:` path** (m-423's `log: m-423@<box2>:.vibe/...`) | `spl-review-line-check.func.sh:254` (the syntax regex wants `/` or `~/`) | **A seat-brief defect, not a checker bug**: the commit form of rulebook 2.7.4 writes the path from `~/`. The holder's seat brief should ask for an absolute or `~/` path. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| The blog share text on Facebook / LinkedIn (csitea `23fc5fee`, 13:51Z) | c-433@`<box2>`, SPL-5968 | Live lane; not a row. |
| CI `wui 2/8` and `wui 7/8` | c-922's lane `ci-red-wui-e2e-spl5888-menu-and-phone-bar` (43ab3767) | Green since 44542235891 (14:18Z). |
| The live lanes of the brief (c-946@sat SPL-5963; c-414@`<box2>` SPL-5966; c-433@`<box2>` SPL-5968; refactor round 67's rows; the customer workspace seats) | their lanes | None touches the rows' files (section 3.1). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 9 named inputs; 104 human posts counted (5 read, plus 1 topic of 12 messages); 100 CI runs (23 failed, 0 open); 38 cron logs (0 hits in 24 h); 2004 briefs scanned for row 02 |
| first inputs for round 23 | the relayed retired-author send (sat's log); the hermetic-suite failure (sat's output); the sha256 token (c-001's 95722c63 case); r66-02 N1 |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-459@`<box2>` (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder (c-002@sat when v0.1 was sent) on task `dispatch-bug-r22`, with at least one non-claude seat. The panel checks both red controls (`rc01.sh 69c9febbb` and `rc02.sh 69c9febbb`: RED; it may rebuild them from section 3.2), the fix scopes (row 01: only a docs-only sha relaxes the rule; row 02: only a brief with a line-start `Author:` line drops the phrase form), the evidence (m-423's line c8fecac2 on the log's box; the b21-02 seat brief 6e753791), and that every other input in sections 2, 4, 5 and 6 is measured as written.
- **Asked of the holder with the panel request:** the sat half of the slug check (3.1: 0 on sat, msg 2edabf91), and sat's evidence for section 5 (c-001 a9ee75ee and 95722c63, `review-go/cron.out`): the holder does not hold a9ee75ee or 95722c63 and leaves them to round 23 (2edabf91).
- **Row reviewers (R7):** a grok seat per row (cross-vendor to the claude authors); backup named by the holder.
- **Review history:**
  - 2026-11-19 15:12Z: the editor pushed v0.1 (`f4f39f7cf`) to `review/c002-bug-round-22-planner` and asked the holder for a panel (msg 96dfb5f9). The lease moved from c-002@sat to c-003@sat (msg 2cdd7c55); grok was on hold (99% weekly) and agy out of quota on `<box2>`, so the panel is one mistral seat.
  - 2026-11-19: panel seat m-472@`<box2>` (mistral, ask ccbc95cb): **PASS** on `f4f39f7cf698f2dd2dad706570073c4274a3d2c9`, 0 warnings (msg 0bc5f24a); seat file on `review/c002-bug-round-22-mistral-seat` at `f163b371d`. It re-ran both red controls (`rc01.sh 69c9febbb` -> exit 1, 3 FAIL, control PASS; `rc02.sh 69c9febbb` -> exit 1, c-944 told, 2 controls PASS), the `sha256sum` of every script, every cited site at `69c9febbb` and `origin/master`, the slug check, `lane-map.sh --check` and `do_check_dist_hygiene` (clean).
  - Panel notes, folded in v1.0 (none changes a row):
    - N1: `lane-map.sh --check` on the 6 row paths exits 4: no live lane lists them; c-946@sat, c-981@sat and m-977@sat record no files (their briefs are on sat). The orchestrator re-runs R3 before the spawn.
    - N2: two section 5 items, r66-02 N1 and `workflow-tool-checksums.tst.sh:33`, rest on their citations (n=0 stated), not on a measurement in this plan; the other 6 carry measurements or line reads the seat re-verified.
    - N3: `W` and the 68-commit count re-measured as written.
    - N4: all 8 cited files are byte-identical between `69c9febbb` and `origin/master` at the review, so the red controls hold on master.
  - v1.0: the editor folded the notes above, the sat slug result (3.1) and the lease change.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-459@`<box2>` | **v1.0** |
| Panel | m-472@`<box2>` (mistral) | **PASS** on `f4f39f7cf` (msg 0bc5f24a, seat file `f163b371d`) |
