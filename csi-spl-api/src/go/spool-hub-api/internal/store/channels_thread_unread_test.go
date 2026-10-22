package store

import (
	"context"
	"testing"
	"time"
)

// TestChannelUnreadCountsTopicReplies is SPL-2124 (owner HUM-10, t1
// b288e5be: "I would expect to have 3 unread msgs and not 0"): a channel
// whose unread lines are all replies inside topics. The member opened the
// channel (its ch: mark is past every line) but read the topics only part
// way (t: marks), so the cards show "1/3" and "2/3". The channel's number -
// the channel view and the Flow keys the sidebar row reads - is the sum, 3,
// and drops to 2 when one topic is opened. Before the fix the ch: mark
// covered every reply and both said 0.
func TestChannelUnreadCountsTopicReplies(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe, rm := s.(FlowEvents), s.(ReadMarks)
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			n := 0
			line := func(task, from, body string) Message {
				t.Helper()
				n++
				at := now.Add(time.Duration(n-60) * time.Second)
				m := msgFor(tid, task, "box-wui", at, at, "e")
				m.Channel, m.FromID, m.FromBox, m.ToBox, m.ToID, m.Body = "feedback", from, "box-a", "", "", body
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			A, B := uuid4(), uuid4()
			line(A, "c-034", "@HUM-1 card A")
			readA := line(A, "c-034", "@HUM-1 a1")
			line(B, "c-034", "@HUM-1 card B")
			readB := line(B, "c-034", "@HUM-1 b1")
			line(A, "c-034", "@HUM-1 a2")
			line(B, "c-034", "@HUM-1 b2")
			lastB := line(B, "c-034", "@HUM-1 b3")
			mark := func(marks map[string]ReadMark) {
				t.Helper()
				if err := rm.SaveReadMarks(ctx, tid, "HUM-1", marks, now); err != nil {
					t.Fatal(err)
				}
			}
			mark(map[string]ReadMark{
				ThreadMarkKey(A): {At: readA.ReceivedAt, MsgID: readA.MsgID, Seen: 1},
				ThreadMarkKey(B): {At: readB.ReceivedAt, MsgID: readB.MsgID, Seen: 1},
				"ch:feedback":    {At: lastB.ReceivedAt, MsgID: lastB.MsgID},
			})
			check := func(step string, want int) {
				t.Helper()
				stats, err := s.ViewChannelStats(ctx, tid, now, nil, "HUM-1", "")
				if err != nil {
					t.Fatal(err)
				}
				got := -1
				for _, st := range stats {
					if st.ChannelID == "feedback" {
						got = st.Unread
					}
				}
				if got != want {
					t.Fatalf("%s: channel view unread = %d, want %d", step, got, want)
				}
				p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Now: now})
				if err != nil {
					t.Fatal(err)
				}
				if p.Keys["ch:feedback"] != want || p.Unread.Channels != want {
					t.Fatalf("%s: flow keys ch:feedback = %d, unread channels %d, want %d", step, p.Keys["ch:feedback"], p.Unread.Channels, want)
				}
			}
			check("channel opened, topics read part way", 3)

			mark(map[string]ReadMark{ThreadMarkKey(A): {At: now, MsgID: "", Seen: 3}})
			check("topic A opened", 2)

			// a topic with no t: mark stays the channel mark's: nothing new
			line(uuid4(), "c-034", "@HUM-1 card C")
			mark(map[string]ReadMark{"ch:feedback": {At: now, MsgID: ""}})
			check("topic C read with the channel", 2)
		})
	}
}

// TestChannelRowCountsEveryLine is bug round 3 row 03 (SPL-2837, owner
// HUM-10, t1 b288e5be: "it still shows the amount of read messages wrongly on
// the channel level"): the side-list channel row reads the Flow key
// ch:<channel>, which counted flow_events only - lines that mention the
// member, are addressed to them, or reply in a topic they watch. A new topic
// that names nobody, and replies in a topic the member opened (t: mark) but
// does not watch, showed on the cards and in the channel view, not on the
// row. The ch: and t: keys now count every channel line the channel view
// counts; the Flow badge counts (spec 062, "only what concerns me") do not.
func TestChannelRowCountsEveryLine(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe, rm := s.(FlowEvents), s.(ReadMarks)
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: "closed", Name: "closed", CreatedBy: "HUM-2", CreatedAt: now}); err != nil {
				t.Fatal(err)
			}
			n := 0
			line := func(channel, task, from, body string, parent int) Message {
				t.Helper()
				n++
				at := now.Add(time.Duration(n-60) * time.Second)
				m := msgFor(tid, task, "box-wui", at, at, "e")
				m.Channel, m.FromID, m.FromBox, m.ToBox, m.ToID, m.Body, m.IsParent = channel, from, "box-a", "", "", body, parent
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			mark := func(marks map[string]ReadMark) {
				t.Helper()
				if err := rm.SaveReadMarks(ctx, tid, "HUM-1", marks, now); err != nil {
					t.Fatal(err)
				}
			}
			read := func() FlowPage {
				t.Helper()
				p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Now: now})
				if err != nil {
					t.Fatal(err)
				}
				return p
			}
			check := func(step, channel string, want int) {
				t.Helper()
				stats, err := s.ViewChannelStats(ctx, tid, now, nil, "HUM-1", "")
				if err != nil {
					t.Fatal(err)
				}
				view := -1
				for _, st := range stats {
					if st.ChannelID == channel {
						view = st.Unread
					}
				}
				p := read()
				if view != want || p.Keys["ch:"+channel] != want {
					t.Fatalf("%s: channel view %d, side-row key ch:%s %d, want %d", step, view, channel, p.Keys["ch:"+channel], want)
				}
				for _, c := range []FlowCounts{p.Counts, p.Unread} {
					if c.Mention != 0 || c.Reply != 0 || c.DM != 0 || c.Channels != 0 || c.Total != 0 {
						t.Fatalf("%s: Flow badge counts %+v, want 0: no line concerns HUM-1", step, c)
					}
				}
			}

			// (a) a new topic that names nobody, after the channel was read
			old := line("feedback", uuid4(), "c-034", "an older topic", 1)
			mark(map[string]ReadMark{"ch:feedback": {At: old.ReceivedAt, MsgID: old.MsgID}})
			A := uuid4()
			line("feedback", A, "c-034", "a new opener, no mention", 1)
			check("new opener, no mention", "feedback", 1)

			// (b) 2 replies in a topic HUM-1 opened (t: mark) and does not watch
			B := uuid4()
			head := line("alerts", B, "c-034", "an alert, no mention", 1)
			mark(map[string]ReadMark{"ch:alerts": {At: head.ReceivedAt, MsgID: head.MsgID},
				ThreadMarkKey(B): {At: head.ReceivedAt, MsgID: head.MsgID, Seen: 1}})
			line("alerts", B, "c-034", "reply 1", 0)
			r2 := line("alerts", B, "c-034", "reply 2", 0)
			check("2 replies in a read-but-unwatched topic", "alerts", 2)
			if p := read(); p.Keys[ThreadMarkKey(B)] != 2 || p.Keys[ThreadMarkKey(A)] != 1 {
				t.Fatalf("topic keys %d and %d, want 2 and 1", p.Keys[ThreadMarkKey(B)], p.Keys[ThreadMarkKey(A)])
			}

			// a channel mark past the replies leaves them to the t: mark; the
			// t: mark at the last reply reads them
			mark(map[string]ReadMark{"ch:alerts": {At: r2.ReceivedAt, MsgID: r2.MsgID}})
			check("channel opened, topic not", "alerts", 2)
			mark(map[string]ReadMark{ThreadMarkKey(B): {At: r2.ReceivedAt, MsgID: r2.MsgID, Seen: 3}})
			check("topic opened", "alerts", 0)

			// an own line, and a channel HUM-1 is not a member of, never count
			line("feedback", A, "HUM-1", "my own reply", 0)
			line("closed", uuid4(), "c-034", "behind the door", 1)
			check("own reply", "feedback", 1)
			if p := read(); p.Keys["ch:closed"] != 0 {
				t.Fatalf("ch:closed = %d, want 0: HUM-1 is not a member", p.Keys["ch:closed"])
			}
		})
	}
}
