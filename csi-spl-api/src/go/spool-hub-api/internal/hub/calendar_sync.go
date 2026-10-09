package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// PUT /v1/calendar/sync (specs/112 HUB-1; spec 4.1, 4.2, D2): the roadmap's
// dates (goal deadlines and milestones, spec done-dates, past releases) into
// the calendar of ONE workspace, cnf env.roadmap.tenant_id, as an idempotent
// bulk upsert by source_key (store.UpsertCalendarBySourceKey). Every event is
// written as creator_type 'system', creator_id 'roadmap-sync'.
//
//   - Who: the deploy identity only, the env service account's Google ID
//     token on the operator allow-list (operatorAuth). A member session or an
//     agent's bearer token is 403 deploy_identity_only, before anything else.
//   - Config: cnf env.roadmap.tenant_id and env.roadmap.approver_role (an
//     rbac.RoleIDs id) have no default; either one missing, or a tenant that
//     does not exist, is 503 roadmap_not_configured and nothing is written.
//   - Approval (D2): a goal is published only when its approval.msg_id is a
//     message of the roadmap workspace written in a member session (box-wui,
//     unsigned) by a member who holds approver_role there. Any other goal is
//     answered in "unapproved" with its reason, and none of its goal:<Gnn>:
//     events is written.
//   - Key families (the STORE-1 finding): the store soft-deletes every live
//     goal: and spec: key missing from a batch. This route prunes only
//     within the families the request carries: a request that names no goal
//     (no goals[] and no goal: event) carries the live goal: rows along
//     unchanged, and one with no spec: event the live spec: rows, so a
//     partial batch (the 8.1 backfill's release: keys alone) never
//     soft-deletes a goal. A request that carries a family carries it WHOLE:
//     a goal: or spec: key it leaves out is soft-deleted, and so are the
//     events of a goal that came back unapproved. "carried" counts the rows
//     kept that way (they are not in "unchanged").
//
// The deploy runs one sync at a time (wf 20), so the carried read and the
// upsert need no lock between them.

const (
	calendarSyncCreatorType = "system"
	calendarSyncCreatorID   = "roadmap-sync"
	calendarSyncMaxBody     = 4 << 20
	calPropRoadmapURL       = "roadmap_url"
	calendarRoadmapURLMax   = 512
)

// calendarSyncFamilies are the key families the store prunes (calendarPruned).
var calendarSyncFamilies = []string{"goal:", "spec:"}

// goalIDRe is spec 2's goal id; its first three characters (G01) are the
// goal's part of a goal: key (goal:G01:deadline, goal:G01:m:<key>).
var goalIDRe = regexp.MustCompile(`^G[0-9]{2}-[a-z0-9-]{1,48}$`)

type calendarSyncGoal struct {
	ID       string `json:"id"`
	Approval struct {
		MsgID string `json:"msg_id"`
	} `json:"approval"`
}

type calendarSyncEventIn struct {
	SourceKey      string `json:"source_key"`
	Title          string `json:"title"`
	Description    string `json:"description"`
	Kind           string `json:"kind"`
	StartsAt       string `json:"starts_at"`
	EndsAt         string `json:"ends_at"`
	AllDay         bool   `json:"all_day"`
	Audience       string `json:"audience"`
	TimeZone       string `json:"time_zone"`
	TopicID        string `json:"topic_id"`
	ReleaseVersion string `json:"release_version"`
	RoadmapURL     string `json:"roadmap_url"`
}

type calendarSyncRequest struct {
	Goals  []calendarSyncGoal    `json:"goals"`
	Events []calendarSyncEventIn `json:"events"`
}

type calendarSyncUnapproved struct {
	ID     string `json:"id"`
	MsgID  string `json:"msg_id"`
	Reason string `json:"reason"`
}

// calendarSyncSeat answers whether r carries a member session or an agent's
// bearer token: a seat, which the sync refuses whoever it is.
func (s *Server) calendarSyncSeat(r *http.Request) bool {
	if _, _, _, ok := s.bearerAny(r); ok {
		return true
	}
	for _, t := range []string{s.hostTenantID(r), s.o.RoadmapTenant} {
		if t == "" {
			continue
		}
		if hum, err := s.memberID(r, t); err == nil && hum != "" {
			return true
		}
	}
	return false
}

// roadmapConfigured is the fail-fast check of the two cnf keys.
func (s *Server) roadmapConfigured() *issueErr {
	bad := func(detail string) *issueErr {
		return &issueErr{http.StatusServiceUnavailable, "roadmap_not_configured", detail}
	}
	switch {
	case s.o.RoadmapTenant == "":
		return bad("cnf env.roadmap.tenant_id (SPOOL_HUB_ROADMAP_TENANT) is not set")
	case s.o.RoadmapApproverRole == "":
		return bad("cnf env.roadmap.approver_role (SPOOL_HUB_ROADMAP_APPROVER_ROLE) is not set")
	case !slices.Contains(rbac.RoleIDs, s.o.RoadmapApproverRole):
		return bad("cnf env.roadmap.approver_role is not an rbac role id")
	}
	return nil
}

// syncEvent is one wire event as the store writes it.
func (in calendarSyncEventIn) syncEvent() (store.CalendarSyncEvent, *issueErr) {
	k := in.SourceKey
	start, ie := optCalTimePtr("starts_at", &in.StartsAt, false)
	if ie != nil {
		return store.CalendarSyncEvent{}, ie
	}
	end, ie := optCalTimePtr("ends_at", &in.EndsAt, false)
	if ie != nil {
		return store.CalendarSyncEvent{}, ie
	}
	switch {
	case store.CalendarAudienceOf(in.Audience) != store.CalendarWorkspace && in.Audience != store.CalendarInternal:
		return store.CalendarSyncEvent{}, badCalendar("source_key " + k + ": audience must be workspace or internal")
	case in.RoadmapURL != "" && (!strings.HasPrefix(in.RoadmapURL, "/roadmap") || len(in.RoadmapURL) > calendarRoadmapURLMax):
		return store.CalendarSyncEvent{}, badCalendar("source_key " + k + ": roadmap_url must be a /roadmap path")
	}
	e := store.CalendarEvent{Title: in.Title, Description: in.Description, Kind: in.Kind, StartsAt: *start, EndsAt: *end,
		AllDay: in.AllDay, Audience: in.Audience, Mentions: []string{}, CreatorType: calendarSyncCreatorType,
		CreatorID: calendarSyncCreatorID, TopicID: in.TopicID, ReleaseVersion: in.ReleaseVersion,
		TimeZone: in.TimeZone, Props: map[string]any{}}
	if in.RoadmapURL != "" {
		e.Props[calPropRoadmapURL] = in.RoadmapURL
	}
	return store.CalendarSyncEvent{SourceKey: k, Event: e}, nil
}

// goalOfKey is the goal part of a goal: key (G01 of goal:G01:deadline).
func goalOfKey(k string) string {
	rest, _ := strings.CutPrefix(k, "goal:")
	g, _, _ := strings.Cut(rest, ":")
	return g
}

// approval checks one goal's approval (D2): "" when approved, else the reason.
func (s *Server) approval(ctx context.Context, g calendarSyncGoal) (string, error) {
	tenant, id := s.o.RoadmapTenant, strings.ToLower(strings.TrimSpace(g.Approval.MsgID))
	if id == "" {
		return "no approval.msg_id: a draft", nil
	}
	if !uuidRe.MatchString(id) {
		return "approval.msg_id must be the full message uuid", nil
	}
	m, err := s.o.Store.GetEditable(ctx, tenant, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		return "the approval message is not in the roadmap workspace", nil
	case err != nil:
		return "", err
	case m.FromBox != WUIBox || m.EnvSig != "":
		return "the approval message was not written in a member session", nil
	}
	a, err := s.access(ctx, m.FromID, tenant)
	if err != nil || a.Role != s.o.RoadmapApproverRole {
		return "the approval message's author does not hold the approver role", nil
	}
	return "", nil
}

// syncBatch checks the request and builds the batch of approved events, and
// which key families the request carries.
func (s *Server) syncBatch(ctx context.Context, q calendarSyncRequest) ([]store.CalendarSyncEvent, []calendarSyncUnapproved, map[string]bool, *issueErr, error) {
	goals, carried := map[string]calendarSyncGoal{}, map[string]bool{}
	for _, g := range q.Goals {
		if !goalIDRe.MatchString(g.ID) {
			return nil, nil, nil, badCalendar("goal id " + g.ID + " must be G<nn>-<slug>"), nil
		}
		if _, dup := goals[g.ID[:3]]; dup {
			return nil, nil, nil, badCalendar("goal " + g.ID[:3] + " is twice in goals"), nil
		}
		goals[g.ID[:3]] = g
		carried["goal:"] = true
	}
	approved, unapproved := map[string]bool{}, []calendarSyncUnapproved{}
	for _, g := range q.Goals {
		reason, err := s.approval(ctx, g)
		if err != nil {
			return nil, nil, nil, nil, err
		}
		if reason == "" {
			approved[g.ID[:3]] = true
		} else {
			unapproved = append(unapproved, calendarSyncUnapproved{ID: g.ID, MsgID: g.Approval.MsgID, Reason: reason})
		}
	}
	batch := make([]store.CalendarSyncEvent, 0, len(q.Events))
	for _, in := range q.Events {
		for _, f := range calendarSyncFamilies {
			if strings.HasPrefix(in.SourceKey, f) {
				carried[f] = true
			}
		}
		if strings.HasPrefix(in.SourceKey, "goal:") {
			if _, ok := goals[goalOfKey(in.SourceKey)]; !ok {
				return nil, nil, nil, badCalendar("source_key " + in.SourceKey + " names no goal in goals"), nil
			}
		}
		ev, ie := in.syncEvent()
		if ie != nil {
			return nil, nil, nil, ie, nil
		}
		if strings.HasPrefix(in.SourceKey, "goal:") && !approved[goalOfKey(in.SourceKey)] {
			continue // D2: an unapproved goal writes no event
		}
		batch = append(batch, ev)
	}
	return batch, unapproved, carried, nil, nil
}

func (s *Server) handleCalendarSync(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if s.calendarSyncSeat(r) {
		writeErr(w, http.StatusForbidden, "deploy_identity_only", "the roadmap sync is the deploy identity's; a member or agent seat may not call it")
		return
	}
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	if ie := s.roadmapConfigured(); ie != nil {
		writeIssueErr(w, ie)
		return
	}
	cs, ok1 := s.o.Store.(store.CalendarSync)
	src, ok2 := s.o.Store.(store.CalendarSourced)
	if !ok1 || !ok2 {
		writeIssueErr(w, calendarUnavailable())
		return
	}
	var q calendarSyncRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, calendarSyncMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {goals, events} (specs/112 HUB-1)")
		return
	}
	ctx, tenant := r.Context(), s.o.RoadmapTenant
	batch, unapproved, carries, ie, err := s.syncBatch(ctx, q)
	if err == nil && ie == nil {
		batch, err = s.carryFamilies(ctx, src, tenant, batch, carries)
	}
	switch {
	case ie != nil:
		writeIssueErr(w, ie)
		return
	case err != nil:
		s.writeCalendarErr(w, tenant, "sync read", err)
		return
	}
	res, err := cs.UpsertCalendarBySourceKey(ctx, tenant, batch, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeIssueErr(w, &issueErr{http.StatusServiceUnavailable, "roadmap_not_configured", "cnf env.roadmap.tenant_id names no workspace"})
		return
	case err != nil:
		s.writeCalendarErr(w, tenant, "sync", err)
		return
	}
	carried := carriedCount(batch)
	s.o.Log.Info().Str("tenant", tenant).Int("created", res.Created).Int("updated", res.Updated).
		Int("deleted", res.Deleted).Int("carried", carried).Int("unapproved", len(unapproved)).Msg("calendar sync")
	writeJSON(w, http.StatusOK, map[string]any{"tenant": tenant, "created": res.Created, "updated": res.Updated,
		"unchanged": max(res.Unchanged-carried, 0), "deleted": res.Deleted, "carried": carried, "unapproved": unapproved})
}

// carryFamilies adds, for each pruned family the request does not carry,
// its live rows unchanged, so the store keeps them (see above).
func (s *Server) carryFamilies(ctx context.Context, src store.CalendarSourced, tenant string,
	batch []store.CalendarSyncEvent, carries map[string]bool) ([]store.CalendarSyncEvent, error) {
	for _, f := range calendarSyncFamilies {
		if carries[f] {
			continue
		}
		rows, err := src.CalendarBySourceKey(ctx, tenant, calendarSyncCreatorID, f)
		if err != nil {
			return nil, err
		}
		for _, e := range rows {
			batch = append(batch, store.CalendarSyncEvent{SourceKey: e.SourceKey, Event: e})
		}
	}
	return batch, nil
}

// carriedCount is how many rows of batch carryFamilies added: those with a
// stored id (a wire event has none).
func carriedCount(batch []store.CalendarSyncEvent) int {
	n := 0
	for _, x := range batch {
		if x.Event.ID != "" {
			n++
		}
	}
	return n
}
