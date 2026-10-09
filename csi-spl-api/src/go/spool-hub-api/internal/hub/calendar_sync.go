package hub

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"net/http"
	"regexp"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// PUT /v1/calendar/sync (specs/112 HUB-1, HUB-2; spec 4.1, 4.2, D2, 12.2-12.5):
// the roadmap's dates (goal deadlines and milestones, spec done-dates, past
// releases, db: topics) into the calendars of the workspaces they name, as an
// idempotent bulk upsert by (tenant_id, source_key) per workspace
// (store.UpsertCalendarBySourceKey). Every event is written as creator_type
// 'system', creator_id 'roadmap-sync'.
//
//   - Who: the deploy identity only, the env service account's Google ID
//     token on the operator allow-list (operatorAuth). A member session or an
//     agent's bearer token is 403 deploy_identity_only, before anything else
//     (a member session of any workspace the request names included).
//   - Workspaces (12.2, 12.4): each goal and each event names its workspace;
//     there is no cnf workspace. The same goal:G01:deadline in two
//     workspaces is two rows. A workspace that does not exist refuses the
//     whole request (400) before anything is written.
//   - Approval (D2 as amended by 12.3): a goal is published only when its
//     approval.msg_id is a message of the goal's own workspace, written in a
//     member session (box-wui, unsigned) by a member who holds biz_owner or
//     admin there (rbac.RoleIDs, no cnf role). Any other goal is answered in
//     "unapproved" with its reason, and none of its goal:<Gnn>: events is
//     written.
//   - Audience (12.5, 4.3): a goal:, release: or spec: event carries no
//     audience (400 if it does); it is written internal, or public when its
//     workspace's roadmap switch (rdb 0162, roadmap_switch.go) is on. A db:
//     event is internal: it may say so, or say nothing.
//   - Key families (the STORE-1 finding), per workspace: the store
//     soft-deletes every live goal: and spec: key missing from a batch. This
//     route prunes only within the families the request carries for that
//     workspace: one whose part of the request names no goal (no goals[] and
//     no goal: event) carries its live goal: rows along unchanged, and one
//     with no spec: event its live spec: rows, so a partial batch (the 8.1
//     backfill's release: keys alone) never soft-deletes a goal. A family a
//     workspace's part carries is carried WHOLE: a goal: or spec: key it
//     leaves out is soft-deleted, and so are the events of a goal that came
//     back unapproved. "carried" counts the rows kept that way (they are not
//     in "unchanged"). A workspace the request does not name is not touched.
//
// The deploy runs one sync at a time (wf 20), so the carried read and the
// upsert need no lock between them. Each workspace is written in its own
// transaction; a failure part way leaves the earlier workspaces written, and
// the same request again converges (idempotent).

const (
	calendarSyncCreatorType = "system"
	calendarSyncCreatorID   = "roadmap-sync"
	calendarSyncMaxBody     = 4 << 20
	calPropRoadmapURL       = "roadmap_url"
	calendarRoadmapURLMax   = 512
)

// calendarSyncFamilies are the key families the store prunes (calendarPruned).
var calendarSyncFamilies = []string{"goal:", "spec:"}

// roadmapApproverRoles are the roles whose holder in a goal's workspace
// approves it (spec 12.3; owner msg 26477898: "both biz_owner and admin").
var roadmapApproverRoles = []string{rbac.BizOwner, rbac.Admin}

// goalIDRe is spec 2's goal id; its first three characters (G01) are the
// goal's part of a goal: key (goal:G01:deadline, goal:G01:m:<key>).
var goalIDRe = regexp.MustCompile(`^G[0-9]{2}-[a-z0-9-]{1,48}$`)

type calendarSyncGoal struct {
	ID        string `json:"id"`
	Workspace string `json:"workspace"`
	Approval  struct {
		MsgID string `json:"msg_id"`
	} `json:"approval"`
}

type calendarSyncEventIn struct {
	SourceKey      string  `json:"source_key"`
	Workspace      string  `json:"workspace"`
	Title          string  `json:"title"`
	Description    string  `json:"description"`
	Kind           string  `json:"kind"`
	StartsAt       string  `json:"starts_at"`
	EndsAt         string  `json:"ends_at"`
	AllDay         bool    `json:"all_day"`
	Audience       *string `json:"audience"`
	TimeZone       string  `json:"time_zone"`
	TopicID        string  `json:"topic_id"`
	ReleaseVersion string  `json:"release_version"`
	RoadmapURL     string  `json:"roadmap_url"`
}

type calendarSyncRequest struct {
	Goals  []calendarSyncGoal    `json:"goals"`
	Events []calendarSyncEventIn `json:"events"`
}

type calendarSyncUnapproved struct {
	ID        string `json:"id"`
	Workspace string `json:"workspace"`
	MsgID     string `json:"msg_id"`
	Reason    string `json:"reason"`
}

// calendarSyncCounts is one workspace's part of the answer.
type calendarSyncCounts struct {
	Created   int `json:"created"`
	Updated   int `json:"updated"`
	Unchanged int `json:"unchanged"`
	Deleted   int `json:"deleted"`
	Carried   int `json:"carried"`
}

// syncPart is one workspace's part of a request, checked and built.
type syncPart struct {
	public  bool // the roadmap switch, read when the part was built
	goals   map[string]calendarSyncGoal
	batch   []store.CalendarSyncEvent
	carries map[string]bool
}

// calendarSyncSeat answers whether r carries a member session of one of
// tenants, or an agent's bearer token: a seat, which the sync refuses
// whoever it is.
func (s *Server) calendarSyncSeat(r *http.Request, tenants ...string) bool {
	if _, _, _, ok := s.bearerAny(r); ok {
		return true
	}
	for _, t := range tenants {
		if t == "" {
			continue
		}
		if hum, err := s.memberID(r, t); err == nil && hum != "" {
			return true
		}
	}
	return false
}

// syncEvent is one wire event as the store writes it, in a workspace whose
// roadmap switch reads public.
func (in calendarSyncEventIn) syncEvent(public bool) (store.CalendarSyncEvent, *issueErr) {
	k := in.SourceKey
	start, ie := optCalTimePtr("starts_at", &in.StartsAt, false)
	if ie != nil {
		return store.CalendarSyncEvent{}, ie
	}
	end, ie := optCalTimePtr("ends_at", &in.EndsAt, false)
	if ie != nil {
		return store.CalendarSyncEvent{}, ie
	}
	aud := store.RoadmapAudience(public)
	switch db := strings.HasPrefix(k, "db:"); {
	case db && in.Audience != nil && *in.Audience != store.CalendarInternal:
		return store.CalendarSyncEvent{}, badCalendar("source_key " + k + ": a db: event is internal only")
	case db:
		aud = store.CalendarInternal
	case in.Audience != nil:
		return store.CalendarSyncEvent{}, badCalendar("source_key " + k + ": a roadmap event carries no audience; its workspace's roadmap switch sets it")
	}
	if in.RoadmapURL != "" && (!strings.HasPrefix(in.RoadmapURL, "/roadmap") || len(in.RoadmapURL) > calendarRoadmapURLMax) {
		return store.CalendarSyncEvent{}, badCalendar("source_key " + k + ": roadmap_url must be a /roadmap path")
	}
	e := store.CalendarEvent{Title: in.Title, Description: in.Description, Kind: in.Kind, StartsAt: *start, EndsAt: *end,
		AllDay: in.AllDay, Audience: aud, Mentions: []string{}, CreatorType: calendarSyncCreatorType,
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

// approval checks one goal's approval (D2, 12.3): "" when approved, else the
// reason. The message and its author's role are read in the goal's own
// workspace only.
func (s *Server) approval(ctx context.Context, g calendarSyncGoal) (string, error) {
	tenant, id := g.Workspace, strings.ToLower(strings.TrimSpace(g.Approval.MsgID))
	if id == "" {
		return "no approval.msg_id: a draft", nil
	}
	if !uuidRe.MatchString(id) {
		return "approval.msg_id must be the full message uuid", nil
	}
	m, err := s.o.Store.GetEditable(ctx, tenant, id, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		return "the approval message is not in the goal's workspace", nil
	case err != nil:
		return "", err
	case m.FromBox != WUIBox || m.EnvSig != "":
		return "the approval message was not written in a member session", nil
	}
	a, err := s.access(ctx, m.FromID, tenant)
	if err != nil || !slices.Contains(roadmapApproverRoles, a.Role) {
		return "the approval message's author holds neither biz_owner nor admin in the goal's workspace", nil
	}
	return "", nil
}

// syncPart answers the part of workspace ws, building it on first use: the
// workspace must exist, and its roadmap switch is read once.
func (s *Server) syncPart(ctx context.Context, rs store.RoadmapSwitch, parts map[string]*syncPart, ws string) (*syncPart, *issueErr, error) {
	if p, ok := parts[ws]; ok {
		return p, nil, nil
	}
	if !msg.ValidTenantID(ws) {
		return nil, badCalendar("workspace " + ws + " must be a workspace id; every goal and event names its workspace"), nil
	}
	public, err := rs.RoadmapPublic(ctx, ws)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return nil, badCalendar("workspace " + ws + " does not exist"), nil
	case err != nil:
		return nil, nil, err
	}
	p := &syncPart{public: public, goals: map[string]calendarSyncGoal{}, carries: map[string]bool{}}
	parts[ws] = p
	return p, nil, nil
}

// syncParts checks the request and builds, per workspace, the batch of
// approved events and which key families that workspace's part carries.
func (s *Server) syncParts(ctx context.Context, rs store.RoadmapSwitch, q calendarSyncRequest) (map[string]*syncPart, []calendarSyncUnapproved, *issueErr, error) {
	parts := map[string]*syncPart{}
	for _, g := range q.Goals {
		if !goalIDRe.MatchString(g.ID) {
			return nil, nil, badCalendar("goal id " + g.ID + " must be G<nn>-<slug>"), nil
		}
		p, ie, err := s.syncPart(ctx, rs, parts, g.Workspace)
		if ie != nil || err != nil {
			return nil, nil, ie, err
		}
		if _, dup := p.goals[g.ID[:3]]; dup {
			return nil, nil, badCalendar("goal " + g.ID[:3] + " is twice in goals of workspace " + g.Workspace), nil
		}
		p.goals[g.ID[:3]] = g
		p.carries["goal:"] = true
	}
	for _, in := range q.Events {
		p, ie, err := s.syncPart(ctx, rs, parts, in.Workspace)
		if ie != nil || err != nil {
			return nil, nil, ie, err
		}
		for _, f := range calendarSyncFamilies {
			if strings.HasPrefix(in.SourceKey, f) {
				p.carries[f] = true
			}
		}
		if _, ok := p.goals[goalOfKey(in.SourceKey)]; strings.HasPrefix(in.SourceKey, "goal:") && !ok {
			return nil, nil, badCalendar("source_key " + in.SourceKey + " names no goal of workspace " + in.Workspace + " in goals"), nil
		}
		ev, ie := in.syncEvent(p.public)
		if ie != nil {
			return nil, nil, ie, nil
		}
		p.batch = append(p.batch, ev)
	}
	unapproved := []calendarSyncUnapproved{}
	for _, g := range q.Goals {
		reason, err := s.approval(ctx, g)
		if err != nil {
			return nil, nil, nil, err
		}
		if reason == "" {
			continue
		}
		unapproved = append(unapproved, calendarSyncUnapproved{ID: g.ID, Workspace: g.Workspace, MsgID: g.Approval.MsgID, Reason: reason})
		p := parts[g.Workspace]
		p.batch = slices.DeleteFunc(p.batch, func(x store.CalendarSyncEvent) bool { // D2: no event
			return strings.HasPrefix(x.SourceKey, "goal:") && goalOfKey(x.SourceKey) == g.ID[:3]
		})
	}
	return parts, unapproved, nil, nil
}

func (s *Server) handleCalendarSync(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if s.calendarSyncSeat(r, s.hostTenantID(r)) {
		writeErr(w, http.StatusForbidden, "deploy_identity_only", "the roadmap sync is the deploy identity's; a member or agent seat may not call it")
		return
	}
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	cs, ok1 := s.o.Store.(store.CalendarSync)
	src, ok2 := s.o.Store.(store.CalendarSourced)
	rs, ok3 := s.o.Store.(store.RoadmapSwitch)
	if !ok1 || !ok2 || !ok3 {
		writeIssueErr(w, calendarUnavailable())
		return
	}
	var q calendarSyncRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, calendarSyncMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {goals, events}, each naming its workspace (specs/112 HUB-2)")
		return
	}
	var named []string
	for _, g := range q.Goals {
		named = append(named, g.Workspace)
	}
	for _, e := range q.Events {
		named = append(named, e.Workspace)
	}
	slices.Sort(named)
	if s.calendarSyncSeat(r, slices.Compact(named)...) {
		writeErr(w, http.StatusForbidden, "deploy_identity_only", "the roadmap sync is the deploy identity's; a member or agent seat may not call it")
		return
	}
	ctx := r.Context()
	parts, unapproved, ie, err := s.syncParts(ctx, rs, q)
	switch {
	case ie != nil:
		writeIssueErr(w, ie)
		return
	case err != nil:
		s.writeCalendarErr(w, "", "sync read", err)
		return
	}
	var total calendarSyncCounts
	counts := map[string]calendarSyncCounts{}
	for _, ws := range slices.Sorted(maps.Keys(parts)) {
		c, err := s.syncWorkspace(ctx, cs, src, rs, ws, parts[ws])
		if err != nil {
			s.writeCalendarErr(w, ws, "sync", err)
			return
		}
		counts[ws] = c
		total.Created += c.Created
		total.Updated += c.Updated
		total.Unchanged += c.Unchanged
		total.Deleted += c.Deleted
		total.Carried += c.Carried
	}
	s.o.Log.Info().Int("workspaces", len(counts)).Int("created", total.Created).Int("updated", total.Updated).
		Int("deleted", total.Deleted).Int("carried", total.Carried).Int("unapproved", len(unapproved)).Msg("calendar sync")
	writeJSON(w, http.StatusOK, map[string]any{"workspaces": counts, "created": total.Created, "updated": total.Updated,
		"unchanged": total.Unchanged, "deleted": total.Deleted, "carried": total.Carried, "unapproved": unapproved})
}

// syncWorkspace writes one workspace's part. A roadmap switch flipped while
// the part was being written is re-applied, so the synced audience follows
// the switch that reads last.
func (s *Server) syncWorkspace(ctx context.Context, cs store.CalendarSync, src store.CalendarSourced, rs store.RoadmapSwitch,
	ws string, p *syncPart) (calendarSyncCounts, error) {
	batch, err := s.carryFamilies(ctx, src, ws, p.batch, p.carries)
	if err != nil {
		return calendarSyncCounts{}, err
	}
	res, err := cs.UpsertCalendarBySourceKey(ctx, ws, batch, s.o.Now())
	if err != nil {
		return calendarSyncCounts{}, err
	}
	if now, err := rs.RoadmapPublic(ctx, ws); err != nil {
		return calendarSyncCounts{}, err
	} else if now != p.public {
		if _, err := rs.SetRoadmapPublic(ctx, ws, now, s.o.Now()); err != nil {
			return calendarSyncCounts{}, err
		}
	}
	carried := carriedCount(batch)
	return calendarSyncCounts{Created: res.Created, Updated: res.Updated, Unchanged: max(res.Unchanged-carried, 0),
		Deleted: res.Deleted, Carried: carried}, nil
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
