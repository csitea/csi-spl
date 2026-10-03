-- 0110_messages_claim.sql - who must deal with a message, and its lock
-- (spec 068 sections 4.1 and 4.2, lane L1). Forward-only.
--
-- Spec 068 replaces the orchestrator role with four peer seats per box
-- (001..004, <id>@<box>). Every 5 s a seat's poll loop locks unclaimed
-- messages for itself with ONE statement (store.PollMessageClaims, box frame
-- `claim`), and the lock lives on the message row itself:
--
--   responsible      <id>@<box>: the seat that must deal with it. Set here, at
--                    insert, for a message to one agent (to_id@to_box), and by
--                    a claim for a message to the peers. NULL = nobody yet.
--   locked_until     the claim's lock on the hub clock; renewed by the
--                    holder's loop; past it any peer may take the message.
--   responsible_gen  +1 on every claim: the fence an outward action re-checks.
--   claim_n          +1 on every claim: the delivery count. A message claimed
--                    CLAIM_MAX (4) times without a close is closed `dead` by
--                    the next poll and handed to the owner once.
--   handled_at/how   the close: answered | handed:<lane> | no-reply:<reason> | dead.
--   not_by           the harnesses (claude, grok, ...) that refused it (F6);
--                    a poll from that harness skips it.
--   needs_peer       true for a message the peers pick up: one to_id 'peers',
--                    or a human post to the room (box-wui, HUM-*, to ALL-0)
--                    in a seated workspace, one whose roster holds an OD seat
--                    (spec 068 3.2: <letter>-001..004). Set at insert only.
--
-- The partial index is the poll's only read: the unhandled rows that need a
-- peer, so eight seats polling every 5 s stay indexed and small.
--
-- No row gets needs_peer here: a peer must not wake up to the history. The
-- back-fill sets only `responsible` on the retained messages to one agent.
--
-- Every ADD COLUMN has a constant default (catalog-only, no rewrite). The
-- trigger sets responsible and needs_peer, so the hub's insert statement is
-- unchanged and a hub that predates this file keeps writing correct rows.
-- DEPLOY ORDER: apply BEFORE the hub that serves the `claim` frame.

ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS responsible     text        NULL,
    ADD COLUMN IF NOT EXISTS locked_until    timestamptz NULL,
    ADD COLUMN IF NOT EXISTS responsible_gen bigint      NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS claim_n         integer     NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS handled_at      timestamptz NULL,
    ADD COLUMN IF NOT EXISTS handled_how     text        NULL,
    ADD COLUMN IF NOT EXISTS not_by          text[]      NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS needs_peer      boolean     NOT NULL DEFAULT false;

ALTER TABLE messages
    ADD CONSTRAINT messages_responsible_check
        CHECK (responsible IS NULL OR length(responsible) <= 100),
    ADD CONSTRAINT messages_handled_how_check
        CHECK (handled_how IS NULL OR (length(handled_how) <= 520
            AND handled_how ~ '^(answered|dead|handed:.+|no-reply:.+)$'));

CREATE INDEX IF NOT EXISTS messages_needs_peer
    ON messages (tenant_id, ts)
    WHERE needs_peer AND handled_at IS NULL;

-- Insert-time defaults. An explicit value from the writer wins.
CREATE FUNCTION messages_claim_defaults() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.responsible IS NULL
       AND NEW.to_id ~ '^([acgq]-[0-9]{3}|(CLE|AGY|GRK|QWN)-[0-9]+)$' AND NEW.to_id !~ '-000$' THEN
        NEW.responsible := NEW.to_id || '@' || NEW.to_box;
    END IF;
    IF NEW.to_id = 'peers' THEN
        NEW.needs_peer := true;
    ELSIF NEW.responsible IS NULL AND NEW.from_box = 'box-wui' AND NEW.from_id LIKE 'HUM-%'
          AND NEW.to_id = 'ALL-0'
          AND EXISTS (SELECT 1 FROM roster r
                      WHERE r.tenant_id = NEW.tenant_id AND r.agent_id ~ '^[acgq]-00[1-4]$') THEN
        NEW.needs_peer := true;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER messages_claim_defaults BEFORE INSERT ON messages
    FOR EACH ROW EXECUTE FUNCTION messages_claim_defaults();

-- Back-fill: the retained messages to one agent name it responsible. Operator
-- scope: this file runs in one transaction, and messages FORCEs RLS (0014).
SELECT set_config('app.rls_scope', 'operator', true);
UPDATE messages
SET responsible = to_id || '@' || to_box
WHERE responsible IS NULL
  AND expires_at > now()
  AND to_id ~ '^([acgq]-[0-9]{3}|(CLE|AGY|GRK|QWN)-[0-9]+)$' AND to_id !~ '-000$';
