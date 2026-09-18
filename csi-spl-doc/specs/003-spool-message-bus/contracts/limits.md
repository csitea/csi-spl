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
| `GET /v1/messages` page | 100 messages | hub (`limit`, default 100) |
| unacked inbox files on box | no hard fail on send | recv may batch |

## Retention (hub)

| Store | Retention |
|---|---|
| GCS `files/` | 30 days (lifecycle). Distinct from git-rel 001 (1 day). |
| Postgres `messages` | 90 days then move to `messages_archive` (same shape) or delete — pick in cnf, default 90 days delete-after-archive. |
| NATS Core | none |
| NATS JetStream | 7 days or 10k messages per `task.*` stream, whichever first |
| Local `$SPOOL_ROOT` | operator’s problem; no auto-delete in 002 |

A `spool-get-file` after GCS expiry is a clean miss (exit `1`), not a
partial file.

## Not limited here

Model-token SSE (not spool). git-rel object size (001).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T13:20:00Z -->
