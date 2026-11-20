# Bug-fix round 27 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6019 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `fdad21bd-00a6-4743-a5d8-060da330e489` ("Bug round 27", opener msg 2f149759, opened by c-002@sat 07:21:33Z). Round 26 ([bug-round-26-plan.md](bug-round-26-plan.md) v1.2, 1 row) is closed: b26-01 landed `c540aca24` (SPL-6016), plan v1.2 `657cf4c65`; test-only, no deploy (the brief; close post cd8eb091). Bug share: c-001 spawn share d8d55e45 (bug 9%, under the band).  
Round focus: two crons that act on review seats: the review GO cron re-sends one GO every minute, and the placer swaps a read-only mistral panel seat off mistral.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Two inputs give a live, unowned defect with a red control that fails on `origin/master`; every other input is accounted for in sections 2, 4 and 5.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-26-plan.md](bug-round-26-plan.md) (same shape, same 5 sources).

**Status: v1.0, the panel passed v0.2 `58f34ab8d` (section 8); for the panel's signature on this sha.**  
Editor: **c-275@sat** (claude, `specs_and_docs`).  
Panel: m-284@sat (mistral): FAIL on v0.1 (W1), PASS on v0.2 `58f34ab8d` (section 8).

**One sha:** every count below is measured on **`0509f0b7b`** (`origin/master`, the tip at every fetch of this seat), on sat, between 07:23Z and 07:4xZ on 2026-11-20, unless a row says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b26-plan')` -> `Window: W=2026-11-20T07:57:34+01:00` (commit `657cf4c65`, 06:57:34Z).

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 26. `<PUSH_USER>` is the OS user that owns the checkouts and pushes (the public repo names none).

---

## 1. How to read this

- Round 26 measured on `2f49bfad2`. This plan re-measures what changed since (`git rev-list --count 2f49bfad2..0509f0b7b` -> 12 commits), round 26's first inputs for round 27 (its section 7) and the holder's candidates file (the brief), and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `0509f0b7b`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `0509f0b7b`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since W** | `cd csi-spl-orc && sudo -u <PUSH_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|leak)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-20T06:57:34Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (07:29:40Z) | t1: 6 posts, 0 with a bug word, 6 `[spool-probe]` | **0 rows** from new reports. |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <PUSH_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (started 07:28Z) | wf 10: 100 runs (2026-11-19T10:57Z..2026-11-20T07:02Z), 15 failed; the newest failed run is 44655865817 (01:44Z, round 25's row, fixed by `2a7befc02`); every failed job's last green is 44690908432 (`c540aca2`, 06:52Z). `gh run list --branch master -L 40`, rows with `createdAt >= W`: 16 `success`, 13 `skipped`, 1 `cancelled` (44691545743, `657cf4c65`, superseded by the next push), 0 `failure` | **0 rows** from a red. The failed runs were read by rounds 24 to 26; `0509f0b7b`'s wf 10 run 44692070408 is `success`. |
| **3. Skipped or disabled tests** | `git diff 2f49bfad2 0509f0b7b -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 1 file: round 26's plan (its text quotes the pattern) | **0 rows.** No test was skipped or disabled since round 26. |
| **4. Box cron logs** | sat: `/var/csi/csi-spl/done-claim-check/cron.log` from the first run after W (line 45304, 07:00:01Z) to 07:25:04Z: `grep -cP '\talert\t'`, `grep -cE 'job [0-9a-f]{6,}'` | 6 runs, 0 alert rows, 0 `job <hex>`; every OK summary reads `0 alerted`. Completed ticks 07:00Z to 07:40Z, both boxes (the holder, c-002 084010c2; `<box2>`'s count corrected by c-001 a41a6ab0 / 423bebf4: the 07:45Z tick was still running when read): sat 9, `<box2>` 9, each rc 0, 0 `job <hex>` alerts | **0 rows.** |
| **5. Round 26's first inputs and the holder's candidates** | round 26 section 7; `/var/spool-hub/dispatch/c002-next-round-candidates.md`, its "next BUG round" and "Bug-shaped" entries | 4 + 9 inputs | **2 rows**: 01 from the review-go entry (ruled for this round by c-001 501ce862), 02 from the placer's panel-seat entry (c-001 2b2ca5b1). The other 11: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `0509f0b7b`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b27-01-orc-review-go-elsewhere-record-and-landed)` | The review GO cron's "elsewhere" path (the reviewed sha is not the tip of the row's branch on origin, SPL-5670) has two defects. (a) **It re-sends the GO every minute until `REVIEW_GO_MAX_AGE`.** `_spl_review_go_one` logs `do_log "INFO msg $msg: the reviewed ... $where" >&2` (`:765`) before it sends. `do_log` sets the global `msg` to its formatted line (`run.sh:669`, `:671`, in `_do_log_format_line`), and by bash's dynamic scope that write lands in `_spl_review_go_one`'s own `local ... msg="$2"` (`:735`). `_spl_review_go_send` then gets the log line as the message id (`:769`) and writes it into the PASS record (`:855`), so `_spl_review_go_seen` (`:168-170`, `^(PASS\|WAIT) [^ ]+ <msg id> `) never matches and the next run sends again. The suite does not see it: its `run()` stubs `do_log() { echo "$*"; }` (`spl-review-go.tst.sh:201`), which sets no global. (b) **A sha already on `origin/master` is called "found locally only, the author must still push it".** `_spl_review_go_elsewhere` (`:796-835`), once origin has no branch of the row's name, checks only the local branch of that name (`:816`) and the HEADs of worktrees on that branch or named for the author (`:819-831`); it never asks whether the sha is on `origin/master`. | Live, n=1 event, sat: m-256's re-PASS 8e64b20a on `767aa329c` (r73 plan v1.0, landed 06:39Z, its review branch deleted) -> GO 1a85b27d 07:04:05Z to c-247, text `(the reviewed sha is in the HEAD of this box's worktree <wt root>/c-247 only, not on origin: found locally only, the author must still push it)`; then GOs 3b8e0abb and 5eac7430 (c-247 msg 254cace3: "the 3rd identical GO ... in a few minutes"), and a 4th; c-001 stopped it at 07:07Z by appending a clean PASS line (msg 7e88798c). `/var/spool-hub/dispatch/automation.log` lines 2884-2886 and 2888: `PASS 2026-11-20T07:04:06Z  [INFO]  2026-11-20 09:04:04 EET [csi-spl-orc][@sat] [2587527] msg 8e64b20a-...: the reviewed 767aa329cb1c is in the HEAD of this box's worktree ... dispatch-refactor-r73 c-247 m-256 767aa329cb1c...` (`grep -c 'PASS [^ ]* *\[INFO\]' automation.log` -> 4, all this event). (b) re-run at 07:3xZ on sat, read only: `git merge-base --is-ancestor 767aa329c origin/master` -> rc 0, and `_spl_review_go_elsewhere review/c002-refactor-round-73-planner 767aa329cb1c... c-247 ""` with `REVIEW_GO_REPO` = this seat's checkout -> rc 0, `is in the HEAD of this box's worktree <wt root>/c-247 only, not on origin: found locally only, the author must still push it`. c-001 confirmed the cause of (b) on `0509f0b7b` (msg 501ce862). | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:735`, `:765` (the do_log before the send), `:769`, `:796-835` (`_spl_review_go_elsewhere`), `:855` (the PASS record); `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh:194-206` (`run()`, its `do_log` stub at `:201`), `:860-928` (case 23); read only: `csi-spl-orc/src/bash/run/run.sh:600-675` (`do_log`, `_do_log_format_line`) | `bash rc01.sh 0509f0b7b` (section 3.2): the suite with run.sh's real `do_log` in place of its stub -> exit 1, `23ac-go-fail=5` (23a 2 of 2 and 23c 3 of 3 GO cases), n=3 (section 3.2). The unchanged suite on the same sha, for contrast: `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` -> `spl-review-go: 0 failure(s)` (179 PASS). | `spl-review-go.func.sh` and its test only. (a) The PASS record (and every later use) keeps the message id whatever `do_log` does: the id must not live in a variable `do_log` writes (`msg`, `action`, `type_of_msg`, `rest_of_msg`, `log_dir`, `log_file`), or the log runs where it cannot write it (a subshell); the lane picks the form and says which in its commit body. (b) In `_spl_review_go_elsewhere`, a sha that is an ancestor of `origin/master` (read from the `ls-remote` it already does, or with `git merge-base --is-ancestor <sha> origin/master` after a fetch-free read) is reported as landed: the GO (or a skip, the lane's choice with its why) says `on origin/master`, never `found locally only`. The suite: `run()` keeps a stub, but one that writes the global `msg` as the real `do_log` does (or sources the real one), so case 23a fails on `0509f0b7b`; a new case: the sha on the fixture origin's master, the row's branch absent there -> the text says `on origin/master`; a second run of the same message sends nothing (the loop's control). Commit body: rc01 on the fix -> exit 0; the red half of each new case on `0509f0b7b`; the whole suite green. Docs: the action's @description, or `Docs: none (<why>)`, the lane's call. Not changed: `run.sh`'s `do_log` (every action shares it). | sat (the review GO cron runs there; rc01 ran there) | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |
| 02 `fix(b27-02-orc-place-panel-seat-no-ui-swap)` | **The placer swaps a read-only mistral PANEL seat off mistral when its brief quotes a `csi-spl-wui/` path.** `spl_spawn_place_swap` (`spl-spawn-place.func.sh:1011-1031`) spares a review seat from the UI and coding rules (SPL-3954, owner HUM-10 t1 1be0e370 msg 594d77e1: "Mistral may review them, read-only"), but `spl_spawn_place_review_seat` (`:1038-1041`) knows a review seat only by a slug ending `-reviewer` or `Kind: review` / `code_review`. A panel seat's slug ends `-panel-seat` and its brief says `Kind: specs_and_docs`, so `spl_lane_mix_ui_target` (`spl-lane-mix.func.sh:261-268`) trips on any quoted `csi-spl-wui/<letter>` path (a live-lanes line, the round's own row) and the seat swaps to agy (`:1028`), which is out on sat and at quota on `<box2>`: the placer holds it. A panel seat writes no code either (rulebook 2.7.6: its scope is its seat file). | n=2 asks: r73 mistral panel seat, ask 4c65f845, held from 06:2xZ (c-001 msg 2b2ca5b1: `hold: ... a review row stays cross-vendor (SPL-2942), and the agy program or its login is missing on sat; agy on <box2> at its quota limit until 2026-11-24T23:34Z`), placed only after c-002 reworded the brief's line 27 to drop the path; b26 mistral panel seat, ask ff933b29 (round 26 section 8: "held by the placer"), re-queued as a claude seat under waiver 1a7c70da. The b26 brief still swaps today (rc02, section 3.2). | `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:1003-1031` (`spl_spawn_place_swap` and its comment), `:1033-1041` (`spl_spawn_place_review_seat`), `:107-110` (the action's @description); the test `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh:1102-1130` (the SPL-3776 / SPL-3954 cases); read only: `spl-lane-mix.func.sh:255-268`, `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh:86-92` (the other caller of `spl_spawn_place_review_seat`) | `bash rc02.sh 0509f0b7b /var/spool-hub/dispatch/briefs/hand-<box2>-c002-bug-round-26-mistral-panel-seat.md` (section 3.2) -> `rc02 x-mistral-panel-seat.md -> agy (mistral takes no UI work until do_spl_vendor_ui_retest passes (the brief names csi-spl-wui/))` / `rc02 x-mistral-reviewer.md -> mistral` / `rc02 hand-<box2>-c002-bug-round-26-mistral-panel-seat.md -> agy (...)` / `rc02 sha=0509f0b7b panel-seats-swapped=2`, exit 1. | `spl-spawn-place.func.sh` and `spl-spawn-queue.tst.sh` only. A brief whose slug ends `-panel-seat` is a review seat for the swap: the UI and coding rules do not swap it, and a mistral panel seat on a mistral author is still refused (`spl_spawn_place_authors`). The lane decides whether the slug test goes into `spl_spawn_place_review_seat` or only into `spl_spawn_place_swap`; in the first case it shows that `spl-spawn-review-notify.func.sh:92` then sends no wrong author note for a panel seat, else it keeps the change in the swap. A build row on WUI still swaps (the SPL-3954 controls stay green). The suite: a mistral `-panel-seat` brief, `Kind: specs_and_docs`, quoting a `csi-spl-wui/src/...` path, launches mistral; red on `0509f0b7b`. Commit body: rc02 on the fix -> exit 0, on `0509f0b7b` -> exit 1; the comment at `:1003-1010` and the @description at `:107-110` say panel seats. Docs: the @description is the doc, or `Docs: none (<why>)`, the lane's call. | sat | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02, disjoint. Row 01: `spl-review-go.func.sh`, `spl-review-go.tst.sh`. Row 02: `spl-spawn-place.func.sh`, `spl-spawn-queue.tst.sh`.
- **Test column (R2):**
  - Row 01: `git grep -l 'spl-review-go\|_spl_review_go_\|do_spl_review_go' 0509f0b7b -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` -> `spl-review-go.tst.sh`, `spl-accepted-close.tst.sh` (it writes and reads the same PASS record form, `:91`), `orc-shard-weights.txt` (a weight, not a test). At least those two suites and `rc01.sh`.
  - Row 02: `git grep -l 'place_swap\|review_seat\|panel-seat' 0509f0b7b -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` -> `spawn-agents/tests/test-lane-issue.sh`, `spl-box-pick.tst.sh`, `spl-spawn-place-argmax.tst.sh`, `spl-spawn-queue.tst.sh`; plus the review-notify suite if the lane touches `spl_spawn_place_review_seat`, and `rc02.sh`.
- **Off limits** for the row lanes: every live lane's files (below); `run.sh` (row 01, read only); `spl-lane-mix.func.sh` and `spl-spawn-review-notify.func.sh` (row 02, read only); r73-02's files (`csi-spl-orc/src/bash/scripts/git-prune-merged-cron.sh`, `prune-go-build-cache-cron.sh`, their tests), `csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh` and the r73-01 sites in `csi-spl-orc/src/bash/run/` (per [refactor-round-73-plan.md](refactor-round-73-plan.md)): none is a row file.
- **How the files were checked (2026-11-20, sat):**
  - 07:27:14Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-place-argmax.tst.sh,csi-spl-doc/doc/md/bug-round-27-plan.md --agent c-275` -> `WARN no live lane lists` them; exit 4 for 6 `<box2>` lanes that record no files, each on an orchestrator rotation branch (`c-049-rotate`, `c-060-rotate`, `c-625-rotate`, `c-812-rotate`, `c-924-rotate-2`, `c-927-rotate`).
  - 07:27:20Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `1 queued, 0 placing`: ask 5fbd4d45, r73-02 (`claude:c002-r73-02-orc-var-app-dir-cron-wrappers`), held until r73-01 + 30 min; its files are above, none a row file.
- **Slug b27 is unused as a round id** (sat, 07:23:46Z, on `0509f0b7b`): `git log origin/master --since="$W" --oneline -E --grep='\(b27-'` -> 0; `git ls-remote origin 'refs/heads/review/b27-*' 'refs/heads/wip/*b27*' 'refs/heads/*-b27-*'` -> nothing; `ls /var/spool-hub/dispatch/briefs \| grep -E 'b27-[0-9]{2}\|bug-round-27'` -> 1, this planner's own brief (`c002-bug-round-27-planner.md`); `git worktree list \| grep -E 'b27-[0-9]{2}\|bug-round-27'` -> 1, this planner's own (`c-275-c002-bug-round-27-planner`), 0 row worktrees. Both boxes' halves, answered: section 8 (b27 is free on both).

  After this plan's pushes, `--grep='(b27-'` matches the plan's commits (`docs(b27-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b27-[0-9]{2}'` stays 0 until a row lands.

### 3.2 Red controls run on `0509f0b7b`

Both files are on sat in `/var/spool-hub/dispatch/b27-red-controls/`, and printed below so a seat on `<box2>` can rebuild them. `rc01.sh` 1702 B, `rc02.sh` 1713 B (`sha256sum` first 12 hex `033471141b25`, `e485e559a988`). Each exports `csi-spl-orc` of the sha with `git archive` (no worktree, nothing installed) and needs bash, git and python3; rc02 also exports the sha's `csi-spl-cnf` and needs `yq`.

| row | command | output on `0509f0b7b` | who |
|---|---|---|---|
| 01 | `bash rc01.sh 0509f0b7b`, from a checkout, n=3 (07:2xZ, 07:33Z, 07:38:25Z to 07:42:16Z, about 4 min each; runs 1 and 2 with an earlier exit rule that also counted the suite's rc, run 3 with the script printed below) | RED in 3 of 3. Run 3: `FAIL: 23a. RED CONTROL: the row's branch is not on origin, the sha is on the local branch of that name -> GO, 'found locally only': rc=0 sent=SEND --from c-002 ...` / `FAIL: 23a. the sha in the HEAD of a worktree named for the author (branch nowhere) -> GO, 'found locally only': ...` / `rc01 other: FAIL: 10. bad max` / `rc01 sha=0509f0b7b suite-rc=1 23ac-go-fail=5 6 FAIL total`, exit 1. Run 2 named the three 23c ones: `FAIL: 23c. RED CONTROL: ... the sha is the tip of review/c002-x-r2 -> GO naming that ref`, the same for `-n2` and for `c-222-retry`. Read: each 23a and 23c failure is a GO that was sent while its PASS record does not hold the bare msg id (`go23`'s `^PASS [^ ]+ <msg id> ` grep): the loop's defect, on every "elsewhere" GO, 23c's "tip of a related origin ref" included, since all of them log at `:765` before the send. `10. bad max` is not this defect and does not decide rc01's exit: it greps the stub's plain `FATAL REVIEW_GO_MAX_AGE`, which the real `do_log` prints as `[FATAL]` in its own format. | editor c-275 |
| 02 | `bash rc02.sh 0509f0b7b /var/spool-hub/dispatch/briefs/hand-<box2>-c002-bug-round-26-mistral-panel-seat.md /var/spool-hub/dispatch/briefs/c002-refactor-round-73-mistral-panel-seat.md`, from a checkout, n=1, 07:2xZ | RED: `rc02 x-mistral-panel-seat.md -> agy (mistral takes no UI work until do_spl_vendor_ui_retest passes (the brief names csi-spl-wui/))` / `rc02 x-mistral-reviewer.md -> mistral` / `rc02 hand-<box2>-c002-bug-round-26-mistral-panel-seat.md -> agy (...)` / `rc02 c002-refactor-round-73-mistral-panel-seat.md -> mistral` (the r73 brief as reworded at 06:2xZ: it no longer quotes the path) / `rc02 sha=0509f0b7b panel-seats-swapped=2`, exit 1 | editor c-275 |

No prototype fix was written: each change is its row lane's, with its own red controls. There is no green control on this sha: the green half is the lane's.

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha>: b27-01 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree), runs src/bash/tests/spl-review-go.tst.sh with the action's REAL
# do_log (run.sh's do_log and _do_log_* helpers, via the suite's RUN_PRE hook)
# in place of the suite's `do_log() { echo "$*"; }` stub. RED when a case-23a
# GO ("found locally only") fails: its PASS record's msg field is not the bare
# msg id (do_log sets the global `msg`, which shadows _spl_review_go_one's
# local `msg` by bash dynamic scope). Other suite FAILs are printed as
# `rc01 other:` and do not decide the exit (case 10 greps the stub's plain
# `FATAL` text, which the real do_log formats as `[FATAL]`). Run from a checkout.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$C" || exit 2
R="$C/csi-spl-orc/src/bash/run/run.sh"
sed -n '/^do_log() {/,/^}/p; /^_do_log_[a-z_]*() {/,/^}/p' "$R" >"$C/do-log.inc.sh"
grep -c '^[_a-z]*() {' "$C/do-log.inc.sh" | sed 's/^/rc01 do_log functions taken from run.sh: /'
mkdir -p "$C/log"
out="$(RUN_PRE="LOG_DIR=$C/log; source $C/do-log.inc.sh" bash "$C/csi-spl-orc/src/bash/tests/spl-review-go.tst.sh" 2>&1)"; rc=$?
grep -E '^(PASS|FAIL): 23a\. (RED CONTROL: the row.s branch is not on origin, the sha is on the local|the sha in the HEAD of a worktree)' <<<"$out" | cut -c1-160
grep -E '^FAIL' <<<"$out" | grep -vE '^FAIL: 23[ac]\.' | cut -c1-160 | sed 's/^/rc01 other: /'
n=$(grep -cE '^FAIL: 23[ac]\.' <<<"$out")
echo "rc01 sha=${full:0:9} suite-rc=$rc 23ac-go-fail=$n $(grep -cE '^FAIL' <<<"$out") FAIL total"
[[ $n -eq 0 ]]
```

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha> [brief...]: b27-02 red control. Exports csi-spl-orc of <sha>
# (git archive, no worktree), sources its lane-mix and spawn-place functions
# and asks spl_spawn_place_swap what a mistral placement of each brief
# launches. Built-in briefs (same text, Kind: specs_and_docs, a live-lanes line
# quoting csi-spl-wui/src/components/Foo.vue): x-mistral-panel-seat.md (the
# panel seat) and x-mistral-reviewer.md (the control: an R7 seat). Extra
# briefs given as args are checked too. RED when a *-panel-seat brief does
# not stay mistral. Run from a checkout.
set -uo pipefail
sha="${1:?usage: rc02.sh <sha> [brief...]}"; shift
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc csi-spl-cnf | tar -x -C "$C" || exit 2
for s in x-mistral-panel-seat x-mistral-reviewer; do
  printf '# Lane brief: %s\n\nKind: specs_and_docs\n\nRead only. Live lanes to stay off: r99-01 edits `csi-spl-wui/src/components/Foo.vue`.\n' "$s" >"$C/$s.md"
done
bad=0
for b in "$C/x-mistral-panel-seat.md" "$C/x-mistral-reviewer.md" "$@"; do
  got="$(cd "$C/csi-spl-orc" && PROJ_PATH="$PWD" APP_PATH="$C" bash -c 'set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in lib/bash/funcs/*.func.sh; do source "$f"; done
    source src/bash/run/spl-lane-mix.func.sh; source src/bash/run/spl-spawn-place.func.sh
    spl_spawn_place_swap mistral "$1"' _ "$b" 2>/dev/null)"
  to="${got%%$'\t'*}" why="${got#*$'\t'}"
  echo "rc02 $(basename "$b") -> ${to:-?}${why:+ ($why)}"
  [[ "$(basename "$b" .md)" == *-panel-seat && "$to" != mistral ]] && bad=$((bad + 1))
done
echo "rc02 sha=${full:0:9} panel-seats-swapped=$bad"
(( bad == 0 ))
```

---

## 4. Round 26's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b26-01 | `git log origin/master --oneline -E --grep='\(b26-01-'` | landed `c540aca24` | Served (round 26 closed, the brief). |
| The done-claim `job` label (a row if a `job <hex>` token alone alerts) | source 4 (section 2) | sat: 6 runs since W, 0 alert rows, 0 `job <hex>` | **Not a row**: the condition did not occur. Stays an input on the same condition. |
| `test-agent-name-shape.sh:89`, `hasnt ... "900006"` (a row once seen red) | source 2: the failed jobs of the 100-run report | `grep -c 'agent-name-shape' <the report>` -> 0 | **Not a row**: not seen red. Stays an input on the same condition. |
| SPL-5850 N1: an AltGr letter may pick a kind (`csi-spl-wui/src/utils/kind-picker-keys.ts`) | `git log --oneline 2f49bfad2..0509f0b7b -- <file>` -> 0; source 1: no owner post since W but probes | unchanged, no owner word | **No rule it breaks, no owner word.** Carried on round 26's condition. |
| The desktop blog switcher's Enter on its one match (round 26 section 10) | source 1; `git log --oneline c540aca24..0509f0b7b -- csi-spl-wui/tests/e2e/blog.test.mjs csi-spl-wui/src/components/LanguageSwitcher.vue` -> 0 | no rule, no owner word; the landed test picks with ArrowDown, a wait for the active option, then Enter | **A product question, no rule.** Carried on round 26's condition. |

---

## 5. The holder's candidates, re-measured; not a row this round

| candidate | command | result |
|---|---|---|
| **review-go: a re-PASS on a landed sha** (c-001 501ce862) and its loop (the 07:0xZ addendum) | section 3 | **Row 01** (both halves). |
| **The placer's panel-seat UI swap** (c-001 2b2ca5b1) | section 3 | **Row 02.** |
| **orc/iac suites not hermetic to the OS user** (c-947 75843c44, n=1, "RE-MEASURE FIRST") | as the agent OS user on `0509f0b7b`, 07:2xZ: `bash csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh` -> rc 0, `ALL PASS`; `bash csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh` -> rc 0, `81 passed, 0 failed` | **Not reproduced** (n=1 each; c-001 and c-002 did not reproduce it either). Not a row; an input if seen red again with its user and tree. |
| **review-notify takes `author c-NNN` inside a never-list** (c-001 364398a4) | `git log -2 --format='%h %s' origin/master -- csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh` | **Fixed**: `3e46a758c` `fix(b22-02-orc-review-notify-author-line-wins, SPL-5976)`: a line-start `Author:` line names the authors, the phrase elsewhere is context (@description lines 15-18). |
| **done-claim check takes a sha256sum prefix for a git sha** (c-001 95722c63) | `git grep -n 'sha256' 0509f0b7b -- csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh` | **Fixed** (SPL-5990): the token after an `md5` / `sha1` / `sha256` / `sha256sum` / `SHA-256` label is skipped (`:20`, `:343-344`). |
| **review-go retries a GO forever to a retired author** (c-001 0f130e27) | `git log --format='%h %s' origin/master -- csi-spl-orc/src/bash/run/spl-review-go.func.sh` | **Fixed**: `2f634fbd4` `fix(b20-01-orc-review-go-retired-author-no-retry, SPL-5953)` (spool-send rc 14 is held once, `:846-850`). |
| **Rows A and B of the reflection** (Qto 71e1dbd3, SPL-5992) | as round 24 section 5 | **Not bugs: detectors** (the brief). |
| **`fallback_postgres.go:83-86` probes uncovered** (r34-01 R7 c-321 N1/N2) | as round 24 section 5 | **A test-coverage gap, not a bug row** (the brief). |
| **SPL-5960 R7 N3: `blog.test.mjs:329` "picking bg lands on /bg/blog/..." fails alone on `67232dbc8`** (candidates file line 35, "Bug-round candidate (msg 577d03b7)"; panel W1) | `git show origin/master:csi-spl-doc/doc/md/bug-round-26-plan.md \| grep -c 577d03b7` -> 1 (row 01's evidence: "the check round 25 carried: c-395's R7 line (msg 577d03b7)"); `git merge-base --is-ancestor c540aca24 origin/master` -> rc 0; `git log -1 --format=%h origin/master -- csi-spl-wui/tests/e2e/blog.test.mjs` -> `c540aca24` | **Served**: round 26's row 01 was made from this alone-run (round 26 section 2, source 5: "01 from the `blog.test.mjs:329` alone-run"), landed `c540aca24` (SPL-6016); the file is unchanged since. Its one open part, Enter on the one match, is section 4's product question. |
| **SPL-5613 wip message sweep refused c-390 on 10 shas already on `origin/master`** (candidates file line 34 (b), c-001 b641a2ed) | `git log -1 --format='%h %s' 1ce9158a1`; `git merge-base --is-ancestor 1ce9158a1 origin/master` -> rc 0 | **Fixed**: round 20 section 5 (b) measured it; `1ce9158a1` `fix(b21-02-orc-pre-push-msg-sweep-skips-master, SPL-5964)`. |
| **c-091@`<box2>`'s read-only worktree with 51 staged files of SPL-5936** (candidates file line 34 (a), c-001 b90519e0) | `git grep -n 'c-091' origin/master -- csi-spl-doc/doc/md/bug-round-2*-plan.md` | **Closed in round 22**: round 20 section 5 (a) measured it and reported it to the orchestrator, round 21 carried it as a watch item, round 22 section 4 closed it ("Closed as round 21 says"). Not re-measured (a `<box2>` worktree). Line 34 (c) is the retired-author entry above. |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row's file (lane map 07:27:14Z, queue 07:27:20Z). The orchestrator re-runs R3 before the spawn. |
| The live review GO cron on sat | c-001 / the holder | Until row 01 lands, a PASS on a sha that is not its row branch's tip on origin, found on the box, loops again; the stop is a hand-written PASS line (c-001, msg 7e88798c). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 4 round 26 inputs and 9 holder candidates, plus round 26's own row; 6 human posts since W (all probes); 100 CI runs; 1 cron log (6 runs); 2 red controls; 2 suites re-run as the agent OS user; 1 read-only replay of `_spl_review_go_elsewhere`; the review-go suite 4 times (1 stubbed, 3 through rc01) |
| first inputs for round 28 | the done-claim `job` label if it alerts alone; the AltGr picker if a rule or the owner says how it must pick; the desktop blog switcher's Enter on its one match if a rule or the owner says Enter must pick; `test-agent-name-shape.sh:89` if seen red; the orc/iac suites as the agent OS user if seen red, with user and tree; a doc input: rulebook 5.3's slug regex `b27-[0-9]{2}` also matches UUID-named briefs (`<box2>`: 3 hits, all inside UUIDs, 0 real) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-275@sat (claude, `specs_and_docs`).
- **Panel:** m-284@sat (mistral, read-only seat, ask 2fba6016); seat file `csi-spl-doc/doc/md/bug-round-27/seat-mistral.md` on `review/c002-bug-round-27-mistral-seat` `b5909cf9a`. Both rows are orc bash, no WUI file, so a mistral seat may sit (developer guide 5.1; the coding rule bars mistral from coding, not from a read-only panel). Row 02's own defect will hold a mistral panel seat whose brief quotes a `csi-spl-wui/<letter>` path, and this plan quotes some in sections 4 and 5: the seat's brief should not copy them.
- **Asked of the holder with v0.1, answered:** the slug check (briefs and worktrees matching `b27-[0-9]{2}\|bug-round-27`): sat (c-002 084010c2) briefs 2 (this plan's and the panel seat's), worktrees 1 (this seat's); `<box2>` (c-001 7c31777b via c-002 cf22541b) 3 brief hits, all inside UUID-named briefs (`bb27-78`, `8b27-33`, `ab27-13`), real 0, worktrees 0: **b27 is free on both boxes.** The done-claim counts: section 2, source 4. The holder confirms `do_spl_review_line_check` rc 0 on the panel's line before the plan lands.
- **Row reviewer (R7):** claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (07:30:14Z) -> `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% billing read 0m ago; <box2> 99% billing read 1h0m ago]: queue the lane, spawn nothing`.
- **Review history:**
  - 2026-11-20 07:4xZ: the editor pushed v0.1 (`282437e3a`) to `review/c002-bug-round-27-planner` and asked the holder for a panel.
  - 2026-11-20 08:1xZ: m-284@sat **FAIL** on `282437e3a` (msg bfe2279a): W1, candidates file line 35 (SPL-5960 R7 N3, `blog.test.mjs:329` alone-run) is in no section, so line 8's "every other input is accounted for" is false. Everything else verified (checks 1-9, N1-N6 in the seat file). Holder send-back da9cd4d3.
  - 2026-11-20 08:22Z: v0.2 (`58f34ab8d`) folds W1: section 5 accounts for line 35 (served by b26-01 `c540aca24`) and for N6's line 34 (a) and (b) (closed in rounds 20 to 22, fixed by `1ce9158a1`); source 5 counts 4 + 9 inputs, the other 11 in sections 4 and 5. Both boxes' slug halves and done-claim counts folded. No row changed.
  - 2026-11-20 08:2xZ: m-284@sat **PASS** on `58f34ab8d` (msg 7123b99f; seat file on `review/c002-bug-round-27-mistral-seat` `cc71525dd`): W1 and N6 closed, each evidence command re-run; N7: `origin/master` moved to `af8ca0ba7`, `git diff --name-only 0509f0b7b origin/master -- <the 7 row files>` empty. `REVIEW_LINE='<that line>' ./run -a do_spl_review_line_check` on sat -> rc 0 (`OK 1 of 1 named in ran: are commands in` its log).
  - 2026-11-20 08:3xZ: v1.0, one commit on `58f34ab8d` (a fast-forward of the review branch; a rebased push would rewrite it, refused by the force-push guard), records the PASS. It rebases on `origin/master` when it lands; this file is the only one it touches. No row changed.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-275@sat | v1.0 |
| Panel | m-284@sat (mistral) | FAIL on v0.1 `282437e3a` (W1); **PASS** on v0.2 `58f34ab8d`; signature on v1.0 pending |
