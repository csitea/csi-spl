package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0117. Every statement runs in the tenant scope except
// the retention prune, which is the operator's (every tenant at once).

const boxStatCols = `box, writer_box, at, load1, load5, load15, cpus, mem_total_kb, mem_avail_kb, swap_used_kb, agents_live, disks`

func (s *Postgres) AppendBoxStat(ctx context.Context, tenant string, b BoxStat) error {
	disks := b.Disks
	if disks == nil {
		disks = []BoxDisk{}
	}
	raw, err := json.Marshal(disks)
	if err != nil {
		return err
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO box_stats (tenant_id, `+boxStatCols+`)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::jsonb)`,
			tenant, b.Box, b.WriterBox, b.At.UTC(), b.Load1, b.Load5, b.Load15, b.CPUs,
			b.MemTotalKB, b.MemAvailKB, b.SwapUsedKB, b.AgentsLive, string(raw))
		return err
	})
}

// ListBoxStats takes the newest BoxStatsMax rows of the window, then returns
// them oldest first.
func (s *Postgres) ListBoxStats(ctx context.Context, tenant, box string, since time.Time) ([]BoxStat, error) {
	out := []BoxStat{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+boxStatCols+` FROM box_stats
			WHERE tenant_id = $1 AND ($2 = '' OR box = $2) AND at >= $3
			ORDER BY at DESC, id DESC LIMIT $4`, tenant, box, since, BoxStatsMax)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var b BoxStat
			var l1, l5, l15 float32
			var disks []byte
			if err := rows.Scan(&b.Box, &b.WriterBox, &b.At, &l1, &l5, &l15, &b.CPUs,
				&b.MemTotalKB, &b.MemAvailKB, &b.SwapUsedKB, &b.AgentsLive, &disks); err != nil {
				return err
			}
			if err := json.Unmarshal(disks, &b.Disks); err != nil {
				return err
			}
			b.Load1, b.Load5, b.Load15 = round2(l1), round2(l5), round2(l15)
			b.At = b.At.UTC()
			out = append(out, b)
		}
		return rows.Err()
	})
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, err
}

func (s *Postgres) PruneBoxStats(ctx context.Context, before time.Time) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM box_stats WHERE at < $1`, before)
		if err != nil {
			return err
		}
		n = int(tag.RowsAffected())
		return nil
	})
	return n, err
}

// round2 is a real column read back as the 2-decimal value /proc/loadavg
// wrote (float32 -> float64 widening shows 0.47 as 0.4699999988).
func round2(f float32) float64 {
	return float64(int64(float64(f)*100+0.5)) / 100
}
