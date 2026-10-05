package store

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The demo ban list (rdb 0130, specs/077 3.6 "ban", T016 part B). A moderator
// removing a demo_user from the demo workspace bans it: the membership goes
// and the account and address digests of every identity of that human are
// listed, in one transaction. The open demo admission refuses a listed
// identity (ErrDemoBanned) and writes nothing. Keys are digests, never the
// raw account or address, and outlive the human the expiry sweep drops.

// ErrDemoBanned refuses an open demo admission of an identity whose account
// or address a moderator banned from the demo workspace. It WRAPS
// ErrNotAdmitted, so the sign-in lands on auth_error=not_allowed like any
// uninvited one; nothing was written.
var ErrDemoBanned = fmt.Errorf("%w: banned from the demo", ErrNotAdmitted)

// DemoBans is implemented by Memory and Postgres.
type DemoBans interface {
	// BanMember removes humanID's membership of tenant (RemoveMember's
	// guards: ErrNotFound, ErrLastOwner, ErrLastAdmin) and lists the
	// demoBanKeys of every identity of that human in tenant's ban list, by
	// whom, in one transaction.
	BanMember(ctx context.Context, tenant, humanID, by string, now time.Time) error
	// DemoBanned reports whether id's account or address is on tenant's ban
	// list.
	DemoBanned(ctx context.Context, tenant string, id Identity) (bool, error)
}

var (
	_ DemoBans = (*Memory)(nil)
	_ DemoBans = (*Postgres)(nil)
)

// demoMailKey is the ban key of an address: "mail:" sha256 of it lowercased.
func demoMailKey(email string) string {
	return "mail:" + hexDigest(strings.ToLower(strings.TrimSpace(email)))
}

// demoBanKeys are the ban list keys of one identity: its account, and its
// address when it has one.
func demoBanKeys(id Identity) []string {
	keys := []string{demoAccountKey(id)}
	if strings.TrimSpace(id.Email) != "" {
		keys = append(keys, demoMailKey(id.Email))
	}
	return keys
}

// Memory side: a per-store set beside the Memory struct, guarded by s.mu.
var memDemoBans = map[*Memory]map[[2]string]string{} // (tenant, key) -> banned_by

func (s *Memory) BanMember(_ context.Context, tenant, humanID, by string, _ time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.removeMemberLocked(tenant, humanID); err != nil {
		return err
	}
	bans := memDemoBans[s]
	if bans == nil {
		bans = map[[2]string]string{}
		memDemoBans[s] = bans
	}
	for k, i := range s.hum.identities {
		if i.human != humanID {
			continue
		}
		for _, key := range demoBanKeys(Identity{Provider: k[0], Subject: k[1], Email: i.email}) {
			bans[[2]string{tenant, key}] = by
		}
	}
	return nil
}

func (s *Memory) DemoBanned(_ context.Context, tenant string, id Identity) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.demoBannedLocked(tenant, id), nil
}

// demoBannedLocked is DemoBanned with s.mu held (admitToTenant).
func (s *Memory) demoBannedLocked(tenant string, id Identity) bool {
	for _, key := range demoBanKeys(id) {
		if _, ok := memDemoBans[s][[2]string{tenant, key}]; ok {
			return true
		}
	}
	return false
}

// Postgres side.

func (s *Postgres) BanMember(ctx context.Context, tenant, humanID, by string, now time.Time) error {
	defer s.hot.forget() // the door cache holds the membership
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if err := removeMemberTx(ctx, tx, tenant, humanID); err != nil {
			return err
		}
		keys, err := identityBanKeysTx(ctx, tx, humanID)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO demo_bans (tenant_id, key, banned_by, banned_at)
			SELECT $1, k, $3, $4 FROM unnest($2::text[]) AS k
			ON CONFLICT (tenant_id, key) DO NOTHING`, tenant, keys, by, now)
		return err
	})
}

// identityBanKeysTx is the demoBanKeys of every identity of hum, sorted
// (human_identities is hub-wide, readable in a tenant scope).
func identityBanKeysTx(ctx context.Context, tx pgx.Tx, hum string) ([]string, error) {
	rows, err := tx.Query(ctx, `SELECT provider, subject, coalesce(email, '') FROM human_identities WHERE human_id = $1`, hum)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	set := map[string]bool{}
	for rows.Next() {
		var id Identity
		if err := rows.Scan(&id.Provider, &id.Subject, &id.Email); err != nil {
			return nil, err
		}
		for _, k := range demoBanKeys(id) {
			set[k] = true
		}
	}
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys, rows.Err()
}

func (s *Postgres) DemoBanned(ctx context.Context, tenant string, id Identity) (bool, error) {
	var banned bool
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		banned, err = demoBannedTx(ctx, tx, tenant, demoBanKeys(id))
		return err
	})
	return banned, err
}

// demoBannedTx reports whether any of keys is on tenant's ban list.
func demoBannedTx(ctx context.Context, tx pgx.Tx, tenant string, keys []string) (bool, error) {
	var banned bool
	err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM demo_bans WHERE tenant_id = $1 AND key = ANY($2::text[]))`,
		tenant, keys).Scan(&banned)
	return banned, err
}
