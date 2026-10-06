package hub

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A person's reply to the whole topic (to ALL-0, no @mention) in a topic that
// has NO channel used to reach nobody but the browsers: there is no channel
// to fan out to and no agent to dispatch to, so the only delivery row was
// box-wui's (prd t1 916c8696, 2026-10-06: the owner's reply c88ae040 under an
// agent's note sat unread for 16+ min, while 5 channel replies the same hour
// were answered within 30 s). A channel-less topic is still a conversation
// with agents when agents wrote in it or were addressed in it, so the reply
// is dispatched to the topic's most recent agent participant that is
// announced now, exactly as "@<that agent> ..." would be. A topic with no
// announced agent participant (a person-to-person DM, an agent that left)
// keeps the browser-only post: never a refusal.

// topicReplyAgent is the dispatch a channel-less ALL-0 reply gets: the agent,
// its box and the pin it is signed for; agent "" = keep the browser-only post.
func (s *Server) topicReplyAgent(ctx context.Context, c *wuiConn, m *msg.Message, channel string, isParent int) wuiSigning {
	if !s.o.WUIDispatch || isParent != 0 || channel != "" || m.To != BroadcastID || c.member == "" ||
		(s.o.LobbyTaskID != "" && m.TaskID == s.o.LobbyTaskID) || !s.allowed(ctx, c.member, c.tenant, rbac.AgentsCommand) {
		return wuiSigning{}
	}
	envs, err := s.o.Store.TaskEnvelopes(ctx, c.tenant, m.TaskID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", m.TaskID).Msg("topic reply participants")
		return wuiSigning{}
	}
	for _, p := range topicAgents(envs) {
		probe := *m
		probe.To = p[0]
		box, pin, tok, _, _ := s.dispatchCheck(ctx, c, &probe, p[1])
		switch tok {
		case "":
			return wuiSigning{agent: p[0], box: box, pin: pin}
		case "wui_unpinned": // nothing can be signed for in this tenant
			return wuiSigning{}
		}
	}
	return wuiSigning{}
}

// topicAgents is every (agent, box) that wrote in or was addressed in a
// topic, newest first, each once. envs are oldest first (TaskEnvelopes).
func topicAgents(envs [][]byte) [][2]string {
	var out [][2]string
	seen := map[[2]string]bool{}
	add := func(id, box string) {
		k := [2]string{id, box}
		if box != WUIBox && isAgent(id) && !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	for i := len(envs) - 1; i >= 0; i-- {
		e, err := wire.ParseEnvelope(envs[i])
		if err != nil {
			continue
		}
		in, err := e.Inner()
		if err != nil {
			continue
		}
		add(in.From, e.FromBox)
		add(in.To, e.ToBox)
	}
	return out
}
