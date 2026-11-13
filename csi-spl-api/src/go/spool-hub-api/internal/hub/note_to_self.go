package hub

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 042 "Note to self" (SPL-5372; owner HUM-10, t1 df36f210, msg
// 76800948: "As proposed: a post tagged only to yourself is a note to self,
// no agent answers"; the f0fc6d7f answer at 11:51:26Z: "also let me tag my
// second account outside the channel"). A person's browser post whose only
// @mentions are the person, or the person's linked accounts (human_links,
// rdb 0278, written only by the operator: poll 3193d41f answer C), is stored
// and shown as usual, and:
//
//   - reaches no agent: wuiRoute builds no dispatch, no topic-agent reply and
//     no channel fan-out for it, and the ordinary fallback is not sent;
//   - carries messages.note_to_self (rdb 0278), the one flag every other
//     reader honours: the WUI marks the line, the operator replay of unsigned
//     posts skips it (replay_postgres.go) and the unanswered sweep
//     (do_spl_unanswered_sweep) never counts it.
//
// A post that also tags anyone else, or is addressed to anyone else, is a
// normal post. Neither the author nor
// a linked account gets the "does not belong to this channel" note
// (noteMentionNonMembers); someone else's account outside the channel still
// does.

// isNoteToSelf: member is a person and the post is addressed to member or a
// linked account of member (linked: the human_links of member), and nobody
// else. Addressed is every @mention of body, plus to when it is a person: the
// WUI sends a leading @tag as the addressee and strips it from the body.
func isNoteToSelf(member, to, body string, linked func() map[string]bool) bool {
	if member == "" || !store.IsFlowMember(member) {
		return false
	}
	ids := store.MentionedIDs(body)
	if store.IsFlowMember(to) {
		ids = append(ids, to)
	}
	var self map[string]bool
	for _, id := range ids {
		if id == member {
			continue
		}
		if self == nil {
			self = linked()
		}
		if !self[id] {
			return false
		}
	}
	return len(ids) > 0
}

// linkedHumans is the accounts linked to member (human_links); none on a
// store without the table or on a read error (the post is then a normal one).
func (s *Server) linkedHumans(ctx context.Context, member string) []string {
	hl, ok := s.o.Store.(store.HumanLinks)
	if !ok || member == "" {
		return nil
	}
	ids, err := hl.LinkedHumans(ctx, member)
	if err != nil {
		s.o.Log.Error().Err(err).Str("human", member).Msg("note to self: linked accounts unread")
		return nil
	}
	return ids
}

// linkedSet is linkedHumans as a set, for isNoteToSelf.
func (s *Server) linkedSet(ctx context.Context, member string) func() map[string]bool {
	return func() map[string]bool {
		out := map[string]bool{}
		for _, id := range s.linkedHumans(ctx, member) {
			out[id] = true
		}
		return out
	}
}

// noteToSelfKey carries a browser send's note-to-self decision from wuiSend
// to commitRowTyped, which stores it on the row.
type noteToSelfKey struct{}

// withNoteToSelf is ctx, its send marked a note to self when on.
func withNoteToSelf(ctx context.Context, on bool) context.Context {
	if !on {
		return ctx
	}
	return context.WithValue(ctx, noteToSelfKey{}, true)
}

// noteToSelfOf is whether ctx's send is a note to self.
func noteToSelfOf(ctx context.Context) bool {
	on, _ := ctx.Value(noteToSelfKey{}).(bool)
	return on
}
