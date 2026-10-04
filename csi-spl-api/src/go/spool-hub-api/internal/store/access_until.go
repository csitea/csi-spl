package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// A membership that expires (rdb 0113 tenant_memberships.access_until, spec
// 072 A27, guest rule R1). At or past access_until the membership grants
// nothing: MemberRole answers ErrNotFound (the door's 403, sign-in included)
// and Memberships leaves the tenant out, exactly as for a suspended one. The
// row stays: MemberState still finds it and ListMembers still lists it, so an
// admin can extend, clear or remove it.

// ErrAccessUntilUnavailable: this database has no access_until column yet
// (rdb 0113 not applied). The hub answers 503 not_migrated.
var ErrAccessUntilUnavailable = errors.New("store: membership expiry needs rdb 0113")

// MemberAccess is implemented by Memory and Postgres.
type MemberAccess interface {
	// SetMemberAccessUntil sets (non-nil) or clears (nil) the instant the
	// membership stops granting access. The last-owner and last-admin guards
	// apply to a set as to a suspension. ErrNotFound: not a member.
	SetMemberAccessUntil(ctx context.Context, tenant, humanID string, until *time.Time) error
}

var (
	_ MemberAccess = (*Memory)(nil)
	_ MemberAccess = (*Postgres)(nil)
)

// lapsed reports whether a membership ending at until (zero = never) has
// ended at now.
func lapsed(until, now time.Time) bool {
	return !until.IsZero() && !now.Before(until)
}

// accessLive is the WHERE clause fragment (memberships aliased m) that keeps
// a membership whose access has not ended; "" before rdb 0113.
func accessLive(withAccess bool) string {
	if !withAccess {
		return ""
	}
	return ` AND (m.access_until IS NULL OR m.access_until > now())`
}

// accessUntilCol is the select-list column for the end of access: NULL before
// rdb 0113, so one scan target serves both shapes.
func accessUntilCol(withAccess bool) string {
	if !withAccess {
		return "NULL::timestamptz"
	}
	return "m.access_until"
}

// hasAccessUntil is the catalogue probe for rdb 0113. The hub may roll before
// the migration reaches its database (a trunk push deploys dev and prd
// together), so until the column is there memberships are read without it:
// never a 500. Same re-check cadence as the agent_seats probe.
func (s *Postgres) hasAccessUntil(ctx context.Context) bool {
	return s.access.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_attribute
			WHERE attrelid = to_regclass('tenant_memberships') AND attname = 'access_until' AND NOT attisdropped)`).Scan(&ok)
		return ok, err
	}, time.Now())
}

func (s *Memory) SetMemberAccessUntil(_ context.Context, tenant, humanID string, until *time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	if until != nil {
		if err := s.memLockoutGuard(tenant, humanID, m.role); err != nil {
			return err
		}
		m.accessUntil = until.UTC()
	} else {
		m.accessUntil = time.Time{}
	}
	s.hum.members[k] = m
	return nil
}

func (s *Postgres) SetMemberAccessUntil(ctx context.Context, tenant, humanID string, until *time.Time) error {
	if !s.hasAccessUntil(ctx) {
		return ErrAccessUntilUnavailable
	}
	defer s.hot.forget() // the door cache must not outlive a shortened access
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		cur, owner, err := memberTx(ctx, tx, tenant, humanID)
		if err != nil {
			return err
		}
		var at any
		if until != nil {
			if err := lockoutGuardTx(ctx, tx, tenant, humanID, cur, owner); err != nil {
				return err
			}
			at = until.UTC()
		}
		_, err = tx.Exec(ctx, `UPDATE tenant_memberships SET access_until = $3::timestamptz
			WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID, at)
		return err
	})
}
