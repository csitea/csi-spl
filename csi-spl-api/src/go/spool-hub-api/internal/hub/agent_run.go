package hub

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Agent run state (t1 bc1a43e1, fix A). An agent's presence was its box's:
// c-001@<box> read green while that box's desk socket was up and no c-001 process
// ran on it, and nobody answered the owner. A box now reports on its hello
// and announce which of its agents really run (wire.Frame.AgentRun, from the
// dispatch lease's liveness test on the box), and the hub serves:
//
//	box online, agent runs or not reported  -> "online" (as before)
//	box online, the box says it does not run -> "not_running"
//	box offline                              -> "offline"
//
// The report is kept on the session (this instance's presence frames and
// snapshot) and in roster.running (rdb 0153, every instance's roster view).

// presenceNotRunning is the presence state and frame status of an agent
// whose box is online but which does not run. An older WUI ignores the frame
// status and reads the roster view's box presence.
const presenceNotRunning = "not_running"

// cleanAgentRun keeps the report's entries for agents in the box's roster;
// nil = nothing reported. The box is untrusted: an id it does not announce
// is dropped, never stored.
func cleanAgentRun(agents []string, run map[string]bool) map[string]bool {
	if len(run) == 0 {
		return nil
	}
	var out map[string]bool
	for _, id := range agents {
		r, ok := run[id]
		if !ok {
			continue
		}
		if out == nil {
			out = make(map[string]bool, len(agents))
		}
		out[id] = r
	}
	return out
}

// splitRun parts agents into those that read online (running or not
// reported) and those the box says do not run, each in agents' order.
func splitRun(agents []string, run map[string]bool) (on, idle []string) {
	for _, id := range agents {
		if r, ok := run[id]; ok && !r {
			idle = append(idle, id)
		} else {
			on = append(on, id)
		}
	}
	return on, idle
}

// keepAgentRun stores a cleaned report right after the roster write that
// cleared the previous one. A store error is logged, never fails the hello
// or the announce: the agents then read their box's presence.
func (s *Server) keepAgentRun(ctx context.Context, tenant, box string, run map[string]bool) {
	ar, ok := s.o.Store.(store.AgentRunner)
	if !ok || len(run) == 0 {
		return
	}
	if err := ar.SetAgentRun(ctx, tenant, box, run); err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Str("box", box).Msg("agent run state not stored")
	}
}

// agentState is one roster agent's presence state (viewBox.AgentPresence).
func agentState(boxOnline bool, run map[string]bool, id string) string {
	if !boxOnline {
		return "offline"
	}
	if r, ok := run[id]; ok && !r {
		return presenceNotRunning
	}
	return "online"
}
