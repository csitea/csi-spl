# Bug-fix round 21 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5957 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `148f6fe9-d148-4cf8-a718-c87a7ad99cbe` ("Bug round 21", opener msg e80060b7, opened by c-002@sat 2026-11-19T11:22:49Z). Round 20 ([bug-round-20-plan.md](bug-round-20-plan.md) v1.0, 1 row) is closed: its row b20-01 landed `2f634fbd4` (tree = reviewed `46ca6ad59`), quality gate 44510382053 success, SPL-5951 and SPL-5953 done; its topic `22556ffa` archived 11:22:36Z (msg 0573d230). Bug share: c-001 spawn-share 8127dce1 (bug 15%).  
Round focus: the first inputs round 20 left (its section 7) and b20-01's R7 notes: the review GO automation counts a delivered GO as failed, and the pre-push hook's commit-message sweep reads commits already on master.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Two inputs give a live, unowned defect with a red control that fails on `origin/master`: 2 rows.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-20-plan.md](bug-round-20-plan.md) and [bug-round-19-plan.md](bug-round-19-plan.md) (same shape, same 5 sources).

**Status: v0.1**, for the panel.  
Editor: **c-912@sat** (claude, `specs_and_docs`).  
Panel: asked of the dispatch holder (section 8).

**One sha:** every count below is measured on **`99f30c7a0`** (`origin/master`, committed 2026-11-19T13:14:21+02:00), on sat, between 11:26Z and 11:45Z on 2026-11-19, unless a row says otherwise. n=1 per command unless stated. `origin/master` moved to `80c903ddc` (r65-01) during the read; `git diff --stat 99f30c7a0 80c903ddc` over every file the rows edit or read (`spl-review-go.func.sh`, `spl-review-go.tst.sh`, `hooks/pre-push`, `lane-wip-push.tst.sh`, `spool-send.sh`, `check-commit-msg-hygiene.func.sh`, spec 157 `spec.md`, `pre-push-gate.md`) -> empty (11:4xZ), so section 3 holds on both.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b20-plan')` -> `Window: W=2026-11-19T11:24:14+01:00`.

---

## 1. How to read this

- Round 20 re-measured every input on `6b5656493`. This plan re-measures only what changed since (`git rev-list --count 6b5656493..99f30c7a0` -> 21 commits), and names each round 20 input it closes and why it stays closed (section 4).
- **Paths** are repo-relative. Line numbers are as of `99f30c7a0`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- `<box2>` is the fleet's other box.

---

## 2. Where the rows come from (measured on `99f30c7a0`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since 07:00Z** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-19T07:00:00Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (11:33Z), then every non-probe post read (38) | t1 25 (24 `[spool-probe]`, 0 regex hits), csitea 37 (2 regex hits) | **0 rows.** t1: one poll answer (07:06Z, a translation review order). csitea: a blog draft review, a customer project's test work and polls. The one defect report of this tree is csitea topic `51150550` (10:30Z..10:32Z): when another user clicks a form or approves, the status is not updated for the other user, and the form state should persist across reloads. It is owned: lane c-335@<box2> `c-335-c002-wui-poll-state-shared-persisted`, SPL-5954 (the brief's live lane list; the lane map row), so it is left out (R3). |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 100 runs (2026-11-18T11:04Z..2026-11-19T11:28Z): 63 success, 23 cancelled, 12 failure, 2 running (11:37Z); every timeout headroom line `ok` | **0 rows.** No new signature since round 20: the newest failed run is 44490281353 (08:45Z, `wui 8/8` "4j Shift+O opens the issue"), which round 20 read; every failed job's last green is 44510382053 on `2f634fbd` (10:57Z), `wui 8/8` 44508606914 (10:45Z). The rest are round 20's (`orc 2/4` canary line 2026-11-18T21:45Z; `orc 3/4` "noon differs", `orc 1/4` real manifest and the `iac` control setup of 2026-11-18, fixed or served). |
| **3. Skipped or disabled tests** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 99f30c7a0 -- "$d" \| wc -l; done`; `git diff 6b5656493 99f30c7a0 -G '<the same pattern>' --stat` | api 200, wui 18, orc 10, iac 21, utl 0 (round 20: the same) | **0 rows.** The diff names one file, `csi-spl-doc/doc/md/bug-round-20-plan.md` (the pattern in its own table), no test. |
| **4. Box cron logs, last 24 h** | sat: for each `/var/csi/csi-spl{,-desk-cron}/*/cron.{out,log}` changed in the last 24 h (`find -maxdepth 3 -mmin -1440`), `tail -3000 \| grep -caE 'unbound variable\|command not found\|syntax error\|Traceback\|panic:\|status 141\|operand expected\|Permission denied'` (11:33Z) | 39 logs, 0 hits | **0 rows.** Two logs (`orch-rotate/cron.out`, `dispatch-rotate/cron.out`) hold non-UTF-8 bytes, so a plain `grep -c` prints nothing for them; with `-a` they read 0 too. |
| **5. Round 20's first inputs, b20-01's R7 notes, the holder's candidate list** | round 20 section 7; c-338's R7 notes N2 and N3 on b20-01 (msg 2ce21e25, as relayed in this planner's brief); `/var/spool-hub/dispatch/c002-next-round-candidates.md` (5569 B, mtime 2026-11-19T08:33Z: unchanged since round 20 read it) | 4 inputs | **2 rows**: 01 from b20-01 N2, 02 from round 20's (b). The relayed retired-author send and N3: section 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `99f30c7a0`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b21-01-orc-review-go-delivered-go-not-resent)` | `_spl_review_go_send` treats every non-zero exit of `spool-send.sh` other than 14 as a failed GO: it logs `GO to <to> failed (rc N); the next run tries again`, returns 9 and writes no `PASS` record (`spl-review-go.func.sh:838`). But `spool-send.sh` exits 5, 6 and 7 AFTER it delivered the message: no live window carries `<to>`, the pane holds unsent typed text, the agent has exited (its header, `spool-send.sh:77-81`; the pane leg's `exit "$rc"` at its end). So a delivered GO is sent again on every cron tick (`* * * * *`, `spl-review-go-install-cron.func.sh:41`) until the message ages out of `REVIEW_GO_MAX_AGE` (60 min, `:102`), and while the pane stays unrung no `PASS <ts> <msg> ...` line reaches `automation.log`, the record Rule 2 (the automatic ACCEPTED) reads (header `:84-89`). This is b20-01's R7 note N2 (c-338@<box2>, msg 2ce21e25: exits 5/6/7 are counted as a failed GO, `:838` at `2f634fbd4`). | sat, n=1: `grep -E 'GO to .* failed' /var/csi/csi-spl/review-go/cron.out` -> 53 lines (the log has no timestamps; the rc is in the text only since `2f634fbd4`): 52 to c-836@sat (round 20's retired author) and 1 `msg 55946ac2-...: GO to c-788@sat failed; the next run tries again`. The holder's outbox holds two GO messages for that one review, `c-002/outbox/20261114T194505Z--c-002--go-7ab3018f...-c6539fef.json` and `20261114T195206Z--...-d8b86e64.json` (both to c-788, task `dispatch-48d75e5f`, body `GO 7ab3018f23859741b6a4e5f467548f1c6c0709c0`), and `automation.log` one `PASS 2026-11-14T19:52:07Z 55946ac2-...` line: the first send wrote its outbox copy, so it was delivered, yet it was logged as failed and sent again. Which of 5, 6 or 7 it exited is not recorded (the old WARN had no rc). The one other repeated GO name in the three role seats' outboxes (392 GO files; sha `0b221a15`, 23:08:02Z and 23:08:05Z) is a hand GO beside the automatic one, not this path. | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:838` (the retry), `:817-824` (its comment), `:93-96` (header); `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh:77-81` (read only); test `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (case 9, `:306-322`, and a new case beside it); doc `csi-spl-doc/specs/157-dispatch-automation/spec.md:256` (exit 9) | `rc01.sh` (section 3.2): the suite's fixture (`spl-review-go.tst.sh:1-215`) plus a case that runs the scan 3 times with the sender stub exiting 5, then 6, then 7. On `99f30c7a0`: `FAIL: b21-01: send rc 5 (delivered) -> 3 GO(s) delivered in 3 ticks; automation.log PASS lines: 0; out: 1 'tries again' in the last tick` (the same for 6 and 7), `FAIL: 3`. Its controls pass: rc 1, 2 ticks -> 2 sends, nothing logged; rc 14 -> one send, one `action=refused rc=9` line (b20-01 unchanged). | Exits 5, 6 and 7 mean delivered: the GO is recorded as sent (the `PASS` line, the `OK` log line) with a WARN that names the rc and that the pane was not rung, and is never sent again. Any other non-zero exit stays a retry (case 9); 14 stays b20-01's hold. The header (`:93-96`), the function comment and spec 157 `spec.md:256` say which. The lane reads `spool-send.sh` to confirm which exits follow a delivery and does not edit it. Live proof (R5): the next GO whose pane is not rung logs one `PASS` and one GO, not one a minute. | sat (the cron and its log run where the dispatch lease is) | claude | grok (cross-vendor), backup: another non-claude seat the holder names | `simple_coding` | 1 |
| 02 `fix(b21-02-orc-pre-push-msg-sweep-skips-master)` | The hook's commit-message sweep (SPL-5613) reads, for a ref the remote already has, `<remote sha>..<local sha>` (`hooks/pre-push:215`), with no `--not <remote>/master`, unlike a new ref (`:216-217`). A lane whose old `wip/<branch>` tip predates master commits that it later fast-forwarded or rebased onto sweeps THOSE landed commits' messages too. Some master messages carry a banned literal: `HYGIENE_MSG_RANGES=1323145f4..6a3220796 ./run -a do_check_commit_msg_hygiene` (csi-spl-iac, the 21 master commits of 2026-11-15 19:00..21:30 +02:00) -> refused, among others `personal home directory -- 8 line(s)` and `hidden workspace or private literal (SPL-1874) -- 4 line(s)`. So the wip push is refused with "Reword that commit" for commits the lane cannot reword: they are on master. Commits already on the public master are already published; sweeping them again protects nothing. This is round 20's input (b). | <box2>, read for round 20 (its section 5 (b), n=1): c-390's wip push refused (`c-001/outbox/20261119T082711Z--c-001--relayed-f4a8fcb8.json`, 08:27:11Z) on 10 shas, all ancestors of `origin/master`, committed 2026-11-15T19:16..21:18+02:00; c-390's branch made at `f7c388910` on 2026-11-15 and moved to master `b97a764ff` by fast-forwards and a rebase. Not re-read from sat (the file is on <box2>). The red control below reproduces the mechanism on the hook alone; round 20's two suite attempts used a clean landed message, which is why they did not fail. | `csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push:211-221` (the range loop; the fix at `:215`), `:191-193` (its comment); `csi-spl-iac/src/bash/run/check-commit-msg-hygiene.func.sh` (read only: it takes `<a>..<b>` and `<sha>^!` ranges); test `csi-spl-orc/src/bash/tests/lane-wip-push.tst.sh` (case 11, `:215-238`, and a new case beside it); doc `csi-spl-doc/doc/md/pre-push-gate.md:148-150` | `rc02.sh` (section 3.2): a `git clone --shared` of the repo at the sha under test, `refs/remotes/origin/master` set to it, a clean lane commit `L` on master `6a3220796` (made with `commit-tree`, so the work tree, the hook and the sweep stay the sha under test), and the hook fed `refs/heads/lane L refs/heads/wip/lane <old tip>`. On `99f30c7a0` with old tip `1323145f4`: `FAIL: b21-02: old wip tip 1323145f4 -> rc 1, 28 hit line(s) on commits already on master, e.g. c27701c45275210ded97d846ee865e36199805a1.msg`, `FAIL: 1`. Its controls pass: the same lane commit with the old tip = its base -> rc 0; a lane commit whose OWN message names a home directory -> refused (rc 1). | For a ref the remote has, sweep only the commits of `<remote sha>..<local sha>` that are not on `refs/remotes/<remote>/master` (listed as `<sha>^!`, as the no-remote-master branch at `:219` already does); with no such ref, the range as today. A new ref and a delete are unchanged; a push to master reads the commits it adds over the remote master, as today. The comment (`:191-193`) and `pre-push-gate.md:148-150` say so. The lane's suite case (a landed master commit whose message has a banned literal, between the old wip tip and the new one) is RED before the fix; case 11 (the lane's own banned message is refused) stays green. R9: a gate row, so its tests run under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. | sat | claude | grok (cross-vendor), backup: another non-claude seat the holder names | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** both rows; their files are disjoint.
  - Row 01: `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`, `csi-spl-doc/specs/157-dispatch-automation/spec.md`. It reads `spool-send.sh` but does not edit it.
  - Row 02: `csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push`, `csi-spl-orc/src/bash/tests/lane-wip-push.tst.sh`, `csi-spl-doc/doc/md/pre-push-gate.md`. It reads `check-commit-msg-hygiene.func.sh` but does not edit it.
- **Test column (R2):**
  - Row 01: `git grep -lE 'spl-review-go(\.func)?\|do_spl_review_go\b' -- '*tests/*'`; the lane runs every file it prints.
  - Row 02: `git grep -lE 'hooks/pre-push\|commit_msg_hygiene\|SPL-5613' -- '*tests/*'` (among them `csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh`, `csi-spl-orc/src/bash/tests/lane-wip-push.tst.sh`, `csi-spl-orc/src/bash/tests/spl-push-master.tst.sh` and the `spawn-agents/tests/test-pre-push-*.sh` files); the lane runs every file it prints.
- **Off limits** for the row lanes: every live lane's files (below); `spool-send.sh`, `spool-fleet-relay.sh` and `check-commit-msg-hygiene.func.sh` (read only; each fix stays in its caller).
- **How the files were checked (2026-11-19, sat):**
  - 11:34:13Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-doc/specs/157-dispatch-automation/spec.md,csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push,csi-spl-orc/src/bash/tests/lane-wip-push.tst.sh,csi-spl-doc/doc/md/pre-push-gate.md,csi-spl-doc/doc/md/bug-round-21-plan.md --agent c-912` -> `WARN no live lane lists` them; exit 4 for 10 lanes that record no files, all on <box2>: the customer workspace seats c-049, c-060, c-812, c-924, c-927, c-939; c-293 (SPL-5949, refactor round 65), c-294 (SPL-5952, SPL-5883 row T17), c-318 (SPL-5945, SPL-5883 row T1), c-335 (SPL-5954, WUI poll form state). Their scopes are read from the lane map's `scope` and `issue_key` (`LANE_FORMAT=json LANE_ALL=1 do_spl_lane_map`, 11:3xZ), as are sat's c-852 (SPL-5945), c-855 (SPL-5946), c-914 (r65-02, graft's state root) and c-917 (SPL-65, contributor docs): none is the review GO or the pre-push hook. The orchestrator re-runs the check before the spawn (R3).
  - 11:34:46Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 0 queued, 0 placing.
- **Slug b21 is unused as a round id** (sat, 11:26:04Z):
  - `git log origin/master --since="$W" --oneline -E --grep='\(b21-'` -> 0;
  - `git ls-remote origin 'refs/heads/review/b21-*' 'refs/heads/wip/*b21*' 'refs/heads/*-b21-*'` -> nothing; `git ls-remote origin \| grep -cE 'b21-[0-9]{2}\|bug-round-21'` -> 0;
  - `grep -rlE '(^|[^0-9a-f])b21-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs`, `/var/spool-hub/asks` and `/var/spool-hub/spawn-remote/briefs` -> 0 files; `bug-round-21` -> 2 files, this planner's brief and `asks/.place.slugs` (its placement);
  - `git branch -a \| grep -cE 'b21-[0-9]{2}'` -> 0.
  - <box2>: asked of the holder (section 8).

  After this plan's pushes, `--grep='(b21-'` matches the plan's commits (`docs(b21-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b21-[0-9]{2}'` stays 0 until a row lands.

### 3.2 Red controls run on `99f30c7a0`

| row | command (repo untouched) | output on `99f30c7a0` | output with a prototype fix | who |
|---|---|---|---|---|
| 01 | `bash rc01.sh`, put in `csi-spl-orc/src/bash/tests/` of a `git archive 99f30c7a0 csi-spl-orc` copy | `FAIL: b21-01: send rc 5 (delivered) -> 3 GO(s) delivered in 3 ticks; automation.log PASS lines: 0; out: 1 'tries again' in the last tick` (the same for rc 6 and rc 7) / `PASS: b21-01 control: a send that delivered nothing (rc 1) is retried, nothing logged` / `PASS: b21-01 control: b20-01's rc 14 hold is unchanged` / `FAIL: 3` | on the copy, one line before `:838`: `case "$src" in 5\|6\|7) do_log "WARN msg $2: GO to $to delivered, its pane not rung (rc $src)"; src=0 ;; esac` -> `PASS: b21-01: send rc 5 (delivered, pane not rung): one GO, the PASS recorded, no resend` (6 and 7 the same), both controls PASS, `PASS: all`; the whole `spl-review-go.tst.sh` on the copy: `spl-review-go: 0 failure(s)` | editor c-912 |
| 02 | `bash rc02.sh 99f30c7a0`, from any checkout of this repository (it clones the common dir's objects with `--shared` into a temp dir and removes it) | `PASS: control 1: clean lane commit, remote wip tip = its base -> rc 0` / `PASS: control 2: the lane's own dirty message is refused (rc 1)` / `FAIL: b21-02: old wip tip 1323145f4 -> rc 1, 28 hit line(s) on commits already on master, e.g. c27701c45275210ded97d846ee865e36199805a1.msg` / `FAIL: 1` | `bash rc02.sh 99f30c7a0 pre-push.proto` (the hook with `:215` replaced by: when `refs/remotes/<remote>/master` resolves, `git rev-list "$_pp_rsha..$_pp_lsha" --not "refs/remotes/$_pp_mrem/master" \| sed 's/$/^!/' \| tr '\n' ' '`, else the range as today) -> controls 1 and 2 PASS, `PASS: b21-02: old wip tip 1323145f4...: landed master messages are not swept (rc 0)`, `PASS: all` | editor c-912 |

The scripts are on sat in `/var/spool-hub/dispatch/b21-red-controls/`: `rc01.sh` (15389 B, `sha256sum` -> `92fd284d8549...`; lines 1-215 of `spl-review-go.tst.sh` at `99f30c7a0`, the fixture, then the b21-01 case), `rc02.sh` (2611 B, `570ca3613a37...`) and `pre-push.proto` (`c3b5f1a50016...`, the hook of `99f30c7a0` with the 5-line prototype). The prototypes only show that PASS is reachable without breaking the suite; each lane writes its own fix and its own suite case.

---

## 4. Round 20's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b20-01 (review-go retries a GO to a retired author) | `git log origin/master --oneline -E --grep='\(b20-01-'` | landed `2f634fbd4`, gate 44510382053 success (the brief) | Served (round 20 closed). Row 01 is its R7 note N2, another exit path (5, 6, 7: delivered), not a re-open; b20-01's rc 14 case is a control of row 01's red control and stays green. |
| Round 20 / round 19 section 4 (the holder's older items: r34-05, b12-02, SPL-5825, SPL-5824, SPL-5828, r34-01, SPL-5850; b17-01 N1; r63-01 W1; p18-02 N1) | the holder's list is unchanged since round 20 read it (5569 B, mtime 08:33Z) | unchanged | Closed as rounds 19 and 20 say: served by refactor rounds, wording only, or refactor-shaped. r34-01 N1/N2 are test-coverage gaps with no failing behaviour: input for a test round, not a bug row. |
| Round 20 watch items: the c-091 staged index; CI `wui 8/8` "4j Shift+O"; CI `orc 2/4` "canary key leaked" | source 2 (CI); the index not re-measured (a <box2> worktree) | section 5 | Watch items. |
| desk-cron `bin/spool` older than its sources | every orc run prints the WARN (`built 2026-10-31T02:27:08Z`) | as in rounds 12 to 20 | As before. |

---

## 5. Not reproduced, or no red control yet

| candidate | command | result |
|---|---|---|
| **The relayed retired-author send** (round 20 section 7, its v1.0 N2: `spool-send.sh:521` exits `10 + rc` of the relay, `spool-fleet-relay.sh:224-231` maps every non-roster failure to 1, so review-go would retry a retired author on another box every minute) | `sed -n 220,235p csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh` at `99f30c7a0`; sat `review-go/cron.out`: `grep -E 'GO to .* failed'` -> 53 lines, every author `@sat` | **Not a row: no observed case and no red control.** The mapping is as round 20 read it (`:224-231`: a roster miss 3, else 1). No GO to an author on another box has failed in sat's log, so the retry is a code reading, not an observed defect; and a fix needs the relay (a fleet-wide script) to tell the hub's retired refusal from a transient hub error, which needs the hub's answer text for a retired id first. First input for round 22: read the relay's `out` for a send to a retired id (`retired.go:84`) and build the control on `spool-fleet-relay.sh` alone. |
| **b20-01 R7 N3: the `spool-send.sh` header (`:76-110`) does not list exit 14** | `sed -n 76,110p csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh \| grep -c '14'` -> 0; the exit is at `:536` | **Not a bug row: wording only.** The `10+` line (`:109`) covers it as `10 + 4`, but not by name. A one-line header fix for whichever lane next edits `spool-send.sh` (a fleet-wide script), or a later round. |
| CI `wui 8/8` "4j Shift+O opens the issue"; CI `orc 2/4` "the canary key leaked: ps.log" | source 2 | No new sighting since round 20: `wui 8/8` stays at 2 (a fixing lane on the 3rd, rulebook 2.11.3), `orc 2/4` at 1. Watch items. |
| c-091@<box2>'s staged index (round 20 section 5 (a)) | not re-measured (a <box2> worktree) | Watch item, as round 20 said; reported to the orchestrator then. |

---

## 6. Owned elsewhere, or reported (R3)

| item | owner | status |
|---|---|---|
| The WUI poll form state, not shared between users nor persisted (csitea topic `51150550`, 10:30Z) | c-335@<box2>, SPL-5954 | Live lane; not a row. |
| The live lanes of the brief (c-852, c-855, c-294, c-318 SPL-5883; c-336/c-347 r65-01 SPL-5955; c-914 r65-02; c-335/c-350 SPL-5954; c-054/c-341 SPL-5781; the customer workspace seats) | their lanes | None touches the rows' files (section 3.1). r65-01 landed `80c903ddc`. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 4 round 20 / R7 inputs; 38 human posts; 100 CI runs (12 failed, 0 new signatures); 39 cron logs (0 hits) |
| watch items | 3 (the c-091 staged index; the `wui 8/8` flake; the `orc 2/4` canary line), all carried from round 20 |
| first inputs for round 22 | the relayed retired-author send (no red control yet); b20-01 N3 (wording) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-912@sat (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder c-002@sat on task `dispatch-bug-r21`, with at least one non-claude seat. The panel checks both red controls (`rc01.sh` on a `git archive 99f30c7a0 csi-spl-orc` copy and `rc02.sh 99f30c7a0`: RED; it may rebuild them from section 3.2), the fix scopes (row 01: only 5, 6 and 7 count as delivered; row 02: only commits already on the remote master are left out), the evidence (row 01's two outbox files and `automation.log` line on sat; row 02's refusal on <box2> and the master range sweep), and that every other input in sections 2, 4, 5 and 6 is measured as written.
- **Row reviewers (R7):** a grok seat per row (cross-vendor to the claude authors); backup named by the holder.
- **Review history:**
  - 2026-11-19: the editor pushed v0.1 to `review/c002-bug-round-21-planner`.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-912@sat | **v0.1** |
| Panel | asked of the holder | pending |
