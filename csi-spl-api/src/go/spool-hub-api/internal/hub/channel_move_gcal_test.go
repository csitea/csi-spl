// SPDX-License-Identifier: AGPL-3.0-only

package hub_test

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal/fakegcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 169 row T7c (SPL-4609): C18's sync-cycle half. A <SRC> member's event
// on the moved channel's topic is mapped in that member's Google Calendar; the
// move runs P1..P4 through the operator endpoint, the lease the pre-P4 delete
// took ends, and one sync cycle runs the In half on that connection. The store
// half is TestApplyChannelMoveC18Google (internal/store). Postgres only
// (moveFixture skips on Memory); no test reaches Google (fakegcal).
//
// The control skips the pre-P4 Google delete in the test's own transport to
// the fake: events.delete answers 204 and never reaches it. The store and the
// hub run as in production, so the control needs no door in either.

// gcalDropDeletes answers every events.delete with 204 while drop is set,
// without passing it on to the fake.
type gcalDropDeletes struct {
	base    http.RoundTripper
	drop    atomic.Bool
	dropped atomic.Int32
}

func (d *gcalDropDeletes) RoundTrip(r *http.Request) (*http.Response, error) {
	if d.drop.Load() && r.Method == http.MethodDelete && strings.Contains(r.URL.Path, "/events/") {
		d.dropped.Add(1)
		return &http.Response{StatusCode: http.StatusNoContent, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{}, Request: r}, nil
	}
	return d.base.RoundTrip(r)
}

// moveGcal is a moveFixture whose hub has Google Calendar on a fake, and a
// <SRC> member whose event on the moved topic the first cycle wrote to Google.
type moveGcal struct {
	*moveFix
	se       *gcalSyncEnv
	rt       *gcalDropDeletes
	hum, cal string
	ev       store.CalendarEvent
	google   string
}

// moveGcalFixture runs on gcalSyncT0, so a claim never takes a connection
// another test left in the shared Postgres (gcal_sync_test.go).
func moveGcalFixture(t *testing.T) *moveGcal {
	t.Helper()
	clock := &gcalClock{t: gcalSyncT0}
	fake := fakegcal.New(t)
	fake.Now = clock.now
	cfg := fake.Config(gcalApp+hub.GcalCallbackPath, gcalTestScopes)
	rt := &gcalDropDeletes{base: cfg.HTTP.Transport}
	cfg.HTTP = &http.Client{Transport: rt}
	google, err := gcal.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k",
		marketing.WithPurpose(hub.GcalPurpose))
	if err != nil {
		t.Fatal(err)
	}
	gc := &hub.GcalConnect{Google: google, Sealer: sealer, CookieName: gcalCookie}
	buf := &syncBuf{}
	f := moveFixture(t, true, func(o *hub.Options) {
		o.Gcal = gc
		o.Log = zerolog.New(buf)
		o.Now = clock.now
	})
	gc.Workspaces = []string{f.src}
	gc.WorkspaceURL = hub.GcalWorkspaceURL("{tenant}."+gcalApexDom, f.src, gcalApp)
	se := &gcalSyncEnv{gcalTestEnv: &gcalTestEnv{env: f.e, fake: fake, gc: gc, clock: clock, log: buf, apex: f.src}, tid: f.src}
	m := &moveGcal{moveFix: f, se: se, rt: rt, hum: se.member(t)}
	m.ev = se.event(t, m.hum, "Moved review", func(e *store.CalendarEvent) { e.TopicID = f.task })
	se.cycle(t)
	m.cal = se.conn(t, m.hum).CalendarID
	got := fake.Events(m.cal)
	if maps := se.maps(t, m.hum); len(got) != 1 || len(maps) != 1 || maps[0].EventID != m.ev.ID {
		t.Fatalf("before the move: google %+v, map rows %+v, want the topic's event mapped", got, maps)
	}
	m.google = got[0].ID
	return m
}

// moveAndCycle moves the channel (P1..P4), lets the pre-P4 lease end, and
// runs one sync cycle on the member's connection.
func (m *moveGcal) moveAndCycle(t *testing.T) {
	t.Helper()
	m.toP3(t)
	m.se.fake.ResetCalls()
	m.must(t, "step", "P4", nil)
	if c := m.se.conn(t, m.hum); c.SyncLeaseUntil == nil {
		t.Fatal("P4 must leave the member's connection leased (5.1a)")
	}
	if m.se.cycle(t) {
		t.Fatal("a cycle claimed a connection the pre-P4 delete still leases")
	}
	// channelMoveGcalLease is on the wall clock, the cycle on gcalSyncT0: end
	// the lease the way its time running out would.
	moveExec(t, m.e, `UPDATE gcal_connections SET sync_lease_until = NULL WHERE tenant_id = $1 AND human_id = $2`, m.src, m.hum)
	m.se.next()
	if !m.se.cycle(t) {
		t.Fatal("the member's connection was not claimed after the move")
	}
}

// eventRows counts calendar_events of tenant with the fixture event's id.
func (m *moveGcal) eventRows(t *testing.T, tenant string) int {
	t.Helper()
	ctx := context.Background()
	n := 0
	err := pgx.BeginFunc(ctx, m.e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT count(*) FROM calendar_events WHERE tenant_id = $1 AND event_id = $2::uuid`, tenant, m.ev.ID).Scan(&n)
	})
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// C18, the sync-cycle half: after the move and one In-half run, <SRC> has no
// event with the Google event's source_key, no map row, and the Google event
// is gone; the event itself is in <DST>.
func TestChannelMoveC18SyncCycle(t *testing.T) {
	m := moveGcalFixture(t)
	m.moveAndCycle(t)
	if n := m.se.fake.Calls("events.delete"); n != 1 {
		t.Errorf("events.delete %d times, want 1 (the pre-P4 delete)", n)
	}
	if ev, ok := m.se.fake.Event(m.cal, m.google); ok && ev.Status != "cancelled" {
		t.Errorf("the Google event is still live: %+v", ev)
	}
	key := "gcal:" + m.se.conn(t, m.hum).ID + ":" + m.google
	if got := m.se.imported(t, m.hum); len(got) != 0 {
		t.Errorf("<SRC> holds %d event(s) keyed %s after the cycle: %+v", len(got), key, got)
	}
	if maps := m.se.maps(t, m.hum); len(maps) != 0 {
		t.Errorf("<SRC> map rows after the cycle: %+v", maps)
	}
	if src, dst := m.eventRows(t, m.src), m.eventRows(t, m.dst); src != 0 || dst != 1 {
		t.Errorf("the moved event: %d in <SRC>, %d in <DST>, want 0 and 1", src, dst)
	}
}

// CONTROL of C18: with the pre-P4 Google delete skipped, the Google event
// outlives the move unmapped, and the same cycle imports it back into <SRC>.
func TestChannelMoveC18SyncCycleControl(t *testing.T) {
	m := moveGcalFixture(t)
	m.rt.drop.Store(true)
	m.moveAndCycle(t)
	if n := m.rt.dropped.Load(); n != 1 {
		t.Fatalf("CONTROL: %d Google deletes skipped, want 1", n)
	}
	got := m.se.imported(t, m.hum)
	key := "gcal:" + m.se.conn(t, m.hum).ID + ":" + m.google
	if len(got) != 1 || got[0].SourceKey != key || got[0].Title != "Moved review" {
		t.Fatalf("CONTROL: <SRC> imports %+v, want the moved event back keyed %s", got, key)
	}
	if maps := m.se.maps(t, m.hum); len(maps) != 1 || maps[0].GoogleID != m.google {
		t.Fatalf("CONTROL: map rows %+v, want the import mapped to %s", maps, m.google)
	}
}
