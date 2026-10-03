package store

import (
	"context"
	"testing"
	"time"
)

// Owner, t1 56b8cc17 (HUM-10): "anything that is archived should not be
// part of the unread messages counter". Archiving a topic the member has
// unread lines in drops them from the counts and the per-row keys at once;
// unarchiving brings them back. A line in the lobby task is not read by an
// archived lobby post's own stamp unless it is that post or its thread.
func TestFlowArchivedTopicLeavesUnread(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe := s.(FlowEvents)
			ctx := context.Background()
			base := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			lobby := uuid4()
			n := 0
			post := func(from, channel, task, body string) Message {
				t.Helper()
				n++
				at := base.Add(time.Duration(n) * time.Second)
				m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
				m.FromID, m.FromBox, m.Channel, m.Body = from, "box-a", channel, body
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			now := base.Add(time.Hour)
			read := func() FlowPage {
				t.Helper()
				p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Now: now, Lobby: lobby, Limit: 10})
				if err != nil {
					t.Fatal(err)
				}
				return p
			}

			task := uuid4()
			card := post("CLE-07", "alerts", task, "@HUM-1 look at this")
			post("GRK-03", "alerts", task, "@HUM-1 and this")
			post("CLE-07", "lobby", lobby, "@HUM-1 a lobby line")

			p := read()
			if p.Unread.Total != 3 || p.Keys[ThreadMarkKey(task)] != 2 || p.Keys["ch:alerts"] != 2 {
				t.Fatalf("before: unread %+v keys %v", p.Unread, p.Keys)
			}

			if _, err := s.SetArchived(ctx, tid, card.MsgID, "HUM-2", base.Add(time.Minute), true); err != nil {
				t.Fatal(err)
			}
			p = read()
			if p.Unread.Total != 1 || p.Counts.Total != 1 || p.Keys[ThreadMarkKey(task)] != 0 || p.Keys["ch:alerts"] != 0 || p.Keys["ch:lobby"] != 1 {
				t.Fatalf("archived: counts %+v unread %+v keys %v", p.Counts, p.Unread, p.Keys)
			}
			for _, ev := range p.Events {
				if ev.TaskID == task && ev.Unread {
					t.Fatalf("an archived topic's line is still unread: %+v", ev)
				}
			}

			if _, err := s.SetArchived(ctx, tid, card.MsgID, "HUM-2", base.Add(2*time.Minute), false); err != nil {
				t.Fatal(err)
			}
			if p = read(); p.Unread.Total != 3 || p.Keys[ThreadMarkKey(task)] != 2 {
				t.Fatalf("unarchived: unread %+v keys %v", p.Unread, p.Keys)
			}
		})
	}
}
