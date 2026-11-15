# Perf round 10: editor seat (c-209@PC, claude)

The raw commands and outputs behind [perf-round-10-plan.md](../perf-round-10-plan.md).

## 1. Seat

- Editor (planner): c-209@PC, claude, issue SPL-5619, discussion `14ea495b`.
- Every number was measured on **`0d5d699d6`** (`origin/master` at 18:12Z), on the
  desk box (PC, 16 cpus), 2026-11-15 18:12Z-18:21Z; the 1-minute load is printed
  beside each run. Each before/after pair ran interleaved (AB on odd runs, BA on
  even) under the same load.
- The row sites are unchanged on `origin/master` `c27701c45` (18:21Z):
  `git diff --stat 0d5d699d6 origin/master -- .github/workflows/10_ci-quality.yml
  csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh
  csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` prints nothing.
- The probe scripts and raw result files: `/var/tmp/c209-probe/` on the desk box
  (`parab.sh`, `sweepB.sh`, `persweep.sh`, `distsplit.sh`, `hyg3.sh`, `bcc.sh`,
  `eagerab.sh`, `parab-clean.txt`, `parab-plant.txt`, `bcc-ab15.txt`,
  `eager-ab15.txt`). None prints a hidden-workspace name.
- The tree under test: a tracked-file export of `0d5d699d6`
  (`git ls-files -z | tar --null -T - -cf - | tar -xf - -C <dir>`, as
  `do_check_dist_hygiene` makes it).

## 2. Measurements

### 2.1 Which parts: the pre-push log

The desk user's `~/.cache/csi-spl/pre-push.log`, PART lines, SKIP and CACHED lines
left out (n, median, sum).

From 2026-11-14T18:10Z to 2026-11-15T18:12Z (24 h), the parts with the largest sums:

| part | n | median | sum |
|---|---|---|---|
| `orc` | 60 | 245 s | 40,328 s |
| `wui` | 26 | 477 s | 14,487 s |
| `orc-features` | 35 | 369 s | 13,937 s |
| `api` | 23 | 293 s | 13,298 s |
| `lint-gosec` | 14 | 602 s | 10,651 s |
| `wui-e2e` | 14 | 564 s | 9,347 s |
| `iac` | 12 | 385 s | 4,850 s |
| `hygiene` | 184 | 12 s | 2,320 s |
| `lint-trufflehog` | 178 | 9 s | 1,638 s |
| `iac-cross` | 143 | 7 s | 1,265 s |
| `commit-links` | 184 | 6 s | 1,167 s |

Since 2026-11-15T11:30Z (p9-02 landed 10:37Z, p9-01 11:26Z), the always-run parts:
`hygiene` n=19 median 6 s, `commit-links` n=19 4 s, `iac-cross` n=15 3 s,
`lint-trufflehog` n=20 2 s. p9-02 shows in the trufflehog part: mean 8.5 s from
00:00Z to 09:59Z (n=114), 3.0 s from 10:00Z to 18:12Z (n=42).

### 2.2 The hygiene part, piece by piece

`_pp_part_hygiene` = `do_check_dist_hygiene`, then `do_check_fleet_rules_drift`,
then `do_check_qto_doc_drift`. `hyg3.sh`, this worktree, n=3:

| run | load | dist hygiene ms | fleet-rules drift ms | qto drift ms |
|---|---|---|---|---|
| 1 | 18.67 | 5467 | 911 | 391 |
| 2 | 20.70 | 4628 | 555 | 330 |
| 3 | 20.72 | 3783 | 426 | 244 |

`do_check_dist_hygiene` split (`distsplit.sh`, n=3, load 16.52..16.80): export 110,
294, 123 ms; Sweep step 4139, 3853, 3157 ms; `rm -rf` 63, 50, 48 ms.

The Sweep step per `sweep` call (`persweep.sh`, n=2, load 13.43..13.99), in wf10
order: 201 / 214, 325 / 315, 562 / 578, 153 / 215, 209 / 266, 1109 / 1490 (the
hidden-workspace sweep), 704 / 1004 ms (the retired-relay sweep). Seven `grep -r`
passes over the same tree, one after the other; none reads another's result.

### 2.3 Row 01: the seven sweeps at once (n=7, interleaved)

`parab.sh <repo> <n> [plant]`: arm A = wf10's Sweep step as it is (`sweep.sh`,
read out of wf10 with `do_check_dist_hygiene`'s own `yq` line); arm B =
`sweepB.sh`, the same step where each of the seven calls runs in the background,
writes its output and its `fail` to a numbered file, and one join before the
`.vibe/` check prints the outputs in call order and folds the `fail`s. Both run
`cd <export> && bash <step>`; the whole stdout+stderr is hashed.

Clean tree (the export of `0d5d699d6`), load 15.47..18.60:

| run | A ms | B ms | rc A / B | output sha A = B |
|---|---|---|---|---|
| 1 | 3397 | 1361 | 0 / 0 | yes (`265131b1`) |
| 2 | 4804 | 1438 | 0 / 0 | yes |
| 3 | 4640 | 1789 | 0 / 0 | yes |
| 4 | 3536 | 1462 | 0 / 0 | yes |
| 5 | 3083 | 1149 | 0 / 0 | yes |
| 6 | 3322 | 1277 | 0 / 0 | yes |
| 7 | 3252 | 1305 | 0 / 0 | yes |

A median **3,397 ms** (3,083..4,804), B median **1,361 ms** (1,149..1,789),
**-60%**; B below its paired A in 7 of 7; the ranges do not overlap.

With a 6-line plant (one hit for each of the five ASCII sweeps and the
retired-relay sweep, `/var/tmp/c209-probe/plant.txt`, copied into the export at
run time), n=1, load 15.87: A 4,856 ms, B 1,581 ms, rc 1 / 1, the 17-line outputs
identical (`diff` empty, sha `c52bfd09` both): every `::error::` and `ok -` line
in the same order. Two runs before the series (n=2, load 17.18..17.81, same
plant): A 4,089 / 4,056 ms, B 1,399 / 1,555 ms, outputs identical.

A temporary assignment before a function call reaches a background child forked
inside it, also after the function returned:
`bash -c 'g(){ ( printenv LC_ALL >f ) & }; LC_ALL=C.UTF-8 g; wait; cat f'` ->
`C.UTF-8` (and `C` for `LC_ALL=C`). So `LC_ALL=C sweep ...` and
`LC_ALL="$gate_loc" sweep ...` keep their locale with the body in the background.

### 2.4 Row 02: the cleancode walk, one awk (n=15 and n=7, interleaved)

`bash-cleancode.tst.sh` `measure()` (`:42-51`) starts one `awk` per file; the walk
lists **1,200** files (`find $ROOTS ... | sort`, the test's own line).

`bcc.sh <repo> <n>`: arm A = today's `measure` over the 1,200 files; arm B = one
`awk` over all of them, the same three rules with `FNR` for `NR`, and
`FNR == 1 { n = ""; f = FILENAME relative to APP_ROOT }`. Load 24.85..30.49:

| run | A ms | B ms | lines A / B | output identical |
|---|---|---|---|---|
| 1 | 1886 | 34 | 7013 / 7013 | yes |
| 2 | 1502 | 37 | 7013 / 7013 | yes |
| 3 | 1550 | 38 | 7013 / 7013 | yes |
| 4 | 1592 | 40 | 7013 / 7013 | yes |
| 5 | 1577 | 34 | 7013 / 7013 | yes |
| 6 | 1604 | 38 | 7013 / 7013 | yes |
| 7 | 1527 | 39 | 7013 / 7013 | yes |
| 8 | 1601 | 38 | 7013 / 7013 | yes |
| 9 | 1787 | 37 | 7013 / 7013 | yes |
| 10 | 1572 | 38 | 7013 / 7013 | yes |
| 11 | 1483 | 36 | 7013 / 7013 | yes |
| 12 | 1436 | 35 | 7013 / 7013 | yes |
| 13 | 1331 | 34 | 7013 / 7013 | yes |
| 14 | 2011 | 33 | 7013 / 7013 | yes |
| 15 | 2236 | 53 | 7013 / 7013 | yes |

`measure` alone: A median **1,577 ms** (1,331..2,236), B median **37 ms** (33..53).

The whole test, A = the file as on `0d5d699d6`, B = the same file with only
`measure()` replaced, both in a tracked-file export, n=7, load 19.46..20.55:
A 1174, 1226, 1234, 1519, 2235, 1984, 1437 ms (median **1,437**); B 173, 168, 161,
163, 296, 309, 180 ms (median **173**), **-88%**; rc 0 both, 13 `PASS` lines each,
the outputs identical but for the file's own name. Before the series, the test as
it is ran 2875, 3259, 3028 ms in this worktree (n=3, load 23.66..27.69).

The test runs at the end of every pre-push `orc` part (`check-pre-push.func.sh`
`_pp_part_orc`, after the suite): 60 non-skipped `orc` parts in the 24 h of 2.1.
It also runs in the iac suite and in CI.

### 2.5 Dropped: the five eager orc files again (n=15)

`perf-round-9-plan.md` section 6, a-827's input 4 (`spl-wd-takeover`,
`spl-peer-crons`, `spl-wd-peers`, `spl-wd-ensure`, `spl-asks-open`): the loop cut
was probed there, the whole start was not. `eagerab.sh`: a tracked-file export of
`csi-spl-orc` and `csi-spl-cnf` whose `do_load_functions` skips the files named in
`RUN_PROBE_SKIP` (a probe-only line); arm A skips none, arm B the five; both time
`./run -a do_p10_no_such_action`. The index lists **89** eager files, the five
among them. Load 15.60..17.95:

A 229, 210, 214, 199, 208, 188, 187, 197, 195, 324, 399, 401, 424, 409, 330 ms
(median **214**, 187..424); B 209, 214, 188, 185, 189, 177, 183, 176, 204, 212, 448,
399, 400, 298, 348 ms (median **209**, 176..448). -5 ms, the ranges overlap: no gain
in the whole start.

### 2.6 Counted, not rows

- `commit-links`: `COMMIT_LINKS_HUB=none COMMIT_LINKS_HARD=0
  COMMIT_LINKS_RANGE=HEAD~1..HEAD ./run -a do_spl_commit_links_check` 535, 362,
  399, 322, 334 ms (median 362, n=5, load 17.91..18.60), beside a no-op `./run`
  305, 298, 259, 257, 231 ms. The part's median is 4 s (n=19) to 6 s (n=184): the
  rest is `_spl_cl_hub` (the prd key lookup) and `_spl_cl_hub_read` (cloud cnf,
  account pin, the hub call). Not probed: that path reads the prd key, which this
  seat does not.
- `iac-cross`: its three `.` rows run on every push. `gcloud-account-pinned.tst.sh`
  1825, 2318, 2325 ms (n=3, load 15.87..16.52), `domain-single-source.tst.sh` 264,
  291, 225 ms, `no-key-material-in-tree.tst.sh` 461, 368, 227 ms. Of
  `gcloud-account-pinned`, its static scans (from `code_files()` to the end) take
  604, 731, 654, 574, 475 ms beside the whole test's 2063, 2474, 2032, 1669, 1511 ms
  (n=5, load 15.10..19.17); the rest is its ~30 `bash -c` resolver cases. No
  after arm.

## 3. Reads for R1 / R3

- Lane map, 18:20:54Z-18:20:55Z, one call: `lane-map.sh --check
  .github/workflows/10_ci-quality.yml,csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh,csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh,csi-spl-doc/doc/md/perf-round-10-plan.md,csi-spl-doc/doc/md/perf-round-10/editor.md
  --agent c-209` -> exit 4, `0` lines `owned by`, `11` lines `unknown:` (all on
  sat): c-170, c-203 (feature lanes), c-193, c-197, c-236, c-762 (rotation seats),
  c-239 (r59-05, landed `c27701c45`), c-241, c-244 (bug lanes; c-244's slug names
  the pre-push commit-body hygiene), c-664, g-266 (a reviewer seat).
- Spawn queue, 18:13:33Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`: 26 queued, 0 placing. No slug names a row file; 17 of the
  briefs are on sat and were not readable here.
- Unlanded round rows, 18:21:12Z, on `c27701c45`: landed r57-01..04,
  r58-01..07, r59-01..05, p8-01, p8-02, p8-04, p9-01..03. Not landed: r57-05,
  r57-06, r58-08, r59-06. r58-08 (`refactor-round-32-plan.md` row 08) edits the
  `LONG` list of `bash-cleancode.tst.sh`, row 02's file.
- Slug, 18:21:12Z: `git log origin/master --oneline -E --grep='\(p10-'` -> 0;
  `git ls-tree -r --name-only origin/master | grep -c perf-round-10` -> 0;
  `... | grep -c perf-round-9-retro` -> 0.
- Agent kinds, 18:21:29Z: `ENV=prd ./run -a do_spl_hub_agent_kinds` ->
  `off [qwen], paused []`. The action minted a prd access token with the box's
  prd SA key to answer; this seat did not open the key file.
- Dispatch lease, 18:21Z: `LEASE_CMD=show ./run -a do_spl_dispatch_lease` ->
  `c-002@sat`.
- A live orc lane outside the round: the pre-push log shows
  `review/c207-spl5620-orc-eager-88` pushed by c-207 at 18:13:26Z (SPL-5620, the
  orc eager list); 2.5 is not a row, so no row touches its files.
