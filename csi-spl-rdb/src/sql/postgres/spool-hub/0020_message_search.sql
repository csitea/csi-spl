-- 0020_message_search.sql — full-text search over message bodies
-- (specs/003 contracts/search-v1.md §2.2, §7; FR-032, CLE-3409). Forward-only.
--
-- search_tsv is generated from body with the 'simple' configuration: words
-- lower-cased, no stemming, no stop words, so all 19 WUI locales (0017)
-- search the same way. A per-language configuration is a later migration,
-- only when a locale needs stemming.
--
-- The hub never writes this column; Postgres keeps it in step with body.
-- Queries pass every user string as a bind parameter of plainto_tsquery /
-- phraseto_tsquery, never to_tsquery. messages keeps 0014's row level
-- security: the index serves only the rows the tenant scope lets through.
--
-- Adding a STORED generated column rewrites messages once (retention keeps
-- the table at 30 days of traffic).

ALTER TABLE messages
    ADD COLUMN search_tsv tsvector
        GENERATED ALWAYS AS (to_tsvector('simple'::regconfig, body)) STORED;

CREATE INDEX messages_search ON messages USING gin (search_tsv);
