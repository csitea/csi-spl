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
	// invited is (tenant, channel, box, agent) added from Properties.
	// SetSubscriptions replaces subs and does not touch this.
	invited map[[4]string]struct{}
	// removed is the same key for an agent a member took out. Announce
	// must not put that agent back into that channel.
	removed map[[4]string]struct{}
	// archived holds the rows ArchiveChannel took out of rows (rdb 0092).
	// humans, subs and invited keep their entries for UnarchiveChannel; every
	// live read skips them through archivedCh().
	archived map[[2]string]Channel
	// backfilled is the rdb 0066 stamp per invited seat (backfill_memory.go).
	// It survives a remove and a re-invite, as the column does.
	backfilled map[[4]string]time.Time
}

// archivedCh reports an archived channel of tenant. Caller holds Memory.mu.
func (c *memChannels) archivedCh(tenant, channel string) bool {
	_, ok := c.archived[[2]string{tenant, channel}]
	return ok
}

func (c *memChannels) init() {
	if c.rows == nil {
		c.rows = map[[2]string]Channel{}
		c.subs = map[[2]string]map[string][]string{}
		c.invited = map[[4]string]struct{}{}
		c.removed = map[[4]string]struct{}{}
	}
	if c.invited == nil {
		c.invited = map[[4]string]struct{}{}
	}
	if c.removed == nil {
		c.removed = map[[4]string]struct{}{}
	}
	if c.archived == nil {
		c.archived = map[[2]string]Channel{}
	}
	if c.backfilled == nil {
		c.backfilled = map[[4]string]time.Time{}
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
	if !ValidChannelID(c.ChannelID) || ChannelReserved(c.ChannelID) {
		return ErrConflict
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[c.TenantID]; !ok {
		return ErrNotFound
	}
	s.ch.init()
	k := [2]string{c.TenantID, c.ChannelID}
	if _, ok := s.ch.rows[k]; ok || s.ch.archivedCh(c.TenantID, c.ChannelID) || IsDefaultChannel(c.ChannelID) {
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
	if IsDefaultChannel(id) || id == ChannelIssues { // the issue discussions have no row
		return true, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	_, ok := s.ch.rows[[2]string{tenant, id}]
	return ok, nil
}

// DeleteChannel HARD-deletes a channel (live or archived): its row, its
// membership rows and its messages are all removed, so the slug is free.
func (s *Memory) DeleteChannel(_ context.Context, tenant, id, by string, now time.Time) error {
	id = NormalizeChannel(id)
	if IsDefaultChannel(id) {
		return ErrConflict
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	k := [2]string{tenant, id}
	c, archived := s.ch.rows[k], false
	if _, ok := s.ch.rows[k]; !ok {
		if c, archived = s.ch.archived[k]; !archived {
			return ErrNotFound
		}
	}
	if len(c.CreatedBy) < 4 || c.CreatedBy[:4] != "HUM-" { // the 0092 CHECK
		return ErrConflict
	}
	delete(s.ch.rows, k)
	delete(s.ch.archived, k)
	delete(s.ch.humans, k)
	for key := range s.ch.invited { // channel_subscriptions / backfill rows
		if key[0] == tenant && key[1] == id {
			delete(s.ch.invited, key)
			delete(s.ch.removed, key)
			delete(s.ch.backfilled, key)
		}
	}
	for key := range s.ch.removed {
		if key[0] == tenant && key[1] == id {
			delete(s.ch.removed, key)
		}
	}
	for sk, bag := range s.ch.subs {
		if sk[0] == tenant {
			delete(bag, id)
		}
	}
	for mk, m := range s.messages { // its messages and the rows that reference them
		if mk[0] == tenant && m.Channel == id {
			delete(s.messages, mk)
			delete(s.revisions, mk)
			delete(s.kindChanges, mk)
			delete(s.reactions, mk)
			for dk := range s.deliveries {
				if dk[0] == tenant && dk[1] == mk[1] {
					delete(s.deliveries, dk)
				}
			}
		}
	}
	return nil
}

// firstOfTaskLocked reports whether m is its task's opening card (no earlier
// is_parent=1 row of the same task). Caller holds Memory.mu.
func (s *Memory) firstOfTaskLocked(tenant string, m *Message) bool {
	for k, o := range s.messages {
		if k[0] == tenant && o.TaskID == m.TaskID && parentBit(o.IsParent) == 1 &&
			newer(m.ReceivedAt, m.MsgID, o.ReceivedAt, o.MsgID) {
			return false
		}
	}
	return true
}

// ArchiveChannel hides a channel, reserves its slug and stamps its topic
// cards (rdb 0092). The cards it stamps carry the channel's archived_at, so
// UnarchiveChannel can tell them from cards archived on their own before.
func (s *Memory) ArchiveChannel(_ context.Context, tenant, id, by string, now time.Time) error {
	id = NormalizeChannel(id)
	if IsDefaultChannel(id) {
		return ErrConflict
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	k := [2]string{tenant, id}
	c, ok := s.ch.rows[k]
	if !ok { // absent or already archived
		return ErrNotFound
	}
	if len(c.CreatedBy) < 4 || c.CreatedBy[:4] != "HUM-" { // the 0092 CHECK
		return ErrConflict
	}
	c.ArchivedAt, c.ArchivedBy = now, by
	delete(s.ch.rows, k)
	s.ch.archived[k] = c
	for _, m := range s.messages {
		if m.TenantID == tenant && m.Channel == id && parentBit(m.IsParent) == 1 &&
			m.ArchivedAt.IsZero() && s.firstOfTaskLocked(tenant, m) {
			m.ArchivedAt, m.ArchivedBy = now, by
		}
	}
	return nil
}

// UnarchiveChannel restores the channel and only the cards this archive
// stamped (same archived_at). Cards archived individually before keep theirs.
func (s *Memory) UnarchiveChannel(_ context.Context, tenant, id string) error {
	id = NormalizeChannel(id)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	k := [2]string{tenant, id}
	c, ok := s.ch.archived[k]
	if !ok {
		return ErrNotFound
	}
	at := c.ArchivedAt
	c.ArchivedAt, c.ArchivedBy = time.Time{}, ""
	delete(s.ch.archived, k)
	s.ch.rows[k] = c
	for _, m := range s.messages {
		if m.TenantID == tenant && m.Channel == id && !m.ArchivedAt.IsZero() && m.ArchivedAt.Equal(at) {
			m.ArchivedAt, m.ArchivedBy = time.Time{}, ""
		}
	}
	return nil
}

func (s *Memory) ArchivedChannel(_ context.Context, tenant, id string) (Channel, bool, error) {
	id = NormalizeChannel(id)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	c, ok := s.ch.archived[[2]string{tenant, id}]
	if !ok {
		return Channel{}, false, nil
	}
	return c, true, nil
}

// SetSubscriptions records one box announce.
//
// an announce seats nobody (see the Postgres store); it only
// clears what an older announce seated.
func (s *Memory) SetSubscriptions(_ context.Context, tenant, box string, _, _ []string, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	delete(s.ch.subs, [2]string{tenant, box})
	return nil
}

// InviteChannelAgent keeps the agent in the channel across later announces.
func (s *Memory) InviteChannelAgent(_ context.Context, tenant, channel, box, agent string, _ time.Time) error {
	if !ValidChannelID(channel) {
		return ErrConflict
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	if _, ok := s.ch.rows[[2]string{tenant, channel}]; !ok && !IsDefaultChannel(channel) {
		return ErrNotFound
	}
	key := [4]string{tenant, channel, box, agent}
	delete(s.ch.removed, key)
	s.ch.invited[key] = struct{}{}
	return nil
}

// RemoveChannelAgent records that this agent must stay out, including
// across a later announce of the same channel.
func (s *Memory) RemoveChannelAgent(_ context.Context, tenant, channel, box, agent string, _ time.Time) error {
	if !ValidChannelID(channel) {
		return ErrConflict
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	if _, ok := s.ch.rows[[2]string{tenant, channel}]; !ok && !IsDefaultChannel(channel) {
		return ErrNotFound
	}
	key := [4]string{tenant, channel, box, agent}
	delete(s.ch.invited, key)
	if bag := s.ch.subs[[2]string{tenant, box}]; bag != nil {
		src := append([]string(nil), bag[channel]...)
		kept := make([]string, 0, len(src))
		for _, id := range src {
			if id != agent {
				kept = append(kept, id)
			}
		}
		bag[channel] = kept
	}
	s.ch.removed[key] = struct{}{}
	return nil
}

func (s *Memory) ChannelMembers(_ context.Context, tenant, channel string) (map[string][]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	out := map[string][]string{}
	if s.ch.archivedCh(tenant, channel) {
		return out, nil
	}
	for k, m := range s.ch.subs {
		if k[0] != tenant {
			continue
		}
		for _, id := range m[channel] {
			if _, gone := s.ch.removed[[4]string{tenant, channel, k[1], id}]; gone {
				continue
			}
			out[k[1]] = append(out[k[1]], id)
		}
	}
	for key := range s.ch.invited {
		if key[0] != tenant || key[1] != channel {
			continue
		}
		box, agent := key[2], key[3]
		if _, out := s.ch.removed[[4]string{tenant, channel, box, agent}]; out {
			continue
		}
		have := false
		for _, id := range out[box] {
			if id == agent {
				have = true
				break
			}
		}
		if !have {
			out[box] = append(out[box], agent)
		}
	}
	for box, ids := range out {
		sort.Strings(ids)
		out[box] = ids
	}
	return out, nil
}

func (s *Memory) ViewChannelStats(_ context.Context, tenant string, now time.Time, reads map[string]ReadMark, reader, lobby string) ([]ChannelStat, error) {
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
		if r, ok := reads[m.Channel]; (!ok || newer(m.ReceivedAt, m.MsgID, r.At, r.MsgID)) && !OwnLine(m.FromID, m.TypedBy, reader, ok) && !s.archivedHiddenLocked(tenant, m, lobby) && !(ok && s.threadReadLocked(tenant, reader, m)) {
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
		for k, m := range s.ch.subs {
			if k[0] == tenant && len(m[id]) > 0 {
				st.Agents += len(m[id])
				boxes[k[1]] = true
			}
		}
		for k := range s.ch.invited {
			if k[0] != tenant || k[1] != id {
				continue
			}
			if _, gone := s.ch.removed[k]; gone {
				continue
			}
			announced := false
			for _, a := range s.ch.subs[[2]string{tenant, k[2]}][id] {
				announced = announced || a == k[3]
			}
			if !announced {
				st.Agents++
				boxes[k[2]] = true
			}
		}
		st.Boxes = len(boxes)
	}
	out := make([]ChannelStat, 0, len(by))
	for id, st := range by {
		if !ChannelHidden(id) && !s.ch.archivedCh(tenant, id) { // issue discussions are not a channel; rdb 0052
			out = append(out, *st)
		}
	}
	SortChannelStats(out) // newest activity first
	return out, nil
}
