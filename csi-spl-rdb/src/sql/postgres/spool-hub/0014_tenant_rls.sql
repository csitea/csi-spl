-- 0014_tenant_rls.sql — row level security on every tenant table (specs/017
-- FR-SEC-013, T019; SEC-08). Forward-only.
--
-- Defense in depth under the Go `WHERE tenant_id = $1`: a statement sees and
-- writes only the rows of the tenant named by the TRANSACTION-LOCAL setting
-- app.tenant_id (store.inTenant: set_config('app.tenant_id', $1, true)).
-- The one other path is app.rls_scope = 'operator' (store.asOperator, same
-- transaction-local form), used only by the retention sweep, the payment
-- webhook / checkout lookups (the tenant is unknown until the checkout row is
-- read) and `spool migrate`. A statement that sets neither sees ZERO rows:
-- fail closed.
--
-- FORCE is what makes the policies bind the hub login: it OWNS these tables
-- (`spool migrate` runs under the same DSN), and a table owner is otherwise
-- exempt. A superuser or a BYPASSRLS role still skips every policy, so the hub
-- must connect as neither (spool hub logs which it got).
--
-- Hub-wide tables without tenant_id stay outside RLS: humans,
-- human_identities, password_credentials, email_verification_tokens,
-- password_reset_tokens, webhook_events_seen, spool_schema_migrations.
--
-- Live-data safety: ALTER TABLE ... ROW LEVEL SECURITY and CREATE POLICY are
-- catalog-only (no rewrite, no data change; a brief ACCESS EXCLUSIVE lock
-- per table). DEPLOY ORDER: roll a hub image that sets the scope FIRST, then
-- apply this file; the other order hides every row from the running hub
-- until its roll (017 T023).

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'tenants', 'boxes', 'pins', 'pins_history', 'roster', 'messages', 'deliveries',
        'channels', 'channel_subscriptions', 'tenant_memberships', 'tenant_invites',
        'payment_checkouts'
    ] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = current_setting('app.tenant_id', true))
            WITH CHECK (tenant_id = current_setting('app.tenant_id', true))$p$, t);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, t);
    END LOOP;
END
$$;
