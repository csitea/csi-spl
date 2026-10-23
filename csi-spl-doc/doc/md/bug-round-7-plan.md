# Bug-fix round 7 - plan (1 action)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 7 focus: **a short topic id (`--task 9e1e51f3`) sent to another machine is hashed into a new, empty topic instead of being refused.**  
Concurrency: rulebook §1.1 asks for 2 row lanes in parallel. This round has one reproduced defect, so there is **one lane**. No rows are added to fill a second lane (brief, Do 6).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), linked here, not copied. Issue: SPL-3088.  
Model: [bug-round-6-plan.md](bug-round-6-plan.md) (same shape, same 5 sources).

**Status: v0.1, editor draft, waiting for the reviewer.**

Editor: **c-824@<box2>** (claude, the backup vendor for `specs_and_docs`; agy has no quota, per the brief).  
Reviewer: one cross-vendor seat (rulebook 2.7.2), asked of the dispatcher: mistral, because grok and agy have no quota. The reviewer signs v1.0 in its own commit.

**One sha:** every count below is measured on **`52cec6efe`** (`origin/master` at the start, 2026-10-23T17:57Z), on <box2> unless a row says sat. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane step, at the sites named and nowhere else. Each row has a **red control**: a test that fails on `52cec6efe` and passes after the fix. Section 3.2 shows each red control's run on `52cec6efe`.
- **Paths** are repo-relative. Line numbers are as of `52cec6efe`.
- **Box:** the preferred box. The placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules. Mistral writes no code. `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` -> `pick=grok`, but grok is at its weekly limit (<box2> `gc.log`: `2026-10-23T17:30:02Z FALLBACK 20261023T1730Z-gc-<box2> grok -> claude: grok weekly limit`; sat the same at 16:30:08Z). So the coding vendor is claude.
- **Subject** (R6 reads it): `fix(b06-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<absolute journal path>` (rulebook 2.7.4).

---

## 2. Where the rows come from (measured on `52cec6efe`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 since 2026-10-22** | `cd csi-spl-orc && ENV=prd SQL="select count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)'), count(*) filter (where body like '[spool-probe]%') from messages where tenant_id='t1' and ts >= '2026-10-22' and from_id like 'HUM%'" ./run -a do_spl_db_query`. Then the non-probe bodies since round 6's read (`ts >= '2026-10-23T06:20Z'`, `left(body,400)`, by ts) were read | 384 human posts, 2 defect-worded, 310 `[spool-probe]` lines. Round 6 counted 266 posts and 1 defect-worded | 42 non-probe posts since 06:20Z: poll answers, "what is the status" (8), go-aheads, a feature request (role permissions, b4af24b2) and one delay question ("over 90 minutes no updates", 37aa8e52, 10:49Z). That last one was a review seat with no quota, answered by the poll db9963e2. None of the 42 describes a code defect. The new defect-worded post is 3756c25b, a poll answer that contains the word "bug" ("a priority 1 feature goes before a priority 3 bug"). **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (`GH_TOKEN` set) | 200 runs 2026-10-22T09:46Z..2026-10-23T17:57Z: 137 success, 42 cancelled, 20 failure, 1 running. Every timeout headroom line is `ok` (worst: orc hermetic 3/3, p90 814 s of 1800 s, 45 %) | 9 failed runs are newer than round 6's read (06:17Z). They have 5 signatures: (i) `dispatch-setup-check` case 7 `prd hub unserved past the grace` x3 (15:37..15:52Z, `178dc2b4`, `b1146c65`): round 6's row 01 fallout, fixed by `c6ee3f5d3` (an ancestor of `52cec6efe`); (ii) `boxes-three-panes.test.mjs` x3 (08:04..08:22Z, from `59516d0b`): fixed by `6d2bb929f` (SPL-3015, 08:30Z); (iii) the phone bulk bar `countFits:false` x3 (10:53..11:19Z, from `bed9b280`): fixed by `fa817cee2` (SPL-3026); (iv) `no-x-scroll.test.mjs` x1 (11:47Z, `fa817cee`, n=1); (v) `lane-restart.tst.sh` case 6 x1 (17:33Z, `337dc9a3`, n=1). Every failed job was green again on run `39997824863` (`a6317999`, 17:46Z). (iv) and (v) are in section 5. **0 rows.** |
| **3. Skipped or disabled tests, local flakes** | `git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 52cec6efe -- <tree> \| wc -l` per tree; `diff` of the sorted grep (`-h`) against `50743edbb` | 187 lines (api 140, wui 17, orc 9, iac 21, utl 0), the same as round 6. `diff` -> empty (rc 0): 0 new skip lines in 57 commits. 4 entries in `csi-spl-wui/tests/e2e/ci-skip.txt`, 0 in `csi-spl-orc/src/bash/features/ci-skip.txt` | 0 defects. Local flake run for the one orc CI flake: `bash csi-spl-orc/src/bash/tests/lane-restart.tst.sh` 20 times on <box2> -> **20 pass, 0 fail** (373 s, load average 8.6..10.5). |
| **4. GC notes and box alarms, last 24 h** | `awk '$1 >= "2026-10-22T18:00"'` over `/var/spool-hub/dispatch/gc/gc.log` on <box2>, and over sat's copy (read over ssh, read-only), grouped by event | <box2>: 49 START, 37 DONE, 13 END-STALE, 13 FALLBACK, 8 POKE, 4 CLOSE-ASK, 1 REFUSED, 1 NONE. sat: 49 START, 40 DONE, 10 END-STALE, 15 FALLBACK, 11 POKE, 2 CLOSE-ASK, 1 REFUSED, 3 NONE. `spool tail --task gc-sat` from <box2> -> `no messages visible to this box` | sat: every END-STALE is a grok pass up to 03:00:04Z; since 03:30Z every grok slot is a FALLBACK followed by a claude DONE (round 4 row 02 holds). <box2>: the same until 13:30Z, but then three passes in a row ended stale: 14:30Z grok `%627`, 15:00Z **claude** `%628`, 15:30Z grok `%629`. At 14:30Z and 15:30Z sat logged FALLBACK for the same slot, so <box2>'s grok passes started instead of falling back. From 16:30Z <box2> falls back again. This is in section 5 (not reproduced). The REFUSED and NONE lines are the GC refusing a wrong `begin`, as designed. **0 rows.** |
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list`, labels and titles read with `python3 -I` | 336 issues (total 336), 4 labelled `bug`; 28 more with a defect word in the title, 2 of them created since round 6's read | The `bug` ones are SPL-1945 (blocked, needs owner) and SPL-455 / SPL-450 / SPL-435 (out of scope by the brief). The 2 new ones are lane briefs: SPL-3088 (this plan) and SPL-3062 (the poll form rendered as a code block, a live lane, section 6). **0 rows from issues.** The dispatcher's candidates: (a) **reproduces** (Row 01); (b) and (d) are measured and not a bug (section 4); (e) is not reproduced (section 5); (c) and (f) are owned elsewhere (section 6). |

---

## 3. The 1 row

| # | defect | evidence | sites file:line | red control (fails on `52cec6efe`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b06-01-orc-relay-short-task)` | A send to an agent on another machine goes through `spool-fleet-relay.sh`. Its task is mapped to a uuid: a full uuid is kept, and **any other string** is treated as a local task name and hashed to `uuid5(NAMESPACE_URL, "spool-task:" + TASK)`. An 8-hex topic prefix such as `9e1e51f3` is not a name. It is the short form of a real topic, the form the fleet writes in posts. The relay still hashes it, so the message lands in a **new, empty topic** that nobody reads. The relay prints success, and nothing tells the sender. The local owner-topic guard in `spool-send.sh` checks only full uuids, so the short form of an owner topic also gets past that guard. | (1) The dispatcher's case: c-002 msg 4592d4c0 (16:01:58Z) was sent with `--task 9e1e51f3` and delivered as task `451c5d94-9794-5aaf-886b-4cebc1a60abc`. `python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL,"spool-task:9e1e51f3"))'` -> `451c5d94-9794-5aaf-886b-4cebc1a60abc`, the same id. (2) Hub, `ENV=prd SQL="select tenant_id, task_id, count(*), min(ts), min(from_id) filter (where from_id like 'HUM%') from messages where task_id::text like '9e1e51f3%' or task_id='451c5d94-9794-5aaf-886b-4cebc1a60abc' group by 1,2" ./run -a do_spl_db_query` -> `9e1e51f3-822a-…` is a real topic (csitea 36 rows, first post by the owner; t1 12 rows), and `451c5d94-…` has **2 rows** (t1, from 16:01:58Z), the orphan. (3) A local send keeps the short id as it is: in a scratch spool root, `spool send --from c-901 --to c-902 --task 9e1e51f3` gives `task_id 9e1e51f3`. So only the relay hop changes it. (4) No task in use is a bare hex string: `"task_id"` of every outbox file under `/var/spool-hub` since 2026-10-16 -> 709 distinct ids, 0 match `^[0-9a-fA-F]{6,31}$`. | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh:130-137` (the uuid mapping; its comment is `:130-133`, the test is `:134`); test `csi-spl-orc/src/bash/features/spawn-agents/tests/test-fleet-send.sh` section 5 (`:133-144`: the `rl` helper `:133`, "a task NAME travels as its one uuid" `:140-141`, "a uuid task travels as it is" `:142-143`, "the box travels as to_box" `:144`). Context only, no change: `spool-send.sh:281` (the owner-topic guard, full uuids only) | A scratch copy of `test-fleet-send.sh` (`git archive 52cec6efe csi-spl-orc csi-spl-api/src/go` + a prebuilt `bin/spool`) with two checks added after `:144`: `rm -f "$T_TMP/stub.args"; out="$(rl --from CLE-100004 --to CLE-001 --kind result --body hi --task 9e1e51f3 --to-box box-desk 2>&1)"; rc=$?`, then `check "b07-01. an 8-hex topic prefix is refused (exit != 0)" test "$rc" -ne 0` and `check "b07-01. ... and nothing reaches the hub" test ! -e "$T_TMP/stub.args"`. Today: **88 passed, 2 failed** (both b07-01 lines), rc 1. Controls: the existing `:140-144` checks stay green, so a name is still hashed and a full uuid is still kept. | In `spool-fleet-relay.sh`, before the uuid mapping (`:134`), refuse a task that is 6 to 31 hex digits (`^[0-9a-fA-F]{6,31}$`) with exit 2 and one line on stderr, before anything is sent: the task looks like a short topic id, so pass the full uuid (or `dispatch-<topic8>` for an owner topic). Extend the comment at `:130-133` with the reason and this case (msg 4592d4c0). Put the two red-control checks into section 5 of `test-fleet-send.sh`, after `:144` (no new file). Nothing else changes: names stay hashed, uuids stay as they are, and `spool-send.sh` does not change. Before the push: `git grep -n -E 'spool-task:\|spool-fleet-relay' 52cec6efe -- '*.tst.sh' '*/tests/*'` lists every test that drives the relay, and the lane runs each one (round 6's lesson, section 4). Docs: the comment at `:130-133` is the one home of the mapping rule (`git grep -n 'spool-task:' 52cec6efe -- csi-spl-doc` -> 0 lines), so the commit carries `Docs: none (the relay's task mapping is documented only in its own header comment, changed in this commit)`. | <box2> | claude | mistral (cross-vendor, rulebook 2.7.2; grok and agy have no quota) | simple_coding | 1 (lane A) |

### 3.1 Files (R1) and lanes

- **Lane A:** Row 01 alone, batch 1. It changes `spool-fleet-relay.sh` and `test-fleet-send.sh` only.
- No second lane this round: no other candidate reproduced (section 2).
- `bash …/lane-map.sh --check csi-spl-doc/doc/md/bug-round-7-plan.md,csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh,csi-spl-orc/src/bash/features/spawn-agents/tests/test-fleet-send.sh --agent c-824` -> exit 4: `no live lane lists` any of them, and 11 live lanes record no files: c-189, c-423 @<box2> and c-499, c-613, c-763, c-795, c-800, c-897, c-898, c-905, c-906 @sat. They are rotation and role seats plus WUI-decompose, migration and ppe-keep lanes. None of their branch names refers to the relay, the fleet send or this plan. On <box2>, no worktree in `git worktree list` has its own change to these files (`git diff --name-only origin/master...HEAD` + `git status --porcelain`, grep `spool-fleet-relay|test-fleet-send|bug-round-7` -> 0). Re-check at spawn.
- `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 18 rows: 15 feature, 1 refactor, 0 bug. None names the relay or the fleet send.
- Box: `sudo -u <DEV_USER> env BOX_PICK_KIND=claude ./run -a do_spl_box_pick` -> `pick=<box2>` (66 %, past its 40..60 band but the least past; sat 101 %, `full`).

### 3.2 Red control run on `52cec6efe`

Inputs: `git archive 52cec6efe csi-spl-orc csi-spl-api/src/go` into a scratch dir on <box2>. The suite's `t_spool_bin` builds `bin/spool` with `csi-spl-api/src/bash/build.sh`, which this archive leaves out, so the binary was built beforehand with `go build -o bin/spool ./cmd/spool` in the archived module. The two checks in the Row 01 cell were added after `:144` of the archived `test-fleet-send.sh`.

| row | command (scratch, repo untouched) | output on `52cec6efe` | output with the fix (scratch copy of the relay) | who |
|---|---|---|---|---|
| 01 | `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-fleet-send.sh` (the scratch copy) | `FAIL - b07-01. an 8-hex topic prefix is refused (exit != 0)`, `FAIL - b07-01. ... and nothing reaches the hub`, `-- test-fleet-send.sh: 88 passed, 2 failed`, rc 1. The relay was checked byte for byte against the tree: `git hash-object` = `git rev-parse 52cec6efe:…/spool-fleet-relay.sh` = `8294dcfb7` | one line before `:134`: `if [[ "$TASK" =~ ^[0-9a-fA-F]{6,31}$ ]]; then say "…short topic id: pass the full uuid. Nothing was sent."; exit 2; fi` -> `ok - b07-01.` x2, `-- test-fleet-send.sh: 90 passed, 0 failed`, rc 0 | editor |

The reviewer re-runs this once from the cell above: the archive, the prebuilt binary, the two added checks, then the run with and without the one-line fix.

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| (b) An owner post in csitea (msg ceb47ac0, topic 1ef6882e, 15:53:52Z) reached the dispatcher as a channel post. `do_spl_desk_reply` on it was refused `dm_not_blocker`, and the hub has no row with that msg_id | Hub: `ENV=prd SQL="select tenant_id, ts, msg_id, from_id, to_id, kind, left(body,120) from messages where msg_id::text like 'ceb47ac0%' or task_id::text like '1ef6882e%'" ./run -a do_spl_db_query` -> **1 row**, and it is not the owner's: c-423 -> c-001, note, 15:54:34Z, t1, `Owner post outside #<channel> reached c-423: … spool tail --url as c-423 now says no messages visible`. `message_moderation`, `message_revisions`, `message_kind_changes`, `message_reactions` for `ceb47ac0%` -> 0 rows each. prd hub request log (`gcloud logging read` as the prd SA, `httpRequest.requestUrl:"ceb47ac0"`, 15:50..16:30Z) -> `15:53:59Z GET /v1/view/messages/ceb47ac0-…/topic 200`, then `15:54:00Z DELETE /v1/messages/ceb47ac0-ad1e-4bbf-83a8-4b74c70d971f/topic 200` | **The read is right and the refusal is right.** The owner deleted the topic 8 s after posting it (`DELETE …/topic` 200; `DeleteMessage` removes the row and cascades, `internal/store/message_edit_postgres.go:165-185`). Then c-423 posted its relay note **on the deleted topic's task id** (15:54:34Z), which made 1ef6882e a new topic whose first message is an agent's. A reply to the owner on that topic is a DM the owner did not start, which is what `dm_not_blocker` refuses (`internal/hub/human_post_guard.go:18-26`). The one thing done wrong is the relay note on the owner's task id. The rule against that already exists ("agents talk about it on --task dispatch-<topic8>", `spool-send.sh:276-285`). It did not fire because the topic was gone, so the hub no longer called it an owner topic. That is not a defect. |
| (d) `csi-spl-api/src/bash/tests/hub-pg.tst.sh` has no "return if sourced" guard, so sourcing it for its `app_dsn` helper runs the whole suite (~16 min) and trips the watchdog's 15-min S4 cap (m-646 in the morning; m-870@<box2> 16:35Z) | `sed -n 1,14p` and `:60-80` of the file; `grep -n -E 'BASH_SOURCE\|return' hub-pg.tst.sh` -> `:15` `HERE=…BASH_SOURCE`, `:197` and `:207` inside functions, no guard; `grep -n -E 'DSN\|export ' csi-spl-api/src/bash/hub-live-stack.sh` | The file is an entry script, and its own header says so: `# Usage: bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` (`:10`), `set -euo pipefail` (`:11`). `app_dsn` is at `:72`, not `:71`. It returns a DSN only for the Postgres this same script starts and the `APP_ROLE` it sets at `:64` and creates at `:71`, so sourcing it to use that helper cannot work even with a guard. The real gap is that **no helper gives a lane a throwaway Postgres DSN**: `hub-live-stack.sh` exports only `HUB_URL` (`:135`). That is a tooling feature request, sent to the orchestrator. It is not a defect row. |
| Round 6 row 01 (`178dc2b4f`, SPL-3065) broke `dispatch-setup-check.tst.sh` case 7 until `c6ee3f5d3` | `git grep -l DISPATCH_LAG_GRACE 50743edbb -- csi-spl-orc` -> 3 files, **not** `dispatch-setup-check.tst.sh`; `git grep -n -E 'grace=30m\|after 30 min' 50743edbb -- csi-spl-orc` -> `dispatch-setup-check.tst.sh:341` and `spl-lane-lifecycle-actions.tst.sh:249,252` (plus 2 unrelated comments in `fleet-lease.tst.sh`) | Why no test caught it before the push: case 7 depended on the old default's **value** (`grace=30m`, `after 30 min`) and never named the knob, so the round 6 plan's knob grep (5 lines in 3 files) could not find it, and the row's lane ran only the suite it edited. A grep for the old value finds it. The fix landed (`c6ee3f5d3`) and the 3 reds stopped. For rounds: a row that changes a default also greps its **old value** and runs every test that grep names. Row 01 above already does this. The rulebook text is not changed here; that change is the orchestrator's (section 6). |
| CI reds (ii) and (iii) of source 2 (`boxes-three-panes`, the phone bulk bar) | `git log --format='%h %cI %s' 50743edbb..52cec6efe -- <file>` | Each was caused by a feature push and fixed within about 30 min by the same lane (`6d2bb929f` SPL-3015; `fa817cee2` SPL-3026) | Fixed. Nothing is left open. |

---

## 5. Not reproduced

| candidate | what I tried | outcome |
|---|---|---|
| (e) `lane-restart.tst.sh` case 6 red once in CI (run `39996051494`, `337dc9a3`, orc hermetic 2/3, 17:42Z; the report's guess: the `send.log` note grep races) | Read the job log (`gh api …/jobs/120559939932/logs`): `FAIL: 6. rc=1 … HUMAN FAIL claude of the human's login human-x: 4242 …`. The test (`lane-restart.tst.sh:289-293`) asserts rc 1, the HUMAN FAIL line, no `4243`, and the note in `send.log`, but the fail message prints only `$T/o`, so the log does not show which assert failed. The sender (`spl-lane-restart.func.sh:156-159`) logs HUMAN FAIL, then calls `spl_rotate_note`. Ran the suite 20 times on `52cec6efe` on <box2> (load average 8.6..10.5) | **20 pass, 0 fail.** The CI run's own hub job was stopped by fail-fast, and every job was green again on `39997824863`. A row needs either a second CI red with the failing assert shown, or a local fail. The test's fail message could print `send.log` too; that is a test-diagnostics change, sent to the orchestrator with the (d) note. |
| `no-x-scroll.test.mjs` red once (run `39948615037`, `fa817cee`, wui 1/8, "exit 1, then exit 1 on retry") | Source 2 signature list over 200 runs | n=1 in 200. The shard was green on every later run that reached it, up to `39997824863`. Not re-run locally (it needs the mock bundle; CI gave one hit only). |
| <box2> GC: three passes in a row ended stale (14:30Z grok `%627`, 15:00Z claude `%628`, 15:30Z grok `%629`). Sat logged FALLBACK for the same two grok slots | Read both gc.logs for 13:55..16:35Z; `tmux display -p -t %627/%628/%629` -> no output (the panes are gone); the gc dir keeps no per-pass pane capture | Unchecked: without the panes there is nothing to read about why grok started on <box2> but not on sat, or why the 15:00Z claude pass stalled. The fallback looks at the pane for `grok weekly limit` (`start-check.inc.sh:59`, `spl-gc.func.sh:219`). From 16:30Z <box2> falls back again (n=2 since). A row needs the next stale pass's pane read while it is still open. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| (c) The sat dispatch lease flipped between c-002 and c-003 several times on 2026-10-23 | c-884@<box2> (ask 1f0b2480) | Listed here by the brief, no row. |
| (f) The pre-push e2e `.output.ppe-keep` timeout leak | c-905@sat (`c-905-c002-bug-ppe-keep-timeout`, ask 81b03c2c) | Live bug lane (lane map above). |
| SPL-3062: a poll form whose options are task-list lines renders as a code block | its live lane (issue `wip`, 2026-10-23T13:14Z) | Not this round's. |
| Round 6's lesson (a default change greps its old value, section 4) as rulebook text | the orchestrator (rulebook owner) | Proposed in the result message; Row 01 applies it already. |
| A throwaway-Postgres DSN helper for lanes (section 4, (d)), and `lane-restart.tst.sh` case 6 printing `send.log` on fail (section 5) | the orchestrator (feature or test-diagnostics lanes) | Proposed in the result message; no row. |
| SPL-455 / SPL-450 / SPL-435 | spec 011 "verify Phase N regression gate" checks | Out of scope by the brief: they carry the `bug` label but are not defects. |
| The review-line check checks test NAMES only, not edits or greps | rulebook 2.7.4 | By design (the brief), not a bug. |
| SPL-1945 secret rotation plan | blocked, needs owner | Not this round's to place. |
| `do_spl_lane_mix` picks grok for `simple_coding` while grok is at its weekly limit (rounds 4 to 7) | the dispatcher / orchestrator (vendor weights) | As in round 6. Row 01 names claude. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 (a defect fix, with its red control run on `52cec6efe`) |
| vendor | claude 1 |
| box (preferred) | <box2> 1 |
| batches | 1 (one lane) |

---

## 8. Panel and reviewer (R7)

- **Editor:** `c-824@<box2>` (claude).
- **Reviewer:** asked of the dispatcher, one cross-vendor seat (mistral). Its verdict is folded here at v1.0.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-824@<box2> | **v0.1** |
| Reviewer | (to be placed: mistral) | waiting |
