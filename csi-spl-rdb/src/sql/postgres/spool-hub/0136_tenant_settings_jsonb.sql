-- 0136_tenant_settings_jsonb.sql - one generic settings column on the
-- workspace table (spec 098). Forward-only, additive.
--
-- Owner HUM-10, t1 29b19f85: "could it be done more genertically for this
-- table to not require DDL changes for EACH type of settings additions /
-- changes", "let's add this generic col , which if heavily used will evoke
-- DDL changes as a strategy", "ensure the performance does not degrade in
-- complex json operations".
--
--   tenants.settings   {"<key>": <value>, ...}  a workspace setting that is
--                      not a column. The hub owns every key: its type, its
--                      default and its check (store/tenant_kv.go registry).
--                      A key absent here takes the hub default. A key that
--                      becomes heavily used is PROMOTED to a real column by a
--                      normal DDL change (spec 098 section 7).
--
-- The CHECK only keeps the value an object; the hub validates every key it
-- writes, and a write is one `settings || $patch - $unset` UPDATE (no
-- read-modify-write). No index: nothing filters on a key. A GIN index is
-- added only when a query needs one (spec 098 section 6).
--
-- NOT NULL with a constant default: a catalog-only ADD COLUMN (pg 11+), no
-- rewrite. The CHECK is validated by one scan of tenants (a handful of rows).
-- RLS is unchanged: tenants already ENABLE + FORCE it (0021), and a column
-- needs no policy of its own. The runtime role (spool_hub_rt) gets UPDATE on
-- the new column through its existing table grant. No change_stamp trigger:
-- tenants is not a stamped view table (0103). No personal data.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45;
-- wf 20 migrates before it rolls).

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS settings jsonb NOT NULL DEFAULT '{}'::jsonb
        CONSTRAINT tenants_settings_object CHECK (jsonb_typeof(settings) = 'object');
