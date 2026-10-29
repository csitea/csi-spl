-- 0240_workspace_system_events.sql - the Workspace and System logs of the
-- event log (spec 162 v1.0 section 3.1, build row B3, SPL-4167; owner
-- HUM-10, t1 cfaa3dce, msg c7769644: "the admins should also see events
-- which are not personal but concerning the whole workspace or the whole
-- system"). Forward-only, additive, idempotent. The spec names "the next
-- free number at build time": the next prefix on master when it lands
-- (renumbered on rebase).
--
--   workspace_events  what changed in one workspace (members, channels,
--                     boxes, join tokens). A tenant table: the 0237 RLS
--                     shape, tenant_scope with NULLIF + operator_scope; a
--                     statement without a tenant reads and writes no row
--                     (spec 162 C10). Read and deleted by the workspace's
--                     owner and admins only (the hub's check). The hub keeps
--                     the newest 5000 rows per workspace, trimmed on insert.
--   system_events     what the hub and the fleet did (lease handovers, hub
--                     start). Hub-wide like human_events (0045): no
--                     tenant_id, outside RLS (0014 lists the hub-wide
--                     tables). Read and deleted by the admins of the
--                     operator workspace only. The hub keeps the newest
--                     10000 rows, trimmed on insert.
--
-- Both tables share one column set. kind is a dotted name checked by
-- pattern, not a closed list: a new producer needs no migration (the hub's
-- Go holds the kinds it writes, store/log_events.go). message is English
-- text the hub builds from fixed templates plus ids: never a message body,
-- an email address or a secret. origin_kind / origin_ref say where an entry
-- came from (spec 162 E6): both empty, or both set. The id primary key
-- serves the newest-first page of system_events; (tenant_id, id DESC)
-- serves workspace_events'. The runtime grants come from the default
-- privileges of spool-hub-roles/runtime-grants.sql, as every table since 017.
-- DEPLOY ORDER: wf 20 applies this file before it rolls the hub that reads
-- or writes either table.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS workspace_events (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    at          timestamptz NOT NULL DEFAULT now(),
    kind        text        NOT NULL CHECK (kind ~ '^[a-z]+(\.[a-z_]+)+$' AND length(kind) <= 48),
    level       text        NOT NULL DEFAULT 'info' CHECK (level IN ('info', 'warn', 'error')),
    actor       text        NOT NULL DEFAULT '' CHECK (length(actor) <= 64),
    message     text        NOT NULL DEFAULT '' CHECK (length(message) <= 800),
    origin_kind text        NOT NULL DEFAULT '' CHECK (origin_kind IN ('', 'msg', 'topic', 'issue', 'component')),
    origin_ref  text        NOT NULL DEFAULT '' CHECK (length(origin_ref) <= 120),
    CONSTRAINT ck_workspace_events_origin CHECK ((origin_kind = '') = (origin_ref = ''))
);
CREATE INDEX IF NOT EXISTS ix_workspace_events_tenant_id
    ON workspace_events (tenant_id, id DESC);

CREATE TABLE IF NOT EXISTS system_events (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at          timestamptz NOT NULL DEFAULT now(),
    kind        text        NOT NULL CHECK (kind ~ '^[a-z]+(\.[a-z_]+)+$' AND length(kind) <= 48),
    level       text        NOT NULL DEFAULT 'info' CHECK (level IN ('info', 'warn', 'error')),
    actor       text        NOT NULL DEFAULT '' CHECK (length(actor) <= 64),
    message     text        NOT NULL DEFAULT '' CHECK (length(message) <= 800),
    origin_kind text        NOT NULL DEFAULT '' CHECK (origin_kind IN ('', 'msg', 'topic', 'issue', 'component')),
    origin_ref  text        NOT NULL DEFAULT '' CHECK (length(origin_ref) <= 120),
    CONSTRAINT ck_system_events_origin CHECK ((origin_kind = '') = (origin_ref = ''))
);

ALTER TABLE workspace_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_events FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON workspace_events;
CREATE POLICY tenant_scope ON workspace_events
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON workspace_events;
CREATE POLICY operator_scope ON workspace_events
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
