package store

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// doorRead is what one view request's door answers for hum: role, channel
// order and channel list, all through a fresh request memo.
func doorRead(t *testing.T, pg *Postgres, tid, hum string) (string, []string, []string, error) {
	t.Helper()
	req := WithMemo(context.Background())
	role, err := pg.MemberRole(req, hum, tid)
	if err != nil {
		return "", nil, nil, err
	}
	order, err := pg.ChannelOrder(req, tid, hum)
	if err != nil {
		t.Fatal(err)
	}
	chans, err := pg.HumanChannels(req, tid, hum)
	if err != nil {
		t.Fatal(err)
	}
	return role, order, chans, nil
}

// TestDoorCacheStalenessBound (DB payload cut 5): the view door's membership
// read is cached per (tenant, human) across requests. A change this store did
// not make - SQL beside it - is served for at most hotCacheTTL, then read
// fresh; a miss (not a member) is never cached; a read without a memo is
// always live. This is also the CONTROL for TestDoorCacheWritersClear: it
// proves the cache serves, so a writer that did not clear it would fail there.
func TestDoorCacheStalenessBound(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	now := time.Now()
	hotNow = func() time.Time { return now }
	t.Cleanup(func() { hotNow = time.Now })
	ctx := context.Background()
	tid := newTenant(t, pg)
	seatMember(t, pg, tid, "biz_owner")
	dev := seatMember(t, pg, tid, "developer")
	outsider := seatMember(t, pg, newTenant(t, pg), "developer")

	if _, _, _, err := doorRead(t, pg, tid, outsider); !errors.Is(err, ErrNotFound) {
		t.Fatalf("outsider: %v", err)
	}
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by)
			VALUES ($1, $2, 'tester', 'operator')`, tid, outsider)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if r, _, _, err := doorRead(t, pg, tid, outsider); err != nil || r != "tester" {
		t.Fatalf("a miss was cached: %q %v", r, err)
	}

	if r, _, _, err := doorRead(t, pg, tid, dev); err != nil || r != "developer" {
		t.Fatalf("dev: %q %v", r, err)
	}
	// Out-of-band demotion: not through this store, so nothing clears.
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE tenant_memberships SET role = 'tester' WHERE tenant_id = $1 AND human_id = $2`, tid, dev)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if r, err := pg.MemberRole(ctx, dev, tid); err != nil || r != "tester" {
		t.Fatalf("CONTROL: a read without a memo must be live: %q %v", r, err)
	}
	now = now.Add(hotCacheTTL - time.Millisecond)
	if r, _, _, _ := doorRead(t, pg, tid, dev); r != "developer" {
		t.Fatalf("within the TTL the cached door is served (the cut, and its bound): %q", r)
	}
	now = now.Add(time.Millisecond)
	if r, _, _, _ := doorRead(t, pg, tid, dev); r != "tester" {
		t.Fatalf("at the TTL an out-of-band demotion must be seen: %q", r)
	}
}

// TestDoorCacheWritersClear (DB payload cut 5): every store writer of what
// the door reads - role, suspension, removal, channel_order, channel_humans,
// a channel's archive state - clears the door cache, so the next view request
// on this instance sees the change at once (the clock never moves here, so a
// writer without the clear serves the old answer and fails).
func TestDoorCacheWritersClear(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	now := time.Now()
	hotNow = func() time.Time { return now }
	t.Cleanup(func() { hotNow = time.Now })
	ctx := context.Background()
	tid := newTenant(t, pg)
	owner := seatMember(t, pg, tid, "biz_owner")
	seatMember(t, pg, tid, "admin")
	dev := seatMember(t, pg, tid, "developer")
	for _, c := range []string{"ops", "qa", "web"} {
		if err := pg.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: c, Name: c, CreatedBy: owner, CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	if err := pg.AddChannelHumans(ctx, tid, "ops", []string{dev}, owner, now); err != nil {
		t.Fatal(err)
	}

	steps := []struct {
		name  string
		write func() error
		check func(role string, order, chans []string, err error) bool
	}{
		{"AddChannelHumans", func() error { return pg.AddChannelHumans(ctx, tid, "qa", []string{dev}, owner, now) },
			func(_ string, _, c []string, _ error) bool { return reflect.DeepEqual(c, []string{"ops", "qa"}) }},
		{"RemoveChannelHuman", func() error { return pg.RemoveChannelHuman(ctx, tid, "qa", dev) },
			func(_ string, _, c []string, _ error) bool { return reflect.DeepEqual(c, []string{"ops"}) }},
		{"ArchiveChannel", func() error { return pg.ArchiveChannel(ctx, tid, "ops", owner, now) },
			func(_ string, _, c []string, _ error) bool { return len(c) == 0 }},
		{"UnarchiveChannel", func() error { return pg.UnarchiveChannel(ctx, tid, "ops") },
			func(_ string, _, c []string, _ error) bool { return reflect.DeepEqual(c, []string{"ops"}) }},
		{"SetChannelOrder", func() error { return pg.SetChannelOrder(ctx, tid, dev, []string{"web", "ops"}) },
			func(_ string, o, _ []string, _ error) bool { return reflect.DeepEqual(o, []string{"web", "ops"}) }},
		{"DeleteChannel", func() error {
			if err := pg.AddChannelHumans(ctx, tid, "web", []string{dev}, owner, now); err != nil {
				return err
			}
			doorRead(t, pg, tid, dev) //nolint:errcheck // warm the cache with web in it
			return pg.DeleteChannel(ctx, tid, "web", owner, now)
		}, func(_ string, _, c []string, _ error) bool { return reflect.DeepEqual(c, []string{"ops"}) }},
		{"SetMemberRole", func() error { return pg.SetMemberRole(ctx, tid, dev, "tester", "") },
			func(r string, _, _ []string, _ error) bool { return r == "tester" }},
		{"SetMemberDisabled", func() error { return pg.SetMemberDisabled(ctx, tid, dev, true, now) },
			func(_ string, _, _ []string, err error) bool { return errors.Is(err, ErrNotFound) }},
		{"SetMemberDisabled restore", func() error { return pg.SetMemberDisabled(ctx, tid, dev, false, now) },
			func(r string, _, _ []string, err error) bool { return err == nil && r == "tester" }},
		{"RemoveMember", func() error { return pg.RemoveMember(ctx, tid, dev) },
			func(_ string, _, _ []string, err error) bool { return errors.Is(err, ErrNotFound) }},
	}
	for _, st := range steps {
		if _, _, _, err := doorRead(t, pg, tid, dev); err != nil && !errors.Is(err, ErrNotFound) { // warm (a miss is never cached)
			t.Fatalf("%s: warm: %v", st.name, err)
		}
		if err := st.write(); err != nil {
			t.Fatalf("%s: %v", st.name, err)
		}
		r, o, c, err := doorRead(t, pg, tid, dev)
		if !st.check(r, o, c, err) {
			t.Fatalf("%s did not clear the door cache: next request read role %q order %v channels %v err %v", st.name, r, o, c, err)
		}
	}
}

// TestDoorCacheRaceGuard: a door read that started before a writer committed
// must not store its answer after that writer cleared the cache.
func TestDoorCacheRaceGuard(t *testing.T) {
	var c hotCache
	gen := c.generation()
	c.forget()
	c.putDoor(gen, "t1", "HUM-1", memberRead{role: "admin"})
	if _, ok := c.door("t1", "HUM-1"); ok {
		t.Fatal("a door read older than a write was cached")
	}
	c.putDoor(c.generation(), "t1", "HUM-1", memberRead{role: "admin", chans: []string{"ops"}})
	v, ok := c.door("t1", "HUM-1")
	if !ok || v.role != "admin" {
		t.Fatal("CONTROL: a current door read was not cached")
	}
	v.chans[0] = "mutated"
	if w, _ := c.door("t1", "HUM-1"); w.chans[0] != "ops" {
		t.Fatal("a caller's slice aliases the cached entry")
	}
	if _, ok := c.door("t2", "HUM-1"); ok {
		t.Fatal("tenant t1's door answered for t2")
	}
}

// TestDoorCacheCloneStopClears (DB payload cut 5): a clone's act-as sign-out
// (StopClone) and its expiry (SweepClones) delete its membership; both clear
// the door cache, so the clone's next view request is refused at once.
func TestDoorCacheCloneStopClears(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	hotNow = func() time.Time { return now }
	t.Cleanup(func() { hotNow = time.Now })
	ctx := context.Background()
	tid := newTenant(t, pg)
	admin := seatMember(t, pg, tid, "admin")
	target := seatMember(t, pg, tid, "developer")
	for _, stop := range []struct {
		name string
		run  func(clone string) error
	}{
		{"StopClone", func(clone string) error { return pg.StopClone(ctx, tid, clone, "stop", now) }},
		{"SweepClones", func(string) error { _, err := pg.SweepClones(ctx, now.Add(2*time.Hour)); return err }},
	} {
		cl, err := pg.StartClone(ctx, CloneStart{TenantID: tid, TargetHum: target, AdminName: "Admin", CreatedBy: admin,
			ExpiresAt: now.Add(time.Hour)}, now)
		if err != nil {
			t.Fatal(err)
		}
		if r, _, _, err := doorRead(t, pg, tid, cl.CloneHum); err != nil || r != "developer" {
			t.Fatalf("%s: clone door %q %v", stop.name, r, err)
		}
		if err := stop.run(cl.CloneHum); err != nil {
			t.Fatalf("%s: %v", stop.name, err)
		}
		if _, _, _, err := doorRead(t, pg, tid, cl.CloneHum); !errors.Is(err, ErrNotFound) {
			t.Fatalf("%s did not clear the door cache: the stopped clone still reads (%v)", stop.name, err)
		}
	}
}
