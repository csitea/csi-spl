package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The visitor of an embed (rdb 0169, specs/121 4.1): an anonymous website
// visitor holding a bearer token, one channel_guest HUM and one channel.
// Every statement of a visitor request runs under inChannel, never inTenant;
// TestEmbedVisitorPathNeverInTenant reads the call graph of embedVisitorPath.

// EmbedVisitor is one embed_visitors row. The token itself is never stored:
// only its sha256 (token_hash), which the hub computes from the bearer.
type EmbedVisitor struct {
	TenantID   string
	EmbedID    string
	VisitorID  string
	HumanID    string
	ChannelID  string
	Email      string // "" = no relink address
	CreatedAt  time.Time
	LastSeenAt time.Time
	ExpiresAt  time.Time
}

// EmbedTokenLife is the token's lifetime (cnf env.hub.embed, spec 4.1):
// Sliding from the last request (30 d), never past Cap after the mint (180 d).
type EmbedTokenLife struct {
	Sliding time.Duration
	Cap     time.Duration
}

// expiry is when a token last seen at seen, minted at created, expires.
func (l EmbedTokenLife) expiry(created, seen time.Time) time.Time {
	exp := seen.Add(l.Sliding)
	if hard := created.Add(l.Cap); hard.Before(exp) {
		exp = hard
	}
	return exp
}

// EmbedVisitorMint is what the hub hands the store for a new visitor.
// TokenHash is the sha256 of the 256-bit bearer token (32 bytes); IPHash the
// salted sha256 of the address, or nil.
type EmbedVisitorMint struct {
	TenantID  string
	EmbedID   string
	TokenHash []byte
	IPHash    []byte
	Life      EmbedTokenLife
}

// embedVisitorPath is every store method a visitor request reaches (spec
// 4.2: never inTenant). TestEmbedVisitorPathNeverInTenant walks their calls.
var embedVisitorPath = []string{"EmbedCustomer", "EmbedVisitorByToken", "MintEmbedVisitor", "SlideEmbedVisitor", "ExpireEmbedVisitor"}

// newVisitorChannelID is a fresh visitor channel id: "v-" and 16 random hex
// digits, a valid channel slug that no default or reserved id can match.
func newVisitorChannelID() (string, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "v-" + hex.EncodeToString(b), nil
}

const pgEmbedVisitorCols = `tenant_id, embed_id, visitor_id::text, human_id, channel_id, coalesce(email, ''),
	created_at, last_seen_at, expires_at`

func scanEmbedVisitor(r pgx.Row) (EmbedVisitor, error) {
	var v EmbedVisitor
	err := r.Scan(&v.TenantID, &v.EmbedID, &v.VisitorID, &v.HumanID, &v.ChannelID, &v.Email, &v.CreatedAt, &v.LastSeenAt, &v.ExpiresAt)
	return v, err
}

// MintEmbedVisitor makes a visitor of an enabled embed in ONE transaction
// under the scope of its new channel (spec 4.1): a channel_guest HUM (no
// e-mail, no password, no identity), its tenant membership with the system
// role channel_guest, a new private channel the HUM created, its
// channel_humans row and the embed_visitors row. ErrNotFound when the embed
// is not an enabled embed of the tenant; nothing is written then.
func (s *Postgres) MintEmbedVisitor(ctx context.Context, in EmbedVisitorMint, now time.Time) (EmbedVisitor, error) {
	ch, err := newVisitorChannelID()
	if err != nil {
		return EmbedVisitor{}, err
	}
	var v EmbedVisitor
	err = s.inChannel(ctx, in.TenantID, ch, func(tx pgx.Tx) error {
		if err := embedEnabledTx(ctx, tx, in.TenantID, in.EmbedID); err != nil {
			return err
		}
		var hum string
		if err := tx.QueryRow(ctx, `INSERT INTO humans (kind, display_name, created_at) VALUES ('channel_guest', 'Visitor', $1)
			RETURNING human_id`, now).Scan(&hum); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, created_at, admitted_by)
			VALUES ($1, $2, $3, $4, $5)`, in.TenantID, hum, rbac.ChannelGuest, now, "embed:"+in.EmbedID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO channels (tenant_id, channel_id, name, created_by, created_at, is_private)
			VALUES ($1, $2, $2, $3, $4, true)`, in.TenantID, ch, hum, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO channel_humans (tenant_id, channel_id, human_id, joined_at, added_by)
			VALUES ($1, $2, $3, $4, 'embed')`, in.TenantID, ch, hum, now); err != nil {
			return err
		}
		v, err = scanEmbedVisitor(tx.QueryRow(ctx, `INSERT INTO embed_visitors
			(tenant_id, embed_id, visitor_id, token_hash, human_id, channel_id, ip_hash, created_at, last_seen_at, expires_at)
			VALUES ($1, $2, gen_random_uuid(), $3, $4, $5, $6, $7, $7, $8)
			RETURNING `+pgEmbedVisitorCols, in.TenantID, in.EmbedID, in.TokenHash, hum, ch, in.IPHash, now, in.Life.expiry(now, now)))
		return err
	})
	return v, err
}

// EmbedVisitorByToken names the visitor a bearer token belongs to: the live
// visitor (not expired at now) of embed whose token hashes to tokenHash,
// while the embed is enabled. The token names no workspace and no channel
// until this row is read, so it is one operator read keyed by the 256-bit
// token's hash and the embed id; every later statement of the request runs
// under inChannel of the row it returns. ErrNotFound otherwise.
func (s *Postgres) EmbedVisitorByToken(ctx context.Context, embedID string, tokenHash []byte, now time.Time) (EmbedVisitor, error) {
	var v EmbedVisitor
	found := false
	err := s.asOperatorQuery(ctx, `SELECT `+pgEmbedVisitorCols+` FROM embed_visitors v
		WHERE v.embed_id = $1 AND v.token_hash = $2 AND v.expires_at > $3
		  AND EXISTS (SELECT 1 FROM embed_customers c WHERE c.tenant_id = v.tenant_id AND c.embed_id = v.embed_id AND c.enabled)`,
		[]any{embedID, tokenHash, now}, func(r pgx.Rows) (err error) {
			v, err = scanEmbedVisitor(r)
			found = err == nil
			return err
		})
	if err == nil && !found {
		err = ErrNotFound
	}
	return v, err
}

// SlideEmbedVisitor marks v seen at now and slides its expiry (life.Sliding
// from now, never past life.Cap after the mint), under v's channel scope.
// ErrNotFound when v has expired already: an expired token never revives.
func (s *Postgres) SlideEmbedVisitor(ctx context.Context, v EmbedVisitor, life EmbedTokenLife, now time.Time) (EmbedVisitor, error) {
	var out EmbedVisitor
	err := s.inChannel(ctx, v.TenantID, v.ChannelID, func(tx pgx.Tx) (err error) {
		out, err = scanEmbedVisitor(tx.QueryRow(ctx, `UPDATE embed_visitors SET last_seen_at = $3,
			expires_at = LEAST($3 + make_interval(secs => $4), created_at + make_interval(secs => $5))
			WHERE tenant_id = $1 AND visitor_id = $2::uuid AND expires_at > $3
			RETURNING `+pgEmbedVisitorCols, v.TenantID, v.VisitorID, now, life.Sliding.Seconds(), life.Cap.Seconds()))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		err = ErrNotFound
	}
	return out, err
}

// ExpireEmbedVisitor ends v's token at now (sign-out, a relink that replaces
// it), under v's channel scope. The channel and its messages stay until
// retention (spec 4.4). Expiring an expired token is a no-op.
func (s *Postgres) ExpireEmbedVisitor(ctx context.Context, v EmbedVisitor, now time.Time) error {
	return s.inChannel(ctx, v.TenantID, v.ChannelID, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE embed_visitors SET expires_at = $3
			WHERE tenant_id = $1 AND visitor_id = $2::uuid AND expires_at > $3`, v.TenantID, v.VisitorID, now)
		return err
	})
}
