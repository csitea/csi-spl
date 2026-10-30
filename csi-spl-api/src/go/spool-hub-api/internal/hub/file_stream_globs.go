package hub

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// File globs typed in the web page (spec 160 section 3.8, row B9, rdb 0242;
// owner HUM-10, t1 c168784c, poll 376e9435 answer B). The gate is the read
// routes' one (fileStreamsStaffRefusal): a member session of the workspace,
// not an act-as clone, owner or admin; else 403.
//
//	POST   /v1/file-streams/globs {box_id, key, glob}        -> 201 the glob
//	GET    /v1/view/file-streams/globs                       -> the live globs, the boxes' folders
//	DELETE /v1/file-streams/globs/{id}                       -> 204
//	GET    /v1/view/file-streams/globs/audit?before=&limit=  -> the audit rows, newest first
//
// The hub never opens, lists or resolves a pattern (3.8.1): it checks the
// syntax, stores it, audits it and hands it to the box on the box's pull
// (lane op file_streams_globs). A box another workspace's, or one that never
// announced here, and another workspace's glob id answer 404, never 403.
// Every refusal of an add after the gate is one audit row (3.8.9).

const (
	fileStreamGlobBodyMax   = 4 << 10
	fileStreamGlobAuditMax  = 500
	fileStreamGlobAuditPage = 50
)

func (s *Server) routeFileStreamGlobs(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/file-streams/globs", s.handleFileStreamGlobAdd)
	mux.HandleFunc("GET /v1/view/file-streams/globs", s.handleFileStreamGlobs)
	mux.HandleFunc("DELETE /v1/file-streams/globs/{id}", s.handleFileStreamGlobRemove)
	mux.HandleFunc("GET /v1/view/file-streams/globs/audit", s.handleFileStreamGlobAudit)
}

// fileStreamGlobsStaff is fileStreamsCaller plus the glob store; false after
// the answer.
func (s *Server) fileStreamGlobsStaff(w http.ResponseWriter, r *http.Request) (store.FileStreamGlobStore, string, string, bool) {
	tenant, hum, ok := s.fileStreamsCaller(w, r)
	if !ok {
		return nil, "", "", false
	}
	gs, ok := s.o.Store.(store.FileStreamGlobStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no file globs")
		return nil, "", "", false
	}
	return gs, tenant, hum, true
}

// fileStreamGlobBody is one glob as the page lists it: state .. reported_at
// are the box's last report (state pending until the first).
type fileStreamGlobBody struct {
	ID         string  `json:"id"`
	BoxID      string  `json:"box_id"`
	Key        string  `json:"key"`
	Glob       string  `json:"glob"`
	CreatedBy  string  `json:"created_by"`
	CreatedAt  string  `json:"created_at"`
	State      string  `json:"state"`
	Reason     string  `json:"reason"`
	Matched    int     `json:"matched"`
	Followed   int     `json:"followed"`
	OverCap    int     `json:"over_cap"`
	ReportedAt *string `json:"reported_at"`
}

func fileStreamGlobJSON(g store.FileStreamGlob) fileStreamGlobBody {
	out := fileStreamGlobBody{ID: g.ID, BoxID: g.Box, Key: g.Key, Glob: g.Glob, CreatedBy: g.CreatedBy,
		CreatedAt: g.CreatedAt.UTC().Format(time.RFC3339Nano), State: g.State, Reason: g.Reason,
		Matched: g.Matched, Followed: g.Followed, OverCap: g.OverCap}
	if g.ReportedAt != nil {
		at := g.ReportedAt.UTC().Format(time.RFC3339Nano)
		out.ReportedAt = &at
	}
	return out
}

// fileStreamGlobRefusal is one refused add: the status, the code (the audit
// row's reason) and the detail.
type fileStreamGlobRefusal struct {
	status       int
	code, detail string
}

// fileStreamGlobCheck is why the add may not be stored, nil when it may:
// the box lock (spec 025: only a lock owner), the syntax, the key and the
// box's announced folders (advisory, 3.8.1). The cap and a taken key are the
// store's, under its lock.
func (s *Server) fileStreamGlobCheck(ctx context.Context, tenant, hum, box, key, glob string, folders []store.FileStreamFolder) (*fileStreamGlobRefusal, error) {
	l, err := s.boxLock(ctx, tenant, box)
	switch {
	case err != nil:
		return nil, err
	case l != nil && !l.IsOwner(hum):
		return &fileStreamGlobRefusal{http.StatusForbidden, "box_locked", "the box is locked: only its lock owners add a file glob to it"}, nil
	}
	if err := wire.CheckFileStreamGlob(glob); err != nil {
		return &fileStreamGlobRefusal{http.StatusBadRequest, "bad_glob", err.Error()}, nil
	}
	if !wire.FileStreamGlobKeyRe.MatchString(key) {
		return &fileStreamGlobRefusal{http.StatusBadRequest, "bad_key", "key must match " + wire.FileStreamGlobKeyRe.String()}, nil
	}
	var allowed []string
	for _, f := range folders {
		if f.State != wire.FileStreamFolderAllowed {
			continue
		}
		if wire.FileStreamGlobUnder(glob, f.Path) {
			return nil, nil
		}
		allowed = append(allowed, f.Path)
	}
	names := "none: the box announced no allowed folder"
	if len(allowed) > 0 {
		names = strings.Join(allowed, ", ")
	}
	return &fileStreamGlobRefusal{http.StatusBadRequest, "outside_folders", "the glob's directory is under none of the box's allowed folders (" + names + ")"}, nil
}

// handleFileStreamGlobAdd is POST /v1/file-streams/globs (3.8.3).
func (s *Server) handleFileStreamGlobAdd(w http.ResponseWriter, r *http.Request) {
	gs, tenant, hum, ok := s.fileStreamGlobsStaff(w, r)
	if !ok {
		return
	}
	var req struct {
		BoxID string `json:"box_id"`
		Key   string `json:"key"`
		Glob  string `json:"glob"`
	}
	if !readJSONStrict(w, r, &req, fileStreamGlobBodyMax, `invalid JSON body (expected {"box_id", "key", "glob"})`) {
		return
	}
	ctx, now := r.Context(), s.o.Now().UTC()
	known, folders, err := false, []store.FileStreamFolder(nil), error(nil)
	if store.FleetNameRe.MatchString(req.BoxID) {
		known, folders, err = gs.FileStreamBoxFolders(ctx, tenant, req.BoxID)
	}
	if err == nil && !known {
		writeErr(w, http.StatusNotFound, "not_found", "no such box among this workspace's file streams")
		return
	}
	var why *fileStreamGlobRefusal
	if err == nil {
		why, err = s.fileStreamGlobCheck(ctx, tenant, hum, req.BoxID, req.Key, req.Glob, folders)
	}
	var g store.FileStreamGlob
	if err == nil && why == nil {
		lim := s.o.FileStreamLimits.Norm()
		g, err = gs.AddFileStreamGlob(ctx, tenant, store.FileStreamGlobAdd{Box: req.BoxID, Key: req.Key, Glob: req.Glob, Actor: hum, Max: lim.GlobsPerBox}, now)
		switch {
		case errors.Is(err, store.ErrFileStreamGlobKeyTaken):
			why, err = &fileStreamGlobRefusal{http.StatusConflict, "glob_key_taken", "a live glob of this box has that key"}, nil
		case errors.Is(err, store.ErrFileStreamGlobsFull):
			why, err = &fileStreamGlobRefusal{http.StatusConflict, "too_many_globs", "the box holds " + strconv.Itoa(lim.GlobsPerBox) + " live globs, its cap"}, nil
		case errors.Is(err, store.ErrNotFound):
			writeErr(w, http.StatusNotFound, "not_found", "no such box among this workspace's file streams")
			return
		}
	}
	if why != nil && why.code != "bad_key" {
		err = gs.AuditFileStreamGlobRefusal(ctx, tenant, store.FileStreamGlobAuditRow{Box: req.BoxID, Key: req.Key, Glob: req.Glob,
			Actor: hum, Reason: why.code, At: now})
	}
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("file stream glob add")
		writeErr(w, http.StatusInternalServerError, "internal", "file glob not stored")
	case why != nil:
		writeErr(w, why.status, why.code, why.detail)
	default:
		s.o.Log.Info().Str("tenant", tenant).Str("box", g.Box).Str("glob_id", g.ID).Str("by", hum).Msg("file_stream_glob.added")
		writeJSON(w, http.StatusCreated, fileStreamGlobJSON(g))
	}
}

// fileStreamFolderBody is one allowed folder as a box last announced it.
type fileStreamFolderBody struct {
	BoxID      string `json:"box_id"`
	Path       string `json:"path"`
	State      string `json:"state"`
	Reason     string `json:"reason"`
	ReportedAt string `json:"reported_at"`
}

// handleFileStreamGlobs is GET /v1/view/file-streams/globs.
func (s *Server) handleFileStreamGlobs(w http.ResponseWriter, r *http.Request) {
	gs, tenant, _, ok := s.fileStreamGlobsStaff(w, r)
	if !ok {
		return
	}
	globs, folders, err := gs.ListFileStreamGlobs(r.Context(), tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("file stream globs list")
		writeErr(w, http.StatusInternalServerError, "internal", "file globs unavailable")
		return
	}
	out := struct {
		Globs   []fileStreamGlobBody   `json:"globs"`
		Folders []fileStreamFolderBody `json:"folders"`
	}{make([]fileStreamGlobBody, len(globs)), make([]fileStreamFolderBody, len(folders))}
	for i, g := range globs {
		out.Globs[i] = fileStreamGlobJSON(g)
	}
	for i, f := range folders {
		out.Folders[i] = fileStreamFolderBody{BoxID: f.Box, Path: f.Path, State: f.State, Reason: f.Reason,
			ReportedAt: f.ReportedAt.UTC().Format(time.RFC3339Nano)}
	}
	writeJSON(w, http.StatusOK, out)
}

// handleFileStreamGlobRemove is DELETE /v1/file-streams/globs/{id} (3.8.8):
// any owner or admin of the workspace removes any of its globs (D7). A
// second remove is 404 and writes no audit row.
func (s *Server) handleFileStreamGlobRemove(w http.ResponseWriter, r *http.Request) {
	gs, tenant, hum, ok := s.fileStreamGlobsStaff(w, r)
	if !ok {
		return
	}
	g, err := gs.RemoveFileStreamGlob(r.Context(), tenant, r.PathValue("id"), hum, s.o.Now().UTC())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such file glob")
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("file stream glob remove")
		writeErr(w, http.StatusInternalServerError, "internal", "file glob not removed")
	default:
		s.o.Log.Info().Str("tenant", tenant).Str("box", g.Box).Str("glob_id", g.ID).Str("by", hum).Msg("file_stream_glob.removed")
		w.WriteHeader(http.StatusNoContent)
	}
}

// fileStreamGlobAuditBody is one audit row (3.8.9).
type fileStreamGlobAuditBody struct {
	ID     string `json:"id"`
	GlobID string `json:"glob_id"`
	BoxID  string `json:"box_id"`
	Action string `json:"action"`
	Key    string `json:"key"`
	Glob   string `json:"glob"`
	Actor  string `json:"actor"`
	Reason string `json:"reason"`
	At     string `json:"at"`
}

// handleFileStreamGlobAudit is GET /v1/view/file-streams/globs/audit:
// newest first, limit 1..500 (default 50), before an RFC 3339 time (the
// previous page's next_before).
func (s *Server) handleFileStreamGlobAudit(w http.ResponseWriter, r *http.Request) {
	gs, tenant, _, ok := s.fileStreamGlobsStaff(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	limit := fileStreamGlobAuditPage
	var before *time.Time
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > fileStreamGlobAuditMax {
			writeErr(w, http.StatusBadRequest, "bad_query", "limit is 1..500")
			return
		}
		limit = n
	}
	if v := q.Get("before"); v != "" {
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_query", "before is an RFC 3339 time")
			return
		}
		before = &t
	}
	rows, err := gs.FileStreamGlobAudit(r.Context(), tenant, before, limit)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("file stream glob audit")
		writeErr(w, http.StatusInternalServerError, "internal", "file glob audit unavailable")
		return
	}
	out := struct {
		Audit      []fileStreamGlobAuditBody `json:"audit"`
		NextBefore string                    `json:"next_before,omitempty"`
	}{Audit: make([]fileStreamGlobAuditBody, len(rows))}
	for i, a := range rows {
		out.Audit[i] = fileStreamGlobAuditBody{ID: a.ID, GlobID: a.GlobID, BoxID: a.Box, Action: a.Action, Key: a.Key, Glob: a.Glob,
			Actor: a.Actor, Reason: a.Reason, At: a.At.UTC().Format(time.RFC3339Nano)}
	}
	if len(rows) == limit {
		out.NextBefore = out.Audit[limit-1].At
	}
	writeJSON(w, http.StatusOK, out)
}

// fileStreamsGlobsPull answers the box's lane op file_streams_globs (3.8.5,
// case C46): the live globs of the session's box in the session's
// workspace; the frame names neither.
func (s *Server) fileStreamsGlobsPull(ctx context.Context, x *session, f wire.Frame, now time.Time) (*wire.FileStreamsAckFrame, *issueErr) {
	if err := wire.DecodeFileStreamsGlobsPull(f.Lane); err != nil {
		return nil, &issueErr{http.StatusBadRequest, "bad_file_stream", err.Error()}
	}
	gs, ok := s.o.Store.(store.FileStreamGlobStore)
	if !ok {
		return nil, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no file globs"}
	}
	globs, err := gs.BoxFileStreamGlobs(ctx, x.tenant, x.box)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("file stream globs pull")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "file globs unavailable"}
	}
	live := make([]wire.FileStreamGlobLive, len(globs))
	for i, g := range globs {
		live[i] = wire.FileStreamGlobLive{ID: g.ID, Key: g.Key, Glob: g.Glob}
	}
	return &wire.FileStreamsAckFrame{Type: "ack", LaneOp: wire.FileStreamsGlobsOp, Globs: &live, At: now.Format(time.RFC3339)}, nil
}

// fileStreamsReport stores an announce's folders and glob states (3.8.5);
// an announce without them (a box before row B10) changes nothing.
func (s *Server) fileStreamsReport(ctx context.Context, x *session, a wire.FileStreamsAnnounceFrame, now time.Time) error {
	gs, ok := s.o.Store.(store.FileStreamGlobStore)
	if !ok || (a.Folders == nil && len(a.Globs) == 0) {
		return nil
	}
	return gs.ReportFileStreamGlobs(ctx, x.tenant, x.box, a.Folders, a.Globs, now)
}

// sweepFileStreamGlobAudit prunes the glob audit rows past their retention
// (3.8.9: 365 days), from the file streams sweep.
func (s *Server) sweepFileStreamGlobAudit(ctx context.Context) {
	gs, ok := s.o.Store.(store.FileStreamGlobStore)
	if !ok {
		return
	}
	n, err := gs.PruneFileStreamGlobAudit(ctx, s.o.Now().Add(-s.o.FileStreamLimits.Norm().GlobAuditRetention))
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Msg("file stream glob audit retention sweep")
	case n > 0:
		s.o.Log.Info().Int("pruned", n).Msg("file stream glob audit retention sweep")
	}
}
