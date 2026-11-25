-- 0326_tax_documents.sql - the hub tables of the Costs > Taxes page
-- (spec 143 taxes-tab.md v0.2 sections 3 and 4, build slice S1, SPL-6438;
-- owner HUM-10, csitea topic dc7c9c9a, msg fc8f964e: "Every person of
-- csitea; agents never", "Weekly, after the weekly tax check").
-- Forward-only, additive.
--
--   tax_snapshots   one row per sync of the main box's tax index (the
--                   private tax project's <year>/index.tsv): the tax year,
--                   when it was taken, its row count and the service
--                   account that filed it.
--   tax_documents   one row per index row of a snapshot: arrival date,
--                   kind, type, tax type, period, due date, category and
--                   the document's content sha256 (it tells "changed" from
--                   "new"; it is not the document). NO column for an
--                   amount, a business id, a tax number, a file name, a
--                   personal name or an address: the index carries no
--                   amount, and the documents stay on the main box.
--
-- RLS: the 0240 tenant_scope on both tables, plus RESTRICTIVE policies:
--
--   tax_read    FOR SELECT: the ingest scope (app.rls_scope = 'tax_ingest',
--               store inTaxIngest, the operator sync) OR a person seat
--               (tax_person_seat(): a live membership of app.human_id in
--               app.tenant_id, not disabled, not past access_until, its
--               human not disabled and not technical (an act-as clone),
--               not a channel guest, and at least one role that is neither
--               pure_agent nor time_accountant: rdb 0260's rule, in its own
--               function so the Finance and Taxes pages can part later).
--   tax_insert, tax_update, tax_delete
--               the ingest scope only: no browser session writes a row.
--
-- NO operator_scope policy: the operator scope, the ops psql and the
-- Reporting SQL tab (its relation list skips a table whose policy names
-- app.human_id) read 0 rows. The store sets app.human_id for these tables
-- only from an authenticated person's browser session (hub taxReader).
--
-- A tenant delete cascades both tables (FK ON DELETE CASCADE; an RI action
-- is not subject to RLS); a snapshot delete cascades its documents (the
-- 26-week prune). Backups: a pg_dump under the operator scope holds no row;
-- the weekly sync refiles the newest snapshot. Store tests: tax_test.go,
-- rls_test.go, crosstenant_test.go, rls_failclosed_test.go (catalogue).
--
-- Live-data safety: two new empty tables; the FK takes a SHARE ROW
-- EXCLUSIVE lock on tenants until COMMIT, hence lock_timeout. No running
-- hub reads them. DEPLOY ORDER: wf 20 applies this before the image that
-- reads it. Nothing is seeded.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS tax_snapshots (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    snapshot_id uuid        NOT NULL,
    tax_year    integer     NOT NULL CHECK (tax_year BETWEEN 2000 AND 2100),
    taken_at    timestamptz NOT NULL,
    row_count   integer     NOT NULL CHECK (row_count BETWEEN 0 AND 10000),
    filed_by    text        NOT NULL CHECK (length(filed_by) BETWEEN 1 AND 200),
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, snapshot_id)
);
CREATE INDEX IF NOT EXISTS ix_tax_snapshots_latest
    ON tax_snapshots (tenant_id, tax_year, taken_at DESC);

CREATE TABLE IF NOT EXISTS tax_documents (
    tenant_id      text    NOT NULL,
    snapshot_id    uuid    NOT NULL,
    row_no         integer NOT NULL CHECK (row_no >= 0),
    arrival_date   date    NOT NULL,
    kind           text    NOT NULL DEFAULT '' CHECK (length(kind) <= 80),
    doc_type       text    NOT NULL DEFAULT '' CHECK (length(doc_type) <= 80),
    tax_type       text    NOT NULL DEFAULT '' CHECK (length(tax_type) <= 80),
    period         text    NOT NULL DEFAULT '' CHECK (length(period) <= 80),
    due_date       date    NULL,
    category       text    NOT NULL CHECK (category IN ('decisions', 'payments', 'balance', 'msgs')),
    content_sha256 text    NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    PRIMARY KEY (tenant_id, snapshot_id, row_no),
    CONSTRAINT fk_tax_documents_snapshot FOREIGN KEY (tenant_id, snapshot_id)
        REFERENCES tax_snapshots (tenant_id, snapshot_id) ON DELETE CASCADE
);

-- The person test lives in a function, as rdb 0260's netvisor_person_seat:
-- a string body records no column dependency, and it runs as the caller, so
-- tenant_memberships' own RLS still applies.
CREATE OR REPLACE FUNCTION public.tax_person_seat()
    RETURNS boolean
    LANGUAGE sql STABLE COST 1
    SET search_path = pg_catalog, public, pg_temp
AS $fn$
    SELECT EXISTS (SELECT 1 FROM public.tenant_memberships m JOIN public.humans h ON h.human_id = m.human_id
        WHERE m.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
          AND m.human_id = NULLIF(current_setting('app.human_id', true), '')
          AND m.disabled_at IS NULL AND h.disabled_at IS NULL AND NOT h.technical
          AND (m.access_until IS NULL OR m.access_until > now())
          AND m.role <> 'channel_guest'
          AND EXISTS (SELECT 1 FROM (SELECT m.role UNION ALL SELECT x.role_id FROM public.tenant_member_roles x
                                     WHERE x.tenant_id = m.tenant_id AND x.human_id = m.human_id) AS r (role)
                      WHERE r.role NOT IN ('pure_agent', 'time_accountant')))
$fn$;

DO $$
DECLARE
    t      text;
    ingest text := $c$current_setting('app.rls_scope', true) = 'tax_ingest'$c$;
    person text := $c$(NULLIF(current_setting('app.human_id', true), '') IS NOT NULL AND tax_person_seat())$c$;
BEGIN
    FOREACH t IN ARRAY ARRAY['tax_snapshots', 'tax_documents'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_scope ON %I', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
        EXECUTE format('DROP POLICY IF EXISTS tax_read ON %I', t);
        EXECUTE format('CREATE POLICY tax_read ON %1$I AS RESTRICTIVE FOR SELECT USING (%2$s OR %3$s)', t, ingest, person);
        EXECUTE format('DROP POLICY IF EXISTS tax_insert ON %I', t);
        EXECUTE format('CREATE POLICY tax_insert ON %1$I AS RESTRICTIVE FOR INSERT WITH CHECK (%2$s)', t, ingest);
        EXECUTE format('DROP POLICY IF EXISTS tax_update ON %I', t);
        EXECUTE format('CREATE POLICY tax_update ON %1$I AS RESTRICTIVE FOR UPDATE USING (%2$s) WITH CHECK (%2$s)', t, ingest);
        EXECUTE format('DROP POLICY IF EXISTS tax_delete ON %I', t);
        EXECUTE format('CREATE POLICY tax_delete ON %1$I AS RESTRICTIVE FOR DELETE USING (%2$s)', t, ingest);
    END LOOP;
END
$$;
