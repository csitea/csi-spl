-- 0280_release_notes_deploys_rls_contract.sql - the contract half of scoping
-- commits and deploys by workspace and repo (spec 171 section 3.3.0 Step C,
-- Lane 2b, with spec 143 releases-projects.md section 4.3; build row B-3,
-- SPL-5475). Forward-only.
--
-- Row B-2's hub (rdb 0270, SPL-5108) reads both tables in the tenant scope and
-- writes them in the operator scope, and serves dev and prd. So this file
-- does what 0267 left for it:
--
--   the defaults        tenant_id 't1' and repo_slug 'csitea/csi-spl' go: a
--                       write that names no workspace fails, never lands in t1.
--   the orphan guards   refuse the file while a row names a tenant_id that is
--                       not in tenants; the foreign keys then cascade a
--                       workspace delete to its commits and deploys.
--   the primary key     (tenant_id, repo_slug, sha), built from 0267's unique
--                       index release_notes_tenant_repo_sha and kept under the
--                       name release_notes_pkey: one sha in two repos of a
--                       workspace keeps two rows (section 4.3, A2).
--   row security        release_notes is read in the tenant's scope only and
--                       written in the operator's; estate_deploys' read policy
--                       USING (true) becomes the same fail-closed tenant read.
--
-- commit_token_burn is not on master yet, so spec 143 creates it in its final
-- form (spec 171 section 3.3.3); this file does not name it.
--
-- Guarded: every step checks the catalogue or drops before it creates, so a
-- re-apply ends in the same catalogue and keeps every row.
-- Live-data safety: dev and prd each read 0 orphan rows of 10,040 notes before
-- the land (do_spl_db_query, 2026-11-13). The key swap and the foreign key
-- checks hold an exclusive lock on release_notes for one scan of it; the
-- deploy-time ingest is the only writer.
-- DEPLOY ORDER: apply only once row B-2's hub serves dev and prd.

SELECT set_config('app.rls_scope', 'operator', true);

ALTER TABLE release_notes ALTER COLUMN tenant_id DROP DEFAULT, ALTER COLUMN repo_slug DROP DEFAULT;
ALTER TABLE estate_deploys ALTER COLUMN tenant_id DROP DEFAULT, ALTER COLUMN repo_slug DROP DEFAULT;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM release_notes r WHERE NOT EXISTS (SELECT 1 FROM tenants t WHERE t.tenant_id = r.tenant_id)) THEN
        RAISE EXCEPTION 'release_notes rows name a tenant not in tenants: register it or delete them first (SPL-4808 Step C)';
    END IF;
    IF EXISTS (SELECT 1 FROM estate_deploys d WHERE NOT EXISTS (SELECT 1 FROM tenants t WHERE t.tenant_id = d.tenant_id)) THEN
        RAISE EXCEPTION 'estate_deploys rows name a tenant not in tenants: register it or delete them first (SPL-4808 Step C)';
    END IF;
END $$;

-- Top-level statements, not a DO block, so the channel move catalogue's DDL
-- reader sees both keys; a re-apply drops and re-adds the same key.
ALTER TABLE release_notes DROP CONSTRAINT IF EXISTS release_notes_tenant_fk,
    ADD CONSTRAINT release_notes_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE CASCADE;
ALTER TABLE estate_deploys DROP CONSTRAINT IF EXISTS estate_deploys_tenant_fk,
    ADD CONSTRAINT estate_deploys_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants (tenant_id) ON DELETE CASCADE;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'release_notes'::regclass AND contype = 'p'
                   AND pg_get_constraintdef(oid) = 'PRIMARY KEY (tenant_id, repo_slug, sha)') THEN
        ALTER TABLE release_notes DROP CONSTRAINT IF EXISTS release_notes_pkey;
        CREATE UNIQUE INDEX IF NOT EXISTS release_notes_tenant_repo_sha ON release_notes (tenant_id, repo_slug, sha);
        ALTER TABLE release_notes ADD CONSTRAINT release_notes_pkey PRIMARY KEY USING INDEX release_notes_tenant_repo_sha;
    END IF;
END $$;

ALTER TABLE release_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE release_notes FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS release_notes_tenant_read ON release_notes;
CREATE POLICY release_notes_tenant_read ON release_notes
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON release_notes;
CREATE POLICY operator_scope ON release_notes
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- rdb 0202's operator_scope stays FOR ALL for the writes.
DROP POLICY IF EXISTS estate_deploys_read ON estate_deploys;
DROP POLICY IF EXISTS estate_deploys_tenant_read ON estate_deploys;
CREATE POLICY estate_deploys_tenant_read ON estate_deploys
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
