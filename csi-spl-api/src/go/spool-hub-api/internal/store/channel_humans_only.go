package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The humans-only mark of a channel (SPL-2423, rdb 0206). Owner HUM-10,
// 2026-10-17: "once the users have removed all of the agents from the
// properties of a channel, no new agents should be added by the system"; his
// poll answer A: no agent is a member, none reads or posts in it.
//
// The hub sets the mark when a person's remove leaves the channel with no
// agent (DELETE /v1/channels/{c}/agents/...), and clears it when a person
// invites an agent again (POST /v1/channels/{c}/agents). Nothing else in the
// hub writes it. The box side's automatic join (do_spl_dispatch_subscribe)
// skips a marked channel, and the hub delivers none of its posts to an agent.

// ChannelHumansOnly is the store half of the mark.
type ChannelHumansOnly interface {
	// ChannelHumansOnly reports the mark (false for an unknown channel).
	ChannelHumansOnly(ctx context.Context, tenantID, channelID string) (bool, error)
	// SetChannelHumansOnly sets (on) or clears the mark; at is when.
	// ErrNotFound when the channel has no row.
	SetChannelHumansOnly(ctx context.Context, tenantID, channelID string, on bool, at time.Time) error
}

var (
	_ ChannelHumansOnly = (*Memory)(nil)
	_ ChannelHumansOnly = (*Postgres)(nil)
)

// ChannelHumansOnly implements ChannelHumansOnly.
func (s *Memory) ChannelHumansOnly(_ context.Context, tenant, channel string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	return s.ch.humansOnly[[2]string{tenant, NormalizeChannel(channel)}], nil
}

// SetChannelHumansOnly implements ChannelHumansOnly.
func (s *Memory) SetChannelHumansOnly(_ context.Context, tenant, channel string, on bool, _ time.Time) error {
	channel = NormalizeChannel(channel)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	k := [2]string{tenant, channel}
	if _, ok := s.ch.rows[k]; !ok && !IsDefaultChannel(channel) {
		return ErrNotFound
	}
	if !on {
		delete(s.ch.humansOnly, k)
		return nil
	}
	s.ch.humansOnly[k] = true
	return nil
}

// ChannelHumansOnly implements ChannelHumansOnly.
func (s *Postgres) ChannelHumansOnly(ctx context.Context, tenant, channel string) (bool, error) {
	var on bool
	err := s.queryRowTenant(ctx, tenant, `SELECT humans_only_at IS NOT NULL FROM channels WHERE tenant_id = $1 AND channel_id = $2`,
		[]any{tenant, NormalizeChannel(channel)}, &on)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return on, err
}

// SetChannelHumansOnly implements ChannelHumansOnly. Setting keeps the first
// stamp; clearing writes NULL. A default channel gets its row first, as
// RemoveChannelAgent seeds it.
func (s *Postgres) SetChannelHumansOnly(ctx context.Context, tenant, channel string, on bool, at time.Time) error {
	channel = NormalizeChannel(channel)
	var stamp *time.Time
	if on {
		stamp = &at
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if err := seedDefault(ctx, tx, tenant, channel); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE channels SET humans_only_at = CASE WHEN $3::timestamptz IS NULL THEN NULL
			ELSE coalesce(humans_only_at, $3) END WHERE tenant_id = $1 AND channel_id = $2`, tenant, channel, stamp)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}
