-- 0089_fallback_attempts.sql — re-escalate a post the responder never acted on
-- (SPL-1225 miss fix, prd t1 topic 4b0ba40a). Forward-only.
--
-- Measured 2026-09-30: HUM-10's #spool-hub-bugs post e2246b90 (09:44Z) WAS
-- escalated to the responder CLE-001 at 09:46Z, but the terminal poke was
-- refused (CLE-001's pane held unsent text) and dropped after 300s, so nobody
-- acted until the owner pinged 49 min later. A single fallback row then hid the
-- post from BOTH reconcile sweeps forever (NOT EXISTS fallback_deliveries) — one
-- failed poke = permanent silence.
--
-- attempts counts the escalations of a post. The relay re-escalates a post that
-- is still unanswered a re-escalate interval after its last attempt, up to a cap
-- (SPOOL_HUB_REESCALATE_MAX), re-poking and rotating to the next responder /
-- any awake agent. delivered_at is the LAST attempt's time. Existing rows read
-- attempts = 1 (the default), so the running image rolls before this.

ALTER TABLE fallback_deliveries
    ADD COLUMN IF NOT EXISTS attempts int NOT NULL DEFAULT 1
    CONSTRAINT fallback_deliveries_attempts_check CHECK (attempts >= 1);
