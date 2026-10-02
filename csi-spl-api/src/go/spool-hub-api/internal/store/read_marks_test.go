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
