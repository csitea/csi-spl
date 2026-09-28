package hubclient

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Pins of the Dial handshake, taken before Dial was split into named steps
// (SPL-1029 round 2): what the hello carries per role, and how each way the
// hub can answer badly surfaces to the caller.

// scriptedHub answers the challenge with first, then (after reading the
// hello) with afterHello; a close code >= 1000 in closeCode closes instead.
type scriptedHub struct {
	first      wire.Frame
	afterHello wire.Frame
	closeCode  websocket.StatusCode
	pinsStatus int // 0 = 200 with an empty list

	mu    sync.Mutex
	hello wire.Frame
}

func (h *scriptedHub) start(t *testing.T) string {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/pins", func(w http.ResponseWriter, r *http.Request) {
		if h.pinsStatus != 0 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(h.pinsStatus)
			w.Write([]byte(`{"error":"boom"}`)) //nolint:errcheck
			return
		}
		json.NewEncoder(w).Encode(wire.PinList{Pins: []wire.PinEntry{}}) //nolint:errcheck
	})
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := r.Context()
		if wsjson.Write(ctx, conn, h.first) != nil || h.first.Type != wire.TChallenge {
			time.Sleep(100 * time.Millisecond)
			return
		}
		var hello wire.Frame
		if wsjson.Read(ctx, conn, &hello) != nil {
			return
		}
		h.mu.Lock()
		h.hello = hello
		h.mu.Unlock()
		if h.closeCode != 0 {
			conn.Close(h.closeCode, "hub_says_no") //nolint:errcheck
			return
		}
		if wsjson.Write(ctx, conn, h.afterHello) != nil {
			return
		}
		for { // keep the socket until the client goes
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL
}

func dialScripted(t *testing.T, h *scriptedHub, role string) (*Session, error) {
	t.Helper()
	c := testClient(t)
	c.Cfg.HubURL = h.start(t)
	c.Cfg.Tenant = "t1"
	c.Cfg.SubmitSocket = "off"
	c.ReadyTimeout = 5 * time.Second
	return c.Dial(context.Background(), role)
}

var (
	challenge = wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}
	welcome   = wire.Frame{Type: wire.TWelcome, UploadToken: "tok", UploadTokenExpiresAt: "2030-01-01T00:00:00Z"}
)

func TestDialHelloPerRole(t *testing.T) {
	for _, role := range []string{wire.RoleBox, "cli"} {
		h := &scriptedHub{first: challenge, afterHello: welcome}
		s, err := dialScripted(t, h, role)
		if err != nil {
			t.Fatalf("%s: %v", role, err)
		}
		if s.token != "tok" || !s.tokenExp.Equal(time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC)) {
			t.Errorf("%s: token %q exp %v", role, s.token, s.tokenExp)
		}
		s.Close()
		h.mu.Lock()
		hl := h.hello
		h.mu.Unlock()
		if hl.Type != wire.THello || hl.BoxID != "box-a" || hl.Nonce != challenge.Nonce || hl.Role != role || hl.Sig == "" || hl.TS == "" || len(hl.MsgVersions) == 0 {
			t.Errorf("%s: hello %+v", role, hl)
		}
		box := role == wire.RoleBox
		if want := []string{wire.FeatureBackfill, wire.FeatureFallback}; box != reflect.DeepEqual(hl.Features, want) {
			t.Errorf("%s: features %v", role, hl.Features)
		}
		if !box && (hl.Agents != nil || hl.Channels != nil || hl.Features != nil) {
			t.Errorf("%s: a non-box hello announced %v / %v / %v", role, hl.Agents, hl.Channels, hl.Features)
		}
	}
}

func TestDialHandshakeFailures(t *testing.T) {
	cases := []struct {
		name string
		hub  *scriptedHub
		role string
		want string
	}{
		{"no challenge", &scriptedHub{first: wire.Frame{Type: wire.TWelcome}}, "cli", "hub unreachable: no challenge: <nil>"},
		{"not a welcome", &scriptedHub{first: challenge, afterHello: wire.Frame{Type: wire.TSent}}, "cli", `hub unreachable: expected welcome, got "sent"`},
		{"normal close", &scriptedHub{first: challenge, closeCode: websocket.StatusNormalClosure}, "cli", "hub unreachable: "},
		{"pins fail", &scriptedHub{first: challenge, afterHello: welcome, pinsStatus: http.StatusInternalServerError}, wire.RoleBox, "boom"},
	}
	for _, c := range cases {
		_, err := dialScripted(t, c.hub, c.role)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: got %v, want it to contain %q", c.name, err, c.want)
		}
	}
	// a hub refusal (close code >= 4000) is a HubError carrying the reason
	_, err := dialScripted(t, &scriptedHub{first: challenge, closeCode: 4003}, "cli")
	var he *HubError
	if !errors.As(err, &he) || he.Token != "hub_says_no" || he.Status != 4003 {
		t.Fatalf("want HubError{hub_says_no 4003}, got %#v", err)
	}
}
