# 108 review: agy-3 opinion (extra agy seat)

## 1. Verdict

**YES**. The design correctly seals the perimeter per workspace and resolves all critical attack vectors.

## 2. Review of the Isolation Design

I have attacked the isolation design looking for leaks across the specified vectors:
- **Shared OS users and dirs on a box**: Sealed. Section 3.5 mandates one box = one workspace, using a distinct OS user and spool root. This closes the local filesystem vector where an agent could read another workspace's keys or mailboxes.
- **The relay bucket and its signed URLs**: Sealed. Section 3.4 guarantees the relay service account key never reaches a box. The hub mints per-object signed URLs scoped under the hub-chosen `<tenant_id>/` prefix, preventing list, read, or delete attacks on other workspaces' objects.
- **Sidecar keys**: Sealed. Section 3.1 states that the box generates its own private key and the hub only pins the public half. The hub never mints a box private key.
- **Hub routes that skip the workspace pin**: Sealed. Section 3.3 enforces that the workspace identity is derived exclusively from the verified pin, rejecting header mismatches. The anonymous view door is also disabled outside `lde`.
- **RLS without FORCE**: Sealed. Section 3.3 mandates Postgres RLS with `FORCE`, leveraging the existing `tenant_id` and `app.tenant_id` implementation.
- **Operator bypasses**: Sealed. Section 3.6 limits the operator scope strictly to a verified list of named `asOperator` callers, with an empty `HubRoleCanLiftRLS` serving as the production start gate.
- **Agent-id collisions across workspaces**: Sealed. Section 3.2 scopes all spool messages by the box's workspace ID and mandates globally unique live public keys via a unique index on `pins(pubkey)`, preventing cross-workspace impersonation or conflict leaks.
- **Revoke that leaves keys alive**: Sealed. Section 3.7 ensures revocation comprehensively closes sockets, voids join tokens, drops upload tokens, and restricts visibility to the short 5s pin cache window.
- **Tests that pass with zero rows but no control**: Sealed. Section 4 explicitly pairs every isolation probe with a positive control test to ensure the failure is due to isolation and not a broken test setup.

## 3. Owner Questions

The owner questions listed in Section 7 remain open, but they represent product and operational policy decisions that do not compromise the integrity of this isolation architecture.

Consensus reached at e83aa15b051dae7578dc6449f58505162673d3e8
