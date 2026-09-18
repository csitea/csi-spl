# Contract: CLI verbs (must stay 1:1 with MCP and with `003`)

Backed by a local `$SPOOL_ROOT` in `002`. The SAME verbs and flags work
unchanged when `003` adds a hub behind them. `$SPOOL_ROOT` default
`/var/tmp/claude/msgs`, overridable by env.

```
spool-keygen  --as <id>                         # create ed25519 keypair for <id>
spool-pin     --id <id> --pubkey <b64|file>     # trust <id>'s pubkey
spool-put-file <path>                           # -> {file_id, sha256, bytes, name}
spool-send    --from <id> --to <id> --task <uuid> --kind <task|result|note|reject>
              --body <text> [--file-id <id> ...]  # -> {msg_id, task_id, ts}
spool-recv    --as <id> [--ack]                 # -> [ v1 message objects ]
spool-get-file <file_id> <dest>                 # -> {path, bytes, sha256}; verifies hash
spool-tail    [--task <uuid>] [--json]          # human lines, or raw v1 NDJSON
```

## Behaviour

- **`spool-keygen`** writes the private key `chmod 600` under `$HOME` (not
  `$SPOOL_ROOT`), prints the pubkey. Never prints the private key.
- **`spool-pin`** records id→pubkey in the shared pin store (`$SPOOL_ROOT/pins/<id>.pub`, mode `0644`). Re-pinning a different key
  for an existing id requires `--force` (prevents silent key swap).
- **`spool-put-file`** hashes bytes, writes `files/<file_id>` idempotently.
- **`spool-send`** builds a `v:1` object, signs with `from`'s key, writes the
  recipient's `inbox/` file and a copy in the sender's `outbox/`. Refuses (exit
  `78`) if `from` is unpinned or its key is missing. `--task` optional; if
  omitted a new UUID is minted and returned.
- **`spool-recv`** reads `inbox/`, verifies each `sig` against the sender's pin,
  returns valid messages as a JSON array. `--ack` atomically renames returned
  files into `archive/`. A file that fails verification is reported (not silently
  dropped) and the command exits `78`.
- **`spool-get-file`** copies `files/<file_id>` to `dest`, re-hashes, fails
  without writing a partial if the hash mismatches or bytes are absent.
- **`spool-tail`** lists a thread oldest-first; `--json` emits raw `v:1` NDJSON.

## Exit codes

`0` ok · `78` verify/refuse (unpinned author, bad signature, hash mismatch) ·
`1` usage/IO error. MCP maps `78` to a tool error carrying the same reason.

## Session Lifecycle & Harness Integration

The box session harness (`next-agent-id.sh` / tmux agent spawn launcher):
1. Allocates a unique agent ID (e.g. `CLE-07`, `GRK-03`, `AGY-01`).
2. Runs `spool keygen --as <id>` (writes private key `chmod 600` under `$HOME/.spool/keys/`).
3. Runs `spool pin --id <id>` (registers pubkey into `$SPOOL_ROOT/pins/<id>.pub` and hub if configured).
4. On 409 collision at the hub, increments to the next ID before starting the agent session.
5. Launches the AI session. The AI agent never manages key generation or initial pin setup manually.
6. Subagents spawned during a session (e.g. Antigravity or Claude subagents) follow the exact same flow, allocated their own distinct top-level IDs (e.g. `AGY-02`) as first-class peers.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:53:00Z -->
