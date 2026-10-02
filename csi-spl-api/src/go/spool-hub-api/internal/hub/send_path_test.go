package hub_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// DB payload cut 7: a browser send stores the message and its box-wui
// delivery row (sent) in one pass. A resend of the same msg_id in a later
// second re-acks with the STORED ts and received_at, stores no second message
// and leaves exactly the one delivery row, still sent; a changed body under
// that msg_id conflicts and writes no delivery. Runs on Postgres too
// (SPOOL_TEST_PG_DSN), where the one-pass path is the CTE.
func TestWUISendOnePassResendKeepsStoredTS(t *testing.T) {
	var mu sync.Mutex
	first := time.Date(2026, 10, 2, 9, 0, 0, 987654321, time.UTC)
	now := first
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	})
	tid, _ := e.tenant()
	ctx := context.Background()
	a := dialWUI(t, e, tid, "HUM-1")
	id := "3c2b1a09-8f7e-4d6c-9b5a-4f3e2d1c0b9a"
	send := map[string]any{"type": "send", "msg_id": id, "task_id": "lobby", "body": "send me once"}

	a.send(send)
	ack1 := a.read("ack")
	ts1, ra1, err := e.st.MessageTimes(ctx, tid, id)
	if err != nil {
		t.Fatal(err)
	}
	if !ts1.Equal(first.Truncate(time.Second)) || !ra1.Equal(first.Truncate(time.Microsecond)) {
		t.Fatalf("stored ts %v received_at %v, want %v", ts1, ra1, first)
	}
	if st, err := e.st.DeliveryState(ctx, tid, id, hub.WUIBox); err != nil || st != store.StateSent {
		t.Fatalf("box-wui delivery after the send: %q %v, want sent", st, err)
	}

	mu.Lock()
	now = now.Add(3 * time.Second)
	mu.Unlock()
	a.send(send)
	ack2 := a.read("ack")
	if ack2.MsgID != id || ack2.Cursor != ack1.Cursor {
		t.Fatalf("resend re-ack: first %+v second %+v", ack1, ack2)
	}
	ts2, ra2, err := e.st.MessageTimes(ctx, tid, id)
	if err != nil {
		t.Fatal(err)
	}
	if !ts2.Equal(ts1) || !ra2.Equal(ra1) {
		t.Fatalf("resend moved the stored times: ts %v -> %v, received_at %v -> %v", ts1, ts2, ra1, ra2)
	}
	if envs, _ := e.st.TaskEnvelopes(ctx, tid, lobby); len(envs) != 1 {
		t.Fatalf("resend stored %d lobby messages, want 1", len(envs))
	}
	if st, err := e.st.DeliveryState(ctx, tid, id, hub.WUIBox); err != nil || st != store.StateSent {
		t.Fatalf("box-wui delivery after the resend: %q %v, want sent", st, err)
	}

	a.send(map[string]any{"type": "send", "msg_id": id, "task_id": "lobby", "body": "changed"})
	if f := a.read("error"); f.Error != "conflict_msg" {
		t.Fatalf("changed body: %+v", f)
	}
	if ts3, _, _ := e.st.MessageTimes(ctx, tid, id); !ts3.Equal(ts1) {
		t.Fatalf("conflict moved the stored ts %v -> %v", ts1, ts3)
	}
}
