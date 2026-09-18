# SPEC: Spool message bus (end vision)

Status: design freeze for implementation planning  
Created: 2026-09-18  
Git-spec: `csi-spl-doc/specs/003-spool-message-bus/`  
Binding over this narrative: `specs/002-box-agent-messaging/contracts/trust-modes.md` (local unsigned; hub = one Ed25519 key per **box**, envelope over WebSocket) and `SPEC-spool-milestones.md` (M1 = non-WUI cross-box mesh; no NATS, no IAM). Sections below that predate those decisions are marked **(superseded)**; the git-spec's Open Questions list what is still undecided.  
Related: `SPEC-spool-hub-rental.md` (paid tenant MVP), `SPEC-spool-box-api.md`, `SPEC-spool-identity-routing.md`, `SPEC-spool-task-lifecycle.md`, `SPEC-spool-wui.md`, `specs/002`–`006`, `specs/001-relay-bucket-estate/` (git-rel — a different plane)

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

**Product MVP:** a stranger pays, gets a tenant URL + tenant root key, pins
their **boxes** (one Ed25519 key per box), and the agents on those boxes intercommunicate through the hub
(`SPEC-spool-hub-rental.md`). ysg-box is optional.

The hosted process is optional on one machine. Local folder still works if
the hub is down (queue, flush later). A rented hub is a SPOF for *cross-machine*
mail of that tenant; local same-machine mail must not need it.

---

## 4. Architecture

```
                    humans
                      │
              tiny UI / spool-tail
                      │
              ┌───────▼────────┐
              │  Cloud Run      │  spool HTTPS + WS (stateless)
              │                 │
              └─┬─────┬─────┬──┘
                │     │     │
        notify     PG    GCS
      (after M1)  msgs   files
                  queue
                │
        ┌───────┴────────┬─────────────┐
        ▼                ▼             ▼
      box A            box B         box C
        │
   ┌────┴─────┐
   │ MCP srv  │  stdio ← Claude / agy
   │ spool CLI│  ← Grok / scripts
   │ WS client│  one per box (box key)
   │ local    │  folder fallback
   │ spool    │
   └──────────┘
        ▲
   CLE / GRK / AGY   (no NATS lib, no PG, no bucket keys, no hub key)
```

### Planes

| Plane | Job | Not |
|---|---|---|
| Agent | reason, call tools | brokers, IAM, buckets |
| Spool CLI / MCP | build / sign / verify JSON | vendor SDKs inside the hub |
| Box hub client | one WS per box, sign envelopes, flush queue | interpret body |
| Cloud Run | WS send/recv + REST files/pins; verify box sig | store anything on container disk |
| Live notify (Postgres LISTEN/NOTIFY) | live WS push across Cloud Run instances & tail | external broker (no NATS/Kafka required) |
| Postgres (Production & LDE) | messages, box pins, roster, hub queue, acks (tenant-scoped) | blobs |
| GCS | file bytes (`file_id` = sha256) | message metadata |
| Box key (Ed25519, pinned by tenant root) | which **box** may connect and which box sent a frame | which agent process typed it |
| IAM / OIDC (private deploys only, optional) | who may reach Cloud Run | who sent the msg |

---

## 5. Two different streams (do not mix)

### Model tokens (the agent thinking / typing)

Short-lived, one viewer. The coding adapter (MCP, CLI, a page) opens **SSE or a websocket** to that one run and paints words. When the run ends, the stream dies. Do **not** put every token on NATS/Kafka. Nobody wants last week’s “um”.

### Spool live tail & inter-instance dispatch (Postgres LISTEN/NOTIFY)

Stateless Cloud Run instances coordinate live socket pushes and live tails using **Postgres `LISTEN/NOTIFY`**:
- When an envelope is stored on Cloud Run instance A, a Postgres notification (`NOTIFY spool_box, '<tenant_id>:<to_box>:<msg_id>'`) is emitted.
- All Cloud Run instances listen; the instance holding the active WebSocket connection to `to_box` receives the event and pushes the message frame immediately.
- WUI clients subscribed to a channel/thread receive live message notifications over SSE/WebSocket via the same mechanism.
- No separate NATS or Redis broker is needed. Missed frames are caught up from the `deliveries` / `messages` tables upon reconnect.

---

## 6. Box shape

On every machine that may run an agent, install as part of the box image:

- CLI: `spool-put-file`, `spool-send`, `spool-recv`, `spool-get-file`, `spool-tail`, `spool-keygen`, `spool-pin`
- MCP binary on the box; Claude/agy spawn `spool mcp` **stdio per agent session** (one process tree per session, shared `$SPOOL_ROOT`/pins). Not a separately configured daemon per tmux window.
- **One** hub client per box (WS, box key) when `$SPOOL_HUB_URL` is set; a notify sidecar only after M1
- Local folder `$SPOOL_ROOT` (default `/var/spool-hub`) as fallback queue

Grok-only box: CLI is enough; no MCP process required. Cloud hub: HTTP; no MCP required there. If the fleet is “any agent anywhere,” install the spool binary (CLI+MCP) on the box image.

Agents do not import NATS, Postgres, GCS, or Cloud Run SDKs. They only call spool.

MCP tools are functions Claude Code / Antigravity call by name with a JSON schema. The MCP server runs the **same code** as the CLI. Grok keeps using the CLI. Same backend. The hub's native wire is WS (send / recv) + HTTP (files / pins), spoken only by the box hub client. MCP is a thin wrapper over the CLI, not the only door (Grok and Cloud Run do not speak stdio MCP).

Canonical tool names: `spool_put_file`, `spool_send`, `spool_recv`, `spool_get_file`, `spool_tail`. No `spool_send_claude`. Kind of agent is not a field except as `from` / `to` ids (`CLE-*`, `GRK-*`, `AGY-*`). New vendor = new id prefix + same tools.

---

## 7. Files

Short msgs: WebSocket frames (notify) + Postgres (record). NATS is deferred past M1 (OQ-04, OQ-12).

Files: **never NATS**. Bytes go to the object store (GCS on this estate; S3 is the same idea). Brokers hate multi-MB blobs.

Not agent → bucket. Agent → `spool-put-file` → hub writes `t/<tenant>/files/<sha256>` (one bucket). Message carries only `file_id` + size + name. Upload needs the box key; download is a tenant-scoped capability.

Why not direct upload: that hands every agent a cloud key and loses the audit.

Hub wire (normative: git-spec 003 `contracts/http-v1.md`):

```
WS   /v1/ws                 → hello (box sig), roster, send envelope, recv frames
POST /v1/files              → body = bytes, box proof → { file_id, sha256, bytes }
GET  /v1/files/{file_id}    → bytes or a short-lived signed URL
```

`POST /v1/messages` and `GET /v1/messages?as=` from the first draft are **dropped/superseded** (OQ-02): public hub send/recv is WebSocket only; REST carries files and pins only.

Box CLI hides these. Agents never call them directly. Local CLI does the same against the folder when the hub is off.

---

## 8. Flow: Grok on box-a sends a message with a file to Claude on box-b

Same flow for every kind (MCP vs bash is only how they invoke).

1. Grok runs `spool-put-file ./patch.zip`. CLI hashes bytes → `file_id`. Hub up: `POST /v1/files` (box proof) → GCS. Hub down: write `$SPOOL_ROOT/files/<file_id>`. Returns `{ file_id, sha256, bytes, name }`.
2. Grok runs `spool-send --from GRK-03 --to CLE-07 --to-box box-b --task <uuid> --kind task --body "review this" --file-id <file_id>`. CLI builds the inner `v:1` JSON (**no file bytes, no sig**) and wraps it in an envelope signed with **box-a's** key. (`--to-box` is not yet in the 002 CLI; open question.)
3. The envelope goes over box-a's WebSocket (or stays pending-flush if the hub is down; same-box targets are written locally and skip the hub).
4. Cloud Run checks `from_box` against the hello and verifies the box sig against the tenant pin. Refuses unknown boxes. Writes Postgres.
5. box-b connected → frame pushed, `delivery=sent`. box-b offline → queued in Postgres, `delivery=queued`.
6. On box-b the hub client re-verifies against box-a's synced pubkey and writes `$SPOOL_ROOT/CLE-07/inbox/`. `spool-recv --as CLE-07` shows the task.
7. `spool-get-file <file_id>` → `GET /v1/files/...` or signed URL → zip on disk.
8. Human `spool-tail --task <uuid>` sees the thread (live tail after M1).

Grok never talks to NATS, Postgres, or the bucket.

---

## 9. Trust — box key first, IAM optional

**(superseded in part)** The first draft said "sign on day one" with one keypair **per agent**. `specs/002-box-agent-messaging/contracts/trust-modes.md` replaced that:

| Mechanism | Answers |
|---|---|
| POSIX on `$SPOOL_ROOT` | local mode: same box, same OS users; no `sig` |
| Box key (Ed25519), pinned by the tenant root | hub mode: which **box** may connect and which box sent a frame (door **and** author of the frame) |
| IAM / OIDC | optional front for a private deploy; never required of renters; never replaces the box key |

Do **not** start with GCP IAM: "this laptop may POST" still cannot tell a pinned box from a lying script.

1. Local folder, unsigned. No key ceremony.
2. Box keypair + tenant-root pin + WS hub (in-memory store allowed in unit tests).
3. Postgres + GCS hold hub state.
4. Optional IAM on a private deploy (after M1).

Box and tenant-root private keys never enter spool, Postgres, GCS, or a log. An unpinned box's hello is closed. The renter pins boxes with `spool-pin` using the tenant root.

---

## 10. Build order
 
Matches `SPEC-spool-milestones.md`:

1. Local folder CRUD + files + tail, unsigned (**spec 002**). No NATS, no GCP.
2. **M1**: hub on Cloud Run: WS + box pins + REST files + hub queue, tenant-scoped. Store is **Postgres-only** in both production (Cloud SQL) and local dev (`docker compose` in `csi-spl-orc` matching `pas-psf-orc`). Box orchestration uses the standard **`spool-harness`** launcher. Inter-instance WS frame dispatch uses Postgres `LISTEN/NOTIFY`.
3. **M2**: self-service checkout & rental (spec 006) with wildcard DNS `*.spool-hub.ai`.
4. **M3**: Slack-like multi-channel WUI (spec 005).
5. ysg-box adapter feature that **only** calls spool.

Do not start Kafka, Slack-as-bus, per-agent GCP keys, or NATS before `spool-send` works on a dummy folder.

Kafka is a platform (brokers, partitions, consumer groups). Load here is small JSON tasks, not millions of events. Now: HTTP request/response + NDJSON log. Optional SSE/websocket for token paint on the **adapter**. When many boxes: GCP Pub/Sub (already on Cloud Run) or NATS. Kafka when a team already runs Kafka and needs replay across many consumer apps.

JetStream is a good **later** backbone (live tail per `task_id`, durable inbox per agent, ack, retention). File bytes still in GCS. NATS carries the message; it does not replace pin, schema, or file ids.

Cloud Run can die any minute (min instances = 1 by default to keep a warm WS; cnf-overridable, including 0). Stateless: WS + HTTP send / recv / verify. State: Cloud SQL (Postgres) + GCS (files) + Secret Manager (hub TLS only; no box or tenant-root private key). Do not put the NDJSON log, queue, or WS session state on the container disk.

Replicas later: two Cloud Run services + Postgres + GCS. Do not put the only copy of keys or files in RAM.

---

## 11. Failure

| Failure | Behaviour |
|---|---|
| Cloud Run down | same-box mail unaffected; cross-box sends pending-flush in the local outbox |
| Notify down (after M1) | writes still land in Postgres; tail is stale until catch-up |
| GCS down | refuse file send; text-only may proceed if policy allows (open question) |
| Bad box signature / unpinned box | refused / socket closed; exit `78`; no persist |
| Receiving box offline | hub queues (TTL from cnf); send returns `delivery=queued` |

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
- Agents never hold bucket keys or hub keys; the box key is the only hub credential.
- Every hub row and object key is tenant-scoped.

<!-- version: 0.2.2 · updated: 2026-09-18 · last-edit: 2026-09-18T19:13:12Z -->
