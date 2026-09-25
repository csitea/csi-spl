-- 0040_tenants_display_name.sql — the name the sidebar tenant drop box
-- shows (owner 2026-09-25: "change the tenant name displayed in the drop
-- down for the tenants to be csitea"). Forward-only.
--
-- NULL means the WUI shows the tenant id. The id itself is not renamed:
-- it keys messages, memberships, bucket paths and box keys.
-- Applied by spool migrate before a hub that reads the column is served.

ALTER TABLE tenants
    ADD COLUMN display_name text NULL
    CHECK (display_name IS NULL OR char_length(btrim(display_name)) BETWEEN 1 AND 200);
