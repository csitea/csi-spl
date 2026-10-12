package store

import (
	"context"
	"reflect"
	"testing"
	"time"
)

// P5-07 (perf round 5): the Postgres read probes the archived filter lazily,
// under the page's LIMIT, newest first. The fixture's newest lines are in an
// archived topic, so a probe that stopped at the first N candidates (a limit
// before the filter) would return a short or empty page. Controls: put the
// LIMIT inside c (before the archived probe) and "limit 2" comes back empty;
// drop the probe and the archived lines come back.
func TestViewDMPointersNewestArchived(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			pr := s.(DMPointerReader)
			tid := newTenant(t, s)
			if err := s.PutPin(ctx, tid, "box-a", pubkey(), false, now, now); err != nil {
				t.Fatal(err)
			}
			at := func(i int) time.Time { return now.Add(time.Duration(i) * time.Second) }
			n := 0
			line := func(task, from, to string) Message {
				t.Helper()
				n++
				fromBox, toBox := "box-wui", "box-wui"
				if from == "CLE-07" {
					fromBox = "box-a"
				}
				m := msgFor(tid, task, toBox, at(n), at(n), "env-"+uuid4())
				m.Channel, m.FromBox, m.FromID, m.ToID, m.Kind = "lobby", fromBox, from, to, "note"
				if ok, err := s.InsertMessage(ctx, m); err != nil || !ok {
					t.Fatalf("insert: %v %v", ok, err)
				}
				return m
			}
			live, gone := uuid4(), uuid4()
			var want []string // newest first
			for i := 0; i < 3; i++ {
				want = append([]string{line(live, "HUM-10", "CLE-07").MsgID}, want...)
			}
			card := line(gone, "HUM-10", "CLE-07")
			for i := 0; i < 2*DMPointerMax; i++ { // the newest lines, all in the archived topic
				from, to := "CLE-07", "HUM-10"
				if i%2 == 1 {
					from, to = to, from
				}
				line(gone, from, to)
			}
			want = append([]string{line(live, "CLE-07", "HUM-10").MsgID}, want...) // one live line newer than all
			if _, err := s.SetArchived(ctx, tid, card.MsgID, "HUM-10", at(n+1), true); err != nil {
				t.Fatal(err)
			}
			ids := func(rows []ViewMsg) []string {
				out := []string{}
				for _, r := range rows {
					out = append(out, r.MsgID)
				}
				return out
			}
			q := DMPointerQuery{Viewer: "HUM-10", Agent: "CLE-07", Lobby: uuid4(), Now: at(n + 2)}
			got, err := pr.ViewDMPointers(ctx, tid, q)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(ids(got), want) {
				t.Fatalf("pointers %v, want %v (the live lines, newest first)", ids(got), want)
			}
			q.Limit = 2
			if got, err = pr.ViewDMPointers(ctx, tid, q); err != nil || !reflect.DeepEqual(ids(got), want[:2]) {
				t.Fatalf("limit 2: %v %v, want %v", err, ids(got), want[:2])
			}
			for _, r := range got {
				if r.RowChannel != "lobby" || len(r.Env) < 4 || string(r.Env[:4]) != "env-" {
					t.Fatalf("pointer %s: channel %q env %q, want the full row joined back", r.MsgID, r.RowChannel, r.Env)
				}
			}
		})
	}
}
