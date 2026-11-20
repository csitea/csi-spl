package hub

import (
	"context"
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The fire of a discussion loop (spec 182 v0.4 sections 4.2-4.4 and 7.2,
// row L2, SPL-6032). Every fire goes through topicLoopFire: a hook names
// the event, each `on` loop of the topic one of whose twelve checked boxes
// matches it is checked (4.2 step 7) and, if every check holds, its prompt
// is stored as a hidden loop prompt message (messages.loop_id, 5.2) to the
// topic's agent and queued for that agent's box. A loop fires at most once
// per event, whatever number of its boxes match. The hooks:
//
//   - a human post (wuiAfterStore): after_human_reply, post_has_keyword,
//     post_has_file, blocker_posted; it arms no_reply_after_human;
//   - before_agent_reply: wuiSend, after its last refusal and right before
//     the post is stored, so the agent's inbox holds the prompt first;
//   - an agent's box send (onSend, after the `sent` frame): an agent reply
//     fires after_agent_reply, before_human_reply (Q11 A: a reply to the
//     loop's author), post_has_keyword, post_has_file and blocker_posted, and
//     clears no_reply_after_human; an agent-to-agent blocker fires
//     blocker_posted only;
//   - a post marked a blocker afterwards (handleSetMessageKind);
//   - an issue status change (updateIssue): issue_status_changed, in every
//     topic the issue links;
//   - every_hour, every_n_minutes, daily_at and no_reply_after_human:
//     runTopicLoopTimer, every 60 s.
//
// A loop prompt message is never a trigger, nor is a hub note (HUB-0, which
// also posts the pause notices of spec 179). Q10 A (the agent's answer to a
// loop's prompt does not fire that loop) is on unless
// Options.TopicLoopSelfFire.

// topicLoopCapDefault is the fires per loop per hour (answer 4 B).
const topicLoopCapDefault = 12

// topicLoopAwait is how long the target agent's next post counts as its
// answer to the fire (Q10 A, 4.4 step 2).
const topicLoopAwait = 30 * time.Minute

// topicLoopQuoteMax cuts the quoted trigger, in characters (4.3 step 2).
const topicLoopQuoteMax = 600

// topicLoopTimerEvery is the time ticker; topicLoopTimerBatch the loops one
// tick claims (the rest are due at the next tick).
const (
	topicLoopTimerEvery = 60 * time.Second
	topicLoopTimerBatch = 50
)

// topicLoopPromptMark starts every loop prompt body (answer 8 A). A time
// fire's quote skips a stored post that starts with it.
const topicLoopPromptMark = "Loop prompt (background; "

// The kinds of loopEvent.
const (
	loopEventPost   = "post"   // a stored post (browser or box)
	loopEventBefore = "before" // a browser post about to go to an agent
	loopEventKind   = "kind"   // a post marked a blocker afterwards
	loopEventTime   = "time"   // the ticker
	loopEventIssue  = "issue"  // an issue status change
)

// loopTimeKeys are the boxes the ticker fires (TopicLoop.Due).
var loopTimeKeys = []string{store.LoopEveryHour, store.LoopEveryNMinutes, store.LoopDailyAt, store.LoopNoReplyAfterHuman}

// loopEvent is one hook's event.
type loopEvent struct {
	kind  string
	post  *msg.Message // the trigger post; nil for a time or issue fire
	human bool         // post: a human post
	reply bool         // post: an agent reply (section 2)
	agent string       // the agent the event names as target ("" = the topic's agent)
	box   string       // that agent's box ("" = resolve it)
	// routed: the browser post also went to an agent, so a loop with
	// before_agent_reply already fired for it (one fire per post).
	routed bool
	arm    bool   // a human post: arm no_reply_after_human
	clear  bool   // an agent reply: clear no_reply_after_human
	cause  string // the id seed after "topic-loop:<loop>:" when post is nil
	quote  string // what an issue fire quotes
}

// matches: one of l's checked boxes fits ev.
func (ev loopEvent) matches(l store.TopicLoop) bool {
	has := func(k string) bool { return slices.Contains(l.Triggers, k) }
	switch ev.kind {
	case loopEventBefore:
		return has(store.LoopBeforeAgentReply)
	case loopEventKind:
		return has(store.LoopBlockerPosted)
	case loopEventIssue:
		return has(store.LoopIssueStatusChanged)
	case loopEventTime:
		return slices.ContainsFunc(l.Due, func(k string) bool { return slices.Contains(loopTimeKeys, k) && has(k) })
	case loopEventPost:
		return !(ev.routed && has(store.LoopBeforeAgentReply)) && ev.postMatches(l, has)
	}
	return false
}

// postMatches is matches for a stored post (4.2 steps 1, 2, 4, 8, 9, 10).
func (ev loopEvent) postMatches(l store.TopicLoop, has func(string) bool) bool {
	m := ev.post
	if has(store.LoopBlockerPosted) && m.Kind == blockerKind {
		return true
	}
	if !ev.human && !ev.reply {
		return false
	}
	switch {
	case ev.human && has(store.LoopAfterHumanReply),
		ev.reply && has(store.LoopAfterAgentReply),
		ev.reply && has(store.LoopBeforeHumanReply) && m.To == l.SetBy,
		has(store.LoopPostHasFile) && len(m.Files) > 0,
		has(store.LoopPostHasKeyword) && topicLoopKeyword(l.Keyword, m.Body):
		return true
	}
	return false
}

// topicLoopKeyword: body holds keyword, case-free, at word edges: a phrase
// matches as a whole, "PDF" matches "pdf," but not "pdfs" (4.2 step 8).
func topicLoopKeyword(keyword, body string) bool {
	k := strings.ToLower(strings.TrimSpace(keyword))
	if k == "" {
		return false
	}
	b := strings.ToLower(body)
	for i := 0; i <= len(b)-len(k); {
		j := strings.Index(b[i:], k)
		if j < 0 {
			return false
		}
		at := i + j
		if loopWordEdge(b, at, -1) && loopWordEdge(b, at+len(k), 1) {
			return true
		}
		_, w := utf8.DecodeRuneInString(b[at:])
		i = at + w
	}
	return false
}

// loopWordEdge: no word character touches position at on side dir (-1:
// the rune before at, 1: the rune at at).
func loopWordEdge(b string, at, dir int) bool {
	var r rune
	switch {
	case dir < 0 && at == 0, dir > 0 && at >= len(b):
		return true
	case dir < 0:
		r, _ = utf8.DecodeLastRuneInString(b[:at])
	default:
		r, _ = utf8.DecodeRuneInString(b[at:])
	}
	return !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '_'
}

// topicLoopCap is the cap in force.
func (s *Server) topicLoopCap() int {
	if s.o.TopicLoopCap > 0 {
		return s.o.TopicLoopCap
	}
	return topicLoopCapDefault
}

// loopStore is the store's loops, nil when it has none (7.1.1 point 4).
func (s *Server) loopStore() store.TopicLoopStore {
	ls, _ := s.o.Store.(store.TopicLoopStore)
	return ls
}

// isLoopTrigger: m may fire a loop at all (section 2, "never a trigger");
// nil (a time or issue fire) may.
func isLoopTrigger(m *msg.Message) bool {
	return m == nil || (m.From != PublicNoticeFrom && !strings.HasPrefix(m.Body, topicLoopPromptMark))
}

// isAgentReply is section 2's agent reply: an agent box's post to the whole
// topic or to a person (spec 179 5.2 row 1); agent-to-agent sends are not.
func isAgentReply(env *wire.Envelope, m *msg.Message) bool {
	if env.FromBox == WUIBox || !isAgent(m.From) {
		return false
	}
	return m.To == BroadcastID || strings.HasPrefix(m.To, "HUM-") || strings.HasPrefix(m.To, GuestPrefix)
}

// topicLoopHuman is the human post hook (wuiAfterStore).
func (s *Server) topicLoopHuman(ctx context.Context, tenant string, rt wuiRouted, m *msg.Message) {
	if rt.noteToSelf || !strings.HasPrefix(m.From, "HUM-") {
		return
	}
	routed := rt.signing.agent != "" || rt.signing.fanOut
	s.topicLoopFire(ctx, tenant, m.TaskID, loopEvent{kind: loopEventPost, post: m, human: true, routed: routed, arm: true})
}

// topicLoopBeforeAgent is the before_agent_reply hook (wuiSend, before the
// store). A resend of a stored post fires nothing: its first send did.
func (s *Server) topicLoopBeforeAgent(ctx context.Context, tenant string, rt wuiRouted, m *msg.Message) {
	if rt.noteToSelf || (rt.signing.agent == "" && !rt.signing.fanOut) || !strings.HasPrefix(m.From, "HUM-") {
		return
	}
	ev := loopEvent{kind: loopEventBefore, post: m, agent: rt.signing.agent, box: rt.signing.box}
	s.topicLoopFireIf(ctx, tenant, m.TaskID, ev, func() bool {
		_, _, err := s.o.Store.MessageTimes(ctx, tenant, m.MsgID)
		return errors.Is(err, store.ErrNotFound)
	})
}

// topicLoopAgent is the box send hook (onSend, after the sent frame): an
// agent reply, or an agent-to-agent blocker (4.2 step 10). The target is
// the agent that posted.
func (s *Server) topicLoopAgent(ctx context.Context, tenant string, env *wire.Envelope, m *msg.Message) {
	reply := isAgentReply(env, m)
	if !reply && (m.Kind != blockerKind || !isAgent(m.From)) {
		return
	}
	s.topicLoopFire(ctx, tenant, m.TaskID, loopEvent{kind: loopEventPost, post: m, reply: reply, clear: reply,
		agent: m.From, box: env.FromBox})
}

// topicLoopKindBlocker is the hook of a post marked a blocker afterwards
// (handleSetMessageKind). An agent's post goes to that agent.
func (s *Server) topicLoopKindBlocker(ctx context.Context, tenant string, m store.EditableMessage) {
	post := &msg.Message{MsgID: m.MsgID, TaskID: m.TaskID, From: m.FromID, To: m.ToID, Kind: blockerKind, Body: m.Body}
	ev := loopEvent{kind: loopEventKind, post: post}
	if isAgent(m.FromID) && m.FromBox != WUIBox {
		ev.agent, ev.box = m.FromID, m.FromBox
	}
	s.topicLoopFire(ctx, tenant, m.TaskID, ev)
}

// topicLoopIssueBefore is the issue's status before an update that sets
// one, read only when the workspace may have loops ("" = no hook).
func (s *Server) topicLoopIssueBefore(ctx context.Context, tenant string, number int, setsStatus bool) string {
	ls := s.loopStore()
	is, ok := s.o.Store.(store.Issues)
	if !setsStatus || ls == nil || !ok || !s.topicLoopsMaybe(ctx, ls, tenant) {
		return ""
	}
	i, err := is.GetIssue(ctx, tenant, number)
	if err != nil {
		return ""
	}
	return i.Status
}

// topicLoopIssue is the issue_status_changed hook (updateIssue, 4.2 step
// 12): each topic the issue links fires its loops once.
func (s *Server) topicLoopIssue(ctx context.Context, tenant, actor string, out store.Issue, before string) {
	idl, ok := s.o.Store.(store.IssueDiscussions)
	if before == "" || out.Status == before || !ok {
		return
	}
	links, err := idl.IssueDiscussionLinks(ctx, tenant, []int{out.Number})
	if err != nil {
		s.o.Log.Error().Err(err).Int("number", out.Number).Msg("topic loop: issue links")
		return
	}
	n := strconv.Itoa(out.Number)
	ev := loopEvent{kind: loopEventIssue,
		cause: "issue:" + n + ":" + out.Status + ":" + out.UpdatedAt.UTC().Format(time.RFC3339),
		quote: out.Prefix + "-" + n + " " + out.Title + ": " + before + " -> " + out.Status + ", by " + actor}
	seen := map[string]bool{}
	for _, d := range links[out.Number] {
		if d.OriginTenant == "" && !seen[d.TaskID] {
			seen[d.TaskID] = true
			s.topicLoopFire(ctx, tenant, d.TaskID, ev)
		}
	}
}

// topicLoopFire fires every loop of task that ev matches.
func (s *Server) topicLoopFire(ctx context.Context, tenant, task string, ev loopEvent) {
	s.topicLoopFireIf(ctx, tenant, task, ev, nil)
}

// topicLoopFireIf is topicLoopFire with a last gate that runs only when a
// loop matches (it may cost a read).
func (s *Server) topicLoopFireIf(ctx context.Context, tenant, task string, ev loopEvent, gate func() bool) {
	ls := s.loopStore()
	if ls == nil || !isLoopTrigger(ev.post) || !uuidRe.MatchString(task) || !s.topicLoopsMaybe(ctx, ls, tenant) {
		return
	}
	loops, err := ls.TopicLoopsOn(ctx, tenant, task)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("task_id", task).Msg("topic loop: read")
		return
	}
	s.loopIdleTimer(ctx, ls, tenant, task, ev, loops)
	var hit []store.TopicLoop
	for _, l := range loops {
		if ev.matches(l) && !s.loopAwaited(ctx, ls, l, ev) {
			hit = append(hit, l)
		}
	}
	if len(hit) == 0 || (gate != nil && !gate()) {
		return
	}
	if why := s.loopTopicHeld(ctx, tenant, task); why != "" {
		s.loopSkip(tenant, task, "", why)
		return
	}
	for _, l := range hit {
		s.loopSend(ctx, ls, l, ev)
	}
}

// loopIdleTimer arms (a human post) or clears (an agent reply) the topic's
// no_reply_after_human loops (4.2 step 11); no write when none has the box.
func (s *Server) loopIdleTimer(ctx context.Context, ls store.TopicLoopStore, tenant, task string, ev loopEvent, loops []store.TopicLoop) {
	idle := slices.ContainsFunc(loops, func(l store.TopicLoop) bool { return slices.Contains(l.Triggers, store.LoopNoReplyAfterHuman) })
	var err error
	switch {
	case !idle:
		return
	case ev.arm:
		_, err = ls.ArmTopicLoopIdle(ctx, tenant, task, ev.post.MsgID, s.o.Now().UTC())
	case ev.clear:
		_, err = ls.ClearTopicLoopIdle(ctx, tenant, task)
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("topic loop: idle timer not written")
	}
}

// loopAwaited is Q10 A: ev is the awaited answer to l's last fire (the
// target agent's next post, whatever box it matches), so it clears the
// wait and does not fire l.
func (s *Server) loopAwaited(ctx context.Context, ls store.TopicLoopStore, l store.TopicLoop, ev loopEvent) bool {
	if s.o.TopicLoopSelfFire || ev.kind != loopEventPost || l.Awaiting == "" || l.Awaiting != ev.post.From {
		return false
	}
	if !s.o.Now().Before(l.AwaitUntil) {
		return false
	}
	if err := ls.SetTopicLoopAwaiting(ctx, l.TenantID, l.LoopID, "", time.Time{}); err != nil {
		s.o.Log.Error().Err(err).Str("loop_id", l.LoopID).Msg("topic loop: awaiting not cleared")
	}
	s.loopSkip(l.TenantID, l.TaskID, l.LoopID, "the awaited answer to this loop's prompt")
	return true
}

// loopTopicHeld is why the topic fires nothing ("" = it may): archived or
// paused (4.2 step 7).
func (s *Server) loopTopicHeld(ctx context.Context, tenant, task string) string {
	closed, err := s.topicClosed(ctx, tenant, task)
	if err != nil || closed {
		return "topic archived or unreadable"
	}
	if ps, ok := s.o.Store.(store.TopicPauseStore); ok {
		_, paused, err := ps.AnyTopicPaused(ctx, tenant, task)
		if err != nil || paused {
			return "topic paused or unreadable"
		}
	}
	return ""
}

// loopSkip logs one line for a loop that does not fire.
func (s *Server) loopSkip(tenant, task, loopID, why string) {
	s.o.Log.Info().Str("tenant", tenant).Str("task_id", task).Str("loop_id", loopID).Str("why", why).Msg("topic loop: not fired")
}

// loopSend runs l's own checks (author, target, cap) and sends its prompt.
func (s *Server) loopSend(ctx context.Context, ls store.TopicLoopStore, l store.TopicLoop, ev loopEvent) {
	if idle := s.loopIdle(ctx, l, nil); idle != "" {
		s.loopSkip(l.TenantID, l.TaskID, l.LoopID, idle)
		return
	}
	envs, err := s.o.Store.TaskEnvelopes(ctx, l.TenantID, l.TaskID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", l.TaskID).Msg("topic loop: topic read")
		return
	}
	tg, ok := s.loopTarget(ctx, l, ev, envs)
	if !ok {
		s.loopSkip(l.TenantID, l.TaskID, l.LoopID, "no announced agent in the topic")
		return
	}
	now := s.o.Now().UTC()
	c := s.loopCause(ctx, l, ev, envs, now)
	counted, fired, err := ls.CountTopicLoopFire(ctx, l.TenantID, l.LoopID, now, s.topicLoopCap())
	if err != nil || !fired {
		s.loopSkip(l.TenantID, l.TaskID, l.LoopID, "capped, paused or gone")
		return
	}
	l = counted
	m := s.loopMessage(l, c, tg.agent, now)
	if err := s.loopStorePrompt(ctx, l, tg, m); err != nil {
		s.o.Log.Error().Err(err).Str("loop_id", l.LoopID).Str("msg_id", m.MsgID).Msg("topic loop: prompt not stored")
		return
	}
	s.o.Log.Info().Str("tenant", l.TenantID).Str("task_id", l.TaskID).Str("loop_id", l.LoopID).Str("to", tg.agent).
		Str("msg_id", m.MsgID).Str("event", ev.kind).Msg("topic loop: fired")
	if !s.o.TopicLoopSelfFire {
		if err := ls.SetTopicLoopAwaiting(ctx, l.TenantID, l.LoopID, tg.agent, now.Add(topicLoopAwait)); err != nil {
			s.o.Log.Error().Err(err).Str("loop_id", l.LoopID).Msg("topic loop: awaiting not set")
		}
	}
}

// loopTarget is the agent the prompt goes to, its box and the box-wui pin
// (4.3 steps 1 and 4): the agent the event names, else the topic's newest
// agent announced now. The checks are a dispatch's, with the loop's author
// as the commanding member (box locks, channel pins, announced, pinned).
func (s *Server) loopTarget(ctx context.Context, l store.TopicLoop, ev loopEvent, envs [][]byte) (wuiSigning, bool) {
	c := &wuiConn{tenant: l.TenantID, from: l.SetBy, member: l.SetBy}
	cands := topicAgents(envs)
	if ev.agent != "" {
		cands = [][2]string{{ev.agent, ev.box}}
	}
	for _, p := range cands {
		probe := msg.Message{TaskID: l.TaskID, From: l.SetBy, To: p[0], Kind: "task"}
		box, pin, tok, _, _ := s.dispatchCheckIn(ctx, c, &probe, p[1], "")
		if tok == "" {
			return wuiSigning{agent: p[0], box: box, pin: pin}, true
		}
		if tok == "wui_unpinned" {
			return wuiSigning{}, false
		}
	}
	return wuiSigning{}, false
}

// loopFireCause is what a fire quotes and seeds its id on (7.1.1 table).
type loopFireCause struct {
	seed, head, quote string
}

// loopCause: a post's id and body; an idle fire's arming post; a time
// fire's due time and the topic's latest post; an issue fire's change.
func (s *Server) loopCause(ctx context.Context, l store.TopicLoop, ev loopEvent, envs [][]byte, now time.Time) loopFireCause {
	switch {
	case ev.post != nil:
		return loopFireCause{ev.post.MsgID, "fired by msg:" + ev.post.MsgID, ev.post.Body}
	case ev.kind == loopEventIssue:
		return loopFireCause{ev.cause, "fired by an issue status change", ev.quote}
	case slices.Contains(l.Due, store.LoopNoReplyAfterHuman) && l.IdlePost != "":
		body := "the post that armed it is gone"
		if m, err := s.o.Store.GetEditable(ctx, l.TenantID, l.IdlePost, now); err == nil {
			body = m.Body
		}
		return loopFireCause{l.IdlePost, "fired by no reply to msg:" + l.IdlePost, body}
	}
	return loopFireCause{"due:" + loopDueClaimed(l, now).Format(time.RFC3339), "fired by its timer", latestPost(envs, l.LastFiredAt)}
}

// loopDueClaimed is the due time a claim fired: the earliest of the row's
// due columns as the claim returned them, else the claim's minute. The
// claim moves the columns on in the same statement, so the value is one
// per claim either way, which is all the id needs.
func loopDueClaimed(l store.TopicLoop, now time.Time) time.Time {
	due := time.Time{}
	for _, t := range []time.Time{l.NextDueAt, l.DailyDueAt} {
		if !t.IsZero() && (due.IsZero() || t.Before(due)) {
			due = t
		}
	}
	if due.IsZero() {
		due = now.Truncate(time.Minute)
	}
	return due.UTC()
}

// loopMessage is the fired prompt (4.3 step 2): kind task from the author
// to the target, its id derived from (loop, cause) (4.3 step 3).
func (s *Server) loopMessage(l store.TopicLoop, c loopFireCause, agent string, now time.Time) *msg.Message {
	body := topicLoopPromptMark + "set by @" + l.SetBy + ", " + c.head + ")\n\n" + l.Prompt + "\n\n" + quoteBlock(c.quote)
	return &msg.Message{V: s.writeVersion(), MsgID: uid.FromSeed("topic-loop:" + l.LoopID + ":" + c.seed), TaskID: l.TaskID,
		TS: now.Format(time.RFC3339), From: l.SetBy, To: agent, Kind: "task", Body: body, Files: []msg.Attachment{}}
}

// latestPost is the body of the topic's newest post that is not a loop
// prompt, or the "nothing new" line when it is not newer than prev.
func latestPost(envs [][]byte, prev time.Time) string {
	for i := len(envs) - 1; i >= 0; i-- {
		e, err := wire.ParseEnvelope(envs[i])
		if err != nil {
			continue
		}
		in, err := e.Inner()
		if err != nil || !isLoopTrigger(in) {
			continue
		}
		if ts, err := time.Parse(time.RFC3339, in.TS); err == nil && !prev.IsZero() && !ts.After(prev) {
			break
		}
		return in.Body
	}
	return "no new post since the last fire"
}

// quoteBlock is text cut to topicLoopQuoteMax characters, as one quote block.
func quoteBlock(text string) string {
	if r := []rune(text); len(r) > topicLoopQuoteMax {
		text = string(r[:topicLoopQuoteMax]) + "…"
	}
	return "> " + strings.ReplaceAll(strings.TrimSpace(text), "\n", "\n> ")
}

// loopStorePrompt signs m as box-wui for the target's box, with no channel
// tag (only that box gets it, routeChannel does not fan it out), and stores
// it through commitRowTyped with its loop id (fanoutWUI skips the row).
func (s *Server) loopStorePrompt(ctx context.Context, l store.TopicLoop, tg wuiSigning, m *msg.Message) error {
	if err := m.Validate(); err != nil {
		return err
	}
	env, err := s.dispatchEnvelope(tg.box, "", "", tg.pin, m)
	if err != nil {
		return err
	}
	_, err = s.commitRowTyped(withLoopID(ctx, l.LoopID), l.TenantID, env, m, 0, "")
	return err
}

// loopIDKey carries a loop prompt's loop id to commitRowTyped.
type loopIDKey struct{}

// withLoopID marks the row as loop's prompt and drops what the trigger
// post's send put on ctx: a DM mirror (dm_ref.go) and a note to self are
// that post's, never the prompt's.
func withLoopID(ctx context.Context, loopID string) context.Context {
	ctx = context.WithValue(ctx, dmRefKey{}, nil)
	ctx = context.WithValue(ctx, noteToSelfKey{}, false)
	return context.WithValue(ctx, loopIDKey{}, loopID)
}

// loopIDOf is the loop id withLoopID set, "" for every other row.
func loopIDOf(ctx context.Context) string {
	id, _ := ctx.Value(loopIDKey{}).(string)
	return id
}

// runTopicLoopTimer fires the due time loops every topicLoopTimerEvery
// until ctx ends (4.2 step 5, the runGcalSync pattern).
func (s *Server) runTopicLoopTimer(ctx context.Context) {
	t := time.NewTicker(topicLoopTimerEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.TopicLoopTickOnce(ctx)
		}
	}
}

// TopicLoopTickOnce claims the due time loops of every workspace and fires
// each once, however many of its time keys came due. The claim moves the
// due columns on in the same statement, so two hub instances never fire one
// tick twice and a missed tick fires once. It answers how many it claimed.
func (s *Server) TopicLoopTickOnce(ctx context.Context) int {
	ls := s.loopStore()
	if ls == nil {
		return 0
	}
	due, err := ls.ClaimDueTopicLoops(ctx, s.o.Now().UTC(), topicLoopTimerBatch)
	if err != nil {
		s.o.Log.Warn().Err(err).Msg("topic loop: timer claim")
		return 0
	}
	ev := loopEvent{kind: loopEventTime}
	for _, l := range due {
		if l.State != store.TopicLoopOn || !ev.matches(l) {
			continue
		}
		if why := s.loopTopicHeld(ctx, l.TenantID, l.TaskID); why != "" {
			s.loopSkip(l.TenantID, l.TaskID, l.LoopID, why)
			continue
		}
		s.loopSend(ctx, ls, l, ev)
	}
	return len(due)
}
