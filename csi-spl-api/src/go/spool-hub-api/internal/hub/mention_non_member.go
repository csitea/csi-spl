package hub

import (
	"context"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// SPL-2419 (owner HUM-10, t1 170c444e, msg 2ad2a99f): a person @mentioned in
// a channel they are not a member of cannot read it, and nothing said so -
// the WUI's mention poke (spec 042 K4) checks agents only, since spec 067
// never pokes a person. The hub knows the channel's members, so right after
// the line is stored it posts one automatic note in the same topic (HUB-0,
// no agent, no AI) naming every such person. A default channel reads as
// everyone and a DM has no channel: neither gets a note.

// mentionNonMemberBody is the note for the ids, in mention order.
func mentionNonMemberBody(ids []string) string {
	verb := "does not belong to this channel and cannot see these messages."
	if len(ids) > 1 {
		verb = "do not belong to this channel and cannot see these messages."
	}
	return "@" + strings.Join(ids, ", @") + " " + verb
}

// mentionedOutside is the people (HUM-/GST- seats) body mentions that are
// not in members, each once, never author.
func mentionedOutside(body, author string, members []string) []string {
	in := map[string]bool{author: true}
	for _, m := range members {
		in[m] = true
	}
	var out []string
	for _, id := range store.MentionedIDs(body) {
		if store.IsFlowMember(id) && !in[id] {
			in[id] = true
			out = append(out, id)
		}
	}
	return out
}

// noteMentionNonMembers posts the note for m, just stored in channel by
// author. Its id is seeded by m's, so a resend posts nothing twice. A failure
// is logged: the line itself is already stored.
func (s *Server) noteMentionNonMembers(ctx context.Context, tenant, channel, author string, m *msg.Message) {
	if channel == "" || store.ChannelPublic(channel) || !strings.Contains(m.Body, "@") {
		return
	}
	members, err := s.channelHumans(ctx, tenant, store.NormalizeChannel(channel))
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", channel).Msg("mention non-member: members")
		return
	}
	ids := mentionedOutside(m.Body, author, members)
	if len(ids) == 0 {
		return
	}
	id := uid.FromSeed("spool-mention-non-member:" + m.MsgID)
	if err := s.postHubNote(ctx, tenant, channel, m.TaskID, id, mentionNonMemberBody(ids)); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("msg_id", m.MsgID).Msg("mention non-member: note")
	}
}
