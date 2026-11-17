package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strconv"

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
//	GET  /v1/release-notes/{ref}?repo= one note by sha or 7+ char prefix, or
//	                                   one version's notes by its release
//	                                   key v<X.Y.Z>[-c<N>] (7.2), of repo, a
//	                                   repo of the workspace (default: the
//	                                   primary repo).
//
// A version is keyed by its release key, the full tag (rdb 0114): after
// 9.9.9 the mint starts over at 1.0.1 as tag v1.0.1-c2, so the two cycles'
// v1.0.1 stay two groups. `display` is what a reader sees, the plain v1.0.1.
//
// The reads are public for a public repo (owner, t1 2e46fcb6 msg daf6efcf,
// SPL-4530: "Release notes are public: the page shows the note without
// signing in"), narrowed by spec 143 releases-projects.md section 6.3 (row
// B-5, owner msg 24e35756: "public only for a repo flagged public"). A
// request whose page Origin or legacy Host names a known, live workspace
// reads with no session, but only the repos flagged notes_public; a member
// session of that workspace reads every repo of it (section 6.4). One that
// names none is the session's, as before. The list and a version read the
// workspace's primary repo only, so two repos' v1.0.0 never merge into one
// version; a member of a workspace with no primary repo reads every row, as
// before row B-5. A store without ReleaseNotes answers as off.

// Release note ingest limits.
const (
	releaseIngestBodyMax = 8 << 20 // 500 commits with long messages
	releaseRedacted      = "[redacted]"
	releaseBodyScan      = 4 * store.ReleaseBodyMax // the body row keeps for the filter; fitBody cuts it after
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
	mux.HandleFunc("POST /v1/operator/issues/{ref}/origin-discussion", s.handleIssueOriginDiscussion)
	mux.HandleFunc("GET /v1/release-notes", rn.handleList)
	mux.HandleFunc("GET /v1/release-notes/{ref}", rn.handleGet)
	mux.HandleFunc("OPTIONS /v1/release-notes", s.preflight)
	mux.HandleFunc("OPTIONS /v1/release-notes/{ref}", s.preflight)
}

// releaseIngestBody is the ingest request: at most store.ReleaseBatchMax rows.
type releaseIngestBody struct {
	Notes []releaseNoteIn `json:"notes"`
	// Tenant and RepoSlug place the rows (ingestScope); both are optional.
	Tenant   string `json:"tenant,omitempty"`
	RepoSlug string `json:"repo_slug,omitempty"`
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
	tenant, repo, ok := rn.s.ingestScope(w, r, body.Tenant, body.RepoSlug)
	if !ok {
		return
	}
	prefix, err := rn.issuePrefix(r.Context(), body.IssueTenant)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", err.Error())
		return
	}
	optional, err := rn.trailersOptional(r.Context(), tenant)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the operator workspace is not readable", err)
		return
	}
	rows, res := rn.buildRows(body.Notes, body.IssueTenant, prefix, optional)
	if err := rs.PutReleaseNotes(r.Context(), tenant, repo, rows, rn.s.o.Now()); err != nil {
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

// trailersOptional is whether the trailer rule (spec 065) does not bind the
// repos of tenant, the workspace of the repo row the ingest resolved: it binds
// the operator workspace's repos only (releases-projects.md section 5, the
// interim rule of row B-6; a per-repo column is a later migration). It reads
// the row's workspace, never the repo's name. On a hub with no operator
// workspace (none flagged, none in cnf) op is "" and every workspace is
// optional: no repo is the operator's there. Such a hub refuses an ingest
// that names no tenant (ingestScope: tenant_required), so the rows always
// land in a workspace the batch named (B-6 review N3).
func (rn *releaseNotes) trailersOptional(ctx context.Context, tenant string) (bool, error) {
	op, err := rn.s.operatorTenant(ctx)
	return tenant != op, err
}

// buildRows turns the wire rows into checked, filtered store rows, each
// naming the issues of tenant (key prefix prefix) its message cites. Every
// row the ingest stores passes here, so none skips the hygiene filter;
// optional is trailersOptional of the rows' workspace.
func (rn *releaseNotes) buildRows(in []releaseNoteIn, tenant, prefix string, optional bool) ([]store.ReleaseNote, releaseIngestResult) {
	res := releaseIngestResult{States: map[string]int{}, Rejected: []releaseRejected{}}
	rows := make([]store.ReleaseNote, 0, len(in))
	for _, wn := range in {
		n := wn.row(optional)
		if tenant != "" {
			n.IssueTenant, n.IssueKeys = tenant, store.ReleaseIssueKeys(prefix, wn.Message)
		}
		if rn.filter.apply(&n) {
			res.Redacted++
		}
		n.Body = fitBody(n.Body)
		if why := store.CheckReleaseNote(n); why != "" {
			res.Rejected = append(res.Rejected, releaseRejected{SHA: wn.SHA, Why: why})
			continue
		}
		res.States[n.State]++
		rows = append(rows, n)
	}
	return rows, res
}

// releaseScope is one release note read: the store, the workspace and
// whether the reader is a member of it (false: a reader with no login, who
// reads notes_public repos only, section 6.4).
type releaseScope struct {
	rs     store.ReleaseNotes
	tenant string
	member bool
}

// releaseReader admits anyone on a known workspace's page (SPL-4530): the
// page Origin, else the legacy Host, names it. The session is read too, so a
// member of that workspace reads as a member; anyone else, a session of
// another workspace included, reads as a visitor (noteRepo). A request that
// names no workspace needs a member session, as before.
func (rn *releaseNotes) releaseReader(w http.ResponseWriter, r *http.Request) (releaseScope, bool) {
	s := rn.s
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	rs, _ := s.o.Store.(store.ReleaseNotes)
	if id := s.webCalendarTenant(r); id != "" {
		if _, ok := s.loadTenant(w, r, id); !ok {
			return releaseScope{}, false
		}
		hum, err := s.memberID(r, id)
		return releaseScope{rs: rs, tenant: id, member: err == nil && hum != ""}, true
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return releaseScope{}, false
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "release notes need a signed-in member session")
		return releaseScope{}, false
	}
	return releaseScope{rs: rs, tenant: t.ID, member: true}, true
}

// noteRepo is the repo a read of sc reads (section 6.3): want, a repo of the
// workspace, or the primary repo for want "". ok false: there is none the
// reader may read (unknown, another workspace's, or not notes_public for a
// visitor), and the caller answers empty or 404, the same either way. A
// workspace with no primary repo: a member reads every repo (repo ""), a
// visitor nothing.
func (rn *releaseNotes) noteRepo(ctx context.Context, sc releaseScope, want string) (repo string, ok bool, err error) {
	var repos []store.ReleaseProjectRepo
	if rr, has := rn.s.o.Store.(store.ReleaseReports); has {
		ps, err := rr.ReleaseProjects(ctx, sc.tenant)
		if err != nil {
			return "", false, err
		}
		for _, p := range ps {
			repos = append(repos, p.Repos...)
		}
	}
	for _, r := range repos {
		if (want == "" && r.IsPrimary) || (want != "" && r.Slug == want) {
			return r.Slug, sc.member || r.NotesPublic, nil
		}
	}
	return "", want == "" && sc.member, nil
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
	sc, ok := rn.releaseReader(w, r)
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
	if sc.rs == nil {
		writeJSON(w, http.StatusOK, releaseListBody{Off: true, Versions: []releaseVersion{}})
		return
	}
	repo, readable, err := rn.noteRepo(r.Context(), sc, "")
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "release notes are not available", err)
		return
	}
	if !readable {
		writeJSON(w, http.StatusOK, releaseListBody{Versions: []releaseVersion{}})
		return
	}
	rows, err := sc.rs.ListReleaseNotes(r.Context(), sc.tenant, repo, q.Get("before"), limit)
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
	sc, ok := rn.releaseReader(w, r)
	if !ok {
		return
	}
	if sc.rs == nil {
		writeErr(w, http.StatusNotFound, "not_found", "this hub's store keeps no release notes")
		return
	}
	ref, want := r.PathValue("ref"), r.URL.Query().Get("repo")
	if want != "" && !releaseRepoParamRe.MatchString(want) {
		writeErr(w, http.StatusBadRequest, "bad_query", "repo must be an owner/name slug")
		return
	}
	repo, readable, err := rn.noteRepo(r.Context(), sc, want)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "release notes are not available", err)
		return
	}
	if !readable {
		writeErr(w, http.StatusNotFound, "not_found", "no release notes for "+ref)
		return
	}
	rn.getNote(w, r, sc, repo, ref)
}

// getNote answers ref of repo: a stored version wins, so a hex-like tag or
// 2026.11.05 opens its version; else one note by its sha.
func (rn *releaseNotes) getNote(w http.ResponseWriter, r *http.Request, sc releaseScope, repo, ref string) {
	rs, tenant := sc.rs, sc.tenant
	rows, err := rs.ReleaseNotesOfVersion(r.Context(), tenant, repo, ref)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_ref", err.Error())
		return
	}
	if len(rows) > 0 {
		writeJSON(w, http.StatusOK, releaseVersionLinks{Version: ref, Display: store.ReleaseDisplay(ref), Notes: rn.s.withReleaseLinks(r, rows)})
		return
	}
	if _, err := store.CheckReleaseRef(ref); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no release notes for "+ref)
		return
	}
	n, err := rs.ReleaseNote(r.Context(), tenant, repo, ref)
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
