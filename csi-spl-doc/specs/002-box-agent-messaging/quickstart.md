# Quickstart: on-box spool (spec 002)

A walkthrough an operator can paste, top to bottom, into one shell. Everything
runs under a throwaway temp root, so it touches neither the live
`/var/tmp/claude/msgs` tree nor `$HOME/.spool/keys`. The steps mirror
`csi-spl-api/src/bash/tests/spool-smoke.tst.sh`, which is the executable
version of this page.

## 1. Build

### 1.1 Offline toolchain

Dependencies come from the Go module cache only; nothing is fetched.

```bash
export PATH=/usr/local/go/bin:$PATH GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
```

### 1.2 Build the binary into the temp root

Run from the repo root.

```bash
export WORK="$(mktemp -d)" && bash csi-spl-api/src/bash/build.sh "$WORK/spool" && export B="$WORK/spool"
```

## 2. Point the spool at the temp root

`SPOOL_ROOT` holds inboxes, pins and blobs; `SPOOL_KEYS_DIR` holds private keys
and must stay outside `SPOOL_ROOT`.

```bash
export SPOOL_ROOT="$WORK/msgs" SPOOL_KEYS_DIR="$WORK/keys" SPOOL_LOG_LEVEL=error
```

## 3. Round trip

### 3.1 Create and pin two agents

`keygen` prints the public key only; the private key lands `0600` in
`$SPOOL_KEYS_DIR`.

```bash
"$B" pin --id GRK-03 --pubkey "$("$B" keygen --as GRK-03)" && "$B" pin --id CLE-07 --pubkey "$("$B" keygen --as CLE-07)"
```

### 3.2 Put a file into the blob store

Prints `{file_id, sha256, bytes, name, kind}`; `file_id` is the sha256.

```bash
echo patch-bytes > "$WORK/patch.txt" && FID="$("$B" put-file "$WORK/patch.txt" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file_id"])')" && echo "$FID"
```

### 3.3 Send a signed message with the blob attached

Prints `{msg_id, task_id, ts}`. Without `--task` a new task UUID is minted.

```bash
"$B" send --from GRK-03 --to CLE-07 --kind task --body "review this" --file-id "$FID"
```

### 3.4 Receive and acknowledge

Prints a JSON array of verified `v:1` messages; `--ack` moves them to
`$SPOOL_ROOT/CLE-07/archive/`, so a second `recv` prints `[]`.

```bash
"$B" recv --as CLE-07 --ack
```

### 3.5 Fetch the blob back

Re-hashes on the way out and writes nothing on a mismatch.

```bash
"$B" get-file "$FID" "$WORK/out.txt" && cat "$WORK/out.txt"
```

### 3.6 Tail the thread

Take the `task_id` printed in 3.3. Add `--json` for raw `v:1` NDJSON.

```bash
"$B" tail --task <task_id>
```

## 4. Refusal is exit 78

### 4.1 Unpinned sender

`AGY-09` has no key and no pin, so the send is refused.

```bash
"$B" send --from AGY-09 --to CLE-07 --kind note --body hi; echo "exit=$?"
```

Expected: `exit=78`. A tampered inbox file makes `recv` exit `78` the same way,
and a hash mismatch does the same for `get-file`.

## 5. Clean up

```bash
rm -rf "$WORK"
```

## 6. How a box gets the binary (T027, docs only)

Spec 002 does not edit any box image or box repo; this section records the
install path a box image is expected to follow.

### 6.1 Build once per release

Pass the install target as the output path. `build.sh` stamps the version from
the repo-root `.version` file (falling back to `0.1.0-dev`).

```bash
bash csi-spl-api/src/bash/build.sh "$HOME/.local/bin/spool"
```

### 6.2 Check it is on PATH

```bash
spool version
```

### 6.3 Live defaults

With no env overrides the binary uses `SPOOL_ROOT=/var/tmp/claude/msgs`, keys
in `$HOME/.spool/keys` and pins in `$SPOOL_ROOT/pins`. The session harness,
not the agent, runs `spool keygen` and `spool pin` for each new agent id
(`contracts/cli.md`, "Session Lifecycle & Harness Integration").

### 6.4 MCP registration

Pending US4 (T022–T024): once `spool mcp` ships, each agent session registers
the same binary as a stdio MCP server, one process per session, sharing
`$SPOOL_ROOT` and the pins with the CLI (`contracts/mcp-tools.md`).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:30:00Z -->
