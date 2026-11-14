# Perf round 9 grok seat

Verdict: **PASS** on `8c19c904732343c1b1e0b8e32d32e8d24a6f5c53` (plan v0.1, parent `e9ea1ef32bb4c5e21abcdd3a03f30a486bcfc9df`).

Panel: g-751@sat, grok. Issue SPL-5502. Epic SPL-2402. Spec `csi-spl-doc/specs/027-spool-performance`.

No defects. Notes N1 to N10 are citation and measurement gaps. They do not change the row shape, the file split, or the direction of the measured gain.

## 1. Slug p9 unused

```
git fetch -q origin master
git log origin/master --oneline -E --grep='\(p9-' | wc -l
git ls-remote origin 'refs/heads/*p9-*' | wc -l
```

Printed:

```
ORIGIN:aa48d077b8014723d326ab72b25efb2f9caed973
SLUG_WC:0
P9_HEADS_WC:0
```

`git ls-remote` of the two review refs printed only `8c19c904732343c1b1e0b8e32d32e8d24a6f5c53 refs/heads/review/c002-perf-round-9-planner`. The grok seat ref was absent.

## 2. Sites exist at 1638ca3a7 and on origin/master

`git cat-file -e` printed `yes` for `1638ca3a7651ace34e8f16dd84e0c49988e6df4f` and for `origin/master` on each of:

- `csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh`
- `csi-spl-iac/src/bash/tests/spl-private-cnf.tst.sh`
- `csi-spl-iac/src/bash/run/sec-trufflehog.func.sh`
- `csi-spl-iac/src/bash/tests/sec-trufflehog.tst.sh`
- `.github/workflows/10_ci-quality.yml`
- `csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh`
- `csi-spl-iac/src/bash/tests/hygiene-hidden-workspaces.tst.sh` (runs unchanged; not an edit site)

`git diff --numstat 1638ca3a7651ace34e8f16dd84e0c49988e6df4f origin/master` on those seven paths printed nothing. `NUMSTAT_WC:0`.

```
git merge-base --is-ancestor 1638ca3a7651ace34e8f16dd84e0c49988e6df4f origin/master
```

Printed `ANCESTOR_MASTER_OK`. The same check against the plan sha printed `ANCESTOR_PLAN_OK`.

Line tags at `1638ca3a7` (the body of a sweep call is not copied):

| line | tag |
|---|---|
| `spl-private-cnf.func.sh:145` | comment |
| `spl-private-cnf.func.sh:157` | `spl_private_gate_patterns()` |
| `spl-private-cnf.func.sh:173` | closing brace |
| `spl-private-cnf.tst.sh:83` | section 6 header |
| `spl-private-cnf.tst.sh:105` | last section 6 pass |
| `spl-private-cnf.tst.sh:106` | blank |
| `spl-private-cnf.tst.sh:107` | section 7 header |
| `sec-trufflehog.func.sh:64` | `do_sec_trufflehog()` |
| `sec-trufflehog.func.sh:78` | `fi` |
| `sec-trufflehog.tst.sh:34` | control header |
| `sec-trufflehog.tst.sh:42` | control-detects header |
| `sec-trufflehog.tst.sh:50` | verified-secret header |
| `10_ci-quality.yml:1708` | `sweep()` |
| `10_ci-quality.yml:1717` | grep |
| `10_ci-quality.yml:1735` | `fi` |
| `10_ci-quality.yml:1736` | closing brace |
| `10_ci-quality.yml:1737,1738,1740,1742,1743,1787` | `sweep` call starts |
| `10_ci-quality.yml:1763` | `elif`, no paste |
| `10_ci-quality.yml:1769` | paste and `sweep` call |

## 3. Row shape

Plan lines 87-91 are three rows. Each cell has a baseline command, a number and n, an after probe, sites, a test with a red control, box "either fleet box", vendor claude, kind `simple_coding`, batch 1. Each row lists at most five sites. Lines 93-94 state the rows are claude and that there is no mistral coding or testing. Lines 99-101 split the files: row 01 the private-cnf function and its test, row 02 the trufflehog function and its test, row 03 the workflow and `check-dist-hygiene.tst.sh`. No path is in two rows.

Same-hits backing:

- Row 01. `editor.md` section 2.2 is a 10-row table, every row "yes" for the hit hash, median 3,951 ms and 2,086 ms. The probe directory listing has `hwprobe.sh` and `hwcount.sh` and no stdout file. This seat did not re-run that probe.
- Row 02. Recompute of `th-ab.txt` printed `n 7 7`, medians 10415 and 5318, `overlap False`. Field 3 printed `['1']` and `['5a6443c7']`. That is a control count against a constant, not a scan-output hash. No `th-ab.sh` is in the probe directory. The plan's medians match the file.
- Row 03. See section 4.

Consensus line 219 is the editor only (`c-723@sat`, claude, v0.1, author). That is the draft before this panel signs.

## 4. Re-measure of row 03

n=5, both locales, on a `git archive` of `1638ca3a7` plus 12 plant lines, tree removed after. Patterns taken from the six call lines above. The probe printed:

```
locprobe_patterns_equal true locprobe_n 6
plant_lines 12
n 5
A_sorted 6420 6446 6745 7468 7555
B_sorted 4658 5020 5301 5491 6287
median_A 6745 median_B 5301
joined_hash_values 1 identical true
per_sweep_tuples 1 identical true
ranges_overlap false
delta_pct -21.4
PROBE_EXIT:0
TREE_REMOVED
```

Every run printed counts `2,11,4,0,6,0` for both locales and one shared hash `aa9ff8a9ff71d41d3b7cd41d`. Load on those runs was 35.50 to 40.91.

A one-run follow-up with no plant printed `C.UTF-8` and `C` both `d41d4da1ff71d41d3b7cd41d` counts `0,9,4,0,6,0`, `NOPLANT_EXIT:0`, tree removed.

Recompute of the editor's `loc.txt` printed `n 10 10`, median 5375.0 and 3988.5, one hash `d41d9406ad88bdac8fb22524`, `overlap False`, `delta_pct -25.8`. That matches the plan (3,989 ms and -26%).

Agrees in direction: locale C is faster, the ranges do not overlap, and the percent is the same sign (-21.4% here at n=5, -25.8% in the editor file at n=10). The absolute milliseconds differ. The 24-character hash differs because the tree differs and this seat's hash is not the editor's per-sweep `md5sum` cut. Within each of this seat's runs the two locales had the same hit set.

## 5. Lane map

The brief command `lane-map.sh --check` on the six row paths, and direct `./run -a do_spl_lane_map --quiet` with the same paths, returned exit 124 and an empty stdout in this session (caps of 45s, 120s and 180s, and a 600s run stopped while only the log-tee processes were left). `spl_lane_wt_scan` ends in a bare `wait`, and that wait also waits on `./run`'s log-tee process substitutions, which stay open until the shell exits.

The run that printed a verdict is the same action and the same six paths, `LANE_AGENT=g-751`, with a `wait` that reaps shell jobs and returns when `jobs -pr` is empty. The trace printed `bare-wait-enter 12:14:49Z` and `bare-wait-return 12:14:49Z`. The action log name is `run.sh.20261114_141445`; the stdout file mtime is 14:14:50 +0200. About five seconds, which fits a hub read whose local candidate loop was empty.

Stdout printed 16 `unknown:` lines and no `owned by` line. The exit line printed `WRAP_EXIT:4`. Stderr printed that no live lane lists the six paths, that 16 live lanes record no files, and that the action status is 4.

The 16 ids, all on the other fleet box: c-004, c-172, c-190, c-382, c-390, c-437, c-473, c-507, c-528, c-545, c-669, c-981, g-155, g-485, g-492, g-524.

Exit 4 is not free. It is the state the plan already records in section 3.2, and that section says the check before each spawn re-reads it and asks a lane that is still unknown. No row path was named as owned. The id set is not the editor's 15 (the editor's call was 09:25Z). See N8.

## 6. Distribution hygiene

On worktree HEAD `dd314df8e` (the seat branch before this checkout, behind `origin/master` by 4):

```
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `ok` for each sweep and `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-751`. `HYG_EXIT:0`. The allowed lines were the owner-approved cnf keys only.

The second run, after `git add` of this file on the plan sha, is recorded at the bottom of this file.

## Notes

N1. Plan section 4 line 141 cites a paste at `:1763`. At `1638ca3a7`, line 1763 is the `elif` and has no paste. Line 1769 is the hidden-workspace `sweep` call and has the paste. The row table already cites `:1769`. Neither line is an edit site.

N2. The plan cites `sweep()` as `:1708-1735`. The closing brace is line 1736. The grep at 1717 is inside the cited range.

N3. The plan cites private-cnf test section 6 as `:83-108`. The last section 6 pass is line 105, line 106 is blank, and line 107 is the section 7 header.

N4. The row 03 remeasure (n=5, load 35.50 to 40.91) agrees in direction and in non-overlapping ranges with the editor's n=10 (load 49.7 to 55.8). Medians here are 6745 and 5301. The editor's are 5375 and 3988.5. This seat's joined hash is `aa9ff8a9ff71d41d3b7cd41d`, not `d41d9406ad88bdac8fb22524`.

N5. The no-plant run's counts were `0,9,4,0,6,0`. The editor's note that the other five sweeps hit is their planted tree. On the clean archive the first, fourth and sixth sweeps were empty.

N6. Row 01's same-hits claim is the "yes" column in `editor.md` section 2.2. This seat did not recompute that hash. The probe directory has no raw stdout.

N7. Row 02's third field is `1` versus `5a6443c7`, not a scan hit hash. The timing medians match the plan. The driver script is not on disk.

N8. This seat's lane-map exit is 4 with 16 unknown ids and 0 owned paths. The plan's call was exit 4 with 15 unknown ids. The plan already requires a fresh check before each spawn.

N9. The first hygiene run was on HEAD `dd314df8e`, four commits behind `origin/master` `aa48d077b`. The seven site paths have an empty diff against that master, so the drift check does not depend on that HEAD.

N10. The plan states there is no p7 or p8 retro. This seat did not re-run the why-now share figure. The consensus table has only the editor until the seats sign.

## Hygiene after add

On this index, after `git add` of this file, HEAD `8c19c904732343c1b1e0b8e32d32e8d24a6f5c53`:

```
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `ok` for each sweep and `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-751`. `HYG_EXIT:0`. The allowed lines were the owner-approved cnf keys only (9 personal-name lines, 4 OS-user or box lines, 6 mail lines).
