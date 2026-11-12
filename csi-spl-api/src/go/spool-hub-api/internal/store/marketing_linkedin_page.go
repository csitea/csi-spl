package store

import (
	"context"
	"sort"

	"github.com/jackc/pgx/v5"
)

// MarketingLinkedInPageDispatch is what the LinkedIn Company Page dispatcher
// (spec 090 phase 4, T041, SPL-5258) reads beyond Marketing,
// MarketingMetaDispatch and the token swap of MarketingXDispatch; rdb 0276
// only widens the platform CHECK. A Page channel is never auto_publish, so
// the personal-profile LinkedIn sweep never lists one.
type MarketingLinkedInPageDispatch interface {
	// LinkedInPageChannels lists every active LinkedIn Page
	// channel, all tenants (the dispatch sweep; operator scope).
	LinkedInPageChannels(ctx context.Context) ([]MarketingChannel, error)
}

// LinkedInPageChannels implements MarketingLinkedInPageDispatch on
// the Postgres store.
func (s *Postgres) LinkedInPageChannels(ctx context.Context) ([]MarketingChannel, error) {
	out := []MarketingChannel{}
	err := s.asOperatorQuery(ctx, `SELECT `+mktChannelCols+` FROM marketing_channels
		WHERE status = 'active' AND platform = 'linkedin_page' ORDER BY tenant_id, created_at`, nil,
		func(r pgx.Rows) error {
			c, err := scanMktChannel(r)
			out = append(out, c)
			return err
		})
	return out, err
}

// LinkedInPageChannels implements MarketingLinkedInPageDispatch on
// the Memory store.
func (s *Memory) LinkedInPageChannels(_ context.Context) ([]MarketingChannel, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []MarketingChannel{}
	for _, c := range s.mkt().channels {
		if c.Status == MarketingActive && c.Platform == MarketingPlatformLinkedInPage {
			out = append(out, *c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}
