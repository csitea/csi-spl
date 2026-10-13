package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The Postgres side of the personal realm (personal.go): every statement in
// inPerson, so rdb 0168's person_scope policy binds it to the session's own
// person even where a WHERE person_id is forgotten. Each statement still
// names its person: the policy is the second lock, not the only one.

// realmPGErr maps a foreign-key violation (no such human) to ErrNotFound and
// a CHECK violation to ErrRealmBad; the store's own checks run first.
func realmPGErr(err error) error {
	var pe *pgconn.PgError
	if !errors.As(err, &pe) {
		return err
	}
	switch pe.Code {
	case "23503":
		return ErrNotFound
	case "23514":
		return errors.Join(ErrRealmBad, err)
	}
	return err
}

// RealmProfileOf is Realm.RealmProfileOf.
func (s *Postgres) RealmProfileOf(ctx context.Context, person string) (RealmProfile, error) {
	p := RealmProfile{CommPrefs: json.RawMessage(`{}`)}
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			SELECT COALESCE(time_zone, ''), COALESCE(locale, ''), comm_prefs, updated_at
			FROM personal.profile WHERE person_id = $1`, person).
			Scan(&p.TimeZone, &p.Locale, &p.CommPrefs, &p.UpdatedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	})
	return p, err
}

// PutRealmProfile is Realm.PutRealmProfile.
func (s *Postgres) PutRealmProfile(ctx context.Context, person string, p RealmProfile, now time.Time) error {
	if err := checkPerson(person); err != nil {
		return err
	}
	p, err := normalizeRealmProfile(p)
	if err != nil {
		return err
	}
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			INSERT INTO personal.profile (person_id, time_zone, locale, comm_prefs, updated_at)
			VALUES ($1, NULLIF($2, ''), NULLIF($3, ''), $4::jsonb, $5)
			ON CONFLICT (person_id) DO UPDATE SET time_zone = EXCLUDED.time_zone, locale = EXCLUDED.locale,
			       comm_prefs = EXCLUDED.comm_prefs, updated_at = EXCLUDED.updated_at`,
			person, p.TimeZone, p.Locale, string(p.CommPrefs), now.UTC())
		return err
	})
	return realmPGErr(err)
}

// AppendRealmLimits is Realm.AppendRealmLimits.
func (s *Postgres) AppendRealmLimits(ctx context.Context, person string, l RealmLimits, now time.Time) error {
	if err := checkPerson(person); err != nil {
		return err
	}
	if err := checkRealmLimits(l); err != nil {
		return err
	}
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `
			INSERT INTO personal.settings (person_id, valid_from, hours_limit_day_minutes, hours_limit_week_minutes, updated_at)
			VALUES ($1, $2::date, $3, $4, $5)
			ON CONFLICT (person_id, valid_from) DO UPDATE SET
			       hours_limit_day_minutes = EXCLUDED.hours_limit_day_minutes,
			       hours_limit_week_minutes = EXCLUDED.hours_limit_week_minutes, updated_at = EXCLUDED.updated_at`,
			person, l.ValidFrom, l.DayLimitMinutes, l.WeekLimitMinutes, now.UTC())
		return err
	})
	return realmPGErr(err)
}

// realmLimitsCols is the column list scanRealmLimits reads.
const realmLimitsCols = `valid_from::text, hours_limit_day_minutes, hours_limit_week_minutes, updated_at`

func scanRealmLimits(r pgx.Row) (RealmLimits, error) {
	var l RealmLimits
	err := r.Scan(&l.ValidFrom, &l.DayLimitMinutes, &l.WeekLimitMinutes, &l.UpdatedAt)
	return l, err
}

// RealmLimitsHistory is Realm.RealmLimitsHistory.
func (s *Postgres) RealmLimitsHistory(ctx context.Context, person string) ([]RealmLimits, error) {
	var out []RealmLimits
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT `+realmLimitsCols+` FROM personal.settings
			WHERE person_id = $1 ORDER BY valid_from`, []any{person}, func(r pgx.Rows) error {
			l, err := scanRealmLimits(r)
			out = append(out, l)
			return err
		})
	})
	return out, err
}

// RealmLimitsOn is Realm.RealmLimitsOn.
func (s *Postgres) RealmLimitsOn(ctx context.Context, person, day string) (RealmLimits, bool, error) {
	if err := checkPerson(person); err != nil {
		return RealmLimits{}, false, err
	}
	if err := checkRealmDay(day); err != nil {
		return RealmLimits{}, false, err
	}
	var l RealmLimits
	found := false
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		var err error
		l, err = scanRealmLimits(tx.QueryRow(ctx, `SELECT `+realmLimitsCols+` FROM personal.settings
			WHERE person_id = $1 AND valid_from <= $2::date ORDER BY valid_from DESC LIMIT 1`, person, day))
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		found = err == nil
		return err
	})
	return l, found, err
}

// RealmReceipts is Realm.RealmReceipts.
func (s *Postgres) RealmReceipts(ctx context.Context, person string) ([]RealmReceipt, error) {
	var out []RealmReceipt
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `
			SELECT DISTINCT ON (workspace_id, day, label, kind)
			       workspace_id, workspace_name, day::text, minutes, label, kind, period_start::text,
			       period_end::text, approval_state, COALESCE(approver_name, ''), decided_at, rev, copied_at
			FROM personal.hours_receipts WHERE person_id = $1
			ORDER BY workspace_id, day, label, kind, rev DESC`, []any{person}, func(r pgx.Rows) error {
			var c RealmReceipt
			var rev int16
			err := r.Scan(&c.WorkspaceID, &c.WorkspaceName, &c.Day, &c.Minutes, &c.Label, &c.Kind, &c.PeriodStart,
				&c.PeriodEnd, &c.ApprovalState, &c.ApproverName, &c.DecidedAt, &rev, &c.CopiedAt)
			c.Rev = int(rev)
			out = append(out, c)
			return err
		})
	})
	return out, err
}

// DeleteRealmReceipts calls personal.delete_my_receipts (rdb 0168), the one
// way a receipt row is removed: the runtime login has no DELETE on
// hours_receipts, and the function reads the person from the scope itself.
// DeleteRealmReceipts is Realm.DeleteRealmReceipts.
func (s *Postgres) DeleteRealmReceipts(ctx context.Context, person, workspaceID string) (int, error) {
	if err := checkPerson(person); err != nil {
		return 0, err
	}
	if err := checkRealmWorkspace(workspaceID); err != nil {
		return 0, err
	}
	var n int
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT personal.delete_my_receipts($1)`, workspaceID).Scan(&n)
	})
	return n, err
}
