# 108 review: agy-2 opinion (stand-in for grok)

## 1. Verdict

**Ready to build.** The draft comprehensively addresses all isolation vectors outlined in the requirements.

## 2. Review of the Isolation Design

I have reviewed the isolation design specifically looking for potential leaks:
- **Shared OS users and dirs:** Addressed by Section 3.5. One box = one workspace, implemented with distinct OS user and spool root.
- **The relay bucket and its signed URLs:** Addressed by Section 3.4. Relay SA key never reaches a box, hub mints per-object signed URLs scoped under `<tenant_id>/`.
- **Sidecar keys:** Addressed by Section 3.1. Box generates its own private key, and the hub never mints it.
- **Hub routes skipping workspace pin:** Addressed by Section 3.3. Workspace identity is taken from the verified pin, `X-Spool-Tenant` mismatch is refused, and the anonymous view door is closed outside `lde`.
- **RLS without FORCE:** Addressed by Section 3.3. Postgres RLS with `FORCE` is mandated and structurally enforced.
- **Operator bypasses:** Addressed by Section 3.6. Operator scope is explicitly limited to verified and named `asOperator` callers.
- **Agent-id collisions across workspaces:** Addressed by Section 3.2. Box identifier is unique per workspace, public key uniqueness is enforced via a unique index on `pins(pubkey)`, and `pin_conflict` avoids leaking cross-workspace existence.
- **Revoke leaving keys alive:** Addressed by Section 3.7. Revocation reliably closes sockets, voids join tokens, and drops upload tokens, tightly bounded by the 5s pin cache TTL.
- **Tests passing with zero rows but no control:** Addressed by Section 4. Every isolation test explicitly pairs with a positive control to prove efficacy.

The design effectively seals the perimeter and establishes a secure boundary per workspace.

## 3. Owner Questions

The unresolved product decisions correctly identified in Section 7 do not impact the core security of the isolation design:
1. Is a second workspace on one machine allowed, as a second OS user + spool root?
2. Does the existing multi-workspace desk stay operator-only, with the workspaces it hosts not isolated from the operator on that box?
3. At revoke, are queued deliveries held for the admin or purged?

Consensus reached at e83aa15b051dae7578dc6449f58505162673d3e8
