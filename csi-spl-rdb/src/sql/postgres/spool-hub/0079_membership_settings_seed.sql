-- 0079_membership_settings_seed.sql — seed each membership's per-tenant override
-- (rdb 0078) from the member's current humans-row globals (CLE-35099, spec 023
-- addendum). Forward-only, idempotent (only rows with settings still NULL).
--
-- Why: once the hub reads settings per tenant, an existing member must keep
-- what they had. Copying today's global into every membership makes each
-- (person, tenant) an override snapshot, so a later change in one tenant never
-- moves the others and no one's settings reset. New settings (issues_sort,
-- pane_sizes) have no humans column, so members get the product default until
-- they choose.
--
-- display_name and the avatar are NOT copied — they stay per human.
-- diagnostics_enabled is copied only when true (false = the default; absent =
-- fall back to it). A member who never picked anything keeps settings NULL.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014).

UPDATE tenant_memberships m
SET settings = NULLIF(
    COALESCE(m.settings, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
        'preferred_locale',    h.preferred_locale,
        'preferred_theme',     h.preferred_theme,
        'submit_key',          h.submit_key,
        'rail_order',          to_jsonb(h.rail_order),
        'message_order',       h.message_order,
        'composer_position',   h.composer_position,
        'issues_view',         h.issues_view,
        'close_buttons',       h.close_buttons,
        'issues_columns',      h.issues_columns,
        'diagnostics_enabled', CASE WHEN h.diagnostics_enabled THEN to_jsonb(true) ELSE NULL END
    )),
    '{}'::jsonb)
FROM humans h
WHERE m.human_id = h.human_id
  AND m.settings IS NULL;
