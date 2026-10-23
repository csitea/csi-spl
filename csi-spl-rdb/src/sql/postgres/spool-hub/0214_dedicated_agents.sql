-- 0214_dedicated_agents.sql - dedicated agents and private scopes: the
-- table, the private-scope flags and the agent row level security
-- (specs/144 T001, sections 3.1 to 3.3). Forward-only, additive. The
-- prefix is the next free one when it landed, not tasks.md's stale 0202.
--
-- 1. dedicated_agents: one agent (agent_id on box_id) bound to ONE scope of
--    its workspace, a channel (scope_id = channels.channel_id) or a topic
--    (scope_id = messages.task_id as text). The primary key is the agent:
--    one agent, one scope (spec 14 Q1 A, a rebind is a new agent).
--    idx_dedicated_agents_scope serves "who is dedicated to this scope"
--    (the routing of T003, the sweep exclusion of spec 5.3).
-- 2. channels.is_private_scope / private_scope_at, messages.is_private_scope:
--    the flags the owner sets (spec 5.1). Constant defaults: catalog-only,
--    no table rewrite.
-- 3. The agent rule, setting app.agent_id + app.agent_box (transaction-local,
--    like app.tenant_id and app.channel_scope). Unset or '' (the NULLIF
--    guard of rdb 0021) means no agent session: every policy below is TRUE,
--    so a human, staff or operator session is unchanged (spec 3.3: humans
--    keep the member policies). Set, spool_agent_scope_ok decides a message:
--      - an agent with a binding (a dedicated agent) reads only its scope:
--        channel = its channel scope_id, or task_id = its topic scope_id;
--      - any other agent reads no private row: messages.is_private_scope,
--        or a message of a channel with channels.is_private_scope.
--    A set app.agent_id with no app.agent_box matches no binding, so it
--    reads like a non-dedicated agent: fails closed.
--    messages:         RESTRICTIVE agent_scope, USING and WITH CHECK, TO
--                      spool_channel_scoped (rdb 0197): never the search
--                      reader, whose `@@` a restrictive policy would keep
--                      out of the GIN index; the hub re-reads its ids as
--                      the runtime login under this policy.
--    deliveries:       RESTRICTIVE agent_scope through the delivery's
--                      message, the same function spelled out (not via the
--                      messages policy), TO public.
--    dedicated_agents: tenant_scope + operator_scope (the 0014/0021 shape),
--                      plus RESTRICTIVE: an agent session reads only its own
--                      binding and writes none (a worker cannot bind itself
--                      to a private scope); binding is the hub's, unscoped.
--    The unset test is spelled CASE ... END IS NOT NULL, not
--    NULLIF(...) IS NULL, for the planner estimate (rdb 0169 point 5).
--
-- No running hub sets app.agent_id yet (T002 does), so on deploy every new
-- policy is TRUE: no deploy order. lock_timeout 5s: ALTER TABLE and CREATE
-- POLICY hold ACCESS EXCLUSIVE on messages until COMMIT; on a busy table the
-- file fails fast instead of queueing every write behind it. Runs under the
-- operator RLS scope (spool migrate, rdb 0014). Runtime grants: the default
-- privileges of spool-hub-roles/runtime-grants.sql. No personal data, no
-- secret.
-- Test: csi-spl-rdb/src/bash/tests/dedicated-agents-rls.tst.sh (as the
-- runtime login, never a superuser).

SET LOCAL lock_timeout = '5s';

CREATE TABLE dedicated_agents (
    tenant_id  text        NOT NULL,
    agent_id   text        NOT NULL CHECK (length(agent_id) BETWEEN 1 AND 64),
    box_id     text        NOT NULL CHECK (length(box_id) BETWEEN 1 AND 64),
    scope_type text        NOT NULL,
    scope_id   text        NOT NULL,
    bound_by   text        NOT NULL CHECK (length(bound_by) BETWEEN 1 AND 64),
    bound_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_dedicated_agents PRIMARY KEY (tenant_id, agent_id, box_id),
    CONSTRAINT fk_dedicated_agents_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT chk_dedicated_scope_type CHECK (scope_type IN ('channel', 'topic')),
    -- A channel id as rdb 0002 spells it; a topic is a task uuid, lower
    -- case. Per type, so a bad scope_type fails chk_dedicated_scope_type.
    CONSTRAINT chk_dedicated_scope_id CHECK (
        (scope_type <> 'channel' OR scope_id ~ '^[a-z0-9][a-z0-9-]{0,63}$')
        AND (scope_type <> 'topic' OR scope_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
);

CREATE INDEX idx_dedicated_agents_scope ON dedicated_agents (tenant_id, scope_type, scope_id);

ALTER TABLE channels ADD COLUMN is_private_scope boolean NOT NULL DEFAULT false;
ALTER TABLE channels ADD COLUMN private_scope_at timestamptz NULL;
ALTER TABLE messages ADD COLUMN is_private_scope boolean NOT NULL DEFAULT false;

-- May the agent session (app.agent_id on app.agent_box) read or write a
-- message of tenant p_tenant in channel p_channel (NULL = a DM), topic
-- p_task, flagged p_private? SECURITY INVOKER: it reads dedicated_agents and
-- channels under the caller's own policies. Called only from the policies
-- below, after their unset guard. COST 1: a session without an agent never
-- calls it (the guard is TRUE first), so the planner should not price every
-- messages row at the default 100 and re-plan the unread reads.
CREATE FUNCTION public.spool_agent_scope_ok(p_tenant text, p_channel text, p_task uuid, p_private boolean)
    RETURNS boolean
    LANGUAGE sql STABLE COST 1
    SET search_path = pg_catalog, public, pg_temp
AS $fn$
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM public.dedicated_agents d
                     WHERE d.tenant_id = p_tenant
                       AND d.agent_id = current_setting('app.agent_id', true)
                       AND d.box_id = current_setting('app.agent_box', true))
        THEN EXISTS (SELECT 1 FROM public.dedicated_agents d
                     WHERE d.tenant_id = p_tenant
                       AND d.agent_id = current_setting('app.agent_id', true)
                       AND d.box_id = current_setting('app.agent_box', true)
                       AND ((d.scope_type = 'channel' AND d.scope_id = p_channel)
                         OR (d.scope_type = 'topic' AND d.scope_id = p_task::text)))
        ELSE NOT (p_private OR EXISTS (SELECT 1 FROM public.channels c
                                       WHERE c.tenant_id = p_tenant AND c.channel_id = p_channel
                                         AND c.is_private_scope))
    END
$fn$;

ALTER TABLE dedicated_agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE dedicated_agents FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON dedicated_agents
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON dedicated_agents
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

DO $$
DECLARE
    unscoped text := $u$CASE WHEN NULLIF(current_setting('app.agent_id', true), '') IS NULL THEN 1 END IS NOT NULL$u$;
    msg_ok   text := $m$EXISTS (SELECT 1 FROM messages m
                               WHERE m.tenant_id = deliveries.tenant_id AND m.msg_id = deliveries.msg_id
                                 AND spool_agent_scope_ok(m.tenant_id, m.channel, m.task_id, m.is_private_scope))$m$;
BEGIN
    EXECUTE format($p$CREATE POLICY agent_scope ON messages AS RESTRICTIVE TO spool_channel_scoped
        USING (%1$s OR spool_agent_scope_ok(tenant_id, channel, task_id, is_private_scope))
        WITH CHECK (%1$s OR spool_agent_scope_ok(tenant_id, channel, task_id, is_private_scope))$p$, unscoped);
    EXECUTE format($p$CREATE POLICY agent_scope ON deliveries AS RESTRICTIVE
        USING (%1$s OR %2$s)
        WITH CHECK (%1$s OR %2$s)$p$, unscoped, msg_ok);
    EXECUTE format($p$CREATE POLICY agent_scope ON dedicated_agents AS RESTRICTIVE FOR SELECT
        USING (%1$s OR (agent_id = current_setting('app.agent_id', true)
                        AND box_id = current_setting('app.agent_box', true)))$p$, unscoped);
    EXECUTE format($p$CREATE POLICY agent_no_insert ON dedicated_agents AS RESTRICTIVE FOR INSERT
        WITH CHECK (%1$s)$p$, unscoped);
    EXECUTE format($p$CREATE POLICY agent_no_update ON dedicated_agents AS RESTRICTIVE FOR UPDATE
        USING (%1$s) WITH CHECK (%1$s)$p$, unscoped);
    EXECUTE format($p$CREATE POLICY agent_no_delete ON dedicated_agents AS RESTRICTIVE FOR DELETE
        USING (%1$s)$p$, unscoped);
END
$$;
