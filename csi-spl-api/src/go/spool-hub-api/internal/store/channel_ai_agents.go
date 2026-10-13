package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The per-channel "AI agents" switch (SPL-1684, rdb 0189). Owner decision in
// a workspace poll: the AI agents are turned on with a button per channel,
// off by default there. Off, the hub does not fan the channel's posts out to
// its member agents (nor back-fill, nor fall back), and the unanswered sweep
// leaves them out; a DM to an agent and an @agent dispatch still go.
//
// The workspace default is the registered tenants.settings key
// channel_ai_agents (spec 098, no migration). Its default is true, so a
// workspace that never set it behaves byte for byte as before. A channel's
// own value (channels.ai_agents) wins over it; NULL follows it.

// ChannelAIAgentsKey is the workspace default of the switch.
const ChannelAIAgentsKey = "channel_ai_agents"

func init() {
	RegisterTenantSetting(TenantSettingDef{Key: ChannelAIAgentsKey, Kind: SettingBool, Default: true})
}

// ChannelAIAgentsDefault is the workspace default in force (true when unset).
func (t Tenant) ChannelAIAgentsDefault() bool { return t.Settings.Bool(ChannelAIAgentsKey) }

// ChannelAIAgents is the store half of the switch.
type ChannelAIAgents interface {
	// ChannelAIAgents is the channel's own switch: nil = follow the
	// workspace default (also an unknown channel).
	ChannelAIAgents(ctx context.Context, tenantID, channelID string) (*bool, error)
	// SetChannelAIAgents stores the switch (nil = back to the workspace
	// default) and stamps ai_agents_at = at. ErrNotFound when the channel
	// does not exist (or is archived).
	SetChannelAIAgents(ctx context.Context, tenantID, channelID string, on *bool, at time.Time) error
}

var (
	_ ChannelAIAgents = (*Memory)(nil)
	_ ChannelAIAgents = (*Postgres)(nil)
)

// ChannelAIAgents implements ChannelAIAgents.
func (s *Memory) ChannelAIAgents(_ context.Context, tenant, channel string) (*bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	v, ok := s.ch.ai[[2]string{tenant, NormalizeChannel(channel)}]
	if !ok {
		return nil, nil
	}
	return &v, nil
}

// SetChannelAIAgents implements ChannelAIAgents.
func (s *Memory) SetChannelAIAgents(_ context.Context, tenant, channel string, on *bool, _ time.Time) error {
	channel = NormalizeChannel(channel)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	k := [2]string{tenant, channel}
	if _, ok := s.ch.rows[k]; !ok && !IsDefaultChannel(channel) {
		return ErrNotFound
	}
	if on == nil {
		delete(s.ch.ai, k)
		return nil
	}
	s.ch.ai[k] = *on
	return nil
}

// ChannelAIAgents implements ChannelAIAgents.
func (s *Postgres) ChannelAIAgents(ctx context.Context, tenant, channel string) (*bool, error) {
	var on *bool
	err := s.queryRowTenant(ctx, tenant, `SELECT ai_agents FROM channels WHERE tenant_id = $1 AND channel_id = $2`,
		[]any{tenant, NormalizeChannel(channel)}, &on)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return on, err
}

// SetChannelAIAgents implements ChannelAIAgents.
func (s *Postgres) SetChannelAIAgents(ctx context.Context, tenant, channel string, on *bool, at time.Time) error {
	tag, err := s.execTenant(ctx, tenant, `UPDATE channels SET ai_agents = $3, ai_agents_at = $4
		WHERE tenant_id = $1 AND channel_id = $2 AND archived_at IS NULL`,
		tenant, NormalizeChannel(channel), on, at)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
