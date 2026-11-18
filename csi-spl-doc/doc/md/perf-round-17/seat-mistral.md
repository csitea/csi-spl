# Perf round 17 (p17): mistral panel seat (m-436)

Seat: m-436@sat, placement `mistral:c002-perf-round-17-mistral-panel-seat`.
Brief: `/var/spool-hub/dispatch/briefs/c002-perf-round-17-mistral-panel-seat.md`
(Issue SPL-5872, Epic SPL-2402, Spec `csi-spl-doc/specs/027-spool-performance`,
class refactor, kind specs_and_docs, topic f758f973-8036-409d-8f83-53536dc310f2).
Review target: branch `review/c002-perf-round-17-planner`. Per the brief this
seat signs ONLY a sha the editor c-705 names as a plan version: v0.1
`933c208d9c1eeca2749db24a76188a99c4d0c266` (named in the brief and by the
dispatch holder c-002@sat on task `dispatch-perf-r17`, 2026-11-18T09:37:17Z:
"p17 plan v0.1 933c208d9"). Read in full at that sha:
`csi-spl-doc/doc/md/perf-round-17-plan.md` (255 lines) and
`csi-spl-doc/doc/md/perf-round-17/editor.md` (274 lines). Baseline sha
`e5f867463`. Rules read: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1-4
(4.1 measured first, 3.2 the panel signs the plan sha). This seat wrote no
code and touched no file but this one.

## Verdict

**PASS on `933c208d9c1eeca2749db24a76188a99c4d0c266`** (plan v0.1, 2 rows:
`p17-01-wui-e2e-shard-weights-refresh`, `p17-02-orc-lane-mix-cnf-read-once`,
both claude / simple_coding, batch 1).

Fetch and sha, 2026-11-18T09:5xZ:
`git fetch origin review/c002-perf-round-17-planner && git rev-parse FETCH_HEAD`
-> `933c208d9c1eeca2749db24a76188a99c4d0c266`;
`git diff origin/master...933c208d9c1eeca2749db24a76188a99c4d0c266 --stat`
-> exactly 2 files, `csi-spl-doc/doc/md/perf-round-17-plan.md` +255 and
`csi-spl-doc/doc/md/perf-round-17/editor.md` +274, as the brief says.

## Checks

1. Slug p17 unused (2026-11-18T09:5xZ, on origin/master):
   `git log origin/master --oneline -E --grep='\(p17-' | wc -l` -> `0`;
   `git ls-remote origin | grep -E 'p17-[0-9]{2}'` -> no output (grep rc 1).
2. Each row's sites exist at `e5f867463` and on origin/master; none drifted:
   `git cat-file -e <ref>:<file>` -> OK for all four row files at both refs
   (`csi-spl-wui/src/node/test/e2e-shard-weights.txt`,
   `csi-spl-wui/tests/unit/e2e-shard-pack.test.mjs`,
   `csi-spl-orc/src/bash/run/spl-lane-mix.func.sh`,
   `csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh`);
   `git diff e5f867463 origin/master --stat -- <the 4 row files +
   csi-spl-wui/src/node/test/run-e2e-tests.mjs>` -> empty (no drift).
   Cited lines verified with `git show <sha>:<file> | sed -n <N>p`:
   `spl-lane-mix.func.sh` `grep -n yq` at both refs -> `:169 :170 :172 :174
   :265 :292 :574 :600` (plus `:108 do_require_bin`), identical at
   `e5f867463` and origin/master, matching the plan's `:166-174, :265, :292,
   :574, :600`; `e2e-shard-pack.test.mjs` `:132-147` is the checked-in-weights
   pack check with the `spread <= 0.05` assert at `:146` (the plan's
   ":133-149"), 180 lines at both refs; `run-e2e-tests.mjs:99-102` is
   `weightFor` with the median fallback and `:259-260` the `<file> <secs>`
   line with the retry comment, as the plan cites.
3. Row shape (plan section 3 table, read at the signed sha): each row has at
   most 5 action sites (rulebook 3.1; per C1 "sites and its tests" the test
   file is the row's test, not a site): row 01 = 1 action file
   (`e2e-shard-weights.txt`) + its test; row 02 = 5 file:line entries in
   `spl-lane-mix.func.sh` (`:166-174, :265, :292, :574, :600`) + its test.
   Each row carries a baseline with command + number + n on `e5f867463`
   (row 01: shard 2/8 mean 1,168 s n=6, 106 of 367 n=1; row 02: 13 `yq` per
   pick n=1 deterministic), a counting test with a red control (4.1: row 01
   the `UNWEIGHTED_MAX` case, red = today's weights give 106 > max; row 02
   the `yq`-stub case, red = today's file gives 13 execs), vendor, kind and
   batch (both claude / simple_coding / batch 1). No file in two rows of one
   batch (R1): row 01 files and row 02 files are disjoint. No mistral coding
   or testing row: both rows are claude.
4. Re-measured myself, read-only, in a `git archive e5f867463` copy at
   /tmp/p17-archive (no prd write), 2026-11-18T09:5xZ:
   - p17-02: one `do_spl_lane_mix` pick per kind with a logging `yq` stub
     first on `PATH` (fixture built before the stub, as the test's `mix()`
     does): `yq execs: 13` for `simple_coding`, `secret`, `complex_coding`,
     `12` for `specs_and_docs` (n=1 each, deterministic) — the editor's 13/12
     exactly. All 13 argv read the same `LANE_MIX_CNF` under `.env.box`
     (`tolerance`, `window`, 6 vendor weights, `backup`,
     `mistral_coding_allowed`, 3 `auth_marker.*`).
   - p17-01: `node src/node/test/run-e2e-tests.mjs --list` (the runner's own
     selection, ci-skip applied) -> `367` files;
     `grep -vE '^#' src/node/test/e2e-shard-weights.txt | awk 'NF{print $1}'`
     -> `261` weight lines; `comm -23 <list> <weighted> | wc -l` -> `106`
     unweighted — the editor's "106 of 367" exactly.
5. R1 across rounds (origin/master, 2026-11-18T09:5xZ): r61-02..06 files from
   `refactor-round-35-plan.md` rows (24 unique `*.func.sh`/`*.tst.sh`/
   `*.baseline` names, incl. `spl-spawn-place.func.sh` of r61-04) and b16-01
   files from `bug-round-16-plan.md` (`spl-spawn-fill.func.sh`,
   `spl-spawn-fill.tst.sh`): none is a p17 row file.
   `git log origin/master --oneline -E --grep='\(r61-'` -> 2 lines, both
   r61-01 (`cebfa7004`, `2e55f493d`), so r61-02..06 are not landed, as the
   plan says. p16 rows landed: `48b44328b`, `0905076cc`.
6. R3, 2026-11-18T09:53Z:
   `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-wui/src/node/test/e2e-shard-weights.txt,csi-spl-wui/tests/unit/e2e-shard-pack.test.mjs,csi-spl-orc/src/bash/run/spl-lane-mix.func.sh,csi-spl-orc/src/bash/tests/spl-lane-mix.tst.sh --agent m-436`
   -> exit 4: 0 lanes own the paths; 17 `unknown:` lanes (all on the other
   box, incl. rotate seats and c-705 the planner itself). Exit 4 is not
   free; the plan's section 3.2 already says the R3 check before each spawn
   re-reads the map and asks any lane still unknown.
7. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
   `INFO distribution-hygiene: clean over the tracked tree of
   /opt/csi/csi-spl-wt/m-436`, exit 0.

## Defects

None. All seven checks pass on the named sha; both rows satisfy rulebook
sections 1-4 (4.1 measured first, 3.2 the panel signs the plan sha) as far as
a plan review can see, and my own re-measurements reproduce the editor's
numbers exactly (13/12 `yq` per pick; 106 of 367 unweighted).

## Notes

- N1: the plan's section 3.2 says "b16-01 not landed"; that was true at its
  09:2xZ reading, and `b1bf6410d fix(b16-01-orc-spawn-fill-topic-open-reaches-hub, SPL-5876)`
  has landed on origin/master since. R1 still holds: b16-01's files are not
  p17 row files, so the landed state changes nothing for this round.
- N2: lane map exit 4 with 17 unknown lanes now (3 at the editor's 09:24Z
  reading), 0 owners of the row paths. Not free per the rule; the plan
  records the same and the per-spawn R3 re-check stands. This seat touched
  no row file.
- N3: row 02's sites column lists 5 file:line entries in
  `spl-lane-mix.func.sh` plus the test file; read per C1 ("the action's sites
  and its tests") the action sites are 5, within the 3.1 bound of 5.
- N4: in my one-pick probe the `:265` `mistral_ui_allowed` read did not fire
  (no UI brief in the pick, `spl_lane_mix_ui_target` empty returns before the
  `yq`); the `:292` `mistral_coding_allowed` read did. The site exists and the
  count still reproduces the editor's 13, so this is a path-dependence note,
  not a defect.
- N5: the consensus table (plan section 9) holds only the editor row; seats
  sign in their own files, as in p12..p16.
