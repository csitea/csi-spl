# Bug round 17 - mistral panel seat verdict

Reviewer: m-459@sat (mistral; docs and reviews only, no code written, no file
touched but this one). Issue: SPL-5880. Epic: SPL-2402. Spec:
csi-spl-doc/specs/157-dispatch-automation.

Plan reviewed: `csi-spl-doc/doc/md/bug-round-17-plan.md` **v0.2** at commit
`dbc28c0049edc4be6d5c63f3a9ef8dcfc5469859` (151 lines). Sha provenance:
`git ls-remote origin review/c002-bug-round-17-planner` ->
`dbc28c0049edc4be6d5c63f3a9ef8dcfc5469859`; `git merge-base --is-ancestor
dbc28c0049edc4be6d5c63f3a9ef8dcfc5469859 origin/master` -> exit 0 (on trunk;
origin/master now `c64437066cf8b44789bc326bbd328d9c556bca36`);
`git diff --stat dbc28c004 origin/master -- csi-spl-doc/doc/md/bug-round-17-plan.md`
-> empty (the plan file is unchanged since v0.2). Named as the review target
by the editor c-448@sat (msg 4c800451). v0.1 `73776c4fa6ca92d4e6dc04c1bec2c3d527c1866f`
is superseded, not reviewed. The plan's measurement sha `dd983b175`:
`git merge-base --is-ancestor dd983b175 origin/master` -> exit 0.

All row sites below were read at BOTH `dd983b175` and `origin/master` with
`git show <sha>:<file> | sed -n <N>p`; the outputs were identical
(`git diff --stat dd983b175 origin/master -- csi-spl-orc/src/bash/scripts/box-link-watch.py csi-spl-orc/src/bash/tests/box-link-watch.tst.sh csi-spl-doc/specs/016-spool-testability/box-link-7min-watcher.md`
-> empty), so 0 drift. The red control was run by me on a scratch
`git archive dd983b175 csi-spl-orc` copy in a mktemp dir, the repo untouched.

## Verdict

**PASS on `dbc28c0049edc4be6d5c63f3a9ef8dcfc5469859`.** Defects W1..: none.
Notes N1..N4 below.

## Checks (each with the command run and what it printed)

### 1. Slug b17 unused

- `git log origin/master --oneline -E --grep='\(b17-' | wc -l` -> `2`; both
  hits are the plan's own version commits `73776c4fa` and `dbc28c004`
  (subject scope `b17-plan`), not a row slug - the plan's own slug bullet
  predicts exactly this.
- `git log origin/master -E --grep='\bb17-[0-9]{2}-' | wc -l` -> `0` (no row
  slug).
- `git ls-remote origin | grep -E 'b17-[0-9]{2}|bug-round-17'` -> one line:
  `dbc28c0049edc4be6d5c63f3a9ef8dcfc5469859  refs/heads/review/c002-bug-round-17-planner`
  (the planner's own review branch, expected).
  `git ls-remote origin | grep -cE 'b17-[0-9]{2}'` -> `0`. Nothing else
  matches.

### 2. Row sites exist at `dd983b175` and on origin/master

- `csi-spl-orc/src/bash/scripts/box-link-watch.py:204-217` ->
  `def refusal_kind(text, raw, results):` ...; line `:208` is exactly
  `if re.search(r"^box: exec: .*(REFUSED|refused|timed out)", text):` - the
  exec match the row names. Docstring `:12-15` -> the condition b text ("a
  `box: deploy:` / `box: exec:` REFUSED / timed out line ..."). Also read
  `:220-241` (`refusals`, condition b; the clear pattern
  `^(box: )?exec: request \S+ (DONE .*)?-> exit 0\b` at `:227-233`),
  `:279-283` (`conditions`: "while one is open the read reaches back to its
  start, so a line older than the window cannot clear it"), `:534-539`
  (`restart`, SPL-5522, `GW_RESTART_AFTER_S`). Identical at both shas.
- `csi-spl-orc/src/bash/tests/box-link-watch.tst.sh:133-139` -> case 7 ("a
  refused apply -> alert; a later APPLIED clears it"), so the new case goes
  after `:139`; the header list `:3-42` is present (cases 1..22, file 354
  lines).
- `csi-spl-doc/specs/016-spool-testability/box-link-7min-watcher.md:27` ->
  the condition b row of the spec table.
- `git diff --stat dd983b175 origin/master -- csi-spl-orc/src/bash/scripts/box-link-watch.py csi-spl-orc/src/bash/tests/box-link-watch.tst.sh csi-spl-doc/specs/016-spool-testability/box-link-7min-watcher.md`
  -> empty: no site drifted between the measurement sha and today's trunk
  (origin/master `c64437066`, one commit past the plan: the perf round 17
  editor notes).

### 3. The row's shape

- Red control fails on `dd983b175`: see check 4, `RESULT: FAIL` reproduced.
- Counting test column:
  `git grep -lE 'box-link-watch(\.py|\.tst)?|do_spl_box_link_watch' dd983b175 -- '*tests/*'`
  -> `csi-spl-orc/src/bash/tests/box-link-watch.tst.sh`,
  `csi-spl-orc/src/bash/tests/install-box-crons.tst.sh`,
  `csi-spl-orc/src/bash/tests/orc-shard-weights.txt` (data) - the same list
  the plan prints; same output on origin/master. (The plan's table cell
  writes the alternation as `\|`, the markdown escape; the plan says "type a
  plain `|`" under the table - see N3.)
- Vendor/kind/batch from the row table: vendor `claude`, kind `simple_coding`,
  batch `1`. Re-ran the mix read-only:
  `cd csi-spl-orc && env LANE_MIX_KIND=simple_coding DRY_RUN=1 ./run -a do_spl_lane_mix`
  -> `pick=claude launcher=/claude-spawn kind=simple_coding reason=kind
  simple_coding: main claude, backup agy ...` and the mistral row reads
  `skip (mistral writes no code, kind simple_coding (owner HUM-10 t1 b61851fb
  msg 91bf8278 ...))`. Agrees with the plan's 10:24:08Z line.
- R7: the row's R7 cell is "a cross-vendor seat if one places (agy or grok);
  else the claude waiver seat ... The holder decides at placement" - a
  cross-vendor seat or the claude waiver, never mistral. Re-ran
  `env BOX_PICK_KIND=grok DRY_RUN=1 ./run -a do_spl_box_pick` ->
  `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99%
  billing read 11m ago; <box2> 99% ...]`, agreeing with the plan's 10:24Z
  line. The round has one row and it is vendor claude: no mistral coding or
  testing row.

### 4. Red control re-run (read-only sandbox)

- Read `/var/spool-hub/dispatch/b17-red-controls/rc01.sh` (31 lines) first:
  it mktemp's its own dir, writes only under it, runs `box-link-watch.py`
  with `DRY_RUN=1` against a fake hub (all `GW_*` paths under the mktemp
  dir), and `rm -rf` only its own mktemp dir. No hub write, no real spool,
  no prd, no terraform - safe to run.
- Ran: `SB=$(mktemp -d /tmp/b17-rc01.XXXXXX); git archive dd983b175 csi-spl-orc | tar -x -C "$SB"; bash /var/spool-hub/dispatch/b17-red-controls/rc01.sh "$SB"`
  ->
  `INFO box b:exec:3d1970ae84ae: box command refused or timed out, 11 min` /
  `INFO box b:exec:c03a833949d6: box command refused or timed out, 11 min` /
  `PLAN blocker to c-002 (dispatch lease holder: no live seat row on topic abcd1234; workspace wsx) on box-link-watch-abcd1234: LINK STUCK > 7 min on box `box` since 2026-11-04T13:35:40Z:` /
  `PLAN restart box box: `run -a kick-now` in the link checkout (stuck since 2026-11-04T13:35:40Z: box command refused or timed out; box command refused or timed out)` /
  `RESULT: FAIL (an expired, nothing-ran request on an up link is a STUCK condition and plans a restart)`,
  exit 1.
- **It reproduces exactly**: the plan's section 3.2 output on `dd983b175` is
  this output verbatim (the INFO ids are the sha1 of the raw line,
  `b:exec:<sha1[:12]>`, not the request id - the script logs request ids
  `2d33743b4de0` / `643d772590a9` from blocker 89af0515). The defect is real
  on the measured sha: on a link that is up (box log 1 min old, radiate
  running), two expired `nothing ran` lines alone raise LINK STUCK and plan
  the restart.
- Suite on the same archive copy:
  `bash "$SB/csi-spl-orc/src/bash/tests/box-link-watch.tst.sh"` -> `ALL PASS`
  (56 s), agreeing with the plan's "ALL PASS (n=1, 64 s)".
- Judgment the brief asks for: is the row still a bug if the link really was
  stopped (owner csitea msg fc3c25be)? **Yes.** The red control raises the
  alert on a link that is demonstrably up, so the defect does not depend on
  the remote box's link state; the code path (`:208` matches the expired
  form, `:279-283` never ages a condition out while an incident is open,
  `:534-539` plans the restart past 600 s) is in this tree and reproduced.
  The owner's stop is the remote box's state, which the plan lists in
  section 5 as not code in this tree; under either reading the row stands.

### 5. Sections 4 to 6 (zero rows elsewhere): source 3 re-run

- `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E '(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)' dd983b175 -- "$d" | wc -l; done`
  -> `csi-spl-api: 199`, `csi-spl-wui: 17`, `csi-spl-orc: 10`,
  `csi-spl-iac: 21`, `csi-spl-utl: 0` - the plan's counts exactly.
- `git diff 714a4fc82 dd983b175 -G '(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)' --stat`
  -> only `csi-spl-doc/doc/md/perf-round-17-plan.md` and
  `csi-spl-doc/doc/md/perf-round-17/editor.md` (they quote the pattern), as
  the plan says. **My count agrees: 0 rows.**
- Sections 4 to 6 read in full: 4 candidates measured not-a-bug, 3
  not-reproduced or not-code, 4 owned elsewhere; section 7 counts rows = 1.

### 6. R3: lane map on the row's files

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/scripts/box-link-watch.py,csi-spl-orc/src/bash/tests/box-link-watch.tst.sh --agent m-459`
  -> exit **4**: `WARN no live lane lists ... but 16 live lane(s) record no
  files`; the unknown lanes are all @<box2>: c-054, c-060, c-390, c-468,
  c-528, c-545, c-570, c-669, c-673, c-700, c-701, c-703, c-706, c-714, c-924,
  c-927. No live lane owns the two files; exit 4 is "ask first, not free" -
  the plan discloses this in section 3.1 (it recorded 18 such lanes at
  10:22:41Z; c-705 and c-939 have since closed) and assigns the re-run to
  the orchestrator before the spawn (R3). See N2.

### 7. R1 across rounds

- `git show origin/master:csi-spl-doc/doc/md/perf-round-17-plan.md | grep -c box-link-watch`
  -> `0`; `git show origin/master:csi-spl-doc/doc/md/perf-round-17/editor.md | grep -c box-link-watch`
  -> `0`; `git show origin/master:csi-spl-doc/doc/md/refactor-round-35-plan.md | grep -c box-link-watch`
  -> `0`. `git grep -c box-link-watch dd983b175 -- <the three files>` -> no
  matches (rc 1). Agrees with the plan's 10:22Z line (0 each).

### 8. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-459`,
  exit 0.

## Defects

None. No W items.

## Notes

- **N1**: the plan's slug bullet recorded `git ls-remote origin | grep -cE
  'b17-[0-9]{2}|bug-round-17'` -> 0 at 10:17Z; now that grep matches the
  planner's own `review/c002-bug-round-17-planner` branch (expected, the plan
  says so). Every row-slug form (`\bb17-[0-9]{2}-` in the log, `b17-[0-9]{2}`
  in ls-remote) is still 0, so b17 is unused as a round row id.
- **N2**: lane-map exit 4 with 16 unknown no-file lanes, all @<box2> (the
  plan recorded 18 at 10:22:41Z; c-705 and c-939 closed since). The plan
  discloses it and the orchestrator re-runs R3 and asks an exit-4 lane first
  before the spawn; not cleared by the plan, not hidden either.
- **N3**: in the source-3 command as printed in the plan's table cell the
  alternation is `\|` (markdown escape); run literally it returns 0 counts.
  The plan says "type a plain `|`" directly under the table, so this is
  documented, not a defect.
- **N4**: origin/master has moved past the plan sha since v0.2 (now
  `c64437066`, the perf round 17 editor notes); the row files and the spec
  doc are unchanged `dd983b175..origin/master` (empty diff), and the plan
  file is unchanged since v0.2, so nothing measured drifted.

---

## v1.0 signature

**PASS on `fcd1feaf4af29e196c8a1129a3eb7a452f1fc59b`** (plan v1.0), signed
2026-11-18T10:5xZ after the editor c-448@sat named it on task
`dispatch-bug-r17` (msg ad6fde0a, 2026-11-18T10:53:08Z: "v1.0 to sign is
`fcd1feaf4af29e196c8a1129a3eb7a452f1fc59b` on origin/master. The review branch
head `8174e6123` is the same commit before the push rebase, with an identical
plan file.").

Provenance and re-checks, each with the command run and what it printed:

- `git fetch origin master review/c002-bug-round-17-planner` then
  `git rev-parse origin/master` -> `fcd1feaf4af29e196c8a1129a3eb7a452f1fc59b`
  (v1.0 is the trunk tip).
- `git merge-base --is-ancestor fcd1feaf4af29e196c8a1129a3eb7a452f1fc59b origin/master`
  -> exit 0 (on trunk).
- `git ls-remote origin review/c002-bug-round-17-planner` ->
  `8174e6123f929a9c0754a2422d73793d2672306c` (the pre-rebase head);
  `git diff --stat 8174e6123 fcd1feaf4 -- csi-spl-doc/doc/md/bug-round-17-plan.md`
  -> empty (identical plan file).
- `git log -1 --format='%H %s' fcd1feaf4` ->
  `fcd1feaf4af29e196c8a1129a3eb7a452f1fc59b docs(b17-plan, SPL-5880): bug round 17 plan v1.0, panel m-459 mistral PASS on v0.2 dbc28c004`;
  `git show fcd1feaf4 --stat` -> 1 file changed, the plan only
  (`csi-spl-doc/doc/md/bug-round-17-plan.md`, 5 insertions, 4 deletions).
  Plan at v1.0: 152 lines
  (`git show fcd1feaf4:csi-spl-doc/doc/md/bug-round-17-plan.md | wc -l`).
- `git diff dbc28c004 fcd1feaf4 -- csi-spl-doc/doc/md/bug-round-17-plan.md` ->
  three hunks only: the status line (v0.2 -> v1.0), one review-history line
  in section 8, and the section 9 consensus table (Editor v1.0, Panel
  m-459@sat PASS on `dbc28c004`). Grepping that diff for
  `b17-01|box-link-watch|rc01|refusal_kind|red control|fix scope` matches only
  those status/history lines, so **no row, site or red control changed**.
- `git diff --stat dd983b175 fcd1feaf4 -- csi-spl-orc/src/bash/scripts/box-link-watch.py csi-spl-orc/src/bash/tests/box-link-watch.tst.sh csi-spl-doc/specs/016-spool-testability/box-link-7min-watcher.md`
  -> empty (row files and the spec doc unchanged from the measurement sha to
  v1.0); `git merge-base --is-ancestor dd983b175 fcd1feaf4` -> exit 0.
- Slug re-check on the new trunk:
  `git log origin/master -E --grep='\bb17-[0-9]{2}-' | wc -l` -> `0`;
  `git ls-remote origin | grep -cE 'b17-[0-9]{2}'` -> `0`.

Every check above run for v0.2 still holds: the red control was measured on
`dd983b175`, which is an ancestor of v1.0 with the row files byte-identical,
so its `RESULT: FAIL` stands unchanged.
