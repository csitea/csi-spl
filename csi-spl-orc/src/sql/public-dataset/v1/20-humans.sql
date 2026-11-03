-- columns: human_id, display_name, email, disabled_at
-- Spec 091 4.1 / 4.3 / Q1b, allow-list v1 humans
-- (rows: spool_hub_member_author_or_addressee). Every member of the
-- workspace, read through its tenant_memberships rows (humans carries no
-- tenant_id). The export keeps only those who author or are the addressee
-- of an exported message. display_name = human_id, email and disabled_at
-- NULL: emitted, never read.
SELECT DISTINCT h.human_id, h.human_id AS display_name,
       NULL::text AS email, NULL::timestamptz AS disabled_at
  FROM humans h
  JOIN tenant_memberships tm ON tm.human_id = h.human_id
 WHERE tm.tenant_id = :'ws'
 ORDER BY h.human_id
