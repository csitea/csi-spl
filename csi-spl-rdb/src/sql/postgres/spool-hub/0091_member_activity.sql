-- 0091_member_activity.sql — the per-person Activity log (CLE-77799, owner topic
-- 1fc29f99: "the admin should be able to see ... the main event log activities
-- for this person, when he has logged in, and logged out etc."). Forward-only.
--
-- One tenant-scoped, durable audit row per event ABOUT a member: membership
-- events (role change, removal) and, from the auth flow, sign-in (with method)
-- / sign-out / session expiry. It sits ALONGSIDE member_clones (0088, act-as,
-- CLE-77797) — the People-card Activity log unions the two.
--
-- Privacy (owner rules, relayed via CLE-001): auth rows carry ONLY the event,
-- time, method, outcome, a /24-masked IP and a coarse user agent (browser +
-- OS) — never a token, cookie, password, a full IP or a third party's email.
-- Read behind audit.read (a tenant's admins/owners) or by the subject
-- themself; a 90-day retention sweep prunes the auth rows (see the sweep).
CREATE TABLE member_activity (
    activity_id bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    subject_hum text        NOT NULL,   -- the member the event is ABOUT (snapshot, no FK: rows outlive the member)
    actor_hum   text        NOT NULL DEFAULT '',  -- who caused it (the admin); '' for the member's own action
    kind        text        NOT NULL CHECK (kind IN (
                    'role_changed', 'removed', 'invited', 'invite_accepted',
                    'sign_in', 'sign_out', 'session_expiry')),
    detail      text        NOT NULL DEFAULT '',  -- role / from->to / sign-in method / outcome — never a secret
    ip          text        NOT NULL DEFAULT '',  -- /24-masked client IP (auth rows only)
    ua          text        NOT NULL DEFAULT '',  -- coarse user agent, browser + OS (auth rows only)
    created_at  timestamptz NOT NULL DEFAULT now()
);
-- the card reads one subject's rows, newest first
CREATE INDEX member_activity_subject ON member_activity (tenant_id, subject_hum, activity_id DESC);
-- the retention sweep prunes auth rows by age
CREATE INDEX member_activity_age ON member_activity (created_at);

-- RLS in the 0014/0021/0088 shape, with the empty-setting guard (NULLIF: a
-- pooled connection reads the GUC as '' after any transaction-local
-- set_config, never NULL; CLE-3416). A tenant reads and writes only its own
-- rows; the operator scope (Sweep, spool migrate) sees everything.
ALTER TABLE member_activity ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_activity FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON member_activity
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON member_activity
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
