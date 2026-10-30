package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// MarketingMetaDispatch is what the Facebook Page / Instagram dispatcher
// (spec 090 T034, SPL-4424) reads beyond Marketing; no new table or column
// (rdb 0187 and 0236 hold it all). A Meta channel is never auto_publish, so
// AutoMarketingChannels (the LinkedIn sweep's list) never names one.
type MarketingMetaDispatch interface {
	// MetaMarketingChannels lists every active facebook_page and
	// instagram_business channel, all tenants (the dispatch sweep; operator
	// scope).
	MetaMarketingChannels(ctx context.Context) ([]MarketingChannel, error)
	// MarketingPostByRef reads the channel's post of (sourceType, ref);
	// ErrNotFound when there is none.
	MarketingPostByRef(ctx context.Context, tenant, channelID, sourceType, ref string) (MarketingPost, error)
	// MarketingPublishedTimes lists, oldest first, when the channel's posts
	// published through the API since `since` went out; a post handed over
	// by hand (platform_post_id 'manual') is not counted.
	MarketingPublishedTimes(ctx context.Context, tenant, channelID string, since time.Time) ([]time.Time, error)
}

// ---- Postgres ---------------------------------------------------------------

// MetaMarketingChannels implements MarketingMetaDispatch on the Postgres store.
func (s *Postgres) MetaMarketingChannels(ctx context.Context) ([]MarketingChannel, error) {
	out := []MarketingChannel{}
	err := s.asOperatorQuery(ctx, `SELECT `+mktChannelCols+` FROM marketing_channels
		WHERE status = 'active' AND platform IN ('facebook_page', 'instagram_business') ORDER BY tenant_id, created_at`, nil,
		func(r pgx.Rows) error {
			c, err := scanMktChannel(r)
			out = append(out, c)
			return err
		})
	return out, err
}

// MarketingPostByRef implements MarketingMetaDispatch on the Postgres store.
func (s *Postgres) MarketingPostByRef(ctx context.Context, tenant, channelID, sourceType, ref string) (MarketingPost, error) {
	var out []MarketingPost
	err := s.queryTenant(ctx, tenant, `SELECT `+mktPostCols+` FROM marketing_posts
		WHERE tenant_id = $1 AND channel_id = $2::uuid AND source_type = $3 AND source_ref = $4`,
		[]any{tenant, channelID, sourceType, ref}, func(r pgx.Rows) error {
			p, err := scanMktPost(r)
			out = append(out, p)
			return err
		})
	if err != nil {
		return MarketingPost{}, err
	}
	if len(out) == 0 {
		return MarketingPost{}, ErrNotFound
	}
	return out[0], nil
}

// MarketingPublishedTimes implements MarketingMetaDispatch on the Postgres store.
func (s *Postgres) MarketingPublishedTimes(ctx context.Context, tenant, channelID string, since time.Time) ([]time.Time, error) {
	out := []time.Time{}
	err := s.queryTenant(ctx, tenant, `SELECT published_at FROM marketing_posts
		WHERE tenant_id = $1 AND channel_id = $2::uuid AND status = 'published' AND published_at >= $3
			AND coalesce(platform_post_id, '') <> '`+MarketingManualPostID+`' ORDER BY published_at`,
		[]any{tenant, channelID, since}, func(r pgx.Rows) error {
			var t time.Time
			err := r.Scan(&t)
			out = append(out, t)
			return err
		})
	return out, err
}

// ---- Memory -----------------------------------------------------------------

// MetaMarketingChannels implements MarketingMetaDispatch on the Memory store.
func (s *Memory) MetaMarketingChannels(_ context.Context) ([]MarketingChannel, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []MarketingChannel{}
	for _, c := range s.mkt().channels {
		if c.Status == MarketingActive && (c.Platform == MarketingPlatformFacebook || c.Platform == MarketingPlatformIG) {
			out = append(out, *c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// MarketingPostByRef implements MarketingMetaDispatch on the Memory store.
func (s *Memory) MarketingPostByRef(_ context.Context, tenant, channelID, sourceType, ref string) (MarketingPost, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.mkt().posts {
		if p.Tenant == tenant && p.ChannelID == channelID && p.SourceType == sourceType && p.SourceRef == ref {
			return p.MarketingPost, nil
		}
	}
	return MarketingPost{}, ErrNotFound
}

// MarketingPublishedTimes implements MarketingMetaDispatch on the Memory store.
func (s *Memory) MarketingPublishedTimes(_ context.Context, tenant, channelID string, since time.Time) ([]time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []time.Time{}
	for _, p := range s.mkt().posts {
		if p.Tenant == tenant && p.ChannelID == channelID && p.Status == MarketingPublished &&
			p.PlatformPostID != MarketingManualPostID && !p.published.Before(since) {
			out = append(out, p.published)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Before(out[j]) })
	return out, nil
}
