package hub

import (
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Workspace and System logs of the event log (spec 162 v1.0 sections
// 3.1-3.2, row B3, SPL-4167; rdb 0240). The personal log (Mine) stays
// events.go.
//
//	GET  /v1/view/events?limit=&before=      the session workspace's log
//	POST /v1/view/events/delete {"ids":[..]}
//	GET  /v1/operator/events?limit=&before=  the hub-wide log
//	POST /v1/operator/events/delete {"ids":[..]}
//	POST /v1/operator/events/link {"fingerprint":"<16 hex>","issue_key":"SPL-n"}
//
// Who may: the Workspace log, a member session whose role set makes it the
// workspace's owner or an admin (TenantOwner || Has(rbac.Admin), the spec
// 153 B6 rule), else 403 workspace.events; the System log, an admin of the
// operator workspace (operatorActor), else 403 operator.workspaces. A page
// is newest first, `next_before` the id to ask below when an older page
// exists (0 = none). A delete names 1..200 ids, removes only the log's own
// rows (another workspace's id counts 0, never 403) and leaves one
// log.deleted row by the caller. No delete-all: Clear stays the personal
// log's verb (3.2).
//
// Backend error groups (spec 162 10.5-10.7, row T4, SPL-6231): a System row
// that is an error group carries its group fields (fingerprint, first_at,
// n, issue_key, issue_n, human_id); a row that is no group carries none of
// them. GET /v1/operator/events?kind=<prefix> lists only the rows whose kind
// starts with prefix (kind=error. = every error group), next_before paging
// within that filter. The link sets a group's issue_key and issue_n = n,
// same caller rule as the delete; an unknown fingerprint is 404 not_found.

const permWorkspaceEvents = "workspace.events"

// systemScanBatch is how many System rows one store read takes while a
// ?kind= filter fills a page; the log keeps store.SystemEventsKeep rows, so
// a full scan is at most SystemEventsKeep/systemScanBatch reads.
const systemScanBatch = 500

var (
	// logKindPrefixRe is a ?kind= value: the start of a dotted kind name.
	logKindPrefixRe = regexp.MustCompile(`^[a-z][a-z._]{0,47}$`)
	// evlogFPRe and evlogIssueKeyRe are the link body's rules (10.7).
	evlogFPRe       = regexp.MustCompile(`^[0-9a-f]{16}$`)
	evlogIssueKeyRe = regexp.MustCompile(`^SPL-[1-9][0-9]{0,9}$`)
)

type logEventJSON struct {
	ID         int64     `json:"id"`
	At         time.Time `json:"at"`
	Kind       string    `json:"kind"`
	Level      string    `json:"level"`
	Actor      string    `json:"actor"`
	Message    string    `json:"message"`
	OriginKind string    `json:"origin_kind"`
	OriginRef  string    `json:"origin_ref"`
	*logGroupJSON
}

// logGroupJSON is an error group's fields (spec 162 10.5); nil on a row that
// is no group, so such a row carries none of them.
type logGroupJSON struct {
	Fingerprint string    `json:"fingerprint"`
	FirstAt     time.Time `json:"first_at"`
	N           int       `json:"n"`
	IssueKey    string    `json:"issue_key"`
	IssueN      int       `json:"issue_n"`
	HumanID     string    `json:"human_id"`
}

// logEventOut is e as JSON, with its group fields when it is a group.
func logEventOut(e store.LogEvent) logEventJSON {
	o := logEventJSON{ID: e.ID, At: e.At.UTC(), Kind: e.Kind, Level: e.Level, Actor: e.Actor,
		Message: e.Message, OriginKind: e.OriginKind, OriginRef: e.OriginRef}
	if e.Fingerprint != "" {
		o.logGroupJSON = &logGroupJSON{Fingerprint: e.Fingerprint, FirstAt: e.FirstAt.UTC(), N: e.N,
			IssueKey: e.IssueKey, IssueN: e.IssueN, HumanID: e.HumanID}
	}
	return o
}

type logEventsPageJSON struct {
	Events     []logEventJSON `json:"events"`
	NextBefore int64          `json:"next_before"`
}

func (s *Server) routeLogEvents(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/events", s.viewHandler(s.handleWorkspaceEvents))
	mux.HandleFunc("POST /v1/view/events/delete", s.viewHandler(s.handleWorkspaceEventsDelete))
	mux.HandleFunc("GET /v1/operator/events", s.handleSystemEvents)
	mux.HandleFunc("POST /v1/operator/events/delete", s.handleSystemEventsDelete)
	mux.HandleFunc("POST /v1/operator/events/link", s.handleSystemEventsLink)
}

// logEventsStore is the store's two logs; false = 503 answered.
func (s *Server) logEventsStore(w http.ResponseWriter) (store.LogEvents, bool) {
	es, ok := s.o.Store.(store.LogEvents)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "this hub keeps no workspace or system log")
	}
	return es, ok
}

// workspaceEventsCaller is the session's HUM-* when it is the owner or an
// admin of t, and the store; false = answered.
func (s *Server) workspaceEventsCaller(w http.ResponseWriter, r *http.Request, t store.Tenant) (string, store.LogEvents, bool) {
	w.Header().Set("Cache-Control", "no-store")
	hum, _ := s.memberID(r, t.ID)
	if hum == "" {
		writeForbidden(w, permWorkspaceEvents, "the workspace log needs a member session")
		return "", nil, false
	}
	if a, err := s.access(r.Context(), hum, t.ID); err != nil || !(a.TenantOwner || a.Has(rbac.Admin)) {
		writeForbidden(w, permWorkspaceEvents, "only the workspace owner or an admin reads its log")
		return "", nil, false
	}
	es, ok := s.logEventsStore(w)
	return hum, es, ok
}

// logEventsQuery reads ?limit (default 50, at most 200) and ?before (a
// positive id); false = 400 answered. The same rules as GET /api/v1/auth/events.
func logEventsQuery(w http.ResponseWriter, r *http.Request) (limit int, before int64, ok bool) {
	q := r.URL.Query()
	limit = eventsPageDefault
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			writeErr(w, http.StatusBadRequest, "bad_request", "limit must be a positive integer")
			return 0, 0, false
		}
		limit = min(n, eventsPageMax)
	}
	if v := q.Get("before"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 1 {
			writeErr(w, http.StatusBadRequest, "bad_request", "before must be a positive event id")
			return 0, 0, false
		}
		before = n
	}
	return limit, before, true
}

// writeLogEventsPage answers list, read with one row past limit, as a page.
func writeLogEventsPage(w http.ResponseWriter, list []store.LogEvent, limit int) {
	out := logEventsPageJSON{Events: []logEventJSON{}}
	if len(list) > limit {
		list = list[:limit]
		out.NextBefore = list[limit-1].ID
	}
	for _, e := range list {
		out.Events = append(out.Events, logEventOut(e))
	}
	writeJSON(w, http.StatusOK, out)
}

// logEventIDs reads the delete body {"ids":[..]}, 1..200 positive ids;
// false = 4xx answered.
func logEventIDs(w http.ResponseWriter, r *http.Request) ([]int64, bool) {
	var req struct {
		IDs []int64 `json:"ids"`
	}
	if !readJSONStrict(w, r, &req, keysMaxBody, `invalid JSON body (expected {"ids":[<event id>, ...]})`) {
		return nil, false
	}
	if len(req.IDs) == 0 || len(req.IDs) > store.LogEventsDeleteMax {
		writeErr(w, http.StatusBadRequest, "bad_request", "ids must name 1.."+strconv.Itoa(store.LogEventsDeleteMax)+" event ids")
		return nil, false
	}
	for _, id := range req.IDs {
		if id < 1 {
			writeErr(w, http.StatusBadRequest, "bad_request", "every id must be a positive event id")
			return nil, false
		}
	}
	return req.IDs, true
}

// GET /v1/view/events
func (s *Server) handleWorkspaceEvents(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	_, es, ok := s.workspaceEventsCaller(w, r, t)
	if !ok {
		return
	}
	limit, before, ok := logEventsQuery(w, r)
	if !ok {
		return
	}
	list, err := es.WorkspaceEventsPage(r.Context(), t.ID, before, limit+1)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("workspace events page")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "event store")
		return
	}
	writeLogEventsPage(w, list, limit)
}

// POST /v1/view/events/delete
func (s *Server) handleWorkspaceEventsDelete(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	hum, es, ok := s.workspaceEventsCaller(w, r, t)
	if !ok {
		return
	}
	ids, ok := logEventIDs(w, r)
	if !ok {
		return
	}
	n, err := es.DeleteWorkspaceEvents(r.Context(), t.ID, ids, hum, s.o.Now().UTC())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("workspace events delete")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "event store")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("by", hum).Int("rows", n).Msg("workspace_events.deleted")
	writeJSON(w, http.StatusOK, map[string]int{"deleted": n})
}

// GET /v1/operator/events
func (s *Server) handleSystemEvents(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorActor(w, r); !ok {
		return
	}
	es, ok := s.logEventsStore(w)
	if !ok {
		return
	}
	limit, before, ok := logEventsQuery(w, r)
	if !ok {
		return
	}
	prefix := r.URL.Query().Get("kind")
	if prefix != "" && !logKindPrefixRe.MatchString(prefix) {
		writeErr(w, http.StatusBadRequest, "bad_request", "kind must be the start of a dotted lowercase kind name, at most 48 characters")
		return
	}
	list, err := systemEventsOfKind(r, es, prefix, before, limit+1)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("system events page")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "event store")
		return
	}
	writeLogEventsPage(w, list, limit)
}

// POST /v1/operator/events/delete
func (s *Server) handleSystemEventsDelete(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	es, ok := s.logEventsStore(w)
	if !ok {
		return
	}
	ids, ok := logEventIDs(w, r)
	if !ok {
		return
	}
	n, err := es.DeleteSystemEvents(r.Context(), ids, a.hum, s.o.Now().UTC())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("system events delete")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "event store")
		return
	}
	s.o.Log.Info().Str("by", a.hum).Int("rows", n).Msg("system_events.deleted")
	writeJSON(w, http.StatusOK, map[string]int{"deleted": n})
}

// systemEventsOfKind reads at most want System rows below before, newest
// first, only those whose kind starts with prefix ("" = every row).
func systemEventsOfKind(r *http.Request, es store.LogEvents, prefix string, before int64, want int) ([]store.LogEvent, error) {
	if prefix == "" {
		return es.SystemEventsPage(r.Context(), before, want)
	}
	var out []store.LogEvent
	for {
		list, err := es.SystemEventsPage(r.Context(), before, systemScanBatch)
		if err != nil {
			return nil, err
		}
		for _, e := range list {
			if strings.HasPrefix(e.Kind, prefix) {
				if out = append(out, e); len(out) == want {
					return out, nil
				}
			}
		}
		if len(list) < systemScanBatch {
			return out, nil
		}
		before = list[len(list)-1].ID
	}
}

// POST /v1/operator/events/link
func (s *Server) handleSystemEventsLink(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	es, ok := s.logEventsStore(w)
	if !ok {
		return
	}
	var req struct {
		Fingerprint string `json:"fingerprint"`
		IssueKey    string `json:"issue_key"`
	}
	if !readJSONStrict(w, r, &req, keysMaxBody, `invalid JSON body (expected {"fingerprint":"<16 hex>","issue_key":"SPL-<n>"})`) {
		return
	}
	if !evlogFPRe.MatchString(req.Fingerprint) || !evlogIssueKeyRe.MatchString(req.IssueKey) {
		writeErr(w, http.StatusBadRequest, "bad_request", "fingerprint must be 16 lowercase hex and issue_key SPL-<n>")
		return
	}
	ev, err := es.LinkSystemErrorGroup(r.Context(), req.Fingerprint, req.IssueKey)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no error group has that fingerprint")
		return
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("fp", req.Fingerprint).Msg("system events link")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "event store")
		return
	}
	s.o.Log.Info().Str("by", a.hum).Str("fp", ev.Fingerprint).Str("issue", ev.IssueKey).Int("issue_n", ev.IssueN).Msg("system_events.linked")
	writeJSON(w, http.StatusOK, logEventOut(ev))
}
