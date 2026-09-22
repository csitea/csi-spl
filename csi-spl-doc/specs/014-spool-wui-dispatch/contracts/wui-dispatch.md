# Contract: WUI dispatch (box-wui key, pin, signed browser commands)

Status: **binding for 014**. Amends 002 `trust-modes.md` (frozen) per
`../spec.md` §0 and replaces the "not delivered to boxes" rule of 003
`wui-live-ws.md` §0 when `SPOOL_HUB_WUI_DISPATCH=true`.

## 1. Configuration (hub env)

| Name | Default | Meaning |
|---|---|---|
| `SPOOL_HUB_WUI_DISPATCH` | `false` | `true` = browser sends to an agent are signed and delivered to its box |
| `SPOOL_HUB_WUI_KEY` | unset | base64 of the 64-byte Ed25519 private key of `box-wui`. Secret Manager, one slot per env (suggested slot id `csi-spl-hub-wui-key`) |
| `SPOOL_HUB_WUI_KEY_EPHEMERAL` | `false` | `true` = generate a fresh key at start; allowed only with `SPOOL_HUB_ENV=lde` or `dev`; ignored when `SPOOL_HUB_WUI_KEY` is set |

Fail fast at start: dispatch on and no key source; a key that is not base64
of 64 bytes; ephemeral outside lde/dev. The private key never reaches a log, a
response, the database or terraform state. At start the hub logs the
**public** key once (`box-wui pubkey`).

## 2. Key lifecycle

### 2.1 Mint (out of band, like the relay SA key)

```
SPOOL_KEYS_DIR=<scratch-dir> spool keygen --box box-wui
```

It prints the public key; `<scratch-dir>/box-box-wui.key` holds the base64
private key, which becomes a new version of the env's Secret Manager slot;
the scratch copy is shredded. Terraform declares the empty slot and the
accessor binding only (never a version).

### 2.2 Publish and pin (per tenant)

1. `GET /v1/wui/pubkey` on the tenant host -> `200 {"box_id":"box-wui","pubkey":"<b64>","dispatch":true|false}`,
   `404 not_found` when the hub has no key. No auth: a public key.
2. The tenant operator pins it with the tenant root key, exactly as a box:
   `spool pin --box box-wui --pubkey <b64> --root-key <root-key-path>`, i.e.
   `POST /v1/pins {box_id:"box-wui", pubkey, ts, force:false, sig}` (004
   pin-semantics). The hub accepts it only when `pubkey` equals its loaded
   key (`400 wui_key_mismatch` otherwise; `400 bad_json` "reserved" when the
   hub has no key at all).
3. Boxes pick the pin up with their normal `GET /v1/pins` sync
   (`$SPOOL_ROOT/pins/box-box-wui.pub`).

### 2.3 Rotation

New secret version -> deploy -> each tenant re-pins with `force:true` and a
later `ts`. Between the deploy and the re-pin, dispatch answers
`wui_unpinned` (the stored pin is the old key); nothing unverifiable is ever
queued. Boxes whose local pin is the old key refuse the new one until their
operator accepts it (004 `pin_conflict`, not clobbered).

### 2.4 Revoke

`DELETE /v1/pins/box-wui` (root-signed) — dispatch for that tenant answers
`wui_unpinned` at once.

## 3. Dispatch (browser `send` frame, `wui-live-ws.md` §4)

Dispatch applies when `SPOOL_HUB_WUI_DISPATCH=true` **and** the send names an
agent recipient:

- `to` is a v:1 agent id that is not `ALL-0` and not `HUM-*`; or
- `to` is empty / `ALL-0` and the body starts with `@<AGENT-ID>` (optional
  leading spaces; the id ends at whitespace or end of body, and a trailing
  `,` `:` `;` is dropped). The message's
  `to` becomes that agent.

Otherwise the send is the browser-only path (`box-wui -> box-wui`) — **except
that a send tagged with a `channel` is signed too** (§3.1).

Steps, in order (the first failure answers its error frame, nothing stored):

1. **Identity**: the socket must carry a 010 member session for the Host
   tenant (checked at upgrade). `from` = the session's v:1 id (spec OQ-014-3).
   `hello.as` is ignored for dispatch.
2. **Kind**: `task` or `note` (a `chat` / empty kind is `note`).
3. **Resolve**: the tenant roster must announce the agent on exactly one box.
4. **Target pin**: that box has an active pin in the tenant.
5. **box-wui pin**: the tenant's active `box-wui` pin equals the hub key.
6. **Admit**: 006 billing / quota and the OQ-11 file rule, as any browser send.
7. **Sign + self-verify**: `wire.NewEnvelope(key, "box-wui", <box>, m)`, then
   `env.Verify(<stored box-wui pin>)`.
8. **Commit**: the shared commit path — `messages` row, `deliveries` row
   `(msg_id, <box>)` queued, pushed live when the box is connected, browser
   fan-out to the task's subscribers.

The ack gains `to_box` and `delivery` (`sent` | `queued`):
`{"type":"ack","msg_id","task_id","cursor","received_at","to_box":"box-a","delivery":"sent"}`.

### 3.1 Channel posts (owner rule 2026-09-22)

A browser send that carries a `channel` and names no agent is signed by the
same key, with `to_box` = `box-wui`: no single box owns a channel post, and
`003 contracts/channels-v1.md` §4 fans it out to one `deliveries` row per
member box. Steps 1, 2, 6, 7 and 8 above apply unchanged; steps 3 and 4 (a
single target box and its pin) do not, because there is no single target.

- The channel signed is the **resolved** one: the frame's tag, else `lobby` on
  the lobby task. A lobby post whose frame carried no tag used to be stored
  under `lobby` and routed to lobby members with an envelope claiming no
  channel — which every receiving box refuses.
- Permission: posting stays `notes.send`; the **fan-out** needs
  `agents.command` (025), because the post now lands in agent inboxes. Without
  it — or with `SPOOL_HUB_WUI_DISPATCH` off, or with no `box-wui` pin in the
  tenant — the post stays browser-only and unsigned, exactly as before. It is
  never refused for that reason: a tenant that has not pinned `box-wui` never
  asked for agents to read its chat.
- The ack is the browser-only ack: no `to_box`, no `delivery`. The post is not
  addressed to one box, so neither field has a value to carry.
- A `channel` send that DOES name an agent keeps `to_box` = that agent's box
  (the dispatch above) and is additionally fanned out to the other member
  boxes, its own included — the members sitting next to the dispatched agent
  are what the owner rule is about.

Tests: `TestWUIChannelPostReachesEveryMemberBox`,
`TestWUIChannelPostWithoutAgentsCommandStaysBrowserOnly`.

## 4. Error frames (new tokens)

| token | status | when |
|---|---|---|
| `dispatch_unauthenticated` | 401 | agent recipient but no member session on the socket |
| `dispatch_kind` | 400 | kind is not `task` / `note` |
| `unknown_agent` | 404 | no box announces the agent |
| `ambiguous_to_box` | 409 | more than one box announces it |
| `unpinned_box` | 404 | the target box has no active pin |
| `wui_unpinned` | 409 | the tenant has no active `box-wui` pin, or it is not the hub's key |
| `wui_key_mismatch` | 400 | `POST /v1/pins` for `box-wui` with a key other than the hub's |

## 5. Box side

A box verifies a `box-wui` envelope with the same code as any other
(`hubclient` receive: `sign.LoadPin(pins, from_box)` + `wire.Envelope.Verify`)
and additionally refuses it unless `kind ∈ {task, note}`. A hello as
`box-wui` is refused by the hub (`4401`).

<!-- version: 0.2.0 · updated: 2026-09-22 · last-edit: 2026-09-22T13:29:42Z -->
