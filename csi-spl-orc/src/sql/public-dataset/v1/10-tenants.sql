-- columns: tenant_id, display_name, created_at, billing_status, plan_id, root_pubkey
-- Spec 091 4.1 / 4.4, allow-list v1 tenants (rows: spool_hub_workspace_only).
-- The listed workspace's own row. billing_status, plan_id and root_pubkey
-- are constants this query emits, never read (root_pubkey: 32 zero bytes,
-- the loader replaces it). psql variable ws = the workspace of this
-- transaction (fence 3; fence 2 pins the same one). Columns named, never all.
SELECT t.tenant_id, t.display_name, t.created_at,
       'internal' AS billing_status, 'default' AS plan_id,
       decode(repeat('00', 32), 'hex') AS root_pubkey
  FROM tenants t
 WHERE t.tenant_id = :'ws'
 ORDER BY t.tenant_id
