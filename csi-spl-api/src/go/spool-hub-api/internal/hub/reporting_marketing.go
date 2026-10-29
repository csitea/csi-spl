package hub

import (
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Reporting Marketing tab (spec 163 v0.2 G5, build row B1, SPL-4250;
// owner HUM-10, csitea topic b13f7763, poll 337fb605, msg 449350b3):
//
//	GET /v1/reporting/marketing
//	  200 {"as_of", "attribution": {"rule", "window_days"}, "stages": [id],
//	       "samples": [...], "definitions": [...]}
//	  403 forbidden  a member who is neither the workspace's owner nor an admin
//
// Q8 ("B — Workspace admins and the owner only"): the hub's own pair,
// TenantOwner || Has(rbac.Admin), as the Lanes view; hiding the tab in the
// WUI is not the control, this check is. samples is the newest sample per
// key of the workspace's G1 store, definitions the newest version of each
// metric's G2 definition (store/marketing_metrics.go); both are empty until
// a connector row (B3..B16) writes them. attribution is the Q7 default every
// definition starts from. stages is the card order of the tab, the overview's
// order of spec 163 section 2.

const permReportingMarketing = "reporting.marketing"

// marketingStages are spec 163 section 2.1..2.7, one card each.
var marketingStages = []string{"reach", "engagement", "acquisition", "conversion", "revenue", "retention", "content_seo"}

type marketingAttributionJSON struct {
	Rule       string `json:"rule"`
	WindowDays int    `json:"window_days"`
}

type reportingMarketingJSON struct {
	AsOf        string                            `json:"as_of"`
	Attribution marketingAttributionJSON          `json:"attribution"`
	Stages      []string                          `json:"stages"`
	Samples     []store.MarketingMetricSample     `json:"samples"`
	Definitions []store.MarketingMetricDefinition `json:"definitions"`
}

func (s *Server) routeReportingMarketing(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/reporting/marketing", s.handleReportingMarketing)
	mux.HandleFunc("OPTIONS /v1/reporting/marketing", s.preflight)
}

// GET /v1/reporting/marketing
func (s *Server) handleReportingMarketing(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if hum == "" {
		writeForbidden(w, permReportingMarketing, "the marketing report needs a signed-in member session")
		return
	}
	if a, err := s.access(r.Context(), hum, t.ID); err != nil || !(a.TenantOwner || a.Has(rbac.Admin)) {
		writeForbidden(w, permReportingMarketing, "only the workspace owner or an admin sees the marketing numbers")
		return
	}
	mm, ok := s.o.Store.(store.MarketingMetrics)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no marketing metrics")
		return
	}
	read, err := mm.ReadMarketingMetrics(r.Context(), t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("reporting.marketing")
		writeErr(w, http.StatusInternalServerError, "internal", "the marketing metrics were not read")
		return
	}
	writeJSON(w, http.StatusOK, reportingMarketingJSON{
		AsOf:        s.o.Now().UTC().Format(time.RFC3339),
		Attribution: marketingAttributionJSON{Rule: store.MarketingAttributionLastTouch, WindowDays: store.MarketingAttributionWindowDays},
		Stages:      marketingStages,
		Samples:     read.Samples,
		Definitions: read.Definitions,
	})
}
