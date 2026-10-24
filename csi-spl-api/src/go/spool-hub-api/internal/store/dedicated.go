package store

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
)

// Dedicated agents and private scopes (spec 144 T002, rdb 0219, SPL-3182).
// A dedicated agent is one (agent_id, box_id) bound to ONE scope of its
// workspace: a channel (scope_id = the channel id) or a topic (scope_id = the
// task uuid). The binding is keyed by the agent, so a rebind to another scope
// is a new agent (spec 14 Q1 A); setting the same binding again is a no-op,
// which keeps it across a SPAWN_REUSE_ID respawn (spec 4.3).
//
// A private scope is a channel with channels.is_private_scope, or a topic
// whose messages carry messages.is_private_scope. BoxTaskEnvelopes (the WS
// tail) returns a private envelope only to the agent dedicated to its scope,
// rdb 0219's spool_agent_scope_ok spelled in the read itself:
//   - an agent with a binding reads only its scope (its channel, or its topic);
//   - any other agent reads no private envelope.
// The reading agent rides on ctx (WithTailAgent). A tail with no agent on
// ctx reads like a non-dedicated agent: it fails closed (spec 12.2 control
// C2: a dispatcher on the dedicated agent's own box reads nothing).

// Dedicated scope types (rdb 0219 chk_dedicated_scope_type).
const (
	ScopeChannel = "channel"
	ScopeTopic   = "topic"
)

// ErrBadDedicatedScope refuses what rdb 0219's checks would refuse: an
// unknown scope type, a malformed channel id or topic uuid, or an agent, box
// or bound_by outside 1..64 characters. Nothing was written.
var ErrBadDedicatedScope = errors.New("store: bad dedicated scope")

// ErrDedicatedRebind refuses SetDedicatedBinding for an agent already bound
// to another scope: one agent, one scope (spec 14 Q1 A). Remove it first.
var ErrDedicatedRebind = errors.New("store: agent is dedicated to another scope")

// DedicatedBinding is one dedicated_agents row.
type DedicatedBinding struct {
	TenantID  string
	AgentID   string
	BoxID     string
	ScopeType string // ScopeChannel or ScopeTopic
	ScopeID   string
	BoundBy   string
	BoundAt   time.Time
}

// DedicatedStore is implemented by Memory and Postgres.
type DedicatedStore interface {
	// GetDedicatedBinding returns agent-on-box's binding, ErrNotFound when
	// it is not dedicated.
	GetDedicatedBinding(ctx context.Context, tenantID, agentID, boxID string) (DedicatedBinding, error)
	// SetDedicatedBinding binds b.AgentID on b.BoxID to b's scope (BoundAt
	// zero = now) and returns the stored row. The same scope again returns
	// the existing row unchanged; another scope is ErrDedicatedRebind.
	SetDedicatedBinding(ctx context.Context, b DedicatedBinding) (DedicatedBinding, error)
	// RemoveDedicatedBinding unbinds agent-on-box, ErrNotFound if unbound.
	RemoveDedicatedBinding(ctx context.Context, tenantID, agentID, boxID string) error
	// ListDedicatedAgentsByScope returns the scope's bindings by agent, box.
	ListDedicatedAgentsByScope(ctx context.Context, tenantID, scopeType, scopeID string) ([]DedicatedBinding, error)
	// IsPrivateScope reports whether a channel is flagged private, or for a
	// topic whether any of its messages is flagged or lives in a private
	// channel. An unknown channel or topic is not private.
	IsPrivateScope(ctx context.Context, tenantID, scopeType, scopeID string) (bool, error)
	// SetPrivateScope sets the flag of a channel (private_scope_at = now,
	// cleared on false) or of every message of a topic (spec 5.1);
	// ErrNotFound for an unknown channel or topic.
	SetPrivateScope(ctx context.Context, tenantID, scopeType, scopeID string, private bool, now time.Time) error
}

var (
	_ DedicatedStore = (*Memory)(nil)
	_ DedicatedStore = (*Postgres)(nil)
)

type tailAgentKey struct{}

// WithTailAgent returns ctx naming agent as the reader of BoxTaskEnvelopes
// under it; "" returns ctx unchanged.
func WithTailAgent(ctx context.Context, agent string) context.Context {
	if agent == "" {
		return ctx
	}
	return context.WithValue(ctx, tailAgentKey{}, agent)
}

// TailAgent is the agent WithTailAgent put on ctx, or "".
func TailAgent(ctx context.Context) string {
	a, _ := ctx.Value(tailAgentKey{}).(string)
	return a
}

// rdb 0219 chk_dedicated_scope_id, per type.
var (
	dedicatedChannelRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)
	dedicatedTopicRE   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

// checkScope is rdb 0219's scope checks in the store, so both twins refuse
// the same input before any write.
func checkScope(scopeType, scopeID string) error {
	switch scopeType {
	case ScopeChannel:
		if dedicatedChannelRE.MatchString(scopeID) {
			return nil
		}
	case ScopeTopic:
		if dedicatedTopicRE.MatchString(scopeID) {
			return nil
		}
	}
	return ErrBadDedicatedScope
}

// idLen1to64 is rdb 0219's length CHECK on agent_id, box_id and bound_by.
func idLen1to64(v string) bool { return len(v) >= 1 && len(v) <= 64 }

// checkBinding validates b and fills BoundAt (zero = now, UTC).
func checkBinding(b *DedicatedBinding, now time.Time) error {
	if err := checkTenant(b.TenantID); err != nil {
		return err
	}
	if !idLen1to64(b.AgentID) || !idLen1to64(b.BoxID) || !idLen1to64(strings.TrimSpace(b.BoundBy)) {
		return ErrBadDedicatedScope
	}
	if err := checkScope(b.ScopeType, b.ScopeID); err != nil {
		return err
	}
	if b.BoundAt.IsZero() {
		b.BoundAt = now
	}
	b.BoundAt = b.BoundAt.UTC()
	return nil
}

// dedicatedTailOK is spool_agent_scope_ok for one envelope of channel ch and
// topic task: bound is the reading agent's binding (ok = it has one),
// private whether the envelope is in a private scope.
func dedicatedTailOK(bound DedicatedBinding, ok bool, ch, task string, private bool) bool {
	if ok {
		return (bound.ScopeType == ScopeChannel && bound.ScopeID == ch) ||
			(bound.ScopeType == ScopeTopic && bound.ScopeID == task)
	}
	return !private
}
