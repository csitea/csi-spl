# Bug-fix round 51 - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6578 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `f64b7b72-d130-4379-a70f-81e6e6bc1887` ("Bug round 51", opened by c-002@sat 10:26Z 2026-11-26, post `c914e360`). Bug round 50 ([bug-round-50-plan.md](bug-round-50-plan.md), plan v1.0 `fee404830`, editor a-927@sat) served both rows b50-01 (`3ce429f73`, SPL-6574) and b50-02 (`86ac09501`, SPL-6576) and recorded close (`68d29f7cd`, written by a-927@sat; no b50 record is written here).  
Round focus: the sources of rounds 40 to 50 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since W, owner posts), round 50's first inputs, and the holder's candidate list on sat.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows (aim at 2, cap 3). Three small, disjoint Batch 1 candidates met the bar (section 3), clearing all three top named round-50 inputs while bug share is UNDER (live 10% vs 15-20% band, 24 h 14% vs 20-30% band, `11:59Z`, `do_spl_spawn_share`); holder `c-002@sat` confirmed keeping 3 rows (`ee7d2da1`, panel N4).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-50-plan.md](bug-round-50-plan.md).

**Status: v0.2 for cross-vendor panel re-review and signature by c-052@sat (claude); folds W1 and N1 to N5 from v0.1 `366b5b8ef` (`201a73934`, `492c7188`, holder `ee7d2da1`) plus holder round-52 input `b4952880`.**

Editor: **a-048@sat** (agy, `specs_and_docs`).  
Panel: **c-052@sat** (claude, cross-vendor; placed on `dispatch-bug-r51`, ask `95e35eea`, live in `do_spl_lane_map` at `12:14Z`; mistral sits on no review since 2026-11-25).

**One sha:** every site, line number and red control below is on **`bf585dc99`** (`origin/master`, `2026-11-26T12:45:10+01:00` / `2026-11-26T11:45:10Z`, `test(wui, SPL-6573): handover check 3 at 390px clicks Copy only once the mobile bars stop sliding`). Re-checked at v0.2 (`12:46Z`): 0 drift on the 5 row files from `bf585dc99` to current `origin/master`. The sources of section 2 were read on sat, `11:58Z..12:14Z` on 2026-11-26. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b50-plan')` read once at `11:58:58Z` -> `Window: W=2026-11-26T10:36:56+02:00` (commit `fee404830`, round 50's plan v1.0; `08:36:56Z`). Note (panel N1): b50's close record `68d29f7cd` (`12:05Z`) subsequently became the newest `docs(b50-plan` commit; per rulebook 5.3 the recorded `Window: W=2026-11-26T10:36:56+02:00` (`fee404830`) stands, and slug `b51` is proven free (`0` matching commits) under BOTH `fee404830` and `68d29f7cd`. Eleven commits landed between `fee404830` and `bf585dc99`.

---

## 1. How to read this

- `<box2>` is the fleet's box that is not sat and `<dev-box>` one unpinned workstation box, as in rounds 21 to 50: the public repo names none of them.
- **Paths** are repo-relative. Line numbers are as of `bf585dc99`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red controls are printed verbatim in section 4 (`rc01-b51.sh` updated at v0.2 per panel W1; `rc02-b51.sh` and `rc03-b51.sh` kept byte-identical from v0.1 `366b5b8ef` so the panel's verified v0.1 runs hold). Each is self-contained (zero box paths, runnable on any machine including `<box2>`), copies files from the named sha with `git archive` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout or live spool. Each site guard checks function names only, so `bash rc0N-b51.sh <fix sha>` (without `fix-shape`) exits 0 on a valid fix.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs).
- This seat runs on sat, so `/var/spool-hub/dispatch/c002-next-round-candidates.md`, `/var/spool-hub/dispatch/automation.log`, recent author briefs under `/var/spool-hub/dispatch/briefs/`, and `c-001`/`c-002`/`c-003` + recent R7 outboxes/reports were read directly; sat-only evidence is quoted inline below so any reviewer can audit it directly.

---

## 2. Where rows could come from (measured since W `fee404830`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=6h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (`11:59:49Z`) | 23 entries in 6 h (**13 since W** `08:36:56Z`: 11 Cloud SQL `spool_hub_rt` ad-hoc SQL errors `relation "topics" does not exist`, `column "id"/"agent_id"/"from_agent"/"deleted_at" does not exist`, `operator does not exist: uuid = text`; 2 Cloud Run `GET /v1/ws` HTTP 503 `malformed HTTP response or connection to the instance had an error` at `09:59:20Z` and `10:13:25Z`) | **0 rows**: section 3.4 (ad-hoc SQL + transient Cloud Run WebSocket instance recycle; 0 alert incidents). |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=6h ./run -a do_gcp_list_alert_incidents` (`11:59:13Z`) | 9 policies, 0 incidents in `05:59:13Z..11:59:13Z` | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,120), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (`11:59:21Z`) | 6 issues (3 `wip` in the release-transfer repo: SPL-6361, 6362, 6366; 3 `onhold`: SPL-5911, 5254, 4994) plus SPL-6578 (this round, priority 2) | **0 rows.** 0 open `csi-spl` `eval`/`todo`/`wip` bug-labelled issues outside this round. |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (`11:59:01Z..12:04:53Z`, background) | 100 runs, `2026-11-25T15:48:27Z..2026-11-26T11:46:12Z`: 73 success, 21 cancelled, 4 failure, 2 running; every job's p90 under 75% of its timeout (highest: hermetic 3/4, 61%). **0 failed runs since W (`08:36:56Z`)** (newest wf 10 failure was pre-W `45771399881` on `a248ed37` at `06:53:58Z`, already fixed by `551b3c601`) | **0 rows**: section 3.4. Trunk is green (`last green 45810065700` on `3ce429f7`, `11:22:52Z`; `wui e2e 5/8` `45807032885` on `984b6d70`, `11:03:25Z`). |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 25 --json databaseId,workflowName,headSha,createdAt,conclusion` (`12:01:53Z`), `createdAt >= 2026-11-26T08:36:56Z` | **1 failed run since W**: `45792046781` (`09:26:53Z`, `62 sec: gosec (Go SAST)` on `4fc040744`, SPL-6571 `taskcron` G115 int-to-uint conversion) — **already served** 20 min later by `06bce3642`; `do_check_deploy_lag` (`12:00:39Z`) dev and prd both `current` (hub `86ac0950`, wui `bf585dc9`, `n=0`) | **0 rows.** |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=6h LINES=5000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (`12:00Z`; cap not reached), plus 16 h targeted `hours/minutes` read (`12:00Z`) | 705 entries in 6 h (**460 since W** `08:36:56Z`): 418 `unknown_token`, 19 `unpinned_box`, 7 `github: request refused` 404 / `gcal` `context canceled`, 7 scanner 404s (`robots.txt`, `.env`), 4 HTTP 403 `GET /v1/operator/workspaces`, 2 HTTP 404 `GET /v1/view/netvisor/forecast`, 1 HTTP 404 `GET /v1/view/tax/overview`, and **1 HTTP 400 `PUT /v1/me/hours/minutes`** at `10:28:07Z` (`hours: minutes refused`, `count: 1`, `max_skew_s: 232`, `reason: "at must be within the last 45 days and not in the future"`). Targeted 16 h `hours/minutes` read: 163 entries (142 HTTP 200, 20 HTTP 204, 1 HTTP 400) | **0 rows**: section 3.4 (single-minute +232 s client clock skew, not whole-batch loss). |
| **7. R7 notes & automation logs since W** | `git log fee404830..bf585dc99 --format=%B`, `c-001`/`c-002`/`c-003` spool archives, R7 reports & outboxes (`a-025`, `a-027`, `a-029`, `a-037`, `a-041`, `a-966`, `a-976`, `a-995`), and `/var/spool-hub/dispatch/automation.log` tail | 11 commits (`fee404830..bf585dc99`), 6 `review:` lines (`a-027` b50-01 `3ce429f73`, `a-029` r06-02 `984b6d70d`, `a-025` b50-02 `86ac09501`, `a-976` M11 `54a39b0ce`, `a-995` S12a `4fc040744`, `a-966` S2 `6a8907804`) plus `a-037` SPL-6573 (`bf585dc99`) and `a-041` r06-01 PASS (`fea2e748c`, landed later as `8024dc0b5`). `a-025`/`a-027`/`a-029`/`a-037`/`a-976`: 0 open items (M11 N2/N4 folded in `54a39b0ce`); `a-995` N1 (malformed step tokens in `TestRefusals`) + N2 (`errors.As` note for S12b); `a-966` 4 non-blocking notes. Two pre-b50-01 `review-go` rc 4 holds (`10:58:12Z` r06-02, `11:05:07Z` b50-01) occurred before b50-01 landed (`11:06:07Z`). Subsequent holder note `b4952880` (`12:38Z`): `review-go` rc 4 false hold on `do_rdb_migration_next` (`c-001` `00b12ff3`/`c98d5412`, cleared `46d6c721`) | **0 new rows** (`a-995` N1 and `b4952880` carried in section 3.5 for round 52). |
| **8. Owner and member posts** | `ENV=prd SQL="select tenant_id, from_id, count(*), max(accepted_at) from messages where from_id like 'HUM-%' and accepted_at > '2026-11-26T00:00:00Z' group by 1, 2 order by 1, 2" ./run -a do_spl_db_query` (`11:59:31Z`) | 0 rows across all workspaces | **0 rows.** |
| **9. Round 50's first inputs** | `bug-round-50-plan.md` section 7 and section 3.5, re-measured on `bf585dc99` | Top 3 named inputs all reproduce cleanly on `bf585dc99` and are file-disjoint: `a-909` N1 & N2 (`y9-vendor-lane-rule.sh:97-109` & `test-agy-qwen-fleet-rules.sh`), `apply-gh-runner-cpu-budget.tst.sh` red controls (`:279-284,336-340,421-425`), and `c-902` N5 (`spl-review-go.func.sh:803` `fixed` list lacks `do_spl_desk_up`, `do_provision`, `do_tf_apply`; b50-01 landed `3ce429f73`, so `spl-review-go` is now free). `a-826` N2 (`spool-live-ack.sh:101-103` log cap) **already served** by SPL-6517 | **Rows b51-01, b51-02, b51-03** (sections 3.1 to 3.3). Rest accounted in section 3.5. |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (151 lines, read on sat `11:58Z`) | `:1-145` already accounted in b50 section 3.5 (`:141-145` served by b50-01 `3ce429f73`). Two new entries since b50 (`:147-151`): `:147-148` `<box2>` process churn (next PERF round, not bug); `:150-151` r06-02 `review-go` rc 4 false hold on `"2. Apply section 1.4's verbatim hunks"` (`10:58:12Z`, **served** 8 min later by b50-01 `3ce429f73`) | **0 additional rows** (accounted in section 3.5). |

---

## 3. The candidates, read

### 3.1 b51-01: `_y9_qwen_backup` (`y9-vendor-lane-rule.sh:97-109`) silences non-`EEXIST` OS errors and spins 99x reporting `no free backup name`; `test-agy-qwen-fleet-rules.sh` lacks mode `0600` and `k=1 -> k=2` assertions

- **What happens.** `csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh:97-109` creates the stamped backup of `~/.qwen/QWEN.md` via:
  ```bash
  for (( k = 1; k < 100; k++ )); do
    cand="$q.bak-spool-install-$stamp$([ "$k" = 1 ] || echo "-$k")"
    if (umask 077; set -C; cat <"$q" >"$cand") 2>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  echo "spool-install: vibe-agents: $q: no free backup name for $stamp: nothing replaced" >&2
  return 1
  ```
  Because `2>/dev/null` discards every shell/OS error and treats every non-zero exit identically to `EEXIST`, any non-`EEXIST` failure reaching `_y9_qwen_backup` spins 99 times and reports the misleading message `spool-install: vibe-agents: <q>: no free backup name for <stamp>: nothing replaced` instead of failing immediately with the real OS error. By contrast, its sibling renderer `y8-vibe-agents.py:52-68` (`backup_stamped`) catches ONLY `FileExistsError` and lets every other `OSError` fail immediately.
  - **Reachability through the entry point (`spool_install_vendor_lane_rule` -> `_y9_qwen`, corrected per panel W1):**
    - Through the entry point, a read-only `~/.qwen` fails earlier at `mktemp -d` (`:65`) with the real `Permission denied` (`rc=1`), and a missing `QWEN.md` skips the backup at `[ -f "$q" ]` (`:79`, `rc=0`) — so neither reaches `_y9_qwen_backup` through `y9 "$H"`.
    - The **reachable entry-level defect** is an **unreadable `QWEN.md` (mode `000`)** (and `ENOSPC` / `EIO` on the backup write): `cp -p` (`:66`) emits `Permission denied` (unchecked), `_y9_one` renders a fresh staged copy, `! cmp -s` (`:78`) evaluates true on `cmp`'s read error, `[ -f "$q" ]` (`:79`) is true, and `_y9_qwen_backup` spins 99x before emitting the false `no free backup name for <stamp>: nothing replaced` line (`rc=1`, panel probe P2).
    - Direct helper-level calls to `_y9_qwen_backup` on a missing parent directory (`ENOENT`) or a read-only `~/.qwen` (`chmod 0500`, `EACCES`) also exhibit the same 99x spin and false `no free backup name` message.
  - Additionally (`a-909` N2), `test-agy-qwen-fleet-rules.sh` does not directly assert the backup file's `0600` mode (`stat -c %a`) or the `k=1 -> k=2` collision suffix (`-2`).
- **Seen.** `a-909@sat` R7 N1 & N2 (`eaf6e4d6`, b49-02 `460750a35`), carried as first input #2 in `bug-round-50-plan.md` section 7; entry-level reachability refined by panel `c-052@sat` W1 (`201a73934`, probe P2). Reproduced live on `bf585dc99` (`rc01-b51.sh` v0.2 `12:45Z`): entry-level `spool_install_vendor_lane_rule` with `chmod 000 "$Q"` (`Case E`) and helper-level `_y9_qwen_backup` on `ENOENT` (`Case A`) and `chmod 0500` dir (`Case B`) all emit the false `no free backup name` message (`rc=1`). Baseline suites green on `bf585dc99`: `test-agy-qwen-fleet-rules.sh` (`20/20 passed`), `test-agy-rules-always-on.sh` (`18/18 passed`), `test-vibe-agents.sh` (`24/24 passed`), `test-y14-agy-exit-rule.sh` (`12/12 passed`).
- **Red control** (`rc01-b51.sh` v0.2, section 4.1, updated per panel W1): self-contained (extracts `csi-spl-orc/src/bash/features/spool-install` from `bf585dc99` into `mktemp -d`).
  - **Case A (helper-level, `helper_enoent`):** calls `_y9_qwen_backup "$tmp/no-such-dir/QWEN.md"` directly -> requires `rc != 0` and `false_nofree=0`. On `bf585dc99`: `rc=1`, `false_nofree=1`.
  - **Case B (helper-level, `helper_readonly_dir`, non-root):** `chmod 0500 "$tmp/ro/.qwen"` and calls `_y9_qwen_backup` directly -> requires `rc != 0` and `false_nofree=0`. On `bf585dc99`: `rc=1`, `false_nofree=1`.
  - **Case E (entry-level, `entry_unreadable_qwen`, non-root; panel W1):** `chmod 000 "$tmp/unr/.qwen/QWEN.md"` and runs `HOME="$tmp/unr"` `spool_install_vendor_lane_rule` -> requires `rc != 0`, `false_nofree=0`, `Permission denied` on stderr, `QWEN.md` bytes unchanged, and 0 leftover `.y9-stage.*` dirs. On `bf585dc99`: `rc=1`, `false_nofree=1` (RED).
  - **Case C (`k1_to_k2_mode600`):** pre-creates `k=1` backup with stubbed `date` under `umask 0022` -> verifies `-2` created with mode `600`, old `QWEN.md` bytes preserved, and `k=1` untouched.
  - **Case D (`suite`):** runs `test-agy-qwen-fleet-rules.sh` -> requires `rc=0`.
  - On `bf585dc99`: `rc01 exit 1`. **Control (`fix-shape`):** replaces `_y9_qwen_backup` with `python3` `os.open(..., os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)` (keeping `stamp="$(date -u +%Y%m%dT%H%M%SZ)"` in bash so test 8's `date` stub holds), catching ONLY `FileExistsError`, unlinking any partial file on write error, and printing the real `OSError` to stderr immediately (`_y9_qwen_backup` = 37 lines <= 75, `shellcheck -S warning -x` rc 0) -> Cases A, B, E, C, D all pass -> `rc01 exit 0`.
- **Fix scope.**
  - `csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh:94-109`: update `_y9_qwen_backup` so ONLY `FileExistsError` (`EEXIST`) advances `k=1..99`, any other `OSError` fails immediately printing the real OS error to stderr (and unlinks any partial backup on write failure), mode is `0600` (`os.umask(0o077)` + `0o600`), and `stamp="$(date -u +%Y%m%dT%H%M%SZ)"` stays compatible with test 8's stubbed `date`. Keep `_y9_qwen_backup` <= 75 lines.
  - `csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh`: add direct `stat -c %a` mode `600` assertion in section 3, add section 9 (`k=1 -> k=2` collision creates `-2` with mode `600`, old content, `k=1` untouched), and add section 10 covering BOTH the **entry-level** unreadable `QWEN.md` (`chmod 000`, driven through `y9 "$H"`, non-root: `rc != 0`, `Permission denied` on stderr, NOT `no free backup name`, `QWEN.md` unchanged, no leftover `.y9-stage.*` — RED on `bf585dc99`) AND **helper-level** direct `_y9_qwen_backup` calls on missing parent dir (`ENOENT`, works for all users) and read-only `~/.qwen` (`chmod 0500`, non-root). `Docs: none` (fixes error-reporting bug and test gaps in internal `spool-install` step `y9`).

### 3.2 b51-02: `apply-gh-runner-cpu-budget.tst.sh` red controls (`:279-284,336-340,421-425`) stage a flat copy in `$T/red/` (6 broken relative-`source` stderr errors) and section 8 passes vacuously on a crashing mutant

- **What happens.** `csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh:279` sets up the red-control directory for sections 6 (gate floor), 7 (CI reserve), and 8 (CI overflow cap) as a flat directory with only one sibling copied:
  ```bash
  mkdir -p "$T/red"; cp "$(dirname "$FUNC")/spl-lane-map.func.sh" "$T/red/"
  ```
  When `apply-gh-runner-cpu-budget.func.sh:172` (`ghrb_hub`) sources `$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh`, `spl-lane-map.func.sh:72,74` resolves `../../../lib/bash/funcs/spl-box-ci.func.sh` and `./spl-box-cordon.func.sh` relative to `$T/red/`, leaking **6** missing-file errors to stderr on every run:
  ```
  /tmp/.../red/spl-lane-map.func.sh: line 72: .../red/../../../lib/bash/funcs/spl-box-ci.func.sh: No such file or directory
  /tmp/.../red/spl-lane-map.func.sh: line 74: .../red/spl-box-cordon.func.sh: No such file or directory
  (repeated x3 across sections 6, 7, and 8)
  ```
  Worse, section 8's red control (`:421-425`) checks ONLY `[[ "$(cat "$SYSD_LOG")" != *'CPUQuota=400%'* ]]` without checking `$rc -eq 0` or asserting `CPUQuota=1280%` (the unclamped idle ceiling):
  ```bash
  out="$(FUNC="$T/red/apply-gh-runner-cpu-budget.func.sh" ov OTHER=0)"; rc=$?
  [[ "$(cat "$SYSD_LOG")" != *'CPUQuota=400%'* ]] &&
    pass "red control: a copy without the cap clamp does not set 400% (the first check catches it)" || fail "red control: the broken copy still set 400%"
  ```
  If the mutated copy exits non-zero before setting any quota, `$SYSD_LOG` is empty, `"" != *'CPUQuota=400%'*` is true, and section 8 reports `PASS` vacuously.
- **Seen.** Observed live during b50-02's baseline run and carried as first input #3 in `bug-round-50-plan.md` section 7 (same single-file-copy root cause fixed for `setup-gh-runner-cpu-budget-cron.tst.sh` in b50-02 `86ac09501`). Reproduced live on `bf585dc99` (`12:00Z` and `rc02-b51.sh` `12:12Z`; confirmed ready as written by panel `c-052@sat` on v0.1 `366b5b8ef`): 6 stderr `No such file or directory` errors on a normal run, and a crashing section-8 mutant passes `apply-gh-runner-cpu-budget.tst.sh` with `rc=0`. Sibling baselines green on `bf585dc99`: `setup-gh-runner-cpu-budget-cron.tst.sh` (`all passed`), `gh-runner-add.tst.sh` (`0 failure(s)`).
- **Red control** (`rc02-b51.sh`, section 4.2, kept byte-identical from v0.1): self-contained (extracts `csi-spl-orc` libs, run actions, scripts, and `apply-gh-runner-cpu-budget.tst.sh` from `bf585dc99` into `mktemp -d`).
  - **Case A (`clean_run`):** runs `bash "$tst"` capturing stderr -> requires `rc=0` and **0** `No such file or directory|command not found` lines on stderr. On `bf585dc99`: `rc=0`, `stderr_source_errs=6 (want 0)`.
  - **Case B (`non_vacuous_sec8`):** injects one line into a temp copy of `apply-gh-runner-cpu-budget.func.sh` so `do_apply_gh_runner_cpu_budget` returns 1 immediately whenever section 8's `sed` (`cap = 0`) has mutated it (leaving `$SYSD_LOG` empty). Runs `bash "$mtst"` -> a non-vacuous section 8 MUST fail (`rc != 0`). On `bf585dc99`: `rc=0 (want !=0)` -> `rc02 exit 1`.
  - **Control (`fix-shape`):** stages `$T/red/src/bash/run` with `$T/red/lib -> $PROJ_ROOT/lib` and symlinked sibling `*.func.sh` (matching b50-02 `86ac09501`), adds a positive control in section 6 proving an unmodified staged copy reaches `CPUQuota=500%`, points sections 6, 7, and 8 at `$RED_FUNC`, and asserts `$rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=1280%'* && "$(cat "$SYSD_LOG")" != *'CPUQuota=400%'*` in section 8 -> Case A `rc=0 stderr_source_errs=0`, Case B `rc=1` -> `rc02 exit 0`.
- **Fix scope.** `csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh:279-284,336-340,421-425`:
  - Stage the red-control tree at `$T/red/src/bash/run` with `$T/red/lib -> $PROJ_ROOT/lib` and symlinks for sibling `*.func.sh` (excluding `$(basename "$FUNC")`), writing mutated copies to `$RED_FUNC`.
  - Add a positive control in section 6 proving an unmodified copy in `$RED_FUNC` reaches `CPUQuota=500%`.
  - In section 8 (`:423-425`), assert `$rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=1280%'* && "$(cat "$SYSD_LOG")" != *'CPUQuota=400%'*` so a crashing mutant cannot pass vacuously. Keep all existing sections green with zero stderr `No such file or directory` / `command not found` lines. `Docs: none` (test-only fix to red-control staging and vacuous assertion; no runtime behaviour changes).

### 3.3 b51-03: `_spl_review_go_owner_go` (`spl-review-go.func.sh:803`) `fixed` list omits `do_spl_desk_up`, `do_provision`, and `do_tf_apply`

- **What happens.** `_spl_review_go_owner_go` (`csi-spl-orc/src/bash/run/spl-review-go.func.sh:801-808`) scans instruction text for owner-go keywords using:
  ```bash
  local fixed='do-provision|do-tf-apply|PROBE_PRD_GO|DRY_RUN=0|ENV=prd|service account key|/etc/'
  ```
  Three owner-go `./run -a` action prefixes (10 actions total on `bf585dc99`, panel N5) are missing from `fixed`:
  1. **`do_spl_desk_up`** (and its prefix family `do_spl_desk_up_all`, `do_spl_desk_up_boxes`, `do_spl_desk_up_tenants`): the agent seed DEPLOY-GATE (e) explicitly forbids running `do_spl_desk_up` without going through `c-001`/owner, and `_spl_review_go_instr`'s `CMD` regex at `:755` already names `do_spl_desk_up`, yet `:803` omits it.
  2. **`do_provision`** (and `do_provision_firebase_dns`, `do_provision_firebase_dns_env`, `do_provision_spool_root`): `:803` lists the Make target `do-provision` with a hyphen, missing the direct `./run -a do_provision*` invocation.
  3. **`do_tf_apply`** (and `do_tf_apply_target`): `:803` lists the Make target `do-tf-apply` with a hyphen, missing `./run -a do_tf_apply`; and because SPL-5798 (`:802,806`) excludes `apply` joined by `_`, `do_tf_apply` is NOT caught by the `apply` check either.
  As a result, an author brief instructing `Run ./run -a do_spl_desk_up` (or `do_provision*` / `do_tf_apply*`) without `ENV=prd`, `DRY_RUN=0`, or bare `apply` passes `_spl_review_go_owner_go` with `rc=0` (GO) instead of holding `rc=4`.
- **Why this causes zero false holds.** Direct scan of the newest 500 readable author briefs on sat (`12:08Z`, excluding `-(reviewer|seat|planner).md`; independently re-verified by panel `c-052@sat`): **0 of 500** briefs flip `GO -> HOLD` (only 1 brief matched any of the three tokens and it was already `HOLD` on `ENV=prd`). `_spl_review_go_instr` continues to strip `## Never`, `## Why`, blockquotes, and fenced code blocks before the scan, so `Never run do_spl_desk_up` under `## Never` stays `rc=0`.
- **Seen.** `c-902@<box2>` panel N5 on b50 (`fc0f6bf6b`, `bug-round-50-plan.md` section 7 first input #1), now unblocked because b50-01 landed (`3ce429f73`, `c-011` ACCEPTED `11:50:27Z`). Reproduced live on `bf585dc99` (`12:03Z` and `rc03-b51.sh` `12:10Z`; confirmed ready as written by panel `c-052@sat` on v0.1 `366b5b8ef`): all 5 action probes return `rc=0` on `bf585dc99` and `rc=1` on `fix-shape`. Baseline `spl-accepted-close.tst.sh` -> `0 failure(s)`, `spl-review-go.tst.sh` -> `0 failure(s)` (panel run).
- **Red control** (`rc03-b51.sh`, section 4.3, kept byte-identical from v0.1): self-contained (extracts `spl-review-go.func.sh` from `bf585dc99` into `mktemp -d`). Checks 5 RED probes (`red_desk_up`, `red_desk_up_all`, `red_do_provision`, `red_do_tf_apply`, `red_do_tf_apply_target` -> want `rc=1`) and 6 regression controls (`ctrl_never`, `ctrl_why`, `ctrl_fenced`, `ctrl_b50_r05_01` -> want `rc=0`; `ctrl_hyphen_provision`, `ctrl_hyphen_tf_apply` -> want `rc=1`). On `bf585dc99`: all 5 RED probes return `rc=0 (want 1)` -> `rc03 exit 1`. **Control (`fix-shape`):** adds `do_provision|do_tf_apply|do_spl_desk_up` to `fixed` at `:803` -> all 5 RED probes return `rc=1` and all 6 controls pass -> `rc03 exit 0`.
- **Fix scope.**
  - `csi-spl-orc/src/bash/run/spl-review-go.func.sh:803`: update `fixed` to `'do-provision|do_provision|do-tf-apply|do_tf_apply|do_spl_desk_up|PROBE_PRD_GO|DRY_RUN=0|ENV=prd|service account key|/etc/'` (and keep the doc comment at `:791-800` consistent). Keep `_spl_review_go_owner_go` <= 75 lines (29 lines unchanged).
  - `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`: add case 35 after case 34 (`:1420`, and document it in the header comment) proving `do_spl_desk_up`, `do_spl_desk_up_all` (prefix family probe, panel N5), `do_provision`, `do_provision_firebase_dns` (prefix family probe, panel N5), `do_tf_apply`, and `do_tf_apply_target` in `## Do` hold `rc=4` (and pass with a valid `Owner-go:` HUM message), while the same tokens under `## Never`, `## Why`, or a fenced code block stay `rc=0` (GO). `Docs: none` (tightens owner-go keyword list in existing spec 157 rule 1 automation).

### 3.4 CI reds and prd WARNING / ERROR lines, read

| source / item | read | why not a row |
|---|---|---|
| wf 10 (`10_ci-quality.yml`, 100 runs `11:59Z..12:04Z`) | **0 failed runs since W (`08:36:56Z`)**. Pre-W failures: `45771399881` (`a248ed37`, `06:53:58Z`, SPL-6517 socket temp path — fixed by `551b3c601`), `45678338355`/`45674842811` (fixed by SPL-6531 `672162eb9`), `45661882286` (pre-b49, green since) | **0 rows**: trunk is green. |
| Other master workflows (`gh run list --status failure`, `12:01Z`) | 1 failure since W: `45792046781` (`09:26:53Z`, `62 sec: gosec` G115 on `4fc040744`, SPL-6571) | **Served** 20 min later by `06bce3642` (green since). |
| Cloud SQL `spool_hub_rt` ad-hoc SQL errors (11 since W) | Exploratory `do_spl_db_query` queries (`relation "topics" does not exist`, `column "id"/"agent_id"/"from_agent"/"deleted_at" does not exist`, `uuid = text`); no repo code runs them | **Not a row**: ad-hoc operator/agent SQL. |
| Cloud Run `GET /v1/ws` HTTP 503 (`09:59:20Z`, `10:13:25Z`; 2 since W) | Transient Cloud Run WebSocket connection drop on revision/instance recycle (hub deployed `4.1.8` -> `4.2.0` around `10:17Z`); 0 alert incidents | **Not a row.** |
| `PUT /v1/me/hours/minutes` HTTP 400 (`10:28:07Z`, 1 in 16 h of 163 calls: 142 HTTP 200, 20 HTTP 204, 1 HTTP 400) | `hours: minutes refused`, `count: 1`, `max_skew_s: 232`, `reason: "at must be within the last 45 days and not in the future"` on a mobile client in a customer workspace — single-minute +232 s device clock skew, NOT a whole-batch loss | **Carried**: single-minute clock skew, not whole-batch loss. |
| `upload token refused` (`unknown_token`, 418 since W), `ws hello refused` (`unpinned_box`, 19 since W), scanner 404s (7), expected non-member/non-operator 403/404s (`operator/workspaces` 4, `netvisor/forecast` 2, `tax/overview` 1, `github contents` 404 / `gcal context canceled` 7) | Carried `unknown_token` box question + `<dev-box>` unpinned retries + expected auth/view 403/404s + deploy-time context cancels (`10:17:02Z`) | **Not a row** (`unknown_token` stays carried with holder). |

### 3.5 Round 50's first inputs, recent R7 notes, and the candidate list, re-read

| candidate | result on `bf585dc99` | verdict |
|---|---|---|
| `a-909` N1 & N2 (`y9-vendor-lane-rule.sh:97-109` & `test-agy-qwen-fleet-rules.sh`, b50 first input #2) | reproduced live on `bf585dc99` (entry-level unreadable `QWEN.md` mode `000` + helper-level `ENOENT`/`chmod 0500` dir all emit false `no free backup name`); `rc01-b51.sh` v0.2 exit 1 -> `fix-shape` exit 0 | **Row b51-01** (section 3.1). |
| `apply-gh-runner-cpu-budget.tst.sh` red controls (`:279-284,336-340,421-425`, b50 first input #3) | reproduced live on `bf585dc99` (6 stderr missing-file errors + vacuous section 8 passing on a crashing mutant); `rc02-b51.sh` exit 1 -> `fix-shape` exit 0 | **Row b51-02** (section 3.2). |
| `c-902` N5 (`spl-review-go.func.sh:803` `fixed` list lacks `do_spl_desk_up`, plus `./run -a` twins `do_provision` & `do_tf_apply`, b50 first input #1) | b50-01 landed (`3ce429f73`), file now free; all 5 action probes return `rc=0` on `bf585dc99` and `rc=1` on `fix-shape`; 0/500 newest sat author briefs flip; `rc03-b51.sh` exit 1 -> exit 0 | **Row b51-03** (section 3.3). |
| `review-go` `DRY_RUN=0` false HOLD on `do_rdb_migration_next` (`c-002@sat` msg `b4952880` `12:38Z`; `c-001` `00b12ff3` rc 4 on s196 T1, cleared by hand `46d6c721`, analysis `c-001` `c98d5412`) | `spl-review-go.func.sh:803` lists `DRY_RUN=0` and `:701-708` exempts only test-description lines, so `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` (local migration-number claim) holds rc 4; b51 already at 3-row cap (do not add to b51) | **Carried** as first input #1 for round 52 (fix shape: exempt `DRY_RUN=0` only when its action is `do_rdb_migration_next`, keeping it fail-closed). |
| `a-826` N2 (`spool-live-ack.sh` log size cap, b50 first input #4) | SPL-6517 landed (`a5e60319b`..`551b3c601`) **with** the cap: `spool-live-ack.sh:101-103` trims `live-ack.log` to last 200 lines once > 400 | **Served** (verified on `bf585dc99`). |
| `c002-next-round-candidates.md:150-151` (r06-02 `review-go` rc 4 false hold `10:58:12Z`) | occurred 8 min before b50-01 `3ce429f73` (`11:06:07Z`) landed; same `"Apply section 1.4's verbatim hunks"` shape already fixed by b50-01 | **Served** by b50-01 `3ce429f73`. |
| `c002-next-round-candidates.md:147-148` (`<box2>` process churn, 11:00Z load5 69.5) | perf round candidate (needs measurement first per `lesson-speed-up-measure-first.md`) | **Not a bug row** (perf round input). |
| `a-767` N2 (`spool-agent-hook.sh:807-813` stale `stop_denies`) & `a-823` N2 (`PreInvocation` in `EVENTS` at `:139-140`) | SPL-6517 landed, so `spool-agent-hook.sh` is now unblocked; round already at rulebook 5.1 3-row cap | **Carried** as first input #2 for round 52. |
| `a-769` N1 (`check-pre-push-lint.func.sh:618-643` `_ppl_run_timed` returns 124 instead of 137 on SIGKILLed group) & N2 (`tenant-host-reserve.tst.sh` symlink control) | verified still present on `bf585dc99`; R9 gate code and `_pp_run` treats 124 and 137 identically; round at 3-row cap | **Carried** as first input #3 for round 52. |
| `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`) | unblocked since SPL-6438 (`5aa360afc`); round at 3-row cap | **Carried** to round 52. |
| `a-995` N1 (`internal/taskcron/cron_test.go:209-229` malformed step tokens `*/`, `*/1/2`, `*/99999` not explicitly in `TestRefusals`; probed refused cleanly with no panic) | non-blocking test-coverage note from S12a (`4fc040744`) | **Carried** to round 52. |
| `a-911` N2 (`customer-box-role-set.tst.sh:160-165` `d6` explicit `rc != 0`); `a-790` N1 (`internal/mcp/mcp_test.go:560-563` control ambient env); hours-minutes whole-batch 400 follow-up (1 single-minute +232 s skew at `10:28:07Z`); `c-708` N1; `a-683` N3; `a-490` N1; `a-480` N1; `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget`; `unknown_token` box; hub dir mode; hermetic 2/4 timeout; composed testids; `i18n-lang-review-exempt.json:2`; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`; candidate-list items not re-measured in b50 | unchanged / carried (round at rulebook 5.1 cap of 3) | **Carried** to round 52. |

---

## 4. Red controls, as run

### 4.1 `rc01-b51.sh` (b51-01, updated at v0.2 per panel W1), sha256 first 12 hex `d017001e49be`, 7133 B

Run from any checkout: `bash rc01-b51.sh bf585dc99` (exit 1), then `bash rc01-b51.sh bf585dc99 fix-shape` (exit 0). Under 5 s each. Self-contained (zero box paths).

```bash
#!/usr/bin/env bash
# rc01-b51.sh <sha> [fix-shape]: b51-01 red control (v0.2, folds panel c-052 W1).
# On <sha>'s tree, _y9_qwen_backup (csi-spl-orc/src/bash/features/spool-install/
# steps/y9-vendor-lane-rule.sh:97-109) uses `(umask 077; set -C; cat <"$q" >"$cand")
# 2>/dev/null`, silencing non-EEXIST OS errors and looping 99 times before falsely
# reporting "no free backup name".
#   - Entry-level (Case E, through spool_install_vendor_lane_rule -> _y9_qwen):
#     an unreadable ~/.qwen/QWEN.md (mode 000, non-root) reaches _y9_qwen_backup
#     and emits the false "no free backup name" line on <sha>.
#   - Helper-level (Cases A & B, calling _y9_qwen_backup directly):
#     missing parent dir (ENOENT) and read-only ~/.qwen (chmod 0500, EACCES)
#     also emit the false "no free backup name" line on <sha>.
#   - Controls (Cases C & D): k=1 -> k=2 collision + mode 0600 under umask 0022,
#     and test-agy-qwen-fleet-rules.sh green.
# Extracts spool-install from <sha> into a mktemp dir. Self-contained (no box paths).
set -uo pipefail
sha="${1:?usage: rc01-b51.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+rwX "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc/src/bash/features/spool-install | tar -x -C "$tmp"
y9="$tmp/csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh"
tst="$tmp/csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh"
a=$(grep -c '^spool_install_vendor_lane_rule()' "$y9")
b=$(grep -c '^_y9_qwen_backup()' "$y9")
echo "rc01 sites: entry=$a backup=$b"
[ "$a" = 1 ] && [ "$b" = 1 ] || { echo "rc01 sites moved"; exit 2; }

if [ "${2:-}" = fix-shape ]; then
  python3 - "$y9" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = '''_y9_qwen_backup() {
  local q="$1" stamp cand k
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for (( k = 1; k < 100; k++ )); do
    cand="$q.bak-spool-install-$stamp$([ "$k" = 1 ] || echo "-$k")"
    if (umask 077; set -C; cat <"$q" >"$cand") 2>/dev/null; then
      printf '%s\\n' "$cand"
      return 0
    fi
  done
  echo "spool-install: vibe-agents: $q: no free backup name for $stamp: nothing replaced" >&2
  return 1
}'''
new = '''_y9_qwen_backup() {
  local q="$1" stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  python3 - "$q" "$stamp" <<'EOF_PY'
import os, sys
q, stamp = sys.argv[1], sys.argv[2]
try:
    data = open(q, "rb").read()
except OSError as e:
    print(f"spool-install: vibe-agents: {q}: backup failed: {e}", file=sys.stderr)
    sys.exit(1)
os.umask(0o077)
for k in range(1, 100):
    cand = f"{q}.bak-spool-install-{stamp}" + ("" if k == 1 else f"-{k}")
    try:
        fd = os.open(cand, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        continue
    except OSError as e:
        print(f"spool-install: vibe-agents: {q}: backup failed: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
    except OSError as e:
        try:
            os.unlink(cand)
        except OSError:
            pass
        print(f"spool-install: vibe-agents: {q}: backup failed: {e}", file=sys.stderr)
        sys.exit(1)
    print(cand)
    sys.exit(0)
print(f"spool-install: vibe-agents: {q}: no free backup name for {stamp}: nothing replaced", file=sys.stderr)
sys.exit(1)
EOF_PY
}'''
assert s.count(old) == 1, f"old count={s.count(old)}"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "rc01 fix-shape: python3 O_EXCL 0o600 backup catching FileExistsError only, failing fast on other OSError"
fi

rc=0
# A (helper-level): ENOENT (missing source/parent dir) -> fail fast with OS error, NOT "no free backup name"
outA="$(bash -c 'source "$1" && _y9_qwen_backup "$2"' _ "$y9" "$tmp/no-such-dir/QWEN.md" 2>&1)"; rA=$?
badA=$(grep -c 'no free backup name' <<<"$outA" || true)
echo "rc01 A(helper_enoent): rc=$rA (want !=0) false_nofree=$badA (want 0) [$outA]"
[ "$rA" != 0 ] && [ "$badA" = 0 ] || rc=1

# B (helper-level): EACCES on read-only ~/.qwen (non-root) -> fail fast with OS error, NOT "no free backup name"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$tmp/ro/.qwen"
  printf 'keep me\n' >"$tmp/ro/.qwen/QWEN.md"
  chmod 0500 "$tmp/ro/.qwen"
  outB="$(bash -c 'source "$1" && _y9_qwen_backup "$2"' _ "$y9" "$tmp/ro/.qwen/QWEN.md" 2>&1)"; rB=$?
  chmod 0700 "$tmp/ro/.qwen"
  badB=$(grep -c 'no free backup name' <<<"$outB" || true)
  echo "rc01 B(helper_readonly_dir): rc=$rB (want !=0) false_nofree=$badB (want 0) [$outB]"
  [ "$rB" != 0 ] && [ "$badB" = 0 ] || rc=1
fi

# E (entry-level, through spool_install_vendor_lane_rule -> _y9_qwen): unreadable QWEN.md (mode 000, non-root)
# On bf585dc99, reaches _y9_qwen_backup and emits the false "no free backup name" line; fix must fail with
# Permission denied, zero "no free backup name", QWEN.md untouched, and no leftover .y9-stage.* dir.
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$tmp/unr/.qwen"
  printf 'keep unreadable original\n' >"$tmp/unr/.qwen/QWEN.md"
  unr_sha="$(sha256sum <"$tmp/unr/.qwen/QWEN.md")"
  chmod 000 "$tmp/unr/.qwen/QWEN.md"
  outE="$(env HOME="$tmp/unr" bash -c 'source "$1" && spool_install_vendor_lane_rule' _ "$y9" 2>&1)"; rE=$?
  chmod 600 "$tmp/unr/.qwen/QWEN.md"
  badE=$(grep -c 'no free backup name' <<<"$outE" || true)
  permE=$(grep -ci 'permission denied' <<<"$outE" || true)
  keptE=0; [ "$(sha256sum <"$tmp/unr/.qwen/QWEN.md")" = "$unr_sha" ] && keptE=1
  stageE=$(find "$tmp/unr/.qwen" -mindepth 1 -maxdepth 1 -name '.y9-stage.*' | wc -l)
  echo "rc01 E(entry_unreadable_qwen): rc=$rE (want !=0) false_nofree=$badE (want 0) perm=$permE (want >=1) kept=$keptE (want 1) stage=$stageE (want 0)"
  [ "$rE" != 0 ] && [ "$badE" = 0 ] && [ "$permE" -ge 1 ] && [ "$keptE" = 1 ] && [ "$stageE" = 0 ] || rc=1
fi

# C: k=1 -> k=2 collision + mode 0600 under umask 0022
mkdir -p "$tmp/hk/.qwen" "$tmp/bin"
printf '#!/bin/sh\necho 20261126T000000Z\n' >"$tmp/bin/date"; chmod +x "$tmp/bin/date"
printf 'old qwen content\n' >"$tmp/hk/.qwen/QWEN.md"
printf 'existing k1\n' >"$tmp/hk/.qwen/QWEN.md.bak-spool-install-20261126T000000Z"
old_sha="$(sha256sum <"$tmp/hk/.qwen/QWEN.md")"
k1_sha="$(sha256sum <"$tmp/hk/.qwen/QWEN.md.bak-spool-install-20261126T000000Z")"
(umask 0022; env HOME="$tmp/hk" PATH="$tmp/bin:$PATH" bash -c 'source "$1" && spool_install_vendor_lane_rule' _ "$y9") >/dev/null 2>&1; rC=$?
k2="$tmp/hk/.qwen/QWEN.md.bak-spool-install-20261126T000000Z-2"
modeC="$(stat -c %a "$k2" 2>/dev/null || echo missing)"
k2_ok=0
[ -f "$k2" ] && [ "$(sha256sum <"$k2")" = "$old_sha" ] && [ "$(sha256sum <"$tmp/hk/.qwen/QWEN.md.bak-spool-install-20261126T000000Z")" = "$k1_sha" ] && k2_ok=1
echo "rc01 C(k1_to_k2_mode600): rc=$rC (want 0) mode=$modeC (want 600) content_ok=$k2_ok (want 1)"
[ "$rC" = 0 ] && [ "$modeC" = 600 ] && [ "$k2_ok" = 1 ] || rc=1

# D: full existing suite still green
bash "$tst" >"$tmp/tst.out" 2>&1; rD=$?
echo "rc01 D(suite): rc=$rD (want 0) [$(tail -n 1 "$tmp/tst.out")]"
[ "$rD" = 0 ] || rc=1

echo "rc01 exit $rc"
exit "$rc"
```

Output on `bf585dc99` (sat, `12:45Z`):

| run | output |
|---|---|
| `bash rc01-b51.sh bf585dc99` | `rc01 sites: entry=1 backup=1` / `rc01 A(helper_enoent): rc=1 false_nofree=1 (want 0) [... no free backup name ...]` / `rc01 B(helper_readonly_dir): rc=1 false_nofree=1 (want 0) [... no free backup name ...]` / `rc01 E(entry_unreadable_qwen): rc=1 false_nofree=1 (want 0) perm=1 kept=1 stage=0` / `rc01 C(k1_to_k2_mode600): rc=0 mode=600 content_ok=1` / `rc01 D(suite): rc=0 [== y9 agy + qwen fleet rules: 20/20 passed]` / `rc01 exit 1` |
| `bash rc01-b51.sh bf585dc99 fix-shape` | `rc01 sites: entry=1 backup=1` / `rc01 fix-shape: python3 O_EXCL 0o600 backup catching FileExistsError only, failing fast on other OSError` / `rc01 A(helper_enoent): rc=1 false_nofree=0 [... backup failed: [Errno 2] No such file or directory ...]` / `rc01 B(helper_readonly_dir): rc=1 false_nofree=0 [... backup failed: [Errno 13] Permission denied ...]` / `rc01 E(entry_unreadable_qwen): rc=1 false_nofree=0 perm=2 kept=1 stage=0` / `rc01 C(k1_to_k2_mode600): rc=0 mode=600 content_ok=1` / `rc01 D(suite): rc=0 [== y9 agy + qwen fleet rules: 20/20 passed]` / `rc01 exit 0` |

### 4.2 `rc02-b51.sh` (b51-02, kept byte-identical from v0.1), sha256 first 12 hex `4d2fb494754c`, 6087 B

Run from any checkout: `bash rc02-b51.sh bf585dc99` (exit 1), then `bash rc02-b51.sh bf585dc99 fix-shape` (exit 0). Self-contained (zero box paths).

```bash
#!/usr/bin/env bash
# rc02-b51.sh <sha> [fix-shape]: b51-02 red control. On <sha>'s tree,
# csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh:279-284,336-340,421-425
# stages its 3 red-control copies in flat $T/red/ with only a bare copy of
# spl-lane-map.func.sh, breaking spl-lane-map.func.sh:72,74 relative `source`
# lines (6 missing-file stderr errors on every run). Worse, section 8 (:423-425)
# never checks $rc or that CPUQuota=1280% was written, so a crashing section-8
# mutant that writes nothing to $SYSD_LOG still passes vacuously.
# Extracts csi-spl-orc from <sha> into a mktemp dir. Self-contained (no box paths).
set -uo pipefail
sha="${1:?usage: rc02-b51.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc/lib/bash/funcs csi-spl-orc/src/bash/run csi-spl-orc/src/bash/scripts csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh | tar -x -C "$tmp"
tst="$tmp/csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh"
fn="$tmp/csi-spl-orc/src/bash/run/apply-gh-runner-cpu-budget.func.sh"
a=$(grep -c '^run_budget()' "$tst")
b=$(grep -c '^ov()' "$tst")
c=$(grep -c '^do_apply_gh_runner_cpu_budget()' "$fn")
echo "rc02 sites: run_budget=$a ov=$b action=$c"
[ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] || { echo "rc02 sites moved"; exit 2; }

if [ "${2:-}" = fix-shape ]; then
  python3 - "$tst" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
o1 = '''mkdir -p "$T/red"; cp "$(dirname "$FUNC")/spl-lane-map.func.sh" "$T/red/"
sed 's/((floor > GHRB_MIN)) \\&\\& GHRB_MIN="$floor"/:/' "$FUNC" >"$T/red/apply-gh-runner-cpu-budget.func.sh"
grep -q 'GHRB_MIN="$floor"' "$T/red/apply-gh-runner-cpu-budget.func.sh" && fail "red control: the sed did not drop the raise"
out="$(FUNC="$T/red/apply-gh-runner-cpu-budget.func.sh" gate CPU_BUDGET_GATE_FLOOR_PCT=500)"; rc=$?'''
n1 = '''RED_RUN="$T/red/src/bash/run"
mkdir -p "$RED_RUN"
ln -s "$PROJ_ROOT/lib" "$T/red/lib"
for sib_f in "$PROJ_ROOT"/src/bash/run/*.func.sh; do
  [[ "$(basename "$sib_f")" == "$(basename "$FUNC")" ]] && continue
  ln -s "$sib_f" "$RED_RUN/$(basename "$sib_f")"
done
RED_FUNC="$RED_RUN/$(basename "$FUNC")"
cp "$FUNC" "$RED_FUNC"
out="$(FUNC="$RED_FUNC" gate CPU_BUDGET_GATE_FLOOR_PCT=500)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=500%'* ]] &&
  pass "red control: unmodified copy in staged tree reaches 500%" || fail "red control: unmodified staged copy failed (rc=$rc): $out"
sed 's/((floor > GHRB_MIN)) \\&\\& GHRB_MIN="$floor"/:/' "$FUNC" >"$RED_FUNC"
grep -q 'GHRB_MIN="$floor"' "$RED_FUNC" && fail "red control: the sed did not drop the raise"
out="$(FUNC="$RED_FUNC" gate CPU_BUDGET_GATE_FLOOR_PCT=500)"; rc=$?'''

o2 = '''sed 's/((floor > GHRB_MIN)) \\&\\& GHRB_MIN="$floor"$/:/' "$FUNC" >"$T/red/apply-gh-runner-cpu-budget.func.sh"
[[ "$(grep -c 'GHRB_MIN="$floor"' "$T/red/apply-gh-runner-cpu-budget.func.sh")" == 0 ]] || fail "red control: the sed did not drop the reserve raise"
out="$(FUNC="$T/red/apply-gh-runner-cpu-budget.func.sh" ci "${R[@]}")"; rc=$?'''
n2 = '''sed 's/((floor > GHRB_MIN)) \\&\\& GHRB_MIN="$floor"$/:/' "$FUNC" >"$RED_FUNC"
[[ "$(grep -c 'GHRB_MIN="$floor"' "$RED_FUNC")" == 0 ]] || fail "red control: the sed did not drop the reserve raise"
out="$(FUNC="$RED_FUNC" ci "${R[@]}")"; rc=$?'''

o3 = '''sed 's/    if (cap > 0 \\&\\& q > cap) q = cap/    cap = 0/' "$FUNC" >"$T/red/apply-gh-runner-cpu-budget.func.sh"
grep -q 'q > cap' "$T/red/apply-gh-runner-cpu-budget.func.sh" && fail "red control: the sed did not drop the clamp"
out="$(FUNC="$T/red/apply-gh-runner-cpu-budget.func.sh" ov OTHER=0)"; rc=$?
[[ "$(cat "$SYSD_LOG")" != *'CPUQuota=400%'* ]] &&
  pass "red control: a copy without the cap clamp does not set 400% (the first check catches it)" || fail "red control: the broken copy still set 400%"'''
n3 = '''sed 's/    if (cap > 0 \\&\\& q > cap) q = cap/    cap = 0/' "$FUNC" >"$RED_FUNC"
grep -q 'q > cap' "$RED_FUNC" && fail "red control: the sed did not drop the clamp"
out="$(FUNC="$RED_FUNC" ov OTHER=0)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=1280%'* && "$(cat "$SYSD_LOG")" != *'CPUQuota=400%'* ]] &&
  pass "red control: a copy without the cap clamp sets 1280%, not 400% (the first check catches it)" || fail "red control: the broken copy did not run cleanly to 1280% (rc=$rc): $(cat "$SYSD_LOG")"'''

for lbl, o, n in [("sec6", o1, n1), ("sec7", o2, n2), ("sec8", o3, n3)]:
    assert s.count(o) == 1, f"{lbl} count={s.count(o)}"
    s = s.replace(o, n, 1)
open(p, "w").write(s)
PY
  echo "rc02 fix-shape: stage red controls in mirrored relative tree + assert unmodified passes + assert sec 8 rc=0 and CPUQuota=1280%"
fi

rc=0
# A: run unmodified test -> must exit 0 with ZERO missing-file/command-not-found stderr lines
bash "$tst" >"$tmp/a.out" 2>"$tmp/a.err"; rA=$?
errsA=$(grep -cE 'No such file or directory|command not found' "$tmp/a.err" || true)
echo "rc02 A(clean_run): rc=$rA (want 0) stderr_source_errs=$errsA (want 0)"
[ "$rA" = 0 ] && [ "$errsA" = 0 ] || rc=1

# B: crashing section-8 mutant (returns 1 before writing $SYSD_LOG whenever `cap = 0` appears) ->
# a non-vacuous section 8 red control MUST fail (rc!=0), not silently pass on empty $SYSD_LOG
cp -a "$tmp/csi-spl-orc" "$tmp/mut-orc"
mfn="$tmp/mut-orc/src/bash/run/apply-gh-runner-cpu-budget.func.sh"
mtst="$tmp/mut-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh"
python3 - "$mfn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
needle = "do_apply_gh_runner_cpu_budget() {\n"
inject = "do_apply_gh_runner_cpu_budget() {\n  grep -q '    cap = '\"\"'0' \"${BASH_SOURCE[0]}\" && return 1\n"
assert s.count(needle) == 1, f"needle count={s.count(needle)}"
open(p, "w").write(s.replace(needle, inject, 1))
PY
bash "$mtst" >"$tmp/b.out" 2>"$tmp/b.err"; rB=$?
echo "rc02 B(non_vacuous_sec8): rc=$rB (want !=0)"
[ "$rB" != 0 ] || rc=1

echo "rc02 exit $rc"
exit "$rc"
```

Output on `bf585dc99` (sat, `12:12Z..12:13Z`; confirmed by panel `c-052@sat` on v0.1 `366b5b8ef`):

| run | output |
|---|---|
| `bash rc02-b51.sh bf585dc99` | `rc02 sites: run_budget=1 ov=1 action=1` / `rc02 A(clean_run): rc=0 (want 0) stderr_source_errs=6 (want 0)` / `rc02 B(non_vacuous_sec8): rc=0 (want !=0)` / `rc02 exit 1` |
| `bash rc02-b51.sh bf585dc99 fix-shape` | `rc02 sites: run_budget=1 ov=1 action=1` / `rc02 fix-shape: stage red controls in mirrored relative tree + assert unmodified passes + assert sec 8 rc=0 and CPUQuota=1280%` / `rc02 A(clean_run): rc=0 (want 0) stderr_source_errs=0 (want 0)` / `rc02 B(non_vacuous_sec8): rc=1 (want !=0)` / `rc02 exit 0` |

### 4.3 `rc03-b51.sh` (b51-03, kept byte-identical from v0.1), sha256 first 12 hex `a977907ee08f`, 3595 B

Run from any checkout: `bash rc03-b51.sh bf585dc99` (exit 1), then `bash rc03-b51.sh bf585dc99 fix-shape` (exit 0). Under 3 s each. Self-contained (zero box paths).

```bash
#!/usr/bin/env bash
# rc03-b51.sh <sha> [fix-shape]: b51-03 red control (c-902 N5 + action twins).
# On <sha>'s tree, _spl_review_go_owner_go (csi-spl-orc/src/bash/run/spl-review-go.func.sh:803)
# lists `do-provision|do-tf-apply` (make targets) in `fixed`, omitting `do_spl_desk_up`
# (DEPLOY-GATE (e) forbidden action, already in _spl_review_go_instr CMD at :755) as well
# as `do_provision` and `do_tf_apply` (`./run -a` action names; SPL-5798 excludes `_`-joined
# `apply`). A brief naming any of those in `## Do` without ENV=prd / DRY_RUN=0 / bare apply
# returns rc 0 (GO) instead of rc 1 (HOLD).
# Extracts spl-review-go.func.sh from <sha> into a mktemp dir. Self-contained (no box paths).
set -uo pipefail
sha="${1:?usage: rc03-b51.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc/src/bash/run/spl-review-go.func.sh | tar -x -C "$tmp"
fn="$tmp/csi-spl-orc/src/bash/run/spl-review-go.func.sh"
a=$(grep -c '^_spl_review_go_instr()' "$fn")
b=$(grep -c '^_spl_review_go_owner_go()' "$fn")
echo "rc03 sites: instr=$a owner_go=$b"
[ "$a" = 1 ] && [ "$b" = 1 ] || { echo "rc03 sites moved"; exit 2; }

if [ "${2:-}" = fix-shape ]; then
  python3 - "$fn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = "  local fixed='do-provision|do-tf-apply|PROBE_PRD_GO|DRY_RUN=0|ENV=prd|service account key|/etc/'\n"
new = "  local fixed='do-provision|do_provision|do-tf-apply|do_tf_apply|do_spl_desk_up|PROBE_PRD_GO|DRY_RUN=0|ENV=prd|service account key|/etc/'\n"
assert s.count(old) == 1, f"old count={s.count(old)}"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "rc03 fix-shape: add do_provision, do_tf_apply, do_spl_desk_up to _spl_review_go_owner_go fixed list"
fi

run_og() {
  local f="$tmp/brief.md"
  printf '%s\n' "$1" >"$f"
  env SPOOL_ROOT="$tmp/spool" bash -c '
    set -uo pipefail
    source "$1"
    _spl_review_go_owner_go "$2" c-002' _ "$fn" "$f" 2>&1
}

rc=0
check_case() {
  local lbl="$1" want="$2" body="$3" out r
  out="$(run_og "$body")"; r=$?
  echo "rc03 $lbl: rc=$r (want $want)${out:+ [$out]}"
  [ "$r" = "$want" ] || rc=1
}

# RED 1..5: owner-go actions omitted from fixed list MUST hold (rc 1)
check_case "red_desk_up" 1 $'## Do\n1. Run `cd csi-spl-orc && ./run -a do_spl_desk_up`.'
check_case "red_desk_up_all" 1 $'## Do\n1. Run `./run -a do_spl_desk_up_all`.'
check_case "red_do_provision" 1 $'## Do\n1. Run `cd csi-spl-iac && ./run -a do_provision`.'
check_case "red_do_tf_apply" 1 $'## Do\n1. Run `cd csi-spl-iac && ./run -a do_tf_apply`.'
check_case "red_do_tf_apply_target" 1 $'## Do\n1. Run `cd csi-spl-iac && ./run -a do_tf_apply_target`.'

# CONTROLS 1..6: Never / Why / fenced stay rc 0; hyphenated twins stay rc 1; b50-01 stays rc 0
check_case "ctrl_never" 0 $'## Never\nNever run do_spl_desk_up, do_provision, or do_tf_apply.\n## Do\n1. Fix the unit test.'
check_case "ctrl_why" 0 $'## Why\nObserved after do_spl_desk_up ran.\n## Do\n1. Fix the log format.'
check_case "ctrl_fenced" 0 $'## Do\n1. Fix the parser.\n```bash\n./run -a do_spl_desk_up\n```'
check_case "ctrl_hyphen_provision" 1 $'## Do\n1. Run `make do-provision`.'
check_case "ctrl_hyphen_tf_apply" 1 $'## Do\n1. Run `make do-tf-apply`.'
check_case "ctrl_b50_r05_01" 0 $'## Do\n2. Apply section 1.3'\''s verbatim hunks to ONLY the row'\''s files.\n4. Run standalone `DRY_RUN=0` install/check/remove lifecycle check.'

echo "rc03 exit $rc"
exit "$rc"
```

Output on `bf585dc99` (sat, `12:10Z`; confirmed by panel `c-052@sat` on v0.1 `366b5b8ef`):

| run | output |
|---|---|
| `bash rc03-b51.sh bf585dc99` | `rc03 sites: instr=1 owner_go=1` / all 5 `red_*` (`red_desk_up`, `red_desk_up_all`, `red_do_provision`, `red_do_tf_apply`, `red_do_tf_apply_target`) `rc=0 (want 1)` / all 6 `ctrl_*` match / `rc03 exit 1` |
| `bash rc03-b51.sh bf585dc99 fix-shape` | `rc03 sites: instr=1 owner_go=1` / `rc03 fix-shape: add do_provision, do_tf_apply, do_spl_desk_up to _spl_review_go_owner_go fixed list` / all 5 `red_*` `rc=1 (want 1)` / all 6 `ctrl_*` match / `rc03 exit 0` |

---

## 5. Rows

| # | id | practice | sites (file:line on `bf585dc99`) | evidence | red control (fails on `bf585dc99`) | test column (R2; R7 must run EVERY entry in `ran:`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b51-01-orc-y9-qwen-backup-os-error-and-tests` | `_y9_qwen_backup` catches only `EEXIST` and fails fast with the real OS error on other `OSError`s; `test-agy-qwen-fleet-rules.sh` pins mode `0600`, `k=1 -> k=2` collision, and entry-level + helper-level non-`EEXIST` failures | `csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh:94-109`; `csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh:78-80,114-127` | `a-909@sat` R7 N1 & N2 (`eaf6e4d6`, b49-02 `460750a35`); `bug-round-50-plan.md` section 7 first input #2; panel `c-052@sat` W1 (`201a73934`); parity vs `y8-vibe-agents.py:52-68`; section 4.1 | `bash rc01-b51.sh bf585dc99` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` | `bash csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh`; `bash csi-spl-orc/src/bash/features/spool-install/tests/test-agy-rules-always-on.sh`; `bash csi-spl-orc/src/bash/features/spool-install/tests/test-vibe-agents.sh`; `bash csi-spl-orc/src/bash/features/spool-install/tests/test-y14-agy-exit-rule.sh`; `bash rc01-b51.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh`; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.1: update `_y9_qwen_backup` to catch only `FileExistsError` (`EEXIST`), fail immediately with real OS error on other `OSError`s (unlinking any partial file on write error), enforce `0600` (`os.umask(0o077)` + `0o600`), keep `date` stamp in bash for test 8, <= 75 lines; in `test-agy-qwen-fleet-rules.sh`, add mode `600` in sec 3, sec 9 (`k=1 -> k=2`), and sec 10 (**entry-level** unreadable `QWEN.md` mode `000` via `y9 "$H"` — RED on `bf585dc99`, proving `Permission denied`, no `no free backup name`, file kept, no `.y9-stage.*` — plus helper-level direct `_y9_qwen_backup` `ENOENT`/`EACCES`); `Docs: none` | sat or `<box2>` (`do_spl_box_pick` claude `12:00Z`: sat 160% / 59% weekly pick, `<box2>` 253% / 58% weekly) | claude | agy (preferred; non-secret-class, `BOX_PICK_KIND=agy` `12:00Z`: sat 160% pick, both `agy weekly unknown`, placed anyway), else claude waiver fallback (`c-001` `77ba5669`, panel N2) | `simple_coding` | 1 |
| 02 | `b51-02-orc-cpu-budget-red-controls-tree` | `apply-gh-runner-cpu-budget.tst.sh` red controls stage in a mirrored relative tree (zero broken `source` stderr errors) and section 8 asserts `rc=0` and `CPUQuota=1280%` | `csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh:279-284,336-340,421-425` | `bug-round-50-plan.md` section 7 first input #3; b50-02 (`86ac09501`) sibling pattern; live run on `bf585dc99` (6 stderr errors + vacuous sec 8); section 4.2 | `bash rc02-b51.sh bf585dc99` -> `rc02 exit 1`; control `fix-shape` -> `rc02 exit 0` | `bash csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh`; `bash csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh`; `bash csi-spl-orc/src/bash/tests/gh-runner-add.tst.sh`; `bash rc02-b51.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh`; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.2: stage `$T/red/src/bash/run` with `$T/red/lib -> $PROJ_ROOT/lib` and symlinked sibling `*.func.sh`; add unmodified positive control in section 6; point sections 6, 7, 8 at `$RED_FUNC`; assert `rc -eq 0` and `CPUQuota=1280%` (not `400%`) in section 8; zero stderr `No such file or directory` / `command not found`; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` `12:00Z`: sat pick) | claude | agy (preferred; non-secret-class), else claude waiver fallback (`c-001` `77ba5669`, panel N2) | `simple_coding` | 1 |
| 03 | `b51-03-orc-review-go-owner-go-actions` | `_spl_review_go_owner_go` `fixed` list holds briefs naming `do_spl_desk_up`, `do_provision`, or `do_tf_apply` (and their prefix families) without `Owner-go:` | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:791-808`; `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (new case 35 after `:1420`) | `c-902@<box2>` N5 (`fc0f6bf6b`); `bug-round-50-plan.md` section 7 first input #1; b50-01 landed `3ce429f73`; 0/500 newest sat author briefs flip; section 4.3 | `bash rc03-b51.sh bf585dc99` -> `rc03 exit 1`; control `fix-shape` -> `rc03 exit 0` | `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`; `bash csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh`; `bash rc03-b51.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x csi-spl-orc/src/bash/run/spl-review-go.func.sh csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `bash csi-spl-iac/src/bash/tests/action-header-tags.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.3: add `do_provision`, `do_tf_apply`, and `do_spl_desk_up` to `fixed` in `_spl_review_go_owner_go` (`:803`), keep comment consistent and function <= 75 lines; add case 35 in `spl-review-go.tst.sh` covering `do_spl_desk_up`, `do_spl_desk_up_all`, `do_provision`, `do_provision_firebase_dns`, `do_tf_apply`, `do_tf_apply_target` holds (panel N5), `Owner-go:` HUM pass, and `## Never`/`## Why`/fenced controls; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` `12:00Z`: sat pick) | claude | agy (preferred; non-secret-class), else claude waiver fallback (`c-001` `77ba5669`, panel N2) | `simple_coding` | 1 |

- **R1 (disjoint files):** all three rows are Batch 1 and share 0 files:
  - b51-01: `csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh`, `csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh`
  - b51-02: `csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh`
  - b51-03: `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`
- **R3** (checked `2026-11-26T12:14:36Z`; re-checked by panel `c-052@sat` at `12:30:51Z`, panel N3): `lane-map.sh --check csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh,csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh,csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh,csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-doc/doc/md/bug-round-51-plan.md --agent a-048` -> **exit 4**: 0 live lanes list these 6 paths, 0 of 275 local worktrees touch a row file (`12:30:51Z`), and 19..20 live lanes on `<box2>` record no files (`unknown:` at `12:14:36Z`: c-029, c-041, c-065, c-068, c-079, c-086, c-146, c-187, c-407, c-416, c-474, c-535, c-728, c-904, c-907, c-927, c-936, c-957, c-965, c-971): **not free until the holder re-runs `--check` at placement**. By `do_spl_lane_map` scopes (`12:01Z` and `12:14Z`), live lanes on sat (`a-927` b50 planner/editor, `a-942` r06 planner/editor, `c-014`/`a-041` r06-01 cron installers [landed `8024dc0b5`], `a-047` spec 150 v2.1, `c-936`/`c-973`/`a-008` spec 186, `a-006` spec 196 R7, `a-934` spec 182 planner, `c-052` b51 panel seat) and `<box2>` (`c-904` s187-s1, `c-907` s196-t1, `c-957`/`c-965` spec 125, `c-065`/`c-068` WUI loops/shortcuts, `c-015` SPL-6573 closing, private workspace seats) touch none of these 5 row files. The queue, `./run -a do_spl_spawn_queue` (`12:13Z`): 9 queued asks (incl. r07 planner `c2348fcc` & panel `617780a1`, feature asks, `03ef6580` WUI multi-file drop), disjoint by slug; r07 has not published a plan yet, so the holder re-checks R3 at night placement.
- **R7 (panel N2):** claude-authored code rows (non-secret-class): prefer **agy** R7 seat (`BOX_PICK_KIND=agy ./run -a do_spl_box_pick` `12:00Z`: both boxes `agy weekly unknown`, placed anyway; pick sat 160%), else claude waiver fallback citing `c-001` `77ba5669`. No grok (c-001 `dc84300a`). No mistral (no review seat since 2026-11-25, and no coding kind). Every test in the row's R2 test column (including `cd csi-spl-iac && ./run -a do_check_pre_push` and `rc0N-b51.sh <fix sha>`) MUST appear in R7's `ran:` (rulebook C4, c-001 `0da5ca10`).
- **Rhythm (1.4) & c-001 ruling `b1141868`:** rows queue once the panel signs and `do_spl_review_line_check` exits 0; rows run at night, never placed ahead of a waiting b50 row (both b50 rows have already landed at `3ce429f73` and `86ac09501`), through the placer load guard.
- **Pushes:** aim 1 per row (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug`.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| Bug round 50 close record (`bug-round-50-plan.md`, SPL-6559) | `a-927@sat` | b50 rows landed (`3ce429f73`, `86ac09501`), close record landed (`68d29f7cd`); stay off. |
| Refactor round 06 (`a-942@sat`, `r06-01` landed `8024dc0b5`, `r06-02` landed `984b6d70d`) and queued refactor round 07 (`c2348fcc`, `617780a1`) | live / queued lanes | owned; stay off. |
| Spec 186 (`c-936@sat`, `c-973@sat`, `a-008@sat`), spec 187 (`c-904@<box2>`), spec 196 (`c-907@<box2>`, `a-006@sat`), spec 125 (`c-957@<box2>`, `c-965@<box2>`), spec 150 (`a-047@sat`), spec 182 (`a-934@sat`), WUI loops/shortcuts (`c-065@<box2>`, `c-068@<box2>`), WUI multi-file drop (`03ef6580`), private workspace seats | live / queued lanes per `do_spl_lane_map` and `do_spl_spawn_queue` | owned; stay off. |
| Release-transfer repo open bug issues (SPL-6361, 6362, 6366) | live lanes on `<box2>` | different repository, not `csi-spl`. |
| The `unknown_token` box (641 prd WARNINGs in 6 h, 418 since W) | the holder, as a box question | carried. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 3 (all Batch 1, R1 disjoint; within rulebook 5.1 cap of 3; holder `c-002@sat` confirmed keeping 3 rows in `ee7d2da1`) |
| inputs re-measured | 10 sources; 23 prd ERROR entries in 6 h (13 since W: 11 ad-hoc Cloud SQL, 2 transient Cloud Run `/v1/ws` 503s); 705 prd WARNING entries in 6 h (401s left out, cap not reached; 460 since W) + 16 h `hours/minutes` read (163 entries: 142 HTTP 200, 20 HTTP 204, 1 HTTP 400 single-minute +232 s clock skew); 9 alert policies (0 incidents); 6 open t1 bug-labelled issues + SPL-6578 (0 `csi-spl` wip/todo/eval outside this round); 100 wf 10 runs (73 success, 21 cancelled, 4 failure, 2 running; **0 failed since W**); 1 failed run since W across all other master workflows (`45792046781` gosec G115 on `4fc040744`, served by `06bce3642`); 11 commits and 6 `review:` lines in `fee404830..bf585dc99` + `c-001`/`c-002`/`c-003` archives + recent R7 reports/outboxes + `automation.log` tail + newest 500 readable author briefs on sat (0/500 flipped on b51-03, re-verified by panel); 0 HUM posts since `00:00:00Z`; round 50's first inputs; holder's candidate list (151 lines on sat) + holder note `b4952880`; `rc01-b51.sh` v0.2 (`d017001e49be`, 7133 B), `rc02-b51.sh` (`4d2fb494754c`, 6087 B, unchanged from v0.1), and `rc03-b51.sh` (`a977907ee08f`, 3595 B, unchanged from v0.1) n=1 each way on `bf585dc99` (`shellcheck -S warning` rc 0); baselines `test-agy-qwen-fleet-rules.sh` (`20/20`), `test-agy-rules-always-on.sh` (`18/18`), `test-vibe-agents.sh` (`24/24`), `test-y14-agy-exit-rule.sh` (`12/12`), `apply-gh-runner-cpu-budget.tst.sh` (`all passed`, with 6 stderr source errors), `setup-gh-runner-cpu-budget-cron.tst.sh` (`all passed`), `gh-runner-add.tst.sh` (`0 failure(s)`), `spl-accepted-close.tst.sh` (`0 failure(s)`), `spl-review-go.tst.sh` (`0 failure(s)`, panel run), `bash-cleancode.tst.sh` (`all assertions`), `action-header-tags.tst.sh` (`ALL PASS`) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b51-'` -> 0 (also 0 under moved `W=68d29f7cd`, panel N1); `git ls-remote origin 'refs/heads/review/b51-*' 'refs/heads/wip/*b51*' 'refs/heads/*-b51-*' 'refs/heads/*bug-round-51*'` -> nothing (rc 0); briefs on sat matching `*b51*` / `*bug-round-51*`: only `hand-sat-c002-bug-round-51-planner.md` and `c002-bug-round-51-claude-panel-seat.md` (`11:58Z`; confirmed by panel `c-052@sat`) |
| R7 seat | agy preferred (non-secret-class; `BOX_PICK_KIND=agy` `12:00Z`: sat 160% pick, both boxes `agy weekly unknown`, placed anyway), else claude waiver fallback (`c-001` `77ba5669`, panel N2) |
| first inputs for round 52 | `review-go` `DRY_RUN=0` false HOLD on `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` (`c-002@sat` `b4952880`, `c-001` `00b12ff3` rc 4 on s196 T1, cleared `46d6c721`, analysis `c-001` `c98d5412`; fix shape: exempt `DRY_RUN=0` only when its action is `do_rdb_migration_next`, fail-closed); `a-767` N2 (`spool-agent-hook.sh:807-813` stale `stop_denies` on tool-before-Stop) and `a-823` N2 (`PreInvocation` in `EVENTS` at `:139-140`, now unblocked after SPL-6517 landed); `a-769` N1 (`check-pre-push-lint.func.sh:618-643` `_ppl_run_timed` returns 124 instead of 137 on SIGKILLed group) & N2 (`tenant-host-reserve.tst.sh` symlink control); `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`, unblocked after SPL-6438); `a-995` N1 (`internal/taskcron/cron_test.go:209-229` malformed step tokens `*/`, `*/1/2`, `*/99999` in `TestRefusals`); `a-790` N1 (`internal/mcp/mcp_test.go:560-563` control ambient env); `a-911` N2 (`customer-box-role-set.tst.sh:160-165` `d6` explicit `rc != 0`); hours-minutes whole-batch 400 follow-up (1 single-minute +232 s skew sighting at `10:28:07Z`); `c-708` N1 (`BoxTaskEnvelopes` box-scoped probe); `a-683` N3 (non-`AgentsCommand` / embed / `channel_box_pins` posts in `hum\|`); `a-490` N1 (`TestCategoryTestPathsZZIsolated` regex at `categories_test.go:388`); `a-480` N1 (`syncWriter.Reset`); `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget`; `unknown_token` box; hub dir mode; hermetic 2/4 timeout; composed testids; `i18n-lang-review-exempt.json:2`; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` as carried |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** a-048@sat (agy, `specs_and_docs`).
- **Panel:** c-052@sat (claude, cross-vendor; placed on `dispatch-bug-r51`, ask `95e35eea`).
- **Row reviewer (R7):** section 5.
- **Review history:**
  - 2026-11-26 12:26Z: v0.1 `366b5b8ef`, pushed to `review/c002-bug-round-51-planner` (3 rows: b51-01, b51-02, b51-03; on `bf585dc99`). Sent to `c-052@sat` (`6631177a`) and holder `c-002@sat` (`5bdfe522`) on task `dispatch-bug-r51`.
  - 2026-11-26 12:44Z: panel `c-052@sat` (claude) **FAIL** on v0.1 `366b5b8ef` (msg `492c7188`; seat file `csi-spl-doc/doc/md/bug-round-51/seat-claude.md` on `review/c002-bug-round-51-claude-seat` `201a73934`; holder send-back `ee7d2da1`). Verified slug proof, 0 drift on `bf585dc99`, every cited line, all 3 rc hashes/sizes/red-green, 0/500 author briefs flipped on b51-03, baseline suites (`test-agy-qwen-fleet-rules`, `spl-accepted-close`, `spl-review-go`), and `do_check_dist_hygiene`; confirmed b51-02 and b51-03 ready as written. Findings: **W1** (b51-01: through `spool_install_vendor_lane_rule` -> `_y9_qwen`, read-only `~/.qwen` fails earlier at `mktemp -d` and missing `QWEN.md` skips backup; the reachable entry-level defect is an unreadable `QWEN.md` mode `000` — probe P2; correct 3.1, add entry-level case to `rc01-b51.sh` and test section 10, label Cases A/B helper-level); **N1** (W moved to b50 close `68d29f7cd`, recorded W `fee404830` stands, b51 free under both); **N2** (drop `1a7c70da` for R7; prefer agy for non-secret-class rows, fallback cites `c-001` `77ba5669`); **N3** (R3 at `12:30:51Z`: exit 4, 19 `<box2>` unknowns, 0/275 local worktrees); **N4** (row count 3 vs aim 2 — holder `ee7d2da1` ruled KEEP 3 rows); **N5** (pin one `do_provision_*` and one `do_spl_desk_up_*` probe in b51-03 case 35).
  - 2026-11-26 12:47Z: v0.2 folds W1 (corrected section 3.1, updated `rc01-b51.sh` to v0.2 `d017001e49be` 7133 B adding entry-level Case E `entry_unreadable_qwen` verified RED on `bf585dc99` / GREEN on `fix-shape` + helper-level labels on Cases A/B, updated test section 10), N1 to N5, and holder round-52 input `b4952880`; `rc02-b51.sh` (`4d2fb494754c`, 6087 B) and `rc03-b51.sh` (`a977907ee08f`, 3595 B) kept byte-identical from v0.1; pushed fast-forward on `366b5b8ef` to `review/c002-bug-round-51-planner` for panel re-review and signature by `c-052@sat`.
