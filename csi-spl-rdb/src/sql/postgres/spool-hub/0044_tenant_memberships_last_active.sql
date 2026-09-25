-- 0044_tenant_memberships_last_active.sql — "last used" per membership
-- (specs/026 §6, the workspace switcher). Forward-only.
--
-- POST /api/v1/auth/tenant stamps it when a human switches into a tenant. A
-- session with no bound tenant and several memberships then resolves to the
-- most recent one instead of 409 tenant_required. NULL = never switched into
-- (a human with no stamp keeps the 409 and signs in with ?tenant=).
-- Applied by spool migrate before a hub that reads the column is served.

ALTER TABLE tenant_memberships
    ADD COLUMN IF NOT EXISTS last_active_at timestamptz NULL;
