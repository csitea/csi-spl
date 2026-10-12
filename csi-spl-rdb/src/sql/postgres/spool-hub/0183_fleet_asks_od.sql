-- 0183_fleet_asks_od.sql - the OD pool's job rows: fleet_asks role 'od'
-- (spec 134 v1.0 sections 3.1-3.3, step P1; SPL-1569). Forward-only.
--
-- Owner HUM-10, t1 e799211c: every OD job (an owner post to route, a spawn
-- request, an ACCEPTED to verify and its lane to close, a box op) is ONE row,
-- and any able seat locks it, works it and closes it. The rows live in
-- fleet_asks with role = 'od' (owner question Q1): the ask book's orch and
-- dispatch rows keep the tick's 60-minute lock, and the new hub ops touch
-- only role 'od' rows, so the two lock regimes never mix.
--
--   open -> acked (lock-next: gen + 1, lock_until = now + lease_s)
--        -> done | declined                (the holder, its gen)
--   acked -> acked by renew                (the holder, its gen: lock_until moves)
--   acked -> open by release               (the holder's gen, or every row of a
--                                           killed seat; gen + 1 fences it)
--   acked, lock_until passed -> acked by another seat's lock-next (lazy
--        expiry: raised_n + 1; at the 4th lost lock the row goes dead)
--   needs_owner -> open | declined         (a human answers; never lockable)
--
-- Every new column has a constant default, so no row is rewritten; nothing
-- on trunk reads them before the P2 ops. The CHECKs scan the table once (a
-- few hundred rows).
ALTER TABLE fleet_asks ADD COLUMN lock_until timestamptz;
ALTER TABLE fleet_asks ADD COLUMN lease_s integer NOT NULL DEFAULT 120
    CHECK (lease_s BETWEEN 15 AND 86400);
ALTER TABLE fleet_asks ADD COLUMN gen bigint NOT NULL DEFAULT 0 CHECK (gen >= 0);
ALTER TABLE fleet_asks ADD COLUMN dedupe_key text NOT NULL DEFAULT ''
    CHECK (length(dedupe_key) <= 200 AND dedupe_key !~ '[[:cntrl:]]');
ALTER TABLE fleet_asks ADD COLUMN issue_key text NOT NULL DEFAULT ''
    CHECK (issue_key ~ '^([A-Z][A-Z0-9]{1,9}-[0-9]{1,9})?$');
ALTER TABLE fleet_asks ADD COLUMN vendor_allow text NOT NULL DEFAULT ''
    CHECK (vendor_allow IN ('', 'claude', 'grok'));
ALTER TABLE fleet_asks ADD COLUMN needs text NOT NULL DEFAULT ''
    CHECK (needs ~ '^(box:[a-z0-9][a-z0-9-]{0,31}|prd)?$');
ALTER TABLE fleet_asks ADD COLUMN not_by text[] NOT NULL DEFAULT '{}'
    CHECK (cardinality(not_by) <= 16);

-- The pool's job kinds next to the book's three; a row's role decides which
-- set it may carry (the hub refuses a mix: store.CheckFleetAsk, CheckOdJob).
ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_kind_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_kind_check
    CHECK (kind IN ('blocker', 'task', 'escalation', 'route_post', 'spawn', 'lane_verify', 'box_op'));

ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_state_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_state_check
    CHECK (state IN ('open', 'acked', 'queued', 'needs_owner', 'done', 'declined', 'dead'));

-- A second open insert of the same job conflicts; a closed one does not block
-- the next (s134-grok).
CREATE UNIQUE INDEX fleet_asks_od_dedupe ON fleet_asks (tenant_id, fleet, kind, dedupe_key)
    WHERE state IN ('open', 'acked', 'needs_owner') AND dedupe_key <> '';

-- lock-next's read: the pool's open and locked rows, oldest first.
CREATE INDEX fleet_asks_od_live ON fleet_asks (tenant_id, fleet, created_at, ask_id)
    WHERE role = 'od' AND state IN ('open', 'acked');

-- One row per tenant and fleet: the pool's target and the kinds it consumes
-- (spec 134 3.1). No row reads as the defaults below with kinds empty: no
-- seat locks anything until a kind is listed (P6, one kind per push).
-- vendor_out / out_until: the vendor that is out and until when (4.3), ''
-- and NULL while both are in. Written only under the fleet-config mutex
-- (P3); the hub stamps the writer and its box.
CREATE TABLE od_pool (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    fleet      text        NOT NULL CHECK (fleet ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    claude_n   integer     NOT NULL DEFAULT 2 CHECK (claude_n BETWEEN 0 AND 16),
    grok_n     integer     NOT NULL DEFAULT 2 CHECK (grok_n BETWEEN 0 AND 16),
    min_boxes  integer     NOT NULL DEFAULT 2 CHECK (min_boxes BETWEEN 1 AND 16),
    vendor_out text        NOT NULL DEFAULT '' CHECK (vendor_out IN ('', 'claude', 'grok')),
    out_until  timestamptz,
    kinds      text[]      NOT NULL DEFAULT '{}'
        CHECK (kinds <@ ARRAY['route_post', 'spawn', 'lane_verify', 'box_op']::text[]),
    updated_by text        NOT NULL DEFAULT '',
    writer_box text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, fleet)
);

ALTER TABLE od_pool ENABLE ROW LEVEL SECURITY;
ALTER TABLE od_pool FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON od_pool
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON od_pool
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
