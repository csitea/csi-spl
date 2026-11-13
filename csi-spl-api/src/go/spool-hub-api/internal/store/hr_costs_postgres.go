package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Postgres side of rdb 0280. Every statement runs in the operator scope;
// hr_person_names is read or written only with app.costs_names = 'on' set in
// the same transaction (its policy asks both), which names = true does.

// pgCostsNames opens hr_person_names for the rest of the transaction.
const pgCostsNames = `SELECT set_config('app.costs_names', 'on', true)`

// ListHRComponents is HRCostStore on Postgres.
func (s *Postgres) ListHRComponents(ctx context.Context) ([]HRComponent, error) {
	out := []HRComponent{}
	err := s.asOperatorQuery(ctx, `SELECT component, grp, label, default_account, sort_order FROM hr_cost_components
		ORDER BY sort_order, component`, nil,
		func(rows pgx.Rows) error {
			var c HRComponent
			err := rows.Scan(&c.Component, &c.Group, &c.Label, &c.DefaultAccount, &c.SortOrder)
			out = append(out, c)
			return err
		})
	return out, err
}

const hrPersonCols = `p.id::text, p.code, p.department, p.employment_type, coalesce(p.birth_year, 0),
	coalesce(to_char(p.left_on, 'YYYY-MM-DD'), ''), p.created_by, p.created_at`

// ListHRPeople is HRCostStore on Postgres. Without names the name table is
// never touched (and its policy would hide every row anyway).
func (s *Postgres) ListHRPeople(ctx context.Context, names bool) ([]HRPerson, error) {
	out := []HRPerson{}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		q := `SELECT ` + hrPersonCols + `, '' FROM hr_people p ORDER BY p.code`
		if names {
			if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
				return err
			}
			q = `SELECT ` + hrPersonCols + `, coalesce(n.name, '') FROM hr_people p
				LEFT JOIN hr_person_names n ON n.person_id = p.id ORDER BY p.code`
		}
		return eachRow(ctx, tx, q, nil, func(rows pgx.Rows) error {
			var p HRPerson
			err := rows.Scan(&p.ID, &p.Code, &p.Department, &p.EmploymentType, &p.BirthYear, &p.LeftOn, &p.CreatedBy, &p.CreatedAt, &p.Name)
			p.CreatedAt = p.CreatedAt.UTC()
			out = append(out, p)
			return err
		})
	})
	return out, err
}

// CreateHRPerson is HRCostStore on Postgres.
func (s *Postgres) CreateHRPerson(ctx context.Context, p HRPerson) (HRPerson, error) {
	if why := CheckHRPerson(p); why != "" {
		return HRPerson{}, fmt.Errorf("hr person: %s", why)
	}
	p.ID = uuid.New()
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `INSERT INTO hr_people (id, code, department, employment_type, birth_year, left_on, created_by)
			VALUES ($1::uuid, $2, $3, $4, nullif($5, 0), to_date(nullif($6, ''), 'YYYY-MM-DD'), $7) RETURNING created_at`,
			p.ID, p.Code, p.Department, p.EmploymentType, p.BirthYear, p.LeftOn, p.CreatedBy).Scan(&p.CreatedAt); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO hr_person_names (person_id, name) VALUES ($1::uuid, $2)`, p.ID, p.Name)
		return err
	})
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "23505" {
		return HRPerson{}, ErrConflict
	}
	if err != nil {
		return HRPerson{}, err
	}
	p.CreatedAt = p.CreatedAt.UTC()
	return p, nil
}

// costPeriodRowIn reads month's cost_periods row in tx; nil = none.
func costPeriodRowIn(ctx context.Context, tx pgx.Tx, month string) (*costPeriodRow, error) {
	var r costPeriodRow
	err := tx.QueryRow(ctx, `SELECT closed_at, closed_by, reopened_at, reopened_by, reopen_reason FROM cost_periods
		WHERE period = to_date($1, 'YYYY-MM')`, month).Scan(&r.closedAt, &r.closedBy, &r.reopenedAt, &r.reopenedBy, &r.re)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	for _, t := range []*time.Time{r.closedAt, r.reopenedAt} {
		if t != nil {
			*t = t.UTC()
		}
	}
	return &r, nil
}

// CostPeriodState is HRCostStore on Postgres.
func (s *Postgres) CostPeriodState(ctx context.Context, month string, now time.Time) (CostPeriod, error) {
	if !IsCostMonth(month) {
		return CostPeriod{}, fmt.Errorf("cost period: month must be YYYY-MM")
	}
	var out CostPeriod
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		row, err := costPeriodRowIn(ctx, tx, month)
		out = costPeriodAt(month, row, now)
		return err
	})
	return out, err
}

// SetCostPeriod is HRCostStore on Postgres.
func (s *Postgres) SetCostPeriod(ctx context.Context, month string, closed bool, by, reason string, now time.Time) (CostPeriod, error) {
	if why := checkCostPeriodSet(month, closed, by, reason); why != "" {
		return CostPeriod{}, fmt.Errorf("cost period: %s", why)
	}
	var out CostPeriod
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		if closed {
			_, err = tx.Exec(ctx, `INSERT INTO cost_periods (period, closed_at, closed_by) VALUES (to_date($1, 'YYYY-MM'), $2, $3)
				ON CONFLICT (period) DO UPDATE SET closed_at = EXCLUDED.closed_at, closed_by = EXCLUDED.closed_by`, month, now.UTC(), by)
		} else {
			_, err = tx.Exec(ctx, `INSERT INTO cost_periods (period, closed_at, reopened_at, reopened_by, reopen_reason)
				VALUES (to_date($1, 'YYYY-MM'), NULL, $2, $3, $4)
				ON CONFLICT (period) DO UPDATE SET closed_at = NULL, reopened_at = EXCLUDED.reopened_at,
					reopened_by = EXCLUDED.reopened_by, reopen_reason = EXCLUDED.reopen_reason`, month, now.UTC(), by, reason)
		}
		if err != nil {
			return err
		}
		row, err := costPeriodRowIn(ctx, tx, month)
		out = costPeriodAt(month, row, now)
		return err
	})
	return out, err
}

var _ HRCostStore = (*Postgres)(nil)
