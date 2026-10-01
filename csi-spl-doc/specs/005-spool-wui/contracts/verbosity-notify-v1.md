# Contract: thread verbosity + in-browser notifications (M3 client)

Feature: `005-spool-wui` · Lane: WUI-UX (GRK-3358) · Status: Partial
(`7e3f9af` modules, `6618f03` wiring). §2 and §3 are Implemented. §1's selector was
removed in `d1648dd0` (2026-09-23); `src/utils/verbosity.mjs` is kept with no caller.
Retire or restore §1: open, owner decision (asked in topic 582f7895). Ticks: `../tasks.md` P4 / P5 / T025–T028.

This is a **client** contract. It adds no hub field and does not reopen frozen
`v:1` (`../../002-box-agent-messaging/contracts/message-schema.md`). Inner
kinds are `task | result | note | reject`
(`csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go` `validKinds`). The
wire envelope (`internal/wire/wire.go` `Envelope.Msg`) carries that inner
object unchanged. Hub unread via `GET /v1/view/channels?read=` is 003
`channels-v1.md` §5.2 / OQ-CH2; this file only covers what the WUI does
locally in M3.

## 1. Verbosity inferred from `kind` (OQ-W3 (a))

Selector states: `minimal` | `normal` (default) | `verbose`. One value per
browser profile, persisted in `localStorage` key `spool.verbosity` (wrapped
in try/catch; private-mode failure → memory only).

A message is visible when its **kind level** is at most the selector:

| `kind` | kind level | visible at |
|---|---|---|
| `task`, `result`, `reject` | `minimal` | `minimal`, `normal`, `verbose` |
| `note` | `normal` | `normal`, `verbose` |
| any other string | `verbose` | `verbose` only |

`note` is the v:1 stand-in for SPEC-spool-wui §2.3 "milestone progress notes".
There is no diagnostic-note kind in frozen v:1; a future kind string shows
only at `verbose`. The old mock body prefix `[verbose]` is **not** a filter.

Pure function: `csi-spl-wui/utils/verbosity.mjs` (`verbosityOf`,
`applyVerbosity`). Table-driven unit test covers every v:1 kind parsed from
`internal/msg/msg.go` plus at least one unknown kind.

## 2. Escalation (OQ-W4 (a))

A newly arrived message **escalates** (and no other message does) when it is
not from the signed-in identity and **any** of:

1. a mention of the signed-in `HUM-*` (`to` equals that id, or body matches
   `@HUM-<n>` on a token boundary);
2. a DM received (`channel` is JSON `null` / absent meaning DM per
   `channels-v1.md` §0, or the active pane is a DM);
3. any message whose channel slug is `alerts` (`#alerts`, alias none).

Escalation **effects**, independently:

- **Web Notification**: only after the user has granted
  `Notification.permission === 'granted'` (the WUI never calls
  `requestPermission` except from the NotificationCenter button).
- **Chime**: opt-in, default off, persisted in `localStorage` key
  `spool.chime` (`"1"` / `"0"`, try/catch).
- **Unread badge**: counts **every** not-yet-read message per channel / DM
  key, not only escalations. Keys: `ch:<slug>` (slug `general` → `lobby`)
  and `dm:<peer>`.

Own messages (`from === selfId`) never escalate and never increment unread.

**Amended 2026-10-01 (bug A, t1 5002067f, CLE-77848).** A member reported
"notifications for new messages are enabled, but no signal comes": under the
rule above an ordinary reply raised only a badge. Since then the **chime and
the Web Notification** fire on **every** new message not from the signed-in
identity, unless its channel is muted (a DM is never muted by a channel) or it
lands in the open feed while the tab is focused. Escalation still decides the
alert's title (`notify.title_*`) and the mention badge. Each alert carries
`tag = <channel key>`, so a feed keeps one, and the chime plays at most once
per 2 s. The tab title leads with the unread total, `(n) <title>`, not
counting muted channels.

## 3. Read cursors are local (OQ-W5 (a), aligns with 003 OQ-CH2 (a))

M3 stores last-read `{ ts, id }` per key in `localStorage`
`spool.read-cursors` (JSON object, try/catch). Opening a channel or DM, or
receiving a message while that key is the active route, advances the cursor.
Hub-stored per-human cursors are OQ-W5 (b) / OQ-CH2 (b), later. Passing
`read=` into `GET /v1/view/channels` is phase-3 WUI wiring (not this slice).

Tokens stay out of `localStorage` (005 FR-003, view-v1 §2). The key list is
005 spec FR-003 (it grew past this contract: font size, locale, mute, emoji,
hidden DM rows); `spool.verbosity` has no writer since `d1648dd0`.

<!-- version: 1.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:35:51Z -->
