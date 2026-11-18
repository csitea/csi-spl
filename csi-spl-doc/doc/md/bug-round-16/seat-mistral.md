# Bug round 16 - mistral panel seat verdict

Reviewer: m-411@sat (mistral; docs and reviews only, no code written, no file
touched but this one). Issue: SPL-5869. Epic: SPL-2402. Spec:
csi-spl-doc/specs/157-dispatch-automation.

Plan reviewed: `csi-spl-doc/doc/md/bug-round-16-plan.md` **v0.2** at commit
`a070d21a5480af945df71155ad4e961b08166222` (132 lines). Sha provenance:
`git ls-remote origin review/c002-bug-round-16-planner` ->
`a070d21a5480af945df71155ad4e961b08166222`; `git merge-base --is-ancestor
a070d21a5480af945df71155ad4e961b08166222 origin/master` -> exit 0 (on trunk,
origin/master now `cb9902b0f5f9c3663e5c66b28424f02a3c0c1330`);
`git diff --stat a070d21a origin/master -- csi-spl-doc/doc/md/bug-round-16-plan.md`
-> empty (the plan file is unchanged since v0.2). Named as the review target
by the editor c-401@sat on task `dispatch-bug-r16` (msg f7037510,
2026-11-18T08:51:50Z: "Please review and sign v0.2, not v0.1 `526155e00`").
v0.1 `526155e001aa02de345eb4ea67b7dd20cd00a199` is superseded:
`git diff --stat 526155e00 a070d21a -- csi-spl-doc/doc/md/bug-round-16-plan.md`
-> `1 file changed, 14 insertions(+), 7 deletions(-)`, the plan file only
(the other box's answers and the review history; row 01, its sites, red
control and fix scope unchanged). The plan's measurement sha `714a4fc82`
(`714a4fc824cbb03a436a2eadad09f51a84029e69`, committed 2026-11-18T08:27:09Z):
`git merge-base --is-ancestor 714a4fc82 origin/master` -> exit 0.

All row sites below were read at BOTH `714a4fc82` and `origin/master` with
`git show <sha>:<file> | sed -n <N>p`; the outputs were identical
(`git diff --stat 714a4fc82 origin/master -- <the row files and flush.go and
channels_postgres.go>` -> empty), so 0 drift. The red control was run by me
on a scratch `git archive 714a4fc82 csi-spl-orc` copy in a mktemp dir, the
repo untouched.

## Verdict

**PASS on `a070d21a5480af945df71155ad4e961b08166222`.** Defects W1..: none.
Notes N1..N4 below.

## Checks (each with the command run and what it printed)

### 1. Slug b16 unused

- `git log origin/master --oneline -E --grep='\(b16-' | wc -l` -> `2`; both
  hits are the plan's own version commits `526155e00` and `a070d21a`
  (subject scope `b16-plan`), not a row slug - the plan's own slug bullet
  predicts exactly this.
- `git log origin/master -E --grep='\bb16-[0-9]{2}-' | wc -l` -> `0` (no row
  slug).
- `git ls-remote origin | grep -E 'b16-[0-9]{2}|bug-round-16'` -> one line:
  `a070d21a5480af945df71155ad4e961b08166222  refs/heads/review/c002-bug-round-16-planner`
  (the planner's own review branch, expected; my own
  `review/c002-bug-round-16-mistral-seat` did not exist yet at check time).
  `git ls-remote origin | grep -cE 'b16-[0-9]{2}'` -> `0`. Nothing else
  matches.

### 2. Row sites exist at `714a4fc82` and on origin/master

- `csi-spl-api/src/go/spool-hub-api/internal/hubclient/flush.go:65-73` ->
  `if toBox == own { ... if !mirror { return wire.DeliveryLocal, nil } }`
  (lines 65-73 exactly: same-box send delivered locally, hub skipped unless
  the mirror is on). Identical at both shas.
- `csi-spl-orc/src/bash/run/spl-spawn-fill.func.sh:357-373` ->
  `spl_spawn_fill_hub() {` at :357, the `open` case at :366
  (`a=(send --from "$agent" --to "$agent" --to-box "$box" --task "$2" --kind note --body "$3")`),
  the `spl_desk_spool` call at :372. `:326-342` -> `spl_spawn_fill_topic() {`
  at :326 with the comment at :321-325 ("a same-box lane's messages never
  reach the hub"). `:285-304` -> `spl_spawn_fill_queue() {` at :285, the
  `spl_spawn_fill_one ... && n=$((n + 1))` at :297, the tick's
  `OK $n row(s) queued` at :302; the `WARN ... no fill this tick` paths at
  :78, :83, :84, :88. Identical at both shas.
- `csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh:266` ->
  `# 9. the lane's discussion (SPL-5860) ---` (case 9; a new case goes after
  it); the `SPAWN_FILL_HUB_CMD` stub at :86-94 (`$T/bin/spoolhub`, logs each
  call, refuses `issue link` with `unknown_discussion` under `HUB_FAIL=link`).
  Identical at both shas.
- `csi-spl-api/src/go/spool-hub-api/internal/store/channels_postgres.go:716-724`
  -> `func topicAccessRead(...)` with `FROM messages WHERE tenant_id = $1 AND
  task_id = $2::uuid` at :724: a topic exists on the hub only when a hub
  message carries its task id. Identical at both shas.
- The probes set the mirror: `spl-box-msg-probe.func.sh:78`,
  `spl-box-file-probe.func.sh:54`, `spl-file-door-probe.func.sh:58` each read
  `... SPOOL_MIRROR_LOCAL=1 "$SPL_SPOOL" "$@"`. And `spl-desk-up.func.sh:205-211`
  -> comment "SPOOL_MIRROR_LOCAL stays unset: a desk answers humans on
  box-wui, never itself" and `spl_desk_spool()` at :207-211 sets no mirror.
- Topic id recomputed: `printf 'spawn-fill-topic:%s' SPL-65 | sha256sum` ->
  `abf8b18bf369a09b354c3fdace831625...`; through the v4 shaping of
  `spl_spawn_fill_topic_id` (:348-352) -> `abf8b18b-f369-409b-854c-3fdace831625`,
  the id in the plan's evidence. Matches.
- `git diff --stat 714a4fc82 origin/master -- csi-spl-orc/src/bash/run/spl-spawn-fill.func.sh csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh csi-spl-api/src/go/spool-hub-api/internal/hubclient/flush.go csi-spl-api/src/go/spool-hub-api/internal/store/channels_postgres.go`
  -> empty: no site drifted between the measurement sha and today's trunk.

### 3. The row's shape

- Red control fails on `714a4fc82`: see check 4, `RESULT: FAIL` reproduced.
- Counting test column: `git grep -lE 'spl-spawn-fill(\.func)?|do_spl_spawn_fill\b' 714a4fc82 -- '*tests/*'`
  -> `desk-user-hops.tst.sh`, `orc-shard-weights.txt`, `spl-epic-stall-check.tst.sh`,
  `spl-spawn-fill.tst.sh`, `spl-spawn-group.tst.sh`, `spl-spawn-share.tst.sh`
  (all under csi-spl-orc; `orc-shard-weights.txt` is data) - the same list the
  plan prints. Same output on origin/master.
- Vendor/kind/batch from the row table: vendor `claude`, kind `simple_coding`,
  batch `1`. Re-ran the mix read-only:
  `cd csi-spl-orc && env LANE_MIX_KIND=simple_coding DRY_RUN=1 ./run -a do_spl_lane_mix`
  -> `pick=claude launcher=/claude-spawn kind=simple_coding reason=kind
  simple_coding: main claude, backup agy ...` and the mistral row reads
  `skip (mistral writes no code, kind simple_coding (owner HUM-10 t1 b61851fb
  msg 91bf8278 ...))`. Agrees with the plan's 08:41:45Z line.
- R7: the row's R7 cell is "a cross-vendor seat if one places (agy or grok);
  else the claude waiver seat ... The holder decides at placement" - a
  cross-vendor seat or the claude waiver, never mistral. The round has one
  row and it is vendor claude: no mistral coding or testing row.

### 4. Red control re-run (read-only sandbox)

- Read `/var/spool-hub/dispatch/b16-red-controls/rc01.sh` (39 lines) first:
  it mktemp's its own dir, writes a fake `spool` that keeps the client's
  same-box rule (local delivery unless `SPOOL_MIRROR_LOCAL=1`; `issue link`
  refused `unknown_discussion` unless a hub send carried the topic), sources
  the repo's `spl-desk-up.func.sh` + `spl-spawn-fill.func.sh` read-only, runs
  `spl_spawn_fill_hub open` then `link` for SPL-65, and `rm -rf` only its own
  mktemp dir. No hub write, no real spool, no prd, no terraform - safe to run.
- Ran: `SB=$(mktemp -d /tmp/b16-rc01.XXXXXX); git archive 714a4fc82 csi-spl-orc | tar -x -C "$SB"; bash /var/spool-hub/dispatch/b16-red-controls/rc01.sh "$SB"`
  ->
  `open rc=0 link rc=1 send: local link: spool: hub refused: unknown_discussion (no such discussion: abf8b18b-f369-409b-854c-3fdace831625)`
  then `RESULT: FAIL`.
- **It reproduces exactly**: the plan's section 3.2 output on `714a4fc82` is
  this line verbatim. The defect is real on the measured sha.

### 5. Sections 4 to 6 (zero rows elsewhere): source 3 re-run

- `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E '(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)' 714a4fc82 -- "$d" | wc -l; done`
  -> `csi-spl-api: 199`, `csi-spl-wui: 17`, `csi-spl-orc: 10`, `csi-spl-iac: 21`,
  `csi-spl-utl: 0` - the plan's counts exactly (round 15: the same).
- `git diff 2fe3729e3 714a4fc82 -G '(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)' --stat`
  -> `csi-spl-doc/doc/md/bug-round-15-plan.md | 158 +++...` only, as the plan
  says. **My count agrees.** (The table cell writes the alternation as `\|`,
  the markdown escape; the plan says right below the table "type a plain `|`";
  with a literal `\|` ERE reads a literal pipe and the counts come out 0 - see
  N3.)

### 6. R3: lane map on the row's files

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-fill.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-fill.tst.sh --agent m-411`
  -> exit **4**: `WARN no live lane lists ... but 13 live lane(s) record no
  files`; the unknown lanes are all @<box2>: c-054, c-060, c-390, c-468, c-528,
  c-545, c-570, c-596, c-669, c-673, c-714, c-924, c-927. No live lane owns
  the two files; exit 4 is "ask first, not free" - the plan discloses this in
  section 3.1 and assigns the re-run to the orchestrator before the spawn
  (R3). See N2.

### 7. R1 across rounds

- `git show origin/master:csi-spl-doc/doc/md/perf-round-16-plan.md | grep -c spl-spawn-fill`
  -> `0`; `git show origin/master:csi-spl-doc/doc/md/refactor-round-35-plan.md | grep -c spl-spawn-fill`
  -> `0`. Agrees with c-003@sat (0 and 0 at 08:5xZ) and with the holder's
  answer b065bf95 folded into v0.2.

### 8. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-411`,
  exit 0.

## Defects

None. No W items.

## Notes

- **N1**: the plan's slug bullet recorded `git ls-remote origin | grep -cE
  'b16-[0-9]{2}|bug-round-16'` -> 0 at 08:41:35Z; now that grep matches the
  planner's own `review/c002-bug-round-16-planner` branch (expected, the plan
  says so). Every row-slug form (`\bb16-[0-9]{2}-` in the log, `b16-[0-9]{2}`
  in ls-remote) is still 0, so b16 is unused as a round row id.
- **N2**: lane-map exit 4 with 13 unknown no-file lanes, all @<box2> (the plan
  recorded 12 @<box2> lanes at 08:40:58Z; c-673 joined since). The plan
  discloses it and the orchestrator re-runs R3 and asks an exit-4 lane first
  before the spawn; not cleared by the plan, not hidden either.
- **N3**: in the source-3 command as printed in the plan's table cell the
  alternation is `\|` (markdown escape); run literally it returns 0 counts.
  The plan says "type a plain `|`" directly under the table, so this is
  documented, not a defect.
- **N4**: origin/master has moved past the measurement sha since the plan
  (now `cb9902b0f`, the perf round 16 plan import); the row files, `flush.go`
  and `channels_postgres.go` are unchanged `714a4fc82..origin/master` (empty
  diff), and the plan file is unchanged since v0.2, so nothing measured
  drifted.

---

## v1.0 signature

Pending: the editor folds this verdict into the plan's v1.0 commit; when
c-401@sat names a v1.0 sha on task `dispatch-bug-r16`, it is re-checked and
signed here in a second commit on `review/c002-bug-round-16-mistral-seat`.
