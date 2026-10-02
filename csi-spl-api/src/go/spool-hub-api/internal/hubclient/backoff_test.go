package hubclient

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// busyHub answers the first `busy` WS upgrades with status (and Retry-After
// when set), then accepts and speaks the challenge/welcome handshake. It
// records when each upgrade arrived.
type busyHub struct {
	busy       int
	status     int
	retryAfter string

	mu    sync.Mutex
	times []time.Time
}

func (h *busyHub) start(t *testing.T) string {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		h.times = append(h.times, time.Now())
		n := len(h.times)
		h.mu.Unlock()
		if n <= h.busy {
			if h.retryAfter != "" {
				w.Header().Set("Retry-After", h.retryAfter)
			}
			http.Error(w, "no available instance", h.status)
			return
		}
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := r.Context()
		var hello wire.Frame
		if wsjson.Write(ctx, conn, challenge) != nil || wsjson.Read(ctx, conn, &hello) != nil || wsjson.Write(ctx, conn, welcome) != nil {
			return
		}
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL
}

func (h *busyHub) gaps() []time.Duration {
	h.mu.Lock()
	defer h.mu.Unlock()
	var g []time.Duration
	for i := 1; i < len(h.times); i++ {
		g = append(g, h.times[i].Sub(h.times[i-1]))
	}
	return g
}

// withDialBudget shortens the single-shot retry for one test and pins the
// jitter to the top of its range (full = true) so spacing is deterministic.
func withDialBudget(t *testing.T, retries int, base, maxd, hintMax time.Duration, full bool) {
	t.Helper()
	r, b, m, h, j := dialRetries, dialRetryBase, dialRetryMax, dialRetryAfterMax, jitter
	dialRetries, dialRetryBase, dialRetryMax, dialRetryAfterMax = retries, base, maxd, hintMax
	if full {
		jitter = func(n int64) int64 { return n - 1 }
	}
	t.Cleanup(func() { dialRetries, dialRetryBase, dialRetryMax, dialRetryAfterMax, jitter = r, b, m, h, j })
}

func dialBusy(t *testing.T, h *busyHub) (*Session, error) {
	t.Helper()
	c := testClient(t)
	c.Cfg.HubURL = h.start(t)
	c.Cfg.Tenant = "t1"
	c.Cfg.SubmitSocket = "off"
	c.ReadyTimeout = 10 * time.Second
	return c.Dial(context.Background(), wire.RoleCLI)
}

// A single-shot dial survives 429s (no Retry-After) and the spacing grows
// with the exponent until the cap.
func TestDialRetries429GrowingCapped(t *testing.T) {
	const base, capd = 40 * time.Millisecond, 100 * time.Millisecond
	withDialBudget(t, 4, base, capd, time.Second, true)
	h := &busyHub{busy: 4, status: http.StatusTooManyRequests}
	s, err := dialBusy(t, h)
	if err != nil {
		t.Fatalf("dial after 4 x 429: %v", err)
	}
	s.Close()
	g := h.gaps()
	if len(g) != 4 {
		t.Fatalf("want 5 upgrades (4 x 429 + 101), got gaps %v", g)
	}
	// pinned jitter = the ceiling: 40, 80, 100 (capped), 100 ms
	want := []time.Duration{base, 2 * base, capd, capd}
	for i, w := range want {
		if g[i] < w || g[i] > w+80*time.Millisecond {
			t.Errorf("gap %d = %v, want ~%v (all gaps %v)", i, g[i], w, g)
		}
	}
	if !(g[1] > g[0]) {
		t.Errorf("spacing did not grow: %v", g)
	}
}

// Retry-After is honoured as the floor of the wait.
func TestDialHonoursRetryAfter(t *testing.T) {
	withDialBudget(t, 2, 10*time.Millisecond, 20*time.Millisecond, 3*time.Second, false)
	h := &busyHub{busy: 1, status: http.StatusTooManyRequests, retryAfter: "1"}
	s, err := dialBusy(t, h)
	if err != nil {
		t.Fatalf("dial after 429 Retry-After 1: %v", err)
	}
	s.Close()
	g := h.gaps()
	if len(g) != 1 || g[0] < time.Second || g[0] > time.Second+500*time.Millisecond {
		t.Fatalf("want one ~1 s gap after Retry-After: 1, got %v", g)
	}
}

// A 503 counts as busy too; the budget is small and then the dial reports
// unreachable carrying the status and Retry-After.
func TestDialGivesUpAfterBudget(t *testing.T) {
	withDialBudget(t, 2, 5*time.Millisecond, 10*time.Millisecond, 50*time.Millisecond, false)
	h := &busyHub{busy: 99, status: http.StatusServiceUnavailable, retryAfter: "7"}
	_, err := dialBusy(t, h)
	var se *DialStatusError
	if !errors.Is(err, ErrUnreachable) || !errors.As(err, &se) || se.Status != 503 || se.RetryAfter != 7*time.Second {
		t.Fatalf("want ErrUnreachable{503, 7s}, got %#v", err)
	}
	if n := len(h.gaps()) + 1; n != 3 {
		t.Fatalf("want 3 upgrades (1 + 2 retries), got %d", n)
	}
	if retryAfterOf(err) != 7*time.Second {
		t.Fatalf("retryAfterOf = %v", retryAfterOf(err))
	}
}

// Not busy = not retried: a 401 answers at once.
func TestDialNoRetryOnRefusal(t *testing.T) {
	withDialBudget(t, 2, 5*time.Millisecond, 10*time.Millisecond, 50*time.Millisecond, false)
	h := &busyHub{busy: 99, status: http.StatusUnauthorized}
	if _, err := dialBusy(t, h); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("want ErrUnreachable, got %v", err)
	}
	if n := len(h.gaps()) + 1; n != 1 {
		t.Fatalf("a 401 was retried: %d upgrades", n)
	}
}

// The daemon's backoff: the ceiling doubles to the cap, every draw lies in
// [0, ceiling] and the draws are actually spread (full jitter), a Retry-After
// is the floor, and reset starts over.
func TestBackoffFullJitterCapped(t *testing.T) {
	b := newBackoff(time.Second, 30*time.Second, 30*time.Second)
	b.rnd = func(n int64) int64 { return n - 1 }
	want := []time.Duration{1, 2, 4, 8, 16, 30, 30}
	for i, w := range want {
		if got := b.next(0); got != w*time.Second {
			t.Fatalf("wait %d = %v, want %v", i, got, w*time.Second)
		}
	}
	b.reset()
	if got := b.next(0); got != time.Second {
		t.Fatalf("after reset: %v", got)
	}
	// Retry-After 5 s floor + half the jitter (ceiling 2 s here)
	if got := b.next(5 * time.Second); got != 6*time.Second {
		t.Fatalf("Retry-After wait %v, want 6s", got)
	}
	// a hint is clamped to hintMax
	b2 := newBackoff(time.Second, 30*time.Second, 30*time.Second)
	b2.rnd = func(int64) int64 { return 0 }
	if got := b2.next(time.Hour); got != 30*time.Second {
		t.Fatalf("clamped hint %v", got)
	}

	// real jitter: draws stay in range and are not all the same
	seen := map[time.Duration]bool{}
	for range 200 {
		r := newBackoff(time.Second, 30*time.Second, 30*time.Second)
		r.n = 3 // ceiling 8 s
		d := r.next(0)
		if d < 0 || d > 8*time.Second {
			t.Fatalf("draw %v outside [0, 8s]", d)
		}
		seen[d] = true
	}
	if len(seen) < 100 {
		t.Fatalf("jitter not spread: %d distinct of 200", len(seen))
	}
}

func TestParseRetryAfter(t *testing.T) {
	now := time.Date(2026, 10, 2, 5, 13, 0, 0, time.UTC)
	cases := map[string]time.Duration{
		"":                              0,
		"3":                             3 * time.Second,
		"-1":                            0,
		"soon":                          0,
		"Fri, 02 Oct 2026 05:13:04 GMT": 4 * time.Second,
		"Fri, 02 Oct 2026 05:12:00 GMT": 0,
	}
	for in, want := range cases {
		if got := parseRetryAfter(in, now); got != want {
			t.Errorf("%q: %v, want %v", in, got, want)
		}
	}
}
