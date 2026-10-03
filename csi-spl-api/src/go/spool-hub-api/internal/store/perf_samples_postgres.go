package store

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0106. Every statement runs in the tenant scope except
// the retention prune, which is the operator's (every tenant at once).

const perfSampleCols = `at, session_id, metric, value_ms, ratio, device, view, cache, outcome, build, net, clock_err_ms, hidden_s`

// perfNull is "" as NULL for the optional enum columns.
func perfNull(v string) any {
	if v == "" {
		return nil
	}
	return v
}

// InsertPerfSamples is ONE multi-row INSERT per batch (no COPY: COPY FROM is
// refused on a table under row-level security).
func (s *Postgres) InsertPerfSamples(ctx context.Context, tenant string, batch []PerfSample) error {
	if len(batch) == 0 {
		return nil
	}
	if len(batch) > PerfBatchMax {
		return fmt.Errorf("perf batch of %d rows, max %d", len(batch), PerfBatchMax)
	}
	const cols = 14
	var sb strings.Builder
	args := make([]any, 0, len(batch)*cols)
	for i, p := range batch {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString("(")
		for c := 1; c <= cols; c++ {
			if c > 1 {
				sb.WriteString(", ")
			}
			fmt.Fprintf(&sb, "$%d", i*cols+c)
		}
		sb.WriteString(")")
		args = append(args, tenant, p.At.UTC(), p.SessionID, p.Metric, p.ValueMs, p.Ratio, p.Device,
			perfNull(p.View), perfNull(p.Cache), p.Outcome, p.Build, perfNull(p.Net), p.ClockErrMs, perfNull(p.HiddenS))
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO wui_perf_samples (tenant_id, `+perfSampleCols+`) VALUES `+sb.String(), args...)
		return err
	})
}

func (s *Postgres) ListPerfSamples(ctx context.Context, tenant string, since time.Time, limit int) ([]PerfSample, error) {
	out := []PerfSample{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT at, session_id::text, metric, value_ms, ratio::float8, device,
				coalesce(view, ''), coalesce(cache, ''), outcome, build, coalesce(net, ''), clock_err_ms, coalesce(hidden_s, '')
			FROM wui_perf_samples WHERE tenant_id = $1 AND at >= $2 ORDER BY at, id LIMIT $3`,
			tenant, since, ClampPerfLimit(limit))
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var p PerfSample
			if err := rows.Scan(&p.At, &p.SessionID, &p.Metric, &p.ValueMs, &p.Ratio, &p.Device,
				&p.View, &p.Cache, &p.Outcome, &p.Build, &p.Net, &p.ClockErrMs, &p.HiddenS); err != nil {
				return err
			}
			p.At = p.At.UTC()
			out = append(out, p)
		}
		return rows.Err()
	})
	return out, err
}

// PerfSummary computes on read, in one statement (spec 066 section 6: only
// the reader pays for it): percentile_cont over the ok samples, the rest
// counted as failed.
func (s *Postgres) PerfSummary(ctx context.Context, tenant string, since time.Time, build string) ([]PerfSummaryRow, error) {
	out := []PerfSummaryRow{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT metric, device, coalesce(view, ''),
				count(*) FILTER (WHERE outcome = 'ok')::int,
				percentile_cont(0.5) WITHIN GROUP (ORDER BY value_ms) FILTER (WHERE outcome = 'ok'),
				percentile_cont(0.75) WITHIN GROUP (ORDER BY value_ms) FILTER (WHERE outcome = 'ok'),
				percentile_cont(0.95) WITHIN GROUP (ORDER BY value_ms) FILTER (WHERE outcome = 'ok'),
				count(*) FILTER (WHERE outcome <> 'ok')::int
			FROM wui_perf_samples
			WHERE tenant_id = $1 AND at >= $2 AND ($3 = '' OR build = $3)
			GROUP BY metric, device, coalesce(view, '')
			ORDER BY metric COLLATE "C", device COLLATE "C", coalesce(view, '') COLLATE "C"`,
			tenant, since, build)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var r PerfSummaryRow
			if err := rows.Scan(&r.Metric, &r.Device, &r.View, &r.N, &r.P50, &r.P75, &r.P95, &r.Failed); err != nil {
				return err
			}
			out = append(out, r)
		}
		return rows.Err()
	})
	return out, err
}

func (s *Postgres) PrunePerfSamples(ctx context.Context, before time.Time) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM wui_perf_samples WHERE at < $1`, before)
		if err != nil {
			return err
		}
		n = int(tag.RowsAffected())
		return nil
	})
	return n, err
}
