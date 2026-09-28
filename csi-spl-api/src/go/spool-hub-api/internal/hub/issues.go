package hub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Issues, the way Linear keeps them (specs/039 contracts/issues-v1.md,
// rdb 0047, CLE-34993). A browser reads under the view door (topics.read)
// and writes with notes.send; a box agent does the same over its socket
// (issue frames, ws.go). Every change reaches every browser of the tenant as
// an `issue` frame, so a list updates without a reload.
//
// The discussion of an issue is an ordinary topic on its task_id in the
// reserved channel id store.ChannelIssues (SPL-68: #tasks is gone), which
// every member reads and no channel list shows; comments are posted at reply
// level.

const (
	issueFrame      = "issue"
	issueLabelFrame = "issue_label"
	// IssueChannel is the channel an issue's discussion is posted in.
	IssueChannel = store.ChannelIssues
	issueMaxBody = 64 << 10
)

// issueJSON is one issue on the wire (issues-v1 §2). Unset times and the
// parent read as "".
type issueJSON struct {
	Key         string   `json:"key"`
	Number      int      `json:"number"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Status      string   `json:"status"`
	Priority    int      `json:"priority"`
	Level       int      `json:"level"`
	Assignee    string   `json:"assignee"`
	Labels      []string `json:"labels"`
	Deadline    string   `json:"deadline"`
	Parent      string   `json:"parent"`
	Kind        string   `json:"kind"` // epic | feature | issue | subtask (SPL-18, rdb 0053)
	Epic        string   `json:"epic"` // the level-1 row above it; "" on an epic / feature
	TaskID      string   `json:"task_id"`
	Channel     string   `json:"channel"`
	CreatedBy   string   `json:"created_by"`
	CreatedAt   string   `json:"created_at"`
	UpdatedBy   string   `json:"updated_by"`
	UpdatedAt   string   `json:"updated_at"`
	CompletedAt string   `json:"completed_at"`
	CanceledAt  string   `json:"canceled_at"`
}

type issueLabelJSON struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Color     string `json:"color"`
	CreatedBy string `json:"created_by"`
	CreatedAt string `json:"created_at"`
}

func optRFC(t *time.Time) string {
	if t == nil {
		return ""
	}
	return rfc(*t)
}

// issueGetter finds an issue of the tenant by number (the JSON needs the
// parent, and for a subtask the grandparent, to name its level and its epic).
type issueGetter func(n int) (store.Issue, bool)

// getterOf is an issueGetter over a listed tenant.
func getterOf(all []store.Issue) issueGetter {
	by := make(map[int]store.Issue, len(all))
	for _, i := range all {
		by[i.Number] = i
	}
	return func(n int) (store.Issue, bool) { i, ok := by[n]; return i, ok }
}

// storeGetter reads one issue at a time (a single-issue answer).
func (s *Server) storeGetter(ctx context.Context, tenant string) issueGetter {
	is, _ := s.o.Store.(store.Issues)
	return func(n int) (store.Issue, bool) {
		if is == nil || n == 0 {
			return store.Issue{}, false
		}
		i, err := is.GetIssue(ctx, tenant, n)
		return i, err == nil
	}
}

// treeKind is the JSON kind (epic | feature | issue | subtask) and the key of
// the level-1 row above i ("" on a level-1 row).
func treeKind(i store.Issue, get issueGetter) (string, string) {
	if i.IsEpic() {
		return i.Kind, ""
	}
	p, ok := get(i.Parent)
	switch {
	case !ok:
		return store.IssueKindIssue, ""
	case p.IsEpic():
		return store.IssueKindIssue, store.IssueKey(i.Prefix, p.Number)
	}
	return "subtask", store.IssueKey(i.Prefix, p.Parent)
}

func toIssueJSON(i store.Issue, get issueGetter) issueJSON {
	parent := ""
	if i.Parent != 0 {
		parent = store.IssueKey(i.Prefix, i.Parent)
	}
	kind, epic := treeKind(i, get)
	labels := i.Labels
	if labels == nil {
		labels = []string{}
	}
	return issueJSON{Key: i.Key(), Number: i.Number, Title: i.Title, Description: i.Description, Status: i.Status,
		Priority: i.Priority, Level: i.Level, Assignee: i.Assignee, Labels: labels, Deadline: optRFC(i.Deadline),
		Parent: parent, Kind: kind, Epic: epic, TaskID: i.TaskID, Channel: IssueChannel, CreatedBy: i.CreatedBy, CreatedAt: rfc(i.CreatedAt),
		UpdatedBy: i.UpdatedBy, UpdatedAt: rfc(i.UpdatedAt), CompletedAt: optRFC(i.CompletedAt), CanceledAt: optRFC(i.CanceledAt)}
}

func toLabelJSON(l store.IssueLabel) issueLabelJSON {
	return issueLabelJSON{ID: l.LabelID, Name: l.Name, Color: l.Color, CreatedBy: l.CreatedBy, CreatedAt: rfc(l.CreatedAt)}
}

// issueRequest is the body of a create and of a PATCH: an absent (or null)
// field is left alone; deadline "" and parent "" clear.
type issueRequest struct {
	Title       *string   `json:"title"`
	Description *string   `json:"description"`
	Status      *string   `json:"status"`
	Priority    *int      `json:"priority"`
	Level       *int      `json:"level"`
	Assignee    *string   `json:"assignee"`
	Labels      *[]string `json:"labels"`
	Deadline    *string   `json:"deadline"`
	Parent      *string   `json:"parent"`
	// SPL-18: epic is the parent epic (same field as parent); kind epic adds
	// the reserved label and drops the parent, kind issue removes the label.
	Epic *string `json:"epic"`
	Kind *string `json:"kind"`
}

// issueErr is a refusal: HTTP status, error token, detail.
type issueErr struct {
	status        int
	token, detail string
}

func (e *issueErr) Error() string { return e.token + ": " + e.detail }

func badIssue(detail string) *issueErr {
	return &issueErr{http.StatusBadRequest, "bad_issue", detail}
}

// patch turns the request into a store patch (shape checks only; the store
// checks ranges, labels and parents).
func (q issueRequest) patch() (store.IssuePatch, *issueErr) {
	p := store.IssuePatch{Title: q.Title, Description: q.Description, Status: q.Status, Priority: q.Priority,
		Level: q.Level, Assignee: q.Assignee, Labels: q.Labels}
	if q.Assignee != nil {
		a := strings.TrimSpace(*q.Assignee)
		p.Assignee = &a
	}
	if q.Deadline != nil {
		p.DeadlineSet = true
		if d := strings.TrimSpace(*q.Deadline); d != "" {
			t, err := time.Parse(time.RFC3339, d)
			if err != nil {
				return p, badIssue("deadline must be RFC 3339 with a zone, e.g. 2026-10-01T15:00:00Z")
			}
			t = t.UTC()
			p.Deadline = &t
		}
	}
	if q.Epic != nil {
		if q.Parent != nil && strings.TrimSpace(*q.Parent) != strings.TrimSpace(*q.Epic) {
			return p, badIssue("epic and parent name two different issues")
		}
		q.Parent = q.Epic
	}
	if q.Kind != nil {
		switch *q.Kind {
		case store.IssueKindEpic, store.IssueKindFeature:
			zero := 0 // level 1 has no parent
			p.Parent = &zero
		case store.IssueKindIssue:
		default:
			return p, badIssue("kind must be epic, feature or issue")
		}
		p.Kind = q.Kind
	}
	if q.Parent != nil {
		n := 0
		if ref := strings.TrimSpace(*q.Parent); ref != "" {
			var ok bool
			if n, ok = store.ParseIssueRef(ref); !ok {
				return p, badIssue("parent must be an issue key like SPL-12")
			}
		}
		p.Parent = &n
	}
	return p, nil
}

func decodeIssueRequest(w http.ResponseWriter, r *http.Request) (issueRequest, bool) {
	var q issueRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, issueMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be an issue object (issues-v1 §3)")
		return q, false
	}
	return q, true
}

// storeIssueErr maps a store refusal.
func storeIssueErr(err error) *issueErr {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, store.ErrInvalidIssue):
		return badIssue(strings.TrimPrefix(err.Error(), store.ErrInvalidIssue.Error()+": "))
	case errors.Is(err, store.ErrUnknownLabel):
		return &issueErr{http.StatusBadRequest, "unknown_label", "every label must be one of the tenant's labels"}
	case errors.Is(err, store.ErrUnknownParent):
		return &issueErr{http.StatusBadRequest, "unknown_parent", "the parent is not an issue here"}
	case errors.Is(err, store.ErrEpicRequired):
		return &issueErr{http.StatusBadRequest, "epic_required", "every issue needs a parent epic (epic: SPL-n)"}
	case errors.Is(err, store.ErrBadEpic):
		return &issueErr{http.StatusBadRequest, "bad_epic", "the parent must be an epic, and an epic has no parent"}
	case errors.Is(err, store.ErrEpicHasIssues):
		return &issueErr{http.StatusConflict, "epic_has_issues", "move this epic's issues to another epic first"}
	case errors.Is(err, store.ErrIssueHasChildren):
		return &issueErr{http.StatusConflict, "issue_has_children", "delete or move this issue's children first"}
	case errors.Is(err, store.ErrNotFound):
		return &issueErr{http.StatusNotFound, "not_found", "no such issue"}
	case errors.Is(err, store.ErrConflict):
		return &issueErr{http.StatusConflict, "conflict", "issue exists"}
	}
	return &issueErr{http.StatusInternalServerError, "internal", "issue not stored"}
}

// checkAssignee: "" or a member HUM-* of the tenant or an agent the tenant's
// roster announces. Anyone else would be a name nobody can act on.
func (s *Server) checkAssignee(ctx context.Context, tenant, a string) *issueErr {
	if a == "" {
		return nil
	}
	if humanIDRe.MatchString(a) {
		if s.o.Authorizer == nil {
			return nil // the door-off rig has no member table to ask
		}
		if _, err := s.access(ctx, a, tenant); err == nil {
			return nil
		}
		return &issueErr{http.StatusBadRequest, "bad_assignee", "assignee is not a member of this tenant"}
	}
	if !msg.ValidID(a) {
		return &issueErr{http.StatusBadRequest, "bad_assignee", "assignee must be a member or an agent id"}
	}
	roster, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		return &issueErr{http.StatusInternalServerError, "internal", "roster unavailable"}
	}
	for _, agents := range roster {
		if contains(agents, a) {
			return nil
		}
	}
	return &issueErr{http.StatusBadRequest, "bad_assignee", "assignee is not an agent of this tenant"}
}

func (s *Server) issueStore() (store.Issues, *issueErr) {
	is, ok := s.o.Store.(store.Issues)
	if !ok {
		return nil, &issueErr{http.StatusServiceUnavailable, "unavailable", "this hub keeps no issues"}
	}
	return is, nil
}

// createIssue is the one create path (browser and agent). actor is the HUM-*
// or agent id recorded as created_by.
func (s *Server) createIssue(ctx context.Context, tenant, actor string, q issueRequest) (store.Issue, *issueErr) {
	is, ie := s.issueStore()
	if ie != nil {
		return store.Issue{}, ie
	}
	if q.Title == nil {
		return store.Issue{}, badIssue("title is required")
	}
	p, ie := q.patch()
	if ie != nil {
		return store.Issue{}, ie
	}
	in := store.Issue{TenantID: tenant, TaskID: newUUID(), CreatedBy: actor, Status: store.IssueBacklog}
	if q.Status != nil {
		in.Status = *q.Status
	}
	p.Status = nil // the create sets it, with its clock, in the store
	store.ApplyIssuePatch(&in, p)
	if ie := s.checkAssignee(ctx, tenant, in.Assignee); ie != nil {
		return store.Issue{}, ie
	}
	if ie := s.checkEpicField(ctx, tenant, q); ie != nil {
		return store.Issue{}, ie
	}
	if ie := s.ensureEpicLabel(ctx, tenant, actor, in.Labels); ie != nil {
		return store.Issue{}, ie
	}
	out, err := is.CreateIssue(ctx, in, s.o.Now())
	if ie := storeIssueErr(err); ie != nil {
		if ie.status == http.StatusInternalServerError {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue create")
		}
		return store.Issue{}, ie
	}
	s.fanoutIssue(ctx, tenant, map[string]any{"type": issueFrame, "op": "create", "issue": toIssueJSON(out, s.storeGetter(ctx, tenant))})
	return out, nil
}

// updateIssue is the one update path (browser and agent).
func (s *Server) updateIssue(ctx context.Context, tenant, actor string, number int, q issueRequest) (store.Issue, *issueErr) {
	is, ie := s.issueStore()
	if ie != nil {
		return store.Issue{}, ie
	}
	p, ie := q.patch()
	if ie != nil {
		return store.Issue{}, ie
	}
	if p.Empty() {
		return store.Issue{}, badIssue("nothing to change")
	}
	if ie := s.checkEpicField(ctx, tenant, q); ie != nil {
		return store.Issue{}, ie
	}
	if p.Assignee != nil {
		if ie := s.checkAssignee(ctx, tenant, *p.Assignee); ie != nil {
			return store.Issue{}, ie
		}
	}
	if p.Labels != nil {
		if ie := s.ensureEpicLabel(ctx, tenant, actor, *p.Labels); ie != nil {
			return store.Issue{}, ie
		}
	}
	out, err := is.UpdateIssue(ctx, tenant, number, p, actor, s.o.Now())
	if ie := storeIssueErr(err); ie != nil {
		if ie.status == http.StatusInternalServerError {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Int("number", number).Msg("issue update")
		}
		return store.Issue{}, ie
	}
	s.fanoutIssue(ctx, tenant, map[string]any{"type": issueFrame, "op": "update", "issue": toIssueJSON(out, s.storeGetter(ctx, tenant))})
	return out, nil
}

// checkEpicField: the `epic` field names a level-1 row (an epic or a feature);
// `parent` is the general form, which also takes a level-2 issue (a subtask).
func (s *Server) checkEpicField(ctx context.Context, tenant string, q issueRequest) *issueErr {
	if q.Epic == nil || strings.TrimSpace(*q.Epic) == "" {
		return nil
	}
	n, ok := store.ParseIssueRef(*q.Epic)
	if !ok {
		return badIssue("epic must be an issue key like SPL-17")
	}
	if e, ok := s.storeGetter(ctx, tenant)(n); ok && !e.IsEpic() {
		return &issueErr{http.StatusBadRequest, "bad_epic", "epic must name an epic or a feature; a subtask's issue goes in parent"}
	}
	return nil
}

// ensureEpicLabel puts the reserved epic label into the tenant's catalogue
// the first time an issue carries it (rdb 0049 seeded every tenant that had
// issues; a new tenant gets it here).
func (s *Server) ensureEpicLabel(ctx context.Context, tenant, actor string, labels []string) *issueErr {
	if !contains(labels, store.IssueEpicLabel) {
		return nil
	}
	// createIssueLabel fans the new label out, so open tabs learn it too.
	if _, ie := s.createIssueLabel(ctx, tenant, actor, store.IssueEpicLabel, "#8b5cf6"); ie != nil && ie.token != "label_exists" {
		return ie
	}
	return nil
}

// fanoutIssue sends a frame to every browser socket of the tenant: an issue
// is as readable as the tenant (topics.read, which every open socket held).
func (s *Server) fanoutIssue(ctx context.Context, tenant string, frame map[string]any) {
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	for _, c := range targets {
		c.write(ctx, frame) //nolint:errcheck
	}
}

// ---- filters and sort (issues-v1 §4) --------------------------------------------

// issueFilter is the list query. Empty sets match everything.
type issueFilter struct {
	status, assignee, label map[string]bool
	priority, level         map[int]bool
	before, after           *time.Time
	sort                    string
	epic                    map[int]bool    // SPL-18: rows under these level-1 rows
	parent                  map[int]bool    // rows whose direct parent is one of these
	kind                    map[string]bool // epic | feature | issue | subtask
}

func csvSet(v string) map[string]bool {
	out := map[string]bool{}
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out[p] = true
		}
	}
	return out
}

func intSet(v string, max int) (map[int]bool, bool) {
	out := map[int]bool{}
	for p := range csvSet(v) {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 || n > max {
			return nil, false
		}
		out[n] = true
	}
	return out, true
}

// parseIssueFilter reads ?status=&priority=&level=&assignee=&label=
// &deadline_before=&deadline_after=&sort=. assignee "me" is the caller,
// "none" is unassigned.
func parseIssueFilter(v map[string][]string, me string) (issueFilter, *issueErr) {
	get := func(k string) string {
		if len(v[k]) == 0 {
			return ""
		}
		return v[k][0]
	}
	f := issueFilter{status: csvSet(get("status")), label: csvSet(get("label")), assignee: map[string]bool{}}
	for st := range f.status { // a first-set name (in_progress, ...) still filters
		if n := store.NormalizeIssueStatus(st); n != st {
			delete(f.status, st)
			f.status[n] = true
		}
	}
	for s := range f.status {
		if !store.ValidIssueStatus(s) {
			return f, badIssue("status must be one of " + strings.Join(store.IssueStatuses, ", "))
		}
	}
	for a := range csvSet(get("assignee")) {
		switch a {
		case "me":
			f.assignee[me] = true
		case "none":
			f.assignee[""] = true
		default:
			f.assignee[a] = true
		}
	}
	var ok bool
	if f.priority, ok = intSet(get("priority"), store.IssuePriorityMax); !ok || f.priority[0] {
		return f, badIssue(fmt.Sprintf("prio must be %d..%d", store.IssuePriorityMin, store.IssuePriorityMax))
	}
	if f.level, ok = intSet(get("level"), store.IssueLevelMax); !ok || f.level[0] {
		return f, badIssue(fmt.Sprintf("level must be %d..%d", store.IssueLevelMin, store.IssueLevelMax))
	}
	for k, dst := range map[string]**time.Time{"deadline_before": &f.before, "deadline_after": &f.after} {
		if s := get(k); s != "" {
			t, err := time.Parse(time.RFC3339, s)
			if err != nil {
				return f, badIssue(k + " must be RFC 3339")
			}
			*dst = &t
		}
	}
	for name, dst := range map[string]*map[int]bool{"epic": &f.epic, "parent": &f.parent} {
		*dst = map[int]bool{}
		for e := range csvSet(get(name)) {
			n, ok := store.ParseIssueRef(e)
			if !ok {
				return f, badIssue(name + " must be issue keys like SPL-17")
			}
			(*dst)[n] = true
		}
	}
	f.kind = csvSet(get("kind"))
	for k := range f.kind {
		switch k {
		case store.IssueKindEpic, store.IssueKindFeature, store.IssueKindIssue, "subtask":
		default:
			return f, badIssue("kind must be epic, feature, issue or subtask")
		}
	}
	switch f.sort = get("sort"); f.sort {
	case "", "priority", "level", "deadline", "updated", "created", "number":
	default:
		return f, badIssue("sort must be priority, level, deadline, updated, created or number")
	}
	return f, nil
}

func (f issueFilter) match(i store.Issue, get issueGetter) bool {
	kind, epic := treeKind(i, get)
	if len(f.kind) > 0 && !f.kind[kind] {
		return false
	}
	if len(f.epic) > 0 {
		n, ok := store.ParseIssueRef(epic)
		if !ok || !f.epic[n] {
			return false
		}
	}
	if len(f.parent) > 0 && !f.parent[i.Parent] {
		return false
	}
	if len(f.status) > 0 && !f.status[i.Status] {
		return false
	}
	if len(f.priority) > 0 && !f.priority[i.Priority] {
		return false
	}
	if len(f.level) > 0 && !f.level[i.Level] {
		return false
	}
	if len(f.assignee) > 0 && !f.assignee[i.Assignee] {
		return false
	}
	if len(f.label) > 0 {
		hit := false
		for _, l := range i.Labels {
			hit = hit || f.label[l]
		}
		if !hit {
			return false
		}
	}
	if f.before != nil && (i.Deadline == nil || !i.Deadline.Before(*f.before)) {
		return false
	}
	if f.after != nil && (i.Deadline == nil || i.Deadline.Before(*f.after)) {
		return false
	}
	return true
}

// SortIssues orders like Linear: priority urgent first and "no priority"
// last; level top of the tree first (1 epic / feature, 2 issue, 3 subtask); deadline soonest first and none last;
// updated / created newest first. Ties: the newest number first.
func SortIssues(list []store.Issue, by string) {
	prio := func(p int) int {
		if p == 0 {
			return store.IssuePriorityMax + 1
		}
		return p
	}
	sort.SliceStable(list, func(a, b int) bool {
		x, y := list[a], list[b]
		switch by {
		case "", "priority":
			if prio(x.Priority) != prio(y.Priority) {
				return prio(x.Priority) < prio(y.Priority)
			}
		case "level":
			if x.Level != y.Level {
				return x.Level < y.Level
			}
		case "deadline":
			switch {
			case x.Deadline == nil && y.Deadline != nil:
				return false
			case x.Deadline != nil && y.Deadline == nil:
				return true
			case x.Deadline != nil && !x.Deadline.Equal(*y.Deadline):
				return x.Deadline.Before(*y.Deadline)
			}
		case "updated":
			if !x.UpdatedAt.Equal(y.UpdatedAt) {
				return x.UpdatedAt.After(y.UpdatedAt)
			}
		case "created":
			if !x.CreatedAt.Equal(y.CreatedAt) {
				return x.CreatedAt.After(y.CreatedAt)
			}
		}
		return x.Number > y.Number
	})
}

// listIssues is the one list path (browser and agent).
func (s *Server) listIssues(ctx context.Context, tenant string, f issueFilter) (map[string]any, *issueErr) {
	is, ie := s.issueStore()
	if ie != nil {
		return nil, ie
	}
	all, err := is.ListIssues(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue list")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "issues unavailable"}
	}
	labels, err := is.ListIssueLabels(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue labels")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "issues unavailable"}
	}
	prefix, err := is.IssuePrefix(ctx, tenant)
	if err != nil {
		return nil, &issueErr{http.StatusInternalServerError, "internal", "issues unavailable"}
	}
	kept := make([]store.Issue, 0, len(all))
	counts := map[string]int{}
	for _, st := range store.IssueStatuses {
		counts[st] = 0
	}
	get := getterOf(all)
	for _, i := range all {
		if f.match(i, get) {
			kept = append(kept, i)
			counts[i.Status]++
		}
	}
	SortIssues(kept, f.sort)
	out := make([]issueJSON, len(kept))
	for k, i := range kept {
		out[k] = toIssueJSON(i, get)
	}
	lj := make([]issueLabelJSON, len(labels))
	for k, l := range labels {
		lj[k] = toLabelJSON(l)
	}
	return map[string]any{"prefix": prefix, "statuses": store.IssueStatuses, "counts": counts, "epics": epicSummaries(all),
		"issues": out, "labels": lj, "channel": IssueChannel}, nil
}

func writeIssueErr(w http.ResponseWriter, ie *issueErr) {
	writeErr(w, ie.status, ie.token, ie.detail)
}

// epicSummary is one row of the Issues tab's left-most panel (SPL-18): an
// epic and its issues, the way Linear shows a project's progress. It is over
// every issue of the tenant, never the filtered list.
type epicSummary struct {
	Key      string         `json:"key"`
	Kind     string         `json:"kind"` // epic | feature
	Number   int            `json:"number"`
	Title    string         `json:"title"`
	Status   string         `json:"status"`
	Total    int            `json:"total"`
	Done     int            `json:"done"`
	Canceled int            `json:"canceled"`
	Counts   map[string]int `json:"counts"`
}

// epicSummaries lists the epics, open ones first then by number, with the
// count of their issues per status.
func epicSummaries(all []store.Issue) []epicSummary {
	by := map[int]*epicSummary{}
	out := []*epicSummary{}
	for _, i := range all {
		if !i.IsEpic() {
			continue
		}
		e := &epicSummary{Key: i.Key(), Kind: i.Kind, Number: i.Number, Title: i.Title, Status: i.Status, Counts: map[string]int{}}
		for _, st := range store.IssueStatuses {
			e.Counts[st] = 0
		}
		by[i.Number] = e
		out = append(out, e)
	}
	for _, i := range all {
		e := by[i.Parent]
		if i.IsEpic() || e == nil {
			continue
		}
		e.Total++
		e.Counts[i.Status]++
		switch i.Status {
		case store.IssueDone:
			e.Done++
		case store.IssueCanceled:
			e.Canceled++
		}
	}
	closed := func(st string) bool { return st == store.IssueDone || st == store.IssueCanceled }
	sort.SliceStable(out, func(a, b int) bool {
		if ca, cb := closed(out[a].Status), closed(out[b].Status); ca != cb {
			return !ca
		}
		return out[a].Number < out[b].Number
	})
	res := make([]epicSummary, len(out))
	for k, e := range out {
		res[k] = *e
	}
	return res
}

// ---- browser routes --------------------------------------------------------------

func (s *Server) routeIssues(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/issues", s.viewHandler(s.handleViewIssues))
	mux.HandleFunc("GET /v1/view/issues/{ref}", s.viewHandler(s.handleViewIssue))
	mux.HandleFunc("POST /v1/issues", s.handleCreateIssue)
	mux.HandleFunc("PATCH /v1/issues/{ref}", s.handlePatchIssue)
	mux.HandleFunc("DELETE /v1/issues/{ref}", s.handleDeleteIssue)
	mux.HandleFunc("POST /v1/issue-labels", s.handleCreateIssueLabel)
	mux.HandleFunc("OPTIONS /v1/issues", s.issuesPreflight)
	mux.HandleFunc("OPTIONS /v1/issues/{ref}", s.issuesPreflight)
	mux.HandleFunc("OPTIONS /v1/issue-labels", s.issuesPreflight)
}

func (s *Server) handleViewIssues(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	hum, _ := s.memberID(r, t.ID)
	f, ie := parseIssueFilter(r.URL.Query(), hum)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	out, ie := s.listIssues(r.Context(), t.ID, f)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleViewIssue(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	is, ie := s.issueStore()
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	n, ok := store.ParseIssueRef(r.PathValue("ref"))
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "no such issue")
		return
	}
	i, err := is.GetIssue(r.Context(), t.ID, n)
	if ie := storeIssueErr(err); ie != nil {
		writeIssueErr(w, ie)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"issue": toIssueJSON(i, s.storeGetter(r.Context(), t.ID))})
}

// issueWriter resolves a browser write: tenant, actor, notes.send, billing.
func (s *Server) issueWriter(w http.ResponseWriter, r *http.Request) (store.Tenant, string, bool) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return t, "", false
	}
	if !s.permit(w, r, t.ID, hum, rbac.NotesSend) { // specs/025, per request
		return t, "", false
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return t, "", false
	}
	actor := hum
	if actor == "" {
		actor = "wui" // the door-off rig
	}
	return t, actor, true
}

func (s *Server) handleCreateIssue(w http.ResponseWriter, r *http.Request) {
	t, actor, ok := s.issueWriter(w, r)
	if !ok {
		return
	}
	q, ok := decodeIssueRequest(w, r)
	if !ok {
		return
	}
	i, ie := s.createIssue(r.Context(), t.ID, actor, q)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"issue": toIssueJSON(i, s.storeGetter(r.Context(), t.ID))})
}

func (s *Server) handlePatchIssue(w http.ResponseWriter, r *http.Request) {
	t, actor, ok := s.issueWriter(w, r)
	if !ok {
		return
	}
	n, ok := store.ParseIssueRef(r.PathValue("ref"))
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "no such issue")
		return
	}
	q, ok := decodeIssueRequest(w, r)
	if !ok {
		return
	}
	i, ie := s.updateIssue(r.Context(), t.ID, actor, n, q)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"issue": toIssueJSON(i, s.storeGetter(r.Context(), t.ID))})
}

// mayDeleteIssue (SPL-1027, spec 039 FR-009): the member who created the
// issue, or a role that holds tenant.settings (admin, owner). An issue an
// agent or the hub created is deleted by such a role. The door-off rig (hum
// "") is allowed, as every write there.
func (s *Server) mayDeleteIssue(ctx context.Context, tenant, hum string, i store.Issue) bool {
	if hum == "" || i.CreatedBy == hum {
		return true
	}
	return s.allowed(ctx, hum, tenant, rbac.TenantSettings)
}

// handleDeleteIssue is the soft delete of rdb 0071: 200 {issue} as it was,
// then an `issue` frame with op delete to every tab of the tenant.
func (s *Server) handleDeleteIssue(w http.ResponseWriter, r *http.Request) {
	t, actor, ok := s.issueWriter(w, r)
	if !ok {
		return
	}
	is, ie := s.issueStore()
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	n, ok := store.ParseIssueRef(r.PathValue("ref"))
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "no such issue")
		return
	}
	cur, err := is.GetIssue(r.Context(), t.ID, n)
	if ie := storeIssueErr(err); ie != nil {
		writeIssueErr(w, ie)
		return
	}
	hum := actor
	if hum == "wui" { // issueWriter's door-off rig actor
		hum = ""
	}
	if !s.mayDeleteIssue(r.Context(), t.ID, hum, cur) {
		writeForbidden(w, rbac.TenantSettings, "only the member who created "+cur.Key()+" or an admin may delete it")
		return
	}
	out, err := is.DeleteIssue(r.Context(), t.ID, n, actor, s.o.Now())
	if ie := storeIssueErr(err); ie != nil {
		if ie.status == http.StatusInternalServerError {
			s.o.Log.Error().Err(err).Str("tenant", t.ID).Int("number", n).Msg("issue delete")
		}
		writeIssueErr(w, ie)
		return
	}
	body := toIssueJSON(out, s.storeGetter(r.Context(), t.ID))
	s.fanoutIssue(r.Context(), t.ID, map[string]any{"type": issueFrame, "op": "delete", "issue": body})
	writeJSON(w, http.StatusOK, map[string]any{"issue": body})
}

// createIssueLabel is the one label path (browser and agent).
func (s *Server) createIssueLabel(ctx context.Context, tenant, actor, name, color string) (store.IssueLabel, *issueErr) {
	is, ie := s.issueStore()
	if ie != nil {
		return store.IssueLabel{}, ie
	}
	l, err := is.CreateIssueLabel(ctx, store.IssueLabel{TenantID: tenant, Name: name, Color: color, CreatedBy: actor}, s.o.Now())
	if errors.Is(err, store.ErrConflict) {
		return l, &issueErr{http.StatusConflict, "label_exists", "a label with that name exists"}
	}
	if ie := storeIssueErr(err); ie != nil {
		return l, ie
	}
	s.fanoutIssue(ctx, tenant, map[string]any{"type": issueLabelFrame, "label": toLabelJSON(l)})
	return l, nil
}

func (s *Server) handleCreateIssueLabel(w http.ResponseWriter, r *http.Request) {
	t, actor, ok := s.issueWriter(w, r)
	if !ok {
		return
	}
	var body struct {
		Name  string `json:"name"`
		Color string `json:"color"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {name, color?}")
		return
	}
	l, ie := s.createIssueLabel(r.Context(), t.ID, actor, body.Name, body.Color)
	if ie != nil {
		writeIssueErr(w, ie)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"label": toLabelJSON(l)})
}

// issuesPreflight is CORS for POST /v1/issues, PATCH and DELETE
// /v1/issues/{ref} and POST /v1/issue-labels. No new request header.
func (s *Server) issuesPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST, PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}
