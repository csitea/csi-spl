package store

import (
	"context"
	"testing"
	"time"
)

// CLE-77889 (owner, t1 99905c80: "they should be shown as new for the receiver
// of those msgs, but not me"): a channel's unread skips the reader's own lines
// - their posts and, against a read mark, a line they typed at an agent's
// terminal (typed_by) - on memory and, with SPOOL_TEST_PG_DSN, Postgres. Any
// other reader still counts every one of them.
func TestChannelUnreadSkipsReadersOwnLines(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			line := func(ago time.Duration, from, typedBy, ch string) Message {
				m := msgFor(tid, uuid4(), "box-wui", now, now.Add(-ago), "e")
				m.Channel, m.FromID, m.FromBox, m.TypedBy = ch, from, "box-wui", typedBy
				return m
			}
			mark := line(6*time.Minute, "HUM-2", "", "feedback")
			rows := []Message{
				mark,
				line(5*time.Minute, "HUM-1", "", "feedback"),       // own post
				line(4*time.Minute, "CLE-07", "HUM-1", "feedback"), // own terminal line
				line(3*time.Minute, "HUM-2", "", "feedback"),       // the other member
				line(2*time.Minute, "CLE-07", "", "feedback"),      // the agent itself
				line(5*time.Minute, "HUM-1", "", "alerts"),         // own, no read mark
				line(4*time.Minute, "CLE-07", "HUM-1", "alerts"),   // own terminal, no mark: counted
				line(3*time.Minute, "HUM-2", "", "alerts"),         // the other member
			}
			for _, m := range rows {
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			reads := map[string]ReadMark{"feedback": {At: mark.ReceivedAt, MsgID: mark.MsgID}}
			unread := func(reader string) map[string]int {
				stats, err := s.ViewChannelStats(ctx, tid, now, reads, reader, "")
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]int{}
				for _, st := range stats {
					out[st.ChannelID] = st.Unread
				}
				return out
			}
			if got := unread("HUM-1"); got["feedback"] != 2 || got["alerts"] != 2 {
				t.Fatalf("HUM-1 (the author) unread = %v, want feedback 2 alerts 2", got)
			}
			if got := unread("HUM-2"); got["feedback"] != 3 || got["alerts"] != 2 {
				t.Fatalf("HUM-2 (a receiver) unread = %v, want feedback 3 alerts 2", got)
			}
			if got := unread(""); got["feedback"] != 4 || got["alerts"] != 3 {
				t.Fatalf("no reader unread = %v, want feedback 4 alerts 3", got)
			}
		})
	}
}
