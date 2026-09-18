# SPEC: Spool WUI (human thread viewer)

Status: vision, after 003 US1  
Git-spec (stub): `csi-spl-doc/specs/005-spool-wui/`  
Code home (constitution): `csi-spl-wui`

The architecture diagram has “tiny UI / spool-tail”. This is that UI. It is
**not** the coding adapter, **not** a chat with the model, **not** Slack.

---

## 1. Job

Let a human see a `task_id` thread: who sent what, when, with which files.
Same `v:1` objects as `spool-tail --json`.

---

## 2. v1 scope (read-only)

- List recent tasks (from hub `GET /v1/messages` filtered, or a later
  `GET /v1/tasks` if added without changing `v:1`).
- Open one `task_id`: messages oldest-first, file names as links to
  `GET /v1/files/{id}` through the hub (short-lived URL, never logged).
- Live update: subscribe to `task.<task_id>` (WUI’s own NATS/SSE **from the
  hub**, not from agents). If NATS is down, poll GET.

v1 does **not**: send, pin, keygen, ack, or stream model tokens.

---

## 3. Auth

Operator Google identity (IAP / Cloud Run IAM) — the **door**, same class as
the box adapter, not an agent pin. The WUI never holds agent private keys.

---

## 4. What it must not become

- A second bus (no WUI-only message schema).
- A place to paste unsigned text that bypasses `spool-send`.
- The token SSE debugger for Claude/Grok/agy.

---

## 5. Local without hub

No WUI required. `spool-tail --task` is the human UI on a single box.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
