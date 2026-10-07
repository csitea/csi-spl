package hub_test

import (
	"context"
	"encoding/json"
	"testing"
)

// spec 102 10.2 (T017, rdb 0147): a box beats over its hello; the ack names
// the writing box (the session's, never the frame's), the hub's time and the
// box_down_min in force, and the beats read back newest first.
func TestBoxBeat(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	b := e.box(tid, "box-b", "CLE-08")
	e.pin(tid, b)
	ctx := context.Background()

	for _, pid := range []string{`{"pid":4242}`, `{"pid":4243}`} {
		raw, err := b.c.Lane(ctx, "box_beat_put", "", json.RawMessage(pid))
		if err != nil {
			t.Fatalf("put %s: %v", pid, err)
		}
		var ack struct {
			OK         bool   `json:"ok"`
			Box        string `json:"box"`
			BeatAt     string `json:"beat_at"`
			BoxDownMin int    `json:"box_down_min"`
		}
		if json.Unmarshal(raw, &ack) != nil || !ack.OK || ack.Box != "box-b" || ack.BeatAt == "" || ack.BoxDownMin != 2 {
			t.Fatalf("ack %s", raw)
		}
	}
	// CONTROL: no ack for a beat the table would refuse, a forged box, or an unknown op.
	for _, bad := range []string{`{"pid":0}`, `{}`, `{"pid":1,"box":"forged"}`, `"not an object"`} {
		if _, err := b.c.Lane(ctx, "box_beat_put", "", json.RawMessage(bad)); err == nil {
			t.Errorf("put %s acked", bad)
		}
	}
	if _, err := b.c.Lane(ctx, "box_beat_drop", "", nil); err == nil {
		t.Error("unknown box_beat op accepted")
	}
	if _, err := b.c.Lane(ctx, "box_beat_list", "", json.RawMessage(`{"since":"yesterday"}`)); err == nil {
		t.Error("since=yesterday accepted")
	}

	raw, err := b.c.Lane(ctx, "box_beat_list", "", json.RawMessage(`{"box":"box-b","since":"1h"}`))
	if err != nil {
		t.Fatal(err)
	}
	var a struct {
		Rows []struct {
			Box string `json:"box"`
			PID int    `json:"pid"`
		} `json:"rows"`
	}
	if err := json.Unmarshal(raw, &a); err != nil || len(a.Rows) != 2 || a.Rows[0].Box != "box-b" {
		t.Fatalf("list %s: %v", raw, err)
	}
	if a.Rows[0].PID != 4243 || a.Rows[1].PID != 4242 {
		t.Fatalf("list not newest first: %s", raw)
	}
	raw, err = b.c.Lane(ctx, "box_beat_list", "", json.RawMessage(`{"box":"other"}`))
	if err != nil || json.Unmarshal(raw, &a) != nil || len(a.Rows) != 0 {
		t.Fatalf("CONTROL: another box's beats: %s %v", raw, err)
	}
}
