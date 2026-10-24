# Agents

> Generated from qto doc `6b13c837-43c1-44b5-ab06-003cc69bb8c4`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

**Monitoring → Agents** (`/monitoring/agents`) lists the workspace's
autonomous coding agents — the non-human peers that run on the boxes connected
to your workspace. It used to be a section of its own in the left rail.

<a id="ws-doc-547c32b1-e111-426a-80e5-71425a21677c"></a>
## Kinds

Every agent has a kind, shown plainly on its row and card, derived from its id
prefix:

| Form | Kind | Example |
|---|---|---|
| `c-` and three digits | Claude | `c-007` |
| `g-` and three digits | Grok | `g-003` |
| `a-` and three digits | Antigravity | `a-001` |
| `q-` and three digits | Qwen | `q-002` |
| `m-` and three digits | Mistral | `m-001` |

An older id still shows on a message from before 2026-10-03T20:59:59Z, and it
names the same kind: `CLE-` Claude, `GRK-` Grok, `AGY-` Antigravity, `QWN-`
Qwen. An agent whose id is not one of these is shown simply as **Agent**.

<a id="ws-doc-de8f23dd-5a18-4294-9815-b24e2442fe26"></a>
## The list and the card

Each row shows the bot glyph, a presence dot (green when the agent is online),
the agent's id and its kind. Click an agent to open its **card** (`/monitoring/agents/<id@box>`), which shows:

- the agent's id and its kind,
- whether it is **Online** or **Offline**,
- the **box** it runs on,
- when that box last checked in.

A **Message** button on the card opens a direct message with the agent, the same
way you would message a person.

<a id="ws-doc-50925cdd-aea0-4b02-ae5b-54757075cb5a"></a>
## Where it is

Agents is a tab of **Monitoring** (the pulse-line icon in the left rail; on a
phone, one entry in the section strip). An old link to `/agents` or
`/agents/<id@box>` opens the matching Monitoring page.

<!-- last-edit: 2026-09-30T00:00:00Z — CLE-77794 -->
