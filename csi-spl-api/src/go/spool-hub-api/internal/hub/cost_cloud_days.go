package hub

import (
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Cloud section's day drill-down (SPL-4187, owner HUM-10, t1 e2c0e6b4
// msg 8c7f4962: "the first level by gcp project of the cloud costs, than
// there should be drill down by service etc."). GET /v1/tenant/costs gives
// the first two levels (its gcp parts, per project and service); this
// route is the third, one project's month per day and service:
//
//	GET /v1/tenant/costs/cloud?month=YYYY-MM&project=<project_or_vendor>
//
// The GCP projects are the ESTATE's: the operator workspace's admin reads
// them, as in the month read; every other member reads 403. month is the
// month read's (default the current UTC month so far, a future one 400).
// Each day carries usd_micros and eur_micros (what was paid) and
// second_micros (the USD at that day's rate in the caller's second
// currency, null with no rate on or before the day, never a guess).

type costCloudDaysBody struct {
	Month    string               `json:"month"`
	Project  string               `json:"project"`
	Currency string               `json:"second_currency"`
	Days     []store.CostCloudDay `json:"days"`
}

func (s *Server) routeCostCloudDays(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/tenant/costs/cloud", s.handleCostCloudDays)
	mux.HandleFunc("OPTIONS /v1/tenant/costs/cloud", s.preflight)
}

// GET /v1/tenant/costs/cloud?month=YYYY-MM&project=<project_or_vendor>
func (s *Server) handleCostCloudDays(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.CostsRead)
	if !ok {
		return
	}
	cr, ok := s.o.Store.(store.CostCloudDaysRead)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no cost lines")
		return
	}
	op, err := s.operatorTenant(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return
	}
	if op == "" || t.ID != op || !a.Has(rbac.Admin) {
		writeErr(w, http.StatusForbidden, "forbidden", "the cloud costs are the estate's: the operator workspace's admin only")
		return
	}
	win, why := costWindow(r.URL.Query().Get("month"), s.o.Now())
	q := store.CostCloudDaysQuery{Project: r.URL.Query().Get("project"), From: win.From, To: win.To}
	if why == "" {
		why = store.CheckCostCloudDaysQuery(q)
	}
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_query", why)
		return
	}
	if q.Currency, err = s.secondCurrency(r.Context(), a.HumanID, t.ID); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("cost.cloud_currency_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "your second currency was not read")
		return
	}
	days, err := cr.CostCloudDays(r.Context(), q)
	if err != nil {
		s.o.Log.Error().Err(err).Str("month", win.Month).Msg("cost.cloud_days_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "cloud cost days unavailable")
		return
	}
	writeJSON(w, http.StatusOK, costCloudDaysBody{Month: win.Month, Project: q.Project, Currency: q.Currency, Days: days})
}
