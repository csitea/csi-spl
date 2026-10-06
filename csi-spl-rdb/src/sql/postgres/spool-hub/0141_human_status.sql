-- 0141_human_status.sql - a member's manual status in one workspace: "Busy",
-- "Unavailable until 14:00", with an optional note. Forward-only.
--
-- Spec 096 section 7.2 (the spec drafted it as 0134; that number was taken
-- before it landed). A member's ask (HUM-24, t1 3ea05d6c, msg 13205fb5): mark
-- my account as unavailable at a given moment, visible to the other users.
-- Owner go: HUM-10, msg cb7a9cec (accept the proposals, section 12).
--
--   human_status   one row per (workspace, member) with a live status.
--                  "available" is NO row: clearing deletes it, so most members
--                  never have one. A row whose until_at <= now() reads as
--                  available everywhere (expiry on read); the hub's sweep
--                  deletes it. No history (Q8): nothing archives a cleared row.
--                  set_by is the member's own id today (Q5: agents do not set
--                  a status); kept so a later "set from my calendar" needs no
--                  migration. pause_notify is the picker's "Pause my
--                  notifications while unavailable" (Q1, off by default); it
--                  only acts while status = 'unavailable' (spec section 6).
--
-- Per workspace (Q2): the key is the membership, so a workspace never sees a
-- status set in another one, and leaving a workspace removes the row.
-- The 90-day limit on until_at (Q6) is the hub's write check, not a CHECK
-- here: a constant against now() is not immutable.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply on dev AND prd BEFORE the hub that reads it (spec 096 L2).

CREATE TABLE human_status (
    tenant_id  text        NOT NULL,
    human_id   text        NOT NULL,
    status     text        NOT NULL CHECK (status IN ('busy', 'unavailable')),
    note       text        CHECK (note IS NULL OR char_length(note) <= 80),
    until_at   timestamptz,
    pause_notify boolean   NOT NULL DEFAULT false,
    set_at     timestamptz NOT NULL DEFAULT now(),
    set_by     text        NOT NULL,
    PRIMARY KEY (tenant_id, human_id),
    FOREIGN KEY (tenant_id, human_id) REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE
);

-- the expiry sweep: rows that clear themselves
CREATE INDEX human_status_until ON human_status (until_at) WHERE until_at IS NOT NULL;

-- RLS in the 0106 shape, with the empty-setting guard (NULLIF).
ALTER TABLE human_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE human_status FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON human_status
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON human_status
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
