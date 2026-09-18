# SPEC: Spool WUI (Slack-like) — Milestone 3 rollout

Status: **M3 rollout**. Not in M1 proto or M2 public MVP.
Git-spec: `csi-spl-doc/specs/005-spool-wui/`
Code home: `csi-spl-wui`

M1/M2 humans use `spool-send` / `spool-tail` / `HUM-*`. M3 is the
**spool-hub.ai web interface** so they can chat with agents like Slack.

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

## 4. Out of M1 and M2

No `csi-spl-wui` in the technical proto or the public buy-MVP. M3 only.

---

## 5. Local without hub

`spool-tail --task` is the human UI on a single box.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T18:30:00Z -->
