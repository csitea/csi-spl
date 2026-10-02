package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0094. Every statement runs in the tenant scope, and
// the write is ONE conditional statement: the gen in its WHERE (or the
// primary key, for the first row) is the compare-and-set.

func (s *Postgres) GetFleetLease(ctx context.Context, tenant, fleet, role string, now time.Time) (FleetLease, error) {
	var l FleetLease
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		l, err = readFleetLease(ctx, tx, tenant, fleet, role, now)
		return err
	})
	return l, err
}

func (s *Postgres) FleetLeases(ctx context.Context, tenant string, now time.Time) ([]FleetLease, error) {
	var out []FleetLease
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		out = nil
		rows, err := tx.Query(ctx, `SELECT fleet, role, holder, box, gen, renewed_at FROM fleet_leases
			WHERE tenant_id = $1`, tenant)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var l FleetLease
			if err := rows.Scan(&l.Fleet, &l.Role, &l.Holder, &l.Box, &l.Gen, &l.RenewedAt); err != nil {
				return err
			}
			l.RenewedAt = l.RenewedAt.UTC()
			l.Age = now.Sub(l.RenewedAt)
			out = append(out, l)
		}
		return rows.Err()
	})
	return out, err
}

func readFleetLease(ctx context.Context, tx pgx.Tx, tenant, fleet, role string, now time.Time) (FleetLease, error) {
	l := FleetLease{Fleet: fleet, Role: role}
	err := tx.QueryRow(ctx, `SELECT holder, box, gen, renewed_at FROM fleet_leases
		WHERE tenant_id = $1 AND fleet = $2 AND role = $3`, tenant, fleet, role).Scan(&l.Holder, &l.Box, &l.Gen, &l.RenewedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return l, nil
	}
	if err != nil {
		return l, err
	}
	l.RenewedAt = l.RenewedAt.UTC()
	l.Age = now.Sub(l.RenewedAt)
	return l, nil
}

func (s *Postgres) CASFleetLease(ctx context.Context, tenant, fleet, role, holder, box string, ifGen int64, now time.Time) (FleetLease, error) {
	var l FleetLease
	won := false
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var q string
		args := []any{tenant, fleet, role, holder, box, now}
		if ifGen == 0 {
			q = `INSERT INTO fleet_leases (tenant_id, fleet, role, holder, box, gen, renewed_at)
				VALUES ($1, $2, $3, $4, $5, 1, $6) ON CONFLICT DO NOTHING`
		} else {
			q = `UPDATE fleet_leases SET holder = $4, box = $5, gen = gen + 1, renewed_at = $6
				WHERE tenant_id = $1 AND fleet = $2 AND role = $3 AND gen = $7`
			args = append(args, ifGen)
		}
		tag, err := tx.Exec(ctx, q, args...)
		if err != nil {
			return err
		}
		won = tag.RowsAffected() == 1
		l, err = readFleetLease(ctx, tx, tenant, fleet, role, now)
		return err
	})
	if err != nil {
		return l, err
	}
	if !won {
		return l, ErrConflict
	}
	return l, nil
}
