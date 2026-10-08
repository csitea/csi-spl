-- 0153_roster_running.sql - whether each announced agent really runs.
-- Forward-only, additive.
--
-- t1 bc1a43e1 (fix A): an agent's presence was its box's, so c-001@<box> read
-- green while that box's desk socket was up and no c-001 process ran on it. The
-- box now reports, on its hello and announce, which of its agents run (a
-- live process that is not stuck on a usage-limit / login screen: the
-- dispatch lease's own liveness test), and the hub serves
-- agent_presence.state = "not_running" for the others.
--
--   roster.running   true = the box says the agent runs, false = it says
--                    it does not, NULL = not reported (an older box, or the
--                    box's report is stale): the agent then reads its box's
--                    presence, as before. The roster is replaced on every
--                    announcement, so a value never outlives the report.
--
-- A NULL column: a catalog-only ADD COLUMN, no rewrite, and the running image
-- ignores it (the hub probes for it). RLS is unchanged: the roster's
-- existing policies cover the new column. No personal data: one flag per agent id.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

ALTER TABLE roster
    ADD COLUMN IF NOT EXISTS running boolean NULL;
