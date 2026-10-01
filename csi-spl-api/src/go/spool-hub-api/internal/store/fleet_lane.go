package store

import (
	"context"
	"regexp"
	"sort"
	"time"
)

// FleetLane is one agent's row in the fleet-wide lane map (rdb 0096,
// CLE-77920, specs/058 G4): who owns what, across machines. The agent is
// addressed <AgentID>@<AgentBox>, AgentBox being its machine's desk box id. Written at spawn,
// set to state done at exit-clean. Age is how long ago it was last written,
// on the hub's clock.
type FleetLane struct {
	Fleet     string
	AgentID   string
	AgentBox  string
	Repo      string
	Branch    string
	Scope     string
	Files     []string
	Topic     string
	State     string // live | done
	WriterBox string // the box that last wrote it (from the authenticated hello)
	UpdatedAt time.Time
	Age       time.Duration
}

// LaneDoneTTL is how long a done row stays readable before a write prunes it.
const LaneDoneTTL = 7 * 24 * time.Hour

// The shapes 0096's CHECKs enforce, so a refusal is a 400, not a 500.
var (
	LaneAgentRe  = regexp.MustCompile(`^[A-Z]{2,4}-[0-9]{1,9}$`)
	LaneRepoRe   = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9_.-]{0,63})?$`)
	LaneBranchRe = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9._/-]{0,199})?$`)
	LaneTopicRe  = regexp.MustCompile(`^([A-Za-z0-9_-]{1,64})?$`)
)

// Lane field limits (0096).
const (
	LaneScopeMax = 500
	LaneFilesMax = 50
	LaneFileMax  = 300
)

// FleetLanes is the lane-map half of the store contract.
type FleetLanes interface {
	// PutFleetLane upserts the row of (fleet, l.AgentID), stamps
	// updated_at = now and box, and prunes the fleet's done rows older than
	// LaneDoneTTL. It returns the row as stored.
	PutFleetLane(ctx context.Context, tenantID string, l FleetLane, box string, now time.Time) (FleetLane, error)
	// ListFleetLanes reads every row of the fleet, live first, then newest
	// write first.
	ListFleetLanes(ctx context.Context, tenantID, fleet string, now time.Time) ([]FleetLane, error)
}

// sortLanes is the list order both drivers share.
func sortLanes(ls []FleetLane) {
	sort.SliceStable(ls, func(i, j int) bool {
		if (ls[i].State == "live") != (ls[j].State == "live") {
			return ls[i].State == "live"
		}
		if !ls[i].UpdatedAt.Equal(ls[j].UpdatedAt) {
			return ls[i].UpdatedAt.After(ls[j].UpdatedAt)
		}
		return ls[i].AgentID < ls[j].AgentID
	})
}

func (s *Memory) PutFleetLane(_ context.Context, tenant string, l FleetLane, box string, now time.Time) (FleetLane, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lanes == nil {
		s.lanes = map[[3]string]FleetLane{}
	}
	for k, r := range s.lanes {
		if k[0] == tenant && k[1] == l.Fleet && r.State == "done" && now.Sub(r.UpdatedAt) > LaneDoneTTL {
			delete(s.lanes, k)
		}
	}
	l.Files = append([]string{}, l.Files...)
	l.WriterBox, l.UpdatedAt, l.Age = box, now, 0
	s.lanes[[3]string{tenant, l.Fleet, l.AgentID}] = l
	return l, nil
}

func (s *Memory) ListFleetLanes(_ context.Context, tenant, fleet string, now time.Time) ([]FleetLane, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []FleetLane{}
	for k, r := range s.lanes {
		if k[0] == tenant && k[1] == fleet {
			r.Files = append([]string{}, r.Files...)
			r.Age = now.Sub(r.UpdatedAt)
			out = append(out, r)
		}
	}
	sortLanes(out)
	return out, nil
}

// CheckFleetLane names the first field a write may not carry ("" = fine): the
// client and the hub refuse the same shapes 0096's CHECKs would.
func CheckFleetLane(l FleetLane) string {
	switch {
	case !FleetNameRe.MatchString(l.Fleet):
		return "fleet must be a lowercase slug ([a-z0-9-], up to 32)"
	case !LaneAgentRe.MatchString(l.AgentID):
		return "agent must be an agent id like CLE-07"
	case !FleetNameRe.MatchString(l.AgentBox):
		return "box must be the agent's desk box id ([a-z0-9-], up to 32)"
	case !LaneRepoRe.MatchString(l.Repo):
		return "repo must be a repo name ([A-Za-z0-9_.-], up to 64)"
	case !LaneBranchRe.MatchString(l.Branch):
		return "branch must be a git branch name (up to 200)"
	case len(l.Scope) > LaneScopeMax || hasControl(l.Scope):
		return "scope must be one line of up to 500 bytes"
	case len(l.Files) > LaneFilesMax:
		return "files lists at most 50 paths"
	case !LaneTopicRe.MatchString(l.Topic):
		return "topic must be a task id ([A-Za-z0-9_-], up to 64)"
	case l.State != "live" && l.State != "done":
		return "state must be live or done"
	}
	for _, f := range l.Files {
		if f == "" || len(f) > LaneFileMax || hasControl(f) {
			return "each file must be a path of up to 300 bytes"
		}
	}
	return ""
}

func hasControl(s string) bool {
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return true
		}
	}
	return false
}
