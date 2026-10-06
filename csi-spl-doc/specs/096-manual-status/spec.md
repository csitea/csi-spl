# 096 Manual status: "Busy", "Unavailable until 14:00"

Status: **v0.2, DECIDED, 2026-10-06.** The owner accepted every proposal
(section 12, msg `cb7a9cec`); building runs in lanes L1..L5
([tasks.md](tasks.md)).
Topic: t1 `3ea05d6c-58f8-4520-a4d8-dd5d3b519f33` (a member's ask, msg
`13205fb5`). Author: c-384.
Builds on: the live presence frame (`wui-live-ws.md` section 3.2), spec
[094 hub multi-instance](../094-hub-multi-instance/spec.md) (G5, human
presence across instances), spec [095 Web Push](../095-web-push/spec.md)
(who is pushed a new line).

## 0. Why

The member, in English: "is there an option to mark my account as unavailable
at a given moment, e.g. when I cannot answer a received message or task right
away, and have that visible to the other users?"

Today there is not. Presence is automatic only: a member is green while a
browser tab of theirs holds a socket to the hub and grey otherwise. A member
who is at the desk but in a meeting reads exactly like one who is free to
answer, and a sender has no way to know a reply will be late.

This spec adds a **manual status** the member sets themselves, shown next to
their name wherever others see them, that clears itself at an "until" time.

## 1. Measured before (tree `50494780d`)

| fact | check |
|---|---|
| human presence is a per-process count of browser sockets | `internal/hub/channels.go` `humanOnline`: `s.online[(tenant, id)] += delta`; first open -> frame `online`, last close -> `offline` |
| the presence frame carries two values only | `channels.go` `presenceMsg{Peer, Status, Type}`; WUI `src/types/spool.ts` `PresenceFrame.status: 'online' \| 'offline'` |
| a new socket gets a snapshot of who is online | `internal/hub/wui.go` `wuiWelcome` -> `onlinePeers` -> one `presence online` frame per peer |
| a human is a peer `<HUM-id>@<WUIBox>` | `channels.go` `onlinePeers`: `k[1]+"@"+WUIBox` |
| human presence is not shared across hub instances yet | spec 094 table row G5 (`s.online` is a count of this process's sockets) |
| the roster read already carries per-member presence-like fields | `internal/hub/view.go` `viewHuman` (`display_name`, `owner`, `interests`, `last_seen`) |
| search results carry an `online` flag per human | `internal/hub/search.go` (`"online": online`) |
| the WUI draws one dot per person | `components/MentionList.vue` `<span class="dot" :class="{ on: p.online }" />`; `FeedHeader.vue` (DM peer dot + status text); `ChannelSidebar.vue` |
| the help text promises two states only | `csi-spl-doc/doc/help/channels-and-direct-messages.md` 3.1: green = connected, grey = offline |
| per-member settings live on `humans` (hub-wide) | `0006_users_and_memberships.sql` `humans`; `0133_human_rail_order_calendar.sql` adds a column there |
| tenant tables use the fail-closed RLS shape | `0107_agent_seats.sql` `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')` |
| next migration number | `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| tail -1` -> `0133_human_rail_order_calendar.sql` |

## 2. Terms

- **presence**: automatic, set by the hub: `online` (a tab is connected) or
  `offline`. Unchanged by this spec.
- **status**: manual, set by the member: one of `available`, `busy`,
  `unavailable`, plus an optional **note** (short text) and an optional
  **until** (a time at which the status clears by itself).
- **shown state**: what others see, the combination of the two (section 4).

## 3. The statuses

| status | meaning to others | ring on the dot | default text (no note) |
|---|---|---|---|
| `available` (default) | "I read and answer as usual" | none (presence only) | none |
| `busy` | "I am here but a reply may take a while" | amber | "Busy" |
| `unavailable` | "I will not answer until I am back" | red | "Unavailable" |

- **Note**: up to 80 characters, plain text, one line, no markup, links not
  rendered. Example: "In a meeting", "On leave, back Monday".
- **Until**: optional. The picker offers *30 min*, *1 hour*, *2 hours*,
  *until end of today*, *until tomorrow 09:00*, *custom date and time*, *no
  end*. Stored in UTC; shown to every viewer in the viewer's own time zone
  ("Unavailable until 14:00", "until Mon 09:00" when not today).
- **Clearing**: at `until` the status returns to `available` and the note is
  cleared. The member can clear it by hand at any time. A status with no
  `until` stays until cleared.
- **Expiry is evaluated on read**, not by a timer: the hub treats a row whose
  `until <= now()` as `available` everywhere it reads it, and a periodic
  sweep (section 7.3) deletes such rows and pushes the clearing frame. A
  missed sweep therefore never shows a stale status.

## 4. How it combines with automatic presence

Presence and status are independent; the WUI shows both.

| presence | status | dot | text next to the name |
|---|---|---|---|
| online | available | green | none |
| offline | available | grey | none (hover: "last seen ...", as today) |
| online | busy | green, amber ring | "Busy · In a meeting" |
| offline | busy | grey, amber ring | "Busy · In a meeting" |
| online | unavailable | green, red ring | "Unavailable until 14:00" |
| offline | unavailable | grey, red ring | "Unavailable until 14:00" |

Rule: **the dot fill is presence, the ring is status.** A status shows while
offline too: that is exactly when a sender most needs it ("on leave until
Monday"). The ring is the only colour change, so the dot keeps its one
meaning; a colour-blind reader gets the text, and the ring carries an
`aria-label` ("Busy", "Unavailable").

## 5. Where others see it

| place | what shows |
|---|---|
| People rail and member lists (channel properties, member pickers) | ring on the dot; the note under the name, one line, truncated |
| DM list (Direct Messages panel) | ring on the dot; full text on hover / long press |
| DM header (`FeedHeader.vue`, the peer's status text) | "Unavailable until 14:00 · On leave" in place of "online" / "offline" |
| `@` mention picker (`MentionList.vue`) | ring on the dot, the note in grey after the name |
| message header (author line of a post) | **nothing** (proposal, Q9): a status is about now, a post is about then; today's status on a week-old post misleads |
| People card (profile popover) | full status, note and until |
| search results (people) | ring on the dot |

### 5.1 What a sender sees

When a member opens a **DM** with, or **@mentions**, someone whose status is
`unavailable` (or `busy`, Q3), the composer shows one inline line above the
input, never a dialog, never blocking the send:

> **FirstName LastName is unavailable until 14:00** · On leave

The line appears as soon as the peer or mention is chosen, so it is read
before sending. Sending works as today; the message is stored and delivered
as normal. Nothing is auto-replied (an auto-reply posts text the member did
not write; Q4).

## 6. The member's own notifications

A status **mutes nothing by default.** Decided (Q1): the picker has a
checkbox *"Pause my notifications while unavailable"*, off by default. When
the member ticks it:

- `unavailable` silences the member's in-tab sound and system notification
  (`csi-spl-wui/src/utils/notify.mjs`, one more check in `shouldPing`) and,
  once spec 095 is built, removes the member from the push recipients in
  095 section 6.2 as one more "minus" step after the mute prefs. Unread
  counts and Flow still record everything; the member catches up when the
  status clears.
- `busy` never silences.

Decided in spec [095 §13](../095-web-push/spec.md): a pause silences only the levels below High.

**Relation to the other lanes, without changing their scope:**

- **Spec 095 Web Push** decides *who is pushed a line*. This spec adds at
  most one filter to its recipient query (Q1). Neither spec waits for the
  other: without 095 the filter is the in-tab check only.
- **Bug lane notify-missed-member (c-376)** fixes a member missing an alert
  they should get. This spec only ever removes alerts the member asked to
  remove. Order of checks in `shouldPing`: the c-376 fix decides whether an
  alert is due, then the status filter. They touch the same function, so
  the build lane rebases after c-376 lands and runs its tests.

## 7. Data model, frames, API

### 7.1 Per workspace, not per account (proposal; Q2)

A status is **per workspace**: a member of two workspaces can be "Busy" in
one and available in the other, and one workspace never learns anything
about the other (section 9). The cost is setting "on leave" twice; the
picker gets a checkbox *"Set in all my workspaces"* that writes one row per
workspace the member belongs to (Q2 may drop it).

### 7.2 Table (migration `0141_human_status.sql`, forward-only)

```sql
CREATE TABLE human_status (
    tenant_id  text        NOT NULL,
    human_id   text        NOT NULL,
    status     text        NOT NULL CHECK (status IN ('busy', 'unavailable')),
    note       text        CHECK (note IS NULL OR char_length(note) <= 80),
    until_at   timestamptz,
    pause_notify boolean   NOT NULL DEFAULT false,
    set_at     timestamptz NOT NULL DEFAULT now(),
    set_by     text        NOT NULL,
    PRIMARY KEY (tenant_id, human_id),
    FOREIGN KEY (tenant_id, human_id) REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE
);
ALTER TABLE human_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE human_status FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON human_status
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON human_status
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
CREATE INDEX human_status_until ON human_status (until_at) WHERE until_at IS NOT NULL;
```

- `available` is **no row**: clearing deletes the row. Most members never
  have one, so the roster join stays cheap.
- `pause_notify` is the Q1 checkbox, off by default; it acts only while
  `status = 'unavailable'` (section 6).
- The key is the membership: leaving a workspace deletes the row.
- `set_by` is the member's own id today (section 8, Q5 keeps room for more).
- Runtime grants: `spool_hub_rt` gets SELECT / INSERT / UPDATE / DELETE
  from the default privileges in `runtime-grants.sql`, like every tenant
  table (no edit there); one row in the existing
  tenant-isolation guard (workspace B reads 0 rows of A).
- The DDL lands on dev **and** prd before any hub code reads it (DDL first).

### 7.3 Hub

- **Roster read** (`view.go` `viewHuman`): one optional field
  `status: {state, note, until}`, omitted when available or expired. Like
  `last_seen` it is presence, not a role, so it is outside the role guard.
- **Search** (`search.go`): the same `status` object next to `online`.
- **Write**: `PUT /v1/me/status` `{state, note?, until?}` and
  `DELETE /v1/me/status`. Own row only (the session's `human_id`); `until`
  in the future and at most 90 days out (Q6); `note` trimmed, control
  characters stripped, 80 characters max.
- **Expiry sweep**: the existing relay tick (`SPOOL_HUB_QUEUE_RELAY`, 5 s)
  deletes rows with `until_at <= now()` for the tenants it already sweeps,
  at most once a minute per tenant, and sends the clearing frame. Reads
  ignore expired rows regardless.

### 7.4 The presence frame change

The existing `presence` frame stays byte for byte, so old tabs keep working.
A **new frame type** carries status, so no old client misreads it:

```json
{"type": "status", "peer": "HUM-12@wui", "state": "unavailable", "note": "On leave", "until": "2026-10-07T12:00:00Z"}
```

- `state: "available"` (note and until omitted) clears it.
- Sent to every browser socket of the workspace when the member sets or
  clears a status, and by the sweep on expiry.
- `wuiWelcome` sends one `status` frame per member with a live status right
  after the presence snapshot, so a fresh tab is complete without a second
  read.
- With N >= 2 hub instances the frame rides the spec 094 bus like the other
  cross-instance frames. Unlike presence (094 G5) a status needs no
  per-instance counting: it is one database row every instance reads. Until
  the bus exists, tabs on another instance pick a change up at their next
  roster read; that is the only gap.

### 7.5 WUI

- **Picker**: on the self row ("You") at the top of the DM list and in the
  avatar menu: *Set a status*. Available / Busy / Unavailable, a note field
  with an 80-character counter, the "until" choices from section 3, *Set in
  all my workspaces* (Q2), *Save*, *Clear status*. Phone: a bottom sheet
  with the same fields. Loaded lazily (initial-chunk budget).
- **Store**: a `statusByPeer` map next to the presence map, filled by the
  roster read and the `status` frame; the client also re-checks expiry every
  minute, so a tab that missed the clearing frame stops showing it.
- **Rendering**: one dot component gains the ring and is used by every place
  in section 5, plus the composer line of 5.1.
- **i18n**: every new string through the existing i18n files (English and
  Bulgarian at least; the ask was written in Bulgarian). User text says
  "workspace", never "tenant".

### 7.6 Help

`channels-and-direct-messages.md` 3.1 gains the ring rule and a short
"Setting your status" subsection; `user-settings.md` links to it.

## 8. Agents

- **Read: yes.** The roster's `status` field reaches agents through the
  roster they already read; no new tool. An agent about to wait on a human
  can see "Unavailable until 14:00".
- **Set for themselves: no.** An agent's availability is already its presence
  and its seat (`agent_seats`); a manual status would be a second, competing
  truth.
- **Set for a human: no** in this version (Q5). `set_by` is kept so a later
  "set from my calendar" needs no migration.
- **Dispatchers**: **no routing change**; they route member posts to agents,
  not to humans. Not in this version (Q7 decided: no change, L6 dropped);
  the idea kept for later: when a dispatcher or orchestrator
  raises a *blocker question to a human* who is `unavailable`, its post says
  so in its first line ("FirstName LastName is unavailable until 14:00;
  holding") and it does not re-ask or escalate on a timer until the status
  clears. That is a text change in the dispatcher handoff doc only.

## 9. Privacy

- Visible to **every member of the same workspace** and to no one else: RLS
  per workspace, no cross-workspace read, no public endpoint.
- The note is text the member chose to publish; the picker says "Everyone in
  this workspace sees this."
- No history: a cleared or expired status is deleted, not archived (Q8).
- An "until" reveals a schedule, so it is optional. Default *no end* for
  `busy`, *1 hour* for `unavailable`, so a forgotten Unavailable does not
  linger.
- Agents read it (section 8): the same audience as the roster today.

## 10. Test plan

### 10.1 Store and hub (CI, Postgres)

- `TestHumanStatusSetClear`: PUT, roster shows it, DELETE, roster omits it.
- `TestHumanStatusExpiresOnRead`: `until` in the past -> roster omits it with
  no sweep run.
- `TestHumanStatusSweepFrame`: the sweep deletes the expired row and sends
  one `status available` frame to that workspace's browser sockets only.
- `TestHumanStatusTenantIsolation`: a row in workspace A reads 0 rows from B.
- `TestHumanStatusOwnRowOnly`: a member cannot write another member's row,
  an agent cannot write any (403).
- `TestHumanStatusValidation`: note > 80 characters, `until` past or > 90
  days, unknown state -> 400.
- `TestWelcomeStatusSnapshot`: a new socket gets the presence snapshot, then
  one `status` frame per live status.
- The existing presence frame byte test stays green unchanged (old clients).

### 10.2 WUI

- Unit: ring by state, text by state and viewer time zone, client-side
  expiry, composer line for DM and `@` mention.
- e2e (mock hub): set Busy with a note from the self row; a second context
  sees the ring in the DM list, the mention picker and the DM header; clear;
  ring gone. Expiry with a short `until` and a fake clock.
- Phone width: bottom sheet, no horizontal scroll.

### 10.3 Dev proof (first)

Two members on a dev workspace in two browsers. A sets *Unavailable*, until
+5 min, with a note; B sees it in the DM list, mention picker, DM header and
composer line (screenshots). Wait for expiry: B's ring clears without a
reload. A sets *Busy, no end* and closes the tab: B sees a grey dot with an
amber ring.

### 10.4 Prd

The same proof on prd, on the e2e workspace host (not the apex), with the
footer version recorded, after the dev proof is green.

## 11. Effort: lanes

| # | lane | size | depends on |
|---|---|---|---|
| L1 | rdb `0141_human_status.sql`, grants, isolation guard row; applied dev and prd | S | owner go |
| L2 | hub: store, `PUT` / `DELETE /v1/me/status`, roster + search field, `status` frame, welcome snapshot, sweep, tests 10.1 | M | L1 on dev and prd |
| L3 | WUI: store map, dot ring, picker (desktop + phone), composer line, i18n, e2e 10.2 | M | L2 contract (can start on the mock) |
| L4 | help 3.1 + "Setting your status"; dev then prd proof 10.3 / 10.4 | S | L2, L3 deployed |
| L5 | Q1 = checkbox: the "Pause my notifications" check in `notify.mjs`; one recipient filter in 095 section 6.2 once 095 is built | S | c-376 landed; the 095 lane |
| ~~L6~~ | dropped: Q7 = no dispatcher change | - | - |

Roughly 2 to 3 lane-days for L1 to L4.

## 12. Decided (owner, 2026-10-06, msg cb7a9cec: accept the proposals)

The owner (HUM-10, t1 `3ea05d6c`) accepted every proposal of v0.1 (msgs
`cb7a9cec`, `ddfccf96`: "start implementing according to it. If something
is wrong, we will iterate after it").

1. **Mute**: a picker checkbox *"Pause my notifications while unavailable"*,
   **off by default**. When on, `unavailable` silences the member's in-tab
   sound, system notification and (once 095 is built) Web Push, as section 6
   describes. `busy` never silences.
2. **Scope**: **per workspace**, with the *"Set in all my workspaces"*
   shortcut in the picker (section 7.1).
3. **Composer line**: shown for **both** `busy` and `unavailable`; Busy in a
   softer colour (section 5.1).
4. **Auto-reply**: **none**. The composer line tells the sender before they
   send.
5. **Agents**: agents **do not set** a status, not for themselves and not
   for a human, in this version. `set_by` stays for a later "set from my
   calendar".
6. **Longest "until"**: **90 days** (the hub's write check, section 7.3).
7. **Dispatchers**: **no change** in this version. Lane L6 is dropped.
8. **Audit**: **none**. A cleared or expired status is deleted, not kept.
9. **Message header**: **nothing** on a post's author line.

<!-- version: 0.2.0 · updated: 2026-10-06 -->
