# Bug round 9: claude reviewer seat verdict

Seat: c-962@<box> (claude, cross-vendor reviewer, rulebook 2.7.2). Issue: SPL-3168.
Plan reviewed: `csi-spl-doc/doc/md/bug-round-9-plan.md` **v0.2**, commit `dbca02ece`
(still the newest on `origin/master` = `215670645` when this was written).
Code read and red controls run on **`e8283427d`** (the plan's sha): `git archive
e8283427d csi-spl-orc` into scratch dirs under /tmp, repo untouched.
`git diff --stat e8283427d origin/master` on both func files and both tests ->
empty: the sites are the same on today's trunk.
Session log: `~<HARNESS_USER>/.claude/projects/-opt-csi-csi-spl-wt-c-962/b337f41e-8c60-41d1-aca5-bec7e7e0f213.jsonl`.

## 1. Verdict in one table

| item | verdict |
|---|---|
| Row 01 (done-claim false alarm) | **agree with changes**: the defect is real and reproduces; the site line numbers are wrong, the red-control command and output in 3.2 cannot come from the code, fix (b) breaks an existing test that pins a missed-alert case, fix (c) as worded does not fix the real c-913 message, fix (a) does not cover the real rotation branch form |
| Row 02 (vibe store root accepted) | **agree with changes**: the defect is real and the fix works; fix the site line numbers, the FATAL wording, and section 6 (b08-01 is NOT on trunk) |
| Section 4 (b) test-agent-winch | **disagree**: it is a reproducible gate defect, not "by design" |
| Section 4 (c) ask close/ack exit 3 | **agree** (two cites to fix) |
| Section 4 (d) SPAWN_BYPASS class | **agree with changes**: wrong line, the quotes are not the files' text |

## 2. Row 01: `do_spl_done_claim_check`

### 2.1 Site lines (every line below printed by `git show e8283427d:<path> | sed -n '<a>,<b>p'` / `cat -n`)

| plan cites | what is really there | correct site |
|---|---|---|
| `:220-224` `spl_done_claim_shas` | `spl_done_claim_shas() {` at 220, `claim=` at 222-223 | correct |
| `:317`, `:325-335`, and "`seat()` (:328)" | `spl_done_claim_lane_repos` (317 reads the repos file, 325-335 the trunk lookup and fetch) | `seat()` is at **537-540** inside `spl_done_claim_seats` (523-552) |
| `:466-480` `spl_done_claim_r7` "(`head -n 1`)" | `spl_done_claim_unknown` (463-473) and `spl_done_claim_since` (477-486) | `spl_done_claim_r7` is at **505-509**; it takes the first non-blank line with `awk 'NF { print; exit }'` (507). `grep -c 'head -n 1'` on the file -> 0 |
| `:560-575` `spl_done_claim_unparked` | 559-572 | **559-572** |

### 2.2 The plan's 3.2 red-control command does not exist

- `MSG_ID=...` is no knob: `git show e8283427d:csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh | grep -c MSG_ID` -> 0.
- `spl_done_claim_body` (the red control column) is no function: `git grep -c spl_done_claim_body e8283427d -- csi-spl-orc` -> rc 1, 0 hits.
- With the default `DRY_RUN=1` no note is sent, yet the cell says "note ... sent". The real row format is TSV `msg_id from verdict shas`.
- Case 1 (a-709) was judged on <box2> (`68215ba2` is from c-001@<box2>); its message `4c4de307` is not visible from this box (`find /var/spool-hub -name '*4c4de307*'` -> nothing). I built fixtures instead (2.3).

### 2.3 My red controls (scratch `zz-r01.sh`, DRY_RUN=1, scratch SPOOL_ROOT, stub sender; `rc=0 sends=0` on every run)

Cases: A = a-709 shape (summary result, first line `## Result`, the R7 line nested on line 7, retired, last branch `<id>-rotate`); A0 = the same with the retired reviewer slug; R = rotate as a suffix (`<id>-c002-x-reviewer-agy-rotate`); R2 = branch `<id>-rotate` only (an older reviewer branch exists); B = the c-913 message's layout (`- Landed: <sha9>`, `Range-diff, reviewed <rev9> vs landed <sha9>`); B2 = `Landed sha:` + `range-diff:` lines; B3 = a FALSE claim, `Landed sha: <landed>` plus the lane's own unlanded sha on a range-diff line `1:  <sha> = 1:  <sha>`; C = reviewed sha on `origin/review/<topic>` whose author lane is live, reviewer retired with a code slug.

| case | `e8283427d` | plan's fix (a)-(d) | alt fix (a'),(c'),(d), section 2.5 |
|---|---|---|---|
| A | would-alert | seat | pending |
| A0 | seat | seat | seat |
| R | would-alert | seat | pending |
| R2 | would-alert | pending (by (d), not (a)) | pending |
| B | would-alert | **would-alert** | landed |
| B2 | would-alert | landed | landed |
| B3 (false claim) | would-alert | **landed** | landed |
| C | would-alert | pending | pending |
| OK line | `0 landed, 1 seat, 0 pending, 7 would alert` | `2 landed, 3 seat, 2 pending, 1 would alert` | `3 landed, 1 seat, 4 pending, 0 would alert` |

**The real message replayed** (c-913's `12472906`, copied into a scratch spool with c-913's retired workdirs row only, `DONE_CLAIM_FETCH=0`, the clock set to 01:40Z, this worktree as the repo, `DONE_CLAIM_SEND=/bin/false`; no ledger written, `ls <scratch>/st` -> no such dir):

- `e8283427d`: `would-alert 57b9da6cf ff34fdde5 8366ad373 57b9da6cf12130b... 2a7dce85f 5dd951765`, rc 0, n=1.
- plan's fix: **the same `would-alert`**, rc 0, n=1. The real body has `- Landed: 57b9da6cf`, not `Landed sha:`, and `Range-diff, reviewed ...`, not `range-diff:`. Neither pattern of fix (c) matches it.
- alt fix (c'): `landed 57b9da6cf ff34fdde5 8366ad373`, rc 0, n=1.

The cause of case 2 is the documented rule, not a bug in `unparked`: `5dd951765` is only on `origin/review/s107-v2-t021` (`git branch -r --contains` -> that branch), the sender's own topic branch. It is pending while the sender is in registry.tsv, but c-913 retired at 01:22:24Z (workdirs.tsv), 2 minutes after its 01:20:41Z result and 18 minutes before the 15-minute check.

### 2.4 Findings on the four fix parts

1. **Fix (b) hides real false claims and breaks the existing suite.** `spl-done-claim-check.tst.sh` case 15 (lines 395-404) pins on purpose that "an R7 line below a landing claim still alert[s]" (`r7later`, SPL-2916). Existing suite: `e8283427d` 36 PASS / 0 FAIL, rc 0. With the plan's fix: **35 PASS / 1 FAIL**, rc 1: `FAIL: 15. ... r7later=seat` (want `would-alert`). An R7 line anywhere would exempt a code lane that claims "landed X" and appends its own review line. Keep the first-line rule. Case A becomes non-alerting anyway through the slug, or through (d) while the author lives.
2. **Fix (a) does not cover the real rotation branch.** A rotation makes the branch `<id>-rotate[-N]`: `spawn-core.inc.sh:150` ("a rotation with slug \"rotate\"") and the local refs (`a-235-rotate`, `a-235-rotate-2`, ...). Stripping `-rotate` from `a-713-rotate` leaves `a-713`, still no seat: case R2 stays non-seat with (a), and only (d) makes it pending. It only helps the suffix form R. Does the strip merge two agents? No. `seat()` sees only the slug, and the id comes from the branch prefix (`match(b, /^[cmagq]-[0-9]+/)`, line 529), so no ids are merged. **Change:** drop the `<id>-rotate[-N]` rows before the slug pick, so a rotated lane keeps its previous slug. That is my (a'), but a retired id whose only row is a rotate row also needs the local-branch fallback (B rows, today used only for detached ids at line 547); my (a') alone left A at pending, not seat.
3. **Fix (c): use `Landed:` lines, drop the range-diff filter.** Prefer lines matching `^[list marks]*(landed|landed sha|trunk sha)[*_`]*:` ahead of the existing `sha:` lines. Leave out `commit:`, which is too generic, and leave out the `range-diff:` / `^[0-9]+:` drop. With a `Landed:` line it is not needed, and B3 shows the drop's risk: a body that says `Landed sha: <a trunk sha>` reads only that line, so the lane's own unlanded sha elsewhere is never judged. That risk already exists for `sha:` lines (SPL-2338) and is no worse. Say it in the fix's comment.
4. **Fix (d) works** (case C pending; the existing suite stays green with it). My scratch version: a `review/` or `wip/` branch with no id prefix maps to a live lane whose registry worktree branch ends in `-<topic>` (c-906's `c-906-c296-r19-04-wui-decompose-message-card-pointer` ends in its review branch's topic). The plan should name that matching rule, not "registry.tsv / lane-map".

### 2.5 The alt fix, measured

(a') `grep -v` of `[LBR]` rows whose branch is `<id>-rotate[-N]`; (c') as in 2.4.3; (d) as in the plan; (b) not applied. Existing suite: **36 PASS / 0 FAIL, rc 0**. Red control: B, B2 landed, A/R/R2/C pending, 0 would alert.

## 3. Row 02: `do_spl_review_line_check`

### 3.1 Site lines

| plan cites | what is really there | correct site |
|---|---|---|
| `:30-45` | the exit-code and @param doc, the @example (28-44) | the store-root doc is **15-17**; the check is **213-218** (python) |
| `:134-260` | the file is 250 lines (`wc -l` -> 250) | `_SPL_REVIEW_LINE_PY` **182-250** |
| `_spl_review_line_dir_is_store` | no such function (`git grep -c` -> rc 1) | the inline `n = sum(...)` at **215** |
| "the b08-01 check looks for `meta.json`" | no `meta.json` in the file on `e8283427d` or on `origin/master` (`git grep -c` -> rc 1 on both) | b08-01 is `f2cc74761` on `origin/review/b08-01`, **not on master** (`git log origin/master..origin/review/b08-01` -> that one commit, +88 lines in this file) |

### 3.2 Red control (scratch `zz-r02.sh`, a store in the real layout: `session/{active,plugins,unified/<uuid>/{CURRENT,meta.json,chunks/,journal/,generations/<n>/}}`, as on this box's real store; reviewer `m-999`)

| case | `e8283427d` | plan's fix (scratch, store-root rule) |
|---|---|---|
| S1 store root, 2 sessions | rc 0 `OK 1 of 1 ... (2 commands read)` | rc 1 `FATAL log <T>/two/session is a session store root holding multiple sessions, not a single session directory` |
| S2 store root, 1 session | rc 0 `OK 1 of 1` | rc 1, same FATAL: says "multiple" for 1 session |
| S3 the reviewer's own session dir `unified/<uuid>` | rc 0 `OK 1 of 1` | rc 0 `OK 1 of 1` |
| S4 a live journal file `journal/<n>.jsonl` | rc 3 (my fixture's journal holds no command) | rc 3, identical: no new refusal |
| S5 a compacted journal path (file gone) | rc 0, read as the session dir | rc 0, the same |
| S6 `session/unified` | rc 1 `holds 2 sessions` (existing rule) | rc 1, the same |
| S7 another agent's session | rc 3 `FAIL 0 of 1` | rc 3, the same |

The real store root on this box, plan's command with `log: m-999@<box>:~<HARNESS_USER>/.vibe/logs/session`: on `e8283427d` it is **read whole**, `FAIL 0 of 1 ... (235296 commands read)`, rc 3, 43.9 s. The plan's rc 0 `OK` was on <box2>; here the `go test ./internal/store` command is no longer in any session, so it misses, but the store root is not refused. With the scratch fix: rc 1, the FATAL above, 3.8 s. n=1 each. Existing `spl-review-line-check.tst.sh`: 33 PASS / 0 FAIL on both trees.

**False refusals:** none of the reviewer's own forms (S3, S4, S5) is refused. **Changes:** (1) the FATAL must not say "multiple sessions" when it found one (S2); say "a session store root (N sessions under it)". (2) Fix the site lines (3.1). (3) Section 6 must say b08-01 is NOT landed (it names `4cfff5c58`, which is `fix(s025-lock-b8-i18n, SPL-3149, SPL-3015): align Swedish sv box terms`, a one-file `sv.json` change). Batch 2 rebases onto `f2cc74761` once it lands.

## 4. Section 4 items

- **(b) disagree.** `test-agent-winch.sh` on `215670645` (= origin/master), as the harness user: `6 passed, 0 failed, 0 skipped`, rc 0, n=3. The same with `TMPDIR=$(mktemp -d /tmp/ppf.XXXXXX)` (mode 700, the gate's own line, `check-pre-push-features.func.sh:95`): **`2 passed, 2 failed`**, rc 1, n=3. A `PRE_PUSH_TIER=full` run as the harness user goes red with no code change: that is a gate/test defect (the test's `mktemp -d` at line 35 lands under a 700 parent the agent user cannot traverse, so its `chmod 755` cannot help). It is a candidate row, or an owned-elsewhere line with an owner. Cite fix: `_ppf_all` / `_ppf_parts` are in `check-pre-push-features.func.sh:47,73-80` (full tier at 76), not `check-pre-push.func.sh:317`.
- **(c) agree.** `spl-ask-close.func.sh:6-7`: "Closing an ask another holder already closed is exit 3 and prints who closed it and why". `spl-ask-ack.func.sh:29-30`: `do_log "WARN ask ${id:0:8} is already <state> by <closed_by>: <reason>"`, `return 3`. Two fixes: the plan's quote "`rc 3: ask already closed`" is not in the file, and ack's exit 3 is not documented in its header (`grep -n -iE 'exit 3|rc 3'` -> no doc line, only `return 3` at 30 and 46).
- **(d) agree with changes.** The refusal is `spl-spawn-enqueue.func.sh:68`: `[[ "$flag" != bypass || "$class" == feature ]] || { do_log "FATAL SPAWN_BYPASS goes with SPAWN_CLASS=feature only" >&2; return 1; }`. Line 78 is `fi`, the queue call is 79. `fleet-rules-index.md:52` reads "`SPAWN_BYPASS=<owner msg id>`: a feature outside the bands, ONLY on the owner's explicit ask". The plan's quote ("Review seats and bug fixes run under their own bands") is not in the file. I believe, unchecked, that the dispatcher was told to enqueue review seats with a bypass (owner GO `994f2257`); `git grep 994f2257 e8283427d -- csi-spl-doc csi-spl-orc` -> nothing. If so, the code and that go disagree: ask the dispatcher which holds, rather than calling it "operator error".

## 5. Signature

v1.0 not yet folded. I sign in my own commit once a-304 lands v1.0 with the changes above or answers each one.
