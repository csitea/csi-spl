package hub

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Who is in a channel (rdb 0028). A created channel is members-only and
// invisible to everyone else, so there is no self-service join: a member with
// channels.manage adds you, exactly as somebody has to invite you to the
// tenant before you can sign in to it at all.
//
// Every route here is behind the SAME read door as the channel's messages:
// you must already be in the channel to see or change who else is. A caller
// who is not gets the 404 a non-existent channel gets, never a 403 - the
// owner's call is that a non-member cannot learn the channel exists.

func (s *Server) routeChannelMembers(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/channels/{channel}/members", s.handleListChannelMembers)
	mux.HandleFunc("POST /v1/channels/{channel}/members", s.handleAddChannelMember)
	mux.HandleFunc("DELETE /v1/channels/{channel}/members/{human_id}", s.handleRemoveChannelMember)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/members", s.channelMembersPreflight)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/members/{human_id}", s.channelMembersPreflight)
}

func (s *Server) channelMembersPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}

// channelDoor resolves the tenant, the caller, and the channel they named,
// applying the read door. ok=false means it already answered.
func (s *Server) channelDoor(w http.ResponseWriter, r *http.Request) (store.Tenant, string, string, bool) {
	s.allowOrigin(w, r)
	t, _, ok := s.humanTenant(w, r)
	if !ok {
		return t, "", "", false
	}
	ch := store.NormalizeChannel(r.PathValue("channel"))
	hum, _ := s.memberID(r, t.ID)
	notFound := func() (store.Tenant, string, string, bool) {
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+r.PathValue("channel")+" in this tenant")
		return t, "", "", false
	}
	if !store.ValidChannelID(ch) {
		return notFound()
	}
	switch known, err := s.o.Store.ChannelKnown(r.Context(), t.ID, ch); {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel lookup failed")
		return t, "", "", false
	case !known:
		return notFound()
	}
	switch may, err := s.canReadChannel(r.Context(), t.ID, ch, hum); {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel lookup failed")
		return t, "", "", false
	case !may:
		return notFound()
	}
	return t, ch, hum, true
}

// GET /v1/channels/{channel}/members — who is in it. A default channel is
// public and carries no rows: it answers members:[] with default:true, so a
// client can tell "everyone" from "nobody" without a second call.
func (s *Server) handleListChannelMembers(w http.ResponseWriter, r *http.Request) {
	t, ch, _, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	ms, err := s.o.Store.ChannelHumanMembers(r.Context(), t.ID, ch)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "members unavailable")
		return
	}
	if ms == nil {
		ms = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"channel": ch, "default": store.ChannelPublic(ch), "members": ms})
}

// POST /v1/channels/{channel}/members {"human_id": "HUM-n"} — add one member.
func (s *Server) handleAddChannelMember(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	if !s.permit(w, r, t.ID, hum, rbac.ChannelsManage) { // specs/025
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	var body struct {
		HumanID string `json:"human_id"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || body.HumanID == "" {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {human_id}")
		return
	}
	if store.ChannelPublic(ch) {
		writeErr(w, http.StatusConflict, "channel_public", "#"+ch+" is a default channel: every member of the tenant already reads it")
		return
	}
	// Only a member of the TENANT can be put in one of its channels; without
	// this a typo would create a membership row nothing ever cleans up.
	h, hasHumans := s.o.Store.(store.Humans)
	if !hasHumans {
		writeErr(w, http.StatusInternalServerError, "internal", "memberships unavailable")
		return
	}
	switch _, err := h.MemberRole(r.Context(), body.HumanID, t.ID); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_a_member", body.HumanID+" is not a member of this tenant")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "memberships unavailable")
		return
	}
	if err := s.o.Store.AddChannelHumans(r.Context(), t.ID, ch, []string{body.HumanID}, hum, s.o.Now()); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "membership not stored")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("human", body.HumanID).
		Str("by", hum).Msg("channel member added")
	writeJSON(w, http.StatusCreated, map[string]any{"channel": ch, "human_id": body.HumanID, "added_by": hum})
}

// DELETE /v1/channels/{channel}/members/{human_id} — remove one member, or
// leave the channel yourself.
func (s *Server) handleRemoveChannelMember(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	target := r.PathValue("human_id")
	// Leaving needs no permission; removing SOMEONE ELSE does.
	if target != hum && !s.permit(w, r, t.ID, hum, rbac.ChannelsManage) {
		return
	}
	if store.ChannelPublic(ch) {
		writeErr(w, http.StatusConflict, "channel_public", "#"+ch+" is a default channel: it has no membership to remove")
		return
	}
	switch err := s.o.Store.RemoveChannelHuman(r.Context(), t.ID, ch, target); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", target+" is not in #"+ch)
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "membership not removed")
	default:
		s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("human", target).
			Str("by", hum).Msg("channel member removed")
		w.WriteHeader(http.StatusNoContent)
	}
}
