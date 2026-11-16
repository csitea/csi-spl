package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Hours of use per person, per workspace, per day (rdb 0289, SPL-5709, spec
// 143 usage-hours.md). The WUI sends one heartbeat a minute while a
// workspace tab is visible and the person active; the hub stamps the minute
// from its own clock and adds it here at most once per person and minute:
// once per workspace (workspace_use_minutes) and once for the whole hub
// (hub_use_minutes), however many tabs send it.

// UseDayLayout is the day format of every range bound here (UTC days).
const UseDayLayout = "2006-01-02"

// UseCounted says which counters a heartbeat moved: false = that minute was
// already counted (a second tab, a retry).
type UseCounted struct {
	Workspace bool
	Hub       bool
}

// UseDay is one UTC day of the hub total: the minutes and the people.
type UseDay struct {
	Day     string
	Minutes int64
	People  int
}

// UseWorkspace is one workspace's share of the hub total in a range.
type UseWorkspace struct {
	TenantID string
	Minutes  int64
	People   int
}

// UseTotal is the hub total in a range: the minutes counted once per
// person and minute, the people who used it, per day and per workspace (a
// workspace's minutes may overlap another's in the same minute, so the
// workspaces need not sum to Minutes).
type UseTotal struct {
	Minutes    int64
	People     int
	Days       []UseDay
	Workspaces []UseWorkspace
}

// UseMinutes is implemented by Memory and Postgres. Days are YYYY-MM-DD,
// both bounds inclusive; the caller validates them.
type UseMinutes interface {
	// RecordUseMinute counts the minute of at (UTC, truncated) for hum in
	// tenant and in the hub, each once.
	RecordUseMinute(ctx context.Context, tenant, hum string, at time.Time) (UseCounted, error)
	// WorkspaceUseMinutes is minutes per human in tenant over the range.
	WorkspaceUseMinutes(ctx context.Context, tenant, from, to string) (map[string]int64, error)
	// HubUseMinutesOf is minutes per human across the hub, for humans only.
	HubUseMinutesOf(ctx context.Context, humans []string, from, to string) (map[string]int64, error)
	// HubUseTotal is the hub total over the range.
	HubUseTotal(ctx context.Context, from, to string) (UseTotal, error)
	// SweepUseMinutes deletes the rows of days before before (retention).
	SweepUseMinutes(ctx context.Context, before string) (int, error)
}

// useMinute is the counted minute and its UTC day.
func useMinute(at time.Time) (time.Time, string) {
	m := at.UTC().Truncate(time.Minute)
	return m, m.Format(UseDayLayout)
}

// RecordUseMinute: an upsert that adds 1 only when the minute is past the
// row's last_minute; RETURNING reads no row when it did not.
func (s *Postgres) RecordUseMinute(ctx context.Context, tenant, hum string, at time.Time) (UseCounted, error) {
	var c UseCounted
	m, day := useMinute(at)
	var n int
	err := s.queryRowTenant(ctx, tenant, `INSERT INTO workspace_use_minutes AS u (tenant_id, human_id, day, minutes, last_minute)
		VALUES ($1, $2, $3::date, 1, $4)
		ON CONFLICT (tenant_id, human_id, day) DO UPDATE SET minutes = u.minutes + 1, last_minute = EXCLUDED.last_minute
		WHERE u.last_minute < EXCLUDED.last_minute RETURNING u.minutes`, []any{tenant, hum, day, m}, &n)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return c, err
	}
	c.Workspace = err == nil
	err = s.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `INSERT INTO hub_use_minutes AS u (human_id, day, minutes, last_minute)
			VALUES ($1, $2::date, 1, $3)
			ON CONFLICT (human_id, day) DO UPDATE SET minutes = u.minutes + 1, last_minute = EXCLUDED.last_minute
			WHERE u.last_minute < EXCLUDED.last_minute RETURNING u.minutes`, hum, day, m).Scan(&n)
	})
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return c, err
	}
	c.Hub = err == nil
	return c, nil
}

// scanMinutesBy reads (key, sum) rows into out.
func scanMinutesBy(out map[string]int64) func(pgx.Rows) error {
	return func(rows pgx.Rows) error {
		var k string
		var n int64
		if err := rows.Scan(&k, &n); err != nil {
			return err
		}
		out[k] = n
		return nil
	}
}

// WorkspaceUseMinutes reads tenant's rows only (tenant scope).
func (s *Postgres) WorkspaceUseMinutes(ctx context.Context, tenant, from, to string) (map[string]int64, error) {
	out := map[string]int64{}
	err := s.queryTenant(ctx, tenant, `SELECT human_id, sum(minutes)::bigint FROM workspace_use_minutes
		WHERE tenant_id = $1 AND day BETWEEN $2::date AND $3::date GROUP BY human_id`, []any{tenant, from, to}, scanMinutesBy(out))
	return out, err
}

// HubUseMinutesOf reads hub_use_minutes (operator scope) for the named
// humans only: the caller passes the members of one workspace.
func (s *Postgres) HubUseMinutesOf(ctx context.Context, humans []string, from, to string) (map[string]int64, error) {
	out := map[string]int64{}
	if len(humans) == 0 {
		return out, nil
	}
	err := s.asOperatorQuery(ctx, `SELECT human_id, sum(minutes)::bigint FROM hub_use_minutes
		WHERE human_id = ANY($1) AND day BETWEEN $2::date AND $3::date GROUP BY human_id`, []any{humans, from, to}, scanMinutesBy(out))
	return out, err
}

// HubUseTotal reads both tables in one operator snapshot.
func (s *Postgres) HubUseTotal(ctx context.Context, from, to string) (UseTotal, error) {
	t := UseTotal{Days: []UseDay{}, Workspaces: []UseWorkspace{}}
	err := s.asOperatorSnapshot(ctx, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT coalesce(sum(minutes), 0)::bigint, count(DISTINCT human_id)::int FROM hub_use_minutes
			WHERE day BETWEEN $1::date AND $2::date`, from, to).Scan(&t.Minutes, &t.People); err != nil {
			return err
		}
		if err := eachRow(ctx, tx, `SELECT to_char(day, 'YYYY-MM-DD'), sum(minutes)::bigint, count(*)::int FROM hub_use_minutes
			WHERE day BETWEEN $1::date AND $2::date GROUP BY day ORDER BY day`, []any{from, to}, func(rows pgx.Rows) error {
			var d UseDay
			err := rows.Scan(&d.Day, &d.Minutes, &d.People)
			t.Days = append(t.Days, d)
			return err
		}); err != nil {
			return err
		}
		return eachRow(ctx, tx, `SELECT tenant_id, sum(minutes)::bigint, count(DISTINCT human_id)::int FROM workspace_use_minutes
			WHERE day BETWEEN $1::date AND $2::date GROUP BY tenant_id ORDER BY 2 DESC, 1`, []any{from, to}, func(rows pgx.Rows) error {
			var w UseWorkspace
			err := rows.Scan(&w.TenantID, &w.Minutes, &w.People)
			t.Workspaces = append(t.Workspaces, w)
			return err
		})
	})
	return t, err
}

// SweepUseMinutes prunes both tables, every workspace (the sweep tick).
func (s *Postgres) SweepUseMinutes(ctx context.Context, before string) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		for _, q := range []string{`DELETE FROM workspace_use_minutes WHERE day < $1::date`, `DELETE FROM hub_use_minutes WHERE day < $1::date`} {
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
