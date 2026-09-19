package auth

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// limiter is a per-key sliding-window counter (spec 015 FR-006b). It is per
// process: it stops a burst at one instance, while the per-account mail floor
// that must hold across instances lives in the database.
type limiter struct {
	mu     sync.Mutex
	window time.Duration
	hits   map[string][]time.Time
	now    func() time.Time
	sweep  time.Time
}

func newLimiter(window time.Duration, now func() time.Time) *limiter {
	return &limiter{window: window, hits: map[string][]time.Time{}, now: now}
}

// allow records one attempt for key and reports whether it is within max.
// When refused, retry is how long until the oldest attempt leaves the window.
func (l *limiter) allow(key string, max int) (ok bool, retry time.Duration) {
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

// clientIP picks the caller's address: the TCP peer when hops is 0, else the
// hops-th X-Forwarded-For entry from the right. Each of the `hops` trusted
// proxies appends the address it received from, so that entry was written by
// the outermost trusted proxy; entries further left are caller-supplied and
// never used. Too few entries fall back to the TCP peer.
func clientIP(r *http.Request, hops int) string {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	if hops <= 0 {
		return peer
	}
	var parts []string
	for _, h := range r.Header.Values("X-Forwarded-For") {
		for _, p := range strings.Split(h, ",") {
			if p = strings.TrimSpace(p); p != "" {
				parts = append(parts, p)
			}
		}
	}
	if i := len(parts) - hops; i >= 0 && i < len(parts) {
		return parts[i]
	}
	return peer
}
