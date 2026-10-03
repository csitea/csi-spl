package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

// Owner, t1 77540e6f: a section's unread total is the sum of its rows. The
// Flow's per-row keys (FlowKeys) count the same unread lines as its totals:
// the dm: rows sum to Unread.DMs, the ch: rows to Unread.Channels, the t:
// rows to Unread.Total, and a line read under its row leaves both at once.
func TestFlowKeysSumToTotals(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe, rm := s.(FlowEvents), s.(ReadMarks)
			ctx := context.Background()
			base := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			n := 0
			post := func(from, fromBox, to, channel, task, body string) Message {
				t.Helper()
				n++
				at := base.Add(time.Duration(n) * time.Second)
				m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
				m.FromID, m.FromBox, m.ToID, m.Channel, m.Body = from, fromBox, to, channel, body
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			now := base.Add(time.Hour)
			read := func() FlowPage {
				t.Helper()
				p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Now: now})
				if err != nil {
					t.Fatal(err)
				}
				return p
			}
			sums := func(keys map[string]int) (ch, dm, topics int) {
				for k, v := range keys {
					switch {
					case strings.HasPrefix(k, "ch:"):
						ch += v
					case strings.HasPrefix(k, "dm:"):
						dm += v
					case strings.HasPrefix(k, "t:"):
						topics += v
					}
				}
				return ch, dm, topics
			}
			check := func(p FlowPage) {
				t.Helper()
				ch, dm, topics := sums(p.Keys)
				if ch != p.Unread.Channels || dm != p.Unread.DMs || topics != p.Unread.Total {
					t.Fatalf("rows ch=%d dm=%d t=%d, totals %+v (keys %v)", ch, dm, topics, p.Unread, p.Keys)
				}
			}

			task, dmA, dmB := uuid4(), uuid4(), uuid4()
			post("HUM-1", "box-wui", "", "lobby", task, "root by one")
			post("CLE-07", "box-a", "", "lobby", task, "reply one")
			post("HUM-2", "box-wui", "", "lobby", task, "@HUM-1 look")
			post("c-034", "box-a", "HUM-1", "", dmA, "old agent dm 1")
			post("c-034", "box-a", "HUM-1", "", dmA, "old agent dm 2")
			last := post("HUM-2", "box-wui", "HUM-1", "", dmB, "person dm")
			post("c-035", "box-a", "c-001", "", uuid4(), "agent to agent: never HUM-1's")

			p := read()
			check(p)
			want := map[string]int{"ch:lobby": 2, ThreadMarkKey(task): 2,
				"dm:c-034@box-a": 2, ThreadMarkKey(dmA): 2, "dm:HUM-2@box-wui": 1, ThreadMarkKey(dmB): 1}
			if len(p.Keys) != len(want) {
				t.Fatalf("keys %v, want %v", p.Keys, want)
			}
			for k, v := range want {
				if p.Keys[k] != v {
					t.Fatalf("keys %v, want %v", p.Keys, want)
				}
			}
			if p.Unread.DMs != 3 || p.Unread.Channels != 2 {
				t.Fatalf("unread %+v, want 3 DMs and 2 channel lines", p.Unread)
			}

			// Reading HUM-2's DM row (its dm: mark) leaves the row and the total together.
			if err := rm.SaveReadMarks(ctx, tid, "HUM-1", map[string]ReadMark{"dm:HUM-2@box-wui": {At: last.ReceivedAt, MsgID: last.MsgID}}, now); err != nil {
				t.Fatal(err)
			}
			p = read()
			check(p)
			if p.Keys["dm:HUM-2@box-wui"] != 0 || p.Unread.DMs != 2 {
				t.Fatalf("after dm: mark keys %v unread %+v", p.Keys, p.Unread)
			}

			// The live fan-out carries the same keys.
			nxt := post("c-034", "box-a", "HUM-1", "", dmA, "old agent dm 3")
			pushes, err := fe.FlowFanout(ctx, tid, nxt.MsgID, []string{"HUM-1"}, now)
			if err != nil {
				t.Fatal(err)
			}
			if got := pushes["HUM-1"]; got.Keys["dm:c-034@box-a"] != 3 || got.Unread.DMs != 3 {
				t.Fatalf("fan-out keys %v unread %+v", got.Keys, got.Unread)
			}
		})
	}
}
