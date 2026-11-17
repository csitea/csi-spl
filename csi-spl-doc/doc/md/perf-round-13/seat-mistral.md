# Perf round 13: mistral panel seat

Seat: **m-909@sat** (mistral), ask 9c0a6cef, placed by c-001@sat
(2026-11-17T07:50:51Z, task `dispatch-perf-r13`, "placed: m-909@sat").
Issue SPL-5774, epic SPL-2402, spec `csi-spl-doc/specs/027-spool-performance`.
Brief: `/var/spool-hub/dispatch/briefs/c002-perf-round-13-mistral-panel-seat.md`.

**Reviewed shas** on `review/c001-perf-round-13-planner`, each named by
c-882@sat on task `dispatch-perf-r13`:

- v0.2 `1774838a26c81095c5cc23aeba786ddd1883967b` (c-882 result
  2026-11-17T07:46:21Z) -> **FAIL**, one defect W1, fixed in v0.3.
- v0.3 `d4e8e8572b6d1fecf695462169b27cfb30afe33a` (c-882 result
  2026-11-17T08:05:57Z) -> **PASS**, re-review below.

My fetch agrees for both:

- `git fetch origin review/c001-perf-round-13-planner && git rev-parse FETCH_HEAD`
  -> `d4e8e8572b6d1fecf695462169b27cfb30afe33a` (v0.2 read earlier at
  `1774838a26c81095c5cc23aeba786ddd1883967b`)
- `git ls-remote origin refs/heads/review/c001-perf-round-13-planner`
  -> `d4e8e8572b6d1fecf695462169b27cfb30afe33a`

Files read at each sha (via `git show <sha>:<file>`):
`csi-spl-doc/doc/md/perf-round-13-plan.md`,
`csi-spl-doc/doc/md/perf-round-13/editor.md`. Rulebook read on
`origin/master` (`d8f6beb59` at first read, `01de192fbd` at the v0.3
re-review): `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1-4. Every
file:line cited below was checked with `git show <sha>:<file> | sed -n <N>p`
first.

## Verdict: FAIL on 1774838a2 (v0.2); PASS on d4e8e8572b6d1fecf695462169b27cfb30afe33a (v0.3)

v0.2 carried one defect (W1, below), folded into v0.3. The v0.3 re-review
finds W1 fixed and all checks green; this seat signs v0.3. The v0.2 checks
are kept below as the record, then the v0.3 delta.

## Checks

### 1. Slug p13 unused

- `git log origin/master --oneline -E --grep='\(p13-' | wc -l` -> `0`
- `git ls-remote origin 'refs/heads/*p13-*' | wc -l` -> `0`
- `git ls-tree -r --name-only origin/master | grep -c perf-round-13` -> `0`

### 2. Each row's sites exist at the plan sha and still on origin/master

Row 01 (plan line 101) sites, `git show 1774838a2:<file> | sed -n <N>p`:

- `csi-spl-iac/src/bash/run/check-pre-push.func.sh:1112` -> `  # Pre-existing on trunk? Re-run the SAME part against the base ref.`
- `:1120` -> `    # a TIMED OUT tree's signature is cut: its base run is not narrowed`
- `:1131` -> `    _pp_timed_out "$label" "$part" "$el" "$note" "$base" "$bsha" "$brc" "$bwt"; return 0`
- `:1142` -> `# A part that TIMED OUT on the tree is refused, never blamed on the lane`
- `:1149` -> `_pp_timed_out() {  # <label> <part> <secs> <note> <base> <bsha> <base-rc> <base-wt>`
- `:1159` -> `}`
- `csi-spl-doc/doc/md/pre-push-gate.md:255` -> `A part that TIMED OUT (rc 124 or 137) on your tree is never compared by`
- `:262` -> `2026-11-14) read `WARN-pre-existing` once and `new=1` 20 min later (n=2).`

Row 02 (plan line 102) sites, same command:

- `csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh:102` -> `  case "$sc" in`
- `:109` -> `    lint-tmp-path)   own=(csi-spl-iac/src/bash/scripts/tmp-path-lint.py .tmp-path-baseline.txt) ;;`
- `:158` -> `      lint-gosec)      [[ "$f" == *.go || "$f" == */go.mod || "$f" == */go.sum ]] && { echo ALL; return 0; } ;;`
- `:443` -> `    lint-gosec)      SEC_GOSEC_ROOT="$tree" do_sec_gosec || rc=$? ;;`
- `csi-spl-iac/src/bash/run/sec-gosec.func.sh:1` -> `#!/usr/bin/env bash`
- `:17` -> `# @example ./run -a do_sec_gosec`
- `:117` -> `  ( cd "$mod" && SEC_GOSEC_PHASE=scan "$bin" -fmt=json -quiet -severity high ./... ) >"$out" 2>/dev/null || true`
- `:118` -> `  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null; then`
- `:122` -> `  fi`
- `:124` -> `  local counts; counts=$(mktemp)`
- `:137` -> `    _sec_baseline_gate "gosec high-severity" "$counts" "$baseline" || rc=1`

All of the above lines print identically at `origin/master` (`d55657565`).
Drift: `git log --oneline 1774838a2..origin/master -- csi-spl-iac/src/bash/run/check-pre-push.func.sh csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh csi-spl-iac/src/bash/run/sec-gosec.func.sh csi-spl-doc/doc/md/pre-push-gate.md csi-spl-iac/src/bash/tests/`
-> 0 lines. **No site drifted.**

Named test files exist at the plan sha:
`git ls-tree --name-only 1774838a2 csi-spl-iac/src/bash/tests/ | grep -E 'check-pre-push-timeout-red-trunk|sec-gosec.tst|check-pre-push-lint.tst|...'`
-> 16 files, including `check-pre-push-timeout-red-trunk.tst.sh`,
`sec-gosec.tst.sh`, `check-pre-push-lint.tst.sh` and the 13 "also run and
green" files the rows name. The timeout test's header (lines 1-20 at the
sha) lists cases a-e plus controls f, g, as the plan claims.

### 3. Row shape (rulebook 3.1, 4.1; R1, R3)

- **At most 5 sites per row:** row 01 lists 3 file:line sites and says
  "3 edit ranges" (plan line 101) - consistent, within the cap. Row 02
  lists **7** file:line sites (plan line 102) - see W1.
- **Baseline with command + number + n:** row 01: the awk command, n=2,
  1,011 s and 2,708 s (plan line 101, editor.md section 2.2 lines 62-82).
  Row 02: the log count n=44, 628..1,696 s, mean 1,039 s, plus the probe
  n=2 per arm (plan line 102, editor.md section 2.3 lines 83-124). Both
  measured on one sha, `9310612f3` (`git log -1 --format='%H %cI' 9310612f3`
  -> `9310612f3c8a8f23630c67830255d13697eb3e10 2026-11-17T07:57:13+02:00`;
  `git merge-base --is-ancestor 9310612f3 origin/master` -> 0).
- **Counting test with a red control (4.1, C2):** row 01 names a new case in
  `check-pre-push-timeout-red-trunk.tst.sh` (stub part exits 124 -> called
  once, no base worktree, FAIL with `trunk=not-checked timed-out-not-compared`;
  red: today's `_pp_run` -> 2 calls). Row 02 names cases a-d in
  `sec-gosec.tst.sh` and selection cases in `check-pre-push-lint.tst.sh`,
  with the red stated (today: `./...`, `ALL`, baseline-only change selects
  nothing). Both rows list the "also run and green" files.
- **Vendor, kind, batch:** both rows `claude / simple_coding`, batches 1 and
  2 (plan lines 101-102). **No mistral coding or testing row.**
- **R1 (no file in two rows of one batch):** batch 1 = row 01
  (`check-pre-push.func.sh`, `check-pre-push-timeout-red-trunk.tst.sh`,
  `pre-push-gate.md`); batch 2 = row 02 (`check-pre-push-lint.func.sh`,
  `sec-gosec.func.sh`, `sec-gosec.tst.sh`, `check-pre-push-lint.tst.sh`,
  `pre-push-gate.md`), plan section 3.1 lines 108-112. The shared
  `pre-push-gate.md` sits in different batches, which R1 allows (serialised
  across batches).
- **Verdict-stays-the-same claims backed by probe output:** row 01's claim
  (verdict FAIL whatever trunk does) is backed by the two log lines, which I
  re-ran myself in check 4 - identical, both FAIL. Row 02 claims no verdict
  change; its saving is marked "suggested, not proven" and the row's lane
  re-times it (plan line 102, section 4).
- **R3 handling of queued/live lanes on the same files:** plan section 3.2
  (lines 115-146) documents the lane map, the spawn queue and unlanded round
  rows, each with its read time, and says the R3 check re-reads the map before
  each spawn. My own re-run in check 5 confirms no live lane owns a row file.

### 4. Re-measure one row myself (read-only, no prd write)

Row 02's baseline, n>=3, on the push user's pre-push log
(`~/.cache/csi-spl/pre-push.log` of the push user, read via sudo):

- `sudo awk '$1>="2026-11-15T12:45:06Z" && $3=="PART" && $4=="lint-gosec" && $5=="PASS" {s=$6; sub(/s$/,"",s); s+=0; n++; t+=s; if(n==1){min=s;max=s} if(s<min)min=s; if(s>max)max=s} END{printf "n=%d sum=%d mean=%.1f min=%d max=%d\n", n, t, t/n, min, max}' ~/.cache/csi-spl/pre-push.log`
  -> `n=46 sum=48593 mean=1056.4 min=628 max=1696`
- verdicts since then: `... | awk '{print $5}' | sort | uniq -c`
  -> `46 PASS`, `1 PASS-cached`

The plan read n=44, 628..1,696 s, mean 1,039 s at 06:2xZ (editor.md 2.1). My
min/max are identical (628..1,696 s); n grew 44 -> 46 because two more PASS
runs landed after the editor's read; every run is PASS. **My number and the
verdict agree.**

Row 01's baseline, re-run:

- `sudo awk '$1>="2026-11-15T12:45:06Z" && /TIMED OUT after/' ~/.cache/csi-spl/pre-push.log`
  -> n=2, the identical two lines the editor quoted (user field elided here):
  `2026-11-16T05:31:00Z <push-user> PART wui-e2e FAIL 2881s ... TIMED OUT after 1870s ... trunk=0a6e9d22e-green timed-out-not-compared`
  and
  `2026-11-16T06:30:10Z <push-user> PART api FAIL 5408s ... TIMED OUT after 2700s ... trunk=77154caf0-red timed-out-not-compared`
  - both FAIL. n=2 is the whole population since `1d7bae644`
  (2026-11-15T12:45:06Z), not a sample. **Agrees.**
- 7-day window cross-check of editor 2.2's context number:
  `sudo awk '$1>="2026-11-10T06:20" && $1<="2026-11-17T06:20" && /TIMED OUT after/ { split($0, a, "TIMED OUT after "); b=a[2]; sub(/s.*/,"",b); b+=0; s=$6; sub(/s$/,"",s); s+=0; if (s > b) { n++; t += (s-b) } } END{printf "n=%d excess_sum=%d\n", n+0, t+0}' ~/.cache/csi-spl/pre-push.log`
  -> `n=466 excess_sum=358438`, exactly the editor's n=466, 358,438 s.

Plan claims re-verified: rulebook 4.4 command on `9310612f3`
(`git log 9310612f3 --since='14 days ago' --format=%s | grep -oE ... | awk ...`)
-> `perf 18 refactor 101 perf-share 15.1% under-20`, exactly the plan's line.
`git merge-base --is-ancestor d5f6f6887 origin/master` -> 0 and same for
`a68a97b96` (p12-01, p12-02 on master).
`git ls-tree -r --name-only origin/master | grep -cE 'perf-round-12-retro'`
-> `0`. `git diff --stat 457116142 9310612f3 -- csi-spl-iac/src/bash/run/check-pre-push.func.sh`
-> empty, as editor.md section 1 claims.

### 5. R3 lane map (my own read)

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-iac/src/bash/run/check-pre-push.func.sh,csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh,csi-spl-iac/src/bash/run/sec-gosec.func.sh,csi-spl-iac/src/bash/tests/check-pre-push-timeout-red-trunk.tst.sh,csi-spl-iac/src/bash/tests/sec-gosec.tst.sh,csi-spl-iac/src/bash/tests/check-pre-push-lint.tst.sh,csi-spl-doc/doc/md/pre-push-gate.md --agent m-909`
  -> **exit 4**: 0 `owned by` lines, 15 `unknown:` lines, all on the second fleet box
  (c-382, c-390, c-528, c-545, c-570, c-669, c-714, c-875, c-888, c-889,
  c-924, c-927, c-928, c-960, c-966 - rotation seats, a blog draft, the
  transport drop, cost allocation, issue notes, an agy memory gap, release
  projects). **None names a pre-push or gosec file.**
- Same check plus `csi-spl-doc/doc/md/perf-round-13-plan.md` and this seat
  file -> **exit 3**: `csi-spl-doc/doc/md/perf-round-13-plan.md owned by c-882@sat c-882-c001-perf-round-13-planner`
  - the planner's own lane owning the plan file, expected; no row code file
  is owned by any live lane.

### 6. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene`
  -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-909`, exit 0.

## Defects

- **W1** - plan line 102 (row 02 sites cell): the cell lists **7** file:line
  sites - `check-pre-push-lint.func.sh:102-109`, `:158`, `:443`;
  `sec-gosec.func.sh:1-17`, `:117`, `:124-137`; `pre-push-gate.md` - against
  rulebook 3.1's "file:line sites (at most 5)", and the cell's own closing
  "5 edit ranges" contradicts the 7 entries it lists. Precedent equates the
  two counts: p12-01 lists 2 sites and says "2 edit ranges"
  (`perf-round-12-plan.md` line 119 on origin/master). Fix in v1.0: trim the
  row to at most 5 sites, or state explicitly that doc-only mentions
  (`sec-gosec.func.sh:1-17` `@param`, `pre-push-gate.md`) sit outside the
  5-site count.

## Notes

- **N1** - row 02's baseline n moved 44 -> 46 between the editor's 06:2xZ
  read and mine (two more PASS runs in the log); the range 628..1,696 s is
  identical and every run is PASS. The plan's n is a snapshot, not an error.
- **N2** - row 01's n=2 is the full population of `TIMED OUT after` lines
  since `1d7bae644`, not a sample; my re-run printed the identical two lines.
- **N3** - the lane map's `unknown:` count moved 17 (plan's 07:43Z read) ->
  15 at my read; still none naming a row file. Exit 4 is handled correctly:
  the plan (section 3.2) says the R3 check re-reads the map before each spawn
  and asks any lane still unknown.
- **N4** - row 01's site description matches the code at the sha:
  `check-pre-push.func.sh:1117-1126` still builds the base worktree and
  captures on it before `_pp_timed_out` at `:1131`, and `_pp_timed_out`
  (`:1149-1159`) records FAIL with `trunk=<sha>-green|red|none` - so today
  the re-check runs and only colours `trunk=`; the row's change (return
  before `_pp_baseline_tree` on rc 124/137) is exactly what removes it.
- **N5** - the 4.4 floor re-run on `9310612f3` prints exactly the plan's
  `perf 18 refactor 101 perf-share 15.1% under-20`, so the round's reason to
  exist holds at the measured sha.

## Re-review of v0.3: d4e8e8572b6d1fecf695462169b27cfb30afe33a

Named by c-882@sat in its result of 2026-11-17T08:05:57Z on task
`dispatch-perf-r13` ("W1 fixed, plan v0.3 = `d4e8e857...`").
`git ls-remote origin refs/heads/review/c001-perf-round-13-planner`
-> `d4e8e8572b6d1fecf695462169b27cfb30afe33a` (branch head matches the named
sha). Branch log since v0.2:
`git log --oneline --format='%h %cI %s' 1774838a2..FETCH_HEAD`
-> `d4e8e8572 ... docs(p13-plan, SPL-5774): perf round 13 plan v0.3: row 02 names 5 code sites (mistral seat W1)` and
`f6dc26c17 ... editor state at the 08:12Z rotation`.
`git diff --stat f6dc26c17 d4e8e857 --stat` -> 1 file:
`csi-spl-doc/doc/md/perf-round-13-plan.md` only (the editor.md change sits in
f6dc26c17, not in the fix commit), as c-882 claimed.

### W1 fixed, verified at d4e8e857

Plan line 102 (row 02 sites cell) at v0.3 now names exactly **5 code sites**:
`check-pre-push-lint.func.sh:102-109`, `:158`, `:443`;
`sec-gosec.func.sh:1-17`, `:117-137` - and says so ("**5 code sites**
(rulebook 3.1)"), with `pre-push-gate.md` listed as "Doc, outside the
code-site count". The contradictory "5 edit ranges" against 7 entries is
gone. The merge of `:117` and `:124-137` into `:117-137` is legitimate:
`grep -nE '^[a-zA-Z_]+\(\) ?\{|^\}'` on `sec-gosec.func.sh` at d4e8e857 shows
`do_sec_gosec() {` at line 87 and its closing `}` at line 141, so lines
117-137 are one function body, one range. Row 01 (plan line 101) is
unchanged: 3 sites. Both rows are within rulebook 3.1's at-most-5 cap.

### Delta checks re-run at v0.3 (commands and output)

- Slug, origin/master `01de192fbd`:
  `git log origin/master --oneline -E --grep='\(p13-' | wc -l` -> `0`;
  `git ls-remote origin 'refs/heads/*p13-*' | grep -v c002-perf-round-13-mistral-seat | wc -l`
  -> `0` (only this seat's own branch carries p13).
- Sites at d4e8e857, `git show d4e8e857:<file> | sed -n <N>p`:
  `check-pre-push.func.sh:1131` -> `_pp_timed_out ...; return 0`;
  `:1149` -> `_pp_timed_out() { ...`; `check-pre-push-lint.func.sh:158` ->
  the `lint-gosec` `*.go`/`go.mod`/`go.sum` selection; `:443` ->
  `SEC_GOSEC_ROOT="$tree" do_sec_gosec`; `sec-gosec.func.sh:117` -> the
  `./...` scan; `:137` -> `_sec_baseline_gate ...`; `pre-push-gate.md:255`
  -> the TIMED OUT paragraph. Drift
  `git log --oneline 1774838a2..origin/master -- <row files + tests>` -> 0
  lines: no site drifted between v0.2, v0.3 and master.
- Re-measure (read-only), push user's log:
  `sudo awk '$1>="2026-11-15T12:45:06Z" && $3=="PART" && $4=="lint-gosec" && $5=="PASS" {...}' ~/.cache/csi-spl/pre-push.log`
  -> `n=46 sum=48593 mean=1056.4 min=628 max=1696` (unchanged since my v0.2
  read; the row keeps its n=44 reading on `9310612f3`, noted in plan v0.3
  section 8). `sudo awk '$1>="2026-11-15T12:45:06Z" && /TIMED OUT after/' ~/.cache/csi-spl/pre-push.log | wc -l`
  -> `2` (unchanged; both FAIL). Verdicts agree.
- R3 lane map, row files only:
  `lane-map.sh --check <7 row paths> --agent m-909` -> exit 4, 0 `owned by`
  lines (15 `unknown:` on the second fleet box, none naming a row file).
- Plan bookkeeping: section 8 (v0.3 entry) records the m-909 FAIL on v0.2
  `1774838a2` and the W1 fix; section 9 consensus records
  `m-909 ... v0.2 1774838a2 | FAIL, W1 (sites > 5), fixed in v0.3`.
  `git diff 1774838a2 d4e8e857 -- csi-spl-doc/doc/md/perf-round-13-plan.md`
  shows only the title/status, the row 02 sites cell, section 8 and section
  9 changed - no row content, baseline, test, vendor or batch moved.

### Verdict on v0.3

**PASS on `d4e8e8572b6d1fecf695462169b27cfb30afe33a`.** W1 is fixed (5 code
sites, doc outside the count, merge into `:117-137` verified against the
function body 87-141), every other check re-run at v0.3 is green with the
output above, and nothing else in the plan moved. This seat signs v0.3.
