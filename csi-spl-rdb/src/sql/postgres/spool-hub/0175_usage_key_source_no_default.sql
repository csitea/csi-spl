-- 0175_usage_key_source_no_default.sql - the contract step of
-- usage_events.key_source (spec 127 v1.1 section 7.2, C12; lane D1).
-- Forward-only.
--
-- rdb 0174 added key_source NOT NULL with DEFAULT 'hub' so the hub then
-- running could keep metering (expand, dispatch-bdc65df6 msg 7da7b68a).
-- The hub insert names key_source itself since aa737c890 (store
-- usageInsertSQL), and dev and prd both served that commit before this
-- landed (do_check_deploy_lag, 2026-10-11). Dropping the default reaches the
-- spec's end state: NOT NULL, CHECK hub | workspace, NO default, so a writer
-- that forgets the field is refused (23502) instead of being charged.
--
-- Live-data safety: catalogue only; rows written under the 0174 default keep
-- 'hub' (the stored value, no rewrite). ACCESS EXCLUSIVE on usage_events for
-- the catalogue change, hence lock_timeout. Store test:
-- TestUsageEventsKeySource. No personal data, no secret.

SET LOCAL lock_timeout = '5s';

ALTER TABLE usage_events ALTER COLUMN key_source DROP DEFAULT;
