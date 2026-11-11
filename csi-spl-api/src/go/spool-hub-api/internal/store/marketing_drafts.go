package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// MarketingDrafts is the workspace's own marketing posts (spec 090 section
// 22, rdb 0274, SPL-5240; owner HUM-10, t1 19ef7d51): a member holding
// tenant.settings writes one, edits or deletes it while it is a draft, and
// publishes it on the workspace's channels. A publish is a marketing_posts
// row per channel, source 'draft', source_ref the draft's id, so it goes
// through the same claim and dispatch as a blog post, once per channel.
//
// Every call is in the tenant's RLS scope: a workspace never reads another
// workspace's drafts. Who may call is the hub's rule (the author edits,
// deletes and publishes); the store only refuses a change to a published
// draft (ErrMarketingDraftPublished).
type MarketingDrafts interface {
	// CreateMarketingDraft stores d (Tenant, AuthorID, Body, ImageURL) and
	// returns it with its id and times.
	CreateMarketingDraft(ctx context.Context, d MarketingDraft, now time.Time) (MarketingDraft, error)
	// MarketingDrafts lists tenant's drafts, last changed first, each with
	// its publishes (Posts).
	MarketingDrafts(ctx context.Context, tenant string) ([]MarketingDraft, error)
	// MarketingDraft reads one draft with its publishes; ErrNotFound when
	// tenant has no such draft.
	MarketingDraft(ctx context.Context, tenant, id string) (MarketingDraft, error)
	// UpdateMarketingDraft replaces an unpublished draft's text and picture.
	// ErrNotFound, or ErrMarketingDraftPublished once it was published.
	UpdateMarketingDraft(ctx context.Context, d MarketingDraft, now time.Time) (MarketingDraft, error)
	// DeleteMarketingDraft deletes an unpublished draft. ErrNotFound, or
	// ErrMarketingDraftPublished once it was published.
	DeleteMarketingDraft(ctx context.Context, tenant, id string) error
	// MarkMarketingDraftPublished sets published_at on the first publish
	// (a later one keeps it). ErrNotFound when tenant has no such draft.
	MarkMarketingDraftPublished(ctx context.Context, tenant, id string, now time.Time) error
}

// ErrMarketingDraftPublished: the draft went out, so its text is kept as sent.
var ErrMarketingDraftPublished = errors.New("store: the post is published: it is no longer edited or deleted")

// MarketingSourceDraft is a marketing_posts source of rdb 0274: a draft.
const MarketingSourceDraft = "draft"

// MarketingDraftMaxChars is rdb 0274's body cap (LinkedIn's 3,000).
const MarketingDraftMaxChars = 3000

// MarketingDraft is one post a member of the workspace wrote.
type MarketingDraft struct {
	ID          string               `json:"id"`
	Tenant      string               `json:"tenant_id"`
	AuthorID    string               `json:"author_id"`
	Body        string               `json:"body"`
	ImageURL    string               `json:"image_url"`
	PublishedAt *time.Time           `json:"published_at,omitempty"`
	CreatedAt   time.Time            `json:"created_at"`
	UpdatedAt   time.Time            `json:"updated_at"`
	Posts       []MarketingDraftPost `json:"posts"`
}

// MarketingDraftPost is a draft's publish on one channel: its row's status.
type MarketingDraftPost struct {
	ChannelID      string `json:"channel_id"`
	Status         string `json:"status"`
	PlatformPostID string `json:"platform_post_id,omitempty"`
	LastError      string `json:"last_error,omitempty"`
}

// ---- Postgres ---------------------------------------------------------------

const mktDraftCols = `draft_id::text, tenant_id, author_id, body, image_url, published_at, created_at, updated_at`

func scanMktDraft(r pgx.Row) (MarketingDraft, error) {
	var d MarketingDraft
	err := r.Scan(&d.ID, &d.Tenant, &d.AuthorID, &d.Body, &d.ImageURL, &d.PublishedAt, &d.CreatedAt, &d.UpdatedAt)
	d.Posts = []MarketingDraftPost{}
	return d, err
}

// CreateMarketingDraft implements MarketingDrafts on the Postgres store (rdb 0274).
func (s *Postgres) CreateMarketingDraft(ctx context.Context, d MarketingDraft, now time.Time) (MarketingDraft, error) {
	var out MarketingDraft
	err := s.inTenant(ctx, d.Tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanMktDraft(tx.QueryRow(ctx, `INSERT INTO marketing_drafts (tenant_id, author_id, body, image_url, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $5) RETURNING `+mktDraftCols, d.Tenant, d.AuthorID, d.Body, d.ImageURL, now))
		return err
	})
	return out, err
}

// MarketingDrafts implements MarketingDrafts on the Postgres store (rdb 0274).
func (s *Postgres) MarketingDrafts(ctx context.Context, tenant string) ([]MarketingDraft, error) {
	out := []MarketingDraft{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT `+mktDraftCols+` FROM marketing_drafts WHERE tenant_id = $1
			ORDER BY updated_at DESC, draft_id`, tenant)
		if err != nil {
			return err
		}
		if err := scanRows(rows, func(r pgx.Rows) error {
			d, err := scanMktDraft(r)
			out = append(out, d)
			return err
		}); err != nil {
			return err
		}
		return mktDraftPosts(ctx, tx, tenant, out)
	})
	return out, err
}

// MarketingDraft implements MarketingDrafts on the Postgres store (rdb 0274).
func (s *Postgres) MarketingDraft(ctx context.Context, tenant, id string) (MarketingDraft, error) {
	var out MarketingDraft
	if !isUUID(id) {
		return out, ErrNotFound
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanMktDraft(tx.QueryRow(ctx, `SELECT `+mktDraftCols+` FROM marketing_drafts
			WHERE tenant_id = $1 AND draft_id = $2::uuid`, tenant, id))
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		ds := []MarketingDraft{out}
		err = mktDraftPosts(ctx, tx, tenant, ds)
		out = ds[0]
		return err
	})
	return out, err
}

// mktDraftPosts fills each draft's Posts: its marketing_posts rows.
func mktDraftPosts(ctx context.Context, tx pgx.Tx, tenant string, ds []MarketingDraft) error {
	if len(ds) == 0 {
		return nil
	}
	at := make(map[string]int, len(ds))
	refs := make([]string, len(ds))
	for i, d := range ds {
		at[d.ID], refs[i] = i, d.ID
	}
	rows, err := tx.Query(ctx, `SELECT source_ref, channel_id::text, status, coalesce(platform_post_id, ''), coalesce(last_error, '')
		FROM marketing_posts WHERE tenant_id = $1 AND source_type = 'draft' AND source_ref = ANY($2::text[])
		ORDER BY created_at, channel_id`, tenant, refs)
	if err != nil {
		return err
	}
	return scanRows(rows, func(r pgx.Rows) error {
		var ref string
		var p MarketingDraftPost
		if err := r.Scan(&ref, &p.ChannelID, &p.Status, &p.PlatformPostID, &p.LastError); err != nil {
			return err
		}
		ds[at[ref]].Posts = append(ds[at[ref]].Posts, p)
		return nil
	})
}

// mktDraftUnpublished locks tenant's draft id: ErrNotFound when there is
// none, ErrMarketingDraftPublished when it was published.
func mktDraftUnpublished(ctx context.Context, tx pgx.Tx, tenant, id string) error {
	var published *time.Time
	err := tx.QueryRow(ctx, `SELECT published_at FROM marketing_drafts WHERE tenant_id = $1 AND draft_id = $2::uuid FOR UPDATE`,
		tenant, id).Scan(&published)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return ErrNotFound
	case err != nil:
		return err
	case published != nil:
		return ErrMarketingDraftPublished
	}
	return nil
}

// UpdateMarketingDraft implements MarketingDrafts on the Postgres store (rdb 0274).
func (s *Postgres) UpdateMarketingDraft(ctx context.Context, d MarketingDraft, now time.Time) (MarketingDraft, error) {
	var out MarketingDraft
	if !isUUID(d.ID) {
		return out, ErrNotFound
	}
	err := s.inTenant(ctx, d.Tenant, func(tx pgx.Tx) error {
		if err := mktDraftUnpublished(ctx, tx, d.Tenant, d.ID); err != nil {
			return err
		}
		var err error
		out, err = scanMktDraft(tx.QueryRow(ctx, `UPDATE marketing_drafts SET body = $3, image_url = $4, updated_at = $5
			WHERE tenant_id = $1 AND draft_id = $2::uuid RETURNING `+mktDraftCols, d.Tenant, d.ID, d.Body, d.ImageURL, now))
		return err
	})
	return out, err
}

// DeleteMarketingDraft implements MarketingDrafts on the Postgres store (rdb 0274).
func (s *Postgres) DeleteMarketingDraft(ctx context.Context, tenant, id string) error {
	if !isUUID(id) {
		return ErrNotFound
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if err := mktDraftUnpublished(ctx, tx, tenant, id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `DELETE FROM marketing_drafts WHERE tenant_id = $1 AND draft_id = $2::uuid`, tenant, id)
		return err
	})
}

// MarkMarketingDraftPublished implements MarketingDrafts on the Postgres store (rdb 0274).
func (s *Postgres) MarkMarketingDraftPublished(ctx context.Context, tenant, id string, now time.Time) error {
	if !isUUID(id) {
		return ErrNotFound
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE marketing_drafts SET published_at = coalesce(published_at, $3)
			WHERE tenant_id = $1 AND draft_id = $2::uuid`, tenant, id, now)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}
