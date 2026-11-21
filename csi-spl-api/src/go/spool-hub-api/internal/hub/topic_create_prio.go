package hub

import (
	"context"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A new topic's priority from its first post (SPL-6145, spec 150 section
// 3.3.1; the owner, t1 0f457318 msg c94e2d29): a browser post that opens a
// topic and ends with prio:N, prio:0N, prio-N, prio-0N or prio N (N 1..5,
// any case) sets the topic to N and is stored without the token. Anything
// else stays plain text and the topic keeps the default 3:
//   - only the first post of the topic (a resend of that same msg_id too,
//     so it stores the same body); a reply never changes the priority;
//   - only at the very end, after white space or a line break, and not in
//     a quoted line or code (prioOwnText); a post that is the token alone
//     stays as typed;
//   - only who may set it on the PUT: a member session, not a demo
//     visitor, and the workspace's "Who can archive topics" with the poster
//     as the starter.
// The cut is the hub's, before the envelope, so every WUI page that opens a
// topic is covered by one place. A box or CLI post is signed by its box and
// its body is not the hub's to change: it carries no token.
// The set follows as the PUT's: issues and lanes (followTopicPriority), the
// operator copy (priorityToOperator), the topic_priority frame. It beats the
// owner's prio word (ownerPrioWord): a number the owner wrote is the one meant.

var createPrioRe = regexp.MustCompile(`(?i)(?:^|\s)prio(?::|-|[ \t]+)0?([1-5])\s*$`)

// createPrioSuffix is body without its trailing prio token, and the token's
// priority; (body, 0) when there is none.
func createPrioSuffix(body string) (string, int) {
	loc := createPrioRe.FindStringSubmatchIndex(body)
	if loc == nil || !createPrioRe.MatchString(prioOwnText(body)) {
		return body, 0
	}
	rest := strings.TrimRight(body[:loc[0]], " \t\r\n")
	if strings.TrimSpace(rest) == "" {
		return body, 0
	}
	return rest, int(body[loc[3]-1] - '0')
}

// createPrioCut strips the token from m when m opens its topic and the
// poster may set the priority; it answers the priority, 0 = none.
func (s *Server) createPrioCut(ctx context.Context, c *wuiConn, m *msg.Message) int {
	task := strings.ToLower(m.TaskID)
	if c.member == "" || !uuidRe.MatchString(task) || strings.EqualFold(task, s.o.LobbyTaskID) {
		return 0
	}
	body, prio := createPrioSuffix(m.Body)
	if prio == 0 || !s.opensTopic(ctx, c.tenant, task, m.MsgID) || !s.mayCreatePrio(ctx, c) {
		return 0
	}
	m.Body = body
	return prio
}

// opensTopic: no message of task is stored yet, or only msgID itself.
func (s *Server) opensTopic(ctx context.Context, tenant, task, msgID string) bool {
	rows, err := s.o.Store.ViewTopic(ctx, tenant, store.TopicMsgQuery{TaskID: task, Limit: 1, Now: s.o.Now()})
	return err == nil && (len(rows) == 0 || rows[0].MsgID == msgID)
}

// mayCreatePrio is the PUT's rule (priorityCaller, priorityAllowed) for the
// topic's starter.
func (s *Server) mayCreatePrio(ctx context.Context, c *wuiConn) bool {
	if s.isDemoVisitor(ctx, c.tenant, c.member) {
		return false
	}
	t, err := s.o.Store.GetTenant(ctx, c.tenant)
	return err == nil && s.mayArchiveByPolicy(ctx, c.tenant, c.member, s.archivePolicy(t), true)
}

// createPrioSet is wuiAfterStore's step: it stores prio for m's new topic;
// false when prio is 0 or the write failed.
func (s *Server) createPrioSet(ctx context.Context, c *wuiConn, m *msg.Message, prio int) bool {
	ps, ok := s.o.Store.(store.TopicPriorityStore)
	if prio == 0 || !ok {
		return false
	}
	task := strings.ToLower(m.TaskID)
	row, err := ps.SetTopicPriority(ctx, c.tenant, task, prio, c.from, s.o.Now().UTC())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Str("task", task).Msg("topic create prio: not stored")
		return false
	}
	s.o.Log.Info().Str("tenant", c.tenant).Str("task", task).Str("by", c.from).Str("msg_id", m.MsgID).Int("priority", prio).Msg("topic create prio")
	s.followTopicPriority(ctx, c.tenant, task, c.from)
	q := topicPriorityReq{t: store.Tenant{ID: c.tenant}, hum: c.member, from: c.from, task: task}
	s.priorityToOperator(ctx, ps, q, prio)
	if card, found, err := s.openingCard(ctx, c.tenant, task); err == nil && found {
		out := map[string]any{"task_id": task, "priority": row.Priority, "set_by": row.SetBy, "set_at": rfc(row.SetAt)}
		s.fanoutTopic(ctx, c.tenant, card, withType(topicPriorityFrame, card, out))
	}
	return true
}
