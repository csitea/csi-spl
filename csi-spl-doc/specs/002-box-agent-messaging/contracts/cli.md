# Contract: CLI verbs (must stay 1:1 with MCP and with `003`)

Backed by a local `$SPOOL_ROOT` in `002`. The SAME verbs and flags work
unchanged when `003` adds a hub behind them. `$SPOOL_ROOT` default
`/var/spool-hub`, overridable by env.

```
spool-keygen  [--box <box_id>] [--force]       # optional: box ed25519 keypair (hub prep)
spool-pin     --box <box_id> --pubkey <b64>     # optional: trust a box's pubkey (hub prep)
spool-put-file <path>                           # -> {bytes, file_id, kind, name, sha256}
spool-send    --from <id> --to <id> [--task <uuid>] --kind <task|result|note|reject>
              --body <text> [--file-id <id> ...]  # -> {delivery, msg_id, task_id, ts}
spool-recv    --as <id> [--ack]                 # -> [ v1 message objects ]
spool-get-file <file_id> <dest>                 # -> {file_id, path}; verifies hash
spool-tail    --task <uuid> [--json]            # human lines, or raw v1 NDJSON
spool-mcp                                       # stdio MCP server (contracts/mcp-tools.md)
```

## Behaviour

Local mode (`$SPOOL_HUB_URL` unset) is unsigned: no verb below needs a key or
a pin (`trust-modes.md` §2).

- **`spool-keygen`** (optional, hub prep) writes the one per-box private key
  `box-<box_id>.key`, `chmod 600`, under `$HOME/.spool/keys` (not
  `$SPOOL_ROOT`), and prints the pubkey. Never prints the private key.
  `--box` defaults to `$SPOOL_BOX_ID`; with neither it fails fast (exit `1`).
- **`spool-pin`** (optional, hub prep) records box→pubkey in the shared pin
  store (`$SPOOL_ROOT/pins/box-<box_id>.pub`, mode `0644`). Re-pinning a
  different key for an existing box requires `--force` (no silent key swap).
- **`spool-put-file`** hashes bytes, writes `files/<file_id>` idempotently.
- **`spool-send`** builds an unsigned `v:1` object, writes the recipient's
  `inbox/` file and a copy in the sender's `outbox/`, and returns
  `delivery: "local"` (hub mode adds `sent`/`queued`, trust-modes §8). `--task`
  optional; if omitted a new UUID is minted and returned.
- **`spool-recv`** reads `inbox/` and returns the well-formed messages as a JSON
  array. `--ack` atomically renames returned files into `archive/`. A malformed
  file is reported (not silently dropped), stays in `inbox/`, and the command
  exits `1` after printing the good messages. A `sig` on a local file is not
  checked.
- **`spool-get-file`** copies `files/<file_id>` to `dest`, re-hashes, fails
  without writing a partial if the hash mismatches (exit `78`) or bytes are
  absent (exit `1`).
- **`spool-tail`** lists a thread oldest-first; `--json` emits raw `v:1` NDJSON.

## Exit codes

`0` ok · `78` verify/refuse — locally only a content-hash mismatch on
`get-file`/`get-dir`; hub mode adds a missing or failing box signature ·
`1` usage/IO error or a malformed inbox file. MCP maps a non-zero exit to a
tool error carrying the same reason and code.

## Session Lifecycle & Harness Integration

The box session harness (`next-agent-id.sh` / tmux agent spawn launcher):
1. Allocates a unique agent ID (e.g. `CLE-07`, `GRK-03`, `AGY-01`).
2. Creates `$SPOOL_ROOT/<id>/` (the roster is the directory list; trust-modes §4). No per-agent key or pin.
3. Hub mode only, once per box (not per agent): `spool keygen --box $SPOOL_BOX_ID`, and the renter pins that box pubkey with the tenant root (trust-modes §3).
4. On a 409 for a duplicate id on this box at the hub, increments to the next ID before starting the agent session.
5. Launches the AI session. The AI agent never manages keys.
6. Subagents spawned during a session (e.g. Antigravity or Claude subagents) follow the exact same flow, allocated their own distinct top-level IDs (e.g. `AGY-02`) as first-class peers.

<!-- version: 0.1.1 · updated: 2026-09-18 · last-edit: 2026-09-18T16:15:00Z -->
