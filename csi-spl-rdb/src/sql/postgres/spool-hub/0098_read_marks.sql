-- 0098_read_marks.sql — a member's read position per channel, thread and DM,
-- kept on the hub (CLE-77930). Forward-only.
--
-- The owner (t1 bf737f3f, 02:10Z): "I see, on a specific channel, 2 new
-- messages, then I go there and there is nothing new for me", and 02:12Z:
-- unread is "for me and me only ... not the new messages which I have seen".
-- The read cursors lived only in each browser's localStorage, so a line read
-- on the phone stayed "new" on the desktop, and a second tab or a cleared
-- profile started from nothing. One row per (tenant, member, key):
--   key   'ch:<channel>' | 't:<task_id>' | 'dm:<peer>'  — the WUI cursor keys
--   at, msg_id  the newest line read (a thread mark: when it was read)
--   seen  a thread's reply total the member had seen (the card's "<new>/<total>")
-- A write only ever moves a mark forward (store SaveReadMarks).

CREATE TABLE read_marks (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id   text        NOT NULL,
    mark_key    text        NOT NULL CHECK (mark_key ~ '^(ch|t|dm):.{1,200}$'),
    at          timestamptz NOT NULL,
    msg_id      text        NOT NULL DEFAULT '',
    seen        integer     NOT NULL DEFAULT 0 CHECK (seen >= 0),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, member_id, mark_key)
);

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF, CLE-3416).
ALTER TABLE read_marks ENABLE ROW LEVEL SECURITY;
ALTER TABLE read_marks FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON read_marks
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON read_marks
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
