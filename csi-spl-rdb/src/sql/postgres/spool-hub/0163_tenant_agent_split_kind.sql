-- 0163_tenant_agent_split_kind.sql - the vendor split per task kind, one row
-- per (workspace, kind, vendor) (spec 115 RDB-1, sections 2 and 3.2).
-- Forward-only, additive: 0109's and 0155's five tenants.agent_split_* columns
-- stay until the WUI settings screen moves here (spec 115 section 7.4).
--
-- A vendor with no row in a kind is 0 there. A kind with no row at all is
-- not set by the workspace: the reader falls back to the cnf
-- env.box.agent_split_by_kind row. No seed rows.
--
-- The table rules of spec 115 section 2:
--   per row (CHECK, immediate)
--     tenant_agent_split_kind_kind_check      the six kinds; the aliases
--                                             (spec, hard, default) are the
--                                             picker's, never stored
--     tenant_agent_split_kind_vendor_check    the five vendors
--     tenant_agent_split_kind_weight_check    0..100
--     tenant_agent_split_kind_no_agy_coding   agy writes no code: 0 and never
--                                             the backup in tests,
--                                             simple_coding, complex_coding
--     tenant_agent_split_kind_secret_vendors  secret: only claude and mistral
--                                             may be non-zero or the backup
--   per kind (deferred constraint trigger, at commit)
--     tenant_agent_split_kind_rules           the kind's weights sum to 100,
--                                             one vendor holds the strict
--                                             maximum (main is never a tie),
--                                             exactly one backup, and the
--                                             backup is not the main
-- The per-kind rules are deferred, so a PATCH rewrites a kind's rows in any
-- order inside one transaction.
-- DEPLOY ORDER: apply on dev AND prd BEFORE the hub that reads it (HUB-1).

CREATE TABLE tenant_agent_split_kind (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    kind       text        NOT NULL,
    vendor     text        NOT NULL,
    weight     smallint    NOT NULL,
    is_backup  boolean     NOT NULL DEFAULT false,
    updated_by text        NOT NULL DEFAULT '' CHECK (length(updated_by) <= 200),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tenant_agent_split_kind_pkey PRIMARY KEY (tenant_id, kind, vendor),
    CONSTRAINT tenant_agent_split_kind_kind_check
        CHECK (kind IN ('specs_and_docs', 'tests', 'simple_coding', 'complex_coding', 'i18n', 'secret')),
    CONSTRAINT tenant_agent_split_kind_vendor_check
        CHECK (vendor IN ('claude', 'grok', 'agy', 'qwen', 'mistral')),
    CONSTRAINT tenant_agent_split_kind_weight_check CHECK (weight BETWEEN 0 AND 100),
    CONSTRAINT tenant_agent_split_kind_no_agy_coding
        CHECK (NOT (vendor = 'agy' AND kind IN ('tests', 'simple_coding', 'complex_coding')
                    AND (weight > 0 OR is_backup))),
    CONSTRAINT tenant_agent_split_kind_secret_vendors
        CHECK (kind <> 'secret' OR vendor IN ('claude', 'mistral') OR (weight = 0 AND NOT is_backup))
);

-- RLS in the 0021 fail-closed NULLIF shape (the 0107 pair).
ALTER TABLE tenant_agent_split_kind ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_agent_split_kind FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON tenant_agent_split_kind
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON tenant_agent_split_kind
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- The per-kind rules, checked per changed (tenant, kind) at commit. It runs
-- as the caller, under the same policies: the rows it reads are the writer's
-- own tenant's. A kind left with no row is valid (not set).
CREATE FUNCTION tenant_agent_split_kind_rules() RETURNS trigger
    LANGUAGE plpgsql AS $$
DECLARE
    k        record;
    n        int;
    tot      int;
    top      int;
    mains    int;
    backups  int;
    backup_w int;
BEGIN
    FOR k IN
        SELECT DISTINCT v.t, v.kd FROM (VALUES
            (CASE WHEN TG_OP <> 'DELETE' THEN NEW.tenant_id END, CASE WHEN TG_OP <> 'DELETE' THEN NEW.kind END),
            (CASE WHEN TG_OP <> 'INSERT' THEN OLD.tenant_id END, CASE WHEN TG_OP <> 'INSERT' THEN OLD.kind END)
        ) v (t, kd) WHERE v.t IS NOT NULL
    LOOP
        SELECT count(*), COALESCE(sum(weight), 0), COALESCE(max(weight), 0),
               count(*) FILTER (WHERE is_backup), max(weight) FILTER (WHERE is_backup)
          INTO n, tot, top, backups, backup_w
          FROM tenant_agent_split_kind WHERE tenant_id = k.t AND kind = k.kd;
        CONTINUE WHEN n = 0;
        SELECT count(*) INTO mains
          FROM tenant_agent_split_kind WHERE tenant_id = k.t AND kind = k.kd AND weight = top;
        IF tot <> 100 THEN
            RAISE EXCEPTION 'agent split kind %: the weights sum to %, want 100', k.kd, tot
                USING ERRCODE = 'check_violation', CONSTRAINT = 'tenant_agent_split_kind_rules';
        END IF;
        IF mains <> 1 THEN
            RAISE EXCEPTION 'agent split kind %: % vendors tie at %, want one main', k.kd, mains, top
                USING ERRCODE = 'check_violation', CONSTRAINT = 'tenant_agent_split_kind_rules';
        END IF;
        IF backups <> 1 THEN
            RAISE EXCEPTION 'agent split kind %: % backups, want exactly one', k.kd, backups
                USING ERRCODE = 'check_violation', CONSTRAINT = 'tenant_agent_split_kind_rules';
        END IF;
        IF backup_w = top THEN
            RAISE EXCEPTION 'agent split kind %: the backup is the main', k.kd
                USING ERRCODE = 'check_violation', CONSTRAINT = 'tenant_agent_split_kind_rules';
        END IF;
    END LOOP;
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER tenant_agent_split_kind_rules
    AFTER INSERT OR UPDATE OR DELETE ON tenant_agent_split_kind
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION tenant_agent_split_kind_rules();
