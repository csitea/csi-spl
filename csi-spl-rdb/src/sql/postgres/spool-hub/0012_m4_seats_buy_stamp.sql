-- 0012_m4_seats_buy_stamp.sql — M4 seats + buy-time identity (specs/009-spool-m4
-- T002/T006/T007, spec D-1..D-8; 003 data-model.md `tenants`). Forward-only.
--
-- Seat OCCUPANCY is not a new table: a user seat is a tenant_memberships row
-- (0006), a bot seat is a roster row whose agent_id is not HUM-* (0001). This
-- file adds only the ENTITLEMENTS and the buy stamp.
--
-- seats_users / seats_bots: paid seats, >= 0. 0 = M4 OFF (unlimited) until
-- entitlements are sold; the paid webhook writes them (store.SetSeatCaps).
-- A new seat over a non-zero cap is refused 402 / quota (003 error-envelope).
--
-- org / app: 3-letter codes, NOT unique (many customers share them).
-- project_id: dedicated SKU only, {org}-{app}-{env}-{YYYYMMDDHHmm} minted at
-- the paid webhook's UTC minute (store.MintProjectID); GCP project-id rule,
-- 6..30 chars. Hosted M2 leaves it NULL, so uniqueness is a partial index.
-- bought_at: the paid webhook's time, the stamp source (never created_at).

ALTER TABLE tenants
    ADD COLUMN org         text        NULL CHECK (org IS NULL OR org ~ '^[a-z]{3}$'),
    ADD COLUMN app         text        NULL CHECK (app IS NULL OR app ~ '^[a-z]{3}$'),
    ADD COLUMN project_id  text        NULL
        CHECK (project_id IS NULL OR (char_length(project_id) BETWEEN 6 AND 30
               AND project_id ~ '^[a-z][a-z0-9-]{4,28}[a-z0-9]$')),
    ADD COLUMN bought_at   timestamptz NULL,
    ADD COLUMN seats_users int         NOT NULL DEFAULT 0 CHECK (seats_users >= 0),
    ADD COLUMN seats_bots  int         NOT NULL DEFAULT 0 CHECK (seats_bots >= 0);

CREATE UNIQUE INDEX tenants_project_id ON tenants (project_id)
    WHERE project_id IS NOT NULL;
