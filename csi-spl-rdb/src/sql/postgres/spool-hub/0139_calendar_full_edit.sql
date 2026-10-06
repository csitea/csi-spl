-- 0139_calendar_full_edit.sql - calendar full editing (specs/097, T002,
-- spec section 3.1). Forward-only, additive.
--
--   calendar_events   grows: props (jsonb, keys in the hub registry, spec
--                     3.3), time_zone, rrule + recur_until (a series),
--                     recurring_event_id + original_start + status (an
--                     exception row), deleted_at + deleted_by (soft delete).
--                     UNIQUE (tenant_id, event_id) is the target of the
--                     guests' composite foreign key.
--   calendar_guests   one row per guest of an event, written by that guest.
--                     The composite foreign key makes a guest row of
--                     workspace A pointing at an event of B impossible, not
--                     only unreadable (spec 3.2). RLS in the 0125 NULLIF shape.
--
-- Every added column is nullable or has a constant default, so the adds are
-- catalogue-only; the checks and the unique constraint scan a small table once.
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply on dev and prd BEFORE the hub that reads these columns
-- (T003/T004); until then the store probes the column and answers 089's shape.

ALTER TABLE calendar_events
    ADD COLUMN props              jsonb       NOT NULL DEFAULT '{}'
        CHECK (jsonb_typeof(props) = 'object' AND octet_length(props::text) <= 16384),
    ADD COLUMN time_zone          text        NOT NULL DEFAULT 'UTC'
        CHECK (length(time_zone) BETWEEN 1 AND 64),
    ADD COLUMN rrule              text        NULL CHECK (rrule IS NULL OR length(rrule) <= 500),
    -- hub-computed end of the series; NULL = no end
    ADD COLUMN recur_until        timestamptz NULL,
    ADD COLUMN recurring_event_id uuid        NULL REFERENCES calendar_events (event_id) ON DELETE CASCADE,
    -- the occurrence an exception replaces
    ADD COLUMN original_start     timestamptz NULL,
    -- cancelled = one deleted occurrence
    ADD COLUMN status             text        NOT NULL DEFAULT 'confirmed'
        CHECK (status IN ('confirmed', 'cancelled')),
    ADD COLUMN deleted_at         timestamptz NULL,
    ADD COLUMN deleted_by         text        NULL CHECK (deleted_by IS NULL OR length(deleted_by) <= 64),
    ADD CONSTRAINT calendar_events_exception_shape
        CHECK ((recurring_event_id IS NULL) = (original_start IS NULL)),
    ADD CONSTRAINT calendar_events_master_or_exception
        CHECK (rrule IS NULL OR recurring_event_id IS NULL),
    ADD CONSTRAINT calendar_events_tenant_event UNIQUE (tenant_id, event_id);

-- An occurrence has at most one exception row.
CREATE UNIQUE INDEX calendar_events_exception_once
    ON calendar_events (recurring_event_id, original_start) WHERE recurring_event_id IS NOT NULL;
-- The range read's live series.
CREATE INDEX calendar_events_series
    ON calendar_events (tenant_id, recur_until) WHERE rrule IS NOT NULL AND deleted_at IS NULL;
-- The trash read.
CREATE INDEX calendar_events_trash
    ON calendar_events (tenant_id, deleted_at) WHERE deleted_at IS NOT NULL;

CREATE TABLE calendar_guests (
    tenant_id     text        NOT NULL,
    event_id      uuid        NOT NULL,
    guest_type    text        NOT NULL CHECK (guest_type IN ('human', 'agent')),
    guest_id      text        NOT NULL CHECK (length(guest_id) BETWEEN 1 AND 64),
    response      text        NOT NULL DEFAULT 'needs_action'
        CHECK (response IN ('needs_action', 'yes', 'no', 'maybe')),
    comment       text        NOT NULL DEFAULT '' CHECK (length(comment) <= 500),
    responded_at  timestamptz NULL,
    invited_by    text        NOT NULL CHECK (length(invited_by) BETWEEN 1 AND 64),
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, guest_type, guest_id),
    -- a guest row can only point at an event of its own workspace
    FOREIGN KEY (tenant_id, event_id) REFERENCES calendar_events (tenant_id, event_id) ON DELETE CASCADE
);
-- "My invitations" and the guest search.
CREATE INDEX calendar_guests_guest ON calendar_guests (tenant_id, guest_id);

ALTER TABLE calendar_guests ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_guests FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON calendar_guests
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON calendar_guests
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
