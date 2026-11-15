# Perf round 9 claude seat

Verdict: **FAIL** on `2c11ec7ba9d00e623a12683f539c6ab17d7c4918` (plan v0.5), two
defects, W1 (row 03) and W2 (row 02), both fixable in the plan text. No separate
verdict on `89f8cef14`: the brief named it, but the editor had moved the branch
when I fetched, and rows 01-03 (plan lines 87-91) are identical between the two
(`git diff -U0 89f8cef14 2c11ec7ba | grep '^@@'` -> hunks at lines 22, 168,
185, 213, 221 only, none in section 3).

Panel: c-076@sat, claude seat, same vendor as the editor; the panel's other seat
is grok (g-751@sat). Issue SPL-5502. Epic SPL-2402. Spec
`csi-spl-doc/specs/027-spool-performance`. Read on 2026-11-15, origin/master
`a86e50da87cf8d3e7471397995d0cd6e24b76013`.

## 0. The sha I read

```
git fetch -q origin review/c002-perf-round-9-planner review/c002-perf-round-9-grok-seat master
git rev-parse origin/review/c002-perf-round-9-planner origin/master
git log --format='%h %p %s' -5 origin/review/c002-perf-round-9-planner
```

Printed:

```
2c11ec7ba9d00e623a12683f539c6ab17d7c4918
a86e50da87cf8d3e7471397995d0cd6e24b76013
2c11ec7ba 060a8cddc docs(p9-plan, SPL-5502): perf round 9 plan v0.5, ...
060a8cddc d6c1bee7a docs(p9-plan, SPL-5502): perf round 9 plan v0.4, ...
d6c1bee7a 89f8cef14 docs(p9-plan, SPL-5502): perf round 9 plan v0.3, ...
89f8cef14 8c19c9047 docs(p9-plan, SPL-5502): perf round 9 plan v0.2, ...
8c19c9047 e9ea1ef32 docs(p9-plan, SPL-5502): perf round 9 plan v0.1, ...
```

`89f8cef14` is in the chain, so the branch was not rewritten. The plan's own
section 9 (line 232) asks the claude seat for the "v0.5 head".

## 1. Slug p9 unused

```
git log origin/master --oneline -E --grep='\(p9-' | wc -l
git ls-remote origin 'refs/heads/*p9-*' | wc -l
```

Printed: `0` and `0`.

## 2. Sites at `1638ca3a7` and on origin/master

Every row file exists at both (`git cat-file -e <rev>:<file>` -> `ok ok` for
the seven files of rows 01-03, `hygiene-hidden-workspaces.tst.sh` included).

```
git diff --stat 1638ca3a7 origin/master -- <the seven files>
```

Printed: `.github/workflows/10_ci-quality.yml | 31 +++` only, one hunk
`@@ -1871,0 +1872,31 @@` (d6bcf4309, 92212bc75, SPL-5551). It lands after every
cited wf10 line, so no row site drifted. Re-read with
`git show <rev>:<file> | sed -n <N>p` at `1638ca3a7` and at `origin/master`,
identical text at both:

| cite | line |
|---|---|
| wf10 `:1708` | `sweep() { # <label> <pattern> [<allowed line regex> <what it allows>]` |
| wf10 `:1717` | `hits="$(grep -rnIoP "${excl[@]}" "$pattern" . \| cut -d: -f1,2 \| sort -u)" \|\| rc=$?` |
| wf10 `:1736` | `}` |
| wf10 `:1737`, `:1738`, `:1740`, `:1742`, `:1743` | the five `sweep "..."` calls (org, name, user, home, mail) |
| wf10 `:1769` | `LC_ALL="$gate_loc" sweep "hidden workspace or private literal (SPL-1874)" "$(paste -sd'\|' <<<"$pats")"` |
| wf10 `:1787` | `sweep "retired relay estate (SPL-1910)"`, its last alternative the box word `<w6>` bounded by `[^A-Za-z0-9_\x80-\xff]` before and the same class as a lookahead after |
| `spl-private-cnf.func.sh:145`, `:157`, `:169`, `:173` | comment head, `spl_private_gate_patterns() {`, the word-slug `printf`, `}` |
| `spl-private-cnf.tst.sh:83`, `:105` | `# --- 6. gate patterns`, `pass "6. a forms_only slug is never matched as the plain word"` |
| `sec-trufflehog.func.sh:64`, `:70`, `:78` | `do_sec_trufflehog() {`, `# --- control: ...`, `fi` |

Section 6 cites that drifted on origin/master (not row sites, N2):
`check-pre-push.func.sh:816` (the `./run` line of `_pp_part_commit_links`) is
`:832` on `a86e50da8`, and `_pp_wui_external` `:153` is `:160`
(`git show <rev>:csi-spl-iac/src/bash/run/check-pre-push.func.sh | grep -n`;
the file changed in d6bcf4309). `spl-commit-links-check.func.sh:42`, `:51`,
`:59`, `:141`, `:168` match on origin/master.

## 3. Row shape (3.1, 4.1, R1)

| row | sites | baseline cmd + number + n | test + red control | vendor / kind / batch |
|---|---|---|---|---|
| 01 | 2 (`:157-173`, comment `:145-156`) | `hwprobe.sh` A, 3,951 ms, n=10 | `spl-private-cnf.tst.sh` s6, count of `(?<![\p{L}\p{N}])` 1 vs one per slug | claude / simple_coding / 1 |
| 02 | 1 (`:64-78`) | `th-ab` A, 10,415 ms, n=7 | `sec-trufflehog.tst.sh`, 1 control call vs 2 | claude / simple_coding / 1 |
| 03 | 2 (`:1708-1736`, `:1769`) | `locprobe.sh` A, 5,375 ms, n=10 | `check-dist-hygiene.tst.sh`, 0 UTF-8 calls vs 6 | claude / simple_coding / 1 |

At most 5 sites each, no file in two rows (section 3.1 lists the six files,
one pair per row), no mistral row. The "same hits" claims: row 01's (79 hits
on the plant, 10 of 10) I did not re-run; row 03's I re-ran (section 4) and it
holds on the tree but not in general (W1).

## 4. Re-measure of row 03 (n=7)

My probe `locprobe-c076.sh` (in my scratchpad, not committed): the six
patterns and the `excl` array copied from wf10 on `a86e50da8` (`:1678-1680`,
`:1737-1787`), `/usr/bin/grep` = `grep (GNU grep) 3.11`, over
`git archive a86e50da8` (9,654 files, no plant), arm A `LC_ALL=C.UTF-8`, arm B
`LC_ALL=C`, ABAB/BABA, a per-sweep hit-set hash. Read-only, no prd call.

```
bash locprobe-c076.sh <export> 7
```

Printed (run, arm, ms, six hashes, total hits, load):

```
1 A 6332 68b31d142a9a68b38fb268b3 hits=19 load=43.37
1 B 3697 68b31d142a9a68b38fb268b3 hits=19 load=43.37
2 B 4209 68b31d142a9a68b38fb268b3 hits=19 load=42.14
2 A 6295 68b31d142a9a68b38fb268b3 hits=19 load=41.89
3 A 4965 68b31d142a9a68b38fb268b3 hits=19 load=41.98
3 B 3472 68b31d142a9a68b38fb268b3 hits=19 load=40.14
4 B 3937 68b31d142a9a68b38fb268b3 hits=19 load=40.21
4 A 4700 68b31d142a9a68b38fb268b3 hits=19 load=38.91
5 A 4716 68b31d142a9a68b38fb268b3 hits=19 load=38.84
5 B 3755 68b31d142a9a68b38fb268b3 hits=19 load=39.01
6 B 3975 68b31d142a9a68b38fb268b3 hits=19 load=39.01
6 A 4999 68b31d142a9a68b38fb268b3 hits=19 load=38.61
7 A 4928 68b31d142a9a68b38fb268b3 hits=19 load=37.28
7 B 3867 68b31d142a9a68b38fb268b3 hits=19 load=37.50
```

A **4,965 ms** (median, n=7; 4,700..6,332), B **3,867 ms** (median, n=7;
3,472..4,209), **-22%**, ranges do not overlap. The plan's -26% (n=10, load
50..56) agrees in direction and size. The six hit sets are identical on the
tree, 7 of 7.

## 5. Defects

**W1, row 03 (plan lines 91 and 151-157): the "six ASCII sweeps", "hit sets
identical" claim is not true in general; `LC_ALL=C` changes what two kinds of
line match.** The plan says the six patterns are ASCII and that C only skips
UTF-8 decoding (line 154). Two things differ under GNU grep 3.11 `-P`:

1. wf10 `:1787` is not an ASCII pattern in meaning: `[^A-Za-z0-9_\x80-\xff]` is
   code points U+0080..U+00FF under UTF-8 and bytes 0x80..0xFF under C. A
   letter above U+00FF (U+0161, U+03A9, U+043D) before `<w6>` is a boundary under UTF-8 and
   not under C.
2. `(?i)` folds Unicode case under UTF-8: U+017F (long s) matches `s`, so the
   `:1740` user word `<w3>` and the `:1738` surname `<w2>` written with U+017F
   for their `s` still hit; under C they do not.

Probe: six planted lines in a dir inside the export, the same `excl`, run once
per locale (P2, P3, P6 = wf10 `:1738`, `:1740`, `:1787`). The lines are, in
order: U+03A9, U+043D, U+0161 and U+00E4 each followed by `<w6>`; `<w3>` with
U+017F for its `s`; `<w2>` with U+017F for its `s`. The words are not written
here: this file passes the same sweeps.

```
printf '%s\n' <the six lines> > zz-c076-plant/edge.txt
LC_ALL=<loc> /usr/bin/grep -rnIoP "${excl[@]}" "<pattern>" ./zz-c076-plant | cut -d: -f1,2 | sort -u
```

Printed:

```
P2 [C.UTF-8] ./zz-c076-plant/edge.txt:6
P2 [C]
P3 [C.UTF-8] ./zz-c076-plant/edge.txt:5
P3 [C]
P6 [C.UTF-8] ./zz-c076-plant/edge.txt:1 ./zz-c076-plant/edge.txt:2 ./zz-c076-plant/edge.txt:3
P6 [C]
```

Under C the gate reports 0 of the 5 lines the UTF-8 gate reports. The plan's
12 planted lines (line 91) did not include a letter above U+00FF or a
case-fold letter, so its 10-of-10 identity does not cover these. The C result
for P6 may be what the `:1780-1786` comment wants (a letter before `<w6>` is no
boundary); the `ſ` cases are a narrowing (a fold variant the UTF-8 gate
catches stops being caught). Either way it is a behaviour change, not an
identity. Fix in the plan: row 03 says which lines change and its test plants
lines like these with the expected C result; or `:1787` keeps the gate locale
and only the five ASCII-literal sweeps move to C (then re-probe the gain).

**W2, row 02 (plan lines 90 and 145-150): the kept control is keyed on the
binary only, but the control proves the whole chain.** At `:73` the control
runs the binary with the part's flags and counts with `_sec_trufflehog_count`
(`:55-62`); the scan counts with the same function (`:93`). With the mark
keyed on the binary's sha256 and `_SEC_TRUFFLEHOG_VER`, a later edit that
breaks the count or the flags finds the mark, skips the control, and the scan
counts 0 and returns 0 (`:95-98`): the red control no longer fires. "A failed
control is never kept" does not cover this. Fix: the key also carries the
control's code (e.g. the blob sha of `sec-trufflehog.func.sh`), and the test
adds "a changed func file -> the control runs again".

## 6. Notes

- **N1** (row 02): `bin` defaults to the name `trufflehog` (`:65`), found by
  `command -v` (`:30`). The sha256 is of the resolved path; section 4 should
  say so.
- **N2** (section 6): `check-pre-push.func.sh:816` and `:153-175` were right
  at the plan sha and drifted on `a86e50da8` (to `:832`, `:160`). Re-cite at
  v1.0 or name the sha.
- **N3**: I did not re-measure rows 01 or 02 or re-run row 01's hit-set probe.
- **N4** (R3): lane map exit 4, section 7. Like the editor's read (line 115),
  not free: the R3 check before each spawn re-reads it.

## 7. R3 lane map

```
lane-map.sh --check csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh,csi-spl-iac/src/bash/tests/spl-private-cnf.tst.sh,csi-spl-iac/src/bash/run/sec-trufflehog.func.sh,csi-spl-iac/src/bash/tests/sec-trufflehog.tst.sh,.github/workflows/10_ci-quality.yml,csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh,csi-spl-doc/doc/md/perf-round-9/seat-claude.md --agent c-076
```

07:47:23Z-07:47:27Z, `EXIT=4`. 0 lines `owned by`. 15 `unknown:` lines, all on
the second fleet box: c-004, c-382, c-390, c-528, c-545, c-669, c-870, c-919,
c-920, c-924, c-927, c-928, c-934, c-936, g-902. Last line: `WARN no live lane
lists <the seven paths>, but 15 live lane(s) record no files: their scope is
unknown, not free`.

## 8. Dist hygiene

```
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `EXIT=0`, ending `INFO distribution-hygiene: clean over the tracked tree
of <this worktree>`, at `a86e50da8` before this file was added. The re-run with
this file staged is in the commit body.
