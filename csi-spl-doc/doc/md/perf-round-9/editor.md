# Perf round 9: editor seat (c-723@sat, claude)

The raw commands and outputs behind [perf-round-9-plan.md](../perf-round-9-plan.md).

## 1. Seat

- Editor (planner): c-723@sat, claude, issue SPL-5502, discussion `8a6d50d4`.
- Every number was measured on **`1638ca3a7`** (`1638ca3a7651ace34e8f16dd84e0c49988e6df4f`,
  `origin/master` at 09:0xZ), on sat (16 cpus), 2026-11-14 09:1xZ-09:2xZ; the
  1-minute load is printed beside each run. Each before/after pair ran interleaved
  (AB on odd runs, BA on even) under the same load.
- The row sites are unchanged on `origin/master` `e9ea1ef32` (09:26Z):
  `git diff --stat 1638ca3a7 e9ea1ef32 -- .github/workflows/10_ci-quality.yml
  csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh
  csi-spl-iac/src/bash/run/sec-trufflehog.func.sh csi-spl-iac/src/bash/tests/
  csi-spl-iac/src/bash/run/check-dist-hygiene.func.sh` prints nothing.
- The probe scripts and raw result files: `/var/tmp/c723-probe/` on sat
  (`hwprobe.sh`, `hwcount.sh`, `locprobe.sh`, `persweep.sh`, `hw-plant.txt`, `loc.txt`,
  `th-ab.txt`, `eager-ab15.txt`). None prints a hidden-workspace name.
- The tree under test: a tracked-file export of `1638ca3a7`
  (`git ls-files -z | tar --null -T - -cf - | tar -xf - -C <dir>`, as
  `do_check_dist_hygiene` makes it): 9,589 files, 104 MB.

## 2. Measurements

### 2.1 Which parts: the pre-push log

The desk user's `~/.cache/csi-spl/pre-push.log`, PART lines from
2026-11-13T09:00Z, read at 09:10Z, SKIP and cached lines left out (median, n, sum):

| part | n | median | sum |
|---|---|---|---|
| `hygiene` | 144 | 17 s | 2,663 s |
| `lint-trufflehog` | 156 | 9 s | 1,404 s |
| `iac-cross` | 115 | 8 s | 1,144 s |
| `commit-links` | 144 | 6 s | 983 s |

The suite parts (`orc`, `api`, `wui`, `iac`) run only when touched; they hold the
largest sums (`orc` 143,812 s over n=50), almost all of it in failing runs. By
status and tier, 2026-11-13T09:00Z..2026-11-14T09:11Z: `orc` FAIL full n=6 mean
12,305 s, WARN-pre-existing full n=4 mean 12,260 s, PASS fast n=18 mean 516 s;
the 4 full-tier `TIMED OUT` lines read 12,023..12,032 s. Input for round 10 (plan
section 6).

`./run -a do_check_dist_hygiene` (csi-spl-iac, this worktree), wall, n=3, load
21..30: 9,854, 10,719, 11,356 ms, rc 0, 8 `ok -` lines each.

The Sweep step alone (read out of wf10 with the action's own `yq` line) under
`PS4='+ $EPOCHREALTIME $LINENO '`, n=1: 9.403 s of the step on its `grep` line
(script line 41); per `sweep` call, in order: 0.656, 0.813, 1.017, 0.392, 0.571,
**4.580** (the hidden-workspace sweep), 1.375 s.

### 2.2 Row 01: the hidden-workspace pattern (n=10, interleaved)

The box overlay builds 26 patterns: 14 word slugs (`(?i)(?<![\p{L}\p{N}])slug(?![\p{L}\p{N}])`),
12 forms_only lines, no deny entry (`grep -c` over `spl_private_gate_patterns`'
output; no name printed).

`/var/tmp/c723-probe/hwprobe.sh <repo> <tree> <n>`: arm A = today's joined
pattern (`paste -sd'|'`), arm B = the 14 word slugs as one
`(?i)(?<![\p{L}\p{N}])(?:s1|...|s14)(?![\p{L}\p{N}])` plus the 12 other lines;
both `LC_ALL=<gate locale> grep -rnIoP <wf10's excludes> <pattern> . | cut -d: -f1,2 | sort -u`,
the hit set hashed. The tree: the export plus a 144-line plant (each slug alone,
inside a word, after an accented letter, before one, as `"name":`, in a
`workspaces:` list, as `<slug>.dev.example.net`, and with a dash), written at run
time and never printed. Load 25..36:

| run | A ms | B ms | hit hash A = B |
|---|---|---|---|
| 1 | 5442 | 2452 | yes |
| 2 | 4462 | 2795 | yes |
| 3 | 3972 | 2374 | yes |
| 4 | 3682 | 2224 | yes |
| 5 | 3362 | 1811 | yes |
| 6 | 3929 | 1966 | yes |
| 7 | 4161 | 1757 | yes |
| 8 | 3511 | 1680 | yes |
| 9 | 4003 | 2205 | yes |
| 10 | 3207 | 1881 | yes |

Median A **3,951 ms**, B **2,086 ms** (-47%). The plant gives 79 hit lines in both
arms (`hwcount.sh`, the same probe with `wc -l` for the hash, n=1). On the export
without the plant (n=2): A 4,674 / 4,324 ms, B 2,637 / 2,597 ms, hit sets equal.

### 2.3 Row 02: the trufflehog control (n=7, interleaved)

trufflehog 3.90.8. The control dir is the action's own planted pair
(`_sec_trufflehog_control_dir`); the scan targets are two tracked files.

One start each, n=5, load 40..52: control
`trufflehog filesystem <ctl> --no-update --no-verification --json`: 7034, 6245,
10928, 7593, 6901 ms (median **7,034**); scan
`trufflehog filesystem <2 files> --only-verified --no-update --json`: 7135, 6905,
7732, 6327, 7706 ms (median **7,135**).

A/B, `th-ab.txt`: arm A = control (1 detection each run) then the scan; arm B =
`sha256sum` of the binary then the scan. Load 49..57:

| run | A ms | B ms |
|---|---|---|
| 1 | 10755 | 6126 |
| 2 | 10481 | 6647 |
| 3 | 9014 | 5027 |
| 4 | 10562 | 4541 |
| 5 | 10415 | 5345 |
| 6 | 9853 | 4701 |
| 7 | 9450 | 5318 |

Median A **10,415 ms**, B **5,318 ms** (-49%); the ranges do not overlap.

### 2.4 Row 03: the six ASCII sweeps under `LC_ALL=C` (n=10, interleaved)

`/var/tmp/c723-probe/locprobe.sh <tree> <n>`: the six fixed patterns of wf10
(`:1737-1743`, `:1787`, copied verbatim into the probe), each
`grep -rnIoP <wf10's excludes> <pattern> . | cut -d: -f1,2 | sort -u`; arm A
under `C.UTF-8` (the box `LANG`, for the desk user too), arm B under `LC_ALL=C`;
one 4-hex hash per sweep's hit set. The tree: the planted export of 2.2 plus 12
lines that put the six sweeps' ASCII words before and after multibyte letters
(the `\b` and `\x80-\xff` cases). Load 49.7..55.8:

| arm | ms, sorted | median |
|---|---|---|
| A (`C.UTF-8`) | 4970 5145 5192 5328 5349 5401 5493 5873 5937 6298 | **5,375** |
| B (`C`) | 3518 3667 3905 3918 3944 4033 4131 4262 4335 4483 | **3,989** |

-26%; the six hashes `d41d9406ad88bdac8fb22524` in all 20 runs (the first sweep
has no hit, the other five do). Per sweep, `persweep.sh`, n=2 per locale: 472 /
474, 685 / 668, 1023 / 826, 337 / 364, 443 / 457, 1282 / 1242 ms under
`C.UTF-8`; 331 / 339, 456 / 457, 699 / 682, 246 / 215, 291 / 311, 949 / 1054 ms
under `C`.

### 2.5 Not a row: the next five eager orc files (n=15, interleaved)

A copy of `csi-spl-orc/src/bash/run/run.sh` in the export (never in a worktree)
times each eager `source` and the loop; `SKIP5=<the five>` skips them. 88 eager
files. Per file, n=7, load ~60 read after the 7th run (median ms): `spl-agent-settings-check` 73,
`spl-dispatch-lease` 54, `spl-wd-ensure` 41, `spl-box-restart-prepare` 41,
`spl-asks-open` 40, then `spl-wd-peers` 23, `net-beat-continuity` 22.

A/B, `eager-ab15.txt`, `./run-probe -a do_p9_no_such_action`, load 55..61:

| arm | eager loop | whole start (wall) |
|---|---|---|
| A (88 files) | median **380 ms** (288..787) | median **753 ms** (573..1721) |
| B (83 files) | median **347 ms** (298..714) | median **736 ms** (572..1533) |

-9% of the loop, -2% of the start, ranges overlapping. An earlier n=7 pair
(load 57..63) read 752 vs 680 ms for the loop. The five files' own medians sum to
249 ms, but skipping them saves 33: the first file to source a common include pays
for it, and the next one pays when the first is skipped. Dropped.

## 3. Readings for R3 and R7

See the plan, sections 3.2 and 5.
