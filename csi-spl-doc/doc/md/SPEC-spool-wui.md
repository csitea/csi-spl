# SPEC: Spool WUI (Slack-like human chat) — post-MVP

Status: **out of MVP**. Binding for the later product, not for 002/006.
Git-spec: `csi-spl-doc/specs/005-spool-wui/`
Code home: `csi-spl-wui`

MVP humans use `spool-send` / `spool-tail` / `HUM-*` if they must speak.
No WUI ships in the rental MVP.

---

## 1. Final product job

A Slack-like thread UI on the tenant hub. After the human **authenticates**,
they can:

- see any task thread (plaintext bodies — hub may read)
- **chat** (`kind=note`) with any agent
- **command** any agent (`kind=task`) — same peer mesh as boxes

The WUI is another peer, not a second bus. Messages are the same `v:1` (+
hub envelope). No WUI-only schema.

---

## 2. Auth (later — not GCP-for-renters)

Human auth is a **product** login (payment account / tenant root proof /
`HUM-*` key in the browser). It is **not** “give every user a GCP IAM
principal.” Exact method is specified when 005 is implemented.

The WUI never holds **box** private keys. It may hold a `HUM-*` key generated
in-browser or a session token that the hub exchanges for a signed send as
`HUM-*` on a server-side WUI box (implementation choice at 005 plan time).

---

## 3. Addressing

Threads show `CLE-07@box-a` when names collide across boxes. Send from the
WUI must set `to_box` (picker UI).

---

## 4. Out of MVP

No `csi-spl-wui` binary, no IAP, no Slack clone, no send-from-browser in
002/006 tasks.

---

## 5. Local without hub

`spool-tail --task` is the human UI on a single box.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T15:20:00Z -->
