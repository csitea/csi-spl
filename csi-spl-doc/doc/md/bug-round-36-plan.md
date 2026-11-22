# Bug-fix round 36 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6216 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `fc7513e6-e832-4cff-aed5-97361c7bebf8` ("Bug round 36", opener msg 126f6849, opened by c-002@sat 21:34:56Z). Round 35 ([bug-round-35-plan.md](bug-round-35-plan.md)) is served: its one row b35-01 landed `ae93a3339`. Round 34 is closed (`1685e0ebe`, rows `f4d7b3ae1` and `0d0797fde`).  
Round focus: two checks that read a value in one spelling and miss the same value in another. Row 01: the spawn share reads an R7 review seat's queue class (`feature`, a queueing device) in place of its brief's class, so the bug and refactor shares are counted low. Row 02: the customer box role check refuses `delegate_to: localhost` and a vault FILE, but not `delegate_to: "localhost"`, `connection: 'local'` or an inline `!vault` value.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Sections 4 and 5 account for every other input.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-35-plan.md](bug-round-35-plan.md) (same shape, same 5 sources).

**Status: v1.0, landed `aae0f987e`, signed: the panel passed v0.1 `83f118d35` and v1.0 `aae0f987e`, each with no W (m-011@sat, mistral, msg c792f329; section 8). v1.0 changes no row: it records the PASS and its notes N1-N5, the `<box2>` halves of R3 and the slug proof, and the holder's answer on a third row, and folds in the seat file [bug-round-36/seat-mistral.md](bug-round-36/seat-mistral.md) (at `1de2c4dea`, its v1.0 signature section).** **Closed**: both rows landed, b36-01 `ca8a0591c` + `b2a96ef8f`, b36-02 `cd1c499ee` (section 8).

Editor: **c-009@sat** (claude, `specs_and_docs`; agy, the kind's main, is out on its limit until 11-24).  
Panel: m-011@sat (mistral, ask `c002-bug-round-36-mistral-panel-seat`): **PASS** on v0.1 `83f118d35` (msg c792f329, the holder's copy a4b61f6f) and on v1.0 `aae0f987e` (msg 1244f877), seat file `1de2c4dea` on `review/c002-bug-round-36-mistral-seat`, folded here, no W. Neither row has a WUI file (orc and iac bash), so a mistral seat may sit on the plan (developer guide 5.1); it writes no row code.

**One sha:** every count below is measured on **`1685e0ebe`** (`origin/master` at this seat's fetch), on sat, between 22:3xZ and 22:50Z on 2026-11-21, unless a row says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b35-plan')` -> `Window: W=2026-11-21T15:44:45+02:00` (commit `962628106`), the value the brief quotes.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 35. `<PUSH_USER>` is the OS user that owns the checkouts and pushes. The public repo names neither.

---

## 1. How to read this

- Round 35 measured on `e1ee705d8`. This plan reads round 35's first inputs for round 36 (its section 7), the R7 notes of b34-01 and b34-02, the holder's candidates file (with the candidate the holder added to this brief at 22:1xZ), and the CI report. For each it says why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `1685e0ebe`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `1685e0ebe`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner, member and lane reports since round 35** | the brief's inputs; the spool task `dispatch-bug-r34` read whole (264 lines, 22:3xZ); the brief's added candidate (c-001@sat msg e9b303da) | no owner word; 1 lane report: the share counts a refactor or bug R7 seat as feature | **Row 01.** |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (22:3xZ..22:44:40Z) | wf 10: 100 runs (2026-11-21T05:53Z..22:35Z): 47 success, 40 cancelled, 11 failure, 2 running. First red per job: `wui: browser e2e 3/8` x5, `6/8` x3, `1/8` x3, `4/8` x1, `orc: hermetic action tests 4/4` x2. The orc reds are the step-030 ones b35-01 fixed (`ae93a3339`). The WUI reds since `d2557fbc4` (SPL-6205, 21:17Z) have a live owner: c-934's fix-forward `e928128e5` on `review/c003-wui-topic-pdf-all-posts-fix`, waiting for its delta R7 (c-934 msg 659574ab, 22:30Z); `8c8c78093`'s run (22:21Z) is the same three jobs. The 12:xxZ `3/8` / `4/8` reds ("the other topic under the pointer is the one lit card") are older than the last green `9de071fa` (20:55Z). Every job's p90 is under 75 % of its timeout (the highest, hermetic 1/4, 57 %) | **0 rows** (R3: the open red is c-934's). The gate's e2e cut is an input (section 4). |
| **3. Skipped or disabled tests** | `git diff e1ee705d8 1685e0ebe -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 4 files, 3 of them new tests from b34-01 (`wsdoc_assets_orphan_sweep_test.go`, `wsdoc_media_av_test.go`, `workspace_docs_assets_test.go`) plus bug-round-35-plan.md; their 4 added `t.Skip` lines are the Postgres-only guard (`SPOOL_TEST_PG_DSN` unset), which the `hub-pg` job runs; no test switched off | **0 rows.** |
| **4. The R7 notes of round 34** | the b34-01 PASS (c-855@`<box2>`, msg dc1653a8, line fix db7a8207) and the b34-02 PASS (c-823@`<box2>`, msg bb1be608 as the holder's GO quotes it), read in the holder's archive and on `dispatch-bug-r34` | b34-01: N1-N3, no W; b34-02: N1-N2, no W | **0 rows**: section 4. |
| **5. Round 35's first inputs, the holder's candidates** | round 35 section 7; the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 110 lines at 22:3xZ, the count round 35 read: no entry since) | its "next BUG round" and "Bug-shaped" entries not served by b20-b35 | **Row 02** (spec 181 B6 R7 c-502 N1-N2, which round 31 held back only for the spec 181 lanes then live); the rest: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `1685e0ebe`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b36-01-orc-share-review-seat-brief-class)` | **The spawn share counts every refactor or bug R7 review seat as a feature lane.** The enqueue queues such a seat as `feature` + bypass on the review-seat GO `994f2257` (`spl-spawn-enqueue.func.sh:133` sets `seat=1`, `:138-140` sets `class=feature`; SPL-5638: the hub flags bypass on a feature only), and the share takes the class of the ask that placed the lane before the lane's brief (`spl-spawn-share.func.sh:146-147` builds `$placed` from the asks' `.class`, `:149` reads `$placed[$id] // $briefs[$id]`). The brief is read only for lanes on this box (`spl_spawn_share_briefs`, `:192-202`, `ASKS_BOX`), so a seat on `<box2>` has no other source. The share feeds the placer's band pick (`spl_spawn_place_band`), the 24 h samples and the holder's round decisions (fleet rules index, SPL-1817 row). | **Live:** `SPAWN_SHARE_FORMAT=json ./run -a do_spl_spawn_share` on sat (22:40:54Z, desk checkout `1685e0ebe`, n=1): 24 classed live lanes, refactor 4 / bug 7 / feature 13; of the 13 feature lanes, 8 distinct lanes were placed by an ask flagged with the review-seat GO (`.bypasses[]` with `msg` `994f2257`: g-079, c-855, g-050, g-061, g-108, g-111 on `<box2>`, c-878 and g-005 on sat), among them c-855 (R7 of bug row b34-01) and g-108 / g-005 (R7 of refactor rows r86-01 / r86-02). c-001's 22:0xZ snapshot on `f6703d2b1` (n=1, msg e9b303da): booked 4 / 7 / 13, by brief class 5 / 12 / 7, the bug verdict UNDER -> OVER. Re-measured here: rc01 below, RED 3 of 3 on `1685e0ebe`, RED on `f6703d2b1` (n=1). | `csi-spl-orc/src/bash/run/spl-spawn-share.func.sh:146-149` (`$placed`, the class pick), `:63-75` (`spl_spawn_share`, the inputs) and `:192-202` (`spl_spawn_share_briefs`); its test `csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh`; doc `csi-spl-doc/doc/md/fleet-rules-index.md` (SPL-1817 row, the share sentence). Read only: `spl-spawn-enqueue.func.sh:133-140,276-279` (`SPL_SPAWN_REVIEW_SEAT_GO`, `spl_spawn_q_review_seat_go`), `spl-spawn-place.func.sh:1466` (`spl_spawn_place_brief`, slug -> brief). | `bash /var/spool-hub/dispatch/b36-red-controls/rc01.sh 1685e0ebe` (section 3.2) -> `rc01 seat: got=feature want=bug` / `rc01 xbox: got=feature want=refactor` / `rc01 ctrl: got=feature/bug want=feature/bug` / `rc01 sha=1685e0ebe by={"refactor":0,"bug":1,"feature":3} wrong=2`, exit 1, n=3 (22:42Z) | `spl-spawn-share.func.sh`, `spl-spawn-share.tst.sh` and the fleet rules index row only. A lane placed by an ask flagged `bypass` with the review-seat GO counts as its brief's class: the lane's own brief on this box (`seat`), else the queued brief its ask's `placement` slug names in this box's `dispatch/briefs` (`xbox`; the holder's box, where the seat briefs are written). Every other ask keeps its class (`ctrl`), an owner bypass included. The lane chooses the shape (a second map beside `$briefs`, or the seat's class resolved before the jq). The enqueue and the hub stay as they are: the seat still queues as feature + bypass, so its place in the queue does not change. A seat whose brief has no `Class:` line stays `feature`, as today. The suite: rc01's three cases as cases of the test, `seat` and `xbox` red on `1685e0ebe`. Commit body: rc01 on the fix -> exit 0, on `1685e0ebe` -> exit 1, and `do_spl_spawn_share` before and after on sat (n=1 each). Docs: the SPL-1817 row says a review seat counts as its brief's class. | sat (the holder's box: the dispatch briefs are there) | claude | grok seat on sat (`do_spl_box_pick` picked sat for grok, section 8), else the claude waiver seat, fresh session, tree only | `simple_coding` | 1 |
| 02 `fix(b36-02-iac-role-check-quoted-and-inline-vault)` | **The customer box role check refuses `delegate_to: localhost`, `connection: local` and a vault file, but passes the same values quoted (`delegate_to: "localhost"`, `connection: 'local'`) and a vaulted value inside a vars file (`x: !vault \|`).** YAML reads a quoted and a bare scalar as one value, so a task run on the controller passes the ban list in its quoted spelling; an inline vault value is as unreadable to the check as a vault file, which it refuses because "its content is unreadable" (`:8`). The regex anchors the value right after the spaces (`SPL_CBR_ESTATE_RX`, `:82`: `delegate_to:[[:space:]]*(localhost\|127\.)`, `connection:[[:space:]]*local`); the vault test reads the first 14 bytes of a file only (`:65`). The check is spec 181 B6's gate that a private workspace's VM gets nothing of ours (`:3-6`). | spec 181 B6 R7 c-502@`<box2>` N1-N2 (msg b107cf3b, on `621ca31bd`, the candidates file); round 31 held them back only while spec 181 lanes were live (bug-round-31-plan.md:204); none is live now (lane map 22:43Z: no s181 / customer-box lane; the queue: none). The W1-W5 fix `3f33e9dab` kept both holes: rc02 RED on `3f33e9dab` (n=1, wrong=3). Re-measured here: rc02, RED 3 of 3 on `1685e0ebe`; with a sketch fix planted in the clone (`RC02_PLANT=1`) every case passes (wrong=0, n=1), so the control can turn green. | `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh:65` (`spl_cbr_key_files`, the vault test), `:82` (`SPL_CBR_ESTATE_RX`), `:3-26` (the header that names what it refuses); its test `csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` (section 3, the CONTROLS). Read only: `csi-spl-iac/src/ansible/customer-box/` (the shipped set must still pass). | `bash /var/spool-hub/dispatch/b36-red-controls/rc02.sh 1685e0ebe` (section 3.2) -> `rc02 dq: got=passed want=refused` / `rc02 sq: got=passed want=refused` / `rc02 ivault: got=passed want=refused` / `rc02 ctrl: got=refused/passed want=refused/passed` / `rc02 sha=1685e0ebe wrong=3`, exit 1, n=3 (22:47Z) | the check and its test only. `delegate_to` and `connection` are refused in their single- and double-quoted spellings (`dq`, `sq`); a `!vault` tag anywhere in a file of the set is refused as `vault` (`ivault`); the bare spellings stay refused and the shipped set still passes (`ctrl`). No other ban changes. The header says the quoted forms and the inline value are covered; its last sentence (a ban list cannot prove absence) stays. Out of scope, named so the lane does not grow: c-502's N3 (`when: 1 == 2`, `ignore_errors`, `failed_when: false` on role 04) and N4 (an absolute `copy src:`, base64-wrapped PEM), which are new bans, not a missed spelling of an existing one. The suite: rc02's four cases as CONTROLS of section 3 (`dq`, `sq`, `ivault` red on `1685e0ebe`). Commit body: rc02 on the fix -> exit 0, on `1685e0ebe` -> exit 1. Docs: the action's own header is its help; a `Docs: none (<why>)` line if the lane adds nothing under `csi-spl-doc/`. | sat or `<box2>` (no pin) | claude | grok seat on sat, else the claude waiver seat, fresh session, tree only | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02. Their files are disjoint: row 01 is two orc files and one doc, row 02 two iac files.
- **Test column (R2), row 01:** `git grep -l -E 'spl-spawn-share\|spl_spawn_share' 1685e0ebe -- '*.tst.sh' '*/tests/*.sh'` -> `spl-epic-stall-check.tst.sh`, `spl-reflection-gather.tst.sh`, `spl-security-round-queue.tst.sh`, `spl-spawn-after.tst.sh`, `spl-spawn-fill.tst.sh`, `spl-spawn-group.tst.sh`, `spl-spawn-place-argmax.tst.sh`, `spl-spawn-place-owner-prio.tst.sh`, `spl-spawn-place-supply.tst.sh`, `spl-spawn-queue.tst.sh`, `spl-spawn-share.tst.sh` (all `csi-spl-orc/src/bash/tests`). The fleet rules drift check (`cd csi-spl-orc && ./run -a do_check_fleet_rules_drift`, the doc row). Also `rc01.sh`.
- **Test column (R2), row 02:** `git grep -l -E 'customer-box-role-check\|spl_cbr_\|do_spl_customer_box_role_check' 1685e0ebe` -> `csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` (and the action, the playbook and bug-round-31-plan.md). The header and length gates `csi-spl-iac/src/bash/tests/action-header-tags.tst.sh` and `bash-cleancode.tst.sh`. Also `rc02.sh`.
- **Off limits** for the row lanes: every live and queued lane's files (below); `spl-spawn-enqueue.func.sh` and `spl-spawn-place.func.sh` (read only for row 01; c-012@sat has `spl-spawn-place.func.sh` modified, panel N2); the shipped role set `csi-spl-iac/src/ansible/customer-box/` (read only for row 02).
- **How the files were checked (2026-11-21, sat):**
  - 22:43:30Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-share.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh,csi-spl-doc/doc/md/bug-round-36-plan.md --agent c-009` -> `WARN no live lane lists` them, exit 4: 11 live lanes record no files, all on `<box2>` (c-028, c-063, c-146, c-806, c-812, c-855, c-924, c-927, g-050, g-079, m-035). 22:4xZ, the same for `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh,csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` -> exit 4, the same 11. Their slugs: rotations, two topic seats, SPL-6182 native auth (hub + store), the t1 issue backlog topic, R7 seats; none share- or role-check-shaped. The holder's own lane map on sat: exit 4, 13 `<box2>` lanes with no files, 0 sat owners of the 5 paths (msg 18c25d60). And the `<box2>` half (c-001@`<box2>` msg 749e7820, relayed by the holder 08c925ee): 0 hits on the 5 row paths across all 13 live `<box2>` lanes (per lane `git diff --name-only origin/master...HEAD` plus `git status --porcelain`, `grep -cE` on the exact paths; c-028, c-063, c-101, c-146, c-806, c-812, c-855, c-924, c-927, g-050, g-079, g-108, m-035).
  - 22:43:37Z, sat's worktrees (`git worktree list`, every one): `git diff --name-only origin/master...HEAD` plus the `git status --porcelain` paths, matched against `spl-spawn-share\|spl-spawn-enqueue\.func\|fleet-rules-index\.md` -> 1 hit, stale: `m-780` (`fleet-rules-index.md`; retired, as round 35 found it: rewritten copies of commits already on master). 22:53:40Z-22:55:20Z, the same walk for `spl-customer-box-role-check\|customer-box-role-set` -> 0 hits.
  - 22:44:38Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `7 queued, 0 placing`. Each queued brief, `grep -cE 'spl-spawn-share\|spl-spawn-enqueue\|fleet-rules-index'` -> 0 for all 7 (google site-verify file, #alerts seat-held r2, s123 L7, s123 L3w, SPL-5882 T3, csi-rel home lede, s154 B7). 22:55:20Z, the same 7 briefs, `grep -cE 'customer-box\|role-check'` -> 0 for all 7 (spec 181 has no queued row).
- **Slug b36 is unused as a round id** (sat, 22:3xZ, on `1685e0ebe`): `git log origin/master --since="$W" --oneline -E --grep='\(b36-'` -> 0. `git ls-remote origin 'refs/heads/review/b36-*' 'refs/heads/wip/*b36*' 'refs/heads/*-b36-*'` -> nothing. `ls /var/spool-hub/dispatch/briefs \| grep -E 'b36\|bug-round-36'` -> the planner's and the panel seat's briefs and one false match (a hand-placed topic seat brief whose topic id `3b8a0b36` holds `b36`), 0 row briefs. `git worktree list \| grep -E 'b36-[0-9]{2}\|bug-round-36'` -> this planner's only (`c-009-c002-bug-round-36-planner`). The `<box2>` half (749e7820): `grep -rlE 'b36-[0-9]{2}\|bug-round-36' /var/spool-hub/dispatch/briefs/ \| wc -l` -> 0; `git worktree list \| grep -cE 'b36-[0-9]{2}\|bug-round-36'` -> 0 (346 worktrees).

### 3.2 Red controls run on `1685e0ebe`

Both scripts are on sat under `/var/spool-hub/dispatch/b36-red-controls/` and printed below so a seat on `<box2>` can rebuild them. Each makes a throwaway `git clone --shared` of the checkout it runs from and checks out the sha. No network, no hub, no push, nothing installed; rc01 needs bash, git and jq, rc02 bash and git (and python3 for `RC02_PLANT=1` only).

| row | command | output | who |
|---|---|---|---|
| 01 | `bash rc01.sh 1685e0ebe`, from a checkout, n=3 (22:42Z; each a few seconds); `rc01.sh` 4292 B, `sha256sum` first 12 hex `4892e3219bbc` | RED in 3 of 3, the same output each time: `rc01 seat: got=feature want=bug` / `rc01 xbox: got=feature want=refactor` / `rc01 ctrl: got=feature/bug want=feature/bug` / `rc01 sha=1685e0ebe by={"refactor":0,"bug":1,"feature":3} wrong=2`, exit 1. `bash rc01.sh f6703d2b1` (c-001's tree) -> `wrong=2`, n=1. `RC01_PLANT=1 bash rc01.sh 1685e0ebe` (the brief read before the ask, a half fix) -> `seat` green, `xbox` still `got=feature`, `wrong=1`, exit 1, n=1: a seat on the other box needs the queued brief, not only the precedence. | editor c-009 |
| 02 | `bash rc02.sh 1685e0ebe`, n=3 (22:47Z; each a few seconds); `rc02.sh` 3262 B, first 12 hex `f951e08671e8` | RED in 3 of 3: `rc02 dq: got=passed want=refused` / `rc02 sq: got=passed want=refused` / `rc02 ivault: got=passed want=refused` / `rc02 ctrl: got=refused/passed want=refused/passed` / `rc02 sha=1685e0ebe wrong=3`, exit 1. `bash rc02.sh 3f33e9dab` (the W1-W5 fix) -> `wrong=3`, n=1. `RC02_PLANT=1 bash rc02.sh 1685e0ebe` -> every case met, `wrong=0`, exit 0, n=1 (a sketch only: it allows any one character before the value; the lane writes its own). | editor c-009 |

The RED-then-GREEN proof on the real fix is each row lane's commit body (C2).

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha>: b36-01 red control. On <sha>'s tree, runs spl_spawn_share
# (do_spl_spawn_share's JSON) on stubbed inputs: the lane map
# (SPAWN_SHARE_LANES_CMD), the hub's asks (ASKS_HUB_CMD) and a temp
# SPOOL_ROOT holding the lanes' briefs and the dispatch briefs. Each lane's
# class in the share's .lanes[] is compared with its brief's Class: line.
#   seat  : a bug R7 seat on THIS box, queued as feature + bypass on the
#           review-seat GO (SPL-5638), its lifetime brief says Class: bug
#                                               (RED: the share says feature)
#   xbox  : a refactor R7 seat on the OTHER box, same queueing; its brief is
#           in this box's dispatch/briefs/<slug>.md (Class: refactor)
#                                               (RED: the share says feature)
#   ctrl  : an owner-bypass feature (another msg id) and a plain bug ask keep
#           feature and bug (control: holds on every sha)
# A temp clone (git clone --shared), no network, no hub, nothing installed.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
top="$(git rev-parse --show-toplevel)"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
git clone -q --shared --no-checkout "$top" "$T/r" || exit 2
git -C "$T/r" -c advice.detachedHead=false checkout -q "$full" || exit 2
# RC01_PLANT=1: a half fix in the clone, the lane brief first ($briefs before $placed)
[[ "${RC01_PLANT:-0}" != 1 ]] || sed -i 's/class: (\$placed\[\$id\] \/\/ (\$briefs\[\$id\] \/\/ "" | cls)/class: (\$briefs[\$id] \/\/ \$placed[\$id] \/\/ "" | cls/' "$T/r/csi-spl-orc/src/bash/run/spl-spawn-share.func.sh"
GO=994f2257-8ad1-4010-88c8-4f0a16230937 OWN=11111111-2222-4333-8444-555555555555
S="$T/spool"; mkdir -p "$S/dispatch/briefs" "$S/asks" "$S/c-901/lifetime" "$S/c-903/lifetime" "$S/c-904/lifetime"
printf 'Lane brief\nClass: bug\n' >"$S/c-901/lifetime/brief.md"
printf 'Lane brief\nClass: bug\n' >"$S/dispatch/briefs/c002-b99-01-claude-waiver-reviewer.md"
printf 'Lane brief\nClass: refactor\n' >"$S/dispatch/briefs/c002-r99-01-grok-reviewer.md"
printf 'Lane brief\nClass: feature\n' >"$S/c-903/lifetime/brief.md"
printf 'Lane brief\nClass: bug\n' >"$S/c-904/lifetime/brief.md"
cat >"$T/lanes.json" <<'J'
{"lanes":[{"agent_id":"c-901","agent_box":"boxa","state":"live","age_s":60},
{"agent_id":"g-902","agent_box":"boxb","state":"live","age_s":60},
{"agent_id":"c-903","agent_box":"boxa","state":"live","age_s":60},
{"agent_id":"c-904","agent_box":"boxa","state":"live","age_s":60}]}
J
jq -n -c --arg go "$GO" --arg own "$OWN" '{asks: [
 {ask_id:"a1",state:"done",reason:"placed: c-901@boxa",class:"feature",flag:"bypass",flag_msg:$go,placement:"claude:c002-b99-01-claude-waiver-reviewer",summary:"R7 b99-01"},
 {ask_id:"a2",state:"done",reason:"placed: g-902@boxb",class:"feature",flag:"bypass",flag_msg:$go,placement:"grok:c002-r99-01-grok-reviewer",summary:"R7 r99-01"},
 {ask_id:"a3",state:"done",reason:"placed: c-903@boxa",class:"feature",flag:"bypass",flag_msg:$own,placement:"claude:c002-owner-feature",summary:"owner feature"},
 {ask_id:"a4",state:"done",reason:"placed: c-904@boxa",class:"bug",placement:"claude:c002-b99-02-fix",summary:"bug row"}]}' >"$T/asks.json"
printf '#!/usr/bin/env bash\ncat %q\n' "$T/asks.json" >"$T/hub.sh"; chmod +x "$T/hub.sh"
out="$(cd "$T/r/csi-spl-orc" && env SPOOL_TEST=1 SPOOL_ROOT="$S" SPOOL_ASKS_DIR="$S/asks" ASKS_BOX=boxa LANE_FLEET=fx \
  SPAWN_SHARE_LANES_CMD="cat $T/lanes.json" ASKS_HUB_CMD="$T/hub.sh" RHYTHM_NOW=2026-01-15T12:00Z APP_PATH="$T" PROJ_PATH="$T/r/csi-spl-orc" \
  bash -c 'do_log() { printf "%s\n" "$*" >&2; }
    source src/bash/features/spawn-agents/lib/spool-asks.inc.sh
    source src/bash/run/spl-asks-open.func.sh
    source src/bash/run/spl-spawn-share.func.sh
    spl_spawn_share' 2>"$T/err")" || { echo "rc01: spl_spawn_share failed:"; cat "$T/err"; exit 2; }
cls() { jq -r --arg i "$1" '.lanes[] | select(.id == $i) | .class' <<<"$out"; }
bad=0
chk() { echo "rc01 $1: got=$2 want=$3"; [[ "$2" == "$3" ]] || bad=$((bad + 1)); }
chk seat "$(cls c-901@boxa)" bug
chk xbox "$(cls g-902@boxb)" refactor
chk ctrl "$(cls c-903@boxa)/$(cls c-904@boxa)" feature/bug
echo "rc01 sha=${full:0:9} by=$(jq -c '.by | map_values(.n)' <<<"$out") wrong=$bad"
(( bad == 0 ))
```

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha>: b36-02 red control. On <sha>'s tree, runs
# do_spl_customer_box_role_check on copies of the shipped role set
# (csi-spl-iac/src/ansible/customer-box), each with one planted task line
# appended to role 02's tasks/main.yml, and on a copy with one inline-vaulted
# value in role 02's defaults. Each case must be REFUSED by the check named.
#   dq     : delegate_to: "localhost"   estate-ref  (RED: passes)
#   sq     : connection: 'local'        estate-ref  (RED: passes)
#   ivault : a var: !vault | value      vault       (RED: passes)
#   ctrl   : delegate_to: localhost (bare) is refused, and the shipped set
#            passes (control: holds on every sha)
# The same spellings are one YAML value; the check bans the bare one.
# A temp clone (git clone --shared), no network, no VM, nothing installed.
set -uo pipefail
sha="${1:?usage: rc02.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
top="$(git rev-parse --show-toplevel)"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
git clone -q --shared --no-checkout "$top" "$T/r" || exit 2
git -C "$T/r" -c advice.detachedHead=false checkout -q "$full" || exit 2
IAC="$T/r/csi-spl-iac"; SET="$IAC/src/ansible/customer-box"
# RC02_PLANT=1: a sketch fix in the clone (any one character before the value;
# a !vault value anywhere), only to show the cases can turn green.
if [[ "${RC02_PLANT:-0}" == 1 ]]; then
  python3 - "$IAC/src/bash/run/spl-customer-box-role-check.func.sh" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("delegate_to:[[:space:]]*(localhost", "delegate_to:[[:space:]]*.?(localhost")
s = s.replace("connection:[[:space:]]*local", "connection:[[:space:]]*.?local")
s = s.replace("""if head -c 14 "$f" 2>/dev/null | grep -F '$ANSIBLE_VAULT' >/dev/null; then""",
              """if grep -qE '^[$]ANSIBLE_VAULT|!vault' "$f" 2>/dev/null; then""")
open(p, "w").write(s)
PY2
fi
check() { (cd "$IAC" && CUSTOMER_BOX_ROLE_DIR="$1" ./run -a do_spl_customer_box_role_check 2>&1); }
plant() {  # <name> <file rel to role 02> <line...>
  local n="$1" f="$2"; shift 2
  rm -rf "$T/$n"; cp -a "$SET" "$T/$n"; mkdir -p "$(dirname "$T/$n/roles/02_spool_harness/$f")"
  printf '%s\n' "$@" >>"$T/$n/roles/02_spool_harness/$f"
}
# verdict <dir> <check name> -> refused|passed|other
verdict() {
  local out; if out="$(check "$1")"; then echo passed; return; fi
  grep -q "REFUSED $2:" <<<"$out" && echo refused || echo other
}
bad=0
chk() { echo "rc02 $1: got=$2 want=$3"; [[ "$2" == "$3" ]] || bad=$((bad + 1)); }
plant dq tasks/main.yml '- name: planted' '  ansible.builtin.command: "true"' '  delegate_to: "localhost"'
plant sq tasks/main.yml '- name: planted' '  ansible.builtin.command: "true"' "  connection: 'local'"
plant iv defaults/main.yml 'planted_secret: !vault |' '  $ANSIBLE_VAULT;1.1;AES256' '  6231356533396433'
plant bare tasks/main.yml '- name: planted' '  ansible.builtin.command: "true"' '  delegate_to: localhost'
chk dq "$(verdict "$T/dq" estate-ref)" refused
chk sq "$(verdict "$T/sq" estate-ref)" refused
chk ivault "$(verdict "$T/iv" vault)" refused
chk ctrl "$(verdict "$T/bare" estate-ref)/$(check "$SET" >/dev/null && echo passed || echo refused)" refused/passed
echo "rc02 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

No fix was written in the repo: the change belongs to the row lanes, with their own tests.

---

## 4. Round 35's inputs, round 34's R7 notes and the CI report, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b34-01 R7 c-855 N1 (`runtime-grants.sql`'s named `GRANT EXECUTE` is redundant with the schema-wide one at `:21`) and N3 (the door tells only a boolean per known sha, in the session tenant) | msgs dc1653a8 + db7a8207 (the holder's archive, 22:3xZ) | no W | **Not bugs**: N1 is harmless duplication (a refactor input), N3 is the reviewer's own "no leak found". |
| b34-01 R7 c-855 N2 (`TestDocAssetHeldDoorCatalogue`'s "PUBLIC has no EXECUTE" passes on a NULL `proacl`, so it would not see 0307's `REVOKE ... FROM PUBLIC` dropped) | the same | the grants are right today (c-855 read `proacl`: no PUBLIC entry) | **Test-shaped**: a pin that proves less than it says; nothing is wrong on the tree. An input for a test or refactor round. |
| b34-02 R7 c-823 N1 (rc02 rebuilt, sha matches), N2 (the `! -s` test at `spl-spawn-enqueue.func.sh:193` is redundant) | the holder's GO quoting bb1be608 (`dispatch-bug-r34`, 12:39Z) | no W | **Not bugs.** |
| SPL-6174's link to the relay hash `3e2c61b1` | `git grep -n 'spool-task:' 1685e0ebe -- csi-spl-orc csi-spl-api` -> the relay that mints it (`spool-fleet-relay.sh:210`), the hub's own hash (`lanes_registration.go:78`), and two readers that refuse a v5 id (`_spawn_lane_topic`, `spawn-core.inc.sh:285-300`; `RelayTaskHashRe`, `store/issue_discussions.go:121-122`) | the writer of that one link is still not named | **Not a row**: no writer, no red control. Carried. |
| The other parts of the pre-push gate | `WUI_E2E_RANGE=6a0cc0146^..d2557fbc4 ./run -a do_check_pre_push_e2e` (22:48Z) -> 6 e2e files selected, 378 CUT, among them `topic-menu-parity.test.mjs` (score 37), `poll-state-shared.test.mjs` (9) and `msg-deep-links.test.mjs` (6): the three that went red on trunk after SPL-6205 | the e2e part ran, but its ranked cut left out the tests that broke | **Not a row this round**: the cut is the design (a budgeted top-N; the R7 reviewer ran the 6 it selects, g-061's PASS line in `d2557fbc4`), and the red has its owner (source 2). Whether a test that names a changed UI entry (`msg-menu-export-topic-pdf`) should outrank the cut is a gate input. The orc tests that name a cnf env file (`git grep -l -E 'all\.env\.yaml\|(dev\|prd)\.env\.yaml' 1685e0ebe -- 'csi-spl-orc/src/bash/tests/*.tst.sh' 'csi-spl-orc/src/bash/features/*/tests/*.sh'` -> 66) gave no red in the 100 runs; not measured further. Carried. |
| The topic loop's hourly cap race (SPL-6032 R7 c-297 N2) | `topic_loop_postgres.go:183-189` on `1685e0ebe` | one `UPDATE ... SET fires_in_hour = ... WHERE ... fires_in_hour < $4`: a single statement, so its row lock re-checks the cap | **Not a bug** on this tree, as round 30 read it. SPL-6105 (the reason to stay off) landed `4c5633d84`. |
| The done-claim `job` label | sat `/var/csi/csi-spl/done-claim-check/cron.log` (47562 lines, 22:49Z): `grep -ciE 'job [0-9a-f]{7}'` -> 0 | 0 alerts | **Not a row**: the condition did not occur. Carried. |
| The lease vendor order writer | sat, 22:49Z: `grep -n LEASE_VENDOR_ORDER /var/spool-hub/dispatch/lease.conf` -> `12:LEASE_VENDOR_ORDER=claude,agy,claude2` | not reverted on sat | **Not a row.** No writer named. Carried. |
| b33-01 N1; the AltGr picker; the blog switcher's Enter; `blog.test.mjs:329` alone; `test-agent-name-shape.sh:89`; the orc/iac suites as the agent OS user; `gcp-billing-invoices.tst.sh` / `workspace-doc-preamble.test.mjs` 3rd sightings; the `tasks/forward/multicast <hex>` forms; b29-01 N1 on `<box2>`; the overlay mount; `<box2>`'s dashless `/tmp` trees; the `!inserted` branch; the trailing-newline briefs | round 35 section 4 | no new report; no sighting in the 100 runs (source 2) | **As round 35 read them.** Carried. |

---

## 5. The holder's candidates, re-measured; not a row this round

The candidates file has 110 lines (22:3xZ), as round 35 read it: no entry since. Every entry keeps round 35's verdict (its section 5) and round 31's (its section 5), except:

| candidate | command | result |
|---|---|---|
| The share counts an R7 seat as feature (added to this brief, c-001 e9b303da) | section 3 | **Row 01.** |
| spec 181 B6 R7 c-502 N1-N2 (inline `!vault`, quoted `delegate_to`) | section 3; lane map and queue: no spec 181 lane | **Row 02.** |
| spec 181 B6 R7 c-502 N3-N4 (`when: 1 == 2`, `ignore_errors`, `failed_when: false`; an absolute `copy src:`, base64 PEM) | `spl-customer-box-role-check.func.sh:23-26` (the header: a ban list; review is the check for what it does not name) | **Not a row**: new bans, not a missed spelling of one the check already makes. A hardening input. |
| spec 181 B5/B10 notes (c-507 N3-N5, N8; m-612 N1, N2, N4) | the candidates file | **Not bugs**: hardening and doc rows, as round 31 read them. |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row file on sat (lane map 22:43:30Z, worktrees 22:43:37Z, queue 22:44:38Z) or on `<box2>` (749e7820: 0 of 13 lanes). |
| The WUI e2e reds since `d2557fbc4` | c-934 (SPL-6205 fix-forward, `review/c003-wui-topic-pdf-all-posts-fix` at `e928128e5`) | Waiting for its delta R7 (msg 659574ab). |
| The unanswered-sweep delta-pg check 5; the pre-push full tier "no verdict after orc red" | ask 96e1cc3b (c-101@`<box2>`); c-982@sat | Their lanes, as the brief says. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 100 CI runs (1 open WUI red with its owner; the step-030 orc reds fixed); 5 R7 notes of round 34 (3 + 2); the brief's added candidate (1 live share snapshot); round 35's carried and first inputs; the candidates file (110 lines, unchanged); 2 red controls (n=3 each on `1685e0ebe`, n=1 each on an older sha, n=1 each planted); sat's `lease.conf` and the done-claim log |
| first inputs for round 37 | the R7 notes of b36-01 and b36-02; the e2e cut that left `topic-menu-parity.test.mjs` out of SPL-6205's selection (section 4); SPL-6174's relay-hash link, once its writer is named; b34-01 N2 (a test or refactor round); and every item carried in section 4 |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-009@sat (claude, `specs_and_docs`).
- **Panel:** the mistral seat (ask `c002-bug-round-36-mistral-panel-seat`). Neither row has a WUI file, so a mistral seat may sit (developer guide 5.1). It reviews the plan only; it writes no row code, and pushes with `PUSH_BRANCH=review/c002-bug-round-36-mistral-seat`.
- **Asked of the holder** (all answered):
  1. (answered, c-001@`<box2>` 749e7820 via 08c925ee: 0 hits in 13 lanes; section 3.1) The `<box2>` half of R3 on `spl-spawn-share.func.sh`, `spl-spawn-share.tst.sh`, `fleet-rules-index.md`, `spl-customer-box-role-check.func.sh` and `customer-box-role-set.tst.sh`.
  2. (answered, 749e7820: 0 briefs, 0 of 346 worktrees) The `<box2>` half of the slug proof.
  3. (answered, 18c25d60: none; the alerts seat-held bug is a live lane's) Whether a third row from the holder's own list belongs here (at most 3, rulebook 5.1).
- **Row reviewer (R7):** `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (22:49:45Z) -> `pick=sat reason=every box is at or above its high mark; sat is the least past its band (152% on high 90%, overflow 180%)`. So both rows name a grok seat on sat (claude author, grok reviewer: cross-vendor, rulebook 2.7.2); if the pick holds when a row is queued, the claude waiver seat (1a7c70da), fresh session, tree only. No mistral backup: both rows are `simple_coding`, a coding kind mistral does not take, as main or backup. An absent seat gets a replacement of an eligible vendor (rulebook 2.7.3).
- **Review history:**
  - 2026-11-21 22:57Z: v0.1 `83f118d35`, pushed to `review/c002-bug-round-36-planner`: two rows.
  - 2026-11-21 23:0xZ: m-011@sat (mistral) **PASS** on v0.1 `83f118d359003bc6b99c5de7691f050e65e61069`, no W (msg c792f329). It re-ran the slug proof, re-printed every cited line on `1685e0ebe`, `e69ffe2f9` and `61977111c`, checked both scripts' sha256, ran rc01 and rc02 (n=2 each on `1685e0ebe`, n=1 on the older shas, n=1 planted), the R2 greps, the lane map and `do_check_dist_hygiene`. Its line passes `REVIEW_LINE=... ./run -a do_spl_review_line_check` on sat (rc 0, "OK 2 of 2 named in ran:"; the editor's run, 23:1xZ). Seat file `a01e164cf`, folded as [bug-round-36/seat-mistral.md](bug-round-36/seat-mistral.md).
    - **N1**: origin/master moved twice during the review (`1685e0ebe` -> `e69ffe2f9` -> `61977111c`); the row files did not drift and the cited lines print the same. The editor re-checked at v1.0 on `75acaab9f`: `git diff --name-only 1685e0ebe 75acaab9f --` the five row files -> none.
    - **N2**: `lane-map.sh --check` exits 3 on `spl-spawn-place.func.sh`: c-012@sat (the alerts seat-held bug) has it modified now. Row 01 reads that file only; the row lane must not write it while c-012 is live (section 3.1, off limits).
    - **N3**: the lane map's exit 4 on the 5 row files (13 no-file lanes, all on `<box2>`); the `<box2>` half came back with 0 hits (section 3.1).
    - **N4**: the planted half fix leaves `xbox` red (wrong=1), as section 3.2 says; the row fix takes a cross-box seat's class from the queued brief in `dispatch/briefs`.
    - **N5**: the CI source (100 runs) was not re-run by the seat; the open red's owner branch was checked (`review/c003-wui-topic-pdf-all-posts-fix` = `e928128e5`). Since then SPL-6205's fix-forward landed on master (`75acaab9f`).
  - 2026-11-21 23:12Z: v1.0 landed on master as `aae0f987e` (the holder's GO b40b696e). No row changed.
  - 2026-11-21 23:1xZ: m-011@sat **PASS** on v1.0 `aae0f987eaa83c75d6cbc322fac1c005948da834`, no W (msg 1244f877; the holder's copy 1325feb3). N1-N5 stand as on v0.1. It re-checked at 23:16Z-23:18Z: 0 `(b36-NN-` row commits, only the planner and seat branches on origin, no row-file drift, rc01 and rc02 still RED on `1685e0ebe` (wrong=2 / wrong=3), lane map exit 4 unchanged, hygiene clean, the seat file blob-identical in `aae0f987e`. Its line passes `do_spl_review_line_check` on sat (rc 0, DOCS-ONLY; the holder c-003's run, msg 2acfa40e). Seat file `1de2c4dea` (its v1.0 section), folded here. The rows are queued: b36-01 ask dc208b13, b36-02 ask 8e132d60 (c-002 msg 4bef1bb0).
  - Round closed (c-009), no version bump: the 2 rows landed, b36-01 `ca8a0591c` + `b2a96ef8f`
    (SPL-6221, committed 2026-11-22T01:33:05Z; R7 g-158 grok W1 on `1c75262c8`, the slug path hole, fixed
    in `b2a96ef8f`, then PASS on `48ca10bea`) and b36-02 `cd1c499ee` (SPL-6222, committed 00:37:56Z;
    R7 g-161 grok PASS on `3e0bd6619`). `git patch-id --stable` of each landed commit equals its
    reviewed commit's (`ca8a0591c` = `1c75262c8` `100a401d3361`, `b2a96ef8f` = `48ca10bea`
    `36f0d7c850a7`, `cd1c499ee` = `3e0bd6619` `247d928fb04e`); `merge-base --is-ancestor` rc 0 for all
    three on `6048633fd`. Quality gate 10 **success** on `cd1c499ee` (44967633421) and on `b2a96ef8f`
    (44972084944). `gh run list --commit`: `b2a96ef8f` 16 runs, 10 success, 6 skipped, 0 red;
    `cd1c499ee` 13 runs, 7 success, 5 skipped, 1 failure (`00 ops: spool hub deploy lag watch`
    44967708480, the r86-02 hub lag per the holder, msg 015abe9a; neither row deploys). ACCEPTED by
    the holder c-002: b36-02 (msg 015abe9a, 01:15:17Z), b36-01 (msg e5084ffa, 02:07:20Z). Both rows
    are orc, iac and doc only: no hub or WUI deploy. The row suites were not re-run at close (the rows'
    R7 lines carry them). rc01 and rc02's green halves are in the rows' commit bodies.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-009@sat | v1.0 |
| Panel | m-011@sat (mistral) | **PASS** on v0.1 `83f118d35` (msg c792f329) and on v1.0 `aae0f987e` (msg 1244f877), no W |
| Holder | c-002@sat, then c-003@sat | GO on v1.0 (c-002 msg b40b696e); rows queued (4bef1bb0) |

- Closed: both rows landed (b36-01 `ca8a0591c` + `b2a96ef8f`, R7 g-158 PASS; b36-02 `cd1c499ee`,
  R7 g-161 PASS). This close record carries `Closes: SPL-6216`.
