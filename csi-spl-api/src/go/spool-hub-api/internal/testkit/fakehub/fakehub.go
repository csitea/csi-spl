// Package fakehub is the smallest hub a `spool send` in hub mode can talk to:
// challenge, welcome, then one `sent` per `send` frame. It records every send
// frame whole, so a test outside hubclient (cmd/spool, mcp) can read what
// rode the frame and what rode the signed envelope.
package fakehub

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Hub is a running fake hub.
type Hub struct {
	URL string

	mu    sync.Mutex
	sends []wire.Frame
}

// New starts a fake hub for the test's lifetime.
func New(t *testing.T) *Hub {
	t.Helper()
	h := &Hub{}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := context.Background()
		if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}); err != nil {
			return
		}
		var hello wire.Frame
		if err := wsjson.Read(ctx, conn, &hello); err != nil {
			return
		}
		if err := wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID,
			UploadToken: "tok", UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}); err != nil {
			return
		}
		for {
			var f wire.Frame
			if err := wsjson.Read(ctx, conn, &f); err != nil {
				return
			}
			if f.Type != wire.TSend {
				continue
			}
			h.mu.Lock()
			h.sends = append(h.sends, f)
			h.mu.Unlock()
			out := wire.Frame{Type: wire.TSent, MsgID: wire.InnerMsgID(f.Env), Delivery: wire.DeliverySent}
			if err := wsjson.Write(ctx, conn, out); err != nil {
				return
			}
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	h.URL = srv.URL
	return h
}

// Wire points cfg at the hub as box: its keypair, tenant t1, no submit
// sidecar (every send dials, so every frame reaches the hub).
func (h *Hub) Wire(t *testing.T, cfg *config.Config, box string) {
	t.Helper()
	if _, err := sign.GenerateKey(cfg.KeysDir, box, false); err != nil {
		t.Fatal(err)
	}
	cfg.HubURL, cfg.BoxID, cfg.Tenant, cfg.SubmitSocket = h.URL, box, "t1", "off"
}

// Sends are the send frames received so far, oldest first.
func (h *Hub) Sends() []wire.Frame {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]wire.Frame(nil), h.sends...)
}
