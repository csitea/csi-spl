package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"
)

// Spec 186 row M2 (rdb 0321): InsertMessage stores Message.McID, and the two
// reads find the copies of one multicast and its author, per tenant. Memory,
// and Postgres under SPOOL_TEST_PG_DSN (parity). RED CONTROL: drop mc_id
// from insertMessageArgs and Postgres finds no copy.
func TestMulticastCopiesAndAuthor(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, at := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
			tid, other := newTenant(t, s), newTenant(t, s)
			mc := uuid4()
			var want []string
			for i := range 3 {
				m := humanPost(tid, uuid4(), "lobby", "to all", at.Add(time.Duration(i)*time.Second))
				m.McID = mc
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				want = append(want, m.MsgID)
			}
			if _, err := s.InsertMessage(ctx, humanPost(tid, uuid4(), "lobby", "plain", at)); err != nil {
				t.Fatal(err)
			}
			slices.Sort(want)
			got, err := s.MulticastCopies(ctx, tid, mc)
			if err != nil || !slices.Equal(got, want) {
				t.Fatalf("copies %v %v, want %v", got, err, want)
			}
			if from, err := s.MulticastAuthor(ctx, tid, mc); err != nil || from != "HUM-google-sub-10" {
				t.Fatalf("author %q %v", from, err)
			}
			if _, err := s.MulticastAuthor(ctx, other, mc); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another tenant's author: %v, want ErrNotFound", err)
			}
			if _, err := s.MulticastAuthor(ctx, tid, uuid4()); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown mc_id: %v, want ErrNotFound", err)
			}
			if got, err := s.MulticastCopies(ctx, other, mc); err != nil || len(got) != 0 {
				t.Fatalf("another tenant's copies %v %v, want none", got, err)
			}
		})
	}
}
