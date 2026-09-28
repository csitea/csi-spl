package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

// SPL-1124: the file read door's answers - FileAttached, FileReadableByHuman
// and FileReadableByBox - for a carrier named by file_id and by sha256, a
// message without files, an expired carrier, a DM party / channel member /
// outsider and a sending / receiving / unrelated box. rdb 0075 changed how
// Postgres finds the carriers (has_files), never which ones.
func TestFileDoorAnswers(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	byID, bySHA, gone, none := strings.Repeat("a1", 32), strings.Repeat("b2", 32), strings.Repeat("c3", 32), strings.Repeat("d4", 32)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			put := func(channel, from, to, toBox, files string, expires time.Time) {
				t.Helper()
				m := Message{TenantID: tid, MsgID: uuid4(), TaskID: uuid4(), Channel: channel, TS: now,
					FromBox: "box-a", FromID: from, ToBox: toBox, ToID: to, Kind: "note", Body: "b",
					Files: []byte(files), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte("env-" + uuid4()),
					ReceivedAt: now, ExpiresAt: expires}
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			live := now.Add(time.Hour)
			put("", "HUM-1", "CLE-07", "box-b", `[{"mode":"blob","kind":"file","file_id":"`+byID+`","name":"a.png"}]`, live)
			put("ops", "CLE-07", "HUM-2", "box-c", `[{"mode":"blob","kind":"file","sha256":"`+bySHA+`","name":"b.pdf"}]`, live)
			put("tasks", "CLE-07", "HUM-2", "box-c", `[{"mode":"blob","kind":"file","file_id":"`+gone+`"}]`, now.Add(-time.Minute))
			put("tasks", "CLE-07", "HUM-2", "box-c", `[]`, live)

			attached := map[string]bool{byID: true, bySHA: true, gone: false, none: false}
			for id, want := range attached {
				if got, err := s.FileAttached(ctx, tid, id, now); err != nil || got != want {
					t.Fatalf("FileAttached %s…: %v %v, want %v", id[:4], got, err, want)
				}
			}
			for _, c := range []struct {
				file, human string
				chans       []string
				want        bool
			}{
				{byID, "HUM-1", nil, true},              // DM party
				{byID, "HUM-3", nil, false},             // not a party
				{bySHA, "HUM-3", []string{"ops"}, true}, // channel member
				{bySHA, "HUM-3", nil, false},            // not in the channel
				{gone, "HUM-2", []string{"tasks"}, false},
				{none, "HUM-1", nil, false},
			} {
				if got, err := s.FileReadableByHuman(ctx, tid, c.file, c.human, c.chans, now); err != nil || got != c.want {
					t.Fatalf("FileReadableByHuman %s… %s %v: %v %v, want %v", c.file[:4], c.human, c.chans, got, err, c.want)
				}
			}
			for _, c := range []struct {
				file, box string
				want      bool
			}{{byID, "box-a", true}, {byID, "box-b", true}, {byID, "box-z", false}, {bySHA, "box-c", true}, {gone, "box-c", false}} {
				if got, err := s.FileReadableByBox(ctx, tid, c.file, c.box, now); err != nil || got != c.want {
					t.Fatalf("FileReadableByBox %s… %s: %v %v, want %v", c.file[:4], c.box, got, err, c.want)
				}
			}
		})
	}
}
