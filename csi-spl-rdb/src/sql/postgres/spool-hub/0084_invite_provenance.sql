-- 0084_invite_provenance.sql — "who ordered this invite, and when" (CLE-77778).
-- Forward-only.
--
-- Owner, 2026-09-30 (prd t1 topic a838eec9): a new member signed in and the
-- desk bots welcomed him; the owner did not recognise the name and it took an
-- agent ~15 minutes to prove it was a legitimate invite. tenant_invites.
-- invited_by records only 'operator' for every operator-issued CLI invite, so
-- the real orderer had to be dug out of a retired agent outbox. Make that
-- answer visible: record WHO ordered the invite and (optionally) VIA which
-- agent, without changing the invited_by = 'operator' semantics (0006).
--
--   ordered_by  — the human who ordered the invite (a HUM-* id). For an
--                 operator CLI invite this is the person who asked for it
--                 (ORDERED_BY env); for a WUI/API admin invite it is the
--                 signed-in admin (same value as invited_by there). NULL on
--                 the historic rows = unknown (operator), never guessed.
--   ordered_via — the agent or channel that carried the order, e.g.
--                 'CLE-34967' or '[terminal]'. NULL when there was none
--                 (the WUI admin path, or an order given in person).
--
-- Both nullable; existing rows stay NULL. A member's provenance is read by
-- joining their accepted invite (accepted_by = human_id): the WUI Users pane
-- and the desk first-time welcome surface it.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014).

ALTER TABLE tenant_invites
    ADD COLUMN ordered_by  text NULL
        REFERENCES humans (human_id) ON DELETE SET NULL
        CONSTRAINT tenant_invites_ordered_by_check
            CHECK (ordered_by IS NULL OR ordered_by ~ '^HUM-[0-9]+$'),
    ADD COLUMN ordered_via text NULL
        CONSTRAINT tenant_invites_ordered_via_check
            CHECK (ordered_via IS NULL OR length(ordered_via) BETWEEN 1 AND 64);
