package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"

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
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	actor, ok := s.editorID(r, t.ID)
	if !ok {
		writeForbidden(w, rbac.NotesSend, "adding an emoji needs a signed-in member session")
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
	emoji, ok := reactionEmoji(w, r)
	if !ok {
		return
	}
	now := s.o.Now()
	m, err := s.o.Store.GetEditable(r.Context(), t.ID, id, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("reaction lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return
	}
	// The door on THIS message (CLE-34986; it was the topic's, so a mixed
	// topic let a member react to a DM they are not an end of). A message you
	// cannot see is a 404, so the refusal does not confirm that it exists.
	if !s.messageDoor(w, r, t.ID, m) {
		return
	}
	if add {
		err = s.o.Store.AddReaction(r.Context(), t.ID, id, actor, emoji, now)
	} else {
		err = s.o.Store.RemoveReaction(r.Context(), t.ID, id, actor, emoji, now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("reaction store")
		writeErr(w, http.StatusInternalServerError, "internal", "emoji not stored")
		return
	}
	rows, err := s.o.Store.ReactionsFor(r.Context(), t.ID, []string{id})
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("reaction list")
		writeErr(w, http.StatusInternalServerError, "internal", "emoji not stored")
		return
	}
	grouped := groupReactions(rows[id])
	s.fanoutReaction(r.Context(), t.ID, m, grouped)
	writeJSON(w, http.StatusOK, map[string]any{
		"msg_id":    m.MsgID,
		"task_id":   m.TaskID,
		"reactions": grouped,
	})
}

// reactionEmoji reads {emoji}, refuses anything the picker does not offer and
// returns the picker's own spelling of it (canonicalEmoji).
// false means the response is already written.
func reactionEmoji(w http.ResponseWriter, r *http.Request) (string, bool) {
	var body reactionRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {emoji}")
		return "", false
	}
	emoji := canonicalEmoji(body.Emoji)
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
	for _, c := range targets {
		c.write(ctx, frame) //nolint:errcheck
	}
}

// reactionPreflight is CORS for PUT and DELETE
// /v1/messages/{msg_id}/reactions. No new request header.
func (s *Server) reactionPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}
