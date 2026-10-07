-- 0148_session_revocations.sql - an admin resets a member's password and signs
-- them out everywhere (owner HUM-10, t1 ea0af569, msg 56dd81ee: "add the ui and
-- the api functionality for the admins to be able to reset the user's
-- passwords"). Forward-only.
--
--   session_revocations  one row per human with a session cut-off. Sessions
--                        are stateless signed cookies, so "sign out
--                        everywhere" is a cut-off: a session of that human
--                        issued at or before revoked_at is no session. Every
--                        hub instance reads the rows newer than the session
--                        TTL (auth/revoke.go); an older row is inert. Hub-wide
--                        like humans (no tenant_id, outside rdb 0014's RLS):
--                        a session is not per workspace.
--
--   member_activity.kind gains 'password_reset': the audit row the reset
--                        writes in the workspace whose admin asked (who, whom,
--                        when; detail 'signed_out' when the sessions went too).
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: wf 20 applies this before the hub that reads it rolls.

CREATE TABLE session_revocations (
    human_id   text        PRIMARY KEY REFERENCES humans (human_id) ON DELETE CASCADE,
    revoked_at timestamptz NOT NULL
);
CREATE INDEX session_revocations_at ON session_revocations (revoked_at);

ALTER TABLE member_activity DROP CONSTRAINT member_activity_kind_check;
ALTER TABLE member_activity ADD CONSTRAINT member_activity_kind_check CHECK (kind IN (
    'role_changed', 'removed', 'invited', 'invite_accepted',
    'sign_in', 'sign_out', 'session_expiry', 'password_reset'));
