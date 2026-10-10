package edge_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
)

// r6-06: the Guard in front of the hub mux - which paths it counts, what a
// refusal answers, and that a socket's slot is given back when it ends.

// guardReq is a request to path from the TCP peer ip.
func guardReq(method, path, ip string) *http.Request {
	r := httptest.NewRequest(method, "http://hub"+path, nil)
	r.RemoteAddr = ip + ":4000"
	return r
}

func TestGuardRates(t *testing.T) {
	cases := []struct {
		name   string
		l      edge.Limits
		method string
		path   string
		n      int // requests from one ip
		wantOK int // how many reach next
		bucket string
	}{
		{"auth over the per-ip rate", edge.Limits{AuthPerIP: 2}, http.MethodPost, edge.PrefixAuth + "login", 3, 2, "auth_rate"},
		{"auth preflight never counted", edge.Limits{AuthPerIP: 1}, http.MethodOptions, edge.PrefixAuth + "login", 3, 3, ""},
		{"auth limit 0 is off", edge.Limits{}, http.MethodPost, edge.PrefixAuth + "login", 5, 5, ""},
		{"other paths never counted", edge.Limits{AuthPerIP: 1, WSConnsTotal: 1}, http.MethodGet, "/v1/pins", 4, 4, ""},
		{"box socket handshakes over the rate", edge.Limits{WSHandshakesPerIP: 2}, http.MethodGet, edge.PathBoxWS, 3, 2, "ws_handshake_rate"},
		{"wui socket handshakes over the rate", edge.Limits{WSHandshakesPerIP: 1}, http.MethodGet, edge.PathWUIWS, 2, 1, "ws_handshake_rate"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var logs bytes.Buffer
			now := time.Unix(1000, 0)
			g := edge.NewGuard(c.l, zerolog.New(&logs), func() time.Time { return now })
			reached := 0
			h := g.Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { reached++ }))
			var last *httptest.ResponseRecorder
			for i := 0; i < c.n; i++ {
				last = httptest.NewRecorder()
				h.ServeHTTP(last, guardReq(c.method, c.path, "192.0.2.10"))
			}
			if reached != c.wantOK {
				t.Fatalf("next reached %d times, want %d", reached, c.wantOK)
			}
			if c.bucket == "" {
				if last.Code != http.StatusOK || logs.Len() != 0 {
					t.Fatalf("not limited: code %d, log %q", last.Code, logs.String())
				}
				return
			}
			assertRefused(t, last, c.bucket)
			if !strings.Contains(logs.String(), `"bucket":"`+c.bucket+`"`) || strings.Contains(logs.String(), "192.0.2.10") {
				t.Errorf("log %q: want the bucket, never the address", logs.String())
			}
			// another caller has its own bucket
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, guardReq(c.method, c.path, "192.0.2.11"))
			if rec.Code != http.StatusOK {
				t.Errorf("a second ip was refused: %d", rec.Code)
			}
		})
	}
}

// assertRefused checks a 429 with the shared error body, Retry-After and no-store.
func assertRefused(t *testing.T, rec *httptest.ResponseRecorder, bucket string) {
	t.Helper()
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("code %d, want 429", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" || rec.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("headers %v", rec.Header())
	}
	var body struct{ Error, Detail string }
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body.Error != edge.TokenLimited || body.Detail != bucket {
		t.Errorf("body %q (%v), want %s/%s", rec.Body.String(), err, edge.TokenLimited, bucket)
	}
}

// TestGuardRetryAfter: the header is the whole seconds until the oldest
// attempt leaves the window, plus one.
func TestGuardRetryAfter(t *testing.T) {
	now := time.Unix(1000, 0)
	g := edge.NewGuard(edge.Limits{AuthPerIP: 1, Window: 30 * time.Second}, zerolog.Nop(), func() time.Time { return now })
	h := g.Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	h.ServeHTTP(httptest.NewRecorder(), guardReq(http.MethodPost, edge.PrefixAuth+"x", "192.0.2.1"))
	now = now.Add(10 * time.Second)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, guardReq(http.MethodPost, edge.PrefixAuth+"x", "192.0.2.1"))
	if got := rec.Header().Get("Retry-After"); got != "21" {
		t.Fatalf("Retry-After %q, want 21", got)
	}
}

// TestGuardDefaultWindow: a zero Window is one minute.
func TestGuardDefaultWindow(t *testing.T) {
	now := time.Unix(1000, 0)
	g := edge.NewGuard(edge.Limits{AuthPerIP: 1}, zerolog.Nop(), func() time.Time { return now })
	h := g.Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	send := func() int {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, guardReq(http.MethodPost, edge.PrefixAuth+"x", "192.0.2.1"))
		return rec.Code
	}
	send()
	now = now.Add(59 * time.Second)
	if c := send(); c != http.StatusTooManyRequests {
		t.Fatalf("inside the minute: %d", c)
	}
	now = now.Add(2 * time.Second)
	if c := send(); c != http.StatusOK {
		t.Fatalf("after the minute: %d", c)
	}
}

// TestGuardSocketCaps holds sockets open in next, so the per-ip and total
// caps count them, and checks each slot is released when next returns.
func TestGuardSocketCaps(t *testing.T) {
	cases := []struct {
		name   string
		l      edge.Limits
		ips    []string // one open socket each, in order
		wantOK int
		bucket string
	}{
		{"per ip", edge.Limits{WSConnsPerIP: 2}, []string{"192.0.2.1", "192.0.2.1", "192.0.2.1", "192.0.2.2"}, 3, "ws_conns_per_ip"},
		{"total", edge.Limits{WSConnsTotal: 2}, []string{"192.0.2.1", "192.0.2.2", "192.0.2.3"}, 2, "ws_conns_total"},
		{"no caps", edge.Limits{}, []string{"192.0.2.1", "192.0.2.1", "192.0.2.1"}, 3, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			g := edge.NewGuard(c.l, zerolog.Nop(), nil)
			hold := make(chan struct{})
			entered := make(chan struct{}, len(c.ips))
			h := g.Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
				entered <- struct{}{}
				<-hold
			}))
			var wg sync.WaitGroup
			var refused []*httptest.ResponseRecorder
			ok := 0
			for _, ip := range c.ips {
				rec := httptest.NewRecorder()
				done := make(chan struct{})
				wg.Add(1)
				go func() {
					defer wg.Done()
					defer close(done)
					h.ServeHTTP(rec, guardReq(http.MethodGet, edge.PathBoxWS, ip))
				}()
				select { // either it is held open in next, or it was refused
				case <-entered:
					ok++
				case <-done:
					refused = append(refused, rec)
				}
			}
			if ok != c.wantOK {
				t.Fatalf("open %d, want %d", ok, c.wantOK)
			}
			if total, _ := g.Open(); total != c.wantOK {
				t.Errorf("Open total %d, want %d", total, c.wantOK)
			}
			for _, rec := range refused {
				assertRefused(t, rec, c.bucket)
				if rec.Header().Get("Retry-After") != "11" {
					t.Errorf("Retry-After %q, want 11", rec.Header().Get("Retry-After"))
				}
			}
			close(hold)
			wg.Wait()
			if total, per := g.Open(); total != 0 || len(per) != 0 {
				t.Fatalf("after close: total %d, per ip %v", total, per)
			}
		})
	}
}

// TestGuardOpenCopies: the per-ip map Open returns is a copy.
func TestGuardOpenCopies(t *testing.T) {
	g := edge.NewGuard(edge.Limits{}, zerolog.Nop(), nil)
	hold, in := make(chan struct{}), make(chan struct{})
	done := make(chan struct{})
	h := g.Wrap(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { in <- struct{}{}; <-hold }))
	go func() {
		defer close(done)
		h.ServeHTTP(httptest.NewRecorder(), guardReq(http.MethodGet, edge.PathWUIWS, "192.0.2.5"))
	}()
	<-in
	_, per := g.Open()
	per["192.0.2.5"] = 99
	if _, again := g.Open(); again["192.0.2.5"] != 1 {
		t.Fatalf("Open shares its map: %v", again)
	}
	close(hold)
	<-done
}

func TestGuardProbe(t *testing.T) {
	cases := []struct {
		name   string
		hops   int
		remote string
		xff    []string
		peer   string
		chain  []string
		client string
	}{
		{"no header", 1, "10.0.0.9:5555", nil, "10.0.0.9", []string{}, "10.0.0.9"},
		{"one hop", 1, "10.0.0.9:5555", []string{"192.0.2.1, 198.51.100.7"}, "10.0.0.9", []string{"192.0.2.1", "198.51.100.7"}, "198.51.100.7"},
		{"hops 0 ignores the chain", 0, "10.0.0.9:5555", []string{"192.0.2.1"}, "10.0.0.9", []string{"192.0.2.1"}, "10.0.0.9"},
		{"peer without a port", 0, "10.0.0.9", nil, "10.0.0.9", []string{}, "10.0.0.9"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			g := edge.NewGuard(edge.Limits{TrustedProxyHops: c.hops}, zerolog.Nop(), nil)
			r := httptest.NewRequest(http.MethodGet, "http://hub"+edge.PathProbe, nil)
			r.RemoteAddr = c.remote
			for _, v := range c.xff {
				r.Header.Add("X-Forwarded-For", v)
			}
			rec := httptest.NewRecorder()
			g.Probe(rec, r)
			if rec.Code != http.StatusOK || rec.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("code %d headers %v", rec.Code, rec.Header())
			}
			var got struct {
				Peer   string   `json:"peer"`
				XFF    []string `json:"x_forwarded_for"`
				Hops   int      `json:"trusted_proxy_hops"`
				Client string   `json:"client_ip"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			if got.XFF == nil || strings.Join(got.XFF, ",") != strings.Join(c.chain, ",") {
				t.Errorf("x_forwarded_for %v, want %v (never null)", got.XFF, c.chain)
			}
			if got.Peer != c.peer || got.Hops != c.hops || got.Client != c.client {
				t.Errorf("got %+v", got)
			}
			if g.ClientIP(r) != c.client {
				t.Errorf("Guard.ClientIP %q, want %q", g.ClientIP(r), c.client)
			}
		})
	}
}

// TestWindowSweep: a key whose last attempt left the window is dropped by
// the sweep, and a later attempt starts a fresh bucket.
func TestWindowSweep(t *testing.T) {
	now := time.Unix(0, 0)
	w := edge.NewWindow(time.Minute, func() time.Time { return now })
	for _, k := range []string{"a", "b"} {
		if ok, _ := w.Allow(k, 1); !ok {
			t.Fatal(k)
		}
	}
	now = now.Add(2 * time.Minute)
	for _, k := range []string{"a", "b"} {
		if ok, _ := w.Allow(k, 1); !ok {
			t.Fatalf("%s still limited after the sweep", k)
		}
	}
	if ok, _ := w.Allow("a", 1); ok {
		t.Fatal("the fresh bucket allowed a second attempt")
	}
}

// TestNewWindowNilClock: a nil clock is time.Now.
func TestNewWindowNilClock(t *testing.T) {
	w := edge.NewWindow(time.Hour, nil)
	if ok, _ := w.Allow("k", 1); !ok {
		t.Fatal("first attempt refused")
	}
	if ok, retry := w.Allow("k", 1); ok || retry <= 0 || retry > time.Hour {
		t.Fatalf("second: ok=%v retry=%v", ok, retry)
	}
}
