package hub

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A channel's box pins (spec 164 section 4, row B2; the table and store are
// B1, rdb 0246): by default a channel runs on any pinned box of the
// workspace; an admin may fix it to some of them (owner HUM-10, t1
// 021d4921 msg 6b6d092c).
//
//	GET /v1/channels/{channel}/box-pins                      (the channel's read door)
//	PUT /v1/channels/{channel}/box-pins {"box_pins": [...]}  (tenant.settings)
//	PUT /v1/operator/channels/{channel}/box-pins?tenant=<id> (the operator twin, B8's seed)
//
// A PUT is refused, in this order (spec 164 4.1): a channel that does not
// exist or is archived, 404 unknown_channel; a default channel (#lobby,
// #alerts, #feedback, #public, and the reserved #issues), 400
// channel_default_unpinnable (owner Q1 = A, msg 1cc5b9bb); a box that is not
// pinned to the workspace or is revoked, 400 unknown_box. "box_pins": []
// clears the pin: the channel is back on every box. Nothing here routes a
// post: the fan-out and the direct legs read the pins in B3.

// maxChannelBoxPins bounds one PUT's list; a workspace has far fewer boxes.
const maxChannelBoxPins = 64

// pinnedByOperator is pinned_by for the operator route (rdb 0246).
const pinnedByOperator = "operator"

func (s *Server) routeChannelBoxPins(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/channels/{channel}/box-pins", s.handleGetChannelBoxPins)
	mux.HandleFunc("PUT /v1/channels/{channel}/box-pins", s.handlePutChannelBoxPins)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/box-pins", s.channelBoxPinsPreflight)
	mux.HandleFunc("PUT /v1/operator/channels/{channel}/box-pins", s.handleOperatorChannelBoxPins)
}

// channelBoxPinsBody is the PUT body of both doors.
type channelBoxPinsBody struct {
	BoxPins *[]string `json:"box_pins"`
}

// writeChannelBoxPins answers {channel, box_pins, is_pinned}; box_pins is
// never null.
func writeChannelBoxPins(w http.ResponseWriter, ch string, boxes []string) {
	if boxes == nil {
		boxes = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"channel": ch, "box_pins": boxes, "is_pinned": len(boxes) > 0})
}

// GET /v1/channels/{channel}/box-pins: whoever may read the channel reads
// its pins (the WUI shows them read-only without tenant.settings).
func (s *Server) handleGetChannelBoxPins(w http.ResponseWriter, r *http.Request) {
	t, ch, _, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	boxes, err := s.o.Store.GetChannelBoxPins(r.Context(), t.ID, ch)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "channel box pins unavailable")
		return
	}
	writeChannelBoxPins(w, ch, boxes)
}

// PUT /v1/channels/{channel}/box-pins {"box_pins": [...]}: a workspace admin
// (tenant.settings) sets any channel's pins, a member of it or not.
func (s *Server) handlePutChannelBoxPins(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	ch, ok := s.tenantChannel(w, r, t.ID)
	if !ok {
		return
	}
	var body channelBoxPinsBody
	if !decodeMembers(w, r, &body) {
		return
	}
	if s.setChannelBoxPins(w, r, t.ID, ch, body.BoxPins, a.HumanID) {
		s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("by", a.HumanID).Msg("tenant.channel_box_pins")
	}
}

// PUT /v1/operator/channels/{channel}/box-pins?tenant=<id> {"box_pins": [...]}:
// the operator form (an allow-listed service account), pinned_by "operator".
func (s *Server) handleOperatorChannelBoxPins(w http.ResponseWriter, r *http.Request) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	t, ok := s.operatorChannelTenant(w, r, r.URL.Query().Get("tenant"))
	if !ok {
		return
	}
	ch, ok := s.tenantChannel(w, r, t.ID)
	if !ok {
		return
	}
	var body channelBoxPinsBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {box_pins: [box ids]}")
		return
	}
	if s.setChannelBoxPins(w, r, t.ID, ch, body.BoxPins, pinnedByOperator) {
		s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("operator", op).Msg("operator.channel_box_pins")
	}
}

// setChannelBoxPins checks and writes one PUT (both doors) and answers it
// with the stored pins; false when it answered an error.
func (s *Server) setChannelBoxPins(w http.ResponseWriter, r *http.Request, tenant, ch string, in *[]string, by string) bool {
	if in == nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "box_pins is required ([] clears the pin)")
		return false
	}
	if store.ChannelPublic(ch) {
		writeErr(w, http.StatusBadRequest, "channel_default_unpinnable", "#"+ch+" is a default channel: it stays on every box")
		return false
	}
	boxes, ok := s.channelBoxPinList(w, r, tenant, *in)
	if !ok {
		return false
	}
	switch err := s.o.Store.SetChannelBoxPins(r.Context(), tenant, ch, boxes, by); {
	case errors.Is(err, store.ErrNotFound):
		// The checks above passed, so the channel or a box went away meanwhile.
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+ch+" in this tenant, or a box was removed")
		return false
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel box pins not stored")
		return false
	}
	stored, err := s.o.Store.GetChannelBoxPins(r.Context(), tenant, ch)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "channel box pins stored, read back failed")
		return false
	}
	writeChannelBoxPins(w, ch, stored)
	return true
}

// channelBoxPinList trims the requested ids and checks each is a box pinned
// to the workspace and not revoked (store.GetPin). ok=false: it answered.
func (s *Server) channelBoxPinList(w http.ResponseWriter, r *http.Request, tenant string, in []string) ([]string, bool) {
	if len(in) > maxChannelBoxPins {
		writeErr(w, http.StatusBadRequest, "bad_json", "at most 64 box_pins")
		return nil, false
	}
	out := make([]string, 0, len(in))
	for _, b := range in {
		b = strings.TrimSpace(b)
		if !msg.ValidBoxID(b) {
			writeErr(w, http.StatusBadRequest, "unknown_box", "box "+b+" is not a box id")
			return nil, false
		}
		switch _, err := s.o.Store.GetPin(r.Context(), tenant, b); {
		case errors.Is(err, store.ErrNotFound):
			writeErr(w, http.StatusBadRequest, "unknown_box", "box "+b+" is not pinned to this workspace, or is revoked")
			return nil, false
		case err != nil:
			writeErr(w, http.StatusInternalServerError, "internal", "box lookup failed")
			return nil, false
		}
		out = append(out, b)
	}
	return out, true
}

func (s *Server) channelBoxPinsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
