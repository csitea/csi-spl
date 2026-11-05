# Root-Cause Analysis: Never-Closed `"from_agent: <id>@<box>"` Blocker Issues (`SPL-4850`)

- **Version**: `v1.0`
- **Date**: `2026-11-05`
- **Epic / Spec**: `SPL-2398` (`csi-spl-doc/specs/157-dispatch-automation`)
- **Panel Issues**: `SPL-4850` (Editor `a-747`), `SPL-4851` (Hub Code Expert `c-754`), `SPL-4852` (Reviewer `c-756`)
- **Discussion**: `t1` topic `8c64225e-d82f-463f-af12-4dc4a0ecba35` (owner screenshot `ebd63d3d8b00040a497f26a0e3435440c15c17b02970d93738a13c333872d0b5` in `d9469b71` / `d8870eec`)
- **Evaluated Tree**: `origin/master` @ `3cceac64fe7f86671dda16b71dbde8a920d6eed3` and live `prd` Postgres (`t1`, read-only; box placeholders `<box-a>` and `<box-b>` denote the primary workstation box and the satellite box)

---

## 1. Root Cause (One Paragraph)

Every cross-box spool message sent through `spool-fleet-relay.sh` has `from_agent: <id>@<box>` prepended as line 1 of its body (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh:142`) and is signed under a seated proxy ID on the sending box (`SENDER`, lines `122-134`) whenever the real sender is unannounced there. While the receiving box's sidecar strips that line on local file delivery (`internal/hubclient/hubclient.go:979` calling `spool.WithFromAgent` in `internal/spool/fromagent.go:25-38`), the hub stores the raw body verbatim in `messages.body` with the proxy ID in `messages.from_id`. Every 1 minute (`cmd/spool/timeouts.go:9`, `cmd/spool/hub.go:147`), `SweepBlockerIssues` (`internal/hub/blocker_issue.go:110-149`) promotes any `kind='blocker'` message that receives no same-topic reply from its assignee within `blocker.issue_after_minutes` (default 3 min, `internal/store/blocker_issue.go:25-35`) into a `todo` issue under epic `SPL-2394` (`blocker_issue_epic.go:24`), taking the raw first non-empty line of `p.Body` as the issue title (`blockerTitle`, `blocker_issue.go:337-345`)—which is always `"from_agent: <id>@<box>"`. On `t1` `prd`, 88 of the 96 open `todo` issues are automated cross-box fleet alarms (watchdog restarts, limit screens, login screens, orchestrator-outcome stalls, `asks-open` nudges, `spawn-share` nudges, `push-orphan` alerts, `issue-closer-red` alerts, and `epic-stall` alerts) sent with `--kind blocker` on synthetic one-off or shared task UUIDs (`uuid5("spool-task:<slug>")`, `spool-fleet-relay.sh:161-164`) where the recipient acts on its box or in another topic rather than posting a reply back into the alarm's topic (`89/96` have zero assignee posts in `messages.task_id`); the remaining `7/96` have a later post by the assignee's bare ID in the same topic, `1d 07h .. 8d 01h` later, past the `24h` `blockerLongLookback` ceiling (`blocker_issue.go:69-70, 93-97`), after which the hub never inspects the blocker again. None of the 7 answers that blocker: 5 are unrelated later posts in the shared `uuid5("spool-task:<name>")` alarm topics (2 of which are also from the same bare ID on the other box), and 2 are other agents relayed under the assignee's proxy ID.

---

## 2. Evidence Table & Answers to Questions 1–3

### 2.1 Master Evidence Table

| Claim | Source Code (`file:line` on `3cceac64fe`) | SQL / Empirical Proof on `prd` (`t1`) | Representative Issue IDs |
| :--- | :--- | :--- | :--- |
| Cross-box relay prepends `from_agent: $FROM@$BOX` as line 1 of `messages.body` | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh:142` | `96/96` open `todo` issues with `labels @> '{blocker}'` in `t1` have `title LIKE 'from_agent: %'` and `m.from_box <> m.to_box` | All 96 open (`SPL-1587` .. `SPL-4783`) |
| `WithFromAgent` strips `from_agent:` only on the receiving sidecar, never in hub `store` or `SweepBlockerIssues` | `csi-spl-api/src/go/spool-hub-api/internal/spool/fromagent.go:25-38`; called only at `internal/hubclient/hubclient.go:979` | `SELECT count(*) FROM issues WHERE tenant_id='t1' AND status='todo' AND deleted_at IS NULL AND archived_at IS NULL AND title LIKE 'from_agent:%'` -> `96` | `SPL-4783`, `SPL-4682..4691`, `SPL-4480..4487` |
| `blockerTitle(p)` uses raw first non-empty line of `p.Body` without stripping `from_agent:` | `csi-spl-api/src/go/spool-hub-api/internal/hub/blocker_issue.go:337-345` | Line 1 of `m.body` is `from_agent: <id>@<box>`; line 2 is the real subject (e.g. `WATCHDOG RESTART (102 4.1): ...`) | All 96 open `todo` issues + 44 archived `done` issues + 1 `diss` (`SPL-1555`) |
| Hub loop runs every `1m` and files a `todo` issue under epic `SPL-2394` (`priority=5`, `labels=['blocker']`) after `>=3m` without same-topic reply | `cmd/spool/timeouts.go:9`, `cmd/spool/hub.go:147`, `internal/hub/blocker_issue.go:82-224`, `internal/hub/blocker_issue_epic.go:24,94-106`, `internal/store/blocker_issue.go:25-35` | `96/96` open rows have `parent_number = 2394`, `priority = 5`, `level = 2`, `labels = '{blocker}'`, `created_by = m.from_id`, and `i.created_at - m.received_at` from `00:03:00.67` (min) to `23:14:45.88` (max) | `SPL-4783` (`m.received_at = 09:53:36Z`, `i.created_at = 09:56:58Z`) |
| Unannounced cross-box sender is proxied via seated `SENDER`, recording proxy in `messages.from_id` and `issues.created_by` | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh:112-134` | `22/96` open issues have `m.from_id <> split_part(regexp_replace(i.title,'^from_agent: ',''),'@',1)`: `c-003` proxies **17** (`16` to `c-001`, `1` to `c-002`), `a-289` proxies **3**, `c-001` proxies **1** (`SPL-3368`), `c-087` proxies **1** (`SPL-3285`) | `SPL-4682..4690` (`c-001@<box-a>` via `c-003`), `SPL-3855..3857` (`c-001@<box-b>` via `a-289`), `SPL-3368` (`c-180@<box-b>` via `c-001`), `SPL-3285` (`g-001@<box-a>` via `c-087`) |
| Self-send filter `Assignees()` seeds `seen[bareID(p.FromID)]` with the proxy ID instead of `from_agent:`, filing self-blockers whenever proxied | `csi-spl-api/src/go/spool-hub-api/internal/store/blocker_issue.go:58-70` | `19/96` open issues have `assignee = real_from`: **16** are `c-001@<box-a> -> c-001` via proxy `c-003` and **3** are `c-001@<box-b> -> c-001` via proxy `a-289`; unproxied `c-001 -> c-001` is dropped (`msg 270b52d0`, twin of `SPL-4783`, filed nothing) | `SPL-4682..4690` (9), `SPL-4480..4485` (6), `SPL-3859` (1), `SPL-3855..3857` (3) |
| 88 of 96 open issues are automated cron/watchdog/nudge alarms using `--kind blocker` on synthetic task slugs | `spl-agent-restart.func.sh:831`, `spl-watchdog.func.sh:1230-1231,1273-1274`, `spl-asks-tick.func.sh:173`, `spl-spawn-place.func.sh:290`, `spl-wd-orch-outcome.func.sh:72`, `spl-push-orphan-check.func.sh:168`, `issue-close-landed-cron.sh:88,97`, `spl-epic-stall-check.func.sh:228,233` | Grouping `96` open issues by line 2 of `m.body`: 29 `WATCHDOG RESTART`, 24 `WATCHDOG kind=limit`, 11 `ASKS STILL OPEN`, 9 `SPAWN SHARE`, 7 `WATCHDOG login`, 4 `WATCHDOG orch-outcome`, 2 `push-orphan`, 1 `ISSUE CLOSER RED`, 1 `epic stalled`, 8 hand-written | See Section 2.2 & Section 2.4 tables |
| `89/96` open issues have `0` subsequent posts by `bareID(assignee)` in `m.task_id` | `csi-spl-api/src/go/spool-hub-api/internal/store/blocker_issue.go:183-195`; `spool-fleet-relay.sh:161-164` (`uuid5(NAMESPACE_URL, "spool-task:" + task)`) | `55/96` have no later post in the topic; `34/96` have later posts by others, never by `bareID(assignee)` (mostly later alarms in shared `uuid5("spool-task:<name>")` topics or peer/sender replies) | `SPL-4783` (answered by `c-001@<box-b>` + closed with `result` by `c-001@<box-a>`, not `c-002`) |
| `7/96` open issues received a same-topic post matching `bareID(assignee)`, `1d 07h .. 8d 01h` later—past the hard `24h` `blockerLongLookback` cutoff—and **0 of the 7** actually answer their blocker | `csi-spl-api/src/go/spool-hub-api/internal/hub/blocker_issue.go:69-70, 93-97, 131-132` (`blockerShortLookback = time.Hour`, `blockerLongLookback = 24 * time.Hour`) | All 7 have `first_assignee_reply - m.received_at` between `1d 07h 07m` (`SPL-4360`) and `8d 00h 53m` (`SPL-3244`); 5 are unrelated posts in shared alarm topics (2 also from the other box) and 2 are proxy false matches | `SPL-1588`, `SPL-2730`, `SPL-2769`, `SPL-3244`, `SPL-3355`, `SPL-3901`, `SPL-4360` |
| `FirstPostAfter` matches any later post in `task_id` by bare `messages.from_id`, causing proxy, other-box, and shared-topic false matches and missing proxied replies | `csi-spl-api/src/go/spool-hub-api/internal/store/blocker_issue.go:183-195` (`from_id = $4 OR from_id LIKE $4 || '@%'`) | Across the 7 late matches: **2 proxy** (`SPL-2730` `c0ab8fcb`, `SPL-3355` `ff9854bc`), **2 same bare ID on the other box** in shared topics (`SPL-1588` `6277957d`, `SPL-2769` `4067d446`), and **3 replies to later alarms** in shared topics (`SPL-3244, 3901` `e53626a5`, `SPL-4360` `b3ababeb`) | `SPL-1588`, `SPL-2730`, `SPL-2769`, `SPL-3244`, `SPL-3355`, `SPL-3901`, `SPL-4360` |

---

### 2.2 Question 1: Who files these issues, from which message, and why is the title `"from_agent: <agent>"` instead of the blocker's words?

#### 1. Who files them
The `spool-hub-api` background goroutine `RunBlockerIssues` -> `SweepBlockerIssues` (`csi-spl-api/src/go/spool-hub-api/internal/hub/blocker_issue.go:82-149`), started at `BlockerInterval = time.Minute` (`cmd/spool/timeouts.go:9`, `cmd/spool/hub.go:147`), scans `messages` rows with `kind = 'blocker'` and `archived_at IS NULL` (`internal/store/blocker_issue.go:164-180`). When a blocker message is older than `blocker.issue_after_minutes` (`default 3`, `internal/store/blocker_issue.go:25-35`) and `FirstPostAfter` finds no reply in `p.TaskID` from assignee `a`, `blockerCreate` -> `blockerIssueOn` (`internal/hub/blocker_issue.go:171-224`) creates an issue with:
- `status = "todo"`, `priority = 5` (store default), `labels = ["blocker"]`
- `parent_number = 2394` (`SPL-2394`, `"Area: unanswered blockers - issues with no spec"`, `internal/hub/blocker_issue_epic.go:24, 94-106`)
- `created_by = p.FromID`, `assignee = a` (bare ID from `p.Assignees()`)
- `task_id = BlockerIssueTask(tenant, p.MsgID, a)` (`uuid.FromSeed("spool-blocker-issue:" + tenant + ":" + msgID + ":" + bareID(assignee))`, `internal/store/blocker_issue.go:106-108`)
- `description` built by `blockerDescription` (`internal/hub/blocker_issue.go:347-351`) and `blockerQuote` (`:354-356`), containing `[Open the message](/m/<msg_id>) in topic <task_id>`.

#### 2. Why the title is `"from_agent: <id>@<box>"` instead of the blocker's words
1. Every cross-box spool message is transmitted by `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh`. At line `142`, the relay prepends the real sender's identity onto line 1 of the message body before calling `spool hub-send`:
   ```bash
   BODY="from_agent: $FROM@${SIDEBOX:-$BOX}"$'\n'"$BODY"
   ```
2. On the receiving box, `hubclient` calls `spool.WithFromAgent(m, fromBox)` (`csi-spl-api/src/go/spool-hub-api/internal/hubclient/hubclient.go:979`, defined at `internal/spool/fromagent.go:25-38`), which parses line 1 (`from_agent: <id>@<box>`), sets `c.From = id + "@" + box` and `c.Body = rest` (`fromagent.go:34-36`) in the local JSON file delivered to `/var/spool-hub/<agent>/inbox`, and drops line 1 from the body.
3. However, **the hub database itself never calls `spool.WithFromAgent`**. The hub stores the raw `BODY` (with `from_agent: <id>@<box>` on line 1) in `messages.body` and the relay proxy `SENDER` in `messages.from_id`.
4. When `SweepBlockerIssues` creates the issue, `blockerTitle(p store.BlockerPost)` (`internal/hub/blocker_issue.go:337-345`) takes the first non-empty line of `p.Body`:
   ```go
   func blockerTitle(p store.BlockerPost) string {
   	for _, line := range strings.Split(p.Body, "\n") {
   		line = strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(line), "#> "))
   		if line != "" {
   			return cutRunes(line, store.IssueTitleMax)
   		}
   	}
   	return "Blocker from " + p.FromID
   }
   ```
   Because line 1 of `p.Body` on every cross-box message is `from_agent: <id>@<box>`, `blockerTitle(p)` always returns `"from_agent: <id>@<box>"` and pushes the real subject line (line 2 of `p.Body`) into `issues.description`.

#### 3. Proxy sender distortion (`SPL-3865` interaction) and self-blocker filing bug
When `$FROM` is not announced on the sending box (for example, `c-001@<box-a>` when the `c-001` lease is held by `<box-b>`, or a lane agent `c-632@<box-a>` / `g-493@<box-a>`), `spool-fleet-relay.sh:112-134` picks a seated proxy on the sending box (`SENDER`). Across the 96 open issues, **22 rows** have `messages.from_id <> real_from`: `c-003` proxies **17** (`16` to `c-001` [`SPL-3859, 4480..4485, 4682..4690`], `1` to `c-002` [`SPL-3901`]), `a-289` proxies **3** (`SPL-3855..3857` to `c-001`), `c-001` proxies **1** (`c-180@<box-b>` to `g-003`, `SPL-3368`), and `c-087` proxies **1** (`g-001@<box-a>` to `c-002`, `SPL-3285`). This causes two defects in `SweepBlockerIssues`:
- **Wrong `created_by`**: `issues.created_by` is set to `p.FromID` (`96/96` match `m.from_id`), recording the proxy ID on all 22 proxied rows rather than the sender named in `from_agent:`.
- **Broken self-send suppression (`BlockerPost.Assignees`)**: `Assignees()` (`internal/store/blocker_issue.go:58-70`) seeds `seen := map[string]bool{bareID(p.FromID): true}` to avoid filing an issue against the sender of the blocker. When `c-001@<box-a>` is announced on `<box-a>` (`p.FromID = "c-001"`) and sends a blocker to `c-001@<box-b>` (`p.ToID = "c-001"`), `bareID("c-001") == bareID("c-001")` drops the recipient (for example, `SPL-4783`'s twin message `270b52d0` from `<box-a>/c-001` to `<box-b>/c-001` filed nothing). Conversely, when `c-001` is unannounced on the sending box and proxied through `c-003` or `a-289`, `bareID(p.FromID) != "c-001"`, so the hub files a self-blocker assigned to `c-001` (**19 of the 96 open issues**: 16 from `c-001@<box-a>` via `c-003` [`SPL-3859, 4480..4485, 4682..4690`] and 3 from `c-001@<box-b>` via `a-289` [`SPL-3855..3857`]).

#### 4. Which messages produced the 96 open `todo` issues in `t1`
All 96 open `todo` blocker issues in `t1` (`prd`) come from cross-box DMs (`channel IS NULL`, `kind = 'blocker'`, `from_box <> to_box`). Grouping all 96 by line 2 of `messages.body` identifies their exact senders:

| Category | Count | Line 2 Pattern (Real Subject) | Sender Script (`file:line`) | Task Flag Passed | Issue Numbers (`SPL-*`) |
| :--- | ---: | :--- | :--- | :--- | :--- |
| 1. Watchdog restart alert | **29** | `WATCHDOG RESTART (102 4.1): <id> on <box> was restarted ...` | `csi-spl-orc/src/bash/run/spl-agent-restart.func.sh:831` | `--task "wd-$id-$ts"` | `2684..2687, 3308..3309, 3316..3324, 3855..3857, 3859, 4682..4691` |
| 2. Watchdog limit screen | **24** | `WATCHDOG (093 S2 kind=limit): <id> on <box> hit a usage/rate limit ...` | `csi-spl-orc/src/bash/run/spl-watchdog.func.sh:1273-1274` | `--task "wd-$id"` | `3237, 3239..3242, 3265, 3267..3269, 3271..3272, 3275, 3277, 3279, 3333, 3336, 3358..3359, 4480..4485` |
| 3. Open asks nudge | **11** | `**ASKS STILL OPEN (<N>, oldest <M>m)**: ...` | `csi-spl-orc/src/bash/run/spl-asks-tick.func.sh:173` | `--task asks-open` | `1588, 1690, 2614, 2727, 2882, 2884, 2885, 3835, 3837, 3842, 3850` |
| 4. Spawn share nudge | **9** | `**SPAWN SHARE: <box> holds <X>% of running fleet agents** ...` | `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:290` | `--task spawn-share` | `2718, 2719, 2721, 2767, 2768, 3355, 3370, 4360, 4487` |
| 5. Watchdog login screen | **7** | `WATCHDOG (093 S2): <id> on <box> is sitting at a login or access screen ...` | `csi-spl-orc/src/bash/run/spl-watchdog.func.sh:1230-1231` | `--task "wd-$id"` | `3246..3248, 3310..3311, 3313..3314` |
| 6. Watchdog orch outcome | **4** | `WATCHDOG (SPL-1717): the orchestrator role on <box> has produced no outcome ...` | `csi-spl-orc/src/bash/run/spl-wd-orch-outcome.func.sh:72` | `--task orch-outcome` | `2769, 3244, 3369, 3901` |
| 7. Push-orphan alert | **2** | `**push-orphan@<box-a>** — commits on origin/master ...` | `csi-spl-orc/src/bash/run/spl-push-orphan-check.func.sh:168` | `--task dispatch-push-orphan` | `2883, 3285` |
| 8. Issue-closer red alert | **1** | `ISSUE CLOSER RED on box <box-b>: the last <N> ticks ...` | `csi-spl-orc/src/bash/scripts/issue-close-landed-cron.sh:88,97` | `--task dispatch-issue-closer` | `2730` |
| 9. Epic stall alert | **1** | `**Blocker: epic SPL-2151 has stalled** ...` | `csi-spl-orc/src/bash/run/spl-epic-stall-check.func.sh:228,233` | `$task` (`spl_spawn_q_task <topic>`) | `2720` |
| 10. Hand-written agent/role blockers | **8** | Agent/orchestrator cross-box blockers on task threads | `agent-send.sh` / `spool-send.sh` -> `spool-fleet-relay.sh` | Task thread UUID or slug | `1587, 1589, 1691, 3368, 3499, 4056, 4486, 4783` |
| **Total** | **96** | | | | |

---

### 2.3 Question 2: Why does none of them close?

We tested all three hypotheses from the brief against `csi-spl-api` and `prd` Postgres:

1. **Is the link back to the blocker message missing?** **No.**
   Every one of the 96 open `todo` issues contains a valid `[Open the message](/m/<msg_id>)` link in `issues.description`, and all 96 referenced `messages.msg_id` rows exist in `t1` with `archived_at IS NULL` and `kind = 'blocker'`. Furthermore, when an assignee *does* post in the same `task_id` within 24 hours, the auto-closer works: **44 historical `from_agent:` blocker issues in `t1` transitioned to `done`** (now archived) with the hub comment `"Resolved by the answer of @<id> in the discussion."` (`internal/hub/blocker_issue.go:240-266`).

2. **Is the blocker never answered in the blocker's topic, or does the answer arrive where/when the closer does not look?** **The blockers are never answered by their assignees in the blocker's topic (`0/96` have a real assignee answer; `89/96` have zero posts matching `bareID(assignee)` and `7/96` have unrelated later posts matching `bareID(assignee)` after the `24h` `blockerLongLookback` cutoff), compounded by three matcher defects in `SweepBlockerIssues`:**

   - **Mechanism A (`89/96` open issues): Zero posts by `bareID(assignee)` in `messages.task_id` (`assignee_replies = 0`).**
     Across the 89 issues with zero posts matching `bareID(assignee)`, **55 have no later post in the topic at all**, and **34 have later posts by others, never by the assignee** (mostly later alarms in the shared `uuid5("spool-task:<name>")` topics such as `asks-open` `c83bdc7f`, `spawn-share` `f481f9ba`, and `orch-outcome` `8546306f`, or replies from another seat).
     - **81 of the 89** are automated one-way operational alarms (`WATCHDOG RESTART` 29, `WATCHDOG limit` 24, `ASKS STILL OPEN` 10, `SPAWN SHARE` 7, `WATCHDOG login` 7, `push-orphan` 2, `WATCHDOG orch-outcome` 1, `epic-stall` 1). `spool-fleet-relay.sh:161-164` maps each non-UUID `--task <name>` into a synthetic v5 topic UUID via `uuid5(NAMESPACE_URL, "spool-task:" + name)`. When the receiving orchestrator or dispatch holder handles the alarm—by restarting/checking an agent, running `do_spl_ask_ack`, or spawning on the under-loaded box—no reply message is posted into `uuid5("spool-task:wd-...")` or `uuid5("spool-task:asks-open")`.
     - **8 of the 89** are hand-written cross-box blockers where work continued either on local spool, on another topic, or via another peer seat in the same topic:
       - `SPL-4783` (`2026-11-04`, `c-001@<box-a> -> c-002`, topic `fb7c0bf2-ef77-51fd-9b57-904795a3af6d`): `c-001@<box-a>` asked `c-002@<box-b>` at `09:53:36Z` (`msg 810affc7`) whether to re-post `af280ac8`. Thirty-five seconds later (`09:54:11Z`), `c-001@<box-b>` answered with `GO` (`msg 3f26318f`), and at `09:55:28Z` (`4aecc476`) and `09:55:37Z` (`5152bbaf`) `c-001@<box-a>` posted `kind='result'` (`"fb7c0bf2 done: the formatted re-post of af280ac8 is live"`). Because `FirstPostAfter` checks **only** for a post from assignee `c-002` and ignores both `c-001@<box-b>`'s `GO` and the sender's own `kind='result'` completion post, `SweepBlockerIssues` still filed `SPL-4783` at `09:56:58Z`—**81 seconds after the task was already finished**—and never closed it.
       - `SPL-4486` (`2026-10-30`, `c-632@<box-a> -> c-003`, topic `361c18a8-e807-5982-8653-dc78d3b100c6`): `c-632@<box-a>` sent `msg 09824eb5` (`10:05:30Z`); dispatch holder `c-002@<box-b>` answered 29 seconds later (`msg 4d897b56` at `10:05:59Z`, `"re BLOCKER 09824eb5: C. Retry the review push now"`), and `c-632@<box-a>` posted `kind='result'` `45800bfe` (`"SPL-4187 landed"`) at `13:35:44Z`. Because `c-003` never posted in that topic, `SPL-4486` remained `todo`.
       - `SPL-4056` (`2026-10-28`, `g-493@<box-a> -> c-527`, topic `9da17538-1993-5f91-80f9-ab8f41c17f18`): `g-493@<box-a>` sent review blocker `f9e03082` (`17:01:55Z`) to lane agent `c-527@<box-b>`; subsequent rounds landed and `c-002@<box-b>` posted `ACCEPTED` (`14199fa7`) in the same topic.

   - **Mechanism B (`7/96` open issues): Hard `24h` `blockerLongLookback` window (`internal/hub/blocker_issue.go:69-70, 93-97, 131-132`), with `0/7` late matches being real answers to their blocker.**
     `SweepBlockerIssues` only queries `BlockerPosts` with `received_at` between `due - lookback` and `due`, where `lookback` is `1h` (`blockerShortLookback`) on 9 of 10 ticks and `24h` (`blockerLongLookback`) on every 10th tick. Once a blocker message is older than `24h + 3m`, **`BlockerPosts` never returns that message again**, so `blockerResolve` is never called after 24 hours. In `prd`, 7 of the 96 open issues have a later post in `task_id` matching `bareID(assignee)` after `1d 07h .. 8d 01h`, **but inspecting the post bodies shows that 0 of the 7 actually answer their blocker** (5 are unrelated posts in shared alarm topics, and 2 are other agents relayed under a shared proxy):

| Issue | Title (`from_agent:`) | `created_by` | Assignee (`to_box`) | Category | Blocker `received_at` (UTC) | First Same-Topic Post Matching `bareID(assignee)` | Delay | What the Matching Post Is |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `SPL-1588` | `from_agent: c-001@<box-b>` | `c-001` | `c-002` (`<box-a>`) | `ASKS STILL OPEN` | `2026-10-12 16:26:32Z` | `2026-10-19 12:51Z` (`6277957d`) | `6d 20h` | `<box-b>/c-002`'s `"**Status card**: edited in place..."` in the shared `asks-open` topic (and on the other box; target was `c-002@<box-a>`) |
| `SPL-2730` | `from_agent: g-002@<box-b>` | `g-002` | `c-001` (`<box-a>`) | `ISSUE CLOSER RED` | `2026-10-20 14:55:13Z` | `2026-10-22 01:31Z` (`c0ab8fcb`) | `1d 10h` | **False proxy match**: `c-826@<box-a>` relayed under `from_id='c-001'` |
| `SPL-2769` | `from_agent: g-001@<box-a>` | `g-001` | `g-002` (`<box-b>`) | `WATCHDOG (SPL-1717)` | `2026-10-21 17:13:20Z` | `2026-10-27 11:16Z` (`4067d446`) | `5d 18h` | `g-002@<box-a>`'s `"Forward ... c-001@<box-a> msg f3c4f87c ..."` about another message in shared `orch-outcome` (and on the other box; target was `g-002@<box-b>`) |
| `SPL-3244` | `from_agent: c-001@<box-a>` | `c-001` | `c-002` (`<box-b>`) | `WATCHDOG (SPL-1717)` | `2026-10-23 17:13:11Z` | `2026-10-31 18:06Z` (`e53626a5`) | `8d 01h` | `c-002@<box-b>`'s `"re WATCHDOG b065a70a"`, answering the later `2026-10-31` alarm in shared `orch-outcome`, not `471d5525` |
| `SPL-3355` | `from_agent: c-001@<box-a>` | `c-001` | `c-003` (`<box-b>`) | `SPAWN SHARE` | `2026-10-25 14:18:24Z` | `2026-10-27 17:07Z` (`ff9854bc`) | `2d 03h` | **False proxy match**: `c-001@<box-a>` relayed under `from_id='c-003'` |
| `SPL-3901` | `from_agent: c-001@<box-a>` | `c-003` | `c-002` (`<box-b>`) | `WATCHDOG (SPL-1717)` | `2026-10-27 22:40:18Z` | `2026-10-31 18:06Z` (`e53626a5`) | `3d 19h` | `c-002@<box-b>`'s `"re WATCHDOG b065a70a"`, answering the later `2026-10-31` alarm in shared `orch-outcome`, not `848e5bf5` |
| `SPL-4360` | `from_agent: c-001@<box-a>` | `c-001` | `c-002` (`<box-b>`) | `SPAWN SHARE` | `2026-10-30 11:01:29Z` | `2026-10-31 18:08Z` (`b3ababeb`) | `1d 07h` | `c-002@<box-b>`'s `"re SUPPLY LEAD e99e3254"` in shared `spawn-share`, not an answer to `20cfa348` |

   - **Mechanism C: Proxy, other-box, and shared-topic matcher defects in `FirstPostAfter` (`internal/store/blocker_issue.go:183-195`).**
     `FirstPostAfter` checks `from_id = $4 OR from_id LIKE $4 || '@%'` against `bareID(from)` for any later post in `task_id`:
     1. **False-positive match on shared proxy or other box (measured in 4 of the 7 rows above)**: In **4 of the 7** late-reply rows—**2 by proxy** (`SPL-2730` via `c0ab8fcb`, `SPL-3355` via `ff9854bc`) and **2 by same bare ID on the other box** (`SPL-1588` via `6277957d` from `<box-b>/c-002` when the blocker targeted `c-002@<box-a>`, and `SPL-2769` via `4067d446` from `g-002@<box-a>` when the blocker targeted `g-002@<box-b>`)—the matching post is not from the target `id@box`.
     2. **False-negative miss on proxied reply (code-path inference from `blocker_issue.go:183-195` + `spool-fleet-relay.sh:122-134`)**: Any cross-box reply from an unannounced agent has its proxy in `messages.from_id`, which `FirstPostAfter` never matches to the real sender in `from_agent:`.
     3. **Shared alarm topic false-positive (measured in 5 of the 7 rows above)**: `FirstPostAfter` takes **any** later post by the assignee in the topic as the answer. One `uuid5("spool-task:<name>")` topic holds every alarm of that name, so the assignee's answer to the newest alarm (or any status card/forward) resolves every older blocker in that topic (`SPL-1588, 2769, 3244, 3901, 4360`). Inside 24 h this already closes issues on non-answers.

---

### 2.4 Question 3: How many open issues share the pattern today, and are any of them real unanswered work the owner should see?

#### 1. Reproducible SQL Query (`prd`)
```sql
SELECT tenant_id, status,
       archived_at IS NOT NULL AS archived,
       deleted_at IS NOT NULL AS deleted,
       CASE WHEN title LIKE 'from_agent:%' THEN 'from_agent_prefix' ELSE 'normal_title' END AS title_kind,
       count(*)
FROM issues
WHERE labels @> ARRAY['blocker'] OR title LIKE 'from_agent:%'
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2, 3, 4, 5;
```

#### 2. All-Time Blocker / `from_agent:` Issue Counts Across All Tenants (`prd`)

| Tenant | Status | Archived | Deleted | `from_agent:` Title | Normal Title | Total |
| :--- | :--- | :--- | :--- | ---: | ---: | ---: |
| `t1` | `todo` | `false` | `false` | **96** | **0** | **96** |
| `t1` | `diss` | `false` | `false` | **1** (`SPL-1555`) | **0** | **1** |
| `t1` | `todo` | `true` | `false` | 0 | 10 | 10 |
| `t1` | `todo` | `false` | `true` | 1 | 4 | 5 |
| `t1` | `done` | `true` | `false` | 44 | 220 | 264 |
| `t1` | `diss` | `true` | `false` | 0 | 175 | 175 |
| `csitea` | `todo` | `false` | `false` | 0 | 1 | 1 |
| `<other-tenants>` (2 workspaces) | `todo` | `false` | `false` | 0 | 3 | 3 |

*(Note: In the owner's screenshot `ebd63d3d...`, the WUI filter is `status=todo&priority=5&fold=diss,blocked`. The top row `SPL-4836`—`"Done-claim check: a listed clone can name its trunk ref and outrun a stale default branch"` under `Area: refactoring`—has `labels = '{}'` (not a blocker issue) and `priority = 5`; the remaining 96 open `todo` rows matching `labels @> '{blocker}'` in `t1` are 100% `from_agent:` issues under `SPL-2394`.)*

#### 3. Breakdown of the 96 Live `todo` Issues in `t1`

**By Title (`issues.title`, where `<box-a>` is the primary workstation box and `<box-b>` is the satellite box)**:

| Title | Open `todo` Count |
| :--- | ---: |
| `from_agent: c-001@<box-a>` | 31 |
| `from_agent: c-001@<box-b>` | 29 |
| `from_agent: g-001@<box-a>` | 29 |
| `from_agent: g-001@<box-b>` | 2 |
| `from_agent: c-003@<box-a>` | 1 (`SPL-1587`) |
| `from_agent: c-180@<box-b>` | 1 (`SPL-3368`) |
| `from_agent: c-632@<box-a>` | 1 (`SPL-4486`) |
| `from_agent: g-002@<box-b>` | 1 (`SPL-2730`) |
| `from_agent: g-493@<box-a>` | 1 (`SPL-4056`) |
| **Total** | **96** |

**By Assignee (`issues.assignee`, rendered with `@<box>` by WUI roster lookup)**:

| Assignee | Open `todo` Count |
| :--- | ---: |
| `c-001` | 42 |
| `g-001` | 19 |
| `c-002` | 17 |
| `c-003` | 7 |
| `g-002` | 7 |
| `g-003` | 3 |
| `c-527` | 1 |
| **Total** | **96** |

**By Age (`issues.created_at::date`, UTC)**:

| Created Date (UTC) | Age (vs `2026-11-05`) | Count | Issue Numbers (`SPL-*`) |
| :--- | :--- | ---: | :--- |
| `2026-11-04` | 1 day | 1 | `4783` |
| `2026-11-03` | 2 days | 10 | `4682..4691` |
| `2026-10-31` | 5 days | 8 | `4480..4487` |
| `2026-10-30` | 6 days | 1 | `4360` |
| `2026-10-28` | 8 days | 1 | `4056` |
| `2026-10-27` | 9 days | 9 | `3835, 3837, 3842, 3850, 3855..3857, 3859, 3901` |
| `2026-10-26` | 10 days | 1 | `3499` |
| `2026-10-25` | 11 days | 27 | `3275, 3277, 3279, 3285, 3308..3311, 3313..3314, 3316..3324, 3333, 3336, 3355, 3358..3359, 3368..3370` |
| `2026-10-24` | 12 days | 15 | `3237, 3239..3242, 3244, 3246..3248, 3265, 3267..3269, 3271..3272` |
| `2026-10-22` | 14 days | 4 | `2882..2885` |
| `2026-10-21` | 15 days | 3 | `2767..2769` |
| `2026-10-20` | 16 days | 10 | `2684..2687, 2718..2721, 2727, 2730` |
| `2026-10-19` | 17 days | 1 | `2614` |
| `2026-10-13` | 23 days | 5 | `1587..1589, 1690..1691` |
| **Total** | | **96** | |

#### 4. Are any of the 96 open issues real unanswered work the owner should see?
**No open action was found across the 96 `from_agent:` blocker issues:**

1. **88 automated cron/watchdog/nudge alarms (`Categories 1–9`)**:
   - 87 of the 88 are historical point-in-time operational telemetry (`WATCHDOG RESTART`, `WATCHDOG kind=limit`, `WATCHDOG login`, `WATCHDOG orch-outcome`, `ASKS STILL OPEN`, `SPAWN SHARE`, `push-orphan`, `ISSUE CLOSER RED`) from `2026-10-12` through `2026-11-03`.
   - The 1 epic-stall alarm (`SPL-2720`, filed `2026-10-20 06:04Z` for `**Blocker: epic SPL-2151 has stalled** (Security scan actions (10), two lanes at a time)`) points to epic `SPL-2151`, which is already tracked directly as an open `wip` epic in `t1` (`SPL-2151` itself remains open; `SPL-2720` is a duplicate stall-ping issue).
2. **8 hand-written agent/role blockers (`Category 10`) — each checked against `messages` in `t1` (`prd`)**:
   - **`SPL-4783`** (`2026-11-04`, `c-001@<box-a> -> c-002`, `msg 810affc7`, topic `fb7c0bf2-ef77-51fd-9b57-904795a3af6d`): **Resolved in topic 81s before filing.** `c-001@<box-b>` gave `GO` at `09:54:11Z` (`msg 3f26318f`) and `c-001@<box-a>` posted `RESULT` `"fb7c0bf2 done: the formatted re-post of af280ac8 is live"` at `09:55:28Z` (`4aecc476`) and `09:55:37Z` (`5152bbaf`).
   - **`SPL-4486`** (`2026-10-30`, `c-632@<box-a> -> c-003`, `msg 09824eb5`, topic `361c18a8-e807-5982-8653-dc78d3b100c6`): **Resolved in topic.** Dispatch holder `c-002@<box-b>` answered 29s later (`msg 4d897b56` at `10:05:59Z`), `c-632@<box-a>` posted `RESULT` `"SPL-4187 landed"` (`msg 45800bfe` at `13:35:44Z`, commits `28598b91c`, `7a5ee431f`, `a1dd6eebd`), and `SPL-4187` is `done`.
   - **`SPL-4056`** (`2026-10-28`, `g-493@<box-a> -> c-527`, `msg f9e03082`, topic `9da17538-1993-5f91-80f9-ab8f41c17f18`): **Resolved in topic.** Round 36 review blocker on `114-scroll-canvas-perf`; `g-493@<box-a>` acked `GO` (`eb228c5c`), rounds 36–41 landed, and `c-002@<box-b>` posted `ACCEPTED: round 41 cut (SPL-4302)` (`msg 14199fa7`).
   - **`SPL-3368`** (`2026-10-25`, `c-180@<box-b> -> g-003`, `msg ee113a75`, topic `f948a410-f536-5069-b29c-4ad8e3339485`): **Resolved in topic.** Slogan review request for `SPL-3342`; `c-002@<box-b>` answered with `GO` (`msg 84c8cdbd` at `18:03:58Z`), and `SPL-3342` closed `done` at `2026-10-25 17:40:22Z`.
   - **`SPL-1589`** (`2026-10-12`, `c-001@<box-a> -> c-002`, `msg 6e010548`, topic `1226651b-b13c-568d-bde8-ea916cea7034`): **Resolved in topic.** Relayed `16:45Z` owner order to reboot `<box-b>` and update orchestrator priority; `<box-b>` reported back up 2m29s later (`msg abee1b8f` at `16:47:43Z`) and `<box-a>` confirmed rank applied (`msg 264ac014`, `3d9e9155` at `16:53:51Z..17:02:52Z`).
   - **`SPL-3499`** (`2026-10-26`, `c-001@<box-a> -> c-002`, `msg fa8b52df`, topic `0f114800-e7e9-50a4-9fcc-7d5359a6ff5e`): **No later post in topic (`0` replies); no open action found.** Relayed a `2026-10-26` terminal priority order for `#development` topics `a82c4a5b` and `55fd7531` (handled in those topics).
   - **`SPL-1691`** (`2026-10-13`, `c-001@<box-a> -> c-003`, `msg c8a1b8a2`, topic `715e9385-9b20-5066-863c-4dffa05f4d15`): **No later post in topic (`0` replies); no open action found.** Reported a Claude weekly limit that reset `2026-10-17T08:00Z`.
   - **`SPL-1587`** (`2026-10-12`, `c-003@<box-a> -> c-002`, `msg 9631c8f3`, topic `eac77771-f6fa-5224-88ac-aad2af59c362`): **No later post in topic (`0` replies); no open action found.** Relayed a `2026-10-12` agent OS account login handoff (`msg 1ae53895`) on `<box-a>`.

*(Separately, `SPL-4836` at the top of the owner's screenshot is a normal, non-blocker `todo` bug issue under `Area: refactoring` and must remain untouched.)*

---

## 3. Ranked Fix Options (Question 4)

A complete fix has three parts:
- **Part A**: Stop the wrong filings and fix `from_agent:` title/sender/reply handling.
- **Part B**: Close the 96 existing `from_agent:` `todo` issues (and `SPL-1555`) cleanly.
- **Part C**: Guard against silent regression with tests and a sweep invariant that does not abandon open blocker issues after 24 hours.

### Part A — Stop Wrong Filings & Fix `from_agent:` Handling (Ranked)

#### Option A1 (Recommended): Normalize `from_agent:` in hub blocker/store path + switch one-way cron nudges to `--kind note --ask blocker` + fix `FirstPostAfter` `id@box` identity matching
- **What changes & where**:
  1. **Strip and normalize `from_agent:` on `BlockerPost` via a new helper**: In `csi-spl-api/src/go/spool-hub-api/internal/store/blocker_issue.go` (`BlockerPosts`, lines `164-180`, using a new helper alongside `spool.WithFromAgent` in `internal/spool/fromagent.go`), extract `from_agent: <id>@<box>` from `p.Body` before computing `blockerTitle(p)` (`internal/hub/blocker_issue.go:337-345`), `blockerDescription(p)` (`lines 347-351`), `p.FromID` (`created_by`), and `p.Assignees()` (`internal/store/blocker_issue.go:58-70`). This eliminates `"from_agent: <id>@<box>"` titles, sets `created_by` to the real sender, and restores `Assignees()` self-send suppression (`c-001@<box-a> -> c-001@<box-b>` and `c-001@<box-b> -> c-001@<box-a>` no longer file self-blockers when proxied through `c-003` or `a-289`).
  2. **Match the real `id@box` in `FirstPostAfter`**: In `internal/store/blocker_issue.go:183-195`, resolve a reply post's `(id, box)` from `from_agent: <id>@<box>` when line 1 carries `FromAgentPrefix` (verified against `r.from_box`), falling back to `(r.from_id, r.from_box)` when no `from_agent:` line is present, and compare **`id@box`** against the blocker's target `(bareID(assignee), blocker.to_box)` (when `blocker.to_box` is set, or `@box` in `to_id`). Comparing `id@box` instead of bare `id` prevents all 4 of the 7 proxy/other-box false matches measured in Mechanism C (`SPL-2730, 3355` proxy; `SPL-1588, 2769` same bare ID on the other box) while matching proxied replies from the true `id@box`. Optionally (if selected by the owner), also treat a `kind = 'result'` post by the blocker's sender (`id@box`) that references the blocker (`accepts` or `re <msg8>`) as resolving that blocker (`SPL-4783`), without letting unrelated `result` posts on shared synthetic topics close older blockers.
  3. **Switch one-way periodic cron nudges from `--kind blocker` to `--kind note --ask blocker` (where sent `--to orchestrator`)**: In `spool-send.sh:48-55`, a `blocker` or `task` sent `--to orchestrator` is also journaled under `$SPOOL_ROOT/asks/<msg_id>.json` and pushed to the hub (`rdb 0097`) until acked. A plain switch to `--kind note` would drop watchdog (`spl-watchdog.func.sh:1230-1231, 1273-1274`), restart (`spl-agent-restart.func.sh:831`), orch-outcome (`spl-wd-orch-outcome.func.sh:72`), issue-closer (`issue-close-landed-cron.sh:97`), and epic-stall (`spl-epic-stall-check.func.sh:233`) alerts from the asks journal. Passing `--kind note --ask blocker` (`spool-send.sh:54`) preserves ask journaling and re-raising while stopping `SweepBlockerIssues` from creating duplicate `SPL-2394` issues; the non-orchestrator nudges (`spl-asks-tick.func.sh:173`, `spl-spawn-place.func.sh:290`, `spl-push-orphan-check.func.sh:168`) become `--kind note`.
- **Risk**: Medium. Changing `--kind blocker` on `--to orchestrator` call sites requires passing `--ask blocker` (`spool-send.sh:54`) and a test on each site verifying that the ask is still journaled under `$SPOOL_ROOT/asks/`. In addition, role IDs (`c-001` orchestrator, `c-002` dispatch) move between boxes on lease rotation, so a strict `id@box` match can miss a real answer from the role's new box unless paired with a message-reference match (`re <msg8>` / `accepts`); the test should cover a blocker to `<role>@<box-a>` answered by the same role after rotating to `<box-b>`, and the owner picks which rule wins.
- **Size**: Small (~55 LoC in Go across `internal/store/blocker_issue.go` and `internal/hub/blocker_issue.go` + 9 call-site updates and ask-journaling tests in `csi-spl-orc`).

#### Option A2: Normalize `from_agent:` in hub blocker/store path + keep `--kind blocker` on cron/watchdog scripts and skip their synthetic task slugs hub-side
- **What changes & where**:
  1. Apply A1.1 and A1.2 (`from_agent:` normalization in `BlockerPosts` and `id@box` matching in `FirstPostAfter`).
  2. Keep `--kind blocker` on the watchdog/cron scripts (leaving `spool-send.sh` ask journaling untouched), and teach `SweepBlockerIssues` (`internal/hub/blocker_issue.go:110-149`) to skip creating issues for messages whose `task_id` matches the synthetic alarm topics (`asks-open`, `spawn-share`, `orch-outcome`, `dispatch-push-orphan`, `dispatch-issue-closer`, `wd-*`) or an explicit message header.
- **Risk**: Low. Does not touch `spool-send.sh` ask journaling; only suppresses `SPL-2394` issue creation for automated alarm topics.
- **Size**: Small (~60 LoC in `internal/store/blocker_issue.go` and `internal/hub/blocker_issue.go`).

---

### Part B — Close the Existing 96 `todo` Issues (and `SPL-1555`) Cleanly (Ranked)

#### Option B1 (Recommended): Named action (`do_spl_issue_blocker_rca_close`, `DRY_RUN=1` by default) transitioning the 96 open `from_agent:` `todo` issues (plus `SPL-1555`) to `diss` with a cited comment
- **What changes & where**:
  - Implement a named action in `csi-spl-orc` (e.g. `do_spl_issue_blocker_rca_close`, `DRY_RUN=1` by default, with its `.tst.sh` test) and run it after owner `GO` across the 96 open `t1` issues matching `parent_number = 2394 AND status = 'todo' AND title LIKE 'from_agent:%'` (plus `SPL-1555` if included). For each key, the action calls `spool issue update --ref <key> --status diss` and `spool issue comment --ref <key>` citing `SPL-4850` (88 automated cross-box alarm pings with no reply in topic; 8 historical/resolved hand-written blockers).
  - **Two built-in hub side effects to note**:
    1. Each transition to `diss` triggers `clearBlockerMark` (`csi-spl-api/src/go/spool-hub-api/internal/hub/issues.go:464`), which rewrites the source message in `messages` from `kind = 'blocker'` back to `kind = 'note'`.
    2. When the last open child issue under `SPL-2394` closes, the hub automatically closes and archives epic `SPL-2394` along with its closed child issues (`internal/hub/blocker_issue_epic.go:28, 34`, `SPL-1729`), and re-opens it on the next unanswered blocker.
- **Risk**: Very low. `DRY_RUN=1` previews the exact keys before any mutation; `SPL-4836` (normal title, `parent_number = 2393`, no `blocker` label) is untouched.
- **Size**: Small (1 named action + `.tst.sh` test, executed once after owner `GO`).

#### Option B2: Rewrite `issues.title` to line 2 on the 96 rows first, then transition all 96 (plus `SPL-1555`) to `diss`
- **What changes & where**:
  - Because `0` of the 96 open issues have a real answer from their assignee, rewriting titles does not make any row eligible for `done`. This option updates `issues.title` on all 96 rows to line 2 of `messages.body` for historical readability in the archive, then runs the named action to transition all 96 rows (plus `SPL-1555`) to `diss`.
- **Risk**: Low-Medium (mutates titles on 96 rows immediately before closing and archiving them).
- **Size**: Medium.

---

### Part C — Guard Against Silent Regression (Ranked)

#### Option C1 (Recommended): Unit tests in `blocker_issue_test.go` + open-blocker-issue resolution pass without the `24h` cutoff (paired with A1.2 and A1.3/A2.2)
- **What changes & where**:
  1. **Regression tests (`csi-spl-api/src/go/spool-hub-api/internal/hub/blocker_issue_test.go`)**:
     - Test that a relayed blocker with `Body = "from_agent: c-001@<box-a>\nReal blocker subject\nDetails"` and proxy `FromID = "c-003"` creates an issue titled `"Real blocker subject"` (never `"from_agent: ..."`), sets `created_by = "c-001"`, suppresses self-assignment when `ToID = "c-001"`, resolves when the assignee on `to_box` replies via cross-box relay (`Body = "from_agent: <assignee>@<to_box>\n..."`), and does **not** falsely resolve when (a) a different agent relays a post through a proxy whose `from_id` matches the assignee, (b) the same bare ID posts from the other box (`from_box <> to_box`), or (c) the assignee posts a second, unrelated message in a shared topic.
  2. **Remove the `24h` resolution blind spot (`internal/hub/blocker_issue.go:110-149`, `internal/store/blocker_issue.go`)**:
     - Keep `blockerShortLookback` (`1h`) / `blockerLongLookback` (`24h`) for **creating** new blocker issues, **but** on `long == true` ticks (every 10 minutes), query open `todo` issues under epic `SPL-2394` (`labels @> '{blocker}'`) and check `FirstPostAfter` (with A1.2's `id@box` identity fix) for their linked `(msg_id, task_id, assignee, to_box)` using the existing `messages_task_received (tenant_id, task_id, received_at, msg_id)` index (`rdb 0022/0083`).
  3. **Require message-reference matching (`re <msg8>` or `accepts`) when a topic has multiple blockers**:
     - In topics where more than one blocker message exists (or for all blocker resolutions), require the assignee's post to reference the blocker message (`re <msg8>` or `accepts`), which also prevents false closes inside the 24 h window when a topic is reused.
- **Risk**: Low only together with A1.2 and (A1.3 or A2.2). C1 alone, or C1 with A1.2 alone, closes blockers on unrelated posts in shared alarm topics. The test must cover a second, unrelated post by the assignee in the same topic.
- **Size**: Small (~70 LoC in `internal/hub/blocker_issue.go`, `internal/store/blocker_issue.go`, and `internal/hub/blocker_issue_test.go`).

#### Option C2: CI/cron audit check failing if any open issue has `title LIKE 'from_agent:%'`
- **What changes & where**:
  - Add a check in fleet health / watchdog alerting if `SELECT count(*) FROM issues WHERE deleted_at IS NULL AND title LIKE 'from_agent:%'` exceeds `0` after cleanup.
- **Risk**: Low, though reactive rather than preventative on its own (best paired with C1).
- **Size**: Tiny (~10 LoC).

---

### Owner Decision Polls

````poll
How should we stop the wrong `from_agent:` blocker filings and fix resolution (Parts A + C)?
1. Option A1 + C1 (Recommended) — normalize `from_agent:` in hub blocker handling, match replies by `id@box`, resolve open blocker issues beyond 24h, and switch one-way cron/watchdog alerts to `--kind note --ask blocker` (keeping ask journaling)
2. Option A2 + C1 — normalize `from_agent:` in hub blocker handling, match replies by `id@box`, resolve open blocker issues beyond 24h, and keep `--kind blocker` on cron/watchdog scripts while skipping their synthetic alarm topics in the hub
3. Hold code changes for now
````

````poll
How should we clean up the 96 existing open `from_agent:` `todo` issues (and `SPL-1555`) under `SPL-2394` in `t1` (`prd`)?
1. Option B1 (Recommended) — run a named action (`DRY_RUN=1` default) calling `spool issue update --status diss` + `spool issue comment` on all 96 open `from_agent:` `todo` issues (plus `SPL-1555`), which clears their blocker marks and auto-archives `SPL-2394`
2. Option B2 — rewrite their titles to line 2 first for archive readability, then transition all 96 issues (plus `SPL-1555`) to `diss`
3. Leave the existing 96 issues open for manual triage
````

---

## 4. Panel Record & Signatures

### 4.1 Findings Folded

| Round | Seat | Source Message / Reference | Summary of Finding | Disposition in Document |
| :--- | :--- | :--- | :--- | :--- |
| `v0.1` | `c-754` (Hub Code Expert) | Spool `6709d93d-c631-42cc-bdaf-c3c97a209804` (`2026-11-05T09:57:04Z`) | Identified `spool-fleet-relay.sh:142` (`from_agent:` prepend), `WithFromAgent` only called in `hubclient.go:979`, `blockerTitle` (`blocker_issue.go:337-345`), proxy `from_id` mismatch (`Assignees` dropping unproxied `c-001 -> c-001` such as `270b52d0` and `FirstPostAfter` proxy mismatch), 89 zero-reply alarms vs 7 late replies past `24h` `blockerLongLookback` (`blocker_issue.go:69-70`), and all 96 issue counts/categories. | Folded in full into Sections 1, 2, and 3. |
| `v0.1` | `a-747` (Editor) | Empirical SQL + WUI screenshot verification (`2026-11-05`) | Verified owner screenshot `ebd63d3d...` (`SPL-4836` is a separate non-blocker `todo` bug; the other 17 visible rows are part of the 96 `SPL-2394` `from_agent:` issues), identified proxied self-blockers (`c-001 -> c-001`), and verified `SPL-4783` was answered (`3f26318f`) and completed (`5152bbaf`) 81s before filing. | Folded into Sections 2.2, 2.3, and 2.4. |
| `v0.2` | `c-754` (Hub Code Expert) | Spool `93cad526-a4ae-4ff5-a333-192c53c0b298` (`2026-11-05T11:26:06Z`) | 11 corrections on `v0.1`: (1) `i.created_at - m.received_at` range `00:03:00.67 .. 23:14:45.88` and `created_by = m.from_id` (`96/96`); (2) exact 22 proxy counts (`c-003` 17, `a-289` 3, `c-001` 1 [`SPL-3368`], `c-087` 1 [`SPL-3285`]); (3) 19 self-blockers (16 via `c-003` + 3 via `a-289`) vs unproxied drop (`270b52d0`); (4) exact title counts (`31/29/29/2/1/1/1/1/1` including `g-002@<box-b>`); (5) `spl-epic-stall-check.func.sh:228,233` passes v5 `$task` (no `uuid4`); (6) `SPL-4783` `received_at = 09:53:36Z`; (7) verbatim `blockerTitle` (`cutRunes`); (8) `blockerDescription` `:347-351`, `BlockerIssueTask` `bareID`, `WithFromAgent` `From = id@box`, new helper in A1.1; (9) `messages_task_received` index; (10) `spool-send.sh:48-55` `--ask blocker` requirement & Medium risk; (11) distinguish measured proxy false-positives from code-path inference and cite exact evidence for the 8 hand-written blockers. | Folded in full (all 11 items) into Sections 2.1–2.4, 3, and 4.1. |
| `v0.2` | `c-756` (Reviewer) | Spool `ae776581-a85e-4d3a-be71-92f3a817fd4a` (`2026-11-05T11:27:58Z`) | 10 findings on `v0.1`: (1) title table `31/29/29/2/1/1/1/1/1`; (2) exact 7-row Mechanism B table (`SPL-1588, 2730, 2769, 3244, 3355, 3901, 4360`) and 4 `orch-outcome` IDs (`2769, 3244, 3369, 3901`); (3) 2 of 7 late matches (`SPL-2730`, `SPL-3355`) are false proxy matches requiring C1 to land with A1.2; (4) Mechanism A split (`55` with no later post, `34` with posts by others); (5) 19 self-blockers (`16` via `c-003`, `3` via `a-289`); (6) verbatim `blockerTitle`; (7) `spool-send.sh:48-55` `--ask blocker` & Medium risk; (8) scope sender `kind=result` in A1.2 so shared topics do not false-close; (9) B1 must use a named action (`spool issue update --status diss` + `issue comment`) and note `clearBlockerMark` (`issues.go:464`) and `SPL-2394` auto-close/archive (`blocker_issue_epic.go:28,34`); (10) `spl-epic-stall-check.func.sh:233`, `09:53:36Z`, `messages_task_received`, and per-issue `msg_id` evidence for the 8 hand-written blockers. | Folded in full (all 10 items) into Sections 2.1–2.4, 3, and 4.1. |
| `v0.3` | `c-754` (Hub Code Expert) | Spool `c7e05980-84c3-4388-8fa0-eca28821cb6b` (`2026-11-05T11:34:37Z`) | Verified all 11 `v0.1` corrections in `v0.2` (`8afd18666`) and noted 1 refinement: in Mechanism B/C.1 and A1.2, `SPL-2769` (target `g-002@<box-b>`, matched by `g-002@<box-a>` in `4067d446`) and `SPL-1588` (target `c-002@<box-a>`, matched by `<box-b>/c-002` Status card in `6277957d`) are also false matches (same bare ID on the other box), making **4 of 7** proxy/other-box false matches (`SPL-2730, 3355` proxy; `SPL-1588, 2769` other box) and requiring A1.2 to compare **`id@box`** using the blocker's `to_box`. | Folded in full into Table 2.1, Section 2.3 (Mechanism B & C.1), and Section 3 (A1.2, C1). |
| `v0.4` | `c-756` (Reviewer) | Spool `af1a3aee-d288-4e60-a3bf-ac49ca5d20d9` (`2026-11-05T11:35:03Z`) | Verified all 10 `v0.1` findings in `v0.2` (`8afd186660`) and reported **F11**: inspecting the 7 matching post bodies (`6277957d`, `c0ab8fcb`, `4067d446`, `e53626a5`, `ff9854bc`, `b3ababeb`) shows **0 of the 7** actually answer their blocker (`5` are unrelated later posts in shared `uuid5("spool-task:<name>")` alarm topics and `2` are false proxy matches). Updated §1, §2.3 Mechanism B table ("What the matching post is") & Mechanism C.3 (shared alarm topic false-positives), §3 B2 & Poll 2 option 2 (all 96 transition to `diss`), and §3 C1 risk & point 3 (`Low only together with A1.2 and (A1.3 or A2.2)`). | Folded in full into Sections 1, 2.1, 2.3, 3 (B2, C1, Poll 2), and 4.1. |
| `v1.0` | `c-754` (Hub Code Expert) & `c-756` (Reviewer) | Spool `0372a3e5-572c-47f3-8693-c2b29a3eea2a` & `22aa0a5a-3412-467b-9dc2-a9142efcf193` (`2026-11-05T11:44Z`) | Both `c-754` and `c-756` confirmed **PASS on `v0.4` @ `eb575811f8`**. Folded `c-756`'s non-blocking note `N1` into A1 Risk (role rotation between `<box-a>` and `<box-b>` under strict `id@box` matching) and promoted the document to `v1.0` for per-seat signature commits. | Folded into Section 3 (Option A1 Risk) and Section 4. |

### 4.2 Signatures

| Role | Agent ID | Version | SHA Read | Status |
| :--- | :--- | :--- | :--- | :--- |
| **EDITOR** | `a-747` | `v1.0` | `eb575811f87b3cecaffd2f880c9ec7f0db704c31` | Signed `v1.0` |
| **HUB CODE EXPERT** | `c-754` | *(pending)* | *(pending)* | Ready to sign `v1.0` |
| **REVIEWER** | `c-756` | *(pending)* | *(pending)* | Ready to sign `v1.0` (`PASS` on `eb575811f8`) |
