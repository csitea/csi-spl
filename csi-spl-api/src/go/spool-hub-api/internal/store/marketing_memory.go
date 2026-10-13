package store

import (
	"context"
	"crypto/rand"
	"fmt"
	"sort"
	"time"
)

// memMarketing is the Memory store's Marketing (rdb 0187), for hub tests and
// a hub without Postgres. Same rules as the Postgres one, under s.mu.
type memMarketing struct {
	channels map[string]*MarketingChannel // channel id -> channel
	tokens   map[string]MarketingToken    // channel id -> sealed token
	posts    map[string]*memMktPost       // post id -> post
	events   []memMktEvent
}

type memMktPost struct {
	MarketingPost
	next    time.Time
	claimed time.Time
}

type memMktEvent struct {
	Tenant, Channel, Post, Type string
}

func memUUID() string {
	b := make([]byte, 16)
	rand.Read(b) //nolint:errcheck // crypto/rand.Read never fails since Go 1.24
	b[6], b[8] = (b[6]&0x0f)|0x40, (b[8]&0x3f)|0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// mkt returns the lazily made marketing state; s.mu must be held.
func (s *Memory) mkt() *memMarketing {
	if s.marketing == nil {
		s.marketing = &memMarketing{channels: map[string]*MarketingChannel{}, tokens: map[string]MarketingToken{},
			posts: map[string]*memMktPost{}}
	}
	return s.marketing
}

func (m *memMarketing) event(tenant, channel, post, typ string) {
	m.events = append(m.events, memMktEvent{Tenant: tenant, Channel: channel, Post: post, Type: typ})
}

// ConnectMarketingChannel implements Marketing on the Memory store (rdb 0187).
func (s *Memory) ConnectMarketingChannel(_ context.Context, ch MarketingChannel, tok MarketingToken, now time.Time) (MarketingChannel, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[ch.Tenant]; !ok {
		return MarketingChannel{}, ErrNotFound
	}
	m := s.mkt()
	var cur *MarketingChannel
	for _, c := range m.channels {
		if c.Tenant == ch.Tenant && c.Platform == ch.Platform && c.AccountRef == ch.AccountRef {
			cur = c
		}
	}
	if cur == nil {
		cur = &MarketingChannel{ID: memUUID(), Tenant: ch.Tenant, Platform: ch.Platform, AccountRef: ch.AccountRef, CreatedAt: now}
		m.channels[cur.ID] = cur
	}
	cur.AccountName, cur.DelegatedBy, cur.AutoPublish = ch.AccountName, ch.DelegatedBy, ch.AutoPublish
	cur.Status, cur.ExpiresAt, cur.RemindedAt = MarketingActive, ch.ExpiresAt, nil
	m.tokens[cur.ID] = tok
	m.event(ch.Tenant, cur.ID, "", "channel_connect")
	return *cur, nil
}

// MarketingChannels implements Marketing on the Memory store (rdb 0187).
func (s *Memory) MarketingChannels(_ context.Context, tenant string) ([]MarketingChannel, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []MarketingChannel{}
	for _, c := range s.mkt().channels {
		if c.Tenant == tenant {
			out = append(out, *c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out, nil
}

// AutoMarketingChannels implements Marketing on the Memory store (rdb 0187).
func (s *Memory) AutoMarketingChannels(_ context.Context) ([]MarketingChannel, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []MarketingChannel{}
	for _, c := range s.mkt().channels {
		if c.Status == MarketingActive && c.AutoPublish {
			out = append(out, *c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// MarketingToken implements Marketing on the Memory store (rdb 0187).
func (s *Memory) MarketingToken(_ context.Context, tenant, channelID string) (MarketingToken, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	c, ok := m.channels[channelID]
	t, has := m.tokens[channelID]
	if !ok || !has || c.Tenant != tenant {
		return MarketingToken{}, ErrNotFound
	}
	return t, nil
}

// ExpireMarketingChannel implements Marketing on the Memory store (rdb 0187).
func (s *Memory) ExpireMarketingChannel(_ context.Context, tenant, channelID string, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	if c, ok := m.channels[channelID]; ok && c.Tenant == tenant && c.Status == MarketingActive {
		c.Status = MarketingExpired
		m.event(tenant, channelID, "", "channel_expired")
	}
	return nil
}

// MarkMarketingReminded implements Marketing on the Memory store (rdb 0187).
func (s *Memory) MarkMarketingReminded(_ context.Context, tenant, channelID string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	c, ok := m.channels[channelID]
	if !ok || c.Tenant != tenant || c.RemindedAt != nil {
		return false, nil
	}
	c.RemindedAt = &now
	m.event(tenant, channelID, "", "channel_reminder")
	return true, nil
}

// BaselineMarketingPosts implements Marketing on the Memory store (rdb 0187).
func (s *Memory) BaselineMarketingPosts(_ context.Context, tenant, channelID string, refs []string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	c, ok := m.channels[channelID]
	if !ok || c.Tenant != tenant {
		return nil
	}
	have := m.refsLocked(channelID)
	for _, ref := range refs {
		if !have[ref] {
			p := &memMktPost{MarketingPost: MarketingPost{ID: memUUID(), Tenant: tenant, ChannelID: channelID,
				SourceType: MarketingSourceBlog, SourceRef: ref, Status: MarketingSkipped}}
			m.posts[p.ID] = p
		}
	}
	if c.BaselineAt == nil {
		c.BaselineAt = &now
		m.event(tenant, channelID, "", "post_baseline")
	}
	return nil
}

func (m *memMarketing) refsLocked(channelID string) map[string]bool {
	out := map[string]bool{}
	for _, p := range m.posts {
		if p.ChannelID == channelID {
			out[p.SourceRef] = true
		}
	}
	return out
}

// MarketingPostRefs implements Marketing on the Memory store (rdb 0187).
func (s *Memory) MarketingPostRefs(_ context.Context, _, channelID string) (map[string]bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.mkt().refsLocked(channelID), nil
}

// ScheduleMarketingPost implements Marketing on the Memory store (rdb 0187).
func (s *Memory) ScheduleMarketingPost(_ context.Context, p MarketingPost, _ time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	for _, q := range m.posts {
		if q.ChannelID == p.ChannelID && q.SourceType == p.SourceType && q.SourceRef == p.SourceRef {
			return false, nil
		}
	}
	p.ID, p.Status, p.Attempts = memUUID(), MarketingScheduled, 0
	m.posts[p.ID] = &memMktPost{MarketingPost: p}
	m.event(p.Tenant, p.ChannelID, p.ID, "post_scheduled")
	return true, nil
}

// ClaimMarketingPosts implements Marketing on the Memory store (rdb 0187).
func (s *Memory) ClaimMarketingPosts(_ context.Context, tenant, channelID string, now time.Time) ([]MarketingPost, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	var out []MarketingPost
	for _, p := range m.posts {
		if p.Tenant != tenant || p.ChannelID != channelID || p.Status != MarketingScheduled || p.next.After(now) {
			continue
		}
		p.Status, p.Attempts, p.claimed = MarketingDispatching, p.Attempts+1, now
		out = append(out, p.MarketingPost)
		m.event(tenant, channelID, p.ID, "post_dispatched")
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SourceRef < out[j].SourceRef })
	return out, nil
}

// FinishMarketingPost implements Marketing on the Memory store (rdb 0187).
func (s *Memory) FinishMarketingPost(_ context.Context, tenant, postID string, out MarketingOutcome, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	p, ok := m.posts[postID]
	if !ok || p.Tenant != tenant || p.Status != MarketingDispatching {
		return ErrNotFound
	}
	status, event, next := outcomeRow(out)
	p.Status, p.PlatformPostID, p.LastError = status, out.PlatformPostID, out.Error
	p.next = time.Time{}
	if next != nil {
		p.next = *next
	}
	m.event(tenant, p.ChannelID, postID, event)
	return nil
}

// StuckMarketingPosts implements Marketing on the Memory store (rdb 0187).
func (s *Memory) StuckMarketingPosts(_ context.Context, before, _ time.Time) ([]MarketingPost, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	var out []MarketingPost
	for _, p := range m.posts {
		if p.Status == MarketingDispatching && p.claimed.Before(before) {
			p.Status, p.LastError = MarketingFailed, "the hub stopped during the LinkedIn call; the outcome is unknown, so it is not retried"
			out = append(out, p.MarketingPost)
			m.event(p.Tenant, p.ChannelID, p.ID, "post_failed")
		}
	}
	return out, nil
}

// MarketingPostsOf lists a channel's posts (tests and diagnostics).
func (s *Memory) MarketingPostsOf(channelID string) []MarketingPost {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []MarketingPost
	for _, p := range s.mkt().posts {
		if p.ChannelID == channelID {
			out = append(out, p.MarketingPost)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SourceRef < out[j].SourceRef })
	return out
}
