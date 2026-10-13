package fakehub

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestHandshakeAndSend walks the fake's protocol by hand: challenge, hello,
// welcome, then one sent per send frame, and Sends records the frame.
func TestHandshakeAndSend(t *testing.T) {
	h := New(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.URL, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow() //nolint:errcheck
	var f wire.Frame
	if err := wsjson.Read(ctx, conn, &f); err != nil || f.Type != wire.TChallenge {
		t.Fatalf("first frame %+v err %v, want a challenge", f, err)
	}
	if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.THello, BoxID: "box-a"}); err != nil {
		t.Fatal(err)
	}
	if err := wsjson.Read(ctx, conn, &f); err != nil || f.Type != wire.TWelcome || f.BoxID != "box-a" {
		t.Fatalf("welcome %+v err %v", f, err)
	}
	if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TSend, TaskID: "task-1"}); err != nil {
		t.Fatal(err)
	}
	if err := wsjson.Read(ctx, conn, &f); err != nil || f.Type != wire.TSent || f.Delivery != wire.DeliverySent {
		t.Fatalf("reply %+v err %v, want sent", f, err)
	}
	sends := h.Sends()
	if len(sends) != 1 || sends[0].TaskID != "task-1" {
		t.Fatalf("Sends() = %+v, want the one send frame", sends)
	}
}

// TestWire points a config at the hub as a box with its own key.
func TestWire(t *testing.T) {
	h := New(t)
	cfg := &config.Config{KeysDir: t.TempDir()}
	h.Wire(t, cfg, "box-a")
	if cfg.HubURL != h.URL || cfg.BoxID != "box-a" || cfg.Tenant != "t1" || cfg.SubmitSocket != "off" {
		t.Fatalf("Wire left %+v", cfg)
	}
}
