# Feature Specification: Spool WUI dispatch — the box-wui key and cross-box commands from a browser

**Feature ID**: `014-spool-wui-dispatch` · **Milestone**: M3 · **Status**: Partial — code Implemented (`9f4f0b9`), cnf done (`70780f1`, T021); deploy handoffs T020/T022/T023 open (see `./tasks.md`)
**Created**: 2026-09-19 · **Lane**: DISPATCH (CLE-3349)
**Narrative**: `../../doc/md/SPEC-spool-wui.md` lines 101-102 (the hub signs a
signed-in human's send with a server-side `box-wui` key; pinned boxes
recognise it).
**Builds on**: 002 `contracts/trust-modes.md` (FROZEN, amended here — §0),
003 `contracts/wui-live-ws.md` (browser socket), 004 `contracts/pin-semantics.md`
(tenant-root-signed pins), 010 (session identity). Rules: `../README.md`.

Status words follow `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

## 0. The trust-model decision (OQ-014-1) — read first

Two binding texts disagree (M3 gap analysis C2 / B2):

- 003 `wui-live-ws.md` §0-§1: `box-wui` is "never pinnable", browser sends are
  "not delivered to boxes".
- `SPEC-spool-wui.md`: "pinned boxes recognize `box-wui` as an authorized
  commander on the tenant's mesh".

002 `trust-modes.md` is frozen, so it is **amended by this spec**, not edited.

**OQ-014-1** — how does a box learn to trust `box-wui`?

- **(a) Recommended, implemented.** `box-wui` gets an ordinary Ed25519 pin
  **signed by the tenant root key** (`POST /v1/pins`, 004 pin-semantics),
  with a **restricted role**: its envelopes may only carry `kind=task` or
  `kind=note`, and it can never open a box session or change a pin. The
  private key is the hub's (one per env); the pin is the tenant's choice. A
  tenant that never pins `box-wui` never receives a browser command, and a
  tenant revokes it with the normal root-signed `DELETE /v1/pins/box-wui`.
- (b) Boxes trust the hub itself (a hub-wide key shipped in the box binary or
  fetched from the hub). Rejected: the tenant root key stops being the only
  trust anchor, which trust-modes §3 forbids.

**Amendment to 002 trust-modes (binding while OQ-014-1 stands at (a))**:
one reserved box id, `box-wui`, may be pinned. Its key is held by the hub
process (not by a box), its pin is signed by the tenant root key like any
other, and a receiving box refuses a `box-wui` envelope whose kind is not
`task|note` (verify class, exit 78). Nothing else in trust-modes changes.

Rollout: dispatch is behind `SPOOL_HUB_WUI_DISPATCH` (default `false`). ORC
decision for M3: **on for dev, off for prd** until the owner answers OQ-014-1.

## 1. User stories

### US1 — A signed-in human tasks an agent on a box (P1)

A human signed in to tenant `t` (010 member session) types `@CLE-07 run tests`
in the WUI. The hub resolves `CLE-07` to `box-a` from the tenant roster,
builds the v:1 message with `from` = the **session's** id, wraps it
`{from_box:"box-wui", to_box:"box-a"}`, signs it with the `box-wui` key and
queues it for `box-a`. `box-a` verifies it against its local `box-wui` pin
(the same code as for any sender box) and writes it to `CLE-07`'s inbox.

**Acceptance**: a `deliveries` row `(msg_id, box-a)` exists; its envelope sig
verifies against the tenant's `box-wui` pin with `wire.Envelope.Verify`; a
live `box-a` session receives it into `CLE-07/inbox`.

### US2 — Refusals are explicit (P1)

Unknown agent, an agent on two boxes, an unpinned target box, an unpinned or
stale `box-wui` pin, a browser without a session, or a kind other than
`task|note` each answer a defined error frame (contract §4) and store nothing.

### US3 — The tenant owns the trust (P1)

The operator reads the hub's `box-wui` pubkey (`GET /v1/wui/pubkey`) and pins
it with the tenant root key (root-signed `POST /v1/pins`, as for any box).
The hub accepts that pin **only** for its own current key. Revoking it stops
dispatch for that tenant at once.

### US4 — Key lifecycle (P2)

prd/dev load the private key from Secret Manager (`SPOOL_HUB_WUI_KEY`, one
slot per env). lde (and dev until the slot has a version) may run with an
ephemeral key generated at start. Rotation = new secret version, deploy, and
the operator re-pins `box-wui` with `force` (contract §2.3).

## 2. Functional requirements

- **FR-001** The hub loads one `box-wui` Ed25519 private key at start from
  `SPOOL_HUB_WUI_KEY` (base64 of the 64-byte private key), or generates an
  ephemeral one when `SPOOL_HUB_WUI_KEY_EPHEMERAL=true` (refused unless
  `SPOOL_HUB_ENV` is `lde` or `dev`). `SPOOL_HUB_WUI_DISPATCH=true` without a
  key fails fast. The private key is never logged, stored, or returned.
- **FR-002** `GET /v1/wui/pubkey` returns the hub's `box-wui` public key and
  whether dispatch is on; `404 not_found` when the hub has no key.
- **FR-003** `POST /v1/pins` with `box_id = box-wui` is accepted only when
  the hub has a key and `pubkey` equals it (else `400 wui_key_mismatch`, or
  the old `400 bad_json` refusal when the hub has no key). Everything else is
  004 pin-semantics unchanged (root sig, ts replay guard, force, quota).
- **FR-004** A box hello as `box-wui` is refused (`4401 unauthorized`).
- **FR-005** Dispatch identity is the **session**: only a browser whose socket
  carries a 010 member session for the Host tenant may dispatch. `hello.as`
  is never the `from` of a dispatched message.
- **FR-006** Recipient: the frame `to` when it is an agent id (not `ALL-0`,
  not `HUM-*`), else a **leading** `@<AGENT-ID>` mention in the body.
  Resolved to exactly one box through the tenant roster.
- **FR-007** The hub signs with `wire.NewEnvelope`, then verifies the result
  against the stored `box-wui` pin with `wire.Envelope.Verify` before storing
  (a hub key the tenant has not pinned is `wui_unpinned`, never a silently
  unverifiable envelope).
- **FR-008** The dispatched envelope goes through the shared commit path
  (`messages` + `deliveries` for the target box, live push when the box is
  connected), fans out to subscribed browsers like any message, and billing /
  quota / file rules apply as for a browser send.
- **FR-009** A receiving box accepts a `box-wui` envelope only for
  `kind ∈ {task, note}`.
- **FR-010** With `SPOOL_HUB_WUI_DISPATCH=false` every browser send behaves
  exactly as 003 `wui-live-ws.md` §4 (browser-only, `box-wui -> box-wui`).

## 3. Open questions (owner)

- **OQ-014-1** Trust model — §0. Default (a) implemented; prd flag off.
- **OQ-014-2** May a browser without a session dispatch in lde/dev (asserted
  `HUM-*`)? (a) **No — recommended, implemented**: the session always wins, so
  dev dispatch works once 010 membership is wired (HUMANS lane, 010 T012/T013);
  (b) yes in lde/dev behind a second flag. (b) is not implemented.
- **OQ-014-3** The v:1 `from` of a dispatched message is a `HUM-<n>` the hub
  maps from the session's human id per process (010 ids such as
  `HUM-google-sub-1@t1` are not v:1 agent ids). (a) **Recommended**: once
  HUMANS lands a durable v:1 human id (rdb 0006, 010 T012) use it and drop
  the per-process map; (b) keep the map. HUMANS landed the store-backed
  Registrar (`a74640b`): its `HUM-<n>` ids are v:1 ids and are used as-is; the
  per-process map now only covers a session id that is not a v:1 id.
- **OQ-014-4** Who may command whom: (a) **recommended, implemented**: any
  member of the tenant may task any agent of that tenant (tenant scope only,
  never cross-tenant); (b) a per-agent allow-list.
- **OQ-014-5** Should a sent card show a queued / `to_box` badge? **Decided
  (owner 2026-09-19): no** — no queued/to_box badge on sent cards; §4 "WUI
  changes: none needed" stands.

## 4. Out of scope

- Agent replies back to the human already work (`spool send --to-box box-wui`,
  003 `wui-live-ws.md` §6). Auto-resolving `HUM-*` to `box-wui` on the box is
  a later 004 change.
- The Secret Manager slot, its IAM and the cnf values (iac 029/030 and cnf:
  HOSTING / DEPLOY lanes) — named in `./tasks.md` as handoffs.
- WUI changes: none needed. The WUI strips a leading `@X-n` and sets the
  send-frame `to`; it does not leave the mention in the body
  (`parseMention` in `csi-spl-wui/src/utils/channel-feed.mjs`:
  `command grep -n -A4 'export function parseMention' csi-spl-wui/src/utils/channel-feed.mjs`
  → `to: m[1], kind: 'task', body: m[2]`; live send in
  `csi-spl-wui/src/stores/live.ts` does the same
  `body.match(/^@([A-Z]{2,4}-\d+)\b/)`). The hub still accepts a leading
  mention as a fallback (FR-006).
- rdb migration 0007 (reserved for this lane): not needed — the restricted
  role keys off the reserved box id, and no new table is written.

<!-- version: 0.2.2 · updated: 2026-09-19 · last-edit: 2026-09-19T13:00:00Z -->
