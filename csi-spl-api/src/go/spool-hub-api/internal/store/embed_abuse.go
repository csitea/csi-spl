package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// The abuse side of the embed (specs/121 section 6, T105): the per-IP and
// per-visitor counters in quota_counts (rdb 0127), the bans in demo_bans
// (rdb 0130), the live-visitor count of an embed and the token sweep. Every
// statement names its workspace: a visitor's runs under inChannel of its
// channel; one before the mint (no channel yet) in the operator scope with
// tenant_id in every WHERE (embedScope). Never inTenant (embedVisitorPath).

// EmbedScope is where an embed abuse statement runs: the visitor's channel,
// or ChannelID "" before the mint, when the visitor has none yet.
type EmbedScope struct {
	TenantID  string
	ChannelID string
}

// EmbedTake is one counter unit to take: Key is the quota_counts human_id (a
// visitor's HUM id, or EmbedIPKey), Kind one of the embed_* kinds.
type EmbedTake struct {
	Key    string
	Kind   string
	Window time.Time
	Limit  int
}

// EmbedSweep is what one SweepEmbed did.
type EmbedSweep struct {
	Tokens int // expired visitor tokens retired, their ip_hash cleared
	Counts int // stale embed_* counter rows dropped
	Bans   int // lapsed automatic bans dropped
}

// EmbedAutoBanBy is demo_bans.banned_by of a ban the hub set itself (a
// repeat offender): it lapses after the hub's ban time. Any other ban (an
// owner's) holds until it is lifted.
const EmbedAutoBanBy = "embed-abuse"

// EmbedQuotaKindPrefix: every embed counter kind starts with it (SweepEmbed).
const EmbedQuotaKindPrefix = "embed_"

// EmbedAbuse is implemented by Postgres only, like EmbedVisitors.
type EmbedAbuse interface {
	// EmbedLiveVisitors counts the unexpired visitors of embed at now.
	EmbedLiveVisitors(ctx context.Context, tenant, embedID string, now time.Time) (int, error)
	// EmbedBanned reports whether any of keys is banned in sc's workspace:
	// an owner's ban always, an automatic one only when set after autoSince.
	EmbedBanned(ctx context.Context, sc EmbedScope, keys []string, autoSince time.Time) (bool, error)
	// TakeEmbedQuotas takes one unit of each take, all or none, in one
	// transaction: refused is the index of the first full counter (nothing
	// written then), -1 when every unit was taken.
	TakeEmbedQuotas(ctx context.Context, sc EmbedScope, takes []EmbedTake) (refused int, err error)
	// EmbedHit records one limit hit of key in now's hour and returns the
	// hits of key in the hours from since's on, this one included.
	EmbedHit(ctx context.Context, sc EmbedScope, key string, now, since time.Time) (int, error)
	// EmbedHits is EmbedHit's count without recording a hit.
	EmbedHits(ctx context.Context, sc EmbedScope, key string, since time.Time) (int, error)
	// BanEmbedKey bans key in sc's workspace, by by, at now. A repeat ban by
	// the same by restarts its time; an existing ban by another is kept.
	BanEmbedKey(ctx context.Context, sc EmbedScope, key, by string, now time.Time) error
	// EmbedVisitorPosted reports whether v has posted in its channel yet.
	EmbedVisitorPosted(ctx context.Context, v EmbedVisitor) (bool, error)
	// SweepEmbed retires every visitor token expired at now, drops embed
	// counters older than countsBefore and automatic bans set at or before
	// bansBefore, in every workspace.
	SweepEmbed(ctx context.Context, now, countsBefore, bansBefore time.Time) (EmbedSweep, error)
}

var _ EmbedAbuse = (*Postgres)(nil)

// EmbedIPKey is the counter key of a salted client address hash.
func EmbedIPKey(ipHash []byte) string { return "ip:" + hex.EncodeToString(ipHash) }

// EmbedBanKey is the demo_bans key of a visitor (what "visitor", id its
// visitor_id) or an address (what "ip", id its hex ip_hash). rdb 0130 keys
// are digests in the account form; the "embed-<what>|" namespace inside the
// digest keeps them apart from any account's key.
func EmbedBanKey(what, id string) string {
	sum := sha256.Sum256([]byte("embed-" + what + "|" + id))
	return "acct:" + hex.EncodeToString(sum[:])
}

// embedScope runs fn in sc: under inChannel of the visitor's channel, or,
// before the mint, in the operator scope, where every statement names
// sc.TenantID itself.
func (s *Postgres) embedScope(ctx context.Context, sc EmbedScope, fn func(pgx.Tx) error) error {
	if err := checkTenant(sc.TenantID); err != nil {
		return err
	}
	if sc.ChannelID != "" {
		return s.inChannel(ctx, sc.TenantID, sc.ChannelID, fn)
	}
	return s.asOperator(ctx, fn)
}

func (s *Postgres) EmbedLiveVisitors(ctx context.Context, tenant, embedID string, now time.Time) (int, error) {
	var n int
	err := s.embedScope(ctx, EmbedScope{TenantID: tenant}, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM embed_visitors
			WHERE tenant_id = $1 AND embed_id = $2 AND expires_at > $3`, tenant, embedID, now).Scan(&n)
	})
	return n, err
}

func (s *Postgres) EmbedBanned(ctx context.Context, sc EmbedScope, keys []string, autoSince time.Time) (bool, error) {
	var banned bool
	err := s.embedScope(ctx, sc, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM demo_bans
			WHERE tenant_id = $1 AND key = ANY($2::text[]) AND (banned_by <> $3 OR banned_at > $4))`,
			sc.TenantID, keys, EmbedAutoBanBy, autoSince).Scan(&banned)
	})
	return banned, err
}

// errEmbedRefused rolls TakeEmbedQuotas back when one counter is full.
var errEmbedRefused = errors.New("embed quota refused")

func (s *Postgres) TakeEmbedQuotas(ctx context.Context, sc EmbedScope, takes []EmbedTake) (int, error) {
	for i, q := range takes {
		if err := checkQuota(sc.TenantID, q.Key, q.Kind); err != nil {
			return -1, err
		}
		if q.Limit < 1 { // never unlimited, and refused before any write
			return i, nil
		}
	}
	refused := -1
	err := s.embedScope(ctx, sc, func(tx pgx.Tx) error {
		for i, q := range takes {
			var n int
			err := tx.QueryRow(ctx, takeQuotaSQL, sc.TenantID, q.Key, q.Kind, q.Window.UTC(), q.Limit).Scan(&n)
			if errors.Is(err, pgx.ErrNoRows) {
				refused = i
				return errEmbedRefused
			}
			if err != nil {
				return err
			}
		}
		return nil
	})
	if errors.Is(err, errEmbedRefused) {
		err = nil
	}
	return refused, err
}

// embedHitKind is the quota_counts kind of a limit hit, one row an hour.
const embedHitKind = "embed_hit"

// embedHitsSQL sums key's hits in the hours from $3 on.
const embedHitsSQL = `SELECT coalesce(sum(n), 0)::int FROM quota_counts
	WHERE tenant_id = $1 AND human_id = $2 AND kind = '` + embedHitKind + `' AND window_start >= $3`

func (s *Postgres) EmbedHit(ctx context.Context, sc EmbedScope, key string, now, since time.Time) (int, error) {
	if err := checkQuota(sc.TenantID, key, embedHitKind); err != nil {
		return 0, err
	}
	var n int
	err := s.embedScope(ctx, sc, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO quota_counts (tenant_id, human_id, kind, window_start, n)
			VALUES ($1, $2, $3, $4, 1) ON CONFLICT (tenant_id, human_id, kind, window_start)
			DO UPDATE SET n = quota_counts.n + 1`, sc.TenantID, key, embedHitKind, now.UTC().Truncate(time.Hour)); err != nil {
			return err
		}
		return tx.QueryRow(ctx, embedHitsSQL, sc.TenantID, key, since.UTC().Truncate(time.Hour)).Scan(&n)
	})
	return n, err
}

func (s *Postgres) EmbedHits(ctx context.Context, sc EmbedScope, key string, since time.Time) (int, error) {
	var n int
	err := s.embedScope(ctx, sc, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, embedHitsSQL, sc.TenantID, key, since.UTC().Truncate(time.Hour)).Scan(&n)
	})
	return n, err
}

func (s *Postgres) BanEmbedKey(ctx context.Context, sc EmbedScope, key, by string, now time.Time) error {
	if by == "" {
		return fmt.Errorf("embed ban: by is required")
	}
	return s.embedScope(ctx, sc, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO demo_bans (tenant_id, key, banned_by, banned_at) VALUES ($1, $2, $3, $4)
			ON CONFLICT (tenant_id, key) DO UPDATE SET banned_at = EXCLUDED.banned_at
			WHERE demo_bans.banned_by = EXCLUDED.banned_by`, sc.TenantID, key, by, now)
		return err
	})
}

func (s *Postgres) EmbedVisitorPosted(ctx context.Context, v EmbedVisitor) (bool, error) {
	var posted bool
	err := s.inChannel(ctx, v.TenantID, v.ChannelID, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM messages
			WHERE tenant_id = $1 AND channel = $2 AND from_id = $3)`, v.TenantID, v.ChannelID, v.HumanID).Scan(&posted)
	})
	return posted, err
}

// SweepEmbed runs in the operator scope (TestOperatorScopeCallers): the
// sweeper goroutine sweeps every workspace; no route reaches it. An expired
// token is retired for good: its stored hash is hashed once more, so no
// bearer can match it again even if its expiry were ever moved, and its
// ip_hash (personal data, spec 4.3) is cleared, which also marks it swept.
// The channel stays until retention (spec 4.4).
func (s *Postgres) SweepEmbed(ctx context.Context, now, countsBefore, bansBefore time.Time) (EmbedSweep, error) {
	var out EmbedSweep
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		out = EmbedSweep{}
		tag, err := tx.Exec(ctx, `UPDATE embed_visitors SET token_hash = sha256(token_hash), ip_hash = NULL
			WHERE expires_at <= $1 AND ip_hash IS NOT NULL`, now)
		if err != nil {
			return err
		}
		out.Tokens = int(tag.RowsAffected())
		if tag, err = tx.Exec(ctx, `DELETE FROM quota_counts WHERE starts_with(kind, $1) AND window_start < $2`,
			EmbedQuotaKindPrefix, countsBefore); err != nil {
			return err
		}
		out.Counts = int(tag.RowsAffected())
		if tag, err = tx.Exec(ctx, `DELETE FROM demo_bans WHERE banned_by = $1 AND banned_at <= $2`,
			EmbedAutoBanBy, bansBefore); err != nil {
			return err
		}
		out.Bans = int(tag.RowsAffected())
		return nil
	})
	return out, err
}
