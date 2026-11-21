package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
)

// Postgres side of rdb 0285 and rdb 0303. Every statement runs in the
// operator scope, like cost_entries (rdb 0245): the rows are the estate's, no
// tenant.

// pgCostLabelMasterInsert is a new entry's master-locale label, in the
// entry's own transaction; no row while no master locale is set.
const pgCostLabelMasterInsert = `INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by)
	SELECT $1::uuid, master_locale, $2, $3 FROM cost_label_settings`

// pgCostLabelKnownCopy gives new entry $1 the other locales' rows of the
// newest other entry with its text $2 that has any, origin and review mark
// kept (spec 123 16.6.2 point 1): a known text is in every language it has
// the moment it is saved.
const pgCostLabelKnownCopy = `INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by, origin, source_text, reviewed_at)
	SELECT $1::uuid, l.locale, l.label, l.updated_by, l.origin, l.source_text, l.reviewed_at
	FROM cost_label_settings st JOIN cost_entry_labels l ON l.locale <> st.master_locale
	WHERE l.entry_id = (SELECT e.id FROM cost_entries e WHERE e.label = $2 AND e.id <> $1::uuid
		AND EXISTS (SELECT 1 FROM cost_entry_labels x WHERE x.entry_id = e.id AND x.locale <> st.master_locale)
		ORDER BY e.created_at DESC, e.id DESC LIMIT 1)`

// pgCostLabelHand is a person's labels on entry $1 (locales $2, texts $3, by
// $4, master text $5): a locale whose text differs from the row becomes hand,
// one sent unchanged keeps its row.
const pgCostLabelHand = `INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by, origin, source_text)
	SELECT $1::uuid, w.locale, w.label, $4, 'hand', $5 FROM unnest($2::text[], $3::text[]) AS w(locale, label)
	ON CONFLICT (entry_id, locale) DO UPDATE SET label = EXCLUDED.label, updated_by = EXCLUDED.updated_by,
		updated_at = now(), origin = 'hand', source_text = EXCLUDED.source_text, reviewed_at = NULL
	WHERE cost_entry_labels.label IS DISTINCT FROM EXCLUDED.label`

// pgCostLabelDropLeftOut deletes, on every entry with text $1, each locale
// but the master $2 that the person's labels $3 leave out.
const pgCostLabelDropLeftOut = `DELETE FROM cost_entry_labels l USING cost_entries e
	WHERE e.id = l.entry_id AND e.label = $1 AND l.locale <> $2 AND NOT (l.locale = ANY($3::text[]))`

// pgCostLabelToSiblings writes entry $1's rows but the master $3's on every
// other entry with its text $2, as they are (owner answer 5 "T").
const pgCostLabelToSiblings = `INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by, origin, source_text, reviewed_at)
	SELECT t.id, l.locale, l.label, l.updated_by, l.origin, l.source_text, l.reviewed_at
	FROM cost_entry_labels l JOIN cost_entries t ON t.label = $2 AND t.id <> $1::uuid
	WHERE l.entry_id = $1::uuid AND l.locale <> $3
	ON CONFLICT (entry_id, locale) DO UPDATE SET label = EXCLUDED.label, updated_by = EXCLUDED.updated_by,
		updated_at = now(), origin = EXCLUDED.origin, source_text = EXCLUDED.source_text, reviewed_at = EXCLUDED.reviewed_at
	WHERE (cost_entry_labels.label, cost_entry_labels.origin, cost_entry_labels.source_text, cost_entry_labels.reviewed_at)
		IS DISTINCT FROM (EXCLUDED.label, EXCLUDED.origin, EXCLUDED.source_text, EXCLUDED.reviewed_at)`

// pgCostLabelMachineEntry upserts the machine labels (locales $2, texts $3,
// reviewed $4, by $5) of every entry with text $1. The WHERE is the guard of
// spec 123 16.6.4: a hand row is skipped in SQL, so a person who corrects a
// row between a read and this write still wins.
const pgCostLabelMachineEntry = `INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by, origin, source_text, reviewed_at)
	SELECT e.id, w.locale, w.label, $5, 'machine', e.label, CASE WHEN $4::boolean THEN now() END
	FROM cost_entries e CROSS JOIN unnest($2::text[], $3::text[]) AS w(locale, label) WHERE e.label = $1
	ON CONFLICT (entry_id, locale) DO UPDATE SET label = EXCLUDED.label, updated_by = EXCLUDED.updated_by,
		updated_at = now(), source_text = EXCLUDED.source_text, reviewed_at = EXCLUDED.reviewed_at
	WHERE cost_entry_labels.origin = 'machine'`

// pgCostLabelMachineComp is pgCostLabelMachineEntry for component $1, made
// from its master text (its master-locale label, else its own), same guard.
const pgCostLabelMachineComp = `INSERT INTO hr_cost_component_labels (component, locale, label, origin, source_text, reviewed_at)
	SELECT c.component, w.locale, w.label, 'machine', coalesce(m.label, c.label), CASE WHEN $4::boolean THEN now() END
	FROM hr_cost_components c
	LEFT JOIN cost_label_settings st ON true
	LEFT JOIN hr_cost_component_labels m ON m.component = c.component AND m.locale = st.master_locale
	CROSS JOIN unnest($2::text[], $3::text[]) AS w(locale, label)
	WHERE c.component = $1
	ON CONFLICT (component, locale) DO UPDATE SET label = EXCLUDED.label,
		source_text = EXCLUDED.source_text, reviewed_at = EXCLUDED.reviewed_at
	WHERE hr_cost_component_labels.origin = 'machine'`

// CostLabelMaster is CostLabelStore on Postgres.
func (s *Postgres) CostLabelMaster(ctx context.Context) (string, error) {
	master := ""
	err := s.asOperatorQuery(ctx, `SELECT master_locale FROM cost_label_settings`, nil,
		func(rows pgx.Rows) error { return rows.Scan(&master) })
	return master, err
}

// CostEntryLabels is CostLabelStore on Postgres.
func (s *Postgres) CostEntryLabels(ctx context.Context) (map[string]map[string]string, error) {
	out := map[string]map[string]string{}
	err := s.asOperatorQuery(ctx, `SELECT entry_id::text, locale, label FROM cost_entry_labels ORDER BY entry_id, locale`, nil,
		func(rows pgx.Rows) error {
			var id, loc, text string
			if err := rows.Scan(&id, &loc, &text); err != nil {
				return err
			}
			if out[id] == nil {
				out[id] = map[string]string{}
			}
			out[id][loc] = text
			return nil
		})
	return out, err
}

// CostEntryLabelMarks is CostLabelStore on Postgres.
func (s *Postgres) CostEntryLabelMarks(ctx context.Context) (map[string]map[string]CostLabelMark, error) {
	out := map[string]map[string]CostLabelMark{}
	err := s.asOperatorQuery(ctx, `SELECT l.entry_id::text, l.locale,
			CASE WHEN l.origin = 'machine' AND l.reviewed_at IS NOT NULL THEN 'reviewed' ELSE l.origin END,
			l.locale IS DISTINCT FROM st.master_locale AND l.source_text IS DISTINCT FROM e.label
		FROM cost_entry_labels l JOIN cost_entries e ON e.id = l.entry_id
		LEFT JOIN cost_label_settings st ON true ORDER BY l.entry_id, l.locale`, nil,
		func(rows pgx.Rows) error {
			var id, loc string
			var m CostLabelMark
			if err := rows.Scan(&id, &loc, &m.Origin, &m.Stale); err != nil {
				return err
			}
			if out[id] == nil {
				out[id] = map[string]CostLabelMark{}
			}
			out[id][loc] = m
			return nil
		})
	return out, err
}

// costLabelArrays is labels but the master's as two parallel arrays, for
// unnest.
func costLabelArrays(labels map[string]string, master string) ([]string, []string) {
	locs, texts := []string{}, []string{}
	for loc, text := range labels {
		if loc != master {
			locs, texts = append(locs, loc), append(texts, text)
		}
	}
	return locs, texts
}

// SetCostEntryLabels is CostLabelStore on Postgres: one transaction reads the
// entry's own text and the master locale, checks labels against them, writes
// the named entry's rows (pgCostLabelHand), drops the locales left out on
// every entry with the text, then copies the named entry's rows to the others.
func (s *Postgres) SetCostEntryLabels(ctx context.Context, id string, labels map[string]string, by string) error {
	if !uuidRe.MatchString(id) {
		return ErrNotFound
	}
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		var own, master string
		err := tx.QueryRow(ctx, `SELECT e.label, coalesce((SELECT master_locale FROM cost_label_settings), '')
			FROM cost_entries e WHERE e.id = $1::uuid`, id).Scan(&own, &master)
		if err == pgx.ErrNoRows {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if why := CheckCostEntryLabels(labels, master, own); why != "" {
			return fmt.Errorf("cost labels: %s", why)
		}
		locs, texts := costLabelArrays(labels, master)
		if _, err := tx.Exec(ctx, pgCostLabelHand, id, locs, texts, by, own); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, pgCostLabelDropLeftOut, own, master, locs); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, pgCostLabelToSiblings, id, own, master)
		return err
	})
}

// SetMachineCostLabels is CostLabelStore on Postgres: one transaction checks
// labels against the master locale and that key names something, then runs
// the guarded upsert.
func (s *Postgres) SetMachineCostLabels(ctx context.Context, key CostLabelKey, labels map[string]string, reviewed bool, by string) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		master, found := "", false
		err := tx.QueryRow(ctx, `SELECT coalesce((SELECT master_locale FROM cost_label_settings), ''),
			EXISTS (SELECT 1 FROM cost_entries WHERE $1 <> '' AND label = $1)
			OR EXISTS (SELECT 1 FROM hr_cost_components WHERE $2 <> '' AND component = $2)`,
			key.Text, key.Component).Scan(&master, &found)
		if err != nil {
			return err
		}
		if why := checkMachineCostLabels(key, labels, master); why != "" {
			return fmt.Errorf("cost labels: %s", why)
		}
		if !found {
			return ErrNotFound
		}
		locs, texts := costLabelArrays(labels, master)
		sql, args := pgCostLabelMachineEntry, []any{key.Text, locs, texts, reviewed, by}
		if key.Component != "" {
			sql, args = pgCostLabelMachineComp, []any{key.Component, locs, texts, reviewed}
		}
		tag, err := tx.Exec(ctx, sql, args...)
		n = int(tag.RowsAffected())
		return err
	})
	return n, err
}

// pgCostLabelMissingTexts is each entry text with the locales (of $1, but
// the master's) that one of its entries lacks or holds as a machine row made
// from another text (spec 123 16.6.2 points 3 and 5).
const pgCostLabelMissingTexts = `SELECT e.label, e.label, array_agg(DISTINCT u.loc ORDER BY u.loc)
	FROM cost_entries e
	CROSS JOIN cost_label_settings st
	CROSS JOIN unnest($1::text[]) AS u(loc)
	LEFT JOIN cost_entry_labels l ON l.entry_id = e.id AND l.locale = u.loc
	WHERE u.loc <> st.master_locale
		AND (l.entry_id IS NULL OR (l.origin = 'machine' AND l.source_text IS DISTINCT FROM e.label))
	GROUP BY e.label ORDER BY e.label`

// pgCostLabelMissingComps is pgCostLabelMissingTexts for the components,
// against each one's master text.
const pgCostLabelMissingComps = `SELECT c.component, coalesce(m.label, c.label), array_agg(u.loc ORDER BY u.loc)
	FROM hr_cost_components c
	CROSS JOIN cost_label_settings st
	CROSS JOIN unnest($1::text[]) AS u(loc)
	LEFT JOIN hr_cost_component_labels m ON m.component = c.component AND m.locale = st.master_locale
	LEFT JOIN hr_cost_component_labels l ON l.component = c.component AND l.locale = u.loc
	WHERE u.loc <> st.master_locale
		AND (l.component IS NULL OR (l.origin = 'machine' AND l.source_text IS DISTINCT FROM coalesce(m.label, c.label)))
	GROUP BY c.component, m.label, c.label ORDER BY c.component`

// MissingCostLabels is CostLabelStore on Postgres: the texts, then the
// components.
func (s *Postgres) MissingCostLabels(ctx context.Context) ([]CostLabelWork, error) {
	out := []CostLabelWork{}
	for _, q := range []struct {
		sql  string
		comp bool
	}{{pgCostLabelMissingTexts, false}, {pgCostLabelMissingComps, true}} {
		err := s.asOperatorQuery(ctx, q.sql, []any{i18n.Supported}, func(rows pgx.Rows) error {
			var k, source string
			var locs []string
			if err := rows.Scan(&k, &source, &locs); err != nil {
				return err
			}
			out = append(out, CostLabelWork{Key: costLabelKeyOf(k, q.comp), Source: source, Locales: locs})
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return out, nil
}

// costLabelKeyOf is k as a component's key when comp, else a text's.
func costLabelKeyOf(k string, comp bool) CostLabelKey {
	if comp {
		return CostLabelKey{Component: k}
	}
	return CostLabelKey{Text: k}
}

// pgCostLabelUnreviewedTexts is each entry text's machine rows of that text
// not yet reviewed, its newest entry's row per locale.
const pgCostLabelUnreviewedTexts = `SELECT DISTINCT ON (e.label, l.locale) e.label, e.label, l.locale, l.label
	FROM cost_entry_labels l JOIN cost_entries e ON e.id = l.entry_id
	WHERE l.origin = 'machine' AND l.reviewed_at IS NULL AND l.source_text = e.label
	ORDER BY e.label, l.locale, e.created_at DESC, e.id DESC`

// pgCostLabelUnreviewedComps is pgCostLabelUnreviewedTexts for the
// components, against each one's master text.
const pgCostLabelUnreviewedComps = `SELECT c.component, coalesce(m.label, c.label), l.locale, l.label
	FROM hr_cost_component_labels l JOIN hr_cost_components c ON c.component = l.component
	LEFT JOIN cost_label_settings st ON true
	LEFT JOIN hr_cost_component_labels m ON m.component = c.component AND m.locale = st.master_locale
	WHERE l.origin = 'machine' AND l.reviewed_at IS NULL AND l.source_text = coalesce(m.label, c.label)
	ORDER BY c.component, l.locale`

// UnreviewedCostLabels is CostLabelStore on Postgres: the texts, then the
// components, one CostLabelWork per key (the rows come ordered by key).
func (s *Postgres) UnreviewedCostLabels(ctx context.Context) ([]CostLabelWork, error) {
	out := []CostLabelWork{}
	for _, q := range []struct {
		sql  string
		comp bool
	}{{pgCostLabelUnreviewedTexts, false}, {pgCostLabelUnreviewedComps, true}} {
		err := s.asOperatorQuery(ctx, q.sql, nil, func(rows pgx.Rows) error {
			var k, source, loc, text string
			if err := rows.Scan(&k, &source, &loc, &text); err != nil {
				return err
			}
			key := costLabelKeyOf(k, q.comp)
			if n := len(out); n == 0 || out[n-1].Key != key {
				out = append(out, CostLabelWork{Key: key, Source: source, Drafts: map[string]string{}})
			}
			out[len(out)-1].Drafts[loc] = text
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return out, nil
}

// costLabelsInSQL is each entry text's label in $1, else the master's, where
// it differs from the text; the first entry of a text (period, created_at)
// wins, as on Memory.
const costLabelsInSQL = `SELECT DISTINCT ON (e.label) e.label, coalesce(l.label, m.label, e.label)
	FROM cost_entries e
	LEFT JOIN cost_entry_labels l ON l.entry_id = e.id AND l.locale = $1
	LEFT JOIN cost_label_settings st ON true
	LEFT JOIN cost_entry_labels m ON m.entry_id = e.id AND m.locale = st.master_locale
	ORDER BY e.label, e.period, e.created_at, e.id`

// CostLabelsIn is CostLabelStore on Postgres.
func (s *Postgres) CostLabelsIn(ctx context.Context, locale string) (map[string]string, error) {
	out := map[string]string{}
	err := s.asOperatorQuery(ctx, costLabelsInSQL, []any{locale}, func(rows pgx.Rows) error {
		var text, label string
		if err := rows.Scan(&text, &label); err != nil {
			return err
		}
		if label != text {
			out[text] = label
		}
		return nil
	})
	return out, err
}

// HRComponentLabelsIn is CostLabelStore on Postgres.
func (s *Postgres) HRComponentLabelsIn(ctx context.Context, locale string) (map[string]string, error) {
	out := map[string]string{}
	err := s.asOperatorQuery(ctx, `SELECT c.component, coalesce(l.label, m.label, en.label, c.label)
		FROM hr_cost_components c
		LEFT JOIN hr_cost_component_labels l ON l.component = c.component AND l.locale = $1
		LEFT JOIN cost_label_settings st ON true
		LEFT JOIN hr_cost_component_labels m ON m.component = c.component AND m.locale = st.master_locale
		LEFT JOIN hr_cost_component_labels en ON en.component = c.component AND en.locale = 'en'`, []any{locale},
		func(rows pgx.Rows) error {
			var c, label string
			err := rows.Scan(&c, &label)
			out[c] = label
			return err
		})
	return out, err
}

var _ CostLabelStore = (*Postgres)(nil)
