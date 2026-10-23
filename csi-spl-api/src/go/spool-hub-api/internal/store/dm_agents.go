package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"
)

// Agents added to a direct message (spec 151 section 4.1, rdb 0214, row
// T001, SPL-3039). A DM has no entity of its own: it is its two ends, a
// sorted pair of id@box (DMPair). A person adds an agent to that pair; the
// agent then reads and writes in the pair's DM topics, and both ends read
// what it writes there (readableByDMAgent). Removing it keeps the row as
// 'removed', so what it wrote while it was in stays readable.

// DM agent row origins (rdb 0214's CHECK).
const (
	DMAgentInvite  = "invite"
	DMAgentRemoved = "removed"
)

// ErrBadDMPair / ErrBadDMAgent refuse a call before any write: an end with
// no id or box, two equal ends, an unsorted pair; or an agent with no id or
// box, or an agent that is one of the DM's two ends.
var (
	ErrBadDMPair  = errors.New("store: a DM pair needs two different id@box ends, sorted")
	ErrBadDMAgent = errors.New("store: a DM agent needs an id@box that is not one of the DM's ends")
)

// DMEnd is an id on a box: one end of a DM, or an agent added to it.
type DMEnd struct {
	ID  string
	Box string
}

// key is the end's id@box, the order a DMPair sorts by.
func (e DMEnd) key() string { return e.ID + "@" + e.Box }

func (e DMEnd) valid() bool {
	return strings.TrimSpace(e.ID) != "" && strings.TrimSpace(e.Box) != ""
}

// DMPair is a DM's two ends, A < B by id@box. Build it with NewDMPair.
type DMPair struct {
	A DMEnd
	B DMEnd
}

// NewDMPair sorts two ends into a pair; ErrBadDMPair when an end is empty or
// the two are the same.
func NewDMPair(x, y DMEnd) (DMPair, error) {
	if y.key() < x.key() {
		x, y = y, x
	}
	p := DMPair{A: x, B: y}
	return p, p.check()
}

func (p DMPair) check() error {
	if !p.A.valid() || !p.B.valid() || p.A.key() >= p.B.key() {
		return ErrBadDMPair
	}
	return nil
}

// has reports whether e is one of the pair's ends.
func (p DMPair) has(e DMEnd) bool { return e == p.A || e == p.B }

// hasID reports whether id is the id of one of the pair's ends (the read
// door knows the reader by id only, as readableBy does).
func (p DMPair) hasID(id string) bool { return id == p.A.ID || id == p.B.ID }

// DMAgent is one dm_agents row of a pair.
type DMAgent struct {
	Agent     DMEnd
	Origin    string // DMAgentInvite or DMAgentRemoved
	InvitedBy string // the HUM-* who last added it
	AddedAt   time.Time
	RemovedAt time.Time // zero while Origin is DMAgentInvite
}

// DMAgentStore is implemented by Memory and Postgres.
type DMAgentStore interface {
	// AddDMAgent adds agent to the pair's DM, by the person by, at now. An
	// agent already in it is left as it is; a removed one comes back with
	// a new AddedAt.
	AddDMAgent(ctx context.Context, tenant string, pair DMPair, agent DMEnd, by string, now time.Time) error
	// RemoveDMAgent marks the agent removed at now; removing a removed one
	// changes nothing. ErrNotFound: it was never added to this pair.
	RemoveDMAgent(ctx context.Context, tenant string, pair DMPair, agent DMEnd, now time.Time) error
	// DMAgents lists every agent ever added to the pair, removed ones
	// included (Origin says which), sorted by id@box.
	DMAgents(ctx context.Context, tenant string, pair DMPair) ([]DMAgent, error)
}

var (
	_ DMAgentStore = (*Memory)(nil)
	_ DMAgentStore = (*Postgres)(nil)
)

// checkDMAgentCall is the shared argument check of the three methods.
func checkDMAgentCall(tenant string, pair DMPair, agent *DMEnd) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if err := pair.check(); err != nil {
		return err
	}
	if agent != nil && (!agent.valid() || pair.has(*agent)) {
		return ErrBadDMAgent
	}
	return nil
}

func sortDMAgents(out []DMAgent) {
	sort.Slice(out, func(i, j int) bool { return out[i].Agent.key() < out[j].Agent.key() })
}

// wrote reports whether the row covers a message received at at: the
// agent was in the DM then.
func (a DMAgent) wrote(at time.Time) bool {
	return !at.Before(a.AddedAt) && (a.RemovedAt.IsZero() || at.Before(a.RemovedAt))
}

// --- Memory side -----------------------------------------------------------

// memDMAgentKey is one dm_agents row's primary key.
type memDMAgentKey struct {
	tenant string
	pair   DMPair
	agent  DMEnd
}

// AddDMAgent implements DMAgentStore.
func (s *Memory) AddDMAgent(_ context.Context, tenant string, pair DMPair, agent DMEnd, by string, now time.Time) error {
	if err := checkDMAgentCall(tenant, pair, &agent); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dmAgents == nil {
		s.dmAgents = map[memDMAgentKey]DMAgent{}
	}
	k := memDMAgentKey{tenant, pair, agent}
	if r, ok := s.dmAgents[k]; ok && r.Origin == DMAgentInvite {
		return nil
	}
	s.dmAgents[k] = DMAgent{Agent: agent, Origin: DMAgentInvite, InvitedBy: by, AddedAt: now.UTC()}
	return nil
}

// RemoveDMAgent implements DMAgentStore.
func (s *Memory) RemoveDMAgent(_ context.Context, tenant string, pair DMPair, agent DMEnd, now time.Time) error {
	if err := checkDMAgentCall(tenant, pair, &agent); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := memDMAgentKey{tenant, pair, agent}
	r, ok := s.dmAgents[k]
	if !ok {
		return ErrNotFound
	}
	if r.Origin == DMAgentInvite {
		r.Origin, r.RemovedAt = DMAgentRemoved, now.UTC()
		s.dmAgents[k] = r
	}
	return nil
}

// DMAgents implements DMAgentStore.
func (s *Memory) DMAgents(_ context.Context, tenant string, pair DMPair) ([]DMAgent, error) {
	if err := checkDMAgentCall(tenant, pair, nil); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []DMAgent{}
	for k, r := range s.dmAgents {
		if k.tenant == tenant && k.pair == pair {
			out = append(out, r)
		}
	}
	sortDMAgents(out)
	return out, nil
}

// readableByDMAgentLocked is the read door's DM agent case (spec 151 4.1),
// the memory twin of dmAgentDoorSQL: m is a DM message written by an agent
// added to a pair of which reader is an end, to the pair's other end or to
// reader, while the agent was in, in a topic that holds a message between
// the pair's two ends. s.mu is held.
func (s *Memory) readableByDMAgentLocked(tenant string, m *Message, reader string) bool {
	if m.Channel != "" || len(s.dmAgents) == 0 {
		return false
	}
	from, to := DMEnd{m.FromID, m.FromBox}, DMEnd{m.ToID, m.ToBox}
	for k, r := range s.dmAgents {
		if k.tenant != tenant || k.agent != from || !k.pair.hasID(reader) || !k.pair.has(to) || !r.wrote(m.ReceivedAt) {
			continue
		}
		if s.topicHasPairLocked(tenant, m.TaskID, k.pair) {
			return true
		}
	}
	return false
}

// topicHasPairLocked: the topic holds a DM message from one of the pair's
// ends to the other. s.mu is held.
func (s *Memory) topicHasPairLocked(tenant, task string, p DMPair) bool {
	for k, m := range s.messages {
		if k[0] != tenant || m.TaskID != task || m.Channel != "" {
			continue
		}
		from, to := DMEnd{m.FromID, m.FromBox}, DMEnd{m.ToID, m.ToBox}
		if (from == p.A && to == p.B) || (from == p.B && to == p.A) {
			return true
		}
	}
	return false
}
