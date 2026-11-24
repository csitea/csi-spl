package hub

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 186 7.1.2: the two read-only frames of a bulk action on topics,
// topic_select (topic_select.go resolves it) and multicast_check, the
// Multicast dialog's dry run. Neither stores anything nor sends to any box.
// Both run off the socket's read loop, one of each kind in flight per
// connection: a newer frame of a kind cancels the running one, which then
// answers nothing (plan N4).

const (
	tokenMulticastNone    = "multicast_none"
	tokenMulticastNoTopic = "multicast_no_topic"
)

// bulkRuns is a socket's running read-only frames, one per kind.
type bulkRuns struct {
	mu  sync.Mutex
	run map[string]*bulkRun
}

type bulkRun struct{ cancel context.CancelFunc }

// start cancels the running frame of kind and returns the new one's context
// and its end.
func (b *bulkRuns) start(parent context.Context, kind string) (context.Context, *bulkRun, func()) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.run == nil {
		b.run = map[string]*bulkRun{}
	}
	if old := b.run[kind]; old != nil {
		old.cancel()
	}
	ctx, cancel := context.WithCancel(parent)
	r := &bulkRun{cancel: cancel}
	b.run[kind] = r
	return ctx, r, func() {
		b.mu.Lock()
		if b.run[kind] == r {
			delete(b.run, kind)
		}
		b.mu.Unlock()
		cancel()
	}
}

// answer writes v unless a newer frame of kind cancelled r: checked under
// the lock start cancels with, so a cancelled frame never answers.
func (b *bulkRuns) answer(ctx context.Context, c *wuiConn, kind string, r *bulkRun, v any) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if ctx.Err() != nil || b.run[kind] != r {
		return
	}
	c.write(ctx, v) //nolint:errcheck
}

// stop cancels every running frame (the socket closed).
func (b *bulkRuns) stop() {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, r := range b.run {
		r.cancel()
	}
}

// wuiBulk runs one topic_select or multicast_check off the read loop.
func (s *Server) wuiBulk(ctx context.Context, c *wuiConn, f wuiIn) {
	fctx, r, done := c.bulk.start(store.WithMemo(ctx), f.Type)
	s.openMembersMemo(fctx)
	go func() {
		defer done()
		var v any
		if f.Type == "topic_select" {
			v = s.topicSelectAnswer(fctx, c, f)
		} else {
			v = s.multicastCheckAnswer(fctx, c, f)
		}
		if v != nil {
			c.bulk.answer(fctx, c, f.Type, r, v)
		}
	}()
}

type topicSelected struct {
	Type   string          `json:"type"`
	ReqID  string          `json:"req_id"`
	OK     bool            `json:"ok"`
	Error  string          `json:"error,omitempty"`
	Detail string          `json:"detail,omitempty"`
	Topics []selectedTopic `json:"topics"`
}

// topicSelectAnswer is the topic_selected frame; nil = cancelled, no answer.
func (s *Server) topicSelectAnswer(ctx context.Context, c *wuiConn, f wuiIn) any {
	out := topicSelected{Type: "topic_selected", ReqID: f.ReqID, Topics: []selectedTopic{}}
	sel, rf := parseTopicSelector(f.Action, f.TaskIDs, f.Patterns)
	if rf == nil && !uuidRe.MatchString(strings.ToLower(f.ReqID)) {
		rf = badJSON("req_id must be a UUID")
	}
	if rf != nil {
		out.Error, out.Detail = rf.token, rf.detail
		return out
	}
	topics, err := s.resolveTopicSelector(ctx, c.tenant, c.member, sel)
	switch {
	case ctx.Err() != nil:
		return nil
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Msg("topic_select")
		out.Error, out.Detail = "internal", "topics unavailable"
		return out
	}
	out.OK, out.Topics = true, topics
	return out
}

type multicastTarget struct {
	TaskID  string `json:"task_id"`
	Channel string `json:"channel"`
	Title   string `json:"title"`
	OK      bool   `json:"ok"`
	Error   string `json:"error,omitempty"`
}

type multicastChecked struct {
	Type    string            `json:"type"`
	ReqID   string            `json:"req_id"`
	OK      bool              `json:"ok"`
	Error   string            `json:"error,omitempty"`
	Detail  string            `json:"detail,omitempty"`
	Targets []multicastTarget `json:"targets"`
}

// multicastCheckAnswer is the multicast_checked frame; nil = cancelled. The
// targets are the ticked task ids, deduplicated, in the order sent; the
// quota is read once for their count (R2 QTA).
func (s *Server) multicastCheckAnswer(ctx context.Context, c *wuiConn, f wuiIn) any {
	out := multicastChecked{Type: "multicast_checked", ReqID: f.ReqID, Targets: []multicastTarget{}}
	ids, rf := multicastIDs(f)
	if rf == nil && !uuidRe.MatchString(strings.ToLower(f.ReqID)) {
		rf = badJSON("req_id must be a UUID")
	}
	if rf == nil {
		rf = s.multicastQuota(ctx, c.tenant, len(ids))
	}
	if rf != nil {
		out.Error, out.Detail = rf.token, rf.detail
		return out
	}
	sel := topicSelector{action: actionMulticast, ticks: map[string]bool{}}
	for _, id := range ids {
		sel.ticks[id] = true
	}
	topics, err := s.resolveTopicSelector(ctx, c.tenant, c.member, sel)
	shared := s.multicastShared(ctx, c, f)
	switch {
	case ctx.Err() != nil:
		return nil
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Msg("multicast_check")
		out.Error, out.Detail = "internal", "topics unavailable"
		return out
	}
	out.Targets = s.multicastTargets(ctx, c, ids, topics, shared)
	if ctx.Err() != nil {
		return nil
	}
	out.OK = true
	for _, t := range out.Targets {
		out.OK = out.OK && t.OK
	}
	return out
}

// multicastIDs is the frame's task ids, lower case, deduplicated in order.
// None answers multicast_none.
func multicastIDs(f wuiIn) ([]string, *frameRefusal) {
	seen := map[string]bool{}
	var ids []string
	for _, id := range f.TaskIDs {
		id = strings.ToLower(strings.TrimSpace(id))
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return nil, &frameRefusal{tokenMulticastNone, http.StatusBadRequest, "no topic selected"}
	}
	return ids, nil
}

// multicastQuota is the month quota for n copies, once for the whole check:
// more than the remaining messages refuses it all, naming both. An
// unlimited quota refuses nothing.
func (s *Server) multicastQuota(ctx context.Context, tenant string, n int) *frameRefusal {
	q := s.quota()
	if q.MessagesPerMonth <= 0 {
		return nil
	}
	used, err := s.o.Store.CountMessagesSince(ctx, tenant, billing.PeriodStart(s.o.Now()))
	if err != nil {
		return &frameRefusal{"internal", http.StatusInternalServerError, "quota lookup failed"}
	}
	if q.Over(billing.Usage{MessagesThisPeriod: used}, n, 0, 0) == "" {
		return nil
	}
	left := max(q.MessagesPerMonth-used, 0)
	return &frameRefusal{billing.TokenQuota, billing.HTTPQuota,
		fmt.Sprintf("%d topics selected, %d messages remaining this period", n, left)}
}

// multicastShared is the token every target shares, "" when none: billing
// and the files of admit (3.2 step 5), the same for each copy.
func (s *Server) multicastShared(ctx context.Context, c *wuiConn, f wuiIn) string {
	trow, err := s.o.Store.GetTenant(ctx, c.tenant)
	if err != nil {
		return "internal"
	}
	if !billing.AllowsWrite(trow.BillingStatus) {
		return billing.TokenUnpaid
	}
	files := wuiAttachments(f.Files)
	if s.missingFile(ctx, c.tenant, files) != "" {
		return "missing_file"
	}
	if c.member == "" {
		return ""
	}
	switch bad, err := s.unreadableFile(ctx, c.tenant, files, "", c.member); {
	case err != nil:
		return "internal"
	case bad != "":
		return "missing_file"
	}
	return ""
}

// multicastTargets is one line per id: out of scope answers topic_archived
// for an archived topic the member reads, else multicast_no_topic (the 404
// rule: it never says the topic exists); in scope, the moved-topic check,
// then the shared token.
func (s *Server) multicastTargets(ctx context.Context, c *wuiConn, ids []string, topics []selectedTopic, shared string) []multicastTarget {
	in := make(map[string]selectedTopic, len(topics))
	for _, t := range topics {
		in[t.TaskID] = t
	}
	out := make([]multicastTarget, 0, len(ids))
	for _, id := range ids {
		t, ok := in[id]
		line := multicastTarget{TaskID: id, Channel: t.Channel, Title: t.Title, Error: shared}
		if !ok {
			line.Error = s.outOfScopeToken(ctx, c, id)
		} else if rf := s.browserMovedRefusal(ctx, c.tenant, id, c.member); rf != nil {
			line.Error = rf.token
		}
		line.OK = line.Error == ""
		out = append(out, line)
	}
	return out
}

// outOfScopeToken: topic_archived for an archived topic member may read,
// else multicast_no_topic.
func (s *Server) outOfScopeToken(ctx context.Context, c *wuiConn, id string) string {
	if !uuidRe.MatchString(id) {
		return tokenMulticastNoTopic
	}
	closed, err := s.topicClosed(ctx, c.tenant, id)
	if err != nil || !closed {
		return tokenMulticastNoTopic
	}
	if may, found, err := s.canReadTopic(ctx, c.tenant, id, c.member); err != nil || !found || !may {
		return tokenMulticastNoTopic
	}
	return topicArchivedToken
}
