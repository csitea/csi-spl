package store

import (
	"context"
	"testing"
	"time"
)

// CLE-77930 (owner, t1 bf737f3f: "2 new messages, then I go there and there
// is nothing new for me"): a channel's unread skips every line its feed hides
// as archived (specs/041) - the archived card, its thread's replies, a reply
// that lands after the archive - against a read mark and without one, on
// memory and, with SPOOL_TEST_PG_DSN, Postgres. A line of the lobby room task
// is not hidden by an archived lobby card beside it; that card's own thread
// is.
func TestChannelUnreadSkipsArchivedLines(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			lobby := uuid4()
			line := func(ago time.Duration, task, ch string) Message {
				m := msgFor(tid, task, "box-wui", now, now.Add(-ago), "e")
				m.Channel, m.FromID, m.FromBox = ch, "CLE-07", "box-a"
				return m
			}
			insert := func(ms ...Message) {
				for _, m := range ms {
					if _, err := s.InsertMessage(ctx, m); err != nil {
						t.Fatal(err)
					}
				}
			}
			gone, kept := uuid4(), uuid4()
			mark := line(10*time.Minute, kept, "devel")
			goneCard := line(9*time.Minute, gone, "devel")
			keptCard := line(8*time.Minute, kept, "devel")
			insert(mark, goneCard, keptCard,
				line(7*time.Minute, gone, "devel"), // a reply of the topic archived below
				line(6*time.Minute, kept, "devel"), // a reply of a live topic
			)
			if _, err := s.SetArchived(ctx, tid, goneCard.MsgID, "HUM-1", now.Add(-5*time.Minute), true); err != nil {
				t.Fatal(err)
			}
			insert(line(4*time.Minute, gone, "devel")) // lands after the archive

			// lobby: the room task, one archived lobby card with a thread
			lobbyCard := line(9*time.Minute, lobby, "lobby")
			insert(line(10*time.Minute, lobby, "lobby"), lobbyCard)
			if _, err := s.SetArchived(ctx, tid, lobbyCard.MsgID, "HUM-1", now.Add(-5*time.Minute), true); err != nil {
				t.Fatal(err)
			}
			insert(line(3*time.Minute, lobbyCard.MsgID, "lobby"), line(2*time.Minute, lobby, "lobby"))

			unread := func(reads map[string]ReadMark) map[string]int {
				stats, err := s.ViewChannelStats(ctx, tid, now, reads, "HUM-1", lobby)
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]int{}
				for _, st := range stats {
					out[st.ChannelID] = st.Unread
				}
				return out
			}
			got := unread(map[string]ReadMark{"devel": {At: mark.ReceivedAt, MsgID: mark.MsgID}})
			if got["devel"] != 2 {
				t.Fatalf("devel unread past the mark = %d, want 2 (the live card + its reply; the archived topic's 3 lines hidden)", got["devel"])
			}
			if got["lobby"] != 2 {
				t.Fatalf("lobby unread = %d, want 2 (the room lines; the archived lobby card + its thread hidden)", got["lobby"])
			}
			if got := unread(nil); got["devel"] != 3 {
				t.Fatalf("devel unread without a mark = %d, want 3", got["devel"])
			}
		})
	}
}
