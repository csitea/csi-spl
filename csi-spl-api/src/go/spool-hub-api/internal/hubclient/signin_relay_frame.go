package hubclient

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The box half of the web-UI sign-in relay (spec 181 row B11): the hub
// writes a signin_relay frame (msg_id = the relay id, lane = one
// wire.SigninRelayLane) on a private VM's role=box socket; the box runs it
// with its SigninRelayer and writes the result back as one
// signin_relay_out frame, msg_id the same relay id. Fire and forget.
//
// A frame id seen before is dropped (the hub may write one frame twice: a
// socket roll, two hub instances), so an input is typed once. Frames run
// one at a time, off the read loop. Nothing here logs a lane's sealed text
// or a result's URL.

// SigninRelayer runs one relay frame on this box and reports the outcome;
// a zero State sends no report.
type SigninRelayer interface {
	Run(ctx context.Context, relay string, lane wire.SigninRelayLane) wire.SigninRelayOutLane
}

// signinSeenTTL is how long a frame id is remembered (longer than a
// relay's life on the hub).
const signinSeenTTL = time.Hour

// signinRelayWriteTimeout bounds the signin_relay_out write.
const signinRelayWriteTimeout = 5 * time.Second

// signinSeen is the frame ids already taken, and the lock that runs one
// frame at a time; it lives on the Client, so a socket roll keeps it.
type signinSeen struct {
	mu  sync.Mutex
	run sync.Mutex
	ids map[string]time.Time
}

// first reports whether id is new, and remembers it.
func (s *signinSeen) first(id string, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ids == nil {
		s.ids = map[string]time.Time{}
	}
	for k, at := range s.ids {
		if now.Sub(at) > signinSeenTTL {
			delete(s.ids, k)
		}
	}
	if _, ok := s.ids[id]; ok {
		return false
	}
	s.ids[id] = now
	return true
}

// signinRelayFrame handles one signin_relay frame from the read loop.
func (s *Session) signinRelayFrame(f wire.Frame) {
	log := s.c.Log.With().Str("relay", f.MsgID).Logger()
	var lane wire.SigninRelayLane
	if s.c.SigninRelay == nil || f.MsgID == "" || json.Unmarshal(f.Lane, &lane) != nil || lane.ID == "" {
		log.Warn().Msg("signin_relay frame dropped: no relayer, no relay id or no frame id")
		return
	}
	if !s.c.signinSeen.first(lane.ID, s.c.now()) {
		log.Info().Str("op", lane.Op).Msg("signin_relay frame seen before: dropped")
		return
	}
	go s.signinRelayRun(f.MsgID, lane)
}

// signinRelayRun runs lane, then writes its report.
func (s *Session) signinRelayRun(relay string, lane wire.SigninRelayLane) {
	s.c.signinSeen.run.Lock()
	out := s.c.SigninRelay.Run(s.ctx, relay, lane)
	s.c.signinSeen.run.Unlock()
	log := s.c.Log.With().Str("relay", relay).Str("op", lane.Op).Str("state", out.State).Logger()
	if out.State == "" {
		log.Info().Msg("signin_relay: no report")
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, signinRelayWriteTimeout)
	defer cancel()
	if err := wsjson.Write(ctx, s.conn, wire.Frame{Type: wire.TSigninRelayOut, MsgID: relay, Lane: raw}); err != nil {
		log.Warn().Err(err).Msg("signin_relay_out not sent")
		return
	}
	log.Info().Msg("signin_relay_out sent")
}
