-- 0049_issue_epics.sql — every issue has exactly one parent epic (specs/039
-- §epics, SPL-18, CLE-34993). Forward-only. Data only: no DDL.
--
-- Owner, 2026-09-26: "the issues should have in the left most panel
-- features / epics", "put all of the current issues to random epic", "but
-- basically each issue should have 1 parent epic".
--
-- An epic is an issue carrying the reserved label `epic` (the tenant already
-- works that way). The hub (store.checkIssueRefs) enforces from 0.7.x on:
-- an epic has no parent; every other issue has one parent, and it is an epic.
-- This file makes the rows that exist obey that rule before such a hub runs:
--   1. every tenant with issues gets the `epic` label in its catalogue;
--   2. an epic that has a parent loses it;
--   3. every other issue whose parent is missing or not an epic moves under
--      the tenant's epic titled "random" - the oldest one, created here
--      (next number from issue_counters, status in_progress) when absent.
-- Idempotent in effect: a second pass would find nothing to move.
-- Runs in the operator RLS scope (store.Migrate).

INSERT INTO issue_labels (tenant_id, label_id, name, color, created_by)
SELECT DISTINCT i.tenant_id, 'epic', 'epic', '#8b5cf6', 'hub'
FROM issues i
ON CONFLICT DO NOTHING;

UPDATE issues SET parent_number = NULL
WHERE 'epic' = ANY (labels) AND parent_number IS NOT NULL;

DO $$
DECLARE
    t     text;
    epicn integer;
BEGIN
    FOR t IN
        SELECT DISTINCT c.tenant_id
        FROM issues c
        LEFT JOIN issues p ON p.tenant_id = c.tenant_id AND p.number = c.parent_number
        WHERE NOT ('epic' = ANY (c.labels))
          AND (p.number IS NULL OR NOT ('epic' = ANY (p.labels)))
        ORDER BY 1
    LOOP
        SELECT number INTO epicn FROM issues
        WHERE tenant_id = t AND 'epic' = ANY (labels) AND lower(title) = 'random'
        ORDER BY number LIMIT 1;
        IF epicn IS NULL THEN
            INSERT INTO issue_counters (tenant_id, last_number) VALUES (t, 1)
            ON CONFLICT (tenant_id) DO UPDATE SET last_number = issue_counters.last_number + 1
            RETURNING last_number INTO epicn;
            INSERT INTO issues (tenant_id, number, title, description, status, labels, task_id, created_by, updated_by)
            VALUES (t, epicn, 'random', 'The epic every issue without one was moved under (rdb 0049).',
                    'in_progress', ARRAY['epic'], gen_random_uuid(), 'hub', 'hub');
        END IF;
        UPDATE issues c SET parent_number = epicn, updated_by = 'hub', updated_at = now()
        WHERE c.tenant_id = t
          AND NOT ('epic' = ANY (c.labels))
          AND c.number <> epicn
          AND NOT EXISTS (
              SELECT 1 FROM issues p
              WHERE p.tenant_id = c.tenant_id AND p.number = c.parent_number AND 'epic' = ANY (p.labels));
    END LOOP;
END
$$;
