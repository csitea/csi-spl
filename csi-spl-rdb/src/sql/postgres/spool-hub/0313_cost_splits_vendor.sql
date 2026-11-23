-- 0313_cost_splits_vendor.sql - a tokens split of ONE vendor over a month
-- range (SPL-6301, spec 143 costs-allocation.md section 7.7; owner HUM-10,
-- topic f3203933 msg cfbd1832: "take the claude code tokens costs
-- from 2026-01 till 2026-06, take 40% of them and set them as the claude
-- costs for this project"). Forward-only and idempotent (DROP CONSTRAINT IF
-- EXISTS, then ADD): a re-run is a no-op.
--
-- cost_splits (rdb 0293) gains split_kind tokens_vendor: subject
-- '<vendor>:<from>:<to>', a vendor of rdb 0205 and two months YYYY-MM, both
-- included. Its shares attribute that vendor's paid AI items in those months
-- in place of the tokens split. The two CHECKs of 0293 are widened; the
-- table, its key and its RLS policy do not change.
--
-- Live-data safety: every stored row (tokens, person) passes the new CHECKs;
-- no row is written or deleted.
-- DEPLOY ORDER: apply BEFORE the hub that writes the new kind (wf 20 does).

ALTER TABLE cost_splits DROP CONSTRAINT IF EXISTS cost_splits_split_kind_check;
ALTER TABLE cost_splits DROP CONSTRAINT IF EXISTS cost_splits_check;

ALTER TABLE cost_splits ADD CONSTRAINT cost_splits_split_kind_check
    CHECK (split_kind IN ('tokens', 'person', 'tokens_vendor'));
ALTER TABLE cost_splits ADD CONSTRAINT cost_splits_check
    CHECK ((split_kind = 'tokens' AND subject = '')
        OR (split_kind = 'person' AND subject <> '')
        OR (split_kind = 'tokens_vendor'
            AND subject ~ '^(claude|mistral|grok|agy|qwen):[0-9]{4}-(0[1-9]|1[0-2]):[0-9]{4}-(0[1-9]|1[0-2])$'
            AND split_part(subject, ':', 2) <= split_part(subject, ':', 3)));
