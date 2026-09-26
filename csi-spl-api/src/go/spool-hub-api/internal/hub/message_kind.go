package hub

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// PATCH /v1/messages/{msg_id}/kind — set a sent message's kind (SPL-952).
//
// Owner, 2026-09-26 (topic d88a3fbb): "the type of the msg should be
// clickable and settable the same way the icons are settable". The kind is in
// the signed inner object and an agent's box signed it, so the hub does not
// rewrite the envelope: the new kind is hub metadata (messages.kind +
// kind_set_by / kind_set_at, rdb 0060) and every change is kept in the
// append-only message_kind_changes register.
//
// Who may set it: the message's author, or a member whose role is one of
// kindSetterRoles. The hub enforces it; the browser only hides the picker.
//
// The live push is the existing message_edited frame, carrying the unchanged
// envelope plus the kind override: every browser already applies that frame
// as a replacement for a row it holds, so no second frame type is needed.

// kindSetterRoles may set the kind of any message they can read.
var kindSetterRoles = map[string]bool{rbac.BizOwner: true, rbac.Admin: true}

type kindRequest struct {
	Kind string `json:"kind"`
}

// kindFields adds the SPL-952 override to a payload. Omitted while the kind
// was never changed: the envelope's own kind is then the truth.
func kindFields(out map[string]any, kind string, setAt time.Time, setBy string) {
	if setAt.IsZero() {
		return
	}
	out["kind"], out["kind_set_at"], out["kind_set_by"] = kind, rfc(setAt), setBy
}

func (s *Server) handleSetMessageKind(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	from, ok := s.editorID(r, t.ID)
	if !ok {
		writeForbidden(w, rbac.NotesSend, "setting a message's kind needs a signed-in member session")
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	if !s.permit(w, r, t.ID, hum, rbac.NotesSend) {
		return
	}
	id := strings.ToLower(r.PathValue("msg_id"))
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_json", "msg_id must be a UUID")
		return
	}
	var body kindRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {kind}")
		return
	}
	if !msg.ValidKind(body.Kind) {
		writeErr(w, http.StatusBadRequest, "bad_kind", "kind must be one of "+msg.KindList)
		return
	}
	m, err := s.o.Store.GetEditable(r.Context(), t.ID, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("kind lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return
	}
	if !s.messageDoor(w, r, t.ID, m) { // the read door first: an unreadable message is a 404
		return
	}
	if m.FromID != from && !s.setsAnyKind(r, t.ID, hum) {
		writeErr(w, http.StatusForbidden, "not_allowed", "only the author, a biz_owner or an admin may set this message's kind")
		return
	}
	now := s.o.Now().UTC().Truncate(time.Second)
	c, err := s.o.Store.SetKind(r.Context(), t.ID, id, body.Kind, from, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("kind store")
		writeErr(w, http.StatusInternalServerError, "internal", "kind not stored")
		return
	}
	if c.Seq > 0 { // an unchanged kind records nothing and pushes nothing
		m.Kind, m.KindSetAt, m.KindSetBy = body.Kind, now, from
		s.o.Log.Info().Str("tenant", t.ID).Str("msg_id", id).Str("by", from).
			Str("from_kind", c.From).Str("to_kind", c.To).Msg("message kind set")
		s.fanoutEdited(r.Context(), t.ID, m, m.Env, m.EditedAt, m.EditedBy, m.Revision)
	}
	writeJSON(w, http.StatusOK, editedPayload(m, m.Env, m.EditedAt, m.EditedBy, m.Revision))
}

// setsAnyKind reports whether hum's role may set any readable message's kind.
func (s *Server) setsAnyKind(r *http.Request, tenant, hum string) bool {
	if hum == "" {
		return false
	}
	a, err := s.access(r.Context(), hum, tenant)
	return err == nil && kindSetterRoles[a.Role]
}

// kindPreflight answers CORS preflight for PATCH /v1/messages/{msg_id}/kind,
// with no new request header (a new header is a new preflight).
func (s *Server) kindPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PATCH")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}
