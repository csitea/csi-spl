package hub

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The agent issue op inherit-priority (SPL-5147, ruling c-001 8ae0ff4e): the
// discussion that carries on an archived one takes its priority, so the work
// re-homed there keeps its place in the spawn queue. The caller names two
// topics and no number, so an agent can only copy a value a member set:
//   - both topics are of the session's workspace;
//   - refused unless the source is archived and the target exists and is live;
//   - refused unless the target is the source's follow-up: its opening card
//     names the source as /t/<source id> (the post do_spl_archived_followup
//     makes), so no agent can lift an unrelated topic (R7 c-714 W1);
//   - a source with no stored row writes nothing, never the default;
//   - a priority the target already has is kept.
// It is no general priority write: that stays PUT /v1/topics/{task_id}/priority.

// agentInheritPriority answers {from, to, inherited, priority?, reason?}.
func (s *Server) agentInheritPriority(ctx context.Context, tenant, as, query string) (any, *issueErr) {
	from, to, ie := inheritTopics(query)
	if ie != nil {
		return nil, ie
	}
	ps, ok := s.o.Store.(store.TopicPriorityStore)
	if !ok {
		return nil, &issueErr{http.StatusInternalServerError, "internal", "priority not stored"}
	}
	card, ie := s.inheritDoor(ctx, tenant, from, to)
	if ie != nil {
		return nil, ie
	}
	out := map[string]any{"from": from, "to": to, "inherited": false}
	set, err := ps.SetTopicPriorities(ctx, tenant, []string{from, to})
	if err != nil {
		return nil, inheritFailed(s, err, to)
	}
	if _, has := set[from]; !has {
		out["reason"] = "source_has_no_priority"
		return out, nil
	}
	row, wrote, err := ps.InheritTopicPriority(ctx, tenant, from, to, as, s.o.Now().UTC().Truncate(time.Second))
	if err != nil {
		return nil, inheritFailed(s, err, to)
	}
	if !wrote {
		out["reason"] = "target_already_set"
		return out, nil
	}
	s.o.Log.Info().Str("tenant", tenant).Str("task", to).Str("from", from).Str("by", as).Int("priority", row.Priority).Msg("topic priority inherited")
	s.followTopicPriority(ctx, tenant, to, as) // spec 150 3.4 item 4, as the PUT
	s.fanoutTopic(ctx, tenant, card, withType(topicPriorityFrame, card, map[string]any{"task_id": to, "priority": row.Priority, "set_by": row.SetBy, "set_at": rfc(row.SetAt)}))
	out["inherited"], out["priority"] = true, row.Priority
	return out, nil
}

// inheritTopics reads from= and to=: two different topic ids, lower case.
func inheritTopics(query string) (string, string, *issueErr) {
	q, err := url.ParseQuery(query)
	if err != nil {
		return "", "", badIssue("query must be URL query form: from=<uuid>&to=<uuid>")
	}
	from, to := strings.ToLower(q.Get("from")), strings.ToLower(q.Get("to"))
	if !uuidRe.MatchString(from) || !uuidRe.MatchString(to) || from == to {
		return "", "", badIssue("from and to must be two different topic ids")
	}
	return from, to, nil
}

// inheritDoor refuses unless from is archived in tenant and to is a live topic
// of tenant whose opening card names from; it answers that card for the live frame.
func (s *Server) inheritDoor(ctx context.Context, tenant, from, to string) (store.EditableMessage, *issueErr) {
	var card store.EditableMessage
	at, _, err := s.o.Store.TopicArchived(ctx, tenant, from, s.o.LobbyTaskID)
	if err != nil {
		return card, inheritFailed(s, err, from)
	}
	if at.IsZero() {
		return card, &issueErr{http.StatusConflict, "source_not_archived", "the source is not an archived topic of this workspace"}
	}
	gone, err := s.o.Store.AnyTopicArchived(ctx, tenant, s.o.LobbyTaskID, []string{to})
	if err != nil {
		return card, inheritFailed(s, err, to)
	}
	if gone {
		return card, &issueErr{http.StatusConflict, "target_not_live", "the target is archived"}
	}
	card, found, err := s.openingCard(ctx, tenant, to)
	if err != nil {
		return card, inheritFailed(s, err, to)
	}
	if !found {
		return card, &issueErr{http.StatusNotFound, "not_found", "no such target topic"}
	}
	if !strings.Contains(strings.ToLower(card.Body), "/t/"+from) {
		return card, &issueErr{http.StatusConflict, "not_followup", "the target's opening post does not name the source: it is not its follow-up"}
	}
	return card, nil
}

func inheritFailed(s *Server, err error, task string) *issueErr {
	s.o.Log.Error().Err(err).Str("task", task).Msg("topic priority inherit")
	return &issueErr{http.StatusInternalServerError, "internal", "priority not inherited"}
}
