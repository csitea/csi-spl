package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// lagOf is the tenant's ConsumerLag rows by box (other tests share the
// Postgres database, so the fleet-wide list is filtered to this tenant).
func lagOf(t *testing.T, s Store, tenant string, now time.Time) map[string]BoxLag {
	t.Helper()
	all, err := s.(Lag).ConsumerLag(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]BoxLag{}
	for _, l := range all {
		if l.TenantID == tenant {
			out[l.BoxID] = l
		}
	}
	return out
}

// TestConsumerLag (spec 059 S4): a box sent rows it never committed reads its
// count and the oldest send; CONTROL: a box that committed every row reads 0
// (is not listed), so a lag of 0 is not just an empty report. A box with no
// hello for days is reported as lag and is dead, not an alert.
func TestConsumerLag(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			ttl := now.Add(7 * 24 * time.Hour)
			acks := s.(Acks)
			send := func(box string, at time.Time, commit bool) string {
				m := msgFor(tid, uuid4(), box, at, at, fmt.Sprintf(`{"l":%q}`, uuid4()))
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				if err := s.Enqueue(ctx, tid, m.MsgID, box, at, ttl, 1000); err != nil {
					t.Fatal(err)
				}
				if ok, err := acks.ClaimSentUnacked(ctx, tid, m.MsgID, box, at); err != nil || !ok {
					t.Fatalf("claim %s: %v %v", box, ok, err)
				}
				if commit {
					if err := acks.AckDelivery(ctx, tid, m.MsgID, box, at); err != nil {
						t.Fatal(err)
					}
				}
				return m.MsgID
			}
			for _, b := range []string{"box-live", "box-done", "box-dead"} {
				if err := s.TouchBox(ctx, tid, b, now.Add(-time.Minute)); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.TouchBox(ctx, tid, "box-dead", now.Add(-5*24*time.Hour)); err != nil {
				t.Fatal(err)
			}
			send("box-live", now.Add(-2*time.Hour), false)
			send("box-live", now.Add(-time.Hour), false)
			send("box-done", now.Add(-2*time.Hour), true)
			send("box-done", now.Add(-time.Hour), true)
			send("box-dead", now.Add(-4*24*time.Hour), false)
			q := msgFor(tid, uuid4(), "box-live", now, now, `{"q":1}`)
			s.InsertMessage(ctx, q) //nolint:errcheck
			if err := s.Enqueue(ctx, tid, q.MsgID, "box-live", now, ttl, 1000); err != nil {
				t.Fatal(err)
			}

			got := lagOf(t, s, tid, now)
			live := got["box-live"]
			if live.Uncommitted != 2 || live.Queued != 1 || !live.OldestSent.Equal(now.Add(-2*time.Hour)) {
				t.Fatalf("box-live lag = %+v, want 2 uncommitted, 1 queued, oldest -2h", live)
			}
			if _, listed := got["box-done"]; listed {
				t.Fatalf("CONTROL: a box that committed everything must read 0, got %+v", got["box-done"])
			}
			dead := got["box-dead"]
			if dead.Uncommitted != 1 {
				t.Fatalf("a dead box's rows must be reported as lag, got %+v", dead)
			}
			if !live.Alert(now, 30*time.Minute, 72*time.Hour) || live.Alert(now, 3*time.Hour, 72*time.Hour) {
				t.Fatalf("box-live alert must fire past 30m and not past 3h: %+v", live)
			}
			if !dead.Dead(now, 72*time.Hour) || dead.Alert(now, 30*time.Minute, 72*time.Hour) {
				t.Fatalf("box-dead must be dead, not an alert: %+v", dead)
			}
		})
	}
}

// TestSweepPrunesCommitted (spec 059 S4 retention): Sweep deletes a committed
// row past CommittedRetention and keeps a recent committed row, an old
// UNCOMMITTED row (lag, never pruned) and a queued row.
func TestSweepPrunesCommitted(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			old := now.Add(-CommittedRetention - time.Hour)
			ttl := now.Add(7 * 24 * time.Hour)
			acks := s.(Acks)
			row := func(box string, at time.Time, claim func(id string) (bool, error)) string {
				m := msgFor(tid, uuid4(), box, now, now, fmt.Sprintf(`{"r":%q}`, uuid4()))
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				if err := s.Enqueue(ctx, tid, m.MsgID, box, at, ttl, 1000); err != nil {
					t.Fatal(err)
				}
				if claim != nil {
					if ok, err := claim(m.MsgID); err != nil || !ok {
						t.Fatalf("claim: %v %v", ok, err)
					}
				}
				return m.MsgID
			}
			oldDone := row("box-p", old, func(id string) (bool, error) { return s.ClaimSent(ctx, tid, id, "box-p", old) })
			newDone := row("box-p", now, func(id string) (bool, error) { return s.ClaimSent(ctx, tid, id, "box-p", now) })
			oldOpen := row("box-p", old, func(id string) (bool, error) { return acks.ClaimSentUnacked(ctx, tid, id, "box-p", old) })
			queued := row("box-p", now, nil)

			r, err := s.Sweep(ctx, now)
			if err != nil {
				t.Fatal(err)
			}
			if r.Pruned < 1 {
				t.Fatalf("sweep pruned %d, want the old committed row", r.Pruned)
			}
			if st, _ := s.DeliveryState(ctx, tid, oldDone, "box-p"); st != "" {
				t.Fatalf("old committed row survived: %q", st)
			}
			for id, want := range map[string]string{newDone: StateSent, oldOpen: StateSent, queued: StateQueued} {
				if st, _ := s.DeliveryState(ctx, tid, id, "box-p"); st != want {
					t.Fatalf("row %s = %q, want %q (only committed rows past the window go)", id, st, want)
				}
			}
			if l := lagOf(t, s, tid, now)["box-p"]; l.Uncommitted != 1 {
				t.Fatalf("the old uncommitted row must stay lag, got %+v", l)
			}
		})
	}
}
