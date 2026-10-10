package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The e-mail relink of an embed visitor (specs/121 4.1, T206): the visitor
// may leave an e-mail; from a new device the hub mails a 15-minute link that
// binds a NEW token to the same visitor. The link is not stored: it is keyed
// by the visitor's current token_hash (hub/embed_relink.go), and the relink
// replaces that hash, so a used link no longer verifies. The address is
// shown to the workspace owner only (EmbedVisitorEmails, an owner route).

// EmbedRelinks is the store side of the relink routes; only Postgres
// implements it, as EmbedVisitors.
type EmbedRelinks interface {
	SetEmbedVisitorEmail(ctx context.Context, v EmbedVisitor, email string, now time.Time) error
	EmbedRelinkVisitor(ctx context.Context, embedID string, by EmbedRelinkKey, now time.Time) (EmbedVisitor, []byte, error)
	RelinkEmbedVisitor(ctx context.Context, v EmbedVisitor, oldHash, newHash []byte, life EmbedTokenLife, now time.Time) (EmbedVisitor, error)
	EmbedVisitorEmails(ctx context.Context, tenant, embedID string) ([]EmbedVisitorEmail, error)
}

var _ EmbedRelinks = (*Postgres)(nil)

// embedRelinkPath is every relink method a VISITOR request reaches (no
// session): never inTenant, as embedVisitorPath (TestEmbedRelinkPathNeverInTenant).
// EmbedVisitorEmails is the owner's, a staff read, and is not on it.
var embedRelinkPath = []string{"SetEmbedVisitorEmail", "EmbedRelinkVisitor", "RelinkEmbedVisitor"}

// EmbedRelinkKey names the visitor of a relink: by its e-mail (the request
// from a new device) or by its id (the link). Exactly one is set.
type EmbedRelinkKey struct {
	Email     string
	VisitorID string
}

// EmbedVisitorEmail is one visitor with a relink address, as the workspace
// owner sees it.
type EmbedVisitorEmail struct {
	VisitorID  string
	ChannelID  string
	Email      string
	LastSeenAt time.Time
}

// SetEmbedVisitorEmail sets v's relink address ("" clears it), under v's
// channel scope. ErrNotFound when v's token has expired. The caller
// normalises the address (lower case, <= 320 bytes: rdb 0169's check).
func (s *Postgres) SetEmbedVisitorEmail(ctx context.Context, v EmbedVisitor, email string, now time.Time) error {
	var n int64
	err := s.inChannel(ctx, v.TenantID, v.ChannelID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE embed_visitors SET email = NULLIF($3, '')
			WHERE tenant_id = $1 AND visitor_id = $2::uuid AND expires_at > $4`, v.TenantID, v.VisitorID, email, now)
		n = tag.RowsAffected()
		return err
	})
	if err == nil && n == 0 {
		err = ErrNotFound
	}
	return err
}

// EmbedRelinkVisitor is the live visitor (token not expired at now) of
// embedID, an enabled embed, that by names, with its current token_hash: the
// most recently seen one when several visitors left the same address. The
// request names no workspace and no channel until this row is read, so it is
// one operator read keyed by the embed id and the address or the visitor id
// (operatorCallers). ErrNotFound otherwise, and when by names neither or both.
func (s *Postgres) EmbedRelinkVisitor(ctx context.Context, embedID string, by EmbedRelinkKey, now time.Time) (EmbedVisitor, []byte, error) {
	if (by.Email == "") == (by.VisitorID == "") {
		return EmbedVisitor{}, nil, ErrNotFound
	}
	var v EmbedVisitor
	var hash []byte
	found := false
	err := s.asOperatorQuery(ctx, `SELECT `+pgEmbedVisitorCols+`, token_hash FROM embed_visitors v
		WHERE v.embed_id = $1 AND v.expires_at > $2
		  AND ($3::text = '' OR v.email = $3) AND ($4::text = '' OR v.visitor_id::text = $4)
		  AND EXISTS (SELECT 1 FROM embed_customers c WHERE c.tenant_id = v.tenant_id AND c.embed_id = v.embed_id AND c.enabled)
		ORDER BY v.last_seen_at DESC LIMIT 1`,
		[]any{embedID, now, by.Email, by.VisitorID}, func(r pgx.Rows) error {
			found = true
			return r.Scan(&v.TenantID, &v.EmbedID, &v.VisitorID, &v.HumanID, &v.ChannelID, &v.Email,
				&v.CreatedAt, &v.LastSeenAt, &v.ExpiresAt, &hash)
		})
	if err == nil && !found {
		err = ErrNotFound
	}
	return v, hash, err
}

// RelinkEmbedVisitor binds newHash to v in place of oldHash, marks v seen at
// now and slides its expiry (never past life.Cap after the mint), under v's
// channel scope. The swap is one compare-and-set on oldHash: of two uses of
// the same link one wins, and the other, like any later use, gets
// ErrNotFound. An expired visitor (a block, the sweep) never revives.
func (s *Postgres) RelinkEmbedVisitor(ctx context.Context, v EmbedVisitor, oldHash, newHash []byte, life EmbedTokenLife, now time.Time) (EmbedVisitor, error) {
	var out EmbedVisitor
	err := s.inChannel(ctx, v.TenantID, v.ChannelID, func(tx pgx.Tx) (err error) {
		out, err = scanEmbedVisitor(tx.QueryRow(ctx, `UPDATE embed_visitors SET token_hash = $4, last_seen_at = $5,
			expires_at = LEAST($5 + make_interval(secs => $6), created_at + make_interval(secs => $7))
			WHERE tenant_id = $1 AND visitor_id = $2::uuid AND token_hash = $3 AND expires_at > $5
			RETURNING `+pgEmbedVisitorCols, v.TenantID, v.VisitorID, oldHash, newHash, now, life.Sliding.Seconds(), life.Cap.Seconds()))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		err = ErrNotFound
	}
	return out, err
}

// EmbedVisitorEmails lists the visitors of tenant's embedID that left a
// relink address, newest seen first: a staff read in the workspace scope,
// for the owner route only (hub/embed_relink.go checks the owner).
func (s *Postgres) EmbedVisitorEmails(ctx context.Context, tenant, embedID string) ([]EmbedVisitorEmail, error) {
	out := []EmbedVisitorEmail{}
	err := s.queryTenant(ctx, tenant, `SELECT visitor_id::text, channel_id, email, last_seen_at FROM embed_visitors
		WHERE tenant_id = $1 AND embed_id = $2 AND email IS NOT NULL
		ORDER BY last_seen_at DESC, visitor_id LIMIT 1000`, []any{tenant, embedID}, func(r pgx.Rows) error {
		var e EmbedVisitorEmail
		if err := r.Scan(&e.VisitorID, &e.ChannelID, &e.Email, &e.LastSeenAt); err != nil {
			return err
		}
		out = append(out, e)
		return nil
	})
	return out, err
}
