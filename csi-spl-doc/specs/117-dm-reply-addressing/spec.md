# 117 — a DM reply from the topic page reaches nobody

Status: DRAFT, for the owner's review. Source: t1 topic f87e6c9d
(msg d2d8fe87 "the following msg did not pass through", ee221470 "this user
should be able to write me a msg"). Measured on prd 2026-10-09, read-only, as
the per-env SA (`do_spl_hub_member_list`, `do_spl_db_query`), tree 341ad8486.

The workspace and the two people are named here by their seat ids only:
`HUM-10` (the owner, admin) and `HUM-46` (a member, role `regular_user`),
tenant `<TENANT>` (the workspace in the owner's screenshot).

## 1. What happened

### 1.1 The rows (n = 4, all stored, none refused)

| msg_id | task_id | received (UTC) | from | to | channel |
|---|---|---|---|---|---|
| 86abbd6a | 483e9afc (the HUM-10 ↔ HUM-46 DM) | 15:52:31 | HUM-46@box-wui | **ALL-0**@box-wui | NULL |
| b7b1b5e7 | 483e9afc | 15:52:38 | HUM-46@box-wui | **ALL-0**@box-wui | NULL |
| 50ed77e0 | 483e9afc | 15:52:41 | HUM-46@box-wui | **ALL-0**@box-wui | NULL |
| 22f73584 | 1a7c634e (a new topic) | 15:53:47 | HUM-46@box-wui | **ALL-0**@box-wui | NULL |

The DM's opening row, 955dcdfb (10-08 09:02), is HUM-10 → HUM-46, channel NULL.
The four bodies are the four links the owner relayed in t1 topic 86a916bf
msg 37edb836.

### 1.2 Not the role

`HUM-46` was `regular_user` before (member list, 2026-10-09) and was not changed
(c-001). `regular_user` holds `notes.send` and `agents.command`, the same grant
as `developer` (`internal/rbac/rbac.go:132`). The hub stored all four rows, so
no rule refused them.

### 1.3 The cause: a reply with no addressee, read only by its addressee

1. **The WUI leaves `to` empty.** `stores/channel.ts:480` sets `to` to the DM
   peer only when the store holds one (`peer.value`, set by `selectDm`, i.e.
   the `/dm/<peer>` page). On the topic page `/t/<task_id>`, the store holds
   no peer, and a line with no `@mention` goes out with no `to`. HUM-46's
   only read marks are `t:483e9afc` (15:56:10) and `t:1a7c634e` (15:59:50);
   there is no `dm:` mark. So both sends came from the topic page.
2. **The hub fills in `ALL-0`.** `internal/hub/wui.go:718` hands a channel-less
   `ALL-0` reply to `topicReplyAgent` (`internal/hub/topic_reply.go:25`), which
   re-addresses it only to an agent that took part (604f9fa22). A
   person-to-person DM has no agent, so the row is stored as HUM-46 → ALL-0
   with no channel: "keeps the browser-only post: never a refusal".
3. **Every read door drops it for HUM-10.** A row with no channel is readable
   by its two ends only, and HUM-10 is neither:
   - topic and DM feeds: `internal/store/view_postgres.go:316-318` and the
     per-message door of `ViewTopic`
   - DM counts: `internal/store/view_topics_batch.go:100`
   - live push: `internal/hub/wui.go:504` (`wants`)
   - unread flow: `flow_postgres.go:37,41` writes the DM event for `to` only,
     and `ALL-0` is not a seat, so no event (prd `flow_events`: 0 rows for
     HUM-10 on these tasks)

   The rows are visible to their sender only. The sender saw "sent"; the owner
   saw nothing.

### 1.4 The "1" badge (not explained)

Neither the server count nor the flow carries these rows for HUM-10. The "1"
next to the member in the screenshot is therefore not one of them. Fix task
T5 records where it comes from; it does not change the cause.

## 2. Fix

Neither side alone is enough: rows from an older WUI, a phone page or an agent
tool reach the hub with the same shape.

### 2.1 Hub (owner of the rule) — lane c-642@sat

**FR-1.** A channel-less `ALL-0` reply (is_parent 0) in a topic whose
non-sender ends are **exactly one human** is re-addressed to that human, the
same way `topicReplyAgent` re-addresses to an agent. The order is: an agent
first (today's rule, unchanged), then the one other human. When there is more
than one other human, or none, the hub refuses it with `400 dm_needs_to`
("say who this is for"), never a silent browser-only post. Only the lobby task
keeps today's behaviour.

**FR-2.** A new channel-less **root** (is_parent 1) with no `to` is refused
(`400 dm_needs_to`). A new topic belongs in a channel or goes to a person.
Today such a row (22f73584) is invisible to everyone but its author.

**FR-3.** The ack carries the final `to`, so the sender's own card shows who
it went to.

### 2.2 WUI

**FR-4.** The topic page `/t/<task_id>` sends a reply in a DM topic with
`to = dmPeerOf(<the topic's rows>, me)` (`utils/channel-feed.mjs:974`), the
same as `/dm/<peer>` does.

**FR-5.** A `dm_needs_to` refusal shows the existing "Not sent" line with the
hub's text. It is never dropped.

### 2.3 The 4 stored rows

**FR-6 (needs c-001's go, a prd write).** Re-addressing the four rows of §1.1
to `HUM-10` needs a new named action (`do_spl_msg_readdress`) and a prd write.
The owner already has their content (37edb836), so the default is to **leave
them** unless the owner wants the lines back in the DM.

## 3. Tasks

| id | lane | what | test that fails on today's code |
|---|---|---|---|
| T1 | hub | FR-1 + FR-3 in `topic_reply.go` (a `topicReplyHuman` after `topicReplyAgent`) | DM topic A↔B: B sends `to` omitted, `is_parent` 0 → stored `to_id` = A, and A's `ViewTopic` returns it (memory + Postgres) |
| T2 | hub | FR-2 | B sends a channel-less root with no `to` → 400 `dm_needs_to`, 0 rows |
| T3 | wui | FR-4 | unit: the topic page's send frame for a DM topic carries `to` = peer |
| T4 | wui | FR-5 | the refusal renders "Not sent" |
| T5 | hub | the "1" badge in §1.4: trace the count source for HUM-10's sidebar row | — (a finding, not a fix) |

## 4. How the owner sees it work

After T1 ships on prd: HUM-46 opens the DM topic from a notification (the
`/t/…` page) and replies without an @mention. The line appears in the owner's
`/dm/HUM-46@box-wui` within a second, and the badge counts it.

<!-- last-edit: 2026-10-09T16:40:00Z -->
