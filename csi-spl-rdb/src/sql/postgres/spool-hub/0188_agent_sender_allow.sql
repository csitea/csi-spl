-- 0188_agent_sender_allow.sql - the per-agent sender allow-list (spec 044
-- FR-OS-017, T034, SPL-1018). Forward-only, additive.
--
-- Owner HUM-10, t1 dee4081d, msg e9ec66fa ("Ok" to the five picks of
-- 873c8aa0): a workspace admin keeps, per agent, the members who may send it
-- a direct message or @mention it. The hub refuses anyone else's with 403
-- sender_not_allowed and the agent never receives it.
--
-- Two tables, so "no list" and "an empty list" are different things:
--   agent_sender_lists  one row = the agent HAS a list (decision 2: an agent
--                       with no row takes messages from every member, which
--                       is the behaviour before this file)
--   agent_sender_allow  the members on that list, by HUM id. A list with no
--                       member row lets no member through.
-- A member who leaves the workspace leaves every list with it (the FK to
-- tenant_memberships cascades), and the list itself stays: removing the
-- last allowed member never reopens the agent to everyone.
--
-- Agents are keyed by their bare id (c-001, not c-001@sat): the list is per
-- agent in a workspace, whichever box it is seated on.

CREATE TABLE agent_sender_lists (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    agent_id   text        NOT NULL CHECK (length(agent_id) BETWEEN 1 AND 64 AND agent_id !~ '^(HUM|GST)-'),
    updated_by text        NOT NULL,
    updated_at timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, agent_id)
);

CREATE TABLE agent_sender_allow (
    tenant_id text        NOT NULL,
    agent_id  text        NOT NULL,
    human_id  text        NOT NULL,
    added_by  text        NOT NULL,
    added_at  timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, agent_id, human_id),
    FOREIGN KEY (tenant_id, agent_id) REFERENCES agent_sender_lists (tenant_id, agent_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, human_id) REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE
);
-- the membership cascade looks rows up by member
CREATE INDEX agent_sender_allow_human ON agent_sender_allow (tenant_id, human_id);

ALTER TABLE agent_sender_lists ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_sender_lists FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON agent_sender_lists
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON agent_sender_lists
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE agent_sender_allow ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_sender_allow FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON agent_sender_allow
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON agent_sender_allow
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
