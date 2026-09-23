package store

import (
	"context"
	"sort"
	"time"
)

// memChannels is Memory's copy of channels / channel_subscriptions; zero value
// is empty. Guarded by Memory.mu.
type memChannels struct {
	rows map[[2]string]Channel             // (tenant, channel)
	subs map[[2]string]map[string][]string // (tenant, box) → channel → agents
	// humans is the 0028 half: (tenant, channel) → human → added_by.
	humans map[[2]string]map[string]string
}

func (c *memChannels) init() {
	if c.rows == nil {
		c.rows = map[[2]string]Channel{}
		c.subs = map[[2]string]map[string][]string{}
	}
}

// seedLocked adds the default channel rows of tenant (CreateTenant).
func (c *memChannels) seedLocked(tenant string, now time.Time) {
	c.init()
	for _, d := range DefaultChannels {
		k := [2]string{tenant, d}
		if _, ok := c.rows[k]; !ok {
			c.rows[k] = Channel{TenantID: tenant, ChannelID: d, Name: d, CreatedBy: "hub", CreatedAt: now}
		}
	}
}

func (s *Memory) CreateChannel(_ context.Context, c Channel) error {
	if c.ChannelID == ChannelGeneralAlias || !ValidChannelID(c.ChannelID) {
		return ErrConflict
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[c.TenantID]; !ok {
		return ErrNotFound
	}
	s.ch.init()
	k := [2]string{c.TenantID, c.ChannelID}
	if _, ok := s.ch.rows[k]; ok || IsDefaultChannel(c.ChannelID) {
		return ErrConflict
	}
	s.ch.rows[k] = c
	return nil
}

func (s *Memory) Channel(_ context.Context, tenant, id string) (Channel, error) {
	id = NormalizeChannel(id)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	if c, ok := s.ch.rows[[2]string{tenant, id}]; ok {
		return c, nil
	}
	if IsDefaultChannel(id) {
		return Channel{TenantID: tenant, ChannelID: id, Name: id, CreatedBy: "hub"}, nil
	}
	return Channel{}, ErrNotFound
}

func (s *Memory) SetMembersOpenInvite(_ context.Context, tenant, id string, open bool) error {
	id = NormalizeChannel(id)
	if ChannelPublic(id) {
		return ErrConflict
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	k := [2]string{tenant, id}
	c, ok := s.ch.rows[k]
	if !ok {
		return ErrNotFound
	}
	c.MembersOpenInvite = open
	s.ch.rows[k] = c
	return nil
}

func (s *Memory) ChannelKnown(_ context.Context, tenant, id string) (bool, error) {
	if IsDefaultChannel(id) {
		return true, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	_, ok := s.ch.rows[[2]string{tenant, id}]
	return ok, nil
}

func (s *Memory) SetSubscriptions(_ context.Context, tenant, box string, agents, channels []string, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	m := map[string][]string{}
	for _, c := range channels {
		if c == ChannelLobby {
			continue
		}
		if _, ok := s.ch.rows[[2]string{tenant, c}]; !ok && !IsDefaultChannel(c) {
			continue
		}
		a := append([]string(nil), agents...)
		sort.Strings(a)
		m[c] = a
	}
	s.ch.subs[[2]string{tenant, box}] = m
	return nil
}

func (s *Memory) ChannelMembers(_ context.Context, tenant, channel string) (map[string][]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	out := map[string][]string{}
	if channel == ChannelLobby {
		for k, a := range s.roster {
			if k[0] == tenant && len(a) > 0 {
				out[k[1]] = append([]string(nil), a...)
			}
		}
		return out, nil
	}
	for k, m := range s.ch.subs {
		if k[0] == tenant && len(m[channel]) > 0 {
			out[k[1]] = append([]string(nil), m[channel]...)
		}
	}
	return out, nil
}

func (s *Memory) ViewChannelStats(_ context.Context, tenant string, now time.Time, reads map[string]ReadMark) ([]ChannelStat, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	by := map[string]*ChannelStat{}
	get := func(id string) *ChannelStat {
		st := by[id]
		if st == nil {
			st = &ChannelStat{Channel: Channel{TenantID: tenant, ChannelID: id, Name: id}, Default: IsDefaultChannel(id)}
			if st.Default {
				st.CreatedBy = "hub"
			}
			by[id] = st
		}
		return st
	}
	for _, d := range DefaultChannels {
		get(d)
	}
	for k, c := range s.ch.rows {
		if k[0] == tenant {
			st := get(k[1])
			st.Name, st.Description, st.CreatedBy, st.CreatedAt, st.MembersOpenInvite = c.Name, c.Description, c.CreatedBy, c.CreatedAt, c.MembersOpenInvite
		}
	}
	posters := map[string]map[string]bool{}
	for _, m := range s.liveLocked(tenant, now) { // oldest first
		if m.Channel == "" {
			continue
		}
		st := get(m.Channel)
		st.Count++
		st.LastAt, st.LastMsgID = m.ReceivedAt, m.MsgID
		if r, ok := reads[m.Channel]; !ok || newer(m.ReceivedAt, m.MsgID, r.At, r.MsgID) {
			st.Unread++
		}
		if posters[m.Channel] == nil {
			posters[m.Channel] = map[string]bool{}
		}
		posters[m.Channel][m.FromID] = true
	}
	for id, st := range by {
		st.Posters = len(posters[id])
		boxes := map[string]bool{}
		if id == ChannelLobby {
			for k, a := range s.roster {
				if k[0] == tenant && len(a) > 0 {
					st.Agents += len(a)
					boxes[k[1]] = true
				}
			}
		} else {
			for k, m := range s.ch.subs {
				if k[0] == tenant && len(m[id]) > 0 {
					st.Agents += len(m[id])
					boxes[k[1]] = true
				}
			}
		}
		st.Boxes = len(boxes)
	}
	out := make([]ChannelStat, 0, len(by))
	for _, st := range by {
		out = append(out, *st)
	}
	SortChannelStats(out) // CLE-3425: newest activity first
	return out, nil
}
