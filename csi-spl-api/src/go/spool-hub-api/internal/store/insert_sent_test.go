package store

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// deliveryRows counts the delivery rows of (tenant, msg_id), any box.
func deliveryRows(t *testing.T, s Store, tenant, msgID string) int {
	t.Helper()
	switch st := s.(type) {
	case *Memory:
		st.mu.Lock()
		defer st.mu.Unlock()
		n := 0
		for k := range st.deliveries {
			if k[0] == tenant && k[1] == msgID {
				n++
			}
		}
		return n
	case *Postgres:
		var n int
		if err := st.queryRowTenant(context.Background(), tenant,
			`SELECT count(*) FROM deliveries WHERE tenant_id = $1 AND msg_id = $2`, []any{tenant, msgID}, &n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	t.Fatalf("no row count for %T", s)
	return 0
}

// TestInsertMessageSent (DB payload cut 7): the message and its sent delivery
// row in one pass. A resend of the identical envelope reports
// inserted=false, keeps the STORED ts and received_at, and leaves one
// delivery row; a different envelope under the msg_id is ErrConflict and
// writes no delivery row; a row left queued is claimed as ClaimSent would.
func TestInsertMessageSent(t *testing.T) {
	for name, s := range drivers(t) {
		si, ok := s.(SentInserter)
		if !ok {
			t.Fatalf("%s: no SentInserter", name)
		}
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			task, exp := uuid4(), now.Add(time.Hour)

			m := msgFor(tid, task, "box-wui", now.Truncate(time.Second), now, `{"e":1}`)
			if ins, err := si.InsertMessageSent(ctx, m, exp); err != nil || !ins {
				t.Fatalf("first send: inserted=%v err=%v", ins, err)
			}
			if st, err := s.DeliveryState(ctx, tid, m.MsgID, "box-wui"); err != nil || st != StateSent {
				t.Fatalf("delivery %q %v, want sent", st, err)
			}

			re := m // the resend: same envelope, a later clock
			re.ReceivedAt, re.ExpiresAt = now.Add(5*time.Second), now.Add(31*24*time.Hour)
			if ins, err := si.InsertMessageSent(ctx, re, exp.Add(time.Minute)); err != nil || ins {
				t.Fatalf("resend: inserted=%v err=%v, want false nil", ins, err)
			}
			ts, ra, err := s.MessageTimes(ctx, tid, m.MsgID)
			if err != nil {
				t.Fatal(err)
			}
			if !ts.Equal(m.TS) || !ra.Equal(m.ReceivedAt) {
				t.Fatalf("resend returned ts %v received_at %v, want the stored %v %v", ts, ra, m.TS, m.ReceivedAt)
			}
			if n := deliveryRows(t, s, tid, m.MsgID); n != 1 {
				t.Fatalf("%d delivery rows after the resend, want 1", n)
			}

			bad := m
			bad.ToBox, bad.Env = "box-x", []byte(`{"e":2}`)
			if _, err := si.InsertMessageSent(ctx, bad, exp); !errors.Is(err, ErrConflict) {
				t.Fatalf("different envelope: %v, want ErrConflict", err)
			}
			if _, err := s.DeliveryState(ctx, tid, m.MsgID, "box-x"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a conflict wrote a delivery row: %v", err)
			}
			if n := deliveryRows(t, s, tid, m.MsgID); n != 1 {
				t.Fatalf("%d delivery rows after the conflict, want 1", n)
			}

			// A row left queued (the insert + enqueue path stopped before its
			// claim) is claimed by an identical resend.
			q := msgFor(tid, task, "box-wui", now.Truncate(time.Second), now, `{"e":3}`)
			if _, err := s.InsertMessage(ctx, q); err != nil {
				t.Fatal(err)
			}
			if err := s.Enqueue(ctx, tid, q.MsgID, "box-wui", now, exp, 0); err != nil {
				t.Fatal(err)
			}
			if ins, err := si.InsertMessageSent(ctx, q, exp); err != nil || ins {
				t.Fatalf("resend over a queued row: inserted=%v err=%v", ins, err)
			}
			if st, _ := s.DeliveryState(ctx, tid, q.MsgID, "box-wui"); st != StateSent {
				t.Fatalf("queued row not claimed: %q", st)
			}

			// Concurrent identical sends: one inserts, none conflicts, one row.
			c := msgFor(tid, task, "box-wui", now.Truncate(time.Second), now, `{"e":4}`)
			var wg sync.WaitGroup
			var mu sync.Mutex
			inserted := 0
			for i := 0; i < 8; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					ins, err := si.InsertMessageSent(ctx, c, exp)
					if err != nil {
						t.Errorf("concurrent send: %v", err)
					}
					if ins {
						mu.Lock()
						inserted++
						mu.Unlock()
					}
				}()
			}
			wg.Wait()
			if inserted != 1 || deliveryRows(t, s, tid, c.MsgID) != 1 {
				t.Fatalf("8 concurrent sends: %d inserted, %d delivery rows; want 1 and 1", inserted, deliveryRows(t, s, tid, c.MsgID))
			}
			if st, _ := s.DeliveryState(ctx, tid, c.MsgID, "box-wui"); st != StateSent {
				t.Fatalf("concurrent sends left the delivery %q", st)
			}
		})
	}
}
