# Contract: Peer mesh (any agent commands any agent)

Binding prose: `doc/md/SPEC-spool-hub-rental.md` §3.1 and
`doc/md/SPEC-spool-task-lifecycle.md` §2.1.

Hub MUST accept `kind=task` from any pinned `from` to any well-formed `to`
in the same tenant. Prefix (`CLE`/`GRK`/`AGY`/`HUM`) MUST NOT change
authorisation. The hub MUST NOT parse `body`.

Self-send (`from == to`) is allowed.

Unicast: one `to`. Two targets = two messages.

Spool delivers. The receiving agent process is what “runs the command.”

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:25:00Z -->
