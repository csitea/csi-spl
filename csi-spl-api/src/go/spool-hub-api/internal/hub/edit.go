package hub

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
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
// received_at are all unchanged, because a typo fix must not reorder a topic.
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
	id, body, ok := readEditRequest(w, r)
	if !ok {
		return
	}
	if tok, status, detail := s.demoBodyFits(r.Context(), t.ID, hum, body); tok != "" { // specs/077 T012
		writeErr(w, status, tok, detail)
		return
	}
	m, pub, ok := s.editTarget(w, r, t.ID, hum, id, from)
	if !ok {
		return
	}
	canon, inner, sig, err := s.editedEnvelope(m, body, pub)
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("edit envelope")
		writeErr(w, http.StatusInternalServerError, "internal", "edit not stored")
		return
	}
	now := s.o.Now().UTC().Truncate(time.Second)
	rev, err := s.o.Store.ApplyEdit(r.Context(), t.ID, id, store.Edit{
		Body: body, Msg: inner, Env: canon, EditedBy: from, EditedAt: now, EnvSig: sig})
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

// readEditRequest reads the message id from the path and the new body; false
// has written the refusal.
func readEditRequest(w http.ResponseWriter, r *http.Request) (id, body string, ok bool) {
	id = strings.ToLower(r.PathValue("msg_id"))
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_json", "msg_id must be a UUID")
		return "", "", false
	}
	var req editRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, bodyMax+4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {body}")
		return "", "", false
	}
	// The composer's own empty guard has been bypassed before (CLE-3433 found
	// a body = "" row in the dev store), so the hub refuses it too rather than
	// trusting the one caller it happens to know about.
	if strings.TrimSpace(req.Body) == "" {
		writeErr(w, http.StatusBadRequest, "empty_body", "body must not be empty")
		return "", "", false
	}
	if len(req.Body) > bodyMax {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "body must be at most 65536 bytes")
		return "", "", false
	}
	return id, req.Body, true
}

// editTarget is rules 5-7: the message exists and the reader may see it, the
// caller may edit it, and the hub can re-sign it. It answers the message
// and, for a signed box-wui envelope, the key to re-sign with (nil = leave
// the empty signature empty). false has written the refusal.
func (s *Server) editTarget(w http.ResponseWriter, r *http.Request, tenant, hum, id, from string) (store.EditableMessage, ed25519.PublicKey, bool) {
	m, err := s.o.Store.GetEditable(r.Context(), tenant, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound): // rule 5: absent, another tenant's, or past retention
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return m, nil, false
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("edit lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return m, nil, false
	}
	if !s.messageDoor(w, r, tenant, m) { // the read door before rule 6
		return m, nil, false
	}
	// Rule 6 (SPL-1291, owner 2026-09-30 "it MUST work for all the other roles
	// as well"): the author edits their own message and the title of the topics
	// they started (a title is the first line of the root message); the tenant
	// owner and an admin edit anyone's, the same author/owner/admin rule that
	// already governs topic archive/merge/move (041 mayChangeTopic). Every human
	// role holds notes.send (rule 4), so this gives EVERY role its own; agents
	// stay out via rule 7 below (a non-box-wui or box-signed envelope the hub
	// cannot re-sign is 409 not_editable). The token stays not_author: it is the
	// one the WUI already maps and it still means "you are not allowed to edit
	// this one".
	if !s.mayChangeTopic(r.Context(), tenant, hum, from, m.FromID) { // rule 6
		writeErr(w, http.StatusForbidden, "not_author", "only the author, the tenant owner or an admin may edit this message")
		return m, nil, false
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
		return m, nil, false
	}
	if m.EnvSig == "" {
		return m, nil, true
	}
	return m, pub, true
}

// editedEnvelope is m's envelope with body, re-signed with pub when it was
// signed: the canonical bytes, the inner v:1 message and the signature.
func (s *Server) editedEnvelope(m store.EditableMessage, body string, pub ed25519.PublicKey) (canon, inner []byte, sig string, err error) {
	env, innerMsg, inner, err := reEnvelope(m, body)
	if err != nil {
		return nil, nil, "", fmt.Errorf("re-encode: %w", err)
	}
	if pub != nil {
		signed, err := s.dispatchEnvelope(env.ToBox, env.Channel, env.ParentTaskID, pub, innerMsg)
		if err != nil {
			return nil, nil, "", fmt.Errorf("re-sign: %w", err)
		}
		env, inner = signed, signed.Msg
	}
	canon, err = env.Marshal()
	return canon, inner, env.Sig, err
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
	kindFields(out, m.Kind, m.KindSetAt, m.KindSetBy)
	return out
}

// fanoutEdited pushes one message_edited frame to every browser socket that
// would have received the message's own `message` frame — the same audience
// rule, the editor's other tabs included, so two tabs of one member never
// disagree about what the message says.
func (s *Server) fanoutEdited(ctx context.Context, tenant string, m store.EditableMessage, canon []byte, at time.Time, by string, rev int) {
	p := parties{m.FromID, m.FromBox, m.ToID, m.ToBox}
	members := s.channelMemberSet(ctx, tenant, m.Channel) // rdb 0028, as fanoutWUI
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant && c.wants(m.TaskID, m.Channel, p, members) {
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
	frame := newEditedMsg(m, canon, e, at, by, rev)
	b, err := encodeFrame(frame)
	if err != nil {
		return
	}
	for _, c := range targets {
		c.writeRaw(ctx, b) //nolint:errcheck
	}
}

// editedMsg is the message_edited frame (contract §3). Its fields are in key
// order, so it encodes byte for byte as the map it replaced (encoding/json
// sorts map keys); the embedded pointers carry editedFields' and kindFields'
// all-or-nothing groups, so a nil one omits exactly the keys they omit
// (perf round 4, G12).
type editedMsg struct {
	Channel string `json:"channel,omitempty"`
	Cursor  string `json:"cursor"`
	*editedMark
	Env      json.RawMessage `json:"env"`
	Envelope json.RawMessage `json:"envelope"`
	*kindMark
	MsgID        string `json:"msg_id"`
	ParentTaskID string `json:"parent_task_id,omitempty"`
	ReceivedAt   string `json:"received_at"`
	Revision     int    `json:"revision,omitempty"` // set only with editedMark, as editedFields
	TaskID       string `json:"task_id"`
	Type         string `json:"type"`
}

type editedMark struct {
	EditedAt string `json:"edited_at"`
	EditedBy string `json:"edited_by"`
}

type kindMark struct {
	Kind      string `json:"kind"`
	KindSetAt string `json:"kind_set_at"`
	KindSetBy string `json:"kind_set_by"`
}

func newEditedMsg(m store.EditableMessage, canon []byte, e wire.Envelope, at time.Time, by string, rev int) *editedMsg {
	f := &editedMsg{Channel: m.Channel, Cursor: encCursor(m.ReceivedAt, m.MsgID),
		Env: json.RawMessage(canon), Envelope: e.Msg, MsgID: m.MsgID,
		ParentTaskID: e.ParentTaskID, ReceivedAt: rfc(m.ReceivedAt), TaskID: m.TaskID, Type: editedFrame}
	if !at.IsZero() {
		f.editedMark = &editedMark{EditedAt: rfc(at), EditedBy: by}
		if rev > 0 {
			f.Revision = rev
		}
	}
	if !m.KindSetAt.IsZero() {
		f.kindMark = &kindMark{Kind: m.Kind, KindSetAt: rfc(m.KindSetAt), KindSetBy: m.KindSetBy}
	}
	return f
}

// deletedFrame tells every open thread to drop the row. It is not a second
// `message` frame: mergeById ignores a msg_id it already holds.
const deletedFrame = "message_deleted"

// DELETE /v1/messages/{msg_id} — the author removes one of their own
// browser-sent messages. Same member, billing and notes.send checks as an
// edit. The row is deleted, not blanked: deliveries and the revision register
// cascade with it, and a later read of the topic no longer returns it.
func (s *Server) handleDeleteMessage(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	from, ok := s.editorID(r, t.ID)
	if !ok {
		writeForbidden(w, rbac.NotesSend, "deleting a message needs a signed-in member session")
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
	m, err := s.o.Store.GetEditable(r.Context(), t.ID, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("delete lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return
	}
	if !s.messageDoor(w, r, t.ID, m) { // the read door before the author gate
		return
	}
	if m.FromID != from {
		writeErr(w, http.StatusForbidden, "not_author", "only the author may delete this message")
		return
	}
	// Same author gate as an edit: a box-signed envelope is that box's, and
	// the browser must not offer a delete the hub will refuse.
	if m.FromBox != WUIBox {
		writeErr(w, http.StatusConflict, "not_editable", "a box-signed message can only be deleted by its box")
		return
	}
	if err := s.o.Store.DeleteMessage(r.Context(), t.ID, id); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "not_found", "no such message")
			return
		}
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("delete store")
		writeErr(w, http.StatusInternalServerError, "internal", "delete not stored")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("msg_id", id).Str("by", from).Msg("message deleted")
	s.fanoutDeleted(r.Context(), t.ID, m)
	w.WriteHeader(http.StatusNoContent)
}

// fanoutDeleted tells every browser socket that was shown this message to
// drop it, including the author's other tabs.
func (s *Server) fanoutDeleted(ctx context.Context, tenant string, m store.EditableMessage) {
	p := parties{m.FromID, m.FromBox, m.ToID, m.ToBox}
	members := s.channelMemberSet(ctx, tenant, m.Channel)
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant && c.wants(m.TaskID, m.Channel, p, members) {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	if len(targets) == 0 {
		return
	}
	frame := newDeletedMsg(m)
	b, err := encodeFrame(frame)
	if err != nil {
		return
	}
	for _, c := range targets {
		c.writeRaw(ctx, b) //nolint:errcheck
	}
}

// deletedMsg is the message_deleted frame, its fields in key order like
// editedMsg's (perf round 4, G12).
type deletedMsg struct {
	Channel string `json:"channel,omitempty"`
	MsgID   string `json:"msg_id"`
	TaskID  string `json:"task_id"`
	Type    string `json:"type"`
}

func newDeletedMsg(m store.EditableMessage) *deletedMsg {
	return &deletedMsg{Channel: m.Channel, MsgID: m.MsgID, TaskID: m.TaskID, Type: deletedFrame}
}

// editPreflight answers CORS preflight for PATCH and DELETE
// /v1/messages/{msg_id}. It introduces no new request header: a new header
// is a new preflight, and this repo has already broken sign-in that way once.
func (s *Server) editPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
