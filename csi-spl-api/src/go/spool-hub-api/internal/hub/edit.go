package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// PATCH /v1/messages/{msg_id} — edit a sent message (specs/032
// contracts/message-edit-v1.md). The owner asked for Slack-wise editing and,
// in the same breath, for a register in the database holding both the old and
// the new body. So this endpoint rewrites the message in place and appends to
// that register in one transaction; it never overwrites a body out of
// existence.
//
// The message does NOT move: msg_id, ts, received_at and the cursor built from
// received_at are all unchanged, because a typo fix must not reorder a thread.
//
// The edit marker (edited_at / edited_by / revision) is HUB metadata and rides
// beside cursor and received_at on the view element. It is never a field of
// the inner v:1/v:2 object, so specs/020's schema freeze is untouched. The
// envelope signature does cover the body: rule 7 re-signs a box-wui envelope
// with the key this process holds, and leaves every other signature alone.

// bodyMax is the v:2 §1 body limit, in bytes.
const bodyMax = 64 << 10

// editedFrame is the live frame shape (contract §3). Named message_edited and
// NOT message on purpose: the browser's mergeById replaces a held row only
// while it is `pending` (csi-spl-wui/src/utils/feed.mjs:89), so a second
// `message` frame for an already-confirmed msg_id is silently dropped and no
// screen that already had the message would change.
const editedFrame = "message_edited"

// editRequest is the whole request body. No task_id: messages' primary key is
// (tenant_id, msg_id), so msg_id identifies the row on its own and a second
// identifier would only be a second way to be wrong.
type editRequest struct {
	Body string `json:"body"`
}

// editedFields adds the contract §2.1 marker to a payload. All three keys are
// OMITTED while the message has never been edited: absence is the signal, so
// the browser's test is one truthiness check.
func editedFields(out map[string]any, editedAt time.Time, editedBy string, revision int) {
	if editedAt.IsZero() {
		return
	}
	out["edited_at"], out["edited_by"] = rfc(editedAt), editedBy
	if revision > 0 {
		out["revision"] = revision
	}
}

// handleEditMessage applies contract §4's seven rules in order, then §1/§2.
func (s *Server) handleEditMessage(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r) // specs/026: the session's active tenant
	if !ok {
		return
	}
	// Rule 2: a signed-in member, never a door-off guest. A guest has no
	// stable identity to be the author of anything.
	from, ok := s.editorID(r, t.ID)
	if !ok {
		writeForbidden(w, rbac.NotesSend, "editing a message needs a signed-in member session")
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) { // rule 3
		writeUnpaid(w)
		return
	}
	if !s.permit(w, r, t.ID, hum, rbac.NotesSend) { // rule 4, per request: a demotion bites at once
		return
	}
	id := strings.ToLower(r.PathValue("msg_id"))
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_json", "msg_id must be a UUID")
		return
	}
	var body editRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, bodyMax+4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {body}")
		return
	}
	// The composer's own empty guard has been bypassed before (CLE-3433 found
	// a body = "" row in the dev store), so the hub refuses it too rather than
	// trusting the one caller it happens to know about.
	if strings.TrimSpace(body.Body) == "" {
		writeErr(w, http.StatusBadRequest, "empty_body", "body must not be empty")
		return
	}
	if len(body.Body) > bodyMax {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "body must be at most 65536 bytes")
		return
	}

	m, err := s.o.Store.GetEditable(r.Context(), t.ID, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound): // rule 5: absent, another tenant's, or past retention
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("edit lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return
	}
	if m.FromID != from { // rule 6
		writeErr(w, http.StatusForbidden, "not_author", "only the author may edit this message")
		return
	}
	// Rule 7. A from_box other than box-wui is that box's envelope: the hub
	// holds no key that could re-sign for it, so the body stays as signed.
	// A box-wui envelope with a signature was signed by this hub — channel
	// fan-out and agent dispatch both call dispatchEnvelope — and the author
	// (rule 6) may edit it. The same signer re-signs the new bytes with the
	// key this process already holds. An unsigned box-wui envelope, a lobby
	// note that never fanned out, is edited with its empty sig left empty.
	// A signed envelope and no key is the same 409: there is nothing to
	// re-sign with.
	pub := s.wuiPub()
	if m.FromBox != WUIBox || (m.EnvSig != "" && pub == nil) {
		writeErr(w, http.StatusConflict, "not_editable", "a box-signed message can only be edited by its box")
		return
	}
	resign := m.EnvSig != ""

	env, innerMsg, inner, err := reEnvelope(m, body.Body)
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("edit re-encode")
		writeErr(w, http.StatusInternalServerError, "internal", "edit not stored")
		return
	}
	if resign {
		signed, err := s.dispatchEnvelope(env.ToBox, env.Channel, env.ParentTaskID, pub, innerMsg)
		if err != nil {
			s.o.Log.Error().Err(err).Str("msg_id", id).Msg("edit re-sign")
			writeErr(w, http.StatusInternalServerError, "internal", "edit not stored")
			return
		}
		env = signed
		inner = signed.Msg
	}
	canon, err := env.Marshal()
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("edit envelope")
		writeErr(w, http.StatusInternalServerError, "internal", "edit not stored")
		return
	}
	now := s.o.Now().UTC().Truncate(time.Second)
	rev, err := s.o.Store.ApplyEdit(r.Context(), t.ID, id, store.Edit{
		Body: body.Body, Msg: inner, Env: canon, EditedBy: from, EditedAt: now})
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("edit store")
		writeErr(w, http.StatusInternalServerError, "internal", "edit not stored")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("msg_id", id).Str("by", from).Int("revision", rev).Msg("message edited")

	s.fanoutEdited(r.Context(), t.ID, m, canon, now, from, rev)
	writeJSON(w, http.StatusOK, editedPayload(m, canon, now, from, rev))
}

// editorID is the v:1 agent id the caller's messages are stamped with. It is
// resolved exactly as the browser socket resolves it (wui.go), so the id the
// send path wrote as from_id is the id the edit path compares against.
func (s *Server) editorID(r *http.Request, tenant string) (string, bool) {
	sess, err := s.wuiSession(r, tenant)
	if err != nil || sess == "" {
		return "", false
	}
	if msg.ValidID(sess) {
		return sess, true
	}
	return s.humans.session(tenant, sess), true
}

// reEnvelope rebuilds the stored envelope around the new body. The envelope is
// re-parsed rather than rebuilt from the message row's columns, because
// messages.channel is the STORED channel (a lobby message carries `lobby` even
// when its envelope had no channel tag): rebuilding from it would add a tag the
// original envelope never had, and an edit must change the body and nothing
// else.
func reEnvelope(m store.EditableMessage, body string) (*wire.Envelope, *msg.Message, []byte, error) {
	env, err := wire.ParseEnvelope(m.Env)
	if err != nil {
		return nil, nil, nil, err
	}
	inner, err := msg.Parse(env.Msg)
	if err != nil {
		return nil, nil, nil, err
	}
	inner.Body = body
	if err := inner.Validate(); err != nil {
		return nil, nil, nil, err
	}
	canon, err := msg.Canonical(inner)
	if err != nil {
		return nil, nil, nil, err
	}
	env.Msg = canon
	return env, inner, canon, nil
}

// editedPayload is the §4.4 view element the WUI already normalises, plus
// task_id and the §2.1 marker. cursor and received_at are the message's
// originals: an edit does not move it.
func editedPayload(m store.EditableMessage, canon []byte, at time.Time, by string, rev int) map[string]any {
	ds := []viewDelivery{}
	for _, d := range m.Deliveries {
		ds = append(ds, viewDelivery{ToBox: d.ToBox, State: d.State})
	}
	out := map[string]any{
		"task_id":     m.TaskID,
		"cursor":      encCursor(m.ReceivedAt, m.MsgID),
		"received_at": rfc(m.ReceivedAt),
		"env":         json.RawMessage(canon),
		"deliveries":  ds,
	}
	editedFields(out, at, by, rev)
	return out
}

// fanoutEdited pushes one message_edited frame to every browser socket that
// would have received the message's own `message` frame — the same audience
// rule, the editor's other tabs included, so two tabs of one member never
// disagree about what the message says.
func (s *Server) fanoutEdited(ctx context.Context, tenant string, m store.EditableMessage, canon []byte, at time.Time, by string, rev int) {
	p := parties{m.FromID, m.FromBox, m.ToID, m.ToBox}
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant && c.wants(m.TaskID, m.Channel, p) {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	if len(targets) == 0 {
		return
	}
	var e wire.Envelope
	if err := json.Unmarshal(canon, &e); err != nil {
		return
	}
	frame := map[string]any{"type": editedFrame, "task_id": m.TaskID, "msg_id": m.MsgID,
		"cursor": encCursor(m.ReceivedAt, m.MsgID), "received_at": rfc(m.ReceivedAt),
		"envelope": e.Msg, "env": json.RawMessage(canon)}
	if m.Channel != "" {
		frame["channel"] = m.Channel
	}
	if e.ParentTaskID != "" {
		frame["parent_task_id"] = e.ParentTaskID
	}
	editedFields(frame, at, by, rev)
	for _, c := range targets {
		c.write(ctx, frame) //nolint:errcheck
	}
}

// editPreflight answers CORS preflight for PATCH /v1/messages/{msg_id}. It
// introduces no new request header: a new header is a new preflight, and this
// repo has already broken sign-in that way once.
func (s *Server) editPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PATCH")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}
