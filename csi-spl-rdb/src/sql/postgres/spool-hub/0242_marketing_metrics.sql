-- 0242_marketing_metrics.sql - the marketing metrics store and its
-- definitions (spec 163 v0.2 section 1, G1 + G2, build row B1, SPL-4250;
-- owner HUM-10, csitea topic b13f7763, poll 337fb605, msg 449350b3: Q1
-- Spool Hub's own marketing first, Q7 last touch over 28 days, Q8 workspace
-- admins and the owner only). Forward-only, additive: two new tables,
-- nothing altered. The spec names "the next free number at build time".
--
--   marketing_metric_samples      G1: the raw numbers a platform reports,
--                                 one row per fetch, the value unchanged.
--                                 A re-fetch ADDS a row; the read takes the
--                                 newest per key (source, object_type,
--                                 object_ref, metric, period_start,
--                                 period_end), store/marketing_metrics.go.
--                                 post_id names a marketing_posts row (rdb
--                                 0187) but carries no FK, as
--                                 marketing_post_events: no post delete
--                                 reaches a sample, and the append-only
--                                 trigger would refuse the SET NULL anyway.
--   marketing_metric_definitions  G2: per workspace and metric, the formula
--                                 and its parameters, versioned. A changed
--                                 definition, a sign-off included, is a NEW
--                                 version, never an edit. The attribution
--                                 columns default to the owner's Q7 answer:
--                                 last_touch, 28 days. A metric whose newest
--                                 version is not signed off shows
--                                 "definition not agreed" (the WUI's rule).
--
-- Both are append-only (the 0187 marketing_post_events trigger shape): no
-- UPDATE; a DELETE only as a tenant delete's cascade. RLS in the 0240 shape:
-- tenant_scope with the NULLIF guard (CLE-3416) plus operator_scope, so a
-- statement without a tenant reads and writes no row. Who reads them is the
-- hub's check (GET /v1/reporting/marketing: the workspace owner or an admin,
-- Q8). No personal data, no secret: numbers, formulas and a HUM id. The
-- runtime grants come from spool-hub-roles/runtime-grants.sql's default
-- privileges. DEPLOY ORDER: wf 20 applies this file before it rolls the hub
-- that reads either table.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS marketing_metric_samples (
    sample_id    bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    source       text        NOT NULL CHECK (source ~ '^[a-z][a-z0-9_]{0,31}$'),
    object_type  text        NOT NULL CHECK (object_type IN ('post', 'page', 'campaign', 'site', 'landing_page', 'query', 'email')),
    object_ref   text        NOT NULL DEFAULT '' CHECK (length(object_ref) <= 512),
    post_id      uuid        NULL,
    metric       text        NOT NULL CHECK (metric ~ '^[a-z][a-z0-9_]{0,47}$'),
    value        numeric     NOT NULL,
    unit         text        NOT NULL DEFAULT 'count' CHECK (unit ~ '^[a-z][a-z0-9_]{0,15}$'),
    period_start timestamptz NOT NULL,
    period_end   timestamptz NOT NULL,
    fetched_at   timestamptz NOT NULL DEFAULT now(),
    run_id       text        NOT NULL DEFAULT '' CHECK (length(run_id) <= 128),
    CONSTRAINT ck_marketing_metric_samples_period CHECK (period_end >= period_start)
);
-- the read: the newest sample per key of one workspace
CREATE INDEX IF NOT EXISTS ix_marketing_metric_samples_key
    ON marketing_metric_samples (tenant_id, source, object_type, object_ref, metric, period_start, period_end, fetched_at DESC, sample_id DESC);

CREATE TABLE IF NOT EXISTS marketing_metric_definitions (
    tenant_id               text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    metric                  text        NOT NULL CHECK (metric ~ '^[a-z][a-z0-9_]{0,47}$'),
    version                 integer     NOT NULL CHECK (version >= 1),
    formula                 text        NOT NULL DEFAULT '' CHECK (length(formula) <= 2000),
    attribution_rule        text        NOT NULL DEFAULT 'last_touch' CHECK (attribution_rule IN ('last_touch')),
    attribution_window_days integer     NOT NULL DEFAULT 28 CHECK (attribution_window_days BETWEEN 1 AND 365),
    params                  jsonb       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(params) = 'object'),
    signed_off_by           text        NULL CHECK (signed_off_by ~ '^HUM-[0-9]+$'),
    signed_off_at           timestamptz NULL,
    created_by              text        NOT NULL DEFAULT '' CHECK (length(created_by) <= 64),
    created_at              timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, metric, version),
    CONSTRAINT ck_marketing_metric_definitions_signed CHECK ((signed_off_by IS NULL) = (signed_off_at IS NULL))
);

-- Append-only: no UPDATE ever; a DELETE only as a tenant delete's cascade.
CREATE OR REPLACE FUNCTION marketing_metrics_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION '% is append-only: % refused (only a tenant delete removes rows)', TG_TABLE_NAME, TG_OP;
END $$;
DROP TRIGGER IF EXISTS append_only ON marketing_metric_samples;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON marketing_metric_samples
    FOR EACH ROW EXECUTE FUNCTION marketing_metrics_append_only();
DROP TRIGGER IF EXISTS append_only ON marketing_metric_definitions;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON marketing_metric_definitions
    FOR EACH ROW EXECUTE FUNCTION marketing_metrics_append_only();

ALTER TABLE marketing_metric_samples ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_metric_samples FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON marketing_metric_samples;
CREATE POLICY tenant_scope ON marketing_metric_samples
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON marketing_metric_samples;
CREATE POLICY operator_scope ON marketing_metric_samples
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE marketing_metric_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_metric_definitions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON marketing_metric_definitions;
CREATE POLICY tenant_scope ON marketing_metric_definitions
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON marketing_metric_definitions;
CREATE POLICY operator_scope ON marketing_metric_definitions
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
