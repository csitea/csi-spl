package hub

import (
	"net/http"
	"strconv"
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

const permWorkspaceEvents = "workspace.events"

type logEventJSON struct {
	ID         int64     `json:"id"`
	At         time.Time `json:"at"`
	Kind       string    `json:"kind"`
	Level      string    `json:"level"`
	Actor      string    `json:"actor"`
	Message    string    `json:"message"`
	OriginKind string    `json:"origin_kind"`
	OriginRef  string    `json:"origin_ref"`
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
		out.Events = append(out.Events, logEventJSON{ID: e.ID, At: e.At.UTC(), Kind: e.Kind, Level: e.Level, Actor: e.Actor,
			Message: e.Message, OriginKind: e.OriginKind, OriginRef: e.OriginRef})
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
	list, err := es.SystemEventsPage(r.Context(), before, limit+1)
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
