package hub

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The human post guard (SPL-2584, store/human_post_guard.go, rdb 0211): two
// deterministic checks on a BOX send to a person, no judgement involved. The
// rule's one home is csi-spl-doc/doc/help/how-to-post.md rule 18.
//
//  1. dm_not_blocker: a DM (the topic has no channel) from an agent to a
//     person is refused unless it is a blocker, it answers a DM that person
//     started (the topic's first message is theirs), it follows up a blocker
//     DM to that person (the topic's first message is one), or it is a DM
//     about a channel topic the agent may read (spec 067 ref_task_id: the
//     #lobby welcome answer, the desk's dm-fallback). Owner HUM-10, t1
//     4b49e47d msg 6c089b4a: "an agent must NOT sent a direct msg to the
//     origination of a msg on a channel topic UNLESS this msg is about
//     blocked task".
//  2. duplicate_to_human: a post to a person, DM or channel topic, whose
//     normalized body equals one any agent sent that person in the last
//     HumanDupWindow is refused (msgs 8b351386, 85a20ac7). A resend of the
//     same msg_id is not a duplicate.
//
// Browser sends (wui.go) and hub-originated envelopes (Deliver) are not box
// sends and are never checked; a store without store.HumanPostGuard, or
// Options.HumanPostGuard false (SPOOL_HUB_HUMAN_POST_GUARD=false), checks
// nothing.

// Refusal tokens of the guard; the desk actions name the rule on them.
const (
	TokenDMNotBlocker     = "dm_not_blocker"
	TokenDuplicateToHuman = "duplicate_to_human"
)

// HumanDupWindow is how far back a person's received bodies are compared.
const HumanDupWindow = 24 * time.Hour

// humanPostRefusal is onSend's guard for a box post to a person. ctx carries
// the send's dmRef (boxDMRef). nil = accepted.
func (s *Server) humanPostRefusal(ctx context.Context, x *session, env *wire.Envelope, m *msg.Message) *frameRefusal {
	if !s.o.HumanPostGuard || !strings.HasPrefix(m.To, "HUM-") || strings.HasPrefix(m.From, "HUM-") {
		return nil
	}
	g, ok := s.o.Store.(store.HumanPostGuard)
	if !ok {
		return nil
	}
	if rf := s.dmRuleRefusal(ctx, g, x.tenant, env, m); rf != nil {
		return rf
	}
	prev, err := g.HumanGotBody(ctx, x.tenant, m.To, m.Body, s.o.Now().Add(-HumanDupWindow), m.MsgID)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("human post guard: body read")
		return &frameRefusal{"internal", http.StatusInternalServerError, "duplicate check failed"}
	case prev != "":
		return &frameRefusal{TokenDuplicateToHuman, http.StatusConflict, m.To + " already got this text from an agent in the last 24 h (msg " + prev +
			"): nothing was sent; say something new or nothing (how-to-post.md rule 18)"}
	}
	return nil
}

// dmRuleRefusal is check 1: nil for a channel post or an allowed DM.
func (s *Server) dmRuleRefusal(ctx context.Context, g store.HumanPostGuard, tenant string, env *wire.Envelope, m *msg.Message) *frameRefusal {
	if m.Kind == "blocker" || s.storedChannel(ctx, tenant, env, m) != "" {
		return nil
	}
	if r, _ := ctx.Value(dmRefKey{}).(dmRef); r.task != "" {
		return nil
	}
	o, err := g.TopicOpener(ctx, tenant, m.TaskID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", m.TaskID).Msg("human post guard: opener read")
		return &frameRefusal{"internal", http.StatusInternalServerError, "topic lookup failed"}
	}
	if o.FromID == m.To || (o.Kind == "blocker" && o.ToID == m.To) {
		return nil
	}
	return &frameRefusal{TokenDMNotBlocker, http.StatusForbidden, "a DM to " + m.To + " must be a blocker (kind blocker) or answer a DM " + m.To +
		" started: nothing was sent; post it in the channel topic it belongs to (how-to-post.md rule 18)"}
}
