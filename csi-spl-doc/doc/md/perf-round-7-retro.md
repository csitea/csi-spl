# Perf round 7 (`p7`) - retrospective

Measured 2026-11-15 on trunk **`5815e76c5`** (`5815e76c5eb582a1c71b6df486155d2989b503c3`, `origin/master`) on `PC`.
Each count names the command that produced it; `n=1` per command unless stated; before/after figures reported by row lanes during the round are marked as not checked today where historical and cite their commit or topic source. This is R8 of [rounds-rulebook.md](rounds-rulebook.md) (sections 2.8 and 4.3). Commit timestamps are converted to UTC. Epic: `SPL-2402`, Spec: `csi-spl-doc/specs/027-spool-performance`, Plan issue: `SPL-5424`, Retro lane issue: `SPL-5537`.

Plan: [perf-round-7-plan.md](perf-round-7-plan.md), v1.1 signed on `dd82bb604` and landed on `master` as **`e7d5d3b2e`** (`2026-11-13T12:00:58Z`; Qto import `e0572925f`, doc `167e29ab`, `SPL-5449`), authored by editor `c-660@sat` (claude) and signed by panel seats `g-666@sat` (grok, `41d428c02`) and `m-669@sat` (mistral, `c147ab4c8`). Round discussion: `t1` `#refactoring` topic `f6cc015c-97b8-4ada-ab61-2f8aa125e793`.

---

## 1. What landed and what was dropped

`git log origin/master -E --grep='\(p7-0[0-9]' --format='%h %cI %s'` -> **5** row commits on `origin/master`, plus 1 follow-up test-margin fix (`2ba18c068` on `SPL-5445`):
- **5 of 5 planned rows landed** (`p7-01`..`p7-05`).
- **0 dropped rows** (every planned row cleared its measurement and red-control gate).
- **0 reverts** (`git log origin/master --grep='Revert' --format=%s | /usr/bin/grep -cE 'p7-|SPL-544[5-8]|SPL-5492'` -> `0`).

*(The hostname of the box where this retro ran is written `PC`, and OS usernames in quoted command outputs and paths are written `<user>`, per public-repository distribution hygiene; the second box `sat` stays literal).*

| row | practice | state | landed sha(s) | lane -> reviewer | reported before -> after (`n`, source) | served state (R5) |
|---|---|---|---|---|---|---|
| `p7-01` (`SPL-5445`) | Encode channel, status, budget and flow WUI frames once, write raw bytes per socket | **Served** | `68eff35cd` (`17:40:02Z`), fix `2ba18c068` (`18:09:15Z`) | `c-034@PC` (claude) -> `g-691@sat` (grok) | 10-socket scratch bench (`go test ./internal/hub -bench P7 -benchmem -count=5`) on `c65b7d546`, `n=5` median: `342 -> 217 allocs/op (-37%)`, `20,923 -> 17,083 B/op (-18%)`, `81,084 -> 57,769 ns/op (-29%)` (not checked today; commit `68eff35cd`) | `dev` & `prd` hub `served=9a96747b` (`do_check_deploy_lag` rc 0); first tag `v1.1.4-c4` |
| `p7-02` (`SPL-5492`) | `spl_lane_local_rows` forks one `jq -R -s` for all lane worktrees instead of per-worktree `jq`/`dirname`/`basename` | **Served** | `8e80a7926` (`2026-11-14T08:18:20Z`) | claude (`sat`) -> `g-719@sat` (grok) | `spl_lane_local_rows` on `0184b4d70` (127 worktrees, 97 lane rows), `n=5` interleaved median: `2,509 ms (2,362..2,883) -> 118 ms (98..132)` (`-95%`), byte-identical 5/5 (not checked today; commit `8e80a7926`) | Ancestor of `PC` shared checkouts (`merge-base --is-ancestor` rc 0); first tag `v1.2.6-c4` |
| `p7-03` (`SPL-5446`) | `./run` caches `_RUN_INDEX_AWK` output per user and tree (`orc`, `iac`, `utl`) | **Served** | `91cfe055b` (`2026-11-14T01:44:49Z`) | `c-035` (claude; `/var/spool-hub/reports/c-035.md` on `PC`, commit body writes `sat`) -> `g-218@PC` (grok) | On `d55284138`: index miss `336 ms` vs cache hit `105 ms` (`n=7` median, load 82); whole `./run -a do_p7_no_such_action` interleaved `n=11` median: uncached `1,657 ms` vs hit `1,369 ms` (`-17%`) (not checked today; commit `91cfe055b`) | Ancestor of `PC` shared checkouts (rc 0); first tag `v1.2.0-c4` |
| `p7-04` (`SPL-5447`) | `csi-spl-orc` `./run` defers top-level `source` and `dpkg` in its 5 costliest eager files (`98 -> 93` eager) | **Served** | `f0d0efa4e` (`16:47:44Z`) | `c-677@sat` (claude) -> `g-681@sat` (grok) | Eager-phase loop on `d55284138` (load ~103), `n=5` interleaved median: `618 ms (563..732) -> 457 ms (406..528)` (`-161 ms, -26%`), eager count `98 -> 93` (not checked today; commit `f0d0efa4e`) | Ancestor of `PC` shared checkouts (rc 0); first tag `v1.1.3-c4` |
| `p7-05` (`SPL-5448`) | Short `spool` CLI execs (`spool-send.sh`, `asks.sh`, `spl-peer-poll.func.sh`) run with `GOMAXPROCS=1` via `spool_cli` | **Served** | `27fd9e0c1` (`17:11:11Z`) | claude (`sat`) -> `g-680@sat` (grok) | Scratch `SPOOL_ROOT` on `d55284138` (load 23.5), `n=20` interleaved median: `spool send` `41 -> 31 ms CPU (-24%)`, `32 -> 31 ms wall`; `spool recv` `29 -> 20 ms CPU (-31%)`, `22 -> 20 ms wall` (not checked today; commit `27fd9e0c1`) | Ancestor of `PC` shared checkouts (rc 0); first tag `v1.1.3-c4` |

Push count per row (rulebook 1.2, aim 1, max 5): 4 rows (`p7-02`..`p7-05`) landed in **1 push**; `p7-01` took **2 pushes** (`68eff35cd` + `2ba18c068`).

---

## 2. Review line verification (`do_spl_review_line_check`), C4, C7, and R7.5

Checked on `PC` from `csi-spl-orc` with `REVIEW_LINE="$(git log -1 --format=%B <landed sha> | grep '^review:')" ./run -a do_spl_review_line_check` (R8 step 1; in the `sat` rows below, the echoed `on sat:` command uses the same `$(git log ...)` form in place of the literal line so it is re-runnable as written without redacted `<user>` paths):
- **1 of 5 row review lines (`p7-03`, `91cfe055b`, reviewer `g-218@PC`) is verified `OK` (`rc=0`)** against its reviewer session journal on `PC`.
- **4 of 5 row review lines (`p7-01`, `p7-02`, `p7-04`, `p7-05`) are `not verified`**: their reviewer journals live on `sat` (`rc=2` on `PC`), each passes `REVIEW_LINE_SYNTAX=1` (`SYNTAX OK`, `rc=0`) on `PC`, and `lane-map.sh --all` shows all four reviewer seats (`g-691@sat`, `g-719@sat`, `g-681@sat`, `g-680@sat`) already in state `done` (`15h`–`30h` old), so none is open to receive a `spool-send.sh` task on `sat`. Per rulebook 2.8 step 1, those four lines are listed as **not verified**.
- Follow-up fix `2ba18c068` (`fix(api, SPL-5445)`) landed under R11.3 (non-row subject for a trunk-red test flake) and carries no `review:` trailer on `origin/master`.

### Row 01 (`68eff35cd`) — **not verified** (log on `sat`, seat `g-691@sat` closed; syntax OK on `PC`)
Command: `cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B 68eff35cd | grep '^review:')" ./run -a do_spl_review_line_check` (`rc=2`):
```text
REFUSED the log is on box 'sat', this is 'PC': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE="$(git log -1 --format=%B 68eff35cd | grep '^review:')" ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1` (`cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B 68eff35cd | grep '^review:')" REVIEW_LINE_SYNTAX=1 ./run -a do_spl_review_line_check`, `rc=0`):
```text
SYNTAX OK the line's format and reviewer check on PC; the run is not (the log is on sat): on sat: REVIEW_LINE="$(git log -1 --format=%B 68eff35cd | grep '^review:')" ./run -a do_spl_review_line_check
```

### Row 02 (`8e80a7926`) — **not verified** (log on `sat`, seat `g-719@sat` closed; syntax OK on `PC`)
Command: `cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B 8e80a7926 | grep '^review:')" ./run -a do_spl_review_line_check` (`rc=2`):
```text
REFUSED the log is on box 'sat', this is 'PC': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE="$(git log -1 --format=%B 8e80a7926 | grep '^review:')" ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1` (`cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B 8e80a7926 | grep '^review:')" REVIEW_LINE_SYNTAX=1 ./run -a do_spl_review_line_check`, `rc=0`):
```text
SYNTAX OK the line's format and reviewer check on PC; the run is not (the log is on sat): on sat: REVIEW_LINE="$(git log -1 --format=%B 8e80a7926 | grep '^review:')" ./run -a do_spl_review_line_check
```

### Row 03 (`91cfe055b`) — **verified OK** (`rc=0` on `PC`)
Command: `cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B 91cfe055b | grep '^review:')" ./run -a do_spl_review_line_check`:
```text
OK 4 of 4 named in ran: are commands in /home/<user>/.grok/sessions/%2Fopt%2Fcsi%2Fcsi-spl-wt%2Fg-218/01a1d727-a55d-7a22-9ffc-35518337f89a/updates.jsonl (148 commands read): run-lazy-loader.tst.sh, run-log-nofork.tst.sh, run-eager-files.tst.sh, g218-run-index-blind-key.tst.sh
```

### Row 04 (`f0d0efa4e`) — **not verified** (log on `sat`, seat `g-681@sat` closed; syntax OK on `PC`)
Command: `cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B f0d0efa4e | grep '^review:')" ./run -a do_spl_review_line_check` (`rc=2`):
```text
REFUSED the log is on box 'sat', this is 'PC': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE="$(git log -1 --format=%B f0d0efa4e | grep '^review:')" ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1` (`cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B f0d0efa4e | grep '^review:')" REVIEW_LINE_SYNTAX=1 ./run -a do_spl_review_line_check`, `rc=0`):
```text
SYNTAX OK the line's format and reviewer check on PC; the run is not (the log is on sat): on sat: REVIEW_LINE="$(git log -1 --format=%B f0d0efa4e | grep '^review:')" ./run -a do_spl_review_line_check
```

### Row 05 (`27fd9e0c1`) — **not verified** (log on `sat`, seat `g-680@sat` closed; syntax OK on `PC`)
Command: `cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B 27fd9e0c1 | grep '^review:')" ./run -a do_spl_review_line_check` (`rc=2`):
```text
REFUSED the log is on box 'sat', this is 'PC': run it on sat (never fetched), or REVIEW_LINE_SYNTAX=1 for the syntax here
on sat: REVIEW_LINE="$(git log -1 --format=%B 27fd9e0c1 | grep '^review:')" ./run -a do_spl_review_line_check
```
With `REVIEW_LINE_SYNTAX=1` (`cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B 27fd9e0c1 | grep '^review:')" REVIEW_LINE_SYNTAX=1 ./run -a do_spl_review_line_check`, `rc=0`):
```text
SYNTAX OK the line's format and reviewer check on PC; the run is not (the log is on sat): on sat: REVIEW_LINE="$(git log -1 --format=%B 27fd9e0c1 | grep '^review:')" ./run -a do_spl_review_line_check
```

### Summary of C7, C4, and R7.5 checks
- **C7 (`git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l`)**:
  - `68eff35cd` vs `8522d36bf` (`p7-01`): **`0`** lines.
  - `8e80a7926` vs `ad27772a8` (`p7-02`): **`0`** lines.
  - `91cfe055b` vs `c4a87f560` (`p7-03`): **`13`** lines in `csi-spl-doc/specs/027-spool-performance/os-tweaks-analysis.md` (`:253`), caused solely by upstream `27fd9e0c1` (`p7-05`, row 5 of the same spec table) landing on `master` before `91cfe055b` rebased. `git range-diff c4a87f560~1..c4a87f560 91cfe055b~1..91cfe055b` shows **0 patch-hunk changes** (only the `review:` trailer was added).
  - `f0d0efa4e` vs `ac576db74` (`p7-04`): **`0`** lines.
  - `27fd9e0c1` vs `991d1088a` (`p7-05`): **`0`** lines.
- **C4 (plan test-column coverage)**: Every test in each row's plan test column is named in `ran:` with passing output in `read:`; **`0`** `NOT RUN` entries across all 5 rows.
- **R7.5 (review count and cross-vendor check)**:
  - Anchored row query `git log origin/master --grep='(p7-' --format=%B | /usr/bin/grep -c '^review: '` -> **`5`** (`5/5` rows; unanchored `--grep='p7-'` returns `6` because `8c39ee3ef` `p8-01` cites `p7-04` in its body).
  - Per-row vendor check (`cut -d' ' -f3`): all 5 reviewers are `grok` against `claude` authors -> **0 same-vendor reviews**.

---

## 3. CI verdict per row (R11) and dependent-batch SLA (R16)

First completed workflow 10 (`10_ci-quality.yml`) run on `master` whose `headSha` contains the row commit (`gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 200`, checked with `git merge-base --is-ancestor <row> <head>`):

| row | commit | first completed wf10 run (`head`) | conclusion | R11.2 verdict |
|---|---|---|---|---|
| `p7-04` | `f0d0efa4e` | `43466600741` (`f0d0efa4e`, `16:49:33Z`) | `success` | **pass** |
| `p7-05` | `27fd9e0c1` | `43471574329` (`27fd9e0c1`, `17:19:00Z`) | `success` | **pass** |
| `p7-01` | `68eff35cd` -> `2ba18c068` | `43475243258` (`68eff35cd`, `17:41:16Z`) `failure` (`TestFanoutChannelEncodesOnce` `149 > 146` cap; wf20 `43475243464` also `failure`); fixed by `2ba18c068` -> `43480668472` (`2ba18c068`, `18:14:23Z`) | `success` (after `2ba18c068`) | **pass** (2nd push) |
| `p7-03` | `91cfe055b` | `43543112235` (`91cfe055b`, `01:52:15Z`) | `success` | **pass** |
| `p7-02` | `8e80a7926` | `43575238050` (`8e80a7926`, `08:19:01Z`) `cancelled`; first non-cancelled `43576680359` (`1638ca3a7`, `08:37:10Z`) | `success` | **pass** |

- **R16 (Batch 2 placement SLA, <= 30 min after prerequisite lands)**: Prerequisite `r58-07` (`0184b4d70`) landed on `master` at `2026-11-14T06:34:59Z`. Batch 2 row `p7-02` (`8e80a7926`) was authored on `0184b4d70` at `2026-11-14T06:57:55Z` (**`+22m 56s`**, inside the 30-minute SLA) and landed at `08:18:20Z`.

---

## 4. Timeline: from plan to last landing

- **Plan landed (`e7d5d3b2e`):** `2026-11-13T12:00:58Z` (Qto import `e0572925f` at `15:04:36Z`).
- **First row landed (`p7-04`, `f0d0efa4e`):** `2026-11-13T16:47:44Z` (`+4h 46m 46s` after plan).
- **Batch 1 completions:**
  - `17:11:11Z`: `p7-05` (`27fd9e0c1`).
  - `17:40:02Z`: `p7-01` (`68eff35cd`), followed by test-bound fix `2ba18c068` at `18:09:15Z`.
  - `2026-11-14T01:44:49Z`: `p7-03` (`91cfe055b`, delayed waiting for replacement reviewer `g-218@PC`).
- **Batch 2 prerequisite (`r58-07`, `0184b4d70`):** `2026-11-14T06:34:59Z`.
- **Last row landed (`p7-02`, `8e80a7926`):** `2026-11-14T08:18:20Z`.
- **Total elapsed time (plan `e7d5d3b2e` to last row `8e80a7926`):** **20 hours, 17 minutes, 22 seconds**.

---

## 5. Remote branch pruning (R8 step 2)

Dry run (`cd csi-spl-orc && sudo -u <user> env ROUND=p7 ./run -a do_git_prune_round_branches`):
```text
round p7: no review/p7-*, wip/*p7* or [review/]<id>-p7-* branch on origin
```
Live run (`cd csi-spl-orc && sudo -u <user> env ROUND=p7 DRY_RUN=0 ./run -a do_git_prune_round_branches`):
```text
round p7: no review/p7-*, wip/*p7* or [review/]<id>-p7-* branch on origin
```
- All row review branches (`review/p7-01`..`review/p7-05`) had already been removed from `origin` before this retro ran.
- `git ls-remote --heads origin '*perf-round-7*'` still lists the two panel seat branches (`41d428c02 refs/heads/review/c002-perf-round-7-grok-seat` and `c147ab4c8 refs/heads/review/c002-perf-round-7-mistral-seat`), which `do_git_prune_round_branches` does not match by naming convention.

---

## 6. What went wrong in running the round

1. **`p7-01` (`68eff35cd`) flaked in CI on its `+10%` allocation cap and `2ba18c068` had no follow-up R7:**
   - Plan row `01` specified `testing.AllocsPerRun` asserting `<= encode-once + 10%`. Locally at low contention `127 * 1.10 = 140` passed, but in CI (`43475243464` wf20 and `43475243258` wf10) background reader goroutines allocated concurrently during the 10-socket write loop (`149 > 146`), failing `TestFanoutChannelEncodesOnce` and skipping hub deploy.
   - `2ba18c068` (`fix(api, SPL-5445)`) widened the cap to `oneEncoding * 4.5` (`127 + 54 = 181`, still well below per-socket `252`), restoring green CI and deploy 29 minutes later. Under R11.3 a trunk-red fix lands immediately under `fix(...)`, and *"its R7 review (2.7.4) follows on the landed sha"*; no post-landing R7 review was recorded for `2ba18c068`.
2. **`p7-03` (`c-035`) lost its first R7 reviewer (`g-088`) and hit a plan cache-key bug caught by R9:**
   - `c-035` authored `91cfe055b` at `14:27:35Z` on 2026-11-13, but its initial reviewer `g-088` disappeared without a verdict; replacement reviewer `g-218@PC` landed `91cfe055b` at `01:44:49Z` (`> 11h` author-to-commit wall).
   - Running `PRE_PUSH_TIER=full` (R9) caught a subtle flaw in the plan's cache-key design before push: hashing `cat "${BASH_SOURCE[0]}"` failed when `gcp-sm-secrets-dead.tst.sh` sourced `run.sh` via process substitution `source <(sed ...)`, where `${BASH_SOURCE[0]}` is `/dev/fd/63`. Hashing `$_RUN_INDEX_AWK` instead fixed it cleanly.
3. **Qto import lane (`c-050`, `SPL-5449`) lacked a `system` workspace desk seat:**
   - After `e7d5d3b2e` landed, `c-050` was spawned to run `do_spl_doctree_import_md` into workspace `system`, hit `403` because no desk seat was provisioned for `system`, and blocked until `c-002@sat` imported via `t1` (`e0572925f`).
4. **Incomplete round-topic tracking (`f6cc015c`) and missing per-row topic links (rulebook 4.3):**
   - `f6cc015c` received result posts for `p7-04`, `p7-05`, and `p7-01`, and its status card froze at `2026-11-14T07:12Z` showing only 3 of 5 rows; neither `p7-03` (`91cfe055b`) nor `p7-02` (`8e80a7926`) was posted there, and per-row discussions were not linked from the round topic (rulebook 4.3 notes F2 is still manual).
5. **Retrospective delayed past `p8` and `p9` planning, closing `sat` reviewer logs to R8 verification:**
   - Rulebook R8 and 4.3 expect `perf-round-7-retro.md` to feed `perf-round-8-plan.md` while reviewer seats are still open. Because the retro ran 17 hours after `8e80a7926` (on `PC` while 4 of 5 reviewers ran on `sat` and retired), 4 of 5 review lines had to be recorded as **not verified**.

---

## 7. What the round found but did not fix

Candidates surfaced or carried in [perf-round-7-plan.md](perf-round-7-plan.md) section 6 and during row execution:
- **Picked up immediately by [perf-round-8-plan.md](perf-round-8-plan.md):**
  1. `spl_box_ws_cnf` single-key `yq` reads without `yq eval-all` merge -> landed as **`p8-02`** (`1e1cf16f8`).
  2. Next 5 costliest eager files in `csi-spl-orc` `./run` (`93 -> 88`) -> landed as **`p8-01`** (`8c39ee3ef`).
  3. `lane-map.sh` worktree git-status scan (`spl_lane_repo_tops` + 8-way `spl_lane_wt_changes`) -> landed as **`p8-04`** (`75a38b791`, plus tee-wait fix `82bb33d70`).
- **Carried forward unfixed past `p7`:**
  1. **Test Postgres `fsync=off` (`spec 027` row 6, `hub-pg.tst.sh` / `hub-live-stack.sh`):** editor A/B run was cut off by hourly rotation (`243 s` into store group d); needs a dedicated measurement lane rather than an editor session.
  2. **Lab-Postgres / built-bundle items carried from `p5` and `p6`:** `ListReleaseNotes` count subquery (`p5` input 1), `topic_head_apply_marks` rebuild on `r` marks (`p5` input 3), and WUI `p6-08` (issues windowed rows) / `p6-09` (`TenantDropBox` lazy list).
  3. **`_spool_bin_stale` `git log -1` check (`13 ms` median, `n=5`):** measured no worthwhile gain and dropped.
  4. **VM/OS changes (`spec 027` rows 2–4 kernel cmdline/CPU family, row 7 `sudo !use_pty`):** excluded (owner-go throwaway VM A/B or terminal-injection guard).

For the live measured input list on today's `origin/master` (`5815e76c5`), see section 8 of [perf-round-8-retro.md](perf-round-8-retro.md).

---

## 8. Commands run to verify this retro

```bash
git log origin/master -E --grep='\(p7-0[0-9]' --format='%h %cI %s'
git log origin/master --grep='(p7-' --format=%B | /usr/bin/grep -c '^review: '
cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B <sha> | grep '^review:')" ./run -a do_spl_review_line_check
cd csi-spl-orc && REVIEW_LINE="$(git log -1 --format=%B <sha> | grep '^review:')" REVIEW_LINE_SYNTAX=1 ./run -a do_spl_review_line_check
git diff <reviewed> <landed> -- $(git show --name-only --format= <landed>) | wc -l
git range-diff c4a87f560~1..c4a87f560 91cfe055b~1..91cfe055b
cd csi-spl-orc && SHA=68eff35cdf98cee78c444b893f62e455534e6017 ENV=prd ./run -a do_check_deploy_lag
cd csi-spl-orc && SHA=2ba18c0683552c529acd9ec899cf2d4a0bd9af83 ENV=prd ./run -a do_check_deploy_lag
gh run list --workflow 10_ci-quality.yml --branch master --status completed -L 200 --json databaseId,headSha,conclusion,createdAt
cd csi-spl-orc && sudo -u <user> env ROUND=p7 ./run -a do_git_prune_round_branches
cd csi-spl-orc && sudo -u <user> env ROUND=p7 DRY_RUN=0 ./run -a do_git_prune_round_branches
```
