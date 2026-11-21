# Bug-fix round 32 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6151 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `c7322a7a-c1f6-4942-891a-d56f2ddc45f6` ("Bug round 32", opener msg bb735343, issue post 2138b760, opened by c-002@sat 05:26Z). Round 31 ([bug-round-31-plan.md](bug-round-31-plan.md) v1.0 `67a6bfa20`) is still open: b31-01 landed `8b7828a6b` (SPL-6149); b31-02 (c-689@sat, the done-claim check) is not landed. This round does not wait for it and stays off its files.  
Round focus: two orc defects in the review path. `do_spl_push_master` lands a panel seat's review head on master when the seat forgets `PUSH_BRANCH`, although its brief allows the review branch only (row 01, seen twice). The R7 review notice names no branch when the reviewed head is on a `wip/` ref (row 02).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Sections 4 and 5 account for every other input.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-31-plan.md](bug-round-31-plan.md) (same shape, same 5 sources).

**Status: v0.1, for the panel. No row lane starts before the panel signs a plan sha.**

Editor: **c-694@sat** (claude, `specs_and_docs`; agy, the kind's main, is out on its limit until 11-24).  
Panel: the b32 mistral panel seat (ask `c002-bug-round-32-mistral-panel-seat`, queued at 05:35:40Z). Both rows are orc bash with no WUI file, so a mistral seat may sit (developer guide 5.1).

**One sha:** every count below is measured on **`8b7828a6b`** (`origin/master` at this seat's fetch, 05:32Z), on sat, between 05:32Z and 05:38Z on 2026-11-21, unless a row says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b31-plan')` -> `Window: W=2026-11-21T06:58:42+02:00` (commit `67a6bfa20`, b31 plan v1.0), the value the brief quotes.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 31. `<PUSH_USER>` is the OS user that owns the checkouts and pushes, and `<AGENT_USER>` is the OS user the agents run as. The public repo names neither.

---

## 1. How to read this

- Round 31 measured on `325a47c76`. This plan re-measures what changed since then: `git rev-list --count 67a6bfa20..8b7828a6b` -> 3 commits. It reads round 31's first inputs for round 32 (its section 7), the two candidates the holder carried (c-001 9d41057c, and m-642's push, which is the same defect), the holder's candidates file, and c-655's exit-gate report. For each it says why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `8b7828a6b`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `8b7828a6b`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since round 31** | `cd csi-spl-orc && sudo -u <PUSH_USER> env ENV=prd SQL="select tenant_id, count(*), ... from messages where ts > '2026-11-21T04:13:00Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (round 31's query, its time moved to round 31's measuring start; 05:36Z) | 0 rows: no human post since 04:13Z | **0 rows** from new reports. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (05:33Z..05:37Z) | wf 10: 100 runs (2026-11-20T15:18Z..2026-11-21T05:24Z): 58 success, 35 cancelled, 6 failure, 1 running. First red per job: `orc: hermetic action tests 2/4` x2 (`hub_cloudtranslate_user` not covered, 75da57eb, ad950c0e); `hub: Postgres gate` x2 (`TestTopicLoopSweepPickIndexOnly`, 18:45Z and 19:07Z); `wui: browser e2e 6/8` x1 (`workspace-doc-preamble.test.mjs`, 44832401773). Last green of every one of those jobs: 44869262961 on `07f34efe`, 05:06Z (e2e 6/8: 04:45Z) | **0 rows** from a red. All three were read by round 31 and are green since; the orc 2/4 red was SPL-6132's, fixed by `4a1c86baa`. `grep -c agent-name-shape <the report>` -> 0; `grep -c 'download iframe'` -> 0; `grep -c workspace-doc-preamble` -> 1 (the same run 44832401773, no 2nd sighting). |
| **3. Skipped or disabled tests** | `git diff 325a47c76 8b7828a6b -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 1 file: `csi-spl-doc/doc/md/bug-round-31-plan.md` (its text quotes `t.Skip`) | **0 rows.** |
| **4. Trunk history: seat notes on master** | `git log origin/master --since=2026-11-14 --format='%h %cI %s' -- 'csi-spl-doc/doc/md/*/seat-*.md'` (28 commits), then each revert's body | 2 reverts of a panel seat's own push: `5f1e27bc7` reverts `b86bcc246` (b30, m-551, "do_spl_push_master defaults to PUSH_BRANCH=master and the seat brief allows only review/c002-bug-round-30-mistral-seat"), and `974d97031` reverts `56d672462`, `7ad437e01`, `685cef6c8` (b31, m-642, "ran do_spl_push_master without PUSH_BRANCH at 04:44Z") | **Row 01.** |
| **5. Round 31's first inputs, the holder's candidates, the exit-gate report** | round 31 section 7 (11 inputs); the brief's two carried candidates (c-001 9d41057c; m-642's push); the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 101 lines, its "next BUG round" and "Bug-shaped" entries); c-655's report ae541e19 | 11 + 2 + 1 (the candidates file has 1 entry since round 31: c-655's, the same report as ae541e19) | **2 rows.** Row 01 is c-001 9d41057c (and m-642's push, the same defect), re-measured by source 4. Row 02 is round 31's first input (c-001 7717bbb1), made a row because b31-01 has landed on its file (`8b7828a6b`). Sections 4 and 5 cover the rest. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `8b7828a6b`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b32-01-orc-push-master-seat-review-only)` | **`do_spl_push_master` lands a panel seat's review head on master when the seat runs it without `PUSH_BRANCH`, although the seat's brief allows its review branch only.** `PUSH_BRANCH` defaults to master (`spl-push-master.func.sh:51` header, `:396` the worker's `${PUSH_BRANCH:-master}`). Nothing at start (`_spl_push_master_start`, `:90-118`) reads what the lane may push to. The lane's brief is at hand: the state dir is picked from `$SPOOL_ROOT/<AGENT_ID>/lifetime` (`_spl_push_master_state_dir`, `:73-85`), and the spawn keeps the brief as `<that dir>/brief.md` (the one a rotation restarts from, `spool-notify.inc.sh:284`). | 2 seats in 2 rounds (source 4): m-551's b30 seat state `b86bcc246` (reverted `5f1e27bc7`), m-642's 3 b31 seat notes `56d672462..685cef6c8` (reverted `974d97031`, c-001 9d41057c, 04:53Z). Each time master took an unreviewed file and the orchestrator spent a forward revert. Every one of the 40 newest `*panel-seat*` briefs on sat but 3 (the b27-02, b28-01 and b29-02 row briefs, whose slugs only quote "panel-seat") says "push it to the branch `` `review/<x>` `` only" (`ls -t /var/spool-hub/dispatch/briefs \| grep panel-seat \| head -40`, then `grep -oE 'to the branch `review/[^`]+` only'` per file). 34 of the 37 `lifetime/` dirs on sat hold a `brief.md` (`ls -d /var/spool-hub/*/lifetime \| wc -l` -> 37, `ls /var/spool-hub/*/lifetime/brief.md \| wc -l` -> 34). | `csi-spl-orc/src/bash/run/spl-push-master.func.sh:90-118` (`_spl_push_master_start`), `:73-85` (`_spl_push_master_state_dir`, read only), `:51` (the `PUSH_BRANCH` param), `:1-50` (header); the test `csi-spl-orc/src/bash/tests/spl-push-master.tst.sh` (header `:1-112`, a new case after case 20 `:516`); read only: the worker `:395-463` | `bash /var/spool-hub/dispatch/b32-red-controls/rc01.sh 8b7828a6b` (section 3.2) -> `rc01 seat: PUSHED <sha> master=moved want=REFUSED master=same` / `rc01 seatrev: PUSHED <sha> master=same want=PUSHED master=same` / `rc01 planner: PUSHED <sha> master=moved want=PUSHED master=moved` / `rc01 rowlane: PUSHED <sha> master=moved want=PUSHED master=moved` / `rc01 sha=8b7828a6b wrong=1`, exit 1, n=3 (05:34Z..05:36Z) | `spl-push-master.func.sh` and `spl-push-master.tst.sh` only. At start, when `PUSH_BRANCH` is unset or `master` and the lane's `$SPOOL_ROOT/<AGENT_ID>/lifetime/brief.md` has a line with "to the branch `` `review/<x>` `` only", the start refuses: `FATAL PUSH: <AGENT_ID>'s brief allows review/<x> only: PUSH_BRANCH=review/<x> ./run -a do_spl_push_master`, exit 1, no status file, nothing pushed (rc01 `seat`). The same brief with `PUSH_BRANCH=review/<x>` pushes as today (`seatrev`). A brief that only says "never master" before a GO or an R7 PASS (a planner: `planner`; a row lane: `rowlane`) still lands on master: those lanes land after the GO. No `AGENT_ID`, no lifetime dir or no `brief.md`: unchanged (the current cases 1-20). The worker, the hook and the review-line gate are not touched. The suite: rc01's four cases, `seat` red on `8b7828a6b`. Commit body: rc01 on the fix -> exit 0 (`wrong=0`), on `8b7828a6b` -> exit 1. Docs: the header's AGENT_ID paragraph and the `PUSH_BRANCH` param say it; or `Docs: none (<why>)`. | sat or `<box2>` (no pin) | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |
| 02 `fix(b32-02-orc-review-notify-wip-branch)` | **The R7 review notice names no branch when the reviewed head is on a `wip/` ref.** `spl_review_notify_branch` (`spl-spawn-review-notify.func.sh:107-113`) matches `review/...` only (`:108`), on the "Branch" line, the "`` `<ref>`, head `` " form and the first ref anywhere. A reviewer brief whose target is `Branch `` `wip/<x>` ``` gets an empty answer. The caller then writes `(no review/ branch named)` in the author's note (`:76`). A `wip/` head is a real review target: the pre-push hook's `wui-lang-review` part refuses `review/*` for WUI text before agy's `Lang-review:` line (the T025 brief's own words, below). | c-001 7717bbb1 (02:07:53Z, n=1 notice): the SPL-6123 T025 R7 placement (reviewer c-506@`<box2>`) told author c-490@`<box2>` "(no review/ branch named)", and c-001 sent the branch and head `e9e3f4ccf` by hand. The brief `c002-s033-t025-claude-waiver-reviewer.md:15` reads "Branch `` `wip/c002-s033-t025-t027-wui-kinds-live` `` (a `` `wip/` `` ref: ...), head `` `e9e3f4ccf...` ``". On sat, 11 other reviewer briefs have a `Branch `` `wip/...` ``` line and no `review/` ref at all (`grep -l 'wip/' *review*.md *waiver*.md` -> 46 files, then a `Branch` line with `wip/` and `grep -c 'review/'` -> 0: e.g. `c002-spl5147-why-claude-waiver-reviewer.md`, `c002-spl5960-claude-waiver-reviewer.md`). Round 31 kept this off its round only because b31-01 shared the file (R1). b31-01 has landed (`8b7828a6b`), and no live lane lists the file (section 3.1). | `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh:104-113` (`spl_review_notify_branch`, its comment and the `r=` pattern `:108`), `:76` (the caller), `:35-39` (header item 3); the test `csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh` (header `:32-34`, case 12 `:241-256`; case 5 `:133` keeps the `(no review/ branch named)` text) | `bash /var/spool-hub/dispatch/b32-red-controls/rc02.sh 8b7828a6b` (section 3.2) -> `rc02 wiplive: branch=none want=wip/c002-s033-t025-t027-wui-kinds-live` / `rc02 wipbare: branch=none want=wip/c-427-SPL-5147-why` / `rc02 review: branch=review/b99-01 want=review/b99-01` / `rc02 target: branch=review/new want=review/new` / `rc02 none: branch=none want=none` / `rc02 sha=8b7828a6b wrong=2`, exit 1, n=3 (05:35Z) | `spl-spawn-review-notify.func.sh` and `spl-spawn-review-notify.tst.sh` only. On the "Branch" line and in the "`` `<ref>`, head `` " form, a `wip/<x>` ref is a target like a `review/<x>` one (rc02 `wiplive`, `wipbare`). The last fallback, the first ref anywhere, stays `review/` only, so a `wip/` named in passing never wins over the target. The order and SPL-5914's rule stay as they are (`target`). With no branch the note still says `(no review/ branch named)` (`none`; case 5 unchanged). No hub call, no placer change. The suite: rc02's five cases, `wiplive` and `wipbare` red on `8b7828a6b`. Commit body: rc02 on the fix -> exit 0, on `8b7828a6b` -> exit 1. Docs: header item 3 names `wip/`; or `Docs: none (<why>)`. | sat or `<box2>` (no pin) | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02, disjoint. Row 01: `spl-push-master.func.sh`, `spl-push-master.tst.sh`. Row 02: `spl-spawn-review-notify.func.sh`, `spl-spawn-review-notify.tst.sh`. Neither sources the other.
- **Test column (R2):**
  - Row 01: `git grep -l -E 'spl-push-master\|do_spl_push_master\|_spl_push_master' 8b7828a6b -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features csi-spl-iac/src/bash/tests` -> 14 test files, plus `orc-shard-weights.txt` (a list, not a test) and 3 files that are not tests (`hooks/pre-push`, `spawn-core.inc.sh`, `tmux-close-window.sh`). The tests are `spl-push-master.tst.sh`, `spl-accepted-close.tst.sh`, `spl-review-go.tst.sh`, `spl-push-orphan-check.tst.sh`, `spl-vendor-ui-retest.tst.sh`, `watcher-read-only.tst.sh` and `force-push-guard.tst.sh` (orc `src/bash/tests`); `test-pre-push-hook.sh`, `test-pre-push-lane-push.sh`, `test-pre-push-review-line.sh`, `test-seed-not-in-argv.sh`, `test-spawn-seed-size.sh` and `test-tmux-close-window.sh` (`spawn-agents/tests`); and `test-y12-vibe-push-guard.sh` (`spool-install/tests`). Also `rc01.sh`.
  - Row 02: `git grep -l -E 'spl-spawn-review-notify\|spl_review_notify\|do_spl_spawn_review_notify' 8b7828a6b -- <the same dirs>` -> `spl-spawn-review-notify.tst.sh` (and `orc-shard-weights.txt`); and `rc02.sh`.
- **Off limits** for the row lanes: every live and queued lane's files (below); b31-02's files (`spl-done-claim-check.func.sh`, its test, `done-claim-check.md`; c-689@sat); the pre-push hook; `spl-spawn-place.func.sh` (the placer's hook `spl_review_notify_placed` is read only); the hub.
- **How the files were checked (2026-11-21, sat):**
  - 05:35:32Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-push-master.func.sh,csi-spl-orc/src/bash/tests/spl-push-master.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh,csi-spl-doc/doc/md/bug-round-32-plan.md --agent c-694` -> `WARN no live lane lists` them, exit 4 for 15 `<box2>` lanes that record no files: c-461 (spec 123 P05), c-490 (spec 033 T025+T027), c-579, c-590, c-598 (spec 123 L2), c-601 (spec 189), c-602, c-610, and the rotation branches of c-146, c-463, c-506, c-562, c-812, c-924 and c-927. Their worktrees are on `<box2>`: asked of the holder (section 8). b31-01's lane c-612 is no longer on the map.
  - 05:35:40Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `15 queued, 0 placing`. All 15 briefs are present in `/var/spool-hub/dispatch/briefs/`. `grep -nE 'push-master\|review-notify\|spl_review_notify\|do_spl_push_master'` gives 1 hit in 14 of them and 0 in `c002-s-qto-doc-media-spec`. Each hit is the brief's own landing step ("You LAND ... with `do_spl_push_master`", or the seat's push line); none edits a row file.
  - `git diff --name-only 8b7828a6b origin/master` -> empty at 05:35Z (no drift since the baseline).
- **Slug b32 is unused as a round id** (sat, 05:32:54Z, on `8b7828a6b`): `git log origin/master --since="$W" --oneline -E --grep='\(b32-'` -> 0. `git ls-remote origin 'refs/heads/review/b32-*' 'refs/heads/wip/*b32*' 'refs/heads/*-b32-*'` -> nothing. `git worktree list \| grep -E 'b32\|bug-round-32'` -> 1, this planner's (`c-694-c002-bug-round-32-planner`). `ls /var/spool-hub/dispatch/briefs \| grep -E 'b32\|bug-round-32'` -> the planner's and the panel seat's briefs, 0 row briefs (8 more hits are the hex id `f655b326` of billing briefs, not a round). `<box2>`'s half is asked of the holder (section 8).

### 3.2 Red controls run on `8b7828a6b`

The two files are on sat in `/var/spool-hub/dispatch/b32-red-controls/`. They are printed below so a seat on `<box2>` can rebuild them. `rc01.sh` is 4053 B and `rc02.sh` 2311 B (`sha256sum` first 12 hex `a51a28ca72b6`, `a7c6b45d4402`). Each exports `csi-spl-orc` of the sha with `git archive` (no worktree of the repo, nothing installed) and needs bash, git and tar. rc01 builds a temp bare origin, a lane worktree and a temp `SPOOL_ROOT`, with no hook and no network. rc02 feeds one fixture brief per case to the branch reader. Neither reads a live queue, worktree, spool or credential.

| row | command | output on `8b7828a6b` | who |
|---|---|---|---|
| 01 | `bash rc01.sh 8b7828a6b`, from a checkout, n=3 (05:34Z..05:36Z; the 4th case, `rowlane`, was added for the 3rd run) | RED in 3 of 3: `rc01 seat: PUSHED <sha> master=moved want=REFUSED master=same` / `rc01 seatrev: PUSHED <sha> master=same want=PUSHED master=same` / `rc01 planner: PUSHED <sha> master=moved want=PUSHED master=moved` / `rc01 rowlane: PUSHED <sha> master=moved want=PUSHED master=moved` / `rc01 sha=8b7828a6b wrong=1`, exit 1 (the `<sha>` differs per run: the fixture commits are new each time). What it shows: a seat whose brief allows `review/<x>` only lands on master when it forgets `PUSH_BRANCH`. The same seat with the branch, a planner and a row lane come out right, and must stay so. | editor c-694 |
| 02 | `bash rc02.sh 8b7828a6b`, from a checkout, n=3 (05:35Z) | RED in 3 of 3, the same output each time: `rc02 wiplive: branch=none want=wip/c002-s033-t025-t027-wui-kinds-live` / `rc02 wipbare: branch=none want=wip/c-427-SPL-5147-why` / `rc02 review: branch=review/b99-01 want=review/b99-01` / `rc02 target: branch=review/new want=review/new` / `rc02 none: branch=none want=none` / `rc02 sha=8b7828a6b wrong=2`, exit 1. What it shows: a `wip/` target is not read. A `review/` target, SPL-5914's target rule and a brief with no branch come out right, and must stay so. | editor c-694 |

No prototype fix was written: each change belongs to its row lane, with its own red controls. There is no green control on this sha; the green half is the lane's.

The row's `seat` case wants `REFUSED`, the first verdict word the run prints. A fix that refuses at start prints `FATAL PUSH: ...` instead: the lane then sets that case's want to `FATAL` in its copy and says so in its commit body. `master=same` is the part that must hold.

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha>: b32-01 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree of the repo) and runs its do_spl_push_master on a fixture: a temp
# bare origin, a lane m-901 in a linked worktree on branch m-901-seat, and a
# temp SPOOL_ROOT whose m-901/lifetime/brief.md is a panel seat brief that
# allows `review/<x>` only (the form of every mistral panel seat brief, e.g.
# c002-bug-round-31-mistral-panel-seat.md:28). No hook, no network.
#   seat    : seat brief, PUSH_BRANCH unset -> must be refused, master unmoved
#             (RED when PUSHED: m-551 b86bcc246, m-642 56d672462..685cef6c8)
#   seatrev : seat brief, PUSH_BRANCH=review/c002-x-seat -> PUSHED on that ref,
#             master unmoved (control)
#   planner : a planner brief ("Push the plan to `review/...` (PUSH_BRANCH=...;
#             never master before the GO)"), PUSH_BRANCH unset -> PUSHED to
#             master (control: an editor lands its plan after the GO)
#   rowlane : a row lane brief ("Push `review/<x>` (never master) ... You LAND
#             only after the R7 PASS ... with `do_spl_push_master`"),
#             PUSH_BRANCH unset -> PUSHED to master (control)
set -uo pipefail
sha="${1:?usage: rc01.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$T" || exit 2
G=(-c user.name=lane -c user.email=lane@example.com -c init.defaultBranch=master)
git "${G[@]}" init -q --bare "$T/origin.git"
git "${G[@]}" clone -q "$T/origin.git" "$T/main" 2>/dev/null
echo base >"$T/main/base.txt"; git -C "$T/main" add base.txt
git -C "$T/main" "${G[@]}" commit -qm base && git -C "$T/main" push -q origin HEAD:master
mkdir -p "$T/nohooks"; git -C "$T/main" config core.hooksPath "$T/nohooks"
git -C "$T/main" config user.name lane; git -C "$T/main" config user.email lane@example.com
git -C "$T/main" worktree add -q -b m-901-seat "$T/main-wt/m-901" 2>/dev/null
L="$T/main-wt/m-901"; mkdir -p "$T/spool/m-901/lifetime"
run() {  # extra env... -> start, then poll status until not RUNNING
  (cd "$T/csi-spl-orc" && env PROJ_PATH="$PWD" SPOOL_ROOT="$T/spool" AGENT_ID=m-901 PUSH_WORKTREE="$L" \
    FETCH_FRESH_MAX_AGE=0 "$@" bash -c 'set -uo pipefail
      do_log() { echo "$*"; }; do_require_bin() { return 0; }
      for f in lib/bash/funcs/*.func.sh src/bash/run/spl-push-master.func.sh; do source "$f"; done 2>/dev/null
      do_spl_push_master || exit $?
      for _ in $(seq 1 120); do PUSH_CMD=status do_spl_push_master >/dev/null; [ $? -ne 3 ] && break; sleep 0.5; done
      PUSH_CMD=status do_spl_push_master' 2>&1 | grep -m1 -oE '^(PUSHED|REFUSED|GAVE-UP|NOTHING-TO-PUSH|FATAL)[^:]{0,40}' )
}
bad=0
chk() {  # NAME WANT-VERDICT WANT-MASTER(moved|same) BRIEF-LINE [env...]
  local name="$1" want="$2" wm="$3" line="$4"; shift 4
  printf '# brief\n\n%s\n' "$line" >"$T/spool/m-901/lifetime/brief.md"
  echo "$name" >"$L/$name.txt"; git -C "$L" add "$name.txt"; git -C "$L" "${G[@]}" commit -qm "docs(x): $name"
  local m0 m1 got mv; m0="$(git --git-dir="$T/origin.git" rev-parse master)"
  got="$(run "$@")"; m1="$(git --git-dir="$T/origin.git" rev-parse master)"
  mv=same; [[ "$m0" != "$m1" ]] && mv=moved
  echo "rc01 $name: ${got:-none} master=$mv want=$want master=$wm"
  [[ "$got" == "$want"* && "$mv" == "$wm" ]] || bad=$((bad + 1))
  git -C "$L" fetch -q origin 2>/dev/null; git -C "$L" reset -q --hard origin/master 2>/dev/null
}
SEAT='Commit it and push it to the branch `review/c002-x-seat` only, never to master: the editor folds it into the plan.'
ROW='5. Push `review/c002-x-row` (never master). You LAND only after the R7 PASS and the holder'"'"'s GO, with `do_spl_push_master`.'
PLAN='Push the plan to `review/c002-x-planner` (`PUSH_BRANCH=review/c002-x-planner`; never master before the GO).'
chk seat    REFUSED same  "$SEAT"
chk seatrev PUSHED  same  "$SEAT" PUSH_BRANCH=review/c002-x-seat
chk planner PUSHED  moved "$PLAN"
chk rowlane PUSHED  moved "$ROW"
echo "rc01 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha>: b32-02 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree), sources its spl-spawn-review-notify.func.sh and asks
# spl_review_notify_branch which review target a reviewer brief names. The
# caller (:76) writes `(no review/ branch named)` in the author's note when it
# prints nothing (c-001 7717bbb1: SPL-6123 T025, reviewer c-506, a wip/ head).
#   wiplive : "Branch `wip/<x>` (a `wip/` ref: ... refuses `review/*` ...), head"
#             (c002-s033-t025-claude-waiver-reviewer.md:15) -> wip/<x> (RED: none)
#   wipbare : "Branch `wip/c-427-SPL-5147-why`, head ..." (the form of 11 older
#             reviewer briefs on sat) -> that ref (RED: none)
#   review  : "Branch `review/b99-01`, head abc" -> review/b99-01 (control)
#   target  : an earlier `review/old` above "Branch `review/new`, head"
#             -> review/new (control, SPL-5914)
#   none    : no branch at all -> none (control: the caller says so)
set -uo pipefail
sha="${1:?usage: rc02.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$C" || exit 2
br() {  # BRIEF-TEXT -> the branch read
  printf '%s\n' "$1" >"$C/brief.md"
  (cd "$C/csi-spl-orc" && bash -c 'set -uo pipefail
    do_log() { :; }
    source src/bash/run/spl-spawn-review-notify.func.sh
    spl_review_notify_branch "$1"' _ "$C/brief.md" 2>/dev/null)
}
bad=0
chk() {  # NAME WANT TEXT
  local got; got="$(br "$3")"
  echo "rc02 $1: branch=${got:-none} want=$2"
  [[ "${got:-none}" == "$2" ]] || bad=$((bad + 1))
}
chk wiplive wip/c002-s033-t025-t027-wui-kinds-live 'Branch `wip/c002-s033-t025-t027-wui-kinds-live` (a `wip/` ref: the pre-push hook refuses `review/*` until the `Lang-review:` line lands), head `e9e3f4ccf`.'
chk wipbare wip/c-427-SPL-5147-why 'Branch `wip/c-427-SPL-5147-why`, head `0123456789abcdef0123456789abcdef01234567`.'
chk review  review/b99-01 'Branch `review/b99-01`, head abc. Report on task dispatch-bug-r99.'
chk target  review/new    "$(printf 'Earlier review: FAIL on `review/old` (msg 1).\nBranch `review/new`, head `0123456789abcdef0123456789abcdef01234567`.')"
chk none    none          'Review the lane. Nobody named a branch.'
echo "rc02 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

---

## 4. Round 31's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b31-01, b31-02 | `git log origin/master --oneline -E --grep='\(b31-0[12]-'` | b31-01 landed `8b7828a6b`; b31-02 none | b31-01 is served. b31-02 is live (c-689@sat), so it is off limits (R3). |
| The review notice's `wip/` branch (c-001 7717bbb1) | section 3 | b31-01 landed on its file | **Row 02.** |
| The done-claim `job` label (a row if a `job <hex>` token alone alerts) | sat `/var/csi/csi-spl/done-claim-check/cron.log`, lines from 04:13Z: `grep -ciE 'job [0-9a-f]{7}'` -> 0 | 0 alerts | **Not a row**: the condition did not occur. It stays an input. |
| The AltGr picker; the blog switcher's Enter | source 1 | 0 human posts since 04:13Z | **No rule it breaks and no owner word.** Carried. |
| `test-agent-name-shape.sh:89` (a row once seen red) | source 2 | `grep -c agent-name-shape <the report>` -> 0 | **Not a row**: not seen red. |
| The orc/iac suites as the agent OS user, if seen red | as `<AGENT_USER>` on `8b7828a6b`, 05:36:52Z: `bash csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh` -> rc 0, `ALL PASS`; `bash csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh` -> `81 passed, 0 failed` | not red (n=1 each) | **Not reproduced**, as in rounds 27 to 31. |
| `gcp-billing-invoices.tst.sh` `download iframe`; `workspace-doc-preamble.test.mjs` at their 3rd sightings | source 2 | 0 and 1 (the same run round 31 counted) in 100 runs | **Not a row**: no new sighting. |
| The `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms | prod messages since 04:13Z (131): `body ~* '\mtasks [0-9a-f]{7,40}\M'` -> 0, `'\m(forward\|multicast) [0-9a-f]{7,40}\M'` -> 0 | not printed again | **Not a row.** Carried. |
| b29-01 N1 on `<box2>` (the profile account across a renewal) | not read here: `<box2>` | no `differs` reported | **Not a row.** Carried. |
| The overlay mount that outlives its `/tmp` worktree | sat, 05:36:52Z: `findmnt -rn -o TARGET,FSTYPE \| grep '^/tmp/'` -> 1, `/tmp/g-334-spl5639-review/csi-spl-wui/node_modules overlay` (the same one); `git worktree list \| awk '$1 ~ /^\/tmp\//' \| wc -l` -> 10 | unchanged | **Not a row this round**: its red control needs a mount, which needs root, and it would be a 3rd row. Carried. |
| `<box2>`'s 8 dashless `/tmp` trees once b30-02's knob is on | `WT_SWEEP_TMP_ROOT` still off | not observable | **Not a row.** Carried. |
| The lease vendor order writer once named | no writer named since round 31 | none | **Not a row.** Carried with round 31's reading (sat's change was a hand edit). |

---

## 5. The holder's candidates and other reports, re-measured; not a row this round

| candidate | command | result |
|---|---|---|
| **`do_spl_push_master` refuses nothing when a brief names a review branch only** (c-001 9d41057c) and **m-642's push to master at 04:44Z** | section 3 | **Row 01**: one defect, two reports. The fix keys on the seat form ("to the branch `` `review/<x>` `` only") and not on any `review/` mention, because planners and row lanes name a `review/` branch too and then land on master (rc01 `planner`, `rowlane`). |
| **A spec-version lane on a discussion issue cannot `/exit-clean`** (c-655 ae541e19, 04:38Z, n=1) | the report: `kill-your-self-report.sh --gate` exit 3, "issue SPL-6086 is still wip: no commit on origin/master closes it ... and no end reason"; the brief had no `Issue-Role: shared`, which `li_review_lane` (`lane-issue.inc.sh:543`) reads | **Not a row this round**: a 3rd candidate (rulebook 5.1: the first row of round 33). The fix is a choice between two places (the enqueue adds `Issue-Role: shared` to a specs_and_docs brief on a discussion key, or the gate passes a docs-only lane whose landed commit cites the key). The holder should pick one before a planner writes the red control. |
| **The placer `After:` hold reads the wrong box's key** (c-001 d77d912f) | `git log origin/master --oneline -E --grep='\(b30-03-'` -> `6f2a343bb`, `252de9ad2` | **Served** (b30-03). |
| **The bare `Author:` box** (c-001 7e965718) | b31-01 `8b7828a6b` | **Served.** |
| **The review-go rows, the panel-seat swap, the kept weekly reading, the `/tmp` worktrees, the CI-first rule** | as round 31 section 5 | **Served** (b20-b30), as round 31 lists them. |
| **Test, refactor and doc notes** (b30-01 N1, the `ws-docs-head.mjs` click, the spec 181 notes, the topic loop cap race, SPL-6107 N1, Rows A and B of the reflection) | as round 31 sections 5 and 6 | **Not bugs this round**, as round 31 reads them; spec 181's stay with its lanes (R3). |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row file (lane map 05:35:32Z, queue 05:35:40Z); the 15 exit-4 `<box2>` lanes are asked of the holder. |
| b31-02 (the done-claim sha256 prefix words) | c-689@sat | Not landed; its files are off limits. |
| The exit gate on a discussion issue (c-655) | the holder | A design pick first (section 5). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 11 round 31 inputs, 2 carried candidates (one defect), 1 exit-gate report (the candidates file's one entry since round 31); 0 human posts since 04:13Z; 100 CI runs; 28 seat-file commits on master since 11-14 and their 2 reverts; 40 panel seat briefs and 46 `wip/` reviewer briefs read; 131 prod messages for the commit-links forms; 2 red controls (n=3 each); 2 suites re-run as the agent OS user; 10 `/tmp` worktrees and 1 mount on sat |
| first inputs for round 33 | c-655's exit gate on a discussion issue, once the holder picks the fix's place; the done-claim `job` label if it alerts alone; the AltGr picker and the blog switcher's Enter if a rule or the owner says how they must pick; `test-agent-name-shape.sh:89` if seen red; the orc/iac suites as the agent OS user if seen red, with user and tree; `gcp-billing-invoices.tst.sh` `download iframe` and `workspace-doc-preamble.test.mjs` at their 3rd sightings; the `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms if printed again; b29-01 N1 on `<box2>` if it reads `differs`; the overlay mount that outlives its `/tmp` worktree; `<box2>`'s 8 dashless `/tmp` trees once b30-02's knob is on; the lease vendor order writer once named |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-694@sat (claude, `specs_and_docs`).
- **Panel:** the b32 mistral panel seat (ask `c002-bug-round-32-mistral-panel-seat`). Both rows are orc bash with no WUI file, so a mistral seat may sit (developer guide 5.1). Its brief has the seat form row 01 reads; until row 01 lands, the seat must push with `PUSH_BRANCH=review/c002-bug-round-32-mistral-seat`.
- **Asked of the holder with v0.1:**
  1. The 15 exit-4 lanes of section 3.1, all on `<box2>`: for each worktree, `git diff --name-only origin/master...HEAD` and its dirty paths, checked against the four row files.
  2. `<box2>`'s slug half: `ls /var/spool-hub/dispatch/briefs \| grep -E 'b32-[0-9]{2}\|bug-round-32'` and `git worktree list \| grep -cE 'b32-[0-9]{2}\|bug-round-32'`.
- **Row reviewer (R7):** rows 01 and 02: the claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (05:36:25Z) -> `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% billing read 6m ago; <box2> 99% billing read 6m ago]: queue the lane, spawn nothing`. No row has a mistral backup: both are a coding kind (`simple_coding`), and mistral takes no coding kind, as main or backup. An absent seat gets a replacement claude waiver seat (rulebook 2.7.3).
- **Review history:**
  - 2026-11-21 05:4xZ: v0.1, pushed to `review/c002-bug-round-32-planner` for the panel.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-694@sat | v0.1 |
| Panel | the b32 mistral seat | asked |
