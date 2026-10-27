package hub

import (
	"cmp"
	"context"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Every Lanes row names its issue, its discussion and its workspace (spec
// 153 v1.3 section 3.8, SPL-3818; owner HUM-10, csitea a1ae72a7 msgs
// 80e92ffb + a6c87420, t1 f94e07bf msgs 77d5b3ab, 33f8eecb, 67c63b8d):
//
//   - a spawn ask the placer holds (state queued) is a row too, state
//     "queued", after the live lanes, in the queue's order: the owner was
//     told a lane was coming and saw none;
//   - every row carries the workspace it belongs to, the last column of the
//     Lanes table: the workspace holding its topic, else the operator
//     workspace, where the row lives.
//
// An ask's topic is its topic when a full uuid, else the 8 hex of a
// dispatch-<topic8> topic resolved as a lane put resolves it (laneTopic):
// the operator's topic first, else the one topic of another workspace.
// Anything else (gc-sat, dispatch-status-sweep) names no topic.

const laneStateQueued = "queued"

// askDispatchRe is an ask topic that names its hub topic by 8 hex.
var askDispatchRe = regexp.MustCompile(`^dispatch-([0-9a-f]{8})$`)

// queuedLane is one queued ask: its resolved topic and its row before links.
type queuedLane struct {
	topic string
	row   fleetLaneViewJSON
}

// queuedLanes is the operator workspace's queued asks of fleet, queue order.
func (s *Server) queuedLanes(ctx context.Context, op, fleet string) ([]queuedLane, error) {
	now := s.o.Now()
	as, err := s.o.Store.ListFleetAsks(ctx, op, fleet, "", false, now)
	if err != nil {
		return nil, err
	}
	slices.SortStableFunc(as, func(a, b store.FleetAsk) int { return cmp.Compare(a.Position, b.Position) })
	out, seen := []queuedLane{}, map[string]string{}
	for _, a := range as {
		if a.State != laneStateQueued {
			continue
		}
		topic, err := s.askTopic(ctx, op, a.Topic, seen)
		if err != nil {
			return nil, err
		}
		at := cmp.Or(a.EnqueuedAt, a.CreatedAt)
		vendor, _, _ := strings.Cut(a.Placement, ":")
		out = append(out, queuedLane{topic: topic, row: fleetLaneViewJSON{Vendor: vendor, Scope: a.Summary,
			TopicID: topic, Issues: []fleetLaneIssueJSON{}, UpdatedAt: at.UTC().Format(time.RFC3339),
			AgeS: int64(now.Sub(at).Seconds()), State: laneStateQueued, Wait: a.Reason}})
	}
	return out, nil
}

// askTopic is the hub topic an ask's topic names, "" for none; seen caches
// the short ids already resolved in this answer.
func (s *Server) askTopic(ctx context.Context, op, topic string, seen map[string]string) (string, error) {
	if uuidRe.MatchString(topic) {
		return topic, nil
	}
	m := askDispatchRe.FindStringSubmatch(topic)
	if m == nil {
		return "", nil
	}
	if got, ok := seen[m[1]]; ok {
		return got, nil
	}
	got, ae := s.laneTopic(ctx, op, m[1])
	if ae != nil {
		return "", ae
	}
	seen[m[1]] = got
	return got, nil
}

// laneWorkspaces is every workspace's name by id (the id when it has no
// name), and for each of topics the one other workspace than op (archived
// ones aside) that holds it, read in that workspace's own scope. A store
// with no workspace list names nothing.
func (s *Server) laneWorkspaces(ctx context.Context, op string, topics []string) (names, of map[string]string, err error) {
	names, of = map[string]string{}, map[string]string{}
	ws, listed := s.o.Store.(store.OperatorWorkspaces)
	if !listed {
		return names, of, nil
	}
	all, err := ws.ListWorkspaces(ctx)
	if err != nil {
		return nil, nil, err
	}
	d, ok := s.issueDiscussionStore()
	left := slices.DeleteFunc(slices.Clone(topics), func(t string) bool { return !uuidRe.MatchString(t) })
	for _, w := range all {
		names[w.ID] = cmp.Or(w.DisplayName, w.ID)
		if !ok || len(left) == 0 || w.ID == op || !w.ArchivedAt.IsZero() {
			continue
		}
		st, err := d.DiscussionStates(ctx, w.ID, left)
		if err != nil {
			return nil, nil, err
		}
		left = slices.DeleteFunc(left, func(t string) bool {
			if x := st[t]; x.State != "" && x.State != store.DiscussionGone {
				of[t] = w.ID
				return true
			}
			return false
		})
	}
	return names, of, nil
}

// laneLinkRows is the lanes and the queued asks as fleetLaneLinks reads
// them: the topic and the own key of each.
func laneLinkRows(active []store.FleetLane, queued []queuedLane) []store.FleetLane {
	out := slices.Clone(active)
	for _, q := range queued {
		if q.topic != "" {
			out = append(out, store.FleetLane{Topic: q.topic})
		}
	}
	return out
}
