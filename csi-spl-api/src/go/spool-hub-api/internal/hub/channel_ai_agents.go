package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The per-channel "AI agents" switch (SPL-1684, rdb 0189; owner decision in
// a workspace poll: on with a button per channel, off by default there).
//
// Off, a channel's posts reach no agent through the channel: routeChannel
// builds no member box delivery, recvAgents drops a queued member row, the
// back-fill leaves the seats pending, and the fallback / escalation does not
// hand the post to a responder. What still goes is the direct leg: a DM to an
// agent and an "@agent ..." dispatch (msg.to, env.to_box), which commitRow
// enqueues before any channel routing. The unanswered sweep reads the same
// switch from the database (spl-unanswered-sweep.func.sh).
//
// The value in force is the channel's own (channels.ai_agents), else the
// workspace default (tenants.settings channel_ai_agents), else ON. A store
// that keeps no switch, or a read error, is ON: the posts flow as before.

func (s *Server) routeChannelAIAgents(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/channels/{channel}/ai-agents", s.handlePutChannelAIAgents)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/ai-agents", s.channelAIAgentsPreflight)
}

// channelAgentsOn is the switch in force for channel ("" = a DM: always on).
func (s *Server) channelAgentsOn(ctx context.Context, tenant, channel string) bool {
	if channel == "" {
		return true
	}
	if ca, ok := s.o.Store.(store.ChannelAIAgents); ok {
		on, err := ca.ChannelAIAgents(ctx, tenant, channel)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", channel).Msg("channel ai_agents: kept on")
			return true
		}
		if on != nil {
			return *on
		}
	}
	t, err := s.o.Store.GetTenant(ctx, tenant)
	if err != nil {
		return true
	}
	return t.ChannelAIAgentsDefault()
}

// mayChannelAIAgents is who may flip the switch: the channel's creator, or a
// workspace admin (tenant.settings). A default channel has no creator.
func (s *Server) mayChannelAIAgents(ctx context.Context, tenant, createdBy, hum string) bool {
	return channelOwner(createdBy, hum) || s.allowed(ctx, hum, tenant, rbac.TenantSettings)
}

// PUT /v1/channels/{channel}/ai-agents {"on": true|false|null}; null = back
// to the workspace default. Answers {channel, on, ai_agents_off}.
func (s *Server) handlePutChannelAIAgents(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	ca, has := s.o.Store.(store.ChannelAIAgents)
	if !has {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no AI agents switch")
		return
	}
	row, ok := s.channelRecord(w, r, t.ID, ch)
	if !ok {
		return
	}
	if !s.mayChannelAIAgents(r.Context(), t.ID, row.CreatedBy, hum) {
		writeForbidden(w, rbac.TenantSettings, "only the channel owner or a workspace admin may switch its AI agents")
		return
	}
	on, ok := aiAgentsBody(w, r)
	if !ok {
		return
	}
	switch err := ca.SetChannelAIAgents(r.Context(), t.ID, ch, on, s.o.Now()); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+ch+" in this tenant")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel setting not stored")
		return
	}
	inForce := s.channelAgentsOn(r.Context(), t.ID, ch)
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("by", hum).Bool("ai_agents", inForce).Msg("channel ai_agents")
	writeJSON(w, http.StatusOK, map[string]any{"channel": ch, "on": on, "ai_agents_off": !inForce})
}

func (s *Server) channelAIAgentsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PUT")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// aiAgentsBody reads {"on": true|false|null}. ok=false: it answered 400.
func aiAgentsBody(w http.ResponseWriter, r *http.Request) (*bool, bool) {
	var body map[string]json.RawMessage
	err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxMemberJSONBody)).Decode(&body)
	raw, has := body["on"]
	if err != nil || !has || len(body) != 1 {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {on: true|false|null}")
		return nil, false
	}
	if string(raw) == "null" {
		return nil, true
	}
	var v bool
	if err := json.Unmarshal(raw, &v); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "on is true, false or null")
		return nil, false
	}
	return &v, true
}
