package store

import (
	"context"
	"testing"
	"time"
)

// SPL-5147: InheritTopicPriority copies a stored priority from one topic to
// another of the workspace. Memory always, Postgres with a DSN (hub-pg.tst.sh,
// PRE_PUSH_TIER=full). RED CONTROL: without ON CONFLICT DO NOTHING (Postgres)
// or the presence check (Memory) the "already set" case overwrites 4 with 2.
func TestTopicPriorityInherit(t *testing.T) {
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ps := s.(TopicPriorityStore)
			tid, other := newTenant(t, s), newTenant(t, s)
			src, dst, kept := uuid4(), uuid4(), uuid4()
			if _, err := ps.SetTopicPriority(ctx, tid, src, 2, "HUM-1", at); err != nil {
				t.Fatal(err)
			}
			row, wrote, err := ps.InheritTopicPriority(ctx, tid, src, dst, "c-002", at)
			if err != nil || !wrote || row.Priority != 2 || row.SetBy != "c-002" {
				t.Fatalf("copy: %+v %v %v, want priority 2 by c-002", row, wrote, err)
			}
			if _, err := ps.SetTopicPriority(ctx, tid, kept, 4, "HUM-1", at); err != nil {
				t.Fatal(err)
			}
			if _, wrote, err = ps.InheritTopicPriority(ctx, tid, src, kept, "c-002", at); err != nil || wrote {
				t.Fatalf("already set: wrote=%v err=%v, want no write", wrote, err)
			}
			unset, fresh := uuid4(), uuid4()
			if _, wrote, err = ps.InheritTopicPriority(ctx, tid, unset, fresh, "c-002", at); err != nil || wrote {
				t.Fatalf("no parent row: wrote=%v err=%v, want no write", wrote, err)
			}
			if _, wrote, err = ps.InheritTopicPriority(ctx, other, src, fresh, "c-002", at); err != nil || wrote {
				t.Fatalf("source of another workspace: wrote=%v err=%v, want no write", wrote, err)
			}
			got, err := ps.SetTopicPriorities(ctx, tid, []string{dst, kept, fresh})
			if err != nil || got[dst] != 2 || got[kept] != 4 {
				t.Fatalf("after: %v %v, want dst 2 and kept 4", got, err)
			}
			if _, ok := got[fresh]; ok {
				t.Fatalf("no parent row wrote %v, want no row", got[fresh])
			}
		})
	}
}
