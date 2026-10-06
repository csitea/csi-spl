-- 0135_messages_search_sig.sql - a lexeme signature per long message, so a
-- text search reads the TOASTed search_tsv only of the rows that can match
-- (t1 6d5bd334: prd 503 search_budget). Forward-only.
--
-- Why no index: messages is FORCE row level security (0014) and the tsvector
-- match (ts_match_vq) is not LEAKPROOF, so Postgres never uses a GIN on
-- search_tsv under the tenant policy (0122 dropped it; spec 022 section 9).
-- The message section scans the tenant's rows and evaluates search_tsv @@ on
-- each, and on long bodies search_tsv is TOASTed: every row costs a TOAST
-- index probe and its chunks.
-- prd t1, 2026-10-06, 18 801 messages, the owner's query
-- "Example refactoring prompt (round 4)": the statement hit the 2 s budget
-- twice (hub dur 2018 / 2029 ms); do_spl_search_measure n=3, one rare word:
-- Index Scan Backward on messages_received, Rows Removed by Filter 18 802,
-- 45 748 buffers (the heap is 4 443), 4 134 ms cold / 67 ms warm.
--
-- search_sig is a 1024-bit Bloom signature of the row's lexemes (one bit per
-- lexeme, hashtext & 1023). It lives in the heap row (128 bytes), so testing
-- it needs no TOAST read. The store checks it before the match:
--   CASE WHEN search_sig IS NULL OR search_sig & mask = mask
--        THEN search_tsv @@ q ELSE false END
-- A Bloom filter never says no to a row that holds every lexeme, so the
-- @@ still decides each result: the answer does not change, only the rows
-- read. NULL is always a candidate.
--
-- Only a body of 1024+ characters is signed: a shorter one's search_tsv sits
-- in the heap row (no TOAST read to save), and its row stays as narrow as
-- before (a signature on every row cost the short-row hidden-unread scan
-- 4 435 -> 6 759 buffers in TestHiddenUnreadBufferBudget). A short row keeps
-- NULL and goes straight to its inline @@.
-- Scratch pg 16, 60 000 messages of ~3 KB, FORCE RLS, a non-bypass role, the
-- owner's query: 254 665 buffers / 2 197 ms -> 14 628 buffers / 136 ms.
--
-- Rows: a BEFORE trigger sets it on insert and on a body edit (a stored
-- generated column cannot read search_tsv, and computing one here would
-- rewrite messages under ACCESS EXCLUSIVE). Existing rows are NOT filled here
-- (one UPDATE of 18.8k rows holds their row locks ~15 s at 0.25 vCPU); the
-- hub's retention sweep fills them in short chunks that SKIP LOCKED rows
-- (store.Postgres.Sweep), using the stored search_tsv.
--
-- DEPLOY ORDER: apply this file BEFORE the hub that reads search_sig, on dev
-- AND prd (a trunk push rolls both). The old hub ignores the column.

CREATE FUNCTION spool_search_sig(v tsvector) RETURNS bit(1024)
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$
        SELECT coalesce(bit_or(set_bit(B'0'::bit(1024), hashtext(l) & 1023, 1)), B'0'::bit(1024))
        FROM unnest(tsvector_to_array(v)) l
    $$;

ALTER TABLE messages ADD COLUMN search_sig bit(1024);

CREATE FUNCTION messages_search_sig_set() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- A BEFORE trigger runs before the stored search_tsv is computed: parse
    -- the body the way search_tsv's own expression does (0048).
    NEW.search_sig := CASE WHEN length(NEW.body) >= 1024
        THEN spool_search_sig(to_tsvector('spool_search'::regconfig, NEW.body)) END;
    RETURN NEW;
END
$$;

CREATE TRIGGER messages_search_sig
    BEFORE INSERT OR UPDATE OF body ON messages
    FOR EACH ROW EXECUTE FUNCTION messages_search_sig_set();

-- The sweep's backfill finds the long rows left to sign; empty once it is
-- done (short rows never enter it).
CREATE INDEX messages_search_sig_todo ON messages (tenant_id)
    WHERE search_sig IS NULL AND length(body) >= 1024;
