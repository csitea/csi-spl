-- 0276_note_to_self.sql - messages.note_to_self and human_links (spec 042
-- section "Note to self", SPL-5372; owner HUM-10, t1 df36f210, msg 76800948:
-- "a post tagged only to yourself is a note to self, no agent answers"; the
-- f0fc6d7f answer at 11:51:26Z: "also let me tag my second account outside
-- the channel"; poll 3193d41f answer C, msg 20528286: "Operator-set link
-- only, no self-service"). Forward-only, additive.
--
--   messages.note_to_self  true on a person's post whose only @mentions
--                     are its author or the author's linked accounts
--                     (human_links). The hub sets it at the browser send
--                     (internal/hub/note_to_self.go) and it is the one flag
--                     every reader honours: no agent delivery is built for
--                     the row, the operator replay of unsigned posts skips
--                     it, the WUI marks it, and the unanswered sweep
--                     (do_spl_unanswered_sweep) never counts it.
--
-- Catalog-only: NOT NULL with a constant default is stored in the catalog
-- (PostgreSQL 11+), so messages, the hub's largest table, is not rewritten
-- and every existing row reads false. RLS is unchanged: the messages
-- policies cover the new column. No index: the readers filter rows they
-- already found by other keys.
-- DEPLOY ORDER: apply before a hub that writes either rolls; an older hub
-- names neither, and its rows read false.

SET LOCAL lock_timeout = '5s';

ALTER TABLE messages ADD COLUMN IF NOT EXISTS note_to_self boolean NOT NULL DEFAULT false;

--   human_links       two HUM ids that are one person (the owner's second
--                     account). Written ONLY by the operator route POST
--                     /v1/operator/humans/{human_id}/links
--                     (do_spl_human_link), both directions as two rows; no
--                     self-service, no email matching. Read by the mention
--                     rule: tagging one's own linked account is a note to
--                     self, and gets no "does not belong to this channel"
--                     note. Hub-wide like humans (rdb 0006): no tenant, no
--                     RLS. created_by is "<agent_id> for <ordered_by>".
CREATE TABLE IF NOT EXISTS human_links (
    human_id        text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    linked_human_id text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    created_by      text        NOT NULL CHECK (length(created_by) BETWEEN 1 AND 200),
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (human_id, linked_human_id),
    CHECK (human_id <> linked_human_id)
);
