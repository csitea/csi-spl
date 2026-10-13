-- 0190_change_stamp_no_deliveries.sql - a second change stamp that a
-- deliveries write does not move, for GET /v1/view/channels (perf round 5
-- P5-10 step 2, SPL-1740). Forward-only.
--
-- Why: the 0103 stamp moves on every committed write to a covered table, and
-- deliveries is the busiest of them (prd: 41 844 bumps a day against 6 840
-- channel GETs, csi-spl-doc/doc/md/perf-round-5-plan.md row 10). The channels
-- view reads no deliveries row (store/channels_postgres.go ViewChannelStats:
-- channels, messages, read_marks, channel_subscriptions; channel_humans and
-- tenant_memberships at the door), so a delivery acked or redelivered moved
-- its stamp and turned a repeat read that could be a 304 into a full read.
--
-- n_nodeliv / nodeliv_changed_at: the same invariant as n / changed_at
-- (0103), for every covered table EXCEPT deliveries. A deliveries-only
-- transaction moves n and changed_at alone; any other covered write moves
-- both pairs. The hub reads both sums in its one stamp read and gates the
-- channels view on the narrow pair (hub/view_stamp.go).
--
-- One transaction still bumps a tenant once per pair: app.change_stamped
-- holds the tenants bumped in full (both pairs), app.change_stamped_d the
-- tenants bumped by a deliveries write only. A deliveries row first and a
-- messages row later in one transaction bump twice (the second bump moves
-- the narrow pair), never zero times.
--
-- The columns are added with a constant default (no table rewrite). An
-- existing row starts its narrow sum at 0 and moves on the next write; a
-- NULL nodeliv_changed_at reads as settled (no change seen yet).
--
-- DEPLOY ORDER: apply this file BEFORE the hub that reads the columns. The
-- old hub ignores them; under the new functions n keeps its 0103 meaning.

SET LOCAL lock_timeout = '5s';

ALTER TABLE tenant_change_stamps ADD COLUMN IF NOT EXISTS n_nodeliv bigint NOT NULL DEFAULT 0;
ALTER TABLE tenant_change_stamps ADD COLUMN IF NOT EXISTS nodeliv_changed_at timestamptz;

CREATE OR REPLACE FUNCTION tenant_change_bump_every() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    scope text := coalesce(current_setting('app.rls_scope', true), '');
BEGIN
    PERFORM set_config('app.rls_scope', 'operator', true);
    UPDATE tenant_change_stamps SET n = n + 1, changed_at = clock_timestamp(),
        n_nodeliv = n_nodeliv + 1, nodeliv_changed_at = clock_timestamp();
    PERFORM set_config('app.rls_scope', scope, true);
END
$$;

-- tenant_change_bump_kind bumps tn: both pairs when whole, n alone when not
-- (a deliveries write).
CREATE OR REPLACE FUNCTION tenant_change_bump_kind(tn text, whole boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    done   text := coalesce(current_setting('app.change_stamped', true), '');
    done_d text := coalesce(current_setting('app.change_stamped_d', true), '');
    scope  text := coalesce(current_setting('app.rls_scope', true), '');
    mark   text := chr(31) || tn || chr(31);
    ts     timestamptz;
BEGIN
    IF tn IS NULL THEN
        PERFORM tenant_change_bump_every();
        RETURN;
    END IF;
    IF position(mark IN done) > 0 OR (NOT whole AND position(mark IN done_d) > 0) THEN
        RETURN;
    END IF;
    PERFORM set_config('app.rls_scope', 'operator', true);
    IF EXISTS (SELECT 1 FROM tenants WHERE tenant_id = tn) THEN
        ts := clock_timestamp();
        INSERT INTO tenant_change_stamps (tenant_id, slot, n, changed_at, n_nodeliv, nodeliv_changed_at)
        VALUES (tn, floor(random() * 16)::smallint, 1, ts, CASE WHEN whole THEN 1 ELSE 0 END, CASE WHEN whole THEN ts END)
        ON CONFLICT (tenant_id, slot) DO UPDATE SET n = tenant_change_stamps.n + 1, changed_at = EXCLUDED.changed_at,
            n_nodeliv = tenant_change_stamps.n_nodeliv + EXCLUDED.n_nodeliv,
            nodeliv_changed_at = coalesce(EXCLUDED.nodeliv_changed_at, tenant_change_stamps.nodeliv_changed_at);
    END IF;
    PERFORM set_config('app.rls_scope', scope, true);
    IF whole THEN
        PERFORM set_config('app.change_stamped', done || mark, true);
    ELSE
        PERFORM set_config('app.change_stamped_d', done_d || mark, true);
    END IF;
END
$$;

-- tenant_change_bump_one keeps its 0103 meaning (a full bump) for any caller.
CREATE OR REPLACE FUNCTION tenant_change_bump_one(tn text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM tenant_change_bump_kind(tn, true);
END
$$;

-- The 0103 row trigger, now telling a deliveries row from the rest. The
-- triggers themselves do not change.
CREATE OR REPLACE FUNCTION tenant_change_bump() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    whole boolean := TG_TABLE_NAME <> 'deliveries';
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM tenant_change_bump_kind(OLD.tenant_id, whole);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM tenant_change_bump_kind(NEW.tenant_id, whole);
    END IF;
    RETURN NULL;
END
$$;
