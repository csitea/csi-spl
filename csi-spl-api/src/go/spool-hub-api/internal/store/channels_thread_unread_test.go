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
