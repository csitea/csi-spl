package hub

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The employer side of human costs (SPL-5433 step c, rdb 0284, spec 123
// section 16.4; owner HUM-10, t1 2d974709, poll 2ff12c21 answer 4 B):
//
//	GET    /v1/operator/hr-rates?year=YYYY            {year, rates: [store.HRRate]}
//	PUT    /v1/operator/hr-rates/{year}/{component}   {rate_pct, applies_to, source} -> the rate
//	DELETE /v1/operator/hr-rates/{year}/{component}   -> 204
//	GET    /v1/operator/hr-payroll/{month}            store.HRPayroll + {period}
//	POST   /v1/operator/hr-payroll/{month}/book       {booked, removed, payroll}
//
// The reads have the hr reads' doors, the writes the cost entries' (an
// accountant holding costs.write, or the operator admin). Book writes the
// computed amounts as hr lines (source "computed: <year> rates") so the cost
// reports carry the employer side, and first removes the month's booked lines
// it replaces; a typed line is never touched. A closed month is 409
// month_closed, as for a typed line.

func (s *Server) routeHRPayroll(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/hr-rates", s.handleHRRatesList)
	mux.HandleFunc("PUT /v1/operator/hr-rates/{year}/{component}", s.handleHRRateSet)
	mux.HandleFunc("DELETE /v1/operator/hr-rates/{year}/{component}", s.handleHRRateDelete)
	mux.HandleFunc("GET /v1/operator/hr-payroll/{month}", s.handleHRPayroll)
	mux.HandleFunc("POST /v1/operator/hr-payroll/{month}/book", s.handleHRPayrollBook)
	mux.HandleFunc("OPTIONS /v1/operator/hr-rates", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/hr-rates/{year}/{component}", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/hr-payroll/{month}", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/hr-payroll/{month}/book", s.operatorWorkspacesPreflight)
}

// hrRateStore is the store's HRRateStore; false = answered 501.
func (s *Server) hrRateStore(w http.ResponseWriter) (store.HRRateStore, bool) {
	rs, ok := s.o.Store.(store.HRRateStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no hr rates")
	}
	return rs, ok
}

// hrYear parses a year 2000..2100; false = answered 400.
func hrYear(w http.ResponseWriter, v string) (int, bool) {
	y, err := strconv.Atoi(v)
	if err != nil || y < 2000 || y > 2100 {
		writeErr(w, http.StatusBadRequest, "bad_hr_rate", "year must be YYYY, 2000..2100")
		return 0, false
	}
	return y, true
}

func (s *Server) handleHRRatesList(w http.ResponseWriter, r *http.Request) {
	if _, _, _, ok := s.hrCaller(w, r, s.operatorReadCaller, true); !ok {
		return
	}
	rs, ok := s.hrRateStore(w)
	if !ok {
		return
	}
	v := r.URL.Query().Get("year")
	if v == "" {
		v = strconv.Itoa(s.o.Now().Year())
	}
	year, ok := hrYear(w, v)
	if !ok {
		return
	}
	rates, err := rs.ListHRRates(r.Context(), year)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr rates")
		writeErr(w, http.StatusInternalServerError, "internal", "hr rates unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"year": year, "rates": rates})
}

// hrRateEdit is the fields a caller sets on a rate.
type hrRateEdit struct {
	RatePct   float64  `json:"rate_pct"`
	AppliesTo []string `json:"applies_to"`
	Source    string   `json:"source"`
}

func (s *Server) handleHRRateSet(w http.ResponseWriter, r *http.Request) {
	hs, _, who, ok := s.hrCaller(w, r, s.operatorWriteCaller, true)
	if !ok {
		return
	}
	rs, ok := s.hrRateStore(w)
	if !ok {
		return
	}
	year, ok := hrYear(w, r.PathValue("year"))
	if !ok {
		return
	}
	var e hrRateEdit
	if !decodeStrict(w, r, &e, "body must be {rate_pct, applies_to, source}") {
		return
	}
	if len(e.AppliesTo) == 0 {
		e.AppliesTo = []string{"employee", "hourly"}
	}
	comps, err := hs.ListHRComponents(r.Context())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr components")
		writeErr(w, http.StatusInternalServerError, "internal", "hr components unavailable")
		return
	}
	in := store.HRRate{Year: year, Component: r.PathValue("component"), RatePct: e.RatePct, AppliesTo: e.AppliesTo, Source: e.Source, SetBy: who}
	if why := store.CheckHRRate(in, comps); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_hr_rate", why)
		return
	}
	out, err := rs.SetHRRate(r.Context(), in)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr rate set")
		writeErr(w, http.StatusInternalServerError, "internal", "hr rate not stored")
		return
	}
	s.o.Log.Info().Int("year", year).Str("component", out.Component).Float64("rate_pct", out.RatePct).Str("by", who).Msg("hr rate set")
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleHRRateDelete(w http.ResponseWriter, r *http.Request) {
	_, _, who, ok := s.hrCaller(w, r, s.operatorWriteCaller, true)
	if !ok {
		return
	}
	rs, ok := s.hrRateStore(w)
	if !ok {
		return
	}
	year, ok := hrYear(w, r.PathValue("year"))
	if !ok {
		return
	}
	comp := r.PathValue("component")
	err := rs.DeleteHRRate(r.Context(), year, comp)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no "+comp+" rate for "+strconv.Itoa(year))
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("hr rate delete")
		writeErr(w, http.StatusInternalServerError, "internal", "hr rate not deleted")
		return
	}
	s.o.Log.Info().Int("year", year).Str("component", comp).Str("by", who).Msg("hr rate deleted")
	w.WriteHeader(http.StatusNoContent)
}

// hrPayrollOf computes month's payroll from the stores; the month's lines
// come back too (book removes from them). An error is the caller's 500.
func (s *Server) hrPayrollOf(r *http.Request, hs store.HRCostStore, month string) (store.HRPayroll, []store.CostEntry, error) {
	ce, ok := s.o.Store.(store.CostEntryStore)
	rs, ok2 := s.o.Store.(store.HRRateStore)
	if !ok || !ok2 {
		return store.HRPayroll{}, nil, errors.New("store keeps no cost entries or hr rates")
	}
	people, err := hs.ListHRPeople(r.Context(), false)
	if err != nil {
		return store.HRPayroll{}, nil, err
	}
	comps, err := hs.ListHRComponents(r.Context())
	if err != nil {
		return store.HRPayroll{}, nil, err
	}
	lines, err := ce.ListCostEntries(r.Context(), "hr", month)
	if err != nil {
		return store.HRPayroll{}, nil, err
	}
	year, _ := strconv.Atoi(month[:4])
	rates, err := rs.ListHRRates(r.Context(), year)
	if err != nil {
		return store.HRPayroll{}, nil, err
	}
	return store.ComputeHRPayroll(month, people, lines, rates, comps), lines, nil
}

// hrPayrollMonth reads the {month} path value; false = answered 400.
func hrPayrollMonth(w http.ResponseWriter, r *http.Request) (string, bool) {
	month := r.PathValue("month")
	if !store.IsCostMonth(month) {
		writeErr(w, http.StatusBadRequest, "bad_cost_period", "month must be YYYY-MM")
		return "", false
	}
	return month, true
}

func (s *Server) handleHRPayroll(w http.ResponseWriter, r *http.Request) {
	hs, _, _, ok := s.hrCaller(w, r, s.operatorReadCaller, true)
	if !ok {
		return
	}
	month, ok := hrPayrollMonth(w, r)
	if !ok {
		return
	}
	p, _, err := s.hrPayrollOf(r, hs, month)
	var period store.CostPeriod
	if err == nil {
		period, err = hs.CostPeriodState(r.Context(), month, s.o.Now())
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr payroll")
		writeErr(w, http.StatusInternalServerError, "internal", "hr payroll unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"month": p.Month, "year": p.Year, "rates": p.Rates, "people": p.People,
		"totals": p.Totals, "flags": p.Flags, "period": period})
}

func (s *Server) handleHRPayrollBook(w http.ResponseWriter, r *http.Request) {
	hs, _, who, ok := s.hrCaller(w, r, s.operatorWriteCaller, true)
	if !ok {
		return
	}
	month, ok := hrPayrollMonth(w, r)
	if !ok {
		return
	}
	if s.hrMonthClosed(w, r, store.CostEntry{Type: "hr", Period: month}) {
		return
	}
	p, lines, err := s.hrPayrollOf(r, hs, month)
	var comps []store.HRComponent
	if err == nil {
		comps, err = hs.ListHRComponents(r.Context())
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr payroll book")
		writeErr(w, http.StatusInternalServerError, "internal", "hr payroll unavailable")
		return
	}
	ce := s.o.Store.(store.CostEntryStore)
	bs := store.HRBookings(p)
	removed := 0
	for _, id := range store.HRStaleBooked(month, lines, p, bs) {
		if err := ce.DeleteCostEntry(r.Context(), id); err != nil && !errors.Is(err, store.ErrNotFound) {
			s.o.Log.Error().Err(err).Msg("hr payroll book: remove")
			writeErr(w, http.StatusInternalServerError, "internal", "booked lines not replaced")
			return
		}
		removed++
	}
	label, account := map[string]string{}, map[string]string{}
	for _, c := range comps {
		label[c.Component], account[c.Component] = c.Label, c.DefaultAccount
	}
	source := store.HRComputedSource + " " + month[:4] + " rates"
	booked := 0
	for _, b := range bs {
		e := store.CostEntry{Type: "hr", Label: label[b.Component], Amount: b.Amount, Currency: b.Currency, Period: month,
			CreatedBy: who, PersonID: b.PersonID, Component: b.Component, Source: source, Account: account[b.Component], PeriodKind: "month"}
		if why := store.CheckCostEntry(e); why != "" {
			s.o.Log.Error().Str("why", why).Str("component", b.Component).Msg("hr payroll book: line refused")
			continue
		}
		if _, err := ce.CreateCostEntry(r.Context(), e); err != nil {
			s.o.Log.Error().Err(err).Msg("hr payroll book: create")
			writeErr(w, http.StatusInternalServerError, "internal", "computed lines not booked")
			return
		}
		booked++
	}
	p, _, err = s.hrPayrollOf(r, hs, month)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr payroll book")
		writeErr(w, http.StatusInternalServerError, "internal", "hr payroll unavailable")
		return
	}
	s.o.Log.Info().Str("month", month).Int("booked", booked).Int("removed", removed).Str("by", who).Msg("hr payroll booked")
	writeJSON(w, http.StatusOK, map[string]any{"booked": booked, "removed": removed, "payroll": p})
}
