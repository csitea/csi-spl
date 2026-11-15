-- 0285_cost_labels_i18n.sql - the cost labels in every interface language,
-- with a master language (SPL-5546, spec 123; owner HUM-10, csitea 720fa031,
-- 2026-11-14: "the labels in this view should be in the language of the
-- interface", "the data those labels must be stored in language aware
-- table", "there should be a master language where those should be fetched
-- from the db"). Forward-only.
--
--   cost_label_settings       one row: the estate's master language, the
--                             language cost_entries.label is written in.
--   cost_entry_labels         one label per (cost entry, locale). The
--                             master locale's row equals cost_entries.label,
--                             which stays the item's key (cost allocations
--                             match on it), so the master text is set at
--                             entry and never edited here.
--   hr_cost_component_labels  one label per (hr component, locale); 'en' is
--                             rdb 0280's seed.
--
-- A reader's label: its interface locale's row, else the master locale's,
-- else cost_entries.label / hr_cost_components.label.
--
-- Live-data safety: three new tables and copies of existing text; no
-- existing row or column changes. Every existing cost_entries.label becomes
-- that entry's master-locale row, untranslated.
--
-- Operator scope only, like cost_entries (rdb 0245) and rdb 0280.
-- DEPLOY ORDER: apply BEFORE the hub that reads these tables (wf 20 does).

CREATE TABLE IF NOT EXISTS cost_label_settings (
    id             boolean     PRIMARY KEY DEFAULT true CHECK (id),
    master_locale  text        NOT NULL CHECK (master_locale IN
            ('bg','fi','ru','en','sv','he','tr','mk','el','lt','et','lv','sr','ro','uk','sk','pl','es','nl')),
    updated_by     text        NOT NULL CHECK (length(updated_by) BETWEEN 1 AND 200),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cost_entry_labels (
    entry_id    uuid        NOT NULL REFERENCES cost_entries (id) ON DELETE CASCADE,
    locale      text        NOT NULL CHECK (locale IN
            ('bg','fi','ru','en','sv','he','tr','mk','el','lt','et','lv','sr','ro','uk','sk','pl','es','nl')),
    label       text        NOT NULL CHECK (length(label) BETWEEN 1 AND 100),
    updated_by  text        NOT NULL CHECK (length(updated_by) BETWEEN 1 AND 200),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (entry_id, locale)
);

CREATE TABLE IF NOT EXISTS hr_cost_component_labels (
    component   text NOT NULL REFERENCES hr_cost_components (component) ON DELETE CASCADE,
    locale      text NOT NULL CHECK (locale IN
            ('bg','fi','ru','en','sv','he','tr','mk','el','lt','et','lv','sr','ro','uk','sk','pl','es','nl')),
    label       text NOT NULL CHECK (length(label) BETWEEN 1 AND 100),
    PRIMARY KEY (component, locale)
);

-- the master language: the owner's answer to poll 1e669c40 (csitea 720fa031)
INSERT INTO cost_label_settings (id, master_locale, updated_by) VALUES (true, 'bg', 'rdb 0285')
    ON CONFLICT (id) DO NOTHING;

INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by)
    SELECT e.id, s.master_locale, e.label, 'rdb 0285' FROM cost_entries e CROSS JOIN cost_label_settings s
    ON CONFLICT (entry_id, locale) DO NOTHING;

INSERT INTO hr_cost_component_labels (component, locale, label)
    SELECT component, 'en', label FROM hr_cost_components
    ON CONFLICT (component, locale) DO NOTHING;

ALTER TABLE cost_label_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE cost_label_settings FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON cost_label_settings;
CREATE POLICY operator_scope ON cost_label_settings
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE cost_entry_labels ENABLE ROW LEVEL SECURITY;
ALTER TABLE cost_entry_labels FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON cost_entry_labels;
CREATE POLICY operator_scope ON cost_entry_labels
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hr_cost_component_labels ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr_cost_component_labels FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON hr_cost_component_labels;
CREATE POLICY operator_scope ON hr_cost_component_labels
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
