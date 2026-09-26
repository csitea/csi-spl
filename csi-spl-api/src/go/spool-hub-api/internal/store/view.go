package store

import (
	"context"
	"crypto/ed25519"
	"sort"
	"time"
)

// Read-only viewer queries (specs/003 contracts/view-v1.md, FR-018/FR-019).
// Nothing here writes: no delivery claim, no roster, pin or last_hello_at
// change. Every query is tenant-scoped and sees only messages in retention
// (expires_at > Now).

// ViewBox is one pinned box (revoked pins included) for GET /v1/view/roster.
type ViewBox struct {
	BoxID       string
	PubKey      ed25519.PublicKey
	Revoked     bool
	LastHelloAt time.Time // zero: never said hello
	Agents      []string  // last announcement, sorted
}

// TopicQuery pages GET /v1/view/topics: newest activity first, strictly
// before (BeforeAt, BeforeTask) when BeforeAt is set.
type TopicQuery struct {
	Channel  string // "" = any
	Agent    string // "" = any; else from_id or to_id of some message
	AgentBox string // with Agent: that message's from_box / to_box must match too
	DM       bool   // only messages with no channel (channels-v1 §0)
	Roots    bool   // only topics whose first message has no parent_task_id
	Parent   string // "" = any; else only topics whose parent_task_id is this
	Viewer   string // "" = any; else only topics with a message from or to this id
	// NoIssues drops the discussion topic of every issue (rdb 0047, specs/039):
	// an issue's comments live in its right pane, never as a topic of a list.
	NoIssues bool
	// Lobby is the shared lobby task (SPL-983): an archived card there hides
	// its own row and thread, never the lobby. Archived topics are left out
	// of every list (specs/041 §3.1).
	Lobby string
	// Reader is the member the list is FOR (rdb 0028, the read door): it
	// keeps only topics in a channel that member may read, plus DMs it is
	// an end of. "" = no door (the door-off rig). Unlike Viewer, which is
	// the caller's explicit dm=true filter, this one is not optional.
	Reader string
	// ReaderChannels are the CREATED channels Reader belongs to. The default
	// channels are public and always readable, so they are not listed here.
	ReaderChannels []string
	BeforeAt       time.Time
	BeforeTask     string
	Limit          int
	Now            time.Time
}

// TopicRow is one task_id's aggregate. Times are hub receive times.
type TopicRow struct {
	TaskID   string
	Channel  string // of the first message; "" = none
	Parent   string // parent_task_id of the first message; "" = none (a root)
	FirstAt  time.Time
	LastAt   time.Time
	Count    int
	Kinds    []string // one per message, oldest first
	Parties  []string // "<agent>@<box>" for every from and to, unsorted, may repeat
	FirstMsg []byte   // inner v:1 JSON of the first message
}

// TopicMsgQuery pages GET /v1/view/topics/{task_id}: oldest first, strictly
// after (AfterAt, AfterID) when AfterAt is set; or, with Desc, newest first,
// strictly before (BeforeAt, BeforeID) when BeforeAt is set (chat-reverse
// windows, SPEC-spool-chat-reverse.md §3).
type TopicMsgQuery struct {
	// Reader is the member reading (rdb 0028). Messages it may not read are
	// not returned AT ALL - not redacted, not counted - so a page of a
	// topic that mixes a DM with a channel reply hands back only the half
	// this reader is entitled to. "" = no door (the door-off rig).
	Reader         string
	ReaderChannels []string
	TaskID         string
	// HideArchived leaves archived rows out (specs/041): the lobby feed,
	// whose archived cards are rows of this one task.
	HideArchived bool
	AfterAt      time.Time
	AfterID      string
	Desc         bool
	BeforeAt     time.Time
	BeforeID     string
	Limit        int
	Now          time.Time
}

// ViewMsg is one stored envelope with its hub-side delivery rows.
type ViewMsg struct {
	MsgID      string
	ReceivedAt time.Time
	Env        []byte
	Deliveries []ViewDelivery
	// The edit marker (specs/032 contracts/message-edit-v1.md §2.1). Zero /
	// "" / 0 = never edited, and the view then emits no key at all. An edit
	// changes neither ReceivedAt nor the cursor built from it: the message
	// must not move in the topic because someone fixed a typo.
	EditedAt time.Time
	EditedBy string
	Revision int
	// IsParent is messages.is_parent (rdb 0034). 0 when the column is 0.
	IsParent int
	// TypedBy is messages.typed_by (rdb 0040); "" = the agent wrote it.
	TypedBy string
	// SPL-952 (rdb 0060): the kind as set after sending. All three are zero
	// while nobody changed it, and the view then emits no override at all.
	Kind      string
	KindSetAt time.Time
	KindSetBy string
}

// ViewDelivery is a deliveries row as the viewer sees it (never changed).
type ViewDelivery struct {
	ToBox string
	State string
}

// ChannelRow is one channel seen in stored messages.
type ChannelRow struct {
	Channel string
	Count   int
	LastAt  time.Time
}

// newer orders (at, id) descending: true when a sorts before b.
func newer(aAt time.Time, aID string, bAt time.Time, bID string) bool {
	if !aAt.Equal(bAt) {
		return aAt.After(bAt)
	}
	return aID > bID
}

func (s *Memory) ViewBoxes(_ context.Context, tenant string) ([]ViewBox, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []ViewBox
	for k, p := range s.pins {
		if k[0] != tenant {
			continue
		}
		out = append(out, ViewBox{
			BoxID: k[1], PubKey: p.pub, Revoked: p.revoked,
			LastHelloAt: s.boxes[k], Agents: append([]string{}, s.roster[k]...),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].BoxID < out[j].BoxID })
	return out, nil
}

// liveLocked returns the tenant's messages still in retention.
func (s *Memory) liveLocked(tenant string, now time.Time) []*Message {
	var ms []*Message
	for k, m := range s.messages {
		if k[0] == tenant && m.ExpiresAt.After(now) {
			ms = append(ms, m)
		}
	}
	sort.Slice(ms, func(i, j int) bool { return newer(ms[j].ReceivedAt, ms[j].MsgID, ms[i].ReceivedAt, ms[i].MsgID) })
	return ms
}

func (s *Memory) ViewTopics(_ context.Context, tenant string, q TopicQuery) ([]TopicRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	byTask := map[string]*TopicRow{}
	match := map[string]bool{}
	seen := map[string]bool{}
	for _, m := range s.liveLocked(tenant, q.Now) { // oldest first
		if q.Channel != "" && m.Channel != q.Channel {
			continue
		}
		if q.DM && m.Channel != "" {
			continue
		}
		if q.Agent == "" || (m.FromID == q.Agent && (q.AgentBox == "" || m.FromBox == q.AgentBox)) ||
			(m.ToID == q.Agent && (q.AgentBox == "" || m.ToBox == q.AgentBox)) {
			match[m.TaskID] = true
		}
		if q.Reader != "" && !readableBy(m.Channel, m.FromID, m.ToID, q.Reader, q.ReaderChannels) {
			continue
		}
		if q.Viewer == "" || m.FromID == q.Viewer || m.ToID == q.Viewer {
			seen[m.TaskID] = true
		}
		r := byTask[m.TaskID]
		if r == nil {
			r = &TopicRow{TaskID: m.TaskID, Channel: m.Channel, Parent: m.ParentTaskID, FirstAt: m.ReceivedAt, FirstMsg: m.Msg}
			byTask[m.TaskID] = r
		}
		r.LastAt = m.ReceivedAt
		r.Count++
		r.Kinds = append(r.Kinds, m.Kind)
		r.Parties = append(r.Parties, m.FromID+"@"+m.FromBox, m.ToID+"@"+m.ToBox)
	}
	var out []TopicRow
	for id, r := range byTask {
		if !match[id] || !seen[id] {
			continue
		}
		if (q.Roots && r.Parent != "") || (q.Parent != "" && r.Parent != q.Parent) {
			continue
		}
		if q.NoIssues && s.iss.isTask(tenant, id) {
			continue
		}
		if s.topicArchivedLocked(tenant, id, q.Lobby) {
			continue
		}
		if !q.BeforeAt.IsZero() && !newer(q.BeforeAt, q.BeforeTask, r.LastAt, r.TaskID) {
			continue
		}
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool { return newer(out[i].LastAt, out[i].TaskID, out[j].LastAt, out[j].TaskID) })
	if q.Limit > 0 && len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out, nil
}

func (s *Memory) ViewTopic(_ context.Context, tenant string, q TopicMsgQuery) ([]ViewMsg, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []ViewMsg
	ms := s.liveLocked(tenant, q.Now) // oldest first
	if q.Desc {
		for i, j := 0, len(ms)-1; i < j; i, j = i+1, j-1 {
			ms[i], ms[j] = ms[j], ms[i]
		}
	}
	for _, m := range ms {
		if m.TaskID != q.TaskID || (q.HideArchived && !m.ArchivedAt.IsZero()) {
			continue
		}
		if !q.AfterAt.IsZero() && !newer(m.ReceivedAt, m.MsgID, q.AfterAt, q.AfterID) {
			continue
		}
		if !q.BeforeAt.IsZero() && !newer(q.BeforeAt, q.BeforeID, m.ReceivedAt, m.MsgID) {
			continue
		}
		if q.Reader != "" && !readableBy(m.Channel, m.FromID, m.ToID, q.Reader, q.ReaderChannels) {
			continue
		}
		v := ViewMsg{MsgID: m.MsgID, ReceivedAt: m.ReceivedAt, Env: m.Env, Deliveries: []ViewDelivery{},
			EditedAt: m.EditedAt, EditedBy: m.EditedBy, IsParent: parentBit(m.IsParent), TypedBy: m.TypedBy}
		if !m.KindSetAt.IsZero() {
			v.Kind, v.KindSetAt, v.KindSetBy = m.Kind, m.KindSetAt, m.KindSetBy
		}
		if revs := s.revisions[[2]string{tenant, m.MsgID}]; len(revs) > 0 {
			v.Revision = revs[len(revs)-1].Revision
		}
		for k, d := range s.deliveries {
			if k[0] == tenant && k[1] == m.MsgID {
				v.Deliveries = append(v.Deliveries, ViewDelivery{ToBox: k[2], State: d.state})
			}
		}
		sort.Slice(v.Deliveries, func(i, j int) bool { return v.Deliveries[i].ToBox < v.Deliveries[j].ToBox })
		out = append(out, v)
		if q.Limit > 0 && len(out) == q.Limit {
			break
		}
	}
	return out, nil
}

func (s *Memory) ViewChannels(_ context.Context, tenant string, now time.Time) ([]ChannelRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	byCh := map[string]*ChannelRow{}
	for _, m := range s.liveLocked(tenant, now) {
		if m.Channel == "" {
			continue
		}
		r := byCh[m.Channel]
		if r == nil {
			r = &ChannelRow{Channel: m.Channel}
			byCh[m.Channel] = r
		}
		r.Count++
		r.LastAt = m.ReceivedAt
	}
	out := []ChannelRow{}
	for _, r := range byCh {
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Channel < out[j].Channel })
	return out, nil
}

// readableBy is the rdb 0028 read door on one message: a public channel, a
// channel the reader is in, or a DM the reader is an end of.
func readableBy(channel, from, to, reader string, chans []string) bool {
	if channel == "" {
		return from == reader || to == reader
	}
	if ChannelPublic(channel) {
		return true
	}
	for _, c := range chans {
		if c == channel {
			return true
		}
	}
	return false
}
