package hubclient

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// Agent run report (t1 bc1a43e1, fix A). The hub read an agent as online
// whenever its box's socket was up, so c-001@<box> showed green with no c-001
// process on it. The box now says which of its agents really run, on its
// hello and on every announce (wire.Frame.AgentRun).
//
// The verdict is not made here: the dispatch lease's fleet tick (csi-spl-orc
// spl-dispatch-lease.func.sh, spl_lease_agent_run_report) runs its own
// liveness test - a live process carrying SPOOL_AGENT_ID, not stuck on a
// usage-limit / login / modal screen - for every agent on the machine and
// writes AgentRunFile under the machine's fleet root ($SPOOL_FLEET_ROOT):
//
//	<id> TAB run|stop [TAB why]
//
// one line per agent id that has a live process; an id with no line has
// none. A report older than AgentRunMaxAge (the tick stopped) is no report.

// AgentRunFile is the report's path under the fleet root.
const AgentRunFile = "dispatch/agent-run.tsv"

// AgentRunMaxAge: the fleet tick rewrites the report every minute or so;
// past this it is stale and the box reports nothing (today's presence).
const AgentRunMaxAge = 5 * time.Minute

// AgentRunReport returns the func a role=box hello and announce call: each
// of agents' run state from fleetRoot's report, or nil (not reported) when
// there is no fleet root, no report, or a stale one. Only agent ids
// (agentid.IsAgent) are reported; any other roster id reads its box's
// presence.
func AgentRunReport(fleetRoot string, now func() time.Time) func(agents []string) map[string]bool {
	if fleetRoot == "" {
		return nil
	}
	path := filepath.Join(fleetRoot, AgentRunFile)
	return func(agents []string) map[string]bool {
		st, err := os.Stat(path)
		if err != nil || now().Sub(st.ModTime()) > AgentRunMaxAge {
			return nil
		}
		lines, err := readAgentRun(path)
		if err != nil {
			return nil
		}
		var out map[string]bool
		for _, id := range agents {
			if !agentid.IsAgent(id) {
				continue
			}
			if out == nil {
				out = make(map[string]bool, len(agents))
			}
			out[id] = lines[id] == "run"
		}
		return out
	}
}

// readAgentRun maps each reported id to its verdict word.
func readAgentRun(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		parts := strings.SplitN(sc.Text(), "\t", 3)
		if len(parts) < 2 || strings.HasPrefix(parts[0], "#") {
			continue
		}
		out[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
	}
	return out, sc.Err()
}

// agentRun is the client's report for agents; nil = none.
func (c *Client) agentRun(agents []string) map[string]bool {
	if c.AgentRun == nil {
		return nil
	}
	return c.AgentRun(agents)
}

// rosterKey is what an announce would say - the scanned roster and its run
// report - as one comparable string; false = the scan failed.
func (c *Client) rosterKey() (string, bool) {
	agents, run, err := c.rosterAgents() // fix B: a drop is a change too
	if err != nil {
		return "", false
	}
	return strings.Join(agents, ",") + runKey(run, agents), true
}

// runKey is a report as one comparable string ("" = none), so the scan tick
// re-announces only when it changed.
func runKey(run map[string]bool, agents []string) string {
	if run == nil {
		return ""
	}
	var b strings.Builder
	for _, id := range agents {
		if r, ok := run[id]; ok {
			b.WriteString(id)
			if r {
				b.WriteString("=1,")
			} else {
				b.WriteString("=0,")
			}
		}
	}
	return "run:" + b.String()
}
