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

// perf round 5 P5-10 (SPL-1761): the WUI re-sends a member's marks every 5 s
// (csi-spl-wui/src/utils/read-sync.mjs), most of them unchanged. A re-sent
// mark that moves nothing writes no row, so the change stamp (rdb 0103/0190)
// settles and GET /v1/view/channels can answer 304; a mark that advances, a
// higher Seen or a new key still moves it (the control). The stamp is
// Postgres only; the memory store checks the marks themselves.
func TestReadMarksUnchangedResendKeepsStamp(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rm := s.(ReadMarks)
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			cs, stamped := s.(ChangeStamper)
			stamp := func() ChangeStamp {
				if !stamped {
					return ChangeStamp{}
				}
				c, err := cs.ChangeStamp(ctx, tid, now, now)
				if err != nil {
					t.Fatal(err)
				}
				return c
			}
			save := func(marks map[string]ReadMark, at time.Time) {
				if err := rm.SaveReadMarks(ctx, tid, "HUM-1", marks, at); err != nil {
					t.Fatal(err)
				}
			}
			mark := ReadMark{At: now, MsgID: "m2", Seen: 3}
			save(map[string]ReadMark{"ch:devel": mark, "t:T1": mark}, now)
			cases := []struct {
				what  string
				marks map[string]ReadMark
				moves bool
			}{
				{"unchanged re-send", map[string]ReadMark{"ch:devel": mark, "t:T1": mark}, false},
				{"older re-send", map[string]ReadMark{"ch:devel": {At: now.Add(-time.Hour), MsgID: "m1", Seen: 1}}, false},
				{"advancing mark", map[string]ReadMark{"ch:devel": {At: now.Add(time.Second), MsgID: "m3", Seen: 3}}, true},
				{"higher seen", map[string]ReadMark{"t:T1": {At: now, MsgID: "m2", Seen: 4}}, true},
				{"new key", map[string]ReadMark{"dm:CLE-07@box-a": mark}, true},
			}
			for i, c := range cases {
				before := stamp()
				save(c.marks, now.Add(time.Duration(i+1)*5*time.Second))
				after := stamp()
				if moved := after.NoDeliveries != before.NoDeliveries; stamped && moved != c.moves {
					t.Errorf("%s: no-deliveries stamp %d -> %d, want moved=%v", c.what, before.NoDeliveries, after.NoDeliveries, c.moves)
				}
				if moved := after.Stamp != before.Stamp; stamped && moved != c.moves {
					t.Errorf("%s: stamp %d -> %d, want moved=%v", c.what, before.Stamp, after.Stamp, c.moves)
				}
			}
			got, err := rm.ReadMarksOf(ctx, tid, "HUM-1")
			if err != nil {
				t.Fatal(err)
			}
			if m := got["ch:devel"]; m.MsgID != "m3" || m.Seen != 3 {
				t.Errorf("ch:devel = %+v, want m3 seen 3", m)
			}
			if m := got["t:T1"]; m.MsgID != "m2" || m.Seen != 4 {
				t.Errorf("t:T1 = %+v, want m2 seen 4", m)
			}
			if len(got) != 3 {
				t.Errorf("marks = %v, want 3 keys", got)
			}
		})
	}
}
