package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0117 and 0317. Every statement runs in the tenant scope except
// the retention prune, which is the operator's (every tenant at once).

const boxStatCols = `box, writer_box, at, load1, load5, load15, cpus, mem_total_kb, mem_avail_kb, swap_used_kb, agents_live, disks,
	cpu_pct, swap_total_kb, mem_buffers_kb, mem_cached_kb, tasks_total, tasks_running, uptime_s`

func (s *Postgres) AppendBoxStat(ctx context.Context, tenant string, b BoxStat) error {
	return s.AppendBoxStatSnapshot(ctx, tenant, b, nil)
}

// AppendBoxStatSnapshot writes the box_stats row and, with a snapshot, the
// box's box_snapshots row in one tenant transaction, so both carry b.At.
func (s *Postgres) AppendBoxStatSnapshot(ctx context.Context, tenant string, b BoxStat, snap *BoxSnapshot) error {
	disks := b.Disks
	if disks == nil {
		disks = []BoxDisk{}
	}
	raw, err := json.Marshal(disks)
	if err != nil {
		return err
	}
	var snapRaw []byte
	if snap != nil {
		if snapRaw, err = json.Marshal(storedBoxSnapshot(*snap, b.At)); err != nil {
			return err
		}
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO box_stats (tenant_id, `+boxStatCols+`)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::jsonb, $14, $15, $16, $17, $18, $19, $20)`,
			tenant, b.Box, b.WriterBox, b.At.UTC(), b.Load1, b.Load5, b.Load15, b.CPUs,
			b.MemTotalKB, b.MemAvailKB, b.SwapUsedKB, b.AgentsLive, string(raw),
			b.CPUPct, b.SwapTotalKB, b.MemBuffersKB, b.MemCachedKB, b.TasksTotal, b.TasksRunning, b.UptimeS)
		if err != nil || snapRaw == nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO box_snapshots (tenant_id, box, writer_box, at, snapshot)
			VALUES ($1, $2, $3, $4, $5::jsonb)
			ON CONFLICT (tenant_id, box) DO UPDATE SET writer_box = EXCLUDED.writer_box, at = EXCLUDED.at, snapshot = EXCLUDED.snapshot`,
			tenant, b.Box, b.WriterBox, b.At.UTC(), string(snapRaw))
		return err
	})
}

// ListBoxSnapshots reads the tenant's snapshot rows; at is the row's.
func (s *Postgres) ListBoxSnapshots(ctx context.Context, tenant, box string) (map[string]BoxSnapshot, error) {
	out := map[string]BoxSnapshot{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT box, at, snapshot FROM box_snapshots
			WHERE tenant_id = $1 AND ($2 = '' OR box = $2)`, tenant, box)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var name string
			var at time.Time
			var raw []byte
			if err := rows.Scan(&name, &at, &raw); err != nil {
				return err
			}
			var snap BoxSnapshot
			if err := json.Unmarshal(raw, &snap); err != nil {
				return err
			}
			out[name] = storedBoxSnapshot(snap, at)
		}
		return rows.Err()
	})
	return out, err
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
			var cpuPct *float32
			var disks []byte
			if err := rows.Scan(&b.Box, &b.WriterBox, &b.At, &l1, &l5, &l15, &b.CPUs,
				&b.MemTotalKB, &b.MemAvailKB, &b.SwapUsedKB, &b.AgentsLive, &disks,
				&cpuPct, &b.SwapTotalKB, &b.MemBuffersKB, &b.MemCachedKB, &b.TasksTotal, &b.TasksRunning, &b.UptimeS); err != nil {
				return err
			}
			if cpuPct != nil {
				c := round2(*cpuPct)
				b.CPUPct = &c
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
		for _, q := range []string{`DELETE FROM box_stats WHERE at < $1`, `DELETE FROM box_snapshots WHERE at < $1`} {
			tag, err := tx.Exec(ctx, q, before)
			if err != nil {
				return err
			}
			n += int(tag.RowsAffected())
		}
		return nil
	})
	return n, err
}

// round2 is a real column read back as the 2-decimal value /proc/loadavg
// wrote (float32 -> float64 widening shows 0.47 as 0.4699999988).
func round2(f float32) float64 {
	return float64(int64(float64(f)*100+0.5)) / 100
}
