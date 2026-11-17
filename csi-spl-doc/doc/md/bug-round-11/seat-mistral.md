# Bug round 11 - mistral panel seat verdict

Reviewer: m-977@sat (mistral; doc review only, no code written, no file but this one touched)
Plan under review: `csi-spl-doc/doc/md/bug-round-11-plan.md` v0.1, commit
`dec0c34d6850d3ed80dd5e6d793665686c79ac0f` on `origin/review/c002-bug-round-11-planner-r2`
(named by c-964@sat on task `dispatch-e1139a1e`, msg 2026-11-17T11:04:29Z; no later
v0.2/v1.0 named as of 2026-11-17T11:17Z).
Fetch proof: `git fetch origin review/c002-bug-round-11-planner-r2 && git rev-parse FETCH_HEAD`
-> `dec0c34d6850d3ed80dd5e6d793665686c79ac0f`;
`git ls-remote origin 'refs/heads/review/c002-bug-round-11-planner-r2'` ->
`dec0c34d6850d3ed80dd5e6d793665686c79ac0f`.
`git show dec0c34d6 --stat` -> one file, `csi-spl-doc/doc/md/bug-round-11-plan.md | 128 ++++`.
Every plan line number below was read with
`git show dec0c34d6850d3ed80dd5e6d793665686c79ac0f:csi-spl-doc/doc/md/bug-round-11-plan.md | sed -n '<N>p'`.
`<box2>` below is the other box's short name, elided the same way the plan elides it
(distribution-hygiene bans the literal in a tracked doc).

## Verdict

**PASS** on `dec0c34d6850d3ed80dd5e6d793665686c79ac0f`, with one defect (W1: a
source-row count that does not reproduce; it does not change the row verdict)
and notes N1-N3. Both rows' red controls reproduce when re-run; every cited
site exists at `d0137722c` and on `origin/master`, and the two row files are
byte-identical between those shas (`git diff d0137722c origin/master -- <files>` -> empty).

## Checks (each with the command run and what it printed)

### 1. Slug b11 unused
- `git log origin/master --oneline -E --grep='\(b11-' | wc -l` -> `0`
- `git ls-remote origin 'refs/heads/*b11-*' | wc -l` -> `0`

### 2. Row sites exist at `d0137722c` and on `origin/master`
`F=csi-spl-orc/src/bash/run/spl-review-go.func.sh`; per range, `git show <sha>:$F | sed -n '<a>,<b>p'`:
- `:229-246` -> `_spl_review_go_brief() {` at 229, `}` at 246 (both shas)
- `:456-468` -> `_spl_review_go_abrief() {` at 456, `}` at 468 (both shas)
- `:475-483` -> `_spl_review_go_tied() {` at 475, `}` at 483 (both shas)
- `:624` -> `_spl_review_go_owner_go() {`; `:627-628` -> the two keyword greps
  (627: `kw="$(grep -oiE '\bapply\b' <<<"$text")"`, 628: the second keyword list) (both shas)
- `:674-677` -> the rc 7 hold; line 675:
  `{ _spl_review_go_hold "$@" 7 "author $author has no brief on this box $here ...": not verified"; return 7; }` (both shas)
- `T=csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`: 959 lines at both shas; line 236 ->
  `for kw in 'DRY_RUN=0' 'PROBE_PRD_GO' 'billing' 'service account key' '/etc/hosts' 'do-tf-apply'; do`

No site drifted between `d0137722c` and `origin/master`.

### 3. Row attributes (plan lines 48-49 rows, 53-54 batches, 61-66 red controls, 102-107 counts)
- Red control per row with command and output: plan 3.2 lines 65-66; both re-run by me (check 4).
- Test column: both rows name `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`.
- Vendor `claude`, kind `simple_coding`, preferred box `sat`, batches 1 and 2 (plan lines 48-49).
- R1: plan 3.1 (lines 53-54) puts row 01 in batch 1 and row 02 in batch 2 on the SAME two
  files, batch 2 starting after row 01 is on trunk (R1, R16) - it says so.
- No mistral coding or testing rows: both rows vendor claude.
- R7 per row (plan lines 48-49): grok if `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` picks a
  box at row time, else a claude waiver seat - never mistral. c-002@sat settled R7 = claude
  waiver seat with the GO by hand (task `dispatch-e1139a1e`, 2026-11-17T10:58:08Z).
- Round size 2 <= 10 (plan line 8, rulebook 1.1); consensus: no owner go (plan line 9, rulebook 1.4).

### 4. Red controls re-run (read-only, DRY_RUN=1, no prd write)
Row 02 (plan line 66), from the worktree (row files identical to `d0137722c`, check 2):
`DRY_RUN=1 bash -c 'do_log(){ :; }; source csi-spl-orc/src/bash/run/spl-review-go.func.sh; _spl_review_go_owner_go /var/spool-hub/dispatch/briefs/c002-bug-review-go-fixture-c710-brief.md c-002; echo "rc=$?"'`
-> `the author brief names owner-go keyword 'apply' and has no Owner-go: line`, `rc=1`. **Reproduces.**
Mechanism: `echo 'apply-gh-runner-cpu-budget' | grep -oiE '\bapply\b'` -> `apply` (rc 0): `-` is a
word boundary, so `\bapply\b` matches inside the hyphenated test name. The fixture's line 19
holds `` `apply-gh-runner-cpu-budget` `` (`sed -n '19p'` on the brief file).

Row 01 (plan line 65): copied review msg d3a83a98
(`/var/spool-hub/c-002/archive/20261114T120133Z--g-524@<box2>--review-g-524-<box2>-grok-pass-98a31-d3a83a98.json`)
with a new msg id `835fbbfe-977e-4801-acca-80326a3e7cdf` into a temp file, then
`cd csi-spl-orc && SPOOL_ROOT=/var/spool-hub REVIEW_GO_MAX_AGE=99999 REVIEW_GO_MSG=<temp file> DRY_RUN=1 ./run -a do_spl_review_go`
-> `PLAN HOLD msg 835fbbfe-977e-4801-acca-80326a3e7cdf (rc 7): author c-490 has no brief on this box sat (author box <box2>; not /var/spool-hub/c-490/lifetime/brief.md, an Author brief: line in /var/spool-hub/dispatch/briefs/hand-<box2>-c002-spl5507-dochub-client-grok-reviewer.md or the lane map): not verified`,
exit 7. **Reproduces.**
Supporting reads: reviewer brief line 9 -> `Author: c-490@<box2> (claude)`; the author placement
brief `hand-<box2>-c002-dochub-shared-client-v1v2-fold.md` is on this box and
`grep -c -E 'c-490-shared-client|98a3198'` on it -> `0`; `/var/spool-hub/c-490/lifetime/` does
not exist on sat.

Row 02's other cases (plan line 49): `_spl_review_go_owner_go` on
`c002-bug-quota-env-knob-pick-hop-5432-followups.md` -> rc 0; on
`hand-sat-c001-tf-002-billing-grants-apply.md` -> rc 1 (`keyword 'APPLY'`). Both as claimed.

### 5. Section 2 source rows re-run (read-only)
- Source 3 (plan line 38):
  `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" d0137722c -- "$d" | wc -l; done`
  -> `csi-spl-api: 197`, `csi-spl-wui: 17`, `csi-spl-orc: 10`, `csi-spl-iac: 21`, `csi-spl-utl: 0`
  (245 total, as the plan). `git show d0137722c:csi-spl-wui/tests/e2e/ci-skip.txt` -> 8 lines =
  4 comment lines + 4 entries; `git show 1663c828b:...ci-skip.txt` -> the same 4 entries.
  The "0 rows" verdict agrees.
- Source 4 (plan line 39): `SPOOL_ROOT=/var/spool-hub spool tail --task gc-sat` -> 1692 lines;
  rows with ts >= 2026-11-16T10:41Z: 104 notes, 48 `GC sat` cycles, 48 with ` 0 restarted`,
  3 with ` 1 close asked`, 0 alarm lines. The plan measured 103 notes / 47 cycles at its
  10:41-10:50Z bound; one more cycle has run since. The "0 rows" verdict agrees.
- Source 5 log part (plan line 40):
  `awk '$2=="review-go" && $1>="2026-11-10" && $1<"2026-11-17T10:41:19Z"' /var/spool-hub/dispatch/automation.log | grep -oE ' rc=[0-9]+ ' | sort | uniq -c`
  -> `95 rc=1, 92 rc=2, 60 rc=3, 29 rc=4, 11 rc=5, 45 rc=6, 36 rc=7` (368 lines) - the per-rc
  hold counts match the plan exactly. But `grep -c ' rc=0 ' /var/spool-hub/dispatch/automation.log`
  -> `0`: the log holds no rc 0 lines at all, so the plan's "736 checks: rc 0 368" does not
  reproduce (W1).
- Row evidence counts (plan lines 48-49): rc 7 per day 2026-11-11..15 -> 2, 1, 8, 7, 18
  (36 total, all 36 containing `has no brief on this box`; 0 on 11-16 and 11-17 at the plan's
  bound); rc 4 since 11-11 -> 29; rc 2 since 11-15 at the plan's bound -> 43 (section 4,
  plan line 74). All reproduce.

### 6. R3 lane-map
- `bash .../spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh --agent m-977`
  -> exit 4: no live lane lists the two files; 16 live lanes record no files (all @<box2>:
  c-051, c-054, c-060, c-092, c-382, c-390, c-528, c-545, c-570, c-669, c-714, c-875, c-888,
  c-924, c-927, c-966) - unknown scope, ask-first per the rule. The plan's 3.1 (line 57)
  recorded exit 4 with 6 such lanes at 10:48:43Z and assigns the re-check to the orchestrator
  before each spawn.
- `lane-map.sh --check csi-spl-doc/doc/md/bug-round-11/seat-mistral.md --agent m-977` -> exit 4
  (no lane lists this file; same 16 unknown lanes).
- `lane-map.sh --check csi-spl-doc/doc/md/bug-round-11-plan.md --agent m-977` -> exit 3:
  owned by c-964@sat (the planner) - this seat does not touch it.

### 7. Distribution hygiene
`cd csi-spl-iac && ./run -a do_check_dist_hygiene`
-> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-977`, exit 0.

## Defects

- **W1** - plan line 40 (section 2, source 5): "review-go since 11-10: 736 checks: rc 0 368,
  rc 1 95, ..." does not reproduce. `awk '$2=="review-go" && $1>="2026-11-10" && $1<"2026-11-17T10:41:19Z"' /var/spool-hub/dispatch/automation.log | wc -l`
  -> `368`, and `grep -c ' rc=0 ' /var/spool-hub/dispatch/automation.log` -> `0` (the log
  records holds only; no rc 0 line exists in it). The per-rc hold counts
  (95/92/60/29/11/45/36) do reproduce at the plan's bound. The row verdict ("2 rows" from the
  two known rows, both re-run green-red here) does not depend on this count; fold the
  correction into v0.2.

## Notes

- **N1** - plan line 49 (row 02 evidence): `git show d0137722c:csi-spl-orc/src/bash/tests/spl-review-go.tst.sh | grep -n -E 'apply-|-apply'`
  matches lines 236 and 242 (both `do-tf-apply`), not only line 236. Substance holds: the suite
  has no hyphenated `apply-...` case.
- **N2** - lane-map exit 4 lists 16 unknown-scope lanes now vs 6 at the plan's 10:48:43Z check
  (all @<box2>); per the rule they are asked first, never treated as free. The plan already
  assigns the re-run to the orchestrator before each spawn (R3, plan line 57).
- **N3** - source 4 counts are 104 notes / 48 GC cycles now vs 103 / 47 at the plan's bound (one
  more cycle since); all cycles ` 0 restarted`, 3 ` 1 close asked`, 0 alarms. Verdict agrees.

## ran:
`git fetch origin review/c002-bug-round-11-planner-r2; git rev-parse FETCH_HEAD; git ls-remote origin refs/heads/review/c002-bug-round-11-planner-r2; git show dec0c34d6 --stat; git log origin/master --oneline -E --grep='\(b11-' | wc -l; git ls-remote origin 'refs/heads/*b11-*' | wc -l; git diff d0137722c origin/master -- csi-spl-orc/src/bash/run/spl-review-go.func.sh csi-spl-orc/src/bash/tests/spl-review-go.tst.sh; git show <sha>:csi-spl-orc/src/bash/run/spl-review-go.func.sh | sed -n '229,246p' (and 456-468, 475-483, 624-630, 674-677) at d0137722c and origin/master; git show <sha>:csi-spl-orc/src/bash/tests/spl-review-go.tst.sh | sed -n '236p' | grep -n -E 'apply-|-apply'; DRY_RUN=1 bash -c 'do_log(){ :; }; source csi-spl-orc/src/bash/run/spl-review-go.func.sh; _spl_review_go_owner_go /var/spool-hub/dispatch/briefs/c002-bug-review-go-fixture-c710-brief.md c-002'; echo 'apply-gh-runner-cpu-budget' | grep -oiE '\bapply\b'; SPOOL_ROOT=/var/spool-hub REVIEW_GO_MAX_AGE=99999 REVIEW_GO_MSG=/tmp/review-go-msg-835fbbfe-977e-4801-acca-80326a3e7cdf.json DRY_RUN=1 ./run -a do_spl_review_go (in csi-spl-orc); for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do git grep -n -E '(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)' d0137722c -- "$d" | wc -l; done; SPOOL_ROOT=/var/spool-hub spool tail --task gc-sat; awk/grep counts on /var/spool-hub/dispatch/automation.log; lane-map.sh --check <rows' paths> --agent m-977; lane-map.sh --check csi-spl-doc/doc/md/bug-round-11/seat-mistral.md --agent m-977; cd csi-spl-iac && ./run -a do_check_dist_hygiene`
