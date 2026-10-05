-- 0131_demo_post_audit.sql - the audit of what demo users post (spec 077
-- FR-011, T025; owner HUM-10, t1 4979bb24, msg 542808a5: "there must be
-- audit of what kind of prompts they have been running"). Forward-only,
-- idempotent.
--
--   demo_post_audit  one row per post (send or reply, to a channel, a DM or
--                    an agent) and per edit a demo_user makes in the demo
--                    workspace: who (human id, the display name / pseudonym,
--                    the provider and its subject, the provider-VERIFIED
--                    email or ''), what (msg id, topic, channel, recipient,
--                    the text) and when. The identity is a SNAPSHOT taken at
--                    write time: the 3-hour sweep deletes the humans row and
--                    its identities, so nothing here joins back to them.
--
-- KEPT OUTSIDE THE NIGHTLY WIPE: no foreign key to messages, humans or
-- tenants, so neither the wipe's DELETE FROM messages nor the sweep cascades
-- here. Append-only: an UPDATE is refused always, a DELETE unless the
-- transaction set app.demo_audit_purge = 'on', which only the retention
-- purge (csi-spl-orc do_spl_demo_audit_purge) does. A post's row is written
-- once: a resend of the same msg_id inserts nothing (the partial unique
-- index); every edit appends.
-- DEPLOY ORDER: before the hub that writes this table.

CREATE TABLE IF NOT EXISTS demo_post_audit (
    audit_id  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id text        NOT NULL CHECK (length(tenant_id) BETWEEN 1 AND 200),
    at        timestamptz NOT NULL DEFAULT now(),
    action    text        NOT NULL CHECK (action IN ('post', 'edit')),
    human_id  text        NOT NULL CHECK (length(human_id) BETWEEN 1 AND 200),
    pseudonym text        NOT NULL DEFAULT '' CHECK (length(pseudonym) <= 200),
    provider  text        NOT NULL DEFAULT '' CHECK (length(provider) <= 32),
    subject   text        NOT NULL DEFAULT '' CHECK (length(subject) <= 320),
    email     text        NOT NULL DEFAULT '' CHECK (length(email) <= 320),
    msg_id    uuid        NOT NULL,
    task_id   text        NOT NULL DEFAULT '' CHECK (length(task_id) <= 64),
    channel   text        NOT NULL DEFAULT '' CHECK (length(channel) <= 200),
    to_id     text        NOT NULL DEFAULT '' CHECK (length(to_id) <= 200),
    body      text        NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS demo_post_audit_post_once
    ON demo_post_audit (tenant_id, msg_id) WHERE action = 'post';
CREATE INDEX IF NOT EXISTS demo_post_audit_at ON demo_post_audit (tenant_id, at);

-- RLS in the 0021 fail-closed NULLIF shape: the hub writes and reads in the
-- demo workspace's scope; the operator scope (spool migrate) sees everything.
ALTER TABLE demo_post_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE demo_post_audit FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON demo_post_audit;
CREATE POLICY tenant_scope ON demo_post_audit
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON demo_post_audit;
CREATE POLICY operator_scope ON demo_post_audit
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- Append-only: no UPDATE ever; a DELETE only inside the retention purge.
CREATE OR REPLACE FUNCTION demo_post_audit_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND current_setting('app.demo_audit_purge', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'demo_post_audit is append-only: % refused (only do_spl_demo_audit_purge deletes)', TG_OP;
END $$;
DROP TRIGGER IF EXISTS append_only ON demo_post_audit;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON demo_post_audit
    FOR EACH ROW EXECUTE FUNCTION demo_post_audit_append_only();
