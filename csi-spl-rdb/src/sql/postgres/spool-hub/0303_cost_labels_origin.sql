-- 0303_cost_labels_origin.sql - who wrote each cost label row, the master
-- text it was made from and when agy reviewed it (SPL-6133, spec 123
-- section 16.6.4, build row L1). Forward-only, idempotent (a second apply
-- changes nothing).
--
-- Owner HUM-10, csitea 720fa031, msg e9f8e835, answer 4: "MC — Machine: a
-- later run may re-make them".
--
-- On cost_entry_labels and hr_cost_component_labels (rdb 0285):
--
--   origin       'hand' (a person) or 'machine' (the API's draft, a fill).
--                Every other-language row already in the tables, the fill
--                lane's included, becomes 'machine'; the master-locale row
--                (cost_label_settings.master_locale) stays 'hand'. The
--                DEFAULT 'hand' keeps today's writers (the POST's master
--                row, a person's PATCH) right until row L2 names it.
--   source_text  the master text a row was made from: cost_entries.label /
--                hr_cost_components.label for the existing other-language
--                rows, NULL on the master row itself.
--   reviewed_at  when agy confirmed or corrected a machine row; NULL until
--                then and on a hand row. Every existing row starts NULL, so
--                the first night's run reviews them.
--
-- The backfill touches only rows whose origin is still NULL, i.e. rows from
-- before this file: a second apply never turns a later hand row to machine.
--
-- Live-data safety: three nullable columns, one UPDATE of the existing label
-- rows, then NOT NULL and the CHECK; no row is deleted, no label changes.
-- DEPLOY ORDER: apply BEFORE the hub that writes these columns (wf 20 does).

ALTER TABLE cost_entry_labels ADD COLUMN IF NOT EXISTS origin text;
ALTER TABLE cost_entry_labels ADD COLUMN IF NOT EXISTS source_text text;
ALTER TABLE cost_entry_labels ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;

ALTER TABLE hr_cost_component_labels ADD COLUMN IF NOT EXISTS origin text;
ALTER TABLE hr_cost_component_labels ADD COLUMN IF NOT EXISTS source_text text;
ALTER TABLE hr_cost_component_labels ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;

UPDATE cost_entry_labels l
    SET origin = CASE WHEN l.locale = s.master_locale THEN 'hand' ELSE 'machine' END,
        source_text = CASE WHEN l.locale = s.master_locale THEN NULL ELSE e.label END
    FROM cost_entries e, cost_label_settings s
    WHERE e.id = l.entry_id AND l.origin IS NULL;

UPDATE hr_cost_component_labels l
    SET origin = CASE WHEN l.locale = s.master_locale THEN 'hand' ELSE 'machine' END,
        source_text = CASE WHEN l.locale = s.master_locale THEN NULL ELSE c.label END
    FROM hr_cost_components c, cost_label_settings s
    WHERE c.component = l.component AND l.origin IS NULL;

-- no master locale set (cost_label_settings empty): nothing to tell apart,
-- every row was typed or seeded by a person
UPDATE cost_entry_labels SET origin = 'hand' WHERE origin IS NULL;
UPDATE hr_cost_component_labels SET origin = 'hand' WHERE origin IS NULL;

ALTER TABLE cost_entry_labels ALTER COLUMN origin SET DEFAULT 'hand';
ALTER TABLE cost_entry_labels ALTER COLUMN origin SET NOT NULL;
ALTER TABLE cost_entry_labels DROP CONSTRAINT IF EXISTS cost_entry_labels_origin_check;
ALTER TABLE cost_entry_labels ADD CONSTRAINT cost_entry_labels_origin_check
    CHECK (origin IN ('hand','machine'));

ALTER TABLE hr_cost_component_labels ALTER COLUMN origin SET DEFAULT 'hand';
ALTER TABLE hr_cost_component_labels ALTER COLUMN origin SET NOT NULL;
ALTER TABLE hr_cost_component_labels DROP CONSTRAINT IF EXISTS hr_cost_component_labels_origin_check;
ALTER TABLE hr_cost_component_labels ADD CONSTRAINT hr_cost_component_labels_origin_check
    CHECK (origin IN ('hand','machine'));
