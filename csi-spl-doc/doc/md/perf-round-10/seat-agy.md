# Perf round 10: agy panel seat (a-225@PC)

Verdict: **PASS** on `4c321482b69c335f8a396e85355cb3eb44ff198b` (plan v1.1),
section 10 (`W1`–`W5` and `N1`–`N5` all verified fixed, zero open defects).
Section 9 is the v1.0 review; sections 0 to 8 are the v0.1 review:

Verdict: **FAIL** on `7cd0b3ef00bf9603bb044c6fb14818b88dc2ad12` (plan v1.0), one
defect (`W5` on row 01's foreground `.vibe/` order vs `EXIT`-only join and 3-site
count, section 9). `W2`–`W4` and `N1`–`N5` from v0.1 are verified fixed in v1.0,
and `W1`'s `CONTROL a` case passes, leaving only `W5` to fix in the plan text.
Sections 0 to 8 are the v0.1 review:

Verdict: **FAIL** on `1fae9045a4c5710debfcb0a93a6c2046ac19c117` (plan v0.1), four
defects (`W1`–`W3` on row 01, `W4` on section 3.1's `LONG` line range), all
fixable in the plan text before v1.0.

Panel: `a-225@PC` (agy, cross-vendor to editor `c-209@PC` claude; the panel's
other seat is grok on `review/c002-perf-round-10-grok-seat`). Issue: SPL-5619.
Epic: SPL-2402. Spec: `csi-spl-doc/specs/027-spool-performance`. Read on
2026-11-15, `origin/master` `5f46a4eac06b0aa0bdcf6054e1d9bf3b0f9cacba`.

## 0. The sha read

```text
git fetch origin review/c002-perf-round-10-planner && git rev-parse FETCH_HEAD
git rev-parse origin/master
git show --stat --oneline -s 1fae9045a4c5710debfcb0a93a6c2046ac19c117
```

Printed:

```text
1fae9045a4c5710debfcb0a93a6c2046ac19c117
5f46a4eac06b0aa0bdcf6054e1d9bf3b0f9cacba
1fae9045a docs(p10, SPL-5619): perf round 10 plan v0.1, 2 rows measured on 0d5d699d6
 csi-spl-doc/doc/md/perf-round-10-plan.md   | 232 +++++++++++++++++++++++++++++
 csi-spl-doc/doc/md/perf-round-10/editor.md | 205 +++++++++++++++++++++++++
 2 files changed, 437 insertions(+)
```

Ancestors and retro status cited in the plan header (`perf-round-10-plan.md:26-44`):

```text
for sha in bf4702451 c27701c45 0d5d699d6 fd3b0c647 f24802938 8a960d204 91cfe055b; do
  git merge-base --is-ancestor "$sha" origin/master && echo "$sha ancestor=yes"
done
git ls-tree -r --name-only origin/master | /usr/bin/grep -c perf-round-9-retro || true
```

Printed `ancestor=yes` for all seven shas and `0` for `perf-round-9-retro`.

## 1. Slug p10 unused

```text
git log origin/master --oneline -E --grep='\(p10-' | wc -l
git ls-remote origin 'refs/heads/*p10-*' | wc -l
git ls-tree -r --name-only origin/master | /usr/bin/grep -c perf-round-10 || true
```

Printed:

```text
0
0
0
```

## 2. Row sites at `0d5d699d6` and on `origin/master` (`5f46a4eac`)

Diff of the row files and `check-dist-hygiene.func.sh` from `0d5d699d6` to
`origin/master` (`5f46a4eac`, 8 commits ahead of `0d5d699d6`):

```text
git diff --stat 0d5d699d6 origin/master -- \
  .github/workflows/10_ci-quality.yml \
  csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh \
  csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh \
  csi-spl-iac/src/bash/run/check-dist-hygiene.func.sh
```

Printed nothing (0 lines changed), so **no row site drifted** between `0d5d699d6`
and `5f46a4eac`.

Every `file:line` cited in the plan checked with
`git show <rev>:<file> | sed -n '<N>p'` at both `0d5d699d6` and `5f46a4eac`
(sweep regex literals elided as `<pattern>` so this file carries none):

```text
git show 0d5d699d6:.github/workflows/10_ci-quality.yml | sed -n '1708p;1717p;1736p;1737p;1744p;1745p;1746p;1748p;1750p;1751p;1777p;1795p;1804p'
git show 0d5d699d6:csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh | nl -ba | sed -n '8,13p;25,30p;36,51p;89p;103p;121,125p'
git show 0d5d699d6:csi-spl-api/src/go/spool-hub-api/internal/repodocs/sync-hygiene.sh | sed -n '30p'
git show 0d5d699d6:csi-spl-api/src/go/spool-hub-api/internal/repodocs/drift_test.go | sed -n '17p'
git show 0d5d699d6:csi-spl-orc/src/bash/run/spl-release-note-bans-seed.func.sh | sed -n '75p'
git show 0d5d699d6:csi-spl-orc/src/bash/tests/blog-check.tst.sh | sed -n '46p'
```

Printed (identical at `0d5d699d6` and `5f46a4eac`):

| cite | what `git show <rev>:<file> \| sed -n` printed | match? |
|---|---|---|
| `wf10:1708` | `sweep() { # <label> <pattern> [<allowed line regex> <what it allows>]` | yes |
| `wf10:1717` | `hits="$(grep -rnIoP "${excl[@]}" "$pattern" . \| cut -d: -f1,2 \| sort -u)" \|\| rc=$?` | yes |
| `wf10:1736` | `}` (end of `sweep()`) | yes (`N1`: `:1737-1744` is `# SPL-5585 ... # CONTROL: ...`) |
| `wf10:1745,1746,1748,1750,1751` | the five `LC_ALL=C sweep "..." <pattern>` calls | yes |
| `wf10:1777` | `LC_ALL="$gate_loc" sweep "hidden workspace or private literal (SPL-1874)" "$(paste -sd'\|' <<<"$pats")"` | yes |
| `wf10:1795` | `sweep "retired relay estate (SPL-1910)"  <pattern>` | yes |
| `wf10:1804` | `vibe="$(find . -path ./.git -prune -o ! -type d -print \| sed ... \| grep -E ... \| sort)" \|\| true` | yes |
| `bash-cleancode.tst.sh:8-13` | `#          the vendored spec-kit scaffold, upstream code.` .. `#          Each LONG entry carries a ceiling (r5-06): ...` | **no (`W4`)**: `LONG` is `:25-30`, not `:8-13` |
| `bash-cleancode.tst.sh:25-30` | `LONG="` .. `"` (4 entries at `:26-29`) | actual `LONG` site |
| `bash-cleancode.tst.sh:36-41` | `# measure <file>... -> "<lines> <file> <function>" ...` | yes |
| `bash-cleancode.tst.sh:42-51` | `measure() {` .. `}` | yes |
| `bash-cleancode.tst.sh:89,103,121,125` | `all=$(measure "${files[@]}")`, `got=$(APP_ROOT="$T" measure "$T/x.sh" \| sed -n 1p)`, subshell `CONTROL`, `grown()` | yes |
| `sync-hygiene.sh:30` | `done < <(sed -nE "s/^[[:space:]]*(LC_ALL=C[[:space:]]+)?sweep[[:space:]]+\"([^\"]+)\"[[:space:]]+'([^']+)'.*/\2\t\3/p" "$wf")` | yes |
| `drift_test.go:17` | ``var sweepLineRe = regexp.MustCompile(`(?m)^[ \t]*(?:LC_ALL=C[ \t]+)?sweep[ \t]+"([^"]+)"[ \t]+'([^']+)'`)`` | yes |
| `spl-release-note-bans-seed.func.sh:75` | `pats="$(sed -nE "s/^[[:space:]]*(LC_ALL=C[[:space:]]+)?sweep[[:space:]]+\"[^\"]*\"[[:space:]]+'([^']+)'([[:space:]].*)?$/\2/p" <<<"$body")"` | yes |
| `blog-check.tst.sh:46` | `sed -nE "s/^(LC_ALL=C[[:space:]]+)?sweep \"personal name\"[[:space:]]+'\(\?i\)([a-z]+)\|.*/\2/p")` | yes |

## 3. Row shape, R1, vendor rule, probe backing, and R1/R3 overlap handling

| row | sites (cap 5) | baseline cmd + number + n | counting test + red control (4.1, C2) | vendor / kind / batch |
|---|---|---|---|---|
| 01 `p10-01` | 2 files (`wf10:1708-1744` + join before `:1804`; `check-dist-hygiene.tst.sh`) | `parab.sh` arm A (`editor.md:82-92`), **3,397 ms** median (`3,083..4,804`), `n=7` | `check-dist-hygiene.tst.sh` `grep` PATH shim (`>=2` in flight vs `1` on serial step) — see `W1`, `W2`, `W3` | `claude` / `simple_coding` / `1` |
| 02 `p10-02` | 1 file, 2 ranges (`bash-cleancode.tst.sh:42-51`, `:36-41`) | `bcc.sh` arm A (`editor.md:117-141`), `measure` **1,577 ms** (`n=15`), whole test **1,437 ms** (`n=7`) | `bash-cleancode.tst.sh` `awk` PATH shim (`1` call vs `3` over 3 files) + open-function EOF reset | `claude` / `simple_coding` / `1, after R3 (below)` |

- **Sites cap (<= 5):** met by both rows (2 and 2).
- **Disjoint files (R1):** met within p10 (`wf10` + `check-dist-hygiene.tst.sh` vs `bash-cleancode.tst.sh`, 0 shared files).
- **No mistral coding or testing rows:** met (`claude / simple_coding` for both rows, `grok` primary reviewer, `agy` or second `grok` backup, mistral code reviews kept paused: `perf-round-10-plan.md:19-20,94-95,171-184`).
- **"Output identical" probe backing:**
  - **Row 02:** backed by `editor.md:117-141` (`7,013 / 7,013` lines identical 15/15; whole test 13 `PASS` lines, rc 0, n=7) and confirmed independently in section 4 below (10/10 and 7/7 byte-for-byte identical).
  - **Row 01:** `editor.md:82-100` backs output identity on the private-overlay-present path (`7/7` clean sha `265131b1`; `1+2` 6-line plant sha `c52bfd09`), **but** does not cover the four non-`sweep` branches of the hidden-workspace block (`wf10:1770,1780,1783,1785`), where the proposed design reorders stdout (`W3`).
- **Does the plan handle `r58-08` and `c-244`?** Checked trunk status first:
  ```text
  git log origin/master --oneline -E --grep='\((r57|r58)-[0-9]{2}-'
  ```
  Printed `r57-01..04` and `r58-01..07` on `origin/master`; neither `r57-06` nor
  `r58-08` has landed, and `r58-08` (`refactor-round-32-plan.md:117`) still targets
  `bash-cleancode.tst.sh:27-29`.
  1. **Row 02 vs unlanded `r58-08` (`bash-cleancode.tst.sh`):** **Yes on serialisation, wrong on line numbers.** Sections 3.1 (`:102-107`), 3.2 (`:134-135`), and Row 02's batch cell (`:92`, `1, after R3 (below)`) serialise the shared file properly under R1/R3 (re-read `lane-map.sh` and the spawn queue before placing Row 02; place Row 02 only while `r58-08` is neither live nor queued, else wait for `r58-08` to land). Fix `:103-104`'s `:8-13` citation to `:25-30` (`W4`).
  2. **Row 01 vs live lane `c-244` (`c-244-c001-bug-prepush-commit-body-hygiene`):** **Yes in section 3.2, missing from Row 01's table/bullet.** `c-244` is still live as an `unknown:` lane on `sat` (section 7). Section 3.2 (`:123-126`) requires re-reading `lane-map.sh --check` and asking `c-244` (and any still-unknown lane) before Row 01 spawns; mirror Row 02's `1, after R3 (below)` in Row 01's batch cell so R4's verbatim row copy carries that guard (`N3`).

## 4. Re-measurement of Row 02 (`p10-02`, read-only, `n=10` and `n=7`)

Read-only probe on a `git archive 0d5d699d6` export (`1,200` walked `.sh` files,
`mawk 1.3.4 20250131`, interleaved AB on odd runs / BA on even runs, no prd
access). Arm A is `measure()` from `0d5d699d6:csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh:42-51`;
arm B is one `awk` with `(( $# )) || return 0` and
`FNR == 1 { n = ""; f = FILENAME; if (index(f, root) == 1) f = substr(f, length(root) + 1) }`:

```text
git archive 0d5d699d6 | tar -xf - -C <scratch>/exp0d5
bash <scratch>/bcc-probe.sh <scratch>/exp0d5 10 7
```

Printed:

```text
=== files=1200 ===
=== 1. measure() alone, n=10 interleaved ===
run 1 load=8.01 A=1734ms B=39ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
run 2 load=8.01 A=1549ms B=38ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
run 3 load=8.25 A=1558ms B=50ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
run 4 load=8.25 A=1558ms B=67ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
run 5 load=8.25 A=1422ms B=39ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
run 6 load=8.39 A=1766ms B=32ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
run 7 load=8.39 A=2169ms B=55ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
run 8 load=8.39 A=2192ms B=41ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
run 9 load=9.56 A=1819ms B=40ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
run 10 load=9.56 A=1465ms B=50ms lines=7013/7013 sha=f4bcadbd/f4bcadbd eq=yes
=== 2. whole bash-cleancode.tst.sh, n=7 interleaved ===
run 1 load=9.52 A=1696ms(rc=0,pass=13) B=239ms(rc=0,pass=13) eq=yes
run 2 load=9.52 A=1607ms(rc=0,pass=13) B=229ms(rc=0,pass=13) eq=yes
run 3 load=9.52 A=1504ms(rc=0,pass=13) B=221ms(rc=0,pass=13) eq=yes
run 4 load=9.39 A=1557ms(rc=0,pass=13) B=219ms(rc=0,pass=13) eq=yes
run 5 load=9.39 A=1466ms(rc=0,pass=13) B=203ms(rc=0,pass=13) eq=yes
run 6 load=9.39 A=1485ms(rc=0,pass=13) B=202ms(rc=0,pass=13) eq=yes
run 7 load=9.12 A=1448ms(rc=0,pass=13) B=181ms(rc=0,pass=13) eq=yes
```

- **`measure()` alone (`n=10`):** A median **1,646 ms** (`1,422..2,192`), B median
  **40.5 ms** (`32..67`), **-97.5%**, non-overlapping ranges, **7,013 lines
  byte-identical 10 of 10** (`sha256` `f4bcadbd`). Agrees with the plan's
  `1,577 ms -> 37 ms` (`n=15`).
- **Whole `bash-cleancode.tst.sh` (`n=7`):** A median **1,504 ms** (`1,448..1,696`),
  B median **219 ms** (`181..239`), **-85.4%**, `rc=0`, `13` `PASS:` lines,
  **output identical 7 of 7** (modulo probe filename). Agrees with the plan's
  `1,437 ms -> 173 ms, -88%` (`n=7`).

## 5. Defects

- **W1, row 01 (`perf-round-10-plan.md:91`, `:143-149`): the single join before
  `:1804` + `rm -rf "$d"` breaks `CONTROL a` of `check-dist-hygiene.tst.sh:118`
  (`rc_extra=0`, test fails).**
  `csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh:118` doctors `wf10` with
  `s|^exit "\$fail"$|sweep "control pattern" '$token'\nexit "$fail"|`, injecting a
  `sweep` call right before `exit "$fail"` (`wf10:1813`) — **after** `:1804` (the
  `.vibe/` check) and therefore after the join (`sweep_wait`) that lines `91` and
  `146-149` place before `:1804` and have delete `$d`. Note that placing a second
  `sweep_wait` above `exit "$fail"` still runs *before* `doctor`'s substitution on
  `^exit "$fail"$`. Probed by applying lines `143-149` to a scratch copy of `wf10`'s
  `Sweep` step and running `check-dist-hygiene.tst.sh` against it:
  ```text
  bash <scratch>/run-cdh.sh
  ```
  Printed:
  ```text
  FAIL: CONTROL a. the action did not follow the given workflow's patterns (real rc=0, doctored rc=0)
      | ...
      | /tmp/tmp.<id>/sweep.sh: line 67: /tmp/tmp.<id>/7.out: No such file or directory
  FAIL: 1 assertion(s) in check-dist-hygiene.tst.sh
  EXIT=1
  ```
  **Fix in the plan:** either include `check-dist-hygiene.tst.sh:118` (`CONTROL a`)
  in Row 01's edit so `doctor` inserts its control `sweep` before `sweep_wait` (e.g.
  before the retired-relay sweep at `:1795`), or join inside an `EXIT` trap before
  exiting with `$fail` so any `sweep` call anywhere in the step is awaited.

- **W2, row 01 (`perf-round-10-plan.md:144-149`): `mktemp -d` in the `Sweep` step
  without `HUP`/`INT`/`TERM`/`EXIT` cleanup leaks `$d` under `timeout` `SIGTERM`
  and turns `hygiene-killed-cleanup.tst.sh` red (CI workflow 10 + R9 `PRE_PUSH_TIER=full`).**
  `csi-spl-iac/src/bash/tests/hygiene-killed-cleanup.tst.sh:41-55` (slow tier, run
  by CI workflow 10 and by `PRE_PUSH_TIER=full`) sets `TMPDIR="$tmp"`, kills
  `timeout` around `hygiene-owner-email-allow.tst.sh`,
  `hygiene-box-users-allow.tst.sh`, and `hygiene-retired-relay.tst.sh` once the
  first `grep` starts, and fails if anything remains in `$tmp`. Each test's
  `tmp_dir` (`csi-spl-iac/src/bash/tests/test-lib.inc.sh:44-48`) removes only its
  own `$T`, not sibling dirs in `$TMPDIR`. With `$d` removed only inside
  `sweep_wait` (`:149`), `SIGTERM` kills `bash "$T/sweep.sh"` while blocked in
  `wait` and strands `$d` in `$tmp`. Probed with the same `grep` sleep stub and
  `timeout -k 2 2` on `hygiene-retired-relay.tst.sh`:
  ```text
  PATH="$T/bin:$PATH" TMPDIR="$tmp" KT_TMP="$tmp" KT_MARK="$mark" \
    timeout -k 2 2 bash <scratch>/hygiene-retired-relay.tst.sh
  ```
  Printed without traps vs with `trap 'rm -rf "$sweep_dir"' EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM`:
  ```text
  mark exists: yes, rc=124
  LEAK: 8 inodes, tmp.<id> tmp.<id>/6.out tmp.<id>/5.out tmp.<id>/4.out tmp.<id>/3.out tmp.<id>/2.out tmp.<id>/1.out
  --- with traps ---
  mark=yes rc=124 left=''
  ```
  **Fix in the plan:** specify `EXIT` + `HUP INT TERM` traps cleaning `$d` in the
  `Sweep` step (matching `test-lib.inc.sh:46-47`) and list
  `hygiene-killed-cleanup.tst.sh` in Row 01's tests.

- **W3, row 01 (`perf-round-10-plan.md:91`, `:150-152`, `editor.md:79-100`): stdout
  order is NOT preserved when `wf10:1769-1786` takes a non-`sweep` branch, and the
  `grep` shim spec (`:91`) either races `:1767-1776` on a small fixture tree or
  leaves late sweeps unverified.**
  1. **Output order:** `wf10:1770`, `:1780`, `:1783`, and `:1785` (`::warning::hygiene: hidden workspaces NOT swept` — every CI pull request, `11_ci-public.yml`, `oss_gate_hygiene` without overlay, and `check-dist-hygiene.tst.sh` cases 1–4) `echo` in the parent shell without calling `sweep()`. When sweeps 1–5 buffer in `$d/1..5.out` until `:1804`, those lines print **before sweep 1** instead of between sweep 5 (`:1751`) and sweep 7 (`:1795`) — observed directly in `W1`'s run (`::warning::hygiene: hidden workspaces NOT swept` printed above `ok - non-Csitea org or bank reference`). Either route `:1770,1780,1783,1785` into a numbered slot in `$d` so all paths keep `wf10` order, or state the order change and verify `oss_gate_hygiene` (`csi-spl-orc/src/bash/run/oss-gate.func.sh:104-118`, `oss-export-gate.tst.sh`).
  2. **Counting-test shim (`:91`):** waiting *"until a second recursive call has begun: the seven sweeps -> 2 or more calls in flight and no call that timed out alone"* is ambiguous and racy on `$T/loc` (4 tiny files, ~2 ms per `grep`) because `:1767-1776` runs `source`, `sed`, `spl_private_gate_locale`, and `spl_private_gate_patterns` (`yq`, ~50–150 ms) in the parent shell between sweeps 1–5 (`:1745-1751`) and sweeps 6–7 (`:1777`, `:1795`). If the shim checks *currently in flight >= 2*, sweeps 1–5 can exit before `:1777`/`:1795` fork (and without an overlay `:1795` arrives alone and times out); if it checks *total begun >= 2*, sweeps 1–2 satisfy it forever so `:1777` and `:1795` would pass even if left serial. **Fix:** on `$T/loc` (with `$T/overlay.yaml`, all 7 sweeps active), hold each recursive `grep` at a bounded barrier until all **7** recursive calls have entered (`7` in flight, `0` timeouts; red control on serial step: `1` in flight). Note also that `wait_event` lives in `csi-spl-orc/src/bash/tests/wait-event.inc.sh:17`, not `csi-spl-iac`, so the executable `$T/shim/grep` must source it or inline the bounded loop.

- **W4, section 3.1 (`perf-round-10-plan.md:103-104`): wrong line range for `LONG`
  in `bash-cleancode.tst.sh` (`:8-13` instead of `:25-30`).**
  Lines `103-104` cite `LONG` at `:8-13` twice; in `bash-cleancode.tst.sh` (both
  `0d5d699d6` and `5f46a4eac`), `:8-13` is the `# Purpose:` comment and `LONG` is
  `:25-30` (`r58-08` in `refactor-round-32-plan.md:117` cites `:27-29`). Still
  disjoint from `measure()` (`:42-51`) and its comment (`:36-41`).

## 6. Notes

- **N1 (row 01 sites/comment, `:91`, `:150`):** `wf10:1708-1744` covers `sweep()`
  (`:1708-1736`) plus the `# SPL-5585` comment (`:1737-1744`). At `:1702-1707` right
  above `sweep()` sits `allowed()` with no comment between them, so `:150` ("The
  comment above `sweep()`") adds a new comment above `:1708` (or updates
  `:1737-1744`).
- **N2 (row 01 test column for R2 / R7 C4, `:91`, `:154-155`):**
  `spl-release-note-bans-seed.func.sh:75` is an action file; name its runnable test
  `csi-spl-orc/src/bash/tests/release-note-bans-seed.tst.sh` (alongside
  `bash csi-spl-api/src/go/spool-hub-api/internal/repodocs/sync-hygiene.sh --check`,
  `go test -count=1 ./internal/repodocs/`, and `csi-spl-orc/src/bash/tests/oss-export-gate.tst.sh`
  for `oss_gate_hygiene`) so the row lane and R7 reviewer have an unambiguous C4
  `ran:` list.
- **N3 (row 01 batch cell & R4, `:91`, `:123-124`):** mark Row 01's batch cell
  `1, after R3 (below)` (matching Row 02's `:92`) or mention `c-244` in section 4's
  `01` bullet so a verbatim R4 row brief carries the `c-244` pre-spawn check.
- **N4 (row 02 `mawk` details, `:158-160`):** `/usr/bin/awk` here is
  `mawk 1.3.4 20250131`. Guard zero args (`(( $# )) || return 0` so `measure` with
  no files never reads stdin), place `FNR == 1` before the function-header rule so a
  line-1 function does not have `n` wiped, and strip `root` with literal `index()` /
  `substr()` rather than `sub("^" root, ...)` (`mktemp -d` paths in `$T` contain `.`).
- **N5 (trunk movement to `5f46a4eac`):** `e62583e01` (`SPL-5620`, noted in progress
  at `perf-round-10-plan.md:191`, `editor.md:203-205`) has now landed on
  `origin/master`; `bash-cleancode.tst.sh` on `5f46a4eac` walks `7,018` functions in
  `1,200` files (`git archive origin/master` check: `PASS: the walk measured 7018 functions in 1200 files`).

## 7. R3 lane-map check

```text
bash csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh \
  --check .github/workflows/10_ci-quality.yml,csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh,csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh,csi-spl-doc/doc/md/perf-round-10/seat-agy.md \
  --agent a-225
```

Printed (18:52:57Z): `EXIT=4`, `0` lines `owned by` (no owning lanes), and `8`
`unknown:` lanes on `sat`: `c-170`, `c-193`, `c-197`, `c-203`, `c-241`,
`c-244` (`c-244-c001-bug-prepush-commit-body-hygiene`), `c-664`, `c-762`, ending:
`WARN no live lane lists <the four paths>, but 8 live lane(s) record no files: their scope is unknown, not free`.

## 8. Distribution hygiene

On an archive of `1fae9045a4c5710debfcb0a93a6c2046ac19c117` and on `<this worktree>`
with `csi-spl-doc/doc/md/perf-round-10/seat-agy.md` staged:

```text
cd csi-spl-iac && ./run -a do_check_dist_hygiene
```

Printed `EXIT=0`, all 7 sweeps `ok` + `ok - no tracked .vibe/ dir`, ending
`INFO distribution-hygiene: clean over the tracked tree of <this worktree>`.

## 9. v1.0 delta review (`7cd0b3ef00bf9603bb044c6fb14818b88dc2ad12`)

```text
git fetch origin master review/c002-perf-round-10-planner
git rev-parse origin/review/c002-perf-round-10-planner origin/master
git log --oneline --stat 1fae9045a4c5710debfcb0a93a6c2046ac19c117..7cd0b3ef00bf9603bb044c6fb14818b88dc2ad12
git diff --stat 0d5d699d6 origin/master -- \
  .github/workflows/10_ci-quality.yml \
  csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh \
  csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh \
  csi-spl-iac/src/bash/run/check-dist-hygiene.func.sh
```

Printed:

```text
7cd0b3ef00bf9603bb044c6fb14818b88dc2ad12
83cb219456a64f358f20ec35aee58030c7cc9ac0
7cd0b3ef0 docs(p10, SPL-5619): perf round 10 plan v1.0, a-225 W1-W4 and both seats' notes folded
 csi-spl-doc/doc/md/perf-round-10-plan.md   | 93 +++++++++++++++++++++---------
 csi-spl-doc/doc/md/perf-round-10/editor.md |  4 +-
 2 files changed, 70 insertions(+), 27 deletions(-)
```

and empty diff on the four files (`0` lines drifted on `83cb21945`).

All newly cited `file:line` references in `7cd0b3ef0` checked on `0d5d699d6` and
`83cb21945` with `git show <rev>:<file> | sed -n '<N>p'`:
- `wf10:1681` -> `fail=0` (match)
- `wf10:1702,1707` -> `allowed() { ... }` (match)
- `wf10:1769,1770,1780,1783,1785,1786` -> hidden-workspace `if` and its four `echo` branches (match)
- `wf10:1813` -> `exit "$fail"` (match)
- `check-dist-hygiene.tst.sh:118` -> `doctor "s|^exit \"\\\$fail\"\$|sweep \"control pattern\" '$token'\nexit \"\$fail\"|" "$T/wf-extra.yml"` (match)
- `hygiene-killed-cleanup.tst.sh:41,55` -> `kill_once()` timeout invocation and `$tmp` leak check (match)
- `oss-gate.func.sh:104,118` -> `while IFS= read -r line; do` .. `fi` Sweep output parser (match)
- `csi-spl-orc/src/bash/tests/wait-event.inc.sh:17` -> `wait_event() {` (match)

Distribution hygiene on an archive export of `7cd0b3ef00bf9603bb044c6fb14818b88dc2ad12`:

```text
git archive 7cd0b3ef00bf9603bb044c6fb14818b88dc2ad12 | tar -xf - -C "$td"
git -C "$td" init -q && git -C "$td" add .
(cd csi-spl-iac && HYGIENE_TREE="$td" ./run -a do_check_dist_hygiene)
```

Printed `ARCHIVE_HYGIENE_EXIT=0` (all 7 sweeps `ok` + `ok - no tracked .vibe/ dir`).

### v0.1 findings verified fixed in `7cd0b3ef0`

- **W2 fixed:** `:91` and `:163-167` specify `HUP` / `INT` / `TERM` + `EXIT`
  traps cleaning `$d` and list `hygiene-killed-cleanup.tst.sh` (`:41-55`) in Row 01's
  test column.
- **W3.1 and W3.2 fixed:** `:91` and `:149-154` route `:1770,1780,1783,1785` to
  numbered slots and add `oss-export-gate.tst.sh` (`oss-gate.func.sh:104-118`) to the
  test column; `:91` specifies a 7-way barrier over `$T/loc` with `$T/overlay.yaml`
  (`7` in flight, `0` timeouts vs `1` on serial red control) and cites
  `csi-spl-orc/src/bash/tests/wait-event.inc.sh:17`.
- **W4, N1–N5 fixed:** `:103-104` cites `LONG` at `bash-cleancode.tst.sh:25-30`;
  `:91` narrows `sweep()` to `wf10:1708-1736` with `allowed()` `:1702-1707`
  unchanged; `:91` names runnable tests (`sync-hygiene.sh --check`,
  `go test -count=1 ./internal/repodocs/`, `release-note-bans-seed.tst.sh`,
  `blog-check.tst.sh`, `oss-export-gate.tst.sh`); `:91` and `:175-177` carry the
  `c-244@sat` pre-spawn check; `:178-185` adds `(( $# )) || return 0`, `FNR == 1`
  first, and literal `index()`/`substr()` under `mawk 1.3.4`; `:213` records
  `e62583e01` landed (`g-223` `N3` also folded in `editor.md:99-102`).

### Defect remaining in `7cd0b3ef0`

- **W5, row 01 (`perf-round-10-plan.md:91`, `:154-166`, `:173-174`): keeping
  `.vibe/` (`:1804-1812`) unslotted in the foreground while running the join only
  in the `EXIT` trap prints `.vibe/` BEFORE sweep 1 instead of last, contradicting
  `:154-155` and breaking `parab.sh` output identity (`:91`, `:173-174`) unless a
  4th `wf10` edit site is listed.**
  Lines `154-155` state *"The `.vibe/` check after `:1795` stays in the foreground
  and prints after the slots, as today"*, lines `157-159` state *"The EXIT trap is
  the join: `wait` for the sweep jobs, print every slot in order..."*, and line `91`
  lists only `3 edit ranges` (`:1681`, `:1708-1736`, `:1769-1786`), leaving `:1804`
  untouched. In bash (`GNU bash 5.2`), `:1804-1812` runs **before** `exit "$fail"`
  (`:1813`) fires `EXIT`, so `ok - no tracked .vibe/ dir` prints on **line 1**
  above sweep 1 rather than on the last line after sweep 7; if the row lane adds a
  4th edit site at `:1804` to fix the order, R7 **C1** fails against `:91`'s
  `3 edit ranges` (R4 copies `:91` verbatim). Tested both variants on `wf10` from
  `0d5d699d6` (n=1 each, plus full `check-dist-hygiene.tst.sh`):
  ```text
  python3 <scratch>/test-v10.py
  ```
  Printed:
  ```text
  === literal_3_ranges stdout (rc=0) ===
  ok - no tracked .vibe/ dir
  ok - non-Csitea org or bank reference
  ok - personal name
  ok - literal OS user / box / AD id
  ok - personal home directory
  ok - owner mail address or domain
  ::warning::hygiene: hidden workspaces NOT swept -- no private overlay or no ./csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh (SPL-1874)
  ok - retired relay estate (SPL-1910)
  === literal_3_ranges check-dist-hygiene.tst.sh rc=0 ===
     PASS: all check-dist-hygiene.tst.sh assertions
  === with_4th_range_before_1804 stdout (rc=0) ===
  ok - non-Csitea org or bank reference
  ok - personal name
  ok - literal OS user / box / AD id
  ok - personal home directory
  ok - owner mail address or domain
  ::warning::hygiene: hidden workspaces NOT swept -- no private overlay or no ./csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh (SPL-1874)
  ok - retired relay estate (SPL-1910)
  ok - no tracked .vibe/ dir
  === with_4th_range_before_1804 check-dist-hygiene.tst.sh rc=0 ===
     PASS: all check-dist-hygiene.tst.sh assertions
  ```
  Also note on `:158-166`: when `HUP` / `INT` / `TERM` triggers `exit 129` / `130` /
  `143`, the killed sweeps have missing `.rc` files, so the `EXIT` trap must skip
  `sweep_join` / the missing-`.rc` -> `exit 1` fold on signal exit (e.g. a
  `sweep_killed=1` flag in the signal traps) and only `rm -rf "$d"; exit "$st"`,
  preserving `129`/`130`/`143` (`hygiene-killed-cleanup.tst.sh:51`).
  **Fix in the plan (3 lines):** add the 4th `wf10` edit site (`4 <= 5`) to `:91`
  and `:154-166` — either call `sweep_join` once right before `:1804` (flushing
  slots `1..N` without removing `$d`) AND again in `EXIT` (flushing any slot added
  above `exit "$fail"` by `CONTROL a`, then `rm -rf "$d"`), OR write `:1804-1812`'s
  `echo` lines to a slot too — and specify that `EXIT` skips the join/verdict fold
  when exiting on `HUP`/`INT`/`TERM`.

## 10. v1.1 re-sign (`4c321482b69c335f8a396e85355cb3eb44ff198b`)

Verdict: **PASS** on `4c321482b69c335f8a396e85355cb3eb44ff198b` (plan v1.1).

```text
git fetch origin master review/c002-perf-round-10-planner
git rev-parse origin/review/c002-perf-round-10-planner origin/master
git log --oneline --stat 7cd0b3ef00bf9603bb044c6fb14818b88dc2ad12..4c321482b69c335f8a396e85355cb3eb44ff198b
git diff --stat 0d5d699d6 origin/master -- \
  .github/workflows/10_ci-quality.yml \
  csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh \
  csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh \
  csi-spl-iac/src/bash/run/check-dist-hygiene.func.sh
```

Printed:

```text
4c321482b69c335f8a396e85355cb3eb44ff198b
01906d740c58432c0e576ff5b8a8f8636b09fb97
4c321482b docs(p10, SPL-5619): perf round 10 plan v1.1, a-225 W5 folded
 csi-spl-doc/doc/md/perf-round-10-plan.md | 40 +++++++++++++++++++++-----------
 1 file changed, 27 insertions(+), 13 deletions(-)
```

and empty diff on the four files (`0` lines drifted on `01906d740`).

Newly cited lines in `4c321482b` checked on `0d5d699d6` and `01906d740` with
`git show <rev>:<file> | sed -n '<N>p'`:
- `wf10:1804,1812` -> `vibe="$(find . -path ./.git -prune ...)" || true` .. `fi` (match)
- `hygiene-killed-cleanup.tst.sh:51` -> `if [[ $rc -ne 124 && $rc -ne 143 ]]; then echo "rc=$rc, not stopped by the TERM"; return; fi` (match)

Distribution hygiene on an archive export of `4c321482b69c335f8a396e85355cb3eb44ff198b`:

```text
git archive 4c321482b69c335f8a396e85355cb3eb44ff198b | tar -xf - -C "$td"
git -C "$td" init -q && git -C "$td" add .
(cd csi-spl-iac && HYGIENE_TREE="$td" ./run -a do_check_dist_hygiene)
```

Printed `ARCHIVE_HYGIENE_EXIT=0` (all 7 sweeps `ok` + `ok - no tracked .vibe/ dir`).

- **W5 verified fixed (`perf-round-10-plan.md:91`, `:154-172`):** `:91` lists the
  4th `wf10` edit site (`sweep_join` right before `:1804`, `4 <= 5` sites);
  `sweep_join` is idempotent and runs both before `:1804` (keeping `.vibe/` last,
  matching `with_4th_range_before_1804` in section 9 above where all
  `check-dist-hygiene.tst.sh` assertions pass with `rc=0`) and in `EXIT` (joining
  `CONTROL a`'s doctored `sweep` above `exit "$fail"` and removing `$d`); and on
  `HUP`/`INT`/`TERM` a flag (`sweep_killed=1`) makes `EXIT` skip `sweep_join` and
  the verdict fold, preserving `129`/`130`/`143` (`hygiene-killed-cleanup.tst.sh:51`).
- No remaining defects or open notes.
