package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The agent context lifecycle (spec 063 sections 11 and 12, rdb 0105).
//
// Admin side, gated on tenant.settings like the rest of Workspace settings:
//
//	GET   /v1/tenant/agent-lifecycle          the config in force, what is stored, the key table
//	PATCH /v1/tenant/agent-lifecycle          {key: int | null} (null = reset to default)
//	GET   /v1/tenant/agent-lifecycle/events   ?since=<RFC3339 | Go duration back>&limit=<1..200>
//
// Box side, over the authenticated hello on a one-shot role=cli session (the
// `spool lane` path; the writing box comes from the session, never the frame):
//
//	lane_op lifecycle_config  the config in force (what `spool lifecycle config` prints)
//	lane_op lifecycle_event   append one event (`spool lifecycle event`)
//
// The event log is off every hot path (spec 063 12.1): nothing here runs on a
// send, a hello or a WUI view read.

// lifecycleEventSkew is how far ahead of the hub's clock a box's event may be
// stamped; a resent event from the box's local spool is older, never newer.
const lifecycleEventSkew = 5 * time.Minute

func (s *Server) routeAgentLifecycle(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/tenant/agent-lifecycle", s.handleAgentLifecycle)
	mux.HandleFunc("PATCH /v1/tenant/agent-lifecycle", s.handlePatchAgentLifecycle)
	mux.HandleFunc("GET /v1/tenant/agent-lifecycle/events", s.handleAgentLifecycleEvents)
	mux.HandleFunc("OPTIONS /v1/tenant/agent-lifecycle", s.tenantSettingsPreflight)
	mux.HandleFunc("OPTIONS /v1/tenant/agent-lifecycle/events", s.tenantSettingsPreflight)
}

// sweepAgentLifecycle is the 90-day retention of the event log, on the hub's
// retention sweep.
func (s *Server) sweepAgentLifecycle(ctx context.Context) {
	al, ok := s.o.Store.(store.AgentLifecycle)
	if !ok {
		return
	}
	n, err := al.PruneLifecycleEvents(ctx, s.o.Now().Add(-store.LifecycleRetention))
	if err != nil {
		s.o.Log.Error().Err(err).Msg("agent_lifecycle_events retention sweep")
		return
	}
	if n > 0 {
		s.o.Log.Info().Int("pruned", n).Msg("agent_lifecycle_events retention sweep")
	}
}

// agentLifecycleActor is the tenant.settings check plus the store. ok=false:
// it answered.
func (s *Server) agentLifecycleActor(w http.ResponseWriter, r *http.Request) (store.Tenant, rbac.Access, store.AgentLifecycle, bool) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return t, a, nil, false
	}
	al, ok := s.o.Store.(store.AgentLifecycle)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no agent lifecycle config")
		return t, a, nil, false
	}
	return t, a, al, true
}

// agentLifecycleBody is the config answer, on HTTP and on the box frame.
type agentLifecycleBody struct {
	TenantID  string               `json:"tenant_id"`
	Config    map[string]any       `json:"config"` // every key, the value in force
	Stored    map[string]any       `json:"stored"` // every key, null = the default
	Keys      []store.LifecycleKey `json:"keys"`
	UpdatedBy string               `json:"updated_by"`
	UpdatedAt string               `json:"updated_at"` // "" = never set
}

func lifecycleBody(tenant string, c store.LifecycleConfig) agentLifecycleBody {
	b := agentLifecycleBody{TenantID: tenant, Config: c.Effective(), Stored: map[string]any{},
		Keys: store.LifecycleKeys, UpdatedBy: c.UpdatedBy}
	for _, k := range store.LifecycleKeys {
		b.Stored[k.Key] = c.Stored[k.Key] // absent = nil = null
	}
	if !c.UpdatedAt.IsZero() {
		b.UpdatedAt = c.UpdatedAt.UTC().Format(time.RFC3339)
	}
	return b
}

// GET /v1/tenant/agent-lifecycle
func (s *Server) handleAgentLifecycle(w http.ResponseWriter, r *http.Request) {
	t, _, al, ok := s.agentLifecycleActor(w, r)
	if !ok {
		return
	}
	c, err := al.AgentLifecycleConfig(r.Context(), t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("agent lifecycle config")
		writeErr(w, http.StatusInternalServerError, "internal", "agent lifecycle config unavailable")
		return
	}
	writeJSON(w, http.StatusOK, lifecycleBody(t.ID, c))
}

// PATCH /v1/tenant/agent-lifecycle {key: int | enum string | null, ...}
func (s *Server) handlePatchAgentLifecycle(w http.ResponseWriter, r *http.Request) {
	t, a, al, ok := s.agentLifecycleActor(w, r)
	if !ok {
		return
	}
	var body map[string]json.RawMessage
	if !decodeMembers(w, r, &body) {
		return
	}
	if len(body) == 0 {
		writeErr(w, http.StatusBadRequest, "bad_setting", "name at least one key: {key: value | null}")
		return
	}
	p := store.LifecyclePatch{}
	for k, raw := range body {
		if strings.TrimSpace(string(raw)) == "null" {
			p[k] = nil
			continue
		}
		kd, known := store.LifecycleKeyByName(k)
		if !known {
			writeErr(w, http.StatusBadRequest, "bad_setting", k+" is not a lifecycle key")
			return
		}
		if kd.Enum != nil {
			var v string
			if err := json.Unmarshal(raw, &v); err != nil {
				writeErr(w, http.StatusBadRequest, "bad_setting", k+" must be "+kd.Range()+" or null")
				return
			}
			p[k] = v
			continue
		}
		var v int
		if err := json.Unmarshal(raw, &v); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_setting", k+" must be a whole number or null")
			return
		}
		p[k] = v
	}
	if k, why := store.CheckLifecyclePatch(p); k != "" {
		writeErr(w, http.StatusBadRequest, "bad_setting", k+" "+why)
		return
	}
	_, cur, err := al.PatchAgentLifecycleConfig(r.Context(), t.ID, p, a.HumanID, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("agent lifecycle patch")
		writeErr(w, http.StatusInternalServerError, "internal", "agent lifecycle config not saved")
		return
	}
	keys := make([]string, 0, len(p))
	for k := range p {
		keys = append(keys, k)
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Strs("keys", keys).Msg("tenant.agent_lifecycle_changed")
	writeJSON(w, http.StatusOK, lifecycleBody(t.ID, cur))
}

// GET /v1/tenant/agent-lifecycle/events?since=&limit=
func (s *Server) handleAgentLifecycleEvents(w http.ResponseWriter, r *http.Request) {
	t, _, al, ok := s.agentLifecycleActor(w, r)
	if !ok {
		return
	}
	now := s.o.Now()
	since := now.Add(-24 * time.Hour)
	if v := r.URL.Query().Get("since"); v != "" {
		if at, err := time.Parse(time.RFC3339, v); err == nil {
			since = at
		} else if d, err := time.ParseDuration(v); err == nil && d > 0 {
			since = now.Add(-d)
		} else {
			writeErr(w, http.StatusBadRequest, "bad_query", "since is an RFC 3339 time or a duration back from now (24h, 168h)")
			return
		}
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > store.LifecycleEventsMax {
			writeErr(w, http.StatusBadRequest, "bad_query", "limit is 1..200")
			return
		}
		limit = n
	}
	evs, err := al.ListLifecycleEvents(r.Context(), t.ID, since, limit)
	if err == nil {
		var ag []store.LifecycleAggregate
		if ag, err = al.LifecycleAggregates(r.Context(), t.ID, since); err == nil {
			if ag == nil {
				ag = []store.LifecycleAggregate{}
			}
			writeJSON(w, http.StatusOK, map[string]any{"since": since.UTC().Format(time.RFC3339), "limit": limit,
				"events": evs, "aggregates": ag})
			return
		}
	}
	s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("agent lifecycle events")
	writeErr(w, http.StatusInternalServerError, "internal", "agent lifecycle events unavailable")
}

// isLifecycleLaneOp routes a lane frame to onLifecycleLane.
func isLifecycleLaneOp(op string) bool { return strings.HasPrefix(op, "lifecycle_") }

// onLifecycleLane answers a lifecycle lane frame; the reply rides the lane
// field of a lane frame, as the lane map's does.
func (s *Server) onLifecycleLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxLifecycle(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: f.LaneOp, Fleet: f.Fleet, Lane: raw}) //nolint:errcheck
}

func (s *Server) boxLifecycle(ctx context.Context, x *session, f wire.Frame) (any, *issueErr) {
	al, ok := s.o.Store.(store.AgentLifecycle)
	if !ok {
		return nil, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no agent lifecycle config"}
	}
	switch f.LaneOp {
	case "lifecycle_config":
		c, err := al.AgentLifecycleConfig(ctx, x.tenant)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", x.tenant).Msg("agent lifecycle config (box)")
			return nil, &issueErr{http.StatusInternalServerError, "internal", "agent lifecycle config unavailable"}
		}
		return lifecycleBody(x.tenant, c), nil
	case "lifecycle_event":
		var e store.LifecycleEvent
		dec := json.NewDecoder(bytes.NewReader(f.Lane))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&e); err != nil {
			return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane must be one lifecycle event object"}
		}
		now := s.o.Now()
		switch {
		case e.At.IsZero():
			e.At = now
		case e.At.After(now.Add(lifecycleEventSkew)) || e.At.Before(now.Add(-store.LifecycleRetention)):
			return nil, &issueErr{http.StatusBadRequest, "bad_frame", "at must be within the last 90 days"}
		}
		if e.Fleet == "" {
			e.Fleet = f.Fleet
		}
		if e.Event == "config_change" {
			return nil, &issueErr{http.StatusBadRequest, "bad_frame", "config_change is written by the hub only"}
		}
		e.WriterBox = x.box
		if why := store.CheckLifecycleEvent(e); why != "" {
			return nil, &issueErr{http.StatusBadRequest, "bad_frame", why}
		}
		if err := al.AppendLifecycleEvent(ctx, x.tenant, e); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("agent lifecycle event")
			return nil, &issueErr{http.StatusInternalServerError, "internal", "agent lifecycle event not stored"}
		}
		return map[string]any{"ok": true, "at": e.At.UTC().Format(time.RFC3339Nano), "writer_box": e.WriterBox}, nil
	}
	return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane_op must be lifecycle_config or lifecycle_event"}
}
