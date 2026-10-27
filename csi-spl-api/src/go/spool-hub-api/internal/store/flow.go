package store

import (
	"bytes"
	"context"
	"encoding/json"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// The per-member Flow (spec 062, rdb 0104, contract
// specs/062-flow-per-user-counts/contracts/flow-v1.md). Relevance is decided
// when a line is stored, in the statement that stores it (Postgres:
// flowInsertCTE, 0 extra round trips), so the badge and the page are one
// indexed read each.

// Flow event kinds, strongest first (spec 062 section 2.1, spec 130
// section 4): blocked and ready label a whole line (a stored blocker, a line
// that carries the v:1 key accepts), so they outrank the per-member reason.
// release is never a row: the read merges it from release_notes.
const (
	FlowBlocked = "blocked"
	FlowReady   = "ready"
	FlowMention = "mention"
	FlowPoke    = "poke"
	FlowDM      = "dm"
	FlowReply   = "reply"
	FlowRelease = "release"
)

// flowKinds is the per-member precedence: index+1 is the rank the insert
// picks by. rdb 0177's CHECK is flowLineKinds + flowKinds.
var flowKinds = []string{FlowMention, FlowPoke, FlowDM, FlowReply}

// flowLineKinds label every event of one line, strongest first.
var flowLineKinds = []string{FlowBlocked, FlowReady}

// FlowSeenKey is the read_marks key of "the member opened the Flow pane".
const FlowSeenKey = "f:seen"

// FlowMarkKey is the read_marks key of "the member opened this entry".
func FlowMarkKey(msgID string) string { return "f:" + msgID }

// FlowCounts is one count per chip; Mention includes pokes and the line
// kinds blocked and ready (before spec 130 such a line was mostly a mention),
// Total the sum.
// Channels and DMs split the same Total by where the line is (owner, t1
// f4e6c677: the rail's Channels and Direct messages numbers).
//
// Release (spec 130 section 6) is in Counts only: the UTC days with a
// release newer than the member's f:seen, the release lines the pane has
// not shown yet. It is NOT in Total (Total stays the member's own events);
// the badge shows Total + Release. A member who never opened the pane counts
// none, so the release history is not a flood.
type FlowCounts struct {
	Mention  int `json:"mention"`
	Reply    int `json:"reply"`
	DM       int `json:"dm"`
	Total    int `json:"total"`
	Channels int `json:"channels"`
	DMs      int `json:"dms"`
	Release  int `json:"release"`
}

func (c *FlowCounts) add(kind, channel string) {
	if channel == "" {
		c.DMs++
	} else {
		c.Channels++
	}
	switch kind {
	case FlowMention, FlowPoke, FlowBlocked, FlowReady:
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
	Lobby          string // the lobby's task id ("" = none): an archived topic's lines are read (archivedHideSQL)
}

// FlowPage is a page of events, newest first, and the member's counts:
// Counts is unseen and unread (the badge), Unread is unread (the chips).
type FlowPage struct {
	Events []FlowEvent
	More   bool
	Counts FlowCounts
	Unread FlowCounts
	Keys   map[string]int // FlowKeys
}

// FlowPush is what the live fan-out sends one member for one stored line.
type FlowPush struct {
	Event  FlowEvent
	Counts FlowCounts
	Unread FlowCounts
	Keys   map[string]int // FlowKeys
}

// FlowKeys: Unread per sidebar row (owner, t1 77540e6f: a section's total
// is the sum of its rows). Every unread line counts once under its place,
// ch:<channel> or dm:<peer> (the sidebar's "<id>@<box>" label), and once
// under its topic, t:<task_id>. The rows are Unread's, so the ch: keys sum
// to Unread.Channels, the dm: keys to Unread.DMs and the t: keys to
// Unread.Total.
func flowKeysAdd(keys map[string]int, ev FlowEvent) {
	keys[flowPlaceKey(ev.Channel, ev.FromID, ev.FromBox)]++
	keys[ThreadMarkKey(ev.TaskID)]++
}

// flowPlaceKey is a line's sidebar row: its channel, or for a DM the sender
// as utils/channel-feed.mjs dmPeerOf labels it (a flow DM goes to its "to",
// so the peer is the sender, the end its covering dm: mark names).
func flowPlaceKey(channel, fromID, fromBox string) string {
	if channel != "" {
		return "ch:" + channel
	}
	if fromBox != "" {
		return "dm:" + fromID + "@" + fromBox
	}
	return "dm:" + fromID
}

// FlowEvents reads the flow. It is written by InsertMessage / InsertMessageSent.
type FlowEvents interface {
	// FlowRead is the page and the counts in one round trip.
	FlowRead(ctx context.Context, q FlowQuery) (FlowPage, error)
	// FlowFanout is, for the stored line msgID, the event and fresh counts of
	// each of members who got one (members without one are absent).
	FlowFanout(ctx context.Context, tenant, msgID string, members []string, now time.Time, lobby string) (map[string]FlowPush, error)
}

var (
	_ FlowEvents = (*Memory)(nil)
	_ FlowEvents = (*Postgres)(nil)
)

// FlowMaxPage bounds one page.
const FlowMaxPage = 50

// flowTargets is what the insert decides for one line: the author (the
// human seat that wrote or typed it, "" for an agent), the members it
// mentions (human seats, and agents named <id>@<box>; never the author),
// the line's `to` as a member key, the task a poke DM links to, and the
// line kind ("" = each member's own rank).
type flowTargets struct {
	author   string
	sender   string // the agent author <id>@<box>, "" for a human line
	mentions []string
	to       string
	poke     string
	label    string // FlowBlocked, FlowReady or ""
	public   bool   // a channel every member reads (no channel_humans door)
}

func flowTargetsOf(m Message) flowTargets {
	author := m.TypedBy
	if author == "" && IsFlowMember(m.FromID) {
		author = m.FromID
	}
	t := flowTargets{author: author, mentions: flowMentions(m.Body, author), to: flowMemberKey(m.ToID, m.ToBox),
		label: flowLineKind(m), public: ChannelPublic(m.Channel)}
	if author == "" {
		t.sender = flowMemberKey(m.FromID, m.FromBox)
	}
	if m.Channel == "" {
		t.poke = PokeTask(m.Body)
	}
	return t
}

// flowLineKind is the kind every event of m takes (spec 130 section 4): a
// stored blocker is blocked; a line that carries the v:1 key accepts is
// ready. No body is parsed.
func flowLineKind(m Message) string {
	switch {
	case m.Kind == "blocker":
		return FlowBlocked
	case MessageAccepts(m.Msg) != "":
		return FlowReady
	}
	return ""
}

// MessageAccepts is the msg_id the inner v:1 object accepts ("" = none):
// the key `accepts` (spec 130 section 4, message-schema.md).
func MessageAccepts(inner []byte) string {
	if !bytes.Contains(inner, []byte(`"accepts"`)) {
		return ""
	}
	var x struct {
		Accepts string `json:"accepts"`
	}
	if json.Unmarshal(inner, &x) != nil {
		return ""
	}
	return x.Accepts
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
	rank := s.flowRankLocked(m, t)
	s.flowRecordLocked(m, t, rank)
}

// flowReadableLocked: member may get a flow row of rank r for m (the door).
func (s *Memory) flowReadableLocked(m Message, t flowTargets, member string, r int) bool {
	if member == "" || member == t.author || member == t.sender {
		return false
	}
	agent := IsFlowAgent(member)
	if !IsFlowMember(member) && !(agent && (r == 1 && m.Channel != "" || m.Channel == "" && t.label == FlowReady)) {
		return false // an agent takes channel mentions and an accepting DM only (spec 130 section 5)
	}
	if m.Channel == "" || t.public {
		return true
	}
	if s.ch.init(); s.ch.archivedCh(m.TenantID, m.Channel) {
		return false
	}
	if agent {
		return s.agentInChannelLocked(m.TenantID, m.Channel, member)
	}
	_, ok := s.ch.humansLocked()[[2]string{m.TenantID, m.Channel}][member]
	return ok
}

// flowRankLocked maps each member who reads m to its best (lowest) rank.
func (s *Memory) flowRankLocked(m Message, t flowTargets) map[string]int {
	rank := map[string]int{}
	pick := func(member string, r int) {
		if s.flowReadableLocked(m, t, member, r) && (rank[member] == 0 || r < rank[member]) {
			rank[member] = r
		}
	}
	if m.Channel != "" {
		for _, id := range t.mentions {
			pick(id, 1)
		}
		pick(t.to, 1)
		for k := range s.flowWatches {
			if k[0] == m.TenantID && k[1] == m.TaskID {
				pick(k[2], 4)
			}
		}
	} else {
		r := 3
		if slices.Contains(t.mentions, m.ToID) {
			r = 1
		} else if t.poke != "" {
			r = 2
		}
		pick(t.to, r)
	}
	return rank
}

// flowRecordLocked stores the watches and one flow event per ranked member.
func (s *Memory) flowRecordLocked(m Message, t flowTargets, rank map[string]int) {
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
		if r < 4 && IsFlowMember(member) {
			watch(member)
		}
		if r == 2 && s.flowMentionedInLocked(m.TenantID, member, t.poke) {
			continue // the poke folds into its mention (spec 062 2.3, Q5)
		}
		kind := t.label
		if kind == "" {
			kind = flowKinds[r-1]
		}
		k := [3]string{m.TenantID, member, m.MsgID}
		if _, ok := s.flowEvents[k]; !ok {
			s.flowEvents[k] = memFlowEvent{taskID: m.TaskID, kind: kind, at: m.ReceivedAt, expiresAt: m.ExpiresAt}
		}
	}
}

// agentInChannelLocked: the agent <id>@<box> is a member of channel (the
// door's agent branch, channel_subscriptions not removed).
func (s *Memory) agentInChannelLocked(tenant, channel, key string) bool {
	id, box := agentid.SplitAtBox(key)
	k := [4]string{tenant, channel, box, id}
	if _, out := s.ch.removed[k]; out {
		return false
	}
	_, invited := s.ch.invited[k]
	return invited || slices.Contains(s.ch.subs[[2]string{tenant, box}][channel], id)
}

func (s *Memory) flowMentionedInLocked(tenant, member, task string) bool {
	for k, e := range s.flowEvents {
		if k[0] == tenant && k[1] == member && e.taskID == task && e.kind == FlowMention {
			return true
		}
	}
	return false
}

// flowEventLocked builds the entry for row k, ok=false when it is not
// listed: its message is gone or expired, or the read door shuts it.
func (s *Memory) flowEventLocked(k [3]string, e memFlowEvent, now time.Time, lobby string) (FlowEvent, bool) {
	m, ok := s.messages[[2]string{k[0], k[2]}]
	if !ok || !now.Before(e.expiresAt) || !now.Before(m.ExpiresAt) {
		return FlowEvent{}, false
	}
	member := k[1]
	if !s.flowDoorLocked(k[0], member, m) {
		return FlowEvent{}, false
	}
	ev := FlowEvent{MsgID: m.MsgID, TaskID: m.TaskID, ParentTaskID: m.ParentTaskID, Channel: m.Channel,
		FromID: m.FromID, FromBox: m.FromBox, ToID: m.ToID, ToBox: m.ToBox, TypedBy: m.TypedBy,
		Kind: e.kind, Body: m.Body, At: m.ReceivedAt, Files: filesCount(m.Files)}
	ev.Unread = !s.flowCoveredLocked(k[0], member, m) && !s.archivedHiddenLocked(k[0], m, lobby) && !s.flowHeadlessLocked(k[0], m, now, lobby)
	return ev, true
}

// flowDoorLocked is flowDoorSQL: a DM by its two ends (an agent end as
// <id>@<box>), a created channel by its (unarchived) member list, a public
// channel for every member.
func (s *Memory) flowDoorLocked(tenant, member string, m *Message) bool {
	switch {
	case m.Channel == "":
		return slices.Contains([]string{m.ToID, m.FromID, m.ToID + "@" + m.ToBox, m.FromID + "@" + m.FromBox}, member)
	case !ChannelPublic(m.Channel):
		if s.ch.init(); s.ch.archivedCh(tenant, m.Channel) {
			return false
		}
		if IsFlowAgent(member) {
			return s.agentInChannelLocked(tenant, m.Channel, member)
		}
		_, ok := s.ch.humansLocked()[[2]string{tenant, m.Channel}][member]
		return ok
	}
	return true
}

// flowCoveredLocked: a mark covers the line (contract section 3). A ch:
// mark covers a channel line only while the member has no t: mark for its
// topic: the thread mark decides that topic's lines, as its card counts them
// (SPL-2124, the CLE-77930 rule).
func (s *Memory) flowCoveredLocked(tenant, member string, m *Message) bool {
	if _, ok := s.readMarks[[3]string{tenant, member, FlowMarkKey(m.MsgID)}]; ok {
		return true
	}
	tm, threaded := s.readMarks[[3]string{tenant, member, ThreadMarkKey(m.TaskID)}]
	if threaded && !newer(m.ReceivedAt, m.MsgID, tm.At, tm.MsgID) {
		return true
	}
	keys := []string{"dm:" + m.FromID, "dm:" + m.FromID + "@" + m.FromBox}
	if m.Channel != "" {
		if threaded {
			return false
		}
		keys = []string{"ch:" + m.Channel}
	}
	for _, key := range keys {
		if r, ok := s.readMarks[[3]string{tenant, member, key}]; ok && !newer(m.ReceivedAt, m.MsgID, r.At, r.MsgID) {
			return true
		}
	}
	return false
}

// flowHeadlessLocked: a channel line whose topic (its parent topic for a
// sub-thread line) has no live is_parent 1 row in that channel is read, as
// flowHeadlessSQL (SPL-2506): the channel shows no card for it. The issues
// and tasks boards list their lines on their own pages.
func (s *Memory) flowHeadlessLocked(tenant string, m *Message, now time.Time, lobby string) bool {
	topic := m.ParentTaskID
	if topic == "" {
		topic = m.TaskID
	}
	if m.Channel == "" || m.Channel == ChannelIssues || m.Channel == ChannelTasks || topic == lobby {
		return false
	}
	for k, h := range s.messages {
		if k[0] == tenant && h.TaskID == topic && h.Channel == m.Channel && h.IsParent == 1 && h.ExpiresAt.After(now) {
			return false
		}
	}
	return true
}

// flowListLocked is every listed event of member, newest first.
func (s *Memory) flowListLocked(tenant, member string, now time.Time, lobby string) []FlowEvent {
	var out []FlowEvent
	for k, e := range s.flowEvents {
		if k[0] != tenant || k[1] != member {
			continue
		}
		if ev, ok := s.flowEventLocked(k, e, now, lobby); ok {
			out = append(out, ev)
		}
	}
	sort.Slice(out, func(i, j int) bool { return newer(out[i].At, out[i].MsgID, out[j].At, out[j].MsgID) })
	return out
}

// flowCountsLocked is flowCountsSQL: the counts of the member's listed
// events, their keys, and flowChannelKeysLocked's lines in the keys only.
func (s *Memory) flowCountsLocked(tenant, member string, all []FlowEvent, now time.Time, lobby string) (counts, unread FlowCounts, keys map[string]int) {
	seen, hasSeen := s.readMarks[[3]string{tenant, member, FlowSeenKey}]
	keys = map[string]int{}
	for _, ev := range all {
		if !ev.Unread {
			continue
		}
		unread.add(ev.Kind, ev.Channel)
		flowKeysAdd(keys, ev)
		if !hasSeen || ev.At.After(seen.At) {
			counts.add(ev.Kind, ev.Channel)
		}
	}
	if hasSeen {
		counts.Release = s.flowReleaseDaysAfter(seen.At)
	}
	s.flowChannelKeysLocked(tenant, member, keys, now, lobby)
	return counts, unread, keys
}

// flowChannelKeysLocked adds to keys the unread channel lines of a human
// member that have no flow event of theirs, as flowChannelKeysSQL (SPL-2837):
// a channel row and its cards count every line the channel view counts.
func (s *Memory) flowChannelKeysLocked(tenant, member string, keys map[string]int, now time.Time, lobby string) {
	if !IsFlowMember(member) {
		return
	}
	for k, m := range s.messages {
		if k[0] != tenant || m.Channel == "" || ChannelHidden(m.Channel) || !now.Before(m.ExpiresAt) || m.FromID == member || m.TypedBy == member {
			continue
		}
		if _, ok := s.flowEvents[[3]string{tenant, member, m.MsgID}]; ok {
			continue
		}
		if !s.flowDoorLocked(tenant, member, m) || s.flowCoveredLocked(tenant, member, m) || s.archivedHiddenLocked(tenant, m, lobby) || s.flowHeadlessLocked(tenant, m, now, lobby) {
			continue
		}
		keys[flowPlaceKey(m.Channel, "", "")]++
		keys[ThreadMarkKey(m.TaskID)]++
	}
}

// flowReleaseDaysAfter is the UTC days with a release after t.
func (s *Memory) flowReleaseDaysAfter(t time.Time) int {
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	days := map[string]bool{}
	for sha, at := range memReleased[s] {
		if at.After(t) && s.releases()[sha].Version != "" {
			days[flowDay(at)] = true
		}
	}
	return len(days)
}

// flowKindMatch: the kind= filter, FlowMention taking pokes too.
func flowKindMatch(filter, kind string) bool {
	return filter == "" || filter == kind || filter == FlowMention && (kind == FlowPoke || kind == FlowBlocked || kind == FlowReady)
}

func (s *Memory) FlowRead(_ context.Context, q FlowQuery) (FlowPage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	all := s.flowListLocked(q.Tenant, q.Member, q.Now, q.Lobby)
	var p FlowPage
	p.Counts, p.Unread, p.Keys = s.flowCountsLocked(q.Tenant, q.Member, all, q.Now, q.Lobby)
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

func (s *Memory) FlowFanout(_ context.Context, tenant, msgID string, members []string, now time.Time, lobby string) (map[string]FlowPush, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]FlowPush{}
	for _, member := range members {
		k := [3]string{tenant, member, msgID}
		e, ok := s.flowEvents[k]
		if !ok {
			continue
		}
		ev, ok := s.flowEventLocked(k, e, now, lobby)
		if !ok {
			continue
		}
		c, u, keys := s.flowCountsLocked(tenant, member, s.flowListLocked(tenant, member, now, lobby), now, lobby)
		out[member] = FlowPush{Event: ev, Counts: c, Unread: u, Keys: keys}
	}
	return out, nil
}

// flowSweepMarksLocked drops the f:<msg_id> marks whose message is gone.
func (s *Memory) flowSweepMarksLocked() {
	for k := range s.readMarks {
		id, ok := strings.CutPrefix(k[2], "f:")
		if !ok || k[2] == FlowSeenKey || strings.HasPrefix(k[2], FlowReleaseMarkKey("")) {
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
