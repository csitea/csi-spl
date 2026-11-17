package hub

import (
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Releases tab of the Reporting section (spec 143 section 2.4, tasks
// T020 and T021): two reads over release_notes joined with estate_deploys.
//
//	GET /v1/reporting/releases/projects
//	    the workspace's software projects and their repos, default first
//	    (releases-projects.md section 6.1), for the drop box.
//	GET /v1/reporting/releases/daily?project=&repo=&from=&to=&kind=&area=
//	    the commits per UTC day, counted by kind, area and repo, with the dev
//	    and prd deploys of that day.
//	GET /v1/reporting/releases/commits?project=&repo=&from=&to=&kind=&area=&search=&limit=&offset=
//	    one page of the commits, newest first, and the count of every match.
//
// project is a project slug of the workspace (default: its default project,
// never every project); repo one repo slug of that project (default: all of
// them). A project or repo the workspace does not have answers 404
// unknown_project / unknown_repo, the same whether it does not exist or is
// another workspace's (section 6.2). from / to are an RFC3339 time or a
// YYYY-MM-DD day (a `to` day includes the whole day); the default window is
// the last 30 days. kind and area are comma lists. Every signed-in member of
// the workspace reads (spec 6.1, section 6.4); a reader with no login does
// not. A store without the report answers as off.

// Releases report window limits.
const (
	releaseReportDefaultDays = 30
	releaseReportMaxDays     = 400
	releaseReportOffsetMax   = 1_000_000
)

// The project and repo param shapes, rdb 0266's slug CHECKs; a bad shape is
// 400 bad_query.
var (
	releaseProjectParamRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,47}$`)
	releaseRepoParamRe    = regexp.MustCompile(`^[a-z0-9._-]+/[a-z0-9._-]+$`)
)

func (s *Server) routeReportingReleases(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/reporting/releases/projects", s.handleReleasesProjects)
	mux.HandleFunc("GET /v1/reporting/releases/daily", s.handleReleasesDaily)
	mux.HandleFunc("GET /v1/reporting/releases/commits", s.handleReleasesCommits)
	mux.HandleFunc("OPTIONS /v1/reporting/releases/projects", s.preflight)
	mux.HandleFunc("OPTIONS /v1/reporting/releases/daily", s.preflight)
	mux.HandleFunc("OPTIONS /v1/reporting/releases/commits", s.preflight)
}

// releaseReportReader admits every signed-in member of the host's tenant.
func (s *Server) releaseReportReader(w http.ResponseWriter, r *http.Request) (store.ReleaseReports, string, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return nil, "", false
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "the reporting section needs a signed-in member session")
		return nil, "", false
	}
	rr, _ := s.o.Store.(store.ReleaseReports)
	return rr, t.ID, true
}

// releaseReportFilter reads the shared query parameters.
func (s *Server) releaseReportFilter(tenant string, q url.Values) (store.ReleaseReportFilter, error) {
	now := s.o.Now().UTC()
	f := store.ReleaseReportFilter{Tenant: tenant, From: now.AddDate(0, 0, -releaseReportDefaultDays), To: now, Search: q.Get("search")}
	var err error
	if v := q.Get("from"); v != "" {
		if f.From, err = parseReportTime(v, false); err != nil {
			return f, errors.New("from must be an RFC3339 time or a YYYY-MM-DD day")
		}
	}
	if v := q.Get("to"); v != "" {
		if f.To, err = parseReportTime(v, true); err != nil {
			return f, errors.New("to must be an RFC3339 time or a YYYY-MM-DD day")
		}
	}
	if f.To.Sub(f.From) > releaseReportMaxDays*24*time.Hour {
		return f, errors.New("the window may span at most " + strconv.Itoa(releaseReportMaxDays) + " days")
	}
	if v := q.Get("project"); v != "" && !releaseProjectParamRe.MatchString(v) {
		return f, errors.New("project must be a project slug")
	}
	if v := q.Get("repo"); v != "" && !releaseRepoParamRe.MatchString(v) {
		return f, errors.New("repo must be an owner/name slug")
	}
	f.Kinds, f.Areas = commaList(q.Get("kind")), commaList(q.Get("area"))
	return f, store.CheckReleaseReportQuery(f)
}

// releaseReportScope resolves the project and repo params into f.Repos
// (section 6.2), or writes the error. ok with a nil project: the workspace
// has no project and the request named none, so the caller answers 200 with
// configured false and no rows.
func releaseReportScope(w http.ResponseWriter, r *http.Request, rr store.ReleaseReports, f *store.ReleaseReportFilter) (*store.ReleaseProject, bool) {
	project, repo := r.URL.Query().Get("project"), r.URL.Query().Get("repo")
	projects, err := rr.ReleaseProjects(r.Context(), f.Tenant)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the releases report is not available", err)
		return nil, false
	}
	p := pickReleaseProject(projects, project)
	switch {
	case p == nil && project == "" && repo == "":
		return nil, true
	case p == nil && project == "":
		writeErr(w, http.StatusNotFound, "unknown_repo", "no such repo in this workspace")
		return nil, false
	case p == nil:
		writeErr(w, http.StatusNotFound, "unknown_project", "no such project in this workspace")
		return nil, false
	}
	f.Repos = p.RepoSlugs()
	if repo != "" {
		if !slices.Contains(f.Repos, repo) {
			writeErr(w, http.StatusNotFound, "unknown_repo", "no such repo in this project")
			return nil, false
		}
		f.Repos = []string{repo}
	}
	return p, true
}

// pickReleaseProject is project slug of ps, the first (the default, by
// ReleaseProjects' order) for slug "", nil when there is none.
func pickReleaseProject(ps []store.ReleaseProject, slug string) *store.ReleaseProject {
	for i := range ps {
		if slug == "" || ps[i].Slug == slug {
			return &ps[i]
		}
	}
	return nil
}

// releaseProjectsBody is the projects answer (section 6.1). off: the store
// keeps no report.
type releaseProjectsBody struct {
	Off        bool                   `json:"off,omitempty"`
	Configured bool                   `json:"configured"`
	Default    string                 `json:"default"`
	Projects   []store.ReleaseProject `json:"projects"`
}

func (s *Server) handleReleasesProjects(w http.ResponseWriter, r *http.Request) {
	rr, tenant, ok := s.releaseReportReader(w, r)
	if !ok {
		return
	}
	if rr == nil {
		writeJSON(w, http.StatusOK, releaseProjectsBody{Off: true, Projects: []store.ReleaseProject{}})
		return
	}
	projects, err := rr.ReleaseProjects(r.Context(), tenant)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the releases report is not available", err)
		return
	}
	body := releaseProjectsBody{Configured: len(projects) > 0, Projects: projects}
	if body.Configured {
		body.Default = projects[0].Slug
	}
	writeJSON(w, http.StatusOK, body)
}

// parseReportTime is an RFC3339 time or a UTC day; a day as the end of a
// window is the start of the next day, so the window includes it.
func parseReportTime(v string, end bool) (time.Time, error) {
	if t, err := time.Parse(time.RFC3339, v); err == nil {
		return t.UTC(), nil
	}
	d, err := time.Parse(time.DateOnly, v)
	if err != nil {
		return time.Time{}, err
	}
	if end {
		d = d.AddDate(0, 0, 1)
	}
	return d, nil
}

// commaList is a comma list, trimmed and lowercased, empty items dropped.
func commaList(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.ToLower(strings.TrimSpace(p)); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// releaseProjectRef names the project a report reads.
type releaseProjectRef struct {
	Slug string `json:"slug"`
	Name string `json:"name"`
}

// releaseDailyBody is the daily answer: the project it read and its repos
// (section 6.2), null and empty when configured is false. off: the store
// keeps no report.
type releaseDailyBody struct {
	Off        bool                       `json:"off,omitempty"`
	Configured bool                       `json:"configured"`
	Project    *releaseProjectRef         `json:"project"`
	Repos      []store.ReleaseProjectRepo `json:"repos"`
	store.ReleaseDaily
	From time.Time `json:"from"`
	To   time.Time `json:"to"`
}

func (s *Server) handleReleasesDaily(w http.ResponseWriter, r *http.Request) {
	rr, tenant, ok := s.releaseReportReader(w, r)
	if !ok {
		return
	}
	f, err := s.releaseReportFilter(tenant, r.URL.Query())
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_query", err.Error())
		return
	}
	body := releaseDailyBody{Repos: []store.ReleaseProjectRepo{}, ReleaseDaily: store.ReleaseDaily{Days: []store.ReleaseDay{}}, From: f.From, To: f.To}
	if rr == nil {
		body.Off = true
		writeJSON(w, http.StatusOK, body)
		return
	}
	p, ok := releaseReportScope(w, r, rr, &f)
	if !ok {
		return
	}
	if p != nil {
		body.Configured, body.Project, body.Repos = true, &releaseProjectRef{Slug: p.Slug, Name: p.Name}, p.Repos
		if body.ReleaseDaily, err = rr.ReleaseDaily(r.Context(), f); err != nil {
			writeErrCause(w, http.StatusServiceUnavailable, "internal", "the releases report is not available", err)
			return
		}
	}
	writeJSON(w, http.StatusOK, body)
}

// releaseCommitsBody is one page of commits.
type releaseCommitsBody struct {
	Off    bool                   `json:"off,omitempty"`
	Total  int                    `json:"total"`
	Limit  int                    `json:"limit"`
	Offset int                    `json:"offset"`
	Notes  []releaseNoteLinksJSON `json:"notes"`
}

func (s *Server) handleReleasesCommits(w http.ResponseWriter, r *http.Request) {
	rr, tenant, ok := s.releaseReportReader(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	f, err := s.releaseReportFilter(tenant, q)
	if err == nil {
		f.Limit, f.Offset, err = releasePage(q)
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_query", err.Error())
		return
	}
	body := releaseCommitsBody{Limit: f.Limit, Offset: f.Offset, Notes: []releaseNoteLinksJSON{}}
	if rr == nil {
		body.Off = true
		writeJSON(w, http.StatusOK, body)
		return
	}
	var notes []store.ReleaseNote
	var total int
	p, ok := releaseReportScope(w, r, rr, &f)
	if !ok {
		return
	}
	if p != nil {
		notes, total, err = rr.ReleaseCommits(r.Context(), f)
	}
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the releases report is not available", err)
		return
	}
	body.Notes, body.Total = s.withReleaseLinks(r, notes), total
	writeJSON(w, http.StatusOK, body)
}

// releasePage is the limit (1..200, default 50) and offset of a commits page.
func releasePage(q url.Values) (limit, offset int, err error) {
	limit = store.ReleaseReportLimitDefault
	if v := q.Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 || limit > store.ReleaseReportLimitMax {
			return 0, 0, errors.New("limit must be 1.." + strconv.Itoa(store.ReleaseReportLimitMax))
		}
	}
	if v := q.Get("offset"); v != "" {
		if offset, err = strconv.Atoi(v); err != nil || offset < 0 || offset > releaseReportOffsetMax {
			return 0, 0, errors.New("offset must be 0.." + strconv.Itoa(releaseReportOffsetMax))
		}
	}
	return limit, offset, nil
}
