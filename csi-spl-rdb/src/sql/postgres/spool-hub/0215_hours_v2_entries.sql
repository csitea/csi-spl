-- 0215_hours_v2_entries.sql - hours entries widen for spec 107 v2 (build
-- row T020; FR-18, FR-23, FR-27, FR-28, FR-30). Forward-only. Owner HUM-10,
-- csitea topic 55a2d6c2, msg 81ed4911 (the go to build v2).
--
--   hours_entries
--     kind              work (default), travel, wait, absence (FR-27). It
--                       joins the key (expand step): a unique index on
--                       (tenant_id, member_id, day, target, kind) beside the
--                       v1 four-column PK. Every v1 row is work.
--     target            the CHECK widens to job:<job_id> (FR-18), a
--                       constraint redefinition in the 0148 pattern.
--     state             adds proposed (a foreman's row, before the worker
--                       approves) and disputed (FR-23).
--     absence_type      sick, vacation, unpaid, training, holiday (FR-30):
--                       set exactly when kind is absence.
--     entered_by        who entered the row for the member (the foreman,
--                       FR-23); NULL = the member's own row.
--     reason            a travel or wait row's reason (FR-27), <= 500.
--     category_minutes  the approved minutes split by rate category, stored
--                       at approval (FR-28): a jsonb object, NULL until then.
--                       A label on hours, never money (FR-19).
--   hours_entry_spans
--     kind              the entry's kind; the FK to hours_entries moves to
--                       the five-column unique index (it named the PK).
--
-- hours_minutes and its target CHECK stay as v1 (FR-18): a job is suggested
-- from its linked topic at read time, never written as a minute.
--
-- Live-data safety: ADD COLUMN with a constant default is catalog-only; the
-- new unique index builds once over hours_entries and the FK check reads
-- hours_entry_spans once, both under ACCESS EXCLUSIVE until COMMIT, hence
-- lock_timeout. No personal data, no secret, no money field.
-- EXPAND / CONTRACT (deploy safety): wf 20 applies this before the hub that
-- reads it rolls, so the v1 hub keeps writing on this schema: its upsert and
-- sweep name ON CONFLICT (tenant_id, member_id, day, target), which still
-- matches the PK, and the T020 hub names the five columns, which match the
-- new unique index. The contract step, a later migration that lands only
-- once the T020 hub serves on dev and prd, drops the four-column PK and
-- promotes the index (PRIMARY KEY USING INDEX). Until then a second kind on
-- one (day, target) is refused by the PK; nothing writes one before that.
-- Runs under the operator RLS scope (spool migrate, rdb 0014); the RLS
-- policies of 0151 and 0176 stay as they are.

SET LOCAL lock_timeout = '5s';

-- 1. hours_entries: the new columns.
ALTER TABLE hours_entries
    ADD COLUMN kind text NOT NULL DEFAULT 'work'
        CONSTRAINT hours_entries_kind_check CHECK (kind IN ('work', 'travel', 'wait', 'absence')),
    ADD COLUMN absence_type text NULL
        CONSTRAINT hours_entries_absence_type_check
        CHECK (absence_type IN ('sick', 'vacation', 'unpaid', 'training', 'holiday')),
    ADD COLUMN entered_by text NULL
        CONSTRAINT hours_entries_entered_by_check CHECK (length(entered_by) BETWEEN 1 AND 200),
    ADD COLUMN reason text NULL
        CONSTRAINT hours_entries_reason_check CHECK (length(reason) <= 500),
    ADD COLUMN category_minutes jsonb NULL
        CONSTRAINT hours_entries_category_minutes_check CHECK (jsonb_typeof(category_minutes) = 'object'),
    ADD CONSTRAINT hours_entries_absence_kind_check
        CHECK ((kind = 'absence') = (absence_type IS NOT NULL));

-- 2. The target and state CHECKs, redefined (the 0148 pattern).
ALTER TABLE hours_entries DROP CONSTRAINT hours_entries_target_check;
ALTER TABLE hours_entries ADD CONSTRAINT hours_entries_target_check
    CHECK (target ~ '^(t|ch|dm|cal|job):.{1,200}$' OR target = 'ws');
ALTER TABLE hours_entries DROP CONSTRAINT hours_entries_state_check;
ALTER TABLE hours_entries ADD CONSTRAINT hours_entries_state_check
    CHECK (state IN ('approved', 'rejected', 'proposed', 'disputed'));

-- 3. The key (expand): the five-column unique index beside the v1 PK; the
--    spans get their kind and their FK moves to that index.
ALTER TABLE hours_entry_spans DROP CONSTRAINT hours_entry_spans_tenant_id_member_id_day_target_fkey;
CREATE UNIQUE INDEX hours_entries_kind_key ON hours_entries (tenant_id, member_id, day, target, kind);

ALTER TABLE hours_entry_spans
    ADD COLUMN kind text NOT NULL DEFAULT 'work',
    ADD CONSTRAINT hours_entry_spans_entry_fkey FOREIGN KEY (tenant_id, member_id, day, target, kind)
        REFERENCES hours_entries (tenant_id, member_id, day, target, kind) ON DELETE CASCADE;

-- The entry's spans (the FK's cascade and the per-entry replace).
DROP INDEX hours_entry_spans_entry;
CREATE INDEX hours_entry_spans_entry ON hours_entry_spans (tenant_id, member_id, day, target, kind);
