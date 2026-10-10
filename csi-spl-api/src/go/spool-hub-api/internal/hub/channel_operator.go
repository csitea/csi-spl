package hub

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator twin of POST /v1/channels (owner HUM-10, csitea 8da3f62a msg
// 5c7a9202: the review topic goes under a new channel of one workspace): an
// agent creates a channel in one workspace with no member session
// (do_spl_channel_create).
//
//	POST /v1/operator/channels {tenant, channel, ordered_by, name?, description?, privacy?}
//	GET  /v1/operator/channels/{channel}?tenant=<slug>   (the read-back)
//
//   - Who: the env service account's Google ID token on the operator
//     allow-list (operatorAuth), as the other /v1/operator routes.
//   - Creator: ordered_by, the HUM-* who ordered it, a member of that
//     workspace; created_by is that human, so the channel reads as theirs,
//     and they are seated in it as the member create seats its creator.
//   - One workspace: the body's tenant, written by the same store call as the
//     member create (RLS inside that tenant). A Host or X-Spool-Tenant naming
//     another workspace is 403 tenant_mismatch.
//   - The member create's rules: the slug (store.ValidChannelID), name <= 80,
//     description <= 500, a reserved or existing slug 409. A created channel
//     is members-only (rdb 0028): privacy is "members" or omitted; only the
//     default channels are public, and they are never created.

// channelPrivacyMembers is the one privacy a created channel has.
const channelPrivacyMembers = "members"

// operatorChannelRequest is the create body.
type operatorChannelRequest struct {
	Tenant      string `json:"tenant"`
	Channel     string `json:"channel"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Privacy     string `json:"privacy"`
	OrderedBy   string `json:"ordered_by"`
}

// operatorChannelTenant loads the workspace an authorised operator call
// names; it writes the error itself.
func (s *Server) operatorChannelTenant(w http.ResponseWriter, r *http.Request, tenant string) (store.Tenant, bool) {
	tenant = strings.ToLower(strings.TrimSpace(tenant))
	if !msg.ValidTenantID(tenant) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "tenant must be a valid slug")
		return store.Tenant{}, false
	}
	if !s.tenantConsistent(w, r, tenant) {
		return store.Tenant{}, false
	}
	return s.loadTenant(w, r, tenant)
}

// valid checks the body by the member create's rules; it writes the error.
func (q *operatorChannelRequest) valid(w http.ResponseWriter) bool {
	q.Channel = strings.TrimSpace(q.Channel)
	q.Name = strings.TrimSpace(q.Name)
	q.Description = strings.TrimSpace(q.Description)
	q.OrderedBy = strings.TrimSpace(q.OrderedBy)
	if q.Name == "" {
		q.Name = q.Channel
	}
	switch {
	case !store.ValidChannelID(q.Channel) || utf8.RuneCountInString(q.Name) > channelNameMax:
		writeErr(w, http.StatusBadRequest, "bad_channel", "channel must match ^[a-z0-9][a-z0-9-]{0,63}$ and name be at most 80 characters")
	case utf8.RuneCountInString(q.Description) > channelDescMax:
		writeErr(w, http.StatusBadRequest, "bad_channel", "description must be at most 500 characters")
	case q.Privacy != "" && q.Privacy != channelPrivacyMembers:
		writeErr(w, http.StatusBadRequest, "bad_privacy", "a created channel is members-only: privacy must be \"members\" or omitted (only the default channels are public)")
	case !humanIDRe.MatchString(q.OrderedBy):
		writeErr(w, http.StatusBadRequest, "bad_ordered_by", "ordered_by must be the HUM-* id of the human who ordered it")
	default:
		return true
	}
	return false
}

// orderedByMember: the ordering human must be a member of tenant, else the
// channel would be owned by someone who cannot open it.
func (s *Server) orderedByMember(w http.ResponseWriter, r *http.Request, tenant, hum string) bool {
	h, ok := s.o.Store.(store.Humans)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "memberships unavailable")
		return false
	}
	switch _, err := h.MemberRole(r.Context(), hum, tenant); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_a_member", hum+" is not a member of this tenant")
		return false
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "memberships unavailable")
		return false
	}
	return true
}

// writeChannelConflict answers a create that hit an existing, archived or
// reserved slug, as the member create does.
func (s *Server) writeChannelConflict(w http.ResponseWriter, r *http.Request, tenant, ch string) {
	if arch, found, err := s.o.Store.ArchivedChannel(r.Context(), tenant, ch); err == nil && found {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "channel_archived",
			"detail": "reserved: an archived channel has this name", "channel": arch.ChannelID,
			"name": arch.Name, "archived_by": arch.ArchivedBy, "archived_at": rfc(arch.ArchivedAt)})
		return
	}
	writeErr(w, http.StatusConflict, "channel_exists", "channel "+ch+" exists or is reserved")
}

func (s *Server) handleOperatorChannelCreate(w http.ResponseWriter, r *http.Request) {
	op, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	var q operatorChannelRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {tenant, channel, ordered_by, name?, description?, privacy?}")
		return
	}
	t, ok := s.operatorChannelTenant(w, r, q.Tenant)
	if !ok || !q.valid(w) || !s.orderedByMember(w, r, t.ID, q.OrderedBy) {
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	now := s.o.Now().UTC()
	c := store.Channel{TenantID: t.ID, ChannelID: q.Channel, Name: q.Name, Description: q.Description,
		CreatedBy: q.OrderedBy, CreatedAt: now}
	switch err := s.o.Store.CreateChannel(r.Context(), c); {
	case errors.Is(err, store.ErrConflict):
		s.writeChannelConflict(w, r, t.ID, q.Channel)
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel not stored")
		return
	}
	// rdb 0028: members-only, so not born empty - the creator is seated, as
	// the member create seats its creator, before the fan-out.
	if err := s.o.Store.AddChannelHumans(r.Context(), t.ID, c.ChannelID, []string{q.OrderedBy}, q.OrderedBy, now); err != nil {
		s.o.Log.Error().Err(err).Str("channel", c.ChannelID).Msg("operator channel creator membership")
	}
	s.fanoutChannel(r.Context(), t.ID, c)
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", c.ChannelID).Str("operator", op).
		Str("ordered_by", q.OrderedBy).Msg("operator.channel_created")
	writeJSON(w, http.StatusCreated, map[string]any{"channel": c.ChannelID, "name": c.Name,
		"description": c.Description, "privacy": channelPrivacyMembers, "created_by": c.CreatedBy,
		"created_at": rfc(c.CreatedAt), "default": false})
}

// handleOperatorChannelGet reads one channel of the workspace back with its
// human members (a default channel answers members:[] and default:true).
func (s *Server) handleOperatorChannelGet(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	t, ok := s.operatorChannelTenant(w, r, r.URL.Query().Get("tenant"))
	if !ok {
		return
	}
	ch := store.NormalizeChannel(r.PathValue("channel"))
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
	writeJSON(w, http.StatusOK, map[string]any{"channel": row.ChannelID, "name": row.Name,
		"description": row.Description, "created_by": row.CreatedBy, "created_at": rfc(row.CreatedAt),
		"default": store.ChannelPublic(ch), "members": ms})
}

func (s *Server) routeOperatorChannels(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/channels", s.handleOperatorChannelCreate)
	mux.HandleFunc("GET /v1/operator/channels/{channel}", s.handleOperatorChannelGet)
}
