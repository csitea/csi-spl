# Contract: Identifiers and keys

Status: **binding for 004**; subordinate to
`../../002-box-agent-messaging/contracts/trust-modes.md`. Checked against
trunk `bbc41e7`.

## 1. Identifiers

| Identifier | Format | Unique within | Source | Appears in |
|---|---|---|---|---|
| Tenant id | `^[a-z0-9][a-z0-9-]{0,31}$` | the hub | request Host (006) | never in a message |
| Box id | `^[a-z0-9][a-z0-9-]{0,31}$` | one tenant (its pin) | `$SPOOL_BOX_ID`, renter-chosen, no default | envelope `from_box` / `to_box`, hello, pins |
| Agent id | `^[A-Z]{2,4}-[0-9]+$`, prefix `BOX-` forbidden | one box (`$SPOOL_ROOT/<id>/`) | harness allocator | inner `v:1` `from` / `to` |
| Hub address | `(box_id, agent_id)`, shown `CLE-07@box-a` | one tenant | derived | WUI, logs |

Not identities: display names, tmux titles, OS users, hostnames, GCP principals.
A box id is **not** a hostname and **not** a credential.

## 2. Agent-id prefixes

| Prefix | Kind |
|---|---|
| `CLE` | Claude Code |
| `GRK` | Grok |
| `AGY` | Antigravity |
| `HUM` | human operator (reserved; not required in M1) |
| `BOX` | **forbidden** |

A new vendor adds a prefix; no API change. Sub-agents get their own top-level
id; dotted ids (`AGY-01.1`) fail the regex.

Validation points — each MUST reject `BOX-`:

| Point | Where | Status |
|---|---|---|
| message `from` / `to` | `internal/msg/msg.go:130,133` | Implemented |
| send / recv `--as`, dir scan | `internal/spool/spool.go:62,131,206` | Implemented |
| hub roster | `internal/hub/ws.go:478` → `roster_duplicate` | Implemented |
| SQL `roster.agent_id` CHECK | `csi-spl-rdb/…/0005_pin_identity.sql` | Implemented (`4f611d6`, `TestRosterIsPerBox/postgres`) |

## 3. Keys

| Key | Holder | Location | Signs |
|---|---|---|---|
| Tenant root (Ed25519) | renter only | `--root-key` / `$SPOOL_TENANT_ROOT_KEY`; pubkey in `tenants.root_pubkey` | pin, force, revoke |
| Box key (Ed25519) | that box only | `$HOME/.spool/keys/box-<box_id>.key` `0600` | hello, every envelope |
| Box pubkey | hub + tenant's boxes | `pins.pubkey`; `$SPOOL_ROOT/pins/box-<box_id>.pub` `0644` | — (verifies) |
| Agent key | **none** | — | — |

Local mode uses none of these. Private keys never enter Postgres, GCS, logs,
the WUI, a pin body or a message.

## 4. Uniqueness

- Two boxes in one tenant MAY both announce `CLE-07`; the hub MUST NOT 409 that.
- One box announcing the same id twice → 409 `roster_duplicate`.
- Same `box_id`, different pubkey, no `force` → 409 `pin_conflict`.
- Same `box_id`, same pubkey → 200, no change.

<!-- version: 1.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:23:00Z -->
