package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The signed-in customer of an embed (specs/121 section 5, R3; T205): the
// customer's server vouches for its own user with a short JWT (sub, aud =
// the embed id), the hub verifies it (hub/embed_jwt.go) and maps (embed,
// sub) to ONE channel_guest: the same user on any device finds the same
// channel. No column holds the sub: the visitor's id and channel id are
// derived from (embed, sub), so the mapping needs no table (rdb 0169 as it
// is) and the sub itself, often an address, is stored nowhere.

// EmbedSignIn is the store side of the signed-in path.
type EmbedSignIn interface {
	// SignInEmbedVisitor is (in.EmbedID, sub)'s one visitor with a fresh
	// token (in.TokenHash): made on the first sign-in, its token replaced
	// on every later one (the old token stops working). ErrNotFound when
	// the embed is not an enabled embed of in.TenantID; nothing is written.
	SignInEmbedVisitor(ctx context.Context, in EmbedVisitorMint, sub string, now time.Time) (EmbedVisitor, error)
}

var _ EmbedSignIn = (*Postgres)(nil)

// embedSubNS is the uuid v5 namespace of signed-in visitor ids.
var embedSubNS = uuid.MustParse("6b1f6d2e-3c1a-5e8e-9a57-121c05e2b205")

// embedSubIDs are the visitor id and the channel id of (embed, sub): a uuid
// v5 (gen_random_uuid's anonymous ids are v4, so the two never meet) and
// "v-" plus 16 hex digits, the anonymous channel's shape.
func embedSubIDs(embed, sub string) (visitorID, channelID string) {
	key := embed + "\x00" + sub
	sum := sha256.Sum256([]byte("embed-sub\x00" + key))
	return uuid.NewSHA1(embedSubNS, []byte(key)).String(), "v-" + hex.EncodeToString(sum[:8])
}

// SignInEmbedVisitor runs in ONE transaction under the scope of (embed,
// sub)'s channel, never inTenant (spec 4.2). A later sign-in counts the
// token's life from now: created_at is the token's mint (EmbedTokenLife),
// so a returning signed-in user is never held to the first token's cap.
func (s *Postgres) SignInEmbedVisitor(ctx context.Context, in EmbedVisitorMint, sub string, now time.Time) (EmbedVisitor, error) {
	if sub == "" {
		return EmbedVisitor{}, ErrNotFound
	}
	vid, ch := embedSubIDs(in.EmbedID, sub)
	var v EmbedVisitor
	err := s.inChannel(ctx, in.TenantID, ch, func(tx pgx.Tx) (err error) {
		if err := embedEnabledTx(ctx, tx, in.TenantID, in.EmbedID); err != nil {
			return err
		}
		v, err = scanEmbedVisitor(tx.QueryRow(ctx, `UPDATE embed_visitors SET token_hash = $3, ip_hash = coalesce($4, ip_hash),
			created_at = $5, last_seen_at = $5, expires_at = $6
			WHERE tenant_id = $1 AND visitor_id = $2::uuid
			RETURNING `+pgEmbedVisitorCols, in.TenantID, vid, in.TokenHash, in.IPHash, now, in.Life.expiry(now, now)))
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		v, err = newSignedInVisitorTx(ctx, tx, in, vid, ch, now)
		return err
	})
	return v, err
}

// newSignedInVisitorTx writes MintEmbedVisitor's rows with the derived ids:
// a channel_guest HUM, its membership, the private channel, its
// channel_humans row and the embed_visitors row. Two first sign-ins of one
// sub racing: the loser's insert hits the primary key and the call fails;
// the customer's page signs in again and takes the UPDATE path.
func newSignedInVisitorTx(ctx context.Context, tx pgx.Tx, in EmbedVisitorMint, vid, ch string, now time.Time) (EmbedVisitor, error) {
	var hum string
	if err := tx.QueryRow(ctx, `INSERT INTO humans (kind, display_name, created_at) VALUES ('channel_guest', 'Visitor', $1)
		RETURNING human_id`, now).Scan(&hum); err != nil {
		return EmbedVisitor{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, created_at, admitted_by)
		VALUES ($1, $2, $3, $4, $5)`, in.TenantID, hum, rbac.ChannelGuest, now, "embed:"+in.EmbedID); err != nil {
		return EmbedVisitor{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO channels (tenant_id, channel_id, name, created_by, created_at, is_private)
		VALUES ($1, $2, $2, $3, $4, true)`, in.TenantID, ch, hum, now); err != nil {
		return EmbedVisitor{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO channel_humans (tenant_id, channel_id, human_id, joined_at, added_by)
		VALUES ($1, $2, $3, $4, 'embed')`, in.TenantID, ch, hum, now); err != nil {
		return EmbedVisitor{}, err
	}
	return scanEmbedVisitor(tx.QueryRow(ctx, `INSERT INTO embed_visitors
		(tenant_id, embed_id, visitor_id, token_hash, human_id, channel_id, ip_hash, created_at, last_seen_at, expires_at)
		VALUES ($1, $2, $3::uuid, $4, $5, $6, $7, $8, $8, $9)
		RETURNING `+pgEmbedVisitorCols, in.TenantID, in.EmbedID, vid, in.TokenHash, hum, ch, in.IPHash, now, in.Life.expiry(now, now)))
}
