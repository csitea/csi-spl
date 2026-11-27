package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// C415 (spec 150 v1.8 section 3.3.2, rdb 0332, SPL-6658): the channel default
// priority on Memory and Postgres. Unset reads nil (effective 3); 1..5 round
// trip on a created channel and on a default channel without its row; 0 and
// 6 are refused and change nothing; nil clears back to unset; an unknown
// channel is ErrNotFound; another workspace's channel of the same id reads
// none of it, one at a time and in the SetReads batch.
func TestChannelDefaultPriority(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 27, 9, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cp, ok := st.(ChannelDefaultPriority)
			if !ok {
				t.Fatalf("%s keeps no channel default priority", name)
			}
			tid, other := newTenant(t, st), newTenant(t, st)
			for _, tn := range []string{tid, other} {
				if err := st.CreateChannel(ctx, Channel{TenantID: tn, ChannelID: "drivers", Name: "drivers",
					CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
					t.Fatal(err)
				}
			}
			read := func(tn, ch string) ChannelDefaultPrio {
				t.Helper()
				p, err := cp.ChannelDefaultPriority(ctx, tn, ch)
				if err != nil {
					t.Fatal(err)
				}
				return p
			}
			for _, ch := range []string{"drivers", ChannelAlerts} {
				if p := read(tid, ch); p.Priority != nil || p.Effective() != TopicPriorityDefault {
					t.Fatalf("unset #%s reads %v (effective %d), want nil (3)", ch, *p.Priority, p.Effective())
				}
			}
			for _, ch := range []string{"drivers", ChannelAlerts} {
				for v := 1; v <= 5; v++ {
					at := now.Add(time.Duration(v) * time.Minute)
					if err := cp.SetChannelDefaultPriority(ctx, tid, ch, &v, "HUM-1", at); err != nil {
						t.Fatalf("#%s set %d: %v", ch, v, err)
					}
					p := read(tid, ch)
					if p.Priority == nil || *p.Priority != v || p.Effective() != v || p.SetBy != "HUM-1" || !p.SetAt.Equal(at) {
						t.Fatalf("#%s after set %d reads %+v", ch, v, p)
					}
				}
			}
			for _, bad := range []int{0, 6} {
				if err := cp.SetChannelDefaultPriority(ctx, tid, "drivers", &bad, "HUM-1", now); !errors.Is(err, ErrBadTopicPriority) {
					t.Fatalf("set %d: %v, want ErrBadTopicPriority", bad, err)
				}
			}
			if p := read(tid, "drivers"); p.Priority == nil || *p.Priority != 5 {
				t.Fatalf("a refused set changed the default: %+v", p)
			}
			two := 2
			if err := cp.SetChannelDefaultPriority(ctx, tid, "no-such", &two, "HUM-1", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown channel: %v, want ErrNotFound", err)
			}
			for _, ch := range []string{"drivers", ChannelAlerts} {
				if p := read(other, ch); p.Priority != nil {
					t.Fatalf("another workspace's #%s reads %d", ch, *p.Priority)
				}
			}
			checkChannelDefaultPrioBatch(t, st, tid, other)
			if err := cp.SetChannelDefaultPriority(ctx, tid, "drivers", nil, "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if p := read(tid, "drivers"); p.Priority != nil || p.Effective() != TopicPriorityDefault {
				t.Fatalf("cleared default reads %v", *p.Priority)
			}
			if pg, ok := st.(*Postgres); ok {
				checkChannelDefaultPrioCheck(t, pg, tid)
			}
		})
	}
}

// checkChannelDefaultPrioBatch: the SetReads batch carries the default of
// tid's channels (5 on both) and none of them into other's.
func checkChannelDefaultPrioBatch(t *testing.T, st Store, tid, other string) {
	t.Helper()
	sr, ok := st.(SetReads)
	if !ok {
		t.Fatal("no SetReads")
	}
	chs := []string{"drivers", ChannelAlerts, ChannelFeedback}
	want := map[string]map[string]int{tid: {"drivers": 5, ChannelAlerts: 5}, other: {}}
	for tn, w := range want {
		set, err := sr.ChannelSettings(context.Background(), tn, chs)
		if err != nil {
			t.Fatal(err)
		}
		for _, ch := range chs {
			got := set[ch].DefaultPriority
			v, has := w[ch]
			if has != (got != nil) || (got != nil && *got != v) {
				t.Fatalf("batch %s #%s: %v, want %v (set %v)", tn, ch, got, v, has)
			}
		}
	}
}

// checkChannelDefaultPrioCheck: the database refuses 0 and 6 itself (the
// rdb 0332 CHECK), not only the store.
func checkChannelDefaultPrioCheck(t *testing.T, pg *Postgres, tid string) {
	t.Helper()
	for _, bad := range []int{0, 6} {
		_, err := pg.execTenant(context.Background(), tid,
			`UPDATE channels SET default_priority = $3 WHERE tenant_id = $1 AND channel_id = $2`, tid, "drivers", bad)
		var pe *pgconn.PgError
		if !errors.As(err, &pe) || pe.Code != "23514" {
			t.Fatalf("raw default_priority = %d: %v, want a CHECK violation (23514)", bad, err)
		}
	}
}
