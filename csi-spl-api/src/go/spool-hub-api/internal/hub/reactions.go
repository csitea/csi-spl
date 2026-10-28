package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// message_reaction is its own frame, like message_edited. A second `message`
// frame for a msg_id the browser already holds is dropped, so an emoji would
// never show on a card that is already on screen.
const reactionFrame = "message_reaction"

// viewReaction is one emoji and everyone who added it. Actors are sorted so
// two readers see the same payload. Omitted nowhere: an empty list is the
// message with no emoji, and a reload has to be able to clear one.
type viewReaction struct {
	Emoji  string   `json:"emoji"`
	Actors []string `json:"actors"`
}

type reactionRequest struct {
	Emoji string `json:"emoji"`
}

// groupReactions folds stored rows into one chip per emoji, in the order the
// first of each emoji was added. Actors within a chip are sorted.
func groupReactions(rows []store.StoredReaction) []viewReaction {
	if len(rows) == 0 {
		return []viewReaction{}
	}
	order := make([]string, 0, len(rows))
	by := map[string][]string{}
	for _, r := range rows {
		if _, ok := by[r.Emoji]; !ok {
			order = append(order, r.Emoji)
		}
		by[r.Emoji] = append(by[r.Emoji], r.Actor)
	}
	out := make([]viewReaction, 0, len(order))
	for _, emoji := range order {
		actors := by[emoji]
		sort.Strings(actors)
		out = append(out, viewReaction{Emoji: emoji, Actors: actors})
	}
	return out
}

// PUT adds the caller's emoji. DELETE removes it. The body is {emoji} either
// way. The message may be is_parent 0 or 1; both are the same row.
func (s *Server) handlePutReaction(w http.ResponseWriter, r *http.Request) {
	s.changeReaction(w, r, true)
}

func (s *Server) handleDeleteReaction(w http.ResponseWriter, r *http.Request) {
	s.changeReaction(w, r, false)
}

func (s *Server) changeReaction(w http.ResponseWriter, r *http.Request, add bool) {
	t, actor, id, emoji, ok := s.reactionCaller(w, r)
	if !ok {
		return
	}
	c := reactionChange{tenant: t.ID, msgID: id, actor: actor, emoji: emoji, add: add, now: s.o.Now()}
	m, ok := s.reactionTarget(w, r, c.tenant, c.msgID, c.now)
	if !ok {
		return
	}
	grouped, ok := s.reactionStore(w, r, c)
	if !ok {
		return
	}
	s.fanoutReaction(r.Context(), c.tenant, m, grouped)
	if c.add && c.emoji == reportEmoji {
		s.reported(r.Context(), c.tenant, m) // after the reaction frame: a hide drops the row last
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"msg_id":    m.MsgID,
		"task_id":   m.TaskID,
		"reactions": grouped,
	})
}

// reactionCaller answers who may react and with what: the member session,
// billing, notes.send, the msg_id and the emoji, in that order.
// false means the response is already written.
func (s *Server) reactionCaller(w http.ResponseWriter, r *http.Request) (t store.Tenant, actor, id, emoji string, ok bool) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return t, "", "", "", false
	}
	actor, ok = s.editorID(r, t.ID)
	if !ok {
		writeForbidden(w, rbac.NotesSend, "adding an emoji needs a signed-in member session")
		return t, "", "", "", false
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return t, "", "", "", false
	}
	if !s.permit(w, r, t.ID, hum, rbac.NotesSend) {
		return t, "", "", "", false
	}
	id = strings.ToLower(r.PathValue("msg_id"))
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_json", "msg_id must be a UUID")
		return t, "", "", "", false
	}
	emoji, ok = reactionEmoji(w, r, s.reportAllowed(t.ID))
	return t, actor, id, emoji, ok
}

// reactionTarget reads the message and refuses one the caller may not see.
// false means the response is already written.
func (s *Server) reactionTarget(w http.ResponseWriter, r *http.Request, tenant, id string, now time.Time) (store.EditableMessage, bool) {
	m, err := s.o.Store.GetEditable(r.Context(), tenant, id, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return m, false
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("reaction lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return m, false
	}
	// The door on THIS message (it was the topic's, so a mixed
	// topic let a member react to a DM they are not an end of). A message you
	// cannot see is a 404, so the refusal does not confirm that it exists.
	if !s.messageDoor(w, r, tenant, m) {
		return m, false
	}
	return m, true
}

// reactionChange is one caller adding (add) or removing their emoji on one
// message, at now.
type reactionChange struct {
	tenant, msgID, actor, emoji string
	add                         bool
	now                         time.Time
}

// reactionStore adds or removes the caller's emoji and returns the message's
// chips as they now stand. false means the response is already written.
func (s *Server) reactionStore(w http.ResponseWriter, r *http.Request, c reactionChange) ([]viewReaction, bool) {
	tenant, id := c.tenant, c.msgID
	var err error
	if c.add {
		err = s.o.Store.AddReaction(r.Context(), tenant, id, c.actor, c.emoji, c.now)
	} else {
		err = s.o.Store.RemoveReaction(r.Context(), tenant, id, c.actor, c.emoji, c.now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return nil, false
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("reaction store")
		writeErr(w, http.StatusInternalServerError, "internal", "emoji not stored")
		return nil, false
	}
	rows, err := s.o.Store.ReactionsFor(r.Context(), tenant, []string{id})
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("reaction list")
		writeErr(w, http.StatusInternalServerError, "internal", "emoji not stored")
		return nil, false
	}
	return groupReactions(rows[id]), true
}

// reactionEmoji reads {emoji}, refuses anything the picker does not offer and
// returns the picker's own spelling of it (canonicalEmoji). report admits
// the demo workspace's report glyph too (demo_moderation.go).
// false means the response is already written.
func reactionEmoji(w http.ResponseWriter, r *http.Request, report bool) (string, bool) {
	var body reactionRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {emoji}")
		return "", false
	}
	emoji := canonicalEmoji(body.Emoji)
	if report && strings.TrimSuffix(body.Emoji, vs16) == reportEmoji {
		emoji = reportEmoji
	}
	if emoji == "" {
		writeErr(w, http.StatusBadRequest, "bad_emoji", "emoji must be one offered glyph")
		return "", false
	}
	return emoji, true
}

// fanoutReaction tells every browser socket that was shown this message,
// including the actor's other tabs.
func (s *Server) fanoutReaction(ctx context.Context, tenant string, m store.EditableMessage, reactions []viewReaction) {
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
	targets = s.dropHiddenConns(ctx, tenant, m.MsgID, targets)
	if len(targets) == 0 {
		return
	}
	if reactions == nil {
		reactions = []viewReaction{}
	}
	frame := map[string]any{
		"type":      reactionFrame,
		"task_id":   m.TaskID,
		"msg_id":    m.MsgID,
		"reactions": reactions,
	}
	if m.Channel != "" {
		frame["channel"] = m.Channel
	}
	b, err := encodeFrame(frame)
	if err != nil {
		return
	}
	for _, c := range targets {
		c.writeRaw(ctx, b) //nolint:errcheck
	}
}

// reactionPreflight is CORS for PUT and DELETE
// /v1/messages/{msg_id}/reactions. No new request header.
func (s *Server) reactionPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
