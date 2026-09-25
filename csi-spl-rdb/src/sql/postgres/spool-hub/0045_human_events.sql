-- 0045_human_events.sql — a human's personal event log (specs/005
-- FR-WUI-EVLOG, contracts/events-v1.md, CLE-34990). Forward-only.
--
-- Owner, 2026-09-25: "all of the errors should get saved into a personal per
-- user event-log entry in the db, which should be accessible from event log".
--
-- One row per error the WUI showed the signed-in human (POST
-- /api/v1/auth/events), read back newest first on the WUI's /events page.
-- Only the fields the WUI's error journal already redacted at capture are
-- stored: no request or response body, no header, no query string, no stack.
--
-- Hub-wide like humans (0006) and human_keys (0018): no tenant_id, outside
-- RLS (0014 lists the hub-wide tables). The only access path is the session's
-- own HUM-*. The hub keeps the newest 500 rows per human and deletes older
-- ones on insert; a cleared log deletes the human's rows. Rows die with their
-- human (ON DELETE CASCADE).
--
-- Applied by spool migrate before a hub that reads the table is served.

CREATE TABLE human_events (
    event_id    bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    human_id    text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    kind        text        NOT NULL DEFAULT 'error' CHECK (kind IN ('error')),
    -- ERR-YYYYMMDD-HHMMSS-XXXX (hub) or ERR-CLIENT-… (browser), or '' when
    -- the client sent none; the WUI's ERROR_ID_RE, checked by the hub too.
    error_id    text        NOT NULL DEFAULT '' CHECK (error_id = '' OR error_id ~ '^ERR(-CLIENT)?-[0-9]{8}-[0-9]{6}-[0-9A-F]{4}$'),
    -- When the browser saw it (client clock) and when the hub stored it.
    occurred_at timestamptz NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    source      text        NOT NULL DEFAULT '' CHECK (length(source) <= 80),
    method      text        NOT NULL DEFAULT '' CHECK (length(method) <= 12),
    origin      text        NOT NULL DEFAULT '' CHECK (length(origin) <= 120),
    path        text        NOT NULL DEFAULT '' CHECK (length(path) <= 200),
    status      integer     NOT NULL DEFAULT 0 CHECK (status BETWEEN 0 AND 999),
    code        text        NOT NULL DEFAULT '' CHECK (length(code) <= 120),
    message     text        NOT NULL DEFAULT '' CHECK (length(message) <= 800),
    name        text        NOT NULL DEFAULT '' CHECK (length(name) <= 80),
    route       text        NOT NULL DEFAULT '' CHECK (length(route) <= 200)
);

CREATE INDEX human_events_human ON human_events (human_id, event_id DESC);
