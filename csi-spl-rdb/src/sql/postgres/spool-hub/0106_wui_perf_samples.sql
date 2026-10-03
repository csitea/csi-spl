-- 0106_wui_perf_samples.sql - the perceived-performance samples of the WUI
-- (spec 066 section 4.1, build lane L1). Forward-only.
--
-- Owner, t1 6e21c7d8 (Q4): "make sure that it does not itself affect the
-- performance of the whole application. Use a proper fire-and-forget thing."
--
--   wui_perf_samples  one row per timing the WUI measured (M1..M8, M6b inp)
--                     and NOTHING else: a dedicated table, nothing else
--                     reads or writes it (spec 4). Append-only, batch
--                     INSERTs from the hub's one ingest writer, no trigger;
--                     the hub's retention sweep deletes rows older than
--                     store.PerfSampleRetention (30 days, owner Q6).
--
-- No personal data (spec 4.2): no user id, email, name, IP, user-agent, URL,
-- topic, channel, message or issue id, no text. tenant_id and at come from
-- the hub (the session and its clock), never from the request body;
-- session_id is a random per-tab value, never tied to the user. Every text
-- column is an enum or a short version-shaped token, so no free text fits.
-- Each CHECK is store/perf_samples.go's allowed set; a store test pins the
-- two together.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that writes this table.

CREATE TABLE wui_perf_samples (
    id           bigserial   PRIMARY KEY,
    at           timestamptz NOT NULL,
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    session_id   uuid        NOT NULL,
    metric       text        NOT NULL CHECK (metric IN ('load_rail', 'load_messages', 'send_ack', 'deliver_visible', 'switch_view', 'type_next_paint', 'inp', 'scroll_jank', 'reconnect_live')),
    value_ms     integer     NOT NULL CHECK (value_ms BETWEEN 0 AND 600000),
    ratio        real        NULL CHECK (ratio BETWEEN 0 AND 1),
    device       text        NOT NULL CHECK (device IN ('phone', 'desktop')),
    view         text        NULL CHECK (view IN ('topic', 'channel', 'dm', 'flow', 'search')),
    cache        text        NULL CHECK (cache IN ('cold', 'warm')),
    outcome      text        NOT NULL CHECK (outcome IN ('ok', 'fail', 'timeout')),
    build        text        NOT NULL DEFAULT '' CHECK (build ~ '^[0-9A-Za-z.+-]{0,40}$'),
    net          text        NULL CHECK (net IN ('slow-2g', '2g', '3g', '4g')),
    clock_err_ms integer     NULL CHECK (clock_err_ms BETWEEN 0 AND 600000),
    hidden_s     text        NULL CHECK (hidden_s IN ('30-300', '300-3600', '3600+'))
);
-- The summary read: one workspace's window.
CREATE INDEX wui_perf_samples_tenant_at ON wui_perf_samples (tenant_id, at);
-- The retention prune: every workspace at once.
CREATE INDEX wui_perf_samples_at ON wui_perf_samples (at);

-- RLS in the 0104 / 0105 shape, with the empty-setting guard (NULLIF).
ALTER TABLE wui_perf_samples ENABLE ROW LEVEL SECURITY;
ALTER TABLE wui_perf_samples FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON wui_perf_samples
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON wui_perf_samples
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
