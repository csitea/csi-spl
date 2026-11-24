package hubclient

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestSigninSeenOnce (spec 181 B11): a signin_relay frame id is taken once,
// so a frame the hub writes twice (a socket roll, two hub instances) types
// an input once; an id older than signinSeenTTL is forgotten.
func TestSigninSeenOnce(t *testing.T) {
	var s signinSeen
	t0 := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	if !s.first("f-1", t0) {
		t.Fatal("a new frame id was not taken")
	}
	if s.first("f-1", t0.Add(time.Minute)) {
		t.Fatal("the same frame id was taken twice: the input would be typed twice")
	}
	if !s.first("f-2", t0.Add(time.Minute)) {
		t.Fatal("another frame id was refused")
	}
	if !s.first("f-1", t0.Add(signinSeenTTL+2*time.Minute)) {
		t.Fatal("an id past signinSeenTTL is still held")
	}
}

// fakeRelayer records each run and reports state.
type fakeRelayer struct {
	mu   sync.Mutex
	runs []wire.SigninRelayLane
}

func (f *fakeRelayer) Run(_ context.Context, _ string, lane wire.SigninRelayLane) wire.SigninRelayOutLane {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.runs = append(f.runs, lane)
	if lane.Op == wire.SigninOpEnd {
		return wire.SigninRelayOutLane{} // no report
	}
	return wire.SigninRelayOutLane{State: wire.SigninStateDelivered}
}

func (f *fakeRelayer) count() int { f.mu.Lock(); defer f.mu.Unlock(); return len(f.runs) }

// relayHub is a hub that keeps the role=box hello, writes the frames put on
// ask and hands back every signin_relay_out.
func relayHub(t *testing.T) (url string, hello chan wire.Frame, ask, outs chan wire.Frame) {
	t.Helper()
	hello, ask, outs = make(chan wire.Frame, 1), make(chan wire.Frame, 8), make(chan wire.Frame, 8)
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/pins", func(w http.ResponseWriter, _ *http.Request) {
		wire.WriteJSON(w, http.StatusOK, wire.PinList{Pins: []wire.PinEntry{}})
	})
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := r.Context()
		var h wire.Frame
		if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}) != nil || wsjson.Read(ctx, conn, &h) != nil {
			return
		}
		hello <- h
		if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: h.BoxID, UploadToken: "tok",
			UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}) != nil {
			return
		}
		go func() {
			for {
				var f wire.Frame
				if wsjson.Read(ctx, conn, &f) != nil {
					return
				}
				if f.Type == wire.TSigninRelayOut {
					outs <- f
				}
			}
		}()
		for {
			select {
			case f := <-ask:
				if wsjson.Write(ctx, conn, f) != nil {
					return
				}
			case <-ctx.Done():
				return
			}
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL, hello, ask, outs
}

// TestSigninRelayFrameOnce (spec 181 B11, box half): a box with a relayer
// says signin_relay in its hello; a frame runs once and its report comes
// back as signin_relay_out on the same relay id; the same frame id again
// runs nothing; a run with no state sends no report. CONTROL: a box with
// no relayer says no signin_relay.
func TestSigninRelayFrameOnce(t *testing.T) {
	url, hello, ask, outs := relayHub(t)
	fr := &fakeRelayer{}
	c := testClient(t)
	c.Cfg.HubURL, c.Cfg.Tenant = url, "t1"
	c.ReadyTimeout, c.KeepAlive = 10*time.Second, -1
	c.SigninRelay = fr
	sess, err := c.Dial(context.Background(), wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	if h := <-hello; !slices.Contains(h.Features, wire.FeatureSigninRelay) {
		t.Fatalf("hello features %v lack %s", h.Features, wire.FeatureSigninRelay)
	}
	frame := func(id, op string) wire.Frame {
		raw, _ := json.Marshal(wire.SigninRelayLane{ID: id, Op: op, Kind: "claude"})
		return wire.Frame{Type: wire.TSigninRelay, MsgID: "r-1", Lane: raw}
	}
	ask <- frame("f-1", wire.SigninOpStart)
	select {
	case o := <-outs:
		var l wire.SigninRelayOutLane
		if json.Unmarshal(o.Lane, &l) != nil || o.MsgID != "r-1" || l.State != wire.SigninStateDelivered {
			t.Fatalf("signin_relay_out %+v", o)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no signin_relay_out")
	}
	ask <- frame("f-1", wire.SigninOpStart) // the same frame again: dropped
	ask <- frame("f-2", wire.SigninOpEnd)   // runs, reports nothing
	deadline := time.Now().Add(5 * time.Second)
	for fr.count() < 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if n := fr.count(); n != 2 {
		t.Fatalf("%d runs, want 2 (f-1 once, f-2 once)", n)
	}
	select {
	case o := <-outs:
		t.Fatalf("a report for a run with no state, or a repeat: %+v", o)
	case <-time.After(200 * time.Millisecond):
	}

	url2, hello2, _, _ := relayHub(t)
	c2 := testClient(t)
	c2.Cfg.HubURL, c2.Cfg.Tenant = url2, "t1"
	c2.ReadyTimeout, c2.KeepAlive = 10*time.Second, -1
	s2, err := c2.Dial(context.Background(), wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	if h := <-hello2; slices.Contains(h.Features, wire.FeatureSigninRelay) {
		t.Fatal("CONTROL: a box with no relayer says signin_relay")
	}
}
