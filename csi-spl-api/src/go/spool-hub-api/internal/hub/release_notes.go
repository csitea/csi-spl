package hub

import (
	"bytes"
	"context"
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
//	                                   one version's notes by its release
//	                                   key v<X.Y.Z>[-c<N>] (7.2).
//
// A version is keyed by its release key, the full tag (rdb 0114): after
// 9.9.9 the mint starts over at 1.0.1 as tag v1.0.1-c2, so the two cycles'
// v1.0.1 stay two groups. `display` is what a reader sees, the plain v1.0.1.
//
// The reads are public (owner, t1 2e46fcb6 msg daf6efcf, SPL-4530: "Release
// notes are public: the page shows the note without signing in"; it replaced
// Q11's "every signed-in member"). A request whose page Origin or legacy Host
// names a known, live workspace reads with no session; one that names none is
// the session's, as before. The rows are estate-wide: built from the public
// trunk's commit messages, hygiene-filtered at ingest, they hold no
// workspace's data, so a visitor of one workspace learns nothing of another;
// the workspace only binds the read to a host this hub serves. A store
// without ReleaseNotes answers as off.

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
	mux.HandleFunc("POST /v1/operator/commit-links", s.handleCommitLinks)
	mux.HandleFunc("GET /v1/release-notes", rn.handleList)
	mux.HandleFunc("GET /v1/release-notes/{ref}", rn.handleGet)
	mux.HandleFunc("OPTIONS /v1/release-notes", s.preflight)
	mux.HandleFunc("OPTIONS /v1/release-notes/{ref}", s.preflight)
}

// releaseIngestBody is the ingest request: at most store.ReleaseBatchMax rows.
type releaseIngestBody struct {
	Notes []releaseNoteIn `json:"notes"`
	// IssueTenant is the workspace whose issues the messages cite (cnf
	// hub.commit_issue_tenant, SPL-4789); "" keeps the rows' stored keys.
	IssueTenant string `json:"issue_tenant,omitempty"`
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
	prefix, err := rn.issuePrefix(r.Context(), body.IssueTenant)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	rows, res := rn.buildRows(body.Notes, body.IssueTenant, prefix)
	if err := rs.PutReleaseNotes(r.Context(), rows, rn.s.o.Now()); err != nil {
		rn.s.o.Log.Error().Err(err).Int("rows", len(rows)).Msg("release notes ingest")
		writeErr(w, http.StatusServiceUnavailable, "internal", "release notes not stored")
		return
	}
	res.Stored = len(rows)
	writeJSON(w, http.StatusOK, res)
}

// issuePrefix is the issue key prefix of tenant ("" for no tenant); an
// unknown tenant is an error, so a cnf typo never stores keys for nobody.
func (rn *releaseNotes) issuePrefix(ctx context.Context, tenant string) (string, error) {
	if tenant == "" {
		return "", nil
	}
	if _, err := rn.s.o.Store.GetTenant(ctx, tenant); err != nil {
		return "", errors.New("issue_tenant names no workspace of this hub")
	}
	is, ok := rn.s.o.Store.(store.Issues)
	if !ok {
		return "", nil
	}
	p, err := is.IssuePrefix(ctx, tenant)
	if err != nil {
		return "", errors.New("issue_tenant: its issue prefix cannot be read")
	}
	return p, nil
}

// buildRows turns the wire rows into checked, filtered store rows, each
// naming the issues of tenant (key prefix prefix) its message cites.
func (rn *releaseNotes) buildRows(in []releaseNoteIn, tenant, prefix string) ([]store.ReleaseNote, releaseIngestResult) {
	res := releaseIngestResult{States: map[string]int{}, Rejected: []releaseRejected{}}
	rows := make([]store.ReleaseNote, 0, len(in))
	for _, wn := range in {
		n := wn.row()
		if tenant != "" {
			n.IssueTenant, n.IssueKeys = tenant, store.ReleaseIssueKeys(prefix, wn.Message)
		}
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

// releaseReader admits anyone on a known workspace's page (SPL-4530): the
// page Origin, else the legacy Host, names it, and no session is read. A
// request that names no workspace needs a member session, as before. A
// visitor gets the member's answer, every field: nothing in a note is
// withheld (see the header).
func (rn *releaseNotes) releaseReader(w http.ResponseWriter, r *http.Request) (store.ReleaseNotes, bool) {
	s := rn.s
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if id := s.webCalendarTenant(r); id != "" {
		if _, ok := s.loadTenant(w, r, id); !ok {
			return nil, false
		}
		rs, _ := s.o.Store.(store.ReleaseNotes)
		return rs, true
	}
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

// releaseVersion is one version's notes, newest commit first. Version is the
// release key (the cursor and the /releases ref), Display the plain v<X.Y.Z>.
type releaseVersion struct {
	Version string              `json:"version"`
	Display string              `json:"display"`
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
			out = append(out, releaseVersion{Version: n.Version, Display: store.ReleaseDisplay(n.Version)})
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
			writeJSON(w, http.StatusOK, releaseVersionLinks{Version: ref, Display: store.ReleaseDisplay(ref), Notes: rn.s.withReleaseLinks(r, rows)})
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
		writeJSON(w, http.StatusOK, map[string]releaseNoteLinksJSON{"note": rn.s.withReleaseLinks(r, []store.ReleaseNote{n})[0]})
	}
}
