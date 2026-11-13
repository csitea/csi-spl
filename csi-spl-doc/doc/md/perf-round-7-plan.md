# Perf round 7 (p7) - plan (5 rows)

> Generated from qto doc `167e29ab-c06b-462c-88c6-22f5dac96f17`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5424  
Topic: f6cc015c-97b8-4ada-ab61-2f8aa125e793  

The first round under [rounds-rulebook.md](rounds-rulebook.md) section 4 (perf
rounds, a permanent round kind). Rules by pointer, not copied: sections 1 to 3
(at most 10 rows, pushes aim 1 up to 3 never more than 5, R1-R16) and 4.1 to 4.5
(every row measured first, lands with a counting or timing test and its red
control, a candidate with no measured gain is dropped).

- Owner HUM-10 msg 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- Owner HUM-10 msg 98dedfc4: under the 20% perf floor the holder requests the next
  perf round's planner instead of refactor round N+1's (rulebook 4.4).
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**

**Status: v1.1, landed** on `master` as `e7d5d3b2e` (both seats PASS on `dd82bb604`; ACCEPTED e741031b by c-002). Editor: c-660@sat (claude).

**Why now.** The holder's brief (c-002@sat, 2026-11-13 08:2xZ): the 4.4 check on
`origin/master` 3783a6b72 printed `perf 0 refactor 137 perf-share 0.0% under-20`;
`git log origin/master --oneline -E --grep='\(p7-'` -> 0 lines; refactor round 34's
planner ended its lane on this rule (SPL-5423). Re-read here at 09:45Z on
`ccef654f0`: the same grep -> `0`; no `perf-round-7-plan.md` on the tree.

**One sha.** Every number below was measured on **`ccef654f0`**
(`ccef654f0329231cce02f9ec7a8f418c03dd62f0`, `origin/master`, fetched 09:26Z and
again 09:45Z, unchanged), on the satellite box (16 vCPU), 2026-11-13
09:26Z-10:2xZ. The box was loaded (1-minute load 15..59, read beside each
measurement); every before/after pair below was run interleaved or back to back
under the same load. The raw commands and outputs: [perf-round-7/editor.md](perf-round-7/editor.md).

<a id="ws-doc-428c69ba-64a6-4830-8fa3-fa7dd70b2a7f"></a>
## 1. How to read this

- A row is one logical change, one lane, subject
  `perf(p7-<NN>-<slug>, SPL-<n>): ...`, review branch `review/p7-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number, `n`, on `ccef654f0`. **After (probe)** =
  the same command on a scratch prototype of the change, never committed; it shows
  the gain is real, the lane re-measures it on its own tree.
- **Test + red control (C2)**: the counting or timing test the row lands with, and
  the plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `hub/` = `csi-spl-api/src/go/spool-hub-api/internal/hub/`,
  `orc/` = `csi-spl-orc/`, `run/` = `csi-spl-orc/src/bash/run/`.

<a id="ws-doc-964767e3-2b54-4eeb-8ce1-2d61871fcafd"></a>
## 2. Where the rows come from

Inputs read (brief step 2), each carried finding re-checked on `ccef654f0`:

| input | finding | on `ccef654f0` | here |
|---|---|---|---|
| `perf-round-5-retro.md` input 1 | `ListReleaseNotes` count subquery, Seq Scan | the query was rewritten since (`release_note_postgres.go:200-223`, a CTE with `count(*)` subqueries); not re-measured (needs a lab Postgres with prd-sized rows) | section 6, carried |
| `perf-round-5-retro.md` input 2 | channel frames encoded once per socket | `hub/wui.go:1311` `fanoutChannelFrame` still calls `w.write(ctx, frame)` per socket; `fanoutIssue` (`hub/issues.go:505`) encodes once | **row 01** |
| `perf-round-5-retro.md` input 3 | `topic_head_apply_marks` rebuild on `r` marks | not re-measured (a write function: lab only, rulebook p5 section 2) | section 6, carried |
| `perf-round-5-retro.md` inputs 4, 5 | duplicated SQL predicate; payments coverage headroom | not perf work | section 6, to the orchestrator as refactor input |
| `perf-round-6-plan.md` rows 08, 09 | issues windowed rows; tenant dropbox lazy list | not landed (`git log --grep='p6-0[89]'` -> 0); `TenantDropBox.vue:70` still `v-show` | section 6, carried: a DOM count needs a built bundle and Chrome, and this seat installs nothing |
| spec 027 `os-tweaks-analysis.md` 4.1 | `./run` startup after the lazy loader (`SPL-5421`) | orc `./run` still `0.95 s`; 98 eager files and the index pass cost most of it | **rows 03, 04** |
| spec 027 4, row 5 | `GOMAXPROCS=1` for short `spool` CLI calls | re-measured below | **row 05** |
| spec 027 4, row 6 | test Postgres `fsync=off` | the A/B did not finish (section 6) | section 6, carried |
| new, this seat | `lane-map.sh --check` (every agent before an edit, every spawn, R3) takes `~9 s` | the local-rows pass forks `jq`, `dirname`, `basename` per worktree | **row 02** |
| new, this seat | `do_spl_desk_cnf` -> `spl_box_ws_guard` reads one cnf key with a `yq eval-all` merge of `130 KB` | measured below | section 6, not a row yet (how often it runs is not measured) |

<a id="ws-doc-bd896fe0-54ea-4457-adb4-f8aab4be7a7c"></a>
## 3. The 5 rows

| # | id | practice | baseline on `ccef654f0` (command, number, n) | after (probe, same n) | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p7-01-hub-channel-frame-encode-once)` | encode a frame once, write the bytes to every socket (round 4 G8, as `fanoutIssue`) | scratch bench `fanoutChannelFrame(ctx,"t1",nil,frame)` to 10 sockets, `go test ./internal/hub -bench P7 -benchmem -count=5`: **342 allocs/op, 20,931 B/op, 334,734 ns/op (median, n=5)** | the same frame through the encode-once path (`fanoutIssue`): **216 allocs/op (-37%), 16,962 B/op (-19%), 249,846 ns/op (-25%)** (n=5, interleaved) | `hub/wui.go:1311-1327` (`fanoutChannelFrame`); `hub/human_status.go:88-105` (`broadcastStatus`, per socket per frame); `hub/token_budget.go:110-121`; `hub/flow.go:255-258` and `:298-300` (per-member frame to each of its sockets) | new `BenchmarkFanoutChannel` beside `BenchmarkFanoutWUI` (`hub/fanout_encode_bench_test.go`), and a test with `testing.AllocsPerRun` over 10 sockets asserting allocs at most the encode-once arm + 10%. Red: the test on today's `fanoutChannelFrame` (per-socket `write`) FAILS; green after. `TestFanoutSendsOneEncodingToEverySocket` extended to the channel frame (bytes identical) | sat | claude / simple_coding | 1 |
| 02 | `perf(p7-02-orc-lane-map-local-rows-one-jq)` | one `jq` for all rows instead of one per worktree; names by parameter expansion, not `dirname`/`basename` forks | `spl_lane_local_rows` alone over `/opt/csi/csi-spl` (113 lane worktrees of 145): **4,365 ms (median, n=5; 3,008..4,650)**; the whole `lane-map.sh --check <one path> --agent c-660`: **8.97 s wall (median, n=5; 7.0..21.1), ~7 s CPU** | prototype (`printf` TSV, one `jq -R -s`): **79 ms (median, n=5; 61..101)**, output byte-identical to today's after `jq -S` (`same=yes` 5 of 5) | `run/spl-lane-map.func.sh:322-344` (`spl_lane_local_rows`, `spl_lane_local_row`) | a case in `orc/src/bash/tests/` (the lane-map suite) with 40 fixture worktrees and a `jq` PATH shim that counts calls: at most 1 `jq` for the rows (today 40), and the rows equal the old function's on the same fixture. Red: today's function -> 40 calls, FAIL | sat | claude / simple_coding | **2: after r58-07 lands** (it owns `spl-lane-map.func.sh:2`, section 3.2) |
| 03 | `perf(p7-03-run-index-cache)` | cache the lazy loader's `awk` index, keyed by the file list with sizes and mtimes; rebuild on any change | phase probe of orc `./run` (the index `awk` pass alone): **165 ms (median, n=5; 160..177)** of a **950 ms** startup (`./run -a do_p7_no_such_action`, wall median n=5; 898..989); iac `21 ms`, utl `9 ms` (n=3) | the cache key (`find ... -printf '%T@ %s %p\0' \| sort -z \| md5sum`): **12 ms (median, n=5)**, so `~150 ms` off each orc `./run` start on a hit | `orc/src/bash/run/run.sh:717-731` (`do_load_functions`), the same lines in `csi-spl-iac/src/bash/run/run.sh` and `csi-spl-utl/src/bash/run/run.sh` (byte-identical copies) | `csi-spl-iac/src/bash/tests/run-lazy-loader.tst.sh`, new cases: a second start on an unchanged tree runs the index `awk` 0 times (PATH shim count), a touched, added or removed `*.func.sh` runs it once, and the stubs equal an uncached start's. Red: drop the cache read -> the second start counts 1, FAIL | sat | claude / complex_coding (R9: it changes the test runner's loader, so `PRE_PUSH_TIER=full` and once with `PRE_PUSH_*` unset) | 1 |
| 04 | `perf(p7-04-orc-eager-top5-lazy)` | a file whose only top-level code is its dependency `source` lines and constants loads them on first call, so the lazy loader can stub it | per-file source time of the 98 eager orc files (phase probe, median of n=3): `spl-agent-restart` **121 ms**, `spl-sender-audit` **35**, `gh-runner-add` **33** (runs `dpkg -s docker-ce` at source time), `spl-box-restart-after` **25**, `spl-agent-login-check` **22**: **236 ms of the 494 ms eager phase (median, n=5; 478..516)** | not probed: the gain is the measured source time of the 5 files, less their stubs (`~0.1 ms` each, the loader's own measure); the lane re-measures | `run/spl-agent-restart.func.sh:76-83` (3 `source` lines, `ARS_CAUSES`), `run/spl-sender-audit.func.sh:24-27` (`readlink`/`dirname`, 3 `source` lines), `run/gh-runner-add.func.sh:74-77` and `:86-95` (`source`, `GH_RUNNER_PKGS`, `ghr_docker_flavour` with `dpkg -s docker-ce` at `:88`, called bare at `:95`), `run/spl-box-restart-after.func.sh:21-28` (3 `source` lines, `SPL_BRX_AGENT_WIN_RE`), `run/spl-agent-login-check.func.sh:69-71` (`source`, 2 regex constants) | new `orc/src/bash/tests/run-eager-files.tst.sh`: the index lists none of the 5 as eager, and the orc eager count is at most 93 (today 98); each file still works when sourced alone (its own tests run). Red: put one top-level `source` back -> that file reads eager, FAIL | sat | claude / simple_coding | 1 |
| 05 | `perf(p7-05-spool-cli-gomaxprocs-1)` | a short Go CLI call runs on one P (spec 027 row 5) | `spool send` (binary 1.1.3) from `c-998` to `c-999` on a scratch `SPOOL_ROOT`, `SPOOL_NOTIFY_CMD=off`, as `spool-send.sh:533` runs it, 20 rounds interleaved (11:27Z): **75.0 ms CPU (user+sys), 69.5 ms wall (median, n=20)**; `spool recv` (v0.1's command, read only): **51.0 ms CPU, 67.5 ms wall (n=20)** | `GOMAXPROCS=1`: `send` **59.0 ms CPU (-21%), 64.0 ms wall (-8%)**; `recv` **35.5 ms CPU (-30%), 53.0 ms wall (-21%)** (median, n=20; the grok seat's `recv` re-measure, n=10: -37% CPU, -14% wall) | the two short-call execs of `$SPOOL_BIN`, there is no single wrapper: `orc/src/bash/features/spawn-agents/scripts/spool-send.sh:533` (`send`) `scripts/asks.sh:66` (`claim`) and `run/spl-peer-poll.func.sh:148` (`claim`, `spl_peer_hub`, every peer-poll tick), through one helper in `lib/spool-env.inc.sh` (`SPOOL_BIN` is chosen at `:459-460`; `spool_resolve_bins` at `:486` sets only the vendor CLI paths). Not `spool-harness.sh:194` (`hub-run`, long-running: keeps the default). Never exported to the shell (it would slow `go test` and the hub). An agent's own `spool recv` line runs the binary directly and is not reached | a case in `spawn-agents/tests/`: the resolved `spool` call carries `GOMAXPROCS=1` unless the caller set one, and a `go` child of the same shell does not see it. Red: export it globally -> the `go` child sees `1`, FAIL; drop it -> the `spool` call lacks it, FAIL | sat | claude / simple_coding | 1 |

Rows 01-05 are claude: rulebook R14 (an established vendor for every row) and the
owner's 10-17 rule (no mistral coding or testing).

<a id="ws-doc-b924fbdc-3963-4ff7-b127-94027cd4c96e"></a>
### 3.1 Batches and disjoint files (R1)

- **Batch 1**: rows 01, 03, 04, 05. No path is in two rows: 01 is Go under
  `hub/`; 03 the three `run.sh` copies and `run-lazy-loader.tst.sh`; 04 five
  `run/*.func.sh` and one new test; 05 `spool-env.inc.sh`, `spool-send.sh`, `asks.sh`,
  `spl-peer-poll.func.sh` (lane map: the first three at 11:28Z, the fourth at
  11:47Z, each `free`, exit 0). Rows 03 and 04 both speed up `./run` start, through
  different files: each lane measures its own arm with the other's code as it is
  on master.
- **Batch 2**: row 02, spawned within 30 minutes (R16) of the commit that lands
  r58-07 (`refactor(r58-07-orc-action-headers-c)`), which edits
  `spl-lane-map.func.sh:2`.

<a id="ws-doc-11095f38-3a68-4a83-8c03-1b4a18b984c0"></a>
### 3.2 Off every live lane, every queued row and rounds 31-33 (R3)

Read on 2026-11-13, each with its time:

- **Lane map, every machine** (09:42Z-09:43Z per row, 09:43:39Z all paths in one
  call): `lane-map.sh --check <every path of rows 01-05, and of the fsync candidate> --agent c-660` -> exit 4,
  `0` lines `owned by`, `16` lines `unknown:` (lanes that recorded no files):
  c-004, c-308, c-382, c-390, c-507, c-528, c-545, c-669, c-816, c-826, c-890,
  c-895, c-981, g-786, g-854, o-208 (all on the second fleet box). Exit 4 is not free: the R3 check
  before each spawn re-reads it and asks a lane that is still unknown. One to ask
  first for row 01: c-308 (`feat-mention-self-note-to-self`, a post tagged only to
  its author: it may touch the hub fan-out).
- **Spawn queue** (09:44:05Z, `./run -a do_spl_spawn_queue`, `25 queued, 0
  placing`): no queued summary names a row's file. The nearest: `d0185518`
  (a `run.sh` lazy loader lane for the other
  org's projects, another repo: not row 03's files) and `561ac0c8` / `3e373385`
  (`wd-self-update` tests).
- **Unlanded round rows** (`git log origin/master --format=%s -E --grep='\(r5[789]-'`,
  09:45Z): landed r57-01..04, r58-01..05, r59-02..04. Not landed: r57-05
  (`useCardMove`), r57-06 and r59-06 (`cleancode_test.go`, `cleancode.test.mjs`
  lists), r58-06 / r58-07 (orc action headers, including `spl-lane-map.func.sh`,
  `spl-spawn-queue.func.sh`, `spl-spawn-share.func.sh`), r58-08
  (`bash-cleancode.tst.sh`), r59-01 (`hub/server.go`), r59-05
  (`spl-spawn-place.func.sh`). Only row 02 meets one (r58-07): Batch 2.
- **Slug** (09:45Z): `git log origin/master --oneline -E --grep='\(p7-'` -> 0
  lines.

<a id="ws-doc-af5c604d-48cb-4996-bcb2-007a0e7c0ce3"></a>
## 4. Per row: what the lane does

- **01**: as `fanoutIssue`: collect targets under the lock, `encodeFrame` once,
  `writeRaw` to each. The status and flow loops: encode each frame once, then
  write the bytes; the flow frame is per member, so it encodes once per member, not
  per socket. Frame bytes on the wire unchanged (the existing test pins the
  trailing newline). Frequency is honest: channel and token-budget frames are rare;
  status frames follow every status change; flow frames follow every message, to
  each member's sockets.
- **02**: `spl_lane_local_rows` prints one TSV line per lane worktree with
  `${wt%/*}` and `${wt##*/}`, and one `jq -R -s` turns them into the same JSON
  array. Check the probe's `same=yes` on the lane's tree before the push.
- **03**: in `do_load_functions`, key = md5 of the sorted `find -printf '%T@ %s %p\0'`
  list plus `run.sh`'s own md5; cache file per module under
  `${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/run-index/` (per user: two users never
  share one), written atomically (`mv`). A miss runs the `awk` as today. The three
  copies stay byte-identical.
- **04**: move each file's top-level dependency `source` lines into the functions
  that need them (or one `_<file>_deps` called first by each `do_` entry), and its
  constants into that function or a `${VAR:-...}` at use; `gh-runner-add` stops
  running `dpkg -s` at source time. No behaviour change: the file's own tests run.
- **05**: one helper in `spool-env.inc.sh`, e.g. `spool_cli() { GOMAXPROCS="${GOMAXPROCS:-1}" "$SPOOL_BIN" "$@"; }`,
  scoped to that exec; `spool-send.sh:533`, `asks.sh:66` and
  `spl-peer-poll.func.sh:148` call it instead of
  `"$SPOOL_BIN"`. `hub-run` (`spool-harness.sh:194`) and any other long-running
  `spool` command keep the default and are named in the commit.

<a id="ws-doc-d34ef092-1199-4b6b-b793-1f31b5cde729"></a>
## 5. Panel and reviewers (R7)

Read on 2026-11-13: `prd` agent kinds off = `[qwen]` only (c-001 msg b06623f5,
01:3xZ), so grok may be placed; agy is not installed on sat, and agy on the second fleet box is at
its quota until **2026-11-13T23:46:21Z** (spawn queue WAIT line, 09:44Z, its a- seat);
mistral is docs and reviews only (owner 10-17), and mistral **code** reviews were
paused (owner 10-30, cf7a7ee5); I did not find a newer word lifting that pause, and
did not check further.

- **Plan panel (rulebook 3.2)**: editor c-660@sat (claude); seats asked of the
  holder: **one grok seat** and **one mistral seat** (a plan review is a doc review,
  which mistral may do). Both are another vendor than the editor, so the panel is
  cross-vendor **without agy**; the rulebook asks for no particular vendor. If the
  holder can also place agy on the second box after 23:46Z, it is a third seat, not a
  condition. The panel signs the plan sha in `perf-round-7/<seat>.md`.
- **Row reviewers (2.7.2)**: every row's author is claude, so its reviewer is the
  grok seat, backup an agy seat on the second box once its quota is back. Mistral is not a row reviewer
  while the code-review pause stands. A row never pushes without that PASS (2.7.3).

<a id="ws-doc-46cd05f2-1411-45e1-b107-62816ec361df"></a>
## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| test Postgres `fsync=off` (spec 027 row 6): `csi-spl-api/src/bash/tests/hub-pg.tst.sh:52-53` (`pg_ctl -o`), `:58-60` (`docker run`), `csi-spl-api/src/bash/hub-live-stack.sh:59` (the `docker run` line) | no baseline: the interleaved A/B of the whole `hub-pg.tst.sh` (arm B adds `-c fsync=off -c synchronous_commit=off -c full_page_writes=off`), started 09:34Z, was stopped by the editor seat's hourly rotation during arm A's first run (its log ends at `store group d: 243 s`, 10:01Z); no pair finished, so there is no number | carried to round 8: one pair takes 30 min or more, longer than an editor session; it needs a lane of its own |
| `spl_box_ws_cnf` (`orc/lib/bash/funcs/spl-box-workspace.func.sh:27-36`): one cnf key via `yq eval-all` merge of `all.env.yaml` + `prd.env.yaml` (130 KB), on every `do_spl_desk_cnf` | a gain per call, but its box-level worth is unknown: how often `do_spl_desk_cnf` runs was not counted. The first reads were 1.85..4.42 s (n=3, 09:3xZ), the re-measure 0.25 s (median, n=5) against 0.05 s for two plain `yq` reads (n=5); a scalar key read env-file-first is the same answer as the merge, a map key is not | `yq.sh` in [perf-round-7/editor.md](perf-round-7/editor.md) 2.6. Input for round 8 with a measurement of how often `do_spl_desk_cnf` runs |
| `_spool_bin_stale` `git log -1 -- <api paths>` on every `spool-env` resolve | no gain | `13 ms` (median, n=5) for the `git log`; `11 ms` to source `spool-env.inc.sh` (n=5) |
| p5 input 1, `ListReleaseNotes` count subquery | not measured: the query changed since the retro, and a fair number needs a lab Postgres with prd-sized `release_notes` | carried to round 8 |
| p5 input 3, `topic_head_apply_marks` on `r` marks | not measured: a write function, lab only | carried to round 8 |
| p6-08 issues windowed rows, p6-09 `TenantDropBox` lazy list | not measured: a DOM count needs a built bundle and Chrome; no `node_modules` in this worktree, and this seat installs nothing | carried to round 8 |
| p5 inputs 4 (duplicated SQL predicate) and 5 (payments coverage headroom) | not perf work | to the orchestrator as refactor input |
| spec 027 rows 2-4 (kernel command line, machine family) | a GCP / VM change: the owner's go, a throwaway VM A/B | not a round row |
| spec 027 row 7 (`sudo` `!use_pty`) | removes a terminal-injection guard; ceiling `0.7%` of the box, no before/after | not a round row |

<a id="ws-doc-647b86d2-b052-40f5-a7bd-2431d8ede965"></a>
## 7. Counts

- Rows: 5 (rulebook 1.1: at most 10). Batch 1: 4, Batch 2: 1.
- Every row: one push aimed (1.2), a counting or timing test and its red control
  (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p7-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p7-' --format=%B | grep -c '^review: '` must reach 5.

<a id="ws-doc-333d46b2-2307-450d-ac4b-cd705b2be1f0"></a>
## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`) after the panel signs and it lands on
`master`, not from the review branch; from then on the Qto doc is the primary copy.


- v0.1 (c-660@sat, 2026-11-13): first draft, 5 rows on `ccef654f0`; the fsync candidate is measuring.
- v1.0 (c-660@sat, 2026-11-13): the grok seat's PASS (g-666, `seat-grok.md` on
  `review/c002-perf-round-7-grok-seat` `d0f89fcd`) folded in. W1: row 02 median
  4,365 ms (the middle of the five sorted samples), not 4,098. W2: row 04 sites
  with file:line. W3: row 05 names its real exec sites (`spool-send.sh:533`,
  `asks.sh:66`; no single wrapper exists, `spool_resolve_bins` execs nothing) and a
  baseline on `spool send`, the call it changes (-21% CPU, -8% wall, n=20). N7:
  row 01 medians 334,734 ns and 20,931 B. The fsync A/B never finished: carried,
  not a row. The mistral seat's PASS (m-669, `seat-mistral.md` on
  `review/c002-perf-round-7-mistral-seat` `0ee0871b`) folded in: its W1 is the
  grok seat's W1; W2: a `box` column (rulebook 3.1; every row is built and
  measured on sat, and the orc and spool changes run on every fleet box); N2:
  `hub-live-stack.sh`'s full path; N3: `human_status.go:88-105`.
- v1.1 (c-660@sat, 2026-11-13): the grok seat's PASS on v1.0 (`d47de8b8f`,
  `seat-grok.md` `7e93a9e8`) folded in. W1: a third short exec of `$SPOOL_BIN`,
  `spl-peer-poll.func.sh:148` (`timeout ... "$SPOOL_BIN" claim`), joins row 05's
  sites; `git grep -n '"$SPOOL_BIN"' ccef654f0` over the four `src/bash` trees,
  tests left out, prints 4 execs (`spool-send.sh:533`, `asks.sh:66`,
  `spl-peer-poll.func.sh:148`, and `spool-harness.sh:194`, which is excluded).
  The file is the same on `origin/master`, and no round 31-33 plan names it. No
  baseline change.
- Landed (c-660@sat, 2026-11-13): v1.1 on `master` as `e7d5d3b2e` (section 9 the
  only change over the signed `dd82bb604`), CI on it green (quality gate
  43421848976, docs publish 43421849066). Status line and this entry only.

<a id="ws-doc-51497156-f9d9-410e-b1c9-17cbfd43e535"></a>
## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-660@sat (editor) | claude | v1.1 `dd82bb604` | author |
| g-666@sat | grok | `e599eabf2`, `d47de8b8f`, `dd82bb604` | PASS, W1-W3 folded in v1.0; PASS on v1.0, W1 folded in v1.1; PASS on v1.1 (seat branch `41d428c02`, notes N13-N16, no hold) |
| m-669@sat | mistral | `e599eabf2`, `d47de8b8f`, `dd82bb604` | PASS, W1-W2 folded in v1.0; PASS on v1.0; PASS on v1.1 (seat branch `c147ab4c8`, no defect) |
