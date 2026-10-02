package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0097. Every statement runs in the tenant scope. An
// update reads the row FOR UPDATE, applies the op in Go (applyAskOp, shared
// with Memory) and writes it back in the same transaction, so two holders
// closing one ask cannot both win.

const askCols = `ask_id, role, kind, from_agent, topic, summary, state, deadline_at, acked_by, closed_by, reason,
	raised_n, raised_at, escalated_at, writer_box, created_at, updated_at`

func scanAsk(row pgx.Row, fleet string, now time.Time) (FleetAsk, error) {
	a := FleetAsk{Fleet: fleet}
	var deadline, raised, escalated *time.Time
	if err := row.Scan(&a.AskID, &a.Role, &a.Kind, &a.From, &a.Topic, &a.Summary, &a.State, &deadline, &a.AckedBy, &a.ClosedBy,
		&a.Reason, &a.RaisedN, &raised, &escalated, &a.WriterBox, &a.CreatedAt, &a.UpdatedAt); err != nil {
		return a, err
	}
	for _, p := range []struct {
		src *time.Time
		dst *time.Time
	}{{deadline, &a.DeadlineAt}, {raised, &a.RaisedAt}, {escalated, &a.EscalatedAt}} {
		if p.src != nil {
			*p.dst = p.src.UTC()
		}
	}
	a.CreatedAt, a.UpdatedAt = a.CreatedAt.UTC(), a.UpdatedAt.UTC()
	askTimes(&a, now)
	return a, nil
}

func (s *Postgres) PutFleetAsk(ctx context.Context, tenant string, a FleetAsk, box string, now time.Time) (FleetAsk, bool, error) {
	var out FleetAsk
	created := false
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM fleet_asks WHERE tenant_id = $1 AND fleet = $2
			AND state IN ('done', 'declined', 'dead') AND updated_at < $3`, tenant, a.Fleet, now.Add(-AskClosedTTL)); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO fleet_asks
			(tenant_id, fleet, ask_id, role, kind, from_agent, topic, summary, state, deadline_at, writer_box, created_at, updated_at)
			VALUES ($1, $2, $3, $11, $4, $5, $6, $7, 'open', $8, $9, $10, $10)
			ON CONFLICT (tenant_id, fleet, ask_id) DO NOTHING`,
			tenant, a.Fleet, a.AskID, a.Kind, a.From, a.Topic, a.Summary, nullTime(a.DeadlineAt), box, now, a.Role)
		if err != nil {
			return err
		}
		created = tag.RowsAffected() == 1
		out, err = scanAsk(tx.QueryRow(ctx, `SELECT `+askCols+` FROM fleet_asks
			WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3`, tenant, a.Fleet, a.AskID), a.Fleet, now)
		return err
	})
	return out, created, err
}

func (s *Postgres) UpdateFleetAsk(ctx context.Context, tenant string, u AskUpdate, box string, now time.Time) (FleetAsk, error) {
	fleet, askID := u.Fleet, u.AskID
	var out FleetAsk
	closed := false
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		a, err := scanAsk(tx.QueryRow(ctx, `SELECT `+askCols+` FROM fleet_asks
			WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3 FOR UPDATE`, tenant, fleet, askID), fleet, now)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if !a.Open() {
			out, closed = a, true
			return nil
		}
		applyAskOp(&a, u, box, now)
		if _, err = tx.Exec(ctx, `UPDATE fleet_asks SET state = $4, acked_by = $5, closed_by = $6, reason = $7,
			raised_n = $8, raised_at = $9, escalated_at = $10, writer_box = $11, updated_at = $12
			WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3`,
			tenant, fleet, askID, a.State, a.AckedBy, a.ClosedBy, a.Reason, a.RaisedN,
			nullTime(a.RaisedAt), nullTime(a.EscalatedAt), a.WriterBox, a.UpdatedAt); err != nil {
			return err
		}
		askTimes(&a, now)
		out = a
		return nil
	})
	if err != nil {
		return FleetAsk{}, err
	}
	if closed {
		return out, ErrConflict
	}
	return out, nil
}

func (s *Postgres) ListFleetAsks(ctx context.Context, tenant, fleet, role string, all bool, now time.Time) ([]FleetAsk, error) {
	out := []FleetAsk{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+askCols+` FROM fleet_asks
			WHERE tenant_id = $1 AND fleet = $2 AND ($4 = '' OR role = $4)
			AND ($3 OR state IN ('open', 'acked'))`, tenant, fleet, all, role)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			a, err := scanAsk(rows, fleet, now)
			if err != nil {
				return err
			}
			out = append(out, a)
		}
		return rows.Err()
	})
	sortAsks(out)
	return out, err
}
