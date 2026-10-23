# Bug-fix round 4 - plan (3 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 4 focus: **freshly measured defects: `spool keygen` writes a clear box key beside a sealed one, the GC's half-hour pass dies on grok's weekly-limit menu every hour, and the weekly-quota reading never sees grok's limit screen**.  
Concurrency: **build 2 row lanes in parallel at all times** (rounds-rulebook.md §1.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1-R16), by pointer, not copied. Issue: SPL-2969.  
Model: [bug-round-3-plan.md](bug-round-3-plan.md) (same shape, same 5 sources).

**Status: v1.0, folded, for the reviewer's signature** (reviewer verdict [seat-mistral.md](bug-round-4/seat-mistral.md), `3c94a73c0`: 2 agree / 1 agree with changes / 0 disagree; the change is folded in Row 02's red control).

Editor: **c-727@<box2>** (claude, the backup vendor for `specs_and_docs`).  
Reviewer: **m-833@sat** (mistral, cross-vendor per rounds-rulebook 2.7.2: agy and grok had no quota on either box; dispatcher msg 6758a9d8, ask 289f3cc1); verdict `3c94a73c0`. It signs v1.0 in its own commit.

**One sha:** every count is measured on **`3f48f3afe`** (`origin/master`, 2026-10-23T00:00Z), n=1 per command unless stated.  
Re-checked on `c89e8f060` (origin/master at the push, spec 025 B2): `git diff --stat 3f48f3afe c89e8f060 -- <every row file>` -> empty.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else, with a **red control**: a test that fails on `3f48f3afe` and passes after the fix. Each red control below was run on `3f48f3afe` (section 3.2).
- **Paths:** repo-relative. Lines as of `3f48f3afe`.
- **Box:** the preferred box; the placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules: WUI or hub work goes to claude, Mistral writes no code.
- **Subject** (R6 reads it): `fix(b04-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<absolute journal path>`.

---

## 2. Where the rows come from (measured on `3f48f3afe`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 since 2026-10-22** | `cd csi-spl-orc && ENV=prd SQL="select count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)') from messages where tenant_id='t1' and ts >= '2026-10-22' and from_id like 'HUM%'" ./run -a do_spl_db_query`, then every body read (`left(body,220)`, ordered by ts) | 264 human posts, 1 defect-worded; 232 of the 264 are `[spool-probe]` lines, the other 32 owner posts read by hand (n=1) | 2 describe a defect: t1 d8ede89a (omnibox under the Android bar, msg b4ff9ea6) and t1 deb3a5ed (rotation failures, msg b7a3b511). Both fixed and live (section 4). 0 rows. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 200 runs 2026-10-21T10:49Z..2026-10-23T00:00Z: 122 success, 59 cancelled, 19 failure | Every failed job's last green is run `39875478235` on `3f48f3afe` (2026-10-23T00:00:58Z). Active trunk defects: **0**. Repeated signatures in section 4. Every timeout headroom line is `ok` (worst: orc hermetic 3/3, p90 829 s of 1800 s, 46 %). |
| **3. Skipped or disabled tests, local flakes** | `git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 3f48f3afe -- csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl \| wc -l` | 183 lines (api 136, wui 17, orc 9, iac 21, utl 0): 8 more than round 3's 175; 4 entries in `csi-spl-wui/tests/e2e/ci-skip.txt`, 0 in `csi-spl-orc/src/bash/features/ci-skip.txt` | 0 defects. The 8 new lines (a diff of the sorted grep on `396343618` and on `3f48f3afe`) are all Go skips gated on `SPOOL_TEST_PG_DSN` or the real Postgres executor. The 4 e2e entries are the same as in round 3, each with its reason. The WUI unit skip (`agent-id.test.mjs:78`) still fires only without `agentid.go`. Local flake runs in section 5. |
| **4. GC notes and box alarms, last 24 h** | the GC journal `/var/spool-hub/dispatch/gc/gc.log` on <box2> (`awk '$1 >= "<now-24h>"'`, counted by event); `rotate.log`, `lease.log` on <box2>; `spool tail --task gc-sat` | gc.log: 48 START, 24 DONE, 23 END-STALE, 11 POKE, 3 REFUSED, 1 CLOSE-ASK. `gc-sat`: "no messages visible to this box" (sat's GC notes cannot be read from <box2>) | **2 reproduced** (Row 02: every grok pass is ended stale; Row 03, found while checking Row 02: the weekly-quota reading never sees grok's limit screen). The rest in sections 4 and 6. |
| **5. Open defect issues** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list` | 312 issues (total 312), 4 labelled `bug`; 34 more with a defect word in the title but no label | SPL-1945 (blocked, needs owner); SPL-455 / SPL-450 / SPL-435 out of scope by the brief. The 34 are lane briefs or stale rotation blockers (section 4). **1 reproduced** from a candidate the dispatcher passed on (c-002@sat msg 2ac80966, from the s025 B4 R7 review, c-831@sat msg 4a7da8e7): Row 01. |

---

## 3. The 3 rows

| # | defect | evidence | sites file:line | red control (fails on `3f48f3afe`) | fix scope | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b04-01-api-keygen-refuses-sealed-box)` | `spool keygen` on a box sealed by the owner lock (spec 025 [box-owner-lock.md](../../specs/025-spool-tenant-rbac/box-owner-lock.md) 4.3: the key exists only as `box-<id>.key.enc`) exits 0 and writes a new clear `box-<id>.key` beside the sealed one. That is a second identity, and 4.6 says the box never gets one ("it never makes a clear key next to a sealed one"). `cmdKeygen` calls `sign.LoadPrivate`, which finds no clear key (`ErrUnpinned`), then `sign.GenerateKey`; it never asks `lockkey.IsSealed`. `boxKey` in `internal/action/join.go:173` does ask it. The hub client (`internal/hubclient/hubclient.go:280`) then loads that clear key, and the hub refuses it as unpinned. | Scratch test in a copy of the module at `3f48f3afe`, built on `lock_test.go`'s `newLockEnv`: `go test -count=1 -run TestZZKeygenOnSealedBox -v ./cmd/spool` -> `after seal: sealed=true clear-key-exists=false`, `keygen rc=0 out="AesEYx…=\n" err="" clear-key-exists=true`, FAIL (n=1). `--force` takes the same `GenerateKey` call (read in the code, not run). | `csi-spl-api/src/go/spool-hub-api/cmd/spool/main.go:391-420` (`cmdKeygen`; the `!*force` branch :404-413, `GenerateKey` :414); reference only: `internal/action/join.go:169-176` (`boxKey`), `internal/lockkey/store.go:67-71` (`IsSealed`); new test `cmd/spool/keygen_sealed_test.go` | The scratch test above, adopted as `TestKeygenSealedBox`: after `lock seal`, `cmdKeygen` with and without `--force` exits non-zero, writes no `box-<id>.key`, and its error names `spool lock`. Control: on an unsealed keys dir `keygen` still writes the key, and `TestRunKeygenAndPin` (`main_verbs_test.go:66`) stays green. | In `cmdKeygen`, after `CheckKeysDir` and before the `LoadPrivate` / `GenerateKey` calls: when `lockkey.IsSealed(cfg.KeysDir, *box)`, refuse with or without `--force` ("box <id> is sealed by the owner lock: its key is box-<id>.key.enc; use spool lock reseal / rebind") and exit 1. No change to `hubclient.go` (spec 025 leaves the client's key source for a later row: B2, `c89e8f060`, box-owner-lock.md "Not in B2") or to `join.go`. Docs: one line in box-owner-lock.md 4.6 ("`spool keygen` refuses a sealed box"). | sat | claude | simple_coding | 1 (lane A) |
| 02 `fix(b04-02-orc-gc-start-falls-back-on-limit)` | The GC's :30 slot (`csi-spl-orc/cnf/gc/gc.conf`: `slot 30 grok`, `fallback claude`) starts grok while grok's login is at its weekly limit. The session stops on grok's "You hit your weekly limit" menu, does nothing for 30 min, and the next start ends it (`END-STALE`). The fallback covers only a CLI that is not installed (`gc-session.sh:31-35`), never a vendor stopped on a known dialog, so half the box's GC passes are lost. | gc.log on <box2>, by pass and vendor: 2026-10-22 grok 22 of 24 passes stale (claude 23 of 23 done); 10-21 grok 11 stale, 13 done; 10-16 grok 23 stale. Last 24 h: 24 grok starts, 23 `END-STALE`, 0 grok DONE. The pass of 2026-10-23T00:30Z (`START 20261023T0030Z-gc-<box2> grok %305`) was captured at 00:52Z on `You hit your weekly limit.` / `1 (○) Buy more credits` / `2 (○) Try Again`, and was ended at 01:00:03Z (`END-STALE … 1800s >= 1500s`). | `csi-spl-orc/src/bash/run/spl-gc.func.sh:149-175` (`spl_gc_start`: vendor :162, `new-window` :168, run file :171); reference only: `csi-spl-orc/src/bash/features/spawn-agents/lib/start-check.inc.sh:51-61,103` (`SPOOL_START_DIALOGS`, `spool_start_check`); test `csi-spl-orc/src/bash/tests/gc-agent.tst.sh` | gc-agent.tst.sh's own sandbox (stub tmux, `screen.<pane>` files), one new case: the :30 start's new pane `%900` shows `You hit your weekly limit.` / `Buy more credits` / `Try Again`, then `gc start $((H0 + 1800))`. Today: `START 20261015T2130Z-gc-box-a grok %900`, the run file says `grok`, no fallback (scratch copy of the suite: `1 failure(s)`). After the fix it must end that window, start `claude` in a new one, **write `claude` to the run file** (`$D/gc/run`, the check's `grep -q claude`; reviewer change, `3c94a73c0`), and log one line that names the dialog. | In `spl_gc_start`, after the window starts: `spool_start_check` on the new pane with a short wait (knob `GC_START_CHECK_S`; the lane measures its default: how long grok takes to draw its menu, n>=3 on a box). On `grok weekly limit` or `usage limit`: kill that window, log `FALLBACK <rid> <vendor> -> <GC_FALLBACK>: <dialog>`, start once more with `GC_FALLBACK`, and write that vendor to the run file. If the fallback also stops on a dialog: `FAIL <rid>`, no third start. "No input box within the wait" keeps the window, as today, so the cron never blocks on a slow CLI. The suite's stub screen (`some output` / `❯`) draws no input box, so the existing cases set the knob to 0 or 1 s and stay green; the commit names that (R1). No change to `gc.conf` or `gc-session.sh`. | sat | claude | simple_coding | 1 (lane B) |
| 03 `fix(b04-03-orc-quota-reads-grok-limit-screen)` | `spl_box_quota_parse grok` reads only grok's footer, `Weekly limit left: N%`. Grok's limit screen ("You hit your weekly limit." over the Buy / Try Again menu) draws no footer, so a grok seat stopped on it gives no reading. The box's grok usage reads "unknown", never 100, and `do_spl_box_pick BOX_PICK_KIND=grok` places grok lanes there anyway ("placed anyway"). The same banner already reads 100 for claude (`spl-box-pick.tst.sh:429`). | `source csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh; printf '  ┃  You hit your weekly limit.\n' \| spl_box_quota_parse grok` -> nothing. Control: `printf 'Weekly limit left: 0%%\n' \| spl_box_quota_parse grok` -> `100`. `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 01:0xZ: `BOX sat … grok weekly unknown <- pick` and `BOX <box2> … grok weekly unknown`, while <box2>'s grok was out of quota (Row 02's capture). Failover-orch's g-001 pane stopped on the same screen on 2026-10-22T09:56Z (`rotate.log`: `SWITCH FAIL … 'grok weekly limit' dialog`). | `csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh:44-48` (the `grok)` case of `spl_box_quota_parse`), comment :8-11; test `csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh` (section 16, next to :431) | The command above as a section 16 case: `You hit your weekly limit.` (with grok's `┃` frame) parses to `100`; today it gives nothing. Controls: `Weekly limit left: 4%` stays `96`; a line that only quotes the words mid-sentence ("… said: you hit your weekly limit") gives no reading, as for claude. | In the `grok)` case: when the footer gives nothing, a line that matches start-check's own grok pattern (`[Yy]ou hit your weekly limit`, framed by `┃` or spaces only, never a bare "weekly limit") reads `100`; the newer of the two kinds wins. Update the comment at :8-11. **Expected reading:** unchanged while no `g-` window shows the screen (the GC window is named `gc@<box>` and is not scanned); Row 02 stops the GC from sitting on it. | sat | claude | simple_coding | 2 (lane B, after Row 02) |

### 3.1 Disjoint files (R1) and 2 parallel lanes

- **Lane A:** Row 01 (`csi-spl-api/.../cmd/spool/main.go`, new `cmd/spool/keygen_sealed_test.go`, one line in `box-owner-lock.md` 4.6).
- **Lane B:** Row 02 (`spl-gc.func.sh`, `gc-agent.tst.sh`) -> Row 03 (`spl-box-quota.func.sh`, `spl-box-pick.tst.sh`). Row 03 waits behind Row 02 for capacity, not because they share a file.
- Batch 1 = Row 01 + Row 02, no shared file. Batch 2 = Row 03, no file of batch 1.
- Spec 025's lock rows: B2 (`internal/hub/box_lock_routes.go`, `internal/hub/ws.go`) landed as `c89e8f060` after the measurement; B3 (queued, ask `1812a7cd`) owns `internal/hub/box_lock.go`, `dispatch.go`, `channels.go`, `fallback.go`, `backfill.go`, `channel_members.go`. Row 01 touches none of them. c-002's note: neither B2's nor B3's brief names `cmd/spool/main.go` or keygen (0 hits).
- `lane-map.sh --check <row file> --agent c-727` -> exit 4 for every row file and for this plan: no live lane lists them. The 16 live lanes with no files recorded are the r18 WUI decompose rows (c-784, c-785, c-786, c-791, c-795, c-799, c-800 @sat), rotate and role seats (c-189@<box2>; c-613, c-763, c-794, c-813, c-816 @sat), and standing seats (c-175@<box2>, c-423@<box2>, c-499@sat). None of their branch names names these files. Re-check at spawn.
- `do_spl_spawn_queue`: 1 row queued, `1812a7cd` (feature, `claude:c001-s025-lock-b3-queue-points`), disjoint.

### 3.2 Red controls run on `3f48f3afe`

Inputs, to rebuild in any scratch dir (also on <box2> at `/var/spool-hub/c-727/b04-red-controls/`, readable by the spool-agents group):

- Row 01 `zz_keygen_sealed_test.go`, in a copy of `csi-spl-api/src/go/spool-hub-api/cmd/spool/`:

  ```go
  func TestZZKeygenOnSealedBox(t *testing.T) {
  	e := newLockEnv(t)
  	if rc, _, _ := e.run(t, []string{ltSecret}, "seal"); rc != 0 { t.Fatalf("seal rc %d", rc) }
  	clear := filepath.Join(e.cfg.KeysDir, "box-"+e.cfg.BoxID+".key")
  	rc, _, _ := capture(t, "", func() int { return cmdKeygen(e.cfg, nil) })
  	if _, err := os.Stat(clear); rc == 0 || err == nil { t.Fatalf("RED: keygen rc %d, clear key written %v", rc, err == nil) }
  }
  ```

- Row 02: the first 116 lines of `gc-agent.tst.sh` (setup and stubs, with `PROJ_ROOT` pointed at the tree), then:
  `reset; printf '  ┃  You hit your weekly limit.\n  ┃  1 (○) Buy more credits\n  ┃  2 (○) Try Again\n' >"$T/tmux/screen.%900"; gc start $(( H0 + 1800 )); check "Z" 'grep -q claude "$D/gc/run" && [ "$(gcwin)" = 1 ]'`
- Row 03: the two `printf … | spl_box_quota_parse grok` lines above.

| row | command (scratch, repo untouched) | output | who |
|---|---|---|---|
| 01 | `go test -count=1 -run TestZZKeygenOnSealedBox -v ./cmd/spool` | `keygen rc=0 … clear-key-exists=true`, `FAIL` | editor + reviewer |
| 02 | `bash zz-gc-limit.tst.sh` | `START 20261015T2130Z-gc-box-a grok %900`; run file `… grok …`; `FAIL: Z. …`, `1 failure(s)` | editor + reviewer |
| 03 | `printf '  ┃  You hit your weekly limit.\n' \| spl_box_quota_parse grok` | empty (control `Weekly limit left: 0%` -> `100`) | editor + reviewer |

Baseline of the tests the rows touch, on `3f48f3afe`: wf 10 run `39875478235` is green on this sha (hub, orc hermetic 1/3..3/3, orc feature tests). The reviewer runs `bash csi-spl-orc/src/bash/tests/gc-agent.tst.sh`, `bash csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh` and `go test ./cmd/spool/` once for the baseline.

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| Omnibox under the Android navigation bar, page zoom (t1 d8ede89a, msg b4ff9ea6, 2026-10-22 06:27Z) | the topic read (`do_spl_db_query`, `task_id like 'd8ede89a%'`) | SPL-2829, `3531847f3`, posted Live on dev and prd at 07:44Z (msg b1cd7d31) | Fixed. |
| Rotation failures (t1 deb3a5ed, msg b7a3b511, 2026-10-22 13:08Z) | `git log --oneline 396343618..3f48f3afe --grep SPL-2898`; the poll answer 09a4c362 | `5eb11fb74` (SPL-2898): one alert per streak, no alert when the old window is already gone | Fixed. The failover's grok try at its limit (`rotate.log` 2026-10-22T09:56Z) backed off and switched back, as designed. |
| CI: 19 failed runs in 200 | `do_report_ci_gate` (section 2) | first reds: wui e2e 8/8 (6, "K4 1440", 10-21 23:33Z..10-22 00:32Z); orc hermetic 3/3 (6: 4x "live dev cnf: WUI entry point(s) not in env.dns.mapped_tenants" 10-22 23:14Z..23:45Z, 1x overlay "ws-hidden-02", 1x proxy port); orc hermetic 1/3 (4: 3x "an orc check skipped in CI" 14:14Z..14:45Z, 1x run-log "blocked log dirs" 10-21 10:49Z); iac (2, 03:31Z..03:51Z); e2e 7/8 (1, phone 390 header) | Each job's last green is run `39875478235` on `3f48f3afe`. K4: `af62f0e53` (SPL-2784, round 3); mapped tenants: `e0f6ea1ba` (SPL-2947, "trunk green again"); overlay: `790cd6b5f` (SPL-2913, two orc 3/3 flakes); proxy port: `21db6dcbf` (round 3). |
| Skipped tests | `git grep` (section 2) | 183 lines, 0 unconditional | Environment-gated skips, each with its reason. |
| Round 3 row 02 (rotate.log split lines): does the fix hold? | `awk` over `rotate.log`: the unstamped lines grouped by the stamp before them | 87 unstamped lines in the file, the newest block at 2026-10-21T22 (7 lines); 0 after `a9a8a835e` (landed 2026-10-22T08:55Z) | Holds (~16 h, n=1 box). |
| Round 3 row 01 (spawn share counts dead lanes): does the fix hold? | the GC DONE lines of the last 24 h | "unknown" 219 at 08:00Z, 15..18 from 09:00Z on (`ac9479545` landed in between) | Holds. |
| Round 3 row 03 (channel row counts every line) | the retro R7 seat on SPL-2924 (m-653), GC POKE 20:01Z | the retro review is still open | Owned by that seat (section 6), not a defect on the tree. |
| c-179 restarts stuck on a git username prompt (`rotate.log`, 4x 10-22 09:58Z..11:19Z, `Username for 'https://githu…`) | `grep "Username for" rotate.log`, by hour | 4 lines, none after 11:19Z; c-179 is listed as working in every GC pass since 12:00Z | Not repeating; the lane runs. |
| ROTATION FAILED blocker issues | issue list (section 2), titles starting `**ROTATION FAILED` | 10 issues, all `todo`, created 2026-10-16..10-19, none since | Stale backlog from before the asks journal, not a live defect. For the dispatcher to close. |
| 124 `wip` issues not updated since 2026-10-20 (38 of them "Lane brief"; e.g. SPL-1864, 1998, 2000, 2013, 2074 have no citing commit, and SPL-2204's work landed under SPL-2219, `79ca8cd21`) | issue list, `status == wip and updated_at < 2026-10-20` | 124 | Issue hygiene from before `/exit-clean` refused a wip issue with no end reason. The issues need closing or ending; the code needs no fix. Reported to the dispatcher with this plan. |

---

## 5. Not reproduced

| candidate | what I tried | outcome |
|---|---|---|
| Overlay provision "a new hidden workspace: ws-hidden-02" (CI run `39825636048`, 1 run) | `bash csi-spl-orc/src/bash/tests/spl-private-overlay-sync.tst.sh` x3 on <box2>, as the agent user | 3 of 3 `0 FAIL, 18 PASS`; `790cd6b5f` later fixed a recycled stub inode in that job. |
| e2e 7/8 "phone 390: label -> button moved no other header item" (run `39688000086`, 1 run, `archived-badge-unarchive.test.mjs`) | not run locally (needs the mock bundle and Chrome); 0 repeats in the other 199 runs | One run in 200; not a row without a local repeat. |
| sat's GC passes (`spool tail --task gc-sat`) | read from <box2> | "no messages visible to this box": sat's GC journal was not read. Whether sat's :30 grok passes also end stale is **unchecked**; Row 02's fix is box-neutral either way. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| The hub client reads the clear `box-<id>.key`, so a sealed box stays offline after `unlock` | spec 025, a later row: B2 landed as `c89e8f060` (SPL-2964) and its as-built note says "Not in B2, left for a later row: the box client (`internal/hubclient`) … still reads the clear key" | Spec 025's to place. Row 01 only stops `keygen` from writing the clear key that the client would read. |
| `do_spl_lane_mix` picks grok for `simple_coding` while grok is at its weekly limit (`LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` -> `pick=grok`, "0 of the last 9 simple_coding spawns, under its 41 of 100") | the dispatcher / orchestrator (vendor weights, cnf `env.box.agent_split_by_kind`) | The vendor mix reads no quota by design (the box pick does; Row 03). The rows here name claude, not lane_mix's grok. |
| Round 3 row 03 retro review (SPL-2924) | m-653 (mistral R7 seat) | Open; poked by the GC at 2026-10-22T20:01Z. |
| The 10 stale ROTATION FAILED issues, the 124 old `wip` issues | the dispatch lease holder | Section 4. |
| SPL-1945 secret rotation plan | blocked, needs owner | Not this round's to place. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 3 (all defect fixes, each with a red control run on `3f48f3afe`) |
| vendor | claude 3 |
| box (preferred) | sat 3 (`do_spl_box_pick` at 01:0xZ read <box2> at 113 %, `full`) |
| batches | 2 (batch 1: 2 parallel lanes; batch 2: 1 lane) |

---

## 8. Panel and reviewer (R7)

- **Editor:** `c-727@<box2>` (claude).
- **Reviewer:** `m-833@sat` (mistral), verdict `3c94a73c0` ([seat-mistral.md](bug-round-4/seat-mistral.md)); it signs v1.0 in its own commit.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-727@<box2> | **v1.0** (folded: Row 02 red control also asserts the run file names the fallback vendor) |
| Reviewer | m-833@sat (mistral) | **PASS v1.0, signed on acbaf31fca5c8a6cf890b5a446ed09f9ec94c6e6** |
