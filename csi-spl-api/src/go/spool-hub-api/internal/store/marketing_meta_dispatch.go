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
	// ClaimMetaMarketingPosts claims due posts of one Meta channel under its
	// rolling cap, in one transaction that holds the channel row's lock, so
	// two claims (a publish and the sweep, or two hubs) never both take the
	// last place (SPL-4564 N2). A post in flight (dispatching) counts
	// against the cap with its claim time, a post published through the API
	// with its publish time; a post handed over by hand (platform_post_id
	// 'manual') does not count. Only as many posts as there is room for are
	// claimed: a post the cap holds back stays scheduled and spends no
	// attempt (N3).
	ClaimMetaMarketingPosts(ctx context.Context, c MetaClaim) (MetaClaimed, error)
}

// MetaClaim is one capped claim of a Meta channel's due posts.
type MetaClaim struct {
	Tenant, ChannelID string
	// PostID, when set, claims only that post (the publish that approved
	// it), waiting for a racing row lock instead of skipping it (SPL-4477);
	// else every due post of the channel, oldest first (the sweep).
	PostID string
	Limit  int           // the most posts the channel makes in Window
	Window time.Duration // the rolling cap window
	Now    time.Time
}

// MetaClaimed is what a capped claim took, and whether the cap held back a
// due post: then FreeAt is when the window next frees a place.
type MetaClaimed struct {
	Posts  []MarketingPost
	Held   bool
	FreeAt time.Time
}

// metaFreeAt is when a window of length w over the sorted times next frees
// a place for a limit of limit; zero while there is room.
func metaFreeAt(times []time.Time, limit int, w time.Duration) time.Time {
	if limit <= 0 || len(times) < limit {
		return time.Time{}
	}
	return times[len(times)-limit].Add(w)
}

// metaClaimed completes a claim: the claimed posts take a place each at now.
func metaClaimed(c MetaClaim, times []time.Time, posts []MarketingPost, held bool) MetaClaimed {
	for range posts {
		times = append(times, c.Now)
	}
	out := MetaClaimed{Posts: posts, Held: held}
	if held {
		out.FreeAt = metaFreeAt(times, c.Limit, c.Window)
	}
	return out
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

// ClaimMetaMarketingPosts implements MarketingMetaDispatch on the Postgres
// store: the channel row's lock serialises every capped claim of the
// channel; the post claim itself is ClaimMarketingPosts' guarded UPDATE.
func (s *Postgres) ClaimMetaMarketingPosts(ctx context.Context, c MetaClaim) (MetaClaimed, error) {
	var out MetaClaimed
	err := s.inTenant(ctx, c.Tenant, func(tx pgx.Tx) error {
		var id string
		if err := tx.QueryRow(ctx, `SELECT channel_id::text FROM marketing_channels WHERE tenant_id = $1 AND channel_id = $2::uuid FOR UPDATE`,
			c.Tenant, c.ChannelID).Scan(&id); err != nil {
			return err
		}
		times, err := metaCapTimes(ctx, tx, c)
		if err != nil {
			return err
		}
		var posts []MarketingPost
		if room := c.Limit - len(times); room > 0 {
			if posts, err = metaClaimTx(ctx, tx, c, room); err != nil {
				return err
			}
		}
		held, err := metaDueLeft(ctx, tx, c)
		out = metaClaimed(c, times, posts, held)
		return err
	})
	return out, err
}

// metaCapTimes lists, oldest first, the times of the channel's posts that
// count against its cap now: published through the API inside the window,
// or in flight.
func metaCapTimes(ctx context.Context, tx pgx.Tx, c MetaClaim) ([]time.Time, error) {
	rows, err := tx.Query(ctx, `SELECT CASE WHEN status = 'published' THEN published_at ELSE claimed_at END AS at
		FROM marketing_posts WHERE tenant_id = $1 AND channel_id = $2::uuid
			AND ((status = 'published' AND published_at >= $3 AND coalesce(platform_post_id, '') <> '`+MarketingManualPostID+`')
				OR status = 'dispatching')
		ORDER BY at`, c.Tenant, c.ChannelID, c.Now.Add(-c.Window))
	if err != nil {
		return nil, err
	}
	out := []time.Time{}
	err = scanRows(rows, func(r pgx.Rows) error {
		var t time.Time
		err := r.Scan(&t)
		out = append(out, t)
		return err
	})
	return out, err
}

// metaClaimTx claims at most room due posts (the one c.PostID, or the
// channel's oldest) and writes their post_dispatched events.
func metaClaimTx(ctx context.Context, tx pgx.Tx, c MetaClaim, room int) ([]MarketingPost, error) {
	q := `UPDATE marketing_posts SET status = 'dispatching', attempts = attempts + 1, claimed_at = $3, updated_at = $3
		WHERE post_id IN (SELECT post_id FROM marketing_posts WHERE tenant_id = $1 AND channel_id = $2::uuid
			AND status = 'scheduled' AND (next_attempt_at IS NULL OR next_attempt_at <= $3)
			ORDER BY created_at LIMIT $4 FOR UPDATE SKIP LOCKED)
		RETURNING ` + mktPostCols
	args := []any{c.Tenant, c.ChannelID, c.Now, room}
	if c.PostID != "" { // a plain UPDATE waits for a racing lock on the row, then re-reads its status
		q = `UPDATE marketing_posts SET status = 'dispatching', attempts = attempts + 1, claimed_at = $3, updated_at = $3
		WHERE tenant_id = $1 AND channel_id = $2::uuid AND post_id = $4::uuid AND status = 'scheduled'
			AND (next_attempt_at IS NULL OR next_attempt_at <= $3)
		RETURNING ` + mktPostCols
		args[3] = c.PostID
	}
	return mktClaimTx(ctx, tx, c.Tenant, q, args)
}

// metaDueLeft: a due post of the claim is still scheduled (the cap held it).
func metaDueLeft(ctx context.Context, tx pgx.Tx, c MetaClaim) (bool, error) {
	var left bool
	err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM marketing_posts WHERE tenant_id = $1 AND channel_id = $2::uuid
		AND status = 'scheduled' AND (next_attempt_at IS NULL OR next_attempt_at <= $3) AND ($4 = '' OR post_id::text = $4))`,
		c.Tenant, c.ChannelID, c.Now, c.PostID).Scan(&left)
	return left, err
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

// ClaimMetaMarketingPosts implements MarketingMetaDispatch on the Memory
// store, under s.mu.
func (s *Memory) ClaimMetaMarketingPosts(_ context.Context, c MetaClaim) (MetaClaimed, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	times := []time.Time{}
	var due []*memMktPost
	for _, p := range m.posts {
		if p.Tenant != c.Tenant || p.ChannelID != c.ChannelID {
			continue
		}
		switch {
		case p.Status == MarketingDispatching:
			times = append(times, p.claimed)
		case p.Status == MarketingPublished && p.PlatformPostID != MarketingManualPostID && !p.published.Before(c.Now.Add(-c.Window)):
			times = append(times, p.published)
		case p.Status == MarketingScheduled && !p.next.After(c.Now) && (c.PostID == "" || p.ID == c.PostID):
			due = append(due, p)
		}
	}
	sort.Slice(times, func(i, j int) bool { return times[i].Before(times[j]) })
	sort.Slice(due, func(i, j int) bool { return due[i].SourceRef < due[j].SourceRef })
	var posts []MarketingPost
	for i := 0; i < len(due) && i < c.Limit-len(times); i++ {
		p := due[i]
		p.Status, p.Attempts, p.claimed = MarketingDispatching, p.Attempts+1, c.Now
		posts = append(posts, p.MarketingPost)
		m.event(c.Tenant, p.ChannelID, p.ID, "post_dispatched")
	}
	return metaClaimed(c, times, posts, len(due) > len(posts)), nil
}
