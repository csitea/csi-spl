package hub

import (
	"context"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Every Lanes row says what it works for, or that it is a role seat (spec
// 153 section 3.11, SPL-4457; owner HUM-10, t1 0acd4eaa, msg 69522885:
// "there are still lanes without proper links fo rthe discussions and empty
// discussions or issues values"):
//
//   - a lane whose row has no topic but whose own issue links a discussion
//     other than the tenant's default one shows that discussion: the issue
//     was filed from the brief's topic, so it is where the lane came from.
//     The default discussion (store.IssueDiscussionDefault) is what an issue
//     with no source links, never a lane's origin;
//   - a role seat (001-003 in any vendor letter, agentid.IsRoleSeat, or a
//     row the role rotation wrote, scope "role <id> (rotation ...)") carries
//     role_seat, so the page says "role seat" in place of an empty cell.

// laneRoleScope starts the scope the role rotation writes for a seat
// (csi-spl-orc spl-rotate-lib.func.sh, spl_rotate_spawn).
const laneRoleScope = "role "

// laneIsRoleSeat is a role seat's row: no discussion and no issue by design.
func laneIsRoleSeat(l store.FleetLane) bool {
	return agentid.IsRoleSeat(l.AgentID) || strings.HasPrefix(l.Scope, laneRoleScope)
}

// laneTopicsFromIssues fills, in place, the topic of each lane that has none
// from the first discussion its own issue (a key of the tenant's prefix)
// links, the tenant's default discussion aside. A store with no issues or no
// discussion links fills nothing.
func (s *Server) laneTopicsFromIssues(ctx context.Context, tenant string, ls []store.FleetLane) error {
	is, ok := s.o.Store.(store.Issues)
	d, linked := s.issueDiscussionStore()
	numbers := []int{}
	for _, l := range ls {
		if n, own := store.ParseIssueRef(l.IssueKey); own && l.Topic == "" {
			numbers = append(numbers, n)
		}
	}
	if !ok || !linked || len(numbers) == 0 {
		return nil
	}
	prefix, err := is.IssuePrefix(ctx, tenant)
	if err != nil {
		return err
	}
	links, err := d.IssueDiscussionLinks(ctx, tenant, numbers)
	if err != nil {
		return err
	}
	def := store.IssueDiscussionDefault(tenant)
	for i, l := range ls {
		n, own := store.ParseIssueRef(l.IssueKey)
		if !own || l.Topic != "" || !strings.EqualFold(l.IssueKey, store.IssueKey(prefix, n)) {
			continue
		}
		for _, x := range links[n] {
			if x.TaskID != def {
				ls[i].Topic = x.TaskID
				break
			}
		}
	}
	return nil
}
