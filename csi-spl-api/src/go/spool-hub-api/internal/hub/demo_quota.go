package hub

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Demo quotas (specs/077 3.7). A demo_user's work is counted in the store
// (store.QuotaCounter, rdb 0127) and the unit past the limit is refused
// 429 demo_quota BEFORE the work is built. T013 counts agent turns per
// visit; T012's posts per minute and per day (demo_post_quota.go) reuse
// takeDemoQuota with their own kind and window.

// DefaultDemoAgentTurns is the owner's 20 agent turns per visit (spec 3.7,
// Q6); Options.DemoAgentTurns <= 0 is this, never unlimited.
const DefaultDemoAgentTurns = 20

// demoQuotaAgentTurn is the quota kind of one agent turn: a channel fan-out
// or an @agent dispatch of a demo_user's browser send.
const demoQuotaAgentTurn = "agent_turn"

// demoAgentTurns is the agent-turn limit per visit in force.
func (s *Server) demoAgentTurns() int {
	if s.o.DemoAgentTurns > 0 {
		return s.o.DemoAgentTurns
	}
	return DefaultDemoAgentTurns
}

// isDemoVisitor reports whether member acts in tenant as a demo_user of the
// open demo workspace; anybody else is never counted.
func (s *Server) isDemoVisitor(ctx context.Context, tenant, member string) bool {
	if s.o.DemoWorkspace == "" || tenant != s.o.DemoWorkspace || member == "" {
		return false
	}
	a, err := s.access(ctx, member, tenant)
	return err == nil && a.Role == rbac.DemoUser
}

// demoAgentTurn takes one agent turn of member's visit (the window is the
// visit's membership created_at), as the (token, status, detail) triple of
// the hub's checks: "" = go on. A resend of a stored msgID is no new turn
// (it re-acks and builds no new delivery). Fails closed: a store that
// cannot count refuses the turn rather than leaving the cost uncapped.
func (s *Server) demoAgentTurn(ctx context.Context, tenant, member, msgID string) (string, int, string) {
	if !s.isDemoVisitor(ctx, tenant, member) {
		return "", 0, ""
	}
	switch _, _, err := s.o.Store.MessageTimes(ctx, tenant, msgID); {
	case err == nil:
		return "", 0, ""
	case !errors.Is(err, store.ErrNotFound):
		return "internal", http.StatusInternalServerError, "message lookup failed"
	}
	qc, ok := s.o.Store.(store.QuotaCounter)
	if !ok {
		return "internal", http.StatusInternalServerError, "this store cannot count demo quotas"
	}
	since, err := qc.MemberSince(ctx, tenant, member)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("member", member).Msg("demo visit lookup")
		return "internal", http.StatusInternalServerError, "demo visit lookup failed"
	}
	limit := s.demoAgentTurns()
	return s.takeDemoQuota(ctx, qc, tenant, member, demoQuotaAgentTurn, since, limit,
		"a demo visit holds "+strconv.Itoa(limit)+" agent turns")
}

// takeDemoQuota takes one unit of member's (kind, window) counter: 429
// demo_quota with detail once it holds limit, 500 when the store fails.
func (s *Server) takeDemoQuota(ctx context.Context, qc store.QuotaCounter, tenant, member, kind string,
	window time.Time, limit int, detail string) (string, int, string) {
	n, ok, err := qc.TakeQuota(ctx, tenant, member, kind, window, limit)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("member", member).Str("kind", kind).Msg("demo quota")
		return "internal", http.StatusInternalServerError, "demo quota unavailable"
	case !ok:
		s.o.Log.Info().Str("tenant", tenant).Str("member", member).Str("kind", kind).Int("n", n).Msg("demo quota refused")
		return "demo_quota", http.StatusTooManyRequests, detail
	}
	return "", 0, ""
}
