-- 0009_native_credentials.sql — email + password sign-in (specs/015-spool-native-auth
-- T004; ported from csi-rel users.password_hash + password_reset_tokens +
-- email_verification_tokens). Forward-only.
--
-- A credential is keyed like a 0006 human_identities row: provider =
-- 'password', subject = the lower-cased email. There is deliberately NO foreign
-- key to human_identities: the credential exists from register/verify on,
-- while the identity row (and the HUM-*) is created by the Registrar only on
-- the first ADMITTED login (015 FR-007).
--
-- A verification token carries the argon2id hash of the password submitted
-- with the register call that minted it; consuming the token installs THAT
-- hash. So an address squatted by someone else before its owner registers is
-- verified with the owner's password, never the squatter's (pre-account
-- takeover, 015 FR-015).
--
-- Tokens are stored as sha256(hex plaintext) only; the plaintext lives in the
-- mail link. Each token is single-use (consumed_at) and expiring (expires_at).

CREATE TABLE password_credentials (
    provider          text        NOT NULL DEFAULT 'password' CHECK (provider = 'password'),
    subject           text        NOT NULL CHECK (subject = lower(subject) AND length(subject) BETWEEN 3 AND 320),
    -- argon2id PHC string (015 FR-001).
    password_hash     text        NOT NULL CHECK (password_hash LIKE '$argon2id$%'),
    display_name      text        NULL CHECK (display_name IS NULL OR length(display_name) <= 200),
    email_verified_at timestamptz NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    last_login_at     timestamptz NULL,
    PRIMARY KEY (provider, subject)
);

CREATE TABLE email_verification_tokens (
    token_hash  text        PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    provider    text        NOT NULL,
    subject     text        NOT NULL,
    password_hash text      NOT NULL CHECK (password_hash LIKE '$argon2id$%'),
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    consumed_at timestamptz NULL,
    FOREIGN KEY (provider, subject) REFERENCES password_credentials (provider, subject) ON DELETE CASCADE
);
CREATE INDEX email_verification_tokens_cred ON email_verification_tokens (provider, subject, created_at);

CREATE TABLE password_reset_tokens (
    token_hash  text        PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    provider    text        NOT NULL,
    subject     text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    consumed_at timestamptz NULL,
    FOREIGN KEY (provider, subject) REFERENCES password_credentials (provider, subject) ON DELETE CASCADE
);
CREATE INDEX password_reset_tokens_cred ON password_reset_tokens (provider, subject, created_at);
