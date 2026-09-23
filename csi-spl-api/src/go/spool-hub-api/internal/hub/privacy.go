package hub

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The read door for channels and DMs (rdb 0028, owner's call 2026-09-23).
//
// Two rules, in one place, applied by every path that hands a stored message
// to a browser:
//
//   - a CHANNEL message is readable by the HUMANS in that channel. The three
//     default channels (#lobby, #tasks, #alerts) are public to the tenant and
//     need no membership; every created channel is members-only, and a
//     non-member cannot learn it exists - it is absent from the channel list
//     and its topics read 404, never 403.
//   - a DM (no channel tag) is readable by its two ends only.
//
// Before this file the only gate was rbac.TopicsRead, a TENANT-wide role, so
// any signed-in member could read any topic of the tenant by its task_id -
// another member's DM included. Membership for humans did not exist at all:
// channel_subscriptions (0002) is the agent/box delivery half.
//
// A reader of "" filters nothing. That is the door-off rig (ViewDoorOff, lde
// only - config refuses it elsewhere), and it is the rule the topic LIST has
// always used for DMs; in the session door humanTenant guarantees a human.

// readerChannels is the set of created channels human belongs to. The result
// is used as an allow-list, so a lookup error must fail CLOSED - an empty set
// leaves the default channels readable and nothing else.
func (s *Server) readerChannels(ctx context.Context, tenant, human string) ([]string, error) {
	if human == "" {
		return nil, nil
	}
	return s.o.Store.HumanChannels(ctx, tenant, human)
}

// canReadChannel reports whether human may read channel. An empty channel is
// a DM and is not this rule's business: canReadTopic decides those.
func (s *Server) canReadChannel(ctx context.Context, tenant, channel, human string) (bool, error) {
	if channel == "" || human == "" || store.ChannelPublic(channel) {
		return true, nil
	}
	ms, err := s.o.Store.ChannelHumanMembers(ctx, tenant, store.NormalizeChannel(channel))
	if err != nil {
		return false, err
	}
	for _, m := range ms {
		if m == human {
			return true, nil
		}
	}
	return false, nil
}

// canReadTopic applies both rules to one task_id. found=false when the
// tenant has no message with that task_id in retention, which the caller
// answers exactly as it answers "not yours": 404.
func (s *Server) canReadTopic(ctx context.Context, tenant, task, human string) (ok, found bool, err error) {
	a, err := s.o.Store.TopicAccess(ctx, tenant, task, s.o.Now())
	if err != nil {
		return false, false, err
	}
	if !a.Found {
		return false, false, nil
	}
	if human == "" {
		return true, true, nil
	}
	// Readable when the topic holds at least ONE message this human may
	// read. It is only the door onto the topic: which messages come back is
	// decided again, per message, by TopicMsgQuery's Reader - a topic that
	// mixes a DM with a channel reply must not hand over the DM half.
	if a.HasDM() && a.Party(human) {
		return true, true, nil
	}
	for _, ch := range a.Channels {
		if ch == "" {
			continue
		}
		switch may, err := s.canReadChannel(ctx, tenant, ch, human); {
		case err != nil:
			return false, true, err
		case may:
			return true, true, nil
		}
	}
	return false, true, nil
}

// memberSet is the channel's human members as a set, for the live fan-out.
// nil means "no membership rule applies" (a public or DM message).
func (s *Server) channelMemberSet(ctx context.Context, tenant, channel string) map[string]bool {
	if channel == "" || store.ChannelPublic(channel) {
		return nil
	}
	ms, err := s.o.Store.ChannelHumanMembers(ctx, tenant, channel)
	if err != nil {
		// Fail closed: an empty set reaches nobody, which is the safe end of
		// a lookup failure on a members-only channel.
		return map[string]bool{}
	}
	out := make(map[string]bool, len(ms))
	for _, m := range ms {
		out[m] = true
	}
	return out
}
