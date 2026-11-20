# Bug round 25 (b25): mistral panel seat (m-767)

Seat: m-767, placement `c002-bug-round-25-mistral-panel-seat` (mistral; docs and
reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/spawn-remote/briefs/8fbcbda7-3521-417f-8211-89d8c72f3acb.md`
(Issue SPL-6009, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `e4423a32-ac00-4eee-95c9-3fdd18b06a60`).

Review target: plan v1.0 `0a700414d3852cc897f2c764fe635ee10ccf7bf7`, named to this
seat by the editor c-184@sat (inbox msg 6fde4c7c, 2026-11-20T02:40:42Z) and by the
dispatch holder c-002@sat (inbox msg 1b3608b7, 2026-11-20T02:40:35Z); the brief
named v0.1 `fd658a9db3a5409ea8fcb885135b971b02bfcd46`, superseded by the named
v1.0. Provenance, all run by this seat on 2026-11-20 02:41-02:47Z:
`git ls-remote origin refs/heads/review/c002-bug-round-25-planner` ->
`0a700414d3852cc897f2c764fe635ee10ccf7bf7` (head);
`git cat-file -t 0a700414d3852cc897f2c764fe635ee10ccf7bf7` -> `commit`;
`git log -1 --format='%H %s' 0a700414d` -> `docs(b25-plan, SPL-6009): bug round 25
plan v1.0, the other box's slug check recorded (0, 0); no row changed`;
`git show 0a700414d --stat` -> 1 file, `csi-spl-doc/doc/md/bug-round-25-plan.md`
(155 lines at the sha, read in full at that sha);
`git diff fd658a9db 0a700414d --stat` -> 1 file, 9 insertions(+), 8 deletions(-)
(status line, review history, holder answers; no row cell changed).
origin/master at my read: `f589257ba4e04de6f02980f65ac32d0e71cf46d3`;
`git merge-base --is-ancestor 82f0e0b0f origin/master` -> exit 0 (the plan's
measurement sha is on trunk). All counts below re-measured on `82f0e0b0f` unless
stated. `<box2>` is the fleet's box that is not this seat's box; `<PUSH_USER>` is
the OS user that owns the checkouts and pushes (the public repo names neither).

## Verdict

**PASS on `0a700414d3852cc897f2c764fe635ee10ccf7bf7`** — the one row (b25-01) is a
real defect: this seat re-ran the red control rebuilt from the plan's section 3.2
and it is red on `82f0e0b0f` exactly as the plan prints (tag `4245` and tag `4243`
exit 1 with `36 passed, 1 failed`, control tag `ctl` exits 0 with `37 passed`),
and the CI failure it reproduces is readable in job 136021944607's log. Every
cited file:line exists on `82f0e0b0f` and is unchanged on origin/master. The fix
scope is the test file only and the fixed needles still match the ALERT line they
guard. The row carries defect, red control, test list, vendor, kind, batch, and an
R7 reviewer that is the claude waiver seat, never mistral. Slug b25 is unused on
origin. Sections 4 and 5 each carry a measurement or say NOT RUN in the plan
itself. Defects W1..: none. Notes N1..N6 below.

## Checks (each with the command run and what it printed, 2026-11-20 02:41-02:47Z)

### 1. Slug b25 unused

- `git log origin/master --oneline -E --grep='\(b25-[0-9]{2}' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b25-[0-9]{2}|bug-round-25'` -> one line:
  `0a700414d3852cc897f2c764fe635ee10ccf7bf7  refs/heads/review/c002-bug-round-25-planner`
  (the planner's branch, expected; this seat's review branch was not pushed yet
  at the check). Nothing else.
- This box's briefs dir: `ls /var/spool-hub/dispatch/briefs | grep -cE 'b25-[0-9]{2}|bug-round-25'`
  -> `0` (the holder's msg said both boxes' halves are 0; this seat re-ran the
  origin parts and its own box's briefs part).
- Window (rulebook 5.3): `git log origin/master -1 --format=%cI -E --grep='^docs\(b24-plan'`
  -> `2026-11-19T22:43:09+01:00 cb8f0f117` (the plan's W).

### 2. Every cited file:line exists on `82f0e0b0f` and on origin/master

13 cited sites checked with `git show <sha>:<file> | sed -n <N>p` for `<sha>` in
{`82f0e0b0f`, `origin/master`}; every one prints the same line on both, 0 missing
files, 0 drifted lines (origin/master = `f589257ba`):

- `csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-boot-restore.sh:97`
  -> `hasnt "3. ... a plain shell is not" "4243" "$out"` (both shas)
- same file `:101` -> `hasnt "3. ... a shell that only mentions vibe is not" "4245" "$out"`
- same file `:28` -> `BX="boxu-$$"; AG="agentu-$$"; ME="$(id -un)"`
- same file `:93` -> `printf '4242 /opt/agent/bin/claude --resume s-99\n4243 bash -l\n' > "$T_TMP/ps.out"`
- same file `:98` -> `printf '4244 Vibe CLI\n4245 bash -c vibe-notes\n' > "$T_TMP/ps.out"`
- `csi-spl-orc/src/bash/run/spl-agent-boot-restore.func.sh:72` ->
  `echo "ALERT   runs as $box_user, not $agent_user: $line"; n=$((n + 1))`
- same file `:73` -> the awk filter
  `... awk '$2 ~ /(^|\/)(claude|grok|agy|qwen|vibe)$/ || ($2 == "Vibe" && $3 == "CLI")'`
- same file `:74` -> `(( n == 0 )) || why="..."`
- `csi-spl-orc/src/bash/features/spawn-agents/tests/lib.inc.sh:30-32` -> `hasnt() {`
  / `case "$3" in *"$2"*) nok "$1 (unexpected '$2')" ;; *) ok "$1" ;; esac` / `}`
  (a substring match, as the plan says)
- `csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-name-shape.sh:89` ->
  `hasnt "5. ... an unknown kind letter x-004 is no agent id (control)" "900006" "$out"`

### 3. The row is a real defect; the red control re-run

- Code read: case 3 of `test-agent-boot-restore.sh` runs the action and searches
  the WHOLE output (`$out`) for the bare needles `"4243"` (`:97`) and `"4245"`
  (`:101`) via `hasnt` (a substring match, `lib.inc.sh:31`). `$out` also carries
  per-run text: the tmux socket path under the sandbox TMPDIR, the `boxu-$$` /
  `agentu-$$` names (`:28`), the restored pid (`SKIP ... (pid <n>)`). A chance
  4-digit substring anywhere in that text fails the case with nothing wrong in
  the code. What a wrongly flagged shell would print is the ALERT line of
  `spl-agent-boot-restore.func.sh:72`.
- CI evidence re-read: `gh run list --repo csitea/csi-spl --workflow 10_ci-quality.yml
  --event schedule -L 12` -> 12 scheduled runs 14:45Z..01:44Z, one `failure`
  `44655865817` (2026-11-20T01:44:59Z), one `failure` `44569585278` (16:44Z, the
  plan's `4j Shift+O` case), the other 10 `success` — the plan's "1 failed of the
  last 8 scheduled runs (18:45Z..01:44Z)" holds.
  `gh api repos/csitea/csi-spl/actions/jobs/136021944607/logs | grep -nE "unexpected
  '4245'|36 passed, 1 failed|tmp.lnipS02eZX"` -> line 504 `FAIL - 3. ... a shell
  that only mentions vibe is not (unexpected '4245')`, line 528 `--
  test-agent-boot-restore.sh: 36 passed, 1 failed`, and `tmp.lnipS02eZX` in the
  runner temp paths (lines 491+). Job meta: run 44655865817, head_sha
  `99029842fae23b119ed820270613f3bb5b6715fa`, conclusion `failure`, job
  `orc: feature tests (spawn-agents, graft, mcp-bot, ...)`.
  `git log --oneline -1 82f0e0b0f -- <the test>` -> `4c1304bcb` (unchanged since,
  as the plan says).
- Red control rebuilt and re-run by this seat. `/var/spool-hub/dispatch/b25-red-controls/`
  does NOT exist on this box (`ls` -> No such file or directory), as the holder's
  msg said; the script was rebuilt from the plan's section 3.2 code block into a
  throwaway dir outside the tree: `wc -c` -> `977`, `sha256sum` ->
  `4df52c39d3b72f2fe8879f98f4c4e1f4241e96015e2775f5a5f66abbb621a346` (first 12 hex
  `4df52c39d3b7`, exactly the plan's recorded prefix and size). Each run from this
  checkout as `<PUSH_USER>` (`sudo -u <PUSH_USER> bash /tmp/b25-rc/rc01.sh <sha> <tag>`):
  - `bash rc01.sh 82f0e0b0f 4245` -> `FAIL - 3. ... a shell that only mentions vibe is not (unexpected '4245')` / `-- test-agent-boot-restore.sh: 36 passed, 1 failed` / `rc01 sha=82f0e0b0f tag=4245 rc=1`, exit 1. RED, word for word as the plan prints.
  - `bash rc01.sh 82f0e0b0f 4243` -> `FAIL - 3. ... a plain shell is not (unexpected '4243')` / `36 passed, 1 failed` / `rc=1`, exit 1. RED.
  - `bash rc01.sh 82f0e0b0f ctl` -> `-- test-agent-boot-restore.sh: 37 passed, 0 failed` / `rc01 sha=82f0e0b0f tag=ctl rc=0`, exit 0. Control GREEN.

### 4. Fix scope

- The plan's fix scope is the test file only (section 3.1 batch 1 names exactly
  `test-agent-boot-restore.sh`; `spl-agent-boot-restore.func.sh` and `lib.inc.sh`
  are read-only). The fixed needles name the ALERT line, e.g.
  `hasnt "..." "not $AG: 4243" "$out"`: the ALERT form at
  `spl-agent-boot-restore.func.sh:72` is `ALERT   runs as $box_user, not
  $agent_user: $line`, so with the fake ps line `4245 bash -c vibe-notes`
  (test `:98`) the ALERT contains `not $AG: 4245` — the fixed needle still catches
  the real defect the case guards (an ALERT naming that pid), while a bare `4245`
  in a tmux socket path no longer matches. Verified by reading `:72`, `:93`, `:98`.
- The "passes after" half is a lane obligation the plan states, not yet
  demonstrated: no prototype fix exists (the plan says so), and the row's fix
  scope requires the lane's commit body to carry rc01 with tags `4245`/`4243` on
  its fix -> PASS, plus a red control that the fixed needles still fail on a copy
  whose awk also takes a shell (`$2 ~ /vibe/` at `func.sh:73`). Not run by this
  seat (no fix exists to run it on).
- `test-agent-name-shape.sh:89` (the plan's "not a row"): `git grep -nE "hasnt
  [\"'][^\"']*[\"'] [\"'][0-9]{3,6}[\"']" 82f0e0b0f -- 'csi-spl-orc/**' 'csi-spl-iac/**'
  'csi-spl-utl/**'` -> exactly 3 lines: the row's `:97`, `:101` and this `:89`.
  Its "not a row" is backed by a measurement only in the negative sense: n=0 red
  in the 100 CI runs of source 2 (re-read above at the run level for the last 12),
  and the plan itself says "not run with a planted value" — no red control exists
  for it. That is what the plan claims, so the claim is honest; it is not a
  demonstrated defect.

### 5. Row shape, vendor, R7

The row carries all of: defect, evidence (CI job + log lines, re-read above),
sites file:line (check 2), red control that fails on `82f0e0b0f` (check 3) with the
pass-after obligation in its fix scope, test list (section 3.1 R2: the test itself,
rc01 with tags `4245`/`4243`/`ctl`, the spawn-agents suite's run of it;
`git grep -l test-agent-boot-restore 82f0e0b0f -- '*tests*'` names none but the
test itself, as the plan says), box, vendor `claude`, kind `tests`, batch 1. No
mistral coding or testing row. R7 reviewer in the signed sha: `claude waiver seat
(1a7c70da), fresh session, tree only` — the waiver seat the brief allows, never
mistral (rulebook 2.7.2 cross-vendor line; ruling b71016ad: mistral reviews plans,
not row code). Rulebook read: sections 1-3 and 5 (`rounds-rulebook.md` 2.2 R2,
2.7 R7, 3.1, 3.2, 5.1-5.4; 5.2 "1 row is a round", 5.3 numbering).

### 6. Lane map on the row path and this seat file

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-boot-restore.sh,csi-spl-doc/doc/md/bug-round-25/seat-mistral.md
--agent m-767` -> `WARN no live lane lists <both paths>, but 3 live lane(s) record
no files: their scope is unknown, not free` + `FATAL ... status 4`, exit 4,
naming `unknown:` c-046@sat, c-168@sat (a rotate lane), c-184@sat (the planner).
No lane lists the row's file or this seat file. Exit 4 is "ask first, not free";
the plan recorded the same shape at 02:31:44Z (exit 4 for 8 `<box2>` lanes and
c-764) and hands the R3 re-run to the orchestrator before the spawn (plan section
6). Not a plan defect (N1).

### 7. Sections 4 and 5: each "not a row" and its measurement

- **FlowFanout counts not cut per box (b24-01 leftover 1): backed by a
  measurement.** Re-ran `git grep -n 'flowCutCounts\|FlowFanout' 82f0e0b0f --
  csi-spl-api/src/go/spool-hub-api/internal/hub/flow.go` -> `:267` `fe.FlowFanout(...)`,
  `:277` `s.flowCutCounts(ctx, fe, row.TenantID, member, locks, &p)`, `:285-286`
  the comment "flowCutCounts replaces p's counts ... FlowFanout's counts are not
  cut per box"; and `git log origin/master --oneline -E --grep='\(b24-0[12]-'` ->
  `6fedc5bbb` (b24-01), `d32ff2ed8` + `d5ca55d20` (b24-02) — landed, as the plan
  says. Served in b24-01.
- **The agent `flow_read` frame reads no lock (leftover 2): backed by a code
  reading, not a count.** `git show 82f0e0b0f:.../hub/flow_agent.go | sed -n 20p` ->
  `func (s *Server) onFlowRead(...)`; `git show 82f0e0b0f:.../hub/box_lock_view.go |
  sed -n 133p` -> `func (s *Server) lockViewFor(ctx context.Context, tenant, hum string)`.
  The plan's "not a bug on the record" rests on these lines plus spec 130 and
  b24-01's body — a reading, honestly labelled.
- **The done-claim `job` label: backed by a measurement.** The plan's source 4:
  0 `job <hex>` alerts since W in 55 runs of the planner's box's
  `/var/csi/csi-spl/done-claim-check/cron.log` (that box's log is not readable from
  this box). Cross-check on this box's own log:
  `awk -F'\t' '$1 > "2026-11-19T21:43:09" && /\talert\t/' /var/csi/csi-spl/done-claim-check/cron.log
  | grep -c 'job [0-9a-f]'` -> `0`. Consistent.
- **AltGr letter may pick a kind: NOT backed by a measurement — the plan says so
  itself** ("Not run: node 20 ... no TypeScript strip, and no browser was
  driven"; "No red control, and no rule it breaks"). The code reading is verified:
  `git show 82f0e0b0f:csi-spl-wui/src/utils/kind-picker-keys.ts | sed -n '45p;58p'`
  -> `function letterOf(ev: KindKeyEvent): string {` and
  `if (ev.shiftKey || ev.ctrlKey || ev.metaKey || ev.altKey) return ''`. Carried as
  an input, correctly not a row.
- **`blog.test.mjs:329` fails when run alone: not re-measured on `82f0e0b0f` —
  the plan says so** ("not re-run on 82f0e0b0f: it needs a generated bundle and
  Chrome, and this worktree has no node_modules"). The 3/3 alone-fail is on
  `67232dbc8` (c-002 msg 577d03b7), a different sha. The line exists on
  origin/master: `git show origin/master:csi-spl-wui/tests/e2e/blog.test.mjs |
  sed -n 329p` -> `ok(\`${label}: picking bg lands on /bg/blog/${id}\`, ...)`. A
  test-isolation defect, green in CI; correctly not a row this round.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-767`,
exit 0 (2026-11-20T02:46Z; re-run after staging this file, still clean).

## Defects

None. W1..: none.

## Notes

- **N1:** lane-map exits 4 on the row path and this seat file (three live no-file
  lanes: c-046@sat, c-168@sat, c-184@sat), the same shape the plan recorded at
  02:31:44Z. Per the rule, exit 4 is "ask first, not free"; the plan hands the R3
  re-run to the orchestrator before the spawn. Not a plan defect.
- **N2:** origin/master moved past the plan's measurement sha `82f0e0b0f` to
  `f589257ba` during this read; `git diff --stat 82f0e0b0f origin/master -- <the
  row file>` is empty and every cited line prints identically on both (check 2),
  so nothing drifted.
- **N3:** the red control was rebuilt from the plan's section 3.2 because
  `/var/spool-hub/dispatch/b25-red-controls/` is absent on this box (the holder's
  msg said so); the rebuilt copy is 977 B with sha256 prefix `4df52c39d3b7`,
  matching the plan's recorded prefix and size, so the bytes are the same.
- **N4:** the plan's source-2 per-job "last green" claim (44655865817 /
  44655802340 on `99029842`) was not re-run as a 100-run report by this seat; the
  run-level claims around it were re-read via `gh run list` / `gh api` (check 3).
- **N5:** the plan's `<box2>` / `<PUSH_USER>` placeholders resolve on this box to:
  push user = owner of the main checkout's `.git`; agent user = this session's
  `id -un`; the public repo names neither, so this file names the roles only.
- **N6:** the brief named v0.1 `fd658a9db`; the editor and the holder named v1.0
  `0a700414d` to this seat in the inbox before the review, and the brief allows
  "a later v1.0 it names to you". This seat signed only `0a700414d`;
  `git diff fd658a9db 0a700414d --stat` -> 1 file, 9 insertions(+), 8 deletions(-),
  no row cell changed.

## Report sent (task `dispatch-bug-r25`, kind result, to c-184@sat and the current
dispatch lease holder)

`review: m-767@<box> mistral PASS 0a700414d3852cc897f2c764fe635ee10ccf7bf7 ran: <commands
as in checks 1-8, separated by ;> | read: <their outputs as printed above>; seat-file:
review/c002-bug-round-25-mistral-seat <commit sha> | log:
m-767@<box>:.vibe/logs/session/unified/2736cb27-4b6a-132d-0ef4-726256dd68c2`
(the spool report itself carries this seat's real `<id>@<box>`; the box name is
a banned literal in docs, so this file writes `<box>`)
