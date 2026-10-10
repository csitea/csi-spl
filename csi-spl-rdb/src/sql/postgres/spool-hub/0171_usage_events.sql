-- 0171_usage_events.sql - the metering ledger, the model prices and the
-- token budgets (specs/121 T301, sections 7, 8, 8.1). Forward-only, additive.
--
-- 1. usage_events: the append-only ledger. One row per metered quantity:
--    the workspace (tenant_id) always, the channel, agent, human and the
--    hub's turn_id when known (no FK on them: a visitor channel removed after
--    30 days, or a deleted visitor HUM, must not take the money record with
--    it). kind is one of section 7's kinds plus 'unmetered': a turn the
--    seat never reported. An unmetered row has NO units, cost or currency
--    (all NULL) and names its turn, so a sum never reads a gap as zero; every
--    other row has all three. unit_cost_micros is the price of ONE unit in
--    micros of currency, copied from model_prices at write time
--    (micros_per_million / 10^6, exact in numeric(20,6)), so an old balance
--    re-prices the same after a price change. One row per (tenant, turn,
--    kind): a re-sent report is a conflict, never a second charge.
--    Append-only: an UPDATE is refused always, a DELETE always except the
--    cascade of a tenant delete (the FK's RI trigger runs it, so the row
--    trigger sees pg_trigger_depth() > 1; a statement a session sends is
--    depth 1). TestCrossTenantEveryTable expects the "append-only" refusal.
-- 2. model_prices: the price per million units by (provider, model, kind)
--    from valid_from on. Hub-wide, no tenant: a price change is a NEW row
--    (do_spl_model_prices_sync, T303); the price in force at t is the row
--    with the latest valid_from <= t. Every workspace scope reads it (the hub
--    copies the price into its own workspace's event); only the operator
--    scope writes it (the cost_coverage shape of rdb 0166).
-- 3. token_budgets: the limits of a workspace, or of one of its channels or
--    visitors (at most one of the two; both NULL = the workspace): tokens
--    per day, per month, and/or the prepaid balance of section 8 (the last
--    top-up and when; the balance is that minus the priced ledger since).
--    hard_stop defaults on (section 7: soft only for an approved customer);
--    auto top-up defaults OFF and needs its cap (8.1: never nudge spend);
--    low_notice_at stamps the one 80 % notice. One budget per scope (UNIQUE
--    NULLS NOT DISTINCT, PG 15+; dev and prd run 16).
--
-- RLS: usage_events and token_budgets in the 0014/0021 shape with the NULLIF
-- guard; store TestRLSPoliciesFailClosed (rls_failclosed_test.go) reads them
-- from the catalogue and TestCrossTenantEveryTable seeds them
-- (usage_rls_test.go). Runtime grants: the default privileges of
-- spool-hub-roles/runtime-grants.sql. No channel_scope policy: a visitor
-- session never reads the ledger (the 8.1 counter is a member's).
--
-- Live-data safety: three new empty tables; the FKs take a SHARE ROW
-- EXCLUSIVE lock on tenants until COMMIT, hence lock_timeout. No running hub
-- reads them (T302..T304 do, later). DEPLOY ORDER: wf 20 applies this before
-- the image that reads it. Runs under the operator RLS scope (spool migrate,
-- rdb 0014). No personal data, no secret.

SET LOCAL lock_timeout = '5s';

CREATE TABLE usage_events (
    id               bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id        text          NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    channel_id       text          NULL CHECK (length(channel_id) BETWEEN 1 AND 200),
    agent_id         text          NULL CHECK (length(agent_id) BETWEEN 1 AND 100),
    human_id         text          NULL CHECK (length(human_id) BETWEEN 1 AND 200),
    turn_id          text          NULL CHECK (length(turn_id) BETWEEN 1 AND 100),
    kind             text          NOT NULL CHECK (kind IN ('llm_tokens_in', 'llm_tokens_out', 'llm_tokens_cache_read',
                                       'llm_tokens_cache_write', 'agent_seconds', 'storage_bytes', 'cloud_share', 'unmetered')),
    provider         text          NULL CHECK (provider ~ '^[a-z][a-z0-9_.-]{0,63}$'),
    model            text          NULL CHECK (length(model) BETWEEN 1 AND 200),
    units            numeric       NULL CHECK (units >= 0),
    unit_cost_micros numeric(20,6) NULL CHECK (unit_cost_micros >= 0),
    currency         text          NULL CHECK (currency ~ '^[A-Z]{3}$'),
    at               timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT usage_events_metered_check CHECK (CASE WHEN kind = 'unmetered'
        THEN units IS NULL AND unit_cost_micros IS NULL AND currency IS NULL AND turn_id IS NOT NULL
        ELSE units IS NOT NULL AND unit_cost_micros IS NOT NULL AND currency IS NOT NULL END),
    CONSTRAINT usage_events_llm_model_check CHECK (kind NOT LIKE 'llm\_%' OR (provider IS NOT NULL AND model IS NOT NULL))
);
-- The 8.1 counter and the 429 check read a workspace's rows since its top-up.
CREATE INDEX usage_events_tenant_at ON usage_events (tenant_id, at);
CREATE UNIQUE INDEX usage_events_turn_kind ON usage_events (tenant_id, turn_id, kind) WHERE turn_id IS NOT NULL;

CREATE TABLE model_prices (
    provider           text        NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_.-]{0,63}$'),
    model              text        NOT NULL CHECK (length(model) BETWEEN 1 AND 200),
    kind               text        NOT NULL CHECK (kind IN ('llm_tokens_in', 'llm_tokens_out', 'llm_tokens_cache_read',
                                       'llm_tokens_cache_write', 'agent_seconds', 'storage_bytes', 'cloud_share')),
    micros_per_million bigint      NOT NULL CHECK (micros_per_million >= 0),
    currency           text        NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    valid_from         timestamptz NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, model, kind, valid_from)
);

CREATE TABLE token_budgets (
    id                    bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id             text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    channel_id            text        NULL CHECK (length(channel_id) BETWEEN 1 AND 200),
    visitor_id            uuid        NULL,
    tokens_per_day        bigint      NULL CHECK (tokens_per_day >= 0),
    tokens_per_month      bigint      NULL CHECK (tokens_per_month >= 0),
    topup_micros          bigint      NULL CHECK (topup_micros >= 0),
    topup_currency        text        NULL CHECK (topup_currency ~ '^[A-Z]{3}$'),
    topped_up_at          timestamptz NULL,
    hard_stop             boolean     NOT NULL DEFAULT true,
    auto_topup            boolean     NOT NULL DEFAULT false,
    auto_topup_cap_micros bigint      NULL CHECK (auto_topup_cap_micros > 0),
    low_notice_at         timestamptz NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT token_budgets_one_scope_check CHECK (channel_id IS NULL OR visitor_id IS NULL),
    CONSTRAINT token_budgets_some_limit_check CHECK (tokens_per_day IS NOT NULL OR tokens_per_month IS NOT NULL OR topup_micros IS NOT NULL),
    CONSTRAINT token_budgets_topup_check CHECK ((topup_micros IS NULL) = (topup_currency IS NULL)
                                                AND (topup_micros IS NULL) = (topped_up_at IS NULL)),
    CONSTRAINT token_budgets_auto_topup_cap_check CHECK (NOT auto_topup OR auto_topup_cap_micros IS NOT NULL)
);
CREATE UNIQUE INDEX token_budgets_scope ON token_budgets (tenant_id, channel_id, visitor_id) NULLS NOT DISTINCT;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['usage_events', 'token_budgets'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, t);
    END LOOP;
END
$$;

ALTER TABLE model_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE model_prices FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON model_prices FOR SELECT
    USING (NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL);
CREATE POLICY operator_scope ON model_prices
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- Append-only ledger: no UPDATE ever; a DELETE only as a tenant delete's cascade.
CREATE FUNCTION usage_events_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'usage_events is append-only: % refused (only a tenant delete removes rows)', TG_OP;
END $$;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON usage_events
    FOR EACH ROW EXECUTE FUNCTION usage_events_append_only();
