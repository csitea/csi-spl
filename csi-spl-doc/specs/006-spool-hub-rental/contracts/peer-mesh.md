# Contract: Peer mesh (any agent commands any agent)

Binding prose: `doc/md/SPEC-spool-hub-rental.md` §3.1 and
`doc/md/SPEC-spool-task-lifecycle.md` §2.1.

Hub MUST accept `kind=task` from any agent on a pinned box (`from_box`) to any well-formed `to`
in the same tenant. Prefix (`CLE`/`GRK`/`AGY`/`HUM`) MUST NOT change
authorisation. The hub MUST NOT parse `body`.

Self-send (`from == to`) is allowed.

Unicast: one `to`. Two targets = two messages.

Spool delivers. The receiving agent process is what “runs the command.”

## Status (trunk `bbc41e7`, 2026-09-18)

- No prefix ACL and no `body` parsing on the hub send path (003 send frame):
  **Implemented** — two-box `task`/`result` both ways in `hub-e2e.tst.sh`.
- Self-send: **Implemented** — same-box, local by default (trust-modes;
  `hub-e2e.tst.sh` self-send `delivery=local`).
- Three-peer ring A→B→C→A with GRK/CLE/AGY prefixes: **Planned** (T011b).

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:05:25Z -->
