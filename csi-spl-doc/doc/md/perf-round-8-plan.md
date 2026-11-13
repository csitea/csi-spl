# Perf round 8 (p8) - plan (4 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5456  
Topic: 720c27be-44e6-4a3f-98f7-61f0bad0bf0c  

The second round under [rounds-rulebook.md](rounds-rulebook.md) section 4 (perf
rounds). Rules by pointer, not copied: sections 1 to 3 (at most 10 rows, pushes
aim 1 up to 3 never more than 5, R1-R16) and 4.1 to 4.5 (every row measured
first, lands with a counting or timing test and its red control, a candidate with
no measured gain is dropped).

- Owner HUM-10 msg 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- Owner HUM-10 msg 98dedfc4: under the 20% perf floor the holder requests the next
  perf round's planner instead of refactor round N+1's (rulebook 4.4).
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**

**Status: v0.1, draft** on `review/c001-perf-round-8-planner`. Editor: c-101 on
the second fleet box (claude).

**Why now.** The holder's brief (c-001@sat on c-002@sat's request 10fad511,
17:3xZ): the 4.4 check on `origin/master` a4c933a5e printed
`perf 2 refactor 139 perf-share 1.4% under-20`. Re-read here at 18:21Z on
`f67ead04e`: `perf 3 refactor 139 perf-share 2.1% under-20` (p7-01 landed between);
`git log origin/master --oneline -E --grep='\(p8-'` -> 0 lines; no
`perf-round-8*` path on the tree. Re-read at 19:10Z on `c3083e6ca`: the same grep
-> 0 lines, `ls csi-spl-doc/doc/md | grep -c perf-round-8` -> 0.

**One sha.** Every number below was measured on **`f67ead04e`**
(`f67ead04e1477b2e207447880f833e51d3627c9f`, `origin/master` at 18:21Z), on the
second fleet box (the one this seat runs on), 2026-11-13 18:2xZ-18:3xZ, under a
1-minute load of 17..55 read beside each measurement; every before/after pair ran
interleaved under the same load. The site files of rows 01-04 are unchanged on
`c3083e6ca` (`git diff --stat f67ead04e c3083e6ca -- <the files>` prints nothing).
The raw commands and outputs: [perf-round-8/editor.md](perf-round-8/editor.md).

## 1. How to read this

- A row is one logical change, one lane, subject
  `perf(p8-<NN>-<slug>, SPL-<n>): ...`, review branch `review/p8-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number, `n`, on `f67ead04e`. **After (probe)** =
  the same command on a scratch prototype of the change, never committed; it shows
  the gain is real, the lane re-measures it on its own tree.
- **Test + red control (C2)**: the counting or timing test the row lands with, and
  the plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `orc/` = `csi-spl-orc/`, `run/` = `csi-spl-orc/src/bash/run/`,
  `wf10` = `.github/workflows/10_ci-quality.yml`.

## 2. Where the rows come from

Inputs read (brief step 2), each carried finding re-checked on `f67ead04e`:

| input | finding | on `f67ead04e` | here |
|---|---|---|---|
| `perf-round-7-plan.md` section 6, `spl_box_ws_cnf` | a `yq eval-all` merge of 130 KB per desk action; how often it runs was not counted | counted: 3,138 desk-cnf actions on 2026-11-12; `0.081 s` merge vs `0.017 s` two reads (n=5) | **row 02** |
| `perf-round-7-plan.md` section 6, test Postgres `fsync=off` | no pair finished in p7 | arm A only (600.8 s, n=1); arm B never ran: this seat's first session ended | section 6, carried |
| `perf-round-7-plan.md` section 6, `_spool_bin_stale` | dropped, no gain | not re-measured | stays dropped |
| `perf-round-7-plan.md` section 6, p5 inputs 1 and 3, p6-08/09 | lab Postgres or a built bundle needed | not re-measured (this seat installs nothing) | section 6, carried |
| `perf-round-7-plan.md` row 04 (landed `f0d0efa4e`) | five eager orc files made lazy | 93 eager files remain; the next five cost 57 ms of a 211 ms eager phase (n=7) | **row 01** |
| `perf-round-7-plan.md` row 02 (not landed, Batch 2 after r58-07) | lane-map local rows | the same `--check` also spends 2.5 s in `spl_lane_wt_changes` and 0.75 s in `spl_lane_repo_tops`, which p7-02 does not touch | **row 04**, after p7-02 |
| `perf-round-5-retro.md` inputs 4, 5 (dead ask 94ae299e) | duplicated SQL predicate; payments coverage headroom | item 4: still 3 copies (`:84`, `:119`, `:152`); item 5: `84.3%` = floor `84.3` | section 6, refactor input (to c-001) |
| `perf-round-6-plan.md` | rows 08, 09 not landed | `git log origin/master --grep='p6-0[89]'` -> 0 | carried as in p7 |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: every row names a frequency and a counting test | - |
| new, this seat | the pre-push `hygiene` part runs on every push: median 13 s, n=147 in 24 h | six whole-tree `grep -P` passes; one pre-filter pass first: -22% (n=5) | **row 03** |

## 3. The 4 rows

| # | id | practice | baseline on `f67ead04e` (command, number, n) | after (probe, same n) | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p8-01-orc-eager-next5-lazy)` | as p7-04: a file whose only top-level code is its dependency `source` lines and constants loads them on first call, so the lazy loader can stub it | the eager loop of orc `./run` (`phase5.sh`, editor 2.1): **211 ms (median, n=7; 158..342)** over 93 files; of it `spl-watchdog` 36, `spl-gc` 21, `spl-agent-login2-sync` 12, `spl-box-leave` 12, `spl-rotate-lib` 9 ms (medians, n=5). The whole orc start `./run -a do_p8_no_such_action`: **0.421 s** wall (median, n=5). 16,266 orc runs on this box on 2026-11-12 | the loop without the five: **154 ms (median, n=7; 117..208), -57 ms, -27%** | `run/spl-watchdog.func.sh:80-94` (7 `source` lines, `SPL_WD_RUN_DIR`), `:1105` (`WD_ORDER`); `run/spl-gc.func.sh:75-85`; `run/spl-agent-login2-sync.func.sh:36-39`; `run/spl-box-leave.func.sh:39-44` and `:208` (a `( )` function body); `run/spl-rotate-lib.func.sh:50-60`, `:609`, `:613` | `orc/src/bash/tests/run-eager-files.tst.sh` (p7-04's): a second list of five, none of them eager, and `MAX_EAGER` 93 -> 88. Red: one top-level `source` put back reads that file eager, FAIL (the test's own CONTROL, `:61-69`, extended to the new five) | either fleet box | claude / simple_coding | 1 |
| 02 | `perf(p8-02-orc-box-ws-cnf-one-read)` | read one cnf key without a deep merge of both files: the env file's value if the key is set there, else `all.env.yaml`'s | `yq eval-all -r '. as $i ireduce ({}; . * $i) \| .env.box.workspace_base // ""' all.env.yaml prd.env.yaml`: **0.081 s (median, n=5; 0.071..0.089)**; at least once per desk-cnf action, **3,138** of them on this box on 2026-11-12 | two plain `yq -r` reads: **0.017 s (median, n=5; 0.013..0.023), -79%** | `orc/lib/bash/funcs/spl-box-workspace.func.sh:27-36` (`spl_box_ws_cnf`) | `orc/src/bash/tests/box-workspace-isolation.tst.sh`, new cases: a `yq` PATH shim counts `eval-all` calls: 0 for one `spl_box_ws_cnf` (today 1); the value equals the merge's for an env file that sets the key, does not set it, and sets it to `""`. Red: today's function -> 1 `eval-all`, FAIL | either fleet box | claude / simple_coding | 1 |
| 03 | `perf(p8-03-ci-hygiene-sweep-prefilter)` | one whole-tree pass finds the files any sweep pattern hits; each sweep then greps only those files | the six fixed-pattern sweeps of wf10's Sweep step on a tracked-file export (9,559 files), `hyprobe.sh` arm A: **4,443 ms (median, n=5; 3,654..4,986)**; the pre-push `hygiene` part, 24 h log: median **13 s, n=147** | arm B (`grep -rlIP` with the six joined, then `grep -nIoHP` per sweep): **3,464 ms (median, n=5; 3,283..3,978), -22%**, hits identical 5 of 5 | `wf10:1708-1735` (`sweep()`, the `grep -rnIoP` at `:1717`), the sweep calls `:1737-1743`, `:1769`, `:1787` | `csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh`, a new case: a `grep` PATH shim counts recursive (`-r`) calls over the fixture tree: at most 1 for the fixed-pattern sweeps (today 6), the planted hits of the `hygiene-*.tst.sh` fixtures still reported. Red: today's step -> 6, FAIL. **Drop rule**: the lane re-measures arm A and B (n=10, interleaved); under 15% median gain it drops the row with that measurement | either fleet box | claude / simple_coding (R9: a CI gate, so `PRE_PUSH_TIER=full` and once with `PRE_PUSH_*` unset) | 1 |
| 04 | `perf(p8-04-orc-lane-map-wt-scan)` | the repo tops read once per scan, not twice per worktree; the worktrees' three `git` reads run 8 at a time | `spl_lane_wt_dir` + `spl_lane_wt_changes` shape over the 26 lane worktrees on this box (`wtscan.sh` arm A, editor 2.4): **1,506 ms (median, n=5; 1,417..1,595)**; the whole `lane-map.sh --check <one path>`: 8.1..15.1 s wall (n=3), of which 2.53 s `spl_lane_wt_changes` and 0.75 s `spl_lane_repo_tops` (52 calls) in one trace | arm B: **253 ms (median, n=5; 240..296), -83%**, output identical 5 of 5 | `run/spl-lane-map.func.sh:308-317` (`spl_lane_repo_tops`), `:677-686` (`spl_lane_wt_dir`), `:690-701` (`spl_lane_wt_changes`), `:704-711` (`spl_lane_wt_scan`) | `orc/src/bash/tests/lane-map.tst.sh`, new case: 12 fixture worktrees, a `git` PATH shim counts `rev-parse --git-common-dir` calls: at most 2 per scan (today 2 per worktree); the scan's JSON equals the old one's on the same fixture. Red: today's functions -> 24, FAIL | either fleet box | claude / simple_coding | **2: after p7-02 lands** (it owns `spl-lane-map.func.sh:322-344`, and p7-02 itself waits on r58-07) |

Rows 01-04 are claude: rulebook R14 (an established vendor for every row) and the
owner's 10-17 rule (no mistral coding or testing).

### 3.1 Batches and disjoint files (R1)

- **Batch 1**: rows 01, 02, 03. No path is in two rows: 01 five `run/*.func.sh`
  and `run-eager-files.tst.sh`; 02 `spl-box-workspace.func.sh` and
  `box-workspace-isolation.tst.sh`; 03 wf10 and `check-dist-hygiene.tst.sh`.
  Row 01's `spl-gc.func.sh:82` sources `spl-lane-map.func.sh` but does not edit it.
- **Batch 2**: row 04, spawned within 30 minutes (R16) of the commit that lands
  p7-02 (`perf(p7-02-orc-lane-map-local-rows-one-jq)`), which edits
  `spl-lane-map.func.sh` (`:322-344`). The two rows touch different functions of
  one file, so they never run at once.

### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-13, each with its time:

- **Lane map, every machine** (19:10:00Z-19:10:34Z, one call):
  `lane-map.sh --check <every site file of rows 01-04, and this plan> --agent c-101`
  -> exit 4, `0` lines `owned by`, `5` lines `unknown:` (lanes that recorded no
  files, all on sat): c-567 (`spl5259-issue-follows-discussion`),
  c-661 (`feat-people-every-workspace-member-email`), c-664 (`rotate`), c-687
  (`feat-calendar-owner-fi-nl-first-end-jan`), c-688
  (`feat-codex-in-every-ai-client-setting`). Exit 4 is not free: the R3 check before
  each spawn re-reads it and asks a lane that is still unknown. The one to ask
  first: c-664 (`rotate`), for row 01's `spl-rotate-lib.func.sh`.
- **Spawn queue** (19:11:16Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`, `38 queued, 0 placing`): no queued summary names a row's
  file. The nearest, to read at each spawn: `561ac0c8`
  (`c002-bug-wd-selfcheck-counts-grace-skip`) and `3e373385`
  (`c002-bug-wd-self-update-walltime-asserts`), watchdog tests that may touch
  `spl-watchdog.func.sh` (row 01); `dc8568f5`
  (`check-pre-push-orphan-pipe.tst.sh`), not a row 03 file.
- **Unlanded round rows** (19:10:40Z, `git log origin/master --format=%s -E
  --grep='\((r5[6-9]|r6[0-9])-[0-9]{2}-'` and `--grep='\(p7-0'`): landed r56-01..08,
  r57-01..04, r58-01..05, r59-02..04, p7-01, p7-04, p7-05. Not landed: r57-05,
  r57-06, r58-06..08, r59-01, r59-05, r59-06 (files as listed in
  `perf-round-7-plan.md` 3.2: `useCardMove`, the cleancode lists, orc action
  headers including `spl-lane-map.func.sh`, `spl-spawn-queue.func.sh`,
  `spl-spawn-share.func.sh`, `bash-cleancode.tst.sh`, `hub/server.go`,
  `spl-spawn-place.func.sh`), p7-02 (`spl-lane-map.func.sh`), p7-03 (the three
  `run.sh` copies, `run-lazy-loader.tst.sh`). Only row 04 meets one (p7-02, and
  through it r58-07): Batch 2. Row 01 does not edit `run.sh`; p7-03's cache and
  row 01's fewer eager files speed up different phases, and each lane measures its
  arm with the other's code as it is on master.
- **Slug** (19:10:40Z): `git log origin/master --oneline -E --grep='\(p8-'` -> 0
  lines.

## 4. Per row: what the lane does

- **01**: as p7-04 (`f0d0efa4e`): move each file's top-level dependency `source`
  lines into one `_<file>_deps` called first by each `do_` entry (or into the
  functions that need them), and its constants into that function or a
  `${VAR:-...}` at use. `spl-box-leave`'s `spl_box_handover() ( ... )` stays a
  subshell function: the lane checks whether the run.sh index reads it as top-level
  code and, if so, makes it a `{ ( ... ) }` body. No behaviour change: each file's
  own tests run, and `do_spl_watchdog`, `do_spl_gc` start as before.
- **02**: `spl_box_ws_cnf` reads the key from `$ENV.env.yaml` with `has()` and,
  when the key is not set there, from `all.env.yaml`; one `yq` per file at most, no
  `eval-all`. The keys read are scalars (`workspace_base`, `workspace_user_prefix`);
  a map key is not read here (a comment says so).
- **03**: in wf10's `sweep()`, the fixed-pattern sweeps share one
  `grep -rlIP "${excl[@]}"` over the tree with every pattern joined as
  `(?:p1)|(?:p2)|...`, run once before the first `sweep` call; each `sweep` then
  runs `grep -nIoHP` over that file list (none: no hits). The hidden-workspace sweep
  keeps its own `LC_ALL` and its own pass. `do_check_dist_hygiene` reads the step
  out of wf10, so it follows without an edit.
- **04**: `spl_lane_wt_scan` reads `spl_lane_repo_tops` once and passes the tops to
  `spl_lane_wt_dir`; the worktrees' `spl_lane_wt_changes` run at most 8 at a time
  (`xargs -P 8` or background jobs with `wait -n`), each into its own temp file,
  joined in the old order. `same=yes` on the lane's tree before the push.

## 5. Panel and reviewers (R7)

Read on 2026-11-13 19:12Z: `ENV=prd ./run -a do_spl_hub_agent_kinds` ->
`off [qwen], paused []`, so grok and agy may be placed. agy is installed on the
second fleet box (`command -v agy` prints a path), not on sat (brief). Mistral is
docs and reviews only (owner 10-17); its code reviews were paused (owner 10-30,
cf7a7ee5): I did not find a newer word lifting that pause.

- **Plan panel (rulebook 3.2)**: editor c-101 (claude); seats asked of the
  holder: **one grok seat** and **one agy seat on the second fleet box** (a plan
  review is `specs_and_docs`, agy's kind). Both are another vendor than the editor.
  If agy is out of quota, a **mistral** seat takes its place (a doc review, which
  mistral may do): the panel is then cross-vendor without agy, which the rulebook
  allows (it names no vendor). The panel signs the plan sha in
  `perf-round-8/<seat>.md`.
- **Row reviewers (2.7.2)**: every row's author is claude, so its reviewer is the
  grok seat, backup the agy seat. A row never pushes without that PASS (2.7.3).

## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| test Postgres `fsync=off` (spec 027 row 6): `csi-spl-api/src/bash/hub-live-stack.sh:53-54` (the `pg_ctl -o` line), `csi-spl-api/src/bash/tests/hub-pg.tst.sh` | no pair: arm A of the store suite ran once (600.8 s, rc 1 on the load-sensitive `TestHiddenUnreadBufferBudget`), arm B never ran (editor 2.5) | carried to round 9: a pair takes 20 min or more per arm; it needs a lane of its own, not an editor session |
| p5 input 4, the signed-human predicate repeated in `csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go` (dead ask 94ae299e item 4) | not perf work: a drift risk, no measured cost (three string copies in one query file) | `grep -n "m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%'" <file>` -> **3** (`:84`, `:119`, `:152`), file **227** lines. Input for refactor round 34: c-001@sat (msg 08440444) says the r34 planner brief `c002-refactor-round-34-planner.md` line 21 already carries it, re-measured on its plan sha; the copy on this box does not (`grep -c fallback_postgres /var/spool-hub/dispatch/briefs/c002-refactor-round-34-planner.md` -> 0, 19:5xZ), the sat copy is unread here |
| p5 input 5, `internal/payments` coverage headroom (dead ask 94ae299e item 5) | not perf work: a test-coverage floor | `go test -count=1 -cover ./internal/payments/` -> **84.3%**; `go-coverage-floor.txt:134` -> **84.3**: 0.0 points headroom (n=1). Input for refactor round 34, carried by the r34 planner brief per c-001@sat msg 08440444 (same check as the row above) |
| `_spool_bin_stale` | no gain (p7 section 6) | not re-measured |
| p5 input 1 `ListReleaseNotes`, p5 input 3 `topic_head_apply_marks`, p6-08 / p6-09 | a lab Postgres with prd-sized rows, or a built bundle and Chrome; this seat installs nothing | carried to round 9 |
| pre-push `commit-links` part (median 9 s, n=147) and `lint-trufflehog` (median 10 s, n=134) | counted, not probed: no before/after | input for round 9 |
| spec 027 rows 2-4 and 7 | GCP / VM changes, or removes a guard (p7 section 6) | not round rows |

## 7. Counts

- Rows: 4 (rulebook 1.1: at most 10). Batch 1: 3, Batch 2: 1.
- Every row: one push aimed (1.2), a counting or timing test and its red control
  (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p8-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p8-' --format=%B | grep -c '^review: '` must reach 4.

## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`) after the panel signs and it lands on
`master`, not from the review branch; from then on the Qto doc is the primary copy.

- v0.1 (c-101, 2026-11-13): first draft, 4 rows on `f67ead04e`.

## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-101 (editor) | claude | v0.1 | author |
