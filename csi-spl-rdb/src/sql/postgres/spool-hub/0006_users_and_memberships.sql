-- 0006_users_and_memberships.sql — humans, their sign-in identities and tenant
-- membership (specs/010-spool-social-auth T012/T013, OQ-A3, OQ-A5; 003 T033b).
-- Forward-only.
--
-- OQ-A3 (recommended default, implemented): a HUM-* id is an opaque, hub-wide
-- sequence number (`HUM-<n>`, the 004 identifiers.md agent-id form), never
-- derived from an IdP subject or an email. A person is keyed by
-- (provider, subject); one human may carry several identities, and a new
-- identity is never linked to an existing human by email alone. Email is a
-- verified attribute, used only to match an invite.
--
-- Nothing here stores a token, a client secret or a password. A native
-- account (NATIVE-AUTH, rdb 0009) is a human_identities row with
-- provider = 'password' and subject = the lower-cased email; its credential
-- lives in 0009's own table, keyed by (provider, subject).

CREATE SEQUENCE humans_seq START 1;

CREATE TABLE humans (
    human_id     text        PRIMARY KEY DEFAULT ('HUM-' || nextval('humans_seq'))
                             CHECK (human_id ~ '^HUM-[0-9]+$'),
    display_name text        NULL CHECK (display_name IS NULL OR length(display_name) <= 200),
    -- Last verified email seen at sign-in; informational, not unique.
    email        text        NULL CHECK (email IS NULL OR (email = lower(email) AND length(email) <= 320)),
    created_at   timestamptz NOT NULL DEFAULT now(),
    disabled_at  timestamptz NULL
);
ALTER SEQUENCE humans_seq OWNED BY humans.human_id;

CREATE TABLE human_identities (
    provider       text        NOT NULL CHECK (provider ~ '^[a-z][a-z0-9-]{0,31}$'),
    subject        text        NOT NULL CHECK (length(subject) BETWEEN 1 AND 320),
    human_id       text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    email          text        NULL CHECK (email IS NULL OR (email = lower(email) AND length(email) <= 320)),
    email_verified boolean     NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now(),
    last_login_at  timestamptz NULL,
    PRIMARY KEY (provider, subject)
);
CREATE INDEX human_identities_human ON human_identities (human_id);

-- role: an owner may invite; a member reads. The first owner is either the
-- first human on a zero-member tenant (SPOOL_HUB_AUTH_BOOTSTRAP_OWNER, dev
-- only) or an operator-issued invite (010 OQ-A5).
CREATE TABLE tenant_memberships (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    human_id    text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    role        text        NOT NULL CHECK (role IN ('owner', 'member')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- Who admitted this human: an owner HUM-*, 'operator', or 'bootstrap'.
    admitted_by text        NOT NULL,
    PRIMARY KEY (tenant_id, human_id)
);
CREATE INDEX tenant_memberships_human ON tenant_memberships (human_id);

-- An invite admits the first sign-in whose VERIFIED email matches, once.
CREATE TABLE tenant_invites (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    email       text        NOT NULL CHECK (email = lower(email) AND length(email) BETWEEN 3 AND 320),
    role        text        NOT NULL CHECK (role IN ('owner', 'member')),
    invited_by  text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    accepted_at timestamptz NULL,
    accepted_by text        NULL REFERENCES humans (human_id) ON DELETE SET NULL,
    PRIMARY KEY (tenant_id, email)
);
