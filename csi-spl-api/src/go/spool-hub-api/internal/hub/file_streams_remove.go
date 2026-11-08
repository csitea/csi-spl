package hub

import (
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Removing a file from the view (spec 160 section 3.10, SPL-4979, rdb 0269;
// owner HUM-10, t1 3331b0e6, msg 5bb5d078). The gate is the read routes' one
// (fileStreamsCaller): a member session of the workspace, not an act-as clone,
// owner or admin; else 403. Another workspace's id, a second remove and a put
// back of a row not removed are 404 and write no audit row.
//
//	DELETE /v1/file-streams/{id}          -> 204 out of the list, the box told at its next pull
//	POST   /v1/file-streams/{id}/restore  -> 204 back in the list, the box's next announce sets its state
//
// The removal lives on the hub's row, so it survives every re-announce: the
// announce keeps it and a push for the key is acked and not stored, whatever
// code the box runs. A remove has no box lock check (D7, it only narrows what
// is read); a put back has the glob add's, for it reads a file on that box again.

func (s *Server) routeFileStreamRemove(mux *http.ServeMux) {
	mux.HandleFunc("DELETE /v1/file-streams/{id}", s.handleFileStreamRemove)
	mux.HandleFunc("POST /v1/file-streams/{id}/restore", s.handleFileStreamRestore)
	mux.HandleFunc("OPTIONS /v1/file-streams/{id}", s.fileStreamRemovePreflight)
	mux.HandleFunc("OPTIONS /v1/file-streams/{id}/restore", s.fileStreamRemovePreflight)
}

// fileStreamRemovePreflight: the WUI calls the hub from another origin, so a
// browser sends this before the DELETE and refuses the call without it.
func (s *Server) fileStreamRemovePreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "DELETE, POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleFileStreamRemove is DELETE /v1/file-streams/{id}.
func (s *Server) handleFileStreamRemove(w http.ResponseWriter, r *http.Request) {
	tenant, hum, ok := s.fileStreamsCaller(w, r)
	if !ok {
		return
	}
	fs, ok := s.o.Store.(store.FileStreamStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no file streams")
		return
	}
	f, err := fs.RemoveFileStream(r.Context(), tenant, r.PathValue("id"), hum, s.o.Now().UTC())
	s.answerFileStreamChange(w, tenant, hum, "file_stream.removed", f, err)
}

// handleFileStreamRestore is POST /v1/file-streams/{id}/restore.
func (s *Server) handleFileStreamRestore(w http.ResponseWriter, r *http.Request) {
	gs, tenant, hum, ok := s.fileStreamGlobsStaff(w, r)
	if !ok {
		return
	}
	fs, ok := s.o.Store.(store.FileStreamStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no file streams")
		return
	}
	ctx, now, id := r.Context(), s.o.Now().UTC(), r.PathValue("id")
	all, err := fs.ListFileStreams(ctx, tenant)
	if err != nil {
		s.answerFileStreamChange(w, tenant, hum, "", store.FileStream{}, err)
		return
	}
	var target *store.FileStream
	for i := range all {
		if all[i].ID == id && all[i].RemovedAt != nil {
			target = &all[i]
		}
	}
	if target == nil {
		s.answerFileStreamChange(w, tenant, hum, "", store.FileStream{}, store.ErrNotFound)
		return
	}
	l, err := s.boxLock(ctx, tenant, target.Box)
	if err == nil && l != nil && !l.IsOwner(hum) {
		err = gs.AuditFileStreamGlobRefusal(ctx, tenant, store.FileStreamGlobAuditRow{Box: target.Box, Key: target.StreamKey, Glob: target.Path,
			Actor: hum, Reason: "box_locked", At: now})
		if err == nil {
			writeErr(w, http.StatusForbidden, "box_locked", "the box is locked: only its lock owners put a file back on it")
			return
		}
	}
	f := store.FileStream{}
	if err == nil {
		f, err = fs.RestoreFileStream(ctx, tenant, id, hum, now)
	}
	s.answerFileStreamChange(w, tenant, hum, "file_stream.restored", f, err)
}

// answerFileStreamChange answers a remove or a put back: 204 and the log line,
// 404 for ErrNotFound, else 500.
func (s *Server) answerFileStreamChange(w http.ResponseWriter, tenant, hum, event string, f store.FileStream, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such file stream")
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("file stream remove or put back")
		writeErr(w, http.StatusInternalServerError, "internal", "file stream not changed")
	default:
		s.o.Log.Info().Str("tenant", tenant).Str("box", f.Box).Str("stream_key", f.StreamKey).Str("by", hum).Msg(event)
		w.WriteHeader(http.StatusNoContent)
	}
}
