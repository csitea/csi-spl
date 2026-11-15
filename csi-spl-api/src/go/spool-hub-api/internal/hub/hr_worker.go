package hub

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The worker side of human costs (SPL-5433 step d, rdb 0285, spec 123 section
// 16.5; owner HUM-10, t1 2d974709, poll 2ff12c21 answer 4 B):
//
//	GET    /v1/operator/hr-worker-rates?year=YYYY                {year, rates: [store.HRWorkerRate]}
//	PUT    /v1/operator/hr-worker-rates/{year}/{kind}            {bands: [{age_from, age_to, rate_pct}], source} -> {year, kind, rates}
//	GET    /v1/operator/hr-tax-cards?year=YYYY                   {year, tax_cards: [store.HRTaxCard]}
//	PUT    /v1/operator/hr-tax-cards/{person_id}/{year}          {base_pct, extra_pct, income_limit, source} -> the card
//	DELETE /v1/operator/hr-tax-cards/{person_id}/{year}          -> 204
//	PUT    /v1/operator/hr-payslips/{month}/{person_id}          {currency, tyel_employee, unemployment_employee, tax_withheld, net_pay} -> the payslip
//	DELETE /v1/operator/hr-payslips/{month}/{person_id}?currency=EUR  -> 204
//
// The worker-share bands have the employer rates' doors. Tax cards and
// payslips are personal: only a member holding costs.write reads or writes
// them (readsHRNames, the names' rule), and GET /v1/operator/hr-payroll/{month}
// carries the worker side ("worker") for that caller only. A payslip of a
// closed month is 409 month_closed, as for a line. Nothing here writes a cost
// line: the worker side is part of the gross (owner Q5 A).

func (s *Server) routeHRWorker(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/hr-worker-rates", s.handleHRWorkerRatesList)
	mux.HandleFunc("PUT /v1/operator/hr-worker-rates/{year}/{kind}", s.handleHRWorkerRatesSet)
	mux.HandleFunc("GET /v1/operator/hr-tax-cards", s.handleHRTaxCardsList)
	mux.HandleFunc("PUT /v1/operator/hr-tax-cards/{person_id}/{year}", s.handleHRTaxCardSet)
	mux.HandleFunc("DELETE /v1/operator/hr-tax-cards/{person_id}/{year}", s.handleHRTaxCardDelete)
	mux.HandleFunc("PUT /v1/operator/hr-payslips/{month}/{person_id}", s.handleHRPayslipSet)
	mux.HandleFunc("DELETE /v1/operator/hr-payslips/{month}/{person_id}", s.handleHRPayslipDelete)
	mux.HandleFunc("OPTIONS /v1/operator/hr-worker-rates", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/hr-worker-rates/{year}/{kind}", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/hr-tax-cards", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/hr-tax-cards/{person_id}/{year}", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/hr-payslips/{month}/{person_id}", s.operatorWorkspacesPreflight)
}

// hrWorkerStore is the store's HRWorkerStore; false = answered 501.
func (s *Server) hrWorkerStore(w http.ResponseWriter) (store.HRWorkerStore, bool) {
	ws, ok := s.o.Store.(store.HRWorkerStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no worker side")
	}
	return ws, ok
}

// hrPersonalCaller is a costs.write member of the operator workspace behind
// gate (tax cards and payslips are theirs to read, like the names); false =
// answered.
func (s *Server) hrPersonalCaller(w http.ResponseWriter, r *http.Request, gate opCallerGate) (store.HRWorkerStore, string, bool) {
	_, actor, who, ok := s.hrCaller(w, r, gate, true)
	if !ok {
		return nil, "", false
	}
	if !s.readsHRNames(r, actor) {
		writeForbidden(w, rbac.CostsWrite, "only a member holding costs.write reads or enters tax cards and payslips")
		return nil, "", false
	}
	ws, ok := s.hrWorkerStore(w)
	return ws, who, ok
}

// hrQueryYear is the ?year= value, this year when empty; false = answered.
func (s *Server) hrQueryYear(w http.ResponseWriter, r *http.Request) (int, bool) {
	v := r.URL.Query().Get("year")
	if v == "" {
		v = strconv.Itoa(s.o.Now().Year())
	}
	return hrYear(w, v)
}

func (s *Server) handleHRWorkerRatesList(w http.ResponseWriter, r *http.Request) {
	if _, _, _, ok := s.hrCaller(w, r, s.operatorReadCaller, true); !ok {
		return
	}
	ws, ok := s.hrWorkerStore(w)
	if !ok {
		return
	}
	year, ok := s.hrQueryYear(w, r)
	if !ok {
		return
	}
	rates, err := ws.ListHRWorkerRates(r.Context(), year)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr worker rates")
		writeErr(w, http.StatusInternalServerError, "internal", "hr worker rates unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"year": year, "rates": rates})
}

// hrWorkerBand is one age band a caller sets.
type hrWorkerBand struct {
	AgeFrom int     `json:"age_from"`
	AgeTo   int     `json:"age_to"`
	RatePct float64 `json:"rate_pct"`
}

// hrWorkerRatesEdit is the body of a bands PUT.
type hrWorkerRatesEdit struct {
	Bands  []hrWorkerBand `json:"bands"`
	Source string         `json:"source"`
}

func (s *Server) handleHRWorkerRatesSet(w http.ResponseWriter, r *http.Request) {
	_, _, who, ok := s.hrCaller(w, r, s.operatorWriteCaller, true)
	if !ok {
		return
	}
	ws, ok := s.hrWorkerStore(w)
	if !ok {
		return
	}
	year, ok := hrYear(w, r.PathValue("year"))
	if !ok {
		return
	}
	var e hrWorkerRatesEdit
	if !decodeStrict(w, r, &e, "body must be {bands: [{age_from, age_to, rate_pct}], source}") {
		return
	}
	kind := r.PathValue("kind")
	bands := make([]store.HRWorkerRate, 0, len(e.Bands))
	for _, b := range e.Bands {
		bands = append(bands, store.HRWorkerRate{Year: year, Kind: kind, AgeFrom: b.AgeFrom, AgeTo: b.AgeTo, RatePct: b.RatePct, Source: e.Source, SetBy: who})
	}
	if why := store.CheckHRWorkerRates(year, kind, bands); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_hr_worker_rate", why)
		return
	}
	out, err := ws.SetHRWorkerRates(r.Context(), year, kind, bands)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr worker rates set")
		writeErr(w, http.StatusInternalServerError, "internal", "hr worker rates not stored")
		return
	}
	s.o.Log.Info().Int("year", year).Str("kind", kind).Int("bands", len(out)).Str("by", who).Msg("hr worker rates set")
	writeJSON(w, http.StatusOK, map[string]any{"year": year, "kind": kind, "rates": out})
}

func (s *Server) handleHRTaxCardsList(w http.ResponseWriter, r *http.Request) {
	ws, _, ok := s.hrPersonalCaller(w, r, s.operatorReadCaller)
	if !ok {
		return
	}
	year, ok := s.hrQueryYear(w, r)
	if !ok {
		return
	}
	cards, err := ws.ListHRTaxCards(r.Context(), year)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr tax cards")
		writeErr(w, http.StatusInternalServerError, "internal", "hr tax cards unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"year": year, "tax_cards": cards})
}

// hrTaxCardEdit is the fields a caller sets on a tax card.
type hrTaxCardEdit struct {
	BasePct     float64 `json:"base_pct"`
	ExtraPct    float64 `json:"extra_pct"`
	IncomeLimit float64 `json:"income_limit"`
	Source      string  `json:"source"`
}

func (s *Server) handleHRTaxCardSet(w http.ResponseWriter, r *http.Request) {
	ws, who, ok := s.hrPersonalCaller(w, r, s.operatorWriteCaller)
	if !ok {
		return
	}
	year, ok := hrYear(w, r.PathValue("year"))
	if !ok {
		return
	}
	var e hrTaxCardEdit
	if !decodeStrict(w, r, &e, "body must be {base_pct, extra_pct, income_limit, source}") {
		return
	}
	in := store.HRTaxCard{PersonID: r.PathValue("person_id"), Year: year, BasePct: e.BasePct, ExtraPct: e.ExtraPct,
		IncomeLimit: e.IncomeLimit, Source: e.Source, SetBy: who}
	if why := store.CheckHRTaxCard(in); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_hr_tax_card", why)
		return
	}
	out, err := ws.SetHRTaxCard(r.Context(), in)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such person")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("hr tax card set")
		writeErr(w, http.StatusInternalServerError, "internal", "hr tax card not stored")
		return
	}
	// The card's figures are personal: the log names who and which year only.
	s.o.Log.Info().Int("year", year).Str("by", who).Msg("hr tax card set")
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleHRTaxCardDelete(w http.ResponseWriter, r *http.Request) {
	ws, who, ok := s.hrPersonalCaller(w, r, s.operatorWriteCaller)
	if !ok {
		return
	}
	year, ok := hrYear(w, r.PathValue("year"))
	if !ok {
		return
	}
	err := ws.DeleteHRTaxCard(r.Context(), r.PathValue("person_id"), year)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no tax card for that person and "+strconv.Itoa(year))
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("hr tax card delete")
		writeErr(w, http.StatusInternalServerError, "internal", "hr tax card not deleted")
		return
	}
	s.o.Log.Info().Int("year", year).Str("by", who).Msg("hr tax card deleted")
	w.WriteHeader(http.StatusNoContent)
}

// hrPayslipEdit is the fields a caller sets on a payslip; a value left out
// is one the payslip does not carry.
type hrPayslipEdit struct {
	Currency             string   `json:"currency"`
	TyelEmployee         *float64 `json:"tyel_employee"`
	UnemploymentEmployee *float64 `json:"unemployment_employee"`
	TaxWithheld          *float64 `json:"tax_withheld"`
	NetPay               *float64 `json:"net_pay"`
}

func (s *Server) handleHRPayslipSet(w http.ResponseWriter, r *http.Request) {
	ws, who, ok := s.hrPersonalCaller(w, r, s.operatorWriteCaller)
	if !ok {
		return
	}
	month, ok := hrPayrollMonth(w, r)
	if !ok {
		return
	}
	var e hrPayslipEdit
	if !decodeStrict(w, r, &e, "body must be {currency, tyel_employee, unemployment_employee, tax_withheld, net_pay}") {
		return
	}
	if e.Currency == "" {
		e.Currency = "EUR"
	}
	in := store.HRPayslip{PersonID: r.PathValue("person_id"), Month: month, Currency: e.Currency, TyelEmployee: e.TyelEmployee,
		UnemploymentEmployee: e.UnemploymentEmployee, TaxWithheld: e.TaxWithheld, NetPay: e.NetPay, SetBy: who}
	if why := store.CheckHRPayslip(in); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_hr_payslip", why)
		return
	}
	if s.hrMonthClosed(w, r, store.CostEntry{Type: "hr", Period: month}) {
		return
	}
	out, err := ws.SetHRPayslip(r.Context(), in)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such person")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("hr payslip set")
		writeErr(w, http.StatusInternalServerError, "internal", "hr payslip not stored")
		return
	}
	s.o.Log.Info().Str("month", month).Str("by", who).Msg("hr payslip set")
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleHRPayslipDelete(w http.ResponseWriter, r *http.Request) {
	ws, who, ok := s.hrPersonalCaller(w, r, s.operatorWriteCaller)
	if !ok {
		return
	}
	month, ok := hrPayrollMonth(w, r)
	if !ok {
		return
	}
	currency := r.URL.Query().Get("currency")
	if currency == "" {
		currency = "EUR"
	}
	if s.hrMonthClosed(w, r, store.CostEntry{Type: "hr", Period: month}) {
		return
	}
	err := ws.DeleteHRPayslip(r.Context(), r.PathValue("person_id"), month, currency)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no payslip for that person, month and currency")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("hr payslip delete")
		writeErr(w, http.StatusInternalServerError, "internal", "hr payslip not deleted")
		return
	}
	s.o.Log.Info().Str("month", month).Str("by", who).Msg("hr payslip deleted")
	w.WriteHeader(http.StatusNoContent)
}

// hrWorkerOf is the worker side of p for a costs.write caller: the year's
// bands and cards, the month's payslips, and the year-to-date gross from the
// year's earlier monthly hr lines.
func (s *Server) hrWorkerOf(r *http.Request, hs store.HRCostStore, p store.HRPayroll) ([]store.HRWorkerSide, error) {
	ws, ok := s.o.Store.(store.HRWorkerStore)
	ce, ok2 := s.o.Store.(store.CostEntryStore)
	if !ok || !ok2 {
		return nil, errors.New("store keeps no worker side or cost entries")
	}
	people, err := hs.ListHRPeople(r.Context(), false)
	if err != nil {
		return nil, err
	}
	comps, err := hs.ListHRComponents(r.Context())
	if err != nil {
		return nil, err
	}
	all, err := ce.ListCostEntries(r.Context(), "hr", "")
	if err != nil {
		return nil, err
	}
	rates, err := ws.ListHRWorkerRates(r.Context(), p.Year)
	if err != nil {
		return nil, err
	}
	cards, err := ws.ListHRTaxCards(r.Context(), p.Year)
	if err != nil {
		return nil, err
	}
	slips, err := ws.ListHRPayslips(r.Context(), p.Month)
	if err != nil {
		return nil, err
	}
	return store.ComputeHRWorker(p, people, store.HRYearToDate(p.Month, all, comps), rates, cards, slips), nil
}
