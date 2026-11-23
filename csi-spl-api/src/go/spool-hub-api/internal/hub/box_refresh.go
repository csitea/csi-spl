package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"slices"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 071 7.3 steps 4-6 and 7.6.2 (SPL-6239 row T5): the hub half of
// "refresh now". The instance that takes a click announces one request per
// asked box on the store's box sample channel (store.BoxSampleWaker, row
// T4); EVERY instance keeps it in its pending map (request id -> tenant,
// box, deadline) until its deadline. The
// instance that holds that box's role=box socket, with the hello feature
// box_sample, writes it a box_sample frame; a box that says hello on any
// instance inside the deadline gets the frame then (the 5-minute socket
// roll), after it none. The box's box_sample_put is stored only against a
// pending request of that (tenant, box) inside its deadline. The route, its
// limits and the wait (row T6) build on askBoxSample.

// errBoxSampleUnsupported: the store cannot announce a box sample request.
var errBoxSampleUnsupported = errors.New("this hub's store carries no box sample requests")

// boxSampleReq is one pending request: the asked (tenant, box), its
// deadline, and the session it was last written to (one frame per socket,
// whichever of the announce and the hello catch-up gets there first).
type boxSampleReq struct {
	tenant, box string
	deadline    time.Time
	sentTo      *session
}

// boxSamples is the pending map, request id -> its request; its own lock.
type boxSamples struct {
	mu sync.Mutex
	m  map[string]*boxSampleReq
}

// put keeps request req and drops every request past its deadline.
func (p *boxSamples) put(req string, r *boxSampleReq, now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.m == nil {
		p.m = map[string]*boxSampleReq{}
	}
	for k, v := range p.m {
		if now.After(v.deadline) {
			delete(p.m, k)
		}
	}
	p.m[req] = r
}

// claimSend returns the ids of the pending requests of x's box that x may
// get a frame for: inside their deadline and not yet written to x. It marks
// them sent to x, so the announce and the hello catch-up never write one
// twice to one socket.
func (p *boxSamples) claimSend(x *session, now time.Time) []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	var out []string
	for req, r := range p.m {
		if r.tenant == x.tenant && r.box == x.box && !now.After(r.deadline) && r.sentTo != x {
			r.sentTo = x
			out = append(out, req)
		}
	}
	return out
}

// take drops and reports the pending request req when it was asked of
// (tenant, box) and is inside its deadline; an unknown id, another box's
// or an expired one takes nothing.
func (p *boxSamples) take(tenant, box, req string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	r := p.m[req]
	if r == nil || r.tenant != tenant || r.box != box || now.After(r.deadline) {
		return false
	}
	delete(p.m, req)
	return true
}

// askBoxSample mints a request id for (tenant, box) and announces it to
// every hub instance, this one too; the instance holding the box's socket
// writes the frame. Row T6 calls it once per asked box.
func (s *Server) askBoxSample(ctx context.Context, tenant, box string, deadline time.Time) (string, error) {
	w, ok := s.o.Store.(store.BoxSampleWaker)
	if !ok {
		return "", errBoxSampleUnsupported
	}
	req := uid.New()
	return req, w.AnnounceBoxSample(ctx, store.BoxSampleReq{Tenant: tenant, Box: box, ReqID: req, Deadline: deadline})
}

// onBoxSampleReq is the box sample listener of RunWake: keep the request,
// and write the frame when this instance holds the box's socket. It never
// blocks the listen connection: the write runs on its own goroutine.
func (s *Server) onBoxSampleReq(r store.BoxSampleReq) {
	now := s.o.Now()
	if now.After(r.Deadline) {
		return
	}
	s.samples.put(r.ReqID, &boxSampleReq{tenant: r.Tenant, box: r.Box, deadline: r.Deadline}, now)
	if x := s.heldBox(r.Tenant, r.Box); x != nil {
		go s.sendBoxSample(context.Background(), x)
	}
}

// sendBoxSample writes x its box's pending box_sample frames, once each, when x
// is a role=box socket whose hello carried FeatureBoxSample: an old binary
// is never asked (spec 071 7.6.1). Called on an announce and after a
// role=box hello (the catch-up).
func (s *Server) sendBoxSample(ctx context.Context, x *session) {
	if x.role != wire.RoleBox || !slices.Contains(x.features, wire.FeatureBoxSample) {
		return
	}
	for _, req := range s.samples.claimSend(x, s.o.Now()) {
		if err := x.write(ctx, wire.Frame{Type: wire.TBoxSample, MsgID: req}); err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("box_sample frame not written")
		}
	}
}

// onBoxSamplePut stores a box's answer (spec 071 7.3 step 6): only for a
// request this instance holds for the session's (tenant, box), inside its
// deadline. Box and WriterBox are the session's box, At the hub's clock
// (7.6.1). Fire and forget: a refused sample is logged, never answered.
func (s *Server) onBoxSamplePut(ctx context.Context, x *session, f wire.Frame) {
	bs, ok := s.o.Store.(store.BoxStats)
	if x.role != wire.RoleBox || !ok {
		s.refuseBoxSample(x, f.MsgID, "not a role=box socket, or no box stats store")
		return
	}
	if !s.samples.take(x.tenant, x.box, f.MsgID, s.o.Now()) {
		s.refuseBoxSample(x, f.MsgID, "unknown request id or past its deadline")
		return
	}
	var b store.BoxStat
	dec := json.NewDecoder(bytes.NewReader(f.Lane))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		s.refuseBoxSample(x, f.MsgID, "lane must be one box stat object")
		return
	}
	b.At, b.Box, b.WriterBox = s.o.Now(), x.box, x.box
	if why := store.CheckBoxStat(b); why != "" {
		s.refuseBoxSample(x, f.MsgID, why)
		return
	}
	if err := bs.AppendBoxStat(ctx, x.tenant, b); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("box sample append")
	}
}

// refuseBoxSample logs a box_sample_put the hub does not store, with why.
func (s *Server) refuseBoxSample(x *session, req, why string) {
	s.o.Log.Warn().Str("tenant", x.tenant).Str("box", x.box).Str("req", req).Str("why", why).Msg("box_sample_put refused")
}
