# 051 — Different notification sounds per message type

**Owner ask** (HUM-10, prd t1 `#spool-hub-devel` topic `dd88348d`, verbatim):
"we should have different sounds for messages …".

Today one sound plays for every alert: `playChime()` in
`csi-spl-wui/src/utils/notify.mjs` — an 880 Hz beep, 120 ms, gain 0.04,
generated with Web Audio (no audio file). It fires from
`useNotificationStore().ping()` whenever the reader has the chime on and a
message would escalate. CLE-35099 recorded "notification sound" as a
per-device setting idea but did not build a per-type sound.

## 1. What plays today

| piece | where | behaviour |
|---|---|---|
| `escalateReason(msg, ctx)` | `notify.mjs` | classifies an incoming message: `alerts` (a `#alerts` post), `dm`, `mention` (a HUM-* mention of you), or `null` (no sound) |
| `shouldPing(msg, ctx, muted)` | `notify.mjs` | escalates AND the channel is not muted |
| `playChime(Ctx)` | `notify.mjs` | the one 880 Hz beep; closes its `AudioContext` on `ended` (CLE-35075) |
| `ping(title, body)` | `stores/notification.ts` | on ingest: if `chime` on → `playChime()`; if alerts on → a browser `Notification` |
| `chime` / `alertsEnabled` | `stores/notification.ts` | per-device switches (`localStorage`: `spool.chime`, `spool.alerts`), mirrored across tabs via a `storage` event |
| Settings → Notifications | `pages/settings/notifications.vue` | the bell (alerts) + the chime checkbox, per browser |

So a message already carries a type (`escalateReason`). A regular channel
message, a thread reply and an issue-assigned event do **not** escalate today,
so they make no sound at all.

## 2. Goal

Give each escalating message type its own distinguishable sound, generated in
code (Web Audio — no audio binaries; distribution hygiene bans bundled audio
files anyway), kept per device like the chime, controllable in
Settings → Notifications, and covered by unit + e2e tests with no regression
to the existing single-chime behaviour. Any new UI text ships in all 19
locales.

## 3. Proposed design (pending owner answers — see the blocker in `dd88348d`)

### 3.1 A sound per type, from one tone table

Replace the single `playChime()` frequency with a small per-reason tone
table, still one short Web-Audio beep (or a two-note motif) per event — no
files, no licensing. Reasons already classified by `escalateReason`:

| reason | today | proposed sound |
|---|---|---|
| `dm` | one chime | a two-note motif (distinct, "someone is talking to you") |
| `mention` | one chime | a single higher note |
| `alerts` | one chime | a lower, urgent double-beep |
| channel message | silent | (only if the owner wants it) a soft single note |
| thread reply | silent | (only if the owner wants it) |
| issue assigned | silent | (only if the owner wants it) |

`playChime` grows a `reason`/`tone` argument; `ping()` passes the reason it
already computes. The default (no reason) stays the 880 Hz beep, so nothing
regresses.

### 3.2 Per-device controls

A per-type on/off (and, if the owner wants it, one master volume) kept in
`localStorage` exactly like `spool.chime` — the master chime switch remains
the top-level gate, the per-type toggles refine it. Surfaced in
Settings → Notifications with a "play" preview button per type.

### 3.3 Focus / mobile

Keep the current rule: a message only pings when the tab is hidden or the
topic is not the active one (`document.hidden` / `activeKey`), so a sound
never fires for the topic you are staring at. Mobile keeps the same Web-Audio
path (it already runs there); no separate native sound.

## 4. Out of scope / owned elsewhere

- DM unread badges / "new DM arrived" indicator — **CLE-35106** owns the DM
  unread state. This lane may reuse the same "new DM arrived" event for its
  DM sound once CLE-35106 lands it; coordinate before sharing the event.
- Per-tenant settings core — **CLE-35099**. Any new setting rides its
  per-device mechanism.
- Language bar / login (CLE-35104), topic archive (CLE-35107), the perf lanes
  (CLE-35108..111 — agent-message before editing shared notification code).

## 5. Open questions

Posted as one blocker in `dd88348d`, each with a recommended answer:

1. Which types get their own sound (DM / @mention / #alerts / channel message
   / thread reply / issue assigned; and agent-sender vs human-sender)?
2. Code-generated Web-Audio tones (recommended) vs audio files?
3. Per-type on/off + one master volume in Settings, per device?
4. Keep "silent for the topic you are looking at" (recommended)?
5. Mobile: same Web-Audio path (recommended), or nothing extra?

Build starts only after the owner answers.
