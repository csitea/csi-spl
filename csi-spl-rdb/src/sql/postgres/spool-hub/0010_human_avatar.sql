-- 0010_human_avatar.sql — a human's IdP picture, stored by the hub
-- (specs/010-spool-social-auth T044; SPEC-spool-avatars §3-4). Forward-only.
--
-- At sign-in the hub fetches the IdP picture server-side (https only, size
-- cap, image content type) and puts the bytes in the tenant blob store
-- (t/<tenant>/files/<sha256>). The row keeps only that file_id: never the
-- IdP URL, so nothing hotlinks a third-party host. NULL = no picture; the
-- WUI falls back to the deterministic default avatar.

ALTER TABLE humans
    ADD COLUMN avatar_file_id text NULL
        CHECK (avatar_file_id IS NULL OR avatar_file_id ~ '^[0-9a-f]{64}$');
