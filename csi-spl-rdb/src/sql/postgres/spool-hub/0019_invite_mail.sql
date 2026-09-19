-- 0019_invite_mail.sql — the invitation email's resend state (010 FR-016,
-- CLE-3411). Forward-only.
--
-- mailed_at is when the invite was last handed to the mail relay, NULL =
-- never. mail_count is how many times it was since the invite was last
-- (re)created: PutInvite resets the count, never mailed_at, so the minimum
-- gap between two sends still holds across a re-invite.
--
-- A send is claimed with ONE conditional UPDATE (open invite, gap elapsed,
-- count under the cap) before the relay is called, so two concurrent resends
-- cannot both mail. The row already sits under 0014's tenant RLS policy.

ALTER TABLE tenant_invites
    ADD COLUMN mailed_at  timestamptz NULL,
    ADD COLUMN mail_count integer     NOT NULL DEFAULT 0
        CONSTRAINT tenant_invites_mail_count_check CHECK (mail_count >= 0);
