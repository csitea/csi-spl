package store

import (
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// DM pointers (owner, prd t1 dc6d5e3f, HUM-10): "if I tag the agent in a
// channels topic, it means that this msg WILL appear also as a personal msg
// ... but of course it should be treated as a reply in the topic and not a
// new topic". The DM view of a person and an agent lists, besides their DMs,
// the channel lines between the two of them: the person's line that tags the
// agent (`to` = the agent) and the agent's line back (`to` = the person). One
// stored row, read where it is: no copy, no new topic, and the row keeps its
// channel and task_id, so the WUI draws it as a pointer into that topic.

// DMPointerMax caps one read: the newest lines of the pair.
const DMPointerMax = 20

// DMPointerQuery is one person's DM view of one agent.
type DMPointerQuery struct {
	Viewer   string // the person
	Agent    string // the agent (the DM peer)
	AgentBox string // "" = any box; else the agent's lines on that box only
	// Reader / ReaderChannels: the read door (rdb 0028), as TopicQuery's.
	Reader         string
	ReaderChannels []string
	Lobby          string // specs/041: archived cards and threads stay out
	Limit          int    // <= 0 or > DMPointerMax = DMPointerMax
	Now            time.Time
}

// DMPointerReader is the read a store may offer; without it the DM view has
// no pointers.
type DMPointerReader interface {
	ViewDMPointers(ctx context.Context, tenant string, q DMPointerQuery) ([]ViewMsg, error)
}

var (
	_ DMPointerReader = (*Memory)(nil)
	_ DMPointerReader = (*Postgres)(nil)
)

func dmPointerLimit(n int) int {
	if n <= 0 || n > DMPointerMax {
		return DMPointerMax
	}
	return n
}

// dmPointerPair: m is a channel line from the viewer to the agent or from
// the agent to the viewer. A tag from the browser is stored to box-wui or to
// the agent's box; the agent's line comes from its box.
func dmPointerPair(m *Message, q DMPointerQuery) bool {
	if m.Channel == "" || q.Viewer == "" || q.Agent == "" {
		return false
	}
	if m.FromID == q.Viewer && m.ToID == q.Agent {
		return q.AgentBox == "" || m.ToBox == q.AgentBox || m.ToBox == msg.PeersToBox
	}
	return m.FromID == q.Agent && m.ToID == q.Viewer && (q.AgentBox == "" || m.FromBox == q.AgentBox)
}

// ViewDMPointers answers newest first.
func (s *Memory) ViewDMPointers(_ context.Context, tenant string, q DMPointerQuery) ([]ViewMsg, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ms := s.liveLocked(tenant, q.Now)
	lim := dmPointerLimit(q.Limit)
	var out []ViewMsg
	for i := len(ms) - 1; i >= 0 && len(out) < lim; i-- {
		m := ms[i]
		if !dmPointerPair(m, q) || s.archivedHiddenLocked(tenant, m, q.Lobby) {
			continue
		}
		if q.Reader != "" && !readableBy(m.Channel, m.FromID, m.ToID, q.Reader, q.ReaderChannels) {
			continue
		}
		out = append(out, s.viewMsgLocked(tenant, m))
	}
	return out, nil
}
