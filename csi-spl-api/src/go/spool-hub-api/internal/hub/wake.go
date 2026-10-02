package hub

import (
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The wake-up (spec 059 §11 S1). A row another process queued for a box
// socket THIS process holds used to wait for the next relay tick (5 s,
// relay.go); now the store announces it on commit (store.Waker: Postgres
// LISTEN/NOTIFY) and the box gets it at once. push claims each row first, so
// a wake-up racing a live send, a hello drain or a relay tick never delivers
// one row twice, and a wake-up for a box held elsewhere costs a map lookup.

const (
	wakeQueue      = 1024 // pending (tenant, box) wake-ups; a full queue drops, the relay catches up
	wakeBackoffMin = time.Second
	wakeBackoffMax = 30 * time.Second
)

// RunWake listens until ctx ends, reconnecting with backoff: the box
// wake-up (Options.Wake) and the browser fan-out of messages stored by
// another process (Options.WakeWUI, wui_wake.go), on one connection. It does
// nothing when both are off or the store cannot announce.
func (s *Server) RunWake(ctx context.Context) {
	w, canBox := s.o.Store.(store.Waker)
	ww, canWUI := s.o.Store.(store.WUIWaker)
	var onBox, onWUI func(tenant, key string)
	if s.o.Wake && canBox {
		kick := make(chan [2]string, wakeQueue)
		go s.wakeWorker(ctx, kick)
		onBox = kicker(kick)
	}
	if s.o.WakeWUI && canWUI {
		kick := make(chan [2]string, wuiWakeQueue)
		go s.wuiWakeWorker(ctx, ww, kick)
		onWUI = kicker(kick)
	}
	listen := func() error { return w.ListenWake(ctx, onBox) }
	switch {
	case onBox == nil && onWUI == nil:
		return
	case canWUI:
		listen = func() error { return ww.ListenWakes(ctx, onBox, onWUI) }
	}
	backoff := wakeBackoffMin
	for ctx.Err() == nil {
		start := time.Now()
		err := listen()
		if ctx.Err() != nil {
			return
		}
		if time.Since(start) > wakeBackoffMax {
			backoff = wakeBackoffMin
		}
		s.o.Log.Warn().Err(err).Dur("retry_in", backoff).Msg("wake listener down; the relay poll covers the gap")
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(2*backoff, wakeBackoffMax)
	}
}

// kicker queues a wake-up without blocking the listener; a full queue drops it.
func kicker(kick chan<- [2]string) func(tenant, key string) {
	return func(tenant, key string) {
		select {
		case kick <- [2]string{tenant, key}:
		default:
		}
	}
}

// wakeWorker coalesces a burst of wake-ups per box, then pushes each held
// box's queue once.
func (s *Server) wakeWorker(ctx context.Context, kick <-chan [2]string) {
	for {
		var first [2]string
		select {
		case <-ctx.Done():
			return
		case first = <-kick:
		}
		pending := map[[2]string]bool{first: true}
	more:
		for {
			select {
			case k := <-kick:
				pending[k] = true
			default:
				break more
			}
		}
		for k := range pending {
			if x := s.heldBox(k[0], k[1]); x != nil {
				s.pushQueued(ctx, x)
			}
		}
	}
}

// heldBox is the welcomed role=box socket of (tenant, box) in this process,
// or nil.
func (s *Server) heldBox(tenant, box string) *session {
	s.mu.Lock()
	x := s.boxes[[2]string{tenant, box}]
	s.mu.Unlock()
	if x == nil || box == WUIBox || x.role != wire.RoleBox {
		return nil
	}
	select {
	case <-x.welcomed:
		return x
	default: // its hello drain has not run yet; that drain sends the row
		return nil
	}
}
