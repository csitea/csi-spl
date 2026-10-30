package hub

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The File streams tab's reads (spec 160 section 3.4, row B3). Each needs a
// member session of the workspace with TenantOwner || Has(rbac.Admin) in it
// (spec 153 3.6's gate); a member, an act-as clone, the operator service
// account (no member session) and a box (no member session either) get 403.
// A stream of another workspace is 404, never 403: the read is in the
// caller's tenant scope, so another workspace's id names no row.
//
//	GET /v1/view/file-streams                                  the workspace's streams
//	GET /v1/view/file-streams/{id}/lines?after=<seq>&limit=<n>  the lines after seq, oldest first
//	GET /v1/view/file-streams/{id}/lines?before=<seq>&limit=<n> the lines before seq (scrolling up)
//
// Without after or before: the last limit lines. limit defaults to
// fileStreamLinesDefault, at most fileStreamLinesMax.

// permFileStreams names the gate in a 403 body; it is not an rbac permission.
const permFileStreams = "file_streams.staff"

const (
	fileStreamLinesDefault = 200
	fileStreamLinesMax     = 1000
)

func (s *Server) routeFileStreams(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/view/file-streams", s.handleFileStreams)
	mux.HandleFunc("GET /v1/view/file-streams/{id}/lines", s.handleFileStreamLines)
	s.routeFileStreamGlobs(mux) // spec 160 3.8.3, row B9: the web globs, file_stream_globs.go
}

// fileStreamsCaller is the caller's workspace and human id when it is a
// member session of an owner or admin who is not an act-as clone; false
// after the answer. The one gate of the read routes and of the web globs.
func (s *Server) fileStreamsCaller(w http.ResponseWriter, r *http.Request) (string, string, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return "", "", false
	}
	if why := s.fileStreamsStaffRefusal(r.Context(), t.ID, hum); why != "" {
		writeForbidden(w, permFileStreams, why)
		return "", "", false
	}
	return t.ID, hum, true
}

// fileStreamsStaff is fileStreamsCaller plus the file stream store.
func (s *Server) fileStreamsStaff(w http.ResponseWriter, r *http.Request) (store.FileStreamStore, string, bool) {
	tenant, _, ok := s.fileStreamsCaller(w, r)
	if !ok {
		return nil, "", false
	}
	fs, ok := s.o.Store.(store.FileStreamStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no file streams")
		return nil, "", false
	}
	return fs, tenant, true
}

// fileStreamsStaffRefusal is why hum may not read tenant's file streams, ""
// when it may: the one gate of the read routes and of the search section
// (spec 160 3.4 and 3.6).
func (s *Server) fileStreamsStaffRefusal(ctx context.Context, tenant, hum string) string {
	if hum == "" {
		return "file streams need a member session"
	}
	if s.readerIsActAsClone(ctx, tenant, hum) {
		return "an act-as session does not read file streams"
	}
	if a, err := s.access(ctx, hum, tenant); err != nil || !(a.TenantOwner || a.Has(rbac.Admin)) {
		return "only the workspace owner or an admin reads file streams"
	}
	return ""
}

// fileStreamBody is one stream as the tab lists it.
type fileStreamBody struct {
	ID           string  `json:"id"`
	BoxID        string  `json:"box_id"`
	StreamKey    string  `json:"stream_key"`
	Path         string  `json:"path"`
	State        string  `json:"state"`
	Reason       string  `json:"reason"`
	LastLineAt   *string `json:"last_line_at"`
	LastSeq      int64   `json:"last_seq"`
	LinesTotal   int64   `json:"lines_total"`
	LinesDropped int64   `json:"lines_dropped"`
	LinesKept    int64   `json:"lines_kept"`
}

func (s *Server) handleFileStreams(w http.ResponseWriter, r *http.Request) {
	fs, tenant, ok := s.fileStreamsStaff(w, r)
	if !ok {
		return
	}
	all, err := fs.ListFileStreams(r.Context(), tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("file streams list")
		writeErr(w, http.StatusInternalServerError, "internal", "file streams unavailable")
		return
	}
	out := make([]fileStreamBody, len(all))
	for i, f := range all {
		out[i] = fileStreamBody{ID: f.ID, BoxID: f.Box, StreamKey: f.StreamKey, Path: f.Path, State: f.State, Reason: f.Reason,
			LastSeq: f.LastSeq, LinesTotal: f.LinesTotal, LinesDropped: f.LinesDropped, LinesKept: f.LinesKept}
		if f.LastLineAt != nil {
			at := f.LastLineAt.UTC().Format(time.RFC3339Nano)
			out[i].LastLineAt = &at
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"streams": out})
}

// fileStreamLineBody is one line as the tab shows it.
type fileStreamLineBody struct {
	Seq    int64  `json:"seq"`
	At     string `json:"at"`
	Text   string `json:"text"`
	Marker bool   `json:"marker"`
}

// fileStreamLinesQuery reads after, before and limit; false after a 400.
func fileStreamLinesQuery(w http.ResponseWriter, r *http.Request) (store.FileStreamLinesQuery, bool) {
	q := r.URL.Query()
	out := store.FileStreamLinesQuery{Limit: fileStreamLinesDefault}
	num := func(k string, min int64) (int64, bool) {
		v := q.Get(k)
		if v == "" {
			return 0, true
		}
		n, err := strconv.ParseInt(v, 10, 64)
		return n, err == nil && n >= min
	}
	after, ok1 := num("after", 0)
	before, ok2 := num("before", 1)
	limit, ok3 := num("limit", 1)
	switch {
	case !ok1 || !ok2 || !ok3:
		writeErr(w, http.StatusBadRequest, "bad_query", "after is a seq >= 0, before a seq >= 1, limit 1..1000")
		return out, false
	case q.Get("after") != "" && q.Get("before") != "":
		writeErr(w, http.StatusBadRequest, "bad_query", "after and before do not go together")
		return out, false
	}
	if q.Get("after") != "" {
		out.After = &after
	}
	if q.Get("before") != "" {
		out.Before = &before
	}
	if limit > 0 {
		out.Limit = int(min(limit, fileStreamLinesMax))
	}
	return out, true
}

func (s *Server) handleFileStreamLines(w http.ResponseWriter, r *http.Request) {
	fs, tenant, ok := s.fileStreamsStaff(w, r)
	if !ok {
		return
	}
	q, ok := fileStreamLinesQuery(w, r)
	if !ok {
		return
	}
	ls, err := fs.FileStreamLines(r.Context(), tenant, r.PathValue("id"), q)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such file stream")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("file stream lines")
		writeErr(w, http.StatusInternalServerError, "internal", "file stream lines unavailable")
		return
	}
	out := make([]fileStreamLineBody, len(ls))
	for i, l := range ls {
		out[i] = fileStreamLineBody{Seq: l.Seq, At: l.At.UTC().Format(time.RFC3339Nano), Text: l.Text, Marker: l.Marker}
	}
	writeJSON(w, http.StatusOK, map[string]any{"lines": out})
}
