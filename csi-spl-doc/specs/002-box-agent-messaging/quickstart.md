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

`SPOOL_ROOT` holds inboxes and blobs. Local mail is unsigned
(`contracts/trust-modes.md` §2), so no key or pin is needed; `SPOOL_KEYS_DIR`
only matters for the optional box key in section 4.2 and must stay outside
`SPOOL_ROOT`.

```bash
export SPOOL_ROOT="$WORK/msgs" SPOOL_KEYS_DIR="$WORK/keys" SPOOL_LOG_LEVEL=error
```

## 3. Round trip

### 3.1 Agents need no setup

There is no key ceremony: an agent id exists once it has a directory under
`$SPOOL_ROOT`, which the first send creates. Go straight to 3.2.

### 3.2 Put a file into the blob store

Prints `{file_id, sha256, bytes, name, kind}`; `file_id` is the sha256.

```bash
echo patch-bytes > "$WORK/patch.txt" && FID="$("$B" put-file "$WORK/patch.txt" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file_id"])')" && echo "$FID"
```

### 3.3 Send a signed message with the blob attached

Prints `{delivery, msg_id, task_id, ts}`; `delivery` is `local`. Without
`--task` a new task UUID is minted.

```bash
"$B" send --from GRK-03 --to CLE-07 --kind task --body "review this" --file-id "$FID"
```

### 3.4 Receive and acknowledge

Prints a JSON array of `v:1` messages (no `sig`); `--ack` moves them to
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

## 4. Refusal and the optional box key

### 4.1 A corrupted blob is refused with exit 78

Locally, `78` means only a content-hash mismatch.

```bash
echo rotted > "$SPOOL_ROOT/files/$FID" && "$B" get-file "$FID" "$WORK/bad.txt"; echo "exit=$?"
```

Expected: `exit=78`, and `$WORK/bad.txt` is not written.

### 4.2 Optional: a box key for hub mode

One key per box, never per agent. It is not used while `$SPOOL_HUB_URL` is
unset. `keygen` prints the public key only; the private key lands `0600` in
`$SPOOL_KEYS_DIR` as `box-box-a.key`.

```bash
"$B" pin --box box-a --pubkey "$(SPOOL_BOX_ID=box-a "$B" keygen)"
```

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
in `$HOME/.spool/keys` and pins in `$SPOOL_ROOT/pins`; local mail needs
neither. A box key is created once per box, only for hub mode, by the harness
or the renter, never by an agent (`contracts/cli.md`, "Session Lifecycle &
Harness Integration").

### 6.4 MCP registration

Each agent session registers the same binary as a stdio MCP server: command
`spool`, argument `mcp`, one process per session (spawned by the harness, not
one per tmux window). It shares `$SPOOL_ROOT` and the pins with the CLI, and
exposes `spool_put_file`, `spool_send`, `spool_recv`, `spool_get_file` and
`spool_tail` (`contracts/mcp-tools.md`). stdout carries only the protocol; the
server exits 0 when the client closes stdin.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T16:30:00Z -->
