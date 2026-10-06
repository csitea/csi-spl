package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// TestMemberRoleLapsesAtAccessUntil (Memory, its clock seam): one tick before
// access_until the member holds the role; at it and one tick after, MemberRole
// answers ErrNotFound. No sleep and no back-dated row: the store's clock is
// stepped across the instant. CONTROL: the "before" read is the same member
// and the same access_until, so the later ErrNotFound is the clock, not the row.
func TestMemberRoleLapsesAtAccessUntil(t *testing.T) {
	ctx := context.Background()
	m := NewMemory()
	tid := newTenant(t, m)
	guest := admitAs(t, m, tid, rbac.Developer)
	until := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)
	if err := m.SetMemberAccessUntil(ctx, tid, guest, &until); err != nil {
		t.Fatal(err)
	}
	at := until.Add(-time.Nanosecond)
	m.clock = func() time.Time { return at }
	if r, err := m.MemberRole(ctx, guest, tid); err != nil || r != rbac.Developer {
		t.Fatalf("one tick before access_until: %q %v, want %q", r, err, rbac.Developer)
	}
	for _, at = range []time.Time{until, until.Add(time.Nanosecond)} {
		if r, err := m.MemberRole(ctx, guest, tid); !errors.Is(err, ErrNotFound) {
			t.Fatalf("at %s (access_until %s): %q %v, want ErrNotFound", at, until, r, err)
		}
	}
}

// TestOperatorTenantCacheTTL (Postgres only, its clock seam): OperatorTenant
// trusts its cached answer for operatorTTL, then reads the flag again. The
// flag is moved past the store (as another hub instance would), so only a
// re-query can see it. CONTROL: one tick before the TTL the stale cached
// answer is still served, so the fresh one after is the TTL, not the move.
func TestOperatorTenantCacheTTL(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	clearOperatorFlag(t, pg)
	t.Cleanup(func() { clearOperatorFlag(t, pg) })
	a, b := newTenant(t, pg), newTenant(t, pg)
	t0 := time.Now()
	at := t0
	pg.clock = func() time.Time { return at }
	if id, err := pg.ClaimOperatorTenant(ctx, a); err != nil || id != a {
		t.Fatalf("claim: %q %v, want %q", id, err, a)
	}
	if id, err := pg.OperatorTenant(ctx); err != nil || id != a {
		t.Fatalf("first read: %q %v, want %q", id, err, a)
	}
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE tenants SET is_operator = false WHERE is_operator`); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE tenants SET is_operator = true WHERE tenant_id = $1`, b)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	at = t0.Add(operatorTTL - time.Nanosecond)
	if id, err := pg.OperatorTenant(ctx); err != nil || id != a {
		t.Fatalf("inside the TTL: %q %v, want the cached %q", id, err, a)
	}
	at = t0.Add(operatorTTL)
	if id, err := pg.OperatorTenant(ctx); err != nil || id != b {
		t.Fatalf("at the TTL: %q %v, want the re-read %q", id, err, b)
	}
}

// TestMembershipsLapseAtTheStoreClock (Memory, its clock seam): Memberships
// lists a member one tick before access_until and drops it at access_until,
// read off the store's clock. CONTROL: the same member, the same row; only
// the clock moves, so the drop is the clock, not the row.
func TestMembershipsLapseAtTheStoreClock(t *testing.T) {
	ctx := context.Background()
	m := NewMemory()
	tid := newTenant(t, m)
	guest := admitAs(t, m, tid, rbac.Developer)
	until := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)
	if err := m.SetMemberAccessUntil(ctx, tid, guest, &until); err != nil {
		t.Fatal(err)
	}
	at := until.Add(-time.Nanosecond)
	m.clock = func() time.Time { return at }
	if ms, err := m.Memberships(ctx, guest); err != nil || len(ms) != 1 || ms[0].TenantID != tid {
		t.Fatalf("one tick before access_until: %+v %v, want the one membership of %s", ms, err, tid)
	}
	at = until
	if ms, err := m.Memberships(ctx, guest); err != nil || len(ms) != 0 {
		t.Fatalf("at access_until %s: %+v %v, want none", until, ms, err)
	}
}

// TestCreateTenantSeedsChannelsAtTheStoreClock (Memory): the default channel
// rows CreateTenant seeds carry the store's clock as created_at.
func TestCreateTenantSeedsChannelsAtTheStoreClock(t *testing.T) {
	m := NewMemory()
	at := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
	m.clock = func() time.Time { return at }
	tid := newTenant(t, m)
	for _, d := range DefaultChannels {
		c, err := m.Channel(context.Background(), tid, d)
		if err != nil || !c.CreatedAt.Equal(at) {
			t.Fatalf("default channel %s: created_at %s %v, want the store clock %s", d, c.CreatedAt, err, at)
		}
	}
}

// TestCatalogueProbesRecheckOnTheStoreClock (Postgres, no database: the probe's
// check stands in for the catalogue): the access_until (rdb 0113) and calendar
// (rdb 0125) probes re-look a miss only seatsRecheck past the last lookup, on
// the store's clock. CONTROL: one tick before the recheck no lookup is made.
func TestCatalogueProbesRecheckOnTheStoreClock(t *testing.T) {
	ctx := context.Background()
	t0 := time.Now()
	at := t0
	pg := &Postgres{clock: func() time.Time { return at }}
	var lookups int
	miss := func(context.Context) (bool, error) { lookups++; return false, nil }
	pg.access.check, pg.cal.check = miss, miss
	for name, probe := range map[string]func(context.Context) bool{
		"access_until": pg.hasAccessUntil, "calendar": pg.hasCalendar,
	} {
		lookups, at = 0, t0
		probe(ctx)
		at = t0.Add(seatsRecheck - time.Nanosecond)
		probe(ctx)
		if lookups != 1 {
			t.Fatalf("%s: one tick before the recheck: %d lookups, want 1", name, lookups)
		}
		at = t0.Add(seatsRecheck)
		probe(ctx)
		if lookups != 2 {
			t.Fatalf("%s: at the recheck on the store clock: %d lookups, want 2", name, lookups)
		}
	}
}
