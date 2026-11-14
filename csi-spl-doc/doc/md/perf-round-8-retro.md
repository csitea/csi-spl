# Perf round 8 (`p8`) - retrospective

Measured 2026-11-15 on trunk **`5815e76c5`** (`5815e76c5eb582a1c71b6df486155d2989b503c3`, `origin/master`) on `PC`.
Each count names the command that produced it; `n=1` per command unless stated; before/after figures reported by row lanes during the round are marked as not checked today where historical and cite their commit or topic source. This is R8 of [rounds-rulebook.md](rounds-rulebook.md) (sections 2.8 and 4.3); **section 8 (the last section) is the measured input list for perf round 9 (`p9`)**. Commit timestamps are converted to UTC. Epic: `SPL-2402`, Spec: `csi-spl-doc/specs/027-spool-performance`, Plan issue: `SPL-5456`, Retro lane issue: `SPL-5537`.

Plan: [perf-round-8-plan.md](perf-round-8-plan.md), authored by editor `c-101@PC` (claude) on `f67ead04e`, reviewed and signed PASS on `29030f905` by panel seats `g-168@PC` (grok, `b6de0461a`) and `m-176@PC` (mistral, `9af99eb52`), and landed on `master` as **`0a7a25ac1`** (`2026-11-13T21:57:03Z`; Qto import `05c8a9478`, doc `7cde6660`; consensus recorded in empty-tree commit `918ad06ac` at `22:24:39Z`). Round discussion: `t1` `#refactoring` topic `720c27be-44e6-4a3f-98f7-61f0bad0bf0c`.

---

## 1. What landed and what was dropped

`git log origin/master -E --grep='\(p8-0[0-9]' --format='%h %cI %s'` -> **3** row commits on `origin/master`, plus 1 follow-up regression fix (`82bb33d70`, `SPL-5519`, for `p8-04`):
- **3 of 4 planned rows landed** (`p8-01`, `p8-02`, `p8-04`), each in **1 row push** (rulebook 1.2).
- **1 planned row (`p8-03`, `SPL-5483`) dropped by its drop rule** (`< 15%` median gain at `n=10` interleaved), 0 commits.
- **0 reverts** (`git log origin/master --grep='Revert' --format=%s | /usr/bin/grep -cE 'p8-|SPL-5479|SPL-5482|SPL-5483|SPL-5500'` -> `0`).
- **14-day perf capacity share (rulebook 4.4)** on `5815e76c5`:
  `git log origin/master --since='14 days ago' --format=%s | /usr/bin/grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk '/^p/{p++} /^r/{r++} END{t=p+r; printf "perf %d refactor %d perf-share %s %s\n", p, r, (t ? sprintf("%.1f%%", 100*p/t) : "n/a"), (t == 0 ? "no-rows" : (5*p >= t ? "floor-met" : "under-20"))}'` -> **`perf 8 refactor 126 perf-share 6.0% under-20`**.

*(Second-box hostnames and OS usernames in quoted logs and paths below are written `PC` and `<user>` per public-repository distribution hygiene).*

| row | practice | state | landed sha(s) | lane -> reviewer | reported before -> after (`n`, source) | served state (R5) |
|---|---|---|---|---|---|---|
| `p8-01` (`SPL-5479`) | `csi-spl-orc` `./run` defers top-level `source` and constants in its next 5 costliest eager files (`93 -> 88` eager) | **Served** | `8c39ee3ef` (`2026-11-14T02:34:56Z`) | `c-236@PC` (claude) -> `g-271@PC` (grok) | On `0380b833e`: eager loop `n=7` median `440 ms (406..475) -> 356 ms (330..390)` (`-84 ms, -19%`); whole start `./run -a do_p8_no_such_action` `n=5` median `399 ms (356..424) -> 297 ms (273..334)` (`-102 ms, -26%`) (not checked today; commit `8c39ee3ef`) | Ancestor of `PC` shared checkouts (`merge-base --is-ancestor` rc 0); first tag `v1.2.0-c4` |
| `p8-02` (`SPL-5482`) | `spl_box_ws_cnf` reads one scalar key (`$ENV.env.yaml` `has()` then `all.env.yaml`) with plain `yq` instead of `yq eval-all` merge | **Served** | `1e1cf16f8` (`2026-11-14T02:28:50Z`) | `c-288@PC` (claude) -> `g-299@PC` (grok) | Plan command `n=5` median `0.037 s -> 0.009 s`; `spl_box_ws_cnf` on real `ENV=prd` cnf `n=5` median `0.049 s -> 0.013 s (-73%)`; reviewer `g-299` `n=5` median `0.070795 s -> 0.018354 s (-74%)` (not checked today; commit `1e1cf16f8`) | Ancestor of `PC` shared checkouts (rc 0); first tag `v1.2.0-c4` |
| `p8-03` (`SPL-5483`) | Pre-filter wf10's 6 fixed-pattern hygiene sweeps with one `grep -rlIP` pass | **Dropped** (`diss`) | None (0 commits) | `c-290@PC` (claude) | On `91cfe055b` (`git archive` 9,571 files, load `17..22`), `n=10` interleaved: wf10 excludes `2,972 -> 2,875 ms (-3.3%)`; plan probe excludes `2,824 -> 2,537 ms (-10.2%)` — both below 15% gate (not checked today; `dispatch-perf-r8` result `2026-11-14T02:03:09Z`) | Dropped before commit; `SPL-5483` ended `diss` |
| `p8-04` (`SPL-5500`) | `spl_lane_wt_scan` reads `spl_lane_repo_tops` once per scan and runs worktree git status 8-way in parallel | **Served** (after `82bb33d70`) | `75a38b791` (`10:18:32Z`), hang fix `82bb33d70` (`18:36:45Z`, `SPL-5519`) | `c-721@sat` (claude) -> `g-478@PC` (grok) | On `1638ca3a7` (`sat`, 102 worktrees, load 21), `n=5` interleaved median: `24,848 ms (19,488..29,233) -> 7,008 ms (4,836..9,285)` (`-72%`), `same=yes` 5/5; reviewer `g-478@PC` (269 worktrees, `n=3`): `18,007 -> 3,111 ms (-83%)` (not checked today; commit `75a38b791`) | Ancestor of `PC` shared checkouts (rc 0); first tags `v1.2.7-c4` / `v1.3.2-c4` |

---

## 2. Gate outcomes and dropped rows

### `p8-03`: Pre-filter wf10's 6 fixed-pattern hygiene sweeps (`SPL-5483`)
- **Drop rule (`perf-round-8-plan.md` section 3, row 03):** *"the lane re-measures arm A and B (`n=10`, interleaved); under 15% median gain it drops the row with that measurement"* (rulebook 4.1: *"A row whose measurement shows no gain is dropped from the round with that measurement, never landed as a guess"*).
- **Reported measurement:** Lane `c-290@PC` measured on `91cfe055b` (`git archive` export of 9,571 tracked files, load `17..22`, `n=10` interleaved rounds, writing `A.out` and `B.out` outside the swept tree; source: `spool tail --task dispatch-perf-r8` at `2026-11-14T02:03:09Z`, not re-run today):
  - **With wf10's actual exclude list (`excl`):** arm A median **`2,972 ms`** (`2,651..3,869 ms`) vs arm B median **`2,875 ms`** (`2,505..3,341 ms`) -> **`-3.3%`** (`-97 ms`), 19 hits byte-identical `10/10`.
  - **With the editor's `hyprobe.sh` exclude list:** arm A median **`2,824 ms`** (`2,161..3,336 ms`) vs arm B median **`2,537 ms`** (`2,004..2,953 ms`) -> **`-10.2%`** (`-287 ms`), 28 hits byte-identical `10/10`.
- **Why the editor's `n=5` probe had read `-22%`:** In `perf-round-8/editor.md` (`hyprobe.sh`), `A.out` and `B.out` were written inside the swept export directory (`$D`), inflating subsequent sweeps on arm A, and `n=5` under load jitter amplified the gap.
- **Outcome:** Dropped cleanly with 0 commits; `c-290` ended `SPL-5483` with status `diss` (`ACCEPTED` by `c-002@sat` at `02:05:37Z`).

---

## 3. Review line verification (`do_spl_review_line_check`), C4, C7, and R7.5

Checked on `PC` from `csi-spl-orc` with `REVIEW_LINE='<line>' ./run -a do_spl_review_line_check` (R8 step 1):
- **All 3 landed `p8` rows (`p8-01`, `p8-02`, `p8-04`) are verified `OK` (`rc=0`)** directly against their Grok reviewer session journals on `PC`.
- Follow-up regression fix `82bb33d70` (`fix(orc, SPL-5519)`) was reviewed by `g-831@sat`; its journal is on `sat` (`rc=2` on `PC`, `SYNTAX OK` with `REVIEW_LINE_SYNTAX=1`, seat `done` `3h` ago in `lane-map.sh --all`), so `82bb33d70`'s review line is **not verified** on `PC`.

### Row 01 (`8c39ee3ef`) — **verified OK** (`rc=0` on `PC`)
Command: `cd csi-spl-orc && REVIEW_LINE='review: g-271@PC grok PASS aec5625a032c6abaa87d979c9f7b18132a485673 ran: bash csi-spl-orc/src/bash/tests/run-eager-files.tst.sh; bash csi-spl-orc/src/bash/tests/gc-agent.tst.sh; bash csi-spl-orc/src/bash/tests/spl-box-leave.tst.sh; bash csi-spl-orc/src/bash/tests/spl-agent-login2-sync.tst.sh; bash csi-spl-orc/src/bash/tests/wd-situations.tst.sh; bash csi-spl-orc/src/bash/tests/lane-rotate.tst.sh; bash csi-spl-orc/src/bash/tests/dispatch-rotate.tst.sh; bash csi-spl-orc/src/bash/tests/agent-restart.tst.sh; bash csi-spl-orc/src/bash/tests/rotate-ack-seen.tst.sh | read: eager 88 rc 0; gc-agent 0; spl-box-leave 0; spl-agent-login2-sync 0; wd-situations 0; lane-rotate 0; dispatch-rotate 0; agent-restart 0; rotate-ack-seen 0; red control n=1 rc 1 (spl-gc eager, count 89) then reverted clean; hygiene rc 0; do_p8_no_such_action median 203 ms n=5 range 194..221 each rc 1 action not found; eager-loop split NOT RUN; head unchanged | log: g-271@PC:/home/<user>/.grok/sessions/%2Fopt%2Fcsi%2Fcsi-spl-wt%2Fg-271/01a1d7a0-1a26-7ca1-af33-5d867567ccd1/chat_history.jsonl' ./run -a do_spl_review_line_check`:
```text
OK 9 of 9 named in ran: are commands in /home/<user>/.grok/sessions/%2Fopt%2Fcsi%2Fcsi-spl-wt%2Fg-271/01a1d7a0-1a26-7ca1-af33-5d867567ccd1/chat_history.jsonl (12 commands read): run-eager-files.tst.sh, gc-agent.tst.sh, spl-box-leave.tst.sh, spl-agent-login2-sync.tst.sh, wd-situations.tst.sh, lane-rotate.tst.sh, dispatch-rotate.tst.sh, agent-restart.tst.sh, rotate-ack-seen.tst.sh
```

### Row 02 (`1e1cf16f8`) — **verified OK** (`rc=0` on `PC`)
Command: `cd csi-spl-orc && REVIEW_LINE='review: g-299@PC grok PASS 128c29dfb8799b133a45b1201ada9ded40917554 ran: bash csi-spl-orc/src/bash/tests/box-workspace-isolation.tst.sh ; ./run -a do_check_dist_hygiene | read: isolation rc 0, part 4 n=4, 0 eval-all, value equals merge for set, unset, empty and null; red control rc 1, 4 cases rejected, 1 eval-all (want 0), n=1, reverted clean; hygiene rc 0; real prd dev lde 4 keys EQUAL, yq v4.43.1, function median n=5 old 0.070795s new 0.018354s | log: g-299@PC:/home/<user>/.grok/sessions/%2Fopt%2Fcsi%2Fcsi-spl-wt%2Fg-299/01a1d7d0-ef85-7d13-b444-1fd07c81908a/chat_history.jsonl' ./run -a do_spl_review_line_check`:
```text
OK 1 of 1 named in ran: are commands in /home/<user>/.grok/sessions/%2Fopt%2Fcsi%2Fcsi-spl-wt%2Fg-299/01a1d7d0-ef85-7d13-b444-1fd07c81908a/chat_history.jsonl (12 commands read): box-workspace-isolation.tst.sh
```

### Row 04 (`75a38b791`) — **verified OK** (`rc=0` on `PC`)
Command: `cd csi-spl-orc && REVIEW_LINE='review: g-478@PC grok PASS 193010b061939e07cd8ef2dc87493c4dc2e87ec3 ran: bash csi-spl-orc/src/bash/tests/lane-map.tst.sh ; cd csi-spl-iac && ./run -a do_check_dist_hygiene ; bash /tmp/g-478-remeasure.sh | read: lane-map rc 0, 136 pass, case 22: 2 repo-tops git reads per scan (old shape 28), JSON byte-identical, jobs=1 same JSON; red control n=1 rc=1, 28 rev-parse --git-common-dir calls (at most 2), 12 lanes, 1 case red, 135 pass, then restored; hygiene rc 0 clean; remeasure PC n=3 worktrees=269 keys=267 same=yes 3/3 old ms 19194,17573,18007 median 18007 new ms 2803,3218,3111 median 3111 load 7.29-11.42 rc 0 both | log: g-478@PC:/home/<user>/.grok/sessions/%2Fopt%2Fcsi%2Fcsi-spl-wt%2Fg-478/01a1d97b-a558-76f2-9a28-9c87cc10f676/updates.jsonl' ./run -a do_spl_review_line_check`:
```text
OK 1 of 1 named in ran: are commands in /home/<user>/.grok/sessions/%2Fopt%2Fcsi%2Fcsi-spl-wt%2Fg-478/01a1d97b-a558-76f2-9a28-9c87cc10f676/updates.jsonl (159 commands read): lane-map.tst.sh
```

### Summary of C7, C4, and R7.5 checks
- **C7 (`git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l`)**:
  - `1e1cf16f8` vs `128c29dfb` (`p8-02`): **`0`** lines.
  - `75a38b791` vs `193010b06` (`p8-04`): **`0`** lines (and `82bb33d70` vs `4f1369835`: **`0`** lines).
  - `8c39ee3ef` vs `aec5625a0` (`p8-01`): **`16`** diff lines (`4 insertions(+), 1 deletion(-)`) in `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:59-62`. **C7 finding:** after `g-271@PC` issued `PASS` on `aec5625a0` with non-blocking comment note N1, dispatcher GO (`dispatch-perf-r8`, `2026-11-14T02:02:23Z`) told `c-236` to fold the 4-line comment clarification into the commit before pushing without re-running R7 on the new tree. Code statements were unchanged, but `spl-rotate-lib.func.sh` differed from `aec5625a0` by that comment hunk.
- **C4 (plan test-column coverage and `NOT RUN` list, rulebook 2.7.7)**:
  - Every test named in the plan's `test + red control` column ran and passed for all 3 landed rows (`run-eager-files.tst.sh` + 8 module suites on `p8-01`, `box-workspace-isolation.tst.sh` on `p8-02`, `lane-map.tst.sh` on `p8-04`).
  - `NOT RUN` entries recorded in `read:`: **1** — on `p8-01` (`8c39ee3ef`), `g-271@PC` recorded `eager-loop split NOT RUN` (it measured whole-start `do_p8_no_such_action` median `203 ms`, `n=5`, rather than the editor's scratch `phase5.sh` split).
- **R7.5 (review count and cross-vendor check)**:
  - `git log origin/master --grep='(p8-' --format=%B | /usr/bin/grep -c '^review: '` -> **`3`** (100% of the 3 landed rows; `p8-03` dropped with 0 commits).
  - Per-row vendor check (`cut -d' ' -f3`): all 3 reviewers are `grok` against `claude` authors -> **0 same-vendor reviews**.

---

## 4. CI verdict per row (R11) and dependent-batch SLA (R16)

First completed workflow 10 (`10_ci-quality.yml`) run on `master` whose `headSha` contains the row commit (`gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 200`, checked with `git merge-base --is-ancestor <row> <head>`):

| row | commit | first completed wf10 run (`head`) | conclusion | R11.2 verdict |
|---|---|---|---|---|
| `p8-02` | `1e1cf16f8` | `43546626665` (`1e1cf16f8`, `2026-11-14T02:29:55Z`) | `success` | **pass** |
| `p8-01` | `8c39ee3ef` | `43548126815` (`8c39ee3ef`, `2026-11-14T02:46:25Z`) | `success` | **pass** |
| `p8-04` | `75a38b791` | `43586029561` (`75a38b791`, `2026-11-14T10:35:42Z`) | `success` | **pass** |
| `SPL-5519` (fix for `p8-04`) | `82bb33d70` | `43628994548` (`82bb33d70`, `2026-11-14T18:52:22Z`) | `success` | **pass** |

- **R16 (Batch 2 placement SLA, <= 30 min after prerequisite lands):** Prerequisite `p7-02` (`8e80a7926`) landed on `master` at `2026-11-14T08:18:20Z`. Batch 2 row `p8-04` (`c-721@sat`) authored `75a38b791` at `09:14:00Z` (`+55m 40s` from prerequisite landing to finished commit) and landed on `master` at `10:18:32Z`.

---

## 5. Timeline: from plan to last landing

- **Plan landed (`0a7a25ac1`):** `2026-11-13T21:57:03Z` (Qto import `05c8a9478` at `22:04:21Z`; closing note `918ad06ac` at `22:24:39Z`).
- **Row `p8-03` dropped by gate (`SPL-5483`):** `2026-11-14T02:03:09Z` (`+4h 06m 06s`).
- **First landed row (`p8-02`, `1e1cf16f8`):** `2026-11-14T02:28:50Z` (`+4h 31m 47s`).
- **Second landed row (`p8-01`, `8c39ee3ef`):** `2026-11-14T02:34:56Z` (`+4h 37m 53s`).
- **Batch 2 prerequisite (`p7-02`, `8e80a7926`):** `2026-11-14T08:18:20Z`.
- **Last planned row landed (`p8-04`, `75a38b791`):** `2026-11-14T10:18:32Z`.
- **Follow-up hang fix (`SPL-5519`, `82bb33d70`):** `2026-11-14T18:36:45Z`.
- **Total elapsed time:**
  - Plan (`0a7a25ac1`) to last planned row (`75a38b791`): **12 hours, 21 minutes, 29 seconds**.
  - Plan (`0a7a25ac1`) to `p8-04` regression fix (`82bb33d70`): **20 hours, 39 minutes, 42 seconds**.

---

## 6. Remote branch pruning (R8 step 2)

Dry run (`cd csi-spl-orc && sudo -u <user> env ROUND=p8 ./run -a do_git_prune_round_branches`):
```text
KEEP review/p8-01-orc-eager-next5-lazy 1 unlanded
DRY_RUN round p8: 0 branch(es) listed, 1 kept unlanded on origin, nothing deleted (DRY_RUN=0 deletes the listed)
```
Live run (`cd csi-spl-orc && sudo -u <user> env ROUND=p8 DRY_RUN=0 ./run -a do_git_prune_round_branches`):
```text
KEEP review/p8-01-orc-eager-next5-lazy 1 unlanded
round p8: nothing to delete on origin, 1 kept unlanded
```
- `review/p8-02` and `review/p8-04` had already been pruned earlier.
- `do_git_prune_round_branches` refused to delete `review/p8-01-orc-eager-next5-lazy` (`aec5625a0`) because the post-review 4-line comment edit in `8c39ee3ef` (section 3, C7) changed its `git patch-id`, causing `git cherry` to classify `aec5625a0` as `1 unlanded`.
- `git ls-remote --heads origin '*perf-round-8*'` also shows the two panel seat branches (`b6de0461a refs/heads/review/c002-perf-round-8-grok-seat` and `9af99eb52 refs/heads/review/c002-perf-round-8-mistral-seat`), outside `do_git_prune_round_branches`'s ref pattern.

---

## 7. What went wrong, what was left unfixed, and verification commands

### What went wrong in running the round
1. **`p8-04` (`75a38b791`) introduced a fleet-wide `lane-map.sh --check` hang under `./run` (`SPL-5519`, fixed in `82bb33d70`):**
   - `spl_lane_wt_scan` launched up to 8 background workers and synchronized with bare `wait -n` and `wait` in the main shell. When invoked via `./run -a do_spl_lane_map` (as `lane-map.sh` does), `run.sh` holds two `>(do_run_log_tee)` process substitutions open as child jobs until exit; bare `wait` blocked forever on those tee children (`rc=124` at 90s on `sat`, `do_wait` on `PC`), breaking pre-edit and pre-spawn R3 checks for ~8 hours.
   - Neither author `c-721@sat` nor reviewer `g-478@PC` nor CI caught it because `lane-map.tst.sh` sourced `spl-lane-map.func.sh` directly without `./run`'s log tees. `82bb33d70` fixed `spl_lane_wt_scan` to track and `wait "${pids[@]}"` on its own worker PIDs and added `lane-map-run-tees.tst.sh`.
   - Reviewer `g-478` also noted (N1) that `spl_lane_wt_scan`'s `tmp=$(mktemp -d)` sets no `EXIT/INT/TERM` trap, so an interrupted scan leaks `/tmp/tmp.*` directories (forwarded separately to the dispatch lease holder as a non-perf hygiene fix).
2. **`perf-round-8-plan.md` landed (`0a7a25ac1`) and imported to Qto (`05c8a9478`) still marked `v0.1, draft` without panel signatures:**
   - Editor `c-101` pushed `0a7a25ac1` before updating line 5 (`Status: v0.1, draft on review/c001-perf-round-8-planner`) or section 9 Consensus (which lists only `c-101`, omitting `g-168` `b6de0461a` and `m-176` `9af99eb52`), and recorded consensus only in empty commit `918ad06ac` after Qto import (forwarded separately to the dispatch lease holder).
3. **Post-review edit on `p8-01` (`8c39ee3ef`) broke C7 identity and `do_git_prune_round_branches`:**
   - Folding `g-271`'s N1 comment change after `PASS` without re-reviewing left a 16-line diff between `aec5625a0` and `8c39ee3ef` and caused `do_git_prune_round_branches` to keep `review/p8-01-orc-eager-next5-lazy` as `unlanded`. Any post-review edit — even to a comment — needs either re-review or a separate follow-up commit.
4. **Editor baseline probe on `p8-03` polluted its own input tree:**
   - Writing `A.out` and `B.out` inside the swept archive directory during the `n=5` editor probe inflated arm A (`-22%` apparent gain vs `-3.3%` clean on wf10 excludes); the `n=10` drop rule caught it before any code landed.
5. **Incomplete topic tracking (`720c27be`), panel stall (`m-176`), and out-of-order `p9` start:**
   - None of the 3 landed rows (`p8-01`, `p8-02`, `p8-04`) had its result posted to `720c27be` or appeared on its status card (which listed only `diss` issues `SPL-5464`, `SPL-5468`, `SPL-5483`), and per-row discussions (rulebook 4.3) were not linked. Panel seat `m-176` stalled on a tool error at `21:44Z` until poked by `c-101`. Meanwhile `p9` planner (`c-723@sat`, `SPL-5502`) started before `p8-04` landed and before `p7`/`p8` retros existed.

### What the round found but did not fix
- **Already drafted in open `perf-round-9-plan.md` (`origin/review/c002-perf-round-9-planner` at `89f8cef14`, `SPL-5502`):** `p9-01` (`spl-private-cnf.func.sh` hidden-workspace single lookaround), `p9-02` (`sec-trufflehog.func.sh` control-verdict cache per binary sha256), and `p9-03` (`10_ci-quality.yml` ASCII sweeps `LC_ALL=C`).
- **Still unmeasured in an isolated lab / bundle lane (from `perf-round-8-plan.md` section 6):** test Postgres `fsync=off` (`spec 027` row 6, `hub-live-stack.sh:53-54` / `hub-pg.tst.sh`, needs its own 40-min A/B lane), `ListReleaseNotes` count subquery (`p5` input 1, needs prd-sized lab Postgres), `topic_head_apply_marks` on `r` marks (`p5` input 3, lab write test), and WUI `p6-08` / `p6-09` (needs built WUI bundle + Chrome). Non-perf items from `p8` section 6 (`fallback_postgres.go` duplicate predicate and `internal/payments` coverage floor) were routed to refactor rounds, not perf rounds.

### Commands run to verify this retro
```bash
git log origin/master -E --grep='\(p8-0[0-9]' --format='%h %cI %s'
git log origin/master --grep='(p8-' --format=%B | /usr/bin/grep -c '^review: '
cd csi-spl-orc && REVIEW_LINE='<line>' ./run -a do_spl_review_line_check
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
git range-diff aec5625a0~1..aec5625a0 8c39ee3ef~1..8c39ee3ef
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 200 --json databaseId,headSha,conclusion,createdAt
cd csi-spl-orc && sudo -u <user> env ROUND=p8 ./run -a do_git_prune_round_branches
cd csi-spl-orc && sudo -u <user> env ROUND=p8 DRY_RUN=0 ./run -a do_git_prune_round_branches
```

---

## 8. Five measured inputs for perf round 9 (measured on `5815e76c5`)

All 5 inputs below were measured on `PC` (load `35..38`) on today's `origin/master` commit **`5815e76c5`** (`5815e76c5eb582a1c71b6df486155d2989b503c3`), and are disjoint from the 3 rows already drafted on `origin/review/c002-perf-round-9-planner` (`89f8cef14`).

### Input 1: `do_spl_commit_links_check` runs `do_spl_cloud_cnf` (`yq eval-all`) twice per push and even on an empty commit range
- **Site:** `csi-spl-orc/src/bash/run/spl-commit-links-check.func.sh:42,51,136-145,163-177` (invoked on every push by the `commit-links` pre-push part). `_spl_cl_hub()` runs `( ENV=prd; do_spl_cloud_cnf && do_gcp_sa_key_file )` at line 42 before checking whether `shas` (`COMMIT_LINKS_RANGE`) is empty at line 51, and `_spl_cl_hub_read()` runs a second `do_spl_cloud_cnf` + `do_gcp_pin_account` at lines 168–170 instead of reading rendered `csi-spl-cnf/csi-spl/prd.env.json` once.
- **Measurement command (on `5815e76c5eb582a1c71b6df486155d2989b503c3`, `n=5`):**
  ```bash
  for r in 1 2 3 4 5; do
    t0=${EPOCHREALTIME/./}; ( cd csi-spl-orc && COMMIT_LINKS_RANGE=HEAD~1..HEAD COMMIT_LINKS_HARD=0 ./run -a do_spl_commit_links_check >/dev/null 2>&1 )
    t1=${EPOCHREALTIME/./}; ( cd csi-spl-orc && COMMIT_LINKS_RANGE=HEAD~1..HEAD COMMIT_LINKS_HUB=none ./run -a do_spl_commit_links_check >/dev/null 2>&1 )
    t2=${EPOCHREALTIME/./}; ( cd csi-spl-orc && COMMIT_LINKS_RANGE=HEAD..HEAD COMMIT_LINKS_HARD=0 ./run -a do_spl_commit_links_check >/dev/null 2>&1 )
    t3=${EPOCHREALTIME/./}; echo "run $r: prd_1commit=$(( (t1-t0)/1000 ))ms hub_none_1commit=$(( (t2-t1)/1000 ))ms empty_range=$(( (t3-t2)/1000 ))ms"
  done
  ```
- **Measured value (`n=5` medians):** `prd_1commit` **`1,273 ms`** (`1,195..1,393 ms`); `hub_none_1commit` **`784 ms`** (`661..1,033 ms`); `empty_range` (`0` commits) **`991 ms`** (`860..1,171 ms`). Short-circuiting `0`-commit ranges before `_spl_cl_hub` and reading rendered `prd.env.json` once eliminates both `yq eval-all` merges.

### Input 2: `do_check_fleet_rules_drift` spends `1.56 s` per pre-push hygiene run in whole-tree `grep -r` and per-line `grep`/`sed` fork loops
- **Site:** `csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh:96-160,291-332` (runs inside pre-push `hygiene` on every push). `_frd_repo_refs` runs recursive `grep -rhoE` across `$1/csi-spl-*` (instead of `git -C "$1" grep` or one `awk` pass) and forks `grep -qxF` per reference; `_frd_id_letters`, `_frd_ceiling_count`, `_frd_data_rule`, and `_frd_language_rule` fork `grep`/`sed` in nested `while read` loops.
- **Measurement command (on `5815e76c5eb582a1c71b6df486155d2989b503c3`, `n=5`):**
  ```bash
  for r in 1 2 3 4 5; do
    bash -c 'source csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh >/dev/null 2>&1; _frd_log(){ :; }; t0=${EPOCHREALTIME/./}; FLEET_RULES_TREE="$PWD" do_check_fleet_rules_drift >/dev/null 2>&1; t1=${EPOCHREALTIME/./}; echo "run '$r': $(( (t1-t0)/1000 ))ms"'
  done
  ```
- **Measured value (`n=5` median):** **`1,564 ms`** (`1,283..1,844 ms`); single-pass breakdown shows `_frd_repo_refs` `593 ms`, `_frd_ceiling_count` `393 ms`, `_frd_data_rule` `325 ms`, `_frd_id_letters` `319 ms`, `_frd_language_rule` `245 ms`.

### Input 3: `_pp_wui_external` in `check-pre-push.func.sh` forks per-line `grep -oE` / `sed -E` across 400+ WUI `.mjs` files (`730 ms` on every `do_check_pre_push` start)
- **Site:** `csi-spl-iac/src/bash/run/check-pre-push.func.sh:153-175`. Called unconditionally when building part keys on `do_check_pre_push`, `_pp_wui_external` pipes `grep` over `csi-spl-wui/tests/unit/*.mjs` and `src/node/**/*.mjs` into a bash `while IFS= read -r line` loop that forks `grep -oE "$_PP_WUI_EXT_RE"` (and `sed -E`) once per matching line to emit 52 path tokens.
- **Measurement command (on `5815e76c5eb582a1c71b6df486155d2989b503c3`, `n=5`):**
  ```bash
  for r in 1 2 3 4 5; do
    bash -c 'source csi-spl-iac/src/bash/run/check-pre-push.func.sh >/dev/null 2>&1; t0=${EPOCHREALTIME/./}; out=$(_pp_wui_external "$PWD"); t1=${EPOCHREALTIME/./}; echo "run '$r': $(( (t1-t0)/1000 ))ms words=$(wc -w <<<"$out")"'
  done
  ```
- **Measured value (`n=5` median):** **`730 ms`** (`651..780 ms`, `52` words) per `do_check_pre_push` invocation; replaceable by one `awk` pass (or keyed cache over those `.mjs` files).

### Input 4: Next 5 costliest eager files in `csi-spl-orc` `./run` (`88 -> 83` eager files)
- **Site:** `csi-spl-orc/src/bash/run/{spl-wd-takeover,spl-peer-crons,spl-wd-peers,spl-wd-ensure,spl-asks-open}.func.sh` and `csi-spl-orc/src/bash/tests/run-eager-files.tst.sh` (`MAX_EAGER=88`). After `p7-04` and `p8-01`, 88 eager files remain in `csi-spl-orc` (`483.1 ms` fresh-shell eager-loop median, `n=5`), led by these 5 files sourcing `.inc.sh` libraries at top level instead of on first call.
- **Measurement command (on `5815e76c5eb582a1c71b6df486155d2989b503c3`, `n=5` per file in clean `bash -c` shells):**
  ```bash
  for f in spl-wd-takeover spl-peer-crons spl-wd-peers spl-wd-ensure spl-asks-open; do
    p="csi-spl-orc/src/bash/run/$f.func.sh"; s=()
    for r in 1 2 3 4 5; do s+=("$(bash -c 'do_log(){ :; }; t0=${EPOCHREALTIME/./}; source "$1" >/dev/null 2>&1 || true; t1=${EPOCHREALTIME/./}; echo $(( (t1-t0)/1000 ))' _ "$p")"); done
    printf '%s: median=%sms samples=(%s)\n' "$f" "$(printf '%s\n' "${s[@]}" | sort -n | sed -n 3p)" "${s[*]}"
  done
  ```
- **Measured value (`n=5` isolated medians):** `spl-wd-takeover` **`146 ms`** (`119..177`), `spl-peer-crons` **`73 ms`** (`69..88`), `spl-wd-peers` **`64 ms`** (`54..71`), `spl-wd-ensure` **`58 ms`** (`45..63`), `spl-asks-open` **`38 ms`** (`34..42`) — **`379 ms`** sum of isolated medians (`183.1 ms` incremental inside the `483.1 ms` 88-file loop when shared `.inc.sh` guards fire).

### Input 5: `csi-spl-iac` `./run` still eagerly sources `36` of its `185` `.func.sh` files (`411 ms` no-op startup median)
- **Site:** `csi-spl-iac/src/bash/run/*.func.sh` (`p7-04` and `p8-01` stubbed eager files only in `csi-spl-orc`, leaving `csi-spl-iac` untouched; every pre-push, lint, and hygiene call starts `csi-spl-iac/./run`).
- **Measurement command (on `5815e76c5eb582a1c71b6df486155d2989b503c3`, `n=5`):**
  ```bash
  for r in 1 2 3 4 5; do t0=${EPOCHREALTIME/./}; ( cd csi-spl-iac && ./run -a do_no_such_action >/dev/null 2>&1 || true ); t1=${EPOCHREALTIME/./}; echo "run $r: $(( (t1-t0)/1000 ))ms"; done
  bash -c 'T=$(mktemp -d); trap "rm -rf \"$T\"" EXIT; sed "/^main \"\\\$@\"\$/d" csi-spl-iac/src/bash/run/run.sh >"$T/nomain.sh"; mapfile -d "" files < <(find csi-spl-iac/lib/bash/funcs csi-spl-iac/src/bash/run -type f -name "*.func.sh" -print0 2>/dev/null | sort -z); source "$T/nomain.sh" >/dev/null 2>&1; trap - ERR; set +u; _rl_eager=(); _rl_cand=(); declare -A _rl_files=(); eval "$(printf "%s\0" "${files[@]}" | xargs -0 -r awk "$_RUN_INDEX_AWK")"; echo "iac total=${#files[@]} eager=${#_rl_eager[@]}"'
  ```
- **Measured value (`n=5` median):** **`411 ms`** (`331..430 ms`) startup for a no-op action, with **`36`** of **`185`** `.func.sh` files classified as eager (`check-pre-push.func.sh:110-119` alone eagerly sources 5 sibling `.func.sh` files on every `iac` `./run` start).
