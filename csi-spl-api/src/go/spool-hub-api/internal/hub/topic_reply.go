package hub

import (
	"context"
	"net/http"

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

// A person-to-person DM topic has no channel and no agent, so an ALL-0 reply
// in it (the topic page's reply pane sends no `to`) matched no reader: the
// read door shows a channel-less row only to its from and its to (prd t1
// f87e6c9d, 2026-10-09: 3 replies to a DM were seen by their poster alone).
// Spec 117 FR-1: such a reply is readdressed to the one other person of the
// topic, as if the poster had typed "@<that person> ..."; with no other
// person, or more than one, it is refused (400 dm_needs_to), never stored
// for its poster alone. FR-2: a NEW channel-less topic with no `to` is
// refused the same way: routing it to the lobby instead would publish to
// every member a line its poster meant for one person. A message-rooted topic
// off a DM line (parent_task_id) takes the parent's people. A topic with an
// agent in it keeps topicReplyAgent's rule (browser-only when that agent
// left), and the lobby task is untouched.

// topicReplyPerson is the person a channel-less ALL-0 send is readdressed to
// ("" = leave it), or the dm_needs_to refusal.
func (s *Server) topicReplyPerson(ctx context.Context, c *wuiConn, m *msg.Message, channel, parentTask string) (string, *frameRefusal) {
	if channel != "" || m.To != BroadcastID || (s.o.LobbyTaskID != "" && m.TaskID == s.o.LobbyTaskID) {
		return "", nil
	}
	envs, err := s.o.Store.TaskEnvelopes(ctx, c.tenant, m.TaskID)
	if err == nil && len(envs) == 0 && parentTask != "" {
		envs, err = s.o.Store.TaskEnvelopes(ctx, c.tenant, parentTask)
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", m.TaskID).Msg("topic reply person")
		return "", nil
	}
	if len(envs) > 0 && len(topicAgents(envs)) > 0 {
		return "", nil
	}
	if p := topicPeople(envs, m.From); len(p) == 1 {
		return p[0], nil
	}
	return "", &frameRefusal{"dm_needs_to", http.StatusBadRequest,
		"say who this is for: a post outside a channel needs a `to` (one person), or post it in a channel"}
}

// topicPeople is every person who wrote in or was addressed in a topic, other
// than me, each once.
func topicPeople(envs [][]byte, me string) []string {
	var out []string
	seen := map[string]bool{me: true}
	for _, raw := range envs {
		e, err := wire.ParseEnvelope(raw)
		if err != nil {
			continue
		}
		in, err := e.Inner()
		if err != nil {
			continue
		}
		for _, id := range []string{in.From, in.To} {
			if isPerson(id) && !seen[id] {
				seen[id] = true
				out = append(out, id)
			}
		}
	}
	return out
}
