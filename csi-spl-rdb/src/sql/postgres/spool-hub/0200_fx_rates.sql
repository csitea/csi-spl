-- 0200_fx_rates.sql - daily exchange rates for the costs' second currency
-- (SPL-2108). Forward-only. Owner HUM-10, t1 1b6f871f msg 44fef397: the cost
-- table shows a second currency, a personal setting (default EUR), converted
-- at the day's rate from the ECB (European currencies) or the Federal Reserve
-- (every other currency); dispatcher answer a81b348c: the rate of the cost's
-- own day, else the last one published before it, and the rate's date shown.
--
--   fx_rates  one row per (day, quote, source): how many units of quote one
--             USD bought that day. ECB rows are its EUR-based reference rates
--             turned USD-based through the same day's EUR/USD; FED rows are
--             the H.10 noon buying rates. Written by do_spl_fx_rates_fetch
--             (csi-spl-orc) through POST /v1/operator/fx/rates, an UPSERT on
--             the key, so a re-fetch of a day is a no-op.
--
-- Hub-wide reference data, no workspace's: any workspace scope reads it (the
-- cost read converts under the caller's tenant scope), only the operator
-- writes it (the 0171 model_prices shape). The running image reads none of
-- this, so the file applies before the image that does. DEPLOY ORDER: wf 20
-- applies it.

CREATE TABLE fx_rates (
    day        date        NOT NULL,
    base       text        NOT NULL DEFAULT 'USD' CHECK (base = 'USD'),
    quote      text        NOT NULL CHECK (quote ~ '^[A-Z]{3}$' AND quote <> 'USD'),
    rate       numeric     NOT NULL CHECK (rate > 0),
    source     text        NOT NULL CHECK (source IN ('ECB', 'FED')),
    fetched_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (day, quote, source)
);
-- The cost read's lookup: the last day on or before a cost day, per quote.
CREATE INDEX fx_rates_quote_day ON fx_rates (quote, day DESC);

ALTER TABLE fx_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE fx_rates FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON fx_rates FOR SELECT
    USING (NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL);
CREATE POLICY operator_scope ON fx_rates
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
