# Bug-fix round 47 - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6529 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `164a8788-1283-4853-a02f-3adc08766e40` ("Bug round 47", opened by c-002@sat 18:1xZ 2026-11-25, post `3634c7e0`). Round 46 ([bug-round-46-plan.md](bug-round-46-plan.md)) served all three rows b46-01 (`c9dd02117`, SPL-6462), b46-02 (`fe9df375a`, SPL-6463), and b46-03 (`f2cb19298`, SPL-6464), and is closed (`8b97f2979`, written by this seat).  
Round focus: the sources of rounds 40 to 46 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since W, owner posts), round 46's first inputs, and the holder's candidate list on sat.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. Three disjoint candidates met the bar (section 3).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-46-plan.md](bug-round-46-plan.md).

**Status: v1.0, signed: c-642 (claude) PASS on v0.1 `50f3a73d1` (landed `d5a2422f4`), W none; notes N1 to N6 folded (section 8), all 3 rows kept (holder call `67030fc2`).** **Closed**: rows b47-01 (`7fe50142d`, SPL-6535), b47-02 (`2ba02c0e2`, SPL-6538), and b47-03 (`a5cb972b7`, SPL-6539) all landed and served (section 8).

Editor: **a-709@sat** (agy, `specs_and_docs`).  
Panel: **c-642@`<box2>`** (claude, cross-vendor; seen placed on `dispatch-bug-r47` at 18:39:06Z; mistral sits on no review since 2026-11-25).

**One sha:** every site, line number and red control below is on **`8b97f2979`** (`origin/master` right after this seat's Task 1 close record landed, 2026-11-25T19:04Z, go1.26.10). At v1.0 (19:37Z), `origin/master` is `cd8cd4cec` and all 6 row files are unchanged (`git diff --stat 8b97f2979 cd8cd4cec -- <the 6 row files>` -> empty), so every site and red control holds at that head. The sources of section 2 were read on sat, 18:59Z..19:14Z on 2026-11-25. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b46-plan')` read once at 18:59Z (before this seat's Task 1 close record landed) -> `Window: W=2026-11-25T08:53:09+02:00` (commit `b1aea77d5`, round 46's v1.0 plan). The close record `8b97f2979` (19:04Z) is a newer `docs(b46-plan` commit; the recorded W stays (5.3: the planner reads W once). Since W (`b1aea77d5..8b97f2979`), `origin/master` took 76 commits (27 with `review:` lines).

---

## 1. How to read this

- `<box2>` is the fleet's box that is not sat, `<ws>` one customer workspace, `<dev-box>` one unpinned workstation box, as in rounds 21 to 46: the public repo names none of them.
- **Paths** are repo-relative. Line numbers are as of `8b97f2979`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red controls are printed verbatim in section 4. Each copies files from the named sha with `git archive` or `git show` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs).
- This seat runs on sat, so `/var/spool-hub/dispatch/c002-next-round-candidates.md`, `/var/csi/csi-spl/review-go/cron.out`, the sat spool (`dispatch-bug-r46`, `dispatch-bug-r47`) and `c-002`/`c-003` review archives were read directly.

---

## 2. Where rows could come from (measured since W)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=14h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (18:59Z) | 46 entries (06:03Z..18:35Z), 40 since W: 37 Cloud SQL statement/connection errors (`column "id"/"key"/"channel_id"/"discussion_task_id"/"host"/"created_at"/"from_agent" does not exist`, `relation "message_files"/"topics"/"tasks" does not exist`, `uuid ~~ unknown`, `uuid = text`, `invalid input syntax for type uuid`, 2 `connection to client lost` + 1 `canceling statement due to user request`) + 3 Cloud Run 503s (16:33Z..16:34Z: 2 `GET /v1/ws`, 1 `GET /v1/wui/revision`) | **0 rows.** The SQL errors are ad-hoc `do_spl_db_query` reads with wrong column/table names (rounds 41 to 46 shape); the 3 Cloud Run 503s in one 58 s window (16:33:02Z..16:34:00Z) are transient instance-roll connection errors (0 alert incidents). |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=14h ./run -a do_gcp_list_alert_incidents` (18:59:33Z) | 9 policies, 0 incidents in 04:59:33Z..18:59:33Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,120), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (18:59:46Z) | 9 issues (plus SPL-6529 this round): 3 `wip` in `csi-spl` (SPL-6531 wui e2e 5/8 `phone-back-matrix.test.mjs`, SPL-6528 env-order gate output-only plan, SPL-6527 `spool-topic-kind.sh` owner topic), 3 `wip` in the release-transfer repo (SPL-6361, 6362, 6366), 3 `onhold` (SPL-5911, 5254, 4994) | **0 rows.** All 3 `csi-spl` `wip` bug issues have live owning lanes (R3, section 6); the other 3 `wip` are in the release-transfer repo. |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (18:59Z..19:07Z, background) | 100 runs, 2026-11-25T00:19:20Z..18:57:36Z: 57 success, 27 cancelled, 13 failure, 3 running; every job's p90 under 75 % of its timeout (highest: hermetic 1/4, 60 %). 5 failed runs since W: `45674842811` (wui e2e 5/8 `360 login no-bfcache`, owned by `c-645@<box2>` SPL-6531), `45661882286` (orc feature `test-spool-send-guard-latency.sh`, green since on `6e50e1fd`, `2110eee3`, `ffaf6876`), and 3 release-note runs (`45596579656`, `45597969469`, `45598661206` on `222f6efe`, fixed) | **0 rows**: section 3.4. Every failure since W is either served on master or owned by a live lane (SPL-6531). |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 100 --json databaseId,workflowName,headSha,createdAt,conclusion` (18:59Z), `createdAt >= 2026-11-25T06:53:09Z` | 48 failed runs since W: 41 of wf 40 (`40 cd: tenant host reconcile`), 5 of wf 10 (source 4), 2 of wf 00 (`00 ops: spool hub deploy lag watch`: `45603197274` 11:18Z `Does dev serve this commit?` transient during roll; `45674000241` 18:19Z `Is dev/prd running the cnf image?` during deploy catch-up; `do_check_deploy_lag` dev+prd current at 18:59Z) | **0 rows.** wf 40 is owned by SPL-6528 (`c-692@sat`, R3); wf 10 is source 4; wf 00 was transient during deploys. |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=14h LINES=5000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (18:59Z; cap not reached), plus targeted 24 h `hours/minutes` >=400 / `hours: minutes refused` read (19:04Z) | 841 entries, 719 since W: 529 `upload token refused` (`unknown_token`), 118 `ws hello refused` (`unpinned_box`), 15 `operator/workspaces` 403, 7 `github: request refused` 404, 7 `GET /v1/view/topics/<uuid>` 404, 4 `GET /v1/view/netvisor/forecast` 404, 5 `GET /v1/release-notes/<sha>` 404, 3 `short/268185` 404, 2 `auth.callback_fail`, 2 `GET /v1/ws` 404, 1 `ws hello refused` (`hello_timeout`), 1 `wake listener down; the relay poll covers the gap`, scanner probes. Targeted 24 h `hours/minutes` read: **0 HTTP 400s and 0 `hours: minutes refused` warns** (only 1 HTTP 401 at 08:40:36Z); **0 `fleet token surge` warns** (fixed by SPL-6461 `8916db13f`) | **0 rows**: section 3.5. b46-01 deployed at 10:11Z and has seen 0 `bad_minutes` 400s since W (follow-up stays carried until a live warn fires). |
| **7. R7 notes of lanes landed since W** | `git log origin/master --since="$W" --format='COMMIT %h %cI %s%n%B%n---END---'` (76 commits, 27 with `review:` lines) and today's `c-002`/`c-003` review archive messages since 06:53Z | 27 commits with `review:` lines; three fresh, unowned bug-shaped R7 notes on already-landed commits: **a-682@sat N1** (`8690f85e` on SPL-6511 `e1795afdf`: `mcp_test.go` `harness.run` inherits other `SPOOL_*` env, plus sibling `topic_pdf_test.go:86`), **a-683@sat N1 + N2** (`b51dc941` on SPL-6523 `bbc2adb26`: `spl-dispatch-subscribe.func.sh` `hum\|` counts `note_to_self` and `humans_only_at` posts), **a-677@sat N1** (`bc7c0689` on SPL-6521 `ffaf6876d`: pinned `claude`/`grok` rows skip weekly quota and `DISK` checks) | **Rows b47-01, b47-02, b47-03** (sections 3.1 to 3.3). Other today notes (`a-480` N1, `a-490` N1, `a-697` N1, `a-704` N1, `c-708` N1-N2, `c-625` N1-N3) accounted in section 3.6 / carried. |
| **8. Owner and member posts** | `ENV=prd SQL="select tenant_id, from_id, count(*), max(accepted_at) from messages where from_id like 'HUM-%' and accepted_at > '2026-11-25T06:53:09Z' group by 1, 2 order by 1, 2" ./run -a do_spl_db_query` (18:59:54Z) | 0 rows across all workspaces | **0 rows.** |
| **9. Round 46's first inputs** | `bug-round-46-plan.md` section 7, every item re-measured on `8b97f2979` | 12 named inputs + carried N2s | **0 rows taken** (3 stronger fresh R7 bug rows fill the cap of 3): `spl-dispatch-subscribe.func.sh` false SILENT gap was dropped from r47 into its own lane SPL-6523 (`bbc2adb26`, landed; its R7 N1+N2 becomes **b47-02**); hours-minutes 400 has 0 live warn sightings since b46-01 deployed; rest carried (section 3.6). |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (read directly on sat, 18:58Z) | 139 lines: line 127 marks false SILENT gap **DROPPED 2026-11-25T16:4xZ** (own lane SPL-6523, landed); no new bug entries added since round 46 | **0 rows** directly (SPL-6523 landed, its R7 follow-up is b47-02; remaining entries accounted in section 3.6). |

---

## 3. The candidates, read

### 3.1 b47-01: `internal/mcp` CLI-parity tests (`mcp_test.go:79` and `topic_pdf_test.go:86`) inherit foreign `SPOOL_*` env vars from the caller's shell

- **What happens.** `harness.run` (`csi-spl-api/src/go/spool-hub-api/internal/mcp/mcp_test.go:70-91`, specifically `cmd.Env` at `:79-82`) builds `cmd.Env = append(os.Environ(), "SPOOL_ROOT=...", "SPOOL_KEYS_DIR=...", "SPOOL_PINS_DIR=...", "SPOOL_LOG_LEVEL=error", "SPOOL_NOTIFY_CMD=off")`. The sibling CLI-parity test in the same package, `TestTopicPDFToolEqualsCLI` (`csi-spl-api/src/go/spool-hub-api/internal/mcp/topic_pdf_test.go:85-88`), likewise does `cmd.Env = append(os.Environ(), ...)` without clearing other `SPOOL_*` keys. Unlike `localBox` (`cmd/spool/main_verbs_test.go:20-41`, which blanks 13 named `SPOOL_*` keys rather than stripping by prefix), neither clears inherited `SPOOL_*` variables (`SPOOL_HUB_URL`, `SPOOL_TENANT`, `SPOOL_DIR_LAYOUT`, `SPOOL_MSG_VERSION`, `SPOOL_BOX_ID`, `SPOOL_FLEET_ROOT`, `SPOOL_MCP_AS`, `SPOOL_TENANT_ROOT_KEY`, `SPOOL_NOTIFY_CMD`, etc.). When a caller's shell or harness exports any such `SPOOL_*` var, the CLI child reads it via `config.Load()` while the MCP side runs on a clean `testkit.NewConfig(t)`, breaking parity tests with spurious config errors.
- **Seen.** a-682@sat R7 N1 (`8690f85e`, 17:57:52Z) on SPL-6511 (`e1795afdf`, `mcp_test.go:79-82`), plus full package sweep on `8b97f2979` (`git grep -n 'Environ' 8b97f2979 -- csi-spl-api/src/go/spool-hub-api/internal/mcp/` -> **2 hits only**: `mcp_test.go:79` and `topic_pdf_test.go:86`). Reproduced live on `8b97f2979`: `SPOOL_HUB_URL=https://hub.example.invalid SPOOL_TENANT=t1 SPOOL_DIR_LAYOUT=flat go test -count=1 -run '^TestSC004MCPEqualsCLI$' ./internal/mcp/` -> `FAIL` (`mcp_test.go:186: put-file: rc=1 isErr=false`); and under `SPOOL_MSG_VERSION=99`, both `harness.run` and `TestTopicPDFToolEqualsCLI` fail with `spool: SPOOL_MSG_VERSION 99 must be 1 or 2`.
- **Red control** (`rc01-b47.sh`, section 4.1): on `8b97f2979`, tests both `harness.run` (with clean-env control passing, then polluted `SPOOL_HUB_URL`/`SPOOL_TENANT`/`SPOOL_DIR_LAYOUT`/`SPOOL_MSG_VERSION=99`) and `TestTopicPDFToolEqualsCLI` (polluted `SPOOL_MSG_VERSION=99`/`SPOOL_DIR_LAYOUT=flat`) -> both subtests fail (`rc01 exit 1`). **Control**: `fix-shape` strips every `SPOOL_*` key from `os.Environ()` via a package helper `scrubSpoolEnv` at both sites -> both subtests pass (`rc01 exit 0`).
- **Fix scope.** `csi-spl-api/src/go/spool-hub-api/internal/mcp/mcp_test.go` (`:79-82` + package helper `scrubSpoolEnv([]string) []string` dropping any `SPOOL_` prefix entry before appending explicit test overrides, plus a unit test proving polluted `SPOOL_*` vars are ignored by both `harness.run` and `TestTopicPDFToolEqualsCLI`, and a clean-env control) and `csi-spl-api/src/go/spool-hub-api/internal/mcp/topic_pdf_test.go` (`:86-88`, switch `os.Environ()` to `scrubSpoolEnv(os.Environ())` and keep explicit `SPOOL_NOTIFY_CMD=off` or its existing overrides cleanly). Touch no production code; keep every function under 75 lines (`cleancode_test.go`). `Docs: none` (test harness isolation only).

### 3.2 b47-02: `spl-dispatch-subscribe.func.sh:165-173` (`hum|`) counts `note_to_self` and humans-only channel posts that never fan out, raising false `UNSIGNED` / `SILENT` alerts

- **What happens.** `_spl_dispatch_subs_read` (`csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh:128-175`) computes `hum|<posts>|<unsigned>` at `:165-173` as the sole `FROM messages m` query in the action (`git grep -n 'FROM messages' 8b97f2979 -- csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh` -> 1 hit, `:168`). SPL-6523 (`bbc2adb26`, landed today) added `AND m.loop_id IS NULL` at `:171`, but two other non-fan-out `box-wui` `HUM-*` channel post shapes remain counted:
  1. **`note_to_self` posts** (`messages.note_to_self = true`, rdb 0278; `internal/hub/note_to_self.go:17-22`, `wui.go:777,815`): stored with `from_box = 'box-wui'`, `from_id LIKE 'HUM-%'`, `channel IS NOT NULL`, `typed_by IS NULL`, `loop_id IS NULL`, `env_sig = ''` (`fanOut` is `false` at `wui.go:815`), and never fan out (`channels.go:352`). `store/replay_postgres.go:19` (`AND NOT note_to_self`) and `do_spl_unanswered_sweep` both skip them, yet `hum|` counts them in BOTH `posts` and `uns`, triggering false `UNSIGNED` and false `SILENT` alerts.
  2. **Humans-only channel posts** (`channels.humans_only_at IS NOT NULL`, SPL-2423; `wui.go:774-776`, `channels.go:355` `!s.channelAgentsHear`): the hub skips channel fan-out and `_spl_dispatch_subs_read` already reads `humans_only_at IS NOT NULL` as `hon|` at `:139-142` so no agent is ever subscribed to them, yet `hum|` still counts their posts toward desk inbound; because `wui.go:815` (`fanOut`) still signs a pinned workspace's humans-only post, its real shape is `hum|1|0` (false `SILENT`, not `UNSIGNED`).
- **Seen.** a-683@sat R7 N1 and N2 (`b51dc941`, 18:03:41Z) on SPL-6523 (`bbc2adb26`). Verified on `8b97f2979` against `note_to_self.go:17-22`, `wui.go:774-779,815-816`, `channels.go:352-355`, `store/replay_postgres.go:19`, and `spl-dispatch-subscribe.func.sh:139-142,165-173`.
- **Red control** (`rc02-b47.sh`, section 4.2): runs `_spl_dispatch_subs_read` unmodified against a real throwaway `postgres:16-alpine` container seeded with `wn` (1 `note_to_self=true` post in `#ops`), `wh` (1 post in humans-only `#quiet`), and `wc` (1 `note_to_self` + 1 humans-only + 1 ordinary human post in `#ops`). On `8b97f2979` (with `wh` and `wc`'s humans-only posts signed per `wui.go:815`, folding panel N6): `wn=hum|1|1` (want `hum|0|0`), `wh=hum|1|0` (want `hum|0|0`), `wc=hum|3|2` (want `hum|1|1`) -> `rc02 exit 1`. **Control**: `fix-shape` adds `AND NOT m.note_to_self` and `AND NOT EXISTS (SELECT 1 FROM channels c WHERE c.tenant_id = m.tenant_id AND c.channel_id = m.channel AND c.humans_only_at IS NOT NULL)` -> `wn=hum|0|0`, `wh=hum|0|0`, `wc=hum|1|1` -> `rc02 exit 0`.
- **Fix scope.** `csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh:165-173`: add `AND NOT m.note_to_self` and `AND NOT EXISTS (SELECT 1 FROM channels c WHERE c.tenant_id = m.tenant_id AND c.channel_id = m.channel AND c.humans_only_at IS NOT NULL)` (with a brief SQL comment naming rdb 0278 and SPL-2423 above `:165`). `csi-spl-orc/src/bash/tests/dispatch-inbound-pg.tst.sh` (new section 8 after `:191`, real Postgres with full rdb migrations + `spool_rt` RLS): prove (a) a workspace with only `note_to_self=true` channel posts yields `hum|0|0` and no `UNSIGNED`/`SILENT`, (b) a workspace with only **signed** posts (`env_sig != ''`, matching `wui.go:815` `fanOut`, panel N6: `hum|1|0` before fix) in a `humans_only_at IS NOT NULL` channel yields `hum|0|0` and no `SILENT`, and (c) a mixed workspace with an ordinary channel post still yields `hum|1|1` and still raises `SILENT` when desk inbound is empty. Keep `dispatch-subscribe.tst.sh` (0 failures on `8b97f2979`) and `dispatch-inbound-pg.tst.sh` green. `Docs: none` (query comment documents the filter; aligns `hum|` with existing spec 042 `note_to_self.go` and SPL-2423 contracts).

### 3.3 b47-03: `spl_spawn_place_pin_hold` (`spl-spawn-place.func.sh:1437-1453`) skips `BOX_PICK_KIND` weekly quota and `DISK` checks on pinned `claude`/`grok` rows

- **What happens.** `spl_spawn_place_pin_hold` (`csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:1437-1453`, 17 lines) checks every pinned queued row (`hand-<box>-...`) by calling `out="$(spl_spawn_place_pick_out)"` at `:1444` with **no `BOX_PICK_KIND` and no `BOX_PICK_REVIEW_SEAT`**, and `spl_spawn_place_pin_full` (`:831-847`, 17 lines) matches only `CORDONED`, `DEGRADED`, `RECOVERING`, `AT CAP`, and CPU overflow (`p >= hi * over / 100`). It never requests or inspects `do_spl_box_pick`'s `<kind> weekly <pct>% >= <max>%: not picked`, `<kind> weekly unknown, its own mark <max>%: not picked`, or `DISK <mount> <pct>% >= <max>%: not picked` markers (`spl-box-pick.func.sh:274-275`). When the row then launches via `spawn-window.sh` with `SPAWN_BOX=<box>`, `place_box()` (`spawn-window.sh:315-326`) refuses a missing CLI (`sw_lacks_kind` at `:319`/`:324`, panel N4) but returns early before calling `do_spl_box_pick`. As a result, a pinned `claude` or `grok` row (plain or review seat) launches onto a box whose weekly quota is exhausted or whose disk is over headroom, whereas `agy` pinned rows already hold in `spl_spawn_place_agy_box_hold` (`:1484-1532`).
- **Seen.** a-677@sat R7 N1 (`bc7c0689`, 18:09:17Z) on SPL-6521 (`ffaf6876d`). Verified on `8b97f2979` across `spl-spawn-place.func.sh:564-579,831-847,1437-1465,1484-1532`, `spl-box-pick.func.sh:274-275`, and `spawn-window.sh:315-326`. Note `spl_spawn_place_hold_class` (`:564-579`) already classifies `*weekly*` as `"weekly quota"` and `*DISK*` as `"disk"`, and `spl_spawn_place_wait_keep` (`:1451`) already preserves `"^pinned to [a-z0-9]+: "`.
- **Red control** (`rc03-b47.sh`, section 4.3): sources `spl-spawn-place.func.sh` from `8b97f2979` and runs `spl_spawn_place_pin_hold` on 6 pinned rows with a stub `SPAWN_PLACE_PICK_CMD` emitting `do_spl_box_pick`'s exact `BOX` line formats: (1) plain `claude` on `qbox` (`claude weekly 94% >= 90%: not picked`), (2) logged review seat `claude` on `qbox` (`claude weekly 94%`, under 95% review-seat mark -> must pass!), (3) logged review seat `claude` on `qbox96` (`claude weekly 96% >= 95%: not picked` -> must hold!), (4) plain `grok` on `qbox` (`grok weekly unknown, its own mark 95%: not picked` -> must hold!), (5) plain `claude` on `diskbox` (`DISK /mnt/data 88% >= 85%: not picked` -> must hold!), and (6) control `claude` on `okbox` (`claude weekly 10%` -> must pass!). On `8b97f2979`: all 6 pass unheld (`waits=` empty) -> `rc03 exit 1`. **Control**: `fix-shape` holds rows 1, 3, 4, 5 with exact `pinned to <box>: box <box> ...: not picked` wait lines while rows 2 and 6 pass unheld -> `rc03 exit 0`.
- **Fix scope.** `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`:
  - In `spl_spawn_place_pin_full` (`:831-847`), also match `DISK [^ ]+ [0-9]+% >= [0-9]+%: not picked` and `[a-z0-9_-]+ weekly (unknown, its own mark [0-9]+%|[0-9]+% >= [0-9]+%): not picked` on the `BOX $1` line (panel N4/N5: missing-CLI match dropped from scope since `spawn-window.sh:319,324` already refuses it at launch; keep function <= 75 lines).
  - In `spl_spawn_place_pin_hold` (`:1437-1453`), read `vendor` (`(.placement | sub(":.*$"; ""))`) alongside `id` and `slug`, determine logged review seat (`seat=1` when in `seats` and `spl_spawn_place_seat_pass "$brief"`, independent of whether `SPAWN_PLACE_SEAT_OVERFLOW` is set; keep `ovf` from `spl_spawn_place_seat_overflow` when set else `${BOX_PICK_OVERFLOW:-200}`), leave `agy` with `kind="" seat=0` so `spl_spawn_place_agy_box_hold` keeps owning `agy` quota messages (preserves `spl-spawn-queue.tst.sh` case 13b4), and cache `BOX_PICK_KIND="$kind" BOX_PICK_REVIEW_SEAT="$seat" spl_spawn_place_pick_out` per `"$kind:$seat"` so `do_spl_box_pick` runs at most once per distinct pair per tick (keep function <= 75 lines).
  - `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`: add case 44 after `:2597` covering pinned plain `claude` held at `>= 90%`, pinned logged review seat `claude` passing at `94%` (`BOX_PICK_REVIEW_SEAT=1`) and held at `96% >= 95%`, pinned `grok` held on `unknown, its own mark 95%: not picked`, pinned row held on `DISK ...: not picked`, and clean-box control passing. Keep existing cases 1 to 43 plus `spl-box-cordon.tst.sh` and `spl-box-pick.tst.sh` (which both call `spl_spawn_place_pin_full`/`spl_spawn_place_pin_hold`) green. `Docs: none` (enforces the existing SPL-2035 / SPL-4966 / SPL-5432 weekly quota and disk-headroom contracts on pinned rows).

### 3.4 CI reds in the 100 runs, read

| run range | job | first red line | why not a row |
|---|---|---|---|
| `45674842811` (18:24Z, `ffaf6876`) | wui e2e 5/8 | `FAIL 360 login no-bfcache L3>L2>L1>L1>out Back never re-parsed /login` | **Owned**: live lane `c-645@<box2>` (SPL-6531, R3, section 6). |
| `45661882286` (17:10Z, `36546701`) | orc feature tests | `test-spool-send-guard-latency.sh: 22 passed, 4 failed` (`2. 41 messages in the inbox`, `4. a topic the index does not hold`) | **Served / green since**: `orc: feature tests` passed on `6e50e1fd`, `2110eee3`, and `ffaf6876` (18:24Z). |
| `45596579656`..`45598661206` (10:36Z..10:49Z) | release-note | `FAIL release-note: 222f6efe (full) missing Lay-What ...` | **Served**: git release note attached; green on all subsequent runs (`last green 45674842811`). |
| `45518940978`..`45533786073` (00:33Z..02:33Z, before W) | wui e2e 1/8, 2/8, 3/8 | `scrolled to the end`; `person's card paints their avatar` | **Served**: pre-W, already accounted in round 46 (SPL-6446). |

### 3.5 The prd WARNING lines, read

| candidate | read | why not a row |
|---|---|---|
| `upload token refused` (`unknown_token`), 529 since W | same box question carried since round 43 | **Not a row**: carried with holder. |
| `ws hello refused` (`unpinned_box`), 118 since W; `hello_timeout`, 1 | `<dev-box>` unpinned client retries; 1 transient timeout | **Not a row.** |
| `GET /v1/operator/workspaces` 403, 15; `github: request refused` 404, 7; `GET /v1/view/topics/<uuid>` 404, 7; `GET /v1/view/netvisor/forecast` 404, 4; `release-notes/<sha>` 404, 5; `short/268185` 404, 3; `auth.callback_fail`, 2; `GET /v1/ws` 404, 2; `wake listener down`, 1; WordPress/env scanner probes | expected refusals, missing/deleted ids, one-off transient, or internet scanners | **Not a row.** |
| `PUT /v1/me/hours/minutes` >=400 / `hours: minutes refused` | 0 HTTP 400s and 0 warn lines in 24 h (only 1 HTTP 401 at 08:40Z); b46-01 deployed 10:11Z | **Carried**: wait for a live `hours: minutes refused` warn before deciding spec 107 / WUI follow-up. |
| `fleet token surge` | 0 hits since W (fixed by SPL-6461 `8916db13f`) | **Served.** |

### 3.6 Round 46's first inputs, today's other R7 notes, and the candidate list, re-read

| candidate | result on `8b97f2979` | verdict |
|---|---|---|
| a-682@sat N1 (`mcp_test.go:79`, plus sibling `topic_pdf_test.go:86`) | both fail live under inherited `SPOOL_*` env | **Row b47-01** (section 3.1). |
| a-683@sat N1 + N2 (`spl-dispatch-subscribe.func.sh:165-173` `note_to_self` + `humans_only_at`) | both counted in `hum\|` on Postgres 16 despite no fan-out | **Row b47-02** (section 3.2). |
| a-677@sat N1 (`spl-spawn-place.func.sh` pinned `claude`/`grok` weekly quota + `DISK`) | pinned rows skip weekly quota and disk checks | **Row b47-03** (section 3.3). |
| `spl-dispatch-subscribe.func.sh` false SILENT gap (round 46 section 7, `c002-next-round-candidates.md:127`) | dropped from r47 into its own lane SPL-6523 (`bbc2adb26`, landed); its R7 N1+N2 is now **b47-02** | **Served** (main gap) / **Row b47-02** (N1+N2). |
| hours-minutes whole-batch 400 follow-up (round 46 section 7) | 0 live `hours: minutes refused` warn lines since b46-01 deployed 10:11Z | **Carried** to round 48 until a live warn confirms skew/reason. |
| `spl-customer-box-role-check.func.sh:115-122` SPL-6122 N3 (`ignore_errors`/`failed_when` in role 04) | re-checked on `8b97f2979`: `spl_cbr_when_false` (`:115-122`) still checks literal falsy `when:` only; 0 `ignore_errors`/`failed_when` hits in `src/ansible/customer-box/` today | **Carried** to round 48 (4th candidate; round capped at 3 rows, 5.1). |
| non-instruction `apply` rule [4] holds (`/var/csi/csi-spl/review-go/cron.out`: 49 historical hits) | design of noun/subject filtering wider than a narrow bug row | **Carried** to round 48. |
| today's other R7 notes: `c-708` N1 (`BoxTaskEnvelopes` box-scoped probe for `spool-topic-kind.sh` when box has no rows in topic), `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview` 403/404 probe order), `a-490` N1 (category test guard regex scope), `a-704` N1 (`moved`/`import` `["no-op"]` in `tf_plan_resource_changes`), `a-480` N1 (`syncWriter.Reset`), `a-683` N3 (non-`AgentsCommand` / embed / `channel_box_pins` posts) | non-blocking notes on recent/active lanes (some still landing or waiting for design) | **Carried** to round 48 (`c-708` N1 and `a-683` N3 worth a look once `a-690` / `c-298` land). |
| `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget` on bloated reused Postgres DBs; `unknown_token` box; hub dir mode; hermetic 2/4 timeout; composed testids; `i18n-lang-review-exempt.json:2` (still says `Lang-review: a-NNN` on `8b97f2979`); SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` | re-checked: unchanged / carried | **Carried.** |

---

## 4. Red controls, as run

### 4.1 `rc01-b47.sh` (b47-01), sha256 first 12 hex `daed9f6a49a7`, 3725 B

Run from any checkout: `bash rc01-b47.sh 8b97f2979` (exit 1), then `bash rc01-b47.sh 8b97f2979 fix-shape` (exit 0). About 20 s with a warm Go cache (builds `cmd/spool` twice).

```bash
#!/usr/bin/env bash
# rc01-b47.sh <sha> [fix-shape]: b47-01 red control. On <sha>'s tree, the two
# CLI-spawning tests in internal/mcp/ (mcp_test.go:79 harness.run and
# topic_pdf_test.go:86 TestTopicPDFToolEqualsCLI) append only a subset of
# SPOOL_* vars to os.Environ(), so other caller SPOOL_* vars (SPOOL_HUB_URL,
# SPOOL_TENANT, SPOOL_DIR_LAYOUT, SPOOL_MSG_VERSION, etc.) leak into the CLI
# subprocess while the MCP side uses a clean testkit.NewConfig. The tree is
# extracted with git archive into a mktemp dir; a test is added there only.
# fix-shape strips all SPOOL_* entries from os.Environ() at both sites before
# appending the explicit test vars (the shape, not the fix).
set -uo pipefail
sha="${1:?usage: rc01-b47.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-api csi-spl-rdb | tar -x -C "$tmp"
d="$tmp/csi-spl-api/src/go/spool-hub-api"
a=$(grep -c 'cmd\.Env = append(os\.Environ(),' "$d/internal/mcp/mcp_test.go")
b=$(grep -c 'cmd\.Env = append(os\.Environ(),' "$d/internal/mcp/topic_pdf_test.go")
echo "rc01 sites: mcp_test=$a topic_pdf_test=$b"
[ "$a" = 1 ] && [ "$b" = 1 ] || { echo "rc01 sites moved: re-read internal/mcp/*_test.go"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$d/internal/mcp/mcp_test.go" "$d/internal/mcp/topic_pdf_test.go" <<'PY' || exit 2
import sys
p1, p2 = sys.argv[1:3]
helper = '''func scrubSpoolEnv(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		if !strings.HasPrefix(kv, "SPOOL_") {
			out = append(out, kv)
		}
	}
	return out
}

'''
s1 = open(p1).read()
t1 = 'func (h *harness) run(args ...string)'
assert s1.count(t1) == 1 and s1.count('cmd.Env = append(os.Environ(),') == 1
s1 = s1.replace(t1, helper + t1, 1).replace('cmd.Env = append(os.Environ(),', 'cmd.Env = append(scrubSpoolEnv(os.Environ()),', 1)
open(p1, "w").write(s1)
s2 = open(p2).read()
assert s2.count('cmd.Env = append(os.Environ(),') == 1
s2 = s2.replace('cmd.Env = append(os.Environ(),', 'cmd.Env = append(scrubSpoolEnv(os.Environ()),', 1)
open(p2, "w").write(s2)
PY
  echo "rc01 fix-shape: mcp_test.go and topic_pdf_test.go strip SPOOL_* from os.Environ() before setting test vars"
fi
cat >"$d/internal/mcp/rc01_b47_test.go" <<'GO'
package mcp

import (
	"testing"
)

func TestRC01MCPTestsScrubInheritedSpoolEnv(t *testing.T) {
	t.Run("harness_run", func(t *testing.T) {
		h := newHarness(t)
		for _, k := range []string{"SPOOL_HUB_URL", "SPOOL_TENANT", "SPOOL_DIR_LAYOUT", "SPOOL_MSG_VERSION", "SPOOL_BOX_ID", "SPOOL_FLEET_ROOT", "SPOOL_MCP_AS", "SPOOL_TENANT_ROOT_KEY"} {
			t.Setenv(k, "")
		}
		if _, stderr, rc := h.run("send", "--from", "c-007", "--to", "c-007", "--kind", "note", "--task", task, "--body", "ctrl"); rc != 0 {
			t.Fatalf("rc01 control (clean env): rc=%d stderr=%q", rc, stderr)
		}
		t.Setenv("SPOOL_HUB_URL", "https://hub.example.invalid")
		t.Setenv("SPOOL_TENANT", "t1")
		t.Setenv("SPOOL_DIR_LAYOUT", "flat")
		t.Setenv("SPOOL_MSG_VERSION", "99")
		if _, stderr, rc := h.run("send", "--from", "c-007", "--to", "c-007", "--kind", "note", "--task", task, "--body", "polluted"); rc != 0 {
			t.Fatalf("rc01 mcp_test.go: harness.run inherited caller SPOOL_* env: rc=%d stderr=%q", rc, stderr)
		}
	})
	t.Run("topic_pdf_cli", func(t *testing.T) {
		t.Setenv("SPOOL_MSG_VERSION", "99")
		t.Setenv("SPOOL_DIR_LAYOUT", "flat")
		TestTopicPDFToolEqualsCLI(t)
	})
}
GO
cd "$d" && go test -v -count=1 -run '^TestRC01MCPTestsScrubInheritedSpoolEnv$' ./internal/mcp/ 2>&1 | tail -16
rc=${PIPESTATUS[0]}
echo "rc01 exit $rc"
exit "$rc"
```

Output on `8b97f2979` (sat, 19:14Z, go1.26.10):

| run | output |
|---|---|
| `bash rc01-b47.sh 8b97f2979` | `rc01 sites: mcp_test=1 topic_pdf_test=1` / `rc01_b47_test.go:21: rc01 mcp_test.go: harness.run inherited caller SPOOL_* env: rc=1 stderr="spool: SPOOL_MSG_VERSION 99 must be 1 or 2"` / `topic_pdf_test.go:102: cli rc 1 "spool: SPOOL_MSG_VERSION 99 must be 1 or 2\n"` / `FAIL` / `rc01 exit 1` |
| `bash rc01-b47.sh 8b97f2979 fix-shape` | `rc01 sites: mcp_test=1 topic_pdf_test=1` / `rc01 fix-shape: mcp_test.go and topic_pdf_test.go strip SPOOL_* from os.Environ() before setting test vars` / `PASS` (`harness_run` + `topic_pdf_cli`) / `ok github.com/csitea/csi-spl/spool-hub-api/internal/mcp 19.813s` / `rc01 exit 0` |

### 4.2 `rc02-b47.sh` (b47-02), sha256 first 12 hex `f2a64d0d8af5`, 4915 B

Run from any checkout with cached `postgres:16-alpine` + `docker` + `psql`: `bash rc02-b47.sh 8b97f2979` (exit 1), then `bash rc02-b47.sh 8b97f2979 fix-shape` (exit 0). About 3 s each.

```bash
#!/usr/bin/env bash
# rc02-b47.sh <sha> [fix-shape]: b47-02 red control. On <sha>'s tree,
# _spl_dispatch_subs_read (spl-dispatch-subscribe.func.sh:165-173) counts
# note_to_self=true channel posts (a-683 N1, env_sig='', false UNSIGNED+SILENT)
# and posts in humans-only channels (channels.humans_only_at IS NOT NULL,
# a-683 N2, signed per wui.go:815 fanOut, false SILENT) in hum|posts|uns, even
# though neither fans out to the dispatchers' desk (channels.go:352,355). Runs
# _spl_dispatch_subs_read against a throwaway postgres:16-alpine container.
# fix-shape adds AND NOT m.note_to_self and AND NOT EXISTS (... humans_only_at
# IS NOT NULL) to the hum| query.
set -uo pipefail
sha="${1:?usage: rc02-b47.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
tmp="$(mktemp -d)"; ctr=""
cleanup() { [[ -n "$ctr" ]] && docker rm -fv "$ctr" >/dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT
git -C "$repo" show "$sha:csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh" >"$tmp/ds.sh" || exit 2
a=$(grep -c 'AND m.loop_id IS NULL' "$tmp/ds.sh")
echo "rc02 site: loop_id filter count=$a"
[ "$a" = 1 ] || { echo "rc02 site moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$tmp/ds.sh" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = '   AND m.loop_id IS NULL\n'
new = ('   AND m.loop_id IS NULL AND NOT m.note_to_self\n'
       '   AND NOT EXISTS (SELECT 1 FROM channels c WHERE c.tenant_id = m.tenant_id\n'
       '                      AND c.channel_id = m.channel AND c.humans_only_at IS NOT NULL)\n')
assert s.count(old) == 1, "fix-shape target not unique"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "rc02 fix-shape: hum| skips note_to_self and humans_only_at channels"
fi
img="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
ctr="rc02-b47-$$"
docker run -d --rm --pull never --name "$ctr" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$img" >/dev/null || exit 2
port="$(docker port "$ctr" 5432/tcp | sed -n 's/.*://p' | head -1)"
[ -n "$port" ] || exit 2
for _ in $(seq 1 60); do docker exec "$ctr" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.2; done
dsn="postgres://spool:spool@127.0.0.1:$port/spool_hub?sslmode=disable"
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$dsn" <<'SQL' >/dev/null || exit 2
CREATE TABLE channels (tenant_id text, channel_id text, deleted_at timestamptz, archived_at timestamptz, humans_only_at timestamptz);
CREATE TABLE channel_subscriptions (tenant_id text, channel_id text, box_id text, agent_id text, origin text);
CREATE TABLE roster (tenant_id text, box_id text, agent_id text);
CREATE TABLE pins (tenant_id text, box_id text, revoked_at timestamptz, updated_at timestamptz);
CREATE TABLE messages (tenant_id text, msg_id uuid, channel text, from_box text, from_id text, typed_by text, loop_id uuid, note_to_self boolean NOT NULL DEFAULT false, env_sig text NOT NULL DEFAULT '', received_at timestamptz NOT NULL);
INSERT INTO channels VALUES ('wn','ops',NULL,NULL,NULL), ('wh','quiet',NULL,NULL,now()), ('wc','ops',NULL,NULL,NULL), ('wc','quiet',NULL,NULL,now());
-- wn: only note_to_self post in #ops (unsigned, no fan-out)
INSERT INTO messages VALUES ('wn','10000000-0000-4000-8000-000000000001','ops','box-wui','HUM-10',NULL,NULL,true,'',now() - interval '20 minutes');
-- wh: only signed post in a humans-only channel #quiet (wui.go:815 fanOut signs, channels.go:355 skips fan-out)
INSERT INTO messages VALUES ('wh','10000000-0000-4000-8000-000000000002','quiet','box-wui','HUM-10',NULL,NULL,false,'sig',now() - interval '20 minutes');
-- wc: 1 note_to_self + 1 signed humans-only + 1 real human channel post (control)
INSERT INTO messages VALUES ('wc','10000000-0000-4000-8000-000000000003','ops','box-wui','HUM-10',NULL,NULL,true,'',now() - interval '20 minutes');
INSERT INTO messages VALUES ('wc','10000000-0000-4000-8000-000000000004','quiet','box-wui','HUM-10',NULL,NULL,false,'sig',now() - interval '20 minutes');
INSERT INTO messages VALUES ('wc','10000000-0000-4000-8000-000000000005','ops','box-wui','HUM-10',NULL,NULL,false,'',now() - interval '20 minutes');
SQL
read_hum() {
  env PROJ_PATH="$repo/csi-spl-orc" SPL_PROXY_DSN="$dsn" DISPATCH_ORCH=c-001 DISPATCH_MASTER=c-002 DISPATCH_FAILOVER=c-003 \
    bash -c '
      set -uo pipefail
      do_log() { :; }
      spl_pg_env() { local d="$1"; shift; PGPASSWORD=spool "$@" "$d"; }
      source "$1"
      spl_dispatch_silence_win() { echo 120; }
      _spl_dispatch_subs_read "$2" | grep "^hum|"
    ' _ "$tmp/ds.sh" "$1"
}
h_wn="$(read_hum wn)"; h_wh="$(read_hum wh)"; h_wc="$(read_hum wc)"
echo "rc02 note_to_self(wn)=$h_wn (want hum|0|0); humans_only(wh)=$h_wh (want hum|0|0); mixed_control(wc)=$h_wc (want hum|1|1)"
rc=0
[ "$h_wn" = "hum|0|0" ] || rc=1
[ "$h_wh" = "hum|0|0" ] || rc=1
[ "$h_wc" = "hum|1|1" ] || rc=1
echo "rc02 exit $rc"
exit "$rc"
```

Output on `8b97f2979` (sat, 19:37Z, `postgres:16-alpine`, updated for panel N6):

| run | output |
|---|---|
| `bash rc02-b47.sh 8b97f2979` | `rc02 site: loop_id filter count=1` / `rc02 note_to_self(wn)=hum\|1\|1 (want hum\|0\|0); humans_only(wh)=hum\|1\|0 (want hum\|0\|0); mixed_control(wc)=hum\|3\|2 (want hum\|1\|1)` / `rc02 exit 1` |
| `bash rc02-b47.sh 8b97f2979 fix-shape` | `rc02 site: loop_id filter count=1` / `rc02 fix-shape: hum\| skips note_to_self and humans_only_at channels` / `rc02 note_to_self(wn)=hum\|0\|0 (want hum\|0\|0); humans_only(wh)=hum\|0\|0 (want hum\|0\|0); mixed_control(wc)=hum\|1\|1 (want hum\|1\|1)` / `rc02 exit 0` |

### 4.3 `rc03-b47.sh` (b47-03), sha256 first 12 hex `cfcf80c12048`, 7577 B

Run from any checkout: `bash rc03-b47.sh 8b97f2979` (exit 1), then `bash rc03-b47.sh 8b97f2979 fix-shape` (exit 0). Under 1 s.

```bash
#!/usr/bin/env bash
# rc03-b47.sh <sha> [fix-shape]: b47-03 red control. On <sha>'s tree,
# spl_spawn_place_pin_hold (spl-spawn-place.func.sh:1437-1453) calls
# spl_spawn_place_pick_out with no BOX_PICK_KIND / BOX_PICK_REVIEW_SEAT and
# spl_spawn_place_pin_full (:831-847) ignores weekly quota and DISK
# "not picked" marks, so pinned claude/grok rows skip those checks (a-677 N1).
# The tree is extracted with git archive into a mktemp dir. fix-shape passes
# BOX_PICK_KIND + BOX_PICK_REVIEW_SEAT per (vendor, seat) for non-agy pinned
# rows and matches weekly and DISK "not picked" markers in
# spl_spawn_place_pin_full (the shape, not the fix).
set -uo pipefail
sha="${1:?usage: rc03-b47.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc csi-spl-cnf | tar -x -C "$tmp"
sp="$tmp/csi-spl-orc/src/bash/run/spl-spawn-place.func.sh"
a=$(grep -c 'spl_spawn_place_pin_hold()' "$sp")
b=$(grep -c 'spl_spawn_place_pin_full()' "$sp")
echo "rc03 sites: pin_hold=$a pin_full=$b"
[ "$a" = 1 ] && [ "$b" = 1 ] || { echo "rc03 sites moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$sp" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old_full = '''    if (/AT CAP/) { printf "box %s is at its CI-busy agent cap", b; exit 0 }'''
new_full = '''    if (match($0, /DISK [^ ]+ [0-9]+% >= [0-9]+%: not picked/)) { printf "box %s %s", b, substr($0, RSTART, RLENGTH); exit 0 }
    if (match($0, /[a-z0-9_-]+ weekly (unknown, its own mark [0-9]+%|[0-9]+% >= [0-9]+%): not picked/)) { printf "box %s %s", b, substr($0, RSTART, RLENGTH); exit 0 }
    if (/AT CAP/) { printf "box %s is at its CI-busy agent cap", b; exit 0 }'''
assert s.count(old_full) == 1, "pin_full target not unique"
s = s.replace(old_full, new_full, 1)

old_hold = '''spl_spawn_place_pin_hold() {  # MARKED ROWS
  local id slug box why out="" held=() ps=() seats ovf
  seats="$(spl_spawn_place_seats "$1" | jq -r '.[].ask_id')"
  while IFS=$'\\t' read -r id slug; do
    mapfile -t ps < <(spl_spawn_place_slug "$slug")
    box="${ps[0]}"
    [[ -n "$box" ]] || continue
    [[ -n "$out" ]] || out="$(spl_spawn_place_pick_out)"
    ovf="$(spl_spawn_place_pin_seat_ovf "$seats" "$id" "$slug")" || ovf="${BOX_PICK_OVERFLOW:-200}"
    why="$(BOX_PICK_OVERFLOW="$ovf" spl_spawn_place_pin_full "$box" "$out")" || continue
    spl_spawn_place_wait "$id" "pinned to $box: $why"
    do_log "INFO hold: ask ${id:0:8} is pinned to $box: $why; it stays queued" >&2
    held+=("$id")
  done < <(jq -r '.[] | select(.state == "queued" and ._l) | "\\(.ask_id)\\t\\(.placement | sub("^[^:]*:"; ""))"' <<<"$1")'''
new_hold = '''spl_spawn_place_pin_hold() {  # MARKED ROWS
  local id vendor slug box why kind seat key brief held=() ps=() seats ovf
  local -A outs=()
  seats="$(spl_spawn_place_seats "$1" | jq -r '.[].ask_id')"
  while IFS=$'\\t' read -r id vendor slug; do
    mapfile -t ps < <(spl_spawn_place_slug "$slug")
    box="${ps[0]}"
    [[ -n "$box" ]] || continue
    seat=0; ovf="${BOX_PICK_OVERFLOW:-200}"
    if grep -qxF -e "$id" <<<"$seats"; then
      brief="$(spl_spawn_place_brief "$slug")"
      if [[ -n "$brief" ]] && spl_spawn_place_seat_pass "$brief"; then
        seat=1
        ovf="$(spl_spawn_place_seat_overflow)" || ovf="${BOX_PICK_OVERFLOW:-200}"
      fi
    fi
    kind="$vendor"; [[ "$kind" == agy ]] && { kind=""; seat=0; }
    key="$kind:$seat"
    [[ -v outs[$key] ]] || outs[$key]="$(BOX_PICK_KIND="$kind" BOX_PICK_REVIEW_SEAT="$seat" spl_spawn_place_pick_out)"
    why="$(BOX_PICK_OVERFLOW="$ovf" spl_spawn_place_pin_full "$box" "${outs[$key]}")" || continue
    spl_spawn_place_wait "$id" "pinned to $box: $why"
    do_log "INFO hold: ask ${id:0:8} is pinned to $box: $why; it stays queued" >&2
    held+=("$id")
  done < <(jq -r '.[] | select(.state == "queued" and ._l) | "\\(.ask_id)\\t\\(.placement | sub(":.*$"; ""))\\t\\(.placement | sub("^[^:]*:"; ""))"' <<<"$1")'''
assert s.count(old_hold) == 1, "pin_hold target not unique"
s = s.replace(old_hold, new_hold, 1)
open(p, "w").write(s)
PY
  echo "rc03 fix-shape: pin_hold passes BOX_PICK_KIND/BOX_PICK_REVIEW_SEAT; pin_full matches weekly/DISK not picked"
fi
mkdir -p "$tmp/briefs" "$tmp/spool/asks"
printf '# Lane brief: R7 reviewer, review only\n' >"$tmp/briefs/p2-reviewer.md"
cat >"$tmp/pick-stub" <<'STUB'
#!/usr/bin/env bash
k="${BOX_PICK_KIND:-}"; s="${BOX_PICK_REVIEW_SEAT:-0}"
echo "BOX okbox  load5 1.0  cpus 16  6%  under  band 70..90 (box)${k:+  $k weekly 10%}"
echo "BOX diskbox  load5 1.0  cpus 16  6%  under  band 70..90 (box)  DISK /mnt/data 88% >= 85%: not picked"
case "$k:$s" in
  claude:0) echo "BOX qbox  load5 1.0  cpus 16  6%  under  band 70..90 (box)  claude weekly 94% >= 90%: not picked"
            echo "BOX qbox96  load5 1.0  cpus 16  6%  under  band 70..90 (box)  claude weekly 96% >= 90%: not picked" ;;
  claude:1) echo "BOX qbox  load5 1.0  cpus 16  6%  under  band 70..90 (box)  claude weekly 94%"
            echo "BOX qbox96  load5 1.0  cpus 16  6%  under  band 70..90 (box)  claude weekly 96% >= 95%: not picked" ;;
  grok:*)   echo "BOX qbox  load5 1.0  cpus 16  6%  under  band 70..90 (box)  grok weekly unknown, its own mark 95%: not picked"
            echo "BOX qbox96  load5 1.0  cpus 16  6%  under  band 70..90 (box)  grok weekly 96% >= 95%: not picked" ;;
  *)        echo "BOX qbox  load5 1.0  cpus 16  6%  under  band 70..90 (box)"
            echo "BOX qbox96  load5 1.0  cpus 16  6%  under  band 70..90 (box)" ;;
esac
echo "pick=okbox reason=ok"
STUB
chmod +x "$tmp/pick-stub"
rows='[
  {"ask_id":"10000001-0000-4000-8000-000000000001","state":"queued","_l":true,"placement":"claude:hand-qbox-p1-plain"},
  {"ask_id":"10000002-0000-4000-8000-000000000002","state":"queued","_l":true,"placement":"claude:hand-qbox-p2-reviewer"},
  {"ask_id":"10000003-0000-4000-8000-000000000003","state":"queued","_l":true,"placement":"claude:hand-qbox96-p2-reviewer"},
  {"ask_id":"10000004-0000-4000-8000-000000000004","state":"queued","_l":true,"placement":"grok:hand-qbox-p3-plain"},
  {"ask_id":"10000005-0000-4000-8000-000000000005","state":"queued","_l":true,"placement":"claude:hand-diskbox-p4-plain"},
  {"ask_id":"10000006-0000-4000-8000-000000000006","state":"queued","_l":true,"placement":"claude:hand-okbox-p5-ctrl"}
]'
out="$(APP_PATH="$tmp" PROJ_PATH="$tmp/csi-spl-orc" SPOOL_ROOT="$tmp/spool" \
  SPAWN_PLACE_BRIEF_DIR="$tmp/briefs" SPAWN_PLACE_PICK_CMD="$tmp/pick-stub" \
  SPAWN_PLACE_SEAT_OVERFLOW=300 bash -c '
    set -uo pipefail
    do_log() { :; }
    spool_asks_dir() { echo "$SPOOL_ROOT/asks"; }
    source "$1"
    spl_spawn_place_seats() { jq -c "[.[] | select(.ask_id == \"10000002-0000-4000-8000-000000000002\" or .ask_id == \"10000003-0000-4000-8000-000000000003\")]" <<<"$1"; }
    spl_spawn_place_pin_hold "$2" | jq -r ".[].ask_id" | paste -sd, -
  ' _ "$sp" "$rows")"
want="10000002-0000-4000-8000-000000000002,10000006-0000-4000-8000-000000000006"
waits="$(cat "$tmp/spool/asks/.place.wait" 2>/dev/null | cut -f1,3 | paste -sd'; ' -)"
echo "rc03 unheld=$out (want $want)"
echo "rc03 waits=$waits"
rc=0
[ "$out" = "$want" ] || rc=1
grep -q 'claude weekly 94% >= 90%: not picked' <<<"$waits" || rc=1
grep -q 'claude weekly 96% >= 95%: not picked' <<<"$waits" || rc=1
grep -q 'grok weekly unknown, its own mark 95%: not picked' <<<"$waits" || rc=1
grep -q 'DISK /mnt/data 88% >= 85%: not picked' <<<"$waits" || rc=1
echo "rc03 exit $rc"
exit "$rc"
```

Output on `8b97f2979` (sat, 19:37Z, updated for panel N4/N5):

| run | output |
|---|---|
| `bash rc03-b47.sh 8b97f2979` | `rc03 sites: pin_hold=1 pin_full=1` / `rc03 unheld=10000001-...,10000002-...,10000003-...,10000004-...,10000005-...,10000006-... (want 10000002-...,10000006-...)` / `rc03 waits=` / `rc03 exit 1` |
| `bash rc03-b47.sh 8b97f2979 fix-shape` | `rc03 sites: pin_hold=1 pin_full=1` / `rc03 fix-shape: pin_hold passes BOX_PICK_KIND/BOX_PICK_REVIEW_SEAT; pin_full matches weekly/DISK not picked` / `rc03 unheld=10000002-0000-4000-8000-000000000002,10000006-0000-4000-8000-000000000006 (want ...)` / waits hold `claude weekly 94% >= 90%: not picked`, `claude weekly 96% >= 95%: not picked`, `grok weekly unknown, its own mark 95%: not picked`, `DISK /mnt/data 88% >= 85%: not picked` / `rc03 exit 0` |

---

## 5. Rows

| # | id | practice | sites (file:line on `8b97f2979`) | evidence | red control (fails on `8b97f2979`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b47-01-api-mcp-harness-scrub-spool-env` | CLI-parity tests scrub inherited `SPOOL_*` env vars | `csi-spl-api/src/go/spool-hub-api/internal/mcp/mcp_test.go:79-82` (`harness.run`); `csi-spl-api/src/go/spool-hub-api/internal/mcp/topic_pdf_test.go:86-88` (`TestTopicPDFToolEqualsCLI`) | a-682@sat R7 N1 (`8690f85e`, SPL-6511 `e1795afdf`); full package sweep (`Environ` -> 2 hits); live fail under `SPOOL_HUB_URL`/`SPOOL_DIR_LAYOUT`/`SPOOL_MSG_VERSION`; section 4.1 | `bash rc01-b47.sh 8b97f2979` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` | `go test -count=1 ./internal/mcp/`; `go test -count=1 ./internal/cleancode/...`; `bash rc01-b47.sh <fix sha>` -> exit 0 (without `fix-shape`); `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.1: add `scrubSpoolEnv` helper in `mcp_test.go` dropping all `SPOOL_*` entries from `os.Environ()`, use it at `mcp_test.go:79` and `topic_pdf_test.go:86`, add unit test proving polluted `SPOOL_*` env is ignored at both sites; touch no production code; `Docs: none` | sat (`do_spl_box_pick` 19:04Z: sat 142% claude weekly 1%, `<box2>` 362% claude weekly 20%) | claude | agy (`BOX_PICK_KIND=agy` 19:04Z: sat 142% `agy weekly unknown`, placed anyway; `<box2>` agy out until 12-01), else claude waiver seat (`1a7c70da`) | `tests` | 1 |
| 02 | `b47-02-orc-dispatch-hum-skip-note-to-self` | inbound guard counts only channel posts that fan out to the desk | `csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh:165-173` (`_spl_dispatch_subs_read` `hum\|` query); `csi-spl-orc/src/bash/tests/dispatch-inbound-pg.tst.sh` (new section 8 after `:191`) | a-683@sat R7 N1 + N2 (`b51dc941`, SPL-6523 `bbc2adb26`); `note_to_self.go:17-22`, `wui.go:774-779,815`, `channels.go:352-355`, `replay_postgres.go:19`; section 4.2 | `bash rc02-b47.sh 8b97f2979` -> `rc02 exit 1`; control `fix-shape` -> `rc02 exit 0` | `bash csi-spl-orc/src/bash/tests/dispatch-inbound-pg.tst.sh` (real Postgres + rdb migrations + RLS, sections 1 to 8); `bash csi-spl-orc/src/bash/tests/dispatch-subscribe.tst.sh`; `bash csi-spl-orc/src/bash/tests/dispatch-check-skip-probe.tst.sh`; `bash csi-spl-orc/src/bash/tests/dispatch-tick.tst.sh`; `bash rc02-b47.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x` on both files; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.2: add `AND NOT m.note_to_self` and `AND NOT EXISTS (SELECT 1 FROM channels c WHERE c.tenant_id = m.tenant_id AND c.channel_id = m.channel AND c.humans_only_at IS NOT NULL)` to `hum\|` at `:171` + SQL comment + section 8 in `dispatch-inbound-pg.tst.sh` (model 8(b) humans-only post as signed per N6); `Docs: none` | sat or `<box2>` (`do_spl_box_pick` 19:04Z: sat pick) | claude | agy on sat if quota, else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |
| 03 | `b47-03-orc-pin-hold-weekly-quota` | pinned rows honour weekly quota and disk stops | `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:831-847` (`spl_spawn_place_pin_full`) and `:1437-1453` (`spl_spawn_place_pin_hold`); `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` (new case 44 after `:2597`) | a-677@sat R7 N1 (`bc7c0689`, SPL-6521 `ffaf6876d`); `spl-box-pick.func.sh:274-275`, `spawn-window.sh:315-326`, `spl-spawn-place.func.sh:564-579,1451,1484-1532`; section 4.3 | `bash rc03-b47.sh 8b97f2979` -> `rc03 exit 1`; control `fix-shape` -> `rc03 exit 0` | `bash csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` (cases 1 to 44, incl. 13b4 and 43); `bash csi-spl-orc/src/bash/tests/spl-box-cordon.tst.sh`; `bash csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh`; `bash csi-spl-orc/src/bash/tests/spl-spawn-place-argmax.tst.sh`; `bash csi-spl-orc/src/bash/tests/spl-spawn-place-owner-prio.tst.sh`; `bash csi-spl-orc/src/bash/tests/spl-spawn-place-supply.tst.sh`; `bash rc03-b47.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x` on both files; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.3: pass `BOX_PICK_KIND` + `BOX_PICK_REVIEW_SEAT` cached per `(kind, seat)` for non-`agy` pinned rows in `spl_spawn_place_pin_hold`; match weekly and `DISK` `not picked` markers in `spl_spawn_place_pin_full` (panel N4/N5: no CLI match); keep both functions <= 75 lines; keep `agy` owned by `spl_spawn_place_agy_box_hold`; add case 44; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` 19:04Z: sat pick) | claude | agy on sat if quota, else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |

- **R1 (disjoint files):** all 3 rows are Batch 1 and share 0 files:
  - b47-01: `csi-spl-api/src/go/spool-hub-api/internal/mcp/mcp_test.go`, `csi-spl-api/src/go/spool-hub-api/internal/mcp/topic_pdf_test.go`
  - b47-02: `csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh`, `csi-spl-orc/src/bash/tests/dispatch-inbound-pg.tst.sh`
  - b47-03: `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`
- **R3** (checked 2026-11-25T19:14:31Z): `lane-map.sh --check csi-spl-api/src/go/spool-hub-api/internal/mcp/mcp_test.go,csi-spl-api/src/go/spool-hub-api/internal/mcp/topic_pdf_test.go,csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh,csi-spl-orc/src/bash/tests/dispatch-inbound-pg.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh,csi-spl-doc/doc/md/bug-round-47-plan.md --agent a-709` -> **exit 4**: 0 live lanes list these 7 paths, but 18 live lanes on `<box2>` record no files (`unknown:` c-029, c-041, c-086, c-146, c-187, c-398, c-407, c-416, c-474, c-535, c-569, c-639, c-645, c-728, c-927, c-936, c-957, c-965): **not free until the holder re-runs `--check` at placement**. The authors of SPL-6511 (`c-615`), SPL-6523 (`c-614`), and SPL-6521 (`c-652`) are no longer live in `do_spl_lane_map` (19:07Z). Live lanes on sat (a-678 lat-a4 R7, c-298 Taxes tab, c-625 Taxes R7, a-697 r01-01 R7, c-688 r01-01, c-657 lat-a5, a-649 r100 planner, c-692 SPL-6528 env-order, a-690 SPL-6527 topic-kind) touch none of these paths by scope. The queue, `./run -a do_spl_spawn_queue` (18:59:58Z): 8 queued asks (1 refactor `r02-planner`, 7 feature: `s186-m9-n2`, `lat-a6`, `lat-a7`, `y9-agy-qwen`, `topic-tags-spec`, `blog-tax-fi`, `wui-notes-delete-key`), all disjoint by slug and brief grep (`0` hits on our 6 row files).
- **R7:** claude-authored code/test rows: agy R7 seat on sat if quota (`BOX_PICK_KIND=agy` 19:04Z: sat 142% `agy weekly unknown`, placed anyway; `<box2>` agy out until 12-01), else claude waiver seat (`1a7c70da`). No grok (c-001 `dc84300a`). No mistral (no review seat since 2026-11-25, and no coding kind).
- **Rhythm (1.4):** rows queue once the panel signs and `do_spl_review_line_check` exits 0; phase is already night (started 19:00Z).
- **Pushes:** aim 1 per row (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug`.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| CI red wf 10 `45674842811` (`wui e2e 5/8`, `phone-back-matrix.test.mjs` `360 login no-bfcache`), SPL-6531 | `c-645@<box2>` | live lane; owned (R3). |
| wf 40 (`40 cd: tenant host reconcile`, 41 failures since W) / env-order gate output-only terraform plan, SPL-6528 | `c-692@sat` (R7 `a-704@sat` PASS 18:53Z) | live lane; owned (R3). |
| `spool-topic-kind.sh` owner topic bug, SPL-6527 | `a-690@sat` (R7 `c-708@sat` PASS 18:58Z) | live lane; owned (R3). |
| Latency actions 1-5 (`e3b16fea`), Taxes tab (SPL-6438), r01-01/r01-02 (`ccd57113`), r02 planner, topic-tags spec (SPL-6524), private workspace seats | live / queued lanes per `do_spl_lane_map` and `do_spl_spawn_queue` | owned; stay off. |
| Release-transfer repo open bug issues (SPL-6361, 6362, 6366) | live lanes on `<box2>` | different repository, not `csi-spl`. |
| The `unknown_token` box (529 prd WARNINGs since W) | the holder, as a box question | carried. |
| Carried round-48 inputs (section 7) | round 48 planner | carried. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 3 (all Batch 1, R1 disjoint) |
| inputs re-measured | 10 sources; 40 prd ERROR entries since W (14 h read); 719 prd WARNING entries since W (401s left out, cap not reached) + 24 h `hours/minutes` >=400 / refused read (0 400s, 0 warns, 1 401); 9 alert policies (0 incidents); 9 open t1 bug issues + SPL-6529; 100 wf 10 runs (13 failures, 5 since W: 4 served, 1 owned SPL-6531); 48 failed runs since W across all workflows (41 wf 40 owned SPL-6528, 5 wf 10, 2 transient wf 00); 76 commits and 27 `review:` lines since W + today's `c-002`/`c-003` review archive messages; 0 HUM posts since W; round 46's first inputs; holder's candidate list (139 lines on sat); `rc01-b47.sh`, `rc02-b47.sh`, `rc03-b47.sh` n=1 each way on `8b97f2979`; baseline `dispatch-subscribe.tst.sh` (0 failures) and `spl-box-cordon.tst.sh` (0 failures) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b47-'` -> 0; `git ls-remote origin 'refs/heads/review/b47-*' 'refs/heads/wip/*b47*' 'refs/heads/*-b47-*' 'refs/heads/*bug-round-47*'` -> nothing (rc 0); briefs on sat: only `hand-sat-c002-bug-round-47-planner.md` and `c002-bug-round-47-claude-panel-seat.md` (18:59Z) |
| R7 seat | agy on sat if quota, else claude waiver seat (`1a7c70da`) |
| first inputs for round 48 | `spl-customer-box-role-check.func.sh:115-122` SPL-6122 N3 (`ignore_errors`/`failed_when` in role 04); hours-minutes whole-batch 400 follow-up (once a live `hours: minutes refused` warn confirms skew/reason); `c-708` N1 (`BoxTaskEnvelopes` box-scoped probe for `spool-topic-kind.sh` when box has no rows in topic, once SPL-6527 lands); `a-683` N3 (non-`AgentsCommand` / embed / `channel_box_pins` posts in `hum\|`); `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview` 403/404 probe order, once SPL-6438 lands); `a-490` N1 (`TestCategoryTestPathsZZIsolated` guard regex scope); `a-704` N1 (`moved`/`import` `["no-op"]` in `tf_plan_resource_changes`); the non-instruction `apply` rule [4] holds (nouns / subject quotes); `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget` on bloated reused Postgres DBs; the `unknown_token` box; the hub dir mode; the hermetic 2/4 timeout; the composed testids; `i18n-lang-review-exempt.json:2`; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` as carried |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** a-709@sat (agy, `specs_and_docs`).
- **Panel:** c-642@`<box2>` (claude, cross-vendor; placed on `dispatch-bug-r47` at 18:39:06Z).
- **Row reviewer (R7):** section 5.
- **Review history:**
  - 2026-11-25 19:21Z: v0.1 `50f3a73d1`, pushed to `review/c002-bug-round-47-planner` (3 rows: b47-01, b47-02, b47-03). Sent to c-642@`<box2>` and c-002@sat on task `dispatch-bug-r47`.
  - 2026-11-25 19:34Z: panel c-642@`<box2>` (claude) **PASS** on v0.1 `50f3a73d1`, W none (msg `10173c63` to this seat; seat file `csi-spl-doc/doc/md/bug-round-47/seat-claude.md` on `review/c002-bug-round-47-claude-seat` `8905243f6`). Verified slug proof, 0 drift `8b97f2979..3582fc44b` across all 6 row files, every site on `8b97f2979`, all three rc hashes/sizes (`daed9f6a49a7`/3725, `a4d03b302a1c`/4812, `c48085295e9e`/7727), each rc exit 1 on base and exit 0 with `fix-shape`, R3 `lane-map.sh --check` (exit 4, 5 unknown on sat, none names a row file), and `do_check_dist_hygiene`. Non-blocking notes: N1 `mcp_test.go:79-82` (not `:77-80`); N2 `localBox` is `main_verbs_test.go:20-41` (blanks 13 named keys, not prefix-strip); N3 `spl_spawn_place_wait_keep` is `:1451` and `not picked` marks are `spl-box-pick.func.sh:274-275`; N4 missing CLI on named `SPAWN_BOX` is already refused at launch (`spawn-window.sh:319,324`), so launch-through holds for weekly and `DISK` only; N5 drop CLI match from row 03 scope (or add fixture); N6 humans-only channel posts are signed (`wui.go:815` `fanOut` -> `hum|1|0`, false `SILENT`, not `UNSIGNED`), model case 8(b) as signed.
  - 2026-11-25 19:35Z: holder c-002@sat (msg `67030fc2`): keep all 3 rows (bug share 9%, band 30-40%: UNDER); fold N1 to N6 into v1.0 and push to `review/c002-bug-round-47-planner` (do not land yet: `REVIEW_LINE_SYNTAX=1` rc 0 on sat, full `do_spl_review_line_check` requested on `<box2>`).
  - Review line checked: `do_spl_review_line_check` rc 0 on `<box2>` (`c-001@<box2>` `82699f56`: `DOCS-ONLY`, OK 0 of 0; holder `c-002@sat` GO `3ebb23a7`).
  - 2026-11-25 19:40Z: v1.0 landed on master as `d5a2422f4` (folds N1 to N6: exact line cites N1-N3; N4/N5 CLI match dropped from row 03 scope and `rc03-b47.sh` `cfcf80c12048` 7577 B re-run red/green; N6 signed humans-only posts in `rc02-b47.sh` `f2a64d0d8af5` 4915 B re-run red/green and case 8(b) spec updated; `rc01-b47.sh` byte-identical `daed9f6a49a7` 3725 B; 0 drift on all 6 row files `8b97f2979..cd8cd4cec`), carrying `c-642`'s box-free review line in the commit body.
  - Round closed (a-846@sat, round 48's editor, for a-709@sat, round 47's editor), no version bump: rows 01 to 03 all landed and are served. Re-measured on `origin/master` `0fcaa450b`, 2026-11-26T00:27Z..00:31Z, n=1 per command.
    - **b47-01** `7fe50142d` (SPL-6535, committed 2026-11-25T21:52:10Z, author c-689@`<box2>` claude): R7 a-790@sat agy **PASS** on `5171db11406c` (in commit body; spool msg `5242c759` 21:49:45Z, W none, N=2 non-blocking; `do_spl_review_go` GO `c11542ea` 21:50:09Z, `do_spl_review_line_check` rc 0 OK 3 of 3; holder ACCEPTED `12218621` 22:12:42Z / `8a0f46e9` 22:13:25Z). `git patch-id --stable` equal on reviewed and landed (`476afb9838a0`); diffstat 2 test files +51 -2 (`mcp_test.go`, `topic_pdf_test.go`). R5 (tests): `git merge-base --is-ancestor 7fe50142d origin/master` rc 0; sat main and desk checkouts (`0fcaa450b`) rc 0. R11: wf 10 on its own sha (`45708322442`) **success** and covering wf 10 `45718633846` on `85f11faa9` (`git merge-base --is-ancestor 7fe50142d 85f11faa9` rc 0) **success**; wf 15, 21, 25, 26, 40, 50, 61, 62, 64 **success**, 0 red.
    - **b47-02** `2ba02c0e2` (SPL-6538, committed 2026-11-25T21:13:48Z, author c-699@`<box2>` claude): R7 a-775@sat agy **PASS** on `1214f639b13b` (in commit body; spool msg `b4697596` 21:03:00Z, W none; holder GO `6719d0a2` 21:03:37Z after `do_spl_review_line_check` rc 0 OK 3 of 3; holder ACCEPTED `4a683b14` / `7950035b` 21:32:58Z..21:33:19Z to a-775 and `dee6e9c6` 21:48:22Z to c-699). `git patch-id --stable` equal on reviewed and landed (`709c08aea286`); diffstat 2 files +43 -1 (`spl-dispatch-subscribe.func.sh`, `dispatch-inbound-pg.tst.sh`). R5 (tooling): `git merge-base --is-ancestor 2ba02c0e2 origin/master` rc 0; sat main and desk checkouts (`0fcaa450b`) rc 0. R11: wf 10 on its own sha (`45703273745`) **success** and covering wf 10 `45718633846` on `85f11faa9` (`git merge-base --is-ancestor 2ba02c0e2 85f11faa9` rc 0) **success**; wf 15, 21, 25, 26, 40, 64, 67 **success**, 0 red.
    - **b47-03** `a5cb972b7` (SPL-6539, committed 2026-11-25T23:02:36Z, author c-780@sat claude): R7 a-801@sat agy **PASS** on `79a656ff39ed` (in commit body; spool `dispatch-bug-r47` msg `49779f62` 22:35:52Z, W none, N1 + N2 non-blocking; holder GO 22:36:10Z, `do_spl_review_line_check` rc 0 OK 4 of 4; holder ACCEPTED 23:28:25Z / 23:28:27Z). `git patch-id --stable` equal on reviewed and landed (`9b7cf452c527`); diffstat 2 files +104 -20 (`spl-spawn-place.func.sh`, `spl-spawn-queue.tst.sh`). R5 (tooling): `git merge-base --is-ancestor a5cb972b7 origin/master` rc 0; sat main and desk checkouts (`0fcaa450b`) rc 0. R11: wf 10 on its own sha (`45718281147`) cancelled (superseded); first completed covering wf 10 `45718633846` on `85f11faa9` (`git merge-base --is-ancestor a5cb972b7 85f11faa9` rc 0) **success**; wf 15, 25, 26, 64, 67 **success**, 0 red.
    - Round closed by c-002@sat at 23:30Z 2026-11-25 (close post `2f6e5d76` in topic `164a8788`, SPL-6529 set `done`, topic archived, per the round 48 planner brief).
    - **R8 seat teardown** (rulebook 2.8 step 3), `do_spl_lane_map` live check and `lane-map.sh --all` at 00:28Z..00:30Z 2026-11-26:
      - `c-689@<box2>` (b47-01 author, claude): not in `do_spl_lane_map` (0 live rows; `done` in `lane-map.sh --all`).
      - `c-699@<box2>` (b47-02 author, claude): not in `do_spl_lane_map` (0 live rows; `done` in `lane-map.sh --all`).
      - `c-780@sat` (b47-03 author, claude): not in `do_spl_lane_map` (0 live rows; `done` in `lane-map.sh --all`).
      - `a-790@sat` (b47-01 R7, agy, 1 review): not in `do_spl_lane_map` (0 live rows; `done` in `lane-map.sh --all`).
      - `a-775@sat` (b47-02 R7, agy, 1 review): not in `do_spl_lane_map` (0 live rows; `done` in `lane-map.sh --all`).
      - `a-801@sat` (b47-03 R7, agy, 1 review): not in `do_spl_lane_map` (0 live rows; `done` in `lane-map.sh --all`).
      - `c-642@<box2>` (panel, claude, 1 review: v0.1 PASS): not in `do_spl_lane_map` (0 live rows; `done` in `lane-map.sh --all`).
      - `a-709@sat` (editor, agy): not in `do_spl_lane_map` (0 live rows; `done` in `lane-map.sh --all`).
      No seat performed zero reviews. Branches (R8 step 2, `git ls-remote origin` at 00:27Z): `review/b47-01`, `review/b47-02`, `review/b47-03`, and `review/c002-bug-round-47-planner` are gone from origin; `review/c002-bug-round-47-claude-seat` (`8905243f6`) remains on origin (matches no round prefix of `do_git_prune_round_branches`, left to the holder).
