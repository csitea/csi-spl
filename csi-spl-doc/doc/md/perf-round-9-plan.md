# Perf round 9 (p9) - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5502  
Topic: 8a6d50d4-5bec-4ab8-ba69-0667e03e75bf  

The third round under [rounds-rulebook.md](rounds-rulebook.md) section 4 (perf
rounds). Rules by pointer, not copied: sections 1 to 3 (at most 10 rows, pushes
aim 1 up to 3 never more than 5, R1-R16) and 4.1 to 4.5 (every row measured
first, lands with a counting or timing test and its red control, a candidate with
no measured gain is dropped).

- Owner HUM-10 msg 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- Owner HUM-10 msg 98dedfc4: under the 20% perf floor the holder requests the next
  perf round's planner instead of refactor round N+1's (rulebook 4.4).
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**

**Status: v0.1, draft** on `review/c002-perf-round-9-planner`. Editor: c-723@sat
(claude).

**Why now.** The holder's brief (c-002@sat, 09:1xZ, answering c-001 spawn-share
6ef7de4b): the 4.4 check on `origin/master` 1638ca3a7 printed
`perf 7 refactor 131 perf-share 5.1% under-20`. Slug, re-read here at 09:26:01Z on
`e9ea1ef32`: `git log origin/master --oneline -E --grep='\(p9-'` -> 0 lines;
`git ls-tree -r --name-only origin/master | grep -c perf-round-9` -> 0.

**One sha.** Every number below was measured on **`1638ca3a7`**
(`1638ca3a7651ace34e8f16dd84e0c49988e6df4f`, `origin/master` at 09:0xZ), on sat
(16 cpus), 2026-11-14 09:1xZ-09:2xZ, under a 1-minute load of 25..63 printed beside
each run; every before/after pair ran interleaved (AB on odd runs, BA on even) under
the same load. The site files of rows 01-03 are unchanged on `e9ea1ef32`
(`git diff --stat 1638ca3a7 e9ea1ef32 -- <the files>` prints nothing). The raw
commands and outputs: [perf-round-9/editor.md](perf-round-9/editor.md); the probe
scripts and raw result files: `/var/tmp/c723-probe/` on sat.

**Retros.** There is no `perf-round-7-retro.md` and no `perf-round-8-retro.md` on
the tree (`git ls-tree -r --name-only origin/master | grep -c 'perf-round-[78]-retro'`
-> 0). Round 8 is not served: p8-01 `8c39ee3ef` and p8-02 `1e1cf16f8` landed, p8-03
was dropped by its own drop rule, p8-04 is live (c-721@sat). This plan reads the two
plans and the landed commits, not a retro.

<a id="p9-how-to-read"></a>
## 1. How to read this

- A row is one logical change, one lane, subject
  `perf(p9-<NN>-<slug>, SPL-<n>): ...`, review branch `review/p9-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number, `n`, on `1638ca3a7`. **After (probe)** =
  the same command on a scratch prototype of the change, never committed; it shows
  the gain is real, the lane re-measures it on its own tree.
- **Test + red control (C2)**: the counting test the row lands with, and the plant
  that must turn it RED before the fix turns it GREEN. Both outputs go in the commit
  body.
- Paths: `iac/` = `csi-spl-iac/`, `wf10` = `.github/workflows/10_ci-quality.yml`.
- Why these three: on sat the pre-push `hygiene` part ran **144** times in the 24 h
  to 09:10Z (median **17 s**, sum 2,663 s) and `lint-trufflehog` **156** times
  (median **9 s**, sum 1,404 s), the two always-run parts with the largest sums
  (desk user's `~/.cache/csi-spl/pre-push.log`, PART lines, editor 2.1). Rows 01 and
  03 cut the hygiene sweep, row 02 the trufflehog part.

<a id="p9-inputs"></a>
## 2. Where the rows come from

Inputs read (brief step 2), each carried finding re-checked on `1638ca3a7`:

| input | finding | on `1638ca3a7` | here |
|---|---|---|---|
| `perf-round-8-plan.md` row 03 (dropped) | one joined pre-filter pass for the six fixed sweeps | c-290 (second fleet box, SPL-5483, on `91cfe055b`): **-3.3%** with wf10's excludes, **-10.2%** with the probe's, n=10, under the row's 15% drop rule; accepted as dropped by c-002@sat | stays dropped. The sweep's cost is elsewhere: the hidden-workspace sweep (**row 01**) and the locale every sweep runs under (**row 03**) |
| `perf-round-8-plan.md` section 6, pre-push `commit-links` and `lint-trufflehog` (counted, not probed) | input for round 9 | `lint-trufflehog`: control + scan are two scanner starts of ~7 s each (n=5); one start can go | **row 02**; `commit-links` (median 6 s, n=144) not probed, section 6 |
| `perf-round-8-plan.md` row 01 (landed `8c39ee3ef`) | five more eager orc files made lazy | the next five cost 33 ms of a 380 ms eager phase and 17 ms of a 753 ms start (n=15), ranges overlapping | section 6, dropped |
| `perf-round-8-plan.md` row 04 (live, c-721@sat) | lane-map worktree scan | `spl-lane-map.func.sh` is p8-04's | not here (R1) |
| `perf-round-8-plan.md` section 6, test Postgres `fsync=off` | no pair in p7 or p8 | not measured (a store-suite arm is 10 min or more; this seat installs and starts nothing) | section 6, carried |
| `perf-round-8-plan.md` section 6, p5 inputs 1 and 3, p6-08/09 | lab Postgres or a built bundle needed | not measured (same reason) | section 6, carried |
| `perf-round-8-plan.md` section 6, p5 inputs 4 and 5 | not perf work, handed to refactor round 34 | item 4: still 3 copies (`fallback_postgres.go:84,119,152`); item 5: floor `go-coverage-floor.txt:134` still `84.3` (coverage not re-run); no `refactor-round-34-plan.md` on `e9ea1ef32` | section 6, unchanged |
| `perf-round-7-plan.md` section 6 | `fsync=off`, `_spool_bin_stale`, spec 027 rows 2-4 and 7 | as in p8 | section 6, carried |
| `perf-round-5-retro.md` section 5 | five inputs | 2 landed as p7-01; 1, 3 lab-only; 4, 5 not perf (above) | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: every row starts from the pre-push log's frequency, then a per-step trace | - |
| new, this seat | pre-push full tier `orc` part: 10 runs in 24 h, none green, 4 TIMED OUT at ~12,020 s | counted, not probed | section 6, input for round 10 |

<a id="p9-rows"></a>
## 3. The 3 rows

| # | id | practice | baseline on `1638ca3a7` (command, number, n) | after (probe, same n) | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p9-01-iac-hidden-sweep-one-lookaround)` | the hidden-workspace word slugs share ONE lookbehind and ONE lookahead, `(?i)(?<![\p{L}\p{N}])(?:s1\|s2\|...)(?![\p{L}\p{N}])`, instead of one `(?i)(?<!...)slug(?!...)` alternative per slug | `hwprobe.sh` arm A (editor 2.2): wf10's hidden-workspace sweep as it runs today (`grep -rnIoP`, wf10's excludes, the gate's UTF-8 locale, the box overlay's 26 patterns, 14 of them word slugs) over a tracked-file export of 9,589 files plus a 144-line plant: **3,951 ms (median, n=10; 3,207..5,442)**. It is the costliest sweep: 4.58 s of the 9.40 s the sweep step spends in `grep` (one trace, n=1); the whole `do_check_dist_hygiene` 9.9..11.4 s (n=3) | arm B, the 14 word slugs factored: **2,086 ms (median, n=10; 1,680..2,795), -47%**; the hit set identical 10 of 10 (79 hits on the plant, accented-letter cases included) | `iac/lib/bash/funcs/spl-private-cnf.func.sh:157-173` (`spl_private_gate_patterns`, the word form at `:169`); its comment `:145-156` | `iac/src/bash/tests/spl-private-cnf.tst.sh` section 6 (`:83-105`), a new case: the builder's output for the fixture's word slugs carries **1** `(?<![\p{L}\p{N}])` (today one per word slug); every hit and no-hit case of section 6 still holds, the Unicode ones included. Red: today's builder -> one per slug, FAIL. `hygiene-hidden-workspaces.tst.sh` runs unchanged | either fleet box | claude / simple_coding (R9: a gate's pattern, so `PRE_PUSH_TIER=full` and once with `PRE_PUSH_*` unset) | 1 |
| 02 | `perf(p9-02-iac-trufflehog-control-once-per-binary)` | the control's verdict is kept per trufflehog binary (its sha256, and `_SEC_TRUFFLEHOG_VER`): a binary that already detected the planted pair is not started again for the control; a failed control is never kept | the part's two scanner starts on 2 files (control on the planted pair, then the `--only-verified` scan; `th-ab` arm A, editor 2.3): **10,415 ms (median, n=7; 9,014..10,755)**; each start alone ~7 s (control 7,034 ms, scan 7,135 ms, medians, n=5) | arm B, `sha256sum` of the binary + the same scan: **5,318 ms (median, n=7; 4,541..6,647), -49%**; the ranges do not overlap | `iac/src/bash/run/sec-trufflehog.func.sh:64-78` (`do_sec_trufflehog`, the control block `:70-78`) | `iac/src/bash/tests/sec-trufflehog.tst.sh`, a new case: the stub logs each call's `SEC_TRUFFLEHOG_PHASE`; two runs with one stub and one `XDG_CACHE_HOME` -> **1** control call (today 2); a changed stub (new sha256) -> the control runs again; the existing CONTROL (a silent stub fails) still fails on its second run. Red: today's code -> 2 control calls, FAIL | either fleet box | claude / simple_coding (R9: a lint part) | 1 |
| 03 | `perf(p9-03-ci-hygiene-ascii-sweeps-c-locale)` | the six ASCII sweeps (`:1737-1743`, `:1787`) run `grep -P` under `LC_ALL=C`; the hidden-workspace sweep keeps its UTF-8 gate locale (`:1769`) | `locprobe.sh` arm A (editor 2.4): the six sweeps' `grep -rnIoP` with wf10's excludes under `C.UTF-8` (the box default; the pre-push runs under it) on the planted export: **5,375 ms (median, n=10; 4,970..6,298)** | arm B, the same six under `LC_ALL=C`: **3,989 ms (median, n=10; 3,518..4,483), -26%**; the six hit sets identical 10 of 10, including 12 planted lines that put the sweeps' ASCII words next to multibyte letters; the ranges do not overlap | `wf10:1708-1736` (`sweep()`, its `grep` at `:1717`), `:1769` (the hidden-workspace call) | `iac/src/bash/tests/check-dist-hygiene.tst.sh`, a new case: a `grep` PATH shim logs the locale of each recursive call: the six ASCII sweeps **0** calls under a UTF-8 locale (today 6), the hidden-workspace sweep still **1** under the gate locale; the planted hits of the `hygiene-*.tst.sh` fixtures still reported. Red: today's step -> 6, FAIL | either fleet box | claude / simple_coding (R9: a CI gate) | 1 |

Rows 01-03 are claude: rulebook R14 (an established vendor for every row) and the
owner's 10-17 rule (no mistral coding or testing).

<a id="p9-batches"></a>
### 3.1 Batches and disjoint files (R1)

- **Batch 1**: rows 01, 02, 03. No path is in two rows: 01
  `spl-private-cnf.func.sh` and `spl-private-cnf.tst.sh`; 02 `sec-trufflehog.func.sh`
  and `sec-trufflehog.tst.sh`; 03 wf10 and `check-dist-hygiene.tst.sh`.
- Rows 01 and 03 speed up two different sweeps of one step: 01 the hidden-workspace
  pattern, 03 the six ASCII ones. Each lane measures its arm with the other's code
  as it is on master. Row 03 must not put `LC_ALL=C` on the shared `grep` line
  unconditionally: the hidden-workspace call passes its own locale (`:1769`), which
  has to win (section 4).

<a id="p9-r3"></a>
### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-14, each with its time:

- **Lane map, every machine** (09:25:31Z-09:25:38Z, one call):
  `lane-map.sh --check <every site and test file of rows 01-03, this plan and its
  seat file> --agent c-723` -> exit 4, `0` lines `owned by`, `15` lines `unknown:`
  (lanes that record no files, all on the second fleet box): a-429 (a docs lane),
  c-382 and c-437 (two feature lanes), c-004, c-172, c-507, c-528, c-545, c-669,
  c-981, g-274, g-434 (rotation seats), c-190, c-390, g-155 (peer-restart seats).
  Exit 4 is not free: the R3 check before each spawn re-reads it and asks a lane
  that is still unknown.
- **Spawn queue** (09:25:46Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`, `31 queued, 0 placing`): no queued slug names a row's file.
  The nearest, read: 10/31 `c001-bug-orphan-pipe-test-part-timeout-env`, whose brief
  names `check-pre-push.func.sh` and `check-pre-push-orphan-pipe.tst.sh`, not a row
  file.
- **Unlanded round rows** (09:26:01Z, `git log origin/master --format=%s -E
  --grep='\(<r>-[0-9]{2}-'` for r57, r58, r59, p7, p8, on `e9ea1ef32`): landed
  r57-01..04, r58-01..07, r59-01..04, p7-01..05, p8-01, p8-02. Not landed: r57-05
  (`useCardMove`), r57-06 and r59-06 (the cleancode lists), r58-08
  (`bash-cleancode.tst.sh`), r59-05 (`spl-spawn-place.func.sh`), p8-04
  (`spl-lane-map.func.sh`, live). None is a row 01-03 file. p8-03 was dropped.
- **Slug** (09:26:01Z): `git log origin/master --oneline -E --grep='\(p9-'` -> 0
  lines.

<a id="p9-per-row"></a>
## 4. Per row: what the lane does

- **01**: `spl_private_gate_patterns` collects the word slugs and prints ONE line
  `(?i)(?<![\p{L}\p{N}])(?:s1|s2|...)(?![\p{L}\p{N}])` (slugs in map order), in
  place of one line per slug; the forms_only lines and the deny entries stay as they
  are. The caller in wf10 (`:1769`, `paste -sd'|'`) needs no edit. The comment
  above the function says the word slugs share one lookaround and why. The lane
  re-runs `hwprobe.sh` (n=10) on its tree and states the hit set is identical on
  the box overlay; it prints no slug.
- **02**: after a control that found at least one detection, `do_sec_trufflehog`
  writes a mark named for the binary's sha256 and `_SEC_TRUFFLEHOG_VER` under
  `${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/trufflehog-control/`; when the mark for
  this binary exists, the control is skipped and the log says so (`control: kept for
  <sha8>`). No mark on a failed control, and an unwritable cache dir only costs the
  control run. The scan is unchanged.
- **03**: `sweep()` runs its `grep` under `LC_ALL="${sweep_loc:-C}"`; the
  hidden-workspace call sets `sweep_loc="$gate_loc"` (in place of today's
  `LC_ALL="$gate_loc" sweep`). A comment at `sweep()` says the six patterns are
  ASCII and why C is their locale (bytes, no UTF-8 decoding); a non-ASCII pattern
  added later passes its locale. `do_check_dist_hygiene` reads the step out of wf10,
  so it follows without an edit. The lane re-runs `locprobe.sh` (n=10) and
  states the six hit sets are identical.

<a id="p9-panel"></a>
## 5. Panel and reviewers (R7)

Read on 2026-11-14 09:26:29Z: `ENV=prd ./run -a do_spl_hub_agent_kinds` ->
`off [qwen], paused []`, so grok and mistral may be placed. sat has no agy
(`command -v agy` prints nothing). Mistral is docs and reviews only (owner 10-17);
its CODE reviews stay paused (owner 10-30, cf7a7ee5; I found no newer word lifting
it).

- **Plan panel (rulebook 3.2)**: editor c-723@sat (claude); seats asked of the
  holder: **one grok seat** and **one mistral seat** (a plan review is a doc review,
  which mistral may do). Both are another vendor than the editor. The rulebook names
  no vendor for the panel, so without agy on sat it is cross-vendor with grok and
  mistral, as perf round 8's panel was (g-168 grok, m-176 mistral). An agy seat on
  the second fleet box may be added; the round does not wait for it. The panel signs
  the plan sha in `perf-round-9/<seat>.md`.
- **Row reviewers (2.7.2)**: every row's author is claude, so its primary reviewer
  is the grok seat; the backup is a second grok seat, or an agy seat on the second
  fleet box (mistral code reviews are paused). A row never pushes without that PASS
  (2.7.3).

<a id="p9-left-out"></a>
## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| p8-01 again: the next five eager orc files (`spl-agent-settings-check`, `spl-dispatch-lease`, `spl-wd-ensure`, `spl-box-restart-prepare`, `spl-asks-open`; per-file medians 73, 54, 41, 41, 40 ms, n=7) | **dropped, no gain**: the per-file costs are shared work (the first file to source a common include pays for it), so skipping the five moves most of it to other files | eager loop with and without the five, n=15 interleaved, load 55..61: **380 ms vs 347 ms (-9%)**, ranges 288..787 / 298..714; whole start `./run -a do_p9_no_such_action` **753 vs 736 ms (-2%)** (editor 2.5) |
| p8-03, the joined pre-filter pass | dropped by its drop rule in round 8 | c-290: -3.3% / -10.2%, n=10, on `91cfe055b` |
| pre-push full tier `orc` part | 10 full-tier runs on sat from 2026-11-13T09:00Z to 2026-11-14T09:11Z, none green: 4 TIMED OUT at 12,023..12,032 s, 6 ran 9,950..13,709 s to FAIL or WARN-pre-existing; the green fast tier ran 516 s (mean, n=18). Counted, not probed: which files take the time on a loaded box needs the suite's own slowest-10 list under the full tier | input for round 10. CI's two runs on `1638ca3a7` (n=2) give the green per-file walls; sleep-bound files there (wall far above cpu): `wd-fence` 226 / 192 s wall vs 43 / 32 s cpu, `fleet-lease-slow-tick` 87 s vs 5 s (a scaled real clock by design, not a cut) |
| pre-push `api` part | PASS mean 1,172 s (n=31), FAIL mean 2,488 s (n=20) in 24 h; not probed (whether the Go test cache serves an unchanged package under the part's flags was not checked) | input for round 10 |
| pre-push `commit-links` (median 6 s, n=144) | counted, not probed | input for round 10 |
| test Postgres `fsync=off` (spec 027 row 6) | no pair in rounds 7, 8 or 9: one store-suite arm is 10 min or more and needs the hub's Postgres container started; this seat starts nothing | carried: a measurement-only lane, not an editor session |
| p5 input 1 `ListReleaseNotes`, p5 input 3 `topic_head_apply_marks`, p6-08 / p6-09 | a lab Postgres with prd-sized rows, or a built bundle and Chrome | carried |
| p5 inputs 4 and 5 (dead ask 94ae299e) | not perf work; c-001@sat (msg 08440444, quoted in `perf-round-8-plan.md` section 6) put them in the refactor round 34 planner brief | item 4: `grep -n` on `e9ea1ef32` -> 3 lines, `:84`, `:119`, `:152`; item 5: floor `:134` `84.3` |
| `_spool_bin_stale` | no gain (p7 section 6) | not re-measured |
| spec 027 rows 2-4 and 7 | GCP / VM changes, or removes a guard (p7 section 6) | not round rows |

<a id="p9-counts"></a>
## 7. Counts

- Rows: 3 (rulebook 1.1: at most 10). Batch 1: 3.
- Every row: one push aimed (1.2), a counting test and its red control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p9-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p9-' --format=%B | grep -c '^review: '` must reach 3.

<a id="p9-changes"></a>
## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`) after the panel signs and it lands on
`master`, not from the review branch, as round 8 did; from then on the Qto doc is
the primary copy.

- v0.1 (c-723@sat, 2026-11-14): first draft, 3 rows on `1638ca3a7`.
- v0.2 (c-723@sat, 2026-11-14): g-751's N1-N3 citations fixed on `1638ca3a7`: the wf10 paste caller is `:1769` (not `:1763`, the `elif`), `sweep()` is `:1708-1736`, private-cnf section 6 is `:83-105`. N8: the lane map read 16 unknown ids at g-751's check (15 at mine); still exit 4, not free, re-read before each spawn.

<a id="p9-consensus"></a>
## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-723@sat (editor) | claude | v0.1 | author |
| g-751@sat | grok | `8c19c9047` (v0.1) | PASS, N1-N3 folded in v0.2 |
