package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// 017 FR-SEC-004 / FR-SEC-006: the in-app edge limits. The hub runs behind
// one trusted proxy here (hops=1), so the client IP is the LAST
// X-Forwarded-For entry and everything left of it is the caller's to invent.

const trustedEntry = "198.51.100.7" // what the trusted proxy appended

// xff is a request header as the proxy forwards it: a caller-written
// (spoofable) entry, then the address the proxy saw.
func xff(spoof, real string) http.Header {
	h := http.Header{}
	h.Set("X-Forwarded-For", spoof+", "+real)
	return h
}

// dialWS opens a socket; it returns the connection or the HTTP status of a
// refused handshake.
func (e *env) dialWS(tenant, path string, h http.Header) (*websocket.Conn, int) {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, resp, err := websocket.Dial(ctx, "ws://"+tenant+domain+path, &websocket.DialOptions{HTTPClient: e.client, HTTPHeader: h})
	if err != nil {
		if resp == nil {
			e.t.Fatalf("dial %s: %v", path, err)
		}
		return nil, resp.StatusCode
	}
	e.t.Cleanup(func() { c.CloseNow() }) //nolint:errcheck
	return c, http.StatusSwitchingProtocols
}

func edgeOn(l edge.Limits) func(*hub.Options) {
	return func(o *hub.Options) { l.TrustedProxyHops = 1; o.Edge = l }
}

// CONTROL: the flood that exhausts one caller's share. Before (limits off) the
// n+1-th socket from one address opens; after, it is 429 before the upgrade,
// and rotating the spoofed X-Forwarded-For entry does not open it either.
func TestEdgeWSConnsPerIPControl(t *testing.T) {
	const n = 3
	before := newEnv(t, func(o *hub.Options) { o.Edge = edge.Limits{TrustedProxyHops: 1} })
	tb, _ := before.tenant()
	for i := 0; i <= n; i++ {
		if _, st := before.dialWS(tb, edge.PathBoxWS, xff(fmt.Sprintf("203.0.113.%d", i), trustedEntry)); st != http.StatusSwitchingProtocols {
			t.Fatalf("before: socket %d refused %d; the control must show the flood succeeding", i, st)
		}
	}

	after := newEnv(t, edgeOn(edge.Limits{WSConnsPerIP: n}))
	ta, _ := after.tenant()
	for i := 0; i < n; i++ {
		if _, st := after.dialWS(ta, edge.PathBoxWS, xff("203.0.113.1", trustedEntry)); st != http.StatusSwitchingProtocols {
			t.Fatalf("after: socket %d within the cap refused %d", i, st)
		}
	}
	for i := 0; i < 5; i++ { // the spoof: a fresh caller-written entry each time
		if _, st := after.dialWS(ta, edge.PathBoxWS, xff(fmt.Sprintf("192.0.2.%d", i), trustedEntry)); st != http.StatusTooManyRequests {
			t.Fatalf("after: spoofed X-Forwarded-For #%d opened a socket over the cap (status %d)", i, st)
		}
	}
	if _, st := after.dialWS(ta, edge.PathWUIWS, xff("x", trustedEntry)); st != http.StatusTooManyRequests {
		t.Fatalf("/v1/wui/ws shares the per-IP cap: got %d", st)
	}
	if _, st := after.dialWS(ta, edge.PathBoxWS, xff("203.0.113.1", "198.51.100.8")); st != http.StatusSwitchingProtocols {
		t.Fatalf("another client IP is not limited by the first one's cap: got %d", st)
	}
}

// The test has teeth: with hops set one too high, the key is the caller's
// entry and the same spoof walks through. This is the misconfiguration
// FR-SEC-006 exists to prevent, measured here so the control above means it.
func TestEdgeHopsTooHighIsSpoofable(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.Edge = edge.Limits{TrustedProxyHops: 2, WSConnsPerIP: 1} })
	tn, _ := e.tenant()
	for i := 0; i < 3; i++ {
		if _, st := e.dialWS(tn, edge.PathBoxWS, xff(fmt.Sprintf("192.0.2.%d", i), trustedEntry)); st != http.StatusSwitchingProtocols {
			t.Fatalf("hops=2 behind one proxy should key on the spoofed entry; socket %d got %d", i, st)
		}
	}
}

func TestEdgeWSHandshakeRate(t *testing.T) {
	e := newEnv(t, edgeOn(edge.Limits{WSHandshakesPerIP: 2, Window: time.Minute}))
	tn, _ := e.tenant()
	for i := 0; i < 2; i++ {
		c, st := e.dialWS(tn, edge.PathBoxWS, xff("a", trustedEntry))
		if st != http.StatusSwitchingProtocols {
			t.Fatalf("handshake %d refused %d", i, st)
		}
		c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, resp, err := websocket.Dial(ctx, "ws://"+tn+domain+edge.PathBoxWS,
		&websocket.DialOptions{HTTPClient: e.client, HTTPHeader: xff("b", trustedEntry)})
	if err == nil || resp == nil || resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("third handshake in the window: want 429, got %v %v", resp, err)
	}
	if resp.Header.Get("Retry-After") == "" {
		t.Fatal("429 without Retry-After")
	}
}

func TestEdgeWSConnsTotal(t *testing.T) {
	e := newEnv(t, edgeOn(edge.Limits{WSConnsTotal: 2}))
	tn, _ := e.tenant()
	for i := 0; i < 2; i++ {
		if _, st := e.dialWS(tn, edge.PathBoxWS, xff("x", fmt.Sprintf("198.51.100.%d", 10+i))); st != http.StatusSwitchingProtocols {
			t.Fatalf("socket %d refused %d", i, st)
		}
	}
	if _, st := e.dialWS(tn, edge.PathBoxWS, xff("x", "198.51.100.99")); st != http.StatusTooManyRequests {
		t.Fatalf("global cap: want 429, got %d", st)
	}
	resp, err := e.client.Get(e.url(tn) + "/healthz") // REST keeps its slots
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz under a full socket cap: %v %v", resp, err)
	}
	resp.Body.Close()
}

// A refused or finished socket gives its slot back.
func TestEdgeWSSlotReleased(t *testing.T) {
	e := newEnv(t, edgeOn(edge.Limits{WSConnsPerIP: 1}))
	tn, _ := e.tenant()
	c, st := e.dialWS(tn, edge.PathBoxWS, xff("x", trustedEntry))
	if st != http.StatusSwitchingProtocols {
		t.Fatalf("first socket refused %d", st)
	}
	c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, st := e.dialWS(tn, edge.PathBoxWS, xff("x", trustedEntry)); st == http.StatusSwitchingProtocols {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the slot of a closed socket was never released")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// CONTROL for /api/v1/auth/*: before, the n+1-th request is served; after, it
// is 429 whatever the spoofed entry says, and a preflight is not charged.
func TestEdgeAuthPerIPControl(t *testing.T) {
	const n = 3
	get := func(e *env, tn string, h http.Header, method string) int {
		req, _ := http.NewRequest(method, e.url(tn)+"/api/v1/auth/session", nil)
		for k, v := range h {
			req.Header[k] = v
		}
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	before := newEnv(t, func(o *hub.Options) { o.Edge = edge.Limits{TrustedProxyHops: 1} })
	tb, _ := before.tenant()
	for i := 0; i <= n+2; i++ {
		if st := get(before, tb, xff("a", trustedEntry), http.MethodGet); st == http.StatusTooManyRequests {
			t.Fatalf("before: request %d limited with the limits off", i)
		}
	}
	after := newEnv(t, edgeOn(edge.Limits{AuthPerIP: n, Window: time.Minute}))
	ta, _ := after.tenant()
	for i := 0; i < 4; i++ {
		if st := get(after, ta, xff("a", trustedEntry), http.MethodOptions); st == http.StatusTooManyRequests {
			t.Fatal("a CORS preflight was charged")
		}
	}
	for i := 0; i < n; i++ {
		if st := get(after, ta, xff("a", trustedEntry), http.MethodGet); st == http.StatusTooManyRequests {
			t.Fatalf("after: request %d within the limit refused", i)
		}
	}
	for i := 0; i < 5; i++ {
		if st := get(after, ta, xff(fmt.Sprintf("192.0.2.%d", i), trustedEntry), http.MethodGet); st != http.StatusTooManyRequests {
			t.Fatalf("after: spoofed request %d got %d, want 429", i, st)
		}
	}
	if st := get(after, ta, http.Header{}, http.MethodGet); st == http.StatusTooManyRequests {
		t.Fatal("a caller with no X-Forwarded-For (TCP peer key) shares no bucket with the trusted entry")
	}
}

// Liveness: a socket whose peer stops answering pings is closed and its slot
// is released; with pings off the dead socket keeps it (the control).
func TestEdgeWSPingTimeoutFreesSlot(t *testing.T) {
	stuck := func(e *env, tn string) {
		c, st := e.dialWS(tn, edge.PathWUIWS, xff("x", trustedEntry))
		if st != http.StatusSwitchingProtocols {
			t.Fatalf("wui socket refused %d", st)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := wsjson.Write(ctx, c, map[string]string{"type": "hello"}); err != nil {
			t.Fatal(err)
		}
		var wel map[string]any
		if err := wsjson.Read(ctx, c, &wel); err != nil || wel["type"] != "welcome" {
			t.Fatalf("welcome: %v %v", wel, err)
		}
		// From here the client never reads again, so it never answers a ping.
	}
	opts := func(ping time.Duration) func(*hub.Options) {
		return func(o *hub.Options) {
			o.ViewDoor = hub.ViewDoorOff
			o.Edge = edge.Limits{TrustedProxyHops: 1, WSConnsPerIP: 1}
			o.PingInterval, o.PingTimeout = ping, 100*time.Millisecond
		}
	}

	off := newEnv(t, opts(0))
	to, _ := off.tenant()
	stuck(off, to)
	time.Sleep(500 * time.Millisecond)
	if _, st := off.dialWS(to, edge.PathWUIWS, xff("x", trustedEntry)); st != http.StatusTooManyRequests {
		t.Fatalf("control: with pings off the dead socket should still hold the slot, got %d", st)
	}

	on := newEnv(t, opts(50*time.Millisecond))
	tn, _ := on.tenant()
	stuck(on, tn)
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, st := on.dialWS(tn, edge.PathWUIWS, xff("x", trustedEntry)); st == http.StatusSwitchingProtocols {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("a peer that never answers pings kept its slot")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// The measurement endpoint (017 T012): off by default, and when on it shows
// the chain the hub received and the key the limits use.
func TestEdgeClientIPProbe(t *testing.T) {
	off := newEnv(t)
	resp, err := off.client.Get(off.url("any") + edge.PathProbe)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("probe mounted without SPOOL_HUB_CLIENT_IP_PROBE: %d", resp.StatusCode)
	}

	on := newEnv(t, edgeOn(edge.Limits{}), func(o *hub.Options) { o.ClientIPProbe = true })
	for _, p := range []string{edge.PathProbe, edge.PathProbeAuth} {
		probeOnce(t, on, p)
	}
}

func probeOnce(t *testing.T, on *env, path string) {
	req, _ := http.NewRequest(http.MethodGet, on.url("any")+path, nil)
	req.Header.Set("X-Forwarded-For", "192.0.2.1, "+trustedEntry)
	resp, err := on.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var got struct {
		Peer string   `json:"peer"`
		XFF  []string `json:"x_forwarded_for"`
		Hops int      `json:"trusted_proxy_hops"`
		IP   string   `json:"client_ip"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.IP != trustedEntry || got.Hops != 1 || len(got.XFF) != 2 || got.Peer != "127.0.0.1" {
		t.Fatalf("probe %s: %+v", path, got)
	}
}

// The 429 body is the hub's error envelope.
func TestEdgeRefusalBody(t *testing.T) {
	e := newEnv(t, edgeOn(edge.Limits{AuthPerIP: 1}))
	tn, _ := e.tenant()
	for i := 0; i < 2; i++ {
		req, _ := http.NewRequest(http.MethodGet, e.url(tn)+"/api/v1/auth/session", nil)
		req.Header.Set("X-Forwarded-For", trustedEntry)
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		var b wire.ErrorBody
		json.NewDecoder(resp.Body).Decode(&b) //nolint:errcheck
		resp.Body.Close()
		if i == 1 && (resp.StatusCode != http.StatusTooManyRequests || b.Error != edge.TokenLimited) {
			t.Fatalf("refusal: %d %+v", resp.StatusCode, b)
		}
	}
}

// A live peer (one that keeps reading, as the box client and browsers do)
// answers every ping and keeps its socket.
func TestEdgeWSPingKeepsLivePeer(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.PingInterval, o.PingTimeout = 30*time.Millisecond, 200*time.Millisecond
	})
	tn, _ := e.tenant()
	c, st := e.dialWS(tn, edge.PathWUIWS, nil)
	if st != http.StatusSwitchingProtocols {
		t.Fatalf("wui socket refused %d", st)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, c, map[string]string{"type": "hello"}); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		for {
			var f map[string]any
			if err := wsjson.Read(context.Background(), c, &f); err != nil {
				done <- err
				return
			}
		}
	}()
	select {
	case err := <-done:
		t.Fatalf("a reading peer was dropped: %v", err)
	case <-time.After(600 * time.Millisecond): // 20 ping intervals
	}
}
