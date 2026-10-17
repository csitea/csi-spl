package hub

import (
	"context"
	"errors"
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
//
// SPL-2426 (owner HUM-10, t1 170c444e, msg a3fe13e3): "use people's real
// names, not their IDs". The note names each person by the name on file
// (humans.display_name, first and last name), never by HUM- id.

// mentionNonMemberBody is the note for the people's names, in mention
// order: "A does not ...", "A and B do not ...", "A, B and C do not ...".
func mentionNonMemberBody(names []string) string {
	verb := "does not belong to this channel and cannot see these messages."
	if len(names) > 1 {
		verb = "do not belong to this channel and cannot see these messages."
	}
	who := strings.Join(names, ", ")
	if n := len(names); n > 1 {
		who = strings.Join(names[:n-1], ", ") + " and " + names[n-1]
	}
	return who + " " + verb
}

// unnamedPerson stands for a person with neither a name nor a sign-in
// address on file: the note never shows a bare id.
const unnamedPerson = "a person with no name on file"

// mentionNames is each id's name for the note: the display name, else the
// part before @ of the sign-in address (the name they sign in with; never
// the whole address, which only admins see), else unnamedPerson. A person
// outside the member directory (a channel guest) is read by id.
func (s *Server) mentionNames(ctx context.Context, tenant string, ids []string) []string {
	known := map[string]string{}
	if dir, ok := s.o.Store.(store.MemberDirectory); ok {
		ms, err := dir.ListMembers(ctx, tenant)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("mention non-member: names")
		}
		for _, m := range ms {
			known[m.HumanID] = personName(m.DisplayName, m.Email)
		}
	}
	byID, _ := s.o.Store.(interface {
		DisplayName(ctx context.Context, humanID string) (string, error)
	})
	out := make([]string, len(ids))
	for i, id := range ids {
		name := known[id]
		if name == "" && byID != nil {
			got, _ := byID.DisplayName(ctx, id)
			name = personName(got, "")
		}
		if name == "" {
			name = unnamedPerson
		}
		out[i] = name
	}
	return out
}

// personName is the display name, else the sign-in address's local part.
func personName(display, email string) string {
	if n := strings.TrimSpace(display); n != "" {
		return n
	}
	local, _, _ := strings.Cut(strings.TrimSpace(email), "@")
	return local
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
	if err := s.postHubNote(ctx, tenant, channel, m.TaskID, id, mentionNonMemberBody(s.mentionNames(ctx, tenant, ids))); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("msg_id", m.MsgID).Msg("mention non-member: note")
	}
}
