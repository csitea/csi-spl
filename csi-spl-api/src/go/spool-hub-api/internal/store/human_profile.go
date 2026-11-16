package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// A human's first name, last name and phone (rdb 0287, SPL-5707, spec 154
// section 12.5). Hub-wide, outside rdb 0014's RLS, like display_name. First +
// last is the one source of truth for the name: SetProfileName writes
// display_name as their join in the same statement, and SetDisplayName (an
// admin's rename, the old single field) splits back into them with
// auth.SplitDisplayName, so the three never drift.

var _ auth.ProfileStore = AuthHooks{}

// nullStr is "" -> SQL NULL.
func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// SetProfileName writes first and last name and display_name as their join in one statement.
func (s *Postgres) SetProfileName(ctx context.Context, humanID, first, last string) error {
	return s.execHuman(ctx, `UPDATE humans SET first_name = $2, last_name = $3, display_name = $4 WHERE human_id = $1`,
		humanID, nullStr(first), nullStr(last), auth.JoinName(first, last))
}

// SetPhone stores the human's phone; "" clears it.
func (s *Postgres) SetPhone(ctx context.Context, humanID, phone string) error {
	return s.execHuman(ctx, `UPDATE humans SET phone = $2 WHERE human_id = $1`, humanID, nullStr(phone))
}

// Profile reads the human's first name, last name and phone; an unknown human is ErrNotFound.
func (s *Postgres) Profile(ctx context.Context, humanID string) (auth.Profile, error) {
	var p auth.Profile
	err := s.pool.QueryRow(ctx, `SELECT COALESCE(first_name, ''), COALESCE(last_name, ''), COALESCE(phone, '')
		FROM humans WHERE human_id = $1`, humanID).Scan(&p.FirstName, &p.LastName, &p.Phone)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.Profile{}, ErrNotFound
	}
	return p, err
}

// SetProfileName is the in-memory twin of Postgres.SetProfileName.
func (s *Memory) SetProfileName(_ context.Context, humanID, first, last string) error {
	return s.withHuman(humanID, func(hm *memHuman) {
		hm.first, hm.last, hm.name = first, last, auth.JoinName(first, last)
	})
}

// SetPhone is the in-memory twin of Postgres.SetPhone.
func (s *Memory) SetPhone(_ context.Context, humanID, phone string) error {
	return s.withHuman(humanID, func(hm *memHuman) { hm.phone = phone })
}

// Profile is the in-memory twin of Postgres.Profile.
func (s *Memory) Profile(_ context.Context, humanID string) (auth.Profile, error) {
	var p auth.Profile
	err := s.withHuman(humanID, func(hm *memHuman) { p = auth.Profile{FirstName: hm.first, LastName: hm.last, Phone: hm.phone} })
	return p, err
}

// Profile is the human's own; an unknown human is auth.ErrNoHuman.
func (a AuthHooks) Profile(ctx context.Context, humanID string) (auth.Profile, error) {
	p, err := a.H.Profile(ctx, humanID)
	if errors.Is(err, ErrNotFound) {
		return auth.Profile{}, auth.ErrNoHuman
	}
	return p, err
}

// SetProfileName: a demo visitor keeps the pseudonym (specs/077 T011), like
// SetDisplayName.
func (a AuthHooks) SetProfileName(ctx context.Context, humanID, first, last string) error {
	if a.demoSeat(ctx, humanID, a.Policy.OpenWorkspace) {
		return auth.ErrPseudonymFixed
	}
	return noHuman(a.H.SetProfileName(ctx, humanID, first, last))
}

// SetPhone: a demo visitor is a pseudonym and keeps no number (its card never
// shows one, specs/077 FR-007).
func (a AuthHooks) SetPhone(ctx context.Context, humanID, phone string) error {
	if a.demoSeat(ctx, humanID, a.Policy.OpenWorkspace) {
		return auth.ErrPseudonymFixed
	}
	return noHuman(a.H.SetPhone(ctx, humanID, phone))
}

func noHuman(err error) error {
	if errors.Is(err, ErrNotFound) {
		return auth.ErrNoHuman
	}
	return err
}
