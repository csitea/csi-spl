package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The default priority of a channel's new topics (spec 150 v1.8 section
// 3.3.2, rdb 0332, SPL-6658). Owner HUM-10 (t1 b6c7b21c, msgs 81cbf77e and
// 1aa52a37): every channel has one, set in its settings; an unset channel
// reads 3 (TopicPriorityDefault); only the workspace owner changes it (the
// hub's gate, B18). A new topic snapshots it into topic_priorities when it
// opens, so a later change never touches an existing topic.

// ChannelDefaultPrio is one channel's default priority: Priority nil = unset
// (also an unknown or an unseeded default channel), SetBy / SetAt the last
// change ("" / zero before the first).
type ChannelDefaultPrio struct {
	Priority *int
	SetBy    string
	SetAt    time.Time
}

// Effective is the priority a new topic of the channel starts at.
func (p ChannelDefaultPrio) Effective() int {
	if p.Priority == nil {
		return TopicPriorityDefault
	}
	return *p.Priority
}

// ChannelDefaultPriority is the store half of the channel default.
type ChannelDefaultPriority interface {
	ChannelDefaultPriority(ctx context.Context, tenantID, channelID string) (ChannelDefaultPrio, error)
	// SetChannelDefaultPriority stores prio (nil = back to unset) and stamps
	// by / at. ErrBadTopicPriority outside 1..5 before any write; ErrNotFound
	// when the channel does not exist (or is archived). A default channel
	// without its row gets it first, as the subscriptions do.
	SetChannelDefaultPriority(ctx context.Context, tenantID, channelID string, prio *int, by string, at time.Time) error
}

var (
	_ ChannelDefaultPriority = (*Memory)(nil)
	_ ChannelDefaultPriority = (*Postgres)(nil)
)

func validChannelDefaultPrio(prio *int) error {
	if prio != nil && (*prio < 1 || *prio > 5) {
		return ErrBadTopicPriority
	}
	return nil
}

// ChannelDefaultPriority implements ChannelDefaultPriority.
func (s *Memory) ChannelDefaultPriority(_ context.Context, tenant, channel string) (ChannelDefaultPrio, error) {
	if err := checkTenant(tenant); err != nil {
		return ChannelDefaultPrio{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	channel = NormalizeChannel(channel)
	if s.ch.archivedCh(tenant, channel) {
		return ChannelDefaultPrio{}, nil
	}
	return s.ch.defPrio[[2]string{tenant, channel}].copied(), nil
}

// SetChannelDefaultPriority implements ChannelDefaultPriority.
func (s *Memory) SetChannelDefaultPriority(_ context.Context, tenant, channel string, prio *int, by string, at time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if err := validChannelDefaultPrio(prio); err != nil {
		return err
	}
	channel = NormalizeChannel(channel)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	k := [2]string{tenant, channel}
	if _, ok := s.ch.rows[k]; !ok && !IsDefaultChannel(channel) {
		return ErrNotFound
	}
	s.ch.defPrio[k] = ChannelDefaultPrio{Priority: prio, SetBy: by, SetAt: at}.copied()
	return nil
}

// copied detaches Priority from the caller's variable.
func (p ChannelDefaultPrio) copied() ChannelDefaultPrio {
	if p.Priority != nil {
		v := *p.Priority
		p.Priority = &v
	}
	return p
}

// ChannelDefaultPriority implements ChannelDefaultPriority.
func (s *Postgres) ChannelDefaultPriority(ctx context.Context, tenant, channel string) (ChannelDefaultPrio, error) {
	var out ChannelDefaultPrio
	var at *time.Time
	err := s.queryRowTenant(ctx, tenant, `SELECT default_priority, default_priority_by, default_priority_at
		FROM channels WHERE tenant_id = $1 AND channel_id = $2 AND archived_at IS NULL`,
		[]any{tenant, NormalizeChannel(channel)}, &out.Priority, &out.SetBy, &at)
	if errors.Is(err, pgx.ErrNoRows) {
		return ChannelDefaultPrio{}, nil
	}
	if at != nil {
		out.SetAt = at.UTC()
	}
	return out, err
}

// SetChannelDefaultPriority implements ChannelDefaultPriority.
func (s *Postgres) SetChannelDefaultPriority(ctx context.Context, tenant, channel string, prio *int, by string, at time.Time) error {
	if err := validChannelDefaultPrio(prio); err != nil {
		return err
	}
	channel = NormalizeChannel(channel)
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if err := seedDefault(ctx, tx, tenant, channel); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE channels SET default_priority = $3, default_priority_by = $4,
			default_priority_at = $5 WHERE tenant_id = $1 AND channel_id = $2 AND archived_at IS NULL`,
			tenant, channel, prio, by, at)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}
