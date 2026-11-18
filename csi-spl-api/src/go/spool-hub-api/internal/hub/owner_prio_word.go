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
// (workspaceOwner), or the owner of the operator workspace: a member, an
// admin, a guest socket or an agent never moves the queue this way. The
// operator workspace's owner posting in another workspace's topic also sets
// that topic's priority in the operator workspace, where the spawn queue
// lives. Quoted lines and code are not the owner's words (prioOwnText). The set is the PUT's (handleTopicPriority): the
// topic's issues and lanes follow (followTopicPriority) and open views get
// the topic_priority frame. One log line for the topic, one per queued ask
// it moved; a topic already at priority 1 logs one line and writes nothing.

// prioQuoteRe and prioCodeRe drop what the owner quotes rather than says
// (R7 W2): a fenced code block, an inline code span, and a "> " quote line
// (a reply quoting a post, or the WUI's "Chat about this" prefill).
var (
	prioFenceRe = regexp.MustCompile("(?s)```.*?(?:```|$)|~~~.*?(?:~~~|$)")
	prioCodeRe  = regexp.MustCompile("`[^`\\n]*`")
	prioQuoteRe = regexp.MustCompile(`(?m)^[ \t]*>.*$`)
)

// prioOwnText is body without its code and quoted lines.
func prioOwnText(body string) string {
	body = prioFenceRe.ReplaceAllString(body, " ")
	body = prioCodeRe.ReplaceAllString(body, " ")
	return prioQuoteRe.ReplaceAllString(body, " ")
}

// prioWordIn is the first of words found in body's own text (prioOwnText)
// as a whole word (no letter, digit or underscore on either side; a space
// inside a word matches any run of white space), any case; "" when none is.
func prioWordIn(body string, words []string) string {
	body = prioOwnText(body)
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

// prioWordOwners answers where member's prio word counts: inTenant when
// member owns tenant or is the operator workspace's owner; op (non-empty)
// when member owns the operator workspace and tenant is another workspace,
// because the fleet's spawn queue lives in op (R7 W1: an owner post in a
// csitea topic must move the t1 ask working for it). A non-operator
// workspace's owner never touches op.
func (s *Server) prioWordOwners(ctx context.Context, tenant, member string) (inTenant bool, op string) {
	inTenant = s.workspaceOwner(ctx, tenant, member)
	o, err := s.operatorTenant(ctx)
	if err != nil || o == "" || !s.operatorOwner(ctx, o, member) {
		return inTenant, ""
	}
	if o == tenant {
		return true, ""
	}
	return true, o
}

// operatorOwner: member owns op, the operator workspace (its owner's role,
// or the business owner's member row). Only such a member orders the
// agents' work: op's queue (prioWordOwners) and op's issues
// (linkedSetPriorities, SPL-5933).
func (s *Server) operatorOwner(ctx context.Context, op, member string) bool {
	return s.workspaceOwner(ctx, op, member) || s.channelMoveOwner(ctx, op, member)
}

// ownerPrioWord is wuiAfterStore's step: m was stored from member's browser
// socket in tenant. A note to self and the lobby topic set nothing.
func (s *Server) ownerPrioWord(ctx context.Context, tenant, member string, m *msg.Message, noteToSelf bool) {
	task := strings.ToLower(m.TaskID)
	if member == "" || noteToSelf || len(s.o.OwnerPrioWords) == 0 || !uuidRe.MatchString(task) || strings.EqualFold(task, s.o.LobbyTaskID) {
		return
	}
	word := prioWordIn(m.Body, s.o.OwnerPrioWords)
	if word == "" {
		return
	}
	inTenant, op := s.prioWordOwners(ctx, tenant, member)
	if !inTenant {
		return
	}
	ps, ok := s.o.Store.(store.TopicPriorityStore)
	if !ok {
		return
	}
	if s.setPrioWord(ctx, ps, tenant, task, member, word, m.MsgID) {
		s.followTopicPriority(ctx, tenant, task, member)
		if card, found, err := s.openingCard(ctx, tenant, task); err == nil && found {
			out := map[string]any{"task_id": task, "priority": 1, "set_by": member, "set_at": rfc(s.o.Now().UTC())}
			s.fanoutTopic(ctx, tenant, card, withType(topicPriorityFrame, card, out))
		}
	}
	s.logPrioWordAsks(ctx, tenant, task, member)
	if op != "" {
		// the operator workspace's queue ranks its asks by op's own
		// topic_priorities row for the discussion (askListPriorities).
		s.setPrioWord(ctx, ps, op, task, member, word, m.MsgID)
		s.logPrioWordAsks(ctx, op, task, member)
	}
}

// setPrioWord sets task to priority 1 in tenant and logs it; false when the
// topic was already at 1 or the write failed.
func (s *Server) setPrioWord(ctx context.Context, ps store.TopicPriorityStore, tenant, task, member, word, msgID string) bool {
	lg := s.o.Log.Info().Str("tenant", tenant).Str("task", task).Str("by", member).Str("word", word).Str("msg_id", msgID)
	if cur, err := ps.TopicPriorities(ctx, tenant, []string{task}); err == nil && cur[task] == 1 {
		lg.Msg("owner prio word: topic already priority 1")
		return false
	}
	if _, err := ps.SetTopicPriority(ctx, tenant, task, 1, member, s.o.Now().UTC()); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("task", task).Msg("owner prio word: topic priority not stored")
		return false
	}
	lg.Msg("owner prio word: topic priority 1")
	return true
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
