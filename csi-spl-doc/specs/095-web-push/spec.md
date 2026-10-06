# 095 Web Push: a new message reaches my other devices

Status: **v0.1, DRAFT for the owner's approval, 2026-10-06.** Spec only: no
code, no key, no secret slot, no terraform, no cnf value was touched by this
lane. Building waits for the owner's go on the open questions (section 11).
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
topic I watch** (I posted in it, was mentioned in it, or was its `to`).

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
chime; Q3 asks whether the two should merge.

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
two. Q2 asks whether to skip all pushes while the member has a focused tab.

### 6.4 Rate limits and coalescing

| rule | value |
|---|---|
| per (device, feed) | at most **one push per 10 s**; later lines in the window are folded into one push (`3 new messages in #ops`) sent when the window ends |
| per device | at most **60 pushes per hour**; past it, one "many new messages" push per 10 minutes |
| per hub instance | a bounded worker pool (4 senders, queue 2 000); a full queue drops the oldest `all`-mode pushes first, never a mention or a DM, and counts the drop |
| Web Push `Topic` header | the feed key, hashed to 32 url-safe characters, so a device that is offline keeps only the newest push per feed at the push service |
| `Urgency` header | `high` for a mention, poke or DM; `normal` for the rest |
| `TTL` header | 24 h; an older push is not worth showing |

The queue is in memory: an instance killed mid-send loses at most the pushes
of its last seconds. Q5 asks whether that is acceptable or a durable outbox
table is wanted.

### 6.5 The library

Encryption (RFC 8291, `aes128gcm`) and VAPID signing (RFC 8292): either a
small vetted Go module (`webpush-go`), or the stdlib (`crypto/ecdh`,
`crypto/ecdsa`) plus `golang.org/x/crypto/hkdf`. The build lane picks one and
states why; a new direct dependency goes through the usual pre-push scanners.

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

| # | question | proposed answer |
|---|---|---|
| **Q1** | Default for a channel once a device is on: only mentions and replies, or every message? | **Mentions and replies**; "Every message" is one tap per channel (the member's case) |
| **Q2** | Push every device even while the member has a Spool tab focused somewhere? | **Yes** (the ask is the other device); the shared tag prevents a double alert on the device in use |
| **Q3** | Merge the per-browser chime mute into the new per-member channel choice? | **Yes, later**: one "Notify" menu, held in the hub, read by the in-tab alert too; not in this build |
| **Q4** | Message text on the lock screen: on by default, a per-device switch, and an admin may force it off? | **Yes** to all three |
| **Q5** | Is an in-memory send queue reliable enough, or a durable outbox table (survives an instance restart, one more write per line)? | **In memory first**, with a drop counter; the outbox only if the 7-day prd watch shows losses |
| **Q6** | Quiet hours (no pushes at night in the member's time zone)? | **Later**: the OS's own do-not-disturb covers it today |

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

Lane 3 starts once lane 2's DDL is on trunk; lanes 4 and 5 run against a mock
hub from day one.

<!-- last-edit: 2026-10-06T09:20:00Z -->
