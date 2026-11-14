package hub

import (
	"context"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The owner's prio word (SPL-5524, spec 157 section 4.1; csitea weekly item
// 10, topic 48d75e5f): a browser post BY THE OWNER that carries one of
// Options.OwnerPrioWords (SPOOL_HUB_OWNER_PRIO_WORDS, default "prio",
// "priority one", "urgent"; whole words, any case) sets its topic's priority
// to 1 at once, with no dispatcher round trip. The spawn queue ranks a queued
// ask by its discussion's priority first (store.askPositions), so every
// queued ask on that topic moves to the head on the next list, and the placer
// takes a priority 1 head ahead of the class bands (spl_spawn_place_band).
//
// The owner is a signed-in member whose role is the workspace owner's
// (workspaceOwner), or the biz owner of the operator workspace
// (channelMoveOwner): a member, an admin, a guest socket or an agent never
// moves the queue this way. The set is the PUT's (handleTopicPriority): the
// topic's issues and lanes follow (followTopicPriority) and open views get
// the topic_priority frame. One log line for the topic, one per queued ask
// it moved; a topic already at priority 1 logs one line and writes nothing.

// prioWordIn is the first of words found in body as a whole word (no letter,
// digit or underscore on either side; a space inside a word matches any run
// of white space), any case; "" when none is.
func prioWordIn(body string, words []string) string {
	for _, w := range words {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		parts := strings.Fields(w)
		for i, p := range parts {
			parts[i] = regexp.QuoteMeta(p)
		}
		re := regexp.MustCompile(`(?i)(?:^|[^\p{L}\p{N}_])` + strings.Join(parts, `\s+`) + `(?:[^\p{L}\p{N}_]|$)`)
		if re.MatchString(body) {
			return w
		}
	}
	return ""
}

// prioWordOwner: member (a signed-in HUM-n) owns tenant, or is the biz owner
// of the operator workspace.
func (s *Server) prioWordOwner(ctx context.Context, tenant, member string) bool {
	if s.workspaceOwner(ctx, tenant, member) {
		return true
	}
	op, err := s.operatorTenant(ctx)
	return err == nil && op != "" && s.channelMoveOwner(ctx, op, member)
}

// ownerPrioWord is wuiAfterStore's step: m was stored from member's browser
// socket in tenant.
func (s *Server) ownerPrioWord(ctx context.Context, tenant, member string, m *msg.Message) {
	task := strings.ToLower(m.TaskID)
	word := prioWordIn(m.Body, s.o.OwnerPrioWords)
	if word == "" || member == "" || !uuidRe.MatchString(task) || !s.prioWordOwner(ctx, tenant, member) {
		return
	}
	ps, ok := s.o.Store.(store.TopicPriorityStore)
	if !ok {
		return
	}
	lg := s.o.Log.Info().Str("tenant", tenant).Str("task", task).Str("by", member).Str("word", word).Str("msg_id", m.MsgID)
	if cur, err := ps.TopicPriorities(ctx, tenant, []string{task}); err == nil && cur[task] == 1 {
		lg.Msg("owner prio word: topic already priority 1")
		return
	}
	row, err := ps.SetTopicPriority(ctx, tenant, task, 1, member, s.o.Now().UTC())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("task", task).Msg("owner prio word: topic priority not stored")
		return
	}
	lg.Msg("owner prio word: topic priority 1")
	s.followTopicPriority(ctx, tenant, task, member)
	if card, found, err := s.openingCard(ctx, tenant, task); err == nil && found {
		out := map[string]any{"task_id": task, "priority": row.Priority, "set_by": row.SetBy, "set_at": rfc(row.SetAt)}
		s.fanoutTopic(ctx, tenant, card, withType(topicPriorityFrame, card, out))
	}
	s.logPrioWordAsks(ctx, tenant, task, member)
}

// logPrioWordAsks writes one line per queued spawn ask of the fleet's orch
// role whose discussion is task: its new position.
func (s *Server) logPrioWordAsks(ctx context.Context, tenant, task, by string) {
	as, err := s.o.Store.ListFleetAsks(ctx, tenant, fleetLanesFleet, "orch", false, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("task", task).Msg("owner prio word: queue not read")
		return
	}
	for _, a := range as {
		if a.State == "queued" && a.Discussion == task {
			s.o.Log.Info().Str("tenant", tenant).Str("task", task).Str("by", by).Str("ask", a.AskID).
				Int("position", a.Position).Int("queue_len", a.QueueLen).Msg("owner prio word: queued ask moved")
		}
	}
}
