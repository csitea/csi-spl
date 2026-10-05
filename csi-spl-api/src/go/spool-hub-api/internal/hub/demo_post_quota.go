package hub

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Demo post quota and size (specs/077 T012, FR-006, 3.6): a demo_user posts
// at most DefaultDemoPostsPerMinute messages a minute and
// DefaultDemoPostsPerDay a day, counted per human in the T013 counter (rdb
// 0127 quota_counts) and refused 429 demo_quota BEFORE the store write. A
// minute is the UTC clock minute and a day the UTC calendar day: fixed
// windows, one counter row each. Every message body a demo_user writes
// (send, reply, edit, merge) is at most demoBodyMax bytes, else 413
// too_large; every other role keeps bodyMax.

// DefaultDemoPostsPerMinute and DefaultDemoPostsPerDay are the owner's
// limits (spec 3.6); Options.DemoPostsPerMinute / DemoPostsPerDay <= 0 is
// these, never unlimited.
const (
	DefaultDemoPostsPerMinute = 10
	DefaultDemoPostsPerDay    = 200
)

// demoBodyMax is a demo_user's message body limit, in bytes (spec 3.6).
const demoBodyMax = 4 << 10

// The quota kinds of one demo_user post: its minute and its day.
const (
	demoQuotaPostMinute = "post_min"
	demoQuotaPostDay    = "post_day"
)

// demoPostLimits is the (per minute, per day) post limit in force.
func (s *Server) demoPostLimits() (int, int) {
	perMin, perDay := DefaultDemoPostsPerMinute, DefaultDemoPostsPerDay
	if s.o.DemoPostsPerMinute > 0 {
		perMin = s.o.DemoPostsPerMinute
	}
	if s.o.DemoPostsPerDay > 0 {
		perDay = s.o.DemoPostsPerDay
	}
	return perMin, perDay
}

// demoSend is a demo_user's browser send (send and reply alike): its body
// size, then one post of its minute and day, as the (token, status, detail)
// triple of the hub's checks: "" = go on. Anybody else is not counted.
func (s *Server) demoSend(ctx context.Context, tenant, member string, m *msg.Message) (string, int, string) {
	if !s.isDemoVisitor(ctx, tenant, member) {
		return "", 0, ""
	}
	if len(m.Body) > demoBodyMax {
		return demoTooLarge()
	}
	return s.demoPost(ctx, tenant, member, m.MsgID)
}

// demoPost takes one post of a demo_user's minute and day. A resend of a
// stored msgID is no new post (it re-acks and writes nothing). The minute
// is taken first, so a burst refused per minute never spends the day. Fails
// closed like demoAgentTurn: a store that cannot count refuses the post.
func (s *Server) demoPost(ctx context.Context, tenant, member, msgID string) (string, int, string) {
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
	now := s.o.Now().UTC()
	perMin, perDay := s.demoPostLimits()
	if tok, status, detail := s.takeDemoQuota(ctx, qc, tenant, member, demoQuotaPostMinute,
		now.Truncate(time.Minute), perMin, "a demo user posts at most "+strconv.Itoa(perMin)+" messages a minute"); tok != "" {
		return tok, status, detail
	}
	return s.takeDemoQuota(ctx, qc, tenant, member, demoQuotaPostDay,
		now.Truncate(24*time.Hour), perDay, "a demo user posts at most "+strconv.Itoa(perDay)+" messages a day")
}

// demoBodyFits refuses 413 too_large when member is a demo_user and body is
// over demoBodyMax (an edit or a merge); "" = go on. Anybody else is held
// to bodyMax by the caller's own check.
func (s *Server) demoBodyFits(ctx context.Context, tenant, member, body string) (string, int, string) {
	if len(body) <= demoBodyMax || !s.isDemoVisitor(ctx, tenant, member) {
		return "", 0, ""
	}
	return demoTooLarge()
}

// demoTooLarge is the refusal of a demo_user body over demoBodyMax.
func demoTooLarge() (string, int, string) {
	return "too_large", http.StatusRequestEntityTooLarge,
		"a demo user's message body must be at most " + strconv.Itoa(demoBodyMax) + " bytes"
}
