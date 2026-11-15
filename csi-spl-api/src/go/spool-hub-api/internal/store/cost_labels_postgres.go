package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0285. Every statement runs in the operator scope, like
// cost_entries (rdb 0245): the rows are the estate's, no tenant.

// pgCostLabelMasterInsert is a new entry's master-locale label, in the
// entry's own transaction; no row while no master locale is set.
const pgCostLabelMasterInsert = `INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by)
	SELECT $1::uuid, master_locale, $2, $3 FROM cost_label_settings`

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

// SetCostEntryLabels is CostLabelStore on Postgres: one transaction reads the
// entry's own text and the master locale, checks labels against them, then
// replaces every other locale's row.
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
		if _, err := tx.Exec(ctx, `DELETE FROM cost_entry_labels WHERE entry_id = $1::uuid AND locale <> $2`, id, master); err != nil {
			return err
		}
		for loc, text := range labels {
			if loc == master {
				continue
			}
			if _, err := tx.Exec(ctx, `INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by)
				VALUES ($1::uuid, $2, $3, $4)`, id, loc, text, by); err != nil {
				return err
			}
		}
		return nil
	})
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
