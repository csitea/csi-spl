-- 0112_dm_ref_task.sql - a DM about a topic, and the channel copy of a
-- person's DM answer (spec 067 sections 3.3 and 3.4, build lane L3).
-- Forward-only.
--
--   ref_task_id  the channel topic (its task_id) this DM is about. Set on a
--                DM by the mention-poke, by `spool send --ref <task>` and,
--                inherited, by a DM reply whose thread root carries one.
--                NULL = a DM about nothing in particular, or a channel row.
--   mirror_of    on the channel copy the hub writes of a person's DM answer:
--                the msg_id of that DM. NULL = an original row.
--
-- Both are nullable with no default (catalog-only ADD COLUMN, no rewrite) and
-- nothing sets them yet: this file changes no behaviour. The hub that writes
-- them is L4. No foreign key on mirror_of: the DM and its copy keep their own
-- retention, and the sweep deletes either without ordering the two.
--
-- Two partial indexes, each small because almost no row carries the column:
-- the DMs about a topic (the WUI's "about" header, L4's inheritance read),
-- and the copy of a DM (an edit or an archive of the DM follows it, edge 3).
-- RLS is unchanged: messages already ENABLE + FORCE it (0014, 0021), and a
-- column needs no policy of its own.
-- DEPLOY ORDER: apply BEFORE the hub that writes either column (spec 067 L4).

ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS ref_task_id uuid NULL,
    ADD COLUMN IF NOT EXISTS mirror_of   uuid NULL;

ALTER TABLE messages
    ADD CONSTRAINT messages_mirror_of_check
        CHECK (mirror_of IS NULL OR mirror_of <> msg_id);

CREATE INDEX IF NOT EXISTS messages_ref_task
    ON messages (tenant_id, ref_task_id)
    WHERE ref_task_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS messages_mirror_of
    ON messages (tenant_id, mirror_of)
    WHERE mirror_of IS NOT NULL;
