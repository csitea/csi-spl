-- 0023_message_period_counts.sql - messages received per tenant per billing
-- period, kept by triggers (specs/027 T040). Forward-only.
--
-- Why: the month quota in onSend / admit ran
--   SELECT COUNT(*) FROM messages WHERE tenant_id = $1 AND received_at >= $2
-- on every send, O(messages this period): ~20 ms at 200k rows on pg16, and
-- still ~20 ms with a (tenant_id, received_at) index (parallel index-only
-- scan; measured, specs/027). The hub now reads the SUM of at most 16 rows.
--
-- Invariant: for every tenant and every UTC month start P,
--   SUM(messages) WHERE period_start >= P
--     = COUNT(*) FROM messages WHERE received_at >= P
-- The triggers keep it on INSERT, DELETE (the retention sweep, a tenant
-- cascade), an UPDATE that moves received_at / tenant_id, and TRUNCATE. A
-- deleted message is decremented, exactly as COUNT(*) forgot it before.
--
-- slot spreads one tenant's hot counter over 16 rows: concurrent sends of one
-- tenant rarely wait on the same row lock. A decrement goes to slot 0, which
-- may go negative; only the SUM means anything.
--
-- The INSERT and DELETE triggers are statement-level (transition tables): one
-- aggregate upsert per statement, so a chunked sweep pays once per chunk.
--
-- DEPLOY ORDER: apply this file BEFORE the hub that reads the table. The old
-- hub ignores the table; the triggers keep it right under either hub.
-- CREATE TRIGGER locks messages (SHARE ROW EXCLUSIVE) until this file's
-- transaction commits, so no insert lands between the triggers and the
-- backfill below.

CREATE TABLE message_period_counts (
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    period_start timestamptz NOT NULL,
    slot         smallint    NOT NULL CHECK (slot BETWEEN 0 AND 15),
    messages     bigint      NOT NULL,
    PRIMARY KEY (tenant_id, period_start, slot)
);

ALTER TABLE message_period_counts ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_period_counts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON message_period_counts
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON message_period_counts
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- billing.PeriodStart: the first instant of the UTC month.
CREATE FUNCTION message_period(at timestamptz) RETURNS timestamptz
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT date_trunc('month', at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' $$;

CREATE FUNCTION message_period_counts_add() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO message_period_counts (tenant_id, period_start, slot, messages)
    SELECT a.tenant_id, message_period(a.received_at), (SELECT floor(random() * 16)::smallint), count(*)
    FROM added a GROUP BY 1, 2
    ON CONFLICT (tenant_id, period_start, slot)
        DO UPDATE SET messages = message_period_counts.messages + EXCLUDED.messages;
    RETURN NULL;
END
$$;

CREATE FUNCTION message_period_counts_sub() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO message_period_counts (tenant_id, period_start, slot, messages)
    SELECT g.tenant_id, message_period(g.received_at), 0, -count(*)
    FROM gone g
    WHERE EXISTS (SELECT 1 FROM tenants t WHERE t.tenant_id = g.tenant_id) -- a tenant cascade drops its counts itself
    GROUP BY 1, 2
    ON CONFLICT (tenant_id, period_start, slot)
        DO UPDATE SET messages = message_period_counts.messages + EXCLUDED.messages;
    RETURN NULL;
END
$$;

CREATE FUNCTION message_period_counts_move() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.tenant_id IS DISTINCT FROM NEW.tenant_id
       OR message_period(OLD.received_at) IS DISTINCT FROM message_period(NEW.received_at) THEN
        INSERT INTO message_period_counts (tenant_id, period_start, slot, messages)
        VALUES (OLD.tenant_id, message_period(OLD.received_at), 0, -1)
        ON CONFLICT (tenant_id, period_start, slot)
            DO UPDATE SET messages = message_period_counts.messages - 1;
        INSERT INTO message_period_counts (tenant_id, period_start, slot, messages)
        VALUES (NEW.tenant_id, message_period(NEW.received_at), 0, 1)
        ON CONFLICT (tenant_id, period_start, slot)
            DO UPDATE SET messages = message_period_counts.messages + 1;
    END IF;
    RETURN NULL;
END
$$;

CREATE FUNCTION message_period_counts_clear() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE message_period_counts;
    RETURN NULL;
END
$$;

CREATE TRIGGER message_period_counts_add AFTER INSERT ON messages
    REFERENCING NEW TABLE AS added FOR EACH STATEMENT EXECUTE FUNCTION message_period_counts_add();
CREATE TRIGGER message_period_counts_sub AFTER DELETE ON messages
    REFERENCING OLD TABLE AS gone FOR EACH STATEMENT EXECUTE FUNCTION message_period_counts_sub();
CREATE TRIGGER message_period_counts_move AFTER UPDATE OF tenant_id, received_at ON messages
    FOR EACH ROW EXECUTE FUNCTION message_period_counts_move();
CREATE TRIGGER message_period_counts_clear AFTER TRUNCATE ON messages
    FOR EACH STATEMENT EXECUTE FUNCTION message_period_counts_clear();

-- Backfill every period already stored (spool migrate runs this file in the
-- operator scope, so it sees every tenant).
INSERT INTO message_period_counts (tenant_id, period_start, slot, messages)
SELECT tenant_id, message_period(received_at), 0, count(*)
FROM messages GROUP BY 1, 2;
