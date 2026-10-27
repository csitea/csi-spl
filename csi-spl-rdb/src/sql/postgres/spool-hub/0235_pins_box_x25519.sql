-- 0235_pins_box_x25519.sql - the box key desk's X25519 recipient on its pin
-- (spec 127 v1.4 5.2 step 3, row H2; spec 159 T5 increment 3; SPL-3738).
-- Forward-only, additive.
--
-- pins.box_x25519: the age X25519 recipient ("age1...", public) of the
-- box's key desk (internal/keydesk), sent in the join payload beside the
-- Ed25519 key and signed with it (wire.JoinKeyPayload). The hub seals a
-- workspace key lease to it, so a TLS-terminating proxy sees ciphertext
-- only. NULL = a pin enrolled before this field, or a box with no desk: it
-- gets no lease (409 box_key_not_enrolled) until it joins again with a
-- fresh token. Every join writes it: one that sends no recipient clears
-- it, so no recipient of an earlier desk survives a re-join.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). Live-data
-- safety: one nullable column with a CHECK that every existing row passes
-- (NULL); ACCESS EXCLUSIVE on pins until COMMIT for the scan, hence
-- lock_timeout. Public key material only, no secret, no personal data.
-- DEPLOY ORDER: wf 20 applies it before the image that reads it.

SET LOCAL lock_timeout = '5s';

ALTER TABLE pins ADD COLUMN box_x25519 text NULL
    CONSTRAINT pins_box_x25519_check CHECK (box_x25519 ~ '^age1[02-9ac-hj-np-z]{58}$');
