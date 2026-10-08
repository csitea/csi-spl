package hubclient

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// Dead agents leave the box's roster (t1 bc1a43e1, fix B). Fix A greys an
// agent whose box is online but which does not run; its name still stayed
// in the roster, so the WUI kept offering it in mentions: c-001@<box> was
// announced ~26 h after its last session ended. An agent the run report
// (agent_run.go) has said "not running" for longer than Client.DropAfter is
// left out of this box's hello and announce. Reversible: the first report
// that says it runs again - or a line it sends - puts it back on the next
// announce (the 10 s scan tick).
//
// The role ids 001..003 exist on every box. One of them is kept while the
// box's own lease mirror (dispatch/lease, dispatch/lease.orch:
// "<id>@<box> <epoch>") names it on this box, or while the report holds it
// for a rotation ("stop" + "held: ..."): the role is seated here and a fresh
// session is on its way.
//
// No report (no fleet root, a stale one) drops nothing: nobody knows.

// AgentRunHeldWhy is the report's why prefix for an agent the dispatch
// rotation holds (spl_lease_held: "held: rotation since <n>s").
const AgentRunHeldWhy = "held:"

// AgentLeaseFiles are the lease mirrors under the fleet root.
var AgentLeaseFiles = []string{"dispatch/lease", "dispatch/lease.orch"}

// roleNumbers are the role seats every box carries (spec 058: 001-003).
var roleNumbers = map[string]bool{"001": true, "002": true, "003": true}

// rosterAgents is what this box announces: the scanned roster minus the
// agents dropped as dead, and the run report for those it keeps.
func (c *Client) rosterAgents() ([]string, map[string]bool, error) {
	agents, err := c.scanAgents()
	if err != nil {
		return nil, nil, err
	}
	run := c.agentRun(agents)
	kept := c.dropDead(agents, run)
	if len(kept) == len(agents) {
		return agents, run, nil
	}
	return kept, keepRun(kept, run), nil
}

// keepRun is run restricted to agents; nil = none.
func keepRun(agents []string, run map[string]bool) map[string]bool {
	var out map[string]bool
	for _, id := range agents {
		if r, ok := run[id]; ok {
			if out == nil {
				out = make(map[string]bool, len(agents))
			}
			out[id] = r
		}
	}
	return out
}

// dropDead is agents minus those not running for longer than DropAfter, in
// agents' order. It keeps the "not running since" clock per agent: started
// at the first report that says so, cleared by one that says it runs.
func (c *Client) dropDead(agents []string, run map[string]bool) []string {
	if c.DropAfter <= 0 || run == nil {
		return agents
	}
	now := c.now()
	c.dropMu.Lock()
	defer c.dropMu.Unlock()
	if c.stopSince == nil {
		c.stopSince = map[string]time.Time{}
	}
	seen := make(map[string]bool, len(agents))
	out := make([]string, 0, len(agents))
	var seated map[string]bool
	for _, id := range agents {
		seen[id] = true
		if r, ok := run[id]; !ok || r {
			delete(c.stopSince, id)
			out = append(out, id)
			continue
		}
		since, ok := c.stopSince[id]
		if !ok {
			since = now
			c.stopSince[id] = now
		}
		if now.Sub(since) <= c.DropAfter {
			out = append(out, id)
			continue
		}
		if roleNumbers[agentid.Number(id)] {
			if seated == nil {
				seated = c.roleSeated()
			}
			if seated[id] {
				out = append(out, id)
				continue
			}
		}
		c.Log.Debug().Str("agent", id).Time("not_running_since", since).Msg("dead agent left out of the roster")
	}
	for id := range c.stopSince {
		if !seen[id] {
			delete(c.stopSince, id)
		}
	}
	return out
}

// revive restarts id's "not running" clock: it just sent a line, so it
// lives, whatever the last report said.
func (c *Client) revive(id string) {
	c.dropMu.Lock()
	defer c.dropMu.Unlock()
	delete(c.stopSince, id)
}

// roleSeated is the role ids the box's lease mirrors seat on this box, plus
// those the run report holds for a rotation. Unreadable files add nothing.
func (c *Client) roleSeated() map[string]bool {
	out := map[string]bool{}
	root := c.Cfg.FleetRoot
	if root == "" {
		return out
	}
	for _, f := range AgentLeaseFiles {
		raw, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			continue
		}
		fields := strings.Fields(string(raw))
		if len(fields) == 0 {
			continue
		}
		id, box := agentid.SplitAtBox(fields[0])
		if box != "" && (box == c.Cfg.BoxID || box == c.Cfg.DeskBox) {
			out[id] = true
		}
	}
	for id := range heldAgents(filepath.Join(root, AgentRunFile)) {
		out[id] = true
	}
	return out
}

// heldAgents is the ids the report says stop because a rotation holds them.
func heldAgents(path string) map[string]bool {
	out := map[string]bool{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		parts := strings.SplitN(sc.Text(), "\t", 3)
		if len(parts) == 3 && strings.TrimSpace(parts[1]) == "stop" &&
			strings.HasPrefix(strings.TrimSpace(parts[2]), AgentRunHeldWhy) {
			out[strings.TrimSpace(parts[0])] = true
		}
	}
	return out
}

// ParseDropAfter reads SPOOL_AGENT_DROP_AFTER: whole minutes ("60", what
// cnf env.box.agent_drop_after_minutes renders), or a Go duration ("1h").
// Empty or 0 = never drop.
func ParseDropAfter(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, nil
	}
	if m, err := strconv.Atoi(s); err == nil {
		return time.Duration(m) * time.Minute, nil
	}
	return time.ParseDuration(s)
}
