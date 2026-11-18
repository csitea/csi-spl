# Refactor round 35: mistral panel seat (m-392, mistral)

Issue SPL-5831, epic SPL-2402, spec `csi-spl-doc/specs/011-spool-project-refactor`,
task `dispatch-refactor-r35`. Doc review only: this seat reviews the plan, never a
row, and touches no file but this one.

## Verdict

**PASS** on plan sha **`a73b73d4701c02bec5bed621589d1f689ab1c389`** (v0.2), file
`csi-spl-doc/doc/md/refactor-round-35-plan.md` (285 lines at that sha), branch
`review/c002-refactor-round-35-planner`.

Sha provenance: c-389@sat named v0.2 `a73b73d47` on task `dispatch-refactor-r35`
(msg `235c5319`, 2026-11-18T08:05:03Z: "Plan sha: `a73b73d47` on
`review/c002-refactor-round-35-planner`"; `git ls-remote` -> `a73b73d47`). My
`git fetch origin review/c002-refactor-round-35-planner && git rev-parse FETCH_HEAD`
-> `a73b73d4701c02bec5bed621589d1f689ab1c389`, matching. `origin/master` at check
time: `f284b414807a3052852becca845f350b037b064d` — the plan's own measured sha.

## Checks (each with the command and what it printed)

### 1. Slug r61 unused

- `git log origin/master --oneline -E --grep='\(r61-' | wc -l` -> **0**
- `git ls-remote origin 'refs/heads/*r61*' | wc -l` -> **0**

### 2. Row sites exist at f284b4148 and on origin/master

For every file:line the rows cite I ran `git show f284b4148:<file> | sed -n <N>p`
and `git show origin/master:<file> | sed -n <N>p`, plus the literal grep
`grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])'` per file. All 14 literal sites print
OK with the literal and are byte-identical on `origin/master` (same sha now):
`spl-box-quota.func.sh:180`, `spl-lane-rotate.func.sh:112`, `spl-watchdog.func.sh:72,1311`,
`install-box-crons.func.sh:36,51`, `spl-box-state-backup.func.sh:11,163,204`,
`external-api-health.func.sh:28,62`, `spl-spawn-place.func.sh:206,672`,
`spl-workspace-docs-purge.func.sh:36,48,135`, `prune-docker-images-install-cron.func.sh:8,27`,
`setup-reverse-tunnel.func.sh:30,40`, `spl-desk-up.func.sh:66`, `spl-m3-e2e.func.sh:85`,
`spl-desk-install-service.func.sh:327,329`. Row 01's `spl-uplink-probe.func.sh:14-15`
carry no literal — they are the stale `@description` lines the row fixes
(`:14` -> `# @description The probe exits 0 even with the link down: it never fails its`);
the code claim holds: `sed -n 55,60p` -> `:58` `spl_uplink_probe_dir dir || return 1`,
`:60` the box-id FATAL `return 1`. Baseline:
`git show f284b4148:csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -vE '^\s*(#|$)' | awk '{s+=$1} END{print NR, s}'`
-> `17 34` (plan: 17 files / 34 lines). Helpers at the named lines:
`spl-claude-login.func.sh:23`, `spl-token-burn-collect.func.sh:37`,
`spl-uplink-probe.func.sh:73` each print their `...() {` definition. Drift since
v0.1's sha: `git diff --stat f62d610cb f284b4148 -- <the 15 written paths>` ->
1 file only, `spl-lane-rotate.func.sh | 17 +++++++++++------` (11 insertions, 6
deletions) — exactly the plan's "only spl-lane-rotate.func.sh moved". Why-now:
`git log origin/master --oneline -E --grep='\(r60-[0-9]{2}' | wc -l` -> **7**.

### 3. Row structure, R1, R3, perf round 16

- Sites per row (entries in the sites column): 01: 1, 02: 4, 03: 4, 04: 2, 05: 4,
  06: 4 — all at most 5 (rulebook 3.1).
- Baseline with command + number + n: section 2's table carries the literal grep,
  the count and n per input (row 02: 4 lines / 3 files; baseline 17/34; row 03:
  7 lines / 3 files; row 04: 2 lines; row 05: 7 lines / 3 files; row 06: 4 lines /
  3 files).
- Counting test with red control per row: each row's test column names its Control
  (row 01 C2 text-only `git diff`; rows 02-06 the section-1 control: derived dir
  equals the old literal, `SPL_RUN_PATHS_TOP=` no-dir answer, ratchet red
  `STALE baseline`). Vendor, kind, batch columns present on every row: vendor
  `claude` on all 6, kind `simple_coding` on all 6, batches 1,1,2,3,4,5.
- R1: batch 1 = rows 01+02, file sets disjoint (row 01 `spl-uplink-probe.func.sh`;
  row 02 `spl-box-quota.func.sh`, `spl-lane-rotate.func.sh`, `spl-watchdog.func.sh`,
  `no-literal-paths.baseline`); batches 2-5 serialised on the shared baseline per
  plan 3.1. No file in two rows of one batch. No mistral coding or testing rows
  (owner 10-17, t1 b61851fb msg 91bf8278).
- Section 3.3 test counts re-run with the plan's own command on `f284b4148`
  (`git grep -lE "${pat}" f284b4148 -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*'
  'csi-spl-utl/**/tests/*' | grep -v baseline | wc -l`): row 01 -> **3**, row 02 ->
  **34**, row 03 -> **11**, row 04 -> **14**, row 05 -> **4**, row 06 -> **60** —
  all match the plan.
- R3, perf round 16 file by file: `git log origin/master --oneline -E
  --grep='\(p16-01'` -> `48b44328b perf(p16-01-orc-map-shared-doc-name, SPL-5866)`
  (landed, as the plan says). p16-02 (c-381@sat, live): `git -C
  /opt/csi/csi-spl-wt/c-381 diff --name-only origin/master...HEAD` ->
  `csi-spl-orc/src/bash/run/spl-spawn-share.func.sh`,
  `csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh` only — no row path;
  its brief `c002-p16-02-orc-spawn-share-briefs-one-pass.md:15` says
  "`spl-spawn-place.func.sh` is NOT yours (parked refactor round 35 row 04 owns it)".
- R3, live sat lanes: for each of c-102, c-176, c-197, c-337, c-339, c-371, c-379,
  c-381, c-384, c-762, m-345, `git -C /opt/csi/csi-spl-wt/<a> diff --name-only
  origin/master...HEAD` plus `git status --porcelain`, matched against the 15 row
  basenames -> **0 hits each** (11 lanes), as the plan's 3.2 claims.

### 4. Re-measure one row, n=3 (read-only)

Row 02, on `f284b4148`, three runs of the literal grep per file:
`git show f284b4148:<file> | grep -cE '/(opt|var)/csi($|[^A-Za-z0-9_-])'` ->
run1/run2/run3: `spl-box-quota.func.sh` 1, `spl-lane-rotate.func.sh` 1,
`spl-watchdog.func.sh` 2 — **4 lines, 3 files every run** (plan: 4 lines, 3 files).
Baseline n=3: `17 34` every run. My number and the row's verdict **agree**.

### 5. R3 lane map on the rows' paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 15 row paths, comma-separated> --agent m-392`
-> **exit 4**: 0 paths owned; 13 `unknown:` lanes with no files recorded, all on
the other box: 11 rotate lanes (`c-060`, `c-390`, `c-468`, `c-528`, `c-545`,
`c-570`, `c-596`, `c-643`, `c-669`, `c-924`, `c-927`) and two blog drafts
(`c-054`, `c-714`). This reproduces the plan's own 3.2 reading (exit 4 at
2026-11-18T08:00:27Z, same 13 ids). Exit 4 is not free; the plan does not treat it
as free and leaves the per-row re-check to the holder (R3).

### 6. Rulebook 4.4 command on origin/master

The 4.4 command verbatim on a fresh fetch ->
`perf 24 refactor 90 perf-share 21.1% floor-met` — exactly the plan's why-now line
(measured on `f284b4148` at 2026-11-18T08:01:15Z).

### 7. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-392`,
**exit 0**.

## Defects

None. (W1..: no defect found; every check above printed what the plan claims.)

## Notes

- N1: the live queue moved since the plan's 08:00:34Z reading:
  `cd csi-spl-orc && ./run -a do_spl_spawn_queue` now (2026-11-18T08:1xZ) ->
  `0 queued, 0 placing`, live lanes `refactor 5 19% (band 10-20%: ok)`,
  `last 24 h (133 sample(s)): refactor 11% (band 20-30%: UNDER)`, `phase day`.
  No refactor-class row queued in either reading; queue/lane readings are live
  state and carry their own time, so this is not a defect.
- N2: the lane-map exit 4 (check 5) is 13 `unknown:` lanes on the other box (rotate and blog
  drafts). Per the seed, exit 4 means ask first, never free; the plan states it
  and assigns the re-run before each row's spawn to the holder, which is what R3
  requires.
- N3: row 01's sites `:14-15` carry no literal path by design (a comment-only
  row, C5); the code at `:58`/`:60` returning 1 was verified directly.
- N4: STEP 0 done: developer guide read, acked as m-392 (blob `8b1916cd`).

Signed: m-392 (mistral), 2026-11-18T08:12:17Z, on
`a73b73d4701c02bec5bed621589d1f689ab1c389`.

## v1.0 signing

The editor c-389@sat landed v1.0 on `origin/master` as
**`e563bf623248e1eb442ec54abfaa45dfdb5af985`** (2026-11-18T08:19:49Z, subject
`docs(refactor-round-35-plan, SPL-5831): refactor round 35 plan v1.0, panel m-392
mistral PASS on v0.2 a73b73d47`, body `Closes: SPL-5831`) and named it to me on
task `dispatch-refactor-r35` ("For m-392 to sign: e563bf623"). Verified before
signing:

- `git fetch origin master && git merge-base --is-ancestor
  e563bf623248e1eb442ec54abfaa45dfdb5af985 origin/master` -> yes; `origin/master`
  head is `e563bf623` itself.
- `git diff a73b73d4701c02bec5bed621589d1f689ab1c389 bd89e7541 --
  csi-spl-doc/doc/md/refactor-round-35-plan.md` -> 0 lines: the master v0.2
  `bd89e7541` is the same content as the review-branch v0.2 I signed.
- `git diff bd89e7541 e563bf623 -- <plan>` -> only the status line and sections
  8-9; the 6-row table (section 3) is untouched, rows as in v0.2.
- Rulebook 4.4 command on `origin/master` `e563bf623` ->
  `perf 25 refactor 90 perf-share 21.7% floor-met` (same reading the editor took
  on `0905076cc`).

**PASS** on v1.0 `e563bf623248e1eb442ec54abfaa45dfdb5af985`.

Signed: m-392 (mistral), 2026-11-18T08:21:26Z, on
`e563bf623248e1eb442ec54abfaa45dfdb5af985`.
