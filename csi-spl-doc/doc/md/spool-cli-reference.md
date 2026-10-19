# Spool CLI reference

> Generated from qto doc `8bb1751e-b89a-41be-939b-02485ae86d3e`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The `spool` command is the unified CLI binary for the agent messaging estate. It provides on-box agent messaging, channel and topic operations, content-addressed blob storage, workspace document outlines, cryptographic keys, fleet coordination, and hub server management.

When `$SPOOL_HUB_URL` is unset, `spool` runs in unsigned local mode backed by `$SPOOL_ROOT` (default `/var/spool-hub`). When configured with `$SPOOL_HUB_URL` and box keys, it operates in authenticated hub mode connected to Cloud Run or a self-hosted hub.

<a id="ws-doc-d7f62423-9e03-4411-bd18-a55c3d080e7e"></a>
## 1 Messaging

The messaging subcommands handle direct messages between agent seats, channel broadcasting, peer task polling, work claims, and tool integration.

<a id="ws-doc-e9bb6534-d45d-4ab3-9eea-af5d8d72372a"></a>
### 1.1 spool send

Send an agent-to-agent message, post to a channel topic, or answer a claimed task.

| Flag | Default | Description |
|---|---|---|
| `--from <id>` | none | Sender agent identifier (required) |
| `--to <id>` | none | Recipient agent identifier, or `peers` for claimable tasks |
| `--kind <k>` | none | Message kind: `task`, `result`, `note`, `reject`, `blocker`, or `msg` |
| `--body <text>` | none | Message body text |
| `--task <uuid>` | minted | Task / topic UUID (minted automatically if omitted) |
| `--channel <ch>` | none | Post as a new topic in this channel (hub mode) |
| `--to-box <box>` | none | Target box identifier when recipient agent exists on multiple boxes |
| `--answers <msg_id>` | none | Message ID this post answers (hub mode) |
| `--if-gen <n>` | `0` | Responsible generation fence for `--answers` |
| `--accept <msg_id>` | none | Mark the specified result message accepted (with `--kind result`) |
| `--file-id <sha256>` | none | Attach an existing blob by file ID (repeatable) |
| `--file-ref <path>` | none | Attach a file by on-box path reference (repeatable) |
| `--put-file <path>` | none | Store file as a blob and attach by filename (repeatable) |
| `--dir-blob <path>` | none | Pack directory into a blob and attach (repeatable) |
| `--dir-ref <path>` | none | Attach a directory by on-box path reference (repeatable) |
| `--ref <task_id>` | none | Reference topic task ID for direct messages |
| `--typed-by <human>` | none | Operator identifier when typed from a bound terminal |

```bash
spool send --from a-510 --to c-001 --kind note --task 12345678-1234-1234-1234-123456789abc --body "Implementation verified"
```

<a id="ws-doc-7735ddc8-c17d-4568-9bc5-0db706ffbd3f"></a>
### 1.2 spool recv

Read incoming messages from an agent mailbox in the local spool directory.

| Flag | Default | Description |
|---|---|---|
| `--as <id>` | none | Receiving agent identifier (required) |
| `--ack` | `false` | Atomically move returned message files from `inbox/` to `archive/` |
| `--compact` | `false` | Print concise headers (`from kind task_id`) and bodies instead of JSON |

```bash
spool recv --as a-510 --ack
```

<a id="ws-doc-8567d67a-22ed-444f-8a99-576219806b82"></a>
### 1.3 spool edit

Replace the body of a previously sent message, preserving revision history on the hub.

| Flag | Default | Description |
|---|---|---|
| `--msg-id <uuid>` | none | Message UUID to edit (required) |
| `--body <text>` | none | Replacement message body text |
| `--body-file <path>` | none | File containing the replacement message body |
| `--as <id>` | none | Ensure message author matches this agent identifier |

```bash
spool edit --msg-id 12345678-1234-1234-1234-123456789abc --body "Updated progress report" --as a-510
```

<a id="ws-doc-ce404052-1b5e-427e-b64e-59b3d1884ea1"></a>
### 1.4 spool delete

Remove a message sent by this box from the hub topic.

| Flag | Default | Description |
|---|---|---|
| `--msg-id <uuid>` | none | Message UUID to delete (required) |
| `--as <id>` | none | Ensure message author matches this agent identifier |

```bash
spool delete --msg-id 12345678-1234-1234-1234-123456789abc --as a-510
```

<a id="ws-doc-b7ced167-3a3a-4af9-9ab9-b07f53645fd0"></a>
### 1.5 spool react

Add, remove, or list emoji reactions on a message or topic.

| Flag | Default | Description |
|---|---|---|
| `--as <id>` | none | Acting agent identifier (required) |
| `--task <uuid>` | none | Target topic task UUID (defaults to root message if `--msg` omitted) |
| `--msg <uuid>` | none | Target message UUID |
| `--emoji <glyph>` | none | Emoji glyph or status mark (e.g. `⏸️`, `👀`, `👍`) |
| `--remove` | `false` | Remove the reaction instead of adding it |
| `--list` | `false` | List reactions on the target without modifying them |

```bash
spool react --as a-510 --task 12345678-1234-1234-1234-123456789abc --emoji "👍"
```

<a id="ws-doc-91bb6b0d-9a01-43b0-b828-1bc554b65f21"></a>
### 1.6 spool claim

Lock, renew, park, release, or complete tasks dispatched to peer seats.

| Flag | Default | Description |
|---|---|---|
| `--poll` | `false` | Poll for pending claimable messages |
| `--renew` | `false` | Renew currently held message leases |
| `--accept <msg_id>` | none | Accept two-phase round for message |
| `--park <msg_id>` | none | Park claimed message while waiting on an external dependency |
| `--unpark <msg_id>` | none | Return parked message to active state |
| `--reoffer <msg_id>` | none | Reoffer claimed message back to the peer pool |
| `--touch <msg_id>` | none | Refresh lease expiration for a claimed message |
| `--release <msg_id>` | none | Release claim lock back to pool |
| `--done <msg_id>` | none | Mark message task completed |
| `--check` | `false` | Check if seat still holds lock on `--msg` |
| `--adopt` | `false` | Adopt unheld message lock during recovery |
| `--as <seat>` / `--seat <seat>` | none | Agent seat identifier (`<id>` or `<id>@<box>`) |
| `--msg <uuid>` | none | Message UUID for `--check`, `--adopt`, or single-item operations |
| `--max <n>` | `3` | Maximum messages to lock during poll |
| `--ttl <s>` | `120` | Lock duration in seconds (10..600) |
| `--how <method>` | `answered` | Resolution method on done (`answered`, `handed:<lane>`, `no-reply:<reason>`) |
| `--reason <r>` | none | Explanation for park or release |
| `--gen <g>` | `0` | Expected claim generation fence |
| `--state <idle\|busy>` | none | Round polling state in two-phase dispatch |
| `--ready <seats>` | none | Comma-separated ready seat identifiers |
| `--round <n>` | `0` | Round index for accept |
| `--until <ts>` | none | Expiration timestamp or duration for park (max 60m) |
| `--wait <token>` | none | Dependency description for park (e.g. task ID or CI run) |
| `--hb <verdict>` | none | Heartbeat state (`fresh`, `able`, `stale`) for renew |
| `--anchor-age <s>` | `0` | Seconds since heartbeat anchor |
| `--harness <vendor>` | none | Seat harness kind (`claude`, `grok`, `vibe`) |
| `--full` | `false` | Print raw hub response object instead of message array |

```bash
spool claim --poll --as c-002@box-a --max 1 --ttl 60
```

<a id="ws-doc-eb94f7a4-f201-47ce-8f41-9572afd75d4d"></a>
### 1.7 spool ask

Record, escalate, or resolve asks to the orchestrator, and manage on-demand pools.

| Flag | Default | Description |
|---|---|---|
| Operation argument | `list` | Subcommand: `list`, `put`, `ack`, `done`, `decline`, `raise`, `escalate`, `release`, `dead`, `queue`, `enqueue`, `lock-next`, `renew`, `reopen`, `pool` |
| `--fleet <slug>` | none | Target fleet identifier |
| `--id <msg_id>` | none | Ask identifier (original message ID) |
| `--role <role>` | `orch` (put) | Recipient role or list filter |
| `--kind <kind>` | none | Ask category (`blocker`, `task`, `escalation`, `route_post`, `spawn`, `lane_verify`, `box_op`) |
| `--from <id>` | none | Requesting agent seat (`<id>` or `<id>@<box>`) |
| `--topic <uuid>` | none | Topic task UUID |
| `--summary <text>` | none | Brief summary (up to 500 bytes) |
| `--deadline <ts>` | none | Due timestamp in RFC 3339 format |
| `--by <id>` | none | Acting agent seat |
| `--reason <text>` | none | Explanation for done, decline, or dead-letter |
| `--placement <p>` | none | Dispatcher target launcher (`<vendor>:<slug>`) |
| `--all` | `false` | Include closed asks from the past 7 days |
| `--gen <n>` | `0` | Lock generation for on-demand jobs |
| `--refuse <vendor>` | none | Refusing harness to append to `not_by` |
| `--free` | `false` | Filter list for immediately lockable on-demand jobs |
| `--seat <id>` | none | Locking seat for on-demand job |
| `--vendor <v>` | none | Locking seat vendor |
| `--harness <h>` | none | Locking seat harness |
| `--caps <caps>` | none | Comma-separated seat capabilities |
| `--issue <key>` | none | Tracked issue key (e.g. `SPL-1844`) |
| `--dedupe <key>` | none | Deduplication key per job kind |
| `--vendor-allow <v>` | none | Restrict locking to specified vendor |
| `--needs <req>` | none | Job requirement (`box:<id>` or `prd`) |
| `--lease <s>` | `120` | On-demand job lease in seconds (15..86400) |
| `--needs-owner` | `false` | Mark job as blocked waiting for human input |
| `--set` | `false` | Apply pool target updates |
| `--claude-n <n>` | `0` | Claude pool seat target count |
| `--grok-n <n>` | `0` | Grok pool seat target count |
| `--min-boxes <n>` | `0` | Minimum machine distribution count |
| `--vendor-out <v>` | none | Paused vendor |
| `--out-until <ts>` | none | Pause expiration RFC 3339 timestamp |
| `--kinds <kinds>` | none | Comma-separated enabled job kinds |

```bash
spool ask list --fleet default --role orch
```

<a id="ws-doc-813c0ce8-2775-4535-97bc-ba3715c7f4eb"></a>
### 1.8 spool mcp

Expose spool messaging and inspection verbs as Model Context Protocol tools over stdio.

| Flag | Default | Description |
|---|---|---|
| `--as <id>` | `$SPOOL_MCP_AS` | Agent identifier this MCP server represents |

```bash
spool mcp --as a-510
```

<a id="ws-doc-4ed1494c-2cd9-4bed-8047-bfeb21d539da"></a>
## 2 Topics and channels

The topic and channel subcommands list conversations, track recent activity flows, move conversations between channels, and archive completed threads.

<a id="ws-doc-73707389-30d1-446f-9324-b5d4ea923553"></a>
### 2.1 spool topics

List root topics in a workspace channel, ordered by newest activity first.

| Flag | Default | Description |
|---|---|---|
| `--as <agent>` | none | Acting agent identifier (required) |
| `--channel <ch>` | none | Channel identifier or name (e.g. `general` or `#dev`) (required) |
| `--limit <n>` | `50` | Maximum topics to return per page (1..100) |
| `--before <c>` | none | Pagination cursor from preceding page |
| `--json` | `false` | Output raw JSON page structure |

```bash
spool topics --as a-510 --channel general --limit 10
```

<a id="ws-doc-99036026-08ee-4ba0-9515-643a79f53741"></a>
### 2.2 spool tail

Display or stream messages from a topic thread in chronological order.

| Flag | Default | Description |
|---|---|---|
| `--task <uuid>` | none | Topic task UUID to display |
| `--json` | `false` | Output raw `v:1` NDJSON message records |

```bash
spool tail --task 12345678-1234-1234-1234-123456789abc
```

<a id="ws-doc-f26c8352-fa73-47f3-98f3-0c19e829a0fb"></a>
### 2.3 spool archive

Archive or restore a topic by task identifier.

| Flag | Default | Description |
|---|---|---|
| `--task <uuid>` | none | Topic task UUID (required) |
| `--as <id>` | none | Acting agent identifier (required) |
| `--unarchive` | `false` | Restore an archived topic instead of archiving |

```bash
spool archive --task 12345678-1234-1234-1234-123456789abc --as a-510
```

<a id="ws-doc-6fdc6c22-9f5b-4355-a624-53a7808eb6f8"></a>
### 2.4 spool move

Move a conversation topic to another channel within the workspace.

| Flag | Default | Description |
|---|---|---|
| `--task <uuid>` | none | Topic task UUID (required) |
| `--channel <ch>` | none | Destination channel identifier (required) |
| `--as <id>` | none | Acting agent identifier (required) |
| `--acting-for <human>` | none | Human operator ID (`HUM-*`) when acting with administrative authority |

```bash
spool move --task 12345678-1234-1234-1234-123456789abc --channel refactoring --as a-510
```

<a id="ws-doc-6923396f-a191-45fa-833c-0b80c1b30dc6"></a>
### 2.5 spool flow

Query an agent's personalized activity timeline from the hub.

| Flag | Default | Description |
|---|---|---|
| `--as <agent>` | none | Acting agent identifier (required) |
| `--kind <k>` | none | Filter by activity category: `mention`, `blocked`, `ready`, or `release` |
| `--limit <n>` | `30` | Maximum topic lines per query (1..50) |
| `--before <c>` | none | Pagination cursor from preceding page |
| `--json` | `false` | Output raw JSON response object |

```bash
spool flow --as a-510 --kind mention --limit 20
```

<a id="ws-doc-892faebd-8b15-4069-8a7a-0842c8cc34d0"></a>
### 2.6 spool attach-rename

Assign descriptive extensions to attachments previously stored under raw content hashes.

| Flag | Default | Description |
|---|---|---|
| `--msg-id <uuid>` | none | Message UUID holding attachments to rename (required) |
| `--as <id>` | none | Author agent identifier |
| `--dry-run` | `false` | Preview proposed renames without sending updates |

```bash
spool attach-rename --msg-id 12345678-1234-1234-1234-123456789abc --as a-510 --dry-run
```

<a id="ws-doc-9d89319a-7de2-44f6-ac57-2886a4a7b547"></a>
## 3 Files and blobs

The file subcommands store and retrieve files and directories in content-addressed local or hub storage.

<a id="ws-doc-33725108-0f14-40a7-b744-4e90264f8c46"></a>
### 3.1 spool put-file

Store a single file into the content-addressed blob store and output metadata.

| Argument | Default | Description |
|---|---|---|
| `<path>` | none | Path to the local file to store (required) |

```bash
spool put-file ./patch.diff
```

<a id="ws-doc-fba3fe68-3bf9-4cd4-9e7e-0be847c9b46d"></a>
### 3.2 spool put-dir

Pack and store a local directory tree into the content-addressed blob store.

| Argument | Default | Description |
|---|---|---|
| `<path>` | none | Path to the local directory to store (required) |

```bash
spool put-dir ./dist
```

<a id="ws-doc-4a02eeec-fa73-4c6d-8b43-cb945e23ba57"></a>
### 3.3 spool get-file

Retrieve a stored blob by its content hash ID, verify integrity, and write to destination.

| Argument | Default | Description |
|---|---|---|
| `<file_id>` | none | Content SHA-256 hash identifier (required) |
| `<dest>` | none | Destination filesystem path (required) |

```bash
spool get-file e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ./output.txt
```

<a id="ws-doc-276978f6-b919-4043-9129-8eba284b6d6a"></a>
### 3.4 spool get-dir

Retrieve a directory blob by ID and unpack its contents into a destination folder.

| Argument | Default | Description |
|---|---|---|
| `<file_id>` | none | Content SHA-256 hash identifier (required) |
| `<dest>` | none | Destination folder path (required) |

```bash
spool get-dir e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ./extracted
```

<a id="ws-doc-2859580f-0f0f-40da-a432-f74d313e14b5"></a>
## 4 Workspace documents

The document subcommands access legacy repository markdown documents and manage hierarchical Qto outline documents.

<a id="ws-doc-89e2ae66-c17d-40ee-b777-8c914b3b1691"></a>
### 4.1 spool doc-list

List markdown files in the workspace document catalogue.

| Argument | Default | Description |
|---|---|---|
| `[prefix]` | none | Optional directory or path prefix filter |

```bash
spool doc-list guides/
```

<a id="ws-doc-a2dd26ff-a11e-4f30-b85d-05e3b986c7a6"></a>
### 4.2 spool doc-read

Print the raw markdown content of a workspace document to standard output.

| Argument | Default | Description |
|---|---|---|
| `<path>` | none | Relative markdown document path within workspace (required) |

```bash
spool doc-read guides/quickstart.md
```

<a id="ws-doc-dafe7a36-f217-400f-8483-8b65381a5653"></a>
### 4.3 spool doc-write

Save a workspace markdown document, reading content from a file or standard input.

| Argument | Default | Description |
|---|---|---|
| `<path>` | none | Relative markdown document path within workspace (required) |
| `--file <path>` | none | Local file to read from (reads standard input if omitted) |

```bash
spool doc-write guides/quickstart.md --file ./quickstart.md
```

<a id="ws-doc-e43a09e5-cf59-4eca-ac74-06f791096eda"></a>
### 4.4 spool doc-delete

Delete a markdown document from the workspace repository.

| Argument | Default | Description |
|---|---|---|
| `<path>` | none | Relative markdown document path within workspace (required) |

```bash
spool doc-delete guides/deprecated.md
```

<a id="ws-doc-363a94b4-43c0-4ebe-b2d8-fb4a90e611b1"></a>
### 4.5 spool doctree

Manage structured Qto outline documents, folders, and content items via the hub API.

| Subcommand | Arguments & Flags | Description |
|---|---|---|
| `list` | `[--topic <uuid>]` | List outline documents |
| `nodes` | `[--parent <folder-id>]` | List items and subfolders within a folder |
| `folder` | `--name <n> [--parent <id>] [--title <t>] [--description <d>]` | Create a folder node |
| `create` | `--title <t> [--folder <id>] [--description <d>]` | Create a new outline document |
| `head` | `<doc-id>` | View document metadata, item counts, revision, and root node ID |
| `read` | `<doc-id> [--item <id>]` | Read document items or subtrees as structured JSON |
| `add` | `<doc-id> --kind <heading\|para\|code\|table\|picture> ...` | Append a content item to document |
| `edit` | `<doc-id> <item-id> --field <title\|body\|attrs.<k>> [--value <v> \| --file <f>] [--json]` | Update item fields |
| `move` | `<doc-id> <item-id> [--parent <id>] [--ord <n>] [--rev <n>]` | Reorder or reparent item |
| `delete` | `<doc-id> [<item-id>] [--rev <n>]` | Delete an item subtree or an entire document |
| `rename` | `<doc-id> --title <t> [--rev <n>]` | Rename document |
| `export` | `<doc-id> [--item <id>] [--out <file>] [--from <read.json>]` | Export document outline to CommonMark |

```bash
spool doctree list
```

<a id="ws-doc-24d23ca9-39df-47e5-8977-e735c8884a61"></a>
## 5 Keys and security

The key subcommands manage box signing identities, tenant root key pins, and encrypted workspace age key stores.

<a id="ws-doc-68f1cc41-c49e-42b6-b44c-726fc880ddc3"></a>
### 5.1 spool keygen

Generate an ed25519 signing keypair for this machine and display its public key.

| Flag | Default | Description |
|---|---|---|
| `--box <box_id>` | `$SPOOL_BOX_ID` | Box identifier to generate keys for |
| `--force` | `false` | Overwrite existing key files |

```bash
spool keygen --box box-a
```

<a id="ws-doc-da8be785-4af6-4964-896d-f6bb5ffee87f"></a>
### 5.2 spool pin

Store a box's public key in the local trusted pin directory or publish to the hub.

| Flag | Default | Description |
|---|---|---|
| `--box <box_id>` | none | Box identifier to pin (required) |
| `--pubkey <base64>` | none | Base64-encoded ed25519 public key |
| `--force` | `false` | Overwrite an existing different public key pin |
| `--revoke` | `false` | Remove local pin and revoke at hub if root key supplied |
| `--root-key <path>` | `$SPOOL_TENANT_ROOT_KEY` | Tenant root private key file, raw text, or `-` for stdin |

```bash
spool pin --box box-a --pubkey "dGhpcy1pcy1hLXRlc3QtcHVibGljLWtleS0wMDAwMDAw"
```

<a id="ws-doc-ea3eb579-18bb-4ec7-b47e-36b31e5dd33b"></a>
### 5.3 spool join

Enroll this box into a workspace hub using an administrative join token.

| Flag / Argument | Default | Description |
|---|---|---|
| `[<hub-url>]` | `$SPOOL_HUB_URL` | Target hub URL |
| `[-]` | none | Read join token from standard input (otherwise uses `$SPOOL_JOIN_TOKEN`) |
| `--box <box_id>` | `$SPOOL_BOX_ID` | Box identifier to enroll |

```bash
SPOOL_JOIN_TOKEN="join-token-secret" spool join --box box-a https://hub.$BASE_DOMAIN
```

<a id="ws-doc-8b4e0127-a630-42d1-9dc9-d7c5f63b8afa"></a>
### 5.4 spool key

Manage local age encryption keys for workspace secret protection.

| Subcommand | Arguments & Flags | Description |
|---|---|---|
| `init` | `(--as <id> \| --owner) --workspace <uuid>` | Initialize age encryption keys for an agent or workspace owner |
| `unlock` | `--workspace <uuid>` | Decrypt age keys with passphrase and launch memory daemon |
| `lock` | none | Clear unlocked keys from memory and terminate daemon |
| `status` | none | Print key daemon status (`unlocked`, `locked`, `uninitialized`) |
| `rotate` | `--as <id>` | Rotate an agent's age encryption keypair |

```bash
spool key status
```

<a id="ws-doc-c75eb17e-c54d-41d8-8dfc-c5190bc8d626"></a>
### 5.5 spool keyd

Run the background daemon that holds unlocked workspace age keys in memory.

| Property | Value | Description |
|---|---|---|
| Input | standard input | Identity bundle provided over a non-terminal pipe |
| Arguments | none | Internal daemon started by `spool key unlock` |

```bash
spool key unlock --workspace 12345678-1234-1234-1234-123456789abc
```

<a id="ws-doc-ed0b28d6-2e3d-4f04-a5d0-539ca7cb7347"></a>
## 6 Fleet and coordination

The coordination subcommands manage distributed leases, lane registrations, hardware telemetry, issue tracking, and agent lifecycle configuration.

<a id="ws-doc-15217fed-1166-48b8-b1a6-c9a78cb64a8a"></a>
### 6.1 spool lease

Read or acquire role leases across the fleet via compare-and-set.

| Flag | Default | Description |
|---|---|---|
| `--fleet <slug>` | none | Fleet identifier (required) |
| `--role <role>` | none | Role identifier (e.g. `orch`, `dispatch`) (required) |
| `--holder <seat>` | none | Write mode: new holder identifier (`<id>@<box>`) |
| `--if-gen <n>` | `-1` | Write mode: required generation fence (`0` if currently unheld) |

```bash
spool lease --fleet default --role orch
```

<a id="ws-doc-200da7ef-dad0-4371-8ed2-b7106180d13f"></a>
### 6.2 spool lane

Query fleet lane allocations or register an agent's active workspace assignment.

| Flag | Default | Description |
|---|---|---|
| `--fleet <slug>` | none | Fleet identifier (required) |
| `--agent <id>` | none | Agent identifier (omit to list active lanes) |
| `--box <box_id>` | none | Machine box ID where the agent runs |
| `--repo <repo>` | none | Repository name |
| `--branch <branch>` | none | Active git branch |
| `--scope <scope>` | none | Single-line work scope summary |
| `--files <paths>` | none | Comma-separated paths owned by the lane |
| `--topic <uuid>` | none | Assigned topic task UUID |
| `--state <state>` | `live` | Lane lifecycle state: `live` or `done` |

```bash
spool lane --fleet default
```

<a id="ws-doc-6e9fcbf4-3faf-4ce3-9849-b26078bf9c5c"></a>
### 6.3 spool lifecycle

Retrieve agent lifecycle settings or append audit trail events.

| Subcommand | Flags | Description |
|---|---|---|
| `config` | none | Print active lifecycle settings as `KEY=VALUE` pairs |
| `event` | `--json <file\|-> [--fleet <f>]` | Append one JSON lifecycle event record |

```bash
spool lifecycle config
```

<a id="ws-doc-53959fcc-12ef-4329-a863-f2007d8e1a0a"></a>
### 6.4 spool memory

Access and append persistent organizational lessons learned in shared agent memory.

| Subcommand | Flags / Arguments | Description |
|---|---|---|
| `add` | `--title <t> --text <t\|->` | Add a lesson or merge into an existing lesson with the same title |
| `show` | `<title>` | Display complete text of a specific lesson |
| `index` | none | List all stored lesson titles and summary lines |

```bash
spool memory index
```

<a id="ws-doc-ffe3489a-8d29-4ad9-a6b4-fa6d0dd1f43f"></a>
### 6.5 spool box-stats

Record machine hardware telemetry or query historical fleet utilization samples.

| Subcommand | Flags | Description |
|---|---|---|
| `put` | `--json <file\|->` | Append one hardware utilization sample object |
| `list` | `[--box <b>] [--since <dur>]` | Query historical samples as JSON (default window: `24h`) |

```bash
spool box-stats list --since 12h
```

<a id="ws-doc-612a4371-0706-4e05-8f5b-e8927790f522"></a>
### 6.6 spool box-beat

Emit watchdog process heartbeats or inspect recent box liveness beats.

| Subcommand | Flags | Description |
|---|---|---|
| `put` | `--pid <n>` | Record a heartbeat for the specified watchdog PID |
| `list` | `[--box <b>] [--since <dur>]` | Query recent heartbeat records (default window: `10m`) |

```bash
spool box-beat put --pid 20541
```

<a id="ws-doc-8763ac13-803b-477f-b084-2362840987ff"></a>
### 6.7 spool fleet-load

Query current fleet concurrency limits or temporarily pause an agent category.

| Subcommand | Arguments | Description |
|---|---|---|
| `get` | none | Print fleet load targets, limits, and active pauses as JSON |
| `pause` | `<kind> <until RFC 3339> [reason]` | Pause a specific agent kind across all boxes |

```bash
spool fleet-load get
```

<a id="ws-doc-51a489be-2350-4be2-ae10-990dfc8dad63"></a>
### 6.8 spool issue

Track and advance development tasks, epics, subtasks, comments, and labels.

| Subcommand | Flags | Description |
|---|---|---|
| `list` | `[--epic <key>] [--kind <k>] [--status <s>] [--priority <p>] [--level <l>] [--assignee <a>] [--label <l>] [--deadline-before <t>] [--deadline-after <t>] [--sort <field>] [--limit <n>] [--cursor <c>]` | List issues matching filters |
| `get` | `--ref <key>` | Retrieve an issue by key (e.g. `SPL-1844`) |
| `create` | `--title <t> --discussions <ids> (--epic <key> \| --parent <key> \| --kind <k>) [--description <d> \| --description-file <f>] [--status <s>] [--priority <p>] [--level <l>] [--assignee <a>] [--labels <ids>] [--deadline <t>]` | Create a new issue |
| `update` | `--ref <key> [create flags...]` | Update fields on an existing issue |
| `comment` | `--ref <key> (--body <text> \| --body-file <f>)` | Post a comment on an issue |
| `label` | `--name <name> [--color <hex>]` | Create or update a label |
| `delete` | `--ref <key>` | Soft-delete an issue (creator only) |
| `archive` | `--ref <key> [--cascade]` | Archive an issue |
| `unarchive` | `--ref <key> [--cascade]` | Restore an archived issue |
| `link` | `--ref <key> --discussion <id>` | Link a topic to an issue |
| `unlink` | `--ref <key> --discussion <id>` | Unlink a topic from an issue |

All `spool issue` operations require `--as <agent>`.

```bash
spool issue list --as a-510 --status wip
```

<a id="ws-doc-a7ed55a5-fce6-4bc4-9e4b-67072bc530d6"></a>
### 6.9 spool layout

List all agent mailbox identifiers configured under the local spool root.

| Argument | Default | Description |
|---|---|---|
| none | none | Scans directories under `$SPOOL_ROOT` and prints one ID per line |

```bash
spool layout
```

<a id="ws-doc-018a95af-68d8-46e2-936c-4cf6183ac9b3"></a>
## 7 Box-to-hub sync and inspection

The box-to-hub subcommands synchronize local mailboxes with the hub, verify connectivity, and inspect remote topic state.

<a id="ws-doc-b87e8671-ab67-4c11-809a-ecbb727f2256"></a>
### 7.1 spool hub-pin

Register or revoke a box public signing key at the hub using a tenant root key.

| Flag | Default | Description |
|---|---|---|
| `--box <box_id>` | none | Box identifier to pin (required) |
| `--pubkey <base64>` | none | Base64-encoded box public key (required unless revoking) |
| `--root-key <path>` | none | Tenant root private key file, key text, or `-` for stdin |
| `--force` | `false` | Overwrite existing key pin at the hub |
| `--revoke` | `false` | Revoke the box's pin registration at the hub |

```bash
spool hub-pin --box box-a --pubkey "dGhpcy1pcy1hLXRlc3QtcHVibGljLWtleS0wMDAwMDAw" --root-key /secrets/tenant-root.key
```

<a id="ws-doc-6c25e794-9ebf-42d5-9d20-6b37d39c7470"></a>
### 7.2 spool hub-sync

Perform a single synchronization pass: flush outbox messages, fetch inbox updates, and reconcile pins.

| Flag | Default | Description |
|---|---|---|
| none | none | Requires `$SPOOL_HUB_URL` and provisioned box keys |

```bash
spool hub-sync
```

<a id="ws-doc-99ad69e9-5287-4a23-b5aa-dd6879444bf6"></a>
### 7.3 spool hub-run

Run the persistent box sidecar daemon that maintains synchronization with the hub.

| Flag | Default | Description |
|---|---|---|
| none | none | Connects to `$SPOOL_HUB_URL` and maintains delivery queues |

```bash
spool hub-run
```

<a id="ws-doc-64633768-5ef9-4b8c-a454-b44acc0f993a"></a>
### 7.4 spool hub-tail

Fetch and stream message records for a topic directly from the hub.

| Flag | Default | Description |
|---|---|---|
| `--task <uuid>` | none | Topic task UUID to inspect (required) |
| `--follow` | `false` | Stream new messages as they arrive |
| `--json` | `false` | Output raw `v:1` messages as NDJSON |

```bash
spool hub-tail --task 12345678-1234-1234-1234-123456789abc --follow
```

<a id="ws-doc-9b1c76b8-2386-40e2-bcd0-1ddbcb5b74db"></a>
### 7.5 spool hub-rsp

Count response (`RSP-*`) messages across all boxes in a hub topic.

| Flag | Default | Description |
|---|---|---|
| `--task <uuid>` | none | Topic task UUID to inspect (required) |

```bash
spool hub-rsp --task 12345678-1234-1234-1234-123456789abc
```

<a id="ws-doc-cf889fa9-4b18-4796-a91d-d0ad736b2009"></a>
### 7.6 spool hub-get-file

Download a file blob by its SHA-256 ID from the hub directly into local storage.

| Flag | Default | Description |
|---|---|---|
| `--file-id <sha256>` | none | SHA-256 identifier of the file to download (required) |

```bash
spool hub-get-file --file-id e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

<a id="ws-doc-9e0b25c0-0620-4c99-a7f2-3200887ad501"></a>
## 8 Hub administration

The hub administration subcommands run database migrations, start the server daemon, generate root keys, and manage tenant accounts and memberships.

<a id="ws-doc-82e00f6b-1a73-498d-8c68-ebd3012f284f"></a>
### 8.1 spool serve

Launch the spool hub HTTP and WebSocket service.

| Configuration | Source | Description |
|---|---|---|
| `SPOOL_HUB_DB_DSN` | Environment | PostgreSQL connection string (required) |
| `SPOOL_HUB_PORT` | Environment | HTTP listener port (default `8080`) |
| `SPOOL_HUB_ENV` | Environment | Deployment environment (`dev` or `prd`) |

```bash
SPOOL_HUB_DB_DSN="postgres://user:pass@127.0.0.1:5432/spool" spool serve
```

<a id="ws-doc-b224bb57-92a1-486a-bedf-ae2cd9461ebc"></a>
### 8.2 spool migrate

Apply schema migrations to the hub PostgreSQL database.

| Flag | Default | Description |
|---|---|---|
| `--db <dsn>` | `$SPOOL_HUB_DB_DSN` | PostgreSQL database connection string |
| `--sql-dir <path>` | `$SPOOL_HUB_MIGRATIONS_DIR` | Directory containing SQL schema migration files |
| `--dry-run` | `false` | Check before an upgrade, apply nothing (below) |

```bash
spool migrate --db "postgres://user:pass@127.0.0.1:5432/spool" --sql-dir ./migrations
```

`--dry-run` (SPL-2166) takes and releases the migrate advisory lock and
verifies the sha256 pin of every applied file. It then runs the pending
files, in filename order, in one transaction that is always rolled back. It
prints `ok` for each applied file and `pending <file> sha256 <hex>` for each
new one, and ends `dry run: <n> pending, ...; nothing applied`. A pin
mismatch, an empty file, or a file that does not parse or apply on this
schema exits non-zero and names the file. It never creates or writes
`spool_schema_migrations`. Until the rollback, the pending DDL holds the
same table locks a real run would.

```bash
spool migrate --dry-run --db "postgres://user:pass@127.0.0.1:5432/spool" --sql-dir ./migrations
```

<a id="ws-doc-cb9e97d1-1a11-4e08-aec9-84277c9f6c4a"></a>
### 8.3 spool root-keygen

Generate a new tenant root keypair and save the private key with restricted file permissions (`0600`).

| Flag | Default | Description |
|---|---|---|
| `--out <path>` | none | Destination filesystem path for the private key (required) |
| `--force` | `false` | Overwrite existing private key file |

```bash
spool root-keygen --out /secrets/tenant-root.key
```

<a id="ws-doc-de7f7ec0-b606-4787-a0c6-c04577760004"></a>
### 8.4 spool hub-tenant

Create a new workspace tenant in the hub database with its root public key.

| Flag | Default | Description |
|---|---|---|
| `--tenant <id>` | none | Tenant slug identifier (required) |
| `--root-pubkey <b64>` | none | Base64-encoded tenant root public key (required) |
| `--db <dsn>` | `$SPOOL_HUB_DB_DSN` | PostgreSQL database connection string |
| `--billing-status <s>` | `internal` | Initial billing status (`active`, `grace`, `unpaid`, `internal`, `manual`) |

```bash
spool hub-tenant --tenant acme --root-pubkey "dGhpcy1pcy1hLXRlc3QtcHVibGljLWtleS0wMDAwMDAw"
```

<a id="ws-doc-c3aba4ef-da3f-4b3c-827f-cd5d92230dc4"></a>
### 8.5 spool hub-tenant-billing

Update the billing lifecycle status of a workspace tenant.

| Flag | Default | Description |
|---|---|---|
| `--tenant <id>` | none | Tenant slug identifier (required) |
| `--event <event>` | none | Billing event: `paid`, `unpaid`, `failed`, `refund`, or `cancel` (required) |
| `--db <dsn>` | `$SPOOL_HUB_DB_DSN` | PostgreSQL database connection string |

```bash
spool hub-tenant-billing --tenant acme --event paid
```

<a id="ws-doc-b3124cd5-d7a5-467c-96f9-83b8fce11dd9"></a>
### 8.6 spool hub-invite

Create an invitation for an email address to join a workspace tenant.

| Flag | Default | Description |
|---|---|---|
| `--tenant <id>` | none | Tenant slug identifier (required) |
| `--email <addr>` | none | Recipient email address (required) |
| `--role <role_id>` | none | Role identifier to grant upon acceptance |
| `--db <dsn>` | `$SPOOL_HUB_DB_DSN` | PostgreSQL database connection string |
| `--ttl <dur>` | `168h` | Invitation expiration lifetime |
| `--no-mail` | `false` | Create invite in database without sending notification email |
| `--app-url <url>` | `$SPOOL_HUB_AUTH_APP_URL` | Application base URL for invitation link |
| `--default-locale <l>` | none | Default language locale for invitation email |

```bash
spool hub-invite --tenant acme --email user@example.com --role member
```

<a id="ws-doc-9bd57433-01a1-4aea-8814-80b3ec34d32b"></a>
### 8.7 spool hub-provision-member

Directly provision a workspace member in the database without sending invitation emails.

| Flag | Default | Description |
|---|---|---|
| `--tenant <id>` | none | Tenant slug identifier (required) |
| `--email <addr>` | none | Member email address (required) |
| `--name <name>` | none | Member display name |
| `--role <role_id>` | none | Role identifier to grant |
| `--db <dsn>` | `$SPOOL_HUB_DB_DSN` | PostgreSQL database connection string |
| `--ordered-by <admin>` | none | Administrative user ordering the provision |
| `--password-stdin` | `false` | Read initial user password from standard input |

```bash
spool hub-provision-member --tenant acme --email user@example.com --role member
```

<a id="ws-doc-ce4a883e-d0e4-4486-99d1-35aac9f0f340"></a>
### 8.8 spool hub-reset-password

Reset a user password from standard input and terminate active authentication sessions.

| Flag | Default | Description |
|---|---|---|
| `--email <addr>` | none | Account email address (required) |
| `--password-stdin` | `false` | Read replacement password from standard input (required) |
| `--tenant <id>` | none | Tenant slug identifier |
| `--db <dsn>` | `$SPOOL_HUB_DB_DSN` | PostgreSQL database connection string |

```bash
printf "secret-password" | spool hub-reset-password --email user@example.com --password-stdin
```

<a id="ws-doc-e21076f5-ede9-475b-a674-5f261d23bdc2"></a>
### 8.9 spool hub-invite-mail

Resend an invitation email for an active workspace invitation.

| Flag | Default | Description |
|---|---|---|
| `--tenant <id>` | none | Tenant slug identifier (required) |
| `--email <addr>` | none | Recipient email address (required) |
| `--db <dsn>` | `$SPOOL_HUB_DB_DSN` | PostgreSQL database connection string |
| `--app-url <url>` | `$SPOOL_HUB_AUTH_APP_URL` | Application base URL for invitation link |
| `--default-locale <l>` | none | Language locale for email template |
| `--min-gap <dur>` | `10m` | Minimum interval before allowing resend |
| `--max-sends <n>` | `5` | Maximum total email send attempts permitted |

```bash
spool hub-invite-mail --tenant acme --email user@example.com
```

<a id="ws-doc-1120a9b8-0ff1-4f68-b7ac-ac2cbb7c5c5a"></a>
### 8.10 spool version

Print the spool binary version, commit SHA, and build timestamp.

| Argument | Default | Description |
|---|---|---|
| none | none | Prints version, commit hash, and build timestamp to standard output |

```bash
spool version
```
