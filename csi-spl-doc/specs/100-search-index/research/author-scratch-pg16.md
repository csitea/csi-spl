# 100 search index: author's scratch probe (c-372, pen)

PostgreSQL 16.15 (`postgres:16-alpine`, local docker, NOT Cloud SQL), tree
`origin/master` `ebfe1fbc`, 2026-10-06. 60 000 synthetic rows (54k tenant A,
6k tenant B; every row has `example`, one A row has `zebraonly`). **n=1 for
every plan below.** These numbers show what PLAN Postgres picks. Synthetic data
under-states real buffer counts (owner lesson 5), so they are NOT prd ratios.

## 1. Results

| # | path, run as the non-owner runtime role `rt`, scope A, word `zebraonly` | plan | buffers |
|---|---|---|---|
| 0 | `rt` direct `search_tsv @@` on FORCE-RLS `messages` (today) | Seq Scan, GIN ignored | 1 578 |
| S1 | SECURITY DEFINER owned by the TABLE OWNER, over `messages` | seq scan inside the function (FORCE binds the owner) | 1 704 |
| S1r | SECURITY DEFINER owned by a NOLOGIN role `search_reader` + `CREATE POLICY ... TO search_reader USING (true)` on `messages` | GIN used | 77 |
| S2 | SECURITY DEFINER owned by the table owner over a side table with RLS ENABLED, NOT forced | GIN used | 65 |
| B | `rt` direct on a word table `(tenant_id, word, msg_id)` under FORCE RLS, index `(word, tenant_id, msg_id)` | Index Only Scan, `word = $1` as Index Cond | 4 |
| B-prefix | same, `word >= 'zebra' AND word < 'zebrb'` | Index Only Scan, range as Index Cond | 4 |
| B-pk | same table, only the PK `(tenant_id, word, msg_id)` | Parallel Seq Scan (the policy's OR blocks the tenant prefix) | 1 969 |

`pg_proc.proleakproof` on 16.15: `texteq`, `text_lt`, `text_ge`, `byteaeq`,
`bytealt`, `uuid_eq`, `timestamptz_lt` = `t`; `ts_match_vq` = `f`.

Isolation checks (n=1): S2 and S1r with scope `B` return 0 rows for A's
`zebraonly`; S2 with `app.tenant_id = ''` returns 0 (NULLIF fails closed);
`rt` `SELECT` on the S2 side table: `permission denied`.

Sizes at 60k synthetic rows: `messages` 23 MB, side table 20 MB (GIN 8 MB),
word table 45 MB (243 888 rows, ~4 words per synthetic row; real posts
carry far more distinct words, so B's real size is unmeasured).

## 2. Script

Run as `postgres` in a throwaway `postgres:16-alpine`; the probe statements
run after `SET ROLE rt; SET app.tenant_id = 'A';`.

```sql
CREATE ROLE owner_r LOGIN NOSUPERUSER CREATEROLE;
CREATE ROLE rt LOGIN NOSUPERUSER;
CREATE ROLE search_reader NOLOGIN;
GRANT CREATE ON SCHEMA public TO owner_r;
SET ROLE owner_r;
CREATE TABLE messages(tenant_id text, msg_id uuid, received_at timestamptz, body text,
  search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple', body)) STORED, PRIMARY KEY (tenant_id,msg_id));
ALTER TABLE messages ENABLE ROW LEVEL SECURITY; ALTER TABLE messages FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON messages USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON messages USING (current_setting('app.rls_scope', true) = 'operator');
GRANT SELECT ON messages TO rt;
SET app.rls_scope=$$operator$$;
INSERT INTO messages(tenant_id,msg_id,received_at,body)
 SELECT CASE WHEN g%10=0 THEN 'B' ELSE 'A' END, gen_random_uuid(), now()-g*interval '1s',
   'example word'||(g%5000)||' filler '||md5(g::text)||CASE WHEN g=777 THEN ' zebraonly' ELSE '' END
 FROM generate_series(1,60000) g;
RESET app.rls_scope;
CREATE INDEX messages_search ON messages USING gin(search_tsv);
ANALYZE messages;
-- S2 side table: owned by owner_r, RLS enabled NOT forced
CREATE TABLE message_search(tenant_id text, msg_id uuid, received_at timestamptz, tsv tsvector, PRIMARY KEY(tenant_id,msg_id));
ALTER TABLE message_search ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON message_search USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
SET app.rls_scope='operator';
INSERT INTO message_search SELECT tenant_id,msg_id,received_at,search_tsv FROM messages;
RESET app.rls_scope;
CREATE INDEX message_search_gin ON message_search USING gin(tsv);
ANALYZE message_search;
CREATE FUNCTION s2_ids(q text) RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
  SELECT msg_id FROM public.message_search WHERE tenant_id = NULLIF(current_setting('app.tenant_id', true), '') AND tsv @@ plainto_tsquery('simple', q) $$;
REVOKE ALL ON FUNCTION s2_ids(text) FROM PUBLIC; GRANT EXECUTE ON FUNCTION s2_ids(text) TO rt;
-- S1: definer over FORCE'd messages, owned by owner_r
CREATE FUNCTION s1_ids(q text) RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
  SELECT msg_id FROM public.messages WHERE tenant_id = NULLIF(current_setting('app.tenant_id', true), '') AND search_tsv @@ plainto_tsquery('simple', q) $$;
GRANT EXECUTE ON FUNCTION s1_ids(text) TO rt;
-- B: inverted word table under FORCE RLS
CREATE TABLE message_words(tenant_id text, word text, msg_id uuid, PRIMARY KEY(tenant_id, word, msg_id));
ALTER TABLE message_words ENABLE ROW LEVEL SECURITY; ALTER TABLE message_words FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON message_words USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON message_words USING (current_setting('app.rls_scope', true) = 'operator');
GRANT SELECT ON message_words TO rt;
SET app.rls_scope='operator';
INSERT INTO message_words SELECT DISTINCT tenant_id, l, msg_id FROM messages, unnest(tsvector_to_array(search_tsv)) l;
RESET app.rls_scope;
ANALYZE message_words;
RESET ROLE;

SET ROLE owner_r;
CREATE INDEX message_words_word ON message_words(word, tenant_id, msg_id);
GRANT SELECT ON messages TO search_reader;
CREATE POLICY search_reader_all ON messages TO search_reader USING (true);
CREATE FUNCTION s1r_ids(q text) RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
RESET ROLE;
ALTER FUNCTION s1r_ids(text) OWNER TO search_reader;
GRANT EXECUTE ON FUNCTION s1r_ids(text) TO rt;
```
