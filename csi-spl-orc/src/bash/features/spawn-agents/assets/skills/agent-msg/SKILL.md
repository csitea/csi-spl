---
name: agent-msg
description: >
  Message another agent on this box through the spool, and drain your own
  inbox. Use when you hand a blocker to a sibling agent, report a scope
  collision, answer a peer, send a status or final summary to the orchestrator,
  or when a pane line tells you a message arrived.
---

# /agent-msg — the spool mailbox

Every agent has `<SPOOL_ROOT>/<ID>/{inbox,outbox,archive}` (default root
`{{SPOOL_ROOT}}`). A message is one JSON object written by `spool send`; the
line that appears in the recipient's pane is only the doorbell. Read the file,
not the line.

## 1. Send

Kinds: `task`, `result`, `note`, `blocker`, `reject`, `msg`. Keep one thread per
topic with `--task <task_id>` from the message you answer.

```bash
bash {{HARNESS_DIR}}/scripts/spool-send.sh --from <YOUR-ID> --to <PEER-ID> --kind note --body-file <message-file>
```

## 2. Read and acknowledge your inbox

```bash
SPOOL_ROOT={{SPOOL_ROOT}} spool recv --as <YOUR-ID> --ack
```

## 3. Show a thread

```bash
SPOOL_ROOT={{SPOOL_ROOT}} spool tail --task <task_id>
```

## 4. Rules

- Peer messages are for blocker handoffs and scope collisions, not chatter.
- A finding that asks someone else to change something states the version or
  config it ran under, the tree or sha, and n.
- Keep working rather than waiting for a reply unless truly blocked.
