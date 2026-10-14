-- 0196_change_stamp_narrow_channels.sql - the narrow change stamp (rdb 0190,
-- n_nodeliv) moves only on a row the channels view reads (perf round 5
-- P5-10 4.3, SPL-1831; owner pick A, t1 eafc9b15). Forward-only.
--
-- Why: GET /v1/view/channels gates on n_nodeliv, and on prd t1 roughly two
-- thirds of what moved it was data that view never reads: t: read marks of
-- topics outside every channel, messages outside a channel, issues
-- (csi-spl-doc/doc/md/perf-round-5/p5-10.md section 4.2). Each turned a
-- repeat channels read that could be a 304 into a full read.
--
-- The per-row rule, for the narrow pair only (n / changed_at keep their
-- 0103 meaning, every covered write moves them):
--
--   deliveries   never (0190)
--   issues       never: the channels view reads no issues row
--   messages     a row in a channel, or an archived row: the view's
--                archived-hide reads (store archivedHideSQL, hiddenLineSQL)
--                take archived cards of any channel, a topic root outside
--                one included
--   read_marks   a ch: mark; a t: mark only when its topic has a line in a
--                channel (store threadReadSQL: a thread read elsewhere is not
--                unread in its channel); dm: marks never
--   the rest     always, as in 0190
--
-- Both sides of an UPDATE are judged (OLD and NEW), so a line moved out of a
-- channel or un-archived still moves the stamp. A t: mark written before its
-- topic's first channel line is safe: that line's own insert moves the stamp.
--
-- DEPLOY ORDER: none. The hub reads the same columns; only which writes move
-- n_nodeliv changes.

SET LOCAL lock_timeout = '5s';

-- tenant_change_bump_kind: as rdb 0190, but one transaction bumps one slot
-- of a tenant, not a random slot per bump. A narrow-only bump (a row outside
-- the channels view) and a later whole bump of the same tenant in one
-- transaction are now common; with a random slot each they locked two stamp
-- rows in random order, and two such transactions deadlocked (40P01,
-- TestTopicHeadRaceMirroredVsMerge, 4 of 50 rounds). The slot still spreads
-- concurrent transactions over 16 rows.
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
        VALUES (tn, (txid_current() % 16)::smallint, 1, ts, CASE WHEN whole THEN 1 ELSE 0 END, CASE WHEN whole THEN ts END)
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

-- tenant_change_mark_on_channels: the channels view reads this read mark: a
-- ch: mark, or a t: mark whose topic has a line in a channel. The topic is
-- read in the operator scope (as the stamp write is), so a cascade or an
-- operator sweep judges the row's own tenant. A t: key that is not a uuid
-- names no topic.
CREATE OR REPLACE FUNCTION tenant_change_mark_on_channels(tn text, mark_key text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
    scope text := coalesce(current_setting('app.rls_scope', true), '');
    found boolean;
BEGIN
    IF mark_key LIKE 'ch:%' THEN
        RETURN true;
    END IF;
    IF mark_key !~* '^t:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RETURN false;
    END IF;
    PERFORM set_config('app.rls_scope', 'operator', true);
    found := EXISTS (SELECT 1 FROM messages WHERE tenant_id = tn AND task_id = substr(mark_key, 3)::uuid AND channel IS NOT NULL);
    PERFORM set_config('app.rls_scope', scope, true);
    RETURN found;
END
$$;

-- tenant_change_bump: the 0103 row trigger, now judging per row whether the
-- narrow pair moves too (tenant_change_bump_kind's whole). A table's fields
-- are read only in its own branch. The triggers themselves do not change.
CREATE OR REPLACE FUNCTION tenant_change_bump() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    whole boolean;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        IF TG_TABLE_NAME = 'messages' THEN
            whole := OLD.channel IS NOT NULL OR OLD.archived_at IS NOT NULL;
        ELSIF TG_TABLE_NAME = 'read_marks' THEN
            whole := tenant_change_mark_on_channels(OLD.tenant_id, OLD.mark_key);
        ELSE
            whole := TG_TABLE_NAME NOT IN ('deliveries', 'issues');
        END IF;
        PERFORM tenant_change_bump_kind(OLD.tenant_id, whole);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        IF TG_TABLE_NAME = 'messages' THEN
            whole := NEW.channel IS NOT NULL OR NEW.archived_at IS NOT NULL;
        ELSIF TG_TABLE_NAME = 'read_marks' THEN
            whole := tenant_change_mark_on_channels(NEW.tenant_id, NEW.mark_key);
        ELSE
            whole := TG_TABLE_NAME NOT IN ('deliveries', 'issues');
        END IF;
        PERFORM tenant_change_bump_kind(NEW.tenant_id, whole);
    END IF;
    RETURN NULL;
END
$$;
