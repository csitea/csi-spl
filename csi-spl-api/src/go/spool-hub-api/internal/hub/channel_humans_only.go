package hub

import (
	"context"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// A humans-only channel (SPL-2423, rdb 0206). Owner HUM-10, 2026-10-17:
// "it should be possible for users to have a channel without bots" and "once
// the users have removed all of the agents from the properties of a channel,
// no new agents should be added by the system"; poll answer A: no agent is a
// member, none reads or posts in it.
//
// The mark is a channel column, not the SPL-1684 AI agents switch: the
// switch is a setting a person flips (and an @agent dispatch still goes when
// it is off), while this records what the people did to the member list, and
// it closes the direct leg too. Set: a person's remove left no agent. Clear:
// a person invited one again. Marked, the channel's posts reach no agent:
// no fan-out, no queued row, no back-fill, no fallback (channelAgentsHear),
// an @agent send there is stored as a plain post (wuiRoute), and an agent's
// own post into it is refused, #lobby's open door included (agentInChannel).
// Every agent it @mentions gets the SPL-2419 "does not belong to this
// channel" note (noteMentionAgentsHumansOnly). The box side's desk reconcile adds no OD seat to it
// (spl-dispatch-subscribe.func.sh), and the unanswered sweep skips it.

// channelHumansOnly reports the mark; a store without it, or a read error,
// is false (the channel behaves as before).
func (s *Server) channelHumansOnly(ctx context.Context, tenant, channel string) bool {
	if channel == "" {
		return false
	}
	ho, ok := s.o.Store.(store.ChannelHumansOnly)
	if !ok {
		return false
	}
	on, err := ho.ChannelHumansOnly(ctx, tenant, channel)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", channel).Msg("channel humans_only: read as not marked")
		return false
	}
	return on
}

// channelAgentsHear is whether a channel post may reach any agent: the AI
// agents switch is on and the channel is not humans-only.
func (s *Server) channelAgentsHear(ctx context.Context, tenant, channel string) bool {
	return s.channelAgentsOn(ctx, tenant, channel) && !s.channelHumansOnly(ctx, tenant, channel)
}

// markHumansOnlyIfEmpty sets the mark when channel has no agent left. Called
// after a PERSON's remove only; a failed read or write is logged, the remove
// stands.
func (s *Server) markHumansOnlyIfEmpty(ctx context.Context, tenant, channel, by string, now time.Time) {
	ho, ok := s.o.Store.(store.ChannelHumansOnly)
	if !ok {
		return
	}
	members, err := s.o.Store.ChannelMembers(ctx, tenant, channel)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", channel).Msg("channel humans_only: members unread, not marked")
		return
	}
	if len(channelAgentList(members)) > 0 {
		return
	}
	if err := ho.SetChannelHumansOnly(ctx, tenant, channel, true, now); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", channel).Msg("channel humans_only: not marked")
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("channel", channel).Str("by", by).Msg("channel humans_only: marked")
}

// clearHumansOnly lifts the mark after a PERSON invited an agent.
func (s *Server) clearHumansOnly(ctx context.Context, tenant, channel, by string, now time.Time) {
	ho, ok := s.o.Store.(store.ChannelHumansOnly)
	if !ok || !s.channelHumansOnly(ctx, tenant, channel) {
		return
	}
	if err := ho.SetChannelHumansOnly(ctx, tenant, channel, false, now); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", channel).Msg("channel humans_only: not cleared")
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("channel", channel).Str("by", by).Msg("channel humans_only: cleared")
}

// noteMentionAgentsHumansOnly posts the SPL-2419 note (mention_non_member.go)
// for the agents m @mentions in a humans-only channel: none of them is a
// member or reads it. Its own seed, so a line naming people and agents gets
// both notes. A failure is logged: the line itself is already stored.
func (s *Server) noteMentionAgentsHumansOnly(ctx context.Context, tenant, channel string, m *msg.Message) {
	if !strings.Contains(m.Body, "@") || !s.channelHumansOnly(ctx, tenant, channel) {
		return
	}
	var ids []string
	seen := map[string]bool{}
	for _, id := range store.MentionedIDs(m.Body) {
		if isAgentID(id) && !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return
	}
	id := uid.FromSeed("spool-humans-only-agent:" + m.MsgID)
	if err := s.postHubNote(ctx, tenant, channel, m.TaskID, id, mentionNonMemberBody(ids)); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("msg_id", m.MsgID).Msg("humans-only agent mention: note")
	}
}
