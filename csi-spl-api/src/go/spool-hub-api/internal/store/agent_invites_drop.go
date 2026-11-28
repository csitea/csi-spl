package store

import (
	"context"
	"time"
)

// AgentInvites is the retire half of an agent id's channel seats (spec 061
// 3.6, SPL-6714). Agent ids are reused after the quarantine, and a seat a
// member gave an id (channel_subscriptions origin 'invite') never ended with
// the id, so a reused id inherited every channel the old one was invited to.
// A retire on the box (agent-id-retire.sh) asks the hub, signed by that box's
// own key, to drop the seats; the hub calls this for the asking box only.
type AgentInvites interface {
	// DropAgentInvites marks every channel seat of agent on box in tenant
	// removed (origin 'removed': a later announce does not put it back; a
	// member's new invite does), archived channels included: their rows stay
	// for UnarchiveChannel, and a retired id must not come back with them.
	// Channel history, agent_seats and the seats of the same id on another
	// box stay. It returns the channels whose seat changed, sorted; nil when
	// there were none.
	DropAgentInvites(ctx context.Context, tenantID, boxID, agentID string, now time.Time) ([]string, error)
}

var (
	_ AgentInvites = (*Memory)(nil)
	_ AgentInvites = (*Postgres)(nil)
)
