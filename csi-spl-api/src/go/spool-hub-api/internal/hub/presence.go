package hub

import (
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Box presence across hub instances (t1 #spool-hub-ops b3bf3d13, owner: "now
// they claim to be offline, which obviously cannot be the case"). `online`
// was "THIS process holds the box's socket" (s.boxes). A Cloud Run roll
// leaves every box socket on the OLD revision until it dies, so the NEW
// revision, which answers every fresh roster read, called every machine
// offline after every hub deploy (redeploy_test.go, revision.go).
//
// online is now a fresh presence record every instance shares: the instance
// that holds the socket re-stamps boxes.last_hello_at (the WUI's "last seen")
// once per presenceEvery, and any instance reads a box online when that stamp
// is younger than presenceTTL. One write per box per interval, no DDL.

// defaultPresenceEvery is the stamp interval when no socket ping interval is
// configured (lde, tests); a deploy uses SPOOL_HUB_WS_PING_INTERVAL (30 s).
const defaultPresenceEvery = 30 * time.Second

func (s *Server) presenceEvery() time.Duration {
	if s.o.PingInterval > 0 {
		return s.o.PingInterval
	}
	return defaultPresenceEvery
}

// presenceTTL: two intervals, so one slow or failed stamp never blinks a box
// offline; a box gone without a close (half-open, its instance killed) reads
// offline within this.
func (s *Server) presenceTTL() time.Duration { return 2 * s.presenceEvery() }

// stampPresence re-stamps x's box every presenceEvery while x is the box's
// registered socket on this instance, until ctx ends.
func (s *Server) stampPresence(ctx context.Context, x *session) {
	t := time.NewTicker(s.presenceEvery())
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if s.boxSession(x.tenant, x.box) != x {
				return // superseded or dropped: the new socket stamps
			}
			if err := s.o.Store.TouchBox(ctx, x.tenant, x.box, s.o.Now()); err != nil && ctx.Err() == nil {
				s.o.Log.Warn().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("presence stamp")
			}
		}
	}
}

// boxOnlineLocked answers one roster row's presence; s.mu is held. A socket
// on this instance is online. Otherwise the shared stamp decides, unless this
// instance saw that box's socket close after the stamp was written (a real
// disconnect reads offline at once where it happened, not a TTL later).
func (s *Server) boxOnlineLocked(tenant string, b store.ViewBox, now time.Time) bool {
	if b.Revoked {
		return false
	}
	k := [2]string{tenant, b.BoxID}
	if s.boxes[k] != nil {
		return true
	}
	if b.LastHelloAt.IsZero() || now.Sub(b.LastHelloAt) > s.presenceTTL() {
		return false
	}
	if left, ok := s.left[k]; ok && !b.LastHelloAt.After(left) {
		return false
	}
	return true
}
