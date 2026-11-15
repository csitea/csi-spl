# Perf round 9 grok seat

Verdict: **REVIEW FAIL** on `060a8cddcc80b021944c032b467f88a8df268ad7` (plan v0.4). The **FAIL** on `d6c1bee7a8b7d1a091d9efc38230d23de752c542` (plan v0.3) stands. The **PASS** on `89f8cef1495819e8b85d0644a8bf7000e77f6cb7` (plan v0.2) stands. Sections 1 to 6 are the v0.1 review. Section 0 is the v0.2 re-sign. Section 7 is the v0.3 delta. Section 8 is the v0.4 delta.

Panel: g-751@sat, grok. Issue SPL-5502. Epic SPL-2402. Spec `csi-spl-doc/specs/027-spool-performance`.

v0.1 and v0.2: no defects. N1 to N3 were citation gaps and v0.2 closes them. N4 to N11 do not change the row shape, the file split, or the direction of the measured gain. v0.3: W1 and W2 in section 7. v0.4: W2 is answered. W1 remains. Section 8.

## 0. Re-sign of v0.2

Asked by c-723 note `0e1905c3-11e9-4bf3-bed3-6eb46a0726bc` on task `dispatch-perf-r9`.

```
git fetch -q origin review/c002-perf-round-9-planner review/c002-perf-round-9-grok-seat master
git rev-parse origin/review/c002-perf-round-9-planner
git rev-parse 89f8cef1495819e8b85d0644a8bf7000e77f6cb7^
git merge-base --is-ancestor 8c19c904732343c1b1e0b8e32d32e8d24a6f5c53 89f8cef1495819e8b85d0644a8bf7000e77f6cb7
git diff --stat 8c19c904732343c1b1e0b8e32d32e8d24a6f5c53 89f8cef1495819e8b85d0644a8bf7000e77f6cb7
git log --oneline 8c19c904732343c1b1e0b8e32d32e8d24a6f5c53..89f8cef1495819e8b85d0644a8bf7000e77f6cb7
```

Printed:

```
PLANNER:89f8cef1495819e8b85d0644a8bf7000e77f6cb7
PARENT:8c19c904732343c1b1e0b8e32d32e8d24a6f5c53
ANCESTOR_OK
 csi-spl-doc/doc/md/perf-round-9-plan.md | 8 +++++---
 1 file changed, 5 insertions(+), 3 deletions(-)
89f8cef14 docs(p9-plan, SPL-5502): perf round 9 plan v0.2, g-751's N1-N3 citations fixed
```

`git diff -U0` of that range has five changed lines. Three replace a citation and keep the same baseline, after number, n, vendor, kind and batch:

- Row 01 test range `:83-108` became `:83-105`.
- Row 03 site range `wf10:1708-1735` became `wf10:1708-1736`.
- Section 4 caller `:1763` became `:1769`.

The other two added lines are the section 8 v0.2 note and the section 9 row for this seat's v0.1 PASS. Row 02 is not in the diff.

Re-read at `1638ca3a7` with `git show 1638ca3a7651ace34e8f16dd84e0c49988e6df4f:<file> | sed -n`:

```
1708: sweep() {
1717: hits="$(grep -rnIoP ..."
1735: fi
1736: }
1763: elif pats="$(spl_private_gate_patterns "$base")"
1769: LC_ALL="$gate_loc" sweep ... "$(paste -sd'|' <<<"$pats")"
83: # --- 6. gate patterns
105: pass "6. a forms_only slug is never matched as the plain word"
106: blank
107: # --- 7. the tracked cnf
```

Those tags match the v0.2 cites. N1, N2 and N3 are closed. No new defect.

`lane-map.sh --check csi-spl-doc/doc/md/perf-round-9/seat-grok.md --agent g-751` (desk-cron copy, `timeout 90`) printed the spool-env warning and `LANE_MAP_EXIT:124`. Empty stdout. Same hang as section 5. Not a collision verdict. This path is the one file this brief assigns to g-751.

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

N11. The v0.2 re-sign in section 0 did not re-run the row 01, 02 or 03 probes. The diff changes three citations and adds the section 8 and section 9 lines. The baseline, after number, n, vendor, kind and batch text is the same on both sides of the row hunks.

## Hygiene after add

On this index, after `git add` of this file, HEAD `8c19c904732343c1b1e0b8e32d32e8d24a6f5c53`:

```
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `ok` for each sweep and `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-751`. `HYG_EXIT:0`. The allowed lines were the owner-approved cnf keys only (9 personal-name lines, 4 OS-user or box lines, 6 mail lines).

The v0.2 re-sign run, after `git add` of this file, HEAD `b0eff100de0d9a100f157fe89c3a32b273c89049`:

```
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `ok` for each sweep and `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-751`. `HYG_EXIT:0`. The allowed lines were the owner-approved cnf keys only (9 personal-name lines, 4 OS-user or box lines, 6 mail lines).

## 7. Delta review of v0.3

Asked by c-002 msg `98531cc1-0739-4127-b3e3-00c5fdc9bc62` on task `dispatch-perf-r8`. Review only `git diff 89f8cef14 d6c1bee7a -- csi-spl-doc/doc/md/perf-round-9-plan.md`. Checked 2026-11-15 from `/opt/csi/csi-spl-wt/g-751`.

```
git fetch -q origin review/c002-perf-round-9-planner review/c002-perf-round-9-grok-seat master
git rev-parse origin/review/c002-perf-round-9-planner
git rev-parse d6c1bee7a8b7d1a091d9efc38230d23de752c542^
git merge-base --is-ancestor 89f8cef1495819e8b85d0644a8bf7000e77f6cb7 d6c1bee7a8b7d1a091d9efc38230d23de752c542
git diff --stat 89f8cef1495819e8b85d0644a8bf7000e77f6cb7 d6c1bee7a8b7d1a091d9efc38230d23de752c542 -- csi-spl-doc/doc/md/perf-round-9-plan.md
git merge-base --is-ancestor 3aeabc558512fba30a0146c19959dfe117a1f520 origin/master
git grep -n -e cross-vendor d6c1bee7a8b7d1a091d9efc38230d23de752c542 -- csi-spl-doc/doc/md/perf-round-9-plan.md
git log -1 --format='%H %ci %s' origin/master -- csi-spl-doc/doc/md/perf-round-8-retro.md
```

Printed:

```
PLANNER:d6c1bee7a8b7d1a091d9efc38230d23de752c542
PARENT:89f8cef1495819e8b85d0644a8bf7000e77f6cb7
ANCESTOR_OK
 csi-spl-doc/doc/md/perf-round-9-plan.md | 23 +++++++++++++++--------
 1 file changed, 15 insertions(+), 8 deletions(-)
RETRO_ANCESTOR_RC:1
CROSS_RC:1
MASTER:035dc15012686aac430500ddbda3a5d06b456ced
8fc934b9e3cefab1409aa278243e504f228a7363 2026-11-15 02:33:14 +0200 docs(doc, SPL-5537): perf rounds 7 and 8 retros
```

`git rev-parse origin/master:csi-spl-doc/doc/md/perf-round-8-retro.md` and the same path at `8fc934b9e` both print `2013b5b30ee0f71a84ae74537303b87ad4dd805a`. `3aeabc558` is not an ancestor of `origin/master` (rc 1). `git branch -a --contains 3aeabc558512fba30a0146c19959dfe117a1f520` prints only `remotes/origin/review/c002-perf-round-7-8-retro`. The plan commit is `2026-11-15 03:03:16 +0200`, after that retro rewrite. Section 8 was read with `git show origin/master:csi-spl-doc/doc/md/perf-round-8-retro.md`.

Panel line and the three rows pass. Plan lines 168-173 say "claude seat, same vendor as the editor; the panel's other seat is grok". `git grep -e cross-vendor` on that file at `d6c1bee7a` prints nothing (rc 1). Section 9 keeps this seat's PASS on `8c19c9047` and `89f8cef14` and leaves the claude seat pending with the same phrase. Line 85 is still `## 3. The 3 rows`. Lines 89-91 are still p9-01, p9-02 and p9-03.

W1. Plan line 185 and the v0.3 changelog line 218 leave a-827's input 1 out because "the after arm reaches the prd hub with its service-account key" and "one needs a key". The cited figures are 1,273 ms with the prd hub and 784 ms with `COMMIT_LINKS_HUB=none` (medians, n=5, on `5815e76c5`), pinned to section 8 at `3aeabc558`. Section 8 on `origin/master` replaced that measurement. Input 1 there is local-only on `8247621e2`, n=5, load ~17, zero prd hub HTTP calls: `empty_default_hub` 619 ms (396..845) vs `empty_hub_none` 344 ms (318..533, -275 ms, -44%) vs `one_commit_hub_none` 378 ms (323..564). The command uses `COMMIT_LINKS_RANGE=HEAD..HEAD` and `COMMIT_LINKS_HUB=none`. The "needs a key" reason is false against that section. Rulebook 4.1: a drop names that candidate's measurement.

W2. Plan line 188 leaves input 4 out as "dropped, no gain" and cites "editor 2.5 above (-9% loop, -2% whole start, n=15)". That probe is line 184's other five files (`spl-agent-settings-check`, `spl-dispatch-lease`, `spl-wd-ensure`, `spl-box-restart-prepare`, `spl-asks-open`): 380 ms vs 347 ms and 753 vs 736 ms. Master section 8 input 4 is `spl-wd-takeover`, `spl-peer-crons`, `spl-wd-peers`, `spl-wd-ensure`, `spl-asks-open`. Isolated medians 146, 73, 64, 58, 38 ms; sum 379 ms; 183.1 ms incremental inside the 483.1 ms 88-file loop. Section 8 does not say no gain. Rulebook 4.1 line 217: a no-gain drop carries that candidate's measurement, never a guess.

Inputs 2, 3 and 5 match master section 8 on the headline numbers: 1,564 ms (n=5), 730 ms (n=5, 52 words), 411 ms (n=5, 36 of 185 eager). Their R3 and "carried until probed" reasons are not contradicted by section 8. Ask ids `68f1dea2`, `dc8568f5`, `20db36c3` and `7e0d6251` were not re-read from the live queue. Input 5's clause "not a gain (input 4)" inherits W2. The carry itself is not a separate fail.

Lane-map of this file, `lane-map.sh --check csi-spl-doc/doc/md/perf-round-9/seat-grok.md --agent g-751`, exited 4. It printed that no live lane lists the path, and that 11 live lanes record no files. Exit 4 is unknown scope, not an owner of this file.

## Hygiene after the v0.3 sign

On this index, after `git add` of this file, HEAD `a6a2f09989497b5dcee49fce86187ab84c49439a`:

```
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `ok` for each sweep and `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-751`. `HYG_EXIT:0`. The allowed lines were the owner-approved cnf keys only (9 personal-name lines, 4 OS-user or box lines, 6 mail lines).

## 8. Delta review of v0.4

Asked by c-002 msg `44c0b551-b5c2-4cac-90a2-275447540055` on task `dispatch-perf-r8`. Review only the delta of `060a8cddc` against W1 and W2 in section 7. Checked 2026-11-15 from `/opt/csi/csi-spl-wt/g-751`.

```
git fetch -q origin review/c002-perf-round-9-planner review/c002-perf-round-9-grok-seat master
git rev-parse origin/review/c002-perf-round-9-planner
git rev-parse 060a8cddcc80b021944c032b467f88a8df268ad7^
git merge-base --is-ancestor d6c1bee7a8b7d1a091d9efc38230d23de752c542 060a8cddcc80b021944c032b467f88a8df268ad7
git diff --stat d6c1bee7a8b7d1a091d9efc38230d23de752c542 060a8cddcc80b021944c032b467f88a8df268ad7 -- csi-spl-doc/doc/md/perf-round-9-plan.md
git rev-parse origin/master
git rev-parse origin/master:csi-spl-doc/doc/md/perf-round-8-retro.md
git grep -n -e cross-vendor 060a8cddcc80b021944c032b467f88a8df268ad7 -- csi-spl-doc/doc/md/perf-round-9-plan.md
git grep -n -e 'p9-0' 060a8cddcc80b021944c032b467f88a8df268ad7 -- csi-spl-doc/doc/md/perf-round-9-plan.md
git show origin/master:csi-spl-iac/src/bash/run/check-pre-push.func.sh | sed -n 816p
git show origin/master:csi-spl-orc/src/bash/run/spl-commit-links-check.func.sh | sed -n 42p
git show origin/master:csi-spl-orc/src/bash/run/spl-commit-links-check.func.sh | sed -n 51p
git show origin/master:csi-spl-orc/src/bash/run/spl-commit-links-check.func.sh | sed -n 59p
git show origin/master:csi-spl-orc/src/bash/run/spl-commit-links-check.func.sh | sed -n 141p
git show origin/master:csi-spl-orc/src/bash/run/spl-commit-links-check.func.sh | sed -n 168p
```

Printed:

```
PLANNER:060a8cddcc80b021944c032b467f88a8df268ad7
PARENT:d6c1bee7a8b7d1a091d9efc38230d23de752c542
ANCESTOR_OK
 csi-spl-doc/doc/md/perf-round-9-plan.md | 14 ++++++++------
 1 file changed, 8 insertions(+), 6 deletions(-)
MASTER:d99a6febb2879288b5692769c2313647151329c4
RETRO_BLOB:2013b5b30ee0f71a84ae74537303b87ad4dd805a
CROSS_RC:1
ROWS:p9-01 p9-02 p9-03
LANE_RC:4
```

`git log -1 --format='%H %ci %s' 060a8cddc` prints `060a8cddcc80b021944c032b467f88a8df268ad7 2026-11-15 03:24:55 +0200 docs(p9-plan, SPL-5502): perf round 9 plan v0.4, g-751's W1 and W2 fixed against master's p8 retro section 8`. Parent of v0.4 is the v0.3 sha. One file, 8 insertions, 6 deletions. Retro blob on `origin/master` is still `2013b5b30`. `git grep -e cross-vendor` on the plan at `060a8cddc` prints nothing (rc 1). Row headings stay p9-01, p9-02 and p9-03. Panel lines 169-170 still say "claude seat, same vendor as the editor; the panel's other seat is grok". Section 9 records this seat's FAIL on `d6c1bee7a` (seat `9c4b5c074`).

The four `sed -n` lines on `origin/master` `d99a6febb` print:

```
  ( cd "$tree/csi-spl-orc" && COMMIT_LINKS_HARD=0 COMMIT_LINKS_REPO="$tree" COMMIT_LINKS_RANGE="$base..HEAD" ./run -a do_spl_commit_links_check )
  hub="$(_spl_cl_hub)" || return 1
  mapfile -t shas < <(git -C "$repo" rev-list --no-merges --reverse "$range")
  if [[ "$hub" != none && -n "$all" ]]; then
    ( ENV=prd; do_spl_cloud_cnf >/dev/null 2>&1 && do_gcp_sa_key_file "$SPL_CNF" >/dev/null 2>&1 ) && h=prd
    do_spl_cloud_cnf || exit 1
```

Line 811, in the same function, sets `base="${PRE_PUSH_BASE:-origin/master}"`. Line 816 does not set `COMMIT_LINKS_HUB`.

W2 is answered. Plan input 4 now names `spl-wd-takeover`, `spl-peer-crons`, `spl-wd-peers`, `spl-wd-ensure` and `spl-asks-open`, and section 8's figures: 379 ms summed isolated medians, 183.1 ms incremental inside the 483.1 ms 88-file loop, n=5, on `5815e76c5`. It reports a with/without probe of those five on the 88 eager files of `d99a6febb`: 336 ms vs 261 ms (-75 ms, -22%), n=15 interleaved, load 39..41, ranges 295..385 / 242..314. This seat did not re-run that n=15 probe. The text keeps the set as a candidate, not a row: the whole `./run` start is not probed, and the lane map exits 4. It no longer drops the set as no gain by the other five files' -9% loop and -2% whole start. Input 5 no longer says the isolated cost is not a gain. It says an isolated cost does not size the gain and still needs its own with/without probe.

W1 remains. v0.4 does cite the right retro blob and the right local figures: empty range 619 ms vs 344 ms (-275 ms, -44%) and one commit with `COMMIT_LINKS_HUB=none` at 378 ms, n=5, on `8247621e2`, load ~17. Those match section 8. The line numbers match the code above. The new reason does not. `do_spl_commit_links_check` calls `_spl_cl_hub` at line 42 before it reads the range (the `mapfile` is line 51). When `COMMIT_LINKS_HUB` is unset, line 141 runs `do_spl_cloud_cnf` on that call, including a call whose range is `PRE_PUSH_BASE..HEAD`. The -275 ms is that first local call (619 ms) against `COMMIT_LINKS_HUB=none` (344 ms). Section 8 ran both of those arms as `HEAD..HEAD`, so `$all` was empty and line 168 ran in neither arm. The empty range isolates the first call. A push that carries commits still pays line 141. Changelog v0.4 says input 1 is left out because its measured gain needs an empty range, which a push that carries commits never gives. That sentence is false. Line 168 is a second cost: it runs only when the hub is not none and the range produced keys. That call is not the -275 ms, and this seat did not time it.

Ask ids `68f1dea2`, `dc8568f5`, `20db36c3` and `7e0d6251` were not re-read from the live queue.

Lane-map of this file, `lane-map.sh --check csi-spl-doc/doc/md/perf-round-9/seat-grok.md --agent g-751`, exited 4. It printed that no live lane lists the path, and that 12 live lanes record no files. Exit 4 is unknown scope, not an owner of this file.

## Hygiene after the v0.4 sign

On this index, after `git add` of this file, HEAD `9c4b5c074cb57885a001b0796bb756485d5b615b`:

```
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `ok` for each sweep and `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-751`. `HYG_EXIT:0`. The allowed lines were the owner-approved cnf keys only (9 personal-name lines, 4 OS-user or box lines, 6 mail lines).
