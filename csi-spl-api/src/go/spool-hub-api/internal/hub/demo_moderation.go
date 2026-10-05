package hub

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Report and hide in the demo workspace (specs/077 3.6 "report /
// moderation", T016 part A; rdb 0128).
//
//   - report: any member of the demo workspace adds the reportEmoji reaction
//     (PUT /v1/messages/{msg_id}/reactions). It is a reaction row, so one
//     reporter counts once; the glyph is refused in every other workspace.
//   - the reportHideAt-th distinct reporter hides the message (set_by
//     "reports"), unless a moderator has already decided on it.
//   - a moderator (moderatePerm: admin and biz_owner, never demo_user) hides
//     or unhides it: PUT / DELETE /v1/messages/{msg_id}/hidden.
//
// A hidden message is gone from every read of a member without moderatePerm
// (the views, search, flow, previews, id links, the message door of every
// message route, socket frames) and stays readable to the moderators,
// marked hidden. Outside the demo workspace nothing is read or filtered.

const (
	reportEmoji  = "🚩"
	reportHideAt = 3
	moderatePerm = rbac.MembersInvite // the member-remove permission part B's ban uses
	hiddenFrame  = "message_hidden"
)

// modView is what one reader may see of the demo workspace's hidden
// messages. The zero value hides nothing (any other workspace, or none
// hidden).
type modView struct {
	hidden    map[string]store.HiddenMessage
	moderator bool
}

// moderation reads hum's modView of tenant: one store read in the demo
// workspace, none elsewhere. Fails closed: the caller answers 500 on error.
func (s *Server) moderation(ctx context.Context, tenant, hum string) (modView, error) {
	mm, ok := s.o.Store.(store.MessageModeration)
	if !ok || s.o.DemoWorkspace == "" || tenant != s.o.DemoWorkspace {
		return modView{}, nil
	}
	hidden, err := mm.HiddenMessages(ctx, tenant, s.o.Now())
	if err != nil || len(hidden) == 0 {
		return modView{}, err
	}
	return modView{hidden: hidden, moderator: s.isModerator(ctx, tenant, hum)}, nil
}

func (s *Server) isModerator(ctx context.Context, tenant, hum string) bool {
	if hum == "" {
		return false
	}
	a, err := s.access(ctx, hum, tenant)
	return err == nil && !s.demoFenced(a, tenant) && a.Can(moderatePerm)
}

// drops: the reader may not see message id.
func (v modView) drops(id string) bool {
	_, ok := v.hidden[id]
	return ok && !v.moderator
}

// marks: the reader is a moderator and message id is hidden.
func (v modView) marks(id string) bool {
	_, ok := v.hidden[id]
	return ok && v.moderator
}

// dropsTopic: a topic row of task whose subject is a hidden message's (its
// opening message) is gone too. Matched on the text, so a store that keeps
// only the subject's source (Postgres TopicRow.FirstMsg) is covered.
func (v modView) dropsTopic(task, subj string) bool {
	if v.moderator {
		return false
	}
	for _, h := range v.hidden {
		if h.TaskID == task && subject(h.Body) == subj {
			return true
		}
	}
	return false
}

// keepMsgs is rows without the ones the reader may not see.
func (v modView) keepMsgs(rows []store.ViewMsg) []store.ViewMsg {
	if len(v.hidden) == 0 || v.moderator {
		return rows
	}
	out := rows[:0:0]
	for _, m := range rows {
		if !v.drops(m.MsgID) {
			out = append(out, m)
		}
	}
	return out
}

// markMsgs sets hidden on out[i] for a moderator (out is viewMsgsIn(rows)).
func (v modView) markMsgs(rows []store.ViewMsg, out []viewMsg) {
	for i := range rows {
		if i < len(out) && v.marks(rows[i].MsgID) {
			out[i].Hidden = true
		}
	}
}

// keepTopics is out without the topic rows whose opening message is hidden.
func (v modView) keepTopics(out []viewTopic) []viewTopic {
	if len(v.hidden) == 0 || v.moderator {
		return out
	}
	kept := out[:0]
	for _, t := range out {
		if !v.dropsTopic(t.TaskID, t.Subject) {
			kept = append(kept, t)
		}
	}
	return kept
}

// keepResults filters one search section: a message or file hit by its
// msg_id, a topic hit by its title.
func (v modView) keepResults(rs []any) []any {
	if len(v.hidden) == 0 {
		return rs
	}
	kept := rs[:0]
	for _, r := range rs {
		m, _ := r.(map[string]any)
		id, _ := m["msg_id"].(string)
		task, _ := m["task_id"].(string)
		title, _ := m["title"].(hl)
		switch {
		case id != "" && v.marks(id):
			m["hidden"] = true
		case id != "" && v.drops(id), id == "" && title.Text != "" && v.dropsTopic(task, title.Text):
			continue
		}
		kept = append(kept, r)
	}
	return kept
}

// messageHidden is the message door's moderation half: false has written
// the same 404 as a message that does not exist.
func (s *Server) messageHidden(w http.ResponseWriter, r *http.Request, tenant, reader, id string) bool {
	v, err := s.moderation(r.Context(), tenant, reader)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("moderation read")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return true
	case v.drops(id):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return true
	}
	return false
}

// dropHiddenConns is targets without the sockets that may not see message
// id. Called outside s.mu (the moderator check reads the store).
func (s *Server) dropHiddenConns(ctx context.Context, tenant, id string, targets []*wuiConn) []*wuiConn {
	if len(targets) == 0 || s.o.DemoWorkspace == "" || tenant != s.o.DemoWorkspace {
		return targets
	}
	v, err := s.moderation(ctx, tenant, "")
	if err != nil {
		return nil // fail closed: nobody hears of it
	}
	if _, hidden := v.hidden[id]; !hidden {
		return targets
	}
	kept := targets[:0:0]
	for _, c := range targets {
		if s.isModerator(ctx, tenant, c.member) {
			kept = append(kept, c)
		}
	}
	return kept
}

// reported runs after a report reaction is stored: the reportHideAt-th
// distinct reporter hides the message.
func (s *Server) reported(ctx context.Context, tenant string, m store.EditableMessage) {
	mm, ok := s.o.Store.(store.MessageModeration)
	if !ok {
		return
	}
	hid, err := mm.ReportHide(ctx, tenant, m.MsgID, reportEmoji, reportHideAt, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("report hide")
		return
	}
	if hid {
		s.o.Log.Info().Str("tenant", tenant).Str("msg_id", m.MsgID).Msg("message hidden by reports")
		s.fanoutHidden(ctx, tenant, m, true)
	}
}

// reportAllowed: the report glyph exists only in the demo workspace.
func (s *Server) reportAllowed(tenant string) bool {
	return s.o.DemoWorkspace != "" && tenant == s.o.DemoWorkspace
}

func (s *Server) routeModeration(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/messages/{msg_id}/hidden", s.handleHideMessage)
	mux.HandleFunc("DELETE /v1/messages/{msg_id}/hidden", s.handleHideMessage)
	mux.HandleFunc("OPTIONS /v1/messages/{msg_id}/hidden", s.hiddenPreflight)
}

// PUT hides, DELETE unhides (a moderator of the demo workspace only).
// Answers {msg_id, task_id, hidden}.
func (s *Server) handleHideMessage(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	by, ok := s.editorID(r, t.ID)
	if !ok {
		writeForbidden(w, moderatePerm, "hiding a message needs a signed-in member session")
		return
	}
	if !s.permit(w, r, t.ID, hum, moderatePerm) {
		return
	}
	mm, ok := s.o.Store.(store.MessageModeration)
	if !ok || !s.reportAllowed(t.ID) || !billing.AllowsWrite(t.BillingStatus) {
		writeErr(w, http.StatusNotFound, "not_found", "moderation is for the demo workspace")
		return
	}
	id := strings.ToLower(r.PathValue("msg_id"))
	m, ok := s.moderatedMessage(w, r, t.ID, id)
	if !ok {
		return
	}
	hide := r.Method == http.MethodPut
	if err := mm.SetHidden(r.Context(), t.ID, id, hide, by, s.o.Now()); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "not_found", "no such message")
			return
		}
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("hide store")
		writeErr(w, http.StatusInternalServerError, "internal", "hide not stored")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("msg_id", id).Str("by", by).Bool("hidden", hide).Msg("message moderated")
	s.fanoutHidden(r.Context(), t.ID, m, hide)
	writeJSON(w, http.StatusOK, map[string]any{"msg_id": m.MsgID, "task_id": m.TaskID, "hidden": hide})
}

// moderatedMessage loads message id through its read door; false has
// written the refusal.
func (s *Server) moderatedMessage(w http.ResponseWriter, r *http.Request, tenant, id string) (store.EditableMessage, bool) {
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusBadRequest, "bad_json", "msg_id must be a UUID")
		return store.EditableMessage{}, false
	}
	m, err := s.o.Store.GetEditable(r.Context(), tenant, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such message")
		return m, false
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("hide lookup")
		writeErr(w, http.StatusInternalServerError, "internal", "message unavailable")
		return m, false
	}
	return m, s.messageDoor(w, r, tenant, m)
}

// fanoutHidden tells the sockets shown m: a moderator's get message_hidden
// {hidden}; everyone else's drop the row (message_deleted) on a hide. An
// unhide reaches them on their next read.
func (s *Server) fanoutHidden(ctx context.Context, tenant string, m store.EditableMessage, hidden bool) {
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
	mark, err := encodeFrame(map[string]any{"type": hiddenFrame, "msg_id": m.MsgID, "task_id": m.TaskID, "hidden": hidden})
	if err != nil {
		return
	}
	drop, err := encodeFrame(newDeletedMsg(m))
	if err != nil {
		return
	}
	for _, c := range targets {
		switch {
		case s.isModerator(ctx, tenant, c.member):
			c.writeRaw(ctx, mark) //nolint:errcheck
		case hidden:
			c.writeRaw(ctx, drop) //nolint:errcheck
		}
	}
}

// hiddenPreflight is CORS for PUT and DELETE /v1/messages/{msg_id}/hidden.
func (s *Server) hiddenPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// moderatedRows is one topic page without what hum may not see, and hum's
// view to mark the rest. A first page that held only hidden messages is the
// 404 of a topic that does not exist. false has written the answer.
func (s *Server) moderatedRows(w http.ResponseWriter, r *http.Request, tenant, hum string, rows []store.ViewMsg,
	sq store.TopicMsgQuery) ([]store.ViewMsg, modView, bool) {
	v, err := s.moderation(r.Context(), tenant, hum)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task", sq.TaskID).Msg("moderation read")
		writeErr(w, http.StatusInternalServerError, "internal", "topic unavailable")
		return nil, v, false
	}
	kept := v.keepMsgs(rows)
	if len(kept) == 0 && len(rows) > 0 && sq.AfterAt.IsZero() && sq.BeforeAt.IsZero() && sq.TaskID != s.o.LobbyTaskID {
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return nil, v, false
	}
	return kept, v, true
}

// idReaderFor is the id door of hum with its moderation view.
func (s *Server) idReaderFor(ctx context.Context, tenant, hum string, mine []string) (idReader, error) {
	v, err := s.moderation(ctx, tenant, hum)
	return idReader{hum: hum, mine: mine, mod: v}, err
}
