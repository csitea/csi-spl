package hub

import (
	"context"
	"slices"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Back-fill of a newly seated channel agent (SPL-987, specs/038 FR-020..026,
// rdb 0066).
//
// Owner, 2026-09-27: "whenever I invite bots in the channel they should
// subscribe for messages from there". The invite seated the agents, but the
// three posts made before it never reached them, so they sat in the channel
// not knowing what they were invited for.
//
// Every invited seat is owed ONE back-fill: the channel's topics active in
// the last BackfillWindow, newest BackfillMax messages of them, oldest first,
// each as a recv frame for that agent alone (Backfill = the channel), then
// one backfill_end frame that the box turns into a single summary poke. The
// seat is then stamped (backfilled_at) and never back-filled again, whatever
// later invites do.
//
// What goes: only envelopes whose SIGNED channel tag is this channel. The
// box accepts a delivery for another box only as a signed channel post
// (channels-v1 §4.5), and that rule is what keeps the hub from slipping a
// DM into an agent's inbox under a channel's name. A box-signed thread reply
// that merely inherited its topic's channel carries no tag, so it is not
// back-filled; every browser post is (wuiSend signs the channel it inherits).
// The agent's own posts are left out, as a live post to its author is.
//
// When it runs: on the invite call (POST /v1/channels/{c}/agents), on the
// box's hello after its queue drain, and from the sweeper every
// backfillEvery for every connected box, which is what picks up a seat the
// operator path (do_spl_channel_agent_add_op) wrote straight into the table.
// A box whose client did not say FeatureBackfill in its hello is skipped and
// its seats stay pending, so an upgraded client still gets them.
//
// A human invite needs none of this: people read the channel itself.

// FeatureBackfill is the hello feature a box client sends when it understands
// back-fill recv frames and backfill_end.
const FeatureBackfill = wire.FeatureBackfill

// backfillEvery is how often the sweeper looks for seats owed a back-fill on
// the connected boxes.
const backfillEvery = time.Minute

// defaultBackfillWindow is BackfillWindow when Options leaves it zero.
const defaultBackfillWindow = 7 * 24 * time.Hour

func (s *Server) backfillWindow() time.Duration {
	if s.o.BackfillWindow > 0 {
		return s.o.BackfillWindow
	}
	return defaultBackfillWindow
}

// backfillBox runs every pending back-fill of box on its live session, if it
// has one that takes them. Safe to call from any goroutine, any number of
// times: a seat in flight is skipped, and a finished one is no longer pending.
func (s *Server) backfillBox(ctx context.Context, tenant, box string) {
	if s.o.BackfillMax <= 0 {
		return
	}
	bf, ok := s.o.Store.(store.Backfills)
	if !ok {
		return
	}
	x := s.boxSession(tenant, box)
	if x == nil || !x.has(FeatureBackfill) {
		return
	}
	seats, err := bf.PendingBackfills(ctx, tenant, box)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("box", box).Msg("pending back-fills")
		return
	}
	for _, seat := range seats {
		s.backfillSeat(ctx, bf, x, seat)
	}
}

// backfillSeat sends one seat's back-fill on x and stamps it. A write that
// fails leaves the seat pending: the box's next hello runs it again, and the
// box's inbox keeps a copy it already has (DeliverTo is idempotent per file).
func (s *Server) backfillSeat(ctx context.Context, bf store.Backfills, x *session, seat store.BackfillSeat) {
	key := [4]string{x.tenant, seat.Channel, seat.Box, seat.Agent}
	if _, busy := s.backfilling.LoadOrStore(key, struct{}{}); busy {
		return
	}
	defer s.backfilling.Delete(key)
	log := s.o.Log.With().Str("tenant", x.tenant).Str("channel", seat.Channel).
		Str("box", seat.Box).Str("agent", seat.Agent).Logger()
	now := s.o.Now()
	rows, err := bf.ChannelBackfill(ctx, x.tenant, seat.Channel, now.Add(-s.backfillWindow()), now, s.o.BackfillMax)
	if err != nil {
		log.Error().Err(err).Msg("back-fill read")
		return
	}
	n, topics, newest := 0, map[string]bool{}, store.BackfillMsg{}
	for _, r := range rows {
		if !s.backfillable(x, seat, r) {
			continue
		}
		f := wire.Frame{Type: wire.TRecv, Env: r.Env, Agents: []string{seat.Agent}, Backfill: seat.Channel}
		if err := x.write(ctx, f); err != nil {
			log.Warn().Err(err).Int("sent", n).Msg("back-fill write failed; the seat stays pending")
			return
		}
		n++
		topics[r.TaskID] = true
		newest = r
	}
	if n > 0 {
		end := wire.Frame{Type: wire.TBackfillEnd, Backfill: seat.Channel, Agents: []string{seat.Agent},
			Count: n, Topics: len(topics), From: newest.FromID, TaskID: newest.TaskID, MsgID: newest.MsgID}
		if err := x.write(ctx, end); err != nil {
			log.Warn().Err(err).Int("sent", n).Msg("back-fill end not written; the seat stays pending")
			return
		}
	}
	if err := bf.MarkBackfilled(ctx, x.tenant, seat.Channel, seat.Box, seat.Agent, s.o.Now()); err != nil {
		log.Error().Err(err).Msg("back-fill not stamped")
		return
	}
	log.Info().Int("messages", n).Int("topics", len(topics)).Msg("channel agent back-filled")
}

// backfillable: a row the box will accept and the agent should read - signed,
// tagged with exactly this channel, readable by the box's reader, and not the
// agent's own post.
func (s *Server) backfillable(x *session, seat store.BackfillSeat, r store.BackfillMsg) bool {
	e, err := wire.ParseEnvelope(r.Env)
	if err != nil || e.Sig == "" || store.NormalizeChannel(e.Channel) != seat.Channel {
		return false
	}
	if !x.accepts(wire.InnerVersion(r.Env)) {
		return false
	}
	return !(e.FromBox == seat.Box && r.FromID == seat.Agent)
}

// backfillLive runs the pending back-fills of every connected box (the
// sweeper's pass).
func (s *Server) backfillLive(ctx context.Context) {
	s.mu.Lock()
	keys := make([][2]string, 0, len(s.boxes))
	for k := range s.boxes {
		keys = append(keys, k)
	}
	s.mu.Unlock()
	for _, k := range keys {
		s.backfillBox(ctx, k[0], k[1])
	}
}

// has reports whether the box's hello named feature f.
func (x *session) has(f string) bool { return slices.Contains(x.features, f) }
