package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A box agent archives, or unarchives, a topic by its task id (CLE-77869,
// owner 2026-10-01: "archive the discussion" of a closed ops topic, from an
// operator action, do_spl_topic_archive). It is the box twin of the browser's
// PUT/DELETE /v1/messages/{card}/archive: the same card (the task's opening
// card, store.TaskCard), the same store write (SetArchived), the same
// topic_archived frame to the open browsers, and the same workspace setting
// "Who can archive topics" (CLE-77819), read for a box as:
//   - everyone (the default): a box that can read the card - it sent it, it
//     is addressed to it, or the hub delivered it there (the tail rule,
//     BoxTaskEnvelopes) - and nothing else;
//   - starter: only the box that sent the card;
//   - admins: never a box (a box is not a tenant admin).
// An issue's discussion and the lobby keep their own lifecycle, as in the
// browser route. archived_by is the acting agent, one this box announced.

// onArchive answers an archive frame.
func (s *Server) onArchive(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "an archive frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxArchive(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TArchive, MsgID: id, TaskID: f.TaskID, ArchiveOp: f.ArchiveOp, Archive: raw}) //nolint:errcheck
}

// boxArchive resolves and gates the topic, then writes the flag.
func (s *Server) boxArchive(ctx context.Context, x *session, f wire.Frame) (map[string]any, *issueErr) {
	task := f.TaskID
	if !uuidRe.MatchString(task) || task != strings.ToLower(task) {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "an archive frame needs task_id, the topic's lowercase UUID"}
	}
	if f.ArchiveOp != "archive" && f.ArchiveOp != "unarchive" {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "archive_op must be archive or unarchive"}
	}
	if detail := senderRefusal(x, f.As); detail != "" {
		return nil, &issueErr{http.StatusForbidden, TokenFromNotAnnounced, detail}
	}
	t, err := s.o.Store.GetTenant(ctx, x.tenant)
	if err != nil {
		return nil, &issueErr{http.StatusInternalServerError, "internal", "tenant unavailable"}
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		return nil, &issueErr{billing.HTTPUnpaid, billing.TokenUnpaid, "tenant billing is unpaid"}
	}
	if s.o.LobbyTaskID != "" && task == s.o.LobbyTaskID {
		return nil, &issueErr{http.StatusConflict, "not_a_card", "the lobby is one task of many cards: archive a lobby card from the WUI"}
	}
	now := s.o.Now()
	card, err := s.o.Store.TaskCard(ctx, x.tenant, task, now)
	var m store.EditableMessage
	if err == nil {
		m, err = s.o.Store.GetEditable(ctx, x.tenant, card.MsgID, now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such topic"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("box archive lookup")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "topic unavailable"}
	}
	// The read door: a topic this box cannot read answers as absent.
	if !s.boxReadsCard(ctx, x, m) {
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such topic"}
	}
	if card.IssueTopic {
		return nil, &issueErr{http.StatusConflict, "issue_topic", "an issue's discussion is archived with its issue, not here"}
	}
	if !boxMayArchive(t.TopicArchivePolicy, m, x.box) {
		return nil, &issueErr{http.StatusForbidden, "not_allowed", "this workspace does not let " + x.box + " archive this topic"}
	}
	archive := f.ArchiveOp == "archive"
	st, err := s.o.Store.SetArchived(ctx, x.tenant, m.MsgID, f.As, now.UTC().Truncate(time.Second), archive)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such topic"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("box archive store")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "archive not stored"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("msg_id", m.MsgID).Str("by", f.As).Bool("archived", archive).Msg("topic archive by box")
	out := archivedBody(m, st)
	s.fanoutTopic(ctx, x.tenant, m, withType(topicArchivedFrame, m, out))
	return out, nil
}

// boxReadsCard is the tail rule on the card: this box sent it, it is
// addressed to it, or the hub delivered it there.
func (s *Server) boxReadsCard(ctx context.Context, x *session, m store.EditableMessage) bool {
	if m.FromBox == x.box || m.ToBox == x.box {
		return true
	}
	st, err := s.o.Store.DeliveryState(ctx, x.tenant, m.MsgID, x.box)
	return err == nil && st != ""
}

// boxMayArchive is "Who can archive topics" for a box that reads the card.
func boxMayArchive(stored string, m store.EditableMessage, box string) bool {
	switch store.EffectiveArchivePolicy(stored) {
	case store.ArchivePolicyAdmins:
		return false
	case store.ArchivePolicyStarter:
		return m.FromBox == box
	default: // everyone
		return true
	}
}
