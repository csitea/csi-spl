package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Who is in a channel (rdb 0028). A created channel is members-only and
// invisible to everyone else, so there is no self-service join. The channel
// owner adds a member. The owner is channels.created_by when that value
// matches ^HUM-; "hub" and "wui" are not owners. When members_open_invite
// is on (rdb 0031, default off), every current member may add a tenant
// human. Leaving, and removing someone else, are unchanged.
//
// Every route here is behind the SAME read door as the channel's messages:
// you must already be in the channel to see or change who else is. A caller
// who is not gets the 404 a non-existent channel gets, never a 403 - the
// owner's call is that a non-member cannot learn the channel exists.

// maxMemberJSONBody caps a channel-membership request body: one member id
// and a role fit in far less.
const maxMemberJSONBody = 4 << 10

func (s *Server) routeChannelMembers(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/channels/{channel}/members", s.handleListChannelMembers)
	mux.HandleFunc("POST /v1/channels/{channel}/members", s.handleAddChannelMember)
	mux.HandleFunc("POST /v1/channels/{channel}/agents", s.handleAddChannelAgent)
	mux.HandleFunc("DELETE /v1/channels/{channel}/agents/{box}/{id}", s.handleRemoveChannelAgent)
	mux.HandleFunc("DELETE /v1/channels/{channel}/members/{human_id}", s.handleRemoveChannelMember)
	mux.HandleFunc("PATCH /v1/channels/{channel}", s.handlePatchChannelInvite)
	mux.HandleFunc("DELETE /v1/channels/{channel}", s.handleDeleteChannel)
	mux.HandleFunc("PUT /v1/channels/{channel}/archive", s.handleArchiveChannel)
	mux.HandleFunc("PUT /v1/channels/{channel}/unarchive", s.handleUnarchiveChannel)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/archive", s.channelArchivePreflight)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/unarchive", s.channelArchivePreflight)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/members", s.channelMembersPreflight)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/members/{human_id}", s.channelMembersPreflight)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/agents", s.channelMembersPreflight)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}/agents/{box}/{id}", s.channelMembersPreflight)
	mux.HandleFunc("OPTIONS /v1/channels/{channel}", s.channelInvitePreflight)
}

// agentIDRe is an agent id (CLE-07, GRK-03, AGY-02). A human is HUM-* and
// is not invited on the agent door.
var agentIDRe = regexp.MustCompile(`^[A-Z]{2,4}-[0-9]+$`)

// mayInviteChannel is who may add a person or an agent. The owner may.
// Any current member may when members_open_invite is on. A channel whose
// created_by is not a HUM-* (hub, wui) has nobody who matches the owner
// rule, so a current member may invite or the channel can never grow.
func mayInviteChannel(createdBy, caller string, open bool) bool {
	if channelOwner(createdBy, caller) || open {
		return true
	}
	return caller != "" && !strings.HasPrefix(createdBy, "HUM-")
}

func (s *Server) channelMembersPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// channelInvitePreflight is CORS for PATCH and DELETE /v1/channels/{channel}.
func (s *Server) channelInvitePreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// channelArchivePreflight answers the archive / unarchive OPTIONS (PUT).
func (s *Server) channelArchivePreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PUT")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// channelOwner reports whether caller is the human who created the channel.
// created_by must match ^HUM-; "hub" and "wui" are not owners.
func channelOwner(createdBy, caller string) bool {
	return caller != "" && createdBy == caller && strings.HasPrefix(createdBy, "HUM-")
}

// channelRecord loads the channels row. ok=false means it already answered.
func (s *Server) channelRecord(w http.ResponseWriter, r *http.Request, tenant, ch string) (store.Channel, bool) {
	row, err := s.o.Store.Channel(r.Context(), tenant, ch)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+r.PathValue("channel")+" in this tenant")
		return store.Channel{}, false
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel lookup failed")
		return store.Channel{}, false
	}
	return row, true
}

// channelDoor resolves the tenant, the caller, and the channel they named,
// applying the read door. ok=false means it already answered.
func (s *Server) channelDoor(w http.ResponseWriter, r *http.Request) (store.Tenant, string, string, bool) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r) // the PROVEN human (CLE-34986: not a second, error-dropping lookup)
	if !ok {
		return t, "", "", false
	}
	ch := store.NormalizeChannel(r.PathValue("channel"))
	if hum == "" && s.o.ViewDoor != ViewDoorOff {
		writeErr(w, http.StatusUnauthorized, "view_door", "a member session is required")
		return t, "", "", false
	}
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
// public to people and carries no human rows: it answers members:[] with
// default:true, so a client can tell "everyone" from "nobody" without a
// second call. Its agents are real rows, like any channel's.
func (s *Server) handleListChannelMembers(w http.ResponseWriter, r *http.Request) {
	t, ch, _, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	row, ok := s.channelRecord(w, r, t.ID, ch)
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
	agents, err := s.o.Store.ChannelMembers(r.Context(), t.ID, ch)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "members unavailable")
		return
	}
	list := s.withAgentState(r.Context(), t.ID, channelAgentList(agents))
	out := map[string]any{
		"channel": ch, "default": store.ChannelPublic(ch), "members": ms,
		"members_open_invite": row.MembersOpenInvite,
		"created_by":          row.CreatedBy,
		"agents":              list,
	}
	if fb := s.fallbackInfo(r.Context(), t.ID, ch, list); fb != nil { // SPL-997, FR-035
		out["fallback"] = fb
		// CLE-77804: a tenant responder hears this channel via the fallback /
		// escalation path (unless the channel opted out, FR-039), so it may be
		// poked here even though it is not a member. The WUI's mention K4 was
		// refusing @<responder> in a channel the responder is not a member of.
		if !fb.Off {
			if fbs, ok := s.o.Store.(store.Fallbacks); ok {
				if resp, err := fbs.TenantResponders(r.Context(), t.ID); err == nil && len(resp) > 0 {
					out["responders"] = resp
				}
			}
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// channelAgent is one subscribed agent on GET /v1/channels/{channel}/members.
//
// SPL-987: the Properties dialog shows whether an invited agent can hear the
// channel at all. Online = its box holds a live role=box socket to this hub
// (posts reach the box now, not on its next hello). Seated = the box's
// current roster still names the agent (its spool dir exists on the box).
// Neither says the agent's terminal is running: that is the box's knowledge,
// and a box can be online with a pane that has exited.
type channelAgent struct {
	ID     string `json:"id"`
	Box    string `json:"box"`
	Online bool   `json:"online"`
	Seated bool   `json:"seated"`
}

// withAgentState fills Online and Seated. A roster read error leaves Seated
// false rather than failing the list.
func (s *Server) withAgentState(ctx context.Context, tenant string, list []channelAgent) []channelAgent {
	if len(list) == 0 {
		return list
	}
	roster, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("roster for channel agents")
	}
	for i := range list {
		list[i].Online = s.boxSession(tenant, list[i].Box) != nil
		list[i].Seated = contains(roster[list[i].Box], list[i].ID)
	}
	return list
}

// channelAgentList flattens box → agent ids. box-wui is the browser, and a
// HUM-* id is a human, so neither is an agent of the channel. Empty is [],
// never null. Order is id, then box.
func channelAgentList(byBox map[string][]string) []channelAgent {
	out := []channelAgent{}
	for box, ids := range byBox {
		if box == "box-wui" {
			continue
		}
		for _, id := range ids {
			if strings.HasPrefix(id, "HUM-") {
				continue
			}
			out = append(out, channelAgent{ID: id, Box: box})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].ID != out[j].ID {
			return out[i].ID < out[j].ID
		}
		return out[i].Box < out[j].Box
	})
	return out
}

// POST /v1/channels/{channel}/members {"human_id": "HUM-n"} — add one member.
// The owner may always. Any current member may when members_open_invite is
// on. channels.manage is not this door.
func (s *Server) handleAddChannelMember(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	// A default channel has no owner and no flag. Answer 409 before the
	// invite rule, which would otherwise refuse everyone (created_by is
	// "hub") and hide channel_public.
	if !store.ChannelPublic(ch) {
		row, ok := s.channelRecord(w, r, t.ID, ch)
		if !ok {
			return
		}
		if !mayInviteChannel(row.CreatedBy, hum, row.MembersOpenInvite) {
			writeErr(w, http.StatusForbidden, "forbidden", "only the channel owner may add members")
			return
		}
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	var body struct {
		HumanID string `json:"human_id"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxMemberJSONBody))
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

// POST /v1/channels/{channel}/agents {"id","box"} — subscribe one announced
// agent. The same people who may add a human may invite an agent. The row
// is origin invite, so the box's next announce does not drop it.
//
// A default channel (#lobby, #alerts, #feedback) takes agents the same way
// (owner decision 2026-09-25): it starts with none, and an announce never
// adds one. Its created_by is "hub", so mayInviteChannel lets any signed-in
// member of the tenant pick its agents. Its PEOPLE stay everyone.
func (s *Server) handleAddChannelAgent(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	row, ok := s.channelRecord(w, r, t.ID, ch)
	if !ok {
		return
	}
	if !mayInviteChannel(row.CreatedBy, hum, row.MembersOpenInvite) {
		writeErr(w, http.StatusForbidden, "forbidden", "only the channel owner may add members")
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	var body struct {
		ID  string `json:"id"`
		Box string `json:"box"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxMemberJSONBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || body.ID == "" || body.Box == "" {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {id, box}")
		return
	}
	if !agentIDRe.MatchString(body.ID) || strings.HasPrefix(body.ID, "HUM-") || body.Box == "box-wui" || strings.ContainsAny(body.Box, " \t") {
		writeErr(w, http.StatusBadRequest, "bad_json", "id must be an agent and box must not be box-wui")
		return
	}
	roster, err := s.o.Store.Roster(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "roster unavailable")
		return
	}
	known := false
	for _, id := range roster[body.Box] {
		if id == body.ID {
			known = true
			break
		}
	}
	if !known {
		writeErr(w, http.StatusNotFound, "not_a_member", body.ID+" is not announced on "+body.Box)
		return
	}
	if err := s.o.Store.InviteChannelAgent(r.Context(), t.ID, ch, body.Box, body.ID, s.o.Now()); err != nil {
		switch {
		case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrConflict):
			writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+ch+" in this tenant")
		default:
			writeErr(w, http.StatusInternalServerError, "internal", "agent subscription not stored")
		}
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("agent", body.ID).
		Str("box", body.Box).Str("by", hum).Msg("channel agent invited")
	// SPL-987: the channel's earlier posts, once, on the box's live session.
	// Off the request: the answer does not wait for up to BackfillMax frames.
	go s.backfillBox(context.WithoutCancel(r.Context()), t.ID, body.Box)
	writeJSON(w, http.StatusCreated, map[string]any{"channel": ch, "id": body.ID, "box": body.Box})
}

// DELETE /v1/channels/{channel}/agents/{box}/{id} — take one agent out.
// The same people who may invite may remove, in a default channel too. The
// row stays as origin removed, so the box's next announce does not put the
// agent back.
func (s *Server) handleRemoveChannelAgent(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	row, ok := s.channelRecord(w, r, t.ID, ch)
	if !ok {
		return
	}
	if !mayInviteChannel(row.CreatedBy, hum, row.MembersOpenInvite) {
		writeErr(w, http.StatusForbidden, "forbidden", "only the channel owner may remove members")
		return
	}
	box := r.PathValue("box")
	id := r.PathValue("id")
	if !agentIDRe.MatchString(id) || strings.HasPrefix(id, "HUM-") || box == "" || box == "box-wui" {
		writeErr(w, http.StatusBadRequest, "bad_json", "id must be an agent and box must not be box-wui")
		return
	}
	if err := s.o.Store.RemoveChannelAgent(r.Context(), t.ID, ch, box, id, s.o.Now()); err != nil {
		switch {
		case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrConflict):
			writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+ch+" in this tenant")
		default:
			writeErr(w, http.StatusInternalServerError, "internal", "agent subscription not removed")
		}
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("agent", id).
		Str("box", box).Str("by", hum).Msg("channel agent removed")
	w.WriteHeader(http.StatusNoContent)
}

// PATCH /v1/channels/{channel} {"members_open_invite": true|false}.
// The owner only. A default channel is 409. This does not use channels.manage.
func (s *Server) handlePatchChannelInvite(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	if store.ChannelPublic(ch) {
		writeErr(w, http.StatusConflict, "channel_public", "#"+ch+" is a default channel: it has no invite setting")
		return
	}
	row, ok := s.channelRecord(w, r, t.ID, ch)
	if !ok {
		return
	}
	if !channelOwner(row.CreatedBy, hum) {
		writeErr(w, http.StatusForbidden, "forbidden", "only the channel owner may change who can invite")
		return
	}
	var body struct {
		MembersOpenInvite *bool `json:"members_open_invite"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxMemberJSONBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || body.MembersOpenInvite == nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {members_open_invite}")
		return
	}
	if err := s.o.Store.SetMembersOpenInvite(r.Context(), t.ID, ch, *body.MembersOpenInvite); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "channel setting not stored")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"channel": ch, "members_open_invite": *body.MembersOpenInvite})
}

// DELETE /v1/channels/{channel} — the member who created the channel deletes
// it (SPL-72, channels-v1 §5.4). The creator ONLY: channelOwner, the rule
// PATCH uses. No role widens it - a biz_owner or admin who did not create the
// channel is refused like any other member (they keep channels.manage to
// remove members). A channel created_by hub or wui has no creator, so nobody
// may delete it. Refusals, in door order: not a member 404 (as a missing
// channel), a default channel 409, not the creator 403.
//
// It is a HARD delete (HUM-10 bug, topic ee21db20): the channels row, its
// members, its agent seats and its messages are removed, so the slug is FREE
// again - a new channel of the same name inherits nothing. A member who wants
// the channel kept but hidden uses PUT .../archive instead. The members are
// read BEFORE the delete - afterwards the channel has none - and each of their
// sockets gets a channel_deleted frame, so every open sidebar drops it at once.
func (s *Server) handleDeleteChannel(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	if store.ChannelPublic(ch) {
		writeErr(w, http.StatusConflict, "channel_public", "#"+ch+" is a default channel: it cannot be deleted")
		return
	}
	row, ok := s.channelRecord(w, r, t.ID, ch)
	if !ok {
		return
	}
	if !channelOwner(row.CreatedBy, hum) {
		writeErr(w, http.StatusForbidden, "forbidden", "only the member who created #"+ch+" may delete it")
		return
	}
	members := s.channelMemberSet(r.Context(), t.ID, ch)
	switch err := s.o.Store.DeleteChannel(r.Context(), t.ID, ch, hum, s.o.Now().UTC()); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+r.PathValue("channel")+" in this tenant")
		return
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "channel_public", "#"+ch+" cannot be deleted")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel not deleted")
		return
	}
	s.fanoutChannelFrame(r.Context(), t.ID, members, map[string]any{"type": "channel_deleted", "channel": ch})
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("by", hum).Msg("channel deleted")
	w.WriteHeader(http.StatusNoContent)
}

// PUT /v1/channels/{channel}/archive — the creator archives the channel
// (SPL feature, topic 32ea1b81): it is hidden and its slug reserved, and its
// topics and messages move to the Archive view (rdb 0092). Reversible by
// PUT .../unarchive. Same door as delete (channelOwner): a member who did not
// create it is refused. The members are read before the archive; each open
// sidebar gets a channel_deleted frame and drops the row.
func (s *Server) handleArchiveChannel(w http.ResponseWriter, r *http.Request) {
	t, ch, hum, ok := s.channelDoor(w, r)
	if !ok {
		return
	}
	if store.ChannelPublic(ch) {
		writeErr(w, http.StatusConflict, "channel_public", "#"+ch+" is a default channel: it cannot be archived")
		return
	}
	row, ok := s.channelRecord(w, r, t.ID, ch)
	if !ok {
		return
	}
	if !channelOwner(row.CreatedBy, hum) {
		writeErr(w, http.StatusForbidden, "forbidden", "only the member who created #"+ch+" may archive it")
		return
	}
	members := s.channelMemberSet(r.Context(), t.ID, ch)
	switch err := s.o.Store.ArchiveChannel(r.Context(), t.ID, ch, hum, s.o.Now().UTC()); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+r.PathValue("channel")+" in this tenant")
		return
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "channel_public", "#"+ch+" cannot be archived")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel not archived")
		return
	}
	s.fanoutChannelFrame(r.Context(), t.ID, members, map[string]any{"type": "channel_deleted", "channel": ch})
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("by", hum).Msg("channel archived")
	w.WriteHeader(http.StatusNoContent)
}

// PUT /v1/channels/{channel}/unarchive — bring an archived channel back
// (rdb 0092). channels.manage (the create-channel permission), because the
// archived channel is invisible to the channelDoor and the person meeting the
// "name reserved" wall on create is the one who unarchives. The channel and
// the topics/messages this archive stamped come back; a topic archived on its
// own before the channel archive stays archived. A `channel` frame re-adds the
// row to every member's sidebar.
func (s *Server) handleUnarchiveChannel(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok || !s.permit(w, r, t.ID, hum, rbac.ChannelsManage) {
		return
	}
	ch := store.NormalizeChannel(r.PathValue("channel"))
	if !store.ValidChannelID(ch) {
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+r.PathValue("channel")+" in this tenant")
		return
	}
	row, found, err := s.o.Store.ArchivedChannel(r.Context(), t.ID, ch)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "channel lookup failed")
		return
	}
	if !found {
		writeErr(w, http.StatusNotFound, "unknown_channel", "no archived channel "+r.PathValue("channel")+" in this tenant")
		return
	}
	switch err := s.o.Store.UnarchiveChannel(r.Context(), t.ID, ch); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no archived channel "+r.PathValue("channel")+" in this tenant")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel not unarchived")
		return
	}
	row.ArchivedAt, row.ArchivedBy = time.Time{}, ""
	s.fanoutChannel(r.Context(), t.ID, row)
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("by", hum).Msg("channel unarchived")
	writeJSON(w, http.StatusOK, map[string]any{"channel": ch, "name": row.Name, "description": row.Description,
		"created_by": row.CreatedBy, "created_at": rfc(row.CreatedAt), "default": false})
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
