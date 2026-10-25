-- 0227_workspace_doc_search.sql - the search index entries of the Qto
-- documents (spec 100 section 14, SPL-3337; owner HUM-10 t1 4e06a219 msg
-- 0be4d1cb: "If the search does not include the QTO documents, it must start
-- including them as well. Create all of the search index and whatever
-- entries support the search."). Forward-only, additive, idempotent: the
-- whole file can run a second time and changes nothing.
--
--   workspace_doc_item.search_tsv  one entry per section: its title and body
--   workspace_doc.search_tsv       one entry per document: its title
--
-- Both are STORED generated columns in spool_search (rdb 0048), the column
-- shape of messages.search_tsv, so a word matches a document exactly as it
-- matches a message, and:
--   - the backfill is this file: ADD COLUMN .. STORED rewrites the table and
--     computes the entry of every existing row (prd 2026-10-25: 3 444 items,
--     4 216 kB in all, the largest body 20 626 chars; dev: none);
--   - Postgres keeps them current in the statement of every write (add,
--     edit, move, delete, the import), so the lag is 0 and no trigger or
--     write path can forget one (spec 100 section 3.4).
-- No GIN: both tables are FORCE RLS (0157) and ts_match_vq is not
-- LEAKPROOF, so the planner could not use one under the tenant policy (rdb
-- 0122). The section's statement reads the entries of ONE tenant through the
-- tenant-leading keys (workspace_doc_item_tenant_doc_id,
-- workspace_doc_tenant_id), so it never computes to_tsvector over a body and
-- never reads another workspace's rows; spec 100 section 14.3 says when the
-- S1r door (rdb 0143) is worth it here.
--
-- RLS, policies and grants are unchanged: a new column of a table the
-- runtime already reads. lock_timeout 5s: the rewrite holds an ACCESS
-- EXCLUSIVE lock for its few ms; on a busy table the file fails fast instead
-- of queueing every write behind its wait. No personal data, no secret.

SET LOCAL lock_timeout = '5s';

ALTER TABLE workspace_doc_item
    ADD COLUMN IF NOT EXISTS search_tsv tsvector
        GENERATED ALWAYS AS (to_tsvector('spool_search'::regconfig, title || ' ' || body)) STORED;

ALTER TABLE workspace_doc
    ADD COLUMN IF NOT EXISTS search_tsv tsvector
        GENERATED ALWAYS AS (to_tsvector('spool_search'::regconfig, title)) STORED;
