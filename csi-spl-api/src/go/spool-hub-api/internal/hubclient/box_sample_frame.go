package hubclient

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The box handler of "Refresh now" (spec 071 7.6.3 and 8.4.1, SPL-6239 row
// T3): the hub writes a box_sample frame (msg_id = its request id) on this
// box's role=box socket; the box collects one sample with BoxSampler (row
// T2) and writes one box_sample_put frame back on the same socket, msg_id the
// same request id, lane the sample (the JSON of lane_op box_stats_put). Fire
// and forget: the hub sends no reply.
//
// The collection runs off the read loop, so a slow df never stalls a
// delivery. Two guards, whatever the hub sends (spec 8.7.1, which raises
// section 7.5's 30 s to 60 s):
//   - at most one collection in flight per box;
//   - at most one answer per SPOOL_BOX_SAMPLE_MIN_S (default 60 s), counted
//     from the start of the last accepted collection.
//
// A frame refused by either guard is logged and dropped; the hub then reads
// the box as stale (7.4). The guard lives on the Client, not the Session, so
// the 5-minute socket roll does not reset it.
//
// Not this row: the v2 handler (fresh du, FeatureBoxLiveV2) is row T14.

// DefaultBoxSampleMin is the box-side guard of spec 071 8.7.1.
const DefaultBoxSampleMin = 60 * time.Second

// boxSampleWriteTimeout bounds the box_sample_put write on a dying socket.
const boxSampleWriteTimeout = 5 * time.Second

// boxSampleGuard is the per-box state of the two guards.
type boxSampleGuard struct {
	mu   sync.Mutex
	busy bool      // a collection is in flight
	last time.Time // start of the last accepted collection; zero = none yet
}

// ParseBoxSampleMin reads SPOOL_BOX_SAMPLE_MIN_S: whole seconds, >= 1;
// "" = DefaultBoxSampleMin.
func ParseBoxSampleMin(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return DefaultBoxSampleMin, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 {
		return 0, fmt.Errorf("want whole seconds >= 1, got %q", s)
	}
	return time.Duration(n) * time.Second, nil
}

// boxSampleMin is the guard's period; 0 or less = the default.
func (c *Client) boxSampleMin() time.Duration {
	if c.BoxSampleMin <= 0 {
		return DefaultBoxSampleMin
	}
	return c.BoxSampleMin
}

// boxSampleAccept takes the in-flight slot when both guards allow it; ""
// = accepted, else the reason the frame is dropped.
func (c *Client) boxSampleAccept() string {
	g := &c.boxSample
	g.mu.Lock()
	defer g.mu.Unlock()
	now := c.now()
	switch {
	case g.busy:
		return "a sample is already being collected"
	case !g.last.IsZero() && now.Sub(g.last) < c.boxSampleMin():
		return fmt.Sprintf("last sample started %s ago, the guard is %s", now.Sub(g.last).Round(time.Second), c.boxSampleMin())
	}
	g.busy, g.last = true, now
	return ""
}

// boxSampleDone frees the in-flight slot.
func (c *Client) boxSampleDone() {
	c.boxSample.mu.Lock()
	c.boxSample.busy = false
	c.boxSample.mu.Unlock()
}

// boxSampler is the collector of this box: the Client's own (tests) or the
// live box, with the Client's run report when it names none.
func (s *Session) boxSampler() BoxSampler {
	var b BoxSampler
	if s.c.BoxSampler != nil {
		b = *s.c.BoxSampler
	}
	b.Box = s.box
	if b.AgentRun == nil {
		b.AgentRun = func() map[string]bool {
			agents, err := s.c.scanAgents()
			if err != nil {
				return nil
			}
			return s.c.agentRun(agents)
		}
	}
	return b
}

// boxSampleFrame handles one box_sample frame from the read loop: checks the
// guards there, then collects and answers in its own goroutine.
func (s *Session) boxSampleFrame(f wire.Frame) {
	log := s.c.Log.With().Str("req", f.MsgID).Logger()
	if f.MsgID == "" {
		log.Warn().Msg("box_sample frame without a request id dropped")
		return
	}
	if why := s.c.boxSampleAccept(); why != "" {
		log.Info().Str("why", why).Msg("box_sample frame dropped")
		return
	}
	go func() {
		defer s.c.boxSampleDone()
		s.boxSampleAnswer(f.MsgID)
	}()
}

// boxSampleAnswer collects one sample and writes its box_sample_put.
func (s *Session) boxSampleAnswer(req string) {
	log := s.c.Log.With().Str("req", req).Logger()
	got, err := s.boxSampler().Collect(s.ctx)
	if err != nil {
		log.Warn().Err(err).Msg("box_sample: no sample sent")
		return
	}
	lane, err := json.Marshal(got.Stat)
	if err != nil {
		log.Warn().Err(err).Msg("box_sample: sample not encoded")
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, boxSampleWriteTimeout)
	defer cancel()
	if err := wsjson.Write(ctx, s.conn, wire.Frame{Type: wire.TBoxSamplePut, MsgID: req, Lane: lane}); err != nil {
		log.Warn().Err(err).Msg("box_sample_put not sent; the hub reads this box as stale")
	}
}
