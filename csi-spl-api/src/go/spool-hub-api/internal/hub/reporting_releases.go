package hub

import (
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Releases tab of the Reporting section (spec 143 section 2.4, tasks
// T020 and T021): two reads over release_notes joined with estate_deploys.
//
//	GET /v1/reporting/releases/daily?from=&to=&kind=&area=
//	    the commits per UTC day, counted by kind and area, with the dev and
//	    prd deploys of that day.
//	GET /v1/reporting/releases/commits?from=&to=&kind=&area=&search=&limit=&offset=
//	    one page of the commits, newest first, and the count of every match.
//
// from / to are an RFC3339 time or a YYYY-MM-DD day (a `to` day includes the
// whole day); the default window is the last 30 days. kind and area are
// comma lists. Every signed-in member reads (spec 6.1), like the release
// notes the rows come from. A store without the report answers as off.

// Releases report window limits.
const (
	releaseReportDefaultDays = 30
	releaseReportMaxDays     = 400
	releaseReportOffsetMax   = 1_000_000
)

func (s *Server) routeReportingReleases(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/reporting/releases/daily", s.handleReleasesDaily)
	mux.HandleFunc("GET /v1/reporting/releases/commits", s.handleReleasesCommits)
	mux.HandleFunc("OPTIONS /v1/reporting/releases/daily", s.preflight)
	mux.HandleFunc("OPTIONS /v1/reporting/releases/commits", s.preflight)
}

// releaseReportReader admits every signed-in member of the host's tenant.
func (s *Server) releaseReportReader(w http.ResponseWriter, r *http.Request) (store.ReleaseReports, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	_, hum, ok := s.humanTenant(w, r)
	if !ok {
		return nil, false
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "the reporting section needs a signed-in member session")
		return nil, false
	}
	rr, _ := s.o.Store.(store.ReleaseReports)
	return rr, true
}

// releaseReportFilter reads the shared query parameters.
func (s *Server) releaseReportFilter(q url.Values) (store.ReleaseReportFilter, error) {
	now := s.o.Now().UTC()
	f := store.ReleaseReportFilter{From: now.AddDate(0, 0, -releaseReportDefaultDays), To: now, Search: q.Get("search")}
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
	f.Kinds, f.Areas = commaList(q.Get("kind")), commaList(q.Get("area"))
	return f, store.CheckReleaseReportFilter(f)
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

// releaseDailyBody is the daily answer. off: the store keeps no report.
type releaseDailyBody struct {
	Off bool `json:"off,omitempty"`
	store.ReleaseDaily
	From time.Time `json:"from"`
	To   time.Time `json:"to"`
}

func (s *Server) handleReleasesDaily(w http.ResponseWriter, r *http.Request) {
	rr, ok := s.releaseReportReader(w, r)
	if !ok {
		return
	}
	f, err := s.releaseReportFilter(r.URL.Query())
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_query", err.Error())
		return
	}
	if rr == nil {
		writeJSON(w, http.StatusOK, releaseDailyBody{Off: true, ReleaseDaily: store.ReleaseDaily{Days: []store.ReleaseDay{}}, From: f.From, To: f.To})
		return
	}
	daily, err := rr.ReleaseDaily(r.Context(), f)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the releases report is not available", err)
		return
	}
	writeJSON(w, http.StatusOK, releaseDailyBody{ReleaseDaily: daily, From: f.From, To: f.To})
}

// releaseCommitsBody is one page of commits.
type releaseCommitsBody struct {
	Off    bool                `json:"off,omitempty"`
	Total  int                 `json:"total"`
	Limit  int                 `json:"limit"`
	Offset int                 `json:"offset"`
	Notes  []store.ReleaseNote `json:"notes"`
}

func (s *Server) handleReleasesCommits(w http.ResponseWriter, r *http.Request) {
	rr, ok := s.releaseReportReader(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	f, err := s.releaseReportFilter(q)
	if err == nil {
		f.Limit, f.Offset, err = releasePage(q)
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_query", err.Error())
		return
	}
	body := releaseCommitsBody{Limit: f.Limit, Offset: f.Offset, Notes: []store.ReleaseNote{}}
	if rr == nil {
		body.Off = true
		writeJSON(w, http.StatusOK, body)
		return
	}
	body.Notes, body.Total, err = rr.ReleaseCommits(r.Context(), f)
	if err != nil {
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "the releases report is not available", err)
		return
	}
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
