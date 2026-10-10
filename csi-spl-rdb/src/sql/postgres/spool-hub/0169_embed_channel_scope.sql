-- 0169_embed_channel_scope.sql - the visitor channel's tables and the
-- channel-scope row level security (specs/121 T101, sections 4.1, 4.2, 5).
-- Forward-only, additive.
--
-- 1. embed_customers: one embedding site of a workspace. allowed_origins
--    feeds its frame-ancestors (spec 5); jwt_public_key is the PUBLIC half
--    of the per-embed key a signed-in customer's server signs with (spec 5,
--    R3). The private half is the customer's: never here, never in a log. A
--    CHECK refuses a PEM private key pasted by mistake.
-- 2. embed_visitors: one anonymous visitor (spec 4.1). token_hash is the
--    sha256 of the 256-bit bearer token, never the token; ip_hash is a
--    salted sha256, never the address; email is the optional relink address.
--    human_id is the visitor's own HUM row (kind channel_guest), so a token
--    lookup names the human the hub acts as. One visitor, one channel:
--    deleting the channel (retention, erasure) takes the visitor row with it.
-- 3. humans.kind: 'member' (every existing row) or 'channel_guest' (a
--    visitor: no e-mail on the HUM row, no password, no identity provider).
-- 4. rbac_roles channel_guest: a system role like demo_user, with NO
--    permission at all. No member route can authorize it, so a guest HUM
--    that ever reached a member route would be refused everywhere; the
--    visitor path (T104) authorizes by its bearer token and runs every
--    statement under the channel scope below, never by a permission.
--    internal/rbac Defaults carries the same row (TestRBACSeedMatchesDefaults).
-- 5. The RESTRICTIVE policy channel_scope, USING and WITH CHECK, on every
--    table a channel reader reaches:
--      channel column:      messages (channel), channels, channel_humans,
--                           channel_subscriptions, topic_head_parts (channel),
--                           embed_visitors
--      through its message: message_reactions, message_revisions,
--                           message_kind_changes, message_moderation,
--                           message_answers (answers)
--    Files have no table: a message carries them (messages.files) and the
--    file door asks the message (rdb 0030). The search signature index is
--    messages.search_sig / search_tsv, read through spool_search_candidates
--    (rdb 0143) from messages: both sit behind the messages policy.
--    topic_heads (ids and times, no text, no channel) is left out: its
--    trigger writes a head before the head's parts exist.
--
--    The setting app.channel_scope is transaction-local (store.inChannel,
--    T102), like app.tenant_id. Unset or '' (the NULLIF guard of rdb 0021:
--    a pooled connection reads '' after any set_config) means no channel
--    scope: the policy is TRUE and a staff session is unchanged. Set, a row
--    passes only when its channel is that channel: a DM (channel NULL) and
--    the default channels (lobby, tasks, alerts) never do. Restrictive, so
--    it only narrows tenant_scope / operator_scope and never widens them.
--    The unset test is spelled CASE ... END IS NOT NULL, not the plain
--    NULLIF(...) IS NULL: the planner folds current_setting while it
--    estimates and prices "<expr> IS NULL" at 0.5% of the rows, so the plain
--    form cut every messages estimate 200-fold for a staff session and
--    turned the unread plans (store E04 budgets); "IS NOT NULL" prices at
--    99.5%. store TestRLSChannelScopePlannerNeutral pins it.
--
-- RLS of the two new tables: the 0014/0021 shape with the NULLIF guard;
-- store TestRLSPoliciesFailClosed (rls_failclosed_test.go) reads them from
-- the catalogue. Runtime grants: the default privileges of
-- spool-hub-roles/runtime-grants.sql.
--
-- Live-data safety: two new empty tables; humans.kind is a constant default
-- (catalog-only) plus a CHECK that scans humans once; CREATE POLICY is
-- catalog-only but holds ACCESS EXCLUSIVE on its table until COMMIT, hence
-- lock_timeout: on a busy messages table the file fails fast instead of
-- queueing every write behind it. No deploy order: no running hub sets
-- app.channel_scope, so every policy below is TRUE for it. Runs under the
-- operator RLS scope (spool migrate, rdb 0014). No personal data, no secret.

SET LOCAL lock_timeout = '5s';

CREATE TABLE embed_customers (
    tenant_id       text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    -- In the iframe URL (/embed/v1/chat?e=<embed_id>), so unique hub-wide.
    embed_id        text        NOT NULL PRIMARY KEY CHECK (embed_id ~ '^[a-z0-9][a-z0-9-]{2,63}$'),
    allowed_origins text[]      NOT NULL DEFAULT '{}'
                                CHECK (cardinality(allowed_origins) <= 32 AND NOT ('*' = ANY (allowed_origins))),
    jwt_public_key  text        NULL
                                CHECK (jwt_public_key IS NULL OR (length(jwt_public_key) <= 4096
                                       AND jwt_public_key NOT ILIKE '%PRIVATE KEY%')),
    jwt_key_id      text        NULL CHECK (jwt_key_id IS NULL OR length(jwt_key_id) BETWEEN 1 AND 128),
    enabled         boolean     NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, embed_id)
);

CREATE TABLE embed_visitors (
    tenant_id    text        NOT NULL,
    embed_id     text        NOT NULL,
    visitor_id   uuid        NOT NULL,
    token_hash   bytea       NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
    human_id     text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    channel_id   text        NOT NULL,
    ip_hash      bytea       NULL CHECK (ip_hash IS NULL OR octet_length(ip_hash) = 32),
    email        text        NULL CHECK (email IS NULL OR (email = lower(email) AND length(email) <= 320)),
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, visitor_id),
    UNIQUE (tenant_id, channel_id),
    FOREIGN KEY (tenant_id, embed_id) REFERENCES embed_customers (tenant_id, embed_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, channel_id) REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE
);
-- The token sweep (spec 4.1, the SweepDemo pattern) reads the expired ones.
CREATE INDEX embed_visitors_expires ON embed_visitors (tenant_id, expires_at);

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['embed_customers', 'embed_visitors'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, t);
    END LOOP;
END
$$;

ALTER TABLE humans ADD COLUMN kind text NOT NULL DEFAULT 'member'
    CONSTRAINT humans_kind_check CHECK (kind IN ('member', 'channel_guest'));
ALTER TABLE humans ADD CONSTRAINT humans_channel_guest_no_email CHECK (kind <> 'channel_guest' OR email IS NULL);

INSERT INTO rbac_roles (role_id, tenant_owner, description) VALUES
    ('channel_guest', false, 'a website visitor in its one channel; holds no permission (specs/121)');

-- 5. channel_scope. A table with its own channel column:
DO $$
DECLARE
    t   text;
    col text;
    unscoped text := $u$CASE WHEN NULLIF(current_setting('app.channel_scope', true), '') IS NULL THEN 1 END IS NOT NULL$u$;
BEGIN
    FOR t, col IN VALUES
        ('messages', 'channel'), ('channels', 'channel_id'), ('channel_humans', 'channel_id'),
        ('channel_subscriptions', 'channel_id'), ('topic_head_parts', 'channel'), ('embed_visitors', 'channel_id')
    LOOP
        EXECUTE format($p$CREATE POLICY channel_scope ON %1$I AS RESTRICTIVE
            USING (%3$s
                   OR %2$I = current_setting('app.channel_scope', true))
            WITH CHECK (%3$s
                   OR %2$I = current_setting('app.channel_scope', true))$p$, t, col, unscoped);
    END LOOP;
END
$$;

-- A table that reaches a channel through its message (messages' own policy
-- binds the subquery too):
DO $$
DECLARE
    t   text;
    col text;
    unscoped text := $u$CASE WHEN NULLIF(current_setting('app.channel_scope', true), '') IS NULL THEN 1 END IS NOT NULL$u$;
BEGIN
    FOR t, col IN VALUES
        ('message_reactions', 'msg_id'), ('message_revisions', 'msg_id'), ('message_kind_changes', 'msg_id'),
        ('message_moderation', 'msg_id'), ('message_answers', 'answers')
    LOOP
        EXECUTE format($p$CREATE POLICY channel_scope ON %1$I AS RESTRICTIVE
            USING (%3$s
                   OR EXISTS (SELECT 1 FROM messages m
                              WHERE m.tenant_id = %1$I.tenant_id AND m.msg_id = %1$I.%2$I
                                AND m.channel = current_setting('app.channel_scope', true)))
            WITH CHECK (%3$s
                   OR EXISTS (SELECT 1 FROM messages m
                              WHERE m.tenant_id = %1$I.tenant_id AND m.msg_id = %1$I.%2$I
                                AND m.channel = current_setting('app.channel_scope', true)))$p$, t, col, unscoped);
    END LOOP;
END
$$;
