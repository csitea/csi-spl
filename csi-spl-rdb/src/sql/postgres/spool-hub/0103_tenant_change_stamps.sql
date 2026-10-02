-- 0103_tenant_change_stamps.sql - a per-tenant change stamp the hub reads
-- BEFORE a view's data reads (DB payload round 2, R2-5). Forward-only.
--
-- Why: a repeat view read (focus, catch-up, a revision re-dial) ran every DB
-- read of the view only to hash the body and answer 304 (~3..5 round trips,
-- ~10..27 ms). With this stamp the hub answers an unchanged read after ONE
-- small read (hub/view_stamp.go).
--
-- Invariant: every committed transaction that writes a row of the tables
-- below adds at least 1 to its tenant's SUM(n), in that same transaction. So
-- an equal SUM means no such write committed in between. The bump is a
-- trigger, not a call in each Go writer: a writer added later is covered
-- without anyone remembering it, and so is a write by hand (psql).
--
-- The triggers are DEFERRABLE INITIALLY DEFERRED constraint triggers: the
-- bump runs at COMMIT, so the stamp row lock is the LAST lock a transaction
-- takes and is held only for the commit (no lock-order deadlock with the
-- rows the transaction wrote before it). They are row-level (constraint
-- triggers must be), so app.change_stamped makes one transaction bump a
-- tenant once.
--
-- slot spreads one tenant's counter over 16 rows (as 0023 does), so two
-- concurrent commits rarely wait on the same row. A SUM, never a MAX: a
-- sequence value is not commit-ordered, a sum of increments is.
--
-- changed_at is the DB clock at the bump: the hub mints a stamp validator
-- only once the last change is older than its in-process cache TTL, so a
-- body built from another instance's cached door read is never pinned.
--
-- The stamp write runs in app.rls_scope = operator, set and then restored
-- inside the function (a function SET clause on a custom setting needs a
-- superuser, which the schema owner is not): a cascade from another table (a
-- human or a tenant deleted) or an operator sweep bumps whatever tenant its
-- rows belong to. A tenant deleted in the same transaction is skipped (its
-- stamp rows cascade away).
--
-- DEPLOY ORDER: apply this file BEFORE the hub that reads the table. The old
-- hub ignores it; the triggers keep it right under either hub.

CREATE TABLE tenant_change_stamps (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    slot       smallint    NOT NULL CHECK (slot BETWEEN 0 AND 15),
    n          bigint      NOT NULL,
    changed_at timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, slot)
);

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF, CLE-3416).
ALTER TABLE tenant_change_stamps ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_change_stamps FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON tenant_change_stamps
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON tenant_change_stamps
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- Every tenant at once: a global row (an rbac role or grant every tenant uses).
CREATE FUNCTION tenant_change_bump_every() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    scope text := coalesce(current_setting('app.rls_scope', true), '');
BEGIN
    PERFORM set_config('app.rls_scope', 'operator', true);
    UPDATE tenant_change_stamps SET n = n + 1, changed_at = clock_timestamp();
    PERFORM set_config('app.rls_scope', scope, true);
END
$$;

CREATE FUNCTION tenant_change_bump_one(tn text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    done  text := coalesce(current_setting('app.change_stamped', true), '');
    scope text := coalesce(current_setting('app.rls_scope', true), '');
BEGIN
    IF tn IS NULL THEN
        PERFORM tenant_change_bump_every();
        RETURN;
    END IF;
    IF position(chr(31) || tn || chr(31) IN done) > 0 THEN
        RETURN;
    END IF;
    PERFORM set_config('app.rls_scope', 'operator', true);
    IF EXISTS (SELECT 1 FROM tenants WHERE tenant_id = tn) THEN
        INSERT INTO tenant_change_stamps (tenant_id, slot, n, changed_at)
        VALUES (tn, floor(random() * 16)::smallint, 1, clock_timestamp())
        ON CONFLICT (tenant_id, slot)
            DO UPDATE SET n = tenant_change_stamps.n + 1, changed_at = EXCLUDED.changed_at;
    END IF;
    PERFORM set_config('app.rls_scope', scope, true);
    PERFORM set_config('app.change_stamped', done || chr(31) || tn || chr(31), true);
END
$$;

CREATE FUNCTION tenant_change_bump() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM tenant_change_bump_one(OLD.tenant_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM tenant_change_bump_one(NEW.tenant_id);
    END IF;
    RETURN NULL;
END
$$;

CREATE FUNCTION tenant_change_bump_all() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM tenant_change_bump_every();
    RETURN NULL;
END
$$;

-- The tenant tables a covered view (topics, one topic, children, channels,
-- archived) reads or is gated by. Left out on purpose: roster / boxes / pins
-- (only the roster view reads them, and it is not covered: its online flag is
-- process memory), fallback_deliveries, human_events, member_activity,
-- message_period_counts, agent_id_aliases, fleet_*, payments, invites, seats,
-- hosts, keys and tokens (no covered view reads them). humans has no
-- tenant_id and no covered view shows a humans column; the door reads it
-- before the stamp is checked. hub/view_stamp.go names the covered views;
-- store/change_stamp_test.go fails when this list and the triggers part.
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON messages
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON deliveries
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON message_reactions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON message_revisions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON message_kind_changes
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON channels
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON channel_humans
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON channel_subscriptions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON tenant_memberships
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON rbac_roles
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON member_clones
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON issues
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON read_marks
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON box_operators
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();

-- The two RBAC tables without tenant_id (written by migrations only).
CREATE TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON rbac_permissions
    FOR EACH STATEMENT EXECUTE FUNCTION tenant_change_bump_all();
CREATE TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON rbac_role_permissions
    FOR EACH STATEMENT EXECUTE FUNCTION tenant_change_bump_all();
