package hubclient

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Evlog (spec 162 10.4.4) sends one evlog frame with a fresh msg_id, its op
// and body, and returns the reply's evlog object; a hub error frame is a
// HubError with its token (409 cursor_moved for the losing box).
func TestEvlogRequest(t *testing.T) {
	ctx := context.Background()
	body := json.RawMessage(`{"env":"dev"}`)
	h := &opsHub{reply: func(f wire.Frame) []wire.Frame {
		if f.EvlogOp == wire.EvlogOpPut {
			return []wire.Frame{{Type: wire.TError, MsgID: f.MsgID, Error: "cursor_moved", Status: 409}}
		}
		return []wire.Frame{{Type: wire.TEvlog, MsgID: f.MsgID, Evlog: echo(f.EvlogOp)}}
	}}
	c := opsClient(t, h)
	got, err := c.Evlog(ctx, wire.EvlogOpCursor, body)
	if err != nil || string(got) != string(echo(wire.EvlogOpCursor)) {
		t.Fatalf("cursor: %s %v", got, err)
	}
	_, err = c.Evlog(ctx, wire.EvlogOpPut, body)
	var he *HubError
	if !errors.As(err, &he) || he.Token != "cursor_moved" || he.Status != 409 {
		t.Fatalf("put: want HubError cursor_moved 409, got %v", err)
	}
	fs := h.frames(wire.TEvlog)
	if len(fs) != 2 || fs[0].MsgID == "" || fs[0].MsgID == fs[1].MsgID || string(fs[0].Evlog) != string(body) || fs[1].EvlogOp != wire.EvlogOpPut {
		t.Fatalf("frames %+v", fs)
	}
}
