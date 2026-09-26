-- 0051_tenants_sort_order.sql — the place of a tenant in the WUI tenant drop
-- box (SPL-71, owner 2026-09-26: "the drop down entries should be csitea
-- ( first ) relishbg ( second ) pawspoon ( third ) orange ( fourth ) ( luka )
-- fifth"). Forward-only.
--
-- 1 is first. NULL = unset: drawn after every set one, by tenant id, so a new
-- tenant goes last. The hub lists a human's memberships in this order. Set
-- per tenant with the csi-spl-orc action do_spl_tenant_sort_order.
-- Applied by spool migrate before a hub that reads the column is served.

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS sort_order integer NULL
    CHECK (sort_order IS NULL OR sort_order BETWEEN 1 AND 100000);
