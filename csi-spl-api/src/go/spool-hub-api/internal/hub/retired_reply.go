package hub

import (
	"context"
	"crypto/ed25519"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// Owner HUM-10, t1 894678f1 (2026-10-07, ERR-CLIENT-20261007-185950-2F39):
// a reply to a 10-03 post by c-002@<old box> read "Not sent - that agent is
// no longer active". The reply's `to` is the post's author as it was then,
// and an agent seat is not forever: the box is retired, the id moved to
// another box, or the legacy id was renamed (spec 061). A REPLY never fails
// for that. When the agent took part in the topic and is not announced where
// the reply names it, the hub
//   - delivers it to the same id on the box that announces it now
//     (fallback "box"), else
//   - posts it to the topic as ALL-0 (fallback "topic"): the channel's
//     members, or for a channel-less topic its newest announced agent
//     (topic_reply.go), get it as any reply to the whole topic.
// The ack names the fallback and the retired address, so the WUI can say
// where the reply went. A tag of an agent that never took part in the topic
// (a new topic, a stranger in a thread) keeps today's refusal.

// Reply fallback kinds, the ack's `fallback` field.
const (
	FallbackBox   = "box"
	FallbackTopic = "topic"
)

// replyFallback is what the hub did instead of refusing a reply.
type replyFallback struct {
	kind    string // FallbackBox | FallbackTopic
	retired string // the address the reply named: <id>@<box>, or <id>
}

// inTopic reports whether agent id (on box want, "" = any box) wrote in or
// was addressed in task. A legacy participant counts as its alias (spec 061),
// so a reply to a CLE-002 post that now resolves to c-002 is still a reply.
func (s *Server) inTopic(ctx context.Context, tenant, task, id, want string) bool {
	envs, err := s.o.Store.TaskEnvelopes(ctx, tenant, task)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("retired reply participants")
		return false
	}
	lk := s.aliasLookup(ctx, tenant)
	for _, p := range topicAgents(envs) {
		if want != "" && p[1] != want {
			continue
		}
		if p[0] == id {
			return true
		}
		if agentid.IsLegacy(p[0]) {
			if n, ok := lk(p[0], p[1]); ok && n == id {
				return true
			}
		}
	}
	return false
}

// rerouteReply is the reply case of an unknown_agent dispatch: the box and
// pin of the id's live seat elsewhere, or a topic fallback; nil when the send
// is not a reply to a topic participant (the refusal stands).
func (s *Server) rerouteReply(ctx context.Context, c *wuiConn, m *msg.Message, want string) (string, ed25519.PublicKey, *replyFallback) {
	if !s.inTopic(ctx, c.tenant, m.TaskID, m.To, want) {
		return "", nil, nil
	}
	retired := m.To
	if want != "" {
		retired += "@" + want
		if box, pin, tok, _, _ := s.dispatchCheck(ctx, c, m, ""); tok == "" {
			return box, pin, &replyFallback{FallbackBox, retired}
		}
	}
	return "", nil, &replyFallback{FallbackTopic, retired}
}

// retiredIDReply is the reply case of a legacy id with no successor (spec 061
// FR-003, retired_id): a topic fallback when id@box took part in task, else
// nil (the refusal stands).
func (s *Server) retiredIDReply(ctx context.Context, tenant, task, id, box string) *replyFallback {
	if !s.inTopic(ctx, tenant, task, id, box) {
		return nil
	}
	if box != "" {
		id += "@" + box
	}
	return &replyFallback{FallbackTopic, id}
}
