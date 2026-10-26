---
name: agent-msg
description: >
  Message another agent on this box through the spool, and drain your own
  inbox. Use when you hand a blocker to a sibling agent, report a scope
  collision, answer a peer, send a status or final summary to the orchestrator,
  or when a pane line tells you a message arrived.
---

# /agent-msg — the spool mailbox

> Generated from qto doc `0333781d-e168-425f-aab5-b7361d74d00f`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Every agent has `<SPOOL_ROOT>/<ID>/{inbox,outbox,archive}` (default root
`{{SPOOL_ROOT}}`). A message is one JSON object written by `spool send`; the
line that appears in the recipient's pane is only the doorbell. Read the file,
not the line.

<a id="ws-doc-15da0a3d-e155-4487-a6a9-385c909e468e"></a>
## 1. Send

Kinds: `task`, `result`, `note`, `blocker`, `reject`, `msg`. Keep one thread per
topic with `--task <task_id>` from the message you answer.

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-send.sh --from <YOUR-ID> <PEER-ID> --kind note --file <message-file>
```

<a id="ws-doc-184eece7-cabe-444d-a11f-e1df894231c6"></a>
## 2. Read and acknowledge your inbox

```bash
SPOOL_ROOT={{SPOOL_ROOT}} spool recv --as <YOUR-ID> --ack
```

<a id="ws-doc-da7ff1e3-ec50-4230-b8af-10ca6996eff5"></a>
## 3. What was sent to you and not seen yet

```bash
SPOOL_ROOT={{SPOOL_ROOT}} bash {{HARNESS_DIR}}/scripts/agent-inbox.sh --as <YOUR-ID>
```

<a id="ws-doc-165f1955-87e9-4e21-90f4-b018c6b556de"></a>
## 4. Show a thread

```bash
SPOOL_ROOT={{SPOOL_ROOT}} spool tail --task <task_id>
```

<a id="ws-doc-d445a75f-ee3e-4132-a039-d6081964b8af"></a>
## 5. Rules

- Peer messages are for blocker handoffs and scope collisions, not chatter.
- A finding that asks someone else to change something states the version or
  config it ran under, the tree or sha, and n.
- Keep working rather than waiting for a reply unless truly blocked.
