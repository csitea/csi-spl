package hub

import (
	"context"
	"net/http"
	"regexp"
	"strings"

	"github.com/google/uuid"

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

// laneRoleScope is the scope the role rotation writes for a seat, `role
// <id> (rotation <rid>)` (csi-spl-orc spl-rotate-lib.func.sh,
// spl_rotate_spawn); a lane whose brief heading merely starts with "role "
// is no seat (R7 c-287 W2).
var laneRoleScope = regexp.MustCompile(`^role [acgmoqu]-[0-9]{3} \(rotation `)

// laneIsRoleSeat is a role seat's row: no discussion and no issue by design.
func laneIsRoleSeat(l store.FleetLane) bool {
	return agentid.IsRoleSeat(l.AgentID) || laneRoleScope.MatchString(l.Scope)
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

// relayTaskHash is what spool-fleet-relay.sh makes of a task name.
func relayTaskHash(name string) string {
	return uuid.NewSHA1(uuid.NameSpaceURL, []byte("spool-task:"+name)).String()
}

// laneTopicOfRelayHash is the one topic of the tenant whose dispatch-<topic8>
// task hashes to hash, or "" for none or two: a report task relayed by name
// reaches a brief as its hash, and the hash of a name like dispatch-r47 names
// no discussion (spec 153 3.12; of 193 such lanes in 7 days, 92 had a topic).
func (s *Server) laneTopicOfRelayHash(ctx context.Context, tenant, hash string) (string, *issueErr) {
	d, ok := s.issueDiscussionStore()
	if !ok {
		return "", nil
	}
	ids, err := d.TopicIDs(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("fleet lane relay hash")
		return "", &issueErr{http.StatusInternalServerError, "internal", "lane map unavailable"}
	}
	found := ""
	for _, id := range ids {
		if relayTaskHash("dispatch-"+id[:8]) == hash {
			if found != "" {
				return "", nil
			}
			found = id
		}
	}
	return found, nil
}
