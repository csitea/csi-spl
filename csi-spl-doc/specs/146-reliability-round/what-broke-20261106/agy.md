# What Broke Today (2026-11-06) — Consensus Panel Seat `agy` (Code & Process Lens)

On `2026-11-06` UTC, `origin/master` commit throughput dropped **4.5x (-77.6%)** from `161` commits on `2026-11-05` to `36` commits (`0` commits during `09:30:08Z–17:54:55Z` [8h 25m] and `20:53:29Z–23:37:34Z` [2h 44m]), while daytime queue `p90` wait rose **3.4x** from `202–795 min` (`10-31..11-02`) to `1,225–2,672 min` (`11-03..11-06`).
1. **Primary outage trigger (`2026-11-06 09:20Z–16:12Z`, 6h 52m)**: `SPL-4608` (`7e0fb9192`, `11-02`) persisted weekly quota readings in `quota-weekly.tsv` until the weekly reset, and `SPL-4702` (`d5dd1206c`, `11-03`) only lifted kept rows when `kp == 100`, leaving any `90–99%` reading (`97%` on `11-06`) permanently latched above `BOX_QUOTA_WEEKLY_MAX_PCT=90` after `SPL-4826` (`e696477ab`, `11-05`) had shifted more fleet share onto Claude.
2. **Secondary placement & queue bottlenecks (`10-31..11-07`)**: `SPL-3470` (`833a49022`) holds any ask whose brief file resides on the other box (`16,676` of `46,426` lines in `spawn-place/cron.out`), `SPL-4499` (`9e278c273`, `10-31`) tightened daytime `bug`/`refactor` band ceilings to `20%`, and `SPL-3762` (`4c995cc2d`) + `SPL-3349` (`dc809702a`) auto-stamped every `-reviewer` seat into an unpruned `bypass.tsv` (`1,296` cumulative rows) that places review seats ahead of all bands and scans `O(|log| × |asks|)` in `jq`.
3. **Gate stacking & load amplification on `<box-2>` (`11-04..11-07`)**: `SPL-4820` (`76ce2e9b7`, `11-05`) deferred lane rotation from `55 min` up to `7,200 s` (`2 h`) whenever `do_check_pre_push|git push` is running, while `SPL-4372` (`e2fa11144`) and `SPL-4789` (`ff214f089`, `11-04`) added uncached per-push checks (`owner-orders`, `commit-links`) on top of load-scaled timeouts (`SPL-4040`), baseline failure re-runs, and up to `4` rebase-and-retest loops (`spl-push-master.func.sh`).

---

## 1. Timeline (`2026-10-28` to `2026-11-07` UTC)

| UTC Timestamp | Commit / Source | Event & Measured Effect |
| :--- | :--- | :--- |
| `2026-10-28` – `2026-10-31` | `git log origin/master` (`04a51b255`) | Baseline daily landings on `master`: `161` (`10-28`), `98` (`10-29`), `210` (`10-30`), `103` (`10-31`). |
| `2026-10-30 19:34Z` | `e2fa11144` / `246c732c7` (`SPL-4372`) | Added `owner-orders` (`do_spl_owner_order`) to both `hooks/pre-push` and `do_check_pre_push` (`_PP_ALWAYS_PARTS`, uncached). |
| `2026-10-31 14:08Z` | `9e278c273` (`SPL-4499`) | Replaced static class bands with day/night rhythm bands (`refactor 10–20%, bug 15–20%, feature 60–100%` by day; `24h` cap `30%`). Non-urgent daytime `bug`/`refactor` asks above `20%` share wait behind features. |
| `2026-11-02 09:00Z` | `7e0fb9192` (`SPL-4608`) | Added `spl_box_quota_keep` in `csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh`, persisting weekly quota `%` in `$SPOOL_ROOT/dispatch/quota-weekly.tsv` until `resets_at` with monotone `max(cur, prev)` merge. |
| `2026-11-03 00:00Z+` | `spec 153 §3.22.8` (`c6da82e46`) | Queue `p90` wait steps up from `202–795 min` (`10-31..11-02`) to `2,672 min` (`11-03`), `1,722 min` (`11-04`), `1,225 min` (`11-05`), and `1,508 min` (`11-06`). |
| `2026-11-03 12:43Z` | `d5dd1206c` (`SPL-4702`) | Added quota lift check in `spl_box_quota_keep`, **gated strictly on `kp == 100`**. Any kept reading in `90..99%` (`>= BOX_QUOTA_WEEKLY_MAX_PCT=90`) cannot auto-lift when account/limit changes. |
| `2026-11-04 22:36Z` | `ff214f089` / `873a7fa68` (`SPL-4789`) | Added `commit-links` (`do_spl_commit_links_check`) to `_PP_ALWAYS_PARTS` (runs uncached on every push tier, activates GCP SA and POSTs `/v1/operator/commit-links`). |
| `2026-11-05 00:33Z` | `76ce2e9b7` (`SPL-4820`) | `spl-lane-rotate.func.sh` defers rotating any lane running `do_check_pre_push|git push` up to `ROTATE_LANE_GATE_MAX_AGE=7200` (`2 h`) instead of cutting at `55 min`. |
| `2026-11-05 01:27Z` | `e696477ab` (`SPL-4826`) | Shifted `orchestration` 35% share from `grok` to `claude` and shifted `tests`/`simple_coding`/`complex_coding` backup share onto `agy`, increasing fleet reliance on Claude and `agy`. |
| `2026-11-05 19:00Z` | `28ea9cf40` (`SPL-4810`) | Added `lane_console.py` to `file-stream-follow.py` (every `5 s` tick queries watched lanes and runs `tmux capture-pane` + 7 regex redaction passes). |
| `2026-11-05` (full day) | `git log origin/master` (`04a51b255`) | `161` commits land on `origin/master` (tying `10-28`), proving steady-state commit velocity had not collapsed before `11-06`. |
| `2026-11-06 09:20Z` | `fe0455e48` (`SPL-4932`) | Kept weekly quota row `claude 97 1794473999 1793973488` (`97% >= 90%`) blocks new Claude placements across the fleet (`waiting: claude weekly >= 90%`). |
| `2026-11-06 09:30:08Z` | `67d283262` (`origin/master`) | Last commit before the **8h 25m (`10Z–16Z`) zero-commit blackout** on `origin/master`. |
| `2026-11-06 16:12Z` | `fe0455e48` (`SPL-4932`) | Kept row `claude 97 1794473999` removed by hand after **6h 52m**; placements resume, and first post-gap commit (`e8048c9b1`) lands at `17:54:55Z` (~1h 43m later). |
| `2026-11-06 20:53:29Z` | `57fb9fc96` (`origin/master`) | Last commit before a second **2h 44m (`21Z–22Z`) zero-commit gap** while `<box-1>` was unreachable and `<box-2>` held briefs/load. |
| `2026-11-06 23:04Z–23:55Z` | `fe0455e48` (`SPL-4932`) | `<box-1>` reachable again (~`23:04Z`); `10` commits land in `23:37:34Z–23:55:06Z`, including `fe0455e48` (`23:41:24Z`) fixing `spl_box_quota_keep` lift threshold from `kp == 100` to `kp >= max_pct`. |

---

## 2. Evidence

### 2.1 Daily & Hourly Commit Velocity on `origin/master`
* **Daily commit counts (`2026-10-28` to `2026-11-06` UTC)**:
  * **Source command**: `env TZ=UTC nice -n 19 git log origin/master --since="2026-09-20T00:00:00Z" --date=format-local:'%Y-%m-%d' --format='%cd' | sort | uniq -c` (evaluated on tree `04a51b255` at `2026-11-07T01:20Z`, `n = 45` UTC days from `2026-09-23` to `2026-11-06`, total `5,154` commits).
  * **Measured counts (last 10 full UTC days, `n = 1,140` commits)**:
    * `2026-10-28`: `161` | `2026-10-29`: `98` | `2026-10-30`: `210` | `2026-10-31`: `103` | `2026-11-01`: `87`
    * `2026-11-02`: `99` | `2026-11-03`: `72` | `2026-11-04`: `113` | `2026-11-05`: `161` | **`2026-11-06`: `36`**
  * Across all `n = 45` UTC days in the window, `2026-11-06` (`36` commits) is the second-lowest day in 45 days (only `2026-09-24` at `20` was lower; `2026-10-21` had `41`), representing a **4.47x drop (`-77.6%`)** from `2026-11-05` (`161`) and a **3.22x drop (`-69.0%`)** vs the prior 9-day mean (`116.0` commits/day, `n = 9` days `10-28..11-05`).
* **Hourly commit distribution on `2026-11-06` UTC**:
  * **Source command**: `env TZ=UTC nice -n 19 git log origin/master --since="2026-11-04T00:00:00Z" --date=format-local:'%Y-%m-%d %H' --format='%cd' | sort | uniq -c` (tree `04a51b255`, `n = 36` commits on `2026-11-06`).
  * **Measured hourly breakdown on `2026-11-06`**:
    * `03Z`: `1`, `04Z`: `2`, `05Z`: `1`, `07Z`: `5`, `08Z`: `4`, `09Z`: `3` (`16` commits through `09:30:08Z`, commit `67d283262`).
    * **`10Z–16Z` (7 consecutive clock hours, `09:30:08Z` to `17:54:55Z` = 8h 24m 47s)**: **`0` commits**.
    * `17Z`: `5` (resuming with `e8048c9b1` at `17:54:55Z`), `18Z`: `2`, `19Z`: `1`, `20Z`: `2` (ending with `57fb9fc96` at `20:53:29Z`).
    * **`21Z–22Z` (2 consecutive clock hours, `20:53:29Z` to `23:37:34Z` = 2h 44m 05s)**: **`0` commits**.
    * `23Z`: `10` commits (`23:37:34Z` to `23:55:06Z`).

### 2.2 Primary Outage Trigger: Latched `90–99%` Weekly Quota Row (`SPL-4608` + `SPL-4702` + `SPL-4826`)
* **Code mechanism**:
  * **Source command**: `nice -n 19 git log -p -n 4 origin/master -- csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh` (tree `04a51b255`, `n = 4` commits: `7e0fb9192`, `d5dd1206c`, `a9b56ebcc`, `fe0455e48`).
  * In `7e0fb9192` (`2026-11-02 09:00:11Z`, `SPL-4608`), `spl_box_quota_keep` wrote weekly usage to `$SPOOL_ROOT/dispatch/quota-weekly.tsv` and enforced `if (prev[v] + 0 > cur[v] + 0) cur[v] = prev[v]` until `resets_at`.
  * In `d5dd1206c` (`2026-11-03 12:43:39Z`, `SPL-4702`), the auto-lift condition was written as:
    `if ((kp + 0) == 100 && (( v in cur && (cur[v] + 0) < 100 ) || ( !(v in cur) && ( v in ok ) ))) next`
  * Because `BOX_QUOTA_WEEKLY_MAX_PCT` defaults to `90` (`spl-box-quota.func.sh:21`), any reading in `90..99%` blocks all placements for that vendor (`waiting: claude weekly >= 90%`) **and** fails `(kp + 0) == 100`, latching the vendor out of placement until `resets_at` (`7` days) even after switching logins or raising plan limits.
  * On `2026-11-05 01:27:49Z`, `e696477ab` (`SPL-4826`) increased `claude`'s share in `orchestration` by `+35%` (removing `grok`) and moved backup coding/testing share onto `agy`. When `claude` latched at `97%` (`claude 97 1794473999 1793973488`) at `09:20Z` on `2026-11-06` and `agy` hit quota (`hold_quota=234` in `cron.out`), fleet placement stalled for **6h 52m** (`09:20Z–16:12Z`), producing the **8h 25m** commit gap on `origin/master`.
  * Fixed at `2026-11-06 23:41:24Z` in `fe0455e48` (`SPL-4932`) by changing the lift condition from `(kp + 0) == 100` to `(kp + 0) >= (max_pct + 0) && (cur[v] + 0) < (max_pct + 0)`.

### 2.3 Placer Holds, Rhythm Bands, and `bypass.tsv` Accumulation (`cron.out` & `spl-spawn-*`)
* **Placer log classification (`/var/csi/csi-spl/spawn-place/cron.out`)**:
  * **Source command**:
    ```bash
    nice -n 19 awk '
      /the orch role is held on/ { orch_elsewhere++; next }
      /is not under \/var\/spool-hub\/dispatch\/briefs/ { hold_brief_remote++; next }
      /last placement started under/ { hold_10min++; next }
      /is out of quota|weekly >=|fleet load target says hold|past its overflow mark/ { hold_quota++; next }
      /band pick:/ { band_pick++; next }
      /placed / { placed++; next }
      { other++ }
      END { printf "total=%d orch_elsewhere=%d hold_brief_remote=%d hold_10min=%d hold_quota=%d band_pick=%d placed=%d other=%d\n", NR, orch_elsewhere, hold_brief_remote, hold_10min, hold_quota, band_pick, placed, other }
    ' /var/csi/csi-spl/spawn-place/cron.out
    ```
  * **Measured counts (`n = 46,426` log lines in `/var/csi/csi-spl/spawn-place/cron.out` on `<box-2>`, read at `2026-11-07T01:22Z`)**:
    * `orch_elsewhere = 25,345` (`54.6%`): `<box-2>` skipping placement while `<box-1>` held the `orch` lease.
    * `hold_brief_remote = 16,676` (`35.9%`): `hold: ask <id>: its brief <slug>.md is not under /var/spool-hub/dispatch/briefs on <box-2>: it was queued on <box-1> ... it stays queued` (`SPL-3470`, `833a49022`). Whenever the `orch` lease is on `<box-2>` (or `<box-1>` is unreachable, as occurred before `23:04Z` on `11-06`), asks queued on `<box-1>` cannot be placed by `<box-2>` until their brief files are synced.
    * `hold_10min = 329` (`0.7%`): spacing floor holds (`10 min` normal / `3 min` urgent floor, `SPL-4120`).
    * `hold_quota = 234` (`0.5%`): `agy is out of quota`, `box <box-2> at 425%..473% is past its overflow mark`, or `fleet load target says hold`.
    * `band_pick = 119`, `placed = 104`.
* **Why `p90` queue wait jumped 3.4x on `2026-11-03+` while median stayed low**:
  * **Source**: `csi-spl-doc/specs/153-monitoring-lanes-tab/spec.md` lines `536–556` (committed in `c6da82e46`, `2026-11-06 03:49:16Z`, `n = 1,401` placed asks across `14` days `2026-10-24..2026-11-06` from `fleet_asks`).
  * `p50` wait was `54 min` on `11-05` (`n = 148`) and `119 min` on `11-06` (`n = 28`), whereas `p90` jumped from `202–795 min` (`10-31..11-02`) to `2,672 min` (`11-03`, `n = 75`), `1,722 min` (`11-04`, `n = 115`), `1,225 min` (`11-05`, `n = 148`), and `1,508 min` (`11-06`, `n = 28`).
  * **Code cause**: `9e278c273` (`2026-10-31 14:08:52Z`, `SPL-4499`, `csi-spl-orc/src/bash/run/spl-spawn-share.func.sh`) lowered daytime (`07:00–20:00 CET`) band ceilings for `refactor` (`10–20%`) and `bug` (`15–20%`) while setting `feature` to `60–100%` (with a `30%` 24h cap). Once `bug` or `refactor` reaches `20%` of the 24h rolling window (`bug 21%` / `refactor 30%`), `spl_spawn_place_band` (`spl-spawn-place.func.sh:406–435`) prioritizes `UNDER`/`WITHIN` feature asks and holds `OVER`-band `bug`/`refactor` asks until the night phase (`20:00–07:00 CET`), creating a multi-hour bimodal tail (`1,200–2,600 min` `p90`) alongside cross-box brief holds (`SPL-3470`).
* **Why the share line reports `1296 bypass(es)` and review seats crowd windows**:
  * **Source command**: `nl -ba csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh | sed -n '90,130p'` and `nl -ba csi-spl-orc/src/bash/run/spl-spawn-share.func.sh | sed -n '145,215p'` (tree `04a51b255`).
  * In `spl-spawn-enqueue.func.sh:94–128` (`SPL-3762`, `4c995cc2d`), every ask with `--agent *-reviewer` and `SPAWN_URGENT=0` is automatically stamped with `SPL_SPAWN_REVIEW_SEAT_GO` (`994f2257-8ad1-4010-88c8-4f0a16230937`) and appended to `$SPOOL_ROOT/dispatch/asks/bypass.tsv`.
  * In `spl-spawn-share.func.sh:155–161, 198–204` (`SPL-3349` / `SPL-4156`), `bypass.tsv` is **never pruned or windowed to 24h** (comment at line 155: *"it outlives the hub's week of closed rows"*), so `(.bypasses | length)` reports the **all-time line count of `bypass.tsv` on that box** (`1,296` on `<box-1>`, `336..400` on `<box-2>`), not 24h bypasses.
  * In addition, `spl_spawn_share_jq` (`spl-spawn-share.func.sh:158`) joins `$log` (`1,296` rows) against `$asks.asks` via a nested linear `jq` scan `[$log[] | .ask as $a | ([$asks.asks[] | select(.ask_id == $a)] | .[0]) as $h ...]`, and `spl-spawn-place.func.sh:352` places every `-reviewer` ask ahead of all band checks (`review_Bypass`). Because review/panel seats stay open waiting for editor consensus instead of exiting immediately, 5 of 15 agent windows on `<box-2>` at `00:40Z` were idle finished review seats consuming window slots against the 40-window cap.

### 2.4 Pre-Push Gate Additions, Re-Runs, and Lane Rotation Deferral (`<box-2>` Overload)
* **Code changes between `2026-10-30` and `2026-11-05` that increased per-push work and concurrent gate count**:
  * **Source command**: `nice -n 19 git log --oneline origin/master --since="2026-10-28T00:00:00Z" -- csi-spl-iac/lib/bash/funcs/check-pre-push.func.sh csi-spl-orc/src/bash/run/spl-push-master.func.sh csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh` (tree `04a51b255`, `n = 19` commits).
  1. **Lane rotation gate deferral (`76ce2e9b7`, `2026-11-05 00:33:16Z`, `SPL-4820`, `spl-lane-rotate.func.sh:36–77`)**: Previously, `do_spl_lane_rotate` rotated lanes at `MAX_AGE = 55 min`. Commit `76ce2e9b7` added `_spl_lane_in_pre_push_gate`, deferring rotation up to `ROTATE_LANE_GATE_MAX_AGE = 7200` (`2 h`) whenever any descendant matches `do_check_pre_push|git push`. When a box slows down, `full`-tier gates (`api` cap `2,700 s`, `orc` cap `6,000 s`) now survive up to `2 hours` concurrently instead of being cut at `55 min`, allowing `7` lanes (`32 pre-push processes`, `23 postgres backends`) to stack simultaneously on `<box-2>`.
  2. **Two new uncached `_PP_ALWAYS_PARTS` checks on every push (`check-pre-push.func.sh:783–809, 1210–1211`)**:
     * `owner-orders` (`e2fa11144` / `246c732c7`, `2026-10-30`, `SPL-4372`): runs `do_spl_owner_order` both in `hooks/pre-push` and again inside `do_check_pre_push` (`_pp_part_cacheable` returns `1` = uncached).
     * `commit-links` (`ff214f089` / `873a7fa68`, `2026-11-04 22:36Z`, `SPL-4789`): runs `./run -a do_spl_commit_links_check` on every tier (`doc`, `single`, `full`), uncached, activating a GCP service account and calling the hub API.
  3. **Baseline failure double-run (`check-pre-push.func.sh:999–1025`) & trunk-move rebase loop (`spl-push-master.func.sh:385–435`)**:
     * When any gate part fails or times out (`rc = 124` or `137`) under high CPU load, `_pp_run` checks out `origin/master` in `_PP_BASE_WT` and **runs the entire failing test suite a second time** to test whether the failure is pre-existing on `master`.
     * When `origin/master` advances while a lane's gate is running, `git push` fails with `non-fast-forward`, and `_spl_push_master_worker` (`spl-push-master.func.sh:385–435`) fetches, rebases onto the new `origin/master`, and re-invokes `git push` up to `PUSH_RETRIES = 4` times. If the newly fetched `origin/master` commits touched any path in `_pp_paths "$part"`, the content-addressed part cache (`_pp_part_input_hash`) misses and re-runs the test suite from scratch.

---

## 3. What Was Ruled Out

1. **GitHub Actions CI (`10_ci-quality.yml`, `20_hub-build-deploy.yml`, `30_wui-build-deploy.yml`) did NOT slow down on `2026-11-06`**:
   * **Source command**: `nice -n 19 gh run list --repo csitea/csi-spl --workflow <wf> --limit 1000 --json databaseId,createdAt,updatedAt,status,conclusion,event,headBranch` (queried at `2026-11-07T01:21Z`, filtering completed `master` runs by UTC date of `createdAt`).
   * **`10_ci-quality.yml` (`master` completed runs)**:
     * `2026-11-04` (`n = 73`, `ok = 66`, `fail = 7`): `p50 = 20.9 min`, `p90 = 33.2 min`, `max = 57.8 min`.
     * `2026-11-05` (`n = 81`, `ok = 63`, `fail = 18`): `p50 = 21.1 min`, `p90 = 31.8 min`, `max = 38.1 min`.
     * `2026-11-06` (`n = 44`, `ok = 43`, `fail = 1`): `p50 = 20.9 min`, `p90 = 23.0 min`, `max = 32.8 min` (**`p90` was 8.8 min faster and failure rate was 2.3% vs 22.2% on `11-05`**).
   * **`20_hub-build-deploy.yml` (`master` completed runs)**:
     * `2026-11-04` (`n = 14`): `p50 = 34.7 min`, `p90 = 38.6 min` | `2026-11-05` (`n = 16`): `p50 = 37.0 min`, `p90 = 39.1 min` | `2026-11-06` (`n = 5`): `p50 = 37.2 min`, `p90 = 40.2 min` (flat within `1.1 min`).
   * **`30_wui-build-deploy.yml` (`master` completed runs)**:
     * `2026-11-04` (`n = 25`): `p50 = 10.6 min`, `p90 = 22.6 min` | `2026-11-05` (`n = 24`): `p50 = 10.4 min`, `p90 = 12.6 min` | `2026-11-06` (`n = 4`): `p50 = 10.8 min`, `p90 = 21.0 min` (median flat within `0.4 min`).
2. **A gradual multi-day commit throughput decay before `2026-11-06` is ruled out**:
   * `origin/master` landed `161` commits on `2026-11-05` (matching `2026-10-28` at `161` and exceeding `11-01..11-04`). The commit collapse on `2026-11-06` (`36` commits) was an acute step-drop driven by the two multi-hour zero-commit windows (`09:30Z–17:54Z` and `20:53Z–23:37Z`).

---

## 4. What Could Not Be Read (Source Limits)

Per the panel's **Data rule and seat `agy` source restriction**, this analysis was strictly limited to:
1. Git history of this repository (`origin/master` at `04a51b255`),
2. `gh run list` and `gh run view` for `csitea/csi-spl`, and
3. `/var/csi/csi-spl/spawn-place/cron.out` on `<box-2>`.

Consequently, the following sources **could not be read directly** by this seat and any raw distributions inside them are not independently verified here beyond what is already committed in repo specs/commits:
* **Hub PostgreSQL tables** (`fleet_asks`, `lanes`, `events`, `box_stats`, `usage_snapshots`): live SQL queries (`do_spl_db_query`) were disallowed for this seat (daily wait percentiles cited in §2.3 come solely from the table committed in `csi-spl-doc/specs/153-monitoring-lanes-tab/spec.md` §3.22.8, `c6da82e46`).
* **Local pre-push timing logs (`/var/csi/csi-spl/logs/pre-push.log`) and push worker logs**: could not be read directly to compute per-part (`api`, `orc`, `wui`, `commit-links`, `owner-orders`) duration percentiles by day.
* **Host kernel/system telemetry (`/var/log/sysstat/sa*`, `vmstat`, `iostat`, `/var/log/messages`) and `<box-1>` local files**: could not be read to establish whether `<box-1>`'s unreachability before `23:04Z` on `2026-11-06` was caused by network/tailscale drop, OOM, or CPU saturation.
* **Spool messages and agent transcripts**: disallowed by panel rules.

---

## 5. How Not To Repeat It

1. **Bound and auto-expire weekly quota cache rows (`spl-box-quota.func.sh`)**:
   * Keep the `SPL-4932` (`fe0455e48`) fix (`kp >= max_pct` lifts as soon as live reading `< max_pct`), and add a staleness TTL (e.g. `30 min`) on `quota-weekly.tsv` rows when the active account fingerprint (`cred-id`) changes so a stale `90–99%` row can never block placement for 7 hours.
2. **Replicate or fetch brief files across boxes on enqueue (`spl-spawn-enqueue.func.sh` / `spl-spawn-place.func.sh`)**:
   * Eliminate the `16,676` `hold: ask ... brief is not under /var/spool-hub/dispatch/briefs` holds (`SPL-3470`) by storing brief text in the hub ask payload (or pulling missing briefs from the peer box / hub API during `do_spl_spawn_place`), decoupling ask placement from which box wrote the brief file.
3. **Prune `bypass.tsv` to a rolling 24h window and cap concurrent review seats (`spl-spawn-share.func.sh` / `spl-spawn-place.func.sh`)**:
   * Filter `bypass.tsv` by `ts >= now - 86400` before counting `.bypasses | length` and replace the `O(|log| × |asks|)` nested `jq` scan with an object lookup `INDEX($asks.asks[]; .ask_id)`. Cap concurrent live `-reviewer` windows (or auto-hibernate review seats after pushing their review branch until the editor pings them) so idle review seats cannot hold 33% of active windows.
4. **Cap concurrent `do_check_pre_push` executions per box and skip baseline re-runs on timeout (`check-pre-push.func.sh` / `spl-lane-rotate.func.sh`)**:
   * Acquire a per-box semaphore (e.g. max `2` concurrent `full`-tier `do_check_pre_push` runs per 16-core box) before spawning heavy test suites (`api`/`orc`/`wui`), and do **not** run the `_PP_BASE_WT` baseline re-check when a part fails with `rc = 124` or `137` (timeout under load), which currently doubles CPU/DB load during congestion.
5. **Deduplicate `owner-orders` and cache `commit-links` by `(HEAD_SHA, range)` (`check-pre-push.func.sh`)**:
   * Remove the duplicate `do_spl_owner_order` invocation between `hooks/pre-push` and `do_check_pre_push`, and mark `commit-links` / `owner-orders` cacheable per `(HEAD_SHA)` so rebase retries do not re-run GCP SA activation and hub HTTP round-trips on unchanged commits.
