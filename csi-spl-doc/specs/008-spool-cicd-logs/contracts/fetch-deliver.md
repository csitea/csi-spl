# Contract: Hub-side CI/CD log fetch + deliver (008)

Feature: `008-spool-cicd-logs`

The hub fetches a GitHub Actions run log **as that tenant** and posts it on
the existing **v:1 bus** as `kind=note` plus a blob file. Agents never call
GitHub; boxes never hold the token. M1 does this **without** the `gh`
binary (HTTP to a configured API base). `gh` in the image is after M3.

Normative with: `../../002-box-agent-messaging/contracts/message-schema.md`,
`../../003-spool-message-bus/contracts/http-v1.md` (send/recv stay WS;
files/pins stay REST), `../../003-spool-message-bus/contracts/limits.md`
(32 MiB / file, 64 KiB body).

## 1. Feature flag (M1 default off)

| Env | Meaning |
|---|---|
| `SPOOL_HUB_CICD_LOGS_ENABLED` | `false` (default). When false the route is **not registered** (looks like 003: REST is files and pins only). |
| `SPOOL_HUB_CICD_GITHUB_API` | API base (`https://…`). **Required when enabled**; no baked host. |
| `SPOOL_HUB_CICD_GITHUB_TOKEN` | Default token for tenants without an override. Secret. Never in git, image, logs, or chat body. |
| `SPOOL_HUB_CICD_TENANT_TOKENS` | `tenant:token,tenant:token` overrides. Secret. |
| `SPOOL_HUB_CICD_REPO_ALLOWLIST` | `tenant:owner/repo,tenant:owner/*`. Empty list for a tenant → **no** repo (fail-closed, not allow-all). |
| `SPOOL_HUB_CICD_FROM_BOX` | Envelope `from_box` (default `hub`). Must be pinned in the tenant to land a `recv`. |
| `SPOOL_HUB_CICD_FROM_ID` | Inner `from` agent id (default `CI-0`; `^[A-Z]{2,4}-\d+$`). |
| `SPOOL_HUB_CICD_HUB_BOX_KEY` | Base64 Ed25519 private key for `from_box`. Secret. Signs the same envelope 003 already forwards. |

`SPOOL_HUB_ENV=prd` **and** the flag true **and** the GitHub token missing
or a placeholder (`CHANGE_ME`, `TODO`, `placeholder`, empty, …) →
`LoadHub` **fails closed** (process does not start). Non-prd may enable
without a token: those tenants get a `note` whose body is exactly
`CI not configured` and no file.

Placeholder detection never logs the value.

## 2. Invocation (hub-side)

`POST /v1/cicd-logs` on the tenant Host. **Only registered when the flag
is on.** Auth = the WS-issued upload token (same capability as
`POST /v1/files`). `to_box` MUST equal the token’s box (a box cannot
stuff another box’s queue).

```json
{ "url": "https://github.com/owner/repo/actions/runs/12345",
  "task_id": "<uuid>", "to": "CLE-07", "to_box": "box-a" }
```

or `{ "owner", "repo", "run_id", "job?", "task_id", "to", "to_box" }`.
`url` is caller input, not a baked default. `job` selects a job log when
set. `task_id` and `to` are required (`to` is a valid agent id).

Reply (200):

```json
{ "delivery": "sent"|"queued", "msg_id": "…", "task_id": "…",
  "configured": true, "truncated": false }
```

`configured: false` is still 200: the `note` was delivered, body
`CI not configured`, no file, no GitHub call.

Errors use `003/contracts/error-envelope.md` plus:

| status | token | when |
|---|---|---|
| 401 | `door` | missing/expired/foreign upload token |
| 403 | `cicd_forbidden` | repo not on this tenant’s allowlist, or `to_box` ≠ token box |
| 400 | `bad_json` | body / ids / URL do not parse |
| 404 | `unknown_tenant` | Host; or the route is absent because the flag is off |
| 413 | `limit_file` | not used on the POST body (the POST is tiny); the **fetched** log is truncated at 32 MiB rather than 413 |

The hub **never** returns or logs the token. GitHub stderr / error JSON is
scrubbed of the token before it becomes `detail`.

## 3. Fetch

When the tenant has a real token and the repo is allowlisted:

1. `GET {API}/repos/{owner}/{repo}/actions/runs/{run_id}/logs`
   (or `…/actions/jobs/{job}/logs` when `job` is set).
2. `Authorization: Bearer <token>` only on the API host; **strip it on
   redirect** (GitHub 302s to a signed blob URL).
3. Read at most 32 MiB + 1 byte (`msg.MaxFileBytes`). Extra → keep 32 MiB,
   set `truncated`, body says `log truncated at 32 MiB`.
4. Put bytes in the existing blob store (`t/<tenant>/files/<sha256>`),
   same as `POST /v1/files`.
5. Compose inner `v:1`: `kind=note`, `from=CI-0`, `to` = requester,
   `task_id` from the request, `files=[blob]`, body a short summary
   (`CI run owner/repo #run_id` plus the truncation line when needed).
   Body never contains the token. Cap is the 002/003 64 KiB body limit.
6. Wrap in the 003 envelope, sign with the hub box key, `InsertMessage` +
   enqueue/push — the same commit path as a WS `send`. Live `role=box`
   socket → `delivery=sent`; else `queued`.

No GitHub HTML on the wire. Cross-tenant: allowlist and token are keyed
by the Host tenant; another tenant’s patterns never apply.

## 4. Allowlist

Patterns are `owner/repo` (exact, case-insensitive) or `owner/*` (that
org only). `*` / `*/*` are rejected at parse (would be an open proxy).
A tenant omitted from the list, or listed with zero patterns, may not
fetch. Allowlist is checked **after** “does this tenant have a token”:
no token → `CI not configured` without revealing the list.

## 5. Out of this contract

`gh` binary. WUI. 031. MCP/CLI tools on the box (token stays on the hub).
Streaming tail. GitLab. Baking tokens. Changing 003 send/recv.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:53:00Z -->
