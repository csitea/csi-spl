package hub

import (
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// GET /v1/admin/perf/summary?days=&build=&build_b= (spec 066 section 6, L3).
//
// tenant.settings, the caller's workspace only: the tenant is the session's,
// never a query field. days is 1..30 (empty = 7, the report window; raw rows
// live store.PerfSampleRetention). build and build_b are version tokens;
// empty build is every build. rows is that window ranked by p75 descending
// (the slowest group first). rows_b is the same window for build_b, and is
// present only when build_b is set. p95 is omitted when n < 50 (section 8).

const (
	perfSummaryDaysDefault = 7
	perfSummaryDaysMax     = 30 // the retention; a longer window has no rows
	perfSummaryP95MinN     = 50
)

// perfSummaryBuildRe is rdb 0106's build CHECK (store.CheckPerfSample). A
// query token outside it is refused, so the summary cannot carry free text.
var perfSummaryBuildRe = regexp.MustCompile(`^[0-9A-Za-z.+-]{0,40}$`)

// routePerfSummary mounts the admin summary (spec 066 L3). One call from
// server.go, beside L2's routePerfIngest.
func (s *Server) routePerfSummary(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/admin/perf/summary", s.handlePerfSummary)
	mux.HandleFunc("OPTIONS /v1/admin/perf/summary", s.preflight)
}

// perfSummaryRow is one (metric, device, view) group. p95 is absent under
// n = 50; p50 and p75 stay, null when the group has no completed sample.
type perfSummaryRow struct {
	Metric string   `json:"metric"`
	Device string   `json:"device"`
	View   string   `json:"view"`
	N      int      `json:"n"`
	P50    *float64 `json:"p50"`
	P75    *float64 `json:"p75"`
	P95    *float64 `json:"p95,omitempty"`
	Failed int      `json:"failed"`
}

// perfSummaryBody is the summary. off is set when this hub's store keeps no
// samples (the route answers as off, the same way the sweep skips).
type perfSummaryBody struct {
	Off    bool             `json:"off,omitempty"`
	Days   int              `json:"days"`
	Build  string           `json:"build,omitempty"`
	BuildB string           `json:"build_b,omitempty"`
	Rows   []perfSummaryRow `json:"rows"`
	RowsB  []perfSummaryRow `json:"rows_b,omitempty"`
}

func (s *Server) handlePerfSummary(w http.ResponseWriter, r *http.Request) {
	t, _, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	days, build, buildB, ok := perfSummaryQuery(w, r)
	if !ok {
		return
	}
	ps, ok := s.o.Store.(store.PerfSamples)
	if !ok {
		writeJSON(w, http.StatusOK, perfSummaryBody{Off: true, Days: days, Rows: []perfSummaryRow{}})
		return
	}
	since := s.o.Now().Add(-time.Duration(days) * 24 * time.Hour)
	rows, err := ps.PerfSummary(r.Context(), t.ID, since, build)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("perf summary")
		writeErr(w, http.StatusInternalServerError, "internal", "performance summary unavailable")
		return
	}
	body := perfSummaryBody{Days: days, Build: build, Rows: rankPerfSummary(rows)}
	if buildB != "" {
		var rowsB []store.PerfSummaryRow
		rowsB, err = ps.PerfSummary(r.Context(), t.ID, since, buildB)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("perf summary")
			writeErr(w, http.StatusInternalServerError, "internal", "performance summary unavailable")
			return
		}
		body.BuildB = buildB
		body.RowsB = rankPerfSummary(rowsB)
	}
	writeJSON(w, http.StatusOK, body)
}

// perfSummaryQuery reads days, build and build_b. ok=false: it answered.
func perfSummaryQuery(w http.ResponseWriter, r *http.Request) (int, string, string, bool) {
	q := r.URL.Query()
	days := perfSummaryDaysDefault
	if v := q.Get("days"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > perfSummaryDaysMax {
			writeErr(w, http.StatusBadRequest, "bad_query", "days is 1..30")
			return 0, "", "", false
		}
		days = n
	}
	build, buildB := strings.TrimSpace(q.Get("build")), strings.TrimSpace(q.Get("build_b"))
	if !perfSummaryBuildRe.MatchString(build) || !perfSummaryBuildRe.MatchString(buildB) {
		writeErr(w, http.StatusBadRequest, "bad_query", "build is a version token")
		return 0, "", "", false
	}
	return days, build, buildB, true
}

// rankPerfSummary orders by p75 descending (a group with no completed sample
// last) and drops p95 under n = 50. The store's own order (metric, device,
// view) stays as the tie-break.
func rankPerfSummary(in []store.PerfSummaryRow) []perfSummaryRow {
	sort.SliceStable(in, func(i, j int) bool {
		pi, pj := in[i].P75, in[j].P75
		if pi == nil || pj == nil {
			return pi != nil && pj == nil
		}
		return *pi > *pj
	})
	out := make([]perfSummaryRow, 0, len(in))
	for _, r := range in {
		row := perfSummaryRow{Metric: r.Metric, Device: r.Device, View: r.View,
			N: r.N, P50: r.P50, P75: r.P75, Failed: r.Failed}
		if r.N >= perfSummaryP95MinN {
			row.P95 = r.P95
		}
		out = append(out, row)
	}
	return out
}
