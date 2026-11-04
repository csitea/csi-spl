package hub

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A lane's live console (spec 153 section 3.18, SPL-4810, rdb 0261; owner
// HUM-10, t1 27162335, msgs 038fa412, 8dd53bd9 and 3b2ba6f3): the lane's
// tmux screen, on demand, for the readers of the Lanes tab who may see it.
//
// Browser side, one pair per door of the Lanes tab:
//
//	POST /v1/operator/lane-console {agent_id, agent_box, fleet?}  watch: the demand, then the console
//	GET  /v1/operator/lane-console?agent_id=&agent_box=&fleet=    the console
//	POST /v1/lanes/console         {agent_id, agent_box, fleet?}
//	GET  /v1/lanes/console?agent_id=&agent_box=&fleet=
//
// Who may: the operator door is an admin of the operator workspace
// (operatorActor; never the service account), the lanes door the owner or
// an admin of the caller's workspace (3.6's gate). Then the lane itself must
// be a live row of the SAME view that door reads (fleetLanesView,
// workspaceLanesView), or 404: a reader opens only a lane its Lanes tab
// shows. A workspace reader never learns an operator box: its view sends
// agent_box "" for those lanes, and so does this answer.
//
// The demand lasts laneConsoleDemand; the page re-posts every 20 s while the
// feed shows. Box side (file_streams.go routes the ops here): the box pulls
// the agents of its own box with a demand on (file_streams_console_demands)
// and pushes each one's screen, masked on the box
// (file_streams_console_push); a push with no demand on is 409 not_demanded.
// The box and the workspace are the session's, never the frame's.

const (
	laneConsoleDemand = 60 * time.Second
	// laneConsoleFresh: a capture older than this reads as stale
	laneConsoleFresh = 15 * time.Second
	// laneConsoleResolved is how long a GET reuses the lane's resolution
	laneConsoleResolved = 30 * time.Second
	laneConsoleBodyMax  = 2 << 10
)

func (s *Server) routeLaneConsole(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/lane-console", s.handleLaneConsole(true, true))
	mux.HandleFunc("GET /v1/operator/lane-console", s.handleLaneConsole(true, false))
	mux.HandleFunc("OPTIONS /v1/operator/lane-console", s.operatorWorkspacesPreflight)
	mux.HandleFunc("POST /v1/lanes/console", s.handleLaneConsole(false, true))
	mux.HandleFunc("GET /v1/lanes/console", s.handleLaneConsole(false, false))
	mux.HandleFunc("OPTIONS /v1/lanes/console", s.operatorWorkspacesPreflight)
}

// laneConsoleTarget is where a lane's console row lives: the box's
// workspace, the box, the agent.
type laneConsoleTarget struct{ tenant, box, agent string }

// laneConsoleAsk is one request: the door, the caller and the lane.
type laneConsoleAsk struct {
	operator          bool
	tenant, hum       string
	fleet, agent, box string
}

type laneConsoleJSON struct {
	AgentID     string           `json:"agent_id"`
	AgentBox    string           `json:"agent_box"`
	State       string           `json:"state"` // waiting | live | stale
	Screen      string           `json:"screen"`
	Lines       int              `json:"lines"`
	Redactions  map[string]int64 `json:"redactions"`
	CapturedAt  string           `json:"captured_at"`
	AgeS        int64            `json:"age_s"`
	DemandUntil string           `json:"demand_until"`
}

func (s *Server) handleLaneConsole(operator, watch bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ask, ok := s.laneConsoleCaller(w, r, operator, watch)
		if !ok {
			return
		}
		cs, ok := s.o.Store.(store.LaneConsoleStore)
		if !ok {
			writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no lane console")
			return
		}
		tg, found, err := s.laneConsoleResolve(r.Context(), ask, watch)
		switch {
		case err != nil:
			s.o.Log.Error().Err(err).Str("agent", ask.agent).Msg("lane console resolve")
			writeErr(w, http.StatusInternalServerError, "internal", "lane map unavailable")
			return
		case !found:
			writeErr(w, http.StatusNotFound, "not_found", "no live lane "+ask.agent+" on your Lanes tab")
			return
		}
		now := s.o.Now().UTC()
		var c store.LaneConsole
		if watch {
			c, err = cs.DemandLaneConsole(r.Context(), tg.tenant, tg.box, tg.agent, ask.hum, now.Add(laneConsoleDemand), now)
		} else if c, err = cs.LaneConsoleOf(r.Context(), tg.tenant, tg.box, tg.agent); errors.Is(err, store.ErrNotFound) {
			c, err = store.LaneConsole{AgentID: tg.agent}, nil
		}
		if err != nil {
			s.o.Log.Error().Err(err).Str("agent", ask.agent).Msg("lane console")
			writeErr(w, http.StatusInternalServerError, "internal", "lane console unavailable")
			return
		}
		writeJSON(w, http.StatusOK, laneConsoleBody(c, ask, now))
	}
}

// laneConsoleCaller is the door's gate and the request's lane; false after
// the answer.
func (s *Server) laneConsoleCaller(w http.ResponseWriter, r *http.Request, operator, watch bool) (laneConsoleAsk, bool) {
	var ask laneConsoleAsk
	if operator {
		a, ok := s.operatorActor(w, r)
		if !ok {
			return ask, false
		}
		ask = laneConsoleAsk{operator: true, tenant: a.tenant, hum: a.hum}
	} else {
		s.allowOrigin(w, r)
		w.Header().Set("Cache-Control", "no-store")
		t, hum, ok := s.humanTenant(w, r)
		if !ok {
			return ask, false
		}
		if a, err := s.access(r.Context(), hum, t.ID); hum == "" || err != nil || !(a.TenantOwner || a.Has(rbac.Admin)) {
			writeForbidden(w, permWorkspaceLanes, "only the workspace owner or an admin sees a lane's console")
			return ask, false
		}
		ask = laneConsoleAsk{tenant: t.ID, hum: hum}
	}
	if watch {
		var req struct {
			AgentID  string `json:"agent_id"`
			AgentBox string `json:"agent_box"`
			Fleet    string `json:"fleet"`
		}
		if !readJSONStrict(w, r, &req, laneConsoleBodyMax, `invalid JSON body (expected {"agent_id", "agent_box", "fleet"})`) {
			return ask, false
		}
		ask.agent, ask.box, ask.fleet = req.AgentID, req.AgentBox, req.Fleet
	} else {
		q := r.URL.Query()
		ask.agent, ask.box, ask.fleet = q.Get("agent_id"), q.Get("agent_box"), q.Get("fleet")
	}
	if ask.fleet == "" {
		ask.fleet = fleetLanesFleet
	}
	switch {
	case !store.FleetNameRe.MatchString(ask.fleet):
		writeErr(w, http.StatusBadRequest, "bad_query", "fleet must be a lowercase slug ([a-z0-9-], up to 32)")
		return ask, false
	case !wire.LaneConsoleAgentRe.MatchString(ask.agent):
		writeErr(w, http.StatusBadRequest, "bad_query", "agent_id must be an agent id")
		return ask, false
	case len(ask.box) > 200 || (ask.operator && ask.box == ""):
		writeErr(w, http.StatusBadRequest, "bad_query", "agent_box must name the lane's box")
		return ask, false
	}
	return ask, true
}

func laneConsoleBody(c store.LaneConsole, ask laneConsoleAsk, now time.Time) laneConsoleJSON {
	out := laneConsoleJSON{AgentID: ask.agent, AgentBox: ask.box, State: "waiting", Screen: c.Screen,
		Lines: c.Lines, Redactions: c.Redactions}
	if out.Redactions == nil {
		out.Redactions = map[string]int64{}
	}
	if !c.DemandUntil.IsZero() {
		out.DemandUntil = c.DemandUntil.UTC().Format(time.RFC3339)
	}
	if c.CapturedAt != nil {
		age := now.Sub(*c.CapturedAt)
		out.CapturedAt, out.AgeS, out.State = c.CapturedAt.UTC().Format(time.RFC3339), int64(age/time.Second), "live"
		if age > laneConsoleFresh {
			out.State = "stale"
		}
	}
	return out
}

// laneConsoleResolved caches a resolution for the GETs that follow a
// watch: the views are many reads, the GET comes every 2 s.
type laneConsoleCacheKey struct {
	s   *Server
	ask laneConsoleAsk
}

type laneConsoleCached struct {
	tg  laneConsoleTarget
	exp time.Time
}

var laneConsoleCache = struct {
	sync.Mutex
	m map[laneConsoleCacheKey]laneConsoleCached
}{m: map[laneConsoleCacheKey]laneConsoleCached{}}

// laneConsoleResolve is where ask's lane lives, false when the door's view
// shows no live lane of that name. A watch always reads the view afresh.
func (s *Server) laneConsoleResolve(ctx context.Context, ask laneConsoleAsk, watch bool) (laneConsoleTarget, bool, error) {
	key, now := laneConsoleCacheKey{s, ask}, s.o.Now()
	laneConsoleCache.Lock()
	hit, ok := laneConsoleCache.m[key]
	laneConsoleCache.Unlock()
	if ok && !watch && now.Before(hit.exp) {
		return hit.tg, true, nil
	}
	resolve := s.workspaceLaneConsoleTarget
	if ask.operator {
		resolve = s.operatorLaneConsoleTarget
	}
	tg, found, err := resolve(ctx, ask)
	laneConsoleCache.Lock()
	defer laneConsoleCache.Unlock()
	for k, v := range laneConsoleCache.m {
		if !now.Before(v.exp) {
			delete(laneConsoleCache.m, k)
		}
	}
	if found && err == nil {
		laneConsoleCache.m[key] = laneConsoleCached{tg, now.Add(laneConsoleResolved)}
	} else {
		delete(laneConsoleCache.m, key)
	}
	return tg, found, err
}

// operatorLaneConsoleTarget: the lane is a live row of the operator view;
// its box is the operator workspace's when the operator's own lane map
// holds it, else the row's workspace's (3.17, a workspace's own box).
func (s *Server) operatorLaneConsoleTarget(ctx context.Context, ask laneConsoleAsk) (laneConsoleTarget, bool, error) {
	v, err := s.fleetLanesView(ctx, ask.tenant, ask.fleet, ask.hum)
	if err != nil {
		return laneConsoleTarget{}, false, err
	}
	row, found := laneConsoleRow(v, ask.agent, ask.box)
	if !found {
		return laneConsoleTarget{}, false, nil
	}
	ls, err := s.o.Store.ListFleetLanes(ctx, ask.tenant, ask.fleet, s.o.Now())
	if err != nil {
		return laneConsoleTarget{}, false, err
	}
	tenant := row.Workspace
	for _, l := range ls {
		if l.AgentID == ask.agent && l.AgentBox == ask.box {
			tenant = ask.tenant
		}
	}
	return laneConsoleTarget{tenant, ask.box, ask.agent}, tenant != "", nil
}

// workspaceLaneConsoleTarget: the lane is a live row of the workspace's
// view; a row with a box is the workspace's own lane (3.17), a row without
// one an operator lane on its topic, whose box the operator's active lanes
// name (never sent back).
func (s *Server) workspaceLaneConsoleTarget(ctx context.Context, ask laneConsoleAsk) (laneConsoleTarget, bool, error) {
	v, err := s.workspaceLanesView(ctx, ask.tenant, ask.fleet, ask.hum)
	if err != nil {
		return laneConsoleTarget{}, false, err
	}
	row, found := laneConsoleRow(v, ask.agent, ask.box)
	switch {
	case !found:
		return laneConsoleTarget{}, false, nil
	case ask.box != "":
		return laneConsoleTarget{ask.tenant, ask.box, ask.agent}, true, nil
	}
	op, err := s.operatorTenant(ctx)
	if err != nil || op == "" {
		return laneConsoleTarget{}, false, err
	}
	_, active, _, err := s.activeFleetLanes(ctx, op, ask.fleet)
	if err != nil {
		return laneConsoleTarget{}, false, err
	}
	for _, l := range active {
		if l.AgentID == ask.agent && l.Topic != "" && l.Topic == row.TopicID {
			return laneConsoleTarget{op, l.AgentBox, ask.agent}, true, nil
		}
	}
	return laneConsoleTarget{}, false, nil
}

// laneConsoleRow is the view's live row of agent at box.
func laneConsoleRow(v fleetLanesViewJSON, agent, box string) (fleetLaneViewJSON, bool) {
	for _, l := range v.Lanes {
		if l.AgentID == agent && l.AgentBox == box && l.State != "queued" {
			return l, true
		}
	}
	return fleetLaneViewJSON{}, false
}

// laneConsoleLane answers the box's two console ops (file_streams.go).
func (s *Server) laneConsoleLane(ctx context.Context, x *session, f wire.Frame, now time.Time) (*wire.FileStreamsAckFrame, *issueErr) {
	cs, ok := s.o.Store.(store.LaneConsoleStore)
	if !ok {
		return nil, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no lane console"}
	}
	ack := &wire.FileStreamsAckFrame{Type: "ack", LaneOp: f.LaneOp, At: now.Format(time.RFC3339)}
	if f.LaneOp == wire.FileStreamsConsoleDemandsOp {
		if err := wire.DecodeFileStreamsGlobsPull(f.Lane); err != nil {
			return nil, &issueErr{http.StatusBadRequest, "bad_file_stream", err.Error()}
		}
		agents, err := cs.LaneConsoleDemands(ctx, x.tenant, x.box, now)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("lane console demands")
			return nil, &issueErr{http.StatusInternalServerError, "internal", "lane console demands not read"}
		}
		ack.Agents = &agents
		return ack, nil
	}
	p, err := wire.DecodeLaneConsolePush(f.Lane)
	switch {
	case errors.Is(err, wire.ErrFileStreamTooLarge):
		return nil, &issueErr{http.StatusRequestEntityTooLarge, "too_large", err.Error()}
	case err != nil:
		return nil, &issueErr{http.StatusBadRequest, "bad_file_stream", err.Error()}
	}
	err = cs.PutLaneConsole(ctx, x.tenant, x.box, store.LaneConsoleShot{AgentID: p.AgentID, Screen: p.Screen,
		Lines: p.Lines, Redactions: p.Redactions}, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return nil, &issueErr{http.StatusConflict, "not_demanded", "nobody watches " + p.AgentID + "'s console on this box now"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("lane console push")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "lane console not stored"}
	}
	ack.Inserted = 1
	return ack, nil
}
