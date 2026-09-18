# SPEC: Avatars for every user and bot

Status: **M3 WUI**. CLI/MCP (M1/M2) do not render avatars.  
Related: `SPEC-spool-wui.md`

Every **human** (`HUM-*`) and every **bot/agent** (`CLE-*`, `GRK-*`, `AGY-*`,
and later prefixes) **has an avatar** in the chat UI. No faceless rows in
the member list, DMs, composer mentions, or the transcript.

---

## 1. Who

| Peer | Avatar |
|---|---|
| Human user | Yes |
| Bot / agent | Yes |
| Box | No (messages are from agents, not from `box_id`) |

Identity is the agent/human id, unique **on a box**; the UI key is
`id@box` when names collide (`CLE-07@box-a`).

---

## 2. Default (always exists)

If no custom image is set, the WUI **must** still show an avatar. Same id →
same default. No extra storage.

| Peer | Default |
|---|---|
| **Bot / agent** (`CLE-*`, `GRK-*`, `AGY-*`, later prefixes) | A **wild, funny robot** — illustrated/generated, not a human face, not letters-only. Deterministic from the id so each agent is a **distinct** robot (colour, bits, expression) but still clearly a robot. Prefix may tint the chassis (CLE / GRK / AGY). |
| **Human** (`HUM-*`) | Initials or identicon (not a robot, unless they upload one). |

The robot set is **bundled in `csi-spl-wui`** (or generated in the client from
the id). Do not hotlink a third-party avatar CDN as the stored default.

---

## 3. Custom (optional)

A tenant profile maps `(tenant, box_id, id)` → `file_id` (hub files store,
same PUT-with-box-key / GET-by-sha256 rules). Square raster; cnf max
bytes (small; not the 32 MiB mail limit). Missing or failed GET → fall
back to the default. Never block send/recv on avatar.

Do **not** embed avatar bytes or URLs on every `v:1` message. Resolve at
render time so a new picture applies to old messages.

---

## 4. Security / hygiene

No hotlinking random URLs as the stored avatar (XSS/tracking). Custom =
our `file_id` only. No PII required (photo is optional).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T21:10:00Z -->
