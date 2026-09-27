package hub

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The fallback responder (SPL-997, specs/038 FR-030..FR-038, rdb 0067).
//
// Owner, 2026-09-27 (prd t1 #spool-hub-devel, topic 1451c158), after three
// posts into a channel reached no agent: "as long as there is even 1 agent
// online ... it should get informed and react".
//
// After a browser post by a signed-in human is stored, the hub asks whether
// any agent it routes to is ONLINE - its box holds a live socket and the
// box's roster names it, the state SPL-987 shows in Properties -> Agents
// (withAgentState). The agents it routes to are the channel's member agents
// and, for a DM or an @agent dispatch, msg.to. When none is, the post goes
// to ONE fallback agent as well: the first online agent of the tenant's
// responder list, else the online agent on the longest-online box. Never a
// broadcast. The frame is flagged Fallback, and the box rings one
// "unanswered post in <where> ..." line instead of the ordinary poke.
//
// The fallback agent is not seated in the channel. It gets this one post;
// the channel's own members still get the history from the FR-020 back-fill
// when they come online.

// FeatureFallback is the hello feature of a box client that takes fallback
// recv frames.
const FeatureFallback = wire.FeatureFallback

// fallbackRecent is how far back the Properties line counts fallback
// deliveries of a channel.
const fallbackRecent = 7 * 24 * time.Hour

// fallbackBox is one live box that takes fallback frames.
type fallbackBox struct {
	x     *session
	box   string
	since time.Time
}

// fallbackBoxes lists the tenant's live role=box sessions whose hello named
// FeatureFallback, the longest-online first (then box id). No store read.
func (s *Server) fallbackBoxes(tenant string) []fallbackBox {
	s.mu.Lock()
	var out []fallbackBox
	for k, x := range s.boxes {
		if k[0] == tenant && k[1] != WUIBox && x.role == wire.RoleBox && x.has(FeatureFallback) {
			out = append(out, fallbackBox{x: x, box: k[1], since: x.since})
		}
	}
	s.mu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		if !out[i].since.Equal(out[j].since) {
			return out[i].since.Before(out[j].since)
		}
		return out[i].box < out[j].box
	})
	return out
}

// agentOnline is the FR-026 state: the box has a live socket and its roster
// names the agent.
func (s *Server) agentOnline(tenant, box, agent string, roster map[string][]string) bool {
	return box != WUIBox && isAgent(agent) && contains(roster[box], agent) && s.boxSession(tenant, box) != nil
}

// fallbackPick is the one agent a post would fall back to now, or ok=false
// when no agent of the tenant is online on a box that takes the frame. The
// tenant's responder list comes first, in its order; then the longest-online
// box, and on it the lowest agent id. An agent on a box whose reader would
// refuse the envelope's inner version (0 = do not check) is skipped.
func (s *Server) fallbackPick(ctx context.Context, tenant string, roster map[string][]string, boxes []fallbackBox, innerV int) (fallbackBox, string, bool) {
	usable := boxes[:0:0]
	for _, b := range boxes {
		if innerV == 0 || b.x.accepts(innerV) {
			usable = append(usable, b)
		}
	}
	if len(usable) == 0 {
		return fallbackBox{}, "", false
	}
	if fb, ok := s.o.Store.(store.Fallbacks); ok {
		list, err := fb.TenantResponders(ctx, tenant)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("fallback responders")
		}
		for _, id := range list {
			for _, b := range usable {
				if isAgent(id) && contains(roster[b.box], id) {
					return b, id, true
				}
			}
		}
	}
	for _, b := range usable {
		agents := append([]string(nil), roster[b.box]...)
		sort.Strings(agents)
		for _, a := range agents {
			if isAgent(a) {
				return b, a, true
			}
		}
	}
	return fallbackBox{}, "", false
}

// fallbackOff reports whether channel opted out of the fallback (rdb 0068,
// FR-039: proof and test channels that have no agent on purpose). A DM
// never does; a read error keeps the fallback on.
func (s *Server) fallbackOff(ctx context.Context, tenant, channel string) bool {
	fb, ok := s.o.Store.(store.Fallbacks)
	if channel == "" || !ok {
		return false
	}
	off, err := fb.ChannelNoFallback(ctx, tenant, channel)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", channel).Msg("channel no_fallback")
		return false
	}
	return off
}

// fallbackWhere is the frame's Fallback value: where the post was made.
func fallbackWhere(channel, to string) string {
	if channel != "" {
		return "#" + channel
	}
	return "DM to " + to
}

// fallback hands a stored browser post to one fallback agent when no agent
// it was meant for is online (FR-030..FR-034). channel is the post's stored
// channel ("" = a DM). Called once, after the post's own deliveries exist.
func (s *Server) fallback(ctx context.Context, tenant, channel string, env *wire.Envelope, m *msg.Message) {
	if !s.o.Fallback || env.FromBox != WUIBox || !strings.HasPrefix(m.From, "HUM-") {
		return
	}
	if channel == "" && !isAgent(m.To) { // a DM to a person, or nothing to route
		return
	}
	boxes := s.fallbackBoxes(tenant)
	if len(boxes) == 0 { // nobody who could take it: nothing to read
		return
	}
	log := s.o.Log.With().Str("tenant", tenant).Str("msg_id", m.MsgID).Str("channel", channel).Logger()
	if env.Sig == "" {
		log.Warn().Msg("fallback_unsigned: no agent box can take an unsigned post; it stays browser-only (FR-038)")
		return
	}
	if s.fallbackOff(ctx, tenant, channel) { // FR-039: a proof / test channel opted out
		return
	}
	roster, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		log.Error().Err(err).Msg("fallback roster")
		return
	}
	if env.ToBox != WUIBox && s.agentOnline(tenant, env.ToBox, m.To, roster) {
		return
	}
	if channel != "" {
		members, err := s.o.Store.ChannelMembers(ctx, tenant, channel)
		if err != nil {
			log.Error().Err(err).Msg("fallback channel members")
			return
		}
		for box, agents := range members {
			for _, a := range agents {
				if s.agentOnline(tenant, box, a, roster) {
					return
				}
			}
		}
	}
	canon, err := env.Marshal()
	if err != nil {
		return
	}
	b, agent, ok := s.fallbackPick(ctx, tenant, roster, boxes, wire.InnerVersion(canon))
	if !ok {
		log.Info().Msg("fallback: no online agent takes this post")
		return
	}
	where := fallbackWhere(channel, m.To)
	f := wire.Frame{Type: wire.TRecv, Env: canon, Agents: []string{agent}, Fallback: where}
	if err := b.x.write(ctx, f); err != nil {
		log.Warn().Err(err).Str("box", b.box).Str("agent", agent).Msg("fallback write failed")
		return
	}
	now := s.o.Now()
	if err := s.o.Store.Enqueue(ctx, tenant, m.MsgID, b.box, now, now.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err == nil {
		s.o.Store.ClaimSent(ctx, tenant, m.MsgID, b.box, now) //nolint:errcheck
	} else {
		log.Error().Err(err).Str("box", b.box).Msg("fallback delivery row")
	}
	if fb, ok := s.o.Store.(store.Fallbacks); ok {
		if err := fb.RecordFallback(ctx, store.FallbackDelivery{TenantID: tenant, MsgID: m.MsgID,
			Channel: channel, Box: b.box, Agent: agent, DeliveredAt: now}); err != nil {
			log.Error().Err(err).Msg("fallback record")
		}
	}
	log.Info().Str("box", b.box).Str("agent", agent).Str("where", where).Msg("fallback delivered")
}

// channelFallback is the members answer's `fallback` (FR-035): who a post
// would fall back to now, whether posts do (no member agent online), and the
// channel's fallback deliveries of the last 7 days.
type channelFallback struct {
	ID     string                `json:"id"`
	Box    string                `json:"box"`
	Active bool                  `json:"active"`
	Off    bool                  `json:"off"` // the channel opted out (FR-039)
	Recent channelFallbackRecent `json:"recent"`
}

type channelFallbackRecent struct {
	Count int    `json:"count"`
	ID    string `json:"id,omitempty"`
	At    string `json:"at,omitempty"`
}

// fallbackInfo builds channelFallback for a channel whose agents already
// carry their online / seated state. nil when the fallback is off.
func (s *Server) fallbackInfo(ctx context.Context, tenant, channel string, agents []channelAgent) *channelFallback {
	if !s.o.Fallback {
		return nil
	}
	out := &channelFallback{Active: true, Off: s.fallbackOff(ctx, tenant, channel)}
	if out.Off {
		out.Active = false
	}
	for _, a := range agents {
		if a.Online && a.Seated {
			out.Active = false
			break
		}
	}
	if boxes := s.fallbackBoxes(tenant); len(boxes) > 0 {
		if roster, err := s.o.Store.Roster(ctx, tenant); err == nil {
			if b, id, ok := s.fallbackPick(ctx, tenant, roster, boxes, 0); ok {
				out.ID, out.Box = id, b.box
			}
		}
	}
	if fb, ok := s.o.Store.(store.Fallbacks); ok {
		sum, err := fb.ChannelFallbacks(ctx, tenant, channel, s.o.Now().Add(-fallbackRecent))
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", channel).Msg("channel fallbacks")
		} else if sum.Count > 0 {
			out.Recent = channelFallbackRecent{Count: sum.Count, ID: sum.Last.Agent, At: rfc(sum.Last.DeliveredAt)}
		}
	}
	return out
}
