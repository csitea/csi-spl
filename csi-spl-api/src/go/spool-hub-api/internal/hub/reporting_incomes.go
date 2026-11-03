package hub

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Reporting -> Incomes (SPL-4697, rdb 0257, spec 143 incomes.md; owner
// HUM-10, csitea topic 450418ab msg e793f8d0): the workspace's invoiced
// income per month.
//
//	GET /v1/reporting/incomes?year=YYYY   the workspace OWNER only (TenantOwner,
//	                                      the embed_admin.go gate): {year, years,
//	                                      invoices}; no year = the newest year
//	                                      with rows (or this year)
//	PUT /v1/operator/incomes              the operator (fleetLoadCaller: the
//	                                      operator workspace's admin or the
//	                                      operator service account): {tenant,
//	                                      invoices} -> {inserted, updated}, an
//	                                      upsert by invoice number, all or none
//
// No figure is logged: the log lines carry the workspace and the counts only.

// incomeBodyMax bounds one import's body: IncomeInvoiceBatchMax rows.
const incomeBodyMax = 512 << 10

// incomeImport is the operator's PUT body.
type incomeImport struct {
	Tenant   string                `json:"tenant"`
	Invoices []store.IncomeInvoice `json:"invoices"`
}

func (s *Server) routeReportingIncomes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/reporting/incomes", s.handleReportingIncomes)
	mux.HandleFunc("OPTIONS /v1/reporting/incomes", s.preflight)
	mux.HandleFunc("PUT /v1/operator/incomes", s.handleOperatorIncomes)
	mux.HandleFunc("OPTIONS /v1/operator/incomes", s.operatorWorkspacesPreflight)
}

// incomeStore is the store's IncomeInvoiceStore; false = answered 501.
func (s *Server) incomeStore(w http.ResponseWriter) (store.IncomeInvoiceStore, bool) {
	ii, ok := s.o.Store.(store.IncomeInvoiceStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no income invoices")
	}
	return ii, ok
}

// GET /v1/reporting/incomes
func (s *Server) handleReportingIncomes(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if a, err := s.access(r.Context(), hum, t.ID); hum == "" || err != nil || !a.TenantOwner {
		writeForbidden(w, permTenantOwner, "only the workspace owner sees its incomes")
		return
	}
	ii, ok := s.incomeStore(w)
	if !ok {
		return
	}
	years, err := ii.IncomeYears(r.Context(), t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("reporting.incomes years")
		writeErr(w, http.StatusInternalServerError, "internal", "the incomes were not read")
		return
	}
	year := s.o.Now().UTC().Year()
	if len(years) > 0 {
		year = years[0]
	}
	if q := r.URL.Query().Get("year"); q != "" {
		y, err := strconv.Atoi(q)
		if err != nil || len(q) != 4 || y < 1900 || y > 9999 {
			writeErr(w, http.StatusBadRequest, "bad_year", "year must be YYYY")
			return
		}
		year = y
	}
	invoices, err := ii.ListIncomeInvoices(r.Context(), t.ID, year)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("reporting.incomes")
		writeErr(w, http.StatusInternalServerError, "internal", "the incomes were not read")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"year": year, "years": years, "invoices": invoices})
}

// PUT /v1/operator/incomes
func (s *Server) handleOperatorIncomes(w http.ResponseWriter, r *http.Request) {
	_, _, who, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return
	}
	ii, ok := s.incomeStore(w)
	if !ok {
		return
	}
	var body incomeImport
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, incomeBodyMax))
	if err == nil {
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		err = dec.Decode(&body)
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {tenant, invoices: [...]}: "+err.Error())
		return
	}
	if strings.TrimSpace(body.Tenant) == "" {
		writeErr(w, http.StatusBadRequest, "bad_income_invoice", "tenant is required")
		return
	}
	if _, err := s.o.Store.GetTenant(r.Context(), body.Tenant); err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "no workspace "+body.Tenant)
		return
	}
	if i, why := store.CheckIncomeInvoices(body.Invoices); why != "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad_income_invoice", "detail": why, "index": i})
		return
	}
	ins, upd, err := ii.UpsertIncomeInvoices(r.Context(), body.Tenant, body.Invoices)
	switch {
	case errors.Is(err, store.ErrIncomeInvoice):
		writeErr(w, http.StatusBadRequest, "bad_income_invoice", err.Error())
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", body.Tenant).Msg("operator.incomes")
		writeErr(w, http.StatusInternalServerError, "internal", "the incomes were not stored")
		return
	}
	s.o.Log.Info().Str("tenant", body.Tenant).Int("inserted", ins).Int("updated", upd).Str("by", who).Msg("incomes imported")
	writeJSON(w, http.StatusOK, map[string]int{"inserted": ins, "updated": upd})
}
