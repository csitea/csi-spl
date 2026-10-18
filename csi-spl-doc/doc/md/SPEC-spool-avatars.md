# SPEC: Avatars for every user and bot

> Generated from qto doc `7a99eb3d-766d-44fd-9d89-99c577b3c102`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Status: **M3 WUI**. CLI/MCP (M1/M2) do not render avatars.  
Related: `SPEC-spool-wui.md`

Every **human** (`HUM-*`) and every **bot/agent** (`CLE-*`, `GRK-*`, `AGY-*`,
and later prefixes) **has an avatar** in the chat UI. No faceless rows in
the member list, DMs, composer mentions, or the transcript.

---

<a id="ws-doc-e7b6f046-0a84-49c2-a79e-175d7f1e6437"></a>
## 1. Who

| Peer | Avatar |
|---|---|
| Human user | Yes |
| Bot / agent | Yes |
| Box | No (messages are from agents, not from `box_id`) |

Identity is the agent/human id, unique **on a box**; the UI key is
`id@box` when names collide (`CLE-07@box-a`).

---

<a id="ws-doc-80f29532-c3e7-406b-9b55-059e3f945c3e"></a>
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

<a id="ws-doc-86b840cf-fc50-4d1b-8edf-7e2862c17ed1"></a>
## 3. Custom (optional)

A tenant profile maps `(tenant, box_id, id)` → `file_id` (hub files store,
same PUT-with-box-key / GET-by-sha256 rules). Square raster; cnf max
bytes (small; not the 32 MiB mail limit). Missing or failed GET → fall
back to the default. Never block send/recv on avatar.

Do **not** embed avatar bytes or URLs on every `v:1` message. Resolve at
render time so a new picture applies to old messages.

---

<a id="ws-doc-a6b7ac5c-9aa3-435b-8ded-742146adbe23"></a>
## 4. Security / hygiene

No hotlinking random URLs as the stored avatar (XSS/tracking). Custom =
our `file_id` only. No PII required (photo is optional).

<a id="ws-doc-4273215a-e16b-42e0-9a08-a0d9c328eb63"></a>
## 5. Your own picture, top right (CLE-3406)

- Every sign-in with an IdP that sends a picture (Google `picture`, Facebook
  Graph, OIDC `picture`) fetches it again on the hub and stores it hub-wide at
  `avatars/<sha256>`. This happens with or without a tenant, and before an
  invite is accepted. A tenant sign-in also puts `t/<tenant>/files/<sha256>`,
  the file the roster names. A picture changed at the IdP shows after the
  next sign-in.
- The top-right corner reads `GET /api/v1/auth/avatar` (auth-v1 §1). It needs
  the session only, no membership. A `404` falls back to the identicon for a
  member HUM-*, or to initials otherwise.
- Every picture renders as a `data:` URL. Each deployed CSP is
  `img-src 'self' data:`, which blocks `blob:`, so the WUI never makes one.
  `tests/unit/feed-avatar.test.mjs` pins that.
- Microsoft: its id_token has no picture, and the Graph photo needs the
  `User.Read` scope, which is not requested. So Microsoft users get the
  fallback until the owner decides on that scope.
- Live proof: `csi-spl-wui/tests/e2e/google-avatar-live.proof.mjs`.

<!-- version: 0.2.0 · updated: 2026-09-19 · last-edit: 2026-09-19T16:32:00Z -->
