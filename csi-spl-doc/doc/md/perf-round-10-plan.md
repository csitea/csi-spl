# Perf round 10 (p10) - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5619  
Topic: 14ea495b-bbb5-49f0-a194-87a17eb51a84  

The fourth round under [rounds-rulebook.md](rounds-rulebook.md) section 4 (perf
rounds). Rules by pointer, not copied: sections 1 to 3 (at most 10 rows, pushes
aim 1 up to 3 never more than 5, R1-R16) and 4.1 to 4.5 (every row measured
first, lands with a counting or timing test and its red control, a candidate with
no measured gain is dropped).

- Owner HUM-10 msg 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- Owner HUM-10 msg 98dedfc4: under the 20% perf floor the holder requests the next
  perf round's planner instead of refactor round N+1's (rulebook 4.4).
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**

**Status: v0.1, draft** on `review/c002-perf-round-10-planner`. Editor: c-209@PC
(claude).

**Why now.** The holder's brief (c-002@sat, 17:4xZ, answering c-001 SPAWN SUPPLY
LEAD 42ff8bbe): the 4.4 check on `origin/master` `bf4702451` printed
`perf 11 refactor 117 perf-share 8.6% under-20`, so the planner after refactor
round 33 is a perf round. Slug, re-read here at 18:21:12Z on `c27701c45`:
`git log origin/master --oneline -E --grep='\(p10-'` -> 0 lines;
`git ls-tree -r --name-only origin/master | grep -c perf-round-10` -> 0.

**One sha.** Every number below was measured on **`0d5d699d6`** (`origin/master`
at 18:12Z), on the desk box (PC, 16 cpus), 2026-11-15 18:12Z-18:21Z, under a
1-minute load of 13..31 printed beside each run; every before/after pair ran
interleaved (AB on odd runs, BA on even) under the same load. The row sites are
unchanged on `c27701c45` (`git diff --stat 0d5d699d6 c27701c45 -- <the files>`
prints nothing). The raw commands and outputs:
[perf-round-10/editor.md](perf-round-10/editor.md); the probe scripts and raw
result files: `/var/tmp/c209-probe/` on the desk box.

**Retro.** There is no `perf-round-9-retro.md` on `origin/master`
(`git ls-tree -r --name-only c27701c45 | grep -c perf-round-9-retro` -> 0). Its
three rows landed: p9-01 `fd3b0c647`, p9-02 `f24802938`, p9-03 `8a960d204` and its
fix `0d5d699d6` (the four readers of wf10's Sweep lines accept the `LC_ALL=C`
prefix). This plan reads `perf-round-9-plan.md` (its section 6 first),
`perf-round-8-plan.md`, `perf-round-5-retro.md` and
`lesson-speed-up-measure-first.md`; it does not stand in for the p9 retro.

<a id="p10-how-to-read"></a>
## 1. How to read this

- A row is one logical change, one lane, subject
  `perf(p10-<NN>-<slug>, SPL-<n>): ...`, review branch `review/p10-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number, `n`, on `0d5d699d6`. **After (probe)** =
  the same command on a scratch prototype of the change, never committed; it shows
  the gain is real, the lane re-measures it on its own tree.
- **Test + red control (C2)**: the counting test the row lands with, and the plant
  that must turn it RED before the fix turns it GREEN. Both outputs go in the commit
  body.
- Paths: `iac/` = `csi-spl-iac/`, `wf10` = `.github/workflows/10_ci-quality.yml`.
- Why these two: after p9 the pre-push `hygiene` part is still the costliest
  always-run part (n=19, median 6 s since p9-01 landed; n=184, median 12 s over the
  24 h to 18:12Z), and its Sweep step is 3.2..4.1 s of it (editor 2.2). Row 01 cuts
  that step. The `orc` part holds the largest daily sum (n=60, 40,328 s); every one
  of its runs ends with `bash-cleancode.tst.sh`, 1.2..3.3 s. Row 02 cuts that test.

<a id="p10-inputs"></a>
## 2. Where the rows come from

Inputs read (brief step 2), each carried finding re-checked on `0d5d699d6`:

| input | finding | on `0d5d699d6` | here |
|---|---|---|---|
| `perf-round-9-plan.md` rows 01, 03 (landed) | the hidden-workspace sweep and the five ASCII sweeps made cheaper | the Sweep step still runs its seven `grep -r` passes one after the other: 201..1,490 ms each, 3.2..4.1 s together (editor 2.2) | **row 01**: run them at once |
| `perf-round-9-plan.md` section 6, a-827's input 4 (the five eager orc files) | candidate: -75 ms of the eager loop, whole start not probed | whole start probed: 214 vs 209 ms (medians, n=15, ranges overlapping) | section 6, **dropped** |
| `perf-round-9-plan.md` section 6, a-827's input 1 (`commit-links`' first `do_spl_cloud_cnf`) | candidate, no after arm | the part is 4 s (n=19) to 6 s (n=184); 362 ms of it is local (`COMMIT_LINKS_HUB=none`, n=5); the rest is the key lookup and the hub call | section 6, input for a lane that may read the prd key |
| `perf-round-9-plan.md` section 6, a-827's inputs 2, 3, 5 | held by queued asks (R3) | input 2: ask 68f1dea2 is no longer in the queue (read 18:13Z), and the drift check now takes 426..911 ms (n=3). Inputs 3 and 5 sit in `check-pre-push.func.sh`, still named by queued asks (below) | section 6, carried |
| `perf-round-9-plan.md` section 6, full-tier `orc`, `api`, `commit-links` | counted, not probed | the suite parts hold the largest sums (editor 2.1); not probed | section 6, carried |
| `perf-round-9-plan.md` section 6, `fsync=off`, lab Postgres, p5 inputs 4-5, `_spool_bin_stale`, spec 027 rows 2-4 and 7 | carried since p7 | not re-measured (this seat starts no container and reads no prd data) | section 6, carried |
| `perf-round-8-plan.md` row 03 (dropped) | one joined pre-filter pass for the sweeps | still dropped: c-290's -3.3% / -10.2% (n=10). Row 01 keeps seven passes and runs them at once instead | - |
| `perf-round-5-retro.md` section 5 | five inputs | 2 landed as p7-01; 1, 3 lab-only; 4, 5 not perf (in p9 section 6) | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: both rows start from the pre-push log, then a per-step trace; row 02 is rule 3 (one process instead of one per record) | - |
| new, this seat | `iac-cross` runs `gcloud-account-pinned.tst.sh` on every push, 1.5..2.5 s | counted, not probed | section 6 |

<a id="p10-rows"></a>
## 3. The 2 rows

| # | id | practice | baseline on `0d5d699d6` (command, number, n) | after (probe, same n) | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p10-01-ci-hygiene-sweeps-concurrent)` | the seven sweeps of the Sweep step run at once: `sweep()` forks its body into the background, which writes its output and its verdict to a numbered file; one join before the `.vibe/` check waits for them, prints the outputs in call order and folds the verdicts into `fail`. The seven call lines stay byte for byte | `parab.sh` arm A (editor 2.3): wf10's Sweep step as it runs today (`cd <export> && bash <step>`, the step read out of wf10 with `do_check_dist_hygiene`'s own `yq` line) over a tracked-file export: **3,397 ms (median, n=7; 3,083..4,804)** | arm B: **1,361 ms (median, n=7; 1,149..1,789), -60%**, B below its paired A 7 of 7; the whole output (stdout+stderr) identical 7 of 7 on the clean tree and 3 of 3 with a 6-line plant (rc 1 both, every `::error::` and `ok -` line in the same order) | `wf10:1708-1744` (`sweep()`), the join before `:1804` (the `.vibe/` check); the calls `:1745`, `:1746`, `:1748`, `:1750`, `:1751`, `:1777`, `:1795` unchanged | `iac/src/bash/tests/check-dist-hygiene.tst.sh`, a new case: a `grep` PATH shim whose recursive calls wait, bounded (`wait_event`), until a second recursive call has begun: the seven sweeps -> **2 or more** calls in flight and no call that timed out alone (today **1** in flight: every call times out alone); with a plant in the first and the last sweep, both hits printed, in wf10's order, and the step exits 1. Red: today's step -> 1 in flight, FAIL. The four readers of the call lines (below) and the `hygiene-*.tst.sh` controls run unchanged | either fleet box | claude / simple_coding (R9: a CI gate, so `PRE_PUSH_TIER=full` and once with `PRE_PUSH_*` unset) | 1 |
| 02 | `perf(p10-02-iac-cleancode-walk-one-awk)` | `measure()` runs ONE `awk` over every file (the same three rules on `FNR`, and `FNR == 1` resets the open function and sets the file's repo-relative name) instead of one `awk` per file | `bcc.sh` arm A (editor 2.4): today's `measure` over the walk's **1,200** files: **1,577 ms (median, n=15; 1,331..2,236)**; the whole `bash-cleancode.tst.sh`: **1,437 ms (median, n=7; 1,174..2,235)** | arm B: `measure` **37 ms (median, n=15; 33..53)**, the 7,013 output lines identical 15 of 15; the whole test **173 ms (median, n=7; 161..309), -88%**, rc 0 and the same 13 `PASS` lines | `iac/src/bash/tests/bash-cleancode.tst.sh:42-51` (`measure`), its comment `:36-41` | the same file, a new CONTROL: an `awk` PATH shim that logs each call, then runs the real `awk`: `measure` over 3 fixture files -> **1** call (today **3**); and a fixture whose first file ends inside an open function and whose second file starts with a `}` line -> no line for the open function (the per-file reset). Red: today's `measure` -> 3 calls, FAIL. The existing CONTROLs (4-line, one-liner then 100, inline close, subshell body, the `LONG` ceiling) still pass | either fleet box | claude / simple_coding (R9: a gate test) | 1, after R3 (below) |

Rows 01-02 are claude: rulebook R14 (an established vendor for every row) and the
owner's 10-17 rule (no mistral coding or testing).

<a id="p10-batches"></a>
### 3.1 Batches and disjoint files (R1)

- **Batch 1**: rows 01, 02. No path is in two rows: 01 wf10 and
  `check-dist-hygiene.tst.sh`; 02 `bash-cleancode.tst.sh`.
- Row 02's file is also the file of **r58-08** (`refactor-round-32-plan.md` row 08,
  not landed: it deletes stale lines of the `LONG` list, `:8-13` today, and waits for
  r57-06). The two hunks do not meet (`LONG` at `:8-13`, `measure()` at `:42-51`),
  but R1 serialises a shared file: row 02 is placed only while r58-08 is neither
  live nor queued (R3 re-read before the spawn); if r58-08 is placed first, row 02
  waits until it lands.
- Row 01 adds no `LC_ALL=` to the shared `grep` line (`:1717`) and edits no call
  line: the five `LC_ALL=C sweep` calls and the `LC_ALL="$gate_loc" sweep` call keep
  their prefix, and a temporary assignment before a function call reaches the
  background child forked inside it (editor 2.3).

<a id="p10-r3"></a>
### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-15, each with its time:

- **Lane map, every machine** (18:20:54Z-18:20:55Z, one call):
  `lane-map.sh --check <wf10, check-dist-hygiene.tst.sh, bash-cleancode.tst.sh, this
  plan and its seat file> --agent c-209` -> exit 4, `0` lines `owned by`, `11` lines
  `unknown:` (lanes that record no files, all on sat): c-170, c-203 (feature lanes),
  c-193, c-197, c-236, c-762 (rotation seats), c-239 (r59-05, landed `c27701c45`),
  c-241, c-244 (bug lanes; c-244's slug names the pre-push commit-body hygiene, so
  it is asked before row 01 spawns), c-664, g-266 (a reviewer seat). Exit 4 is not
  free: the R3 check before each spawn re-reads it and asks a lane that is still
  unknown.
- **Spawn queue** (18:13:33Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`, `26 queued, 0 placing`): no queued slug names a row file.
  17 of the briefs are on sat and were not readable from here; the R3 check before
  each spawn reads them where they are.
- **Unlanded round rows** (18:21:12Z, `git log origin/master --format=%s -E
  --grep='\(<r>-[0-9]{2}-'` for r57, r58, r59, r60, p8, p9, p10, on `c27701c45`):
  landed r57-01..04, r58-01..07, r59-01..05, p8-01, p8-02, p8-04, p9-01..03. Not
  landed: r57-05 (`useCardMove`), r57-06 and r59-06 (the Go and WUI cleancode lists),
  r58-08 (`bash-cleancode.tst.sh`, row 02's file: 3.1). p8-03 was dropped. The p9-03
  fix `0d5d699d6` and r59-05 `c27701c45` are on master, so their files are free.
- **Slug** (18:21:12Z): `git log origin/master --oneline -E --grep='\(p10-'` -> 0
  lines.

<a id="p10-per-row"></a>
## 4. Per row: what the lane does

- **01**: `sweep()` keeps its body and runs it in a background subshell, `( fail=0;
  <body>; echo "$fail" >"$d/<n>.rc" ) >"$d/<n>.out" 2>&1 &`, numbered in call order
  under one `mktemp -d`; the `grep failed (rc > 1)` path still sets the sweep's
  verdict to fail. A new join (one function, e.g. `sweep_wait`, a name the four
  readers' `sweep[ \t]+"` match cannot take) runs once before the `.vibe/` check:
  `wait`, then each `<n>.out` in order, and `fail=1` for any verdict that is not
  `0` or is missing; it removes the dir. `skip_re` (set around `:1777`) is read by
  that sweep's subshell when it forks, as today. The comment above `sweep()` says
  the sweeps run at once, why (seven passes over one tree, none reads another's
  result), and that the output order is the call order. `do_check_dist_hygiene`
  reads the step out of wf10, so it follows without an edit. The four readers of
  the call lines, `repodocs/sync-hygiene.sh:30`, `repodocs/drift_test.go:17`,
  `spl-release-note-bans-seed.func.sh:75` and `blog-check.tst.sh:46`, are in the
  test column and run unchanged. The lane re-runs `parab.sh` (n=7) on its tree and
  states the outputs are identical.
- **02**: `measure()` becomes one `awk -v root="$APP_ROOT/" '...' "$@"`; the rules
  are today's with `FNR` for `NR`, plus `FNR == 1 { n = ""; f = <FILENAME without
  root> }`, so a function left open at the end of one file is never closed by the
  next file, as today. The callers (`:89`, the CONTROLs at `:103-123`, `grown()`)
  need no edit; the 4-line CONTROL already accepts both name forms. The comment
  above `measure()` says one `awk` reads every file and why (one process per file
  cost 1.6 s of 1.2..3.3 s). The lane re-runs `bcc.sh` (n=15) on its tree and
  states the output is identical.

<a id="p10-panel"></a>
## 5. Panel and reviewers (R7)

Read on 2026-11-15 18:21:29Z: `ENV=prd ./run -a do_spl_hub_agent_kinds` ->
`off [qwen], paused []`, so grok, agy and mistral may be placed. Mistral is docs
and reviews only (owner 10-17); its CODE reviews stay paused (owner 10-30,
cf7a7ee5; I found no newer word lifting it). The editor's box (PC) has agy
(`command -v agy` -> one path); sat has none (the holder's brief).

- **Plan panel (rulebook 3.2)**: editor c-209@PC (claude). Seats asked of the
  dispatch holder c-002@sat: one **grok** seat and one **agy** seat, the agy seat
  on PC, where agy runs. Each seat signs the plan sha in `perf-round-10/<seat>.md`.
  If no agy seat is placed by the end of the day phase, the holder may place a
  claude seat in its place, as p9 did (the panel's other seat is then grok); that
  is the holder's call, said in section 9.
- **Row reviewers (2.7.2)**: every row's author is claude, so its primary reviewer
  is the grok seat; the backup is the agy seat, or a second grok seat (mistral
  code reviews are paused). A row never pushes without that PASS (2.7.3).

<a id="p10-left-out"></a>
## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| a-827's input 4 (`perf-round-8-retro.md` section 8, carried in p9 section 6): the five eager orc files `spl-wd-takeover`, `spl-peer-crons`, `spl-wd-peers`, `spl-wd-ensure`, `spl-asks-open` | **dropped, no gain**: p9 measured the eager loop (-75 ms); the whole `./run` start does not move | whole start `./run -a do_p10_no_such_action` with and without the five (a probe-only skip in the eager loop), n=15 interleaved, load 15.60..17.95: **214 vs 209 ms** (medians), ranges 187..424 / 176..448 (editor 2.5). c-207's lane (SPL-5620, `review/c207-spl5620-orc-eager-88`, pushed 18:13Z) works the orc eager list outside this round |
| a-827's input 1: `commit-links`' prd key lookup and hub call | **not here**: the part is 4 s (n=19, since p9) to 6 s (n=184, 24 h); with `COMMIT_LINKS_HUB=none` the action takes 362 ms (median, n=5), so ~3.5 s or more is the key lookup (`_spl_cl_hub`) and the hub call (`_spl_cl_hub_read`: cloud cnf, account pin, token, POST). Measuring it reads the prd key; this seat does not | input for round 11: a secret-class measurement lane (claude or grok) that times the two steps |
| `iac-cross`'s `gcloud-account-pinned.tst.sh` (a `.` row: every push) | counted, not probed: no after arm. Its static scans are 475..731 ms of 1,511..2,474 ms (n=5); the rest is ~30 `bash -c` resolver cases | input for round 11 |
| the hygiene part's two drift checks run after the dist sweep, one after the other | not here (R3): running them beside the sweep edits `check-pre-push.func.sh` (`_pp_part_hygiene`), named by queued asks f356b137 (orphan-pipe test, part timeout) and 2a38e34c (`_ppf_select` pipefail), queue read 18:13Z | fleet-rules drift 426..911 ms, Qto drift 244..391 ms (n=3, editor 2.2); carried |
| a-827's input 2: `do_check_fleet_rules_drift` | its queued holder (ask 68f1dea2) is gone from the queue; the check now takes 426..911 ms (n=3), not the 1,564 ms of a-827's sha | no after-probe; carried with the row above |
| a-827's inputs 3 and 5: `_pp_wui_external` and the iac `./run` eager start | not here (R3): both sit in `check-pre-push.func.sh`, as above | carried from p9 |
| the suite parts (`orc` 40,328 s, `wui` 14,487 s, `orc-features` 13,937 s, `api` 13,298 s, `lint-gosec` 10,651 s, `wui-e2e` 9,347 s summed over 24 h, editor 2.1) | counted, not probed: which files take the time needs each suite's slowest-file list on a loaded box | input for round 11, with p9's full-tier `orc` and `api` items |
| test Postgres `fsync=off` (spec 027 row 6) | one store-suite arm is 10 min or more and needs the hub's Postgres container; this seat starts nothing | carried: a measurement-only lane |
| p5 input 1 `ListReleaseNotes`, p5 input 3 `topic_head_apply_marks`, p6-08 / p6-09 | a lab Postgres with prd-sized rows, or a built bundle and Chrome | carried |
| p5 inputs 4 and 5 (dead ask 94ae299e) | not perf work, in the refactor round 34 planner brief (p8 section 6) | not re-measured |
| `_spool_bin_stale` | no gain (p7 section 6) | not re-measured |
| spec 027 rows 2-4 and 7 | GCP / VM changes, or removes a guard (p7 section 6) | not round rows |
| p8-03, the joined pre-filter pass | dropped by its drop rule in round 8 | c-290: -3.3% / -10.2%, n=10, on `91cfe055b` |

No finding of this seat is non-perf work, so no ask went to the orchestrator.

<a id="p10-counts"></a>
## 7. Counts

- Rows: 2 (rulebook 1.1: at most 10). Batch 1: 2.
- Every row: one push aimed (1.2), a counting test and its red control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p10-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p10-' --format=%B | grep -c '^review: '` must reach 2.

<a id="p10-changes"></a>
## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel signs
and it lands on `master`, not from the review branch, as rounds 8 and 9 did; from
then on the Qto doc is the primary copy.

- v0.1 (c-209@PC, 2026-11-15): first draft, 2 rows on `0d5d699d6`.

<a id="p10-consensus"></a>
## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-209@PC (editor) | claude | v0.1 | author |
| grok seat | grok | v0.1 head | pending (asked of the holder) |
| agy seat | agy | v0.1 head | pending (asked of the holder) |
