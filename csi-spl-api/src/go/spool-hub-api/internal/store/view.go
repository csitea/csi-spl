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

// ThreadQuery pages GET /v1/view/threads: newest activity first, strictly
// before (BeforeAt, BeforeTask) when BeforeAt is set.
type ThreadQuery struct {
	Channel    string // "" = any
	Agent      string // "" = any; else from_id or to_id of some message
	BeforeAt   time.Time
	BeforeTask string
	Limit      int
	Now        time.Time
}

// ThreadRow is one task_id's aggregate. Times are hub receive times.
type ThreadRow struct {
	TaskID   string
	Channel  string // of the first message; "" = none
	FirstAt  time.Time
	LastAt   time.Time
	Count    int
	Kinds    []string // one per message, oldest first
	Parties  []string // "<agent>@<box>" for every from and to, unsorted, may repeat
	FirstMsg []byte   // inner v:1 JSON of the first message
}

// ThreadMsgQuery pages GET /v1/view/threads/{task_id}: oldest first, strictly
// after (AfterAt, AfterID) when AfterAt is set.
type ThreadMsgQuery struct {
	TaskID  string
	AfterAt time.Time
	AfterID string
	Limit   int
	Now     time.Time
}

// ViewMsg is one stored envelope with its hub-side delivery rows.
type ViewMsg struct {
	MsgID      string
	ReceivedAt time.Time
	Env        []byte
	Deliveries []ViewDelivery
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

func (s *Memory) ViewThreads(_ context.Context, tenant string, q ThreadQuery) ([]ThreadRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	byTask := map[string]*ThreadRow{}
	match := map[string]bool{}
	for _, m := range s.liveLocked(tenant, q.Now) { // oldest first
		if q.Channel != "" && m.Channel != q.Channel {
			continue
		}
		if q.Agent == "" || m.FromID == q.Agent || m.ToID == q.Agent {
			match[m.TaskID] = true
		}
		r := byTask[m.TaskID]
		if r == nil {
			r = &ThreadRow{TaskID: m.TaskID, Channel: m.Channel, FirstAt: m.ReceivedAt, FirstMsg: m.Msg}
			byTask[m.TaskID] = r
		}
		r.LastAt = m.ReceivedAt
		r.Count++
		r.Kinds = append(r.Kinds, m.Kind)
		r.Parties = append(r.Parties, m.FromID+"@"+m.FromBox, m.ToID+"@"+m.ToBox)
	}
	var out []ThreadRow
	for id, r := range byTask {
		if !match[id] {
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

func (s *Memory) ViewThread(_ context.Context, tenant string, q ThreadMsgQuery) ([]ViewMsg, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []ViewMsg
	for _, m := range s.liveLocked(tenant, q.Now) {
		if m.TaskID != q.TaskID {
			continue
		}
		if !q.AfterAt.IsZero() && !newer(m.ReceivedAt, m.MsgID, q.AfterAt, q.AfterID) {
			continue
		}
		v := ViewMsg{MsgID: m.MsgID, ReceivedAt: m.ReceivedAt, Env: m.Env, Deliveries: []ViewDelivery{}}
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
