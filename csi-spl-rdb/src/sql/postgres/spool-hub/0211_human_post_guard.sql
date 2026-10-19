-- 0211_human_post_guard.sql — the body read of the human post guard
-- (SPL-2584). Forward-only, additive, idempotent.
--
-- Owner HUM-10, t1 4b49e47d msg 85a20ac7: "add a check in the db to not
-- accept the same msgs ... implement with less weight on the intelligence
-- used". The hub refuses an agent's post to a person whose normalized body
-- equals one an agent already sent that person in the last 24 h
-- (internal/hub/human_post_guard.go, store.HumanGotBody).
--
-- 1. spool_norm_body(text): whitespace runs (the regex class [[:space:]])
--    become one space, the ends are trimmed, the rest is lower-cased. The Go
--    twin is store.NormalizeBody; both say the same rule.
-- 2. messages_to_human (tenant_id, to_id, received_at): the guard reads one
--    person's last 24 h. The existing messages_to leads with to_box, which
--    the guard does not know (a channel reply and a DM reach different
--    boxes). Plain CREATE INDEX: prd held 47 756 rows on 2026-10-19, the
--    same scale rdb 0143 measured at a few seconds of SHARE lock.
--
-- DEPLOY ORDER: apply this file BEFORE the hub that calls spool_norm_body(),
-- on dev AND prd (a trunk push rolls both). The old hub ignores both.

CREATE OR REPLACE FUNCTION spool_norm_body(t text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT lower(btrim(regexp_replace(t, '[[:space:]]+', ' ', 'g'))) $$;

CREATE INDEX IF NOT EXISTS messages_to_human ON messages (tenant_id, to_id, received_at);
