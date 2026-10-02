package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// A person's own order of the Channels list (SPL-1034, specs/045 §3.8, rdb
// 0073): per person AND per tenant, on the membership row. nil = never set.

// ChannelOrders reads and writes tenant_memberships.channel_order.
type ChannelOrders interface {
	// ChannelOrder is the stored order, nil when never set. ErrNotFound when
	// the human has no membership in the tenant.
	ChannelOrder(ctx context.Context, tenant, humanID string) ([]string, error)
	// SetChannelOrder stores order (the caller validated it); an empty order
	// clears it. ErrNotFound when there is no such membership.
	SetChannelOrder(ctx context.Context, tenant, humanID string, order []string) error
}

var (
	_ ChannelOrders = (*Memory)(nil)
	_ ChannelOrders = (*Postgres)(nil)
)

func (s *Memory) ChannelOrder(_ context.Context, tenant, humanID string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	m, ok := s.hum.members[[2]string{tenant, humanID}]
	if !ok {
		return nil, ErrNotFound
	}
	if m.channelOrder == nil {
		return nil, nil
	}
	return append([]string{}, m.channelOrder...), nil
}

func (s *Memory) SetChannelOrder(_ context.Context, tenant, humanID string, order []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	m.channelOrder = nil
	if len(order) > 0 {
		m.channelOrder = append([]string{}, order...)
	}
	s.hum.members[k] = m
	return nil
}

// ChannelOrder / SetChannelOrder touch one row of the tenant they name, so
// they run in that tenant's scope (FORCE RLS, rdb 0014).
func (s *Postgres) ChannelOrder(ctx context.Context, tenant, humanID string) ([]string, error) {
	if order, ok, err := memoOrder(ctx, humanID, tenant); ok {
		return order, err
	}
	var order []string
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT channel_order FROM tenant_memberships
			WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID).Scan(&order)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return order, err
}

func (s *Postgres) SetChannelOrder(ctx context.Context, tenant, humanID string, order []string) error {
	defer s.hot.forget() // DB payload cut 5: the door cache holds channel_order
	var v any
	if len(order) > 0 {
		v = order
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE tenant_memberships SET channel_order = $3::text[]
			WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID, v)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}
