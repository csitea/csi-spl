package hub

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/rs/zerolog"

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
func (s *Server) fallbackPick(ctx context.Context, tenant string, roster map[string][]string, boxes []fallbackBox, innerV int, avoid string) (fallbackBox, string, bool) {
	usable := boxes[:0:0]
	for _, b := range boxes {
		if innerV == 0 || b.x.accepts(innerV) {
			usable = append(usable, b)
		}
	}
	if len(usable) == 0 {
		return fallbackBox{}, "", false
	}
	// avoid (SPL-1225 miss fix) is the agent the last escalation attempt went
	// to; a re-escalation rotates PAST it, to the next responder / any awake
	// agent, so the re-delivery is a NEW inbox (a new poke, a fresh pane) and
	// not a no-op the sidecar dedupes.
	if fb, ok := s.o.Store.(store.Fallbacks); ok {
		list, err := fb.TenantResponders(ctx, tenant)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("fallback responders")
		}
		for _, ref := range list {
			// spec 061 3.3.1: c-004@<box> is that box's agent only; a bare
			// id that two boxes announce is ambiguous and skipped.
			got, re := locateAgent(roster, ref)
			if re != nil || got.ID == avoid {
				continue
			}
			for _, b := range usable {
				if b.box == got.Box {
					return b, got.ID, true
				}
			}
		}
	}
	for _, b := range usable {
		agents := append([]string(nil), roster[b.box]...)
		sort.Strings(agents)
		for _, a := range agents {
			if a != avoid && isAgent(a) {
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
	s.fallbackPost(ctx, tenant, channel, env, m, escalation{})
}

// recipientOnline reports whether any agent the post was meant for is online:
// the DM's addressee, or a member agent of the channel. A members read error
// counts as online, so the caller HOLDS the ordinary fallback on a transient
// store error rather than sending a duplicate. Extracted from fallbackPost so
// it reads as one gate (SPL-1036).
func (s *Server) recipientOnline(ctx context.Context, tenant, channel string, env *wire.Envelope, m *msg.Message, roster map[string][]string) bool {
	if env.ToBox != WUIBox && s.agentOnline(tenant, env.ToBox, m.To, roster) {
		return true
	}
	if channel == "" {
		return false
	}
	members, err := s.o.Store.ChannelMembers(ctx, tenant, channel)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", channel).Msg("fallback channel members")
		return true
	}
	for box, agents := range members {
		for _, a := range agents {
			if s.agentOnline(tenant, box, a, roster) {
				return true
			}
		}
	}
	return false
}

// fallbackPost is fallback; swept = the relay's sweep of a post another hub
// process stored (relay.go, SPL-1004). A swept post is CLAIMED before its
// frame is written, so two processes that both hold boxes of the tenant hand
// it out once.
//
// escalate = the SPL-1225 unanswered-post sweep (relay.go). It reuses this
// delivery machinery but SKIPS the "is any agent online" gates: those gates
// read the stored roster, which names every agent that ever had a dir on the
// shared box-desk - a long-dead agent still reads "online" - so they suppress
// the fallback for exactly the posts that most need it. An escalated post has
// already been proven unheard by the ground truth (no reply in its topic past
// the grace), so it always goes to the responder. It is always CLAIMED first,
// like a swept post, for the same one-delivery guarantee.
//
// reescalate = the SPL-1225 miss fix (prd t1 4b0ba40a): a post that WAS
// escalated but the responder never acted on (its poke was refused and
// dropped). It bumps the existing fallback row (attempts+1) instead of
// claiming a new one, re-poking and rotating to the next responder / any awake
// agent, so one refused poke to a busy responder is not permanent silence.
// escalation is fallbackPost's mode: swept = a relay sweep of another
// process's post (claim first); escalate = the SPL-1225 unanswered sweep (skip
// the online gates); reescalate = the miss-fix re-fire (bump the row, rotate
// past avoid). The zero value is the immediate post-time fallback.
type escalation struct {
	swept, escalate, reescalate bool
	avoid                       string
	// taskID is messages.task_id when a sweep read the row back. Empty on the
	// immediate fallback, which runs in the same turn as the insert, before
	// any merge.
	taskID string
}

func (s *Server) fallbackPost(ctx context.Context, tenant, channel string, env *wire.Envelope, m *msg.Message, esc escalation) {
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
	if !esc.escalate && s.recipientOnline(ctx, tenant, channel, env, m, roster) {
		return
	}
	canon, err := s.fallbackCanon(ctx, tenant, env, m, esc.taskID)
	if err != nil {
		log.Error().Err(err).Str("task_id", esc.taskID).Msg("fallback envelope")
		return
	}
	b, agent, ok := s.fallbackPick(ctx, tenant, roster, boxes, wire.InnerVersion(canon), esc.avoid)
	if !ok {
		log.Info().Msg("fallback: no online agent takes this post")
		return
	}
	where := fallbackWhere(channel, m.To)
	now := s.o.Now()
	rec := store.FallbackDelivery{TenantID: tenant, MsgID: m.MsgID, Channel: channel, Box: b.box, Agent: agent, DeliveredAt: now}
	if !s.fallbackTake(ctx, rec, esc, log) {
		return
	}
	f := wire.Frame{Type: wire.TRecv, Env: canon, Agents: []string{agent}, Fallback: where}
	if err := b.x.write(ctx, f); err != nil {
		log.Warn().Err(err).Str("box", b.box).Str("agent", agent).Msg("fallback write failed")
		return
	}
	s.fallbackRecord(ctx, rec, esc, log)
	log.Info().Str("box", b.box).Str("agent", agent).Str("where", where).
		Bool("swept", esc.swept).Bool("escalate", esc.escalate).Bool("reescalate", esc.reescalate).Msg("fallback delivered")
}

// fallbackCanon is the envelope a fallback frame carries. The stored envelope
// keeps the task the human signed. MergeTopic rewrites messages.task_id and
// does not touch env (the sig covers the inner task), so delivering those
// bytes writes the abandoned task into the responder's inbox and the Seen
// opens a lonely topic (prd t1 139c58c8: merged into 4a31aa83 at 03:33:25,
// escalated at 03:35 still naming 139c58c8). When taskID is the row's current
// topic and it differs, this re-signs a delivery-only copy onto that topic.
// The stored row stays the historical record. A failure returns before the
// claim, so the next sweep tries again instead of sealing a stale delivery.
func (s *Server) fallbackCanon(ctx context.Context, tenant string, env *wire.Envelope, m *msg.Message, taskID string) ([]byte, error) {
	if taskID == "" || taskID == m.TaskID {
		return env.Marshal()
	}
	pin := s.wuiPin(ctx, tenant)
	if pin == nil {
		return nil, fmt.Errorf("moved post %s now lives in %s and this hub cannot re-sign box-wui", m.MsgID, taskID)
	}
	cp := *m
	cp.TaskID = taskID
	signed, err := s.dispatchEnvelope(env.ToBox, env.Channel, env.ParentTaskID, pin, &cp)
	if err != nil {
		return nil, err
	}
	return signed.Marshal()
}

// fallbackTake makes this process the one that delivers a swept, escalated or
// re-escalated post: a re-escalation bumps the row (attempts+1, capped at
// ReescalateMax), a sweep or an escalation claims it. false = another hub
// process holds it, the cap is reached, or the store failed (logged). The
// immediate fallback takes nothing up front: it records after delivery.
func (s *Server) fallbackTake(ctx context.Context, rec store.FallbackDelivery, esc escalation, log zerolog.Logger) bool {
	fb, ok := s.o.Store.(store.Fallbacks)
	if !ok {
		return true
	}
	switch {
	case esc.reescalate:
		won, err := fb.BumpFallback(ctx, rec, s.o.ReescalateMax)
		if err != nil {
			log.Error().Err(err).Msg("fallback re-escalate")
		}
		return err == nil && won
	case esc.swept || esc.escalate:
		won, err := fb.ClaimFallback(ctx, rec)
		if err != nil {
			log.Error().Err(err).Msg("fallback claim")
		}
		return err == nil && won
	}
	return true
}

// fallbackRecord writes what a delivered fallback leaves behind: the box's
// delivery row (queued, then sent) and, for the immediate fallback only, the
// fallback record (a taken post already has its row).
func (s *Server) fallbackRecord(ctx context.Context, rec store.FallbackDelivery, esc escalation, log zerolog.Logger) {
	now := rec.DeliveredAt
	if err := s.o.Store.Enqueue(ctx, rec.TenantID, rec.MsgID, rec.Box, now, now.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err == nil {
		s.o.Store.ClaimSent(ctx, rec.TenantID, rec.MsgID, rec.Box, now) //nolint:errcheck
	} else {
		log.Error().Err(err).Str("box", rec.Box).Msg("fallback delivery row")
	}
	if fb, ok := s.o.Store.(store.Fallbacks); ok && !esc.swept && !esc.escalate && !esc.reescalate {
		if err := fb.RecordFallback(ctx, rec); err != nil {
			log.Error().Err(err).Msg("fallback record")
		}
	}
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
			if b, id, ok := s.fallbackPick(ctx, tenant, roster, boxes, 0, ""); ok {
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
