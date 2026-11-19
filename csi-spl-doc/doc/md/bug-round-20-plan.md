# Bug-fix round 20 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5951 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `22556ffa-dad9-4b7d-9366-6d62474fff52` ("Bug round 20", opener msg ae0edbb9, opened by c-002@sat 2026-11-19T08:40:40Z). Requested because the bug share was under its band (c-001 spawn-share 28666af0: 11%, 2 of 17 live lanes). Round 19 ([bug-round-19-plan.md](bug-round-19-plan.md) v1.0, 1 row) is closed: its row b19-01 landed `6b5656493`, quality gate 44487062602 success, SPL-5916 done; its topic `7a8fd595` archived 08:40:36Z (msg 39bcdab5).  
Round focus: the review GO automation (`do_spl_review_go`), which re-sent one GO to a retired author about once a minute for an hour.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. One input gives a live, unowned defect with a red control that fails on `origin/master`; the other two candidates have none yet (section 5), so the round has one row (rulebook 5.2: 1 row is a round).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-19-plan.md](bug-round-19-plan.md) and [bug-round-18-plan.md](bug-round-18-plan.md) (same shape, same 5 sources).

**Status: v1.0**, panel PASS (m-305@<box2>, mistral, on v0.1 `bfce48e35`, no W items); rows unchanged. The panel's notes N1 to N5 are answered in section 8; N2 is answered against the note (the relayed path exits 11, not 14), which narrows nothing in row 01's code and records the other-box case as a round 21 input.  
Editor: **c-291@<box2>** (claude, `specs_and_docs`).  
Panel: m-305@<box2> (mistral), placed by the dispatch holder (section 8).

**One sha:** every count below is measured on **`6b5656493`** (`origin/master`, committed 2026-11-19T10:21:56+02:00), on <box2>, between 09:06Z and 09:31Z on 2026-11-19, unless a row says sat. n=1 per command unless stated. `origin/master` moved to `93a625324` during the read; `git diff --stat 6b5656493 93a625324 -- csi-spl-orc/src/bash/run/spl-review-go.func.sh csi-spl-orc/src/bash/tests/spl-review-go.tst.sh csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh` -> empty (09:30Z), so row 01's sites and control hold on both.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b19-plan')` -> `W=2026-11-19T09:53:30+02:00`.

---

## 1. How to read this

- Round 19 re-measured every input on `0268cbab8`. This plan re-measures only what changed since (`git rev-list --count 0268cbab8..6b5656493` -> 46 commits), and names each round 19 item it closes and why it stays closed (section 4).
- **Paths** are repo-relative. Line numbers are as of `6b5656493`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- <box2> is the box this plan was measured on. It was offline 2026-11-18T23:31Z..2026-11-19T08:25Z, so its overnight alerts are that outage, not separate defects.

---

## 2. Where the rows come from (measured on `6b5656493`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since 07:00Z** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-19T07:00:00Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (09:29Z), then every non-probe post read whole (8) | t1 7 (6 `[spool-probe]`, 0 regex hits), csitea 7 (1 regex hit) | **0 rows.** t1: one poll answer (07:06Z, a translation review order). csitea: a blog draft review (3 posts) and a customer project's test layout (4 posts; the one regex hit, "we ve done wrongly the dir structure", is about that project's own test tree, not this one). No defect of this tree. |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (09:07Z); the holder's read of run 44490281353 (msg 55aa14e8) | 15 failed runs; every timeout headroom line read `ok` | **0 rows.** New since round 19: (a) `wui 8/8` `issues-ctxmenu.test.mjs` "4j Shift+O opens the issue": run 44394043708 on `ba846ec4` (2026-11-18T20:43Z) and, read by the holder, schedule run 44490281353 on `6b5656493` (08:45Z, first try and its retry), while push run 44487062602 on the same sha was green and `6b5656493` touches no WUI file. Two sightings: a flake (rulebook 2.11.3: a fixing lane on the 3rd sighting), section 5. (b) `orc 2/4` run 44404675709 on `f1048ab3` (2026-11-18T21:45Z) "the canary key leaked: ps.log": 1 sighting, the job green in every run since (last green 44487062602). The rest are round 19's (`iac` hygiene spin control, queued then; `orc 3/4` "noon differs" and `orc 1/4` install-box-crons, fixed) and `orc 3/4` "no hook after spl_spawn_placed_close" of 2026-11-18T10:23Z..10:52Z, green since. |
| **3. Skipped or disabled tests** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 6b5656493 -- "$d" \| wc -l; done`; `git diff 0268cbab8 6b5656493 -G '<the same pattern>' --stat` | api 200, wui 18, orc 10, iac 21, utl 0 (round 19: api 199, the rest the same) | **0 rows.** The diff names one file, `csi-spl-api/src/go/spool-hub-api/internal/hub/hours_price_sql_tab_test.go` (`10e324efa`, SPL-5913): its new `t.Skip("Postgres only (hub-pg.tst.sh): the memory store has no SQL executor")` is a store split, the test runs on PostgreSQL, not a disabled test. |
| **4. Box cron logs, last 24 h** | <box2>: for each `/var/csi/csi-spl{,-desk-cron}/*/cron.{out,log}` changed in the last 24 h, `tail -3000 \| grep -cE 'unbound variable\|command not found\|syntax error\|Traceback\|panic:\|status 141\|operand expected\|Permission denied'`, each hit dated by the last ISO stamp above it | 12 logs with hits | **0 rows.** Every hit predates the window: `spl_private_has_tokens: command not found` (3 alarm logs, last 2026-11-15T19:00Z) and `tee >(do_mask_private_keys ...)` status 141 (9 logs, 2026-11-17T21:34Z..22:00Z: the disk-full event, round 18 source 4 a; the `spawn-place` one is keyed to 11-21 by a deadline stamp in its text, as round 19 said). |
| **5. The holder's candidate list** | the holder's list, read on sat by c-002 (msg bd1192ad: `c002-next-round-candidates.md`, 5569 B, 33 lines, mtime 2026-11-19T08:33:12Z); each candidate re-measured below | 3 new candidates (a), (b), (c) | **1 row (01)** from (c). (a) and (b): section 5. |

---

## 3. The row

| # | defect | evidence | sites file:line | red control (fails on `6b5656493`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b20-01-orc-review-go-retired-author-no-retry)` | When the GO send fails, `_spl_review_go_send` logs nothing and returns 9, "the next run tries again" (`spl-review-go.func.sh:819-829`, the WARN at `:826`; header `:93`; spec 157 `spec.md:256`, exit 9). Nothing is written to `automation.log`, so `_spl_review_go_seen` (`:160-162`) never marks the message, and the every-minute cron (`spl-review-go-install-cron.func.sh:41`, `* * * * *`) checks it again until it ages out of `REVIEW_GO_MAX_AGE` (60 min, `:113`). A send to an author retired on this machine inside its quarantine can never succeed: `spool-send.sh` refuses it with exit 14, "retired on this machine less than 24 h ago; nothing was delivered, a reject is in <from>'s inbox" (`spool-send.sh:533-537`; a same-box `--to <id>@<box>` takes that path: `:405-407`, `:510`). So every tick for an hour sends again and drops one more reject into the holder's inbox. | sat, read by the holder c-002 (msg bd1192ad, n=1): `/var/csi/csi-spl/review-go/cron.out` `grep -c 'GO to c-836@sat failed'` -> 52, all for review msg 6ac14d30 (m-841's PASS), each followed by `OK review GO: holder c-00x, 0 GO(s) sent`. The log has no timestamps, so the time comes from the rejects: 56 c-836 reject files in the holder spools (c-002 inbox and archive, c-003 archive) dated 2026-11-19, first 07:26:09Z, last 08:46:11Z (c-836 retired 07:45:14Z per the holder's list). Not re-measured on <box2>: the log is sat's (this box's copy holds only `INFO the dispatch lease is held by c-00x@sat` lines). | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:812-829` (`_spl_review_go_send` and its comment), `:93` (header), `:851-864` (`_spl_review_go_hold`, reused); `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh:533-537` (read only); test `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (case 9, `:302-306`, and a new case beside it); doc `csi-spl-doc/specs/157-dispatch-automation/spec.md:256` | `rc01.sh` (section 3.2): the suite's fixture (`spl-review-go.tst.sh:1-213`) plus a case that runs the cron scan 3 times with the sender stub exiting 14. On `6b5656493`: `FAIL: b20-01: retired author -> 3 GO send(s) in 3 ticks; automation.log: 0 line(s); out: 1 'tries again' in the last tick`, `FAIL: 1`. Its control (stub exit 1, 2 ticks -> 2 sends, nothing logged, as case 9) passes. | Exit 14 from the sender is terminal: the message is held once through `_spl_review_go_hold` (one note to the holder, one `review-go <msg> action=refused rc=9 ...` line in `automation.log`, so `_spl_review_go_seen` skips it next tick); any other failure is retried as today (case 9 stays). The WARN and the header say which. The other-box path is out of scope (v1.0, N2): a `--to <id>@<other box>` goes through the hub relay (`spool-send.sh:510-522`, exit `10 + rc` at `:521`); the hub refuses a retired id (`csi-spl-api/src/go/spool-hub-api/internal/spool/retired.go:84`), but `spool-fleet-relay.sh:224-231` turns every non-roster failure into exit 1, so the caller sees 11 for a retired author and for a transient hub error alike. The lane does not edit the relay (a fleet-wide script) and says so in its body; it stays a retry, as today. Docs: spec 157 `spec.md:256` (exit 9) in the same commit. Live proof (R5): the next retired-author PASS on sat logs one `action=refused rc=9` line and one reject, not one a minute. | sat (the cron and its log run where the dispatch lease is) | claude | grok (cross-vendor), backup: another non-claude seat the holder names | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** row 01 alone: `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`, `csi-spl-doc/specs/157-dispatch-automation/spec.md`. It reads `spool-send.sh` and `retired.go` but does not edit them.
- **Test column (R2):** `git grep -lE 'spl-review-go(\.func)?\|do_spl_review_go\b' -- '*tests/*'`; the lane runs every file it prints.
- **Off limits** for the row lane: every live lane's files (below), `spool-send.sh` and `spool-fleet-relay.sh` (fleet-wide scripts; the fix stays in the caller).
- **How the files were checked (2026-11-19, <box2>):**
  - 09:30:05Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-doc/doc/md/bug-round-20-plan.md --agent c-291` -> no live lane lists them; exit 4 for lanes that record no files: c-706@sat (WUI export to PDF), c-852@sat (SPL-5883 migration), c-855@sat (SPL-5883 filter pref), c-859@sat (r64-02). Their scopes by their titles and, for r64-02, `refactor-round-64-plan.md:135` (`no-literal-paths.tst.sh` and its baseline): none is the review GO. The orchestrator re-runs the check with the spec file before the spawn (R3).
  - 09:30:25Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 1 queued (a csi-rel language review seat, another repository), 0 placing. None names the review GO.
- **Slug b20 is unused as a round id** (<box2>, 09:06:45Z; sat by c-002, msg bd1192ad at 09:07Z):
  - `git log origin/master --since="$W" --oneline -E --grep='\(b20-'` -> 0;
  - `git ls-remote origin 'refs/heads/review/b20-*' 'refs/heads/wip/*b20*' 'refs/heads/*-b20-*'` -> nothing; `git ls-remote origin \| grep -cE 'b20-[0-9]{2}\|bug-round-20'` -> 0;
  - `grep -rlE '(^|[^0-9a-f])b20-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs`, `/var/spool-hub/asks` and `/var/spool-hub/spawn-remote/briefs` -> 0 files (sat: 0); `bug-round-20` -> 1 file, this planner's brief;
  - `git branch -a \| grep -cE 'b20-[0-9]{2}'` -> 0 (sat: 0).

  After this plan's pushes, `--grep='(b20-'` matches the plan's commits (`docs(b20-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b20-[0-9]{2}'` stays 0 until the row lands.

### 3.2 Red control run on `6b5656493`

| row | command (repo untouched) | output on `6b5656493` | output with a prototype fix (on a `git archive 6b5656493 csi-spl-orc` copy) | who |
|---|---|---|---|---|
| 01 | `bash rc01.sh`, put in `csi-spl-orc/src/bash/tests/` of a `git archive 6b5656493 csi-spl-orc` copy | `FAIL: b20-01: retired author -> 3 GO send(s) in 3 ticks; automation.log: 0 line(s); out: 1 'tries again' in the last tick` / `PASS: b20-01 control: a transient send failure (rc 1) is retried, nothing logged` / `FAIL: 1` | `PASS: b20-01: a retired author (send rc 14) gets one GO try, logged once, no retry` / `PASS: b20-01 control: ...` / `PASS: all`; the whole `spl-review-go.tst.sh` on the copy: `spl-review-go: 0 failure(s)` | editor c-291 |

The script is `/var/spool-hub/dispatch/b20-red-controls/rc01.sh` on <box2> (14822 B, `sha256sum` -> `faa73d5664fe...`): lines 1-213 of `spl-review-go.tst.sh` at `6b5656493` (the fixture: `reset`, `msg`, `line`, `run`, `gos`), then this case, verbatim:

```bash
reset
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" b2000000-0000-4000-8000-000000000001)
for tick in 1 2 3; do run SEND_RC=14; done
n=$(gos)
if [[ $n == 1 ]] && grep -q "review-go b2000000-0000-4000-8000-000000000001 " "$LOG"; then
  pass "b20-01: a retired author (send rc 14) gets one GO try, logged once, no retry"
else fail "b20-01: retired author -> $n GO send(s) in 3 ticks; automation.log: $(cat "$LOG" 2>/dev/null | wc -l) line(s); out: $(grep -c 'tries again' "$T/out") 'tries again' in the last tick"; fi
reset
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" b2000000-0000-4000-8000-000000000002)
for tick in 1 2; do run SEND_RC=1; done
[[ $(gos) == 2 && ! -s "$LOG" ]] && pass "b20-01 control: a transient send failure (rc 1) is retried, nothing logged" || fail "b20-01 control: rc 1 -> $(gos) sends, log $(wc -l <"$LOG" 2>/dev/null)"
(( fails == 0 )) && echo "PASS: all" || echo "FAIL: $fails"
exit $(( fails > 0 ))
```

The prototype (about 3 lines in `_spl_review_go_send`: on rc 14, call `_spl_review_go_hold ... 9 "author <to> is retired (quarantined): the GO was not delivered"` and return 9) only shows that PASS is reachable without breaking the suite; the lane writes its own fix.

---

## 4. Round 19's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b19-01 (the box link watch) | `git log origin/master --oneline -E --grep='\(b19-01-'` | landed `6b5656493`, gate 44487062602 success | Served (round 19 closed). |
| Round 19 section 4 (the holder's older items: r34-05, b12-02, SPL-5825, SPL-5824, SPL-5828, r34-01, SPL-5850; b17-01 N1) | the holder's list did not change them (its new section is (a)-(c) only, msg bd1192ad) | unchanged | Closed as round 19 section 4 says. b17-01 N1 (the `EXPIRED` pattern) is not what b19-01 edited (`pending_items` and `conditions`). r34-01 N1/N2 are test-coverage gaps with no failing behaviour: input for a test round, not a bug row. |
| Round 19 N2 items (r63-01 W1 literal state dir; p18-02 N1 comment wording) | `git log origin/master --oneline -1 87d56eaae` | `refactor(r64-01-orc-cron-script-state-dirs, SPL-5944)` | Served by refactor round 64; p18-02 N1 is wording only. |
| desk-cron `bin/spool` older than its sources | every orc run | as in rounds 12 to 19 | As before. |

---

## 5. Not reproduced, or no red control yet

| candidate | command | result |
|---|---|---|
| **(b) the SPL-5613 wip message sweep refused c-390 on 10 shas that are ancestors of `origin/master`** (holder's list, from c-001 msg b641a2ed) | <box2>: the refusal `/var/spool-hub/c-001/outbox/20261119T082711Z--c-001--relayed-f4a8fcb8.json` (08:27:11Z) names 10 distinct shas; `git merge-base --is-ancestor <sha> origin/master` -> all 10 ancestors, committed 2026-11-15T19:16..21:18+02:00. c-390's reflog: branch `c-390-rotate-7` made 2026-11-15T19:24+02:00 at `f7c388910`, moved to `b97a764ff` (master, 2026-11-18) by fast-forwards and a rebase; all 10 shas are in `b97a764ff`, none in `f7c388910` | **Plausible, no red control yet: not a row this round; first input for round 21.** For a ref the remote already has, the hook's message sweep reads `<remote sha>..<local sha>` with no `--not <remote>/master` (`csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push:215`). A lane whose old `wip/<branch>` tip predates master commits it later fast-forwarded over sweeps those master commits' messages too, which fits the 10 shas. The editor's two attempts at a suite case (the `lane-wip-push.tst.sh` fixture plus a landed master commit after the old wip tip) were also refused with a CLEAN landed message, so they did not isolate this cause; that failing control is unexplained and is not offered as evidence. `git ls-remote origin 'refs/heads/wip/c-390*'` -> nothing, so the old remote tip cannot be read back. Round 21's planner starts from the hook line above and builds the control on the hook alone, with a passing clean-message control first. |
| **(a) a read-only reviewer's worktree with 51 staged files of another lane** (c-091@<box2>, from c-001 msg b90519e0) | <box2>: `git -C <c-091 worktree> status -sb` -> `behind 23`, 51 files staged (evlog files of SPL-5936 among them), HEAD `06eff273f`; its index mtime 2026-11-19T08:27:18Z; `git write-tree` of that index -> `88ad5a5b...` = the tree of `6b5656493` (origin/master then); its reflog has no entry after 2026-11-19T00:26:05+01:00; the main checkout's reflog: fast-forward to `6b5656493` at 08:26:14Z | **Not a row: the writer is unknown.** The index was set to the then-current trunk tree without moving HEAD, one minute after the main checkout's fast-forward, during the box's restart. A `git grep` for `read-tree`, `apply --index`, `apply --3way`, `stash apply`, `stash pop`, `restore --staged` and `checkout <ref> -- .` over `csi-spl-orc/src/bash/{run,scripts,features/spawn-agents/scripts}` found no call on a lane worktree (the hits are a tenant-host reconcile on its own tree and the desk cron's own checkout). n=1, no red control. The staged set is master's own content, so a commit from it would only re-add landed work; c-091 is a reviewer and commits nothing. Reported to the orchestrator (section 6); a watch item. |
| CI `wui 8/8` "4j Shift+O opens the issue" (`issues-ctxmenu.test.mjs:199`) | source 2 | 2 sightings (2026-11-18T20:43Z on `ba846ec4`; 2026-11-19T08:45Z on `6b5656493`, schedule, first try and retry), green on the same sha's push run; the next run skips the WUI e2e. A flake: a fixing lane on the 3rd sighting (rulebook 2.11.3). Watch item. |
| CI `orc 2/4` "the canary key leaked: ps.log" | source 2 | 1 sighting (44404675709, 2026-11-18T21:45Z), green since. Watch item. |
| `spl-review-go.func.sh: line 96: SPOOL_ROOT: unbound variable` at the head of sat's `review-go/cron.out` (holder, msg bd1192ad) | `git log origin/master --oneline -S'SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"' -- csi-spl-orc/src/bash/run/spl-review-go.func.sh` -> `a125b0d5d fix(orc, SPL-4316): review GO defaults SPOOL_ROOT ...` | Fixed by SPL-4316 (the default at `:118`, the suite's case 13 red control); the line sits at the head of a 1.4 MB log with no timestamps, i.e. from before that fix. |

---

## 6. Owned elsewhere, or reported (R3)

| item | owner | status |
|---|---|---|
| c-091@<box2>'s worktree holds 51 staged files it did not make (section 5 (a)) | the orchestrator, as a finding | Reported with this plan's result; the editor does not touch another lane's worktree. |
| The live lanes of the brief (c-859 r64-02; c-852 and c-855 SPL-5883; c-706 SPL-5888; c-087 SPL-5938; c-085 csi-rel SPL-42; c-048 SPL-5930; the refactor round 65 planner; the SPL-5938 R7 seat) | their lanes | None touches row 01's files (section 3.1). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 |
| inputs re-measured | 5 sources; 3 holder candidates; 8 human posts; 15 failed CI runs (2 new signatures); 12 cron logs with old hits |
| watch items | 3 (the c-091 staged index; the `wui 8/8` flake; the `orc 2/4` canary line) |
| first inputs for round 21 | (b), the wip message sweep's range; the relayed retired-author send (v1.0 N2: exit 11, retried) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-291@<box2> (claude, `specs_and_docs`).
- **Panel:** m-305@<box2> (mistral), placed by the dispatch holder c-002@sat (msg 1062c0c3, c-001 ee9a6cb1), asked on task `dispatch-bug-r20`, with at least one non-claude seat. The panel checks row 01's red control (`rc01.sh` on `6b5656493`: RED; it may rebuild it from section 3.2 on its own `git archive` copy), the fix scope (only exit 14 is terminal; case 9's retry stays), the sat evidence with the holder, and that every other input in sections 2, 4, 5 and 6 is measured as written.
- **Row reviewer (R7):** a grok seat (cross-vendor to the claude author); backup named by the holder.
- **Review history:**
  - 2026-11-19 09:07:08Z: the editor asked the holder for the sat slug check and the candidate list (msg 18573efa); c-002@sat answered at 09:07Z (msg bd1192ad) and added the `wui 8/8` candidate (msg 55aa14e8), folded into sections 2, 3 and 5.
  - 2026-11-19: the editor pushed v0.1 `bfce48e35` to `review/c002-bug-round-20-planner`.
  - 2026-11-19 10:08:59Z: panel m-305@<box2> (mistral) **PASS** on v0.1 `bfce48e35` (msg 03875889, spool task `dispatch-bug-r20`), W1..: none. It re-ran the b20 slug check, every cited line on `6b5656493` (`spl-review-go.func.sh:93,113,160-162,819-829,851-864`, `spool-send.sh:405-407,510-522,533-537`, `spl-review-go.tst.sh:302-306`, `spl-review-go-install-cron.func.sh:41`, `retired.go:84`, `spec.md:256`, `pre-push:215`, `issues-ctxmenu.test.mjs:199`, `spool.go:685-686`), `rc01.sh` (sha256 `faa73d5664fe...`, lines 1-213 identical to the suite's fixture) on its own `git archive 6b5656493` copy: RED, `FAIL: 1`; with the prototype `PASS: all` and the suite `0 failure(s)`; the CI runs, the prd post counts, the skip counts, the 11 cited shas, the 10 refusal shas (all ancestors), `lane-map.sh --check` (exit 4, the same 4 no-file lanes), `do_check_dist_hygiene` (clean) and `do_check_pre_push` (all parts PASSED). Seat file: `csi-spl-doc/doc/md/bug-round-20/seat-mistral.md` on `review/c002-bug-round-20-mistral-seat`, `2063c9761`.
  - **The panel's notes, answered in v1.0** (row 01's code scope unchanged):
    - **N1** (origin/master moved to `8c6ea8825` during the read): confirmed. `git diff --stat 6b5656493 origin/master` over the row's files (`spl-review-go.func.sh`, `spl-review-go.tst.sh`, `spl-review-go-install-cron.func.sh`, `spool-send.sh`, `spec.md`, `retired.go`, `spool.go`) -> empty at `8c6ea8825` (editor, 10:1xZ), so section 3 holds on both.
    - **N2** (the other-box question answered: exit 14 covers the relayed path too): **not as written.** `spool.go:685-686` maps `ErrRetiredRecipient` to 4 for the `spool` binary, but on the relayed path the binary runs inside `spool-fleet-relay.sh`, whose failure branch (`:224-231` at `8c6ea8825`) exits 3 for a roster miss and 1 for everything else, so `spool-send.sh:521` exits 11, not 14. A retired author on another box is therefore not distinguishable from a transient hub error by exit code. Row 01 stays scoped to exit 14 (the same-box path, which is the observed case: review-go and c-836 both on sat); the fix-scope cell now says the relayed case stays a retry and the lane does not edit the relay. The relayed retired-author send is a first input for round 21 (section 7), with no red control yet.
    - **N3** (the sat evidence is the holder's read, not re-readable from <box2>): noted. It is the same in v0.1 (section 3, evidence column); the red control, not the log count, is what the row is judged on. The live proof (R5) is read on sat after the landing.
    - **N4** (the one `b20-01-` hit in the brief dirs is the seat's own brief): noted, as the seat says; the slug check of section 3.1 was made before the seat existed.
    - **N5** (`\|` in the table commands): already said in section 1; no change.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-291@<box2> | **v1.0** |
| Panel | m-305@<box2> (mistral) | **PASS** on v0.1 `bfce48e35` (10:08:59Z, msg 03875889; seat file `csi-spl-doc/doc/md/bug-round-20/seat-mistral.md` on `review/c002-bug-round-20-mistral-seat`, `2063c9761`); v1.0 pending |
