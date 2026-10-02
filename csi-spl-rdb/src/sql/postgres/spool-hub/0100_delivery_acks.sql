-- 0100_delivery_acks.sql — a box commits a delivery after its inbox write
-- (spec 059 §11 S2, Kafka's "commit after processing"). Forward-only.
--
-- Until now state = 'sent' meant "the hub wrote the frame to the socket". A box
-- that died before its inbox write lost that message and every frame still in
-- flight, and the hub kept nothing to send again: the spec 059 spike measured
-- 6 of 10 lost, n = 4 (csi-spl-doc/specs/059-messaging-backbone/spec.md §10).
--
-- acked_at is set when the box says the inbox copy is written (the `commit`
-- frame, hello feature "commit"). A box without that feature keeps the old
-- meaning: the hub sets acked_at = sent_at when it claims the row. A sent row
-- with acked_at NULL goes to the box again at its next hello and after the
-- acquisition lock runs out (hub ackTimeout); the box dedups by file name.

ALTER TABLE deliveries ADD COLUMN acked_at timestamptz;

-- Every row sent before this migration was sent under the old meaning.
UPDATE deliveries SET acked_at = sent_at WHERE state = 'sent';

CREATE INDEX deliveries_unacked ON deliveries (tenant_id, to_box, sent_at)
    WHERE state = 'sent' AND acked_at IS NULL;
