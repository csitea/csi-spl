-- columns: tenant_id, human_id, role, created_at, admitted_by
-- Spec 091 4.1, allow-list v1 tenant_memberships
-- (rows: spool_hub_rows_of_exported_humans). The workspace's memberships;
-- the export keeps the rows of the exported humans only. role is forced to
-- member and admitted_by is the constant seed: emitted, never read.
SELECT tm.tenant_id, tm.human_id, 'member' AS role, tm.created_at,
       'seed' AS admitted_by
  FROM tenant_memberships tm
 WHERE tm.tenant_id = :'ws'
 ORDER BY tm.human_id
