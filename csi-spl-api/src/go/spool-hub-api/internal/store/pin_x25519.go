package store

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
)

// The box key desk's X25519 recipient on its pin (spec 127 5.2 step 3,
// rdb 0234): public, sent signed in the join; a lease is sealed to it.

// BoxX25519Re is an age X25519 recipient, as rdb 0234's CHECK has it.
var BoxX25519Re = regexp.MustCompile(`^age1[02-9ac-hj-np-z]{58}$`)

// PinX25519 is implemented by Memory and Postgres.
type PinX25519 interface {
	// SetPinBoxX25519 records box's desk recipient on its live pin; ""
	// clears it (a join without one: no stale recipient survives a re-join).
	// ErrNotFound: no live pin.
	SetPinBoxX25519(ctx context.Context, tenant, box, recipient string, now time.Time) error
	// PinBoxX25519 reads it; "" = none recorded. ErrNotFound: no live pin.
	PinBoxX25519(ctx context.Context, tenant, box string) (string, error)
}

var (
	_ PinX25519 = (*Memory)(nil)
	_ PinX25519 = (*Postgres)(nil)
)

// SetPinBoxX25519 records a desk recipient (PinX25519).
func (s *Memory) SetPinBoxX25519(_ context.Context, tenant, box, recipient string, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, box}
	if p, ok := s.pins[k]; !ok || p.revoked {
		return ErrNotFound
	}
	if s.pinX25519 == nil {
		s.pinX25519 = map[[2]string]string{}
	}
	if recipient == "" {
		delete(s.pinX25519, k)
		return nil
	}
	s.pinX25519[k] = recipient
	return nil
}

// PinBoxX25519 reads a desk recipient (PinX25519).
func (s *Memory) PinBoxX25519(_ context.Context, tenant, box string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, box}
	if p, ok := s.pins[k]; !ok || p.revoked {
		return "", ErrNotFound
	}
	return s.pinX25519[k], nil
}

// SetPinBoxX25519 records a desk recipient (PinX25519).
func (s *Postgres) SetPinBoxX25519(ctx context.Context, tenant, box, recipient string, _ time.Time) error {
	tag, err := s.execTenant(ctx, tenant, `UPDATE pins SET box_x25519 = NULLIF($3, '')
		WHERE tenant_id = $1 AND box_id = $2 AND revoked_at IS NULL`, tenant, box, recipient)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

// PinBoxX25519 reads a desk recipient (PinX25519).
func (s *Postgres) PinBoxX25519(ctx context.Context, tenant, box string) (string, error) {
	var out *string
	err := s.queryRowTenant(ctx, tenant, `SELECT box_x25519 FROM pins
		WHERE tenant_id = $1 AND box_id = $2 AND revoked_at IS NULL`, []any{tenant, box}, &out)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil || out == nil {
		return "", err
	}
	return *out, nil
}
