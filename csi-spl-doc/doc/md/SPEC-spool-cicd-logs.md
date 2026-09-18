# SPEC: CI/CD run logs in chat (long-term)

Status: **after M3**. Not in M1 proto, M2 public MVP, or M3 Slack rollout.  
Git-spec stub: `csi-spl-doc/specs/008-spool-cicd-logs/`

Fetch GitHub Actions (and later other CI) **run logs** with `gh` and post
them **into the same spool chats** (`v:1` `note` + file). Humans and agents
see the log in the thread, not in a separate GitHub tab.

---

## 1. Shape

The **Cloud Run spool-hub-api image** includes the **`gh` binary**. A
**configured GitHub token** lives in **Secret Manager** (csi-rel `029`
pattern). The hub (or a hub-side worker) runs `gh run view` / `gh run
list` / log download and **sends a spool message** on the caller’s
`task_id` (file for the log; short summary in `body`).

| Piece | Rule |
|---|---|
| Binary | `gh` in the Cloud Run Docker image (not required on boxes) |
| Token | Secret Manager; **never** in git, image, logs, or chat body |
| Tenant | **Per-tenant** token (optional). Hub uses only that tenant’s token. No token → feature off (`kind=note` “CI not configured”). |
| Allowlist | cnf: org/repo patterns this tenant may read. Cross-tenant fetch forbidden. |
| Size | Prefer `spool-put-file` for the log (32 MiB limit). Truncate + say so if larger. |
| Wire | Same `v:1` + box/hub envelope. No GitHub HTML in the protocol. |

---

## 2. How it is invoked

From **chat (M3)** or **CLI/MCP** (same tools later):

- Input: Actions **run URL**, or `owner/repo` + `run_id` (and optional job).
- Auth: caller is a pinned peer in the tenant (human `HUM-*` or agent).
- Hub runs `gh` **as that tenant**, writes bytes to files store, `spool-send`
  `kind=note` to the thread (`to` = requester or the channel’s task).

Do not scrape GitHub in the browser. Do not put the token on a box.

---

## 3. Security

- Fail-closed if the secret is missing/placeholder in prd (csi-rel payment
  wiring style).
- `gh` stderr must be scrubbed of tokens.
- Logs in chat are the **CI output**, which may contain secrets **from the
  pipeline**. That is the renter’s leak; we still never add **our** token.
- IAP is gone in M2; this feature still must not expose `gh` as an open
  proxy: pin + tenant token + repo allowlist.

---

## 4. Out of this feature

M1/M2/M3 scope. GitLab/other CI (same pattern later). Streaming log tail
(first cut is fetch-a-finished-run or current log snapshot). Running
`gh` on the **box** instead of Cloud Run (boxes already have keys; this
spec is hub-side).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:30:00Z -->
