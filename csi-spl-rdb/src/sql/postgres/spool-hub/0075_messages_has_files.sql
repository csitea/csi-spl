-- 0075_messages_has_files.sql — the file read door stops scanning every
-- message of the tenant (SPL-1124, epic SPL-1093). Forward-only.
--
-- The door (FileAttached / FileReadableByHuman / FileReadableByBox, rdb 0028 +
-- 0030) asks "does a message carry this file?" with jsonb containment
-- (files @> ...). 0030's gin index was meant to answer that, and the hub
-- never uses it: messages is FORCE row level security (0014), and Postgres
-- will not use a non-LEAKPROOF operator (jsonb @>, and jsonb <> too) as an
-- index condition under a policy. So every attachment and avatar fetch
-- scanned the tenant's messages: prd Query Insights 2026-09-28, 24 h,
-- 2165 + 205 calls, 8 / 27 ms mean, 12 % of the database's time; a file no
-- message carries (every avatar) always read the whole tenant.
--
-- has_files is a stored boolean the database keeps itself (it can never
-- disagree with files), and messages_with_files a partial index on the few
-- rows where it is true (prd: 133 of 6437). The door adds "AND m.has_files",
-- which every carrier satisfies, so its answers do not change; a bare boolean
-- column needs no operator, so the planner may use the index under RLS.
-- Local pg16, 20000 messages, 606 with files, as the non-superuser owner:
-- a miss 110 ms -> 17 ms.
--
-- Adding a STORED generated column rewrites the table once (prd 40 MB).
-- The running image never names the column, so this file rolls before the
-- image that reads it. No RLS clause: an index inherits the table's policies.

ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS has_files boolean
        GENERATED ALWAYS AS (files <> '[]'::jsonb) STORED;

CREATE INDEX IF NOT EXISTS messages_with_files ON messages (tenant_id, expires_at) WHERE has_files;
