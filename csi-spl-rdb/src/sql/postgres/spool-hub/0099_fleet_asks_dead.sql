-- 0099_fleet_asks_dead.sql — the asks' dead-letter state (CLE-77942, owner
-- bug t1 2f7996aa: "Keep the Kafka style."). Forward-only.
--
-- 0097 gave each ask Kafka's share-group record states except the last one:
-- an ask was re-raised forever. Kafka archives a record once its delivery
-- count reaches the group's limit (KIP-932 group.share.delivery.attempt.limit);
-- here the lease tick does the same at ASKS_MAX_RAISES re-raises, tells the
-- owner once and closes the ask as 'dead' with the reason. dead is a closed
-- state like done and declined: it leaves the open index, a later op on it is
-- a 409 naming who dead-lettered it and why, and a week after its last write
-- the fleet's next put prunes it.
--
--   open -> acked -> done | declined | dead
--   acked -> open (the acquisition lock expired: ASKS_LOCK_MIN, op release)
--
-- release needs no column: the row goes back to open and keeps acked_by as
-- the last holder of the lock.
ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_state_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_state_check
    CHECK (state IN ('open', 'acked', 'done', 'declined', 'dead'));
