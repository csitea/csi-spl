package hub

import (
	"context"
	"sort"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The queue relay (SPL-1004). A hub process pushes a stored message only to
// the box sockets IT holds (boxSession is process memory); every other box
// gets the row queued and reads it at its next hello. That is fine for one
// process, but a Cloud Run deploy runs two or three revisions side by side
// for up to the 3600 s request timeout: the boxes redial onto the new
// revision within seconds (the session probe), while a browser socket stays
// on the old one. Measured on prd 2026-09-27: at 11:52:45Z every box sat on
// revision 00093 (1.0.0) and a person's browser on 00092 (0.9.11), so a post
// stored there would reach its member agents only at their next hello, and
// the fallback on 00092 saw no box at all and handed it to nobody.
//
// So every relayEvery each process:
//  1. drains the queued deliveries of the box sockets it holds - a row
//     another process queued reaches its box within one tick. push claims
//     each row first, so this and a hello drain or a live send never
//     deliver one row twice;
//  2. sweeps the tenants whose boxes it holds for signed posts by a person
//     that no agent box was sent (store.UnheardPosts) and runs the fallback
//     on them with its own boxes. The window starts relaySweepGrace back,
//     so the process that holds a member's box has relayed the post first,
//     and reaches relaySweepWindow back, so a post from before a restart is
//     not dug up an hour later.

const (
	relaySweepGrace  = 15 * time.Second
	relaySweepWindow = 10 * time.Minute
	relaySweepMax    = 20 // posts per tenant per tick
)

// RunRelay runs the queue relay every interval until ctx ends; interval <= 0
// does nothing (tests and the lde opt in).
func (s *Server) RunRelay(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		return
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.Relay(ctx)
		}
	}
}

// Relay is one relay tick (exported for the tests' clock).
func (s *Server) Relay(ctx context.Context) {
	s.sweepHumanStatus(ctx) // spec 096: expired statuses, at most once a minute per tenant
	boxes := s.relayBoxes()
	tenants := map[string]bool{}
	for _, x := range boxes {
		tenants[x.tenant] = true
		// spec 059 S2: a row a committing box has held unacked past the
		// acquisition lock goes to it again.
		if n := s.pushQueued(ctx, x) + s.pushUnacked(ctx, x, s.o.Now().Add(-ackTimeout)); n > 0 {
			s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Int("relayed", n).Msg("relay delivered queued rows")
		}
	}
	if !s.o.Fallback {
		return
	}
	fb, ok := s.o.Store.(store.Fallbacks)
	if !ok {
		return
	}
	ids := make([]string, 0, len(tenants))
	for t := range tenants {
		ids = append(ids, t)
	}
	sort.Strings(ids)
	now := s.o.Now()
	for _, tenant := range ids {
		posts, err := fb.UnheardPosts(ctx, tenant, now.Add(-relaySweepWindow), now.Add(-relaySweepGrace), relaySweepMax)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("relay unheard posts")
			continue
		}
		for _, p := range posts {
			env, err := wire.ParseEnvelope(p.Env)
			if err != nil {
				continue
			}
			m, err := env.Inner()
			if err != nil {
				continue
			}
			s.fallbackPost(ctx, tenant, s.storedChannel(ctx, tenant, env, m), env, m, escalation{swept: true, taskID: p.TaskID})
		}
	}
	s.escalateUnanswered(ctx, fb, ids, now)
}

// unansweredWindow is how far back the SPL-1225 escalation sweep looks. It is
// wider than relaySweepWindow because an unanswered post is a slow failure,
// not a lost frame: a post that sat silent while the hub was briefly down must
// still be caught when it comes back. The per-msg fallback_deliveries claim
// keeps a caught post from being escalated twice, so a wide window is cheap.
const unansweredWindow = 60 * time.Minute

// escalateUnanswered is the SPL-1225 safety net: a signed human post that no
// agent replied to in its topic within UnansweredGrace goes to the tenant's
// responder, whatever the roster claims about who is "online". Off when
// UnansweredGrace is 0.
func (s *Server) escalateUnanswered(ctx context.Context, fb store.Fallbacks, tenants []string, now time.Time) {
	if s.o.UnansweredGrace <= 0 {
		return
	}
	for _, tenant := range tenants {
		posts, err := fb.UnansweredPosts(ctx, tenant, now.Add(-unansweredWindow), now.Add(-s.o.UnansweredGrace), relaySweepMax)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("relay unanswered posts")
			continue
		}
		for _, p := range posts {
			env, err := wire.ParseEnvelope(p.Env)
			if err != nil {
				continue
			}
			m, err := env.Inner()
			if err != nil {
				continue
			}
			s.fallbackPost(ctx, tenant, s.storedChannel(ctx, tenant, env, m), env, m, escalation{swept: true, escalate: true, taskID: p.TaskID})
		}
	}
	s.reescalate(ctx, fb, tenants, now)
}

// reescalate re-fires a post that WAS escalated but the responder never acted
// on (SPL-1225 miss fix, prd t1 4b0ba40a): its last attempt is older than
// ReescalateEvery, it is still unanswered, and it has fewer than ReescalateMax
// attempts. Each re-fire re-pokes and rotates the responder. Off when
// ReescalateEvery is 0 or ReescalateMax < 2.
func (s *Server) reescalate(ctx context.Context, fb store.Fallbacks, tenants []string, now time.Time) {
	if s.o.ReescalateEvery <= 0 || s.o.ReescalateMax < 2 {
		return
	}
	for _, tenant := range tenants {
		posts, err := fb.ReescalatablePosts(ctx, tenant, now.Add(-unansweredWindow), now.Add(-s.o.ReescalateEvery), now.Add(-s.o.UnansweredGrace), s.o.ReescalateMax, relaySweepMax)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("relay reescalatable posts")
			continue
		}
		for _, p := range posts {
			env, err := wire.ParseEnvelope(p.Env)
			if err != nil {
				continue
			}
			m, err := env.Inner()
			if err != nil {
				continue
			}
			s.fallbackPost(ctx, tenant, s.storedChannel(ctx, tenant, env, m), env, m, escalation{swept: true, escalate: true, reescalate: true, avoid: p.LastAgent, taskID: p.TaskID})
		}
	}
}

// relayBoxes is every welcomed role=box session this process holds.
// pushQueued pushes every queued row of a box socket this process holds and
// returns how many it sent (the relay tick and the wake-up, wake.go).
func (s *Server) pushQueued(ctx context.Context, x *session) int {
	q, err := s.o.Store.QueuedFor(ctx, x.tenant, x.box, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("relay queue")
		return 0
	}
	n := 0
	for _, d := range q {
		if s.push(ctx, x, d.MsgID, d.Env) {
			n++
		}
	}
	return n
}

func (s *Server) relayBoxes() []*session {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*session, 0, len(s.boxes))
	for k, x := range s.boxes {
		if k[1] == WUIBox || x.role != wire.RoleBox {
			continue
		}
		select {
		case <-x.welcomed:
			out = append(out, x)
		default: // its hello drain has not run yet
		}
	}
	return out
}
