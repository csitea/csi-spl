package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0147. Every statement runs in the tenant scope except
// the retention prune, which is the operator's (every tenant at once).

func (s *Postgres) AppendBoxBeat(ctx context.Context, tenant string, b BoxBeat) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO box_beats (tenant_id, box, beat_at, pid) VALUES ($1, $2, $3, $4)`,
			tenant, b.Box, b.BeatAt.UTC(), b.PID)
		return err
	})
}

func (s *Postgres) ListBoxBeats(ctx context.Context, tenant, box string, since time.Time) ([]BoxBeat, error) {
	out := []BoxBeat{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT box, beat_at, pid FROM box_beats
			WHERE tenant_id = $1 AND ($2 = '' OR box = $2) AND beat_at >= $3
			ORDER BY beat_at DESC, id DESC LIMIT $4`, tenant, box, since, BoxBeatsMax)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var b BoxBeat
			if err := rows.Scan(&b.Box, &b.BeatAt, &b.PID); err != nil {
				return err
			}
			b.BeatAt = b.BeatAt.UTC()
			out = append(out, b)
		}
		return rows.Err()
	})
	return out, err
}

func (s *Postgres) PruneBoxBeats(ctx context.Context, before time.Time) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM box_beats WHERE beat_at < $1`, before)
		if err != nil {
			return err
		}
		n = int(tag.RowsAffected())
		return nil
	})
	return n, err
}
