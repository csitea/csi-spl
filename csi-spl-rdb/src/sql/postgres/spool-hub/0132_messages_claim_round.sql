-- 0132_messages_claim_round.sql - the two-phase claim on a peer message
-- (spec 093 section 4.1, task T008). Forward-only, idempotent.
--
-- 0110 (spec 068) made a seat's poll loop the owner of a message in one
-- step, so a seat whose model was dead still owned what its loop took. 093
-- splits the claim: a ROUND run by code tells up to OFFER_K seats about a
-- job, and the job is owned only once an agent ACCEPTS it with its own tool
-- call. One column names the state, and the statement that moves a row
-- writes it together with the clocks, so a row is in exactly one state:
--
--   claim_state   free | offered | owned | parked | done
--   offer_set     the seats told in the open round
--   offer_n       +1 per round opened; the accept names it (--round)
--   offer_until   the open round's end; while free, the moment the row went
--                 free (a lapse, an expiry, a release): a busy seat may open
--                 a round only BUSY_DELAY after it
--   lapsed        the seats of lapsed rounds: a one-lap skip list, cleared
--                 when every ready seat is on it (not_by is the permanent one)
--   accepted_at   the accept that made the current holder
--   touched_at    the holder's last call naming this job (accept, park,
--                 unpark, touch, release, done): a job untouched for
--                 JOB_IDLE_MAX is not renewed
--   parked_until  the holder's declared wait (at most PARK_MAX ahead)
--   park_reason   why it waits
--   wait_token    what it waits on (a lane id, a task id, a CI run); kept
--                 when a parked job expires, so the next owner inherits it
--
-- 0110's responsible, locked_until, responsible_gen, claim_n, not_by and
-- handled_* stay; claim_n now counts ACCEPTS only (a lapsed round is not a
-- delivery). All times are the hub's clock.
--
-- Every ADD COLUMN has a constant default (catalog-only, no rewrite). The
-- back-fill gives the closed rows and any open 0110 claim their state.
-- DEPLOY ORDER: apply BEFORE the hub that serves the 093 `claim` ops (T009).

ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS claim_state  text        NOT NULL DEFAULT 'free',
    ADD COLUMN IF NOT EXISTS offer_set    text[]      NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS offer_n      integer     NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS offer_until  timestamptz NULL,
    ADD COLUMN IF NOT EXISTS lapsed       text[]      NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS accepted_at  timestamptz NULL,
    ADD COLUMN IF NOT EXISTS touched_at   timestamptz NULL,
    ADD COLUMN IF NOT EXISTS parked_until timestamptz NULL,
    ADD COLUMN IF NOT EXISTS park_reason  text        NULL,
    ADD COLUMN IF NOT EXISTS wait_token   text        NULL;

ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_claim_state_check;
ALTER TABLE messages
    ADD CONSTRAINT messages_claim_state_check
        CHECK (claim_state IN ('free', 'offered', 'owned', 'parked', 'done'));
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_claim_round_text_check;
ALTER TABLE messages
    ADD CONSTRAINT messages_claim_round_text_check
        CHECK ((park_reason IS NULL OR length(park_reason) <= 500)
           AND (wait_token IS NULL OR length(wait_token) <= 200));

-- Operator scope: this file runs in one transaction, and messages FORCEs RLS (0014).
SELECT set_config('app.rls_scope', 'operator', true);
UPDATE messages SET claim_state = 'done'
WHERE claim_state = 'free' AND handled_at IS NOT NULL;
UPDATE messages SET claim_state = 'owned'
WHERE claim_state = 'free' AND needs_peer AND handled_at IS NULL
  AND responsible IS NOT NULL AND locked_until IS NOT NULL;
