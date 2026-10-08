package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A person's own order of the Channels list (SPL-1034, specs/045 §3.8,
// contracts/move-v1.md §7). Per person and per tenant, on the membership
// (rdb 0073). GET /v1/view/me carries it; PUT /v1/me/channel-order sets it.

// maxChannelOrder bounds the stored list: a tenant with more channels than
// this is not a list a person drags.
const maxChannelOrder = 200

// channelOrder is the stored order for GET /v1/view/me; nil when never set,
// when the store keeps none, or on a lookup error (the list then shows the
// default order rather than failing the whole /me answer).
func (s *Server) channelOrder(ctx context.Context, tenant, hum string) []string {
	co, ok := s.o.Store.(store.ChannelOrders)
	if !ok {
		return nil
	}
	order, err := co.ChannelOrder(ctx, tenant, hum)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("channel order read")
	}
	if len(order) == 0 {
		return nil
	}
	return order
}

// normalizeChannelOrder is contract §7: '#' dropped, lower case, duplicates
// removed (the first wins), every id a channel id, at most maxChannelOrder.
func normalizeChannelOrder(in []string) ([]string, bool) {
	if len(in) > maxChannelOrder {
		return nil, false
	}
	seen := map[string]bool{}
	out := []string{}
	for _, raw := range in {
		id := store.NormalizeChannel(strings.ToLower(strings.TrimPrefix(strings.TrimSpace(raw), "#")))
		if !store.ValidChannelID(id) {
			return nil, false
		}
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out, true
}

// PUT /v1/me/channel-order {"channel_order": [...]}.
func (s *Server) handleSetChannelOrder(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "a channel order needs a signed-in member session")
		return
	}
	var body struct {
		ChannelOrder *[]string `json:"channel_order"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || body.ChannelOrder == nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {channel_order: [channel ids]}")
		return
	}
	order, valid := normalizeChannelOrder(*body.ChannelOrder)
	if !valid {
		writeErr(w, http.StatusBadRequest, "bad_json", "channel_order must hold at most 200 channel ids")
		return
	}
	co, ok := s.o.Store.(store.ChannelOrders)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "channel order unavailable")
		return
	}
	switch err := co.SetChannelOrder(r.Context(), t.ID, hum, order); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_member", "not a member of this tenant")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("channel order write")
		writeErr(w, http.StatusInternalServerError, "internal", "channel order not stored")
		return
	}
	var out []string
	if len(order) > 0 {
		out = order
	}
	writeJSON(w, http.StatusOK, map[string]any{"channel_order": out})
}

// routeMe registers the member's own /v1/me routes: the Channels order
// (SPL-1034), the manual status (spec 096, human_status.go) and the
// member's hours (spec 107, hours_me.go, hours_timer.go).
func (s *Server) routeMe(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/me/channel-order", s.handleSetChannelOrder)
	mux.HandleFunc("OPTIONS /v1/me/channel-order", s.channelOrderPreflight)
	s.routeHumanStatus(mux)
	s.routeMyHours(mux)
	s.routeMyHoursTimer(mux)
}

// channelOrderPreflight: PUT with the headers every browser route allows (no
// new request header: a new header is a new preflight, see 032).
func (s *Server) channelOrderPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PUT")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
