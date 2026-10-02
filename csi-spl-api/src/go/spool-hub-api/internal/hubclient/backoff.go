package hubclient

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
)

// Reconnect backoff (CLE-77949). On 2026-10-02 a Cloud Run "no available
// instance" window answered 429 for ~2.5 min; this box's 15 hub-run and 13 mcp
// processes redialled in lockstep (9 ws 429s within 0.4 s) and the lease loop
// logged HUB-UNREACHABLE after ONE 429. Two layers fix that:
//   - dialWS: a single-shot Dial retries a 429/502/503/504 upgrade answer a
//     couple of times, briefly, so one rejected dial is not "unreachable";
//   - Run: the daemon's reconnect loop waits a capped, fully jittered,
//     exponentially growing delay, honours Retry-After, and resets only after
//     a session that stayed up for stableAfter.

// Single-shot dial retry budget. Package vars so tests can shorten them.
var (
	dialRetries       = 2                      // retries after the first attempt
	dialRetryBase     = 250 * time.Millisecond // first ceiling of the jitter
	dialRetryMax      = time.Second            // cap of the jittered part
	dialRetryAfterMax = 2 * time.Second        // a CLI waits at most this for Retry-After
)

// Daemon reconnect loop (Run).
var (
	runBackoffBase = time.Second
	runBackoffMax  = 30 * time.Second
	stableAfter    = time.Minute // a session up this long resets the backoff
)

// backoff is capped exponential backoff with full jitter: wait n is uniform in
// [0, min(max, base*2^n)]. A Retry-After hint is a floor the jitter is added
// on top of (so a fleet told "1" does not return in the same millisecond),
// clamped to hintMax.
type backoff struct {
	base, max, hintMax time.Duration
	n                  int
	rnd                func(n int64) int64
}

// jitter draws the uniform part of every wait; tests pin it.
var jitter = rand.Int64N

func newBackoff(base, max, hintMax time.Duration) *backoff {
	return &backoff{base: base, max: max, hintMax: hintMax, rnd: jitter}
}

// ceiling is the jitter range of the next wait.
func (b *backoff) ceiling() time.Duration {
	d := b.base
	for i := 0; i < b.n && d < b.max; i++ {
		d *= 2
	}
	return min(d, b.max)
}

// next returns the wait before the next attempt and advances the exponent.
func (b *backoff) next(retryAfter time.Duration) time.Duration {
	ceil := b.ceiling()
	b.n++
	d := time.Duration(b.rnd(int64(ceil) + 1))
	if retryAfter > 0 {
		d = min(retryAfter, b.hintMax) + d/2
	}
	return d
}

func (b *backoff) reset() { b.n = 0 }

// DialStatusError is a WS upgrade the hub (or its edge) answered with an HTTP
// status instead of 101. It is wrapped under ErrUnreachable.
type DialStatusError struct {
	Status     int
	RetryAfter time.Duration // 0 when absent or unparsable
	Err        error
}

func (e *DialStatusError) Error() string { return e.Err.Error() }
func (e *DialStatusError) Unwrap() error { return e.Err }

// retryable is an answer that means "busy, come back": rate limit or no
// instance, never a refusal of who we are.
func (e *DialStatusError) retryable() bool {
	switch e.Status {
	case http.StatusTooManyRequests, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return true
	}
	return false
}

// parseRetryAfter reads delta-seconds or an HTTP date; 0 when absent.
func parseRetryAfter(v string, now time.Time) time.Duration {
	v = strings.TrimSpace(v)
	if v == "" {
		return 0
	}
	if s, err := strconv.Atoi(v); err == nil {
		return max(time.Duration(s)*time.Second, 0)
	}
	if t, err := http.ParseTime(v); err == nil {
		return max(t.Sub(now), 0)
	}
	return 0
}

// retryAfterOf digs the hub's Retry-After out of a Dial error (0 if none).
func retryAfterOf(err error) time.Duration {
	var se *DialStatusError
	if errors.As(err, &se) {
		return se.RetryAfter
	}
	return 0
}

// dialWS is the WS upgrade with the single-shot retry: a retryable status is
// retried up to dialRetries times; anything else (a transport error, 401, 403,
// a hub close) returns at once.
func (c *Client) dialWS(ctx context.Context, wsURL string) (*websocket.Conn, error) {
	b := newBackoff(dialRetryBase, dialRetryMax, dialRetryAfterMax)
	for attempt := 0; ; attempt++ {
		conn, resp, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPClient: c.http(), HTTPHeader: c.TenantHeader()})
		if err == nil {
			return conn, nil
		}
		if resp == nil || resp.StatusCode == http.StatusSwitchingProtocols {
			return nil, fmt.Errorf("%w: %w", ErrUnreachable, err)
		}
		se := &DialStatusError{Status: resp.StatusCode, RetryAfter: parseRetryAfter(resp.Header.Get("Retry-After"), time.Now()), Err: err}
		if !se.retryable() || attempt >= dialRetries {
			return nil, fmt.Errorf("%w: %w", ErrUnreachable, se)
		}
		wait := b.next(se.RetryAfter)
		c.Log.Debug().Int("status", se.Status).Dur("retry_in", wait).Int("attempt", attempt+1).Msg("hub dial busy; retrying")
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("%w: %w", ErrUnreachable, se)
		case <-time.After(wait):
		}
	}
}
