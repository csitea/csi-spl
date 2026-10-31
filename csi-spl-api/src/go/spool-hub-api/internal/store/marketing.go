package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Marketing is spec 090's connected-account store (rdb 0187, SPL-1634): a
// LinkedIn account a member connected, its token as KMS-sealed ciphertext
// only, and the blog shares made with it. The store never sees a plaintext
// token: the hub seals before Connect and opens after MarketingToken.
//
// A share happens at most once per (channel, source): ScheduleMarketingPost
// inserts on the UNIQUE key and reports whether this call made the row, and
// ClaimMarketingPosts moves a row to dispatching in one guarded UPDATE, so two
// hub instances never both call LinkedIn for one post.
type Marketing interface {
	// ConnectMarketingChannel upserts the channel on (tenant, platform,
	// account ref), stores its sealed token, sets it active with expires_at,
	// clears reminded_at and writes channel_connect. baseline_at is kept.
	ConnectMarketingChannel(ctx context.Context, ch MarketingChannel, tok MarketingToken, now time.Time) (MarketingChannel, error)
	// MarketingChannels lists tenant's channels (never a token).
	MarketingChannels(ctx context.Context, tenant string) ([]MarketingChannel, error)
	// AutoMarketingChannels lists every active auto_publish channel, all
	// tenants (the share sweep; operator scope).
	AutoMarketingChannels(ctx context.Context) ([]MarketingChannel, error)
	// DisconnectMarketingChannel deletes tenant's channel channelID with its
	// sealed token and its posts; a facebook_page takes its linked
	// instagram_business channels (metadata page_id = the Page's id, the same
	// Page token) with it. It returns the deleted channel ids; ErrNotFound
	// when tenant has no such channel. The events stay (append-only).
	DisconnectMarketingChannel(ctx context.Context, tenant, channelID string) ([]string, error)
	// MarketingToken reads a channel's sealed token; ErrNotFound when none.
	MarketingToken(ctx context.Context, tenant, channelID string) (MarketingToken, error)
	// ExpireMarketingChannel sets an active channel expired (+ event).
	ExpireMarketingChannel(ctx context.Context, tenant, channelID string, now time.Time) error
	// MarkMarketingReminded sets reminded_at once per expiry; true only for
	// the caller that set it (so one reminder is sent).
	MarkMarketingReminded(ctx context.Context, tenant, channelID string, now time.Time) (bool, error)
	// BaselineMarketingPosts records refs as skipped and sets baseline_at.
	BaselineMarketingPosts(ctx context.Context, tenant, channelID string, refs []string, now time.Time) error
	// MarketingPostRefs is the set of source refs the channel already has.
	MarketingPostRefs(ctx context.Context, tenant, channelID string) (map[string]bool, error)
	// ScheduleMarketingPost inserts a scheduled post, or a held one when
	// p.Status is MarketingAwaitingApproval (rdb 0236), with its media
	// assets; false when the (channel, source) row already exists (nothing
	// changed).
	ScheduleMarketingPost(ctx context.Context, p MarketingPost, now time.Time) (bool, error)
	// ApproveMarketingPost releases a held post: awaiting_approval ->
	// scheduled, due now (+ post_approved by actor). ErrNotFound when the
	// post is not held in tenant.
	ApproveMarketingPost(ctx context.Context, tenant, postID, actor string, now time.Time) error
	// HandOverMarketingPost records a post the member published by hand
	// (spec 090 section 17): a held or scheduled post becomes published with
	// platform_post_id 'manual' (+ post_handed_over by actor). ErrNotFound
	// when the post is neither in tenant.
	HandOverMarketingPost(ctx context.Context, tenant, postID, actor string, now time.Time) error
	// ClaimMarketingPosts moves the channel's due scheduled posts to
	// dispatching (attempts+1) and returns them.
	ClaimMarketingPosts(ctx context.Context, tenant, channelID string, now time.Time) ([]MarketingPost, error)
	// FinishMarketingPost settles a dispatching post (+ event).
	FinishMarketingPost(ctx context.Context, tenant, postID string, out MarketingOutcome, now time.Time) error
	// StuckMarketingPosts fails every post still dispatching since before
	// `before` (the hub died mid-call: the outcome is unknown, so it is never
	// retried) and returns them.
	StuckMarketingPosts(ctx context.Context, before, now time.Time) ([]MarketingPost, error)
}

// MarketingChannel is one connected account. Times are nil when unset.
type MarketingChannel struct {
	ID          string     `json:"channel_id"`
	Tenant      string     `json:"tenant_id"`
	Platform    string     `json:"platform"`
	AccountType string     `json:"account_type"` // "" on connect = personal
	AccountRef  string     `json:"account_ref"`
	AccountName string     `json:"account_name"`
	DelegatedBy string     `json:"delegated_by"`
	AutoPublish bool       `json:"auto_publish"`
	Status      string     `json:"status"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
	RemindedAt  *time.Time `json:"reminded_at,omitempty"`
	BaselineAt  *time.Time `json:"baseline_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
	// Metadata is the platform's public account facts (rdb 0236): the Page
	// id, the Instagram business id, the username, the profile picture URL.
	// Never a token.
	Metadata map[string]any `json:"metadata"`
}

// MarketingToken is a channel's sealed token: ciphertext and the KMS key
// version that wrapped its data key. Never a plaintext.
type MarketingToken struct {
	Ciphertext string
	KMSKeyID   string
}

// MarketingPost is one share of one source on one channel.
type MarketingPost struct {
	ID             string
	Tenant         string
	ChannelID      string
	SourceType     string
	SourceRef      string
	ContentText    string
	Status         string
	Attempts       int
	PlatformPostID string
	LastError      string
	MediaAssets    []MarketingMediaAsset // rdb 0236; nil reads back as empty
}

// MarketingMediaAsset is one candidate picture of a post (rdb 0236
// media_assets): where it is, its size, and whether it was picked.
type MarketingMediaAsset struct {
	URL         string  `json:"url"`
	Width       int     `json:"width,omitempty"`
	Height      int     `json:"height,omitempty"`
	AspectRatio float64 `json:"aspect_ratio,omitempty"`
	Selected    bool    `json:"selected"`
}

// MarketingOutcome is how a dispatching post ends: Published (with the
// platform's id and, when the platform gave one, the public Permalink, kept
// in the post_published event), Retry at RetryAt, or failed with Error.
type MarketingOutcome struct {
	Published      bool
	PlatformPostID string
	Permalink      string
	Retry          bool
	RetryAt        time.Time
	Error          string
}

// Marketing statuses, platforms and source types (rdb 0187 and 0236 CHECKs).
const (
	MarketingAwaitingApproval = "awaiting_approval"
	MarketingPlatformLinkedIn = "linkedin"
	MarketingPlatformFacebook = "facebook_page"
	MarketingPlatformIG       = "instagram_business"
	MarketingManualPostID     = "manual"
	MarketingActive           = "active"
	MarketingExpired          = "expired"
	MarketingSkipped          = "skipped"
	MarketingScheduled        = "scheduled"
	MarketingDispatching      = "dispatching"
	MarketingPublished        = "published"
	MarketingFailed           = "failed"
	MarketingSourceBlog       = "blog"
)

// outcomeRow maps an outcome to the post's next status and its event.
func outcomeRow(out MarketingOutcome) (status, event string, next *time.Time) {
	switch {
	case out.Published:
		return MarketingPublished, "post_published", nil
	case out.Retry:
		t := out.RetryAt
		return MarketingScheduled, "post_failed", &t
	}
	return MarketingFailed, "post_failed", nil
}

func outcomeDetails(out MarketingOutcome) map[string]any {
	d := map[string]any{}
	if out.PlatformPostID != "" {
		d["platform_post_id"] = out.PlatformPostID
	}
	if out.Permalink != "" {
		d["permalink"] = out.Permalink
	}
	if out.Error != "" {
		d["error"] = out.Error
		d["retry"] = out.Retry
	}
	return d
}

// ---- Postgres ---------------------------------------------------------------

const mktChannelCols = `channel_id::text, tenant_id, platform, account_type, account_ref, account_name, delegated_by,
	auto_publish, status, expires_at, reminded_at, baseline_at, created_at, metadata`

func scanMktChannel(r pgx.Row) (MarketingChannel, error) {
	var c MarketingChannel
	err := r.Scan(&c.ID, &c.Tenant, &c.Platform, &c.AccountType, &c.AccountRef, &c.AccountName, &c.DelegatedBy,
		&c.AutoPublish, &c.Status, &c.ExpiresAt, &c.RemindedAt, &c.BaselineAt, &c.CreatedAt, &c.Metadata)
	return c, err
}

const mktPostCols = `post_id::text, tenant_id, channel_id::text, source_type, source_ref, content_text,
	status, attempts, coalesce(platform_post_id, ''), coalesce(last_error, ''), media_assets`

func scanMktPost(r pgx.Row) (MarketingPost, error) {
	var p MarketingPost
	err := r.Scan(&p.ID, &p.Tenant, &p.ChannelID, &p.SourceType, &p.SourceRef, &p.ContentText,
		&p.Status, &p.Attempts, &p.PlatformPostID, &p.LastError, &p.MediaAssets)
	return p, err
}

// mktJSON marshals a metadata map or a media asset list for a jsonb
// parameter; nil becomes empty (the 0236 column defaults).
func mktJSON(v any, empty string) (string, error) {
	switch x := v.(type) {
	case map[string]any:
		if x == nil {
			return empty, nil
		}
	case []MarketingMediaAsset:
		if x == nil {
			return empty, nil
		}
	}
	b, err := json.Marshal(v)
	return string(b), err
}

// mktEv is one marketing_post_events row; Actor "" with ActorType system.
type mktEv struct {
	Tenant, Channel, Post, Type, ActorType, Actor string
	Details                                       map[string]any
}

func mktEvent(ctx context.Context, tx pgx.Tx, e mktEv) error {
	if e.Details == nil {
		e.Details = map[string]any{}
	}
	if e.ActorType == "" {
		e.ActorType = "system"
	}
	b, err := json.Marshal(e.Details)
	if err != nil {
		return err
	}
	var postID any
	if e.Post != "" {
		postID = e.Post
	}
	_, err = tx.Exec(ctx, `INSERT INTO marketing_post_events (tenant_id, channel_id, post_id, event_type, actor_type, actor_id, details)
		VALUES ($1, $2::uuid, $3::uuid, $4, $5, $6, $7::jsonb)`, e.Tenant, e.Channel, postID, e.Type, e.ActorType, e.Actor, string(b))
	return err
}

// ConnectMarketingChannel implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) ConnectMarketingChannel(ctx context.Context, ch MarketingChannel, tok MarketingToken, now time.Time) (MarketingChannel, error) {
	var out MarketingChannel
	meta, err := mktJSON(ch.Metadata, "{}")
	if err != nil {
		return out, err
	}
	err = s.inTenant(ctx, ch.Tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanMktChannel(tx.QueryRow(ctx, `INSERT INTO marketing_channels
			(tenant_id, platform, account_type, account_ref, account_name, delegated_by, auto_publish, status, expires_at,
				metadata, created_at, updated_at)
			VALUES ($1, $2, coalesce(nullif($9, ''), 'personal'), $3, $4, $5, $6, 'active', $7, $10::jsonb, $8, $8)
			ON CONFLICT (tenant_id, platform, account_ref) DO UPDATE SET account_name = EXCLUDED.account_name,
				account_type = EXCLUDED.account_type, metadata = EXCLUDED.metadata,
				delegated_by = EXCLUDED.delegated_by, auto_publish = EXCLUDED.auto_publish, status = 'active',
				expires_at = EXCLUDED.expires_at, reminded_at = NULL, updated_at = EXCLUDED.updated_at
			RETURNING `+mktChannelCols,
			ch.Tenant, ch.Platform, ch.AccountRef, ch.AccountName, ch.DelegatedBy, ch.AutoPublish, ch.ExpiresAt, now,
			ch.AccountType, meta))
		if err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO marketing_channel_tokens (channel_id, tenant_id, ciphertext, kms_key_id, updated_at)
			VALUES ($1::uuid, $2, $3, $4, $5) ON CONFLICT (channel_id) DO UPDATE SET ciphertext = EXCLUDED.ciphertext,
				kms_key_id = EXCLUDED.kms_key_id, updated_at = EXCLUDED.updated_at`,
			out.ID, ch.Tenant, tok.Ciphertext, tok.KMSKeyID, now); err != nil {
			return err
		}
		return mktEvent(ctx, tx, mktEv{Tenant: ch.Tenant, Channel: out.ID, Type: "channel_connect", ActorType: "human", Actor: ch.DelegatedBy, Details: map[string]any{"platform": ch.Platform, "kms_key_id": tok.KMSKeyID}})
	})
	return out, err
}

// MarketingChannels implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) MarketingChannels(ctx context.Context, tenant string) ([]MarketingChannel, error) {
	out := []MarketingChannel{}
	err := s.queryTenant(ctx, tenant, `SELECT `+mktChannelCols+` FROM marketing_channels WHERE tenant_id = $1 ORDER BY created_at`,
		[]any{tenant}, func(r pgx.Rows) error {
			c, err := scanMktChannel(r)
			out = append(out, c)
			return err
		})
	return out, err
}

// DisconnectMarketingChannel implements Marketing on the Postgres store
// (rdb 0187, 0236). The token and post rows go first, named, rather than
// left to the FK cascade.
func (s *Postgres) DisconnectMarketingChannel(ctx context.Context, tenant, channelID string) ([]string, error) {
	var ids []string
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT c.channel_id::text FROM marketing_channels c, marketing_channels t
			WHERE t.tenant_id = $1 AND t.channel_id = $2::uuid AND c.tenant_id = $1
				AND (c.channel_id = t.channel_id OR (t.platform = 'facebook_page' AND c.platform = 'instagram_business'
					AND c.metadata->>'page_id' = t.account_ref))
			ORDER BY c.channel_id = t.channel_id DESC, c.created_at FOR UPDATE OF c`, tenant, channelID)
		if err != nil {
			return err
		}
		if err := scanRows(rows, func(r pgx.Rows) error {
			var id string
			err := r.Scan(&id)
			ids = append(ids, id)
			return err
		}); err != nil {
			return err
		}
		if len(ids) == 0 {
			return ErrNotFound
		}
		for _, q := range []string{`DELETE FROM marketing_channel_tokens WHERE tenant_id = $1 AND channel_id = ANY($2::uuid[])`,
			`DELETE FROM marketing_posts WHERE tenant_id = $1 AND channel_id = ANY($2::uuid[])`,
			`DELETE FROM marketing_channels WHERE tenant_id = $1 AND channel_id = ANY($2::uuid[])`} {
			if _, err := tx.Exec(ctx, q, tenant, ids); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return ids, nil
}

// AutoMarketingChannels implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) AutoMarketingChannels(ctx context.Context) ([]MarketingChannel, error) {
	out := []MarketingChannel{}
	err := s.asOperatorQuery(ctx, `SELECT `+mktChannelCols+` FROM marketing_channels
		WHERE status = 'active' AND auto_publish ORDER BY tenant_id, created_at`, nil, func(r pgx.Rows) error {
		c, err := scanMktChannel(r)
		out = append(out, c)
		return err
	})
	return out, err
}

// MarketingToken implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) MarketingToken(ctx context.Context, tenant, channelID string) (MarketingToken, error) {
	var t MarketingToken
	err := s.queryRowTenant(ctx, tenant, `SELECT ciphertext, kms_key_id FROM marketing_channel_tokens
		WHERE tenant_id = $1 AND channel_id = $2::uuid`, []any{tenant, channelID}, &t.Ciphertext, &t.KMSKeyID)
	if errors.Is(err, pgx.ErrNoRows) {
		return t, ErrNotFound
	}
	return t, err
}

// ExpireMarketingChannel implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) ExpireMarketingChannel(ctx context.Context, tenant, channelID string, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE marketing_channels SET status = 'expired', updated_at = $3
			WHERE tenant_id = $1 AND channel_id = $2::uuid AND status = 'active'`, tenant, channelID, now)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		return mktEvent(ctx, tx, mktEv{Tenant: tenant, Channel: channelID, Type: "channel_expired"})
	})
}

// MarkMarketingReminded implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) MarkMarketingReminded(ctx context.Context, tenant, channelID string, now time.Time) (bool, error) {
	won := false
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE marketing_channels SET reminded_at = $3, updated_at = $3
			WHERE tenant_id = $1 AND channel_id = $2::uuid AND reminded_at IS NULL`, tenant, channelID, now)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		won = true
		return mktEvent(ctx, tx, mktEv{Tenant: tenant, Channel: channelID, Type: "channel_reminder"})
	})
	return won, err
}

// BaselineMarketingPosts implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) BaselineMarketingPosts(ctx context.Context, tenant, channelID string, refs []string, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO marketing_posts (tenant_id, channel_id, source_type, source_ref, status, created_at, updated_at)
			SELECT $1, $2::uuid, 'blog', ref, 'skipped', $4, $4 FROM unnest($3::text[]) AS ref
			ON CONFLICT (channel_id, source_type, source_ref) DO NOTHING`, tenant, channelID, refs, now); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE marketing_channels SET baseline_at = $3, updated_at = $3
			WHERE tenant_id = $1 AND channel_id = $2::uuid AND baseline_at IS NULL`, tenant, channelID, now)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		return mktEvent(ctx, tx, mktEv{Tenant: tenant, Channel: channelID, Type: "post_baseline", Details: map[string]any{"skipped": len(refs)}})
	})
}

// MarketingPostRefs implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) MarketingPostRefs(ctx context.Context, tenant, channelID string) (map[string]bool, error) {
	out := map[string]bool{}
	err := s.queryTenant(ctx, tenant, `SELECT source_ref FROM marketing_posts WHERE tenant_id = $1 AND channel_id = $2::uuid`,
		[]any{tenant, channelID}, func(r pgx.Rows) error {
			var ref string
			err := r.Scan(&ref)
			out[ref] = true
			return err
		})
	return out, err
}

// ScheduleMarketingPost implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) ScheduleMarketingPost(ctx context.Context, p MarketingPost, now time.Time) (bool, error) {
	made := false
	status, event := mktScheduleStatus(p.Status)
	media, err := mktJSON(p.MediaAssets, "[]")
	if err != nil {
		return false, err
	}
	err = s.inTenant(ctx, p.Tenant, func(tx pgx.Tx) error {
		var id string
		err := tx.QueryRow(ctx, `INSERT INTO marketing_posts (tenant_id, channel_id, source_type, source_ref, content_text, status,
				media_assets, created_at, updated_at)
			VALUES ($1, $2::uuid, $3, $4, $5, $7, $8::jsonb, $6, $6)
			ON CONFLICT (channel_id, source_type, source_ref) DO NOTHING RETURNING post_id::text`,
			p.Tenant, p.ChannelID, p.SourceType, p.SourceRef, p.ContentText, now, status, media).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		made = true
		return mktEvent(ctx, tx, mktEv{Tenant: p.Tenant, Channel: p.ChannelID, Post: id, Type: event, Details: map[string]any{"source_ref": p.SourceRef}})
	})
	return made, err
}

// mktScheduleStatus is a new post's status and event: held when asked for
// (rdb 0236), else scheduled.
func mktScheduleStatus(want string) (status, event string) {
	if want == MarketingAwaitingApproval {
		return MarketingAwaitingApproval, "post_held"
	}
	return MarketingScheduled, "post_scheduled"
}

// mktMove moves one post of tenant from one of the from statuses in one
// guarded UPDATE (set is the SET list after updated_at; $1 tenant, $2 post,
// $3 now, $4 from) and writes the event; ErrNotFound when no row moved.
func (s *Postgres) mktMove(ctx context.Context, tenant, postID string, from []string, set string, ev mktEv, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var channel string
		err := tx.QueryRow(ctx, `UPDATE marketing_posts SET updated_at = $3, `+set+`
			WHERE tenant_id = $1 AND post_id = $2::uuid AND status = ANY($4::text[]) RETURNING channel_id::text`,
			tenant, postID, now, from).Scan(&channel)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		ev.Tenant, ev.Channel, ev.Post, ev.ActorType = tenant, channel, postID, "human"
		return mktEvent(ctx, tx, ev)
	})
}

// ApproveMarketingPost implements Marketing on the Postgres store (rdb 0236).
func (s *Postgres) ApproveMarketingPost(ctx context.Context, tenant, postID, actor string, now time.Time) error {
	return s.mktMove(ctx, tenant, postID, []string{MarketingAwaitingApproval},
		`status = 'scheduled', next_attempt_at = $3`, mktEv{Type: "post_approved", Actor: actor}, now)
}

// HandOverMarketingPost implements Marketing on the Postgres store (rdb 0236).
func (s *Postgres) HandOverMarketingPost(ctx context.Context, tenant, postID, actor string, now time.Time) error {
	return s.mktMove(ctx, tenant, postID, []string{MarketingAwaitingApproval, MarketingScheduled},
		`status = 'published', platform_post_id = '`+MarketingManualPostID+`', published_at = $3, next_attempt_at = NULL`,
		mktEv{Type: "post_handed_over", Actor: actor}, now)
}

// ClaimMarketingPosts implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) ClaimMarketingPosts(ctx context.Context, tenant, channelID string, now time.Time) ([]MarketingPost, error) {
	return s.mktClaim(ctx, tenant, `UPDATE marketing_posts SET status = 'dispatching', attempts = attempts + 1,
			claimed_at = $3, updated_at = $3
		WHERE post_id IN (SELECT post_id FROM marketing_posts WHERE tenant_id = $1 AND channel_id = $2::uuid
			AND status = 'scheduled' AND (next_attempt_at IS NULL OR next_attempt_at <= $3)
			ORDER BY created_at FOR UPDATE SKIP LOCKED)
		RETURNING `+mktPostCols, channelID, now)
}

// mktClaim runs one claiming UPDATE ($1 tenant, then args) and writes a
// post_dispatched event for each post it moved to dispatching.
func (s *Postgres) mktClaim(ctx context.Context, tenant, query string, args ...any) ([]MarketingPost, error) {
	var out []MarketingPost
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, query, append([]any{tenant}, args...)...)
		if err != nil {
			return err
		}
		if err := scanRows(rows, func(r pgx.Rows) error {
			p, err := scanMktPost(r)
			out = append(out, p)
			return err
		}); err != nil {
			return err
		}
		for _, p := range out {
			if err := mktEvent(ctx, tx, mktEv{Tenant: tenant, Channel: p.ChannelID, Post: p.ID, Type: "post_dispatched", Details: map[string]any{"attempt": p.Attempts}}); err != nil {
				return err
			}
		}
		return nil
	})
	return out, err
}

// FinishMarketingPost implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) FinishMarketingPost(ctx context.Context, tenant, postID string, out MarketingOutcome, now time.Time) error {
	status, event, next := outcomeRow(out)
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var channel string
		err := tx.QueryRow(ctx, `UPDATE marketing_posts SET status = $3, next_attempt_at = $4,
				platform_post_id = nullif($5, ''), last_error = nullif($6, ''),
				published_at = CASE WHEN $3 = 'published' THEN $7 ELSE published_at END, updated_at = $7
			WHERE tenant_id = $1 AND post_id = $2::uuid AND status = 'dispatching' RETURNING channel_id::text`,
			tenant, postID, status, next, out.PlatformPostID, out.Error, now).Scan(&channel)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		return mktEvent(ctx, tx, mktEv{Tenant: tenant, Channel: channel, Post: postID, Type: event, Details: outcomeDetails(out)})
	})
}

// StuckMarketingPosts implements Marketing on the Postgres store (rdb 0187).
func (s *Postgres) StuckMarketingPosts(ctx context.Context, before, now time.Time) ([]MarketingPost, error) {
	var out []MarketingPost
	const why = "the hub stopped during the LinkedIn call; the outcome is unknown, so it is not retried"
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `UPDATE marketing_posts SET status = 'failed', last_error = $3, updated_at = $2
			WHERE status = 'dispatching' AND claimed_at < $1 RETURNING `+mktPostCols, before, now, why)
		if err != nil {
			return err
		}
		if err := scanRows(rows, func(r pgx.Rows) error {
			p, err := scanMktPost(r)
			out = append(out, p)
			return err
		}); err != nil {
			return err
		}
		for _, p := range out {
			if err := mktEvent(ctx, tx, mktEv{Tenant: p.Tenant, Channel: p.ChannelID, Post: p.ID, Type: "post_failed", Details: map[string]any{"error": why}}); err != nil {
				return err
			}
		}
		return nil
	})
	return out, err
}
