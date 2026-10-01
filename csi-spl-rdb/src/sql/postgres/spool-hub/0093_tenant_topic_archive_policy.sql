-- 0093_tenant_topic_archive_policy.sql — "Who can archive topics", a
-- per-workspace setting (CLE-77819). Forward-only.
--
-- Owner, 2026-09-30 (csitea #spool-hub topic 85597e91): "we must have a
-- workspace specific setting for this behaviour .. some organisations might
-- want EVERY user to be able to archive .. but some might want only the
-- admins, and some only the topics starter persons, so do this as a settings,
-- and set the default to EVERYONE".
--
-- tenants.topic_archive_policy: who may archive / unarchive a topic in this
-- workspace. The three values match internal/store ArchivePolicy*:
--   'everyone' — any member who can read the topic (the DEFAULT)
--   'admins'   — the tenant owner or an admin only
--   'starter'  — the topic's starter, plus the owner / admin
-- NULL = unset = 'everyone', so EVERY existing workspace (csitea included)
-- gets "everyone" with no backfill. Delete of a whole topic is unchanged
-- (the author, the owner or an admin); this setting governs archive only.
-- Applied by spool migrate before a hub that reads the column is served.

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS topic_archive_policy text NULL
        CONSTRAINT tenants_topic_archive_policy_check
        CHECK (topic_archive_policy IS NULL OR topic_archive_policy IN
            ('everyone','admins','starter'));
