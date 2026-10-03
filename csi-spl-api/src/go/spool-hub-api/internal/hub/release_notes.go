package hub

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The release notes surface (spec 065 L4): one row per trunk commit, the six
// Lay-* / Tech-* trailers of its message (spec 4.1), stored by L3's
// store.ReleaseNotes.
//
//	POST /v1/operator/release-notes   the deploy-time ingest (L5). Operator
//	                                   auth: a Google ID token of the env's SA,
//	                                   like the other /v1/operator routes.
//	GET  /v1/release-notes?before=&limit=50
//	                                   the newest `limit` versions (1..50)
//	                                   strictly older than before, grouped.
//	GET  /v1/release-notes/{ref}       one note by sha or 7+ char prefix, or
//	                                   one version's notes by v<X.Y.Z> (7.2).
//
// Every signed-in member reads (Q11 yes); the rows are estate-wide, so the
// tenant only gates the session. A store without ReleaseNotes answers as off.

// Release note ingest limits.
const (
	releaseIngestBodyMax = 8 << 20 // 500 commits with long messages
	releaseRedacted      = "[redacted]"
	// ReleaseNoteBansEnv names extra hygiene patterns (RE2, one per line),
	// the distribution-hygiene sweep's name / box / org bans. They come from
	// the environment, never from this file: the sweep would refuse the
	// literals here.
	ReleaseNoteBansEnv = "SPOOL_HUB_RELEASE_NOTE_BANS"
)

// releaseNotes is a Server's ingest and read handlers with the hygiene filter.
type releaseNotes struct {
	s      *Server
	filter releaseFilter
}

// routeReleaseNotes mounts spec 065 L4. One call from server.go.
func (s *Server) routeReleaseNotes(mux *http.ServeMux) {
	rn := &releaseNotes{s: s, filter: newReleaseFilter(os.Getenv(ReleaseNoteBansEnv), func(p string, err error) {
		s.o.Log.Error().Err(err).Int("pattern_len", len(p)).Msg("release note ban pattern skipped")
	})}
	mux.HandleFunc("POST /v1/operator/release-notes", rn.handleIngest)
	mux.HandleFunc("GET /v1/release-notes", rn.handleList)
	mux.HandleFunc("GET /v1/release-notes/{ref}", rn.handleGet)
	mux.HandleFunc("OPTIONS /v1/release-notes", s.preflight)
	mux.HandleFunc("OPTIONS /v1/release-notes/{ref}", s.preflight)
}

// releaseIngestBody is the ingest request: at most store.ReleaseBatchMax rows.
type releaseIngestBody struct {
	Notes []releaseNoteIn `json:"notes"`
}

// releaseRejected names one row the ingest did not store, and why.
type releaseRejected struct {
	SHA string `json:"sha"`
	Why string `json:"why"`
}

// releaseIngestResult is the ingest answer. A bad row is reported, never
// fatal to the rest of the batch: a deploy must not lose every note for one.
type releaseIngestResult struct {
	Stored   int               `json:"stored"`
	Redacted int               `json:"redacted"`
	States   map[string]int    `json:"states"`
	Rejected []releaseRejected `json:"rejected"`
}

func (rn *releaseNotes) handleIngest(w http.ResponseWriter, r *http.Request) {
	if _, ok := rn.s.operatorAuth(w, r); !ok {
		return
	}
	rs, ok := rn.s.o.Store.(store.ReleaseNotes)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "release_notes_off", "this hub's store keeps no release notes")
		return
	}
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(http.MaxBytesReader(w, r.Body, releaseIngestBodyMax)); err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "release notes body too large")
		return
	}
	var body releaseIngestBody
	dec := json.NewDecoder(&buf)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {notes: [...]}: "+err.Error())
		return
	}
	if len(body.Notes) > store.ReleaseBatchMax {
		writeErr(w, http.StatusBadRequest, "bad_json", "at most "+strconv.Itoa(store.ReleaseBatchMax)+" notes per request")
		return
	}
	rows, res := rn.buildRows(body.Notes)
	if err := rs.PutReleaseNotes(r.Context(), rows, rn.s.o.Now()); err != nil {
		rn.s.o.Log.Error().Err(err).Int("rows", len(rows)).Msg("release notes ingest")
		writeErr(w, http.StatusServiceUnavailable, "internal", "release notes not stored")
		return
	}
	res.Stored = len(rows)
	writeJSON(w, http.StatusOK, res)
}

// buildRows turns the wire rows into checked, filtered store rows.
func (rn *releaseNotes) buildRows(in []releaseNoteIn) ([]store.ReleaseNote, releaseIngestResult) {
	res := releaseIngestResult{States: map[string]int{}, Rejected: []releaseRejected{}}
	rows := make([]store.ReleaseNote, 0, len(in))
	for _, wn := range in {
		n := wn.row()
		if rn.filter.apply(&n) {
			res.Redacted++
		}
		if why := store.CheckReleaseNote(n); why != "" {
			res.Rejected = append(res.Rejected, releaseRejected{SHA: wn.SHA, Why: why})
			continue
		}
		res.States[n.State]++
		rows = append(rows, n)
	}
	return rows, res
}

// releaseReader admits every signed-in member of the host's tenant (Q11).
func (rn *releaseNotes) releaseReader(w http.ResponseWriter, r *http.Request) (store.ReleaseNotes, bool) {
	s := rn.s
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	_, hum, ok := s.humanTenant(w, r)
	if !ok {
		return nil, false
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "release notes need a signed-in member session")
		return nil, false
	}
	rs, _ := s.o.Store.(store.ReleaseNotes)
	return rs, true
}

// releaseVersion is one version's notes, newest commit first.
type releaseVersion struct {
	Version string              `json:"version"`
	Notes   []store.ReleaseNote `json:"notes"`
}

// releaseListBody is one page. next_before is the cursor for the next (older)
// page, "" when this page is the last. off: the store keeps no notes.
type releaseListBody struct {
	Off        bool             `json:"off,omitempty"`
	Versions   []releaseVersion `json:"versions"`
	NextBefore string           `json:"next_before"`
}

func (rn *releaseNotes) handleList(w http.ResponseWriter, r *http.Request) {
	rs, ok := rn.releaseReader(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	limit := store.ReleaseVersionsMax
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > store.ReleaseVersionsMax {
			writeErr(w, http.StatusBadRequest, "bad_query", "limit must be 1.."+strconv.Itoa(store.ReleaseVersionsMax))
			return
		}
		limit = n
	}
	if rs == nil {
		writeJSON(w, http.StatusOK, releaseListBody{Off: true, Versions: []releaseVersion{}})
		return
	}
	rows, err := rs.ListReleaseNotes(r.Context(), q.Get("before"), limit)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_query", err.Error())
		return
	}
	body := releaseListBody{Versions: groupReleaseNotes(rows)}
	if len(body.Versions) == limit {
		body.NextBefore = body.Versions[len(body.Versions)-1].Version
	}
	writeJSON(w, http.StatusOK, body)
}

// groupReleaseNotes groups the list (already version-ordered) by version.
func groupReleaseNotes(rows []store.ReleaseNote) []releaseVersion {
	out := []releaseVersion{}
	for _, n := range rows {
		if len(out) == 0 || out[len(out)-1].Version != n.Version {
			out = append(out, releaseVersion{Version: n.Version})
		}
		last := &out[len(out)-1]
		last.Notes = append(last.Notes, n)
	}
	return out
}

func (rn *releaseNotes) handleGet(w http.ResponseWriter, r *http.Request) {
	rs, ok := rn.releaseReader(w, r)
	if !ok {
		return
	}
	if rs == nil {
		writeErr(w, http.StatusNotFound, "not_found", "this hub's store keeps no release notes")
		return
	}
	ref := r.PathValue("ref")
	if strings.HasPrefix(ref, "v") {
		rows, err := rs.ReleaseNotesOfVersion(r.Context(), ref)
		switch {
		case err != nil:
			writeErr(w, http.StatusBadRequest, "bad_ref", err.Error())
		case len(rows) == 0:
			writeErr(w, http.StatusNotFound, "not_found", "no release notes for "+ref)
		default:
			writeJSON(w, http.StatusOK, releaseVersion{Version: ref, Notes: rows})
		}
		return
	}
	n, err := rs.ReleaseNote(r.Context(), ref)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no release note for that sha")
	case errors.Is(err, store.ErrAmbiguousRef):
		writeErr(w, http.StatusConflict, "ambiguous_ref", "that sha prefix matches more than one note")
	case err != nil:
		writeErr(w, http.StatusBadRequest, "bad_ref", err.Error())
	default:
		writeJSON(w, http.StatusOK, map[string]store.ReleaseNote{"note": n})
	}
}
