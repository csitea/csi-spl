# Bug-fix round 49 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6554 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `4dcc34cd-6999-4224-8a3f-8601150bf10c` ("Bug round 49", opened by c-002@sat 03:11Z 2026-11-26, post `942a7390`). Round 48 ([bug-round-48-plan.md](bug-round-48-plan.md)) served all three rows b48-01 (`61a325ebc`, SPL-6548), b48-02 (`917d60ce4`, SPL-6549), and b48-03 (`bc92189cf`, SPL-6550), and is closed (`0d5e0b252`, written by a-846@sat).  
Round focus: the sources of rounds 40 to 48 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since b48 plan and W, owner posts), round 48's first inputs, and the holder's candidate list on sat.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. Two disjoint candidates met the bar (section 3; v0.1's colon-less `pin_hold` row dropped per panel W1 because DB/API/enqueue refuse colon-less placements); bug share is 8% (band 30-40%: UNDER, 03:17Z).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-48-plan.md](bug-round-48-plan.md).

**Status: v1.0 (folded panel W1, W2, N1 to N5 from v0.1 `0dfecbb3e`), awaiting final cross-vendor panel signature by c-896@sat (claude).**

Editor: **a-895@sat** (agy, `specs_and_docs`).  
Panel: **c-896@sat** (claude, cross-vendor; placed on `dispatch-4dcc34cd` / `dispatch-bug-r49`, ask `e2b92184`; mistral sits on no review since 2026-11-25).

**One sha:** every site, line number and red control below is on **`0d5e0b252`** (`origin/master`, 2026-11-26T03:15:24Z, round 48's close record). At v1.0 (03:47Z), `origin/master` is `874d1b2f4` and all 4 row files are unchanged (`git diff --name-only 0d5e0b252 874d1b2f4 -- <the 4 row files>` -> empty), so every site and red control holds at that head. The sources of section 2 were read on sat, 03:16Z..03:25Z on 2026-11-26. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b48-plan')` read once at 03:17Z -> `Window: W=2026-11-26T05:15:24+02:00` (commit `0d5e0b252`, round 48's close record; confirmed by holder `c-002@sat` msg `1ae0c673`). Because `0d5e0b252` is `HEAD` of `origin/master` at open time (0 commits since W), section 2 also audited the full round 48 window since `8483a5d02` (b48 plan v1.0, `01:28:36Z`, 12 commits, 7 with `review:` lines) so no R7 note or incident between `8483a5d02` and `0d5e0b252` was missed.

---

## 1. How to read this

- `<box2>` is the fleet's box that is not sat and `<dev-box>` one unpinned workstation box, as in rounds 21 to 48: the public repo names none of them.
- **Paths** are repo-relative. Line numbers are as of `0d5e0b252`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red controls are printed verbatim in section 4 (kept byte-identical from v0.1 `0dfecbb3e` as `rc02-b49.sh` and `rc03-b49.sh` so the panel's v0.1 runs hold). Each copies files from the named sha with `git archive` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout or live spool. Each site guard checks function names only, so `bash rc0N-b49.sh <fix sha>` (without `fix-shape`) exits 0 on a valid fix.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs).
- This seat runs on sat, so `/var/spool-hub/dispatch/c002-next-round-candidates.md`, `/var/spool-hub/dispatch/automation.log`, and `c-001`/`c-002`/`c-003` + recent R7 outboxes/archives were read directly.

---

## 2. Where rows could come from (measured since `8483a5d02` and W)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=6h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (03:19Z) | 10 entries in 6 h (**0 since W** `03:15:24Z`; 2 since b48 plan `01:28:36Z`: 1 Cloud SQL `ERROR: operator does not exist: uuid ~~ unknown` at `02:56:41Z`, 1 Cloud Run 503 on `/v1/ws` at `01:39:34Z`) | **0 rows.** Ad-hoc SQL error (repeating, noted in section 3.5 per panel N4) and transient 503 (0 alert incidents). |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=6h ./run -a do_gcp_list_alert_incidents` (03:17:30Z) | 9 policies, 0 incidents in 21:17:30Z..03:17:30Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,120), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (03:17:46Z) | 6 issues (plus SPL-6554 this round): 3 `wip` in the release-transfer repo (SPL-6361, 6362, 6366), 3 `onhold` (SPL-5911, 5254, 4994) | **0 rows.** 0 open `csi-spl` `eval`/`todo`/`wip` bug issues outside this round. |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (03:16Z..03:22Z, background) | 100 runs, 2026-11-25T09:04:52Z..2026-11-26T03:16:15Z: 69 success, 23 cancelled, 6 failure, 2 running; every job's p90 under 75% of its timeout (highest: hermetic 1/4 & 3/4, 60%). **0 failed runs since b48 plan (`01:28:36Z`) or W** (all 6 pre-b48: 2 `wui e2e 5/8`, 1 `orc feature`, 3 `release-note`) | **0 rows**: section 3.4. Trunk is green (`last green 45744475349` on `fc50062f`, `02:45:02Z`; panel also saw `874d1b2f4` `success` at `03:33:39Z`). |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 100 --json databaseId,workflowName,headSha,createdAt,conclusion` (03:17Z), `createdAt >= 2026-11-26T01:28:36Z` | **0 failed runs** across all workflows since b48 plan (`01:28:36Z`) or W (newest failure is pre-b48 `45678338355` at `2026-11-25T18:45:14Z`); `do_check_deploy_lag` dev and prd both `current` (hub `5aa360af`, wui `7e7962df`, `n=0`) | **0 rows.** |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=6h LINES=5000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (03:19Z; cap not reached), plus 16 h targeted `hours/minutes` read | 439 entries in 6 h (**0 since W** `03:15:24Z`; 149 since `01:28:36Z`: 99 `unknown_token`, 3 `unpinned_box`, 2 `github: request refused` 404 on `contents`, 45 WordPress/PHP scanner 404s). Targeted 16 h `hours/minutes` read: 212 entries (183 HTTP 200, 29 HTTP 204), **0 HTTP 400s and 0 `hours: minutes refused` warns** | **0 rows**: section 3.5. |
| **7. R7 notes & automation logs since `8483a5d02`** | `git log 8483a5d02..0d5e0b252 --format=%B`, `c-001`/`c-002`/`c-003` spool archives & recent R7 outboxes (`a-872`, `a-875`, `a-877`, `a-882`, `a-886`, `a-835`, `a-826`, `a-748`, `a-801`, `a-841`, `a-769`, `a-790`), and `/var/spool-hub/dispatch/automation.log` tail | 12 commits (`8483a5d02..0d5e0b252`), 7 `review:` lines (panel N1: 7th is `a-835` on `7e7962df5`, SPL-6542 W1/N1-N3 already folded/answered in that commit): `a-875` N1-N3 (`6f6bae52`) on b48-02 (`spl-customer-box-role-check.func.sh`); `a-886` N1 (typo path in r04-02 brief only); `a-872` / `a-877` / `a-882` 0 blocking; `c-002` `56a64404` & `c-001` `d05ddaad` (`review-go` rc 4 false holds on prose `Apply` in r04-01/r04-02 briefs) | **Row b49-01** (`a-875` N1 & N3, section 3.1). `a-826` N2 on SPL-6517 stays with live lane `c-722@sat` (R3, running full gate on `06467d099` at 03:17:49Z, msg `18a2429c`); `review-go` prose `Apply` / inline `DRY_RUN=0` accounted in section 3.6. |
| **8. Owner and member posts** | `ENV=prd SQL="select tenant_id, from_id, count(*), max(accepted_at) from messages where from_id like 'HUM-%' and accepted_at > '2026-11-26T00:00:00Z' group by 1, 2 order by 1, 2" ./run -a do_spl_db_query` (03:17:55Z) | 0 rows across all workspaces | **0 rows.** |
| **9. Round 48's first inputs** | `bug-round-48-plan.md` section 7 and seat file (`review/c002-bug-round-48-claude-seat` `692ed6e20`), re-measured on `0d5e0b252` | `a-748` N3-N4 (`y9-vendor-lane-rule.sh:62-89` `_y9_qwen` dropped stderr on unexpected failures + uncapped non-atomic backup loop) reproduces cleanly on `0d5e0b252`; `a-801` N1 (`spl-spawn-place.func.sh:1448,1464`) dropped per panel W1 (colon-less non-empty placement refused at DB/API/enqueue layers, section 3.6) | **Row b49-02** (section 3.2). Rest accounted in section 3.6. |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (read directly on sat, 03:16Z) | 142 lines (unchanged since b48); `:141-142` (`review-go` owner-go `DRY_RUN=0` inline backtick / prose `apply` false holds) | **0 rows directly**: naive backtick/prose-`apply` skip still conflicts with `spl-review-go.func.sh:684-685` and `spl-review-go.tst.sh:111-114` case 24 (`a backticked prd step -> rc 4`); needs narrower design (section 3.6). |

---

## 3. The candidates, read

### 3.1 b49-01: `do_spl_customer_box_role_check` (`spl-customer-box-role-check.func.sh:49,145,151-158`) misses YAML list-dash tasks (`- ignore_errors:` / `- failed_when:` / `- when: false`) and breaks dedup / relative paths on a trailing `/` in `CUSTOMER_BOX_ROLE_DIR`

- **What happens.** Two defects in `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh` (both reported by `a-875@sat` R7 on b48-02):
  1. **List-dash bypass (N1, `:145,154-156`):** `spl_cbr_when_false` (`:145`) and `spl_cbr_no_swallow` (`:154-156`) anchor on `^[[:space:]]*(when|ignore_errors|failed_when):`. In Ansible YAML, an unnamed task can start with `- ` directly on the directive (`- ignore_errors: true`, `- failed_when: false`, `- failed_when: dsc_out.rc == 99`, `- when: false`). Every such line passes `do_spl_customer_box_role_check` with `OK` (rc 0), even inside `roles/04_desk_start_checks/tasks/main.yml`.
  2. **Trailing `/` on `CUSTOMER_BOX_ROLE_DIR` (N3, `:49,69,115,138,150-157`, output-only; panel N2):** Line `:49` does not strip trailing slashes from `d`. When called as `CUSTOMER_BOX_ROLE_DIR=/path/to/customer-box/`, `r4="$1/roles/04_desk_start_checks"` becomes `.../customer-box//roles/04_desk_start_checks`, which disagrees with the single-slash path emitted by the first `grep` on `$d`. The check already refuses (`rc 1`), so this half is output-only: `sort -u` fails to deduplicate a role-04 hit (emitting two `REFUSED swallow-error:` lines for one line) and the second line keeps the whole absolute path (as do `:69` and `:115` when `$d` ends in `/`). Normalizing `d` at `:49` fixes all three strips at once.
- **Seen.** `a-875@sat` R7 N1 & N3 (`6f6bae52`, 2026-11-26 02:22Z) on b48-02 (`917d60ce4`), named in this round's brief. Verified on `0d5e0b252` across `spl-customer-box-role-check.func.sh:48-61,143-159`; baseline `bash csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` -> `0 failure(s)`.
- **Red control** (`rc02-b49.sh`, section 4.1, kept byte-identical from v0.1): runs `do_spl_customer_box_role_check` on copies of `src/ansible/customer-box` from `0d5e0b252`: 3 controls (shipped set bare, shipped set with trailing `/`, comment lines `# - ignore_errors: true` / `  # - when: false`) + 5 planted YAML list-dash bypasses (`- ignore_errors: true`, `  - failed_when: false`, `- failed_when: dsc_out.rc == 99`, `- when: false` in role 04, and `- ignore_errors: true` in role 03) + 1 trailing-slash dedup check (`CUSTOMER_BOX_ROLE_DIR="$tmp/s/"` on role-04 `  ignore_errors: true`, expecting `refused_total=1` and `clean_rel=1`). On `0d5e0b252`: all 5 list-dash bypasses pass (`rc=0 hits=0`, want `rc=1 hits=1`) and `trailing_slash` emits `refused_total=2 (want 1)` -> `rc02 exit 1`. **Control**: `fix-shape` strips trailing slashes from `d` at `:49` (`while [[ "$d" != / && "$d" == */ ]]; do d="${d%/}"; done`) and adds `(-[[:space:]]+)?` after `^[[:space:]]*` at `:145,154-156` -> all 3 controls pass (`rc=0`), all 5 list-dash bypasses refused (`rc=1 hits=1`), `trailing_slash` emits `refused_total=1 clean_rel=1` -> `rc02 exit 0`.
- **Fix scope.** `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh`:
  - Strip trailing slashes from `d` at `:49` (keeping `/` unchanged): `while [[ "$d" != / && "$d" == */ ]]; do d="${d%/}"; done`.
  - Allow optional YAML list dash `(-[[:space:]]+)?` after `^[[:space:]]*` in `spl_cbr_when_false` (`:145`) and `spl_cbr_no_swallow` (`:154-156`). Keep comment lines (`# - ...`) and `changed_when: false` (`roles/04_desk_start_checks/tasks/main.yml:19`) green, and keep every function <= 75 lines.
  - `csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh`: add controls after `:143` proving `- ignore_errors: true`, `- failed_when: false`, `- failed_when: dsc_out.rc == 99`, `- when: false` in role 04, `- ignore_errors: true` in role 03, and a trailing `/` on `CUSTOMER_BOX_ROLE_DIR` (exactly 1 `REFUSED swallow-error: roles/04_desk_start_checks/tasks/main.yml:` line), while `# - ignore_errors: true` and `$SET/` stay green. `Docs: none` (hardens existing spec 181 B6 / b48-02 gate checks; header already documents `when-false` and `swallow-error`).

### 3.2 b49-02: `_y9_qwen` (`y9-vendor-lane-rule.sh:62-89`) drops unexpected `y8-vibe-agents.py` stderr on failure and uses a non-atomic uncapped backup loop

- **What happens.** Two defects in `_y9_qwen` (`csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh:62-89`, added by SPL-6533):
  1. **Silent error drop (N3, `:66-71`):** When `_y9_one` (`y8-vibe-agents.py`) exits non-zero, `:68` sets `rc=1`, but `:70` forwards `$msg` to stderr only when `$msg` matches 4 hardcoded substrings (`"edited by hand"`, `FATAL`, `"no such part"`, `"has no value"`). Any other failure — e.g. `UnicodeDecodeError` on a non-UTF-8 `QWEN.md`, `PermissionError`, `is not NN-<slug>.md`, `no free backup name`, or a Python traceback — causes `spool_install_vendor_lane_rule` to fail with `rc=1` and **zero stderr**. (`:67` also reuses outer `rc` inside the command substitution; fixing it to per-part `prc` avoids forwarding passing parts' noise after an earlier part failed, though the step's exit code is already 1; panel N3.)
  2. **Non-atomic uncapped backup loop — parity hardening with `y8-vibe-agents.py:52-68` (N4, `:74-78`; panel N3):** `_y9_qwen` allocates the backup name with `while [ -e "$bak..." ]; do k=$((k + 1)); done` followed by `cp -p "$q" "$bak"` — non-`O_EXCL` and with no upper bound on `k` (when 99 names exist for one UTC second, it writes `-100`, keeps that backup, and replaces `QWEN.md` without losing data). Aligning it with `y8-vibe-agents.py:52-68` (`O_CREAT | O_EXCL`, mode `0600`, `k = 1..99`, refusing with `no free backup name` when full) gives one backup contract across `y8` and `y9`.
- **Seen.** `a-748@sat` R7 N3 & N4 (`4c1990d6` / `8e03ff9b`) on SPL-6533; carried in `bug-round-48-plan.md` section 7 ("`a-748` N3-N4 ... worth a look next"). Verified on `0d5e0b252` across `y9-vendor-lane-rule.sh:62-89` and `y8-vibe-agents.py:52-68`; baseline `bash csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh` -> `18/18 passed`.
- **Red control** (`rc03-b49.sh`, section 4.2, kept byte-identical from v0.1): extracts `csi-spl-orc/src/bash/features/spool-install` from `0d5e0b252` into a `mktemp -d` dir and tests 3 cases under throwaway `HOME`: (A) `QWEN.md` containing invalid UTF-8 (`\xff\xfe`, triggering `UnicodeDecodeError` in `y8-vibe-agents.py`) -> must fail (`rc!=0`), leave `QWEN.md` untouched, and print the cause on stderr; (B) stub `date` returning `20261126T000000Z` with all 99 backup names (`...` and `-2`..`-99`) already present -> must fail (`rc!=0`), emit `no free backup name`, create no `-100`, and leave `QWEN.md` untouched; (C) control: normal upgrade with existing memories -> `rc=0`, 5 fragments, 1 backup. On `0d5e0b252`: A exits 1 with `stderr_has_cause=0 (want 1)`, B exits `0 (want 1)` with `created_100=1 (want 0) msg=0 file_kept=0` -> `rc03 exit 1`. **Control**: `fix-shape` captures per-part rc (`rc=0; _y9_one ...`), forwards `$msg` to stderr whenever `prc != 0` (keeping the 4-substring filter for `prc == 0` notices like `"edited by hand"`), and adds `_y9_qwen_backup` using atomic `set -C` (`O_EXCL`, `umask 077`) capped at `k=1..99` -> A `stderr_has_cause=1`, B `rc=1 created_100=0 msg=1 file_kept=1`, C `rc=0 frags=5 baks=1` -> `rc03 exit 0`.
- **Fix scope.** `csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh:62-89`:
  - Extract `_y9_qwen_backup <q>` (matching `y8-vibe-agents.py:52-68`: atomic `O_EXCL` create via `(umask 077; set -C; cat <"$q" >"$cand") 2>/dev/null` for `k=1..99`, refusing with `no free backup name for <stamp>: nothing replaced` on exhaustion).
  - In `_y9_qwen`: track per-part exit status (`prc`) cleanly, always forward non-empty `$msg` to stderr when `prc != 0` (and keep the `"edited by hand"` warning echo when `prc == 0`), and keep both functions <= 75 lines. (Keep existing `rm -rf "${stage:?}"`.)
  - `csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh`: add cases 7 and 8 after `:98` covering (7) unexpected `y8-vibe-agents.py` error (invalid UTF-8 `QWEN.md` -> `rc!=0`, stderr names the error, `QWEN.md` unchanged, no `.y9-stage.*` left) and (8) all 99 backup names occupied -> `rc!=0`, `no free backup name`, no `-100` created, `QWEN.md` unchanged. Keep cases 1 to 6 (`18/18`) green. `Docs: none` (bug fix to existing `spool-install` step `y9` error reporting and backup contract parity with `y8-vibe-agents.py`).

### 3.4 CI reds in the 100 runs, read

| run range | job | first red line | why not a row |
|---|---|---|---|
| **Since b48 plan (`01:28:36Z`) and W (`03:15:24Z`)**: none | all jobs | 0 failed runs across wf 10 and every other workflow on master | **0 rows**: trunk is green (`last green 45744475349` on `fc50062f`, `02:45:02Z`; `874d1b2f4` `success` at `03:33:39Z`). |
| `45678338355`, `45674842811` (2026-11-25 18:24Z..18:45Z, pre-b48) | wui e2e 5/8 | `FAIL 360 login no-bfcache L3>L2>L1>L1>out Back never re-parsed /login` | **Served**: fixed by SPL-6531 `672162eb9` (green since). |
| `45661882286` (2026-11-25 17:10Z, pre-b48) | orc feature tests | `FAIL - 1. sent, exit 0 (want '0', got '137')` | **Served**: pre-b48, green since. |
| `45596579656`..`45598661206` (2026-11-25 10:36Z..10:49Z, pre-b48) | release-note | `FAIL release-note: 222f6efe (full) missing Lay-What ...` | **Served**: pre-b48, green since. |

### 3.5 The prd WARNING and repeating ERROR lines, read

| candidate | read | why not a row |
|---|---|---|
| `upload token refused` (`unknown_token`), 99 since `01:28:36Z` (0 since W) | same box question carried since round 43 | **Not a row**: carried with holder. |
| `ws hello refused` (`unpinned_box`), 3 since `01:28:36Z` (0 since W) | `<dev-box>` unpinned client retries | **Not a row.** |
| `github: request refused` 404 on `contents` (2), WordPress/PHP scanner 404s (45) since `01:28:36Z` (0 since W) | expected GitHub 404s and internet scanners | **Not a row.** |
| Cloud SQL `ERROR: operator does not exist: uuid ~~ unknown` (`spool_hub_rt`), 3 times in 8 h (`21:51:35Z`, `22:41:10Z`, `02:56:41Z`; panel N4) | `git grep` finds no repo code running `LIKE` (`~~`) on a `uuid` id column | **Not a row**: repeating ad-hoc `do_spl_db_query` SQL (noted here so a future planner can check if a script adds one). |
| `PUT /v1/me/hours/minutes` >=400 / `hours: minutes refused` | 212 entries in 16 h (183 HTTP 200, 29 HTTP 204), 0 HTTP 400s and 0 warn lines | **Carried**: wait for a live `hours: minutes refused` warn before deciding spec 107 / WUI follow-up. |

### 3.6 Round 48's first inputs, recent R7 notes, and the candidate list, re-read

| candidate | result on `0d5e0b252` | verdict |
|---|---|---|
| `a-875` N1 & N3 (`spl-customer-box-role-check.func.sh:49,145,151-158` YAML list-dash bypass + trailing `/` dedup/path bug, brief input) | verified on `0d5e0b252`, reproduced live in `rc02-b49.sh` | **Row b49-01** (section 3.1). (`a-875` N2: YAML 1.1 `on`/`off`, list forms `[]`, templated values already documented as ban-list limits at `:37-43`.) |
| `a-748` N3-N4 (`y9-vendor-lane-rule.sh:62-89` `_y9_qwen` silent stderr drop + non-atomic uncapped backup loop, b48 first input) | verified on `0d5e0b252`, reproduced live in `rc03-b49.sh` | **Row b49-02** (section 3.2). |
| `a-801` N1 (`spl-spawn-place.func.sh:1448,1464` `IFS=$'\t' read` empty-field collapse on colon-less `.placement`, b48 first input; v0.1 row 01) | **Dropped (panel W1):** unreachable in the live placer — `0180_fleet_asks_queue.sql:27-28` CHECK, `AskPlacementRe` (`fleet_ask.go:132`, `ask.go:180`, `box_ask.go:377`), and `spl_spawn_q_enqueue` (`spl-spawn-enqueue.func.sh:220-221`) refuse every non-empty colon-less placement, and `spl_spawn_place_mark` (`:326-336`) marks `_l` only for non-empty placements; the `else ""` branch at `:1464` is dead on live data | **Not a bug row** (optional refactor/cleanup candidate only, dropped from b49). |
| `review-go` owner-go rc 4 false holds on inline backticks (`c002-next-round-candidates.md:141-142`, r03-01/r03-02 `DRY_RUN=0`) and prose `Apply` (`c-002` `56a64404` r04-01, `c-001` `d05ddaad` r04-02: `"Apply 1.3's verbatim helper, caller, and test hunks..."`) | **Design tension unchanged:** `spl-review-go.func.sh:684-685` intentionally scans backticked spans and `spl-review-go.tst.sh:111-114` case 24 explicitly asserts `a backticked prd step -> rc 4`. Similarly, exempting prose `Apply` risks missing `"Apply step 053 to prd"` unless narrowly scoped (e.g. `"Apply <section>'s ... hunk(s)/patch"` or explicit brief-table/prose rules without weakening case 24) | **Carried to round 50** with design note: needs a deliberate narrow rule (or brief phrasing convention) that keeps case 24 and real `apply` holds intact. |
| `a-826` N2 on SPL-6517 (`spool-live-ack.sh` log size cap, brief input) and `a-767` N2 / `a-823` N2 (`spool-agent-hook.sh`) | SPL-6517 is STILL live (`c-722@sat` running full gate on `06467d099` at `03:17:49Z`, msg `18a2429c`; `a-826@sat` live in `do_spl_lane_map` at `03:17Z`) | **Left to `c-722@sat`** (R3; brief: leave unless SPL-6517 lands without it). |
| `a-841` N1 (`setup-gh-runner-cpu-budget-cron.tst.sh:83-91` section 4 red control copies only one `.func.sh` file into `$T/`, so relative `source` at `:35-40,69` fails before reaching `do_setup_gh_runner_cpu_budget_cron`) | verified real on `0d5e0b252` (`setup-gh-runner-cpu-budget-cron.func.sh:35-40,69` does relative `source` from `BASH_SOURCE[0]`); cron tests sit near refactor round 05 (`a-891@sat`, planning) | **Carried** as first input #1 for round 50. |
| `a-769` N1 (`check-pre-push-lint.func.sh` `_ppl_run_timed` returns 124 instead of 137 when `tail` exits on SIGTERM) & `a-769` N2 (`tenant-host-reserve.tst.sh` missing symlink test case); `a-790` N1 (`internal/mcp/mcp_test.go:560-563` control runs on ambient env); `a-886` N1 (r04-02 brief typo only, no repo file) | verified on `0d5e0b252`; lower runtime severity than b49-01..02 | **Carried** to round 50. |
| Round 48 carried inputs: `c-708` N1 (`BoxTaskEnvelopes` box-scoped probe), `a-683` N3 (non-`AgentsCommand` / embed / `channel_box_pins` posts in `hum\|`), `c-625` N1-N3 (Taxes tab, `c-298@sat` still live R3), `a-490` N1 (`TestCategoryTestPathsZZIsolated` regex at `categories_test.go:388`), `a-480` N1 (`syncWriter.Reset`), hours-minutes 400 follow-up (0 warns in 16 h), `i18n-lang-review-exempt.json:2`, `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget`, `unknown_token` box, hub dir mode, hermetic 2/4 timeout, composed testids, SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` | re-checked: unchanged / carried (`c-298@sat` still live R3; `b42-01` N1 `cmd/spool/hub.go:1235-1238` already fixed on master) | **Carried** to round 50. |

---

## 4. Red controls, as run

### 4.1 `rc02-b49.sh` (b49-01, kept byte-identical from v0.1), sha256 first 12 hex `5509c3f13d9b`, 5523 B

Run from any checkout: `bash rc02-b49.sh 0d5e0b252` (exit 1), then `bash rc02-b49.sh 0d5e0b252 fix-shape` (exit 0). Under 2 s each. (Filename and header comment keep the v0.1 `rc02-b49.sh` / `b49-02` label so the script stays byte-identical to the panel's verified v0.1 run.)

```bash
#!/usr/bin/env bash
# rc02-b49.sh <sha> [fix-shape]: b49-02 red control. On <sha>'s tree,
# do_spl_customer_box_role_check (spl-customer-box-role-check.func.sh:49,145,151-158):
#   (1) a-875 N1: unnamed YAML task list items opening with `- ignore_errors:`,
#       `- failed_when:`, or `- when: false` slip past `^[[:space:]]*` even in
#       roles/04_desk_start_checks/tasks/main.yml (rc 0);
#   (2) a-875 N3: a trailing `/` on CUSTOMER_BOX_ROLE_DIR produces `//` in $r4,
#       breaking `sort -u` dedup (two duplicate REFUSED lines for one role 04
#       hit) and failing `${hit#"$d"/}` relative path stripping.
# Extracts csi-spl-iac from <sha> into a mktemp dir. fix-shape strips trailing
# slashes from d at :49 and allows optional YAML list dash `(-[[:space:]]+)?`.
set -uo pipefail
sha="${1:?usage: rc02-b49.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-iac | tar -x -C "$tmp"
fn="$tmp/csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh"
a=$(grep -c '^do_spl_customer_box_role_check()' "$fn")
b=$(grep -c '^spl_cbr_when_false()' "$fn")
c=$(grep -c '^spl_cbr_no_swallow()' "$fn")
echo "rc02 sites: main=$a when_false=$b no_swallow=$c"
[ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] || { echo "rc02 sites moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$fn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old_d = '  local d="${CUSTOMER_BOX_ROLE_DIR:-${PROJ_PATH}/src/ansible/customer-box}" bad=0 pb\n'
new_d = '  local d="${CUSTOMER_BOX_ROLE_DIR:-${PROJ_PATH}/src/ansible/customer-box}" bad=0 pb\n  while [[ "$d" != / && "$d" == */ ]]; do d="${d%/}"; done\n'
old_wf = '  spl_cbr_report when-false "$1" < <(grep -rniE "^[[:space:]]*when:[[:space:]]*$SPL_CBR_FALSY_RX" "$1" 2>/dev/null)'
new_wf = '  spl_cbr_report when-false "$1" < <(grep -rniE "^[[:space:]]*(-[[:space:]]+)?when:[[:space:]]*$SPL_CBR_FALSY_RX" "$1" 2>/dev/null)'
old_ns = '''      grep -rniE -e "^[[:space:]]*ignore_errors:[[:space:]]*$SPL_CBR_TRUTHY_RX" \\
        -e "^[[:space:]]*failed_when:[[:space:]]*$SPL_CBR_FALSY_RX" "$d"
      [[ ! -d "$r4" ]] || grep -rniE '^[[:space:]]*(ignore_errors|failed_when):' "$r4"'''
new_ns = '''      grep -rniE -e "^[[:space:]]*(-[[:space:]]+)?ignore_errors:[[:space:]]*$SPL_CBR_TRUTHY_RX" \\
        -e "^[[:space:]]*(-[[:space:]]+)?failed_when:[[:space:]]*$SPL_CBR_FALSY_RX" "$d"
      [[ ! -d "$r4" ]] || grep -rniE '^[[:space:]]*(-[[:space:]]+)?(ignore_errors|failed_when):' "$r4"'''
for lbl, old in [("d", old_d), ("wf", old_wf), ("ns", old_ns)]:
    assert s.count(old) == 1, f"{lbl} count={s.count(old)}"
s = s.replace(old_d, new_d, 1).replace(old_wf, new_wf, 1).replace(old_ns, new_ns, 1)
open(p, "w").write(s)
PY
  echo "rc02 fix-shape: strip trailing / on d + allow YAML list dash (- ) before when/ignore_errors/failed_when"
fi

SET="$tmp/csi-spl-iac/src/ansible/customer-box"
run_chk() {
  env PROJ_PATH="$tmp/csi-spl-iac" CUSTOMER_BOX_ROLE_DIR="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-customer-box-role-check.func.sh"
    do_spl_customer_box_role_check'
}
copy_set() { rm -rf "$tmp/s"; cp -a "$SET" "$tmp/s"; }

rc=0
# Controls: shipped set (bare and trailing /), comment lines with list dash
out="$(run_chk "$SET" 2>&1)"; r=$?
echo "rc02 ctrl_shipped: rc=$r (want 0)"
[ "$r" = 0 ] || rc=1

out="$(run_chk "$SET/" 2>&1)"; r=$?
echo "rc02 ctrl_shipped_slash: rc=$r (want 0)"
[ "$r" = 0 ] || rc=1

copy_set; printf '# - ignore_errors: true\n  # - when: false\n' >>"$tmp/s/roles/04_desk_start_checks/tasks/main.yml"
out="$(run_chk "$tmp/s" 2>&1)"; r=$?
echo "rc02 ctrl_dash_comments: rc=$r (want 0)"
[ "$r" = 0 ] || rc=1

# RED 1..4: YAML list-dash unnamed tasks in role 04
for pair in \
  "r4_dash_ignore|- ignore_errors: true|swallow-error" \
  "r4_dash_failed_false|  - failed_when: false|swallow-error" \
  "r4_dash_failed_expr|- failed_when: dsc_out.rc == 99|swallow-error" \
  "r4_dash_when_false|- when: false|when-false"; do
  lbl="${pair%%|*}"; rest="${pair#*|}"; line="${rest%%|*}"; chk="${rest#*|}"
  copy_set; printf '%s\n' "$line" >>"$tmp/s/roles/04_desk_start_checks/tasks/main.yml"
  out="$(run_chk "$tmp/s" 2>&1)"; r=$?
  hit=$(grep -c "^REFUSED $chk: roles/04_desk_start_checks/tasks/main.yml:" <<<"$out" || true)
  echo "rc02 $lbl: rc=$r (want 1) hits=$hit (want 1)"
  [ "$r" != 0 ] && [ "$hit" = 1 ] || rc=1
done

# RED 5: YAML list-dash ignore_errors in role 03
copy_set; printf '%s\n' "- ignore_errors: true" >>"$tmp/s/roles/03_workspace/tasks/main.yml"
out="$(run_chk "$tmp/s" 2>&1)"; r=$?
hit=$(grep -c '^REFUSED swallow-error: roles/03_workspace/tasks/main.yml:' <<<"$out" || true)
echo "rc02 r3_dash_ignore: rc=$r (want 1) hits=$hit (want 1)"
[ "$r" != 0 ] && [ "$hit" = 1 ] || rc=1

# RED 6: trailing slash on CUSTOMER_BOX_ROLE_DIR must dedup role 04 to 1 line with clean relative path
copy_set; printf '  ignore_errors: true\n' >>"$tmp/s/roles/04_desk_start_checks/tasks/main.yml"
out="$(run_chk "$tmp/s/" 2>&1)"; r=$?
tot=$(grep -c '^REFUSED swallow-error:' <<<"$out" || true)
rel=$(grep -c '^REFUSED swallow-error: roles/04_desk_start_checks/tasks/main.yml:' <<<"$out" || true)
echo "rc02 trailing_slash: rc=$r (want 1) refused_total=$tot (want 1) clean_rel=$rel (want 1)"
[ "$r" != 0 ] && [ "$tot" = 1 ] && [ "$rel" = 1 ] || rc=1

echo "rc02 exit $rc"
exit "$rc"
```

Output on `0d5e0b252` (sat, 03:25Z; confirmed by panel `c-896@sat` on v0.1 `0dfecbb3e`):

| run | output |
|---|---|
| `bash rc02-b49.sh 0d5e0b252` | `rc02 sites: main=1 when_false=1 no_swallow=1` / `rc02 ctrl_shipped: rc=0 (want 0)` / `rc02 ctrl_shipped_slash: rc=0 (want 0)` / `rc02 ctrl_dash_comments: rc=0 (want 0)` / `rc02 r4_dash_ignore: rc=0 (want 1) hits=0 (want 1)` / `rc02 r4_dash_failed_false: rc=0 (want 1) hits=0 (want 1)` / `rc02 r4_dash_failed_expr: rc=0 (want 1) hits=0 (want 1)` / `rc02 r4_dash_when_false: rc=0 (want 1) hits=0 (want 1)` / `rc02 r3_dash_ignore: rc=0 (want 1) hits=0 (want 1)` / `rc02 trailing_slash: rc=1 (want 1) refused_total=2 (want 1) clean_rel=1 (want 1)` / `rc02 exit 1` |
| `bash rc02-b49.sh 0d5e0b252 fix-shape` | `rc02 sites: main=1 when_false=1 no_swallow=1` / `rc02 fix-shape: strip trailing / on d + allow YAML list dash (- ) before when/ignore_errors/failed_when` / `rc02 ctrl_shipped: rc=0 (want 0)` / `rc02 ctrl_shipped_slash: rc=0 (want 0)` / `rc02 ctrl_dash_comments: rc=0 (want 0)` / `rc02 r4_dash_ignore: rc=1 (want 1) hits=1 (want 1)` / `rc02 r4_dash_failed_false: rc=1 (want 1) hits=1 (want 1)` / `rc02 r4_dash_failed_expr: rc=1 (want 1) hits=1 (want 1)` / `rc02 r4_dash_when_false: rc=1 (want 1) hits=1 (want 1)` / `rc02 r3_dash_ignore: rc=1 (want 1) hits=1 (want 1)` / `rc02 trailing_slash: rc=1 (want 1) refused_total=1 (want 1) clean_rel=1 (want 1)` / `rc02 exit 0` |

### 4.2 `rc03-b49.sh` (b49-02, kept byte-identical from v0.1), sha256 first 12 hex `e474daac0f09`, 7052 B

Run from any checkout: `bash rc03-b49.sh 0d5e0b252` (exit 1), then `bash rc03-b49.sh 0d5e0b252 fix-shape` (exit 0). Under 2 s each. (Filename and header comment keep the v0.1 `rc03-b49.sh` / `b49-03` label so the script stays byte-identical to the panel's verified v0.1 run; its header's `:56-68` cites the loop and refusal inside `backup_stamped` at `y8-vibe-agents.py:52-68`, panel N3.)

```bash
#!/usr/bin/env bash
# rc03-b49.sh <sha> [fix-shape]: b49-03 red control. On <sha>'s tree,
# _y9_qwen (csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh:62-89):
#   (1) a-748 N3: on a non-zero exit from y8-vibe-agents.py whose stderr does
#       not match the 4 hardcoded substrings (e.g. UnicodeDecodeError on invalid
#       UTF-8 in QWEN.md), line :70 drops stderr completely -> rc=1 with empty
#       stderr;
#   (2) a-748 N4: backup creation uses a non-atomic `while [ -e ]` + `cp -p`
#       loop with no k cap (unlike y8-vibe-agents.py:56-68 O_EXCL k=1..99), so
#       when all 99 names for a timestamp exist it creates -100 instead of
#       refusing and leaving QWEN.md untouched.
# Extracts csi-spl-orc from <sha> into a mktemp dir. fix-shape forwards stderr
# whenever a part fails (per-part rc) and creates the backup atomically via
# O_EXCL (noclobber) capped at k=1..99.
set -uo pipefail
sha="${1:?usage: rc03-b49.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc/src/bash/features/spool-install | tar -x -C "$tmp"
fn="$tmp/csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh"
a=$(grep -c '^_y9_qwen()' "$fn")
echo "rc03 site: _y9_qwen=$a"
[ "$a" = 1 ] || { echo "rc03 site moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$fn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = '''_y9_qwen() {
  local q="$HOME/.qwen/QWEN.md" stage part bak k=1 rc=0 msg
  stage="$(mktemp -d "$HOME/.qwen/.y9-stage.XXXXXX")" || return 1
  [ -f "$q" ] && cp -p "$q" "$stage/QWEN.md"
  for part in $1; do
    msg="$(_y9_one "$part" "$stage/QWEN.md" 2>&1; echo "rc=$rc")"
    case "${msg##*rc=}" in 0) ;; *) rc=1 ;; esac
    msg="${msg%rc=*}"; msg="${msg//"$stage/QWEN.md"/$q}"
    case "$msg" in *"edited by hand"* | *FATAL* | *"no such part"* | *"has no value"*) printf '%s' "$msg" >&2 ;; esac
  done
  if [ "$rc" = 0 ] && [ -f "$stage/QWEN.md" ] && ! cmp -s "$stage/QWEN.md" "$q"; then
    if [ -f "$q" ]; then
      bak="$q.bak-spool-install-$(date -u +%Y%m%dT%H%M%SZ)"
      while [ -e "$bak$([ "$k" = 1 ] || echo "-$k")" ]; do k=$((k + 1)); done
      bak="$bak$([ "$k" = 1 ] || echo "-$k")"
      cp -p "$q" "$bak" || rc=1
    fi
    if [ "$rc" = 0 ] && mv -f "$stage/QWEN.md" "$q"; then
      echo "spool-install: vibe-agents: $q: the fleet rule parts rendered${bak:+, the old file kept as $bak}" >&2
    else
      rc=1
    fi
  elif [ "$rc" = 0 ]; then
    echo "spool-install: vibe-agents: $q: already current" >&2
  fi
  rm -rf "${stage:?}"
  return "$rc"
}'''
new = '''_y9_qwen_backup() {
  local q="$1" stamp cand k
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for (( k = 1; k < 100; k++ )); do
    cand="$q.bak-spool-install-$stamp$([ "$k" = 1 ] || echo "-$k")"
    if (umask 077; set -C; cat <"$q" >"$cand") 2>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  echo "spool-install: vibe-agents: $q: no free backup name for $stamp: nothing replaced" >&2
  return 1
}

_y9_qwen() {
  local q="$HOME/.qwen/QWEN.md" stage part bak="" rc=0 prc msg
  stage="$(mktemp -d "$HOME/.qwen/.y9-stage.XXXXXX")" || return 1
  [ -f "$q" ] && cp -p "$q" "$stage/QWEN.md"
  for part in $1; do
    msg="$(rc=0; _y9_one "$part" "$stage/QWEN.md" 2>&1; echo "rc=$rc")"
    prc="${msg##*rc=}"
    msg="${msg%rc=*}"; msg="${msg//"$stage/QWEN.md"/$q}"
    if [ "$prc" != 0 ]; then
      rc=1
      [ -n "$msg" ] && printf '%s' "$msg" >&2
    else
      case "$msg" in *"edited by hand"* | *FATAL* | *"no such part"* | *"has no value"*) printf '%s' "$msg" >&2 ;; esac
    fi
  done
  if [ "$rc" = 0 ] && [ -f "$stage/QWEN.md" ] && ! cmp -s "$stage/QWEN.md" "$q"; then
    if [ -f "$q" ]; then
      bak="$(_y9_qwen_backup "$q")" || rc=1
    fi
    if [ "$rc" = 0 ] && mv -f "$stage/QWEN.md" "$q"; then
      echo "spool-install: vibe-agents: $q: the fleet rule parts rendered${bak:+, the old file kept as $bak}" >&2
    else
      rc=1
    fi
  elif [ "$rc" = 0 ]; then
    echo "spool-install: vibe-agents: $q: already current" >&2
  fi
  rm -rf "${stage:?}"
  return "$rc"
}'''
assert s.count(old) == 1, f"_y9_qwen count={s.count(old)}"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "rc03 fix-shape: forward stderr on any non-zero part rc + atomic O_EXCL backup capped at k=1..99"
fi

rc=0
# A (RED on base): unexpected y8 error (invalid UTF-8 in QWEN.md -> UnicodeDecodeError)
# must fail (rc!=0), leave QWEN.md unchanged, AND report the error on stderr
H1="$tmp/h1"; mkdir -p "$H1/.qwen"
printf '\xff\xfe bad utf8\n' >"$H1/.qwen/QWEN.md"
h1_before="$(sha256sum <"$H1/.qwen/QWEN.md")"
err1="$(env HOME="$H1" bash -c 'source "$0" && spool_install_vendor_lane_rule' "$fn" 2>&1 >/dev/null)"; r1=$?
h1_after="$(sha256sum <"$H1/.qwen/QWEN.md")"
err1_has=0; grep -qiE 'UnicodeDecodeError|Traceback|codec' <<<"$err1" && err1_has=1
echo "rc03 A(unexpected_err): rc=$r1 (want 1) stderr_has_cause=$err1_has (want 1) file_kept=$([ "$h1_before" = "$h1_after" ] && echo 1 || echo 0) (want 1)"
[ "$r1" != 0 ] && [ "$err1_has" = 1 ] && [ "$h1_before" = "$h1_after" ] || rc=1

# B (RED on base): all 99 backup names for the timestamp already taken -> must
# refuse (rc!=0), emit "no free backup name", create no -100, and leave QWEN.md untouched
H2="$tmp/h2"; mkdir -p "$H2/.qwen" "$tmp/bin"
printf '#!/bin/sh\necho 20261126T000000Z\n' >"$tmp/bin/date"
chmod +x "$tmp/bin/date"
printf 'keep original\n' >"$H2/.qwen/QWEN.md"
h2_before="$(sha256sum <"$H2/.qwen/QWEN.md")"
: >"$H2/.qwen/QWEN.md.bak-spool-install-20261126T000000Z"
for (( k = 2; k < 100; k++ )); do
  : >"$H2/.qwen/QWEN.md.bak-spool-install-20261126T000000Z-$k"
done
err2="$(env HOME="$H2" PATH="$tmp/bin:$PATH" bash -c 'source "$0" && spool_install_vendor_lane_rule' "$fn" 2>&1 >/dev/null)"; r2=$?
h2_after="$(sha256sum <"$H2/.qwen/QWEN.md")"
has100=0; [ -e "$H2/.qwen/QWEN.md.bak-spool-install-20261126T000000Z-100" ] && has100=1
has_msg=0; grep -q 'no free backup name' <<<"$err2" && has_msg=1
echo "rc03 B(backup_cap_99): rc=$r2 (want 1) created_100=$has100 (want 0) msg=$has_msg (want 1) file_kept=$([ "$h2_before" = "$h2_after" ] && echo 1 || echo 0) (want 1)"
[ "$r2" != 0 ] && [ "$has100" = 0 ] && [ "$has_msg" = 1 ] && [ "$h2_before" = "$h2_after" ] || rc=1

# C (CONTROL): normal fresh upgrade still succeeds with 1 backup and 5 fragments
H3="$tmp/h3"; mkdir -p "$H3/.qwen"
printf '## Qwen Added Memories\n- keep me\n' >"$H3/.qwen/QWEN.md"
env HOME="$H3" bash -c 'source "$0" && spool_install_vendor_lane_rule' "$fn" >/dev/null 2>&1; r3=$?
frags="$(grep -c '^<!-- fragment spool-install/' "$H3/.qwen/QWEN.md" 2>/dev/null || echo 0)"
baks="$(find "$H3/.qwen" -maxdepth 1 -name 'QWEN.md.bak-spool-install-*' | wc -l)"
echo "rc03 C(ctrl_upgrade): rc=$r3 (want 0) frags=$frags (want 5) baks=$baks (want 1)"
[ "$r3" = 0 ] && [ "$frags" = 5 ] && [ "$baks" = 1 ] || rc=1

echo "rc03 exit $rc"
exit "$rc"
```

Output on `0d5e0b252` (sat, 03:25Z; confirmed by panel `c-896@sat` on v0.1 `0dfecbb3e`):

| run | output |
|---|---|
| `bash rc03-b49.sh 0d5e0b252` | `rc03 site: _y9_qwen=1` / `rc03 A(unexpected_err): rc=1 (want 1) stderr_has_cause=0 (want 1) file_kept=1 (want 1)` / `rc03 B(backup_cap_99): rc=0 (want 1) created_100=1 (want 0) msg=0 (want 1) file_kept=0 (want 1)` / `rc03 C(ctrl_upgrade): rc=0 (want 0) frags=5 (want 5) baks=1 (want 1)` / `rc03 exit 1` |
| `bash rc03-b49.sh 0d5e0b252 fix-shape` | `rc03 site: _y9_qwen=1` / `rc03 fix-shape: forward stderr on any non-zero part rc + atomic O_EXCL backup capped at k=1..99` / `rc03 A(unexpected_err): rc=1 (want 1) stderr_has_cause=1 (want 1) file_kept=1 (want 1)` / `rc03 B(backup_cap_99): rc=1 (want 1) created_100=0 (want 0) msg=1 (want 1) file_kept=1 (want 1)` / `rc03 C(ctrl_upgrade): rc=0 (want 0) frags=5 (want 5) baks=1 (want 1)` / `rc03 exit 0` |

---

## 5. Rows

| # | id | practice | sites (file:line on `0d5e0b252`) | evidence | red control (fails on `0d5e0b252`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b49-01-iac-customer-box-role-list-dash-and-slash` | customer-box role gate refuses YAML list-dash directives (`- ignore_errors:` / `- failed_when:` / `- when:`) and normalizes trailing `/` on `CUSTOMER_BOX_ROLE_DIR` | `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh:49,145,151-158`; `csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` (new controls after `:143`) | `a-875@sat` R7 N1 & N3 (`6f6bae52`, b48-02 `917d60ce4`), named in b49 brief; section 4.1 | `bash rc02-b49.sh 0d5e0b252` -> `rc02 exit 1`; control `fix-shape` -> `rc02 exit 0` | `bash csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh`; `bash rc02-b49.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x` on both files; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `bash csi-spl-iac/src/bash/tests/action-header-tags.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.1: strip trailing `/` from `d` at `:49` (preserving `/`); allow `(-[[:space:]]+)?` after `^[[:space:]]*` in `spl_cbr_when_false` (`:145`) and `spl_cbr_no_swallow` (`:154-156`); keep comments and `changed_when: false` green; keep all functions <= 75 lines; add controls in `customer-box-role-set.tst.sh`; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` claude 03:18Z: sat 82% / 37% weekly pick, `<box2>` 86% / 38% weekly) | claude | agy (`BOX_PICK_KIND=agy` 03:17Z: sat 82% pick, both `agy weekly unknown`, placed anyway), else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |
| 02 | `b49-02-orc-y9-qwen-stderr-and-backup` | `spool-install` step `y9` forwards stderr on every `y8-vibe-agents.py` failure and creates `QWEN.md` backups atomically (`O_EXCL`, capped at 99) | `csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh:62-89`; `csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh` (new cases after `:98`) | `a-748@sat` R7 N3 & N4 (`4c1990d6`, SPL-6533), round 48 section 7; `y8-vibe-agents.py:52-68`; section 4.2 | `bash rc03-b49.sh 0d5e0b252` -> `rc03 exit 1`; control `fix-shape` -> `rc03 exit 0` | `bash csi-spl-orc/src/bash/tests/spool-install-y9-agy-qwen-fleet-rules.tst.sh`; `bash csi-spl-orc/src/bash/features/spool-install/tests/test-agy-rules-always-on.sh`; `bash csi-spl-orc/src/bash/features/spool-install/tests/test-vibe-agents.sh`; `bash csi-spl-orc/src/bash/features/spool-install/tests/test-y14-agy-exit-rule.sh`; `bash rc03-b49.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x` on both files; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.2: extract `_y9_qwen_backup` (`O_EXCL` via `set -C` + `umask 077`, `k=1..99`, refusing with `no free backup name` when full); track per-part rc in `_y9_qwen` and forward non-empty stderr on every non-zero part rc while keeping `"edited by hand"` echo on rc 0; keep all functions <= 75 lines; add cases 7 & 8 in `test-agy-qwen-fleet-rules.sh`; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` 03:18Z: sat pick) | claude | agy if quota, else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |

- **R1 (disjoint files):** both rows are Batch 1 and share 0 files:
  - b49-01: `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh`, `csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh`
  - b49-02: `csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh`, `csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh`
- **R3** (checked 2026-11-26T03:22:16Z and re-checked at v1.0 2026-11-26T03:47:28Z, panel N5): `lane-map.sh --check csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh,csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh,csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh,csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh,csi-spl-doc/doc/md/bug-round-49-plan.md --agent a-895` -> **exit 4**: 0 live lanes list these 5 paths, but 15 live lanes on `<box2>` record no files at 03:47:28Z (`unknown:` c-029, c-041, c-086, c-146, c-187, c-398, c-407, c-416, c-474, c-535, c-728, c-927, c-936, c-957, c-965; panel also saw `c-935` at 03:4xZ): **not free until the holder re-runs `--check` at placement**. By `do_spl_lane_map` scopes (03:17Z..03:18Z), live lanes on sat (`a-826` & `c-722` SPL-6517, `a-891` & `c-893` refactor round 05 planner/panel, `a-886` & `c-879` r04-02 closing, `a-852` r04 planner, `a-846` b48 planner, `c-298` Taxes tab SPL-6438) and `<box2>` (`c-957`/`c-965` spec 125, private workspace seats) touch none of these 4 row files. Note `a-891@sat` (r05 planner) has not yet published its r05 plan, so the holder must also confirm r05 does not pick these 4 files at placement. The queue, `./run -a do_spl_spawn_queue` (03:17:20Z): 2 queued asks (`e2b92184` b49 panel seat `c-896@sat`, now placed; `5b1b7d82` `c001-s186-m9-n2-qto-sync`, feature), disjoint by slug.
- **R7:** claude-authored code rows: agy R7 seat if `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` shows agy quota (03:17Z: both boxes `agy weekly unknown`, placed anyway; pick sat 82%), else claude waiver seat (`1a7c70da`). No grok (c-001 `dc84300a`). No mistral (no review seat since 2026-11-25, and no coding kind).
- **Rhythm (1.4):** rows queue once the panel signs and `do_spl_review_line_check` exits 0; phase is night (since 19:00Z).
- **Pushes:** aim 1 per row (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug`.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| `a-826` N2 on SPL-6517 (`spool-live-ack.sh` log size cap) and `spool-agent-hook.sh` (`a-767` N2, `a-823` N2) | `c-722@sat` + `a-826@sat` | live lane SPL-6517 (R3, full gate running on `06467d099` at 03:17:49Z); stay off. |
| `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`) | `c-298@sat` | live lane SPL-6438 (R3); stay off. |
| Refactor round 05 (SPL-6553), r04-02 closing (SPL-6552), spec 125 (SPL-6409), private workspace seats | live / queued lanes per `do_spl_lane_map` and `do_spl_spawn_queue` | owned; stay off. |
| Release-transfer repo open bug issues (SPL-6361, 6362, 6366) | live lanes on `<box2>` | different repository, not `csi-spl`. |
| The `unknown_token` box (99 prd WARNINGs since `01:28:36Z`, 0 since W) | the holder, as a box question | carried. |
| `review-go` inline-backtick `DRY_RUN=0` and prose `Apply` false holds (`c002-next-round-candidates.md:141-142`, `c-002` `56a64404`, `c-001` `d05ddaad`) | design / round 50 planner | naive skip conflicts with `spl-review-go.tst.sh:111-114` case 24 and real `apply` holds; needs narrower design. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 (all Batch 1, R1 disjoint; matches rulebook 5.1 aim of 2) |
| inputs re-measured | 10 sources; 10 prd ERROR entries in 6 h (**0 since W**, 2 since `01:28:36Z`); 439 prd WARNING entries in 6 h (401s left out, cap not reached; **0 since W**, 149 since `01:28:36Z`) + 16 h `hours/minutes` read (212 entries: 183 HTTP 200, 29 HTTP 204, 0 400s, 0 warns); 9 alert policies (0 incidents); 6 open t1 bug issues + SPL-6554 (0 `csi-spl` wip/todo/eval outside this round); 100 wf 10 runs (69 success, 23 cancelled, 6 failure, 2 running; **0 failed since `01:28:36Z` or W**); **0 failed runs** since `01:28:36Z` or W across all other master workflows; 12 commits and 7 `review:` lines in `8483a5d02..0d5e0b252` (0 since W) + `c-001`/`c-002`/`c-003` archives + recent R7 outboxes + `automation.log` tail; 0 HUM posts since `00:00:00Z`; round 48's first inputs + seat file (`692ed6e20`); holder's candidate list (142 lines on sat); `rc02-b49.sh` and `rc03-b49.sh` n=1 each way on `0d5e0b252` (`shellcheck -S warning` rc 0, verified independently by panel `c-896@sat`); baseline `customer-box-role-set.tst.sh` (`0 failure(s)`), `test-agy-qwen-fleet-rules.sh` (`18/18 passed`) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b49-'` -> 0; `git ls-remote origin 'refs/heads/review/b49-*' 'refs/heads/wip/*b49*' 'refs/heads/*-b49-*' 'refs/heads/*bug-round-49*'` -> nothing (rc 0); briefs on sat matching `b49\|bug-round-49`: only `hand-sat-c002-bug-round-49-planner.md` and `c002-bug-round-49-claude-panel-seat.md` (03:17Z; confirmed by panel `c-896@sat`) |
| R7 seat | agy if quota (`BOX_PICK_KIND=agy` 03:17Z: sat 82% pick, both boxes `agy weekly unknown`, placed anyway), else claude waiver seat (`1a7c70da`) |
| first inputs for round 50 | `a-841` N1 (`setup-gh-runner-cpu-budget-cron.tst.sh:83-91` section 4 red control copies only one `.func.sh` into `$T/`, failing on relative `source` at `:35-40,69` before reaching the action); `review-go` owner-go false holds on plan-table / backticked `DRY_RUN=0` and prose `"Apply <section>'s verbatim hunks"` (`c002-next-round-candidates.md:141-142`, `c-002` `56a64404`, `c-001` `d05ddaad`, designing around case 24 `a backticked prd step -> rc 4`); `a-826` N2 (`spool-live-ack.sh` log size cap, only if SPL-6517 lands without it); `a-767` N2 (`spool-agent-hook.sh:683,771` stale `stop_denies` on tool-before-Stop) and `a-823` N2 (`PreInvocation` in `EVENTS`, once SPL-6517 lands); `a-769` N1 (`check-pre-push-lint.func.sh` `_ppl_run_timed` returns 124 instead of 137 on SIGKILLed group) & N2 (`tenant-host-reserve.tst.sh` symlink control); `a-790` N1 (`internal/mcp/mcp_test.go:560-563` control ambient env); hours-minutes whole-batch 400 follow-up (once a live `hours: minutes refused` warn fires); `c-708` N1 (`BoxTaskEnvelopes` box-scoped probe); `a-683` N3 (non-`AgentsCommand` / embed / `channel_box_pins` posts in `hum\|`); `c-625` N1-N3 (Taxes tab, once SPL-6438 lands); `a-490` N1 (`TestCategoryTestPathsZZIsolated` regex at `categories_test.go:388`); `a-480` N1 (`syncWriter.Reset`); `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget`; `unknown_token` box; hub dir mode; hermetic 2/4 timeout; composed testids; `i18n-lang-review-exempt.json:2`; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` as carried |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** a-895@sat (agy, `specs_and_docs`).
- **Panel:** c-896@sat (claude, cross-vendor; placed on `dispatch-4dcc34cd` / `dispatch-bug-r49`, ask `e2b92184`).
- **Row reviewer (R7):** section 5.
- **Review history:**
  - 2026-11-26 03:35Z: v0.1 `0dfecbb3e`, pushed to `review/c002-bug-round-49-planner` (3 rows: b49-01, b49-02, b49-03; rebased on `874d1b2f4` with 0 drift). Sent to `c-896@sat` (`5f0fb818`) and holder `c-002@sat` (`06829235`) on task `dispatch-bug-r49`.
  - 2026-11-26 03:46Z: panel `c-896@sat` (claude) **FAIL** on v0.1 `0dfecbb3e` (msg `9ab17288`; seat file `csi-spl-doc/doc/md/bug-round-49/seat-claude.md` on `review/c002-bug-round-49-claude-seat` `29eac34d1`). Verified slug proof, 0 drift `0d5e0b252..874d1b2f4`, every site on `0d5e0b252`, all three rc hashes/sizes (`f6fce61785cf`/4668, `5509c3f13d9b`/5523, `e474daac0f09`/7052), each rc exit 1 on base and exit 0 on `fix-shape`, all three baseline suites green (`customer-box-role-set` 0 fail, `test-agy-qwen-fleet-rules` 18/18, `spl-spawn-queue` PASS all), R3 `lane-map.sh --check` (exit 4), and `do_check_dist_hygiene`. Findings: W1 (v0.1 b49-01 colon-less non-empty placement is refused by `0180_fleet_asks_queue.sql:27-28`, `AskPlacementRe`, and `spl_spawn_q_enqueue:220-221`, and empty placement is never `_l`, so drop v0.1 b49-01 -> 2 rows, matching rulebook 5.1 aim); W2 (R2 test columns: v0.1 b49-01 missing 6 tests -> moot once dropped; v0.1 b49-03 missing `test-y14-agy-exit-rule.sh`); N1 (7 `review:` lines in `8483a5d02..0d5e0b252`, not 6); N2 (trailing `/` keeps full absolute path, output-only, already rc 1); N3 (`_y9_qwen` backup cap is parity hardening with `y8-vibe-agents.py:52-68`, no data loss; `:67` outer `rc` changes no exit code); N4 (`uuid ~~ unknown` repeats 3x in 8 h, noted in 3.5); N5 (R3 re-checked at placement).
  - 2026-11-26 03:48Z: v1.0 folds W1 (drops v0.1 b49-01 -> 2 rows: `b49-01-iac-customer-box-role-list-dash-and-slash` and `b49-02-orc-y9-qwen-stderr-and-backup`), W2 (adds `test-y14-agy-exit-rule.sh` to b49-02's test column), and N1 to N5; `rc02-b49.sh` (`5509c3f13d9b`, 5523 B) and `rc03-b49.sh` (`e474daac0f09`, 7052 B) kept byte-identical from v0.1; 0 drift on all 4 row files `0d5e0b252..874d1b2f4`; pushed fast-forward on `0dfecbb3e` to `review/c002-bug-round-49-planner` for final panel signature by `c-896@sat`.
