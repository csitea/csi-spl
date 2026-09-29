-- 0078_membership_settings.sql — a person's per-tenant view/behaviour settings
-- (CLE-35099, spec 023). Forward-only.
--
-- Owner, prd t1 topic 3a589b54: "the user setting for the position of the
-- channels is global for all tenants, but it should be just per tenant ...
-- this applies to the theme, language and other settings too".
--
-- The layout/behaviour settings lived on the hub-wide humans row (preferred_theme
-- 0057, preferred_locale 0017, submit_key 0062, rail_order 0063, message_order /
-- composer_position 0070, issues_view 0072, issues_columns 0076, close_buttons
-- 0077, diagnostics_enabled 0038), so every tenant a person belonged to showed
-- the same value. This column holds each person's PER-TENANT override, on the
-- membership row (like channel_order 0073) — a channel id or a tenant's chosen
-- theme only means something inside its tenant.
--
-- settings  a JSON object, override-key -> value, e.g.
--           {"preferred_theme":"dark","message_order":"newest-last",
--            "issues_sort":{"col":"priority","dir":"asc"},
--            "pane_sizes":{"sidebar":0.22,"topic":0.34}}.
--           A key ABSENT (or the whole column NULL) = no override for that
--           setting in this tenant: the hub falls back to the humans-row global
--           value, then the product default. The hub admits only the known keys
--           and each key's own shape; the CHECK pins it to a JSON object.
--           display_name and the avatar stay PER HUMAN (humans row) and are not
--           kept here.
--
-- One nullable column: the running image ignores it, so this file rolls before
-- the image that reads it (like 0073).

ALTER TABLE tenant_memberships
    ADD COLUMN IF NOT EXISTS settings jsonb NULL;

ALTER TABLE tenant_memberships DROP CONSTRAINT IF EXISTS tenant_memberships_settings_check;
ALTER TABLE tenant_memberships ADD CONSTRAINT tenant_memberships_settings_check
    CHECK (settings IS NULL OR jsonb_typeof(settings) = 'object');
