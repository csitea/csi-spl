package hub

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// POST /v1/messages/{msg_id}/merge {"into": "<msg_id>"} — fold one message
// into its neighbor in the same thread.
//
// The owner, prd t1 topic 04130ea2: "the merge with previous and next works,
// but once the content is merged, the actual source of the merged content,
// the source card, should self-delete". The browser did it as a PATCH and a
// DELETE; on prd the DELETE never went out (Cloud Run request log,
// 2026-09-27: PATCH 845e637d 200 at 20:48:59Z, then nothing until a manual
// delete 9 s later). Here it is one request and one transaction: the kept
// message gets both bodies, older first, with a revision (specs/032), and the
// source row is deleted — both or neither.
//
// {msg_id} is the SOURCE, the row that goes away; "into" is the message that
// keeps the text. The hub joins the bodies itself, so two tabs racing an edit
// cannot make it write a stale one.
//
// Who may: the same as an edit plus a delete of both rows. Both rows have one
// author, and the caller is that author, the tenant owner or an admin (041's
// mayChangeTopic). Both are browser-authored (a box-signed envelope is its
// box's). They share a thread (task_id).
//
// Refusals, in order after the edit path's member / billing / notes.send /
// UUID checks: 400 bad_json (no into, or into = msg_id); 404 not_found
// (either row, or the read door); 409 not_same_thread; 409 not_same_author;
// 403 not_allowed; 409 not_editable; 409 is_card (the source opens its topic:
// deleting it would leave the topic without its card); 409 has_replies (the
// source has a thread of its own: moving it is specs/045's message move).

// mergedFrame replaces both a message_edited and a message_deleted frame, so
// every open tab applies the merge as one change.
const mergedFrame = "message_merged"

type mergeRequest struct {
	Into string `json:"into"`
}

func (s *Server) handleMergeMessage(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	from, ok := s.editorID(r, t.ID)
	if !ok || hum == "" {
		writeForbidden(w, rbac.NotesSend, "merging messages needs a signed-in member session")
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	if !s.permit(w, r, t.ID, hum, rbac.NotesSend) {
		return
	}
	srcID, keepID, ok := readMergeRequest(w, r)
	if !ok {
		return
	}
	now := s.o.Now()
	src, keep, pub, ok := s.mergePair(w, r, t.ID, hum, from, srcID, keepID, now)
	if !ok {
		return
	}
	older, newer := keep.Body, src.Body
	if !msgBefore(keep, src) {
		older, newer = src.Body, keep.Body
	}
	merged := joinBodies(older, newer)
	if tok, status, detail := s.demoBodyFits(r.Context(), t.ID, hum, merged); tok != "" { // specs/077 T012
		writeErr(w, status, tok, detail)
		return
	}
	if len(merged) > bodyMax {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "the merged body would be over 65536 bytes")
		return
	}
	canon, inner, sig, err := s.editedEnvelope(keep, merged, pub) // the edit path's rule 7: re-sign what this hub signed
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", keepID).Msg("merge envelope")
		writeErr(w, http.StatusInternalServerError, "internal", "merge not stored")
		return
	}
	at := now.UTC().Truncate(time.Second)
	rev, err := s.o.Store.MergeMessages(r.Context(), t.ID, keepID, srcID, store.Edit{
		Body: merged, Msg: inner, Env: canon, EditedBy: from, EditedAt: at, EnvSig: sig})
	switch {
	case errors.Is(err, store.ErrMergeHasReplies):
		writeErr(w, http.StatusConflict, "has_replies", "a message with replies of its own cannot be merged away")
		return
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", keepID).Str("from", srcID).Msg("merge store")
		writeErr(w, http.StatusInternalServerError, "internal", "merge not stored")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("msg_id", keepID).Str("merged_from", srcID).Str("by", from).Int("revision", rev).Msg("message merged")

	s.fanoutMerged(r.Context(), t.ID, keep, src, canon, at, from, rev)
	out := editedPayload(keep, canon, at, from, rev)
	out["merged_from"] = srcID
	writeJSON(w, http.StatusOK, out)
}

// readMergeRequest reads the source id from the path and the kept one from
// {into}; false has written the 400.
func readMergeRequest(w http.ResponseWriter, r *http.Request) (srcID, keepID string, ok bool) {
	srcID = strings.ToLower(r.PathValue("msg_id"))
	if !uuidRe.MatchString(srcID) {
		writeErr(w, http.StatusBadRequest, "bad_json", "msg_id must be a UUID")
		return "", "", false
	}
	var body mergeRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {into}")
		return "", "", false
	}
	keepID = strings.ToLower(strings.TrimSpace(body.Into))
	if !uuidRe.MatchString(keepID) || keepID == srcID {
		writeErr(w, http.StatusBadRequest, "bad_json", "into must be the UUID of another message")
		return "", "", false
	}
	return srcID, keepID, true
}

// mergePair reads both rows and applies the merge's refusals in order: one
// thread, one author, the caller may change it, both browser-authored and
// re-signable, and the source is not a topic's card. It answers the key to
// re-sign the kept row with (nil when it was never signed); false has
// written the refusal.
func (s *Server) mergePair(w http.ResponseWriter, r *http.Request, tenant, hum, from, srcID, keepID string,
	now time.Time) (src, keep store.EditableMessage, pub ed25519.PublicKey, ok bool) {
	if src, ok = s.mergeRow(w, r, tenant, srcID, now); !ok {
		return src, keep, nil, false
	}
	if keep, ok = s.mergeRow(w, r, tenant, keepID, now); !ok {
		return src, keep, nil, false
	}
	if src.TaskID != keep.TaskID {
		writeErr(w, http.StatusConflict, "not_same_thread", "only two messages of one thread can be merged")
		return src, keep, nil, false
	}
	if src.FromID != keep.FromID {
		writeErr(w, http.StatusConflict, "not_same_author", "only two messages of one author can be merged")
		return src, keep, nil, false
	}
	if !s.mayChangeTopic(r.Context(), tenant, hum, from, src.FromID) {
		writeErr(w, http.StatusForbidden, "not_allowed", "only the author, the tenant owner or an admin may merge these messages")
		return src, keep, nil, false
	}
	pub = s.wuiPub()
	if src.FromBox != WUIBox || keep.FromBox != WUIBox || (keep.EnvSig != "" && pub == nil) {
		writeErr(w, http.StatusConflict, "not_editable", "a box-signed message can only be edited by its box")
		return src, keep, nil, false
	}
	if !s.mergeSourceNotCard(w, r, tenant, src, now) {
		return src, keep, nil, false
	}
	if keep.EnvSig == "" {
		pub = nil
	}
	return src, keep, pub, true
}

// mergeSourceNotCard refuses a source that opens its topic: deleting it
// would leave the topic without its card (the lobby has no cards).
func (s *Server) mergeSourceNotCard(w http.ResponseWriter, r *http.Request, tenant string, src store.EditableMessage, now time.Time) bool {
	st, err := s.o.Store.CardState(r.Context(), tenant, src.MsgID, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return false
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", src.MsgID).Msg("merge card lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return false
	}
	lobby := s.o.LobbyTaskID != "" && src.TaskID == s.o.LobbyTaskID
	if st.IsParent == 1 && st.FirstOfTask && !lobby {
		writeErr(w, http.StatusConflict, "is_card", "the message that opens a topic cannot be merged away")
		return false
	}
	return true
}

// mergeRow reads one side of a merge: 404 when absent or behind the read door.
func (s *Server) mergeRow(w http.ResponseWriter, r *http.Request, tenant, id string, now time.Time) (store.EditableMessage, bool) {
	m, err := s.o.Store.GetEditable(r.Context(), tenant, id, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return m, false
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("merge lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return m, false
	}
	if !s.messageDoor(w, r, tenant, m) {
		return m, false
	}
	return m, true
}

// msgBefore is the thread order: received_at, then msg_id.
func msgBefore(a, b store.EditableMessage) bool {
	if !a.ReceivedAt.Equal(b.ReceivedAt) {
		return a.ReceivedAt.Before(b.ReceivedAt)
	}
	return a.MsgID < b.MsgID
}

// joinBodies is the WUI's joinBodies (csi-spl-wui/src/utils/msg-menu.mjs):
// both bodies, older first, a blank line between; an empty side adds nothing.
func joinBodies(older, newer string) string {
	a := strings.TrimRight(older, " \t\r\n\f\v")
	b := strings.TrimLeft(newer, " \t\r\n\f\v")
	switch {
	case a == "":
		return b
	case b == "":
		return a
	}
	return a + "\n\n" + b
}

// fanoutMerged sends ONE message_merged frame to every browser socket that
// was shown either message: the edited element of the kept row plus
// merged_from, the row to drop.
func (s *Server) fanoutMerged(ctx context.Context, tenant string, keep, src store.EditableMessage, canon []byte, at time.Time, by string, rev int) {
	pk := parties{keep.FromID, keep.FromBox, keep.ToID, keep.ToBox}
	ps := parties{src.FromID, src.FromBox, src.ToID, src.ToBox}
	mk := s.channelMemberSet(ctx, tenant, keep.Channel)
	ms := mk
	if src.Channel != keep.Channel {
		ms = s.channelMemberSet(ctx, tenant, src.Channel)
	}
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant && (c.wants(keep.TaskID, keep.Channel, pk, mk) || c.wants(src.TaskID, src.Channel, ps, ms)) {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	targets = s.dropHiddenConns(ctx, tenant, src.MsgID, s.dropHiddenConns(ctx, tenant, keep.MsgID, targets)) // specs/077 T016
	if len(targets) == 0 {
		return
	}
	var e wire.Envelope
	if err := json.Unmarshal(canon, &e); err != nil {
		return
	}
	frame := map[string]any{"type": mergedFrame, "task_id": keep.TaskID, "msg_id": keep.MsgID,
		"merged_from": src.MsgID, "cursor": encCursor(keep.ReceivedAt, keep.MsgID),
		"received_at": rfc(keep.ReceivedAt), "envelope": e.Msg, "env": json.RawMessage(canon)}
	if keep.Channel != "" {
		frame["channel"] = keep.Channel
	}
	if e.ParentTaskID != "" {
		frame["parent_task_id"] = e.ParentTaskID
	}
	editedFields(frame, at, by, rev)
	kindFields(frame, keep.Kind, keep.KindSetAt, keep.KindSetBy)
	b, err := encodeFrame(frame)
	if err != nil {
		return
	}
	for _, c := range targets {
		c.writeRaw(ctx, b) //nolint:errcheck
	}
}

// mergePreflight answers CORS preflight for the merge. No new request header
// (a new header is a new preflight, and sign-in has broken that way before).
func (s *Server) mergePreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
