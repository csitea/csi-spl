package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// A member's manual status in one workspace (spec 096, rdb 0141): "Busy",
// "Unavailable until 14:00", with an optional note. "available" is NO row,
// so clearing deletes it. A row whose until is at or before now reads as
// available everywhere (expiry on read); the hub's sweep deletes it.

// HumanStatus is one live status row.
type HumanStatus struct {
	HumanID     string
	State       string    // "busy" or "unavailable"
	Note        string    // "" = none
	Until       time.Time // zero = no end
	PauseNotify bool      // Q1: pause my notifications while unavailable
	SetAt       time.Time
	SetBy       string
}

// Live reports whether st still shows at now (no until, or until after now).
func (st HumanStatus) Live(now time.Time) bool {
	return st.Until.IsZero() || st.Until.After(now)
}

// HumanStatuses reads and writes human_status. Every call is in the tenant
// it names (FORCE RLS): a workspace never reads another's rows.
type HumanStatuses interface {
	// HumanStatuses is every live status of tenant at now, by HUM-*.
	HumanStatuses(ctx context.Context, tenant string, now time.Time) (map[string]HumanStatus, error)
	// PutHumanStatus sets st (one row per member, replaced). ErrNotFound when
	// st.HumanID is not a member of tenant.
	PutHumanStatus(ctx context.Context, tenant string, st HumanStatus) error
	// ClearHumanStatus deletes the member's row; false when there was none.
	ClearHumanStatus(ctx context.Context, tenant, humanID string) (bool, error)
	// SweepHumanStatus deletes the rows of tenant expired at now and returns
	// their HUM-*.
	SweepHumanStatus(ctx context.Context, tenant string, now time.Time) ([]string, error)
}

var (
	_ HumanStatuses = (*Memory)(nil)
	_ HumanStatuses = (*Postgres)(nil)
)

// ---- Postgres ----

// hasHumanStatus is the probe for rdb 0141: until the table is there, reads
// list none and the roster reads without it (never a 500).
func (s *Postgres) hasHumanStatus(ctx context.Context) bool {
	return s.humStatus.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT to_regclass('human_status') IS NOT NULL`).Scan(&ok)
		return ok, err
	}, s.now())
}

// humanStatusRead is HumanStatuses' statement, shared with ViewRoster's batch.
func humanStatusRead(tenant string, now time.Time, out map[string]HumanStatus) tenantRead {
	return tenantRead{sql: `SELECT human_id, status, coalesce(note, ''), until_at, pause_notify, set_at, set_by
		FROM human_status WHERE tenant_id = $1 AND (until_at IS NULL OR until_at > $2)`,
		args: []any{tenant, now}, each: func(rows pgx.Rows) error {
			var st HumanStatus
			var until *time.Time
			if err := rows.Scan(&st.HumanID, &st.State, &st.Note, &until, &st.PauseNotify, &st.SetAt, &st.SetBy); err != nil {
				return err
			}
			if until != nil {
				st.Until = until.UTC()
			}
			out[st.HumanID] = st
			return nil
		}}
}

func (s *Postgres) HumanStatuses(ctx context.Context, tenant string, now time.Time) (map[string]HumanStatus, error) {
	out := map[string]HumanStatus{}
	if !s.hasHumanStatus(ctx) {
		return out, nil
	}
	r := humanStatusRead(tenant, now, out)
	if err := s.queryTenant(ctx, tenant, r.sql, r.args, r.each); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Postgres) PutHumanStatus(ctx context.Context, tenant string, st HumanStatus) error {
	var note, until any
	if st.Note != "" {
		note = st.Note
	}
	if !st.Until.IsZero() {
		until = st.Until
	}
	_, err := s.execTenant(ctx, tenant, `INSERT INTO human_status
		(tenant_id, human_id, status, note, until_at, pause_notify, set_at, set_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (tenant_id, human_id) DO UPDATE SET status = EXCLUDED.status, note = EXCLUDED.note,
			until_at = EXCLUDED.until_at, pause_notify = EXCLUDED.pause_notify,
			set_at = EXCLUDED.set_at, set_by = EXCLUDED.set_by`,
		tenant, st.HumanID, st.State, note, until, st.PauseNotify, st.SetAt, st.SetBy)
	return mapFK(err) // 23503: not a member of the tenant
}

func (s *Postgres) ClearHumanStatus(ctx context.Context, tenant, humanID string) (bool, error) {
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM human_status WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

func (s *Postgres) SweepHumanStatus(ctx context.Context, tenant string, now time.Time) ([]string, error) {
	var ids []string
	if !s.hasHumanStatus(ctx) {
		return nil, nil
	}
	err := s.queryTenant(ctx, tenant, `DELETE FROM human_status WHERE tenant_id = $1 AND until_at <= $2 RETURNING human_id`,
		[]any{tenant, now}, func(rows pgx.Rows) error {
			var id string
			if err := rows.Scan(&id); err != nil {
				return err
			}
			ids = append(ids, id)
			return nil
		})
	return ids, err
}

// ---- Memory ----

// The status rides the membership (memMember.status), so leaving the
// workspace drops it, like the FK's ON DELETE CASCADE.

func (s *Memory) HumanStatuses(_ context.Context, tenant string, now time.Time) (map[string]HumanStatus, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	out := map[string]HumanStatus{}
	for k, m := range s.hum.members {
		if k[0] == tenant && m.status != nil && m.status.Live(now) {
			out[k[1]] = *m.status
		}
	}
	return out, nil
}

func (s *Memory) PutHumanStatus(_ context.Context, tenant string, st HumanStatus) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, st.HumanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	m.status = &st
	s.hum.members[k] = m
	return nil
}

func (s *Memory) ClearHumanStatus(_ context.Context, tenant, humanID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok || m.status == nil {
		return false, nil
	}
	m.status = nil
	s.hum.members[k] = m
	return true, nil
}

func (s *Memory) SweepHumanStatus(_ context.Context, tenant string, now time.Time) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	var ids []string
	for k, m := range s.hum.members {
		if k[0] == tenant && m.status != nil && !m.status.Live(now) {
			m.status = nil
			s.hum.members[k] = m
			ids = append(ids, k[1])
		}
	}
	return ids, nil
}
