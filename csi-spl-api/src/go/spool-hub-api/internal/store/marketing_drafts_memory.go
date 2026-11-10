package store

import (
	"context"
	"sort"
	"time"
)

// The Memory store's MarketingDrafts (rdb 0273), for hub tests and a hub
// without Postgres. Same rules as the Postgres one, under s.mu.

// CreateMarketingDraft implements MarketingDrafts on the Memory store (rdb 0273).
func (s *Memory) CreateMarketingDraft(_ context.Context, d MarketingDraft, now time.Time) (MarketingDraft, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[d.Tenant]; !ok {
		return MarketingDraft{}, ErrNotFound
	}
	d.ID, d.PublishedAt, d.CreatedAt, d.UpdatedAt = memUUID(), nil, now, now
	s.mkt().drafts[d.ID] = &d
	return s.draftLocked(d), nil
}

// draftLocked is a copy of d with its publishes; s.mu must be held.
func (s *Memory) draftLocked(d MarketingDraft) MarketingDraft {
	d.Posts = []MarketingDraftPost{}
	var rows []*memMktPost
	for _, p := range s.mkt().posts {
		if p.Tenant == d.Tenant && p.SourceType == MarketingSourceDraft && p.SourceRef == d.ID {
			rows = append(rows, p)
		}
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].ChannelID < rows[j].ChannelID })
	for _, p := range rows {
		d.Posts = append(d.Posts, MarketingDraftPost{ChannelID: p.ChannelID, Status: p.Status,
			PlatformPostID: p.PlatformPostID, LastError: p.LastError})
	}
	return d
}

// MarketingDrafts implements MarketingDrafts on the Memory store (rdb 0273).
func (s *Memory) MarketingDrafts(_ context.Context, tenant string) ([]MarketingDraft, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []MarketingDraft{}
	for _, d := range s.mkt().drafts {
		if d.Tenant == tenant {
			out = append(out, s.draftLocked(*d))
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].UpdatedAt.Equal(out[j].UpdatedAt) {
			return out[i].UpdatedAt.After(out[j].UpdatedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

// MarketingDraft implements MarketingDrafts on the Memory store (rdb 0273).
func (s *Memory) MarketingDraft(_ context.Context, tenant, id string) (MarketingDraft, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.mkt().drafts[id]
	if !ok || d.Tenant != tenant {
		return MarketingDraft{}, ErrNotFound
	}
	return s.draftLocked(*d), nil
}

// unpublishedLocked is tenant's draft id while unpublished; s.mu must be held.
func (s *Memory) unpublishedLocked(tenant, id string) (*MarketingDraft, error) {
	d, ok := s.mkt().drafts[id]
	switch {
	case !ok || d.Tenant != tenant:
		return nil, ErrNotFound
	case d.PublishedAt != nil:
		return nil, ErrMarketingDraftPublished
	}
	return d, nil
}

// UpdateMarketingDraft implements MarketingDrafts on the Memory store (rdb 0273).
func (s *Memory) UpdateMarketingDraft(_ context.Context, d MarketingDraft, now time.Time) (MarketingDraft, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur, err := s.unpublishedLocked(d.Tenant, d.ID)
	if err != nil {
		return MarketingDraft{}, err
	}
	cur.Body, cur.ImageURL, cur.UpdatedAt = d.Body, d.ImageURL, now
	return s.draftLocked(*cur), nil
}

// DeleteMarketingDraft implements MarketingDrafts on the Memory store (rdb 0273).
func (s *Memory) DeleteMarketingDraft(_ context.Context, tenant, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.unpublishedLocked(tenant, id); err != nil {
		return err
	}
	delete(s.mkt().drafts, id)
	return nil
}

// MarkMarketingDraftPublished implements MarketingDrafts on the Memory store (rdb 0273).
func (s *Memory) MarkMarketingDraftPublished(_ context.Context, tenant, id string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.mkt().drafts[id]
	if !ok || d.Tenant != tenant {
		return ErrNotFound
	}
	if d.PublishedAt == nil {
		d.PublishedAt = &now
	}
	return nil
}
