// Package edge is the hub's own edge protection (spec 017 FR-SEC-004): with no
// load balancer and no Cloud Armor in front of Cloud Run (owner 2026-09-19),
// the per-client-IP limits on the sockets and on sign-in live in the process.
// With max_instances=1 (OQ-05) that one process sees every request, so an
// in-memory count is the whole count.
//
// It also owns the one answer to "who is calling" (FR-SEC-006): ClientIP,
// which native auth (spec 015) uses too, so both key on the same address.
package edge

import (
	"encoding/json"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ClientIP picks the caller's address: the TCP peer when hops is 0, else the
// hops-th X-Forwarded-For entry from the right. Each of the `hops` trusted
// proxies appends the address it received from, so that entry was written by
// the outermost trusted proxy; entries further left are caller-supplied and
// never used, so rotating a spoofed header does not move the key. Too few
// entries fall back to the TCP peer. hops must be the MEASURED chain of the
// path in service (csi-spl-orc do_spl_probe_client_ip): too few collapses
// every caller into the proxy's bucket, too many keys on a caller's entry.
func ClientIP(r *http.Request, hops int) string {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	if hops <= 0 {
		return peer
	}
	parts := forwarded(r)
	if i := len(parts) - hops; i >= 0 && i < len(parts) {
		return parts[i]
	}
	return peer
}

func forwarded(r *http.Request) []string {
	var parts []string
	for _, h := range r.Header.Values("X-Forwarded-For") {
		for _, p := range strings.Split(h, ",") {
			if p = strings.TrimSpace(p); p != "" {
				parts = append(parts, p)
			}
		}
	}
	return parts
}

// Window is a per-key sliding-window counter (spec 015 FR-006b). It is per
// process: it stops a burst at one instance, while a floor that must hold
// across instances lives in the database.
type Window struct {
	mu     sync.Mutex
	window time.Duration
	hits   map[string][]time.Time
	now    func() time.Time
	sweep  time.Time
}

// NewWindow returns a Window of the given length; now nil = time.Now.
func NewWindow(window time.Duration, now func() time.Time) *Window {
	if now == nil {
		now = time.Now
	}
	return &Window{window: window, hits: map[string][]time.Time{}, now: now}
}

// Allow records one attempt for key and reports whether it is within max.
// When refused, retry is how long until the oldest attempt leaves the window.
func (l *Window) Allow(key string, max int) (ok bool, retry time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	cut := now.Add(-l.window)
	if now.Sub(l.sweep) > l.window {
		for k, v := range l.hits {
			if len(v) == 0 || !v[len(v)-1].After(cut) {
				delete(l.hits, k)
			}
		}
		l.sweep = now
	}
	v := l.hits[key]
	i := 0
	for i < len(v) && !v[i].After(cut) {
		i++
	}
	v = v[i:]
	if len(v) >= max {
		l.hits[key] = v
		return false, v[0].Add(l.window).Sub(now)
	}
	l.hits[key] = append(v, now)
	return true, 0
}

// Limits is cnf hub.env SPOOL_HUB_EDGE_* (config.Hub). A limit of 0 is off.
type Limits struct {
	TrustedProxyHops  int
	Window            time.Duration // the rate window of the two per-IP rates
	WSConnsPerIP      int           // open /v1/ws + /v1/wui/ws sockets per client IP
	WSConnsTotal      int           // open sockets, all callers: keep < Cloud Run concurrency
	WSHandshakesPerIP int           // socket handshakes per client IP per Window
	AuthPerIP         int           // /api/v1/auth/* requests per client IP per Window
}

// Socket paths the connection caps apply to.
const (
	PathBoxWS    = "/v1/ws"
	PathWUIWS    = "/v1/wui/ws"
	PrefixAuth   = "/api/v1/auth/"
	PathProbe    = "/v1/debug/client-ip"
	TokenLimited = "rate_limited"
)

// Guard enforces Limits in front of the hub mux.
type Guard struct {
	l     Limits
	win   *Window
	log   zerolog.Logger
	mu    sync.Mutex
	open  map[string]int
	total int
}

// NewGuard returns a Guard; now nil = time.Now.
func NewGuard(l Limits, log zerolog.Logger, now func() time.Time) *Guard {
	if l.Window <= 0 {
		l.Window = time.Minute
	}
	return &Guard{l: l, win: NewWindow(l.Window, now), log: log, open: map[string]int{}}
}

// ClientIP is ClientIP with the Guard's hops.
func (g *Guard) ClientIP(r *http.Request) string { return ClientIP(r, g.l.TrustedProxyHops) }

// Open reports the sockets currently held (tests, probes).
func (g *Guard) Open() (total int, perIP map[string]int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	m := make(map[string]int, len(g.open))
	for k, v := range g.open {
		m[k] = v
	}
	return g.total, m
}

// Wrap applies the limits, then next. A refused socket is answered before the
// upgrade, so it never holds a Cloud Run request slot.
func (g *Guard) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch p := r.URL.Path; {
		case p == PathBoxWS || p == PathWUIWS:
			ip := g.ClientIP(r)
			if g.l.WSHandshakesPerIP > 0 {
				if ok, retry := g.win.Allow("ws:"+ip, g.l.WSHandshakesPerIP); !ok {
					g.refuse(w, retry, "ws_handshake_rate", p)
					return
				}
			}
			if bucket, ok := g.acquire(ip); !ok {
				g.refuse(w, 10*time.Second, bucket, p)
				return
			}
			defer g.release(ip)
		case strings.HasPrefix(p, PrefixAuth) && r.Method != http.MethodOptions:
			if g.l.AuthPerIP > 0 {
				if ok, retry := g.win.Allow("auth:"+g.ClientIP(r), g.l.AuthPerIP); !ok {
					g.refuse(w, retry, "auth_rate", PrefixAuth+"*")
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}

func (g *Guard) acquire(ip string) (bucket string, ok bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.l.WSConnsTotal > 0 && g.total >= g.l.WSConnsTotal {
		return "ws_conns_total", false
	}
	if g.l.WSConnsPerIP > 0 && g.open[ip] >= g.l.WSConnsPerIP {
		return "ws_conns_per_ip", false
	}
	g.open[ip]++
	g.total++
	return "", true
}

func (g *Guard) release(ip string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.total--
	if g.open[ip]--; g.open[ip] <= 0 {
		delete(g.open, ip)
	}
}

// refuse answers 429 + Retry-After. The log names the bucket and the path,
// never the address (Constitution VII: no caller identity in logs).
func (g *Guard) refuse(w http.ResponseWriter, retry time.Duration, bucket, path string) {
	w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusTooManyRequests)
	json.NewEncoder(w).Encode(wire.ErrorBody{Error: TokenLimited, Detail: bucket}) //nolint:errcheck
	g.log.Warn().Str("bucket", bucket).Str("path", path).Msg("edge.rate_limited")
}

// Probe answers GET /v1/debug/client-ip (cnf SPOOL_HUB_CLIENT_IP_PROBE): the
// X-Forwarded-For chain as the hub received it, the TCP peer, and the address
// the limits key on. It is how the hops of a new path are measured instead of
// assumed (017 T012). It echoes only what the caller's own request carried.
func (g *Guard) Probe(w http.ResponseWriter, r *http.Request) {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	xff := forwarded(r)
	if xff == nil {
		xff = []string{}
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(map[string]any{ //nolint:errcheck
		"peer": peer, "x_forwarded_for": xff, "trusted_proxy_hops": g.l.TrustedProxyHops,
		"client_ip": g.ClientIP(r),
	})
}
