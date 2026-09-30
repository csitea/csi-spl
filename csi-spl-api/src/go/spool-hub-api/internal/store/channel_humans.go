package store

import (
	"context"
	"sort"
	"time"
)

// Human channel membership (rdb 0028) — which HUMANS may read a channel.
//
// channel_subscriptions (0002) is the other half and answers a different
// question: which agent, on which box, a post must be DELIVERED to. Neither
// is a substitute for the other, and before 0028 only the delivery half
// existed, which is why every signed-in member of a tenant could read every
// channel in it.

// ChannelPublic reports whether channelID is readable by every member of the
// tenant without a membership row. The default channels are (owner's
// call, 2026-09-23: lobby is the channel every tester needs), and so are the
// issue discussions (ChannelIssues and the retired ChannelTasks: who may
// read an issue may read its thread); every created channel is members-only. Public is about PEOPLE
// only: the agents of a default channel are the ones a member invited (owner
// decision 2026-09-25).
func ChannelPublic(channelID string) bool {
	id := NormalizeChannel(channelID)
	return ChannelHidden(id) || IsDefaultChannel(id)
}

// TopicAccess is what a read door needs to know about one topic without
// reading its messages: the channel it belongs to, and the ids at both ends
// of every message in it.
// One topic can hold BOTH: the WUI posts a reply from whichever channel page
// it is on, so a DM topic picks up a channel-tagged message the moment
// somebody answers it from a channel view. dev t1 topic
// 57e6f191-582e-45b1-a08e-389c0b034803 is exactly that shape. So a single
// Channel field cannot describe a topic, and "is a party of the topic"
// cannot be the DM rule: appending one message would otherwise buy the whole
// private history before it.
type TopicAccess struct {
	Found bool
	// Channels are the distinct channel tags in the topic. "" is present
	// when the topic holds at least one DM (untagged) message.
	Channels []string
	// DMParties are the ends of the UNTAGGED messages only - never of the
	// channel-tagged ones.
	DMParties []string
}

// HasDM reports whether the topic holds an untagged (DM) message.
func (a TopicAccess) HasDM() bool {
	for _, c := range a.Channels {
		if c == "" {
			return true
		}
	}
	return false
}

// Party reports whether id is an end of some DM message in the topic.
func (a TopicAccess) Party(id string) bool {
	if id == "" {
		return false
	}
	for _, p := range a.DMParties {
		if p == id {
			return true
		}
	}
	return false
}

// ChannelHumans is the store side of 0028. Memory and Postgres implement it.
type ChannelHumans interface {
	// ChannelHumanMembers returns the sorted human ids in channelID. A
	// default channel is public and carries no rows, so it returns none —
	// callers must ask ChannelPublic first, never treat empty as "nobody
	// may read it".
	ChannelHumanMembers(ctx context.Context, tenantID, channelID string) ([]string, error)
	// HumanChannels returns the sorted CREATED channels humanID belongs to.
	// Default channels are not included: they need no membership.
	HumanChannels(ctx context.Context, tenantID, humanID string) ([]string, error)
	// AddChannelHumans adds members; already-a-member is not an error.
	AddChannelHumans(ctx context.Context, tenantID, channelID string, humans []string, by string, now time.Time) error
	// RemoveChannelHuman drops one membership. ErrNotFound: not a member.
	RemoveChannelHuman(ctx context.Context, tenantID, channelID, humanID string) error
	// TopicAccess describes one topic for the read door. Found=false when
	// the tenant has no message with that task_id in retention.
	TopicAccess(ctx context.Context, tenantID, taskID string, now time.Time) (TopicAccess, error)
}

var (
	_ ChannelHumans = (*Memory)(nil)
	_ ChannelHumans = (*Postgres)(nil)
)

// ---- Memory ---------------------------------------------------------------

func (c *memChannels) humansLocked() map[[2]string]map[string]string {
	if c.humans == nil {
		c.humans = map[[2]string]map[string]string{}
	}
	return c.humans
}

func (s *Memory) ChannelHumanMembers(_ context.Context, tenant, channel string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	var out []string
	if s.ch.archivedCh(tenant, NormalizeChannel(channel)) {
		return nil, nil
	}
	for h := range s.ch.humansLocked()[[2]string{tenant, NormalizeChannel(channel)}] {
		out = append(out, h)
	}
	sort.Strings(out)
	return out, nil
}

func (s *Memory) HumanChannels(_ context.Context, tenant, human string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	var out []string
	for k, hs := range s.ch.humansLocked() {
		if k[0] == tenant && hs[human] != "" && !s.ch.archivedCh(tenant, k[1]) {
			out = append(out, k[1])
		}
	}
	sort.Strings(out)
	return out, nil
}

func (s *Memory) AddChannelHumans(_ context.Context, tenant, channel string, humans []string, by string, _ time.Time) error {
	channel = NormalizeChannel(channel)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	if _, ok := s.ch.rows[[2]string{tenant, channel}]; !ok && !IsDefaultChannel(channel) {
		return ErrNotFound
	}
	k := [2]string{tenant, channel}
	m := s.ch.humansLocked()[k]
	if m == nil {
		m = map[string]string{}
		s.ch.humansLocked()[k] = m
	}
	if by == "" {
		by = "hub"
	}
	for _, h := range humans {
		if h != "" {
			m[h] = by
		}
	}
	return nil
}

func (s *Memory) RemoveChannelHuman(_ context.Context, tenant, channel, human string) error {
	channel = NormalizeChannel(channel)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	m := s.ch.humansLocked()[[2]string{tenant, channel}]
	if m == nil || m[human] == "" {
		return ErrNotFound
	}
	delete(m, human)
	return nil
}

func (s *Memory) TopicAccess(_ context.Context, tenant, task string, now time.Time) (TopicAccess, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var a TopicAccess
	chans, ends := map[string]bool{}, map[string]bool{}
	for _, m := range s.liveLocked(tenant, now) {
		if m.TaskID != task {
			continue
		}
		a.Found = true
		chans[m.Channel] = true
		if m.Channel != "" {
			continue
		}
		for _, p := range []string{m.FromID, m.ToID} {
			if p != "" && !ends[p] {
				ends[p] = true
				a.DMParties = append(a.DMParties, p)
			}
		}
	}
	for c := range chans {
		a.Channels = append(a.Channels, c)
	}
	sort.Strings(a.Channels)
	sort.Strings(a.DMParties)
	return a, nil
}
