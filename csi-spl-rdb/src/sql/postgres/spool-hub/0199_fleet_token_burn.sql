-- 0199_fleet_token_burn.sql - near real-time token burn of the fleet's agent
-- lanes (spec 140 section 3, SPL-1986; owner HUM-10, t1 e8ae0aad, poll
-- aa31a0fe). Forward-only. Spec 140 names this file 0198; that number went
-- to 0198_human_rail_order_monitoring.sql first.
--
--   fleet_token_burn_events  one row per (box_tag, agent_id, minute_bucket):
--                            the tokens one agent lane burned in one UTC
--                            minute, as the box collector counted them from
--                            its transcripts, priced at write time against
--                            model_prices (rdb 0171) in force at the minute.
--                            box_tag is the box key of the authenticated
--                            hello, never the frame. A re-sent minute
--                            overwrites its row (ON CONFLICT), never adds.
--                            Kept 30 days (store.FleetTokensRetention).
--   fleet_token_burn_daily   the same per (day_bucket, box_tag, agent_id),
--                            rolled up by the hub's retention sweep before it
--                            prunes the minutes. Kept 365 days.
--
-- These are NOT spec 123's cost_lines (rdb 0166): those are daily counts of
-- the box cost feed; these are per-minute burn for the Monitoring page. The
-- two tables are never summed together.
--
-- Operator scope only: no tenant_id, the rows are the instance's estate. No
-- personal data and no transcript text: ids, model names and counts.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that writes these tables (wf 20 does).

CREATE TABLE fleet_token_burn_events (
    id            bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    box_tag       text          NOT NULL CHECK (box_tag ~ '^[a-z0-9_-]{1,32}$'),
    agent_id      text          NOT NULL CHECK (length(agent_id) BETWEEN 1 AND 100),
    vendor        text          NOT NULL CHECK (vendor IN ('claude', 'mistral', 'grok', 'agy', 'qwen')),
    model         text          NULL CHECK (length(model) BETWEEN 1 AND 200),
    minute_bucket timestamptz   NOT NULL CHECK (date_trunc('minute', minute_bucket) = minute_bucket),
    tokens_in     bigint        NOT NULL DEFAULT 0 CHECK (tokens_in >= 0),
    tokens_out    bigint        NOT NULL DEFAULT 0 CHECK (tokens_out >= 0),
    cache_read    bigint        NOT NULL DEFAULT 0 CHECK (cache_read >= 0),
    cache_write   bigint        NOT NULL DEFAULT 0 CHECK (cache_write >= 0),
    cost_micros   numeric(20,6) NOT NULL DEFAULT 0 CHECK (cost_micros >= 0),
    currency      text          NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
    priced        boolean       NOT NULL DEFAULT false,
    is_metered    boolean       NOT NULL DEFAULT true,
    created_at    timestamptz   NOT NULL DEFAULT now(),
    updated_at    timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT fleet_token_burn_unmetered_check CHECK (is_metered
        OR (tokens_in = 0 AND tokens_out = 0 AND cache_read = 0 AND cache_write = 0 AND cost_micros = 0))
);
CREATE UNIQUE INDEX fleet_token_burn_natural ON fleet_token_burn_events (box_tag, agent_id, minute_bucket);
CREATE INDEX fleet_token_burn_time_vendor ON fleet_token_burn_events (minute_bucket, vendor);
CREATE INDEX fleet_token_burn_time_agent ON fleet_token_burn_events (minute_bucket, agent_id);

CREATE TABLE fleet_token_burn_daily (
    day_bucket    date          NOT NULL,
    box_tag       text          NOT NULL CHECK (box_tag ~ '^[a-z0-9_-]{1,32}$'),
    agent_id      text          NOT NULL CHECK (length(agent_id) BETWEEN 1 AND 100),
    vendor        text          NOT NULL CHECK (vendor IN ('claude', 'mistral', 'grok', 'agy', 'qwen')),
    model         text          NULL CHECK (length(model) BETWEEN 1 AND 200),
    minutes       integer       NOT NULL CHECK (minutes BETWEEN 0 AND 1440),
    tokens_in     bigint        NOT NULL CHECK (tokens_in >= 0),
    tokens_out    bigint        NOT NULL CHECK (tokens_out >= 0),
    cache_read    bigint        NOT NULL CHECK (cache_read >= 0),
    cache_write   bigint        NOT NULL CHECK (cache_write >= 0),
    cost_micros   numeric(24,6) NOT NULL CHECK (cost_micros >= 0),
    currency      text          NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    is_metered    boolean       NOT NULL,
    rolled_at     timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (day_bucket, box_tag, agent_id)
);

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['fleet_token_burn_events', 'fleet_token_burn_daily'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, t);
    END LOOP;
END
$$;
