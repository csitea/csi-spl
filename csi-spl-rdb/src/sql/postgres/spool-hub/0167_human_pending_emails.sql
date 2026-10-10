-- 0167_human_pending_emails.sql - a person signs in with more than one email
-- (owner HUM-10, t1 f265541a, msg cca0746d: "Only the admin of a workspace can
-- add other emails to other users, but before they can use them, they must
-- authenticate with them against the cloud provider."). Forward-only.
--
--   human_pending_emails  one row per address a workspace admin added to a
--                         member and nobody has proved yet. PENDING: it signs
--                         nobody in and matches no invite. The first sign-in
--                         at a cloud provider (Google, Facebook, LinkedIn,
--                         Microsoft) that asserts the address verified LINKS
--                         that new identity to human_id (store findHuman) and
--                         deletes this row: the address is then ACTIVE, a
--                         verified human_identities row like any other. A
--                         native password sign-in never activates it.
--
-- Its own table, not a human_identities row: every reader of that table
-- (sign-in providers on the member list, the demo ban keys and audit, the
-- forgot-password lookup) takes a row there as a way in.
--
-- email is the primary key: one pending holder per address hub-wide. Hub-wide
-- like humans (no tenant_id, outside rdb 0014's RLS): an address belongs to a
-- person, not a workspace. added_in / added_by are the audit of who asked.
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: wf 20 applies this before the hub that reads it rolls.

CREATE TABLE human_pending_emails (
    email      text        PRIMARY KEY CHECK (email = lower(email) AND length(email) BETWEEN 3 AND 320),
    human_id   text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    added_in   text        NOT NULL CHECK (length(added_in) BETWEEN 1 AND 200),
    added_by   text        NOT NULL CHECK (length(added_by) BETWEEN 1 AND 200),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX human_pending_emails_human ON human_pending_emails (human_id);
