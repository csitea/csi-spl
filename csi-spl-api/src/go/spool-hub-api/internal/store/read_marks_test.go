package store

import (
	"context"
	"testing"
	"time"
)

// CLE-77930 (rdb 0098): a member's read marks only move forward - an older
// device's write never rewinds a newer one, Seen only rises - and are per
// member: another member's marks are not theirs. Memory and, with
// SPOOL_TEST_PG_DSN, Postgres.
func TestReadMarksMoveForwardOnly(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rm, ok := s.(ReadMarks)
			if !ok {
				t.Fatalf("%s store has no ReadMarks", name)
			}
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			save := func(hum string, marks map[string]ReadMark) {
				if err := rm.SaveReadMarks(ctx, tid, hum, marks, now); err != nil {
					t.Fatal(err)
				}
			}
			newMark, oldMark := ReadMark{At: now, MsgID: "m2", Seen: 3}, ReadMark{At: now.Add(-time.Hour), MsgID: "m1", Seen: 5}
			save("HUM-1", map[string]ReadMark{"ch:devel": newMark, "t:T1": newMark})
			save("HUM-1", map[string]ReadMark{"ch:devel": oldMark, "t:T1": oldMark, "dm:CLE-07@box-a": oldMark})
			save("HUM-2", map[string]ReadMark{"ch:devel": oldMark})
			got, err := rm.ReadMarksOf(ctx, tid, "HUM-1")
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != 3 {
				t.Fatalf("HUM-1 marks = %v, want 3 keys", got)
			}
			if m := got["ch:devel"]; !m.At.Equal(now) || m.MsgID != "m2" || m.Seen != 5 {
				t.Fatalf("ch:devel = %+v, want the newer position with the higher seen (m2, 5)", m)
			}
			if m := got["dm:CLE-07@box-a"]; m.MsgID != "m1" {
				t.Fatalf("dm mark = %+v, want m1", m)
			}
			other, err := rm.ReadMarksOf(ctx, tid, "HUM-2")
			if err != nil {
				t.Fatal(err)
			}
			if len(other) != 1 || other["ch:devel"].MsgID != "m1" {
				t.Fatalf("HUM-2 marks = %v, want only its own ch:devel m1", other)
			}
		})
	}
}

// CLE-77930: a line the reader already read inside its thread (a t: mark at or
// past it - Flow, a link, another device) is not unread in its channel; a
// later reply of that thread is.
func TestChannelUnreadSkipsLinesReadInTheirThread(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rm := s.(ReadMarks)
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			line := func(ago time.Duration, task string) Message {
				m := msgFor(tid, task, "box-wui", now, now.Add(-ago), "e")
				m.Channel, m.FromID, m.FromBox = "devel", "CLE-07", "box-a"
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			read, other := uuid4(), uuid4()
			mark := line(10*time.Minute, other)
			line(9*time.Minute, read)
			r2 := line(8*time.Minute, read)
			line(7*time.Minute, other)
			line(6*time.Minute, read) // after the thread mark: new
			if err := rm.SaveReadMarks(ctx, tid, "HUM-1", map[string]ReadMark{ThreadMarkKey(read): {At: r2.ReceivedAt, MsgID: r2.MsgID, Seen: 1}}, now); err != nil {
				t.Fatal(err)
			}
			stats, err := s.ViewChannelStats(ctx, tid, now, map[string]ReadMark{"devel": {At: mark.ReceivedAt, MsgID: mark.MsgID}}, "HUM-1", "")
			if err != nil {
				t.Fatal(err)
			}
			for _, st := range stats {
				if st.ChannelID == "devel" && st.Unread != 2 {
					t.Fatalf("devel unread = %d, want 2 (the other thread's reply + the read thread's newer reply)", st.Unread)
				}
			}
			// another member has no thread mark: all 4 lines past the channel mark
			stats, err = s.ViewChannelStats(ctx, tid, now, map[string]ReadMark{"devel": {At: mark.ReceivedAt, MsgID: mark.MsgID}}, "HUM-2", "")
			if err != nil {
				t.Fatal(err)
			}
			for _, st := range stats {
				if st.ChannelID == "devel" && st.Unread != 4 {
					t.Fatalf("HUM-2 devel unread = %d, want 4", st.Unread)
				}
			}
		})
	}
}
