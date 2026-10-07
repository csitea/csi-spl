-- 0150_human_own_avatar.sql - a person changes their own picture. Forward-only,
-- additive.
--
-- Owner HUM-10, t1 ccaee528: "the users should be able to change their own
-- picture ... the simpliest possible implementation for it".
--
--   humans.avatar_own          true = avatar_file_id is a picture the person
--                              uploaded (PUT /api/v1/auth/avatar); a sign-in
--                              then never overwrites it.
--   humans.idp_avatar_file_id  the last IdP picture a sign-in stored, kept
--                              while an upload is shown, so DELETE
--                              /api/v1/auth/avatar goes back to it. NULL = the
--                              IdP gave none (or none since this column).
--
-- avatar_file_id (rdb 0010) stays the ONE picture every reader shows (the
-- roster, the view, search): an upload is stored in the same blob place an IdP
-- picture is, so nothing else changes.
--
-- A nullable column and a constant default: catalog-only ADD COLUMNs, no
-- rewrite, and the running image ignores them. humans is hub-wide (outside
-- rdb 0014's RLS), unchanged. No new personal data: a content address and a flag.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS avatar_own boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS idp_avatar_file_id text NULL
        CONSTRAINT humans_idp_avatar_file_id_check
            CHECK (idp_avatar_file_id IS NULL OR idp_avatar_file_id ~ '^[0-9a-f]{64}$');
