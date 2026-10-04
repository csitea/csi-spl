# 075 the Docs section: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names its lane, the files it owns, and its done check. Status vocabulary: `../README.md` §2.3. Open owner questions: `spec.md` section 9 (Q1 resolved as b; Q2-Q4 open).

Phased according to owner HUM-10 order (topic `9f0d751c-c0db-4e56-ad8b-798ab312f1ff`, msg `9431127d`):
1. Repo docs read-only, bucket-hosted, uploaded by deploy (c-221).
2. Workspace docs: dedicated GCS bucket per workspace, docs only, Hub SA mediated access, revision history.
3. Omnisearch integration: Hub search + Google Site Search trade-off.
4. Linking flows: git-spec auto-links in messages, doc <-> topic binders.
5. Corporate enterprise: Vector database + IAM.

---

### Phase 0: Specification
- [x] T001 **spec** (a-223): `spec.md`, `plan.md`, and this file. Done: Landed on master, approved by c-002, clean distribution hygiene.
- [x] T001b **amendment: per-workspace docs bucket** (a-223): amended for owner msg `9431127d` ("create a new s3 bucket for the docs only per tenant"). Q1 resolved as (b) GCS bucket per workspace; Q2-Q4 kept open.

### Phase 1: Repo Docs (Read-Only, Bucket-Hosted, Built by Lane c-221)
- [ ] T002 **deploy publish action** (c-221): action `do_publish_docs` in `csi-spl-orc` uploading all repository `*.md` files (excluding agent instruction files and build dirs) to the environment's object storage bucket (`csi-spl-<env>-docs`) and writing `tree.json`. Done: CI deploy pipeline uploads docs and passes verification.
- [ ] T003 **hub docs route** (c-221): `GET /v1/docs/tree.json` and `GET /v1/docs/{repo path}` in `internal/hub/docs.go`, session-gated with `humanTenant`. Done: unit tests in `docs_test.go` pass (200 for member, 403 for unauthenticated, 404 for invalid path or `docs_off`).
- [ ] T004 **wui explorer tree & viewer** (c-221): `pages/docs/[...path].vue` and `utils/docs.mjs` rendering collapsible Explorer folder tree on left and theme-styled markdown on right, with relative link rewriting. Done: unit tests in `docs.test.mjs` pass, WUI typecheck green.
- [ ] T005 **navigation & i18n** (c-221): "Docs" entry in desktop sidebar (`ChannelSidebar.vue`) and mobile drawer, localized in all 19 language files in `i18n/locales/*.json`. Done: i18n test green.

### Phase 2: Workspace Docs (Per-Workspace GCS Bucket, Members & Agents)
- [ ] T006 **workspace docs bucket provisioning** (future lane): Terraform module / step `052-gcs-tenant-docs` provisioning GCS bucket `${SPL_ORG_APP}-${ENV}-docs-${WORKSPACE_SLUG}` per configured workspace with uniform bucket-level access and no public access, granting `roles/storage.objectAdmin` to Hub runtime SA. Dynamic provisioning hook for new operator workspaces. Done: `terraform plan` clean and bucket creation verified.
- [ ] T007 **hub workspace blob store resolver** (future lane): `blob.Store` resolver in `internal/hub/` dynamically routing workspace storage calls to `csi-spl-<env>-docs-<tenant>` based on authenticated session `humanTenant`. Done: unit tests proving caller in `t2` cannot read or write `t1` bucket.
- [ ] T008 **hub workspace docs api** (future lane): endpoints `GET /v1/workspace/docs/tree.json`, `GET /v1/workspace/docs/{path...}`, `PUT /v1/workspace/docs/{path...}`, and `DELETE /v1/workspace/docs/{path...}` with GCS generation preconditions (`if_generation_match`) and writing `.history/` audit trail. Done: API tests pass against mock GCS / emulator.
- [ ] T009 **spool cli & agent verbs** (future lane): verbs `spool doc-read`, `spool doc-write`, and `spool doc-list` in `cmd/spool/` targeting the workspace docs bucket through the Hub API. Done: CLI tests authoring a document and verifying revision record.
- [ ] T010 **wui workspace docs editor** (future lane): collaborative Markdown editor in WUI with live preview, revision history drawer, and unified Explorer tree displaying both Repository (Phase 1) and Workspace (Phase 2) documentation sections. Done: WUI e2e test creating, editing, and previewing doc.

### Phase 3: Omnisearch Integration
- [ ] T011 **hub doc search route** (future lane): `GET /v1/search/docs?q=...` querying workspace docs and repo docs via in-memory catalogue and cached content. Done: search unit tests pass.
- [ ] T012 **wui omnisearch docs group** (future lane): TopBar Omnisearch (spec 022) displays matching documentation results alongside channels, topics, and messages. Done: Omnisearch browser test verifies doc search results.
- [ ] T013 **google site search fallback** (future lane): action in Omnisearch "Search public docs with Google" targeting `site:<BASE_DOMAIN>/docs` for public open-source instances. Done: component test verifies query URL construction.

### Phase 4: Linking Capabilities
- [ ] T014 **git-spec citation auto-linker** (future lane): regex parser in `utils/id-links.mjs` converting git-spec references (e.g. `spec 072`, `specs/074`) into clickable interactive badges routing to `/docs/repo/csi-spl-doc/specs/NNN-.../spec.md`. Done: unit tests in `id-links.test.mjs` pass.
- [ ] T015 **doc <-> topic binding schema** (future lane): migration `0117_doc_topics.sql` adding `topics.doc_path` and workspace docs `tree.json` recording `topic_id`. Done: migration linter clean.
- [ ] T016 **wui doc discussion flow** (future lane): doc header "Discussion" button opening linked topic; topic header pinned banner displaying doc link and title. Done: e2e test verifying doc-to-topic and topic-to-doc navigation.

### Phase 5: Corporate Enterprise (Vector Database + IAM)
- [ ] T017 **vector embedding pipeline** (future lane): background worker embedding document passages on save using configured embedding model. Done: embedding generation test passes.
- [ ] T018 **semantic search endpoint** (future lane): vector similarity search endpoint using `pgvector` HNSW index or enterprise vector store. Done: semantic query returns relevant chunk.
- [ ] T019 **corporate iam & folder acls** (future lane): document and folder ACL enforcement integrated with corporate IdP groups (SAML / OIDC). Done: role-gated access tests pass.

<!-- version: 0.2.0 · updated: 2026-10-04 · last-edit: 2026-10-04T15:20:00Z -->
