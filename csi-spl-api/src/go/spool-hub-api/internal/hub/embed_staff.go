package hub

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The staff side of the visitor channels (specs/121 4.4, 6; T106). Staff
// (biz_owner, admin) list the workspace's visitor channels, mark one a lead
// (kept past retention) and block a visitor (token revoked, channel kept):
//
//	GET  /v1/tenant/embed-visitors                    the visitor channels
//	PUT  /v1/tenant/embed-visitors/{channel}/lead     {"lead": true|false}
//	POST /v1/tenant/embed-visitors/{channel}/block    revoke the token (204)
//
// And the #sales triage line: a new visitor channel, and a first post after
// embedTriageQuiet, post ONE line to the private #sales channel, a link to
// the visitor channel and never the visitor's text. A new channel also
// seats the staff in it, so the link opens (store.EmbedTriageSeats).
// While cnf env.hub.embed.enabled is off every route answers exactly as an
// unknown path, before the session is read.

// embedTriageQuiet: a visitor's post after this long without a message in
// its channel gets a triage line again (spec 4.4).
const embedTriageQuiet = 24 * time.Hour

// permEmbedStaff names the gate in a 403 body; it is not an rbac permission.
const permEmbedStaff = "embed.staff"

func (s *Server) routeEmbedStaff(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/tenant/embed-visitors", s.handleEmbedStaffList)
	mux.HandleFunc("PUT /v1/tenant/embed-visitors/{channel}/lead", s.handleEmbedLead)
	mux.HandleFunc("POST /v1/tenant/embed-visitors/{channel}/block", s.handleEmbedBlock)
}

// embedStaffActor is the caller's workspace when the embed is on and the
// caller is staff; false after a 404 (flag off: the unknown path's answer,
// before the session is read), 401, 403, or 501 (a store without visitor
// channels).
func (s *Server) embedStaffActor(w http.ResponseWriter, r *http.Request) (store.EmbedStaff, string, bool) {
	if !s.o.EmbedEnabled {
		http.NotFound(w, r)
		return nil, "", false
	}
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return nil, "", false
	}
	if hum == "" {
		writeForbidden(w, permEmbedStaff, "visitor channels need a member session")
		return nil, "", false
	}
	if a, err := s.access(r.Context(), hum, t.ID); err != nil || !(a.TenantOwner || a.Has(rbac.Admin)) {
		writeForbidden(w, permEmbedStaff, "only the workspace owner or an admin manages visitor channels")
		return nil, "", false
	}
	es, ok := s.o.Store.(store.EmbedStaff)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no visitor channels")
		return nil, "", false
	}
	return es, t.ID, true
}

// embedVisitorBody is one visitor channel as the staff list shows it.
type embedVisitorBody struct {
	Channel   string  `json:"channel"`
	EmbedID   string  `json:"embed_id"`
	CreatedAt string  `json:"created_at"`
	LastAt    string  `json:"last_at"`
	Lead      bool    `json:"lead"`
	LeadAt    *string `json:"lead_at"`
	Blocked   bool    `json:"blocked"`
	BlockedAt *string `json:"blocked_at"`
	Live      bool    `json:"live"`
}

func (s *Server) handleEmbedStaffList(w http.ResponseWriter, r *http.Request) {
	es, tenant, ok := s.embedStaffActor(w, r)
	if !ok {
		return
	}
	got, err := es.EmbedVisitorChannels(r.Context(), tenant, s.o.Now().UTC())
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "visitor channels not read", err)
		return
	}
	out := make([]embedVisitorBody, 0, len(got))
	for _, c := range got {
		out = append(out, embedVisitorBody{Channel: c.ChannelID, EmbedID: c.EmbedID, CreatedAt: rfc(c.CreatedAt),
			LastAt: rfc(c.LastAt), Lead: !c.LeadAt.IsZero(), LeadAt: rfcOrNil(c.LeadAt),
			Blocked: !c.BlockedAt.IsZero(), BlockedAt: rfcOrNil(c.BlockedAt), Live: c.Live})
	}
	writeJSON(w, http.StatusOK, map[string]any{"visitors": out})
}

// embedStaffDone answers one staff write: 204, 404 for a channel that is no
// visitor channel of the workspace, else 500.
func embedStaffDone(w http.ResponseWriter, err error, what string) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such visitor channel")
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", what, err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (s *Server) handleEmbedLead(w http.ResponseWriter, r *http.Request) {
	es, tenant, ok := s.embedStaffActor(w, r)
	if !ok {
		return
	}
	var in struct {
		Lead *bool `json:"lead"`
	}
	if !readJSONStrict(w, r, &in, 256, "invalid JSON body (only lead)") {
		return
	}
	if in.Lead == nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "lead must be true or false")
		return
	}
	err := es.SetEmbedLead(r.Context(), tenant, r.PathValue("channel"), *in.Lead, s.o.Now().UTC())
	embedStaffDone(w, err, "lead mark not stored")
}

func (s *Server) handleEmbedBlock(w http.ResponseWriter, r *http.Request) {
	es, tenant, ok := s.embedStaffActor(w, r)
	if !ok {
		return
	}
	err := es.BlockEmbedVisitor(r.Context(), tenant, r.PathValue("channel"), s.o.Now().UTC())
	embedStaffDone(w, err, "visitor not blocked")
}

// embedTriage posts the #sales line for v's channel, after the visitor's
// answer is written: for a new channel (msgID ""), or when msgID is the
// first post after embedTriageQuiet. A failure is logged; the visitor's
// request has succeeded already and never sees it.
func (s *Server) embedTriage(ctx context.Context, v store.EmbedVisitor, msgID string) {
	es, ok := s.o.Store.(store.EmbedStaff)
	if !ok {
		return
	}
	now := s.o.Now().UTC()
	body := "New website visitor: [#" + v.ChannelID + "](/channel/" + v.ChannelID + ")"
	if msgID != "" {
		quiet, err := es.EmbedQuiet(ctx, v.TenantID, v.ChannelID, msgID, now.Add(-embedTriageQuiet))
		if err != nil || !quiet {
			s.embedTriageErr(v, err)
			return
		}
		body = "Website visitor is back after a quiet day: [#" + v.ChannelID + "](/channel/" + v.ChannelID + ")"
	}
	err := es.EmbedTriageSeats(ctx, v.TenantID, v.ChannelID, msgID == "", now)
	if err == nil {
		err = s.embedTriageLine(ctx, v, body, now)
	}
	s.embedTriageErr(v, err)
}

// embedTriageErr logs a triage failure (nil: nothing).
func (s *Server) embedTriageErr(v store.EmbedVisitor, err error) {
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", v.TenantID).Str("channel", v.ChannelID).Msg("embed triage line")
	}
}

// embedTriageLine stores body in #sales as a browser-only note of the
// visitor's HUM (the event is the visitor's), its own topic, delivered to no
// box.
func (s *Server) embedTriageLine(ctx context.Context, v store.EmbedVisitor, body string, now time.Time) error {
	m := &msg.Message{V: s.writeVersion(), MsgID: uid.New(), TaskID: uid.New(), TS: now.Format(time.RFC3339),
		From: v.HumanID, To: BroadcastID, Kind: "note", Body: body, Files: []msg.Attachment{}}
	if err := m.Validate(); err != nil {
		return err
	}
	inner, err := msg.Canonical(m)
	if err != nil {
		return err
	}
	env := &wire.Envelope{FromBox: WUIBox, ToBox: WUIBox, Channel: store.EmbedSalesChannel, Msg: inner}
	_, err = s.commitRow(ctx, v.TenantID, env, m, 1)
	return err
}
