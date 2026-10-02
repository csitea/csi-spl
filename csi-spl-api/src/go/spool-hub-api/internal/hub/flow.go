package hub

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The per-member Flow (spec 062, contract
// specs/062-flow-per-user-counts/contracts/flow-v1.md). The owner, t1
// 25826b7b: "facebook like numbering on top of the flow pane, and that flow
// page to show ONLY the flow events relevant to that user". The store
// decides relevance when a line is stored (store/flow_postgres.go); the hub
// serves the page and the counts (GET /v1/view/flow) and pushes a `flow`
// frame to the member's sockets on every hub process: when a line gives
// them an event (fanoutFlow), and when their marks move (pushFlowCounts).

const (
	flowLimitDefault = 30
	flowTextMax      = 90 // characters of the body an entry carries
)

// wireFlowEvent is the thin entry (contract 2.1): never the envelope.
type wireFlowEvent struct {
	MsgID        string  `json:"msg_id"`
	Cursor       string  `json:"cursor"`
	ReceivedAt   string  `json:"received_at"`
	Kind         string  `json:"kind"`
	Unread       bool    `json:"unread"`
	From         string  `json:"from"`
	FromBox      string  `json:"from_box"`
	To           string  `json:"to"`
	ToBox        string  `json:"to_box"`
	TypedBy      string  `json:"typed_by,omitempty"`
	Channel      *string `json:"channel"`
	TaskID       string  `json:"task_id"`
	ParentTaskID string  `json:"parent_task_id,omitempty"`
	Text         string  `json:"text"`
	Files        int     `json:"files"`
}

func wireFlow(e store.FlowEvent) wireFlowEvent {
	w := wireFlowEvent{MsgID: e.MsgID, Cursor: encCursor(e.At, e.MsgID), ReceivedAt: rfc(e.At), Kind: e.Kind,
		Unread: e.Unread, From: e.FromID, FromBox: e.FromBox, To: e.ToID, ToBox: e.ToBox, TypedBy: e.TypedBy,
		TaskID: e.TaskID, ParentTaskID: e.ParentTaskID, Text: flowText(e.Body), Files: e.Files}
	if e.Channel != "" {
		ch := e.Channel
		w.Channel = &ch
	}
	return w
}

// flowText is the body on one line, at most flowTextMax characters; a cut
// ends in an ellipsis.
func flowText(body string) string {
	line := strings.Join(strings.Fields(body), " ")
	if utf8.RuneCountInString(line) <= flowTextMax {
		return line
	}
	r := []rune(line)
	return strings.TrimRight(string(r[:flowTextMax-1]), " ") + "…"
}

func (s *Server) flowStore() (store.FlowEvents, bool) {
	fe, ok := s.o.Store.(store.FlowEvents)
	return fe, ok
}

// flowQuery parses GET /v1/view/flow's query (contract section 2).
func flowQuery(r *http.Request) (store.FlowQuery, bool) {
	v := r.URL.Query()
	q := store.FlowQuery{Limit: flowLimitDefault, Kind: v.Get("kind")}
	switch q.Kind {
	case "", store.FlowMention, store.FlowReply, store.FlowDM:
	default:
		return q, false
	}
	if l := v.Get("limit"); l != "" {
		n, err := strconv.Atoi(l)
		if err != nil || n < 1 || n > store.FlowMaxPage {
			return q, false
		}
		q.Limit = n
	}
	if b := v.Get("before"); b != "" {
		at, id, err := decCursor(b)
		if err != nil || !uuidRe.MatchString(id) {
			return q, false
		}
		q.BeforeAt, q.BeforeID = at, id
	}
	if v.Get("counts_only") == "true" {
		q.Limit = 0
	}
	return q, true
}

// handleViewFlow is GET /v1/view/flow: the member's page and counts in one
// store round trip.
func (s *Server) handleViewFlow(w http.ResponseWriter, r *http.Request) {
	r = r.WithContext(store.WithMemo(r.Context()))
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "the flow needs a signed-in member session")
		return
	}
	fe, ok := s.flowStore()
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "flow unavailable")
		return
	}
	q, valid := flowQuery(r)
	if !valid {
		writeErr(w, http.StatusBadRequest, "bad_query", "limit 1..50; kind mention|reply|dm; before a cursor")
		return
	}
	q.Tenant, q.Member, q.Now = t.ID, hum, s.o.Now()
	p, err := fe.FlowRead(r.Context(), q)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("flow read")
		writeErr(w, http.StatusInternalServerError, "internal", "flow unavailable")
		return
	}
	body := map[string]any{"counts": p.Counts, "unread": p.Unread}
	if r.URL.Query().Get("counts_only") != "true" {
		events := make([]wireFlowEvent, 0, len(p.Events))
		for _, e := range p.Events {
			events = append(events, wireFlow(e))
		}
		next := ""
		if p.More && len(p.Events) > 0 {
			last := p.Events[len(p.Events)-1]
			next = encCursor(last.At, last.MsgID)
		}
		body["events"], body["next"] = events, next
	}
	// No Cache-Control of its own: etagViews tags it `private, no-cache`, so
	// a repeat read of an unchanged flow is a 304 with no body (perf r4 G11).
	writeJSON(w, http.StatusOK, body)
}

// flowFrame is the `flow` WS frame (contract section 4).
func flowFrame(counts, unread store.FlowCounts, ev *store.FlowEvent) map[string]any {
	f := map[string]any{"type": "flow", "counts": counts, "unread": unread, "event": nil}
	if ev != nil {
		f["event"] = wireFlow(*ev)
	}
	return f
}

// flowSockets is the browser sockets this process holds per member of
// tenant, for the members who can get a flow event (human seats), minus skip.
func (s *Server) flowSockets(tenant string, skip ...string) map[string][]*wuiConn {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string][]*wuiConn{}
	for c := range s.wui {
		if c.tenant != tenant || c.member == "" || !store.IsFlowMember(c.member) || containsID(skip, c.member) {
			continue
		}
		out[c.member] = append(out[c.member], c)
	}
	return out
}

func containsID(xs []string, x string) bool {
	for _, v := range xs {
		if v != "" && v == x {
			return true
		}
	}
	return false
}

// fanoutFlow pushes the event a stored line gave each member with a socket
// here, with their fresh counts: one store round trip, and none when no
// other member of the tenant has a socket on this process (the author never
// gets an event). Called from fanoutWUI on every process.
func (s *Server) fanoutFlow(ctx context.Context, row store.Message) {
	fe, ok := s.flowStore()
	if !ok {
		return
	}
	socks := s.flowSockets(row.TenantID, row.FromID, row.TypedBy)
	if len(socks) == 0 {
		return
	}
	members := make([]string, 0, len(socks))
	for m := range socks {
		members = append(members, m)
	}
	go func() {
		ctx := context.WithoutCancel(ctx)
		pushes, err := fe.FlowFanout(ctx, row.TenantID, row.MsgID, members, s.o.Now())
		if err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", row.TenantID).Str("msg_id", row.MsgID).Msg("flow fan-out")
			return
		}
		for member, p := range pushes {
			frame := flowFrame(p.Counts, p.Unread, &p.Event)
			for _, c := range socks[member] {
				c.write(ctx, frame) //nolint:errcheck
			}
		}
	}()
}

// flowMarkWake reads the WUI-wake key of "member's marks moved" (store
// SaveReadMarks announces it): "f:<member>", never a msg id.
func flowMarkWake(key string) (string, bool) { return strings.CutPrefix(key, "f:") }

// pushFlowCounts sends member's sockets here a counts-only flow frame.
func (s *Server) pushFlowCounts(ctx context.Context, tenant, member string) {
	fe, ok := s.flowStore()
	if !ok {
		return
	}
	socks := s.flowSockets(tenant)[member]
	if len(socks) == 0 {
		return
	}
	p, err := fe.FlowRead(ctx, store.FlowQuery{Tenant: tenant, Member: member, Now: s.o.Now()})
	if err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Msg("flow counts push")
		return
	}
	frame := flowFrame(p.Counts, p.Unread, nil)
	for _, c := range socks {
		c.write(ctx, frame) //nolint:errcheck
	}
}
