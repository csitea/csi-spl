# Spec 179: Pause and Resume the Agents of a Discussion

Version **0.3.0** (updated 2026-11-19). Authored by lane `a-680` (`agy`); v0.2.0 by lane `c-596` (`claude`), fixing R7 review `c-712` FAIL (msg `7c6de2cc`, W1..W4, N1..N7); v0.3.0 by lane `c-511` (`claude`, issue **SPL-5979**), folding the owner's poll answers (poll `2aee5c75`, msg `f88b925f`): Q1 C, Q3 A, Q4 A (Section 9).
Placement slug: `c002-s179-pause-agents-of-a-discussion-spec`.
Epic: **SPL-2398**. Issue: **SPL-5702** (v0.1.0..v0.2.0, `done`); v0.3.0: **SPL-5979**. Class: `feature`. Kind: **specs_and_docs**.
Discussion / Topic: `a4b718a6-78cd-4d4e-a26b-98c7fe7bbb35` (`t1`).
Nearest prior specs on `origin/master` (`e491a8dab`):
- [`063-agent-context-lifecycle`](../063-agent-context-lifecycle/spec.md) (lane context lifecycle, restarts, and handoffs),
- [`041-spool-topic-archive-delete/archive-releases-work.md`](../041-spool-topic-archive-delete/archive-releases-work.md) (`SPL-3983`, `SPL-4955`, `SPL-5284`: how archiving a discussion releases lanes and follows issues),
- `135-work-process` (discussion issues, Restart cards) and `150` (`0214_topic_priorities.sql`: per-topic hub state table and queue ordering).
Line references re-checked for v0.2.0 on `origin/master` `317ec31cb`: of every file this spec cites, `git diff --name-only e491a8dab 317ec31cb` lists only `spl-rotate-lib.func.sh` (SPL-5704, its `## 10. Open takes` line moved 1078 -> 1079) and `spawn-core.inc.sh` (lines 12 and 538 unchanged).
Next-free check (`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -3` -> `177-reporter-role`, `178-nuxt4-migration`, `README.md`): `179-pause-agents-of-a-discussion` verified free on `origin/master`.

> **Note on `csi-spl-doc/specs/README.md`**: On `origin/master` (`e491a8dab`), `csi-spl-doc/specs/README.md` is a Qto-exported document (`59cba1d3-fb50-4045-82ff-13f5c140566f`, workspace `system`, mapped in `csi-spl-doc/doc/md/qto-docs.tsv`) whose index stops at spec `099` (`git log -n 5 --oneline -- csi-spl-doc/specs/README.md`). Hand-editing a Qto-mapped Markdown file fails `QTO_DRIFT_LIVE=1` (`csi-spl-orc/src/bash/run/check-qto-doc-drift.func.sh`) and is overwritten by `do_spl_doctree_export_md`, while `prd` Qto writes are barred in this spec-only lane. Following specs `100..178`, `csi-spl-doc/specs/README.md` is left untouched here.

---

## 1. The Owner's Words (Verbatim) and Measured Gap on `origin/master`

### 1.1 Owner (`HUM-10`, `prd`), verbatim

- `csi-rel` `#development`, topic `f94518fa-024f-45ee-bd70-2161c3dc8e95`, `2026-11-16 08:55:32Z` (msg `8f7feda6`), to `ALL-0`:
  > "Pause all agents on this discussion. No need to stand by"
- `t1`, topic `a4b718a6-78cd-4d4e-a26b-98c7fe7bbb35`, `2026-11-16 08:56:43Z` (msg `defccc7d`):
  > "We need the feature to pause agents , check this discussion https://csi-rel.spool-hub.ai/channel/development?topic=f94518fa-024f-45ee-bd70-2161c3dc8e95"

### 1.2 What Exists Today vs What Is Missing (`origin/master` at `e491a8dab`)

1. **Incident trace (`08:55Z`)**: The post in `csi-rel` `#development` (`f94518fa-024f-45ee-bd70-2161c3dc8e95`) reached the dispatch seats only as a pane notification; no agent had yet replied in that topic, and no command, hub route, or WUI control exists to pause the agents of a single discussion. Today, stopping work on one live discussion requires manual orchestrator intervention (closing lanes and editing issues by hand).
2. **Existing `pause` in the CLI and hub** (`git grep -n pause origin/master -- csi-spl-api/src/go/spool-hub-api/cmd/spool/main.go csi-spl-doc/doc/md/spool-cli-reference.md`):
   - Only `spool fleet-load pause <kind> <until> [reason]` (`cmd/spool/main.go:56-59`, `spool-cli-reference.md:627-632`, migrations `0118`, `0134`, `0149`, `agent_kinds_paused`) exists — pausing an entire AI **vendor kind** across every box in the fleet, plus quota/limit pauses. Nothing exists per discussion, per channel, or per agent.
3. **Why Topic Archive (`Spec 041` / `SPL-4955` / `SPL-5284`) is not Topic Agent Pause**:

| Dimension | Topic Archive (`PUT /v1/messages/{card}/archive`, `0282`) | Topic Agent Pause (**Spec 179**, Planned) |
|---|---|---|
| **Topic visibility in channel** | Hidden from live channel and topic lists (`messages.archived_at`). | **Stays live and visible** in its channel with a **Paused** badge showing who paused it. |
| **Human posts in the topic** | **Refused** (`409 topic_archived`, `internal/hub/topic_archived_input.go`). | **Allowed** — humans can keep talking, leave notes, or resume agents at any time. |
| **Agent posts in the topic** | Still accepted on box sockets (`topic_archived_input.go:19`). | **Refused at the hub** (`409 topic_paused`) and in `do_spl_desk_reply` (except the hub's own pause/resume notice). |
| **Linked open issues** | Closed as **`diss`** (`canceled_at`, `0282_issue_discussion_closes.sql`). | Moved to **`onhold`** (`topic_pause_issues` keeps `prev_status` so Resume restores them). |
| **Queued spawn asks (`fleet_asks`)** | **Declined** (`spl_spawn_place_drop_archived`) and moved to a new follow-up topic (`do_spl_archived_followup`). | **Held in line** (`.place.wait`, keeping queue priority and position; lift automatically on Resume). |
| **Running lanes & single-topic seats** | Freed after a 10-min settle delay (`ARCHIVED_FOLLOWUP_SETTLE_MIN`); skips every `standing .*seat` (`spl-archived-seats-free.func.sh:106,114`). | **Stopped cleanly without delay** (`"No need to stand by"`): dirty work snapshotted to `refs/heads/wip/<branch>`, issue set `onhold`, window closed & retired — **including single-topic standing seats**. |
| **Unanswered sweep & escalation** | Skipped via `archived` column (`spl-unanswered-sweep.func.sh:530`), but `fallback_postgres.go` `UnansweredPosts` does not filter paused topics. | **Skipped in both** `do_spl_unanswered_sweep` (no list, no re-send, **no orchestrator escalation**) and `store/fallback_postgres.go` (`UnheardPosts`, `UnansweredPosts`, `ReescalatablePosts`). |

---

## 2. What "the Agents of a Discussion" Are — and How Each Is Found Today

A discussion is identified by `(tenant_id, task_id)` where `task_id` is its lowercase UUID (`<topic8>` is `task_id[0:8]`). Across a customer workspace (where the channel/topic lives, e.g. `csi-rel`) and the operator workspace (`t1`, where `fleet_lanes` and `fleet_asks` live), five categories of agent state belong to a discussion:

| # | Category | Authoritative Store / File Today (`origin/master`) | Exact Query or Command Today | Action on Pause |
|---|---|---|---|---|
| **1** | **Agents that posted in the topic** | Hub `messages` table (`csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql`, index `0083_messages_task_received_covering.sql`); desk spool `inbox`/`outbox`/`archive`. | **SQL**: `SELECT DISTINCT m.from_id, m.from_box FROM messages m WHERE m.tenant_id = $1 AND m.task_id = $2::uuid AND m.typed_by IS NULL AND m.from_id NOT LIKE 'HUM-%' AND m.from_id NOT LIKE 'GST-%'`<br>**CLI**: `spool hub-tail --task <task_id> --with-channel` (`spl-take-auto.func.sh:152`) or `GET /v1/view/topics/{task_id}` (`internal/hub/view.go:1171`). | Hub `onSend` (`409 topic_paused`) and `do_spl_desk_reply` block any further reply into the topic (or DM `--ref <task_id>`). Multi-topic seats stay alive; single-topic lanes/seats end (rows 3–4). |
| **2** | **Taking dispatcher / OD & pending deferred takes** | Per-box take ledger `$SPOOL_ROOT/dispatch/take.log`, deferred ledger `$SPOOL_ROOT/dispatch/take-defer.pending`, and auto-take log `$SPOOL_ROOT/dispatch/take-auto.log` (`csi-spl-orc/src/bash/run/spl-take.func.sh:20,39`, `spl-take-auto.func.sh:167`); rotation handoff `spl-rotate-lib.func.sh:1079`. | **Take ledger**: `awk -F'\t' -v t="<task_id>" '$2 == t { print $3, $5 }' "$SPOOL_ROOT/dispatch/take.log"` (`<epoch>\t<topic>\t<id>@<box>\t<plan>\t<post_msg_id>`).<br>**Deferred take**: `awk -F'\t' -v t="<task_id>" '$2 == t { print $4, $3, $1 }' "$SPOOL_ROOT/dispatch/take-defer.pending"` (`<due>\t<topic>\t<post_msg_id>\t<id>@<box>`).<br>**Topic owner in tail**: `spl_take_auto_owner` (`spl-take-auto.func.sh:160-163`, first non-`HUM/GST/RSP` reply to `ALL-0` or `HUM-*`). | Role seats (`001..003`) are **never closed** by one topic, but `do_spl_take_auto`, `do_spl_take`, woke `take-defer.pending` jobs, and rotation handoff `## 10. Open takes` (`spl-rotate-lib.func.sh:1079`) all skip paused topics. |
| **3** | **Standing or dedicated seats naming the topic** | Hub `dedicated_agents` table (`0219`, `scope_type IN ('topic','channel')`, read in `box_archive.go:148-160` and `spl-unanswered-sweep.func.sh:463-468`); per-box `$SPOOL_ROOT/registry.tsv` + `$SPOOL_ROOT/<id>/lifetime/brief.md` (`# Seat brief: ... standing seat`). | **SQL**: `SELECT agent_id, box_id FROM dedicated_agents WHERE tenant_id = $1 AND scope_type = 'topic' AND scope_id = $2`<br>**Box files**: `grep -lE '(^# .*standing .*seat|<task_id>|<topic8>)' "$SPOOL_ROOT"/*/lifetime/brief.md` cross-checked with `$SPOOL_ROOT/registry.tsv` and desk roots `spl_archived_seat_desks` (`spl-archived-seats-free.func.sh:140-182`). | **Single-topic standing seat** (bound to this one topic alone, not `001..003` and not workspace/channel-wide): **ends cleanly** (`issue onhold`, window closed & retired — `"No need to stand by"`).<br>**Workspace/channel-wide standing seat**: stays alive for other topics; blocked on this topic. |
| **4** | **Running task / review lanes bound to the topic** | Hub `fleet_lanes` table in operator workspace (`0096_fleet_lanes.sql`, `0221`, `0253`, `0264_fleet_lanes_topic_issue_required.sql`; `internal/hub/box_lane.go`); per-box `$SPOOL_ROOT/registry.tsv` (`spawn-core.inc.sh:12,538`: `<id>\t<kind>\t<pane>\t<rundir>\t<spawned_utc>\t<requester>`), `$SPOOL_ROOT/agents/<id>.json`, `$SPOOL_ROOT/<id>/lifetime/{brief.md,issue,origin-issue}`, and `issue_discussions` (`0194`). | **Hub CLI / API**: `lane-map.sh --json` / `spool lane --fleet <fleet> --state live` (no `--list` flag exists: leaving out `--agent` lists, `cmd/spool/lane.go:22`, and `--state` narrows the list to that state, `lane.go:31,41-44`) (`SELECT agent_id, agent_box, repo, branch, issue_key, origin_issue, topic FROM fleet_lanes WHERE tenant_id = $1 AND fleet = $2 AND state = 'live' AND topic = $3`; `laneTopic` in `box_lane.go:233` resolves `<topic8>` and `dispatch-<topic8>` across workspaces).<br>**Authoritative brief binding** (`spl_archived_seat_binding`, `spl-archived-seats-free.func.sh:117-125,190-198`): `^Ask-Topic:` line (written by `spl_spawn_place_ask_topic`), else first `^[*]*(Task\|Topic\|Discussion):` line naming `<task_id>`, `dispatch-<topic8>`, or `<topic8>` (excluding `none`/`n/a`/`no topic`). | **Ends cleanly at a safe point** (`"No need to stand by"`): dirty worktree snapshotted via `do_spl_lane_wip_push`, lane issue set `onhold` with pause reason, tmux window closed & agent ID retired (`tmux-close-window.sh --agent <id> --retire`). |
| **5** | **Queued & open spawn asks (and work-group rows) on the topic** | Hub `fleet_asks` table in operator workspace (`0097_fleet_asks.sql`, `0180_fleet_asks_queue.sql`, `0241_fleet_ask_discussion.sql`; `internal/store/fleet_ask.go`); brief files `$SPOOL_ROOT/dispatch/briefs/<slug>.md`; work-group files under `$SPAWN_GROUP_DIR` (`spl-spawn-group-put.func.sh`). | **Queue CLI**: `SPAWN_QUEUE_FORMAT=json ./run -a do_spl_spawn_queue` and `ASKS_FORMAT=json ./run -a do_spl_asks_open`.<br>**Row-to-topic resolver** (`spl_spawn_place_row_topic`, `spl-spawn-place.func.sh:802-810`): matches `.discussion` (`<uuid>` or `<topic8>`), else `.topic` (`<uuid>` or `dispatch-<topic8>`), plus the `SPAWN_PLACE` brief's `Ask-Topic:` / `Topic:` / `Discussion:` line. | **New `do_spl_spawn_enqueue`**: refused while paused.<br>**Already-`queued` `fleet_asks` rows & waiting work-group rows**: **held in place** (`.place.wait` records pause reason; never declined; other queue rows bypass them). |

---

## 3. Pause: Authorization, Entry Doors, and Clean Agent Shutdown ("No Need to Stand By")

### 3.1 Who May Pause (and Resume)

- **The rule (owner, Q1 C, msg `f88b925f`)**: pause and resume follow the workspace's **"Who can archive topics"** policy (`tenants.topic_archive_policy`, rdb `0093`, CLE-77819), exactly as archive and topic priority do. There is no pause-specific role list:
  - `everyone` (the default): any signed-in member who can read the topic;
  - `admins`: the workspace owner (`a.TenantOwner`) or a workspace admin (`a.Has(rbac.Admin)`);
  - `starter`: the author of the topic's opening card, plus the workspace owner or an admin;
  - the demo workspace is always `starter` (`archivePolicy`, `internal/hub/demo.go:73-81`).
  - The operator workspace owner has no extra reach in a managed workspace: they pause there only when that workspace's policy lets them through, as for an archive. (v0.2.0's `prioWordOwners` clause, which Q1 A carried, is dropped.)
- **Where the policy already lives, so B2 and B6 reuse it and add no rule of their own** (`git grep -n -E 'mayArchiveByPolicy|archivePolicy\(|function mayArchiveTopic' origin/master -- csi-spl-api csi-spl-wui/src`, on `origin/master` `b144fea59`):
  - **Hub**: `mayArchiveByPolicy(ctx, tenant, hum, stored, change)` (`internal/hub/topic_archive.go:172-182`) with `s.archivePolicy(t)` (`internal/hub/demo.go:76`). Its task-keyed caller `priorityAllowed` (`internal/hub/topic_priority.go:174-178`: `change := s.mayChangeTopic(..., q.card.FromID)`, the starter being the opening card's author) is the shape `PUT`/`DELETE /v1/topics/{task_id}/pause` takes, `403 not_allowed` when it says no. Door B (3.2) runs the same check on the human who wrote the directive (B1) or wrote the `cause_msg_id` (B2 relay).
  - **WUI**: `mayArchiveTopic(msg, viewerId, me)` (`csi-spl-wui/src/utils/topic-archive.mjs:74-85`, reading `me.topicArchivePolicy` from `/v1/view/me`, `utils/access.mjs:46`), applied to the topic's opening card. `mayPauseTopic` (6.3) is that call, not a new rule; the hub re-checks every write.
- **Also required**, as for every topic write: the caller passes the topic's read door (`canReadTopic` -> `404 not_found` if unreadable, never `403`), tenant billing allows writes (`billing.AllowsWrite`), and the session is not a demo visitor (`403 demo_read_only`).
- **Excluded topics**:
  - An archived topic returns `409 topic_archived` (`s.topicOpenDoor`, `topic_archived_input.go:78` — unarchive first, or leave archived).
  - The shared `#lobby` container task (`task == s.o.LobbyTaskID`, `topic_archive.go:130`) returns `409 lobby_task` (`"pause an individual topic, not the lobby container"`).
- **Idempotency**: Pausing an already-paused topic returns `200 OK` with the existing `topic_pauses` row (updating `reason` only if a new non-empty `reason` is supplied) and writes **no duplicate topic notice** and **no duplicate issue comments**.

### 3.2 From Where Pause Is Triggered (Two Doors, One Store Transaction)

1. **Door A — WUI Topic Control (`PUT /v1/topics/{task_id}/pause`)**:
   - Browser HTTP route `PUT /v1/topics/{task_id}/pause` with optional JSON body `{"reason": "<optional string <= 500 chars>"}` (empty body `{}` valid).
   - Exposed in `TopicPane.vue` row 2 (`topic-head__row2`, beside `LazyTopicPriorityChooser`) and in the topic card menu (`topic-menu.mjs` / `msg-menu.mjs`, shown disabled with `feed.msg_menu.why.pause` reason for unauthorized viewers per `CLE-77891`).
2. **Door B — Human Post in the Discussion (Deterministic Hub Phrase + Dispatcher Action)**:
   - **Why a post in the topic must work even when no agent owns the topic yet**: In the triggering incident (`csi-rel` `#development`, topic `f94518fa-024f-45ee-bd70-2161c3dc8e95`), no agent was in the topic when `HUM-10` wrote `"Pause all agents on this discussion. No need to stand by"`.
   - **Layer B1 — Deterministic hub command detection (`internal/hub/owner_pause_word.go`, modelled on `owner_prio_word.go` `SPL-5524`)**:
     - Runs in `wuiAfterStore` (`wui.go`) after stripping fenced code blocks, inline code spans, and `>` blockquotes (`prioOwnText`, `owner_prio_word.go:40-45`), ignoring `note_to_self` and `LobbyTaskID`.
     - When an authorized human (Section 3.1) posts a directive whose **first line** is the whole directive sentence, the hub immediately runs the **same** `pauseTopic` transaction in `< 50 ms` with zero LLM/dispatcher latency. The sentence must end at `.`, `!` or the end of the line, so a question never matches:
       `(?i)^\s*(?:/pause(?:-agents)?|pause\s+(?:all\s+)?agents(?:\s+on\s+this\s+(?:discussion|topic))?)\s*(?:[.!]\s*(?P<reason>.*))?$`
       Matches: `Pause all agents on this discussion. No need to stand by` (reason `No need to stand by`), `Pause agents`, `/pause`. Does not match: `Pause agents? what do you think`, `Pause agents tomorrow`, `pause agents if CI is red`. Any text after the directive on that line, and the lines after it, are recorded as `reason` (cut to 500 chars). *(Decided: Q4 A, Section 9.)*
   - **Layer B2 — Dispatcher relay action (`do_spl_topic_pause` / `spool topic-pause`)**:
     - When an authorized human phrases a pause request conversationally (not matching Layer B1's strict prefix regex), the dispatch lease holder runs:
       ```bash
       cd csi-spl-orc && ENV=prd TENANT_ID=<ws> DESK_AGENT=<seat> \
         TOPIC_ID=<full-topic-uuid> TOPIC_PAUSE_OP=pause PAUSE_CAUSE_MSG=<human-msg-uuid> \
         DRY_RUN=0 ./run -a do_spl_topic_pause
       ```
     - Over the desk box WebSocket (`type: "topic_pause"`, `pause_op: "pause"|"resume"`, `task_id`, `cause_msg_id`), the hub verifies that `cause_msg_id` exists in `task_id` and was authored by a `HUM-<n>` who passes Section 3.1's authorization check (`paused_by` records that `HUM-<n>`, never an autonomous agent decision). An agent cannot pause or resume a discussion without a real human message ID in that topic.

### 3.3 What Pause Does to Issues and Agents ("No Need to Stand By")

#### 3.3.1 Immediate Synchronous Hub Effects
Inside one store transaction (`SetTopicPaused(ctx, tenant, taskID, actor, reason, now, true)`):
1. Upserts `(tenant_id, task_id, paused_by, paused_at, reason)` in `topic_pauses` (bumping `tenant_change_bump()` via `change_stamp`).
2. Finds every open task issue linked to `task_id` in `issue_discussions` (`d.origin_tenant IS NULL`, `i.status IN ('eval', 'todo', 'wip', 'blocked')`, `i.archived_at IS NULL`, `i.deleted_at IS NULL`, `i.kind NOT IN ('epic', 'feature')` — matching `internal/store/issue_follow.go:52-57` and `0282_issue_discussion_closes.sql`; issues already `done`, `diss`, `qas`, or `onhold` are untouched):
   - Moves each to **`onhold`**, storing `(tenant_id, number, task_id, prev_status, paused_at, paused_by)` in `topic_pause_issues`.
   - Emits an `issue` WS update frame per moved issue and posts one comment on each issue:
     `Put on hold (was <prev_status>) because discussion /t/<task_id> was paused by <paused_by> at <paused_at>. Resuming the discussion restores it.`
3. Commits one visible pause notice into `task_id` (`Section 6.2`) and broadcasts live WS frame `topic_paused` (`paused: true`) via `fanoutTopic`.

#### 3.3.2 Clean Teardown of Running Lanes and Single-Topic Seats (`do_spl_paused_seats_free`)
Per the owner's explicit order (*"Pause all agents on this discussion. No need to stand by"*), paused agents **end cleanly rather than waiting in a tmux pane**. This is decided, not asked: there is no stand-by variant (v0.1.0's Q2 is dropped, Section 9).

Every **1 minute** on each box (new box-cron row `paused-seats-free` in `csi-spl-orc/cnf/box-crons/box-crons.manifest`, no 10-minute settle delay because pause is non-destructive and reversible), `DRY_RUN=0 ./run -a do_spl_paused_seats_free`:

1. Queries the hub via `spool lane --fleet "$LANE_FLEET" --paused --box "$LANE_BOX"` (`lane_op: "paused"` in `internal/hub/box_lane_paused.go`, returning live `fleet_lanes` rows on `$LANE_BOX` whose resolved topic is paused in the operator workspace or any customer workspace, with `topic_paused_at`, `topic_paused_by`, `topic_pause_reason`, and `issue_held` = the row's `issue_key` is in `topic_pause_issues`), **plus** scans local `$SPOOL_ROOT/*/lifetime/brief.md` for any local single-topic standing seat not yet in `fleet_lanes`.
2. Applies deterministic target classification (sharing worktree/desk helpers with `spl-archived-seats-free.func.sh`):
   - **Never closed**: role seats (`001..003` / `LEASE_*`), multi-workspace seats (`spl_archived_seat_workspace_wide`), channel-wide/multi-topic standing seats whose brief does not bind to a single topic, and lanes whose brief binds to a *different* topic or explicit `none`/`n/a`.
   - **Closed cleanly**: any task lane, review seat, **or single-topic standing seat** whose `lifetime/brief.md` binds solely to the paused topic (`Ask-Topic:`, `Task:`, `Topic:`, or `Discussion:`, or single-topic `# Seat brief: ... topic <id>`) and whose brief mtime is older than `topic_paused_at`.
3. **Stopping at a safe point**:
   - **Already at a safe point** (`git status --porcelain` = `0` lines, `git rev-list --count HEAD --not --remotes` = `0` commits, no child process matching `ROTATE_LANE_BUSY_RE` in `spl-lane-rotate.func.sh:106`, and `PUSH_CMD=status do_spl_push_master` != `RUNNING`):
     1. If `$SPOOL_ROOT/<id>/lifetime/issue` names an issue and there is no `lifetime/issue-end`:
        - **The issue is already held by the pause** (the `lane_op: "paused"` row carries `issue_held: true`, i.e. the lane's `issue_key` is a row of `topic_pause_issues` in the issue's workspace, put there by 3.3.1): **no lane end runs and nothing is written to the issue**. `do_spl_paused_seats_free` writes only the local `lifetime/issue-end` line (`onhold\tdiscussion paused by <by> at <at>\t<utc>`, the 3-column form of `spl-lane-issue.func.sh:512`) so `/exit-clean` and the closer see the end. The hub alone owns that issue's status until Resume restores it (Section 4.2).
        - **Otherwise** (an issue not linked to the discussion in `issue_discussions`, e.g. a `t1` lane issue whose brief names the topic only by `Ask-Topic:`): runs `AGENT_ID=<id> LANE_ISSUE_OP=end LANE_ISSUE_STATUS=onhold LANE_ISSUE_REASON="discussion paused by <by> at <at>" DRY_RUN=0 ./run -a do_spl_lane_issue`. Such an issue is not in `topic_pause_issues`, so Resume does not restore it; the fresh lane of Section 4.2 step 3 takes it back to `wip` when it places.
        - Belt and braces, measured on `origin/master`: `spl_lane_issue_close` (`spl-lane-issue.func.sh:546-557`) already makes no hub write for an issue at the target status, so a lane that ends itself with `LANE_ISSUE_STATUS=onhold` (the `PAUSED` note below) on a held issue changes nothing either.
     2. Closes the window and retires the ID via `tmux-close-window.sh --agent <id> --retire` (drops single-topic desk seat if any, marks `fleet_lanes` `done`, and registers the worktree in `$SPOOL_ROOT/workdirs.tsv` for 24 h retention).
   - **Busy or dirty worktree** (running tests/`do_check_pre_push`/`git push`, uncommitted edits, or unpushed commits):
     1. **Never kills `do_check_pre_push` or `git push` mid-flight**.
     2. Immediately snapshots any dirty index and untracked `csi-spl-*/` source files to `refs/heads/wip/<lane_branch>` via `ID=<id> ./run -a do_spl_lane_wip_push` (`spl-lane-wip-push.func.sh`, using a temporary git index so the live worktree is untouched).
     3. Sends **one** deduplicated spool message (`--from <orch_seat> --to <id> --kind note --task <lane_task>`) starting with `PAUSED`:
        `PAUSED: discussion <task_id> was paused by <by> at <at>. Do not post in the topic. Finish your current command, commit/push green work (or leave refs/heads/wip/<branch>), update your issue Restart card, run LANE_ISSUE_OP=end LANE_ISSUE_STATUS=onhold, and run /exit-clean.`
     4. **Self-close gate support (`kill-your-self-report.sh --gate` & `tmux-close-window.sh`)**:
        - `kill-your-self-report.sh` (`--gate`, lines `35-58`) accepts a verified `PAUSED` message from a role seat (`001..003` / `LEASE_*`) alongside `ACCEPTED` **when and only when** `lifetime/issue-end` records `onhold` and no `do_spl_push_master` is `RUNNING`.
        - `tcw_f3_outcome` (`tmux-close-window.sh:585-614`) records **`paused`** (never `fail:F3`) in `$SPOOL_ROOT/dispatch/attempts.tsv` when a lane exits with a pause `onhold`, so pausing a discussion never pollutes vendor failure-rate / takeover metrics.
     5. **Bounded drain backstop (`PAUSED_DRAIN_MAX_MIN`, default `15` min)**: If a notified dirty/hung lane has still not exited `15` minutes after `topic_paused_at` (and no `ROTATE_LANE_GATE_RE` push is running), `do_spl_paused_seats_free` runs `do_spl_lane_wip_push` one final time:
        - If `do_spl_lane_wip_push` succeeds (`0` unbacked-up bytes), it writes the `refs/heads/wip/<branch>` ref into the issue's `onhold` comment / Restart card and runs `tmux-close-window.sh --agent <id> --retire` so no pane stands by forever.
        - Only if `do_spl_lane_wip_push` fails (e.g. unreadable git dir) is the lane kept and reported in **one** deduplicated blocker to `orchestrator`.

---

## 4. Resume: How a Topic Is Un-Paused and What Restarts

### 4.1 Triggering Resume
1. **WUI**: Clicking the **`Paused`** button/badge in `TopicPane.vue` header (`PausedBadge.vue`, one tap on desktop and phone, mirroring `ArchivedBadge.vue` `SPL-1763`) or selecting **Resume agents** on the topic card menu calls **`DELETE /v1/topics/{task_id}/pause`** (same authorization check as Section 3.1; idempotent `200 OK` `{task_id, paused: false}` if already unpaused).
2. **Post in the topic**: an authorized-human directive on the first line, same whole-sentence rule as pause (`(?i)^\s*(?:/resume(?:-agents)?|(?:resume|unpause)\s+(?:all\s+)?agents(?:\s+on\s+this\s+(?:discussion|topic))?)\s*(?:[.!].*)?$`; `Resume agents?` does not match) in `owner_pause_word.go`, or dispatcher `TOPIC_PAUSE_OP=resume PAUSE_CAUSE_MSG=<msg_uuid> DRY_RUN=0 ./run -a do_spl_topic_pause`.

### 4.2 What Restarts (Fresh Lane from Issue State, Never the Old Pane)

1. **Hub store transaction (`SetTopicPaused(..., paused=false)`)**:
   - Deletes `(tenant_id, task_id)` from `topic_pauses` (bumping `change_stamp`).
   - Restores every issue that is **a row of `topic_pause_issues` for this topic AND still `onhold`**, in one statement: `WITH back AS (DELETE FROM topic_pause_issues p WHERE p.tenant_id = $1 AND p.task_id = $2 RETURNING p.number, p.prev_status) UPDATE issues i SET status = <restored>, updated_at = $3, updated_by = left($4, 64) FROM back WHERE i.tenant_id = $1 AND i.number = back.number AND i.status = 'onhold' AND i.deleted_at IS NULL AND i.archived_at IS NULL`.
     - The guard is membership plus status, never `updated_at`: a comment, a title edit or a lane end on the held issue after `paused_at` must not stop the restore. An issue someone moved out of `onhold` by hand while paused (to `wip`, `done`, `diss`) is left as it is; its row is still deleted.
     - The shape follows `followUnarchiveTx` (`internal/store/issue_follow.go:87-97`), whose guard at lines 93-94 reads `i.status = 'diss' AND i.canceled_at = back.closed_at`: archive has a column of its own (`canceled_at`) that only the archive writes, while `onhold` has none, so pause guards on the `topic_pause_issues` row instead.
     - `prev_status IN ('eval', 'todo', 'blocked')` -> restored to `prev_status`.
     - `prev_status == 'wip'` -> restored to **`todo`** (because the previous lane's process and tmux pane were closed and retired; it returns to `wip` when the replacement lane places).
   - Deletes the topic's rows from `topic_pause_issues`, emits `issue` WS update frames, posts one comment per restored issue (`Restored to <status> because discussion /t/<task_id> was resumed by <by> at <at>.`), writes one visible resume notice in the topic (`Section 6.2`), and fans out WS frame `topic_paused` (`paused: false`).
2. **Held queue rows (`fleet_asks.state = 'queued'`) resume automatically**:
   - On the next 1-minute `do_spl_spawn_place` tick, `spl_spawn_place_paused_hold` sees the topic is no longer paused, clears its `<asks_dir>/.place.wait` entry, and places the held ask(s) in their original `enqueued_at` and priority order. Work-group waiting rows (`spl_spawn_group_feed`) resume feeding the same way.
3. **Interrupted `wip` lanes and single-topic seats restart as NEW lanes from the issue's state**:
   - Old panes and retired agent IDs (`.retired/<id>.<utc>`) are **never** revived or `--resume`d.
   - When `do_spl_paused_seats_free` closes an active lane or single-topic seat on pause, it records one row in `$SPOOL_ROOT/dispatch/paused-lanes.tsv` (`<paused_at>\t<topic_uuid>\t<issue_key>\t<issue_tenant>\t<retired_id>\t<vendor>:<slug>\t<class>\t<wip_ref>\t<brief_copy_path>`).
   - On its 1-minute tick, when a topic in `paused-lanes.tsv` is observed unpaused (`spool lane --paused --topic <topic_uuid>` returns live/unpaused) and its `issue_key` is open (`todo`/`onhold`, not `done` or `diss`):
     - **Decided (Section 9, Q3 A)**: `do_spl_paused_seats_free` writes a resume brief `<slug>-resume-<ts>.md` pointing to `Issue: <issue_key>`, its updated Restart card, and `refs/heads/wip/<old_branch>` (if non-empty), files a fresh spawn ask, enqueues it via `do_spl_spawn_enqueue` (`SPAWN_PLACE=<vendor>:<resume-slug>`), notifies the current dispatch lease holder on `dispatch-<topic8>`, and removes the `paused-lanes.tsv` row.
4. **Unanswered human messages posted while paused**:
   - Because the resume notice updates `topic_heads.changed_at`, `do_spl_unanswered_sweep`'s next 1-minute delta read re-evaluates the topic: if a human posted a substantive message before or during the pause that still has no agent reply, it enters the normal dispatch flow; if the last real message before the pause was already an agent answer and the human only clicked Resume, the sweep stays quiet (`Section 5.2`).

---

## 5. State Storage and How Every Path Checks It

### 5.1 Forward-Only PostgreSQL Migration (`csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_topic_pauses.sql`)

Claimed at build time via `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` (current head on `origin/master` is `0286_hr_worker_side.sql`):

- **Why a dedicated `topic_pauses` table**: Matches `0214_topic_priorities.sql`. `topic_heads` (`0144_topic_heads.sql`) is a pure trigger projection of `messages` checked by `topic_head_diff`, and `messages` rows are signed envelopes. A dedicated `(tenant_id, task_id)` PK table costs zero bytes for unpaused topics, answers point lookups in one B-tree probe, and carries `FORCE ROW LEVEL SECURITY` + `change_stamp`.

```sql
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS topic_pauses (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id   uuid        NOT NULL,
    paused_by text        NOT NULL CHECK (paused_by <> '' AND length(paused_by) <= 64),
    paused_at timestamptz NOT NULL,
    reason    text        NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
    PRIMARY KEY (tenant_id, task_id)
);

CREATE TABLE IF NOT EXISTS topic_pause_issues (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    number      integer     NOT NULL,
    task_id     uuid        NOT NULL,
    prev_status text        NOT NULL CHECK (length(prev_status) <= 16),
    paused_at   timestamptz NOT NULL,
    paused_by   text        NOT NULL DEFAULT '' CHECK (length(paused_by) <= 64),
    PRIMARY KEY (tenant_id, number),
    FOREIGN KEY (tenant_id, number) REFERENCES issues (tenant_id, number) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS topic_pause_issues_task ON topic_pause_issues (tenant_id, task_id);

-- Fail-closed tenant_scope + operator_scope RLS on both tables (0021 NULLIF shape):
-- plus rlsTables registration in internal/store/rls_test.go.
-- Constraint trigger change_stamp on topic_pauses -> tenant_change_bump() (0103),
-- so ETag / stamped topic-list reads never return stale 304 after pause or resume.
```

### 5.2 Complete Path Enforcement Matrix

Every code path that acts on a discussion checks `topic_pauses` deterministically:

| # | Path | Exact File(s) | How It Checks `topic_pauses` & Exact Behaviour |
|---|---|---|---|
| **1** | **Hub box message send (`onSend`)** | `csi-spl-api/src/go/spool-hub-api/internal/hub/{ws.go,topic_paused_input.go}` | On a box send (`env.FromBox != WUIBox` and `f.TypedBy == ""`) **that would be read in the discussion**: addressed to `ALL-0` (a post in the topic) or to a `HUM-*` / `GST-*` (a reply to a person, or a DM carrying `--ref <task_id>`). Only for those does it probe `AnyTopicPaused(ctx, x.tenant, m.TaskID, f.RefTaskID)`; if paused and `m.MsgID` is not an idempotent replay (`MessageTimes`), it refuses with `409 topic_paused` before `claimAnswer` / `commitRowTyped`. **Agent-to-agent sends on the paused task id pass** (a `note`, `result`, `blocker` or `reject` to an agent id): the `PAUSED` note of 3.3.2, a finishing lane's report to its dispatcher and an R7 verdict all use the discussion's task id when a lane's `Ask-Topic:` is the discussion. Same choice as archive, which lets every box send through (`topic_archived_input.go:17-20`); pause narrows it to what a human would read. Browser sends (`wui.go`) and hub-originated notices are untouched (`0` extra round trips on `WS wui send`). |
| **2** | **Desk reply (`do_spl_desk_reply`)** | `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh` | (a) Pre-send check and `_spl_desk_reply_refusal` map `topic_paused` to **exit `10`** (`FATAL nothing was sent: topic <ans_task> is paused...`).<br>(b) **Blocks Spec 067 edge-2 DM fallback**: when a reply into channel topic `T` (`ans_ref`) is refused with `topic_paused`, `_spl_desk_reply_send_to` **never** falls back to sending a DM with `--ref T` to the human.<br>(c) Inbox picker (`spl_desk_pick` when `DESK_TASK` is unset) skips human lines belonging to paused topics so they do not trigger exit `4` ambiguity against live topics. |
| **3** | **Take & auto-take (`do_spl_take`, `do_spl_take_auto`)** | `csi-spl-orc/src/bash/run/{spl-take.func.sh,spl-take-auto.func.sh}` | `spl_take_auto_skip` checks topic pause state and exits `0` (`TAKE-AUTO skip <task>: topic paused`). `do_spl_take` checks pause before deferring and again after `spl_take_defer_wait`: an already-sleeping `take-defer.pending` process wakes up, sees the topic paused, logs `TAKE-PAUSED <task>`, and exits `0` without posting or writing `take.log`. |
| **4** | **Spawn enqueue (`do_spl_spawn_enqueue`)** | `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh` | `spl_spawn_q_enqueue_paused` (sibling of `spl_spawn_q_enqueue_archived`, lines `56, 175`) checks `ASK_DISCUSSION`, `spl_spawn_place_row_topic`, and the `SPAWN_PLACE` brief's topic binding via `spool lane --paused --topic <t>` (`spl_spawn_topic_paused`). Refuses (`exit 1`, `FATAL ask <id8> not queued: its topic <t> is paused by <by> since <at>`) unless internal `SPAWN_ALLOW_PAUSED_HOLD=1` is set. |
| **5** | **Spawn placer, queue view & work groups (`do_spl_spawn_place`, `do_spl_spawn_queue`)** | `csi-spl-orc/src/bash/run/{spl-spawn-place.func.sh,spl-spawn-queue.func.sh,spl-spawn-group-put.func.sh}` | **Holds, never declines**: `spl_spawn_place_paused_hold` (alongside `spl_spawn_place_pin_hold` / `spl_spawn_place_dark_hold` at lines `252-256`) queries `spl_spawn_topic_paused` once per distinct queued topic, records `topic <t8> paused by <by> since <at>` in `<asks_dir>/.place.wait` (printed as `WAIT` by `do_spl_spawn_queue`), and removes those rows from the tick's placement line so rows behind them still launch. Re-checked in `spl_spawn_place_take` right before launch to close any race. `spl_spawn_group_feed` holds waiting rows of paused topics. |
| **6** | **Rotations, context restarts & watchdog takeovers** | `csi-spl-orc/src/bash/run/{spl-lane-rotate.func.sh,spl-lane-restart.func.sh,spl-wd-takeover.func.sh,spl-rotate-lib.func.sh}` | • **`do_spl_lane_rotate`**: `spl_lane_rotate_consider` skips any lane/single-topic seat whose bound topic is paused (`SKIP <id>: topic <t8> paused`).<br>• **`do_spl_lane_restart` (Spec 063)** & `do_spl_lane_handover*`: `spl_lane_restart_gate` refuses (`GATE FAIL: topic <t8> is paused; end onhold instead`).<br>• **`do_spl_wd_takeover` (Spec 093)**: `spl_wdt_gate` refuses (`exit 4`) takeover of a non-role seat whose bound topic is paused.<br>• **Role-seat rotation (`001..003`, `spl-rotate-lib.func.sh:1079`)**: `## 10. Open takes` excludes paused topics so a newly rotated dispatcher never answers a paused thread. **Dependency on `SPL-5704`** (landed on `origin/master`, `4f25fa836` + `317ec31cb`): `spl_rotate_open_takes` already drops a take whose topic row in the sweep's `unanswered.rows` has column 10 `archived` (`f[9] == "archived"`). B3 makes the sweep write `paused` in that column (row 7 below); B5 then changes that test to `f[9] in ("archived", "paused")` and adds a paused case to `rotate-open-takes.tst.sh`. B5 must be rebased on a master that holds both `4f25fa836` and B3. |
| **7** | **Unanswered sweep & escalation (`do_spl_unanswered_sweep`)** | `csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh`, `csi-spl-orc/src/bash/scripts/unanswered-sweep-classify.py` | • `_spl_sweep_rows_tail` column 10 (`archived`/`open`, line `530`) emits **`'paused'`** whenever `EXISTS (SELECT 1 FROM topic_pauses tp WHERE tp.tenant_id = l.tenant_id AND tp.task_id = l.task_id)`.<br>• `unanswered-sweep-classify.py` drops `'paused'` rows into the closed/skipped set and prunes any prior `unanswered.state` entry for that topic: **zero `NEW` items, zero `AGAIN` re-sends, and zero `ESC` escalations to the orchestrator** while paused.<br>• Hub pause/resume notice rows (`env_sig = ''`, `kind = 'note'`, body matching `_spl_sweep_pause_notice_sql`) are ignored as anchor/last-actor rows (like `note_to_self` in `0278`), so clicking Resume alone never manufactures a false unanswered alert while any genuine unanswered human post before/during the pause surfaces immediately on the next delta read (`unanswered.rows.meta` bumped `v=2 -> v=3`). |
| **8** | **Hub fallback responder & re-escalation (`box-rsp`)** | `csi-spl-api/src/go/spool-hub-api/internal/store/{fallback_postgres.go,fallback_memory.go}` | `UnheardPosts` (`:80`), `UnansweredPosts` (`:114`), and `ReescalatablePosts` (`:147`) each add `AND NOT EXISTS (SELECT 1 FROM topic_pauses tp WHERE tp.tenant_id = m.tenant_id AND tp.task_id = m.task_id)`. Paused topics never trigger `box-rsp` `"Seen"` deliveries or responder re-escalations. |

---

## 6. Visible to the Human: Badge, Attribution, and Topic Notice

### 6.1 Zero-Extra-Round-Trip View API & Live WebSocket Frame

1. **`GET /v1/view/topics` (`TopicRow`) and `GET /v1/view/topics/{task_id}` (`topicBody`)**:
   - Both responses include:
     ```json
     "paused": true,
     "paused_at": "2026-11-16T08:55:32Z",
     "paused_by": "HUM-10",
     "pause_reason": "No need to stand by"
     ```
     (`"paused": false` and `paused_at`/`paused_by`/`pause_reason` omitted when not paused).
   - **Round-trip budget (`TestRoundTripsPerRequest` in `internal/hub/roundtrips_perf_test.go`)**:
     - In `store/view_postgres.go:386` (`topicsSQL.summary`), read via one `LEFT JOIN topic_pauses tpz ON tpz.tenant_id = <tn> AND tpz.task_id = w.task_id` inside the existing query.
     - In `store/channels_postgres.go:716` (`topicAccessRead` inside `ViewTopicDoor`), read in the same single-row door aggregate alongside `topic_priorities`.
     - Result: **zero additional SQL round trips** on `GET /v1/view/topics` or `GET /v1/view/topics/{task_id}`.
2. **Live WebSocket frame (`topic_paused`)**:
   - Broadcast via `s.fanoutTopic` (`topic_archive.go:217`) to every connected viewer who can read the topic:
     - On pause: `{"type": "topic_paused", "task_id": "<uuid>", "channel": "<ch>", "paused": true, "paused_by": "HUM-10", "paused_at": "<RFC3339>", "pause_reason": "..."}`
     - On resume: `{"type": "topic_paused", "task_id": "<uuid>", "channel": "<ch>", "paused": false, "resumed_by": "HUM-10", "resumed_at": "<RFC3339>"}`

### 6.2 Visible Pause / Resume Post in the Topic

Every transition writes one level-2 thread message (`is_parent = 0`, `kind = "note"`, `from_box = "box-wui"`, `to_box = "box-wui"`, `from_id = <acting HUM-n>`, `to_id = "ALL-0"`, `env_sig = ""`) into the discussion via `s.commitRow`:

- **On Pause**:
  `Agents paused on this discussion by @HUM-<n> (YYYY-MM-DD HH:MM UTC)[ — <reason>]. Running agents stop cleanly and open issues move to on-hold.`
- **On Resume**:
  `Agents resumed on this discussion by @HUM-<n> (YYYY-MM-DD HH:MM UTC).`

Because `from_id` is `@HUM-<n>` in the body and WUI's `@HUM-<n>` chip resolver renders the member's display name, every human reading the thread sees immediately **when** the discussion was paused or resumed and **by whom**, inline in the message history.

### 6.3 WUI Controls and `PausedBadge.vue` (`csi-spl-wui`)

1. **`PausedBadge.vue`** (modelled on `ArchivedBadge.vue`, rendered in `TopicPane.vue` header next to `topic-heading__title` and on topic cards in `MessageCard.vue` whenever `paused === true`):
   - Shows the pause icon + translated word (`t('topic.pause.badge')` -> `"Agents paused"` / `"Paused"`, plus `t('topic.pause.by_who', { who })` in the open topic header; hover `title` shows `t('topic.pause.paused_by_at', { who, when, reason })`). Never icon-only, so mobile (`<= 820 px`) displays the text clearly.
   - When the signed-in viewer is allowed to resume (`mayPauseTopic(card, viewerId, me)`, which is `mayArchiveTopic` on the topic's opening card, Section 3.1), `PausedBadge.vue` renders as a `<button>` (`min-height` / `::after` hit area `44 px` on mobile, canonical focus ring token) whose click calls `DELETE /v1/topics/{task_id}/pause` (`aria-label="t('topic.pause.resume_agents')"`), matching the one-click `ArchivedBadge` unarchive UX (`SPL-1763`).
2. **Pause button when unpaused**:
   - `LazyTopicPauseControl` in `TopicPane.vue` row 2 (`topic-head__row2`, beside `LazyTopicPriorityChooser`) renders a compact **Pause agents** button for authorized viewers; topic card menu (`topic-menu.mjs` + `msg-menu.mjs`) includes **Pause agents** / **Resume agents** for all viewers (disabled with `feed.msg_menu.why.pause` hint when unauthorized, keeping uniform menu shape per `CLE-77891`).
   - All user-visible strings are added to `csi-spl-wui/i18n/locales/en.json` and translated in all 18 other locale files (`i18n-parity.test.mjs`, `i18n-untranslated.test.mjs`, `i18n-no-raw-text.test.mjs`), authored/checked by an `agy` lane per the fleet language rule.

---

## 7. Edge Cases and Invariants

1. **Cross-workspace discussions (e.g. `csi-rel` `#development` + `t1` orchestration)**:
   - `topic_pauses` lives in the discussion's own workspace (`csi-rel`). When `t1`'s placer or `do_spl_paused_seats_free` queries `spool lane --paused`, `laneTopicPaused` in `internal/hub/box_lane_paused.go` checks `t1` first and then non-archived workspaces via `OperatorWorkspaces` — identical to `laneTopicArchivedAt` (`box_lane_archived.go:102-131`).
2. **Archiving a paused topic**:
   - Allowed (`handleArchiveTopic` in `topic_archive.go` does not block on `topic_pauses`): archiving clears `topic_pauses` and transitions `topic_pause_issues` into `issue_discussion_closes` (`diss`, preserving the original pre-pause `prev_status`!) so a later unarchive restores the true pre-pause status rather than leaving issues stuck in `onhold`.
3. **Hub unreachable from a box (`fail-safe asymmetry`)**:
   - Matching `spl-spawn-place.func.sh:850` and `spl-archived-seats-free.func.sh:78`: if the hub cannot be read on one cron tick, `do_spl_paused_seats_free` **frees nothing** (never kills a live agent on a network blip), while `onSend` on the hub itself still blocks every agent post into a paused topic at the server door.
4. **Human posts written while paused are still delivered (a choice, not a gap left open)**:
   - The hub keeps delivering a human's post in a paused topic to the seat inboxes and keeps the pane pokes: nothing a human writes is dropped or held back, and the sweep reads it on Resume (Section 4.2 step 4). Only the inbox picker skips it (5.2 row 2c), and any agent that tries to answer it into the topic is refused (5.2 row 1).
   - **Known limit, not closed by this spec**: a dispatcher that forwards such a post to a lane under a **different** task id (a fresh `dispatch-<topic8>` relay or a spawn ask) is stopped only where that path checks the pause: an enqueue or a placement of a row bound to the paused topic (5.2 rows 4-5). A hand-typed `spool-send.sh --kind task` on another task id is not checked. Closing it means a pause probe in `spool-send.sh` keyed on the body's `/t/<uuid>` links: a follow-up issue if the owner wants it, not a row here.

---

## 8. Build Rows (`B1..B7`, Disjoint Lanes in Landing Order)

Each row below is one small lane with explicit dependencies, task kind, files, tests, and red control:

| Row | Depends On | Kind | Scope & Files | Tests & Red Control |
|---|---|---|---|---|
| **B1** | — | `complex_coding` | **RDB migration & Go store layer (`topic_pauses`, `topic_pause_issues`, view/door fusion, fallback responder exclusion, RLS & `change_stamp`)**:<br>• `csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_topic_pauses.sql` (number claimed via `DRY_RUN=0 ./run -a do_rdb_migration_next`)<br>• `csi-spl-api/src/go/spool-hub-api/internal/store/{topic_pause.go,topic_pause_postgres.go,topic_pause_memory.go,topic_pause_test.go}`<br>• `csi-spl-api/src/go/spool-hub-api/internal/store/{view.go,view_postgres.go,channels_postgres.go,channel_humans.go,fallback_postgres.go,fallback_memory.go,rls_test.go,change_stamp_test.go}` | `PRE_PUSH_TIER=full`: `go test ./internal/store/...` (Postgres + Memory: `TestRLSCoversEveryTenantTable`, `TestRLSControl`, `TestChangeStamp`, `TestViewTopicDoor`, `TestTopicPauseIssuesRestore`: a held issue that got a comment and an `updated_at` bump after `paused_at` is still restored, one moved out of `onhold` by hand is not, `TestFallbackSkipsPausedTopic`).<br>**Red control**: omit `NOT EXISTS (... topic_pauses)` in `UnansweredPosts` or drop `change_stamp` trigger -> `TestFallbackSkipsPausedTopic` and `TestChangeStamp` fail. |
| **B2** | `B1` | `complex_coding` | **Hub HTTP/WS pause & resume routes, `onSend` `topic_paused` guard, `owner_pause_word`, `lane_op paused`, & `spool` CLI verbs**:<br>• `csi-spl-api/src/go/spool-hub-api/internal/hub/{topic_pause.go,topic_pause_test.go,topic_paused_input.go,topic_paused_input_test.go,owner_pause_word.go,owner_pause_word_test.go,box_lane_paused.go,box_lane_paused_test.go}`<br>• `csi-spl-api/src/go/spool-hub-api/internal/hub/{ws.go,wui.go,view.go,box_lane.go}`<br>• `csi-spl-api/src/go/spool-hub-api/cmd/spool/lane.go` (`spool lane --paused [--box B] [--topic T]`, beside `--archived`) and `cmd/spool/main.go` (the `spool topic-pause` verb)<br>• Authorization reuses `mayArchiveByPolicy` + `archivePolicy` (3.1, the `priorityAllowed` shape); no new rule | `PRE_PUSH_TIER=full`: `go test ./internal/hub/... ./cmd/spool/...` including `TestRoundTripsPerRequest` (proving `0` extra SQL round trips on `GET /v1/view/topics`, `GET /v1/view/topics/{task_id}`, and `WS wui send`), `409 topic_paused` on box sends to `ALL-0` / `HUM-*` & `--ref` DMs, an agent-to-agent `note` on the paused task id still sent, human sends still `200`/sent, the B1 directive regex table of 3.2 (each "Matches" and "Does not match" example), cross-workspace `lane_op paused`, archive-after-pause status preservation, and the 3.1 policy table on all three doors (WUI route, B1 directive, B2 relay `cause_msg_id`): `everyone` lets a reader-member pause, `admins` gives a plain member `403 not_allowed` (and a B1 directive or relay from them pauses nothing), `starter` lets only the opening card's author, the owner or an admin, the demo workspace acts as `starter`.<br>**Red control**: bypass `topicPausedRefusal` in `onSend` -> box send into paused topic succeeds and `TestBoxSendRefusedWhenTopicPaused` fails. |
| **B3** | `B2` | `simple_coding` | **Desk reply, take, auto-take, unanswered sweep pause gates, & `do_spl_topic_pause` action**:<br>• `csi-spl-orc/src/bash/run/{spl-topic-pause.func.sh,spl-desk-reply.func.sh,spl-take.func.sh,spl-take-auto.func.sh,spl-unanswered-sweep.func.sh}`<br>• `csi-spl-orc/src/bash/scripts/unanswered-sweep-classify.py`<br>• `csi-spl-orc/src/bash/tests/{spl-topic-pause.tst.sh,desk-reply-paused.tst.sh,spl-take-paused.tst.sh,unanswered-sweep-pg.tst.sh}` | `spl-topic-pause.tst.sh`, `desk-reply-paused.tst.sh` (verifies exit `10` and Spec 067 edge-2 DM fallback blocked), `spl-take-paused.tst.sh` (immediate, auto, and woken `take-defer.pending`), `unanswered-sweep-pg.tst.sh` (paused topic never listed, never re-sent, **never escalated**, and `v=3` delta cache updates on pause/resume).<br>**Red control**: treat `'paused'` as `'open'` in `unanswered-sweep-classify.py` -> paused topic escalates to `orch.md` and test fails. |
| **B4** | `B2` | `simple_coding` | **Spawn enqueue refusal, placer `.place.wait` queue hold, queue `WAIT` display, & work-group hold**:<br>• `csi-spl-orc/src/bash/run/{spl-spawn-enqueue.func.sh,spl-spawn-place.func.sh,spl-spawn-queue.func.sh,spl-spawn-group-put.func.sh}`<br>• `csi-spl-orc/src/bash/tests/spl-spawn-paused.tst.sh` | `spl-spawn-paused.tst.sh`: `do_spl_spawn_enqueue` refuses new asks on a paused topic; `do_spl_spawn_place` holds already-queued asks in `.place.wait` without declining them while placing unpaused rows behind them; unpausing lifts the hold and places them in order.<br>**Red control**: drop `spl_spawn_place_paused_hold` -> placer launches a lane for a paused topic and test fails. |
| **B5** | `B2`, `B3`, `B4`, `SPL-5704` (landed, `4f25fa836`; see 5.2 row 6) | `complex_coding` | **Safe-point lane & single-topic seat teardown (`do_spl_paused_seats_free`), `/exit-clean` `PAUSED` gate, rotation/restart/watchdog skip, & Resume `wip` re-enqueue**:<br>• `csi-spl-orc/src/bash/run/{spl-paused-seats-free.func.sh,spl-lane-rotate.func.sh,spl-lane-restart.func.sh,spl-wd-takeover.func.sh,spl-rotate-lib.func.sh}`<br>• `csi-spl-orc/src/bash/scripts/paused-seats-free-cron.sh` + `csi-spl-orc/cnf/box-crons/box-crons.manifest`<br>• `csi-spl-orc/src/bash/features/spawn-agents/scripts/{kill-your-self-report.sh,tmux-close-window.sh}`<br>• `csi-spl-orc/src/bash/tests/spl-paused-seats-free.tst.sh` + `csi-spl-orc/src/bash/features/spawn-agents/tests/test-exit-clean-paused.sh` | `spl-paused-seats-free.tst.sh`, `test-exit-clean-paused.sh`, `install-box-crons.tst.sh`, `rotate-open-takes.tst.sh`: clean lane & single-topic standing seat put `onhold` + retired; role & multi-topic seats untouched; dirty lane snapshotted via `do_spl_lane_wip_push` + poked `PAUSED` + exits cleanly with `attempts.tsv` `paused` (never `fail:F3`); `do_spl_lane_rotate`, `do_spl_lane_restart`, `do_spl_wd_takeover`, and rotation `Open takes` skip paused topics; Resume re-enqueues fresh lane from `paused-lanes.tsv`.<br>**Red control**: omit `paused` check in `tcw_f3_outcome` or `spl_lane_rotate_consider` -> `attempts.tsv` logs `fail:F3` and `lane-rotate` spawns a successor on a paused topic; tests fail. |
| **B6** | `B2` | `i18n` | **WUI `PausedBadge.vue`, `TopicPauseControl.vue`, card menu items, live `topic_paused` WS handling, & 19-locale i18n**:<br>• `csi-spl-wui/src/components/{PausedBadge.vue,TopicPauseControl.vue,TopicPane.vue,MessageCard.vue}`<br>• `csi-spl-wui/src/utils/{spool-client.mjs,spool-client-mock.mjs,spool-client-lazy.mjs,topic-pause.mjs,topic-menu.mjs,msg-menu.mjs}` (`mayPauseTopic` = `mayArchiveTopic` on the opening card, 3.1)<br>• `csi-spl-wui/i18n/locales/*.json` (all 19 locale files)<br>• `csi-spl-wui/tests/unit/topic-pause.test.mjs` + `csi-spl-wui/tests/e2e/topic-pause.test.mjs` | `pnpm run typecheck`, `pnpm run test:unit` (`i18n-parity`, `i18n-untranslated`, `i18n-no-raw-text`, `font-size`, `focus-tokens`, `cleancode`, `topic-pause`: `mayPauseTopic` follows `me.topicArchivePolicy` for `everyone`, `admins` and `starter`), and Chrome Playwright e2e `BASE_URL=<bundle> pnpm run test:e2e` verifying pause/resume in header & menu, `"Paused by ..."` attribution, inline notice, and `44 px` mobile tap target.<br>**Red control**: omit a locale key or hard-code raw template text -> `i18n-parity.test.mjs` / `i18n-no-raw-text.test.mjs` fails. |
| **B7** | `B3`, `B5`, `B6` | `specs_and_docs` | **CLI, fleet rules, and dispatcher documentation**:<br>• `csi-spl-doc/doc/md/{spool-cli-reference.md,fleet-rules-index.md}`<br>• `csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh` + `tests/check-fleet-rules-drift.tst.sh` | `cd csi-spl-iac && ./run -a do_check_dist_hygiene`, `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift`, `do_check_qto_doc_drift`.<br>**Red control**: broken path citation in `fleet-rules-index.md` -> `do_check_fleet_rules_drift` fails. |

*(Rows `B3`, `B4`, and `B6` touch disjoint file sets and can run in parallel as soon as `B2` lands and deploys.)*

**Row status**
- **B1** — built by lane `c-521` (issue **SPL-5980**), landed (R7 c-608 PASS on 5b4451d8d): rdb `0297_topic_pauses.sql`; store API `TopicPauseStore` in `internal/store/topic_pause.go`:
  - `SetTopicPaused(ctx, tenant, taskID, by, reason, at, paused)` answers `TopicPauseState{Pause, Changed, Followed}`. `Followed` is the issues it held or restored as `[]IssueFollow` with op `pause` / `resume` (`IssueFollowPause`, `IssueFollowResume`); the issue comments and `issue` frames of 3.3.1 and 4.2 are the hub's, through `afterIssueFollow` (`internal/hub/issue_follow.go`), in **B2**.
  - A repeat pause holds no issue and keeps the first `paused_by` / `paused_at`, storing only a new non-empty reason; a repeat resume changes nothing (`Changed` false on both).
  - `AnyTopicPaused(ctx, tenant, taskIDs...)` is the one primary key probe `onSend` uses in B2 (5.2 row 1).
  - `TopicRow.Pause` and `TopicAccess.Pause` carry the row (6.1): Postgres in the list's and the door's own statement, Memory under the same lock. The list statement's pins move with it, as for the topic priority (`898bd5082`): `testdata/view_topics_sql.golden`, the heads oracle in `topic_head_harness_test.go` and the orc copy `csi-spl-orc/src/bash/run/spl-db-hot-measure.stmt.sql`, each regenerated.
  - The three fallback queries skip a paused topic through their shared `fallbackHumanPostSQL` conjunct (5.2 row 8).
  - `crosstenant_test.go` `seedTenantAll` seeds both tables (dispatch holder decision, msg `4d406e69`).
  - A channel move or copy (spec 169) refuses while a topic of the channel is paused or a pause holds one of its issues: both tables are `Refuse` in `internal/channelmove/catalogue.go`, set `task_id = ANY(@tasks)` (and `number = ANY(@numbers)` for the held issues); resume first. `TestPlanChannelMoveRefusePausedTopic` (store, Postgres) shows the plan refusing, then passing after the resume (dispatch holder decision (A), msg `7c224426`). Moving the pause with the channel (`Moved`) is a spec 169 follow-up, not this row.

**Docs per row** (`csi-spl-doc/doc/md/lane-issue-and-docs.md`): B1..B6 change behaviour but the reference pages land in B7, so each of B1..B6 also updates this spec (its row's status line in this section, and any section its build changed from the text above). A row whose build matches this spec exactly changes no doc and carries `Docs: none (spec 179 section <n> already describes it; reference pages land in B7)` in its commit body. B7 is the doc row and needs neither.

**Commit rules for every row and for this spec's own landing commit**: the subject cites the row's issue in its scope (`feat(<area>, SPL-<n>): ...`; this spec: `docs(doc, SPL-5702): ...`), the body carries `Refs: SPL-2398` (the epic), and `Closes: SPL-<n>` is in the last paragraph. No `Co-Authored-By:`, `Generated with` or session-link trailer.

---

## 9. Decided (Owner Poll `2aee5c75`, Answer Msg `f88b925f-c6d3-4543-aa59-31bca267e050`)

The dispatcher asked the v0.2.0 questions as one poll in `t1` topic `a4b718a6`; the owner (`HUM-10`) answered in msg `f88b925f`. The poll's Answer 1, 2 and 3 are this spec's Q1, Q3 and Q4. v0.1.0's **Q2** (a stand-by variant) was dropped in v0.2.0: the owner had already decided it ("No need to stand by", msg `8f7feda6`).

| Q | Question | Owner's pick (verbatim) | Where it lands |
|---|---|---|---|
| **Q1** | Who may pause and resume the agents of a discussion? | **C** — Whoever the workspace's "Who can archive topics" policy allows (everyone, starter or admins) | Section 3.1 rewritten (v0.2.0 recommended A); 3.2, 4.1 and 6.3 point to it; B2 and B6 reuse the existing policy check (Section 8). |
| **Q3** | On Resume, how does work that a pause interrupted mid-wip restart? | **A** — Automatically: held asks unhold and each closed wip lane is re-enqueued as a fresh lane from its brief, wip snapshot and Restart card | Section 4.2 steps 2-3 already said this; only the Option B note is removed. |
| **Q4** | May a post in the discussion pause or resume its agents, beside the WUI button? | **A** — Both: the hub acts at once on an exact one-line directive (Pause all agents on this discussion.), and the dispatcher relays other phrasings with do_spl_topic_pause | Section 3.2 Door B (Layers B1 and B2) and 4.1 step 2 already said this; unchanged. |

No question is open.

Related: a saved prompt that runs on each reply in a discussion is [spec 182 topic loop prompt](../182-topic-loop-prompt/spec.md).

<!-- version: 0.3.0 · updated: 2026-11-19 · last-edit: 2026-11-19T18:00:00Z -->
