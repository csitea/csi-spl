# Bug round 21 (b21): mistral panel seat (m-923)

Seat: m-923@sat, placement `c003-bug-round-21-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c003-bug-round-21-mistral-panel-seat.md`
(Issue SPL-5957, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `148f6fe9-d148-4cf8-a718-c87a7ad99cbe`).

Review target: plan v0.1 `2bfd43c226fa2f3116d3f4f7981c213760b14136`, named in the
brief. Provenance: `git ls-remote origin | grep bug-round-21` ->
`2bfd43c226fa2f3116d3f4f7981c213760b14136  refs/heads/review/c002-bug-round-21-planner`;
`git merge-base origin/review/c002-bug-round-21-planner origin/master` ->
`e178584dfc5cdeeb8697ef3292242f06058a384b` (= origin/master at my read, so the plan
is NOT on master and its base is current trunk); `git diff --stat origin/master...origin/review/c002-bug-round-21-planner`
-> 1 file, +139, `csi-spl-doc/doc/md/bug-round-21-plan.md` (139 lines, read in full
at that sha). Measured-on sha `99f30c7a0c38e24f3b6a0f20c3944486b86bd00f`:
`git cat-file -t` -> commit, `git log -1 --format=%cI` -> `2026-11-19T13:14:21+02:00`,
`git merge-base --is-ancestor 99f30c7a0 origin/master` -> exit 0 (on trunk).
At 2026-11-19T12:10Z no later plan version was named to me (inbox `[]`), so the
first sign-off below is v0.1. At 2026-11-19T12:25Z the editor c-912@sat named
plan v1.0 `67232dbc8b2f2e6c8681f531f5971cad6f98eeac` (msg 3edea98b, task
`dispatch-bug-r21`); it is verified and signed in the last section.

## Verdict

**PASS on `2bfd43c226fa2f3116d3f4f7981c213760b14136`** (plan v0.1, 2 rows) and
**PASS on `67232dbc8b2f2e6c8681f531f5971cad6f98eeac`** (plan v1.0, same 2 rows).
Both rows' defects are real as described on `99f30c7a0`, both red controls are
falsifiable exactly as the plan claims (RED on `99f30c7a0`, GREEN only with the
prototype fix, controls green in both), the n=1 evidence re-reads from sat, every
cited file:line and sha exists as cited, and every dropped candidate is really
fixed, owned, or rightly deferred. Defects W1..: none. Notes N1..N6 below.

## Checks (each with the command run and what it printed, 2026-11-19 11:5x-12:1xZ, sat)

### 1. Slug b21 unused since W

`W=2026-11-19T11:24:14+01:00`, re-derived: `git log origin/master -1 --format=%cI -E --grep='^docs\(b20-plan'`
-> `2026-11-19T11:24:14+01:00` (matches the plan's W).

- `git log origin/master --since="$W" --oneline -E --grep='\(b21-' | wc -l` -> `0`.
- `git ls-remote origin | grep -cE 'b21-[0-9]{2}'` -> `0`;
  `git ls-remote origin | grep bug-round-21` -> one line, the planner's
  `review/c002-bug-round-21-planner` at `2bfd43c2` (expected, not a row slug).

### 2. The rows, read on `99f30c7a0` AND on the plan's base `e178584df` at the cited lines

`git diff --stat 99f30c7a0 origin/master -- <the 8 row files>` -> empty, so the
cited lines are identical on both; spot-checked on both shas anyway
(`git show <sha>:<file> | sed -n <N>p`).

**Row b21-01** (`spl-review-go.func.sh:838`):

- `git show 99f30c7a0:csi-spl-orc/src/bash/run/spl-review-go.func.sh | sed -n '838p'`
  -> `  (( src == 0 )) || { do_log "WARN msg $2: GO to $to failed (rc $src); the next run tries again"; return 9; }`
  — exactly as the plan describes: every non-zero exit other than 14 is a failed
  GO, retried next tick, no PASS record. Same line on `e178584df`.
- `:817-824` (comment) and `:93-96` (header) read as cited; `:102` is
  `# @param REVIEW_GO_MAX_AGE (optional) - minutes; ... default 60`; the every-minute
  cron line is `spl-review-go-install-cron.func.sh:41`
  (`* * * * * ... do_spl_review_go >> .../cron.out`).
- `spool-send.sh:77-81` at `99f30c7a0` -> exits `5`/`6`/`7` documented as
  "delivered; no live window / REFUSED to poke / bare shells only"; the pane leg
  ends in `exit "$rc"` at `:645`, after the send and the outbox copy (`:274-278`),
  so 5/6/7 exit AFTER delivery. Defect real.
- Test case 9 at `spl-review-go.tst.sh:306-322`: rc 1 -> rc 9, nothing logged
  (retry); rc 14 -> one GO, one hold, one `action=refused rc=9` line. Spec 157
  `spec.md:256` is the Exit-codes bullet naming exit 9 (and the 14 hold). All as
  cited.
- **Transient-failure question:** the red control's controls answer it — rc 1
  stays "retried, nothing logged" and rc 14 stays b20-01's hold, on the unfixed
  code AND with the prototype fix (see check 3). The proposed fix (only 5/6/7
  count as delivered) is the smallest that closes it: one `case` line before
  `:838` in the prototype.

**Row b21-02** (`hooks/pre-push:215`):

- `git show 99f30c7a0:.../hooks/pre-push | sed -n '215p'`
  -> `      _pp_mr+="$_pp_rsha..$_pp_lsha "` — the existing-ref range with no
  `--not <remote>/master`; `:216-217` is the new-ref branch
  (`refs/remotes/$_pp_mrem/master..$_pp_lsha`), `:219` the no-remote-master branch
  (`git rev-list "$_pp_lsha" --not --remotes ... ^!`), `:191-193` the comment.
  Same lines on `e178584df`. Defect real as described.
- Independent reproduction of the banned-literal master range:
  `cd csi-spl-iac && HYGIENE_MSG_RANGES=1323145f4..6a3220796 ./run -a do_check_commit_msg_hygiene`
  -> action rc=1, `::error::hygiene: personal home directory -- 8 line(s)`,
  `::error::hygiene: hidden workspace or private literal (SPL-1874) -- 4 line(s)`
  (plus `personal name -- 1`, `literal OS user / box / AD id -- 15`), 28 `.msg:N`
  hit lines total, among them `c27701c45275210ded97d846ee865e36199805a1.msg:23`.
  `git rev-list --count 1323145f4..6a3220796` -> 21; `6a3220796` is an ancestor of
  origin/master. Matches the plan's evidence.
- Test case 11 at `lane-wip-push.tst.sh:215-238` (the lane's own banned message
  refused, wip ref unchanged) and `pre-push-gate.md:148-150` read as cited.
- **Own-commits question:** rc02's control 2 answers it — with the prototype
  hook, a lane commit whose OWN message names a home directory is still refused
  (rc 1). The proposed fix (sweep `<remote sha>..<local sha>` minus
  `refs/remotes/<remote>/master`, listed `^!` as `:219` already does) is the
  smallest that closes it: the 5-line replacement at `:215` in `pre-push.proto`.

### 3. Red controls (read from sat, run on a `git archive 99f30c7a0 csi-spl-orc` copy under mktemp)

`/var/spool-hub/dispatch/b21-red-controls/`: `rc01.sh` 15389 B sha256
`92fd284d85493a8dd73b7568e4e9a2e97a43ae33389ce42f964bc8631fdcb186`, `rc02.sh`
2611 B sha256 `570ca3613a3722a91821e2d1f93ac4bf1c970066572651960a80261774644015`,
`pre-push.proto` 21523 B sha256 `c3b5f1a50016fdc348c99cc0f6283c4f002c61126ee61e301575507c70f62077`
— all three match the plan's printed prefixes. `diff <(git show 99f30c7a0:.../spl-review-go.tst.sh | sed -n '1,215p') <(sed -n '1,215p' rc01.sh)`
-> identical (the fixture is the suite's own lines 1-215). `diff <(git show 99f30c7a0:.../hooks/pre-push) pre-push.proto`
-> only `:215` replaced by the 5-line prototype.

- `bash rc02.sh 99f30c7a0c38e24f3b6a0f20c3944486b86bd00f` ->
  `PASS: control 1: clean lane commit, remote wip tip = its base -> rc 0` /
  `PASS: control 2: the lane's own dirty message is refused (rc 1)` /
  `FAIL: b21-02: old wip tip 1323145f4 -> rc 1, 28 hit line(s) on commits already on master, e.g. c27701c45275210ded97d846ee865e36199805a1.msg`
  / `FAIL: 1`, exit 1 — RED exactly as the plan claims.
- `bash rc02.sh 99f30c7a0... pre-push.proto` -> controls 1 and 2 PASS,
  `PASS: b21-02: old wip tip 1323145f4...: landed master messages are not swept (rc 0)`,
  `PASS: all`, exit 0 — GREEN only with the fix.
- rc01.sh copied into `csi-spl-orc/src/bash/tests/` of a mktemp `git archive 99f30c7a0 csi-spl-orc`
  copy, `bash rc01.sh` -> for rc 5, 6, 7 each:
  `FAIL: b21-01: send rc N (delivered) -> 3 GO(s) delivered in 3 ticks; automation.log PASS lines: 0; out: 1 'tries again' in the last tick`,
  plus `PASS: b21-01 control: a send that delivered nothing (rc 1) is retried, nothing logged`
  and `PASS: b21-01 control: b20-01's rc 14 hold is unchanged`, then `FAIL: 3` —
  RED exactly as the plan claims.
- Same copy with the plan's one-line prototype inserted before `:838`
  (`case "$src" in 5|6|7) ... src=0 ;; esac`): `bash rc01.sh` ->
  `PASS: b21-01: send rc 5/6/7 (delivered, pane not rung): one GO, the PASS recorded, no resend`
  x3, both controls PASS, `PASS: all`, exit 0; and the whole suite
  `bash spl-review-go.tst.sh` -> `spl-review-go: 0 failure(s)`, exit 0 — both as
  the plan claims.

Both controls are falsifiable: fail on `99f30c7a0`, pass only with the fix, and
their controls (rc 1 retry, rc 14 hold, own dirty message refused) stay green in
both states.

### 4. Row 01's n=1 evidence, re-read from sat

- `grep -cE 'GO to .* failed' /var/csi/csi-spl/review-go/cron.out` -> `53`;
  `grep -E 'GO to .* failed' ... | grep -c 'c-788'` -> `1`, the line
  `WARN msg 55946ac2-756b-40dd-be30-e04fe5c1781a: GO to c-788@sat failed; the next run tries again`.
- Holder outbox: `ls /var/spool-hub/c-002/outbox/ | grep -E '20261114T19(45|52)'`
  -> `20261114T194505Z--c-002--go-7ab3018f23859741b6a4e5f467548-c6539fef.json` and
  `20261114T195206Z--c-002--go-7ab3018f23859741b6a4e5f467548-d8b86e64.json`; both
  read as `{"body":"GO 7ab3018f23859741b6a4e5f467548f1c6c0709c0",...,"task_id":"dispatch-48d75e5f","to":"c-788","ts":"2026-11-14T19:45:05Z"/"...19:52:06Z"}`.
- `grep -c 'PASS .*55946ac2' /var/spool-hub/dispatch/automation.log` -> `1`:
  `PASS 2026-11-14T19:52:07Z 55946ac2-... dispatch-48d75e5f c-788 g-890 7ab3018f...`.

So the first send (19:45:05Z) wrote its outbox copy — delivered — yet was logged
as failed and sent again at 19:52:06Z. n=1 confirmed, exactly as the plan says.

### 5. Dropped candidates

- **Relayed retired-author send:** `git show 99f30c7a0:.../spool-fleet-relay.sh | sed -n '224,231p'`
  -> roster miss (`cannot resolve to_box`/`ambiguous_to_box`/`unknown_agent`) exits 3,
  every other relay failure exits 1 — as the plan reads it. `grep -E 'GO to .* failed'
  /var/csi/csi-spl/review-go/cron.out | grep -vc '@sat'` -> `0`: no GO to a
  non-sat author has failed in sat's log, so "no observed case, no red control,
  first input for round 22" is rightly deferred. `spool-send.sh:521` is
  `exit $((10 + rc))` (relay failure), as cited.
- **b20-01 N3 (header omits exit 14):** `git show 99f30c7a0:.../spool-send.sh | sed -n '76,110p' | grep -c '14'`
  -> `0`; the exit is at `:536` (`exit 14`); `:109` is the `10+` line. Wording-only
  call is right.
- **Poll form state (SPL-5954):** `lane-map.sh --all | grep c-335` ->
  `c-335@<box2>  live  37m  csi-spl  c-335-c002-wui-poll-state-shared-persis~  51150550-45~ ...`
  — live lane on the csitea topic `51150550`, owned; rightly not a row.
- **CI, 0 new signatures:** re-measured at 2026-11-19T12:0xZ:
  `gh run list --limit 100 --json databaseId,conclusion,status,createdAt,headSha,workflowName`
  -> 100 runs, window 2026-11-19T10:45:30Z..12:06:27Z: 56 success, 3 failure,
  2 cancelled, 37 skipped, 2 in_progress. The 3 failures (44513056526 on
  `99f30c7a`, 44515106107 on `80c903dd`, 44517684388 on `e178584d`) all fail only
  `wui: browser e2e (mock, generated) 2/8` and `7/8` (`gh run view <id> --json jobs`)
  — the known `wui 8/8` watch-item signature the plan already carries (round 20
  read 44490281353's `8/8`). No new signature: the plan's "0 rows" holds.
  (The plan's own 63/23/12/2 counts were its 11:37Z window; mine is later, see N2.)
- **Cron logs:** `find /var/csi/csi-spl /var/csi/csi-spl-desk-cron -maxdepth 3 \( -name cron.out -o -name cron.log \) -mmin -1440 | wc -l`
  -> `39`; tail-3000 + `grep -caE 'unbound variable|command not found|syntax error|Traceback|panic:|status 141|operand expected|Permission denied'`
  summed over them -> `0` hits. Matches.
- **Skip counts:** `git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" 99f30c7a0 -- <dir> | wc -l`
  -> api 200, wui 18, orc 10, iac 21, utl 0 — identical to the plan;
  `git diff 6b5656493 99f30c7a0 -G '<same pattern>' --stat` -> only
  `csi-spl-doc/doc/md/bug-round-20-plan.md | 160 +++...`, no test. Matches.
- **Source 1 (human posts):** re-ran the plan's query at 12:1xZ
  (`ENV=prd ... do_spl_db_query`, ts > 2026-11-19T07:00:00Z, from HUM%):
  t1 25 posts (0 regex hits, 24 probes), csitea 45 (2 regex hits, 0 probes) —
  csitea grew from 37 to 45 since the plan's 11:33Z read, the 2 regex hits are the
  same non-defects the plan named, and the one defect report (topic `51150550`)
  is owned by c-335@<box2>. Still 0 rows.
- **b20-01 landed:** `git log origin/master -E --grep='\(b20-01-'` ->
  `2f634fbd4 fix(b20-01-orc-review-go-retired-author-no-retry, SPL-5953): ...`;
  `git merge-base --is-ancestor 2f634fbd4 origin/master` -> exit 0;
  `gh run view 44510382053 --json conclusion` -> `success`. Matches.

### 6. Every cited file:line and sha exists as cited; drift since `99f30c7a0`

All row file:lines above were read with `git show <sha>:<file> | sed -n <N>p` on
both `99f30c7a0` and `e178584df` and match. Shas: `99f30c7a0`, `e178584df`,
`80c903ddc`, `2f634fbd4`, `46ca6ad59`, `1323145f4`, `6a3220796`,
`c27701c45275210ded97d846ee865e36199805a1`, `6b5656493` -> `git cat-file -t` = commit;
`2f634fbd4` and `99f30c7a0` are ancestors of origin/master;
`git rev-list --count 6b5656493..99f30c7a0` -> 21 (as the plan says).
`retired.go:84` = `internal/spool/retired.go:84`, the `ErrRetiredRecipient`
quarantine text. `check-commit-msg-hygiene.func.sh` lists each range with
`git rev-list "$r"` (`:39`), so `<a>..<b>` and `<sha>^!` both work, as cited.
`bug-round-19-plan.md`, `bug-round-20-plan.md`, `rounds-rulebook.md` exist on
origin/master. Drift: `git diff --stat 99f30c7a0 origin/master -- <8 row files>`
-> empty; the only commits since are `80c903ddc` (r65-01) and `e178584df`
(r65-02), neither touching them (N1). `8127dce1` is a message id, not a commit
(`git cat-file -t` -> missing) — cited as the spawn-share msg, not a tree sha
(N5). Row 02's box2 evidence file
`/var/spool-hub/c-001/outbox/20261119T082711Z--c-001--relayed-f4a8fcb8.json` is
NOT present on sat (`ls` -> No such file) — NOT RUN from my box, as the plan
itself says; the mechanism is reproduced locally by rc02 and the hygiene range
run above (N3).

### 7. R3 lane-map check

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push --agent m-923`
-> `WARN no live lane lists ... but 9 live lane(s) record no files: their scope is unknown, not free`,
`unknown:` c-049@<box2>, c-060@<box2>, c-293@<box2>, c-294@<box2>, c-318@<box2>, c-335@<box2>,
c-812@<box2>, c-924@<box2>, c-927@<box2> — **exit 4**. No lane that records files owns the
row paths; the 9 unknown lanes are all on <box2> and record no files (ask-first per
the rule). This seat edits none of those paths (docs-only seat file), so exit 4
blocks nothing here; the orchestrator re-runs this before the row spawns (N4).

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`ok - owner mail address or domain` / `ok - hidden workspace or private literal (SPL-1874)`
/ `ok - retired relay estate (SPL-1910)` / `ok - no tracked .vibe/ dir` /
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-923`,
rc 0.

## Defects

None. W1..: no defect found in the plan at `2bfd43c2`.

## Notes

- N1: origin/master moved past `99f30c7a0` during the round (`80c903ddc` r65-01,
  then `e178584df` r65-02); `git diff --stat 99f30c7a0 origin/master` over every
  file the rows edit or read is empty, so section 3 holds on both, as the plan
  says. The plan's base `e178584df` is current trunk at my read.
- N2: my CI re-measure window (10:45Z..12:06Z) is later than the plan's
  (..11:28Z), so the raw counts differ (56/3/2/37/2 vs 63/12/23/2); the 3 new
  failures are all the known `wui 8/8` e2e signature on the three newest master
  commits, so "0 new signatures" still holds.
- N3: row 02's box2 refusal evidence (c-390's wip push, the c-001 outbox file)
  is not readable from sat — NOT RUN from my box; the mechanism is reproduced
  on sat by rc02.sh (RED/GREEN) and by the `HYGIENE_MSG_RANGES=1323145f4..6a3220796`
  run (rc 1, 28 hit lines).
- N4: lane-map exit 4 with 9 unknown lanes on <box2> (check 7); none records the
  row files. Informational for the orchestrator's R3 re-run before spawning.
- N5: `8127dce1` (the spawn-share) is a message id, not a commit; no drift.
- N6: source-1 post counts grew between the plan's read and mine (csitea 37 -> 45);
  regex hits unchanged at 2, still 0 rows.

## Sign-off

- v0.1: signed sha `2bfd43c226fa2f3116d3f4f7981c213760b14136`, verdict **PASS**
  (commit `847cf6ffb` on `review/c003-bug-round-21-mistral-seat`, reported as msg
  93a013e0 on task `dispatch-bug-r21`).
- v1.0: signed sha `67232dbc8b2f2e6c8681f531f5971cad6f98eeac`, verdict **PASS**
  (this commit). Named by the editor c-912@sat, msg 3edea98b-83bd-4fe7-a183-d5d46f85dd34,
  task `dispatch-bug-r21`, 2026-11-19T12:25Z. Verified at 2026-11-19T12:3xZ:
  - `git ls-remote origin | grep c002-bug-round-21` ->
    `67232dbc8b2f2e6c8681f531f5971cad6f98eeac  refs/heads/review/c002-bug-round-21-planner`;
  - `git log --oneline 2bfd43c22..origin/review/c002-bug-round-21-planner` -> one
    commit, `67232dbc8 docs(b21-plan, SPL-5957): bug round 21 plan v1.0, panel
    m-923 mistral PASS on 2bfd43c22 ...`;
  - `git merge-base origin/review/c002-bug-round-21-planner origin/master` ->
    `e178584dfc5cdeeb8697ef3292242f06058a384b` = `git rev-parse origin/master`
    (base = current trunk, plan NOT on master);
  - `git diff --stat 2bfd43c22 67232dbc8` -> 1 file, +15/-6,
    `csi-spl-doc/doc/md/bug-round-21-plan.md` only;
  - `git diff 2bfd43c22 67232dbc8 -- <plan file>` -> 3 hunks: the header status
    (v0.1 -> v1.0, panel PASS recorded), section 8 (review history: my PASS msg
    93a013e0, seat file `847cf6ffb`, N1..N6 folded, the <box2> slug result
    0/0 from c-001@<box2> msg a5b6ac22, the holder change c-002 -> c-003), and the
    section 9 table (Panel: m-923@sat **PASS** on `2bfd43c22`). No hunk in
    section 3's row table or 3.1's files/batches except the slug bullet's <box2>
    line (now filled with 0/0); `diff` of section 3 (rows) between the two shas
    -> only that one line; `diff` of section 3.2 (red controls) -> identical;
    `grep -c 'b21-0'` on the plan at both shas -> 5 and 5.
  - All checks above were run on `99f30c7a0` (still an ancestor of origin/master)
    and on the plan base `e178584df` (still origin/master), neither of which v1.0
    changes, so every check holds unchanged on v1.0.
