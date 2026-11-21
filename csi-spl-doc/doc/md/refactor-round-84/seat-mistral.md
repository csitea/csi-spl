# Refactor round 84 — panel seat mistral (m-840@<box>)

Issue: SPL-6187 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/spawn-remote/briefs/737c3abb-f9cf-470a-8251-006e80ca3046.md`.
Review target: `csi-spl-doc/doc/md/refactor-round-84-plan.md` on branch
`review/c002-refactor-round-84-planner`, at the v0.1 sha the planner's branch names
(the only plan commit, subject `... plan v0.1 ...`):
`d90bec9f397459574f3965aa4d4a2e64c49fd8b7`.
`git ls-remote origin | grep refactor-round-84` ->
`d90bec9f397459574f3965aa4d4a2e64c49fd8b7  refs/heads/review/c002-refactor-round-84-planner`
(head matches; `git log -1 --format='%H %cI %s'` ->
`d90bec9f397459574f3965aa4d4a2e64c49fd8b7 2026-11-21T15:02:16+02:00 docs(r84-plan, SPL-6187): refactor round 84 plan v0.1, 2 rows: ...`).
The plan's measured base is `e1ee705d8` (`git merge-base --is-ancestor e1ee705d8 origin/master` -> ok;
`git merge-base --is-ancestor e1ee705d8 d90bec9f...` -> ok).
`origin/master` at my reads: `05848e16c` (`git log -1 --format='%H %s' origin/master`).
Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2 the panel signs
the plan sha; 5.1 1 to 3 rows; 5.3 numbering and window). Form:
`csi-spl-doc/doc/md/refactor-round-83-plan.md` and `refactor-round-83/seat-mistral.md`
(on origin/master; the r83 seat file's `:256-269`, `:400-414` N1-N4 notes exist as cited:
`git show origin/master:csi-spl-doc/doc/md/refactor-round-83/seat-mistral.md | sed -n '256p;400p'` ->
`- **N1:** live state moved ...` / `- **N1:** live drift since ...`).
Every file:line below was checked with `git show <sha>:<file> | sed -n <N>p` on both
`e1ee705d8` and `origin/master` unless stated. `sa:` = `csi-spl-orc/src/bash/features/spawn-agents`.

## Verdict

**PASS** on `d90bec9f397459574f3965aa4d4a2e64c49fd8b7`. Both rows pass every check (1-8):
the r84 slug is free since W, every cited site line exists on the base sha and on
origin/master with no drift, both red controls fail on the base for exactly the reason
the plan gives (not an environment reason) and touch no live state, both rows keep
behaviour (my own probes: 156/156 an_strip cases equal, kv bodies byte-identical, source
move collision-free), row fields satisfy R1/R2/R7 with no mistral row and a claude waiver
R7 seat, the lane map shows no owning lane on any of the 9 row paths, the inputs are
accounted for, and distribution hygiene is clean. No defects (W1..: none). Notes N1-N5 below.

### 1. Slug r84 unused since the plan's `Window: W=`

W = `2026-11-21T13:36:16+02:00`, verified: `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r83-plan'`
-> `85ea3fb627ad28dbc0aafe5bd4f4fb096ba3f24d 2026-11-21T13:36:16+02:00 docs(r83-plan, SPL-6178): plan v1.0 records m-780's signature on ee0908f7f ...`.

- `git log origin/master --since="$W" --oneline -E --grep='\(r84-' | wc -l` -> **0**
  (the same grep over all history, no `--since`, -> **0**).
- `git ls-remote origin | grep -E 'r84-[0-9]{2}|refactor-round-84'` ->
  **one** line: `d90bec9f397459574f3965aa4d4a2e64c49fd8b7  refs/heads/review/c002-refactor-round-84-planner`
  (the planner's branch, expected; `git ls-remote origin | grep -cE 'r84-[0-9]{2}'` -> **0**;
  my own seat branch did not exist yet at this read).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r84-[0-9]{2}|refactor-round-84'` -> no match (rc 1);
  content grep `grep -rlE 'r84-[0-9]{2}|refactor-round-84' /var/spool-hub/spawn-remote/briefs/ /var/spool-hub/dispatch/briefs/`
  -> **one** file, my own brief `737c3abb-f9cf-470a-8251-006e80ca3046.md`
  (the planner's brief lives on sat, not on this box).

### 2. Every site file:line of every row exists on the base sha and on origin/master

38 cited lines (row 01: `scripts/tmux-close-window.sh:96,97,271,272,298,326`,
`lib/agent-state.inc.sh:34,36,44,45,67`, `tests/test-agent-id.sh:76,77,78`;
row 02: `lib/desk-root.inc.sh:34`, `scripts/spool-fleet-relay.sh:55,57,82,83,87,89,91,92,182`,
`scripts/topic-text.sh:51,54,56,58,59,63`, `scripts/spool-topic-kind.sh:52,56,58,60,63,67`,
`csi-spl-orc/src/bash/tests/desk-root-readers.tst.sh:76`) each read with
`git show <sha>:<file> | sed -n <N>p` on `e1ee705d8` and on `origin/master`; `diff` of the
two outputs -> **IDENTICAL** (e.g. `tmux-close-window.sh:97` ->
`BOX_USER="$SPOOL_BOX_USER" BOX_TMUX_SOCKET="$SPOOL_TMUX_SOCKET" BOX_TAG="${SPOOL_BOX_TAG:-}"`,
`:274` -> `an_strip() {`, `:326` -> `  name="$(an_strip "$1")"; id="$2"`,
`agent-state.inc.sh:34` -> `an_tag() { printf '%s' "${SPOOL_BOX_TAG:-${BOX_TAG:-${AGENT_TOP_TAG:-}}}"; }`,
`desk-root.inc.sh:34` -> `spool_desk_root() {  # CALLER_HOME [BOX_ENV]`).

- Drift: `git diff --name-only e1ee705d8 origin/master -- <the 9 row paths of plan 2.2>` -> **empty**;
  `git diff --name-only e1ee705d8 d90bec9f... -- <the 9 paths>` -> **empty**.
- Counts: `git grep -nE '^an_strip\(\) *\{' origin/master -- sa:` -> `lib/agent-state.inc.sh:46`,
  `scripts/tmux-close-window.sh:274` (**2**, plan says 2 on `e1ee705d8` -> 1 after row 01);
  `git grep -nE '^(spool_box_kv|kv)\(\) *\{' origin/master -- sa:` -> `spool-fleet-relay.sh:84`,
  `spool-topic-kind.sh:53`, `topic-text.sh:51` (**3**, plan says 3 -> 1 after row 02).
- kv bodies: `git show origin/master:sa:<f> | sed -n '/^kv()/,/^}/p' | tail -n +2 | md5sum`
  -> `126ff6d3a9d5255343970d6113c4200f` for all three scripts (byte-identical body; only the
  first line's trailing comment differs). The `sed` line is identical in all three
  (`git grep -nF 'sed -n "s/^$2=' origin/master -- sa/scripts` -> `:86`, `:55`, `:53`).
- File sizes: `git show origin/master:sa:<f> | wc -l` -> tmux-close-window.sh **1103**,
  agent-state.inc.sh **243**, desk-root.inc.sh **52**, test-agent-id.sh **148** — all match the plan.

### 3. Red controls, run on the plan's base in a scratch copy

Scratch: `git archive e1ee705d8 | tar -x -C /tmp/r84-full` (full tree, chown <box user>), runs as
`sudo -u <box user> env SPOOL_TEST=1 bash <test>`; nothing outside the test's own `$T` temp dir is
read or written — no live state touched (the suites say so in their headers; I observed only
`/tmp/r84-full` and the tests' `$T` change).

- Control files at base, `sha256sum`:
  `55b1f6ccdfaeee6163252d70b3888c810c9a9b804d3e9d620908801068191418  .../spawn-agents/tests/test-agent-id.sh`
  `487e70523067ca369718ae8977cddbd71c248fa16066fa86483e15ce78fa9b55  .../src/bash/tests/desk-root-readers.tst.sh`
- Base runs (n=1): `SPOOL_TEST=1 bash tests/test-agent-id.sh` -> rc **0**, last line
  `-- test-agent-id.sh: 86 passed, 0 failed` (86 `ok` lines) — matches the plan's "base 0 / 86".
  `SPOOL_TEST=1 bash src/bash/tests/desk-root-readers.tst.sh` -> rc **0**, last line `ALL PASS`
  (37 `PASS:` lines) — matches "base 0 / 37".
- Row 01 red (head's test on base: the plan 1.3 case inserted after `:78` of test-agent-id.sh
  in the scratch copy, nothing else changed): rc **1**, last line
  `-- test-agent-id.sh: 86 passed, 1 failed`, FAIL line
  `FAIL - 3. an_strip is defined once, in agent-state.inc.sh (want '.../lib/agent-state.inc.sh', got '.../lib/agent-state.inc.sh\n.../scripts/tmux-close-window.sh')`
  — exactly the plan's quoted red ("want '<lib>', got '<lib> <script>'"). Fails for the plan's
  reason (two definitions on base), not an environment reason.
- Row 02 red (head's test on base: section 0b's +4 cases inserted before `:76` of
  desk-root-readers.tst.sh in the scratch copy): rc **1**, last line `4 FAILED`, 37 `PASS:` lines,
  FAIL lines: three `FAIL: 0b. spool_box_kv reads ... (want 'prd'/'t1'/'box-t', got 'bash: line 1: spool_box_kv: command not found')`
  and `FAIL: 0b. spool_box_kv is defined once, in desk-root.inc.sh (want '.../lib/desk-root.inc.sh', got '.../scripts/topic-text.sh\n...')`
  — exactly the plan's quoted red (three `spool_box_kv: command not found` + `is defined once`
  got the three scripts). Fails for the plan's reason, not an environment reason.
- After the row (reasoning, the row heads are not on the plan branch — see N2): row 01 leaves
  only `lib/agent-state.inc.sh:46`, so the grep returns the lib alone -> the case passes (87);
  row 02 defines `spool_box_kv` once in desk-root.inc.sh and the three call cases run -> 41 pass.

### 4. Equivalence of each row

- Row 01: the two `an_strip` texts use literally the same regexes —
  `git grep -nE 'AN_ID_HEAD_RE=|AN_ID_AT_RE=|AN_TAG_TOKEN_RE=|AN_TAG_SHAPE_RE=' origin/master -- sa/lib/agent-state.inc.sh`
  -> `:21 AN_TAG_TOKEN_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'`, `:23 AN_TAG_SHAPE_RE='^[a-z][a-z0-9]{2}$'`,
  `:30 AN_ID_HEAD_RE="^${SPOOL_AGENT_ID_RX}([[:space:]]|\$)"`, `:32 AN_ID_AT_RE="^${SPOOL_PARTICIPANT_RX}@..."`,
  identical to the script's inlined greps at `:277`, `:283`, `:288`, `:294-295`.
  The only divergence is the lib's `an_tag` fallback to `AGENT_TOP_TAG`:
  `git grep -c 'export AGENT_TOP_TAG' origin/master` -> rc 1 (**no matches**);
  `git grep -n 'AGENT_TOP_TAG' origin/master -- sa/scripts/tmux-close-window.sh` -> rc 1 (never set there);
  the script's only caller of `an_strip` outside the function is `name_is_agent` at `:326`.
  My probe (lib `an_strip` vs the script's copy, verbatim, under the script's env
  `BOX_TAG="${SPOOL_BOX_TAG:-}"`): 3 tag envs (unset/bx1/<box>) x 2 BOX_TAGS x 26 window-name
  shapes = **156 cases, 0 differ**. Behaviour kept on every path the script takes; the control
  (check 3) would catch a difference (it greps the definitions).
- Row 02: the `kv` body is byte-identical in all three readers (check 2), so moving it into
  `desk-root.inc.sh` as `spool_box_kv` with the same body keeps every value read.
  Source order: `spool-fleet-relay.sh` sources desk-root.inc.sh at `:57`, before its `kv` calls
  `:89,:91,:92,:182` — no move needed. `topic-text.sh` (`:59-63`) and `spool-topic-kind.sh`
  (`:63-67`) source it after their `kv` calls (`:56-58`, `:58-60`), so the plan moves the
  source block above `BOXENV=`; I verified the region between the kv block and the source
  block touches **0** of the 81 names the two libs define
  (`grep -cE "(^|[^A-Za-z0-9_])$v(=|\(\))"` per name over the region -> 0 each, both scripts).
  `_spool_desk_root_key` (`:19-32`) is correctly left out (plan section 7): it keeps any
  character, `spool_box_kv`'s sed would refuse values it takes today. Behaviour kept.

### 5. Row fields (R2, R7, R1)

- Each row has a control that fails today and passes after (R2): check 3 — red on base for
  the plan's reason; green after by construction (one definition left / `spool_box_kv` defined
  once and callable). Test lists: plan 1.5's tables (11 suites for row 01, 8 for row 02,
  `bash-cleancode.tst.sh`, `do_check_pre_push`), plus the R2 named-but-not-run list.
- Vendor/kind/batch: both rows `claude`, `simple_coding`, batch 1 (plan section 2 table).
  **No mistral coding or testing row.**
- R7 reviewer: plan section 4 — grok is on hold, re-run by me:
  `cd csi-spl-orc && BOX_PICK_KIND=grok ./run -a do_spl_box_pick` ->
  `pick=hold reason=waiting: grok weekly >= 95% or unknown on <both boxes> [...]: queue the lane, spawn nothing`
  (matches the plan's 12:46Z quote), so each row takes a fresh **claude waiver seat** (1a7c70da),
  as r63-r83 — a cross-vendor seat or the claude waiver seat, **never mistral**. OK per rulebook 2.7.
- R1: batch 1 = rows 01 and 02; row 01's paths (tmux-close-window.sh, test-agent-id.sh,
  agent-state.inc.sh, test-tmux-close-window.sh) and row 02's (desk-root.inc.sh,
  spool-fleet-relay.sh, topic-text.sh, spool-topic-kind.sh, desk-root-readers.tst.sh) share
  **no file** (listed from plan 2.2, disjoint).

### 6. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 9 row paths, comma-separated> --agent m-840`
-> **exit 4**: `WARN no live lane lists <the 9 paths>, but 10 live lane(s) record no files:
their scope is unknown, not free`; the `unknown:` lanes, all @sat: c-760 (s189 b1-b7),
c-778, c-789, c-799, c-801 (rotate), c-809 (b34-01), c-833 (rotate), c-838 (bug-round-35
planner), c-840 (this round's planner), m-785 (bug-round-34 panel). One call per path:
each of the 9 -> **exit 4** (no exit 3: no live lane owns any row path).
Briefs on this box naming a row basename and changed in the last 24 h: **1**,
`f73467ea-...md` (r81-01's claude waiver reviewer, SPL-6163, landed `3174e591a`), which names
`desk-root-readers.tst.sh` as a gate to re-run, not a file it edits. The live/queued lanes the
brief names (r83-01 c-807@<box>, r83-02 c-835@sat, bug round 34 c-809/c-811@sat, the six queued
spec 184 rows, SPL-6182 c-806@<box>, spec 123/189/190 lanes): none lists a row path (exit 4, not 3);
the planner's 2.2 read their briefs on sat (`grep -cE '<row basenames>'` -> 0 each). No row file
is touched by any of them per every read available to me.

### 7. Inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` is **not on this box**
  (`ls` -> No such file or directory; `find /var/spool-hub /opt/csi -name '*next-round*'` ->
  nothing outside `.retired/`). The plan read it on sat (110 lines at 12:39Z; G1 -> 8 lines
  `:1 :25 :48 :51 :74 :76 :104 :109`). NOT RUN here: the raw file read (see N1); I verified the
  plan's accounting of those 8 lines against r83's section 7 (on origin/master): `:1`, `:25`,
  `:48` served (plan 1.2 re-reads them), `:51` bug-shaped, `:74` test row (r84 s7), `:76` served
  by r81-01, `:104` behaviour (r84 s7), `:109` feature/bug by its own text.
- r83 plan section 7's "candidate for r84" items are each accounted in r84 section 7:
  `parse-metadata.func.sh` `${1:?}` (bug row; files are r83-02's), `spl-lane-mix.func.sh`
  `:138`/`:401-402` (output asserted by its test: behaviour), `workspace-rules.md:33-34` +
  the wf 10 job name (doc text / required-check name). No refactor-shaped input is neither
  served nor accounted for.
- Each row is ONE logical refactor with no behaviour change: no row changes an exit code, a
  message, a path or a default (check 4: 156/156 probe equal, kv byte-identical, source move
  collision-free; row 01 keeps `:97` `BOX_TAG=` so an inherited `BOX_TAG` still cannot reach
  `an_tag`).

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> rc **0**, last line
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-840`
(all `ok -` lines above it).

## Defects

None. W1..: none.

## Notes

- **N1:** the candidates file `c002-next-round-candidates.md` lives on the planner's box
  (the planner's box), not on this box; its raw read is the planner's (plan 1.2). I verified the accounting of its
  8 G1 lines against r83's section 7 and the plan's own quotes, not the raw file. NOT RUN here:
  `wc -l` / `grep -nE '[Rr]efactor|[Tt]est-shaped'` on that file on this box (absent).
- **N2:** the plan branch carries only the plan doc (no row heads), so for check 3 I
  reconstructed the head test files exactly as plan 1.3/1.4 specify (the +1 case after
  `:78`; section 0b's +4 cases before `:76`) on a scratch copy of base; the failure reasons
  match the plan's quoted red controls verbatim.
- **N3:** the plan's perf-floor line ("re-read on `267bd3bbd`: `perf 29 refactor 110 perf-share
  20.9% floor-met`") I did not re-run (no such output in a quick `git log --grep='perf-share'`
  over origin/master); read from the plan. It only decides refactor vs perf round, not a row.
- **N4:** a first scratch run (csi-spl-orc only, as the agent user) gave 5 environment FAILs (missing
  csi-spl-doc/csi-spl-api paths, tmux close); the full-tree scratch as the box user reproduces the
  plan's exact base numbers (86/0 and 37/ALL PASS) — environment reason, not a plan defect.
- **N5:** lane-map exit is 4, not 0: 10 unknown-scope lanes on sat. Per the seed rule exit 4
  is "ask them first, never free"; the planner's 2.2 read their briefs on sat (0 row basenames
  each), and on this box the only recent brief naming a row basename is r81-01's reviewer
  (landed), naming `desk-root-readers.tst.sh` as a gate only.
