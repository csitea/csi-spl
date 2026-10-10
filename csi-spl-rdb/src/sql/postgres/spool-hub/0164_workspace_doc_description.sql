-- 0164_workspace_doc_description.sql - a workspace document's meta
-- description: the short plain-text summary the WUI's new-document modal asks
-- for beside the title (owner, t1 889e15d9 msg 0a7a9702), stored now for the
-- omnibox search later. Forward-only, additive: '' = none, so every existing
-- row and every older hub stay valid.
-- DEPLOY ORDER: wf 20 applies it on dev AND prd before the hub that reads it.

ALTER TABLE workspace_doc
    ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT ''
        CONSTRAINT workspace_doc_description_len CHECK (length(description) <= 1000);
