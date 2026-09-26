package hub

import (
	"context"
	"encoding/json"
	"errors"
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
// The discussion of an issue is an ordinary topic on its task_id in #tasks
// (a default channel every member reads), posted at reply level so it never
// becomes a card in the #tasks feed.

const (
	issueFrame      = "issue"
	issueLabelFrame = "issue_label"
	// IssueChannel is the channel an issue's discussion is posted in.
	IssueChannel = store.ChannelTasks
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

func toIssueJSON(i store.Issue) issueJSON {
	parent := ""
	if i.Parent != 0 {
		parent = store.IssueKey(i.Prefix, i.Parent)
	}
	labels := i.Labels
	if labels == nil {
		labels = []string{}
	}
	return issueJSON{Key: i.Key(), Number: i.Number, Title: i.Title, Description: i.Description, Status: i.Status,
		Priority: i.Priority, Level: i.Level, Assignee: i.Assignee, Labels: labels, Deadline: optRFC(i.Deadline),
		Parent: parent, TaskID: i.TaskID, Channel: IssueChannel, CreatedBy: i.CreatedBy, CreatedAt: rfc(i.CreatedAt),
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
		return &issueErr{http.StatusBadRequest, "unknown_parent", "the parent is not an issue here, or would make a cycle"}
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
	out, err := is.CreateIssue(ctx, in, s.o.Now())
	if ie := storeIssueErr(err); ie != nil {
		if ie.status == http.StatusInternalServerError {
			s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue create")
		}
		return store.Issue{}, ie
	}
	s.fanoutIssue(ctx, tenant, map[string]any{"type": issueFrame, "op": "create", "issue": toIssueJSON(out)})
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
	if p.Assignee != nil {
		if ie := s.checkAssignee(ctx, tenant, *p.Assignee); ie != nil {
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
	s.fanoutIssue(ctx, tenant, map[string]any{"type": issueFrame, "op": "update", "issue": toIssueJSON(out)})
	return out, nil
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
	if f.priority, ok = intSet(get("priority"), store.IssuePriorityMax); !ok {
		return f, badIssue("priority must be 0..4")
	}
	if f.level, ok = intSet(get("level"), store.IssueLevelMax); !ok {
		return f, badIssue("level must be 0..5")
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
	switch f.sort = get("sort"); f.sort {
	case "", "priority", "level", "deadline", "updated", "created", "number":
	default:
		return f, badIssue("sort must be priority, level, deadline, updated, created or number")
	}
	return f, nil
}

func (f issueFilter) match(i store.Issue) bool {
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
// last; level largest first; deadline soonest first and none last;
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
				return x.Level > y.Level
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
	for _, i := range all {
		if f.match(i) {
			kept = append(kept, i)
			counts[i.Status]++
		}
	}
	SortIssues(kept, f.sort)
	out := make([]issueJSON, len(kept))
	for k, i := range kept {
		out[k] = toIssueJSON(i)
	}
	lj := make([]issueLabelJSON, len(labels))
	for k, l := range labels {
		lj[k] = toLabelJSON(l)
	}
	return map[string]any{"prefix": prefix, "statuses": store.IssueStatuses, "counts": counts,
		"issues": out, "labels": lj, "channel": IssueChannel}, nil
}

func writeIssueErr(w http.ResponseWriter, ie *issueErr) {
	writeErr(w, ie.status, ie.token, ie.detail)
}

// ---- browser routes --------------------------------------------------------------

func (s *Server) routeIssues(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/issues", s.viewHandler(s.handleViewIssues))
	mux.HandleFunc("GET /v1/view/issues/{ref}", s.viewHandler(s.handleViewIssue))
	mux.HandleFunc("POST /v1/issues", s.handleCreateIssue)
	mux.HandleFunc("PATCH /v1/issues/{ref}", s.handlePatchIssue)
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
	writeJSON(w, http.StatusOK, map[string]any{"issue": toIssueJSON(i)})
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
	writeJSON(w, http.StatusCreated, map[string]any{"issue": toIssueJSON(i)})
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
	writeJSON(w, http.StatusOK, map[string]any{"issue": toIssueJSON(i)})
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

// issuesPreflight is CORS for POST /v1/issues, PATCH /v1/issues/{ref} and
// POST /v1/issue-labels. No new request header.
func (s *Server) issuesPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST, PATCH")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}
