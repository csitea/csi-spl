package store

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"
)

// The per-member Flow (spec 062, rdb 0104, contract
// specs/062-flow-per-user-counts/contracts/flow-v1.md). Relevance is decided
// when a line is stored, in the statement that stores it (Postgres:
// flowInsertCTE, 0 extra round trips), so the badge and the page are one
// indexed read each.

// Flow event kinds, strongest first (spec 062 section 2.1).
const (
	FlowMention = "mention"
	FlowPoke    = "poke"
	FlowDM      = "dm"
	FlowReply   = "reply"
)

// flowKinds is the precedence: index+1 is the rank the insert picks by.
var flowKinds = []string{FlowMention, FlowPoke, FlowDM, FlowReply}

// FlowSeenKey is the read_marks key of "the member opened the Flow pane".
const FlowSeenKey = "f:seen"

// FlowMarkKey is the read_marks key of "the member opened this entry".
func FlowMarkKey(msgID string) string { return "f:" + msgID }

// FlowCounts is one count per chip; Mention includes pokes, Total the sum.
type FlowCounts struct {
	Mention int `json:"mention"`
	Reply   int `json:"reply"`
	DM      int `json:"dm"`
	Total   int `json:"total"`
}

func (c *FlowCounts) add(kind string) {
	switch kind {
	case FlowMention, FlowPoke:
		c.Mention++
	case FlowReply:
		c.Reply++
	case FlowDM:
		c.DM++
	}
	c.Total++
}

// FlowEvent is one entry: the event and the thin projection of its message
// (never the envelope). Body is the head of the text; the hub folds and cuts it.
type FlowEvent struct {
	MsgID, TaskID, ParentTaskID, Channel  string
	FromID, FromBox, ToID, ToBox, TypedBy string
	Kind                                  string
	Body                                  string
	At                                    time.Time
	Files                                 int
	Unread                                bool
}

// FlowQuery reads one member's flow. Limit 0 = the counts only.
type FlowQuery struct {
	Tenant, Member string
	Limit          int
	BeforeAt       time.Time // with BeforeID: the page starts after this event
	BeforeID       string
	Kind           string // "" = all; FlowMention includes pokes
	Now            time.Time
}

// FlowPage is a page of events, newest first, and the member's counts:
// Counts is unseen and unread (the badge), Unread is unread (the chips).
type FlowPage struct {
	Events []FlowEvent
	More   bool
	Counts FlowCounts
	Unread FlowCounts
}

// FlowPush is what the live fan-out sends one member for one stored line.
type FlowPush struct {
	Event  FlowEvent
	Counts FlowCounts
	Unread FlowCounts
}

// FlowEvents reads the flow. It is written by InsertMessage / InsertMessageSent.
type FlowEvents interface {
	// FlowRead is the page and the counts in one round trip.
	FlowRead(ctx context.Context, q FlowQuery) (FlowPage, error)
	// FlowFanout is, for the stored line msgID, the event and fresh counts of
	// each of members who got one (members without one are absent).
	FlowFanout(ctx context.Context, tenant, msgID string, members []string, now time.Time) (map[string]FlowPush, error)
}

var (
	_ FlowEvents = (*Memory)(nil)
	_ FlowEvents = (*Postgres)(nil)
)

// FlowMaxPage bounds one page.
const FlowMaxPage = 50

// flowTargets is what the insert decides for one line: the author (the
// human seat that wrote or typed it, "" for an agent), the human seats it
// mentions (never the author), and the task a poke DM links to.
type flowTargets struct {
	author   string
	mentions []string
	poke     string
	public   bool // a channel every member reads (no channel_humans door)
}

func flowTargetsOf(m Message) flowTargets {
	author := m.TypedBy
	if author == "" && IsFlowMember(m.FromID) {
		author = m.FromID
	}
	t := flowTargets{author: author, mentions: flowMentions(m.Body, author), public: ChannelPublic(m.Channel)}
	if m.Channel == "" {
		t.poke = PokeTask(m.Body)
	}
	return t
}

// memFlowEvent is one memory flow_events row.
type memFlowEvent struct {
	taskID    string
	kind      string
	at        time.Time
	expiresAt time.Time
}

// flowWriteLocked is the memory twin of flowInsertCTE. Caller holds s.mu and
// just stored m.
func (s *Memory) flowWriteLocked(m Message) {
	if s.flowWatches == nil {
		s.flowWatches, s.flowEvents = map[[3]string]time.Time{}, map[[3]string]memFlowEvent{}
	}
	t := flowTargetsOf(m)
	readable := func(member string) bool {
		if !IsFlowMember(member) || member == t.author {
			return false
		}
		if m.Channel == "" || t.public {
			return true
		}
		if s.ch.init(); s.ch.archivedCh(m.TenantID, m.Channel) {
			return false
		}
		_, ok := s.ch.humansLocked()[[2]string{m.TenantID, m.Channel}][member]
		return ok
	}
	rank := map[string]int{}
	pick := func(member string, r int) {
		if readable(member) && (rank[member] == 0 || r < rank[member]) {
			rank[member] = r
		}
	}
	if m.Channel != "" {
		for _, id := range t.mentions {
			pick(id, 1)
		}
		pick(m.ToID, 1)
		for k := range s.flowWatches {
			if k[0] == m.TenantID && k[1] == m.TaskID {
				pick(k[2], 4)
			}
		}
	} else {
		r := 3
		if containsStr(t.mentions, m.ToID) {
			r = 1
		} else if t.poke != "" {
			r = 2
		}
		pick(m.ToID, r)
	}
	watch := func(member string) {
		k := [3]string{m.TenantID, m.TaskID, member}
		if _, ok := s.flowWatches[k]; !ok {
			s.flowWatches[k] = m.ReceivedAt
		}
	}
	if t.author != "" {
		watch(t.author)
	}
	for member, r := range rank {
		if r < 4 {
			watch(member)
		}
		if r == 2 && s.flowMentionedInLocked(m.TenantID, member, t.poke) {
			continue // the poke folds into its mention (spec 062 2.3, Q5)
		}
		k := [3]string{m.TenantID, member, m.MsgID}
		if _, ok := s.flowEvents[k]; !ok {
			s.flowEvents[k] = memFlowEvent{taskID: m.TaskID, kind: flowKinds[r-1], at: m.ReceivedAt, expiresAt: m.ExpiresAt}
		}
	}
}

func (s *Memory) flowMentionedInLocked(tenant, member, task string) bool {
	for k, e := range s.flowEvents {
		if k[0] == tenant && k[1] == member && e.taskID == task && e.kind == FlowMention {
			return true
		}
	}
	return false
}

func containsStr(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

// flowEventLocked builds the entry for row k, ok=false when it is not
// listed: its message is gone or expired, or the read door shuts it.
func (s *Memory) flowEventLocked(k [3]string, e memFlowEvent, now time.Time) (FlowEvent, bool) {
	m, ok := s.messages[[2]string{k[0], k[2]}]
	if !ok || !now.Before(e.expiresAt) || !now.Before(m.ExpiresAt) {
		return FlowEvent{}, false
	}
	member := k[1]
	switch {
	case m.Channel == "":
		if m.ToID != member && m.FromID != member {
			return FlowEvent{}, false
		}
	case !ChannelPublic(m.Channel):
		if s.ch.init(); s.ch.archivedCh(k[0], m.Channel) {
			return FlowEvent{}, false
		}
		if _, ok := s.ch.humansLocked()[[2]string{k[0], m.Channel}][member]; !ok {
			return FlowEvent{}, false
		}
	}
	ev := FlowEvent{MsgID: m.MsgID, TaskID: m.TaskID, ParentTaskID: m.ParentTaskID, Channel: m.Channel,
		FromID: m.FromID, FromBox: m.FromBox, ToID: m.ToID, ToBox: m.ToBox, TypedBy: m.TypedBy,
		Kind: e.kind, Body: m.Body, At: m.ReceivedAt, Files: filesCount(m.Files)}
	ev.Unread = !s.flowCoveredLocked(k[0], member, m)
	return ev, true
}

// flowCoveredLocked: a mark covers the line (contract section 3).
func (s *Memory) flowCoveredLocked(tenant, member string, m *Message) bool {
	if _, ok := s.readMarks[[3]string{tenant, member, FlowMarkKey(m.MsgID)}]; ok {
		return true
	}
	keys := []string{ThreadMarkKey(m.TaskID)}
	if m.Channel != "" {
		keys = append(keys, "ch:"+m.Channel)
	} else {
		keys = append(keys, "dm:"+m.FromID, "dm:"+m.FromID+"@"+m.FromBox)
	}
	for _, key := range keys {
		if r, ok := s.readMarks[[3]string{tenant, member, key}]; ok && !newer(m.ReceivedAt, m.MsgID, r.At, r.MsgID) {
			return true
		}
	}
	return false
}

// flowListLocked is every listed event of member, newest first.
func (s *Memory) flowListLocked(tenant, member string, now time.Time) []FlowEvent {
	var out []FlowEvent
	for k, e := range s.flowEvents {
		if k[0] != tenant || k[1] != member {
			continue
		}
		if ev, ok := s.flowEventLocked(k, e, now); ok {
			out = append(out, ev)
		}
	}
	sort.Slice(out, func(i, j int) bool { return newer(out[i].At, out[i].MsgID, out[j].At, out[j].MsgID) })
	return out
}

func (s *Memory) flowCountsLocked(tenant, member string, all []FlowEvent) (counts, unread FlowCounts) {
	seen, hasSeen := s.readMarks[[3]string{tenant, member, FlowSeenKey}]
	for _, ev := range all {
		if !ev.Unread {
			continue
		}
		unread.add(ev.Kind)
		if !hasSeen || ev.At.After(seen.At) {
			counts.add(ev.Kind)
		}
	}
	return counts, unread
}

// flowKindMatch: the kind= filter, FlowMention taking pokes too.
func flowKindMatch(filter, kind string) bool {
	return filter == "" || filter == kind || filter == FlowMention && kind == FlowPoke
}

func (s *Memory) FlowRead(_ context.Context, q FlowQuery) (FlowPage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	all := s.flowListLocked(q.Tenant, q.Member, q.Now)
	var p FlowPage
	p.Counts, p.Unread = s.flowCountsLocked(q.Tenant, q.Member, all)
	for _, ev := range all {
		if q.Limit == 0 {
			break
		}
		if !flowKindMatch(q.Kind, ev.Kind) || q.BeforeID != "" && !newer(q.BeforeAt, q.BeforeID, ev.At, ev.MsgID) {
			continue
		}
		if len(p.Events) == q.Limit {
			p.More = true
			break
		}
		p.Events = append(p.Events, ev)
	}
	return p, nil
}

func (s *Memory) FlowFanout(_ context.Context, tenant, msgID string, members []string, now time.Time) (map[string]FlowPush, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]FlowPush{}
	for _, member := range members {
		k := [3]string{tenant, member, msgID}
		e, ok := s.flowEvents[k]
		if !ok {
			continue
		}
		ev, ok := s.flowEventLocked(k, e, now)
		if !ok {
			continue
		}
		c, u := s.flowCountsLocked(tenant, member, s.flowListLocked(tenant, member, now))
		out[member] = FlowPush{Event: ev, Counts: c, Unread: u}
	}
	return out, nil
}

// flowSweepMarksLocked drops the f:<msg_id> marks whose message is gone.
func (s *Memory) flowSweepMarksLocked() {
	for k := range s.readMarks {
		id, ok := strings.CutPrefix(k[2], "f:")
		if !ok || k[2] == FlowSeenKey {
			continue
		}
		if _, ok := s.messages[[2]string{k[0], id}]; !ok {
			delete(s.readMarks, k)
		}
	}
}

// filesCount is the length of a v:1 files[] JSON array.
func filesCount(files []byte) int {
	var xs []json.RawMessage
	if json.Unmarshal(files, &xs) != nil {
		return 0
	}
	return len(xs)
}
