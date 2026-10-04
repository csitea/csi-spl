package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// A membership past its access_until holds no role and leaves the tenant list,
// but stays listed and manageable; a control member keeps their access; the
// lockout guards cover it as they cover a suspension (rdb 0113, spec 072 A27).
func TestMemberAccessUntil(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		h := s.(Humans)
		ma := s.(MemberAccess)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			adm := admitAs(t, h, tid, rbac.Admin)
			guest := admitAs(t, h, tid, rbac.Developer)
			ctl := admitAs(t, h, tid, rbac.Developer)
			later := admitAs(t, h, tid, rbac.Developer)

			past := time.Now().Add(-time.Minute).UTC().Truncate(time.Second)
			future := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)
			if err := ma.SetMemberAccessUntil(ctx, tid, guest, &past); err != nil {
				t.Fatal(err)
			}
			if err := ma.SetMemberAccessUntil(ctx, tid, later, &future); err != nil {
				t.Fatal(err)
			}
			if _, err := h.MemberRole(ctx, guest, tid); !errors.Is(err, ErrNotFound) {
				t.Fatalf("lapsed member still holds a role: %v", err)
			}
			// CONTROLS: no end, and an end still ahead, keep the role.
			for hum, what := range map[string]string{ctl: "no end", later: "future end"} {
				if r, err := h.MemberRole(ctx, hum, tid); err != nil || r != rbac.Developer {
					t.Fatalf("%s member role %q %v", what, r, err)
				}
			}
			ms, err := s.(MembershipLister).Memberships(ctx, guest)
			if err != nil || len(ms) != 0 {
				t.Fatalf("lapsed member still lists the tenant: %v %v", ms, err)
			}
			if r, off, err := s.(TenantSettings).MemberState(ctx, tid, guest); err != nil || r != rbac.Developer || off {
				t.Fatalf("lapsed member state %q %v %v", r, off, err)
			}
			list, err := s.(MemberDirectory).ListMembers(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			got := map[string]time.Time{}
			for _, m := range list {
				got[m.HumanID] = m.AccessUntil
			}
			if !got[guest].Equal(past) || !got[later].Equal(future) || !got[ctl].IsZero() {
				t.Fatalf("directory access_until: %v", got)
			}
			// Clearing restores the role.
			if err := ma.SetMemberAccessUntil(ctx, tid, guest, nil); err != nil {
				t.Fatal(err)
			}
			if r, err := h.MemberRole(ctx, guest, tid); err != nil || r != rbac.Developer {
				t.Fatalf("cleared member role %q %v", r, err)
			}
			// The only member manager cannot be given an end; not a member: ErrNotFound.
			if err := ma.SetMemberAccessUntil(ctx, tid, adm, &future); !errors.Is(err, ErrLastAdmin) {
				t.Fatalf("last admin given an end: %v", err)
			}
			if err := ma.SetMemberAccessUntil(ctx, tid, "HUM-999999999", &future); !errors.Is(err, ErrNotFound) {
				t.Fatalf("non-member: %v", err)
			}
		})
	}
}

// The hub may roll before rdb 0113 reaches its database: with the column
// really gone, the door, the tenant list and the directory still answer, and a
// write of the end is ErrAccessUntilUnavailable, never a 500 (CONTROL: once
// the column is back and the probe re-checks, the write lands).
func TestMemberAccessUntilBeforeMigration(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	tid := newTenant(t, pg)
	admitAs(t, pg, tid, rbac.Admin) // a member manager beside dev
	dev := admitAs(t, pg, tid, rbac.Developer)
	readd := func() {
		_, _ = pg.pool.Exec(ctx, `ALTER TABLE tenant_memberships ADD COLUMN IF NOT EXISTS access_until timestamptz NULL`)
	}
	t.Cleanup(readd)
	if _, err := pg.pool.Exec(ctx, `ALTER TABLE tenant_memberships DROP COLUMN access_until`); err != nil {
		t.Fatal(err)
	}
	pg.access = seatsProbe{}
	pg.hot.forget()
	if r, err := pg.MemberRole(ctx, dev, tid); err != nil || r != rbac.Developer {
		t.Fatalf("MemberRole without the column: %q %v", r, err)
	}
	if ms, err := pg.Memberships(ctx, dev); err != nil || len(ms) != 1 {
		t.Fatalf("Memberships without the column: %v %v", ms, err)
	}
	if list, err := pg.ListMembers(ctx, tid); err != nil || len(list) != 2 {
		t.Fatalf("ListMembers without the column: %v %v", list, err)
	}
	if _, err := pg.ViewRoster(ctx, tid); err != nil {
		t.Fatalf("ViewRoster without the column: %v", err)
	}
	until := time.Now().Add(time.Hour)
	if err := pg.SetMemberAccessUntil(ctx, tid, dev, &until); !errors.Is(err, ErrAccessUntilUnavailable) {
		t.Fatalf("write without the column: %v", err)
	}
	readd()
	pg.access = seatsProbe{}
	if err := pg.SetMemberAccessUntil(ctx, tid, dev, &until); err != nil {
		t.Fatalf("CONTROL write with the column: %v", err)
	}
}
