package hubclient

import (
	"context"
	"errors"
	"time"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Make before break (SPL-6514, latency action 4, spec 059 section 12).
//
// Measured on the prd t1 desk of one box, 24 h to 2026-11-25 (lat-hub
// a-600): 315 session ends, 23 `submit refused` and 15 sends that waited
// for the 10 s scan tick. About 288 of the ends are the hub's own planned
// close: it ends every box socket at its max life (SPOOL_HUB_WS_MAX_LIFE
// 5 min, less a jitter of up to a fifth, so 4..5 min; hub/ws_maxlife.go).
// The other 28 were session-probe doors. Each one cost a gap: the old socket
// closed, the submit listener went with it, Run slept its backoff (0.5..1 s)
// and redialled.
//
// Now hub-run rotates its session itself, before the hub's earliest planned
// close: it dials and welcomes a new role=box session, hands it to the submit
// listener (which outlives every session), flushes on it, and only then
// closes the old one with 1012, which the hub reads as a roll, not a leave.
// A rotation dial that fails keeps the old session. The hub's own 1012, if
// it still comes first, is redialled at once with no backoff.
//
// The doors were false (same evidence: each of the 28 fell 0..20 min after a
// new hub revision, e.g. rev 02009 at 18:45:36Z, then 7 doors 18:49..18:58Z,
// each redial greeted by another door). While two revisions serve, the box's
// REST lands on either: a token minted by the revision that holds the socket
// is refused by the other one, though the socket's own revision is alive,
// answers pings and delivers (its relay and the store's wake run until it
// stops). With rotation on, a door no longer ends a live session: the next
// rotation dials onto whichever revision takes new sockets, so a socket left
// on a retired revision moves within RotateAfter, and in the meantime its
// queued rows are still delivered by that revision's relay.

const (
	// defaultRotateAfter is under the hub's earliest planned close (max life
	// 5 min less a fifth = 4 min), so the box swaps before the hub closes.
	defaultRotateAfter = 3*time.Minute + 45*time.Second
	// rotateRetry is the wait before another rotation after a failed dial.
	rotateRetry = 15 * time.Second
)

// rotateAfter is the session age at which hold swaps to a new session; 0 =
// off (Client.RotateAfter < 0).
func (c *Client) rotateAfter() time.Duration {
	switch {
	case c.RotateAfter < 0:
		return 0
	case c.RotateAfter == 0:
		return defaultRotateAfter
	}
	return c.RotateAfter
}

// rotates reports whether hold swaps sessions itself; then a door from the
// session probe or a pin sync no longer ends a session that still pongs.
func (c *Client) rotates() bool { return c.rotateAfter() > 0 }

// rotateTimer is the timer of the next rotation; its channel is nil (never
// ready) with rotation off.
func (c *Client) rotateTimer() (*time.Timer, <-chan time.Time) {
	d := c.rotateAfter()
	if d <= 0 {
		return nil, nil
	}
	t := time.NewTimer(d)
	return t, t.C
}

// rotate dials and welcomes the next role=box session under the daemon's
// ctx, makes it the submit listener's, and then closes old with 1012. It
// returns nil, keeping old, when the dial fails.
//
// A dial that reaches the same hub process as old supersedes old (4409) as
// soon as the hub registers it, before the welcome. When the dial then fails,
// old is already ending: holdOne reads that 4409 as the rotation's own
// (ended), not as another box process taking the link.
func (c *Client) rotate(ctx context.Context, old *Session, srv *SubmitServer) *Session {
	next, err := c.dialAs(ctx, wire.RoleBox, 0, true)
	if err != nil {
		c.Log.Warn().Err(err).Dur("retry_in", rotateRetry).Msg("session rotation dial failed; keeping the current session")
		return nil
	}
	srv.set(next)
	go old.closeRotated()
	c.Log.Info().Str("box", c.Cfg.BoxID).Msg("hub session rotated (make before break)")
	return next
}

// closeRotated ends a session that a newer one has replaced: 1012, which
// the hub reads as a roll (hub/ws.go), so the box never reads offline.
func (s *Session) closeRotated() {
	s.cancel()
	if s.dialCtx != nil && s.dialCtx.Err() != nil {
		s.conn.CloseNow() //nolint:errcheck
		return
	}
	s.conn.Close(websocket.StatusServiceRestart, "rotate") //nolint:errcheck
}

// plannedClose reports a session the hub ended at its max life (1012): the
// box redials at once instead of waiting its backoff.
func (s *Session) plannedClose() bool {
	return s.CloseCode() == websocket.StatusServiceRestart
}

// ended is holdOne's result for a session that has ended. A 4409 within
// rotateRetry of a failed rotation dial is that dial's own (rotate): the
// link is redialled at once, as a planned close, with no supersede yield
// and no re-hello. A 4409 from another box process in that same window is
// read the same way once; the next one is yielded to as before.
func (c *Client) ended(sess *Session, rotateFailed time.Time) (*Session, bool, error) {
	err := sess.endErr()
	if errors.Is(err, ErrSuperseded) && !rotateFailed.IsZero() && time.Since(rotateFailed) < rotateRetry {
		c.Log.Info().Str("box", c.Cfg.BoxID).Msg("the failed rotation dial superseded this session; redialling at once")
		return nil, true, nil
	}
	return nil, sess.plannedClose(), err
}
