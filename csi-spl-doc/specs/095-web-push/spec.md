# 095 Web Push: a new message reaches my other devices

Status: **v0.4, 2026-10-06.** v0.4 records the owner's answers to Q1 to Q6
(t1 `a477c187`, msgs `d3d8e225-38a2-4cbe-a45a-a27ec6daf047`,
`51f96f43-d781-4cef-92ce-53942be73a39`, `5517673c-7452-4d04-9171-63dbeacb2b3e`):
Q1 to Q5 as proposed; Q5 in memory for this build, with a durable
fire-and-forget outbox as a planned follow-up; Q6 **changed**: quiet hours are
in this build (section 6.6, lane 9). **Q1 to Q10 are all decided**; the one
choice left for the owner is which levels quiet hours silence (section 6.6,
a proposal). The owner gave the go to build (msg `39d77db2`).
v0.3 recorded Q7 to Q10 (msg `08477fa7-802b-4a2f-ab74-f46852a3e8be`);
v0.2 added section 13, notification priority levels (msg `b87a487a`,
author c-386). Spec only: no code, no key, no secret slot, no terraform, no
cnf value was touched by this lane.
Topic: t1 `cd9b0f47-a5cb-4a5e-bc92-c3723aecba67` (a member's ask, msg
`3e2b31ea`). Author: c-378.
Builds on: [062 per-user Flow](../062-flow-per-user-counts/spec.md) (who an
event is for; its Q4 deferred this spec), the in-tab alert rules
(`csi-spl-wui/src/utils/notify.mjs`) and the PWA service worker
(`csi-spl-wui/src/public/sw.js`, its `notificationclick` handler, CLE-77890).
Ideas lists: mobile 3.2 / consensus D2, desktop 3.14 / consensus L15.

## 0. Why

The member, in English: "when a new message arrives I get no notification. I
tested the sounds, they are on. I need a clear and reliable notification for a
message in this channel EVEN WHEN I WORK ON ANOTHER DEVICE, and to check
exactly that new message quickly."

The ask has two halves. The same-browser miss is a bug with its own lane
(notify-missed-member) and is **out of scope here**. This spec is the other
half: a device with **no Spool tab running** (a closed browser, a phone with
the app swiped away, a laptop in another room) hears nothing today.

## 1. Measured before (tree `acc9f9ccd`)

| fact | check |
|---|---|
| no Web Push code anywhere | `grep -rliE 'pushmanager\|vapid' csi-spl-wui/src csi-spl-api/src` -> 0 files |
| every alert is raised by a live tab | `csi-spl-wui/src/utils/notify.mjs` `shouldPing` / `notificationOptions`; `csi-spl-doc/doc/help/user-settings.md` section 6 |
| channel mutes live in the browser only | `notify.mjs` `MUTED_CHANNELS_KEY = 'spool.muted-channels'` (localStorage); the hub stores no mute |
| the click target already exists | `notify.mjs` `notificationTarget` -> `{ msgId, url: /m/<msg_id> }`; page `csi-spl-wui/src/pages/m/[id].vue`; `sw.js` `notificationclick` -> `openFromNotification` focuses a tab or opens one there |
| who a line is "for" is decided at write time | `0104_flow_events.sql` `flow_events (tenant_id, member_id, msg_id, kind mention\|poke\|dm\|reply)`, written in the insert statement (`store/flow_postgres.go` `flowInsertCTE`) |
| the live Flow frame skips members with no socket | `internal/hub/flow.go` `fanoutFlow` -> `flowSockets`; it returns early when `len(socks) == 0` |
| the read door (who may read a line) | `store/flow_postgres.go` `flowDoorSQL`: a DM by its two ends, a created channel by its member list, a public channel for every member |
| secrets reach the hub as Secret Manager env | `030-cloud-run-hub/04-cloud-run-service.tf` `secret_key_ref`; cnf `hub.secret_env`, and the `wui_key` / `release_note_bans` "slot always, inject once seeded" pattern in `csi-spl-cnf/csi-spl/all.env.yaml` |
| the service worker keeps an app shell (W9) | `sw.js` header: `SHELL_CACHE = 'spool-shell-v1'`, network-first navigations; `/api/**` is never cached |
| next migration number | `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| tail -1` -> `0133_human_rail_order_calendar.sql` |

## 2. Terms

- **device**: one browser profile (or one installed PWA) on one machine, on
  one workspace host. Web Push gives it one **subscription**: an endpoint URL
  at the browser vendor's push service plus two keys (`p256dh`, `auth`).
- **push**: a message the hub sends to that endpoint; the browser wakes the
  service worker, which shows a system notification, even with no tab open.
- **VAPID**: the hub's own P-256 key pair (RFC 8292). The public half goes to
  the browser at subscribe time; the private half signs every push.
- **feed**: a channel, a DM peer, or a topic (thread) inside a channel.

## 3. Who opts in, and how

### 3.1 Per device (the switch)

Settings -> Notifications (`/settings/notifications`) gets one new block,
**"This device, when Spool is closed"**, with one button: **Turn on**.

1. The click (a user gesture, which iOS requires) asks for the browser's
   notification permission if it is not granted yet.
2. The WUI fetches the hub's VAPID public key (`GET /v1/push/key`, section
   6.1) and calls
   `pushManager.subscribe({ userVisibleOnly: true, applicationServerKey })`.
3. It sends the subscription to `POST /v1/me/push-devices` with a device
   label the member can edit (default: browser + OS, e.g. "Chrome on
   Android").
4. The block then lists **every device of mine** with its label, its last
   successful push and a **Remove** button, so a lost phone can be cut off
   from another device. **Send a test** sends one push to this device.

Off is the default. A device never receives a push until its own member
turned it on, on that device. Turning it off (or Remove) deletes the hub row,
and calls `subscription.unsubscribe()` when it is this device.

Sign-out removes this device's row first (the WUI calls
`DELETE /v1/me/push-devices/<id>`), so a shared computer stops receiving the
previous member's pushes. A member removed from the workspace loses every row
(section 5).

### 3.2 What a device is told about (defaults)

Once a device is on, it gets, **by default**, the events the Flow badge counts
(062): a **mention** of me, a **DM** to me, a **poke**, and a **reply in a
topic I watch** (I posted in it, was mentioned in it, or was its `to`). Each event carries a
priority level (section 13), which sets its push urgency and its in-tab sound.

### 3.3 Per channel and per topic (the member's ask: "this channel")

Every channel row menu gets **"Notify my devices"** with three choices:

| choice | pushes for |
|---|---|
| **Every message** | every new line in the channel and its topics, except my own |
| **Mentions and replies** (default) | section 3.2 only |
| **Off** | nothing from this channel, not even a mention |

Every topic row menu gets **Follow** / **Unfollow**: Follow pushes every new
reply in that topic (it adds a `flow_watches` row, so the Flow badge agrees);
Unfollow removes the watch and silences the topic's replies (a mention still
pushes). Each DM peer has **On** (default) / **Off**.

These choices are **per member, held in the hub**, and apply to every device
of that member: the member wants to be told on the device they are NOT using,
so a choice made on one device has to reach the others. The existing
per-browser chime mute (`spool.muted-channels`) stays as it is for the in-tab
chime in this build. Q3 is decided: the two merge into one "Notify" menu
held in the hub, **later**, not in this build's lanes (section 12).

## 4. What a notification shows, and where a click lands

| field | value |
|---|---|
| title | `#<channel>` or `<sender name> (DM)`, then ` - <workspace name>` when the member belongs to more than one workspace |
| body | `<sender>: <text>`, the first 90 characters on one line (the Flow's `flowText` rule, `internal/hub/flow.go`), or `New message` when the preview is off (section 8) |
| tag | the feed's existing tag, `ch:<name>` or `dm:<peer>` (the tag every in-tab alert has carried since bug A), so a push and an in-tab alert for the same feed replace each other instead of stacking |
| data | `{ msgId, url: /m/<msg_id> }`, exactly `notificationTarget`'s shape |
| icon | the manifest's 192 px icon |
| sound | the OS notification sound; the custom chime cannot play from a closed app |

**A click lands on exactly that message.** The push handler builds the same
`data` the in-tab alert does, so the existing `notificationclick` code
(CLE-77890) does the rest: it focuses an open Spool tab and hands it the
message, or navigates it, or opens a new window at `/m/<msg_id>`. No new click
code. The page `/m/[id]` opens the message in its feed.

A burst in one feed shows **one** notification (same tag, the newest wins,
`renotify` true so it sounds again). Ten feeds show ten.

## 5. Data model (hub)

One forward-only migration (the next free number when it lands, `0134` today),
RLS in the 0104 shape (`tenant_scope` with the `NULLIF` guard,
`operator_scope`), DDL deployed before the hub that writes it.

```sql
CREATE TABLE push_devices (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    device_id     uuid        NOT NULL,
    member_id     text        NOT NULL,
    kind          text        NOT NULL DEFAULT 'webpush' CHECK (kind IN ('webpush', 'fcm', 'apns')),
    endpoint      text        NOT NULL,
    p256dh        text,
    auth          text,
    vapid_kid     text,
    label         text        NOT NULL,
    preview       boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL,
    last_ok_at    timestamptz,
    last_fail_at  timestamptz,
    fail_count    int         NOT NULL DEFAULT 0,
    expires_at    timestamptz,
    PRIMARY KEY (tenant_id, device_id),
    UNIQUE (tenant_id, endpoint)
);
CREATE INDEX push_devices_member ON push_devices (tenant_id, member_id);

CREATE TABLE push_prefs (
    tenant_id   text NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id   text NOT NULL,
    feed        text NOT NULL,
    mode        text NOT NULL CHECK (mode IN ('all', 'flow', 'off')),
    PRIMARY KEY (tenant_id, member_id, feed)
);
```

Columns: `endpoint` is the push service URL (for `fcm` / `apns`, the native
token); `p256dh` / `auth` are Web Push only; `vapid_kid` names the VAPID key
the subscription was made with (section 6.1); `preview` is the per-device
text switch (section 8); `expires_at` is the subscription's `expirationTime`
when the browser gives one. `feed` is `ch:<name>`, `dm:<peer>` or
`t:<task_id>`.

The member is a seat (`IsFlowMember`): agents get no pushes, as they get no
Flow events (062 Q5). The membership-removal path deletes the leaver's rows in
both tables (tested).

**The endpoint is a bearer capability**: anyone holding it plus the keys can
make the device show a notification. It is never logged (the log carries
`device_id` and the endpoint's host only), never returned except to its own
member, and never in a trace.

**Lifecycle.**

| event | action |
|---|---|
| push answered 201 / 200 | `last_ok_at = now`, `fail_count = 0` |
| push answered **404 or 410** (gone) | **delete the row** at once |
| 403 (VAPID mismatch, e.g. after a key rotation) | delete the row; the WUI re-subscribes on next open (section 6.1) |
| 413 (payload too large) | log, never retry; a test pins the size (section 8) |
| 429 / 5xx | honour `Retry-After` once, then drop that push; `fail_count += 1` |
| `fail_count` reaches 20, or no success in 30 days | delete the row |
| `expires_at` passed | delete the row |
| the WUI opens on a device that is on | it re-reads `pushManager.getSubscription()` and `PUT`s it when the endpoint or keys changed (browsers rotate them) |

The dead and expired rows are deleted by one daily sweep that runs next to the
hub's other periodic sweeps (e.g. `SweepClones`); no new scheduler.

## 6. The send path

### 6.1 Keys (secrets)

- One VAPID P-256 key pair **per env** (dev, prd). The private key lives only
  in Secret Manager, slot `csi-spl-hub-vapid-key`, injected as
  `SPOOL_HUB_VAPID_KEY` by the `secret_env` + `inject` pattern `wui_key`
  already uses (030 creates the empty slot; inject flips to `"true"` once a
  version exists). Never in git, cnf values, tfvars, terraform state or a log.
- It is minted by a named action, `./run -a do_spl_vapid_key_seed`
  (csi-spl-orc), run as the env's project service account (never the owner
  account), which generates the pair and adds the private half as a secret
  version. Nothing ad hoc.
- The hub derives the public key from the private one and serves it at
  `GET /v1/push/key` (`{ key, kid }`), so the public key needs no cnf value
  either. `kid` is a short hash of it; after a rotation the WUI sees its
  device's `vapid_kid` differ and re-subscribes.
- The VAPID `sub` claim is `https://` + the env's `BASE_DOMAIN` (cnf), never a
  literal host and never a personal mailbox.
- With no key injected (lde, CI, an env before seeding) `GET /v1/push/key`
  answers 404 and the settings block says "not available on this workspace
  yet". Nothing else changes.

### 6.2 Who receives a new line

After the message **commits** (never before; a resend of the same `msg_id`
pushes nothing, the `flowInsertCTE` rule), the storing hub instance computes
the recipients in one statement:

1. members with a `flow_events` row for this `msg_id` (mention, poke, DM,
   watched reply), written in the same transaction, so this is a read of the
   `flow_events_msg` index;
2. union members whose `push_prefs` for the line's channel or topic is `all`,
   filtered by the **read door** (`flowDoorSQL`): only members who may read
   that line;
3. minus members whose pref for the topic, the channel or the DM peer is
   `off` (the most specific pref wins: topic, then channel);
4. minus **the sender**: the author seat and the `typed_by` seat (a line I
   typed at an agent's terminal is mine, CLE-77889), so nobody is pushed
   their own words;
5. join `push_devices` of the remaining members.

The read door is applied **at send time**, so a member removed from a channel
(or whose `access_until` passed) before the line gets nothing.

Exactly one instance sends: the one that stored the line. With N >= 2 hub
instances (spec 094) nothing changes; the wake bus is not used for pushes.

### 6.3 Every device, even the one in use

The hub cannot know which device the member is looking at, and the point of
the ask is the device they are NOT looking at. So **every** device of a
recipient gets the push. On a device whose Spool tab is open, the push and the
in-tab alert share the feed's tag, so the member sees one notification, not
two. Q2 is decided: pushes go to every device even while the member has a
focused Spool tab.

### 6.4 Rate limits and coalescing

| rule | value |
|---|---|
| per (device, feed) | at most **one push per 10 s**; later lines in the window are folded into one push (`3 new messages in #ops`) sent when the window ends |
| per device | at most **60 pushes per hour**; past it, one "many new messages" push per 10 minutes |
| per hub instance | a bounded worker pool (4 senders, queue 2 000); a full queue drops the oldest pushes of the lowest level first (section 13: Information, then System), never High priority or Action required, and counts the drop |
| Web Push `Topic` header | the feed key, hashed to 32 url-safe characters, so a device that is offline keeps only the newest push per feed at the push service |
| `Urgency` header | by level (section 13.3): `high` for High priority and Action required, `normal` for Attention, `low` for Information, `very-low` for System |
| `TTL` header | 24 h; an older push is not worth showing |

The queue is in memory (Q5, decided for this build): an instance killed
mid-send loses at most the pushes of its last seconds, and the drop counter
shows it. A durable outbox, written fire-and-forget and asynchronously so the
send path never waits on it, is a planned follow-up after this build
(section 12, follow-up F1); the 7-day prd watch informs when, not whether.

### 6.5 The library

Encryption (RFC 8291, `aes128gcm`) and VAPID signing (RFC 8292): either a
small vetted Go module (`webpush-go`), or the stdlib (`crypto/ecdh`,
`crypto/ecdsa`) plus `golang.org/x/crypto/hkdf`. The build lane picks one and
states why; a new direct dependency goes through the usual pre-push scanners.

### 6.6 Quiet hours (Q6)

Each member sets a **quiet-hours window** in their own user settings (the
Notifications block, section 3.1): `Quiet hours` off (default) or on, a start
and an end time (e.g. 22:00 to 07:00, may cross midnight) and the member's
time zone (IANA name, defaulted from the browser on first save). It is held
**per member in the hub**, one row in `push_quiet`, so it applies to every
device of that member:

```sql
CREATE TABLE push_quiet (
    tenant_id   text     NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id   text     NOT NULL,
    enabled     boolean  NOT NULL DEFAULT false,
    start_min   smallint NOT NULL CHECK (start_min BETWEEN 0 AND 1439),
    end_min     smallint NOT NULL CHECK (end_min BETWEEN 0 AND 1439),
    tz          text     NOT NULL,
    PRIMARY KEY (tenant_id, member_id)
);
```

Read and written via `GET` / `PUT /v1/me/push-quiet`. The **push sender skips
a push** whose send time, in the member's `tz`, falls inside the window: one
more "minus" step in 6.2, next to Unavailable. A skipped push is not queued
for later (the Flow badge and the in-tab alert still count the line), and a
counter `push_skipped_quiet` records it. The in-tab alert is not affected.

**Levels it silences: a proposal for the owner, not decided.** Consistent
with Q9 (Unavailable silences only the levels below High), quiet hours
silence **Action required, Attention, Information and System**; **High
priority** (a mention, a DM, a poke) still pushes. A member who wants total
silence at night uses the OS's do-not-disturb or sets channels to Off.

## 7. The service worker

`csi-spl-wui/src/public/sw.js` gets **one `push` listener**, shaped like this:

```js
self.addEventListener('push', (event) => {
  const p = event.data ? event.data.json() : {}
  event.waitUntil(self.registration.showNotification(p.title || 'Spool', {
    body: p.body || '', tag: p.tag, renotify: true, icon: p.icon,
    data: { msgId: p.msgId, url: p.url },
  }))
})
```

plus a `pushsubscriptionchange` listener that re-subscribes with the same key
and `PUT`s the new subscription.

- **No caching.** The handler touches neither `SHELL_CACHE` nor the fetch
  handler nor any Cache Storage entry, and reads nothing from the network:
  everything it shows is in the payload. Lanes deploy every few minutes; a
  push must never pin an old build.
- **Always show.** `userVisibleOnly: true` means every push must show a
  notification, or Chrome shows its own generic one and may revoke the
  permission. So the worker never skips a push; the hub decides who gets one.
- The click is the existing `notificationclick` (section 4).

## 8. Privacy: the message text in the payload

Web Push payloads are **end-to-end encrypted** to the device (RFC 8291): the
browser vendor's push service sees the endpoint, the size and the time, never
the text. The text is visible on the **device's lock screen**, though, to
anyone holding the device.

| option | payload | lock screen |
|---|---|---|
| **A (proposed default): preview on** | sender + first 90 characters | readable by whoever holds the device |
| B: preview off | `New message in #ops` + the ids | nothing sensitive; the member opens the app to read |
| C: ids only, text fetched on show | ids; the worker fetches the text with the session | same as A, plus a network call per push, and an expired session shows nothing; **not proposed** |

Each device has its own **Show message text** switch (`push_devices.preview`),
so a member can keep it on for a laptop and off for a phone. A workspace admin
may force it off for the whole workspace (Q4). The payload never carries
attachments, file names, link targets or an access token, and stays under
**3 000 bytes** before encryption (the push services' limit is 4 096 after);
a unit test pins that.

## 9. Platform limits

| platform | push to a closed app |
|---|---|
| Chrome, Edge, Firefox on desktop | yes while the browser process runs (Chrome on Windows can keep running in the background after the last window closes); a fully quit browser gets the pushes when it starts again, within `TTL` |
| Chrome / Firefox on Android | yes, also with the app swiped away; battery savers may delay |
| Safari on macOS 13+ | yes, in Safari or as a Dock web app |
| **iPhone / iPad (iOS / iPadOS 16.4+)** | **only for Spool added to the Home Screen and opened from there**; a Safari tab can never subscribe. The permission prompt needs a tap (the Turn on button is one). The re-check on open (section 5) restores a subscription the OS dropped |
| older iOS, in-app browsers (a link opened inside another app) | no; the block says so instead of offering the button |

The settings block detects each case (`'PushManager' in window`,
`display-mode: standalone` on iOS) and shows the one sentence that applies,
e.g. "On iPhone: Share -> Add to Home Screen, open Spool from there, then turn
this on".

### 9.1 Capacitor (the later native app)

In a Capacitor build Web Push is not used: the native layer gets an **FCM**
token (Android) or an **APNs** token (iOS) through
`@capacitor/push-notifications`. What carries over unchanged:

- the opt-in model (per device, per channel / topic / DM peer, section 3);
- `push_prefs` and the recipient query (6.2), the rate limits and coalescing
  (6.4), the payload fields and the click target `/m/<msg_id>` (the app's
  deep-link handler opens it);
- `push_devices`, through its `kind` column (`fcm` / `apns`, the token in
  `endpoint`, no `p256dh` / `auth`).

What this spec does **not** cover: the FCM sender (FCM HTTP v1 with the env's
service account), the APNs auth key (a new secret per env), the Firebase app
wiring, Android notification channels and app-store review. Those are a later
spec, written when Capacitor starts. The hub sender sits behind one small
interface (`Send(device, payload)`) so a second driver is an addition, not a
rewrite.

## 10. Test plan

### 10.1 Unit and store (CI, no network)

- recipient query on Postgres (`PRE_PUSH_TIER=full`): mention / DM / poke /
  watched reply / channel `all`; channel `off` beats a mention; a topic pref
  beats the channel pref; the sender and `typed_by` get nothing; a member
  outside a private channel gets nothing even with `all`; an agent gets
  nothing; RLS: workspace A's rows are invisible from workspace B (the
  tenant-isolation guard every new tenant table needs);
- the lifecycle table of section 5 against a fake push service (`httptest`):
  404 / 410 / 403 delete, 429 honours `Retry-After`, 413 never retries;
- encryption against the RFC 8291 test vector; the VAPID JWT `aud` is the
  endpoint's origin, `sub` the cnf host, `exp` <= 24 h;
- payload <= 3 000 bytes for a 10 000-character body; no field carries a file
  name or a token;
- coalescing: 5 lines in 3 s in one feed -> 1 push now, 1 folded push at 10 s.

### 10.2 WUI

- e2e (mock hub): the settings block's four states (no support, iOS not
  installed, off, on); Turn on -> `POST` with the subscription; Remove ->
  `DELETE`; sign-out -> `DELETE` before the session ends;
- a service-worker test: a `push` event shows a notification with the right
  tag and data, and the Cache Storage key list is equal before and after.

### 10.3 Dev proof (first)

1. `do_spl_vapid_key_seed` on dev, inject on, deploy the hub.
2. One member, two real devices on the dev host: an Android phone (Chrome)
   and a desktop Chrome. Turn on both.
3. Close Spool on the phone (swipe the app away). From a second member in a
   third browser, post a line mentioning the first member in a channel set to
   **Mentions and replies**, then a plain line in a channel set to **Every
   message**.
4. Pass: the phone shows both within 10 s; the desktop (tab open on another
   feed) shows one notification per feed, not two; tapping the phone's
   notification opens `/m/<msg_id>` with that line in view; the sender's own
   devices show nothing.
5. Repeat 3-4 with an iPhone (Home Screen install). Record n per device, the
   median and worst delay, and every miss.
6. Revoke: Remove the phone from the desktop's device list; the next line no
   longer reaches the phone.

### 10.4 Prd

The same script on prd, on the e2e workspace host (not the apex), with the
owner's go for the key seed and the inject flip. Then a 7-day watch of the
counters: pushes sent, 404/410 deletions, drops, p95 send delay.

## 11. Open questions for the owner

All ten are **DECIDED**. Q1 to Q6 on 2026-10-06 (msg `d3d8e225-38a2-4cbe-a45a-a27ec6daf047`; Q5 also msgs `51f96f43-d781-4cef-92ce-53942be73a39` and `5517673c-7452-4d04-9171-63dbeacb2b3e`); Q7 to Q10 on 2026-10-06 (msg `08477fa7-802b-4a2f-ab74-f46852a3e8be`). Left for the owner: which levels quiet hours silence (section 6.6, a proposal).

| # | question | answer |
|---|---|---|
| **Q1** | Default for a channel once a device is on: only mentions and replies, or every message? | **DECIDED.** Mentions and replies (as proposed); "Every message" is one tap per channel (the member's case). Msg `d3d8e225` |
| **Q2** | Push every device even while the member has a Spool tab focused somewhere? | **DECIDED.** Yes (as proposed); the shared tag prevents a double alert on the device in use. Msg `d3d8e225` |
| **Q3** | Merge the per-browser chime mute into the new per-member channel choice? | **DECIDED.** Yes, later (as proposed): one "Notify" menu, held in the hub, read by the in-tab alert too; **not in this build's lanes** (section 12, follow-up F2). Msg `d3d8e225` |
| **Q4** | Message text on the lock screen: on by default, a per-device switch, and an admin may force it off? | **DECIDED.** Yes to all three (as proposed). Msg `d3d8e225` |
| **Q5** | Is an in-memory send queue reliable enough, or a durable outbox table (survives an instance restart, one more write per line)? | **DECIDED.** In memory for this build, with a drop counter (the owner's own answer, msg `51f96f43`). The owner added (msg `5517673c`) that a durable outbox, written fire-and-forget and asynchronously so the send path never waits on it, is a planned follow-up regardless; the 7-day prd watch informs when to build it, not whether (section 12, follow-up F1) |
| **Q6** | Quiet hours (no pushes at night in the member's time zone)? | **DECIDED, changed from the proposal ("Later").** In scope: each member configures quiet hours in their own user settings (section 6.6, lane 9). Msg `d3d8e225`. Which levels the window silences is a proposal for the owner (6.6: all below High) |
| **Q7** | Are these the five levels (section 13.1), or fewer? | **DECIDED.** Five levels. A DM and a poke count as High. |
| **Q8** | Push default per level once a device is on? | **DECIDED.** On by default: High, Action required, Attention. Off for Information (turned on per channel via "Every message") and for System (one switch). Section 13.3 (a) |
| **Q9** | Does Unavailable (096 Q1, when the member chose to pause) silence every level, or only the levels below High? | **DECIDED.** Unavailable (spec 096) silences only the levels below High. A mention, a DM or a poke still reaches the member. |
| **Q10** | "You were assigned a task" has no producer today (section 13.2). Build it (an issue's assignee set to me writes a Flow event), or drop the level until issues need it? | **DECIDED.** Build the missing "assigned a task" event as its own small lane (section 12, lane 7). |

## 12. Effort: lanes

Effort **L** in total (the ideas lists' estimate holds). Each lane lands green
on its own:

| # | lane | scope | size |
|---|---|---|---|
| 1 | **infra** (claude: a secret) | the `vapid_key` slot in 030 + cnf (`inject: "false"`), `do_spl_vapid_key_seed` + its test, seed dev | S |
| 2 | **store** (claude) | the migration (`push_devices`, `push_prefs`), RLS, the tenant-isolation test, the recipient query, the sweep | M |
| 3 | **hub sender** (claude) | `GET /v1/push/key`, `/v1/me/push-devices` CRUD, `/v1/me/push-prefs`, the encrypt + VAPID sender, the worker pool, coalescing, the lifecycle table, counters | M |
| 4 | **WUI settings** (grok) | the Notifications block, the device list, Turn on / Remove / Send a test, platform hints, the sign-out delete, i18n ("workspace", never "tenant") | M |
| 5 | **WUI menus + sw** (grok) | channel / topic / DM "Notify my devices" items (after the topic-menu and CSS lanes land), the `push` and `pushsubscriptionchange` listeners, the sw test | S |
| 6 | **proof** (claude) | section 10.3 on dev with real devices, then 10.4 on prd with the owner's go; help page `user-settings.md` section 6 | S |
| 7 | **assign event** (Q10, claude) | a Flow event `assign` when an issue's assignee becomes another member (widen `flow_events.kind`, DDL first), level Action required, push on (Q8), silenced by Unavailable (Q9). Test: one `assign` at level `action` that pushes; a self-assign writes nothing (13.4) | S |
| 8 | **system event** (Q7, claude) | a v:1 `kind: result` line in a topic the member started is System (13.2); push off until the one per-member switch (Q8); Unavailable silences it (Q9) | XS |
| 9 | **quiet hours** (Q6, claude) | the `push_quiet` table (in lane 2's migration if it has not landed, else the next one), `GET`/`PUT /v1/me/push-quiet`, the sender's skip step and `push_skipped_quiet` counter (section 6.6), the "Quiet hours" row in the Notifications block (start, end, time zone). Tests: a push inside the window (across midnight, in a non-UTC `tz`) is skipped for the silenced levels and sent for High | S |

Lane 3 starts once lane 2's DDL is on trunk; lanes 4 and 5 run against a mock
hub from day one. The priority levels (section 13) add one `level` field to
the recipient query, the payload and the in-tab alert: a few hours inside
lanes 3, 4 and 5, not a new lane. Lanes 7 and 8 are in (Q10 and Q7 decided)
and small; their push defaults and the Unavailable rule follow Q8 and Q9.
Lane 9 (Q6) is in and small; its silenced levels await the owner's pick
(6.6). The total stays **L**.

Planned follow-ups, **not lanes in this build**:

| # | follow-up | why |
|---|---|---|
| F1 | **durable push outbox** (Q5): each push written to an outbox table fire-and-forget and asynchronously, so the send path never waits on it, and replayed after an instance restart | the owner's direction (msg `5517673c-7452-4d04-9171-63dbeacb2b3e`); planned regardless; the 7-day prd watch of the drop counter informs when |
| F2 | **one "Notify" menu** (Q3): the per-browser chime mute merges into the per-member channel choice held in the hub | Q3 decided "yes, later" (msg `d3d8e225`) |

## 13. Priority levels (v0.3)

Decided 2026-10-06 (msg `08477fa7-802b-4a2f-ab74-f46852a3e8be`): five levels;
push on by default for High, Action required and Attention; push off for
Information (on per channel via "Every message") and for System (one switch);
Unavailable silences only the levels below High; the missing "assigned a
task" event is built as lane 7. The member's ask (msg `b87a487a`) was:
"Better notification priorities: High priority - You were mentioned; Action
required - You were assigned a task; Attention - Someone replied to your
message; Information - New activity; System - Agent completed a workflow".

### 13.1 The five levels

Every alert, pushed (sections 6, 7) or in-tab (`notify.mjs`), carries exactly
one level. When one line is several events for a member, the **highest level
wins**, the rule `flowInsertCTE` already applies to Flow kinds (`min(rnk)`:
mention before poke before DM before reply).

| level | id | event |
|---|---|---|
| **High priority** | `high` | you were mentioned; also a **DM** to you and a **poke** (both are addressed to you alone) |
| **Action required** | `action` | you were assigned a task |
| **Attention** | `attention` | someone replied in a topic you watch (you posted in it, were mentioned in it, or were its `to`) |
| **Information** | `info` | any other new line you may read in a channel set to "Every message" |
| **System** | `system` | an agent finished a piece of work for you |

### 13.2 Measured: which events exist today (tree `1aa29e990`)

| level | event | producer today | check |
|---|---|---|---|
| High priority | mention, poke, DM | **yes**: Flow kinds `mention`, `poke`, `dm`, written in the message insert | `grep -c "kind IN ('mention', 'poke', 'dm', 'reply')" csi-spl-rdb/src/sql/postgres/spool-hub/0104_flow_events.sql` -> 1; `grep -c "'mention'" csi-spl-api/src/go/spool-hub-api/internal/store/flow_postgres.go` -> 4 |
| Action required | issue assignee set to you | **no producer today**: issues have an `assignee` field, but setting it writes no Flow event and raises no alert | `grep -ciE 'flow_events\|fanoutFlow\|notify' internal/hub/issues.go internal/store/issues_postgres.go internal/hub/issues_agent.go` (under `csi-spl-api/src/go/spool-hub-api`) -> 0, 0, 0 |
| Action required | a v:1 `kind: task` line sent to you | partly: the kind exists (`internal/msg/msg.go` `KindList = "task\|result\|note\|reject\|blocker\|msg"`), and such a line is recorded as a Flow `dm` / `mention`; nothing marks it as a task | `grep -n KindList csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go` -> line 56 |
| Attention | reply in a topic you watch | **yes**: Flow kind `reply` (`flow_watches`); broader than "a reply to *your message*" (it also counts topics you were mentioned in) | `grep -c "'reply'" csi-spl-api/src/go/spool-hub-api/internal/store/flow_postgres.go` -> 3 |
| Information | new line in a channel | **yes, in-tab only**: `shouldPing` pings every line from someone else unless its channel is muted (bug A) | `csi-spl-wui/src/utils/notify.mjs` `shouldPing` |
| System | agent completed a workflow | **no producer today**: no workflow-completed event anywhere; the nearest is a v:1 `kind: result` line, which no alert rule reads | `grep -rliE 'workflow_(run\|complete)\|workflow.?completed' csi-spl-api/src/go/spool-hub-api csi-spl-wui/src \| wc -l` -> 0; `grep -cE "'result'" csi-spl-wui/src/utils/notify.mjs` -> 0 |

The producers for the two events that have none today (section 12, lanes 7
and 8):

- **Action required** (lane 7): an issue's `assignee` changing to another
  member writes a Flow event of kind `assign` for that member (its line is
  the issue's update), and a `kind: task` line whose `to` is the member is
  `action` instead of `dm`. Assigning to yourself raises nothing (the sender
  rule, section 6.2 step 4). Push for this level is on (13.3).
- **System** (lane 8): a `kind: result` line from an agent, in a topic the
  member started or addressed to the member. A `result` anywhere else is
  Information. Push for this level stays off until the member's one switch
  (13.3).

### 13.3 What a level changes

| level | (a) Web Push default | (b) in-tab alert | (c) OS notification | (d) channel choice (Q1) that includes it |
|---|---|---|---|---|
| High priority | **on** | chime + system notification, title "<sender> mentioned you" / "DM from <sender>" (today's `notifyCopy`) | `Urgency: high`; tag `<feed>:hi`; `requireInteraction: true` on desktop | Mentions and replies, Every message |
| Action required | **on** | chime + system notification, title "<sender> assigned you <issue>" | `Urgency: high`; tag `<feed>:hi`; `requireInteraction: true` | Mentions and replies, Every message |
| Attention | **on** | chime + system notification | `Urgency: normal`; tag `<feed>` | Mentions and replies, Every message |
| Information | **off** (on only in a channel set to Every message) | system notification + chime, as today, unless the channel's chime is muted | `Urgency: low`; tag `<feed>` | Every message |
| System | **off** (one per-member switch "Agent results") | system notification, **no chime** (`silent: true`) | `Urgency: very-low`; tag `<feed>:sys` | Every message, or the switch |

Rules behind the table:

- **Tags keep a high alert from being overwritten.** A burst in one feed
  still shows one notification (section 4), but a later Information line
  must not replace an unread mention: High and Action share the tag
  `<feed>:hi`, System uses `<feed>:sys`, the rest keep `<feed>`. So a feed
  shows at most three notifications at once.
- **Channel "Off" silences every level** in that channel, a mention included
  (section 3.3 unchanged). A DM peer set to Off silences that peer's DMs.
- **The level is computed by the hub** in the recipient query (6.2), from
  the Flow kind of step 1 (`mention`/`poke`/`dm` -> `high`, `assign` ->
  `action`, `reply` -> `attention`) and from step 2 (`all` -> `info`, or
  `system` for a `result` line). It travels in the payload as `level`; the
  service worker maps it to the options above and needs no other logic.
- **In-tab** the same mapping lives in `notify.mjs` (`escalateReason` grows
  to return a level); the per-browser chime mute stays the noise control for
  Information. No new settings UI beyond the "Agent results" switch in the
  section 3.1 block.
- **Rate limits** (6.4) are per level: High and Action are never folded into
  a "many new messages" push and never dropped from the queue.
- **Unavailable** (spec 096, when the member chose to pause) removes the
  member from every level **below High**. A mention, a DM or a poke still
  reaches them. It is one more "minus" step in 6.2 and one more check in
  `shouldPing`.

### 13.4 Tests added to section 10

- the level of a line that is both a mention and a reply is `high`;
- each Flow kind maps to its level; `all` mode yields `info`; a `result` in
  the member's own topic yields `system`;
- the payload carries `level`; the service worker sets the per-level options
  (`requireInteraction`, `silent`, tag suffix);
- an Information line in a feed with an open High notification leaves that
  notification in place;
- a full send queue drops Information before System and never drops High or
  Action;
- setting an issue's assignee to another member writes one Flow event
  `assign` at level `action` and pushes; assigning to yourself writes nothing.

## Changelog

| version | date | change |
|---|---|---|
| v0.4 | 2026-10-06 | Q1 to Q6 decided (msgs `d3d8e225`, `51f96f43`, `5517673c`). Q5 in memory for this build; durable fire-and-forget outbox is follow-up F1. Q6 changed to in scope: section 6.6, lane 9; its levels are a proposal for the owner. Q3's merge is follow-up F2. |
| v0.3 | 2026-10-06 | Q7 to Q10 decided (msg `08477fa7-802b-4a2f-ab74-f46852a3e8be`). Section 13 is that design. Lane 7 is the assign event, with its test. |

<!-- last-edit: 2026-10-06T14:20:00Z -->
