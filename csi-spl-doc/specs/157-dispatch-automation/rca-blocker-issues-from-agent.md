# Root-Cause Analysis: Never-Closed `"from_agent: <id>@<box>"` Blocker Issues (`SPL-4850`)

- **Version**: `v0.1`
- **Date**: `2026-11-05`
- **Epic / Spec**: `SPL-2398` (`csi-spl-doc/specs/157-dispatch-automation`)
- **Panel Issues**: `SPL-4850` (Editor `a-747`), `SPL-4851` (Hub Code Expert `c-754`), `SPL-4852` (Reviewer `c-756`)
- **Discussion**: `t1` topic `8c64225e-d82f-463f-af12-4dc4a0ecba35` (owner screenshot `ebd63d3d8b00040a497f26a0e3435440c15c17b02970d93738a13c333872d0b5` in `d9469b71` / `d8870eec`)
- **Evaluated Tree**: `origin/master` @ `3cceac64fe7f86671dda16b71dbde8a920d6eed3` and live `prd` Postgres (`t1`, read-only; box placeholders `<box-a>` and `<box-b>` denote the primary workstation box and the satellite box)

---

## 1. Root Cause (One Paragraph)

Every cross-box spool message sent through `spool-fleet-relay.sh` has `from_agent: <id>@<box>` prepended as line 1 of its body (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh:142`) and is signed under a seated proxy ID on the sending box (`SENDER`, lines `122-134`) whenever the real sender is unannounced there. While the receiving box's sidecar strips that line on local file delivery (`internal/hubclient/hubclient.go:979` calling `spool.WithFromAgent` in `internal/spool/fromagent.go:25-38`), the hub stores the raw body verbatim in `messages.body` with the proxy ID in `messages.from_id`. Every 1 minute (`cmd/spool/timeouts.go:9`, `cmd/spool/hub.go:147`), `SweepBlockerIssues` (`internal/hub/blocker_issue.go:110-149`) promotes any `kind='blocker'` message that receives no same-topic reply from its assignee within `blocker.issue_after_minutes` (default 3 min, `internal/store/blocker_issue.go:25-35`) into a `todo` issue under epic `SPL-2394` (`blocker_issue_epic.go:24`), taking the raw first non-empty line of `p.Body` as the issue title (`blockerTitle`, `blocker_issue.go:337-345`)—which is always `"from_agent: <id>@<box>"`. On `t1` `prd`, 88 of the 96 open `todo` issues are automated cross-box fleet alarms (watchdog restarts, limit screens, login screens, orchestrator-outcome stalls, `asks-open` nudges, `spawn-share` nudges, `push-orphan` alerts, `issue-closer-red` alerts, and `epic-stall` alerts) sent with `--kind blocker` on synthetic one-off or broadcast task UUIDs (`uuid5("spool-task:<slug>")`, `spool-fleet-relay.sh:161-164`) where the recipient acts on its box or in another topic rather than posting a reply back into the alarm's topic (`89/96` have zero assignee posts in `messages.task_id`); the remaining `7/96` whose assignees eventually posted in the same topic did so `31h..193h` later, past the sweep's hard `24h` `blockerLongLookback` ceiling (`blocker_issue.go:69-70, 93-97`), after which the hub never inspects the blocker again.

---

## 2. Evidence Table & Answers to Questions 1–3

### 2.1 Master Evidence Table

| Claim | Source Code (`file:line` on `3cceac64fe`) | SQL / Empirical Proof on `prd` (`t1`) | Representative Issue IDs |
| :--- | :--- | :--- | :--- |
| Cross-box relay prepends `from_agent: $FROM@$BOX` as line 1 of `messages.body` | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh:142` | `96/96` open `todo` issues with `labels @> '{blocker}'` in `t1` have `title LIKE 'from_agent: %'` and `m.from_box <> m.to_box` | All 96 open (`SPL-1587` .. `SPL-4783`) |
| `WithFromAgent` strips `from_agent:` only on the receiving sidecar, never in hub `store` or `SweepBlockerIssues` | `csi-spl-api/src/go/spool-hub-api/internal/spool/fromagent.go:25-38`; called only at `internal/hubclient/hubclient.go:979` | `SELECT count(*) FROM issues WHERE tenant_id='t1' AND status='todo' AND deleted_at IS NULL AND archived_at IS NULL AND title LIKE 'from_agent:%'` -> `96` | `SPL-4783`, `SPL-4682..4691`, `SPL-4480..4487` |
| `blockerTitle(p)` uses raw first non-empty line of `p.Body` without stripping `from_agent:` | `csi-spl-api/src/go/spool-hub-api/internal/hub/blocker_issue.go:337-345` | Line 1 of `m.body` is `from_agent: <id>@<box>`; line 2 is the real subject (e.g. `WATCHDOG RESTART (102 4.1): ...`) | All 96 open `todo` issues + 44 archived `done` issues + 1 `diss` (`SPL-1555`) |
| Hub loop runs every `1m` and files a `todo` issue under epic `SPL-2394` (`priority=5`, `labels=['blocker']`) after `3m` without same-topic reply | `cmd/spool/timeouts.go:9`, `cmd/spool/hub.go:147`, `internal/hub/blocker_issue.go:82-224`, `internal/hub/blocker_issue_epic.go:24,94-106`, `internal/store/blocker_issue.go:25-35` | All 96 open rows have `parent_number = 2394`, `priority = 5`, `level = 2`, `labels = '{blocker}'`, and `i.created_at - m.received_at` between `3m` and `4m` | `SPL-4783` (`m.received_at = 09:53:46Z`, `i.created_at = 09:56:58Z`) |
| Unannounced cross-box sender is proxied via seated `SENDER`, recording proxy in `messages.from_id` and `issues.created_by` | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh:112-134` | `22/96` open issues have `m.from_id <> split_part(regexp_replace(i.title,'^from_agent: ',''),'@',1)`: `c-003` proxies 18, `a-289` proxies 3, `c-087` proxies 1 | `SPL-4682..4691` (`title='from_agent: c-001@<box-a>'`, `created_by='c-003'`), `SPL-3368` (`c-180@<box-b>` via `c-087`) |
| Self-send filter `Assignees()` seeds `seen[bareID(p.FromID)]` with the proxy ID instead of `from_agent:`, filing self-blockers `c-001@<box-a> -> c-001@<box-b>` whenever proxied | `csi-spl-api/src/go/spool-hub-api/internal/store/blocker_issue.go:58-70` | `16/96` open issues are `c-001@<box-a> -> c-001` proxied through `c-003` (`bareID('c-003') <> 'c-001'`), whereas non-proxied `c-001@<box-a> -> c-001` messages are suppressed | `SPL-4682..4690` (9), `SPL-4480..4485` (6), `SPL-3859` (1) |
| 88 of 96 open issues are automated cron/watchdog/nudge alarms using `--kind blocker` on synthetic task slugs | `spl-agent-restart.func.sh:831`, `spl-watchdog.func.sh:1231,1274`, `spl-asks-tick.func.sh:173`, `spl-spawn-place.func.sh:290`, `spl-wd-orch-outcome.func.sh:72`, `spl-push-orphan-check.func.sh:168`, `issue-close-landed-cron.sh:88,99`, `spl-epic-stall-check.func.sh:250` | Grouping `96` open issues by line 2 of `m.body`: 29 `WATCHDOG RESTART`, 24 `WATCHDOG kind=limit`, 11 `ASKS STILL OPEN`, 9 `SPAWN SHARE`, 7 `WATCHDOG login`, 4 `WATCHDOG orch-outcome`, 2 `push-orphan`, 1 `ISSUE CLOSER RED`, 1 `epic stalled`, 8 hand-written | See Section 2.2 & Section 2.4 tables |
| `89/96` open issues have `0` subsequent posts by `bareID(assignee)` in `m.task_id` | `csi-spl-api/src/go/spool-hub-api/internal/store/blocker_issue.go:183-195`; `spool-fleet-relay.sh:161-164` (`uuid5(NAMESPACE_URL, "spool-task:" + task)`) | `SELECT count(*) ... WHERE assignee_replies = 0` -> `89` (86 have `0` total replies from anyone; 3 have posts from other seats only: `SPL-4783`, `SPL-4486`, `SPL-4056`) | `SPL-4783` (answered by `c-001@<box-b>` + closed with `result` by `c-001@<box-a>`, not `c-002`) |
| `7/96` open issues received a same-topic post matching `bareID(assignee)`, but after `31h..193h`—past the hard `24h` `blockerLongLookback` cutoff | `csi-spl-api/src/go/spool-hub-api/internal/hub/blocker_issue.go:69-70, 93-97, 131-132` (`blockerShortLookback = time.Hour`, `blockerLongLookback = 24 * time.Hour`) | All 7 have `first_assignee_reply - m.received_at` between `1d 07:10:02` and `8d 00:49:16`; `BlockerPosts` stops scanning `m.received_at < due - 24h` | `SPL-4360`, `SPL-3901`, `SPL-3355`, `SPL-3244`, `SPL-2769`, `SPL-2730`, `SPL-1588` |
| `FirstPostAfter` matches `messages.from_id` (proxy) instead of `from_agent:`, missing lane-agent replies sent via proxy and falsely matching unrelated lane agents sharing a proxy | `csi-spl-api/src/go/spool-hub-api/internal/store/blocker_issue.go:183-195` (`from_id = $4 OR from_id LIKE $4 || '@%'`) | On `SPL-2730` (`to_id=c-001`), the post at `+34h40m` (`c0ab8fcb`) is `from_agent: c-826@<box-a>` proxied via `from_id='c-001'`; conversely, any reply from `c-527@<box-b>` (`SPL-4056`) proxied via `c-001` has `from_id='c-001'` and never matches `c-527` | `SPL-2730`, `SPL-4056` |

---

### 2.2 Question 1: Who files these issues, from which message, and why is the title `"from_agent: <agent>"` instead of the blocker's words?

#### 1. Who files them
The `spool-hub-api` background goroutine `RunBlockerIssues` -> `SweepBlockerIssues` (`csi-spl-api/src/go/spool-hub-api/internal/hub/blocker_issue.go:82-149`), started at `BlockerInterval = time.Minute` (`cmd/spool/timeouts.go:9`, `cmd/spool/hub.go:147`), scans `messages` rows with `kind = 'blocker'` and `archived_at IS NULL` (`internal/store/blocker_issue.go:164-180`). When a blocker message is older than `blocker.issue_after_minutes` (`default 3`, `internal/store/blocker_issue.go:25-35`) and `FirstPostAfter` finds no reply in `p.TaskID` from assignee `a`, `blockerCreate` -> `blockerIssueOn` (`internal/hub/blocker_issue.go:171-224`) creates an issue with:
- `status = "todo"`, `priority = 5` (store default), `labels = ["blocker"]`
- `parent_number = 2394` (`SPL-2394`, `"Area: unanswered blockers - issues with no spec"`, `internal/hub/blocker_issue_epic.go:24, 94-106`)
- `created_by = p.FromID`, `assignee = a` (bare ID from `p.Assignees()`)
- `task_id = BlockerIssueTask(tenant, p.MsgID, a)` (`uuid5(NameSpaceURL, "spool-blocker-issue:" + tenant + ":" + msgID + ":" + strings.ToLower(a))`, `internal/store/blocker_issue.go:106-108`)
- `description` ending with `[Open the message](/m/<msg_id>)` (`internal/hub/blocker_issue.go:356-369`).

#### 2. Why the title is `"from_agent: <id>@<box>"` instead of the blocker's words
1. Every cross-box spool message is transmitted by `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh`. At line `142`, the relay prepends the real sender's identity onto line 1 of the message body before calling `spool hub-send`:
   ```bash
   BODY="from_agent: $FROM@${SIDEBOX:-$BOX}"$'\n'"$BODY"
   ```
2. On the receiving box, `hubclient` calls `spool.WithFromAgent(m)` (`csi-spl-api/src/go/spool-hub-api/internal/hubclient/hubclient.go:979`, defined at `internal/spool/fromagent.go:25-38`), which parses line 1 (`from_agent: <id>@<box>`), rewrites `m.From` and `m.FromBox` in the local JSON file delivered to `/var/spool-hub/<agent>/inbox`, and strips line 1 from `m.Body`.
3. However, **the hub database itself never calls `spool.WithFromAgent`**. The hub stores the raw `BODY` (with `from_agent: <id>@<box>` on line 1) in `messages.body` and the relay proxy `SENDER` in `messages.from_id`.
4. When `SweepBlockerIssues` creates the issue, `blockerTitle(p store.BlockerPost)` (`internal/hub/blocker_issue.go:337-345`) takes the first non-empty line of `p.Body`:
   ```go
   func blockerTitle(p store.BlockerPost) string {
       for _, ln := range strings.Split(p.Body, "\n") {
           ln = strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(ln), "#> "))
           if ln != "" {
               return clipRunes(ln, 120)
           }
       }
       return "Blocker from " + p.FromID
   }
   ```
   Because line 1 of `p.Body` on every cross-box message is `from_agent: <id>@<box>`, `blockerTitle(p)` always returns `"from_agent: <id>@<box>"` and pushes the real subject line (line 2 of `p.Body`) into `issues.description`.

#### 3. Proxy sender distortion (`SPL-3865` interaction) and self-blocker filing bug
When `$FROM` is not announced on the sending box (for example, `c-001@<box-a>` when the `c-001` lease is held by `<box-b>`, or a lane agent `c-632@<box-a>` / `g-493@<box-a>`), `spool-fleet-relay.sh:112-134` picks a seated proxy on the sending box (`SENDER`, typically `c-003`, `c-001`, `g-001`, `a-289`, or `c-087`). This causes two defects in `SweepBlockerIssues`:
- **Wrong `created_by`**: `issues.created_by` is set to `p.FromID` (the proxy, e.g. `c-003` on 18 open issues, `a-289` on 3, `c-087` on 1) rather than the sender in `from_agent:`.
- **Broken self-send suppression (`BlockerPost.Assignees`)**: `Assignees()` (`internal/store/blocker_issue.go:58-70`) seeds `seen := map[string]bool{bareID(p.FromID): true}` to avoid filing an issue against the sender of the blocker. When `c-001@<box-a>` is announced on `<box-a>` (`p.FromID = "c-001"`) and sends a blocker to `c-001@<box-b>` (`p.ToID = "c-001"`), `bareID("c-001") == bareID("c-001")` suppresses issue creation. But when `c-001@<box-a>` is unannounced on `<box-a>` and proxied through `c-003` (`p.FromID = "c-003"`), `bareID("c-003") != bareID("c-001")`, so the hub files an issue assigned to `c-001` for a message sent by `c-001@<box-a>` (**16 of the 96 open issues**: `SPL-4682..4690`, `SPL-4480..4485`, `SPL-3859`).

#### 4. Which messages produced the 96 open `todo` issues in `t1`
All 96 open `todo` blocker issues in `t1` (`prd`) come from cross-box DMs (`channel IS NULL`, `kind = 'blocker'`, `from_box <> to_box`). Grouping all 96 by line 2 of `messages.body` identifies their exact senders:

| Category | Count | Line 2 Pattern (Real Subject) | Sender Script (`file:line`) | Task Flag Passed | Issue Numbers (`SPL-*`) |
| :--- | ---: | :--- | :--- | :--- | :--- |
| 1. Watchdog restart alert | **29** | `WATCHDOG RESTART (102 4.1): <id> on <box> was restarted ...` | `csi-spl-orc/src/bash/run/spl-agent-restart.func.sh:831` | `--task "wd-$id-$ts"` | `4682..4691, 3855..3857, 3859, 3308..3309, 3316..3324, 2684..2687` |
| 2. Watchdog limit screen | **24** | `WATCHDOG (093 S2 kind=limit): <id> on <box> hit a usage/rate limit ...` | `csi-spl-orc/src/bash/run/spl-watchdog.func.sh:1274` | `--task "wd-$id"` | `4480..4485, 3358..3359, 3333, 3336, 3265, 3267..3269, 3271..3272, 3275, 3277, 3279, 3237, 3239..3242` |
| 3. Open asks nudge | **11** | `ASKS STILL OPEN (<N>, oldest <M>m): ...` | `csi-spl-orc/src/bash/run/spl-asks-tick.func.sh:173` | `--task asks-open` | `3850, 3842, 3837, 3835, 2885, 2884, 2882, 2727, 2614, 1690, 1588` |
| 4. Spawn share nudge | **9** | `SPAWN SHARE: <box> holds <X>% of running fleet agents ...` | `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:290` | `--task spawn-share` | `4487, 4360, 3370, 3355, 2768, 2767, 2721, 2719, 2718` |
| 5. Watchdog login screen | **7** | `WATCHDOG (093 S2): <id> on <box> is sitting at a login or access screen ...` | `csi-spl-orc/src/bash/run/spl-watchdog.func.sh:1231` | `--task "wd-$id"` | `3314, 3313, 3311, 3310, 3248, 3247, 3246` |
| 6. Watchdog orch outcome | **4** | `WATCHDOG (SPL-1717): the orchestrator role on <box> has produced no outcome ...` | `csi-spl-orc/src/bash/run/spl-wd-orch-outcome.func.sh:72` | `--task orch-outcome` | `3901, 3369, 3244, 2769` |
| 7. Push-orphan alert | **2** | `**push-orphan@<box-a>** — commits on origin/master ...` | `csi-spl-orc/src/bash/run/spl-push-orphan-check.func.sh:168` | `--task dispatch-push-orphan` | `3285, 2883` |
| 8. Issue-closer red alert | **1** | `ISSUE CLOSER RED on <box-a> — 1 landed commit(s) ...` | `csi-spl-orc/src/bash/scripts/issue-close-landed-cron.sh:88,99` | `--task dispatch-issue-closer` | `2730` |
| 9. Epic stall alert | **1** | `**Blocker: epic SPL-2151 has stalled** ...` | `csi-spl-orc/src/bash/run/spl-epic-stall-check.func.sh:250` | *(none -> random UUID)* | `2720` |
| 10. Hand-written agent/role blockers | **8** | Agent/orchestrator cross-box blockers on task threads | `agent-send.sh` / `spool-send.sh` -> `spool-fleet-relay.sh` | Task thread UUID or slug | `4783, 4486, 4056, 3499, 3368, 1691, 1589, 1587` |
| **Total** | **96** | | | | |

---

### 2.3 Question 2: Why does none of them close?

We tested all three hypotheses from the brief against `csi-spl-api` and `prd` Postgres:

1. **Is the link back to the blocker message missing?** **No.**
   Every one of the 96 open `todo` issues contains a valid `[Open the message](/m/<msg_id>)` link in `issues.description`, and all 96 referenced `messages.msg_id` rows exist in `t1` with `archived_at IS NULL` and `kind = 'blocker'`. Furthermore, when an assignee *does* post in the same `task_id` within 24 hours, the auto-closer works: **44 historical `from_agent:` blocker issues in `t1` transitioned to `done`** (now archived) with the hub comment `"Resolved by the answer of @<id> in the discussion."` (`internal/hub/blocker_issue.go:240-266`).

2. **Is the blocker never answered in the blocker's topic, or does the answer arrive where/when the closer does not look?** **Both—splitting 89 vs 7 across the 96 open issues, compounded by three matcher defects in `SweepBlockerIssues`:**

   - **Mechanism A (`89/96` open issues): Zero posts by `bareID(assignee)` in `messages.task_id` (`assignee_replies = 0`).**
     - **81 of the 89** are automated one-way operational alarms (`WATCHDOG RESTART` 29, `WATCHDOG limit` 24, `ASKS STILL OPEN` 10, `SPAWN SHARE` 7, `WATCHDOG login` 7, `push-orphan` 2, `WATCHDOG orch-outcome` 1, `epic-stall` 1). `spool-fleet-relay.sh:161-164` converts each non-UUID `--task <name>` into a synthetic topic UUID via `uuid5(NAMESPACE_URL, "spool-task:" + name)` (or generates a fresh `uuid4()` when `--task` is omitted, as in `spl-epic-stall-check.func.sh:250`). When the receiving orchestrator or dispatch holder handles the alarm—by restarting/checking an agent, running `do_spl_ask_ack`, or spawning on the under-loaded box—no reply message is posted into `uuid5("spool-task:wd-...")` or `uuid5("spool-task:asks-open")`.
     - **8 of the 89** are hand-written cross-box blockers where work continued either on local spool, on another topic, or via another peer seat in the same topic:
       - `SPL-4783` (`2026-11-04`, `c-001@<box-a> -> c-002`, topic `fb7c0bf2-ef77-51fd-9b57-904795a3af6d`): `c-001@<box-a>` asked `c-002@<box-b>` at `09:53:46Z` (`msg 810affc7`) whether to re-post `af280ac8`. Twenty-five seconds later (`09:54:11Z`), `c-001@<box-b>` answered with `GO` (`msg 3f26318f`), and at `09:55:37Z` (`msg 5152bbaf`) `c-001@<box-a>` posted `kind='result'` (`"fb7c0bf2 done: the formatted re-post of af280ac8 is live"`). Because `FirstPostAfter` checks **only** for a post from assignee `c-002` and ignores both `c-001@<box-b>`'s `GO` and the sender's own `kind='result'` completion post, `SweepBlockerIssues` still filed `SPL-4783` at `09:56:58Z`—**81 seconds after the task was already finished**—and never closed it.
       - `SPL-4486` (`2026-10-31`, `c-632@<box-a> -> c-003`, topic `361c18a8-e807-5982-8653-dc78d3b100c6`): `c-632@<box-a>` reported a scope blocker on `SPL-4187` to `c-003`. `c-632` resolved and landed `SPL-4187` (`28598b91c`, `7a5ee431f`, `a1dd6eebd`), and `c-002@<box-b>` posted `ACCEPTED — SPL-4187 verified on origin/master` (`54f04d89`). Because `c-003` never posted in that topic, `SPL-4486` remained `todo`.
       - `SPL-4056` (`2026-10-28`, `g-493@<box-a> -> c-527`, topic `9da17538-1993-5f91-80f9-ab8f41c17f18`): `g-493@<box-a>` sent a review blocker to lane agent `c-527@<box-b>`. Subsequent rounds landed and `c-002@<box-b>` posted `ACCEPTED` for `SPL-4302` (`bb25c41f`). Even if `c-527@<box-b>` replied cross-box, `spool-fleet-relay.sh` sends lane-agent messages under proxy `from_id = 'c-001'`, which `FirstPostAfter` never matches to `c-527`.

   - **Mechanism B (`7/96` open issues): Assignee DID post in the same `task_id`, but after the hard `24h` `blockerLongLookback` window (`internal/hub/blocker_issue.go:69-70, 93-97, 131-132`).**
     `SweepBlockerIssues` only queries `BlockerPosts` with `received_at` between `due - lookback` and `due`, where `lookback` is `1h` (`blockerShortLookback`) on 9 of 10 ticks and `24h` (`blockerLongLookback`) on every 10th tick. Once a blocker message is older than `24h + 3m`, **`BlockerPosts` never returns that message again**, so `blockerResolve` is never called for any reply arriving after 24 hours:

| Issue | Title (`from_agent:`) | Assignee | Category | Blocker `received_at` (UTC) | First Same-Topic Post Matching `bareID(assignee)` | Delay (`reply - blocker`) | Why Still `todo` |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `SPL-4360` | `from_agent: c-001@<box-a>` | `c-002` | `SPAWN SHARE` | `2026-10-30 16:40:21Z` | `2026-10-31 23:50:23Z` | `1d 07h 10m` | Reply arrived `>24h` after blocker |
| `SPL-3901` | `from_agent: g-001@<box-a>` | `c-001` | `WATCHDOG orch-outcome` | `2026-10-27 16:42:08Z` | `2026-11-03 19:22:18Z` | `7d 02h 40m` | Reply arrived `>24h` after blocker |
| `SPL-3355` | `from_agent: g-001@<box-a>` | `c-002` | `SPAWN SHARE` | `2026-10-25 16:33:13Z` | `2026-10-30 16:40:21Z` | `5d 00h 07m` | Later post on `spawn-share` topic arrived `>24h` later |
| `SPL-3244` | `from_agent: g-001@<box-a>` | `g-001` | `WATCHDOG orch-outcome` | `2026-10-24 22:02:09Z` | `2026-10-27 16:42:08Z` | `2d 18h 40m` | Later post on `orch-outcome` topic arrived `>24h` later |
| `SPL-2769` | `from_agent: g-001@<box-a>` | `g-001` | `WATCHDOG orch-outcome` | `2026-10-21 04:42:08Z` | `2026-10-24 22:02:09Z` | `3d 17h 20m` | Later post on `orch-outcome` topic arrived `>24h` later |
| `SPL-2730` | `from_agent: c-001@<box-a>` | `c-001` | `ISSUE CLOSER RED` | `2026-10-20 12:30:10Z` | `2026-10-21 23:10:49Z` | `1d 10h 40m` | Post `c0ab8fcb` arrived `>24h` later (and was `from_agent: c-826@<box-a>` proxied via `from_id='c-001'`) |
| `SPL-1588` | `from_agent: c-001@<box-a>` | `c-002` | `ASKS STILL OPEN` | `2026-10-13 08:25:05Z` | `2026-10-21 09:14:21Z` | `8d 00h 49m` | Later post on `asks-open` topic arrived `>24h` later |

   - **Mechanism C: Identity mismatch in `FirstPostAfter` (`internal/store/blocker_issue.go:183-195`).**
     `FirstPostAfter` checks `from_id = $4 OR from_id LIKE $4 || '@%'` against `bareID(from)`. Because cross-box messages store the sending box's proxy seat in `messages.from_id` and the real sender only in line 1 of `messages.body` (`from_agent:`), a cross-box reply from an unannounced agent (such as `c-527@<box-b>` or `c-001@<box-a>` when proxied as `c-003`) has the proxy's `from_id` in Postgres and is invisible to `FirstPostAfter` for the real sender's ID.

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
| `from_agent: c-001@<box-b>` | 34 |
| `from_agent: g-001@<box-a>` | 29 |
| `from_agent: c-001@<box-a>` | 27 |
| `from_agent: g-001@<box-b>` | 2 |
| `from_agent: c-003@<box-a>` | 1 (`SPL-1587`) |
| `from_agent: c-180@<box-b>` | 1 (`SPL-3368`) |
| `from_agent: c-632@<box-a>` | 1 (`SPL-4486`) |
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
**No—0 of the 96 open `from_agent:` blocker issues represent live unanswered work that needs a new action today:**

1. **88 automated cron/watchdog/nudge alarms (`Categories 1–9`)**:
   - 87 of the 88 are historical point-in-time operational telemetry (`WATCHDOG RESTART`, `WATCHDOG kind=limit`, `WATCHDOG login`, `WATCHDOG orch-outcome`, `ASKS STILL OPEN`, `SPAWN SHARE`, `push-orphan`, `ISSUE CLOSER RED`) from `2026-10-13` through `2026-11-03`.
   - The 1 epic-stall alarm (`SPL-2720`, filed `2026-10-20 06:04Z` for `**Blocker: epic SPL-2151 has stalled** (Security scan actions (10), two lanes at a time)`) points to epic `SPL-2151`, which is already tracked directly as an open `wip` epic in `t1` (`SPL-2151` itself should remain open; `SPL-2720` is a duplicate stall-ping artifact).
2. **8 hand-written agent/role blockers (`Category 10`) — verified individually against `messages`, `issues`, and `git log`**:
   - **`SPL-4783`** (`2026-11-04`, `c-001@<box-a> -> c-002`, topic `fb7c0bf2-ef77-51fd-9b57-904795a3af6d`): **Resolved 81s before filing.** `c-001@<box-b>` gave `GO` at `09:54:11Z` (`3f26318f`) and `c-001@<box-a>` posted `RESULT` `"fb7c0bf2 done: the formatted re-post of af280ac8 is live"` at `09:55:37Z` (`5152bbaf`).
   - **`SPL-4486`** (`2026-10-31`, `c-632@<box-a> -> c-003`, topic `361c18a8-e807-5982-8653-dc78d3b100c6`): **Resolved.** Scope question on `SPL-4187`; `SPL-4187` landed on `master` (`28598b91c`, `7a5ee431f`, `a1dd6eebd`), was `ACCEPTED` by `c-002@<box-b>` (`54f04d89`), and `SPL-4187` is `done`.
   - **`SPL-4056`** (`2026-10-28`, `g-493@<box-a> -> c-527`, topic `9da17538-1993-5f91-80f9-ab8f41c17f18`): **Resolved.** Round 36 review blocker on `114-scroll-canvas-perf`; rounds 36–41 landed and `SPL-4302` was `ACCEPTED` (`bb25c41f`).
   - **`SPL-3499`** (`2026-10-26`, `c-001@<box-a> -> c-002`, topic `0f114800-e7e9-50a4-9fcc-7d5359a6ff5e`): **Resolved / Historical.** Relayed a `2026-10-26` terminal priority order for `#development` topics `a82c4a5b` and `55fd7531`.
   - **`SPL-3368`** (`2026-10-25`, `c-180@<box-b> -> g-003`, topic `f948a410-f536-5069-b29c-4ad8e3339485`): **Resolved.** Slogan review request for `SPL-3342`; `SPL-3342` closed `done` at `2026-10-25 17:40:22Z`.
   - **`SPL-1691`** (`2026-10-13`, `c-001@<box-a> -> c-003`, topic `715e9385-9b20-5066-863c-4dffa05f4d15`): **Resolved / Historical.** Claude weekly limit alert that reset `2026-10-17T08:00Z`.
   - **`SPL-1589`** (`2026-10-13`, `c-001@<box-a> -> c-002`, topic `1226651b-b13c-568d-bde8-ea916cea7034`): **Resolved / Historical.** `2026-10-13` `<box-b>` reboot notice.
   - **`SPL-1587`** (`2026-10-13`, `c-003@<box-a> -> c-002`, topic `eac77771-f6fa-5224-88ac-aad2af59c362`): **Resolved / Historical.** `2026-10-13` agent OS account login handoff on `<box-a>`.

*(Separately, `SPL-4836` at the top of the owner's screenshot is a normal, non-blocker `todo` bug issue under `Area: refactoring` and must remain untouched.)*

---

## 3. Ranked Fix Options (Question 4)

A complete fix has three parts:
- **Part A**: Stop the wrong filings and fix `from_agent:` title/sender/reply handling.
- **Part B**: Close the 96 existing `from_agent:` `todo` issues (and `SPL-1555`) cleanly.
- **Part C**: Guard against silent regression with tests and a sweep invariant that does not abandon open blocker issues after 24 hours.

### Part A — Stop Wrong Filings & Fix `from_agent:` Handling (Ranked)

#### Option A1 (Recommended): Normalize `from_agent:` in hub blocker/store path + downgrade one-way cron nudges from `blocker` to `note` + widen resolution check
- **What changes & where**:
  1. **Strip and normalize `from_agent:` on `BlockerPost`**: In `csi-spl-api/src/go/spool-hub-api/internal/store/blocker_issue.go` (`BlockerPosts`, lines `164-180`, or a helper calling `spool.SplitFromAgent` from `internal/spool/fromagent.go`), extract `from_agent: <id>@<box>` from `p.Body` before computing `blockerTitle(p)` (`internal/hub/blocker_issue.go:337-345`), `blockerBody(p)` (`lines 347-369`), `p.FromID` (`created_by`), and `p.Assignees()` (`internal/store/blocker_issue.go:58-70`). This immediately eliminates `"from_agent: <id>@<box>"` titles, attributes `created_by` to the true sender, and restores `Assignees()` self-send suppression (`c-001@<box-a> -> c-001@<box-b>` no longer files self-blockers when proxied through `c-003`).
  2. **Match `from_agent:` and sender `kind='result'` in `FirstPostAfter`**: In `internal/store/blocker_issue.go:183-195`, match a subsequent post in `task_id` when **either** `from_id` matches `bareID(assignee)`, **or** `body` starts with `from_agent: <assignee>@`, **or** the blocker's sender posts `kind = 'result'` in the same `task_id` (preventing already-finished threads like `SPL-4783` from filing or staying open).
  3. **Downgrade one-way periodic cron nudges from `--kind blocker` to `--kind note`**: Change `--kind blocker` -> `--kind note` in the 8 automated cron/watchdog call sites (`spl-agent-restart.func.sh:831`, `spl-watchdog.func.sh:1231,1274`, `spl-asks-tick.func.sh:173`, `spl-spawn-place.func.sh:290`, `spl-wd-orch-outcome.func.sh:72`, `spl-push-orphan-check.func.sh:168`, `issue-close-landed-cron.sh:88,99`, `spl-epic-stall-check.func.sh:250`). These scripts already wake the recipient's pane via `spool-send.sh` / `spool-fleet-relay.sh`; they do not expect a conversational reply in `uuid5("spool-task:wd-...")`.
- **Risk**: Low. Local and cross-box pane delivery (`spool-notify.sh` / `hubclient`) delivers `note` messages identically to `blocker` messages; only `SweepBlockerIssues` treats `kind='blocker'` as an issue-creating ticket.
- **Size**: Small (~45 LoC in Go across `internal/store/blocker_issue.go` and `internal/hub/blocker_issue.go` + 9 one-line `--kind note` edits in `csi-spl-orc`).

#### Option A2: Normalize `from_agent:` at hub ingest (`hubSend`) + filter synthetic alarm tasks in `SweepBlockerIssues`
- **What changes & where**:
  1. Call `spool.WithFromAgent` inside the hub's message ingest handler (`csi-spl-api/src/go/spool-hub-api/internal/hub/`) before inserting into `messages` (or when `from_id` is an announced box seat and line 1 is `from_agent:`), so `messages.from_id` and `messages.body` are normalized everywhere in the DB.
  2. Keep `--kind blocker` on watchdog/cron scripts, but teach `SweepBlockerIssues` to skip messages whose `task_id` matches the deterministic `uuid5("spool-task:<prefix>")` set (`asks-open`, `spawn-share`, `orch-outcome`, `dispatch-*`, `wd-*`) or whose body carries a `no_blocker_issue: true` header.
- **Risk**: Medium. Rewriting `messages.from_id` at hub ingest interacts with `SPL-3865`'s `from_not_announced` enforcement if the check runs after normalization, and leaves historical `messages` rows un-normalized unless migrated.
- **Size**: Medium (~80 LoC across hub ingest + `blocker_issue.go`).

---

### Part B — Close the Existing 96 `todo` Issues (and `SPL-1555`) Cleanly (Ranked)

#### Option B1 (Recommended): One-shot audited CLI/action sweep transitioning the 96 open `from_agent:` `todo` issues (plus `SPL-1555`) to `diss` with a cited RCA note
- **What changes & where**:
  - After owner approval, run a scripted `spool issue-edit` / `do_spl_db_query` batch (or dedicated `run` action) on `t1` (`prd`) targeting the exact set:
    `tenant_id = 't1' AND parent_number = 2394 AND status = 'todo' AND deleted_at IS NULL AND archived_at IS NULL AND title LIKE 'from_agent:%'` (96 rows, plus `SPL-1555` if included), setting `status = 'diss'` and posting a closing note citing `SPL-4850` and the reason (88 automated cross-box alarm pings with no reply channel; 8 historical/already-resolved hand-written blockers).
- **Risk**: Very low. Every row in the predicate has been verified in Section 2.4; `SPL-4836` (normal title, `parent_number = 2393`, no `blocker` label) is untouched. Using `diss` (with note) matches existing hub semantics for dismissed blocker issues (`175` historical `diss` rows in `t1`).
- **Size**: Small (1 scripted batch / action execution after owner `GO`).

#### Option B2: Backfill `messages.body` / strip `from_agent:` on the 96 rows and let an expanded closer auto-resolve only the 10 replied rows, manually dismissing the remaining 86
- **What changes & where**:
  - Update `issues.title` on the 96 rows to line 2 of `messages.body`, run the updated `SweepBlockerIssues` (with no 24h cap) so the 7 late-reply rows + 3 peer-replied rows transition to `done`, then transition the remaining 86 one-way alarm issues to `diss`.
- **Risk**: Low-Medium (mutates both titles and statuses on historical telemetry issues that will immediately be closed anyway).
- **Size**: Medium.

---

### Part C — Guard Against Silent Regression (Ranked)

#### Option C1 (Recommended): Unit tests in `blocker_issue_test.go` + open-blocker-issue resolution pass without the `24h` cutoff
- **What changes & where**:
  1. **Regression tests (`csi-spl-api/src/go/spool-hub-api/internal/hub/blocker_issue_test.go`)**:
     - Test that a relayed blocker with `Body = "from_agent: c-001@<box-a>\nReal blocker subject\nDetails"` and proxy `FromID = "c-003"` creates an issue titled `"Real blocker subject"` (never `"from_agent: ..."`), sets `created_by = "c-001"`, suppresses self-assignment when `ToID = "c-001"`, and resolves when the assignee replies either directly (`FromID = assignee`) or via cross-box relay (`Body = "from_agent: <assignee>@<box>\n..."`).
  2. **Remove the `24h` resolution blind spot (`internal/hub/blocker_issue.go:110-149`, `internal/store/blocker_issue.go`)**:
     - Keep `blockerShortLookback` (`1h`) / `blockerLongLookback` (`24h`) for **creating** new blocker issues, so the time-bounded scan stays fast, **but** on `long == true` ticks (every 10 minutes), query open `todo` issues under epic `SPL-2394` (`labels @> '{blocker}'`) and check `FirstPostAfter` for their linked `(msg_id, task_id, assignee)`. That way, an open blocker issue is resolved whenever the answer arrives—even `31h..193h` later—and cannot get stranded past 24 hours.
- **Risk**: Very low. The open-issue query on `long` ticks scans only live `status = 'todo' AND labels @> '{blocker}'` rows (which after cleanup is near zero) and uses `messages_task_idx` (`tenant_id, task_id, received_at DESC`).
- **Size**: Small (~60 LoC in `internal/hub/blocker_issue.go`, `internal/store/blocker_issue.go`, and `internal/hub/blocker_issue_test.go`).

#### Option C2: CI/cron audit check failing if any open issue has `title LIKE 'from_agent:%'`
- **What changes & where**:
  - Add a SQL assertion in fleet health / watchdog checks alerting if `SELECT count(*) FROM issues WHERE deleted_at IS NULL AND title LIKE 'from_agent:%'` exceeds `0` after cleanup.
- **Risk**: Low, though reactive rather than preventative on its own (best paired with C1).
- **Size**: Tiny (~10 LoC).

---

### Owner Decision Polls

````poll
Should we apply Recommended Fix Bundle A1 + C1 (strip `from_agent:` in hub blocker handling, match relayed replies & sender `result` posts, remove the 24h resolution blind spot for open blocker issues, and change one-way watchdog/cron nudges from `--kind blocker` to `--kind note`)?
1. Yes — implement A1 + C1 (strip `from_agent:`, fix proxy sender/reply matching, resolve open blocker issues beyond 24h, and switch one-way cron nudges to `--kind note`)
2. Implement the Go hub fixes only (strip `from_agent:`, fix proxy matching, resolve beyond 24h), but keep `--kind blocker` on cron/watchdog scripts and filter their synthetic task slugs in the hub
3. Hold code changes for now
````

````poll
How should we clean up the 96 existing open `from_agent:` `todo` issues (and `SPL-1555`) under `SPL-2394` in `t1` (`prd`)?
1. Option B1 (Recommended) — transition all 96 open `from_agent:` `todo` issues (plus `SPL-1555`) to `diss` with a closing comment citing `SPL-4850`
2. Option B2 — rewrite their titles to line 2 first, let the 10 replied issues close as `done`, and transition the 86 unanswered cron alarms to `diss`
3. Leave the existing 96 issues open for manual triage
````

---

## 4. Panel Record & Signatures

### 4.1 Findings Folded

| Round | Seat | Source Message / Reference | Summary of Finding | Disposition in Document |
| :--- | :--- | :--- | :--- | :--- |
| `v0.1` | `c-754` (Hub Code Expert) | Spool `6709d93d-c631-42cc-bdaf-c3c97a209804` (`2026-11-05T09:57:04Z`) | Identified `spool-fleet-relay.sh:142` (`from_agent:` prepend), `WithFromAgent` only called in `hubclient.go:979`, `blockerTitle` (`blocker_issue.go:337-345`), proxy `from_id` mismatch (`Assignees` self-blocker bug on 16 issues and `FirstPostAfter` proxy bug), 89 zero-reply synthetic-task alarms vs 7 replies after `24h` `blockerLongLookback` (`blocker_issue.go:69-70`), and all 96 issue counts/categories. | Folded in full into Sections 1, 2, and 3. |
| `v0.1` | `a-747` (Editor) | Empirical SQL + WUI screenshot verification (`2026-11-05`) | Verified owner screenshot `ebd63d3d...` (`SPL-4836` is a separate non-blocker `todo` bug; the other 17 visible rows are part of the 96 `SPL-2394` `from_agent:` issues), verified `SPL-4783` was answered (`3f26318f`) and completed (`5152bbaf`) 81s before filing, and verified all 8 hand-written blockers are resolved. | Folded into Sections 2.2, 2.3, and 2.4. |

### 4.2 Signatures

| Role | Agent ID | Version | SHA Read | Status |
| :--- | :--- | :--- | :--- | :--- |
| **EDITOR** | `a-747` | `v0.1` | *(initial draft)* | Drafted `v0.1` |
| **HUB CODE EXPERT** | `c-754` | *(pending)* | *(pending)* | Pending `v0.1` review & signature |
| **REVIEWER** | `c-756` | *(pending)* | *(pending)* | Pending `v0.1` review & signature |
