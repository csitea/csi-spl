package store

import (
	"context"
	"testing"
	"time"
)

// SPL-2506 (owner HUM-10, t1 bd5edeb3: "it shows 3 unread msgs, but when I
// scroll all of the topics - there are no topics with those unread msgs"):
// a channel lists a topic by its is_parent 1 row, and the sweep purges an
// expired head while its later replies live on. Those replies have no card,
// so they must not count under ch: or t:, while a live topic's still do.
// Red before flowHeadless: ch:sec 6, t:<gone> 2.
func TestFlowHeadlessTopicLeavesUnread(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe := s.(FlowEvents)
			ctx := context.Background()
			base := time.Now().UTC().Truncate(time.Microsecond)
			now := base.Add(time.Hour)
			tid := newTenant(t, s)
			if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: "sec", Name: "sec", CreatedBy: "HUM-1", CreatedAt: base}); err != nil {
				t.Fatal(err)
			}
			if err := s.AddChannelHumans(ctx, tid, "sec", []string{"HUM-1"}, "HUM-1", base); err != nil {
				t.Fatal(err)
			}
			n := 0
			post := func(task, parent string, isParent int, expires time.Time) {
				t.Helper()
				n++
				at := base.Add(time.Duration(n) * time.Second)
				m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
				m.FromID, m.ToID, m.Channel, m.Body = "c-002", "HUM-1", "sec", "status"
				m.ParentTaskID, m.IsParent, m.ExpiresAt = parent, isParent, expires
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			live, gone := uuid4(), uuid4()
			later := now.Add(7 * 24 * time.Hour)
			post(gone, "", 1, base.Add(30*time.Minute)) // the head, expired by now (the sweep would purge it)
			post(gone, "", 0, later)                    // its replies outlive it
			post(gone, "", 0, later)
			post(uuid4(), gone, 0, later) // a sub-thread line of the headless topic
			post(live, "", 1, later)      // a live topic: head, reply, sub-thread line
			post(live, "", 0, later)
			sub := uuid4()
			post(sub, live, 0, later)

			// an issues-board line has no is_parent 1 row and still counts (the Issues page shows it)
			board := msgFor(tid, uuid4(), "box-a", base, base, "env-"+uuid4())
			board.FromID, board.ToID, board.Channel, board.Body, board.IsParent = "HUB-0", "HUM-1", ChannelIssues, "issue", 0
			if _, err := s.InsertMessage(ctx, board); err != nil {
				t.Fatal(err)
			}

			p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Limit: 30, Now: now})
			if err != nil {
				t.Fatal(err)
			}
			if p.Keys["ch:sec"] != 3 || p.Keys["t:"+live] != 2 || p.Keys["t:"+sub] != 1 || p.Keys["t:"+gone] != 0 {
				t.Fatalf("keys %v: want ch:sec 3 (the live topic's lines), t:<live> 2, t:<sub> 1, no t:<gone>", p.Keys)
			}
			if p.Keys["ch:"+ChannelIssues] != 1 || p.Keys["t:"+board.TaskID] != 1 {
				t.Fatalf("keys %v: want the issues-board line counted (ch:issues 1)", p.Keys)
			}
			if p.Unread.Channels != 4 {
				t.Fatalf("unread %+v, want Channels 4", p.Unread)
			}
			unread := 0
			for _, ev := range p.Events {
				if ev.Unread {
					unread++
				}
			}
			if unread != 4 {
				t.Fatalf("%d events unread, want 4 (the headless topic's lines list as read)", unread)
			}
		})
	}
}
