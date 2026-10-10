-- 0172_embed_staff.sql - the staff side of the visitor channels (specs/121
-- T106, sections 4.3, 4.4, 6). Forward-only, additive.
--
-- 1. embed_visitors.lead_at: the owner marked this visitor channel a lead
--    (spec 4.4). NULL = not a lead: the retention sweep removes the channel
--    30 days after its last message; a lead is kept.
-- 2. embed_visitors.blocked_at: the owner blocked the visitor from the
--    channel header (spec 6: token revoked, channel kept). The hub ends the
--    token in the same statement (expires_at); this column says why it
--    ended, for the staff list.
-- 3. The public dataset export (specs/091, fence 2 of rdb 0126) leaves out
--    every visitor channel, its messages and the visitor's membership
--    (spec 4.3): three RESTRICTIVE policies FOR SELECT TO spool_public_export
--    only, AND-ed with public_export_scope. The hub's roles are not that
--    role and see exactly what they saw before.
--    The export role holds no grant on embed_visitors (its column grants are
--    the 091 allow-list, nothing more), so the channels and messages
--    policies ask embed_visitor_channel(tenant, channel): a SECURITY DEFINER
--    sql function owned by the schema owner, search_path pinned, the body
--    naming public.embed_visitors, EXECUTE revoked from PUBLIC and granted
--    to the export role alone. It answers yes or no, never a row. FORCE RLS
--    binds its owner too, so it reads under the caller's settings: the
--    export sets app.tenant_id to the one workspace it reads. With neither a
--    tenant nor the operator scope set, tenant_scope hides every channel and
--    message anyway, so that case fails closed.
--    tenant_memberships needs no lookup: its role column says channel_guest.
--
-- Live-data safety: two nullable columns with no default (catalog-only); one
-- new function; CREATE POLICY is catalog-only but holds ACCESS EXCLUSIVE on
-- its table until COMMIT, hence lock_timeout. No deploy order: no running hub
-- reads the new columns, and no hub role is spool_public_export. Runs under
-- the operator RLS scope (spool migrate, rdb 0014). No personal data, no
-- secret.

SET LOCAL lock_timeout = '5s';

ALTER TABLE embed_visitors ADD COLUMN lead_at timestamptz NULL;
ALTER TABLE embed_visitors ADD COLUMN blocked_at timestamptz NULL;

CREATE FUNCTION public.embed_visitor_channel(p_tenant text, p_channel text)
    RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT EXISTS (SELECT 1 FROM public.embed_visitors v
                   WHERE v.tenant_id = p_tenant AND v.channel_id = p_channel)
$fn$;
REVOKE ALL ON FUNCTION public.embed_visitor_channel(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.embed_visitor_channel(text, text) TO spool_public_export;

CREATE POLICY public_export_no_visitors ON channels AS RESTRICTIVE
    FOR SELECT TO spool_public_export
    USING (NOT public.embed_visitor_channel(tenant_id, channel_id));
CREATE POLICY public_export_no_visitors ON messages AS RESTRICTIVE
    FOR SELECT TO spool_public_export
    USING (channel IS NULL OR NOT public.embed_visitor_channel(tenant_id, channel));
CREATE POLICY public_export_no_visitors ON tenant_memberships AS RESTRICTIVE
    FOR SELECT TO spool_public_export
    USING (role <> 'channel_guest');
