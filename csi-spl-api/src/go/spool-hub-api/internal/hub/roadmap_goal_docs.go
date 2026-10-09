package hub

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// In-app goals for a workspace with no repo (specs/112 HUB-3, spec 12.2 OQ1,
// 12.8; the shape note in tasks.md, agreed with the spec 113 lane).
//
//	PUT /v1/workspace/doctree/{doc}/goal   {rev, goal}: save a goal doc
//
// A goal doc is a spec 113 workspace doc (rdb 0157) whose hidden root item
// carries attrs.goal: the template-goal.yaml fields (DOC-2) with no
// workspace, because the doc's tenant IS the goal's workspace, so a goal doc
// of workspace B can never write into A (a workspace field naming another is
// 400). The other root attrs (topic_id) are kept. Saving one runs HUB-2's
// approval check (approval: a biz_owner or an admin of that workspace wrote
// approval.msg_id there) and its upsert
// (syncWorkspace) for that workspace only, as creator_id 'roadmap-sync',
// giving the same goal:<Gnn>:deadline and goal:<Gnn>:m:<key> events ORC-2
// writes from a goal.yaml. The spool's own roadmap is just another workspace
// (OQ2): nothing here names it.
//
//   - Who: a member holding docs.write, or an agent (the doctree door). The
//     approval, not the saver, decides whether events are written.
//   - rev is the root item's rev the caller read (0 = no precondition); a
//     stale one is 412 and writes nothing, events included.
//   - The upsert carries every other live goal: key of the workspace
//     unchanged (one goal doc never prunes another, nor a goal.yaml goal);
//     this goal's keys are replaced whole: an unapproved or draft goal keeps
//     none, a dropped milestone is soft-deleted.
//   - A goal:<Gnn>: key already held by another source (another goal doc, a
//     goal.yaml) is 409 goal_id_taken, before anything is written.
//   - Saves of one workspace are serialised in this process; the doc's root
//     rev serialises saves of one doc across instances.

const (
	calPropGoalDoc   = "goal_doc"
	calPropSpecs     = "specs"
	calPropDoneLines = "done_lines"
	goalDocMaxBody   = 256 << 10
	goalDocTextMax   = 500
	goalDocListMax   = 100
)

var (
	goalMilestoneKeyRe = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)
	goalSpecIDRe       = regexp.MustCompile(`^[0-9]{3}$`)
)

// goalDocMu serialises the goal-doc saves of one workspace (its carried read
// and its upsert).
var goalDocMu sync.Map // workspace -> *sync.Mutex

// goalDoc is attrs.goal: template-goal.yaml's fields. workspace may be
// given (a goal.yaml copied in) but must name the doc's own workspace.
type goalDoc struct {
	ID               string          `json:"id"`
	Workspace        string          `json:"workspace,omitempty"`
	OwnerRole        string          `json:"owner_role"`
	Public           *bool           `json:"public,omitempty"`
	BackfillStartSHA string          `json:"backfill_start_sha,omitempty"`
	Deadline         string          `json:"deadline"`
	Milestones       []goalMilestone `json:"milestones"`
	DoneLines        []string        `json:"done_lines"`
	Specs            []string        `json:"specs"`
	Lanes            []string        `json:"lanes,omitempty"`
	Approval         struct {
		MsgID string `json:"msg_id"`
	} `json:"approval"`
}

type goalMilestone struct {
	Key   string `json:"key"`
	Date  string `json:"date"`
	Title string `json:"title"`
}

// goalDate is an ISO date's all-day start, or "" when d is not one.
func goalDate(d string) string {
	t, err := time.Parse(time.DateOnly, d)
	if err != nil {
		return ""
	}
	return t.Format(time.RFC3339)
}

func textsOK(xs []string, re *regexp.Regexp) bool {
	if len(xs) > goalDocListMax {
		return false
	}
	for _, x := range xs {
		if x == "" || len(x) > goalDocTextMax || (re != nil && !re.MatchString(x)) {
			return false
		}
	}
	return true
}

// check answers what is wrong with g in workspace ws ("" = nothing), spec
// 2's rules.
func (g goalDoc) check(ws string) string {
	keys := map[string]bool{}
	for _, m := range g.Milestones {
		switch {
		case !goalMilestoneKeyRe.MatchString(m.Key):
			return "milestone key " + m.Key + " must be [a-z0-9-]{1,32}"
		case keys[m.Key]:
			return "milestone key " + m.Key + " is twice in milestones"
		case goalDate(m.Date) == "":
			return "milestone " + m.Key + ": date must be YYYY-MM-DD"
		case len(m.Title) > goalDocTextMax:
			return "milestone " + m.Key + ": title is too long"
		}
		keys[m.Key] = true
	}
	switch {
	case g.Workspace != "" && g.Workspace != ws:
		return "workspace must be this doc's own workspace (" + ws + "): a goal doc never writes into another"
	case !goalIDRe.MatchString(g.ID):
		return "id must be G<nn>-<slug>"
	case !slices.Contains(rbac.RoleIDs, g.OwnerRole):
		return "owner_role must be a role id, never a name"
	case goalDate(g.Deadline) == "":
		return "deadline must be YYYY-MM-DD"
	case len(g.Milestones) > goalDocListMax:
		return "too many milestones"
	case !textsOK(g.DoneLines, nil):
		return "done_lines are non-empty lines"
	case !textsOK(g.Specs, goalSpecIDRe):
		return "specs are three-digit spec ids"
	case !textsOK(g.Lanes, nil), len(g.BackfillStartSHA) > 64, len(g.Approval.MsgID) > 64:
		return "lanes, backfill_start_sha or approval.msg_id is too long"
	}
	return ""
}

// events are g's wire events in workspace ws, as ORC-2 builds them from a
// goal.yaml (spec 4.2 keys).
func (g goalDoc) events(ws string) []calendarSyncEventIn {
	gid := g.ID[:3]
	url := "/roadmap?ws=" + ws + "&goal=" + gid
	out := []calendarSyncEventIn{{SourceKey: "goal:" + gid + ":deadline", Workspace: ws, Title: g.ID + " deadline",
		Kind: "goal", StartsAt: goalDate(g.Deadline), EndsAt: goalDate(g.Deadline), AllDay: true, RoadmapURL: url}}
	for _, m := range g.Milestones {
		title := m.Title
		if title == "" {
			title = g.ID + " " + m.Key
		}
		out = append(out, calendarSyncEventIn{SourceKey: "goal:" + gid + ":m:" + m.Key, Workspace: ws, Title: title,
			Kind: "milestone", StartsAt: goalDate(m.Date), EndsAt: goalDate(m.Date), AllDay: true, RoadmapURL: url})
	}
	return out
}

func (s *Server) routeGoalDocs(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/workspace/doctree/{doc}/goal", s.handleGoalDocSave)
}

func (s *Server) handleGoalDocSave(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	cs, ok1 := s.o.Store.(store.CalendarSync)
	src, ok2 := s.o.Store.(store.CalendarSourced)
	rs, ok3 := s.o.Store.(store.RoadmapSwitch)
	if !ok1 || !ok2 || !ok3 {
		writeIssueErr(w, calendarUnavailable())
		return
	}
	var in struct {
		Rev  int64   `json:"rev"`
		Goal goalDoc `json:"goal"`
	}
	if !readJSONStrict(w, r, &in, goalDocMaxBody, "invalid JSON body (only rev and goal, the template-goal.yaml fields without workspace)") {
		return
	}
	if why := in.Goal.check(c.tenant); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_goal", why)
		return
	}
	ctx, doc, ws := r.Context(), r.PathValue("doc"), c.tenant
	mu, _ := goalDocMu.LoadOrStore(ws, &sync.Mutex{})
	mu.(*sync.Mutex).Lock()
	defer mu.(*sync.Mutex).Unlock()
	h, err := c.st.DocHeadOf(ctx, ws, doc)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	if in.Rev != 0 && in.Rev != h.RootRev {
		docTreeFail(w, store.ErrDocStale)
		return
	}
	p, others, ie, err := s.goalDocPart(ctx, src, rs, ws, doc, in.Goal)
	switch {
	case err != nil:
		s.writeCalendarErr(w, ws, "goal doc read", err)
		return
	case ie != nil:
		writeIssueErr(w, ie)
		return
	}
	attrs := map[string]any{}
	_ = json.Unmarshal(h.RootAttrs, &attrs)
	attrs["goal"] = in.Goal
	raw, _ := json.Marshal(attrs)
	rev, err := c.st.DocItemUpdateField(ctx, ws, doc, h.RootID, "attrs", string(raw), h.RootRev)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	reason, err := s.approval(ctx, calendarSyncGoal{ID: in.Goal.ID, Workspace: ws, Approval: in.Goal.Approval})
	if err != nil {
		s.writeCalendarErr(w, ws, "goal doc approval", err)
		return
	}
	if reason != "" { // D2: an unapproved goal keeps none of its events
		p.batch = others
	}
	n, err := s.syncWorkspace(ctx, cs, src, rs, ws, p)
	if err != nil {
		s.writeCalendarErr(w, ws, "goal doc sync", err)
		return
	}
	s.o.Log.Info().Str("tenant", ws).Str("goal", in.Goal.ID).Bool("approved", reason == "").Int("created", n.Created).
		Int("updated", n.Updated).Int("deleted", n.Deleted).Msg("goal doc sync")
	writeJSON(w, http.StatusOK, map[string]any{"root_rev": rev, "goal": in.Goal.ID, "approved": reason == "",
		"unapproved_reason": reason, "created": n.Created, "updated": n.Updated, "unchanged": n.Unchanged,
		"deleted": n.Deleted, "carried": n.Carried})
}

// goalDocPart is the save's syncPart for workspace ws: the other goals'
// live rows carried, then g's events. others is the carried rows alone (the
// batch of an unapproved goal).
func (s *Server) goalDocPart(ctx context.Context, src store.CalendarSourced, rs store.RoadmapSwitch, ws, doc string,
	g goalDoc) (*syncPart, []store.CalendarSyncEvent, *issueErr, error) {
	others, ie, err := s.goalDocOthers(ctx, src, ws, doc, g.ID[:3])
	if ie != nil || err != nil {
		return nil, nil, ie, err
	}
	public, err := rs.RoadmapPublic(ctx, ws)
	if err != nil {
		return nil, nil, nil, err
	}
	p := &syncPart{public: public, batch: slices.Clone(others), carries: map[string]bool{"goal:": true}}
	for _, ev := range g.events(ws) {
		e, ie := ev.syncEvent(public)
		if ie != nil {
			return nil, nil, ie, nil
		}
		e.Event.Props[calPropGoalDoc] = doc
		if strings.HasSuffix(e.SourceKey, ":deadline") {
			e.Event.Props[calPropSpecs] = g.Specs
			e.Event.Props[calPropDoneLines] = g.DoneLines
		}
		p.batch = append(p.batch, e)
	}
	return p, others, nil, nil
}

// goalDocOthers is the workspace's live goal: rows that are not this doc's,
// carried unchanged; a live goal:<gid>: row of another source is 409.
func (s *Server) goalDocOthers(ctx context.Context, src store.CalendarSourced, ws, doc, gid string) ([]store.CalendarSyncEvent, *issueErr, error) {
	rows, err := src.CalendarBySourceKey(ctx, ws, calendarSyncCreatorID, "goal:")
	if err != nil {
		return nil, nil, err
	}
	var out []store.CalendarSyncEvent
	for _, e := range rows {
		from, _ := e.Props[calPropGoalDoc].(string)
		switch {
		case from == doc: // this doc's: replaced whole, its old goal id included
		case goalOfKey(e.SourceKey) == gid:
			return nil, &issueErr{http.StatusConflict, "goal_id_taken",
				"goal " + gid + " of this workspace already comes from another goal doc or a goal.yaml"}, nil
		default:
			out = append(out, store.CalendarSyncEvent{SourceKey: e.SourceKey, Event: e})
		}
	}
	return out, nil, nil
}
