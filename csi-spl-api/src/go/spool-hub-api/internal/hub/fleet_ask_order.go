package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The order of the spawn queue (spec 153 sections 3.22.6-3.22.7, row Q2,
// SPL-6396, rdb 0323): a queued request's own priority and its dragged
// place in the line, on the operator workspace's fleet asks.
//
//	PUT /v1/operator/fleet-asks/{ask_id}/priority?fleet=  {"priority": 1..5}
//	PUT /v1/operator/fleet-asks/{ask_id}/position?fleet=  {"before": <ask_id>|null, "after": <ask_id>|null}
//
// Who may: an admin of the operator workspace (operatorActor), else 403. 404
// unknown_ask for no such ask in the fleet (default main); 409 not_queued
// once it is placed or closed; 400 bad_json for a priority outside 1..5 or a
// neighbour that is not an ask id. A priority write clears the row's rank.
// before is the ask the row now follows (directly above it), after the ask
// it now precedes (directly below it), as the page saw them; null = the top
// or the bottom. Neighbours no longer adjacent or no longer queued: 409
// stale_position, nothing changed. The moved row takes the priority of the
// row it now sits directly above (of the row above it when it lands last)
// as its own; store.askPlanMove ranks it. Both answer {"ask": <the row as a
// list reads it, with its position>}, and each change writes one row of the
// operator workspace's log (queue.priority_set / queue.position_set) with
// who and the old and new value.
//
// The agents' door is ask_op position on a box session (askPosition): the
// dispatch holder moves a row when the owner asks in words, with the
// owner's msg id required and recorded in rank_by (as SPAWN_BYPASS records
// flag_msg). There is no agent door to the priority.

const (
	logKindQueuePriority = "queue.priority_set"
	logKindQueuePosition = "queue.position_set"
)

func (s *Server) routeFleetAskOrder(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/operator/fleet-asks/{ask_id}/priority", s.handleFleetAskPriority)
	mux.HandleFunc("PUT /v1/operator/fleet-asks/{ask_id}/position", s.handleFleetAskPosition)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-asks/{ask_id}/priority", s.fleetAskOrderPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-asks/{ask_id}/position", s.fleetAskOrderPreflight)
}

func (s *Server) fleetAskOrderPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PUT")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// fleetAskOrderReq is one resolved order PUT: the operator admin, the order
// store, the fleet and the ask.
type fleetAskOrderReq struct {
	a     opActor
	st    store.FleetAskOrder
	fleet string
	ask   string
}

// fleetAskOrderCaller resolves who asks and which ask; false has answered.
func (s *Server) fleetAskOrderCaller(w http.ResponseWriter, r *http.Request) (fleetAskOrderReq, bool) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return fleetAskOrderReq{}, false
	}
	q := fleetAskOrderReq{a: a, fleet: r.URL.Query().Get("fleet"), ask: r.PathValue("ask_id")}
	if q.fleet == "" {
		q.fleet = fleetLanesFleet
	}
	if q.st, ok = s.o.Store.(store.FleetAskOrder); !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no queue order")
		return q, false
	}
	switch {
	case !store.FleetNameRe.MatchString(q.fleet):
		writeErr(w, http.StatusBadRequest, "bad_query", "fleet must be a lowercase slug ([a-z0-9-], up to 32)")
	case !store.AskIDRe.MatchString(q.ask):
		writeErr(w, http.StatusNotFound, "unknown_ask", "no such ask in this fleet")
	default:
		return q, true
	}
	return q, false
}

// fleetAskOld is the ask's effective priority and position before a change
// (for the log; 0 when the list did not hold it).
func (s *Server) fleetAskOld(ctx context.Context, q fleetAskOrderReq) store.FleetAsk {
	as, err := s.o.Store.ListFleetAsks(ctx, q.a.tenant, q.fleet, "", false, s.o.Now())
	if err == nil {
		for _, a := range as {
			if a.AskID == q.ask {
				return a
			}
		}
	}
	return store.FleetAsk{}
}

// PUT /v1/operator/fleet-asks/{ask_id}/priority
func (s *Server) handleFleetAskPriority(w http.ResponseWriter, r *http.Request) {
	q, ok := s.fleetAskOrderCaller(w, r)
	if !ok {
		return
	}
	prio, ok := priorityBody(w, r)
	if !ok {
		return
	}
	old := s.fleetAskOld(r.Context(), q)
	got, err := q.st.SetFleetAskPriority(r.Context(), q.a.tenant,
		store.AskPrioritySet{Fleet: q.fleet, AskID: q.ask, By: q.a.hum, Priority: prio}, s.o.Now().UTC())
	if !s.fleetAskOrderErr(w, q, err) {
		return
	}
	s.fleetAskOrderLog(r.Context(), q, logKindQueuePriority, "priority "+strconv.Itoa(old.Priority)+" -> "+strconv.Itoa(got.Priority))
	writeJSON(w, http.StatusOK, map[string]any{"ask": askRow(got)})
}

// PUT /v1/operator/fleet-asks/{ask_id}/position
func (s *Server) handleFleetAskPosition(w http.ResponseWriter, r *http.Request) {
	q, ok := s.fleetAskOrderCaller(w, r)
	if !ok {
		return
	}
	var in struct {
		Before *string `json:"before"`
		After  *string `json:"after"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10))
	if err := dec.Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", `body must be {"before": <ask_id>|null, "after": <ask_id>|null}`)
		return
	}
	m := store.AskMove{Fleet: q.fleet, AskID: q.ask, By: q.a.hum, Before: deref(in.Before), After: deref(in.After)}
	if why := checkAskMove(m); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_json", why)
		return
	}
	old := s.fleetAskOld(r.Context(), q)
	got, err := q.st.MoveFleetAsk(r.Context(), q.a.tenant, m, s.o.Now().UTC())
	if !s.fleetAskOrderErr(w, q, err) {
		return
	}
	s.fleetAskOrderLog(r.Context(), q, logKindQueuePosition, "position "+strconv.Itoa(old.Position)+" -> "+
		strconv.Itoa(got.Position)+", priority "+strconv.Itoa(old.Priority)+" -> "+strconv.Itoa(got.Priority))
	writeJSON(w, http.StatusOK, map[string]any{"ask": askRow(got)})
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return strings.ToLower(strings.TrimSpace(*p))
}

// checkAskMove names the first thing wrong with a move's neighbours ("" = fine).
func checkAskMove(m store.AskMove) string {
	for _, n := range []string{m.Before, m.After} {
		if n != "" && !store.AskIDRe.MatchString(n) {
			return "before and after must be ask ids (lowercase UUIDs) or null"
		}
		if n == m.AskID {
			return "a row is not its own neighbour"
		}
	}
	if m.Before != "" && m.Before == m.After {
		return "before and after must differ"
	}
	return ""
}

// fleetAskOrderErr answers a store error; true = none.
func (s *Server) fleetAskOrderErr(w http.ResponseWriter, q fleetAskOrderReq, err error) bool {
	switch {
	case err == nil:
		return true
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_ask", "no such ask in this fleet")
	case errors.Is(err, store.ErrAskNotQueued):
		writeErr(w, http.StatusConflict, "not_queued", "the ask is no longer queued: it was placed or closed")
	case errors.Is(err, store.ErrStalePosition):
		writeErr(w, http.StatusConflict, "stale_position", "the queue changed: the neighbours are no longer adjacent or queued; re-read it")
	default:
		s.o.Log.Error().Err(err).Str("fleet", q.fleet).Str("ask", q.ask).Msg("fleet ask order")
		writeErr(w, http.StatusInternalServerError, "internal", "asks unavailable")
	}
	return false
}

// fleetAskOrderLog writes the change to the operator workspace's log.
func (s *Server) fleetAskOrderLog(ctx context.Context, q fleetAskOrderReq, kind, change string) {
	s.o.Log.Info().Str("tenant", q.a.tenant).Str("fleet", q.fleet).Str("ask", q.ask).Str("by", q.a.hum).
		Str("change", change).Msg(kind)
	s.workspaceEvent(ctx, q.a.tenant, store.LogEvent{Kind: kind, Actor: q.a.hum,
		Message: "ask " + q.ask + " " + change, OriginKind: store.LogOriginComponent, OriginRef: "queue"})
}

// askPositionReq is an ask_op position frame's Ask object.
type askPositionReq struct {
	AskID    string  `json:"ask_id"`
	By       string  `json:"by"`
	Before   *string `json:"before"`
	After    *string `json:"after"`
	OwnerMsg string  `json:"owner_msg"`
}

// askPosition is ask_op position: the dispatch holder's move on the owner's
// word. rank_by and priority_by record "<by> msg <owner_msg>".
func (s *Server) askPosition(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in askPositionReq
	if err := json.Unmarshal(f.Ask, &in); err != nil {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be {ask_id, by, before, after, owner_msg}"}
	}
	var ae *issueErr
	if in.By, ae = s.resolveAgent(ctx, x.tenant, in.By, ""); ae != nil {
		return askAnswer{}, ae
	}
	in.By = store.AskAtBox(in.By, x.box)
	m := store.AskMove{Fleet: f.Fleet, AskID: in.AskID, Before: deref(in.Before), After: deref(in.After)}
	switch {
	case !store.ValidAskAgent(in.By) || in.By == "":
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "by must be the acting agent, <ID>@<box>"}
	case !store.AskIDRe.MatchString(in.OwnerMsg):
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "owner_msg must be the owner message id that asked for the move (a lowercase UUID)"}
	case !store.AskIDRe.MatchString(in.AskID):
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask_id must be a lowercase UUID"}
	}
	if why := checkAskMove(m); why != "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	st, ok := s.o.Store.(store.FleetAskOrder)
	if !ok {
		return askAnswer{}, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no queue order"}
	}
	m.By = in.By + " msg " + in.OwnerMsg
	got, err := st.MoveFleetAsk(ctx, x.tenant, m, s.o.Now().UTC())
	switch {
	case errors.Is(err, store.ErrNotFound):
		return askAnswer{}, &issueErr{http.StatusNotFound, "unknown_ask", "no such ask in this fleet"}
	case errors.Is(err, store.ErrAskNotQueued):
		return askAnswer{}, &issueErr{http.StatusConflict, "not_queued", "the ask is no longer queued"}
	case errors.Is(err, store.ErrStalePosition):
		return askAnswer{}, &issueErr{http.StatusConflict, "stale_position", "the neighbours are no longer adjacent or queued; re-read the queue"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("ask", in.AskID).Msg("fleet ask position")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("ask", got.AskID).
		Str("by", m.By).Int("position", got.Position).Int("priority", got.Priority).Msg(logKindQueuePosition)
	return askAnswer{Fleet: f.Fleet, Asks: []AskRow{askRow(got)}}, nil
}
