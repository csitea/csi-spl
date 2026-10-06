-- 0142_repo_doc_edits.sql - editable repo docs: the save queue, the git
-- author of each member, the author-notice consents, and the authors the
-- repository history already knows. Forward-only.
--
-- Spec 075 repo-edit section 10, task T02 (csi-spl-doc/specs/075-docs-section/
-- repo-edit/; tasks.md planned it as 0134, a number taken before it landed).
-- Owner answers O1-O9: prd t1 2e20d6d4, msgs e7efcb67 and f4142409.
--
--   repo_doc_edits           one row per save of a repo doc (PUT /v1/docs/{path}):
--                            the overlay in the docs bucket, the resolved git
--                            author, and the worker's push state. The env is not
--                            a column: each env has its own database. The worker
--                            (the env's one pusher) reads across workspaces as
--                            the operator; the hub routes read under inTenant.
--                            human_id is the member, or an agent's requester
--                            (section 4.3). No FK to tenant_memberships: an edit
--                            and its commit outlive the editor's membership.
--   repo_doc_authors         a member's mapped git identity (section 4.1 rule 1)
--                            and the agents opt-out (section 4.3).
--   repo_doc_author_notices  the member's consent to commit under one published
--                            identity (section 4.2): a changed name or email is a
--                            new row, so the notice shows again.
--   repo_doc_known_authors   git identities seen in the repository history
--                            (section 4.1 rule 2), refreshed daily by the worker.
--                            Hub-wide: public history, no tenant column, no RLS.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply on dev AND prd BEFORE the hub that reads it (T06, T08).

CREATE TABLE repo_doc_edits (
    edit_id        uuid        PRIMARY KEY,
    tenant_id      text        NOT NULL,
    human_id       text        NOT NULL,
    actor_kind     text        NOT NULL CHECK (actor_kind IN ('member', 'agent')),
    agent_id       text,
    path           text        NOT NULL,
    base_blob      text        NOT NULL,
    overlay_key    text        NOT NULL,
    text_sha256    text        NOT NULL,
    author_name    text        NOT NULL,
    author_email   text        NOT NULL,
    author_source  text        NOT NULL CHECK (author_source IN ('mapping', 'history', 'signin')),
    target_ref     text        NOT NULL DEFAULT 'master',
    status         text        NOT NULL CHECK (status IN
                   ('queued', 'pushing', 'pushed', 'published', 'conflict', 'failed', 'superseded')),
    tries          int         NOT NULL DEFAULT 0 CHECK (tries >= 0),
    next_try_at    timestamptz NOT NULL,
    first_saved_at timestamptz NOT NULL,
    last_error     text,
    commit_sha     text,
    merged_with    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CHECK ((actor_kind = 'agent') = (agent_id IS NOT NULL))
);

-- the worker's claim: due rows by status
CREATE INDEX repo_doc_edits_due ON repo_doc_edits (status, next_try_at);
-- coalescing and the overlay read: a path's newest edits
CREATE INDEX repo_doc_edits_path ON repo_doc_edits (path, created_at);
-- rate limits and "My edits"
CREATE INDEX repo_doc_edits_editor ON repo_doc_edits (tenant_id, human_id, created_at);

CREATE TABLE repo_doc_authors (
    tenant_id    text        NOT NULL,
    human_id     text        NOT NULL,
    git_name     text        NOT NULL,
    git_email    text        NOT NULL,
    verified_at  timestamptz,
    allow_agents boolean     NOT NULL DEFAULT true,
    PRIMARY KEY (tenant_id, human_id)
);

CREATE TABLE repo_doc_author_notices (
    tenant_id text        NOT NULL,
    human_id  text        NOT NULL,
    git_name  text        NOT NULL,
    git_email text        NOT NULL,
    acked_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, human_id, git_email, git_name)
);

CREATE TABLE repo_doc_known_authors (
    git_email text        PRIMARY KEY,
    git_name  text        NOT NULL,
    seen_at   timestamptz NOT NULL
);

-- RLS in the 0106 shape, with the empty-setting guard (NULLIF), on the three
-- tenant tables.
ALTER TABLE repo_doc_edits ENABLE ROW LEVEL SECURITY;
ALTER TABLE repo_doc_edits FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON repo_doc_edits
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON repo_doc_edits
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE repo_doc_authors ENABLE ROW LEVEL SECURITY;
ALTER TABLE repo_doc_authors FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON repo_doc_authors
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON repo_doc_authors
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE repo_doc_author_notices ENABLE ROW LEVEL SECURITY;
ALTER TABLE repo_doc_author_notices FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON repo_doc_author_notices
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON repo_doc_author_notices
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
