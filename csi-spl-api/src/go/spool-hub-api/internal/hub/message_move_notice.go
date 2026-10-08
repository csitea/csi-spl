package hub

import (
	"bytes"
	"context"
	"fmt"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A message moved to another topic, or made a topic of its own, keeps
// answers going to the OLD topic (prd t1 645f9e3e: posted in 5901e226, made
// topic 65f75266 six seconds later; the dispatcher already had it and
// answered in 5901e226, and 65f75266 looked unanswered for ~7 min). The move
// re-homes messages.task_id; the signed envelope keeps the task it was sent
// in, and three agent-facing paths hand out that envelope:
//
//	hub-tail (onTail)          retaskEnv: the topic the row lives in now
//	a queued delivery (push)   retaskEnv: same, for a box that was offline
//	a delivery already made    moveNotice: one short note, in the new topic,
//	                           to every agent that holds the message
//
// The re-tasked copy is fallbackCanon's (a merged post's escalation): the hub
// re-signs it as box-wui, so only a box-wui envelope - a person's post, the
// case above - is re-tasked; an agent's envelope is another box's signature
// and is handed out as stored. The stored row stays the historical record.
// The unanswered sweeps already read the row (UnansweredPosts,
// ReescalatablePosts and the orc sweep all key on messages.task_id), so an
// answer in the old topic does not close the new one.

// moveNoticeExcerpt is how much of the moved message the notice quotes.
const moveNoticeExcerpt = 300

// retaskEnv is raw as a delivery-only copy on task, the topic its row lives
// in now: raw itself when it already names task (the fast path: the
// canonical inner object carries `"task_id":"<task>"` verbatim), when task is
// "", when it is not a box-wui envelope, or when it cannot be re-signed
// (logged; the stored bytes are still better than nothing).
func (s *Server) retaskEnv(ctx context.Context, tenant string, raw []byte, task string) []byte {
	if task == "" || bytes.Contains(raw, []byte(`"task_id":"`+task+`"`)) {
		return raw
	}
	env, err := wire.ParseEnvelope(raw)
	if err != nil || env.FromBox != WUIBox {
		return raw
	}
	m, err := env.Inner()
	if err != nil || m.TaskID == task {
		return raw
	}
	out, err := s.fallbackCanon(ctx, tenant, env, m, task)
	if err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Str("msg_id", m.MsgID).Str("task_id", task).
			Msg("moved post handed out on its old topic")
		return raw
	}
	return out
}

// moveNotice tells every agent that already holds m where it lives now:
// task (in channel; "" = a DM). The note is new (its own msg_id, so a box
// that has m in its inbox or archive still writes it), from the mover by,
// kind note, in task - so an agent that answers the note answers in the new
// topic, and the desk reply's picker finds task in the inbox. Holders are the
// fallback record's agent and the agents each sent box got m for; only the
// box sockets this process holds are reached (as for the fallback). Nothing
// is stored: the note is a pointer, not a post in the topic.
func (s *Server) moveNotice(ctx context.Context, tenant string, m store.EditableMessage, task, channel, by string) {
	if m.TaskID == task {
		return
	}
	pin := s.wuiPin(ctx, tenant)
	if pin == nil {
		return // no box-wui key: nothing can sign the note
	}
	log := s.o.Log.With().Str("tenant", tenant).Str("msg_id", m.MsgID).Str("from_task", m.TaskID).
		Str("task_id", task).Logger()
	for _, h := range s.moveHolders(ctx, tenant, m) {
		x := s.boxSession(tenant, h[0])
		if x == nil {
			log.Info().Str("box", h[0]).Str("agent", h[1]).Msg("move notice: box not on this process")
			continue
		}
		n := &msg.Message{V: msg.V1, MsgID: uid.New(), TaskID: task, TS: msg.Now(s.o.Now()), From: by, To: h[1],
			Kind: "note", Body: moveNoticeBody(m, task), Files: []msg.Attachment{}}
		env, err := s.dispatchEnvelope(h[0], channel, "", pin, n)
		if err != nil {
			log.Error().Err(err).Str("box", h[0]).Msg("move notice envelope")
			continue
		}
		raw, err := env.Marshal()
		if err != nil || !x.accepts(wire.InnerVersion(raw)) {
			continue
		}
		if err := x.write(ctx, wire.Frame{Type: wire.TRecv, Env: raw, Agents: []string{h[1]}}); err != nil {
			log.Warn().Err(err).Str("box", h[0]).Str("agent", h[1]).Msg("move notice write failed")
			continue
		}
		log.Info().Str("box", h[0]).Str("agent", h[1]).Str("notice", n.MsgID).Msg("move notice sent")
	}
}

// moveHolders is every (box, agent) that holds m: the fallback record's
// agent, then, per box m was sent to, the agents that box got it for (a DM's
// to, or the channel's members there, recvAgents' rule). Each pair once.
func (s *Server) moveHolders(ctx context.Context, tenant string, m store.EditableMessage) [][2]string {
	var out [][2]string
	seen := map[[2]string]bool{}
	add := func(box, agent string) {
		k := [2]string{box, agent}
		if box != "" && box != WUIBox && agentid.IsAgent(agent) && !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	if fb, ok := s.o.Store.(store.Fallbacks); ok {
		if d, err := fb.FallbackOf(ctx, tenant, m.MsgID); err == nil {
			add(d.Box, d.Agent)
		}
	}
	for _, d := range m.Deliveries {
		if d.State != store.StateSent || d.ToBox == WUIBox {
			continue
		}
		if m.Channel == "" {
			add(d.ToBox, m.ToID)
			continue
		}
		x := s.boxSession(tenant, d.ToBox)
		if x == nil {
			continue
		}
		agents, _ := s.recvAgents(ctx, x, m.Env)
		for _, a := range agents {
			add(d.ToBox, a)
		}
	}
	return out
}

// moveNoticeBody is the note: where the message lives now, and its head so
// the agent can answer without another read.
func moveNoticeBody(m store.EditableMessage, task string) string {
	return fmt.Sprintf("Moved: message %s from %s now lives in topic %s (it was in %s). "+
		"Answer it in %s, not in the old topic.\n\n> %s", m.MsgID, m.FromID, task, m.TaskID, task,
		clip(strings.Join(strings.Fields(m.Body), " "), moveNoticeExcerpt))
}
