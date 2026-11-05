package store

import (
	"context"
	"errors"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// FleetLane is one agent's row in the fleet-wide lane map (rdb 0096,
// CLE-77920, specs/058 G4): who owns what, across machines. The agent is
// addressed <AgentID>@<AgentBox>, AgentBox being its machine's desk box id. Written at spawn,
// set to state done at exit-clean. Age is how long ago it was last written,
// on the hub's clock.
type FleetLane struct {
	Fleet    string
	AgentID  string
	AgentBox string
	Repo     string
	Branch   string
	Scope    string
	Files    []string
	Topic    string // the lane's discussion, never "" (rdb 0263); LaneUnknown on an old row
	IssueKey string // the lane's own issue (rdb 0221, spec 153 3.4), never "" (rdb 0263); LaneUnknown on an old row
	// OriginIssue is the issue the lane came from, "" for none (rdb 0253, spec 153 3.12)
	OriginIssue string
	State       string // live | done
	WriterBox   string // the box that last wrote it (from the authenticated hello)
	UpdatedAt   time.Time
	Age         time.Duration
}

// LaneUnknown is what a lane row's topic or issue_key reads when nobody
// knows it: rdb 0263 wrote it into every row that had none (owner HUM-10,
// msg 937e89a4: "use the unknown string", no search). It is a value, not a
// gap: a write may carry it (a done write of an old row does).
const LaneUnknown = "unknown"

// ErrLaneUnlinked refuses a lane row without its discussion or its issue
// (rdb 0263, spec 153 3.21).
var ErrLaneUnlinked = errors.New("a lane row needs its discussion (topic) and its issue (issue_key)")

// LaneRoleScope is the scope the role rotation writes for a seat, `role
// <id> (rotation <rid>)` (csi-spl-orc spl-rotate-lib.func.sh,
// spl_rotate_spawn); a lane whose brief heading merely starts with "role "
// is no seat (R7 c-287 W2).
var LaneRoleScope = regexp.MustCompile(`^role [acgmoqu]-[0-9]{3} \(rotation `)

// LaneIsNotLane is a row of the lane map that is no lane: a box's own load
// row (BOX-<n>@<box>, spl-lane-map.func.sh) or a role seat (001..003 in any
// vendor letter, legacy CLE-001..003: agentid.IsRoleSeat; or a row the role
// rotation wrote, LaneRoleScope). It has no discussion and no issue of its
// own, so a missing one stores LaneUnknown.
func LaneIsNotLane(l FleetLane) bool {
	return strings.HasPrefix(l.AgentID, "BOX-") || agentid.IsRoleSeat(l.AgentID) || LaneRoleScope.MatchString(l.Scope)
}

// laneLinked is the row a put stores (rdb 0263): a non-lane's missing links
// read LaneUnknown; a lane without either is refused. Both drivers call it.
func laneLinked(l FleetLane) (FleetLane, error) {
	if LaneIsNotLane(l) {
		if l.Topic == "" {
			l.Topic = LaneUnknown
		}
		if l.IssueKey == "" {
			l.IssueKey = LaneUnknown
		}
		return l, nil
	}
	if l.Topic == "" || l.IssueKey == "" {
		return l, ErrLaneUnlinked
	}
	return l, nil
}

// LaneDoneTTL is how long a done row stays readable before a write prunes it.
const LaneDoneTTL = 7 * 24 * time.Hour

// The shapes 0096's CHECKs enforce, so a refusal is a 400, not a 500.
var (
	LaneRepoRe   = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9_.-]{0,63})?$`)
	LaneBranchRe = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9._/-]{0,199})?$`)
	LaneTopicRe  = regexp.MustCompile(`^([A-Za-z0-9_-]{1,64})?$`)
	LaneIssueRe  = regexp.MustCompile(`^([A-Z][A-Z0-9]{1,9}-[0-9]{1,9})?$`) // rdb 0221
)

// ValidFleetAgent is a fleet row's agent id as 0096/0097 accept it: either
// grammar (spec 061, agentid), a legacy number of at most 9 digits.
func ValidFleetAgent(id string) bool {
	return agentid.IsParticipant(id) && len(agentid.Number(id)) <= 9
}

// Lane field limits (0096).
const (
	LaneScopeMax = 500
	LaneFilesMax = 50
	LaneFileMax  = 300
)

// FleetLanes is the lane-map half of the store contract.
type FleetLanes interface {
	// PutFleetLane upserts the row of (fleet, l.AgentID, l.AgentBox) - one
	// row per agent AT ITS BOX (spec 061 3.3.1: c-004 on two machines is two
	// lanes, rdb 0102) - stamps
	// updated_at = now and box, and prunes the fleet's done rows older than
	// LaneDoneTTL. It returns the row as stored.
	PutFleetLane(ctx context.Context, tenantID string, l FleetLane, box string, now time.Time) (FleetLane, error)
	// ListFleetLanes reads every row of the fleet, live first, then newest
	// write first.
	ListFleetLanes(ctx context.Context, tenantID, fleet string, now time.Time) ([]FleetLane, error)
	// FleetLaneIssues is what the lanes view (spec 153 3.3) links: for each
	// of topics the live issues issue_discussions links to it (ascending
	// number, served by issue_discussions_task), and the status of every
	// such issue and of each of numbers (the lanes' own keys). A topic or
	// number with no live issue is absent; a topic that is not a uuid too.
	// Each issue comes with its prio (spec 153 3.14), in the same read.
	FleetLaneIssues(ctx context.Context, tenantID string, topics []string, numbers []int) (map[string][]int, map[int]FleetLaneIssue, error)
}

// FleetLaneIssue is what the lanes view shows of one linked issue: its
// status and its prio (1 highest .. 5; a row from before rdb 0055 reads as
// IssuePriorityDefault).
type FleetLaneIssue struct {
	Status   string
	Priority int
}

// laneIssuePrio is a stored prio as the view shows it: 0 (unset) is the default.
func laneIssuePrio(p int) int {
	if p == 0 {
		return IssuePriorityDefault
	}
	return p
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
		if ls[i].AgentID != ls[j].AgentID {
			return ls[i].AgentID < ls[j].AgentID
		}
		return ls[i].AgentBox < ls[j].AgentBox
	})
}

func (s *Memory) PutFleetLane(_ context.Context, tenant string, l FleetLane, box string, now time.Time) (FleetLane, error) {
	l, err := laneLinked(l)
	if err != nil {
		return FleetLane{}, err
	}
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
	s.lanes[[3]string{tenant, l.Fleet, l.AgentID + "@" + l.AgentBox}] = l
	return l, nil
}

// FleetLaneIssues reads the lanes view's issue links (on the Memory store).
func (s *Memory) FleetLaneIssues(_ context.Context, tenant string, topics []string, numbers []int) (map[string][]int, map[int]FleetLaneIssue, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	byTopic, status := map[string][]int{}, map[int]FleetLaneIssue{}
	want := map[string]bool{}
	for _, t := range topics {
		want[t] = canonUUIDRe.MatchString(t)
	}
	rows := s.iss.rows[tenant]
	for n, ls := range s.iss.links[tenant] {
		r, live := rows[n]
		if !live {
			continue
		}
		for _, l := range ls {
			if want[l.TaskID] && !slices.Contains(byTopic[l.TaskID], n) {
				byTopic[l.TaskID] = append(byTopic[l.TaskID], n)
				status[n] = FleetLaneIssue{Status: r.Status, Priority: laneIssuePrio(r.Priority)}
			}
		}
	}
	for _, ns := range byTopic {
		sort.Ints(ns)
	}
	for _, n := range numbers {
		if r, live := rows[n]; live {
			status[n] = FleetLaneIssue{Status: r.Status, Priority: laneIssuePrio(r.Priority)}
		}
	}
	return byTopic, status, nil
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
	case !ValidFleetAgent(l.AgentID):
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
	case l.Topic == "" && !LaneIsNotLane(l):
		return "topic is required: the discussion the lane comes from (rdb 0263)"
	case !LaneIssueRe.MatchString(l.IssueKey) && l.IssueKey != LaneUnknown:
		return "issue_key must be an issue key like SPL-12"
	case l.IssueKey == "" && !LaneIsNotLane(l):
		return "issue_key is required: the issue the lane works on (rdb 0263)"
	case !LaneIssueRe.MatchString(l.OriginIssue):
		return "origin_issue must be an issue key like SPL-12"
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
