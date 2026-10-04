-- 0113_membership_access_until.sql - a membership that expires (spec 072
-- A27, lane L26; guest rule R1: "scoped, revocable, expiring").
-- Forward-only.
--
--   access_until  the instant this membership stops granting access in its
--                 tenant. NULL = no end (every membership before this file).
--                 At or past it the hub reads the membership as absent, the
--                 same as a suspended one (0074 disabled_at): the door
--                 refuses the person's sign-in, their session and the agents
--                 acting as them, with 403. The row stays, so an admin still
--                 sees it on Tenant settings -> Members and can extend it,
--                 clear it or remove the member.
--
-- An invite's expires_at (0006) is how long the INVITE stays open; this is
-- how long the ACCESS lasts once accepted.
--
-- Nullable with no default: a catalog-only ADD COLUMN, no rewrite, and the
-- running image ignores it. RLS is unchanged: tenant_memberships already
-- ENABLE + FORCE it (0014, 0021), and a column needs no policy of its own.
-- DEPLOY ORDER: either order is safe. The hub probes the catalogue for this
-- column (store/access_until.go) and, until it is there, reads memberships
-- without it and answers 503 not_migrated to a write of it.

ALTER TABLE tenant_memberships
    ADD COLUMN IF NOT EXISTS access_until timestamptz NULL;
