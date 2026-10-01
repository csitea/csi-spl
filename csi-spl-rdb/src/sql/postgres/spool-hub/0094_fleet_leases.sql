-- 0094_fleet_leases.sql — ONE fleet-wide lease per role across machines
-- (CLE-77911, owner decision "a", t1 5fe56859). Forward-only.
--
-- Exactly one orchestrator and one master dispatcher act at a time across
-- every machine of a fleet (the box PC and the satellite). Each machine's
-- lease loop (do_spl_dispatch_lease LEASE_CMD=fleet) reads the row, and
-- writes it only by compare-and-set on gen: the write names the gen it read,
-- and loses (409, the current row in the answer) when another machine wrote
-- first. The hub stamps renewed_at with ITS clock, and the loops judge a
-- holder silent on age = now() - renewed_at, so the machines' clocks never
-- have to agree.
--
-- holder is "<machine>:<agent id>" as the loop writes it; box is the box
-- that wrote it, from the authenticated hello (an audit column the client
-- cannot choose).
CREATE TABLE fleet_leases (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    fleet      text        NOT NULL CHECK (fleet ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    role       text        NOT NULL CHECK (role ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    holder     text        NOT NULL CHECK (holder ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}:[A-Za-z0-9_-]{1,32}$'),
    box        text        NOT NULL,
    gen        bigint      NOT NULL CHECK (gen > 0),
    renewed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, fleet, role)
);

-- RLS in the 0021 fail-closed NULLIF shape: a tenant reads and writes only
-- its own fleet's rows; the operator scope (spool migrate) sees everything.
ALTER TABLE fleet_leases ENABLE ROW LEVEL SECURITY;
ALTER TABLE fleet_leases FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON fleet_leases
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON fleet_leases
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
