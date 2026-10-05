-- 0128_message_moderation.sql - a moderator's hide of one message (spec 077
-- 3.6 "report / moderation", T016 part A). Forward-only, idempotent.
--
-- The report itself is a reaction: the hub's report glyph in
-- message_reactions (rdb 0037), so one reporter counts once by that table's
-- primary key. This table holds the DECISION:
--
--   message_moderation  one row per (tenant, msg): hidden or not, who set it
--                       and when. The third distinct reporter inserts
--                       (hidden, set_by 'reports') only while no row exists;
--                       a moderator (members.invite) upserts hidden true or
--                       false, so a moderator's unhide sticks against the
--                       reports already counted.
--
-- A hidden message is left out of every read a member without the
-- moderation permission makes in the demo workspace (hub/demo_moderation.go)
-- and stays readable, marked, for the moderators. The row goes with its
-- message (ON DELETE CASCADE: the nightly wipe, an author delete). A write
-- here changes what the stamped views answer, so it bumps the tenant change
-- stamp like message_reactions (rdb 0103).
-- DEPLOY ORDER: before the hub that writes this table.

CREATE TABLE IF NOT EXISTS message_moderation (
    tenant_id text        NOT NULL,
    msg_id    uuid        NOT NULL,
    hidden    boolean     NOT NULL,
    set_by    text        NOT NULL CHECK (length(set_by) BETWEEN 1 AND 200),
    set_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, msg_id),
    FOREIGN KEY (tenant_id, msg_id) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE
);

-- RLS in the 0021 fail-closed NULLIF shape, like message_reactions.
ALTER TABLE message_moderation ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_moderation FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON message_moderation;
CREATE POLICY tenant_scope ON message_moderation
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON message_moderation;
CREATE POLICY operator_scope ON message_moderation
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

DROP TRIGGER IF EXISTS change_stamp ON message_moderation;
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON message_moderation
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
