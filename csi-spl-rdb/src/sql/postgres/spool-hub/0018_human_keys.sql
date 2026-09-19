-- 0018_human_keys.sql — a human's Ed25519 PUBLIC keys and their history
-- (specs/023 T010, contracts/keys-v1.md). Forward-only.
--
-- Public keys only: the default pair is generated in the browser and the hub
-- never receives the private half (023 §3.1, SEC-03). public_key is the pin
-- form (base64 of the 32 raw bytes, 004), fingerprint OpenSSH's SHA256 form.
--
-- Hub-wide like humans (0006): no tenant_id, outside RLS (0014 lists the
-- hub-wide tables). The only access path is the session's own HUM-*.
--
-- One ACTIVE key per human (partial unique index); a new key revokes the
-- active one with reason 'replaced' in the same transaction. Rows are never
-- deleted except with their human: they are the audit history. A public key
-- is registered once across the hub, whatever its state, so a key maps to
-- exactly one human.

CREATE TABLE human_keys (
    key_id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    human_id       text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    public_key     text        NOT NULL UNIQUE CHECK (public_key ~ '^[A-Za-z0-9+/]{43}=$'),
    fingerprint    text        NOT NULL CHECK (fingerprint ~ '^SHA256:[A-Za-z0-9+/]{43}$'),
    source         text        NOT NULL CHECK (source IN ('generated', 'uploaded')),
    label          text        NOT NULL DEFAULT '' CHECK (length(label) <= 80),
    created_at     timestamptz NOT NULL DEFAULT now(),
    revoked_at     timestamptz NULL,
    revoked_reason text        NOT NULL DEFAULT ''
                               CHECK (revoked_reason IN ('', 'replaced', 'revoked')),
    CHECK ((revoked_at IS NULL) = (revoked_reason = ''))
);

CREATE UNIQUE INDEX human_keys_one_active ON human_keys (human_id) WHERE revoked_at IS NULL;
CREATE INDEX human_keys_human ON human_keys (human_id, key_id DESC);
