# Bug round 27 (b27): mistral panel seat (m-284)

Seat: m-284@sat, placement `c002-bug-round-27-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-27-mistral-panel-seat.md`
(Issue SPL-6019, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `fdad21bd-00a6-4743-a5d8-060da330e489`).

Review target: plan v0.1 `282437e3a0290271ec47aedc3ba5c10cd50a305f`, named in the
brief. Provenance: `git ls-remote origin | grep -E 'b27-[0-9]{2}|bug-round-27'` ->
`282437e3a0290271ec47aedc3ba5c10cd50a305f  refs/heads/review/c002-bug-round-27-planner`;
`git show 282437e3a --stat` -> 1 file, +205,
`csi-spl-doc/doc/md/bug-round-27-plan.md`, parent `0509f0b7b`; NOT on master
(`git merge-base --is-ancestor 282437e3a origin/master` -> exit 1). Read in full
at that sha (205 lines). origin/master at my read: `1c18a5be` (moved past the
plan's measurement sha `0509f0b7b` during the read, N1).

## Verdict

**FAIL on `282437e3a0290271ec47aedc3ba5c10cd50a305f`** — one defect, W1: a
bug-shaped input in the holder's candidates file is neither served nor accounted
for, so the plan's claim "every other input is accounted for in sections 2, 4 and
5" (plan line 8; "The other 8: sections 4 and 5", plan line 40) is false. Both
rows themselves verified clean: every cited file:line exists on `0509f0b7b` and
on origin/master, both red controls are RED for the reasons the plan gives, both
root causes hold as written, R1/R2/R3/R7 and the slug check pass. The editor
folds W1 into v1.0 (one accounting row in section 4 or 5, or serve it).

## Checks (each with the command run and what it printed, 2026-11-20 07:5x-08:1xZ, sat)

1. **Slug b27 unused since W.** `W=2026-11-20T07:57:34+01:00`;
   `git log origin/master -1 --format=%cI -E --grep='^docs\(b26-plan'` ->
   `657cf4c6562b3aa2daebcd25be7c9ece7d6cca18 2026-11-20T07:57:34+01:00` (the plan's
   recorded Window, verified). `git log origin/master --since="$W" --oneline -E
   --grep='\(b27-' | wc -l` -> `0`. `git ls-remote origin | grep -E 'b27-[0-9]{2}|bug-round-27'`
   -> only `282437e3a... refs/heads/review/c002-bug-round-27-planner` (the
   planner's own review branch, expected; my own seat branch appears only after
   my push below). `ls /var/spool-hub/dispatch/briefs | grep -E 'b27-[0-9]{2}|bug-round-27'`
   -> `c002-bug-round-27-mistral-panel-seat.md` (this brief), `c002-bug-round-27-planner.md`
   (the planner's) — both expected. `git worktree list | grep -E 'b27-[0-9]{2}|bug-round-27'`
   -> `/opt/csi/csi-spl-wt/c-275 ... [c-275-c002-bug-round-27-planner]` and
   `/opt/csi/csi-spl-wt/m-284 ... [m-284-c002-bug-round-27-mistral-panel-seat]` — both
   expected. Nothing else. PASS.

2. **Row sites on `0509f0b7b` and origin/master.** `git diff --name-only 0509f0b7b
   origin/master -- csi-spl-orc/src/bash/run/spl-review-go.func.sh
   csi-spl-orc/src/bash/tests/spl-review-go.tst.sh csi-spl-orc/src/bash/run/run.sh
   csi-spl-orc/src/bash/run/spl-spawn-place.func.sh
   csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh
   csi-spl-orc/src/bash/run/spl-lane-mix.func.sh
   csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh` -> empty (no drift;
   origin/master is now `1c18a5be`, but no row file changed, N1). Each cited line
   checked with `git show 0509f0b7b:<file> | sed -n <N>p` (and the files are
   identical on origin/master, spot-checked
   `git show origin/master:csi-spl-orc/src/bash/run/spl-spawn-place.func.sh | sed -n 1038p`
   -> `spl_spawn_place_review_seat() {  # BRIEF KIND`):
   - `spl-review-go.func.sh:168-170` `_spl_review_go_seen` with
     `grep -qE "^(PASS|WAIT) [^ ]+ $1 | review-go $1 "`; `:735`
     `local holder="$1" msg="$2" task="$3" ...`; `:765`
     `do_log "INFO msg $msg: the reviewed ${sha:0:12} $where" >&2`; `:769`
     `_spl_review_go_send "$holder" "$msg" ...`; `:796` `_spl_review_go_elsewhere() {`;
     `:816` `git -C "$repo" merge-base --is-ancestor "$2" "$head"`; `:855`
     `printf 'PASS %s %s %s %s %s %s\n' ... "$2" ... >>"$8"` — all as the plan says.
   - `spl-review-go.tst.sh:194-206` `run()` with the stub at `:201`
     `do_log() { echo "$*"; }`; `:860` case-23 header; `:928` case 23a RED CONTROL.
   - `run.sh:600` `do_log() {`; `:669`/`:671` `msg=" $type_padded ..."`;
     `:675` end of the do_log block.
   - `spl-spawn-place.func.sh:107-110` @description (review seat stays mistral);
     `:1003-1010` swap comment; `:1011` `spl_spawn_place_swap() {`; `:1028`
     `case "$kind" in specs_and_docs|i18n) to=agy ;; esac`; `:1031` `}`; `:1033-1041`
     `spl_spawn_place_review_seat()` (`*-reviewer` / `review` / `code_review` only).
   - `spl-spawn-queue.tst.sh:1102-1130` the SPL-3776 / SPL-3954 cases;
     `spl-lane-mix.func.sh:255-268` `spl_lane_mix_ui_target` (grep
     `csi-spl-wui/[[:alnum:]_]` in the brief); `spl-spawn-review-notify.func.sh:86-92`
     the other caller. PASS.

3. **Red controls.** `sha256sum /var/spool-hub/dispatch/b27-red-controls/rc0{1,2}.sh`
   -> `033471141b250a8d3398e3b6e6267a391efb20533b05f2e378ce20fd74cfea86  rc01.sh`
   (1702 B), `e485e559a988a0661d79aaee5f5f680b8b915f60b59e6f52266551dc485e0ca6  rc02.sh`
   (1713 B) — first 12 hex `033471141b25` / `e485e559a988` and sizes 1702/1713 B,
   exactly as the plan's section 3.2 states; both files `diff`-identical to the
   code blocks the plan prints. Run from a scratch clone at `0509f0b7b`
   (`git clone /opt/csi/csi-spl-wt/m-284 <scratch> && git checkout 0509f0b7b`;
   tools present: bash, git, python3, yq v4.43.1):
   - rc02, n=1: `bash rc02.sh 0509f0b7b
     /var/spool-hub/dispatch/briefs/hand-<box2>-c002-bug-round-26-mistral-panel-seat.md
     /var/spool-hub/dispatch/briefs/c002-refactor-round-73-mistral-panel-seat.md` ->
     `rc02 x-mistral-panel-seat.md -> agy (mistral takes no UI work until
     do_spl_vendor_ui_retest passes (the brief names csi-spl-wui/))` /
     `rc02 x-mistral-reviewer.md -> mistral` /
     `rc02 hand-<box2>-c002-bug-round-26-mistral-panel-seat.md -> agy (...)` /
     `rc02 c002-refactor-round-73-mistral-panel-seat.md -> mistral` /
     `rc02 sha=0509f0b7b panel-seats-swapped=2`, exit 1 — identical to the plan's
     row-02 output. RED for the plan's reason (a `-panel-seat` brief swaps to agy),
     not for an environment reason.
   - rc01, n=2 (clean sequential runs, 07:59:39Z-08:03:39Z and 08:03:39Z-08:07:40Z):
     both exit 1, both print
     `rc01 do_log functions taken from run.sh: 8`,
     `FAIL: 23a. RED CONTROL: the row's branch is not on origin, the sha is on the local branch of that name -> GO, 'found locally only': rc=0 sent=SEND --from c-002 ...`,
     `FAIL: 23a. the sha in the HEAD of a worktree named for the author (branch nowhere) -> GO, 'found locally only': ...`,
     `rc01 other: FAIL: 10. bad max`,
     `rc01 sha=0509f0b7b suite-rc=1 23ac-go-fail=5 6 FAIL total`
     — identical to the plan's run 3 (`23ac-go-fail=5`, `6 FAIL total`, exit 1).
     RED 2/2 for the plan's reason (a): each elsewhere GO's PASS record holds the
     do_log line, so `_spl_review_go_seen` never matches. The 6th FAIL (case 10
     "bad max") is a format artifact, as the plan says: `spl-review-go.tst.sh:359`
     greps the stub's plain `FATAL REVIEW_GO_MAX_AGE`, which the real `do_log`
     prints as `[FATAL]` (`run.sh` `print_fatal`) — TRUE, and it does not decide
     rc01's exit. rc01 never sends a real GO and never touches the live review-go
     state or cron: the suite's `run()` sets `REVIEW_GO_SEND="$T/send.sh"` (stub ->
     `$T/s/sent.log`), `SPOOL_ROOT="$S"` (temp), `REVIEW_GO_REPO="$T/repo"` (tst:197);
     `grep -c 'PASS [^ ]* *\[INFO\]' /var/spool-hub/dispatch/automation.log` -> 4
     before and 4 after my runs. Contrast: the unchanged suite on `0509f0b7b`
     (`bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`) -> 179 `PASS` lines,
     `spl-review-go: 0 failure(s)`, exit 0 — as the plan claims. PASS.

4. **Root cause b27-01.** (a) `run.sh:600` `do_log() {` declares only
   `local display_type _do_log_day` (:619); its comment (:617-618) says it sets
   the globals `type_of_msg, action, rest_of_msg, msg, log_dir, log_file`, and
   `_do_log_format_line` sets `msg=` at :669/:671. `_spl_review_go_one` declares
   `local ... msg="$2"` at :735, calls `do_log "INFO msg $msg: ..." >&2` at :765,
   then passes `"$msg"` to `_spl_review_go_send` at :769, which writes it into the
   PASS record at :855. By bash dynamic scope the `do_log` write lands in the
   caller's local `msg` — the plan's reading holds; `_spl_review_go_seen`
   (:168-170) then never matches. The suite's stub at tst:201 sets no global, so
   it hides the defect. (b) `_spl_review_go_elsewhere` (:796-835): the ls-remote
   awk matches only `refs/heads/<author>-*` or `refs/heads/<branch><sep>` pointing
   AT the sha; then the local branch check at :806
   (`merge-base --is-ancestor "$2" "refs/heads/$1"` — local refs only) and the
   worktree HEADs at :816-831. `grep -n 'origin/master' ` over :796-835 -> no
   hits: no is-ancestor check on origin/master exists there. Demonstrated:
   `git merge-base --is-ancestor 657cf4c65 origin/master` -> rc 0, yet with a
   local branch `review/c002-x-demo` at `657cf4c65`,
   `_spl_review_go_elsewhere review/c002-x-demo 657cf4c65... c-999 ""` -> rc 0,
   `is on this box's local branch 'review/c002-x-demo' only, not on origin: found
   locally only, the author must still push it`. The live event's sha:
   `git merge-base --is-ancestor 767aa329c origin/master` -> rc 0;
   `grep -c 'PASS [^ ]* *\[INFO\]' /var/spool-hub/dispatch/automation.log` -> 4,
   lines 2884-2886 and 2888 hold the `[INFO]` log line in the PASS record (2887 is
   c-001's hand-written clean PASS). PASS.

5. **Root cause b27-02.** `spl_spawn_place_review_seat` (:1038-1041) returns "is a
   review seat" only for a brief basename ending `-reviewer` or kind
   `review`/`code_review`; a `*-panel-seat` slug with `Kind: specs_and_docs` is
   NOT exempt today. In `spl_spawn_place_swap` (:1011-1031) the review-seat check
   comes first (:1016-1021: stays mistral, or `refuse` on a mistral author);
   otherwise `spl_lane_mix_mistral_ui_off "$cnf" "$2" ""` (:1023) ->
   `spl_lane_mix_ui_target` (:261-268) greps the brief for `csi-spl-wui/[[:alnum:]_]`
   -> `the brief names csi-spl-wui/` -> why non-empty -> kind specs_and_docs ->
   `to=agy` (:1028). rc02 above demonstrates the swap. The fix scope keeps a WRITE
   seat under the UI rule: the exemption sits before the UI check, so a WUI build
   row (not a review seat) still swaps — consistent with the plan's "SPL-3954
   controls stay green". PASS.

6. **Per-row R2/tests/vendor/kind/batch, R7, R1.** `git grep -l
   'spl-review-go\|_spl_review_go_\|do_spl_review_go' 0509f0b7b --
   csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` ->
   `orc-shard-weights.txt`, `spl-accepted-close.tst.sh`, `spl-review-go.tst.sh`
   (the plan names the same three). `git grep -l 'place_swap\|review_seat\|panel-seat'
   0509f0b7b -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` ->
   `spawn-agents/tests/test-lane-issue.sh`, `spl-box-pick.tst.sh`,
   `spl-spawn-place-argmax.tst.sh`, `spl-spawn-queue.tst.sh` (the same four). Both
   rows: vendor claude, kind `simple_coding`, batch 1 — no mistral coding or
   testing row. R7: claude waiver seat (1a7c70da) unless box_pick picks grok;
   `SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (csi-spl-orc)
   -> `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [...]: queue the
   lane, spawn nothing` — as the plan's section 8 records, so the R7 is the claude
   waiver seat, never mistral. R1: the two rows' file sets
   (`spl-review-go.func.sh`+`spl-review-go.tst.sh` vs
   `spl-spawn-place.func.sh`+`spl-spawn-queue.tst.sh`) share 0 files (`comm -12`
   -> 0). PASS.

7. **R3 lane map.** `bash .../spawn-agents/scripts/lane-map.sh --check
   csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh,csi-spl-orc/src/bash/run/run.sh,csi-spl-orc/src/bash/run/spl-lane-mix.func.sh,csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh
   --agent m-284` -> `WARN no live lane lists` them; `FATAL ... status 4`, exit 4;
   unknown no-file lanes: `c-049@<box2> c-049-rotate`, `c-060@<box2>`, `c-625@<box2>`,
   `c-812@<box2>`, `c-924@<box2> c-924-rotate-2`, `c-927@<box2>` — the same 6 the
   plan recorded at 07:27:14Z (N2). `lane-map.sh --all` -> no live lane lists any
   row file; live lanes are c-275@sat (the planner), m-256@sat (r73 panel), the
   c-001 roles, c-625@<box2> (spec 181, doc) and the rotate seats on the ops
   channel of `<box2>`; c-280@sat
   (r73-02) is no longer live — it landed `1c18a5be`. No row file is touched by any
   of them. Exit 4 means ask-first, not free; the plan says the orchestrator
   re-runs R3 before the spawn. PASS (with N2).

8. **Inputs accounted.** b26 plan section 7's four first inputs are all accounted
   in plan section 4: the done-claim `job` label (0 alerts since W -> not a row),
   `test-agent-name-shape.sh:89` (not seen red), the AltGr picker (carried), the
   blog switcher's Enter (product question, carried). The candidates file's
   "next BUG round" / "Bug-shaped" entries: retired-author GO retry (line 32) ->
   fixed `2f634fbd4` (plan s5); the 13:40Z section (line 37): OS-user hermeticity
   (not reproduced, s5), review-notify author line -> fixed `3e46a758c` (s5),
   sha256sum prefix -> fixed SPL-5990 (s5); the 19:3xZ section (line 43): Rows A/B
   -> detectors (s5); the 06:2xZ placer gap (line 51) -> row 02; the 07:3xZ
   review-go re-PASS + loop (lines 53-54) -> row 01; SPL-5850 AltGr -> s4. NOT
   accounted: line 35, `SPL-5960 R7 c-395@<box2> N3: csi-spl-wui/tests/e2e/blog.test.mjs:329
   "picking bg lands on /bg/blog/..." fails on BASE 67232dbc8 3/3 when run alone
   ... Bug-round candidate (msg 577d03b7)` — plan sections 4 and 5 never mention
   it (section 4's blog row is the Enter-on-one-match product question, a
   different input). See W1. FAIL on this check.

9. **Distribution hygiene.** `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
   `ok - non-Csitea org or bank reference`, `ok - personal name`,
   `ok - literal OS user / box / AD id`, `ok - personal home directory`,
   `ok - owner mail address or domain`, `ok - hidden workspace or private literal`,
   `ok - retired relay estate`, `ok - no tracked .vibe/ dir`,
   `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-284`,
   exit 0. PASS.

## Defects

- **W1:** the plan's accounting claim is false for one bug-shaped input.
  `/var/spool-hub/dispatch/c002-next-round-candidates.md:35` (SPL-5960 R7 N3,
  `csi-spl-wui/tests/e2e/blog.test.mjs:329` fails 3/3 when run alone on BASE
  `67232dbc8`, marked "Bug-round candidate (msg 577d03b7)") is neither a row nor
  accounted for in plan sections 4 or 5, contradicting plan line 8 ("every other
  input is accounted for in sections 2, 4 and 5") and line 40 ("The other 8:
  sections 4 and 5"). Fold into v1.0: one row in section 4 or 5 accounting for it
  (e.g. "not a row: test-isolation flake, passes in the suite, no rule broken —
  carried on its condition"), or serve it as a row if the panel rules it one.

## Notes

- **N1:** origin/master moved past the plan's measurement sha during my read:
  `0509f0b7b` -> `1c18a5be` (`refactor(r73-02-..., SPL-6020)`, 2026-11-20T09:45:28+02:00).
  No row file drifted (`git diff --name-only 0509f0b7b origin/master -- <row files>`
  empty), so every site holds on both shas.
- **N2:** lane-map exits 4 (unknown no-file lanes) on the row paths, as in every
  recent round and as the plan itself recorded at 07:27:14Z; the 6 unknown lanes
  are all orchestrator rotation seats on `<box2>` recording no files. No live lane
  lists a row file.
- **N3:** rc01's 6th FAIL (case 10 "bad max") is a format artifact, not the row's
  defect: tst:359 greps the stub's plain `FATAL REVIEW_GO_MAX_AGE`; the real
  `do_log` prints `[FATAL]`. The plan says exactly this; verified.
- **N4:** rc01 sends no real GO and touches no live review-go state or cron: the
  suite stubs `REVIEW_GO_SEND` to `$T/send.sh` and runs on a temp `SPOOL_ROOT`;
  `grep -c 'PASS [^ ]* *\[INFO\]' /var/spool-hub/dispatch/automation.log` was 4
  before and 4 after my two rc01 runs.
- **N5:** my replay of `_spl_review_go_elsewhere review/c002-refactor-round-73-planner
  767aa329c... c-247 ""` matched the author ref still on origin
  (`refs/heads/c-247-c002-refactor-round-73-planner`) -> "is the tip of origin ref
  ...", rc 0 (the 23c case); the "found locally only" case I demonstrated
  separately with `657cf4c65` + a local branch (check 4b).
- **N6:** two further candidates entries are not marked "Bug-shaped"/"next BUG
  round" and are also unaccounted, noted for completeness, not counted in W1:
  line 33-34 (a) SPL-5936 restart/salvage staged files, (b) SPL-5613 wip-hygiene
  refusing landed shas — both marked "not re-checked by me" by the holder.

## Re-check of v0.2 `58f34ab8d3af7ea0e72a07bc01526c6ee563ac1a` (2026-11-20 08:2x-08:29Z, sat)

Asked by c-002@sat, msg `1e2e7711-fff7-4c09-953a-6e4d2f2f0687` (task
`dispatch-bug-r27`): c-275 pushed v0.2 (its msg 2830291a) folding W1 and N6;
re-review the diff and the W1/N6 rows. Provenance, all run now:

- `git ls-remote origin review/c002-bug-round-27-planner` ->
  `58f34ab8d3af7ea0e72a07bc01526c6ee563ac1a`.
- `git fetch origin review/c002-bug-round-27-planner`;
  `git merge-base --is-ancestor 282437e3a0290271ec47aedc3ba5c10cd50a305f
  58f34ab8d3af7ea0e72a07bc01526c6ee563ac1a` -> rc 0: v0.2 is a fast-forward of
  v0.1.
- `git diff --stat 282437e3a 58f34ab8d` -> `csi-spl-doc/doc/md/bug-round-27-plan.md
  | 29 +++...  1 file changed, 17 insertions(+), 12 deletions(-)`;
  `git log --oneline 282437e3a..58f34ab8d` -> one commit, `58f34ab8d docs(b27-plan,
  SPL-6019): bug round 27 plan v0.2, panel W1 folded: ...`. Hunk headers
  (`git diff ... | grep '^@@'`): `@@ -10,9 +10,9 @@`, `@@ -36,8 +36,8 @@`,
  `@@ -58,7 +58,7 @@` (status/panel header, both boxes' slug halves),
  `@@ -164,6 +164,9 @@` (section 5: three new rows), `@@ -181,19 +184,21 @@`
  (review history), `@@ -201,5 +206,5 @@` (seats table). No hunk touches the
  rows table: `sed -n '/^| 0[12] /p'` of the plan at both shas, `diff` of the
  two -> empty (rows byte-identical).

W1 fold, re-verified row by row (v0.2 plan line 167): the candidates-file
line 35 input (SPL-5960 R7 N3, `blog.test.mjs:329` alone-run, "Bug-round
candidate (msg 577d03b7)") is now a section-5 row marked **Served** by b26-01
`c540aca24`. The row's evidence commands, re-run by me now, print what the row
claims:

- `git show origin/master:csi-spl-doc/doc/md/bug-round-26-plan.md | grep -c
  577d03b7` -> `1` (line 48, row 01's evidence cites msg 577d03b7);
- `git show origin/master:csi-spl-doc/doc/md/bug-round-26-plan.md | grep -n
  'alone-run'` -> line 40, source 5: "**1 row**: 01 from the
  `blog.test.mjs:329` alone-run" — round 26's row 01 was made from exactly
  this input;
- `git merge-base --is-ancestor c540aca24 origin/master` -> rc 0;
  `git log -1 --format='%h %s' origin/master -- csi-spl-wui/tests/e2e/blog.test.mjs`
  -> `c540aca24 test(b26-01-wui-blog-switcher-e2e-runs-in-ci, SPL-6016): ...` —
  the file is unchanged since b26-01 landed.

So the input is served, not merely asserted: the alone-run became b26 row 01,
which landed as `c540aca24`. W1 is folded.

N6 fold, re-verified (v0.2 plan lines 168-169): line 34 (b) SPL-5613 -> **Fixed**
by `1ce9158a1`: `git log -1 --format='%h %s' 1ce9158a1` ->
`1ce9158a1 fix(b21-02-orc-pre-push-msg-sweep-skips-master, SPL-5964): the
pre-push message sweep skips commits already on master`;
`git merge-base --is-ancestor 1ce9158a1 origin/master` -> rc 0. Line 34 (a)
c-091's 51 staged files (SPL-5936) -> **Closed in round 22**:
`git grep -n 'c-091' origin/master -- 'csi-spl-doc/doc/md/bug-round-2*-plan.md'`
-> hits in b20 (lines 109, 120, 131), b21 (88, 100, 119) and b22 (130: "Closed
as round 21 says."). Both N6 items are now accounted in section 5.

The accounting claim is now true: v0.2 line 8 is unchanged ("every other input
is accounted for in sections 2, 4 and 5") and line 40 (source 5) now reads
"4 + 9 inputs ... The other 11: sections 4 and 5" — line 35 sits at section 5
line 167 and line 34 (a)/(b) at lines 168-169, so the count holds.

**Verdict: PASS on `58f34ab8d3af7ea0e72a07bc01526c6ee563ac1a`.** W1 and N6 are
folded verifiably (each fold row's evidence commands re-run by me print what
the row claims), the rows table is byte-identical to v0.1, the diff touches
only the plan file, and v0.2 is a fast-forward of v0.1. Per the brief the
final signature waits for the editor's v1.0 sha; if c-275 names v0.2 as final,
this PASS is the signature on it.

- **N7:** origin/master moved again during the re-check (`1c18a5be` ->
  `af8ca0ba7`, `docs(r73-plan, SPL-6017): ... rows 01-02 landed 0509f0b7b
  1c18a5be8`); `git diff --name-only 0509f0b7b origin/master -- <the 7 row
  files>` -> empty (no drift), and `git merge-base --is-ancestor
  58f34ab8d3af7ea0e72a07bc01526c6ee563ac1a origin/master` -> rc 1 (v0.2 is
  still review-branch only, not on master).

## Signature on v1.0 `e8be57d8603c33fcfda0f5e6fcbed2715c68d080` (2026-11-20 08:3xZ, sat)

Named by c-275@sat, msg `2d13ef84-1fe8-47ef-b641-9fa7c70f332b` (task
`dispatch-bug-r27`): "Plan v1.0 for your signature". Provenance, all run now:

- `git ls-remote origin review/c002-bug-round-27-planner` ->
  `e8be57d8603c33fcfda0f5e6fcbed2715c68d080`.
- `git fetch origin review/c002-bug-round-27-planner`;
  `git merge-base --is-ancestor 58f34ab8d3af7ea0e72a07bc01526c6ee563ac1a
  e8be57d8603c33fcfda0f5e6fcbed2715c68d080` -> rc 0: v1.0 is a fast-forward on
  v0.2.
- `git log --oneline 58f34ab8d..e8be57d8` -> one commit, `e8be57d86 docs(b27-plan,
  SPL-6019): bug round 27 plan v1.0, m-284 mistral PASS on v0.2 58f34ab8d
  recorded; no row changed`.
- `git diff --stat 58f34ab8d e8be57d8` -> `csi-spl-doc/doc/md/bug-round-27-plan.md
  | 12 ++++---  1 file changed, 7 insertions(+), 5 deletions(-)`;
  `git diff --name-only 58f34ab8d e8be57d8` (whole tree) -> the plan file only.
  Hunk headers: `@@ -10,9 +10,9 @@` (status/panel header), `@@ -198,7 +198,9 @@`
  (review history), `@@ -206,5 +208,5 @@` (seats table). No hunk touches the
  rows table or sections 4/5: `sed -n '/^| 0[12] /p'` of the plan at v0.2 and at
  v1.0, `diff` -> empty (rows byte-identical).
- The PASS line v1.0 records (plan line 202) cites msg `7123b99f` and seat sha
  `cc71525dd` — both mine and both correct: `7123b99f-d8d7-4ae5-9385-3eee76ec3725`
  is my v0.2 PASS result sent to c-275@sat at 2026-11-20T08:32:38Z, and
  `git ls-remote origin review/c002-bug-round-27-mistral-seat` ->
  `cc71525dda1754db2373110cba142f57f9143f28` (this seat branch's tip). The v0.2
  history time is corrected to 08:22Z (plan line 201), matching the dispatch
  task msg `1e2e7711` ts 2026-11-20T08:22:42Z.
- `git merge-base --is-ancestor e8be57d8603c33fcfda0f5e6fcbed2715c68d080
  origin/master` -> rc 1: v1.0 is review-branch only, not on master.

**Signature: PASS on `e8be57d8603c33fcfda0f5e6fcbed2715c68d080`.** v1.0 is a
fast-forward on the v0.2 I passed, touches only the plan file, changes no row
and no section 4/5 accounting, and records my v0.2 PASS with the correct msg
id and seat sha. I sign it.
