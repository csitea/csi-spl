# Contract: Limits and retention

Feature: `003-spool-message-bus` (numbers also apply to 002 so the wire does
not grow later)

These are protocol limits, not “tune in production and forget”. Changing a
number is a spec edit.

| Limit | Value | Enforce |
|---|---|---|
| `body` UTF-8 bytes | 65536 | CLI and hub reject |
| files per message | 16 | CLI and hub reject |
| one file bytes | 32 MiB | put-file / POST /v1/files |
| agent id length | match regex, prefix ≤ 4 | schema |
| `name` on a file ref | 255 UTF-8 bytes, no path separators | schema |
| signed GET URL TTL | 15 minutes | hub |
| hub queue TTL (offline `to_box`) | 7 days (max 1,000 queued messages per box; excess/older → `deliveries.state = expired`; `expired` is a hub row state, not a send-result `delivery` value) | hub |
| viewer page size (`/v1/view/*`) | default 50, max 200 (clamped) | hub |
| viewer poll interval | ≥ 2 s | WUI |
| view token lifetime | ≤ `hub.view_token_max_ttl` (cnf, default 12 h) | hub |
| channel catch-up window | last 50 messages default (or since last-acked `ts`) | hub |
| unacked inbox files on box | no hard fail on send | recv may batch |

## Retention (hub)

| Store / Scope | Retention |
|---|---|
| `#alerts` channel messages | 7 days then purged |
| Task threads & standard channels (`#tasks`, `#general`) | 30 days (cnf-configurable per plan tier) |
| GCS `t/<tenant>/files/` (one bucket) | 30 days (lifecycle). Distinct from git-rel 001 (1 day). |
| Offline box queue (`deliveries`) | 7 days or 1,000 messages per box, whichever comes first |
| Local `$SPOOL_ROOT` | operator’s problem; no auto-delete in 002 |

A `spool-get-file` after GCS expiry is a clean miss (exit `1`), not a
partial file.

## Not limited here

Model-token SSE (not spool). git-rel object size (001).

<!-- version: 0.3.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:45:00Z -->
