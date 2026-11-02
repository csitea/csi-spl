-- 0251_channel_move_audit_door.sql - two things P4 of a channel move needs
-- (spec 169 section 8.2, build row T5, SPL-4595): the one door through the
-- three append-only guards (decided by the orchestrator, msg 0c8a87ea, on ask
-- e5e61c6c), and a journal row that may come home (msg dd7b5039). Forward-only,
-- idempotent.
--
-- The catalogue moves usage_events, sql_query_audit and demo_post_audit rows
-- about the channel to <DST>. A move is insert-then-delete (F5), and these
-- guards refused the delete: the first two allow one only inside a tenant
-- cascade, the third only inside its retention purge. So one such row made
-- every move of that channel roll back. The rows are not lost: P4 inserts each
-- under <DST> in the same transaction before its <SRC> delete.
--
-- A DELETE passes only when app.channel_move = 'on' AND app.rls_scope =
-- 'operator'. P4 sets the first with set_config(..., true), so it ends with the
-- transaction. An UPDATE stays refused always. The tenant cascade door and the
-- demo purge door are unchanged and serve only what they served.
-- ck_channel_move_journal_src is dropped: a journal row's tenant_id is where
-- the row lives now and src_tenant_id is where that move started, and the two
-- meet when a channel moves back home (A to B, then B to A: 5.1 treats that as
-- a real state, and the catalogue carries the first journal row with it).
-- With the CHECK, every such move rolled back. A new move with <SRC> = <DST>
-- stays refused in the store (mpCheckRequest, ErrMoveRequest).
-- DEPLOY ORDER: apply on dev and prd BEFORE a hub with ApplyChannelMove (T5)
-- rolls; a hub without the door only fails such a move and rolls it back.

SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION usage_events_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND (pg_trigger_depth() > 1
        OR (current_setting('app.channel_move', true) = 'on' AND current_setting('app.rls_scope', true) = 'operator')) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'usage_events is append-only: % refused (only a tenant delete or a channel move removes rows)', TG_OP;
END $$;

CREATE OR REPLACE FUNCTION sql_query_audit_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND (pg_trigger_depth() > 1
        OR (current_setting('app.channel_move', true) = 'on' AND current_setting('app.rls_scope', true) = 'operator')) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'sql_query_audit is append-only: % refused (only a tenant delete or a channel move removes rows)', TG_OP;
END $$;

CREATE OR REPLACE FUNCTION demo_post_audit_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND (current_setting('app.demo_audit_purge', true) = 'on'
        OR (current_setting('app.channel_move', true) = 'on' AND current_setting('app.rls_scope', true) = 'operator')) THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'demo_post_audit is append-only: % refused (only do_spl_demo_audit_purge or a channel move deletes)', TG_OP;
END $$;

ALTER TABLE channel_move_journal DROP CONSTRAINT IF EXISTS ck_channel_move_journal_src;
