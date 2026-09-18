# SPEC: Spool message bus (end vision)

Status: design freeze for implementation planning  
Created: 2026-09-18  
Git-spec: `csi-spl-doc/specs/003-spool-message-bus/`  
Related: `SPEC-spool-box-api.md` (uniform box API), `specs/002-box-agent-messaging/` (local folder MVP), `specs/001-relay-bucket-estate/` (git-rel GCS estate — a different plane)

---

## 1. Split the names

`ysg-box` is the **machine**. The product this spec is for is the **bus**.

| Token | Job |
|---|---|
| **box** / ysg-box | Host harness: tmux, ACLs, sessions, vendor CLIs. Private/engine. Keep. |
| **spool** | Public product name for the bus. Short, true, not an org tag. |

Mild box synonyms that remain honest: `fleetbox` (many agents on one host), `harness` (what it is). Prefer **box**.

Rejected product names: Pinbox (crowded — punch-list SaaS, macOS app, IPFS pinning at pinbox.cloud, maps/pensions/pins), Mesh, Nexus, HubAI, Slack-anything, invented Greek. DNS that will not come clean: `pinbox.com` / `.io` / `.app` / `.cloud` and near-collisions.

Candidate public DNS (check WHOIS before committing; never bake a host into code — Constitution II): `spool.dev`, `getspool.dev`, `agentspool.dev`, `taskspool.io`, `agentbus.dev`. This repo’s documented public URL placeholder is `spool-hub.ai`, resolved at deploy time.

---

## 2. Two jobs, two codebases — clean cut

Do not grow ysg-box into the hub. Do not migrate Slack-trigger, directive, or `$MSGS_ROOT` into spool piece by piece. That produces two half-buses.

| Repo | Job |
|---|---|
| **ysg-box** | Machine. Later: one thin adapter feature that shells out to spool. Still owns window ids, inbox *path* until the adapter lands, ACLs. |
| **csi-spl (spool)** | Bus. Schema, send/recv, keys, files, later Go + HTTP hub + UI. No org overlay of another product. |

**Start clean, then force the box to use it.**

1. This repo implements the spec in isolation (fake agents, temp dir).
2. ysg-box adds one adapter feature that calls spool.
3. Only then stop writing ad-hoc files into `$MSGS_ROOT`.

`directive` (owner GPG → box) stays in ysg-box **forever**. It is not agent mail. Slack-trigger stays a **pager**, not the transcript.

git-rel (spec 001) remains the gpg-encrypted **file relay** through a GCS bucket. Agent mail is this spec. Do not conflate them.

---

## 3. Intent

Agents (Claude Code, Grok, Antigravity) never speak NATS, Postgres, or object storage. They call **spool** (CLI or MCP). Spool moves **signed JSON messages** and **content-addressed files**.

The hosted process is optional. MVP is a library + folder on the box. Box dies → that box’s mail dies (same as today). The Cloud Run hub is a SPOF only if it is the only path; local spool must still send when the hub is down (queue, flush later).

---

## 4. Architecture

```
                    humans
                      │
              tiny UI / spool-tail
                      │
              ┌───────▼────────┐
              │  Cloud Run      │  spool HTTP (stateless)
              │                 │
              └─┬─────┬─────┬──┘
                │     │     │
         JetStream   PG    GCS
         (NATS)    msgs   files
         live+replay
                │
        ┌───────┴────────┬─────────────┐
        ▼                ▼             ▼
      box A            box B         box C
        │
   ┌────┴─────┐
   │ MCP srv  │  stdio ← Claude / agy
   │ spool CLI│  ← Grok / scripts
   │ sidecar  │  one NATS client
   │ local    │  folder fallback
   │ spool    │
   └──────────┘
        ▲
   CLE / GRK / AGY   (no NATS lib, no PG, no bucket keys)
```

### Planes

| Plane | Job | Not |
|---|---|---|
| Agent | reason, call tools | brokers, IAM, buckets |
| Spool CLI / MCP | build / sign / verify JSON | vendor SDKs inside the hub |
| Box sidecar | publish / subscribe, flush queue | interpret body |
| Cloud Run | HTTP CRUD + verify sig | store files on container disk |
| NATS JetStream | live tail + replay per task | file bytes, model tokens |
| Postgres | tasks, messages, pins, acks | blobs |
| GCS | file bytes (`file_id` = sha256) | message metadata |
| IAM / OIDC | who may hit Cloud Run | who authored the msg |
| Ed25519 pin | who authored the msg | door lock |

---

## 5. Two different streams (do not mix)

### Model tokens (the agent thinking / typing)

Short-lived, one viewer. The coding adapter (MCP, CLI, a page) opens **SSE or a websocket** to that one run and paints words. When the run ends, the stream dies. Do **not** put every token on NATS/Kafka. Nobody wants last week’s “um”.

### Spool live tail (the mail thread)

`spool-tail` is “a new message landed on task X.” One JSON blob per **send**, not per token.

- **Core NATS**: subject `task.<task_id>`. Subscribers get the blob now. No disk, no replay. Missed it → read Postgres / NDJSON.
- **JetStream**: same subject, kept, so a late subscriber can replay.

NATS is a small broker: publish a payload to a **subject** (a name), subscribers get it immediately. It is the **radio**, not the archive. JetStream is the optional tape recorder.

NATS **does** have its own wire protocol (NATS-over-TCP). That is how clients talk to the broker. It is **not** the agent protocol. NATS does not define `from`, `to`, `task_id`, `sig`, `files`. That is spool JSON. NATS = how bytes move. Spool JSON = what the bytes mean.

---

## 6. Box shape

On every machine that may run an agent, install as part of the box image:

- CLI: `spool-put-file`, `spool-send`, `spool-recv`, `spool-get-file`, `spool-tail`, `spool-keygen`, `spool-pin`
- **One** MCP server (stdio) if Claude or agy may run here — one per **box**, not per tmux window, not per `CLE-07`
- **One** NATS sidecar (optional until two boxes must see the same task live)
- Local folder `$SPOOL_ROOT` (default `/var/tmp/claude/msgs`) as fallback queue

Grok-only box: CLI is enough; no MCP server required. Cloud hub: HTTP; no MCP required there. If the fleet is “any agent anywhere,” treat MCP as part of the box image, next to `spool-send`.

Agents do not import NATS, Postgres, GCS, or Cloud Run SDKs. They only call spool.

MCP tools are functions Claude Code / Antigravity call by name with a JSON schema. The MCP server runs the **same code** as the CLI. Grok keeps using the CLI. Same backend. Native API is HTTP (`send` / `recv` / `put-file`). MCP is a thin wrapper, later — not the only door (Grok and Cloud Run will not speak stdio MCP).

Canonical tool names: `spool_put_file`, `spool_send`, `spool_recv`, `spool_get_file`, `spool_tail`. No `spool_send_claude`. Kind of agent is not a field except as `from` / `to` ids (`CLE-*`, `GRK-*`, `AGY-*`). New vendor = new id prefix + same tools.

---

## 7. Files

Short msgs: NATS (notify) + Postgres (record).

Files: **never NATS**. Bytes go to the object store (GCS on this estate; S3 is the same idea). Brokers hate multi-MB blobs.

Not agent → bucket. Agent → `spool-put-file` → hub writes `files/<sha256>`. Message carries only `file_id` + size + name.

Why not direct upload: that hands every agent a cloud key and loses the audit.

Hub HTTP:

```
POST /v1/files              → body = bytes → { file_id, sha256, bytes }
GET  /v1/files/{file_id}    → bytes or a short-lived signed URL
POST /v1/messages           → JSON with files: [{ file_id, name }]
GET  /v1/messages?as=&task_id=
```

Box CLI hides these. Agents never call them directly. Local CLI does the same against the folder when the hub is off.

---

## 8. Flow: Grok sends a message with a file

Same flow for every kind (MCP vs bash is only how they invoke).

1. Grok runs `spool-put-file ./patch.zip`. CLI hashes bytes → `file_id`. Hub up: `POST /v1/files` → GCS. Hub down: write `$SPOOL_ROOT/files/<file_id>`. Returns `{ file_id, sha256, bytes, name }`.
2. Grok runs `spool-send --from GRK-03 --to CLE-07 --task <uuid> --kind task --body "review this" --file-id <file_id>`. CLI builds JSON (**no file bytes**), signs with GRK-03’s Ed25519 key.
3. `POST /v1/messages` (or local inbox file).
4. Cloud Run checks pin + sig. Refuses unsigned / unknown. Writes Postgres.
5. Cloud Run publishes the small JSON on NATS `task.<task_id>` and `agent.CLE-07.inbox`.
6. On the Claude box: sidecar / MCP wakes. `spool-recv --as CLE-07` shows the task.
7. `spool-get-file <file_id>` → `GET /v1/files/...` or signed URL → zip on disk.
8. Human `spool-tail --task <uuid>` sees the thread.

Grok never talks to NATS, Postgres, or the bucket.

---

## 9. Trust — pin first, IAM last

Do **not** start with GCP IAM.

| Mechanism | Answers |
|---|---|
| IAM / OIDC | which Google identity may hit Cloud Run (the **door**) |
| Ed25519 pin | which agent **wrote** this message (the **author**) |

If IAM is first you only have “this laptop may POST.” You still cannot tell `CLE-07` from a lying script.

**Sign on day one.** Do not ship unsigned CRUD and “add auth later.”

1. Agent keypair + pin. Works on a folder, no cloud. Private key never in spool, Postgres, GCS, or a log.
2. Same API as a Cloud Run process (memory / sqlite allowed for a week).
3. Postgres + GCS replace the folder.
4. IAM / OIDC on the door (who may call Cloud Run). Signatures already prove who wrote the msg.

Hub checks signature **after** the request is allowed in. Unpublished key ≠ trusted. Operator pins with `spool-pin`.

---

## 10. Build order

1. Local folder CRUD + Ed25519 + files + tail (**spec 002**). No NATS, no GCP.
2. Same HTTP API on Cloud Run (sqlite / memory ok for a week).
3. Postgres + GCS replace the folder for hub state.
4. NATS JetStream for live tail (Core NATS first if needed; JetStream when replay matters).
5. IAM / OIDC on Cloud Run.
6. MCP wrapper around the same CLI (if not already in 002).
7. ysg-box adapter feature that **only** calls spool.

Do not start Kafka, Slack-as-bus, per-agent GCP keys, or NATS before `spool-send` works on a dummy folder.

Kafka is a platform (brokers, partitions, consumer groups). Load here is small JSON tasks, not millions of events. Now: HTTP request/response + NDJSON log. Optional SSE/websocket for token paint on the **adapter**. When many boxes: GCP Pub/Sub (already on Cloud Run) or NATS. Kafka when a team already runs Kafka and needs replay across many consumer apps.

JetStream is a good **later** backbone (live tail per `task_id`, durable inbox per agent, ack, retention). File bytes still in GCS. NATS carries the message; it does not replace pin, schema, or file ids.

Cloud Run can scale to zero and die any minute. Stateless: HTTP send / recv / verify. State: Cloud SQL (Postgres) + GCS (files) + Secret Manager (hub TLS only — nothing private of agents). Do not put the NDJSON log on the container disk.

Replicas later: two Cloud Run services + Postgres + GCS. Do not put the only copy of keys or files in RAM.

---

## 11. Failure

| Failure | Behaviour |
|---|---|
| Cloud Run down | local folder queue; agents still send |
| NATS down | writes still land in Postgres; tail is stale until replay |
| GCS down | refuse file send; text-only may proceed if policy allows |
| Bad signature | HTTP 400 / exit `78`; no persist |
| Box offline | others keep going; flush on return |

Verify/refuse: exit `78` (same as ysg-box `directive-verify`).

---

## 12. What ysg-box keeps

- tmux, sessions, ACLs, vendor CLIs
- `directive` (owner GPG → box)
- slack-trigger as a pager only
- window / agent ids (`CLE-07`, …) as the address book the adapter maps onto spool ids

What ysg-box does **not** grow: a second message schema, Mattermost as the bus, GCS writers inside agents, Kafka, per-kind HTTP.

---

## 13. Out of this spec

Kafka, Pinbox, per-kind endpoints, per-agent cloud keys, MCP server per tmux window, token SSE on spool, Slack as transcript, slow feature-by-feature absorption of `$MSGS_ROOT`, IAM-before-pin.

---

## 14. Invariants

- Same tool names on every box image.
- Same JSON `v: 1` on the wire and in the local folder (002 disk format is 003 wire format).
- Kind of agent is not a field on the API except as `from` / `to` id prefixes.
- Local spool works on-box even if the hub is down.
- Agents never hold bucket keys.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T12:50:00Z -->
