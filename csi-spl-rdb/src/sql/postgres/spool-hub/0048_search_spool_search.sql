-- 0048_search_spool_search.sql — one language-neutral search index for all
-- 19 WUI locales (search-v1 grammar 1.1, specs/022 §9,
-- CLE-34992). Forward-only.
--
-- Owner, 2026-09-26: "we need to improve the indexsing and searching
-- capabliities of it once the data in the db starts grwoing and take into
-- the considerations the existing languages as well".
--
-- spool_search is the 'simple' parser and dictionary behind unaccent: words
-- are lower-cased AND stripped of accents, never stemmed. So cafe finds
-- café, strasse finds Straße and resume finds résumé whatever the locale.
-- No per-language stemmer: a message carries no language tag, and one
-- language's stemmer applied to another's text loses matches; prefix
-- queries (deplo -> deploy, deployed) do the stemmer's job for every
-- language at once. 0020's note ("a per-language configuration is a later
-- migration, only when a locale needs stemming") stays true.
--
-- unaccent is a trusted contrib extension (PG13+): the database owner's
-- members may create it, which the Cloud SQL owner login spool_hub is
-- (cloudsqlsuperuser owns the database). pg_trgm is NOT added: nothing
-- measured needs substring search yet.
--
-- search_tsv is regenerated with spool_search: the column is dropped (which
-- drops 0020's messages_search) and added again, one rewrite of messages
-- (retention keeps it at 30 days). A hub still querying with 'simple'
-- keeps working on it: an unaccented word is still its own lexeme.

CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE TEXT SEARCH CONFIGURATION spool_search (COPY = simple);

ALTER TEXT SEARCH CONFIGURATION spool_search
    ALTER MAPPING FOR asciiword, asciihword, hword_asciipart, word, hword, hword_part
    WITH unaccent, simple;

ALTER TABLE messages DROP COLUMN search_tsv;

ALTER TABLE messages
    ADD COLUMN search_tsv tsvector
        GENERATED ALWAYS AS (to_tsvector('spool_search'::regconfig, body)) STORED;

CREATE INDEX messages_search ON messages USING gin (search_tsv);
