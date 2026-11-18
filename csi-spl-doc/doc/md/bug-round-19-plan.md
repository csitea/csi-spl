# Bug-fix round 19 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5916 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `7a8fd595-45c2-4fbc-8278-477da23154dc` ("Bug round 19", opener msg d8a84a3f, opened by c-002@sat 2026-11-18T17:52Z). Requested because the bug share was under its band (c-001 spawn-share 457144e2: 18%, 4 of 22 live lanes; 24 h 18%, band 20-30%). Round 18 ([bug-round-18-plan.md](bug-round-18-plan.md) v1.0, 0 rows) is closed: plan `232902108` on `origin/master`, quality gate 44358523357 success, SPL-5900 done.  
Round focus: the box link watch (`box-link-watch.py`), which raised an incident at 15:25:56Z that cannot clear.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Only one input gives a live, unowned defect with a red control, so the round has one row (rulebook 5.2: 1 row is a round).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-18-plan.md](bug-round-18-plan.md) and [bug-round-17-plan.md](bug-round-17-plan.md) (same shape, same 5 sources).

**Status: v0.1**, draft for the panel.  
Editor: **c-967@<box2>** (claude, `specs_and_docs`).  
Panel: asked of the dispatch holder (section 8).

**One sha:** every count below is measured on **`0268cbab8`** (`origin/master`, committed 2026-11-18T19:36:11+01:00), on <box2>, between 18:48Z and 19:10Z on 2026-11-18, unless a row says sat. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b18-plan')` -> `W=2026-11-18T18:24:57+01:00`.

---

## 1. How to read this

- Round 18 re-measured every input on `8de1d37b1`. This plan re-measures only what changed since then (`git rev-list --count 8de1d37b1..0268cbab8` -> 21 commits), and names each round 18 item it closes and why it stays closed (section 4).
- **Paths** are repo-relative. Line numbers are as of `0268cbab8`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The relay's queue and log files name a customer project and its hosts. This plan names neither: `<pack>` stands for the bundle's file name, and the box is `box`, as the watch calls it.

---

## 2. Where the rows come from (measured on `0268cbab8`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since 14:34Z** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-18T14:34:00Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query`, then every non-probe post read whole (13) | t1 20 (12 `[spool-probe]`, 2 regex hits), csitea 5 (1 regex hit) | **0 rows from the posts.** t1: poll answers (SPL-5882, the message kinds), a status question, "close this leftover" (SPL-5909) and the calendar look (SPL-5908, a feature). csitea `89afc3f6` (14:52Z, 16:12Z, "the mdp_10_report shell action still fails"): a customer project on a remote box (`git grep -c mdp_10_report 0268cbab8` -> 0), owned by c-924, done at 18:32Z. That topic led to row 01: the watch's open incident on the same link (source 4). |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (18:48Z), then the failed job's log (`gh api repos/<owner>/<repo>/actions/jobs/135008392699/logs`) | 13 failed runs; every timeout headroom line `ok` (highest p90: 54 %) | One signature new since round 18: `iac` 1 run, 44362658751 on `71152a944` (17:48Z), `FAIL: control: SETUP, the step's planted wait() never ran (verdict: clean)` in `hygiene-killed-cleanup.tst.sh:98`. Green since (44369022256 on `69ccfa3b1`, which holds `71152a944`). A flake on its first sighting (rulebook 2.11.3: a fixing lane on the 3rd); it is already **queued** as a bug lane (ask 4293e172, `c002-bug-hygiene-killed-spin-flake`, by c-001@sat), so R3 leaves it out (section 6). The other signatures are round 18's: `orc 1/4` install-box-crons (last red 15:45Z, fixed by r62-01) and `orc 3/4` "noon differs" (last red 16:45Z on `454edf844`; fixed by `b9b22d2f9` SPL-5897 at 17:48+01:00 = 16:48Z, after which every run is green). **0 rows.** |
| **3. Skipped or disabled tests** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 0268cbab8 -- "$d" \| wc -l; done`; then `git diff 8de1d37b1 0268cbab8 -G '<the same pattern>' --stat` | api 199, wui 18, orc 10, iac 21, utl 0 (round 18: the same) | The diff names only `csi-spl-doc/doc/md/bug-round-18-plan.md` (its own command text). **0 rows.** |
| **4. Box cron logs and the relay watch, since round 18's read (15:46Z)** | <box2>: an awk over the 40 `/var/csi/csi-spl{,-desk-cron}/*/cron.{out,log}` changed in the last 24 h, for `unbound variable\|command not found\|syntax error\|Traceback\|panic:\|status 141\|No such file or directory\|operand expected\|Permission denied\|FATAL\|ERROR\|unknown_discussion`, keyed by the last ISO timestamp above each line; for the 4 logs with no recent stamp (`review-go`, `box-stats`, `spawn-place`, `gc`), the same patterns over their last 3000 lines. Then `box-link-watch/cron.log` read whole since 15:20Z | 1 keyed hit; 15 + 1 in the tails | **1 row (01).** The keyed hit and the `spawn-place` tail hit are one line, `tee >(do_mask_private_keys ...)` status 141 next to `No space left on device`: the disk-full event of 2026-11-17 (round 18 source 4 a), keyed to 2026-11-21 by a deadline stamp in the log's text. `box-stats`: 14 `hub unreachable ... lookup ... connection refused` and their `FATAL`/`ERROR` lines, 575 lines before the end, every sample OK since: the network drop of 10:15Z (round 18 source 4 b). `box-link-watch`: the incident opened at 15:25:56Z is still open at 19:00Z (`INFO box: incident open since 2026-11-18T15:25:56Z`, every minute), while the relay has delivered every bundle and command sent since 15:53Z. That is row 01 (section 3). |
| **5. Open defect issues, the holder's candidate list, round 18's watch item** | prd `issues` (t1, `created_at > 2026-11-18T14:34:00Z`); the holder's list (read on sat by c-002, msg b8af597b: `c002-next-round-candidates.md`, 2967 B, mtime 2026-11-18T01:57:39Z, the file round 18 read, no row added); `git diff --stat 8de1d37b1 0268cbab8 -- <their files>`; prd `human_events` `kind='error'` since 11:18:00Z | 21 issues (7 `bug`); 7 candidate rows; 0 WUI errors | **0 rows.** Every new bug issue is done (SPL-5901, 5904, 5905, 5914, 5915) or a live lane (SPL-5911, 5919). The list's files are unchanged since `8de1d37b1` (the diff is empty), so round 18's verdicts stand (section 4). The F9 Vue crash family did not recur (section 5). |

---

## 3. The row

| # | defect | evidence | sites file:line | red control (fails on `0268cbab8`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b19-01-orc-box-link-watch-withdrawn-pack-is-no-incident)` | Condition a counts a bundle as pending from its `queued .../outbound/launch/<pack>` line until a `delivered <pack>` line (`pending_items`, `box-link-watch.py:156-191`, the match at `:162`). A pack that leaves `outbound/launch/` without being sent never gets that line, so it stays pending for good. While an incident is open, the read reaches back to its start (`conditions`, `:290-293`), so the window never ages it out: the incident never clears, and the watch reports it as "bundle <pack> sent, no receipt" (`:188`) though it was never sent. While it is open, a real stuck link on the same box raises no new blocker (one incident per box). | <box2>, 2026-11-18: the relay log has `queued <root>/box/outbound/launch/<pack> (48271732 B ...): a full git pack` at 15:25:56Z and no other line naming `<pack>` (`grep -aHc` over every `*.log` of the relay log dir -> 1 file, 1 line); `<pack>` is in neither `outbound/launch/` nor `outbound/archived/` (`ls \| grep -c` -> 0, 0). The watch: one `SENT blocker to c-002@sat ... LINK STUCK > 7 min on box box since 2026-11-18T15:25:56Z: - bundle <pack> sent, no receipt` (15:33Z), then `INFO box a:<pack>: bundle <pack> sent, no receipt, 213 min` at 18:59Z. The relay since 15:53Z (the owner restarted it, csitea msg 84f130a2): every `sent` line has its `delivered` line, the last at 19:33:55 CET. No restart was planned (no `GW_RESTART_ACTION` on <box2>). | `csi-spl-orc/src/bash/scripts/box-link-watch.py:156-191` (`pending_items`), `:286-293` (`conditions`), `:9` (the docstring of condition a); test `csi-spl-orc/src/bash/tests/box-link-watch.tst.sh` (a new case after 7b) | A suite case (`rc01.sh`, section 3.2): a fresh hub, `queued $R/box/outbound/launch/w.v1.zip ...` 30 min ago, no file in `launch/`, a later pack sent and delivered. Expect no message. On `0268cbab8`: `FAIL: b19: withdrawn pack -> 1 message(s): ... LINK STUCK > 7 min on box box ... bundle w.v1.zip sent, no receipt, since ... (30 min)`, and 3 h later `incident open since ...`. | A pack that has a `queued .../outbound/launch/<pack>` line, no `sent <pack>` line and no file at `<root>/<box>/outbound/launch/<pack>` is withdrawn: no condition a. A `sent` line keeps it pending as today (a file gone from `launch/` does not prove the send stopped: the upload may already run); commands (`gr-cmd-*`) are unchanged. The incident then clears with its normal `LINK CLEARED` note. Optional in the same row: the text says "queued, not sent" for an item that has no `sent` line. The relay itself is not in this tree and does not change. Docs: the condition a line of `csi-spl-doc/specs/016-spool-testability/box-link-7min-watcher.md`. | <box2> (the live relay and its incident are here; R5 live proof: the open incident clears on the next run after the land) | claude (`secret` kind: the live proof reads the relay's logs, which name a customer project; the code and the test are synthetic) | grok (cross-vendor; secret-class may take grok, global CLAUDE.md data rule), backup: another non-claude seat the holder names | `secret` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** row 01 alone: `csi-spl-orc/src/bash/scripts/box-link-watch.py`, `csi-spl-orc/src/bash/tests/box-link-watch.tst.sh`, `csi-spl-doc/specs/016-spool-testability/box-link-7min-watcher.md`. It reads `csi-spl-orc/src/bash/run/spl-box-link-watch.func.sh` (it sets `GW_ROOT`) but does not edit it.
- **Off limits** for the row lane, as read here: every live lane's files; the queued lanes (section 6), including the hygiene spin flake's `csi-spl-iac/src/bash/tests/hygiene-killed-cleanup.tst.sh`; refactor round 63 (SPL-5912); perf round 18 row 02 (SPL-5918, `.github/workflows/10_ci-quality.yml`); SPL-5911's relay fix (another repository: the relay's sync script, not this tree).
- **How the files were checked (2026-11-18, <box2>):**
  - 19:02:03Z `lane-map.sh --check csi-spl-orc/src/bash/scripts/box-link-watch.py,csi-spl-orc/src/bash/tests/box-link-watch.tst.sh,csi-spl-doc/doc/md/bug-round-19-plan.md,csi-spl-iac/src/bash/tests/hygiene-killed-cleanup.tst.sh --agent c-967` -> `free`, exit 0. The orchestrator re-runs it with the spec file before the spawn (R3).
  - 19:02:12Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 13 queued, 0 placing: 5 bug (agy restart gate, the hygiene spin flake, the retire report's foreign sha, the blog check waiver, the after-key cross box), 1 refactor (r63-02), 7 features. None names the box link watch.
  - SPL-5911 (c-909@<box2>, the relay's send loop that died when a pack left `launch/` between its list and its open) is the same 15:25Z event seen from the relay's side. Its fix is in the relay repository (brief `addc262c`: its sync script and a new test); row 01 is the watch in this tree. Disjoint files; the two fixes do not depend on each other.
- **Slug b19 is unused as a round id** (19:02:36Z, <box2>; sat by c-002, msg b8af597b at 19:03:03Z):
  - `git log origin/master --since="$W" --oneline -E --grep='\(b19-'` -> 0; `git log origin/master --oneline -E --grep='\bb19-[0-9]{2}-'` -> 0;
  - `git ls-remote origin 'refs/heads/review/b19-*' 'refs/heads/wip/*b19*' 'refs/heads/*-b19-*'` -> nothing; `git ls-remote origin \| grep -cE 'b19-[0-9]{2}\|bug-round-19'` -> 0;
  - `grep -rlE '(^|[^0-9a-f])b19-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs`, `/var/spool-hub/asks` and `/var/spool-hub/spawn-remote/briefs` -> 0 files (sat: 0); `bug-round-19` -> 1 file, this planner's brief;
  - sat: `git branch -a \| grep -cE 'b19-[0-9]{2}'` -> 0.

  After this plan's pushes, `--grep='(b19-'` matches the plan's commits (`docs(b19-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b19-[0-9]{2}'` stays 0 until the row lands.

### 3.2 Red control run on `0268cbab8`

| row | command (repo untouched) | output on `0268cbab8` | output with a prototype fix (on a `git archive 0268cbab8 csi-spl-orc` copy) | who |
|---|---|---|---|---|
| 01 | `bash rc01.sh <repo root>`: `box-link-watch.tst.sh` lines 1-87 (its fixture and helpers) plus the case above | `FAIL: b19: withdrawn pack -> 1 message(s): --from\|c-001\|--to\|c-701@boxa\|--kind\|blocker\|... LINK STUCK > 7 min on box box since ...: - bundle w.v1.zip sent, no receipt, since ... (30 min)` / `after 3 h: 1 message(s); incident open since ...` / `FAIL: 1` | `PASS: b19: a withdrawn, never-sent pack opens no incident` / `after 3 h: 0 message(s)` / `PASS: all`; the whole `box-link-watch.tst.sh` on the copy: 54 `PASS` lines, `ALL PASS` | editor c-967 |

The script is `/var/spool-hub/dispatch/b19-red-controls/rc01.sh` on <box2> and goes to the row lane with its brief; the lane turns it into a suite case. The prototype (about 8 lines in `pending_items` and `conditions`) only shows that PASS is reachable without breaking the suite; the lane writes its own fix.

---

## 4. Measured and not a bug (round 18's inputs, re-read)

| candidate | command | result | why not a row |
|---|---|---|---|
| Holder's list: r34-05 R7 c-331 N3 (literal `/var` paths); b12-02 R7 c-126 N1-N4 (terraform); SPL-5825 W1, W2, N1-N4 (reflection gather); SPL-5824 W1, N1, N2 (desk hop); SPL-5828 N1, N2; r34-01 R7 c-321 N1, N2; SPL-5850 N1 (AltGr) | `git diff --stat 8de1d37b1 0268cbab8 -- 'csi-spl-iac/src/bash/run/tf-*.func.sh' csi-spl-iac/lib/bash/funcs/tf-log-mask.func.sh csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh csi-spl-orc/lib/bash/funcs/spl-desk-moved.func.sh csi-spl-orc/src/bash/run/spl-lane-issue.func.sh csi-spl-orc/src/bash/run/spl-uplink-probe.func.sh csi-spl-wui/src/utils/kind-picker-keys.ts csi-spl-wui/src/utils/msg-shortcuts.mjs csi-spl-orc/src/bash/run/spl-watchdog.func.sh csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go` -> empty | Unchanged since round 18 | Closed as round 18 section 4 says (fixed by r61-02 and b14-01, or no failing behaviour). r34-01 N1/N2 are test-coverage gaps with no failing behaviour: input for a test round, not a bug row. |
| b17-01 R7 N1 (the `EXPIRED` pattern is unanchored) | `git diff --stat 8de1d37b1 0268cbab8 -- csi-spl-orc/src/bash/scripts/box-link-watch.py` -> empty | Unchanged | As round 18 section 4: hardening, no misfiring line. Row 01 edits the same file, not that pattern. |
| b17-01 live proof (no condition b on expired requests) | `box-link-watch/cron.log` since 15:20Z, the `INFO box <c>:` lines | 0 `b:` lines; the open incident is conditions a and c | Row 01 of round 17 holds. |
| desk-cron `bin/spool` older than its sources | every orc run on <box2> (`spool-env: WARN ... built 2026-10-31T02:29:14Z, last source commit 2026-11-18T17:12:45Z`) | As in rounds 12 to 18 | As before. |

---

## 5. Not reproduced, or not code

| candidate | command | result |
|---|---|---|
| **Watch: the F9 Vue crash family** (round 18 section 5; SPL-5751) | prd `human_events`, `kind='error'`, `occurred_at > '2026-11-18T11:18:00Z'`, grouped by minute and human | 0 rows: no burst since 11:17:20Z. Still no red control (round 18's panel: every store path merges rows by `msg_id` first). Stays a watch item. |
| Condition c on the same incident (`no box log received in the last 6 h`) | `box-link-watch/cron.log` | Counted only while something else is in flight (`box-link-watch.py:18-21`, `in_flight` `:400-412`: a quiet box with nothing in flight is no incident). It goes with row 01. |
| `box-stats` `hub unreachable ... lookup ... connection refused` (14) | source 4 | The network drop of 10:15Z (round 18 source 4 b); every sample OK since. |
| `spawn-place` `tee >(do_mask_private_keys ...)` status 141 | source 4 | The disk-full event of 2026-11-17 (round 18 source 4 a); the line sits next to `No space left on device`. |
| CI `orc 3/4` "noon differs" and `orc 1/4` install-box-crons | source 2 | Fixed (`b9b22d2f9`, r62-01); green since. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| CI `iac` `hygiene-killed-cleanup.tst.sh:98` spin control, 1 sighting (run 44362658751) | queued bug lane, ask 4293e172 (`c002-bug-hygiene-killed-spin-flake`, c-001@sat) | Queued. A lead for it, read here and not checked further: the control TERMs the test as soon as the first stubbed `grep` of the step marks (`hygiene-killed-cleanup.tst.sh:58-63`), while the step may still be launching its sweeps before `sweep_join` calls `wait` (the Sweep step of `10_ci-quality.yml`, `sweep_join`); its TERM trap (`sweep_stop`) then exits 143 before the planted `wait()` runs. |
| SPL-5911, the relay's send loop dies when a pack leaves `launch/` between its list and its open | c-909@<box2> (author), its R7 seat | In review (brief `addc262c`). The relay's side of row 01's event. |
| SPL-5919, the watchdog snapshot's login probe | live lane | `wip`. |
| agy restart vendor gate; retire report foreign sha; blog check agy waiver; after-key cross box | queued bug lanes (asks e37476d3, 8508b9a7, 2c936b7f, d2f0ca24) | Queued. |
| SPL-5751 and the F9 family | the owner's event-log program (t1 955ab0bd); SPL-5882 | Watch (section 5). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 |
| inputs re-measured | 5 sources; 7 holder candidates; 13 human posts; 13 failed CI runs (1 new signature); 4 cron logs read by tail; 21 new issues |
| watch items | 1 (the F9 Vue crash family, section 5) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-967@<box2> (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder on task `dispatch-bug-r19`, with at least one non-claude seat. The panel checks row 01's red control (`rc01.sh` on `0268cbab8`: RED; it may re-run it on its own `git archive` copy), the fix scope (a `sent` line keeps a pack pending), and that every other input in sections 2, 4, 5 and 6 is measured as written.
- **Row reviewer (R7):** a grok seat (cross-vendor to the claude author); backup named by the holder.
- **Review history:**
  - 2026-11-18 19:02:51Z: the editor asked the holder for the sat slug check and the candidate list (msg 5b573c2c); c-002@sat answered at 19:03Z (msg b8af597b), folded into sections 2 and 3.1.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-967@<box2> | **v0.1** |
| Panel | asked of the holder | pending |
