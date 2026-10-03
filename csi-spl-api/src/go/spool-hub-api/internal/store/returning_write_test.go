package store

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// Perf round 4 G6: AddReaction and SetKind are one round trip each on
// Postgres. These pin what the folded statements must keep: the not-found and
// no-op answers, and a dense register under concurrent kind changes.

func TestAddReactionOneStatement(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			m := msgFor(tid, uuid4(), "box-b", now, now, `{}`)
			if _, err := s.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
			for i := 0; i < 2; i++ { // the second add is a no-op, not an error
				if err := s.AddReaction(ctx, tid, m.MsgID, "HUM-1", "👍", now); err != nil {
					t.Fatalf("add %d: %v", i, err)
				}
			}
			got, err := s.ReactionsFor(ctx, tid, []string{m.MsgID})
			if err != nil || len(got[m.MsgID]) != 1 {
				t.Fatalf("reactions after a repeated add: %v %v", got, err)
			}
			if err := s.AddReaction(ctx, tid, uuid4(), "HUM-1", "👍", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no such message: %v", err)
			}
			if err := s.AddReaction(ctx, tid, m.MsgID, "HUM-2", "👍", m.ExpiresAt.Add(time.Second)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("past retention: %v", err)
			}
			if got, _ := s.ReactionsFor(ctx, tid, []string{m.MsgID}); len(got[m.MsgID]) != 1 {
				t.Fatalf("a refused add wrote a row: %v", got)
			}
		})
	}
}

func TestSetKindConcurrentRegisterDense(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			m := msgFor(tid, uuid4(), "box-b", now, now, `{}`)
			if _, err := s.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
			if _, err := s.SetKind(ctx, tid, uuid4(), "note", "HUM-1", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no such message: %v", err)
			}
			kinds := []string{"note", "blocker", "result", "msg"}
			var wg sync.WaitGroup
			errs := make(chan error, 32)
			for i := 0; i < 32; i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					if _, err := s.SetKind(ctx, tid, m.MsgID, kinds[i%len(kinds)], "HUM-1", now.Add(time.Duration(i)*time.Millisecond)); err != nil {
						errs <- err
					}
				}(i)
			}
			wg.Wait()
			close(errs)
			for err := range errs {
				t.Fatalf("concurrent SetKind: %v", err)
			}
			cs, err := s.KindChanges(ctx, tid, m.MsgID)
			if err != nil || len(cs) == 0 {
				t.Fatalf("register: %v %v", cs, err)
			}
			prev := "task"
			for i, c := range cs {
				if c.Seq != i+1 || c.From != prev || c.From == c.To {
					t.Fatalf("register row %d: %+v (previous kind %q)", i, c, prev)
				}
				prev = c.To
			}
			if e, err := s.GetEditable(ctx, tid, m.MsgID, now); err != nil || e.Kind != prev {
				t.Fatalf("current kind %q, register ends at %q: %v", e.Kind, prev, err)
			}
		})
	}
}
