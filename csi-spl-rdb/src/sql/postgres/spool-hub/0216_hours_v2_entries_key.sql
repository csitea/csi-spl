-- 0216_hours_v2_entries_key.sql - the contract step of rdb 0215 (spec 107
-- v2 build row T020, FR-27). Forward-only. Owner HUM-10, csitea topic
-- 55a2d6c2, msg 81ed4911 (the go to build v2).
--
-- 0215 added the five-column unique index hours_entries_kind_key beside the
-- v1 four-column PK, so the v1 hub kept writing while wf 20 rolled. This
-- lands only after the T020 hub serves on dev and prd: no running hub names
-- ON CONFLICT on the four columns any more. It drops the four-column PK and
-- promotes the index to the PK (PRIMARY KEY USING INDEX renames it to
-- hours_entries_pkey), so a work, a travel and a wait row can share one
-- (day, target).
--
-- The spans FK (hours_entry_spans_entry_fkey, 0215) references the index;
-- Postgres records the FK against the index, which the promotion keeps, so
-- the FK stays as it is.
--
-- Live-data safety: no table rewrite and no index build (the index exists,
-- its columns are NOT NULL); the ALTER takes ACCESS EXCLUSIVE briefly,
-- hence lock_timeout. No personal data, no secret, no money field.
-- Runs under the operator RLS scope (spool migrate, rdb 0014).

SET LOCAL lock_timeout = '5s';

ALTER TABLE hours_entries
    DROP CONSTRAINT hours_entries_pkey,
    ADD CONSTRAINT hours_entries_pkey PRIMARY KEY USING INDEX hours_entries_kind_key;
