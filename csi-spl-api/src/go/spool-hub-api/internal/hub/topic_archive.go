package hub

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Archive, unarchive and delete a topic card (SPL-983, specs/041
// contracts/topic-archive-v1.md).
//
// The owner, 2026-09-26: "archive and delete a topic or msg in direct msgs
// (aka card with is_parent=1), which if archived will add a soft delete = 1
// and if delete will actually delete not only the parent msg or topic but
// also all of its children". And, answering who may: the card's author, the
// tenant owner and an admin; nobody else, and never an agent. An agent has
// no route here at all: every one is a member-session browser route.

const (
	topicArchivedFrame = "topic_archived"
	topicDeletedFrame  = "topic_deleted"
)

// topicCard is one resolved request on a card: who asks, what the card is,
// and whether the caller may change it.
type topicCard struct {
	t       store.Tenant
	from    string // the caller's v:1 id, as editorID resolves it
	m       store.EditableMessage
	st      store.CardState
	ownTask string // the card's task, or "" for a lobby card (store.TopicArchive)
	may     bool   // author, tenant owner or admin (spec §3.3)
}

// resolveCard runs contract §1 in order. mutate adds billing, notes.send
// and the §3.3 gate. ok=false means it answered.
func (s *Server) resolveCard(w http.ResponseWriter, r *http.Request, mutate bool) (topicCard, bool) {
	var c topicCard
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return c, false
	}
	c.t = t
	from, ok := s.editorID(r, t.ID)
	if !ok || hum == "" {
		writeForbidden(w, rbac.NotesSend, "archiving or deleting a topic needs a signed-in member session")
		return c, false
	}
	c.from = from
	perm := rbac.TopicsRead
	if mutate {
		if !billing.AllowsWrite(t.BillingStatus) {
			writeUnpaid(w)
			return c, false
		}
		perm = rbac.NotesSend
	}
	if !s.permit(w, r, t.ID, hum, perm) {
		return c, false
	}
	id := strings.ToLower(r.PathValue("msg_id"))
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_json", "msg_id must be a UUID")
		return c, false
	}
	now := s.o.Now()
	m, err := s.o.Store.GetEditable(r.Context(), t.ID, id, now)
	if err == nil {
		c.st, err = s.o.Store.CardState(r.Context(), t.ID, id, now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return c, false
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("topic card lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return c, false
	}
	c.m = m
	if !s.messageDoor(w, r, t.ID, m) {
		return c, false
	}
	lobby := s.o.LobbyTaskID != "" && m.TaskID == s.o.LobbyTaskID
	if c.st.IsParent != 1 || (!lobby && !c.st.FirstOfTask) {
		writeErr(w, http.StatusConflict, "not_a_card", "only a topic's opening card can be archived or deleted")
		return c, false
	}
	if !lobby {
		c.ownTask = m.TaskID
	}
	if c.st.IssueTopic {
		writeErr(w, http.StatusConflict, "issue_topic", "an issue's discussion is archived with its issue, not here")
		return c, false
	}
	c.may = s.mayChangeTopic(r.Context(), t.ID, hum, from, m.FromID)
	if mutate && !c.may {
		writeErr(w, http.StatusForbidden, "not_allowed", "only the author, the tenant owner or an admin may do this")
		return c, false
	}
	return c, true
}

// mayChangeTopic is spec §3.3: the card's author, the tenant owner or an
// admin. The author test is the edit path's (from_id = the caller's v:1 id).
func (s *Server) mayChangeTopic(ctx context.Context, tenant, hum, from, author string) bool {
	if from != "" && from == author {
		return true
	}
	a, err := s.access(ctx, hum, tenant)
	return err == nil && (a.TenantOwner || a.Role == rbac.Admin)
}

// PUT (archive) and DELETE (unarchive) /v1/messages/{msg_id}/archive.
func (s *Server) handleArchiveTopic(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	c, ok := s.resolveCard(w, r, true)
	if !ok {
		return
	}
	archive := r.Method == http.MethodPut
	now := s.o.Now().UTC().Truncate(time.Second)
	st, err := s.o.Store.SetArchived(r.Context(), c.t.ID, c.m.MsgID, c.from, now, archive)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", c.m.MsgID).Msg("archive store")
		writeErr(w, http.StatusInternalServerError, "internal", "archive not stored")
		return
	}
	s.o.Log.Info().Str("tenant", c.t.ID).Str("msg_id", c.m.MsgID).Str("by", c.from).Bool("archived", archive).Msg("topic archive")
	out := archivedBody(c.m, st)
	s.fanoutTopic(r.Context(), c.t.ID, c.m, withType(topicArchivedFrame, c.m, out))
	writeJSON(w, http.StatusOK, out)
}

func archivedBody(m store.EditableMessage, st store.CardState) map[string]any {
	out := map[string]any{"msg_id": m.MsgID, "task_id": m.TaskID, "archived": !st.ArchivedAt.IsZero()}
	if !st.ArchivedAt.IsZero() {
		out["archived_at"], out["archived_by"] = rfc(st.ArchivedAt), st.ArchivedBy
	}
	return out
}

// withType is body as a frame: the type and the card's channel added.
func withType(typ string, m store.EditableMessage, body map[string]any) map[string]any {
	f := map[string]any{"type": typ}
	for k, v := range body {
		f[k] = v
	}
	if m.Channel != "" {
		f["channel"] = m.Channel
	}
	return f
}

// DELETE /v1/messages/{msg_id}/topic: the card and every child, one
// transaction (store.DeleteTopic).
func (s *Server) handleDeleteTopic(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	c, ok := s.resolveCard(w, r, true)
	if !ok {
		return
	}
	set, err := s.o.Store.DeleteTopic(r.Context(), c.t.ID, c.m.MsgID, c.ownTask)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "too_deep", "this topic nests deeper than a delete will walk")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", c.m.MsgID).Msg("topic delete store")
		writeErr(w, http.StatusInternalServerError, "internal", "delete not stored")
		return
	}
	s.o.Log.Info().Str("tenant", c.t.ID).Str("msg_id", c.m.MsgID).Str("by", c.from).Int("rows", len(set.MsgIDs)).Msg("topic deleted")
	out := map[string]any{"msg_id": c.m.MsgID, "task_id": c.m.TaskID, "deleted": len(set.MsgIDs),
		"msg_ids": set.MsgIDs, "task_ids": set.TaskIDs}
	s.fanoutTopic(r.Context(), c.t.ID, c.m, withType(topicDeletedFrame, c.m, out))
	writeJSON(w, http.StatusOK, out)
}

// GET /v1/view/messages/{msg_id}/topic: the confirm dialog's reply count and
// what the caller may do (contract §3).
func (s *Server) handleViewTopicSize(w http.ResponseWriter, r *http.Request) {
	r = r.WithContext(store.WithMemo(r.Context()))
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	c, ok := s.resolveCard(w, r, false)
	if !ok {
		return
	}
	set, err := s.o.Store.TopicOf(r.Context(), c.t.ID, c.m.MsgID, c.ownTask)
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", c.m.MsgID).Msg("topic size")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return
	}
	out := archivedBody(c.m, c.st)
	out["replies"], out["task_ids"], out["can_delete"], out["can_archive"] = set.Replies(), set.TaskIDs, c.may, c.may
	writeJSON(w, http.StatusOK, out)
}

// GET /v1/view/archived (contract §5): the archived cards the caller may
// read, newest archived first.
func (s *Server) handleViewArchived(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	w.Header().Set("Cache-Control", "no-store")
	hum, ok := s.readerID(r, t.ID)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "archive unavailable")
		return
	}
	if !s.permit(w, r, t.ID, hum, rbac.TopicsRead) {
		return
	}
	q := store.ArchivedQuery{Limit: viewLimit(r) + 1, Now: s.o.Now()}
	if hum != "" {
		mine, err := s.readerChannels(r.Context(), t.ID, hum)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "archive unavailable")
			return
		}
		q.Reader, q.ReaderChannels = hum, mine
	}
	if c := r.URL.Query().Get("before"); c != "" {
		at, id, err := decCursor(c)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_cursor", "before is not a cursor from this API")
			return
		}
		q.BeforeAt, q.BeforeID = at, id
	}
	from, _ := s.editorID(r, t.ID)
	cards, err := s.o.Store.ArchivedCards(r.Context(), t.ID, q)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("archived cards")
		writeErr(w, http.StatusInternalServerError, "internal", "archive unavailable")
		return
	}
	var next *string
	if len(cards) == q.Limit {
		cards = cards[:q.Limit-1]
		c := encCursor(cards[len(cards)-1].ArchivedAt, cards[len(cards)-1].MsgID)
		next = &c
	}
	ids, own, rows := make([]string, len(cards)), make([]string, len(cards)), make([]store.ViewMsg, len(cards))
	for i, c := range cards {
		ids[i], rows[i] = c.MsgID, c.ViewMsg
		if s.o.LobbyTaskID == "" || c.TaskID != s.o.LobbyTaskID {
			own[i] = c.TaskID
		}
	}
	replies, err := s.o.Store.TopicReplies(r.Context(), t.ID, ids, own)
	if err == nil && len(ids) > 0 {
		var react map[string][]store.StoredReaction
		if react, err = s.o.Store.ReactionsFor(r.Context(), t.ID, ids); err == nil {
			views := viewMsgs(rows, react)
			out := make([]map[string]any, len(cards))
			for i, c := range cards {
				out[i] = map[string]any{"message": views[i], "msg_id": c.MsgID, "task_id": c.TaskID,
					"archived_at": rfc(c.ArchivedAt), "archived_by": c.ArchivedBy, "replies": replies[c.MsgID],
					"can_delete": hum == "" || s.mayChangeTopic(r.Context(), t.ID, hum, from, c.FromID)}
				if c.Channel != "" {
					out[i]["channel"] = c.Channel
				}
			}
			writeJSON(w, http.StatusOK, map[string]any{"cards": out, "next": next})
			return
		}
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("archived replies")
		writeErr(w, http.StatusInternalServerError, "internal", "archive unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"cards": []any{}, "next": next})
}

// fanoutTopic sends frame to every browser socket that was shown the card
// (the audience of 032's fanoutDeleted).
func (s *Server) fanoutTopic(ctx context.Context, tenant string, m store.EditableMessage, frame map[string]any) {
	p := parties{m.FromID, m.FromBox, m.ToID, m.ToBox}
	members := s.channelMemberSet(ctx, tenant, m.Channel)
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant && (c.wants(m.TaskID, m.Channel, p, members) || c.wants(m.MsgID, m.Channel, p, members)) {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	for _, c := range targets {
		c.write(ctx, frame) //nolint:errcheck
	}
}

// topicPreflight answers CORS preflight for the archive and topic routes.
// No new request header (a new header is a new preflight; see 032).
func (s *Server) topicPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}
