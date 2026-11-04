-- 0260_netvisor_member_read.sql - every person seated in the workspace
-- READS its Netvisor figures; only the Netvisor owner writes them (spec 125
-- C7 as rewritten, SPL-4792; owner HUM-10, csitea topic 67c25538, poll
-- 2a767008, answer msg cfa78746: "WS - Every member of the csitea
-- workspace"; msg 91a1bc9a: "agents never see the figures" still holds).
-- Forward-only, idempotent: a second apply changes nothing. 0255, 0257 and
-- 0258 are not edited.
--
-- rdb 0255's RESTRICTIVE owner_scope (FOR ALL) is split, per table, into:
--
--   owner_insert / owner_update / owner_delete
--                 RESTRICTIVE, FOR INSERT / UPDATE / DELETE: 0255's
--                 owner_scope expression, unchanged. Only the owner (and,
--                 on netvisor_settings, the B5 ingest scope) writes: a
--                 member's settings PUT, "Refresh now" or snapshot insert
--                 still matches 0 rows or is refused (42501).
--   member_read   RESTRICTIVE, FOR SELECT: the owner's expression OR a
--                 person seat. A person seat is a live membership of
--                 app.human_id in the transaction's workspace (app.tenant_id):
--                 not disabled, not past its access_until (0113), its human
--                 not disabled and not technical (an act-as clone, 0088),
--                 not a channel guest, and at least one role of its set
--                 (the primary role plus tenant_member_roles, 0201) that is
--                 neither pure_agent nor time_accountant (the hub's
--                 realmNotPerson). On the three data tables a row still
--                 passes only when it is filed under the workspace's
--                 CURRENT owner (0255's EXISTS): a member reads the owner's
--                 snapshots, never a former owner's.
--
-- Who sets app.human_id is unchanged: store inNetvisorOwner, from an
-- authenticated person's browser session only (hub netvisorReader), never a
-- token, a desk, the operator, a migration or the Reporting SQL tab
-- (TestNetvisorHumanScopeCallers). Still NO operator_scope: the operator
-- scope, the ops psql and the Reporting SQL tab read 0 rows. The person
-- test (netvisor_person_seat, below) keys on app.tenant_id, not the row's
-- tenant_id; tenant_scope already pins every row to that workspace.
--
-- Live-data safety: CREATE / DROP POLICY is catalog-only but holds ACCESS
-- EXCLUSIVE on its table until COMMIT, hence lock_timeout; no row is
-- rewritten. The old hub keeps working: it reads as the owner, which both
-- policy sets pass. DEPLOY ORDER: wf 20 applies this before the hub whose
-- door lets members in; that hub on the old policies answers a member an
-- empty screen, never another's figures. No figure, id or account number
-- here.

SET LOCAL lock_timeout = '5s';

-- The person test lives in a function: a policy's inline subquery records a
-- dependency on every column it names, and one on
-- tenant_memberships.access_until would refuse the column's drop that
-- TestMemberAccessUntilBeforeMigration plays (a hub rolled before 0113). A
-- string body records none (the 0219 spool_agent_scope_ok pattern); it runs
-- as the caller, so tenant_memberships' own RLS still applies.
CREATE OR REPLACE FUNCTION public.netvisor_person_seat()
    RETURNS boolean
    LANGUAGE sql STABLE COST 1
    SET search_path = pg_catalog, public, pg_temp
AS $fn$
    SELECT EXISTS (SELECT 1 FROM public.tenant_memberships m JOIN public.humans h ON h.human_id = m.human_id
        WHERE m.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
          AND m.human_id = NULLIF(current_setting('app.human_id', true), '')
          AND m.disabled_at IS NULL AND h.disabled_at IS NULL AND NOT h.technical
          AND (m.access_until IS NULL OR m.access_until > now())
          AND m.role <> 'channel_guest'
          AND EXISTS (SELECT 1 FROM (SELECT m.role UNION ALL SELECT x.role_id FROM public.tenant_member_roles x
                                     WHERE x.tenant_id = m.tenant_id AND x.human_id = m.human_id) AS r (role)
                      WHERE r.role NOT IN ('pure_agent', 'time_accountant')))
$fn$;

DO $$
DECLARE
    t             text;
    owner         text;
    current_owner text;
    person        text := 'netvisor_person_seat()';
BEGIN
    FOREACH t IN ARRAY ARRAY['netvisor_settings', 'netvisor_snapshots', 'netvisor_forecast_items',
                             'netvisor_card_cost_lines'] LOOP
        current_owner := format($c$EXISTS (SELECT 1 FROM netvisor_settings s WHERE s.tenant_id = %1$I.tenant_id
                                 AND s.owner_human_id = %1$I.owner_human_id)$c$, t);
        IF t = 'netvisor_settings' THEN
            owner := $c$(owner_human_id = NULLIF(current_setting('app.human_id', true), '')
                     OR current_setting('app.rls_scope', true) = 'netvisor_ingest')$c$;
        ELSE
            owner := format($c$(owner_human_id = NULLIF(current_setting('app.human_id', true), '') AND %s)$c$, current_owner);
        END IF;
        EXECUTE format('DROP POLICY IF EXISTS owner_scope ON %I', t);
        EXECUTE format('DROP POLICY IF EXISTS owner_insert ON %I', t);
        EXECUTE format('CREATE POLICY owner_insert ON %1$I AS RESTRICTIVE FOR INSERT WITH CHECK (%2$s)', t, owner);
        EXECUTE format('DROP POLICY IF EXISTS owner_update ON %I', t);
        EXECUTE format('CREATE POLICY owner_update ON %1$I AS RESTRICTIVE FOR UPDATE USING (%2$s) WITH CHECK (%2$s)', t, owner);
        EXECUTE format('DROP POLICY IF EXISTS owner_delete ON %I', t);
        EXECUTE format('CREATE POLICY owner_delete ON %1$I AS RESTRICTIVE FOR DELETE USING (%2$s)', t, owner);
        EXECUTE format('DROP POLICY IF EXISTS member_read ON %I', t);
        IF t = 'netvisor_settings' THEN
            EXECUTE format('CREATE POLICY member_read ON %1$I AS RESTRICTIVE FOR SELECT USING (%2$s OR %3$s)', t, owner, person);
        ELSE
            EXECUTE format('CREATE POLICY member_read ON %1$I AS RESTRICTIVE FOR SELECT USING (%2$s OR (%3$s AND %4$s))',
                           t, owner, person, current_owner);
        END IF;
    END LOOP;
END
$$;
