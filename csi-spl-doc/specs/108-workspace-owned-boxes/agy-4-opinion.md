# 108 review: agy-4 opinion (extra agy seat)

## 1. Verdict

**Ready to build.** I have reviewed the design against e83aa15b. The design thoroughly addresses the isolation vectors and prevents another workspace from seeing a box's files, spool dirs, inbox, keys, or logs, and from reading its messages in the hub DB.

## 2. Review of the Isolation Vectors

- **Shared OS users and dirs on a box:** Closed. Section 3.5 correctly asserts one box equals one workspace. Enforcing a distinct OS user, spool root, and state dir prevents lateral movement on the box.
- **Relay bucket and signed URLs:** Closed. Section 3.4 ensures the relay SA key never reaches a box. Hub-minted, short-lived signed URLs scoped under `<tenant_id>/` prevent bucket-wide access.
- **Sidecar keys:** Closed. Section 3.1 states the box generates its own private key and the hub only pins the public half.
- **Hub routes skipping workspace pin:** Closed. Section 3.3 mandates the workspace is determined from the verified pin, rejecting header/pin mismatches and disabling the anonymous view door outside lde.
- **RLS without FORCE:** Closed. Section 3.3 enforces Postgres RLS with FORCE for all tenant tables, relying on `tenant_id` and `app.tenant_id`.
- **Operator bypasses:** Closed. Section 3.6 limits operator visibility to named `asOperator` callers and requires `HubRoleCanLiftRLS` to answer empty as a production start gate.
- **Agent-id collisions across workspaces:** Closed. Section 3.2 uses a unique index on live `pins(pubkey)` to prevent pinning the same key across workspaces, and generic `pin_conflict` responses prevent leaking presence info.
- **Revoke leaving keys alive:** Closed. Section 3.7 implements a thorough revocation process: updating DB state, closing live sockets, dropping upload tokens, voiding join tokens, bounded by a 5s pin cache TTL.
- **Tests with zero rows but no control:** Closed. Section 4 pairs every negative test with a positive control to guarantee test validity.

## 3. Owner Questions

The three owner questions in Section 7 (second workspace per machine, operator-hosted multi-workspace desk, and queued deliveries at revoke) are appropriate product decisions that do not compromise the foundational isolation rules established in the spec. Build awaits the owner's answers.

Consensus reached at e83aa15b
