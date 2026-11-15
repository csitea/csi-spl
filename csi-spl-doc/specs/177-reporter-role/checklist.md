# Reporter Checklist

Initial content of the workspace `t1` Qto document **Reporter Checklist** (Spec 177, issue `SPL-5533`, epic `SPL-2129`). Do not import into `prd` until build rows `B1..B8` land and the dispatch/orchestrator role seat runs the post-deploy operator cutover with the owner's GO (Spec 177 Section 8.2).

## 1. Shared Rules for Every Round

1. **Truth first**: Verify every check for this slot empirically from `$ROUND_DIR/facts.json` (pre-collected before your session started by box-user `do_spl_reporter_gather`) before writing a single line of the report. If a check could not run (`status: "error"` or `"not_run"` in `facts.json`), state `NOT RUN (<reason>)` explicitly — never omit it silently and never guess green.
2. **Independence**: You were started directly by the `sat` box cron (`0,30 * * * *`), not by an orchestrator or dispatcher. Never wait on `c-001`, `c-002`, or `c-003` to publish your report. If the orchestrator or dispatch lease is stuck, your job is to surface that directly in `t1` `#reports` with a poll/action for the owner to unstick it.
3. **One new topic per round in `t1` `#reports`** (owner decision, poll `f85b65de`): Post through `REPORTER_CMD=post` -> `do_spl_desk_post` (`DESK_CHANNEL=reports`) as this round's seated Reporter desk identity on `sat`. Never reply inside an older report topic.
4. **Hot first, top-to-bottom priority order (`P1` -> `P5`)** (owner `21:50:45Z`, `21:51:15Z`):
   - Lead with a one-line round header (`UTC` timestamp per `csi-spl-doc/doc/help/how-to-post.md` section 4, slot `:00` or `:30`, active vendor, boxes & envs reached).
   - Group **Hot items requiring owner input or attention** at the top, ordered strictly `P1` (highest) down to `P5` (lowest), breaking ties by age (oldest waiting first).
   - Every item carries `[P1]`..`[P5]`, a one-line factual summary, its age/metric, and clickable WUI deep links (`topic:<uuid>` or `https://<ws-host>/t/<uuid>`, `SPL-<n>`, `/monitoring/lanes?lane=<id@box>`, `msg:<uuid>`, or `[<title>, <YYYY-MM-DD>](https://<ws-host>/calendar?d=<YYYY-MM-DD>&event=<uuid>)`) so the owner can jump out to act and return to the next line.
   - Quiet checks (green / zero items) collapse into a single compact footer line naming the checks verified green — never pad the top of the report with healthy boilerplate.
5. **Data rule (`agy` and `codex` read `facts.json` only)**:
   - Box-user `do_spl_reporter_gather` already ran all hub, DB, and GCP checks and stripped **all human/customer message bodies across every workspace** (not only `spool_enc` workspaces) plus all GCP SA keys, `client_email` values, and filesystem paths before writing `facts.json`.
   - When this round runs on **`agy` or `codex`**, read **only** `facts.json` and `checklist-active.md`, and run only `REPORTER_CMD=post|checklist-update|daily-notes|done` — **never** run `do_spl_unanswered_sweep`, `do_gcp_list_alert_incidents`, `psql`, or `gcloud` directly.
   - Live drill-down commands that inspect non-`spool_enc` topic text are permitted on **`claude`, `grok`, and `mistral` rounds only**, and even then never print secrets, key paths, or `spool_enc` customer text into panes, logs, Qto edits, or `#reports`.
6. **End-of-round Qto iteration and exit**: After posting the `#reports` topic, review the **Iteration Notes** section of this Qto document (`REPORTER_CMD=checklist-update` -> `do_spl_desk_doctree`), record any threshold adjustment, new recurring failure signature, or false-positive note under section 5 (preserving sections 1–4 intact), and exit cleanly via `REPORTER_CMD=done` without waiting for `ACCEPTED`.

---

## 2. Full-Hour Checklist (`:00` UTC)

Run every item below on `:00` rounds (reading `facts.json`; direct drill-down commands below apply only as noted under Rule 1.5). Order all findings into one `P1..P5` list before posting.

### 2.1 Stuck or Silent Orchestrator and Dispatch Lease

- **What to check**:
  1. Fleet dispatch lease (`$SPOOL_ROOT/dispatch/lease`) and orch lease (`$SPOOL_ROOT/dispatch/lease.orch`) holder identity, renewal age (`> LEASE_STALE` = `180 s` is stale), renew/watch lock liveness, and unread inbox depth (`> 20` non-rotation messages).
  2. Dispatcher & orchestrator process liveness across fleet boxes (`SPOOL_AGENT_ID` live process, channel subscriptions, last rotation age `<= 10800 s`).
  3. Open `fleet_asks` to `orchestrator` that have been `open` without `ack` past `ASK_UNACKED_WARN` (`15 min`) or `acked` without progress.
- **Existing actions / queries on `origin/master`** (collected in `facts.json.leases_and_asks`):
  - `cd csi-spl-orc && LEASE_CMD=show ./run -a do_spl_dispatch_lease` (`csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh`)
  - `cd csi-spl-orc && ENV=prd ./run -a do_spl_dispatch_check` (`csi-spl-orc/src/bash/run/spl-dispatch-check.func.sh`, executed inside box-user `do_spl_reporter_gather`)
  - `cd csi-spl-orc && ASKS_FORMAT=json ./run -a do_spl_asks_open` (`csi-spl-orc/src/bash/run/spl-asks-open.func.sh`)
  - Cross-box orchestrator pane/liveness read from `sat` without SSHing raw panes: partial via `lane-map.sh` (`GET /v1/operator/fleet-lanes` + role rows); **dedicated cross-box orch/dispatch health roll-up JSON action: `no action yet`** (planned in Spec 177 row `B4`: `do_spl_reporter_gather`).
- **Default priority**: `P1` when `lease` or `lease.orch` is missing/expired (`> 180 s`) or holder process is dead; `P2` when unread backlog `> 20` or unacked asks `> 15 min`.
- **Owner unstick prompt**: When `P1`, include a single valid ```` ```poll ```` block in the `#reports` post (validated by `spl_desk_poll_check`) offering `(A) Rotate / restart stuck lease holder`, `(B) Fail over lease to standby box`, `(C) Hold — owner inspecting manually`, and set `DESK_KIND=blocker` only when human intervention is required to restore dispatching.

### 2.2 Stuck Lanes, Failed Launches, and Unplaced Spawn Queue

- **What to check**:
  1. **Silent / stuck active lanes**: Any non-standing lane (`004..999`, excluding owner-pane seats) with no commit, no spool message, and no heartbeat/token movement for `>= 15 min` (`GC_SILENT_AGE=900`), or alive past rotation cap without progress.
  2. **Failed launches / DOA windows**: Spawn attempts that exited or hit an S2 `limit` / `auth` / `trust prompt` dialog on start (`start-check.inc.sh`), or asks stuck in `placing` / repeated failed tries in the lane-mix tries journal (`attempts.tsv`).
  3. **Queued asks not placed**: Rows in `do_spl_spawn_queue` waiting `>= 20 min` (`wait_s >= 1200`), especially `P1`/`P2` topics or fleet-stopped holds (`fleet-stopped-alarm`).
- **Existing actions / queries on `origin/master`** (collected in `facts.json.lanes_and_queue`):
  - `bash csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh` / `do_spl_lane_map` (`csi-spl-orc/src/bash/run/spl-lane-map.func.sh`, reads `GET /v1/operator/fleet-lanes`)
  - `cd csi-spl-orc && GC_CMD=scan ./run -a do_spl_gc` (`csi-spl-orc/src/bash/run/spl-gc.func.sh` — local box `sat` only)
  - `cd csi-spl-orc && SPAWN_QUEUE_FORMAT=json ./run -a do_spl_spawn_queue` (`csi-spl-orc/src/bash/run/spl-spawn-queue.func.sh`)
  - `cd csi-spl-orc && ./run -a do_spl_spawn_share` (`csi-spl-orc/src/bash/run/spl-spawn-share.func.sh`)
  - Fleet-wide failed-launch counter across all boxes (aggregating remote `spawn-place` / `start-check` failures onto `sat`): **`no action yet`** (local box logs exist; cross-box failed-launch summary added in Spec 177 row `B4`).
- **Priority linking**: Inherit the lane's `prio` (`hub/fleet_lanes_view.go:351` `lanePrio`, highest priority `1..5` among linked issues via `0194_issue_discussions.sql`), else its discussion's `topic_priorities.priority` (`1..5`, Spec 177 row `B3`), else `P3`. Link `/monitoring/lanes?lane=<id@box>`, linked `SPL-<n>`, and `topic:<uuid>`.

### 2.3 Owner Questions Waiting (Blockers and Unanswered Polls)

- **What to check**:
  1. Open issues carrying label `needs-owner` (`status` in `eval,todo,wip,blocked,onhold,qas`), with wait age since `**Needs owner** since <UTC>`.
  2. Open human-facing `DESK_KIND=blocker` messages and unanswered ```` ```poll ```` forms posted by agents across active workspace topics where the owner (`HUM-10`) has not yet voted or replied.
- **Existing actions / queries on `origin/master`** (collected in `facts.json.owner_waiting`):
  - `cd csi-spl-orc && ./run -a do_spl_issue_needs_owner` / `spl_owner_digest_render` logic (`csi-spl-orc/src/bash/run/spl-owner-digest-post.func.sh`, executed inside box-user `do_spl_reporter_gather`)
  - Standalone body-free query listing unanswered ```` ```poll ```` posts and open `kind=blocker` channel posts with their topic priorities and deep links (`msg:<uuid>`): **`no action yet`** (`spl-desk-poll-ack.func.sh` acknowledges answered polls; an unanswered-poll & open-blocker metadata endpoint `GET /v1/operator/reporter/status` is added in Spec 177 row `B4`).
- **Priority linking**: Inherit `min(issue.priority, topic.priority)` (`1..5`, unset topic = `3`); an explicit `DESK_KIND=blocker` waiting on the owner defaults to at least `P2` unless its topic/issue is `P1`. Link `msg:<poll_or_blocker_msg_id>`, `topic:<task_id>`, and `SPL-<n>`.

### 2.4 Unanswered Human Posts Across Workspaces

- **What to check**:
  - Topics in any non-test workspace whose last effective message is a human post older than `SWEEP_MIN_AGE=15` minutes (excluding `note_to_self`, `ack`, `to-human`, archived topics/channels, and `taken` within grace), plus any `"Reached nobody"` null-channel posts.
- **Existing actions / queries on `origin/master`** (collected in `facts.json.unanswered_posts`):
  - Box-user `do_spl_reporter_gather` runs `SWEEP_FORMAT=metadata-json` on `do_spl_unanswered_sweep` (`csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh`; hub store counterpart `UnansweredPosts` in `csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go:114-130`), **dropping all message bodies across every workspace** before writing `facts.json`.
  - Direct drill-down (`cd csi-spl-orc && ENV=prd DELIVER=0 ./run -a do_spl_unanswered_sweep`, which prints `body[:120]` on non-`spool_enc` workspaces): **`claude` / `grok` / `mistral` rounds only — NEVER run directly in an `agy` or `codex` session (Data Rule 1.5)**.
  - Exposing `topic_priorities.priority` and body-free `SWEEP_FORMAT=metadata-json` on `do_spl_unanswered_sweep`: **`no action yet`** on `origin/master` (store `UnansweredPosts` already orders by `coalesce(tp.priority, $5)` at `:130`; Spec 177 row `B3` adds both to `spl-unanswered-sweep.func.sh`).
- **Priority linking**: Topic's `topic_priorities.priority` (`1..5`, unset = `P3`; owner prio-word posts are already `P1` via `hub/owner_prio_word.go`). Link `https://<ws-host>/m/<msg_id>` and `https://<ws-host>/t/<task_id>` (metadata only — never quote customer message bodies).

### 2.5 CI Red on `master` and Stuck CI Runs

- **What to check**:
  - Failed, timed-out, or `runner-lost` jobs on `master` across `10_ci-quality.yml`, `20_hub-build-deploy.yml`, `30_wui-build-deploy.yml`, `45_db-backup.yml`, and security scanner workflows (`61..67`, `85`), plus any workflow run stuck in progress past threshold (`do_check_ci_gate_stuck`) and jobs over 75% timeout headroom (`AT RISK`).
- **Existing actions / queries on `origin/master`** (collected in `facts.json.ci_gate`):
  - `cd csi-spl-iac && CI_GATE_RUNS=20 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (`csi-spl-iac/src/bash/run/report-ci-gate.func.sh`)
  - `cd csi-spl-iac && ./run -a do_check_ci_gate_stuck` (`csi-spl-iac/src/bash/run/check-ci-gate-stuck.func.sh`)
  - `csi-spl-orc/src/bash/scripts/ci-red-note-cron.sh` / `csi-spl-iac/src/bash/run/report-ci-red-note.func.sh` (`do_report_ci_red_note`)
- **Priority linking**: If a filed open CI-red issue exists (`SPL-<n>`), inherit `min(issue.priority, P1)` (`bug`/`alert` issues default to `P1`); an unfiled red `master` gate or broken deploy workflow (`20`/`30`) is `P1`; a timeout-headroom `AT RISK` warning with green `master` is `P3`. Link the GitHub Actions run URL, offending commit, and `SPL-<n>`.

### 2.6 Deploy Lag (`dev` and `prd`) and Release Notes Lag

- **What to check**:
  - Whether `dev` and `prd` Hub (`/version`) and WUI (`/build.json`) serve `origin/master` within `GRACE_MINUTES=45`, whether `dev -> prd` environment order holds, whether recent deploy workflows failed, and whether any `master` commit lacks its release note past the alarm limit.
- **Existing actions / queries on `origin/master`** (collected in `facts.json.deploy_lag`):
  - `cd csi-spl-orc && ENV=dev ./run -a do_check_deploy_lag` (`csi-spl-orc/src/bash/run/check-deploy-lag.func.sh`)
  - `cd csi-spl-orc && ENV=prd ./run -a do_check_deploy_lag` (`csi-spl-orc/src/bash/run/check-deploy-lag.func.sh`)
  - `cd csi-spl-orc && ./run -a do_spl_deploy_failure_poll` (`csi-spl-orc/src/bash/run/spl-deploy-failure-poll.func.sh`)
  - `cd csi-spl-orc && ./run -a do_spl_release_notes_lag_alarm` (`csi-spl-orc/src/bash/run/spl-release-notes-lag-alarm.func.sh`)
- **Priority linking**: `prd` `lagging` (exit 3) or failed `prd` deploy = `P1`; `dev` `lagging` = `P2`; release-note lag = `P3` (or linked issue's priority if higher). Link the unserved commit range and `/releases` or workflow URL.

### 2.7 Vendor Quota, Weekly Limits, and Login Markers

- **What to check**:
  - Fleet-wide `agent_kinds_off` and `agent_kinds_paused` (with `until`, `reason`, `box`), per-box weekly quota percentages (`>= 85%` warn, `>= 90%/95%/99%` alert, conflicting readings via `spl_box_quota_disagree`), and missing/expired vendor CLI auth markers (`agent-login-check`).
- **Existing actions / queries on `origin/master`** (collected in `facts.json.quotas`):
  - `spool fleet-load get` / `GET /v1/operator/fleet-load` (`csi-spl-api/src/go/spool-hub-api/internal/store/fleet_load.go`, `do_spl_hub_agent_kinds`)
  - `cd csi-spl-orc && DRY_RUN=1 ./run -a do_spl_weekly_limit_alert` (`csi-spl-orc/src/bash/run/spl-weekly-limit-alert.func.sh`, reads local box; cross-box quota readings come from hub `fleet-load` pauses + `#alerts` posts)
  - `csi-spl-orc/src/bash/scripts/agent-login-check-cron.sh`
  - Single cross-box live weekly-% reader (for vendors below pause threshold on non-`sat` boxes): **`no action yet`** (each box's `do_spl_weekly_limit_alert` reads local `spl_box_quota_here`; Spec 177 row `B4` reads hub `fleet-load` + latest `#alerts` weekly-limit lines).
- **Priority linking**: Primary vendor (`claude` or `agy`) off/paused or `>= 95%` = `P1` if it blocks `orchestration`/`secret` or `>= 2` kinds are paused simultaneously, else `P2`; `85%..94%` or secondary vendor auth marker missing = `P3`. Link `/tenant-settings/fleet-load` and any linked `SPL-<n>`.

### 2.8 Box Health, Disk/Inode Headroom, and Active Alerts

- **What to check**:
  - Disk block headroom (`>= 85%` warn `DISK_HEADROOM_BLOCK_PCT`, `>= 92%` crit `DISK_HEADROOM_CRIT_PCT`) and inode headroom (`>= 80%` warn `DISK_HEADROOM_INODE_PCT`, `>= 90%` crit `SCRATCH_INODE_MIN_FREE_PCT=10`), box heartbeat freshness (`rel-box-beat`), uplink watches (`box-link-watch`, `uplink-probe`), reliability checks (`rel-systemd-unit`, `rel-tmux-health`, `rel-gh-runner`, `rel-cert-expiry`, `rel-clock-sync`, `rel-cron-snitch`, `rel-reboot-required`), GCP alert incidents (`do_gcp_list_alert_incidents`), and new `#alerts` topics / `alert-issue` filings (`do_spl_alert_issue_tick`).
- **Existing actions / queries on `origin/master`** (collected in `facts.json.box_health`):
  - `cd csi-spl-orc && DRY_RUN=1 ./run -a do_check_disk_headroom` (`csi-spl-orc/src/bash/run/check-disk-headroom.func.sh` — local box)
  - `cd csi-spl-utl && ./run -a do_systemd_unit_health`, `do_tmux_health_guard`, `do_gh_runner_health`, `do_external_api_health`, `do_cron_heartbeat_snitch` (`csi-spl-utl/src/bash/run/*.func.sh`)
  - `do_gcp_list_alert_incidents` (`csi-spl-iac/src/bash/run/gcp-list-alert-incidents.func.sh`) — **executed strictly inside box-user `do_spl_reporter_gather` using `$SPOOL_BOX_USER`'s `0600` GCP SA key and scrubbed to incident counts/timestamps in `facts.json`; NEVER run directly by an `agy` or `codex` session (`claude`/`grok`/`mistral` box-user drill-down only, Rule 1.5)**
  - `spool topics --channel alerts` + `$SPOOL_ROOT/dispatch/alert-issue/state.json` (`csi-spl-orc/src/bash/run/spl-alert-issue-tick.func.sh`)
  - Cross-box disk/load summary from `sat`: `GET /v1/operator/boxes` / `lane-map.sh` header (`BOX <id> busy N seats M mem X`); cross-box mount-% field on hub box heartbeat: **`no action yet`** (relies on `#alerts` / `alert-issue` filings from non-`sat` boxes until added).
- **Priority linking**: Inherit filed alert issue priority (`do_spl_alert_issue_tick` files `P1` issues); disk blocks `>= 92%`, inodes `>= 90%`, dead box heartbeat, broken tmux server, or open `prd` GCP incident = `P1`; disk blocks `85%..91%`, inodes `80%..89%`, `reboot-required`, or single runner warning = `P2`–`P3`. Link `/monitoring/boxes`, `#alerts` `topic:<uuid>`, and `SPL-<n>`.

### 2.9 Daily Per-Member Task-List Notes (Once Daily on the Configured Morning `:00` Round)

- **When to run**: Only on the `:00` full-hour round matching `env.reporter.daily_notes_hour_utc` (once per UTC date, idempotent if re-run).
- **What to check & write**:
  - Trigger `REPORTER_CMD=daily-notes` -> `do_spl_reporter_daily_notes` (`POST /v1/operator/reporter/daily-notes` inside the Go hub).
  - For every active human member (`HUM-<n>` with `humans.day_tasks_reminder` `NULL` or `'on'` in `0252_humans_day_tasks_reminder.sql`) of each enabled workspace, the hub reads today's calendar occurrences (using `tenant_memberships.settings->>'time_zone'` in `0078_membership_settings.sql`, where the member is `owner_id`, `creator_id`, in `calendar_events.mentions`, or a human row in `calendar_guests` from `0139_calendar_full_edit.sql`) and open assigned task issues (`type NOT IN ('epic', 'feature')`, `status NOT IN ('done', 'diss')`), reusing Spec 170 `day-tasks.mjs` (`82822fc4b`).
  - The hub writes (or updates for today) one task-list Note per member in `personal.notes` (`0225_personal_notes.sql`, `0254_note_priority.sql`) with checklist rows (`personal.note_items`) and typed links (`personal.note_links`: `kind='event'` with `day` set, `kind='issue'` with `workspace_id` set), ordered top-to-bottom `P1..P5`, returning aggregate counts only.
- **Existing actions / queries on `origin/master`**:
  - Pure task/day-bounds/overdue filter: `csi-spl-wui/src/utils/day-tasks.mjs` (`82822fc4b`, landed).
  - Notes schema & WUI: `csi-spl-rdb/src/sql/postgres/spool-hub/0225_personal_notes.sql`, `0254_note_priority.sql`, `csi-spl-wui/src/components/Note*.vue` (Spec 155 B1–B10 landed).
  - Hub/orc action compiling and writing daily per-member `personal.notes` from calendar + issues: **`no action yet`** (specified in Spec 177 section 6 and build rows `B7`–`B8`).
- **Report line**: Record one `P4` summary line in `#reports` when daily notes were generated (`workspaces`, `members`, `notes written`), or `P2` if any workspace failed.

---

## 3. Half-Hour Checklist (`:30` UTC)

The `:30` round is a fast delta pulse (`<= 3 min` wall budget): read `facts.json` and report what **changed**, **crossed a threshold**, or **newly requires owner input** since the `:00` report, plus any unresolved `P1`/`P2` hot item. Skip heavy signature log downloads and skip daily per-member notes.

1. **Orchestrator & dispatch lease pulse** (`facts.json.leases_and_asks`: `do_spl_dispatch_lease` `LEASE_CMD=show`, `ASKS_FORMAT=json do_spl_asks_open`): Report immediately (`P1`, with unstick ```` ```poll ````) if `lease` or `lease.orch` went stale/dead, or if unacked asks crossed `15 min`.
2. **Newly stuck lanes, failed launches, & P1/P2 queue holds** (`facts.json.lanes_and_queue`: `lane-map.sh`, `GC_CMD=scan do_spl_gc`, `SPAWN_QUEUE_FORMAT=json do_spl_spawn_queue`): Report lanes newly crossing `15 min` silence, any launch failure since `:00`, and `P1`/`P2` asks stuck in queue `>= 15 min`.
3. **Owner blockers & unanswered polls delta** (`facts.json.owner_waiting`: `do_spl_issue_needs_owner` + open poll/blocker metadata query [`no action yet` -> `B4`]): Surface any new `P1`/`P2` blocker or poll posted since `:00`, and keep existing `P1` owner blockers visible at the top with updated wait age.
4. **Unanswered human posts delta** (`facts.json.unanswered_posts`, collected via box-user `SWEEP_FORMAT=metadata-json do_spl_unanswered_sweep` with all message bodies dropped; direct sweep drill-down `claude`/`grok`/`mistral` only): Report newly aged unanswered human topics (`>= 15 min`), ordered by `topic_priorities.priority`.
5. **CI `master` & `prd` deploy-lag fast check** (`facts.json.ci_gate` with `CI_GATE_RUNS=10` without `CI_GATE_SIGNATURES=1` unless a new `master` run failed since `:00`; `ENV=prd do_check_deploy_lag`): Check `master` CI and `prd` deploy lag (`dev` lag waits for `:00` unless `prd` is affected).
6. **Quota pauses, disk/inode crit, & `#alerts` delta** (`facts.json.quotas` & `facts.json.box_health`: `spool fleet-load get`, `DRY_RUN=1 do_check_disk_headroom`, `#alerts` topics since `:00`): Report only newly paused/off vendors, disk blocks `>= 92%` or inodes `>= 90%` (`P1`) / blocks `>= 85%` or inodes `>= 80%` newly crossed (`P2`), or new `P1` `#alerts` topics since `:00`.

---

## 4. Priority Mapping Quick Reference (`P1` Highest -> `P5` Lowest)

| Source Object | Stored / Derived Priority | Fallback When Unset | Required Clickable Link in `#reports` |
|---|---|---|---|
| **Discussion / Topic** | `topic_priorities.priority` (`1..5`, `rdb 0214`; `1` on owner prio word, `SPL-5524`) | `P3` (`store.TopicPriorityDefault`) | `topic:<task_uuid>` or `https://<ws-host>/t/<task_uuid>` |
| **Issue** | `issues.priority` (`1..5`, `rdb 0047/0273`, linked via `0194_issue_discussions.sql` & synced via `SPL-4813`) | `P5` (DB default; `bug`/`alert` created at `P1`) | Bare `SPL-<n>` in `t1`, else `[<KEY>](https://<ws-host>/issues?issue=<KEY>)` |
| **Active Lane** | `lanePrio`: `min(priority)` across linked issues (`hub/fleet_lanes_view.go:351`) | Topic priority (`1..5`), else `P3` | `[<id@box>](https://<t1-host>/monitoring/lanes?lane=<id@box>)` + `SPL-<n>` |
| **Queued Spawn Ask** | `fleet_asks.discussion` -> `topic_priorities.priority` (`store/fleet_ask.go`) | `P3` (`urgent` class escalates to `P1`) | `topic:<discussion_uuid>` + ask 8-hex ID |
| **Human Post / Poll / Blocker** | Enclosing topic's `topic_priorities.priority` (`min` with linked issue if any) | `P2` for open owner `blocker`, else `P3` | `msg:<msg_uuid>` (`https://<ws-host>/m/<msg_uuid>`) |
| **Calendar Event** | `min(issues.priority)` across `issue_keys` (`rdb 0247`) and `topic_id` (`rdb 0125`) | `P3` (`release`/`freeze`/`deploy` `P2` if unlinked) | `[<title>, <YYYY-MM-DD>](https://<ws-host>/calendar?d=<YYYY-MM-DD>&event=<uuid>)` |
| **Infra / CI / Deploy / Lease** | Linked open `SPL-<n>` priority if filed | `P1` (`prd` lag, `master` CI red, dead lease, disk `>=92%`, inodes `>=90%`); `P2` (`dev` lag, disk `>=85%`, inodes `>=80%`, vendor paused) | Run URL / `/monitoring/boxes` / `/tenant-settings/fleet-load` + `SPL-<n>` |

---

## 5. Iteration Notes (Updated by Each Reporter at End of Round)

- Keep at most the **last 10** concise operational observations or checklist refinements here (`YYYY-MM-DDTHH:MMZ (<agent>@sat): <change or note>`).
- Promote durable check rules into sections 2 or 3 via `REPORTER_CMD=checklist-update` -> `do_spl_desk_doctree` (`DOCTREE_ARGS='edit <doc-uuid> <item-uuid> --field body ...'`), never deleting a required check category without an explicit owner order.

<!-- version: 0.2.0 · updated: 2026-11-15 · last-edit: 2026-11-15T04:55:00Z -->
