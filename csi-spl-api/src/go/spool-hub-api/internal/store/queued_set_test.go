package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// P5-03: the relay tick reads the queued rows of a tenant's boxes as one set.
// QueuedForBoxes must return, per box, exactly what QueuedFor returns for it:
// the same rows in the same order, no sent or expired row, no other box's or
// tenant's row, and no key for a box with nothing queued.
func TestQueuedForBoxesEqualsQueuedForPerBox(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	tid, other := newTenant(t, pg), newTenant(t, pg)
	task := uuid4()
	ttl := now.Add(7 * 24 * time.Hour)
	queue := func(tenant, box string, i int, expires time.Time) string {
		m := msgFor(tenant, task, box, now.Add(time.Duration(i)*time.Second), now, fmt.Sprintf(`{"%s":%d}`, box, i))
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		// enqueued newest first, so the order comes from received_at, not insertion
		if err := pg.Enqueue(ctx, tenant, m.MsgID, box, now.Add(time.Duration(10-i)*time.Second), expires, 1000); err != nil {
			t.Fatal(err)
		}
		return m.MsgID
	}
	for i := 0; i < 4; i++ {
		queue(tid, "box-a", i, ttl)
	}
	sent := queue(tid, "box-a", 4, ttl)
	if ok, err := pg.ClaimSent(ctx, tid, sent, "box-a", now); err != nil || !ok {
		t.Fatalf("claim: %v %v", ok, err)
	}
	queue(tid, "box-a", 5, now.Add(-time.Second)) // expired
	queue(tid, "box-b", 0, ttl)
	queue(tid, "box-b", 1, ttl)
	queue(tid, "box-c", 0, ttl)   // not asked for
	queue(other, "box-a", 0, ttl) // another tenant's box-a

	got, err := pg.QueuedForBoxes(ctx, tid, []string{"box-a", "box-b", "box-z"}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("keys %v, want box-a and box-b only", keysOf(got))
	}
	for _, box := range []string{"box-a", "box-b"} {
		want, err := pg.QueuedFor(ctx, tid, box, now)
		if err != nil {
			t.Fatal(err)
		}
		if fmt.Sprint(rowsOf(got[box])) != fmt.Sprint(rowsOf(want)) {
			t.Fatalf("%s: set read %v, per-box read %v", box, rowsOf(got[box]), rowsOf(want))
		}
	}
	if n := len(got["box-a"]); n != 4 {
		t.Fatalf("box-a has %d rows, want the 4 queued (no sent, no expired)", n)
	}
	if empty, err := pg.QueuedForBoxes(ctx, tid, nil, now); err != nil || len(empty) != 0 {
		t.Fatalf("no boxes: %v %v", empty, err)
	}
}

func keysOf(m map[string][]Queued) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func rowsOf(q []Queued) []string {
	out := make([]string, len(q))
	for i, r := range q {
		out[i] = r.MsgID + " " + r.TaskID + " " + string(r.Env)
	}
	return out
}
