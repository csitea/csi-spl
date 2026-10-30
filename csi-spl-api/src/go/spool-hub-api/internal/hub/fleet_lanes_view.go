package hub

import (
	"cmp"
	"context"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The live lanes view (spec 153 v1.0 section 3.3, build row B3, SPL-3158;
// owner HUM-10, prd t1 5e7b15c9, msgs 5949d68e and 5c7d1395): the active
// lanes of the operator workspace's fleet, each with its discussion and its
// issues, for the Monitoring page's Lanes tab (refreshed every minute).
//
//	GET /v1/operator/fleet-lanes?fleet=<fleet, default main>
//
// Who may: the fleet load doors (fleetLoadCaller), as fleet-tokens: the
// operator workspace's admin or the operator service account. One tenant
// only: the operator workspace's lanes, topics and issues, never another
// tenant's; a lane whose topic is not one of its topics shows no title and
// only its own issue.
//
// Active (decision P1) = state live AND a lane id (^[acgmq]-[0-9]{3}$) AND
// (token burn of agent_id under box_tag = agent_box within
// fleetLaneBurnFresh OR updated_at within fleetLaneWriteFresh).

const (
	fleetLaneBurnFresh  = 15 * time.Minute
	fleetLaneWriteFresh = 60 * time.Minute
	// fleetLaneBurnLookback is how far back last_active is read.
	fleetLaneBurnLookback = fleetLaneWriteFresh
	fleetLanesFleet       = "main"
)

// laneIDRe is a lane's agent id (rdb 0155): the box row BOX-0 and the old
// upper-case ids are no lanes.
var laneIDRe = regexp.MustCompile(`^[acgmq]-[0-9]{3}$`)

type fleetLaneIssueJSON struct {
	Key    string `json:"key"`
	Status string `json:"status"`
}

type fleetLaneViewJSON struct {
	AgentID    string               `json:"agent_id"`
	AgentBox   string               `json:"agent_box"`
	Vendor     string               `json:"vendor"`
	Scope      string               `json:"scope"`
	TopicID    string               `json:"topic_id"`
	TopicTitle string               `json:"topic_title"`
	Issues     []fleetLaneIssueJSON `json:"issues"`
	UpdatedAt  string               `json:"updated_at"`
	AgeS       int64                `json:"age_s"`
	LastActive string               `json:"last_active"`
	// spec 153 v1.3 3.8: live | queued; a queued row's wait reason ("" =
	// waiting for room); the workspace the row belongs to, the last column
	State         string `json:"state"`
	Wait          string `json:"wait,omitempty"`
	Workspace     string `json:"workspace"`
	WorkspaceName string `json:"workspace_name"`
	// SPL-4421: the topic's channel, set only where the title is (same
	// door); "" for a DM, another workspace's topic or a withheld title
	TopicChannel string `json:"topic_channel"`
}

type fleetLanesViewJSON struct {
	AsOf  string              `json:"as_of"`
	Fleet string              `json:"fleet"`
	Lanes []fleetLaneViewJSON `json:"lanes"`
}

func (s *Server) routeFleetLanes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/fleet-lanes", s.handleFleetLanesView)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-lanes", s.operatorWorkspacesPreflight)
}

// GET /v1/operator/fleet-lanes?fleet=
func (s *Server) handleFleetLanesView(w http.ResponseWriter, r *http.Request) {
	tenant, a, _, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return
	}
	fleet := r.URL.Query().Get("fleet")
	if fleet == "" {
		fleet = fleetLanesFleet
	}
	if !store.FleetNameRe.MatchString(fleet) {
		writeErr(w, http.StatusBadRequest, "bad_query", "fleet must be a lowercase slug ([a-z0-9-], up to 32)")
		return
	}
	reader := ""
	if a != nil {
		reader = a.hum
	}
	out, err := s.fleetLanesView(r.Context(), tenant, fleet, reader)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("fleet", fleet).Msg("fleet lanes view")
		writeErr(w, http.StatusInternalServerError, "internal", "lane map unavailable")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// fleetLanesView reads the active lanes and the queued asks and fills their
// links and workspaces (3.8); reader is the admin whose topic door decides
// the titles ("" = the service account).
func (s *Server) fleetLanesView(ctx context.Context, tenant, fleet, reader string) (fleetLanesViewJSON, error) {
	out, active, burn, err := s.activeFleetLanes(ctx, tenant, fleet)
	if err != nil {
		return out, err
	}
	queued, err := s.queuedLanes(ctx, tenant, fleet)
	if err != nil {
		return out, err
	}
	titles, byTopic, status, prefix, err := s.fleetLaneLinks(ctx, tenant, reader, laneLinkRows(active, queued))
	if err != nil {
		return out, err
	}
	elsewhere := []string{}
	for _, l := range laneLinkRows(active, queued) {
		if _, mine := titles[l.Topic]; !mine && l.Topic != "" {
			elsewhere = append(elsewhere, l.Topic)
		}
	}
	names, of, err := s.laneWorkspaces(ctx, tenant, elsewhere)
	if err != nil {
		return out, err
	}
	place := func(v *fleetLaneViewJSON, topic string) {
		v.Workspace = cmp.Or(of[topic], tenant)
		v.WorkspaceName = cmp.Or(names[v.Workspace], v.Workspace)
	}
	for _, l := range active { // ListFleetLanes order: newest write first
		v := fleetLaneRow(l, burn)
		topic, mine := titles[l.Topic]
		if mine {
			v.TopicTitle, v.TopicChannel = topic.Title, topic.Channel
		}
		v.Issues = laneIssues(l.IssueKey, prefix, mine, byTopic[l.Topic], status)
		place(&v, l.Topic)
		out.Lanes = append(out.Lanes, v)
	}
	for _, q := range queued { // the queue's order, after the lanes
		v := q.row
		if topic, mine := titles[q.topic]; mine {
			v.TopicTitle, v.TopicChannel = topic.Title, topic.Channel
			v.Issues = laneIssues("", prefix, true, byTopic[q.topic], status)
		}
		place(&v, q.topic)
		out.Lanes = append(out.Lanes, v)
	}
	return out, nil
}

// activeFleetLanes is the answer's head (as_of, fleet, no lanes yet), the
// tenant's active lanes of fleet (decision P1, newest write first) and the
// token burn the rule read: the part the operator view (3.3) and the
// workspace view (3.6) share.
func (s *Server) activeFleetLanes(ctx context.Context, tenant, fleet string) (
	fleetLanesViewJSON, []store.FleetLane, map[[2]string]store.FleetTokenBucket, error) {
	now := s.o.Now()
	out := fleetLanesViewJSON{AsOf: now.UTC().Format(time.RFC3339), Fleet: fleet, Lanes: []fleetLaneViewJSON{}}
	ls, err := s.o.Store.ListFleetLanes(ctx, tenant, fleet, now)
	if err != nil {
		return out, nil, nil, err
	}
	burn, err := s.fleetLaneBurn(ctx, now)
	if err != nil {
		return out, nil, nil, err
	}
	active := []store.FleetLane{}
	for _, l := range ls {
		b, burnt := burn[[2]string{l.AgentBox, l.AgentID}]
		if l.State == "live" && laneIDRe.MatchString(l.AgentID) &&
			((burnt && now.Sub(b.Minute) <= fleetLaneBurnFresh) || l.Age <= fleetLaneWriteFresh) {
			active = append(active, l)
		}
	}
	return out, active, burn, nil
}

// fleetLaneRow is one active lane's row before its links: no title, no issues.
func fleetLaneRow(l store.FleetLane, burn map[[2]string]store.FleetTokenBucket) fleetLaneViewJSON {
	v := fleetLaneViewJSON{AgentID: l.AgentID, AgentBox: l.AgentBox, Vendor: agentid.Kind(l.AgentID), Scope: l.Scope,
		State: "live", TopicID: l.Topic, Issues: []fleetLaneIssueJSON{}, UpdatedAt: l.UpdatedAt.UTC().Format(time.RFC3339), AgeS: int64(l.Age.Seconds())}
	if b, ok := burn[[2]string{l.AgentBox, l.AgentID}]; ok {
		v.LastActive = b.Minute.UTC().Format(time.RFC3339)
		if b.Vendor != "" {
			v.Vendor = b.Vendor
		}
	}
	return v
}

// fleetLaneBurn is each (box_tag, agent_id)'s newest token-burn minute within
// the lookback; a store with no token burn answers none.
func (s *Server) fleetLaneBurn(ctx context.Context, now time.Time) (map[[2]string]store.FleetTokenBucket, error) {
	out := map[[2]string]store.FleetTokenBucket{}
	ft, ok := s.o.Store.(store.FleetTokenStore)
	if !ok {
		return out, nil
	}
	rows, err := ft.ListBuckets(ctx, now.Add(-fleetLaneBurnLookback), "")
	if err != nil {
		return nil, err
	}
	for _, b := range rows {
		k := [2]string{b.BoxTag, b.AgentID}
		if cur, seen := out[k]; !seen || b.Minute.After(cur.Minute) {
			out[k] = b
		}
	}
	return out, nil
}

// fleetLaneLinks reads, for the active lanes, the title and channel of each
// topic the reader may open in the tenant (absent: not the tenant's, gone,
// or closed to the reader), the issues each such topic links, every issue's status
// and the tenant's issue key prefix.
func (s *Server) fleetLaneLinks(ctx context.Context, tenant, reader string, ls []store.FleetLane) (
	titles map[string]store.DiscussionState, byTopic map[string][]int, status map[int]string, prefix string, err error) {
	titles, byTopic, status = map[string]store.DiscussionState{}, map[string][]int{}, map[int]string{}
	topics, numbers := []string{}, []int{}
	for _, l := range ls {
		if l.Topic != "" && !slices.Contains(topics, l.Topic) {
			topics = append(topics, l.Topic)
		}
		if n, ok := store.ParseIssueRef(l.IssueKey); ok {
			numbers = append(numbers, n)
		}
	}
	if is, ok := s.o.Store.(store.Issues); ok {
		if prefix, err = is.IssuePrefix(ctx, tenant); err != nil {
			return
		}
	}
	d, ok := s.issueDiscussionStore()
	if !ok || len(ls) == 0 {
		return
	}
	states, err := d.DiscussionStates(ctx, tenant, topics)
	if err != nil {
		return
	}
	mine := []string{}
	for _, t := range topics {
		st := states[t]
		if st.State == "" || st.State == store.DiscussionGone {
			continue
		}
		may, _, rerr := s.canReadTopic(ctx, tenant, t, reader)
		if rerr != nil {
			err = rerr
			return
		}
		if may {
			titles[t] = st
			mine = append(mine, t)
		}
	}
	byTopic, status, err = s.o.Store.FleetLaneIssues(ctx, tenant, mine, numbers)
	return
}

// laneIssues is a lane's issues: those its topic links (when the topic is
// the tenant's) and its own key, each once, ascending. An own key of another
// prefix is listed as sent, with no status.
func laneIssues(own, prefix string, mine bool, linked []int, status map[int]string) []fleetLaneIssueJSON {
	out := []fleetLaneIssueJSON{}
	nums := []int{}
	if mine {
		nums = append(nums, linked...)
	}
	foreign := ""
	if n, ok := store.ParseIssueRef(own); ok && own != "" {
		if strings.EqualFold(own, store.IssueKey(prefix, n)) {
			if !slices.Contains(nums, n) {
				nums = append(nums, n)
			}
		} else {
			foreign = own
		}
	}
	slices.Sort(nums)
	for _, n := range nums {
		out = append(out, fleetLaneIssueJSON{Key: store.IssueKey(prefix, n), Status: status[n]})
	}
	if foreign != "" {
		out = append(out, fleetLaneIssueJSON{Key: foreign})
	}
	return out
}
