package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 164 B1 (SPL-4438): the channel box pins store, rdb 0246. The
// contract runs on Memory and Postgres (drivers); the RLS case is Postgres
// only and reads through the hub's runtime login (SPOOL_TEST_PG_RUNTIME_DSN,
// hub-pg.tst.sh). crosstenant_test.go seeds the table per tenant.

// cbpSeed makes a tenant with channel ch and the pinned boxes box-a, box-b
// and box-old (revoked).
func cbpSeed(t *testing.T, s Store) (tenant, ch string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC()
	tenant, ch = newTenant(t, s), uid("ch-")
	if err := s.CreateChannel(ctx, Channel{TenantID: tenant, ChannelID: ch, Name: ch, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	for _, b := range []string{"box-a", "box-b", "box-old"} {
		if err := s.PutPin(ctx, tenant, b, pubkey(), false, now, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.RevokePin(ctx, tenant, "box-old", now.Add(time.Second), now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	return tenant, ch
}

// TestChannelBoxPinsStore: no row reads as unpinned (nil); a set replaces
// the list, sorted and without duplicates, and [] clears it; an unknown
// channel or a box with no pins row is ErrNotFound and writes nothing; a
// revoked pin's box is kept (the hub refuses it, spec 164 4.1); another
// tenant reads none of it; no tenant and no pinned_by are refused.
func TestChannelBoxPinsStore(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a, ch := cbpSeed(t, s)
			b, chB := cbpSeed(t, s)
			if got, err := s.GetChannelBoxPins(ctx, a, ch); err != nil || got != nil {
				t.Fatalf("unpinned: %v (%v), want nil", got, err)
			}
			if err := s.SetChannelBoxPins(ctx, a, ch, []string{"box-b", "box-a", "box-b"}, "HUM-1"); err != nil {
				t.Fatal(err)
			}
			if got, _ := s.GetChannelBoxPins(ctx, a, ch); !slices.Equal(got, []string{"box-a", "box-b"}) {
				t.Fatalf("pinned: %v, want [box-a box-b]", got)
			}
			for _, bad := range []struct {
				name, ch string
				boxes    []string
			}{{"unknown box", ch, []string{"box-a", "box-none"}}, {"unknown channel", uid("ch-"), []string{"box-a"}},
				{"unknown channel cleared", uid("ch-"), nil}, {"empty box id", ch, []string{""}}} {
				if err := s.SetChannelBoxPins(ctx, a, bad.ch, bad.boxes, "HUM-1"); !errors.Is(err, ErrNotFound) {
					t.Errorf("%s: %v, want ErrNotFound", bad.name, err)
				}
			}
			if got, _ := s.GetChannelBoxPins(ctx, a, ch); !slices.Equal(got, []string{"box-a", "box-b"}) {
				t.Fatalf("a refused set changed the pins: %v", got)
			}
			if err := s.SetChannelBoxPins(ctx, a, ch, []string{"box-old"}, "operator"); err != nil {
				t.Fatalf("a revoked pin's box: %v (the FK keeps its row; the hub refuses it)", err)
			}
			if err := s.SetChannelBoxPins(ctx, b, chB, []string{"box-b"}, "HUM-2"); err != nil {
				t.Fatal(err)
			}
			if got, err := s.GetChannelBoxPins(ctx, b, ch); err != nil || got != nil {
				t.Errorf("B reads A's channel: %v (%v), want nil", got, err)
			}
			list, err := s.ListChannelBoxPins(ctx, a)
			if err != nil || len(list) != 1 || !slices.Equal(list[ch], []string{"box-old"}) {
				t.Fatalf("A's list: %v (%v), want only %s -> [box-old]", list, err, ch)
			}
			if err := s.SetChannelBoxPins(ctx, a, ch, []string{}, ""); err != nil {
				t.Fatal(err)
			}
			if got, _ := s.GetChannelBoxPins(ctx, a, ch); got != nil {
				t.Errorf("cleared: %v, want nil", got)
			}
			if list, _ := s.ListChannelBoxPins(ctx, a); len(list) != 0 {
				t.Errorf("cleared list: %v", list)
			}
			if list, _ := s.ListChannelBoxPins(ctx, b); !slices.Equal(list[chB], []string{"box-b"}) || len(list) != 1 {
				t.Errorf("B's list after A cleared: %v", list)
			}
			if err := s.SetChannelBoxPins(ctx, a, ch, []string{"box-a"}, ""); !errors.Is(err, errChannelBoxPinsBy) {
				t.Errorf("no pinned_by: %v", err)
			}
			if _, err := s.GetChannelBoxPins(ctx, "", ch); !errors.Is(err, ErrNoTenant) {
				t.Errorf("no tenant read: %v", err)
			}
			if err := s.SetChannelBoxPins(ctx, " ", ch, []string{"box-a"}, "HUM-1"); !errors.Is(err, ErrNoTenant) {
				t.Errorf("no tenant write: %v", err)
			}
			if _, err := s.ListChannelBoxPins(ctx, ""); !errors.Is(err, ErrNoTenant) {
				t.Errorf("no tenant list: %v", err)
			}
		})
	}
}

// TestRLSChannelBoxPins (the B1 red control, spec 164 section 8): pins
// written under tenant A read back through the hub's RUNTIME login in A's
// scope as the same rows (a policy on the wrong setting reads 0 and fails
// here); in B's scope, with an empty or no tenant, 0 rows; B cannot write an
// A row (42501); a raw pin of a box with no pins row is the FK error
// (23503). CONTROL: with FORCE lifted (rolled back) the owner reads A's rows
// with no tenant set, so the zeros are the policy's.
func TestRLSChannelBoxPins(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx := context.Background()
	a, ch := cbpSeed(t, pg)
	b, _ := cbpSeed(t, pg)
	if err := pg.SetChannelBoxPins(ctx, a, ch, []string{"box-a", "box-b"}, "HUM-1"); err != nil {
		t.Fatal(err)
	}
	if got, err := rt.GetChannelBoxPins(ctx, a, ch); err != nil || !slices.Equal(got, []string{"box-a", "box-b"}) {
		t.Errorf("runtime login in A's scope: %v (%v), want [box-a box-b]", got, err)
	}
	if got, err := rt.ListChannelBoxPins(ctx, b); err != nil || len(got) != 0 {
		t.Errorf("runtime login in B's scope lists %v (%v), want none", got, err)
	}
	for _, c := range []struct {
		scope string
		want  int
	}{{"tenant:" + b, 0}, {"empty", 0}, {"none", 0}, {"tenant:" + a, 2}} {
		if got := mktCount(t, rt, "channel_box_pins", c.scope, a); got != c.want {
			t.Errorf("runtime login, scope %s reads %d of A's rows, want %d", c.scope, got, c.want)
		}
	}
	insert := `INSERT INTO channel_box_pins (tenant_id, channel_id, box_id, pinned_by) VALUES ($1, $2, $3, 'HUM-1')`
	if _, err := rt.execTenant(ctx, b, insert, a, ch, "box-a"); pgCode(err) != "42501" {
		t.Errorf("an A row written under B's scope: %v (want 42501)", err)
	}
	if _, err := rt.execTenant(ctx, a, insert, a, ch, "box-none"); pgCode(err) != "23503" {
		t.Errorf("a pin of a box with no pins row: %v (want the FK error 23503)", err)
	}
	var lifted int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `ALTER TABLE channel_box_pins NO FORCE ROW LEVEL SECURITY`); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM channel_box_pins WHERE tenant_id = $1`, a).Scan(&lifted); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) || lifted != 2 {
		t.Fatalf("CONTROL: without FORCE the owner read %d of A's rows with no tenant (%v), want 2", lifted, err)
	}
}
