package hub

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// What the operator PAID for the fleet's AI vendors, and the effective price
// per token it makes (SPL-2342, rdb 0205; owner HUM-10, t1 e8ae0aad msg
// 9f549412). The doors of GET /v1/operator/fleet-tokens (fleetLoadCaller:
// the operator workspace's admin or the operator service account):
//
//	GET    /v1/operator/fleet-tokens/paid        {items: [store.FleetPaidItem]}
//	POST   /v1/operator/fleet-tokens/paid        {vendor, kind, plan_label, quantity?, amount,
//	                                              currency, period_start, period_end, note?}
//	                                              -> 201 the item
//	PATCH  /v1/operator/fleet-tokens/paid/{id}   the same fields, an absent one kept -> the item
//	DELETE /v1/operator/fleet-tokens/paid/{id}   -> 204
//	GET    /v1/operator/fleet-tokens/effective?from=YYYY-MM-DD&to=YYYY-MM-DD
//	                                              -> store.FleetPaidEffectiveResponse
//
// The effective price is a sibling read, not a field of the fleet-tokens
// read: that one is polled every few seconds over minutes of the last 24 h;
// this one spans whole paid periods (the daily rollups, up to a year) and the
// exchange rates, a heavier read the page asks for once. Each vendor row
// still carries the list-price cost of the same days beside it.

// fleetPaidBodyMax bounds one item's body (a 2000-character note and change).
const fleetPaidBodyMax = 16 << 10

// fleetPaidEdit is the fields a caller sets; the hub sets id and the stamps.
type fleetPaidEdit struct {
	Vendor      string  `json:"vendor"`
	Kind        string  `json:"kind"`
	PlanLabel   string  `json:"plan_label"`
	Quantity    int     `json:"quantity"`
	Amount      float64 `json:"amount"`
	Currency    string  `json:"currency"`
	PeriodStart string  `json:"period_start"`
	PeriodEnd   string  `json:"period_end"`
	Note        string  `json:"note"`
}

func (s *Server) routeFleetPaid(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/fleet-tokens/paid", s.handleFleetPaidList)
	mux.HandleFunc("POST /v1/operator/fleet-tokens/paid", s.handleFleetPaidCreate)
	mux.HandleFunc("PATCH /v1/operator/fleet-tokens/paid/{id}", s.handleFleetPaidUpdate)
	mux.HandleFunc("DELETE /v1/operator/fleet-tokens/paid/{id}", s.handleFleetPaidDelete)
	mux.HandleFunc("GET /v1/operator/fleet-tokens/effective", s.handleFleetPaidEffective)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-tokens/paid", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-tokens/paid/{id}", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/fleet-tokens/effective", s.operatorWorkspacesPreflight)
}

// fleetPaidCaller is fleetLoadCaller plus the store; who called, false = answered.
func (s *Server) fleetPaidCaller(w http.ResponseWriter, r *http.Request) (store.FleetPaidStore, string, bool) {
	_, _, who, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return nil, "", false
	}
	fp, ok := s.o.Store.(store.FleetPaidStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no paid items")
		return nil, "", false
	}
	return fp, who, true
}

func (s *Server) handleFleetPaidList(w http.ResponseWriter, r *http.Request) {
	fp, _, ok := s.fleetPaidCaller(w, r)
	if !ok {
		return
	}
	items, err := fp.ListPaidItems(r.Context())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet paid list")
		writeErr(w, http.StatusInternalServerError, "internal", "paid items unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// decodeFleetPaid reads the body onto e (its absent fields keep e's values)
// and checks the result; false = answered.
func (s *Server) decodeFleetPaid(w http.ResponseWriter, r *http.Request, e *fleetPaidEdit) bool {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, fleetPaidBodyMax))
	if err == nil {
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		err = dec.Decode(e)
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {vendor, kind, plan_label, quantity, amount, currency, period_start, period_end, note}: "+err.Error())
		return false
	}
	if why := store.CheckFleetPaidItem(e.item()); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_paid_item", why)
		return false
	}
	return s.knownCurrency(w, r, e.Currency)
}

func (e fleetPaidEdit) item() store.FleetPaidItem {
	return store.FleetPaidItem{Vendor: e.Vendor, Kind: e.Kind, PlanLabel: e.PlanLabel, Quantity: e.Quantity, Amount: e.Amount,
		Currency: e.Currency, PeriodStart: e.PeriodStart, PeriodEnd: e.PeriodEnd, Note: e.Note}
}

// knownCurrency: USD, or a quote the hub holds a rate for (rdb 0200), so the
// effective price can convert it; false = answered.
func (s *Server) knownCurrency(w http.ResponseWriter, r *http.Request, c string) bool {
	if c == "USD" {
		return true
	}
	var known []string
	if fx, ok := s.o.Store.(store.FX); ok {
		cs, err := fx.FXCurrencies(r.Context())
		if err != nil {
			s.o.Log.Error().Err(err).Msg("fleet paid currencies")
			writeErr(w, http.StatusServiceUnavailable, "unavailable", "the currencies were not read")
			return false
		}
		known = cs
	}
	if !slices.Contains(known, c) {
		writeErr(w, http.StatusBadRequest, "bad_paid_item", "currency must be USD or one the hub holds an exchange rate for")
		return false
	}
	return true
}

func (s *Server) handleFleetPaidCreate(w http.ResponseWriter, r *http.Request) {
	fp, who, ok := s.fleetPaidCaller(w, r)
	if !ok {
		return
	}
	e := fleetPaidEdit{Quantity: 1}
	if !s.decodeFleetPaid(w, r, &e) {
		return
	}
	it := e.item()
	it.CreatedBy = who
	out, err := fp.CreatePaidItem(r.Context(), it)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet paid create")
		writeErr(w, http.StatusInternalServerError, "internal", "paid item not stored")
		return
	}
	s.o.Log.Info().Str("id", out.ID).Str("vendor", out.Vendor).Str("by", who).Msg("fleet paid item created")
	writeJSON(w, http.StatusCreated, out)
}

// fleetPaidByID is item {id}; false = answered (404 when there is none).
func (s *Server) fleetPaidByID(w http.ResponseWriter, r *http.Request, fp store.FleetPaidStore) (store.FleetPaidItem, bool) {
	items, err := fp.ListPaidItems(r.Context())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet paid read")
		writeErr(w, http.StatusInternalServerError, "internal", "paid items unavailable")
		return store.FleetPaidItem{}, false
	}
	id := r.PathValue("id")
	for _, it := range items {
		if it.ID == id {
			return it, true
		}
	}
	writeErr(w, http.StatusNotFound, "not_found", "no paid item "+id)
	return store.FleetPaidItem{}, false
}

func (s *Server) handleFleetPaidUpdate(w http.ResponseWriter, r *http.Request) {
	fp, who, ok := s.fleetPaidCaller(w, r)
	if !ok {
		return
	}
	old, ok := s.fleetPaidByID(w, r, fp)
	if !ok {
		return
	}
	e := fleetPaidEdit{Vendor: old.Vendor, Kind: old.Kind, PlanLabel: old.PlanLabel, Quantity: old.Quantity, Amount: old.Amount,
		Currency: old.Currency, PeriodStart: old.PeriodStart, PeriodEnd: old.PeriodEnd, Note: old.Note}
	if !s.decodeFleetPaid(w, r, &e) {
		return
	}
	it := e.item()
	it.ID = old.ID
	out, err := fp.UpdatePaidItem(r.Context(), it)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no paid item "+old.ID)
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("fleet paid update")
		writeErr(w, http.StatusInternalServerError, "internal", "paid item not stored")
		return
	}
	s.o.Log.Info().Str("id", out.ID).Str("by", who).Msg("fleet paid item updated")
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleFleetPaidDelete(w http.ResponseWriter, r *http.Request) {
	fp, who, ok := s.fleetPaidCaller(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	err := fp.DeletePaidItem(r.Context(), id)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no paid item "+id)
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("fleet paid delete")
		writeErr(w, http.StatusInternalServerError, "internal", "paid item not deleted")
		return
	}
	s.o.Log.Info().Str("id", id).Str("by", who).Msg("fleet paid item deleted")
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/operator/fleet-tokens/effective?from=&to=
func (s *Server) handleFleetPaidEffective(w http.ResponseWriter, r *http.Request) {
	fp, _, ok := s.fleetPaidCaller(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	from, to, why := store.FleetPaidWindow(q.Get("from"), q.Get("to"), s.o.Now())
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_query", why)
		return
	}
	ctx := r.Context()
	items, err := fp.ListPaidItems(ctx)
	var days []store.FleetVendorDay
	if err == nil {
		days, err = fp.FleetVendorDays(ctx, from, to)
	}
	rates := map[[2]string]fleetPaidRate{}
	for _, it := range items {
		if k := [2]string{it.Currency, it.PeriodStart}; err == nil && it.Currency != "USD" {
			var fr fleetPaidRate
			fr.rate, fr.day, fr.ok, err = fp.FleetPaidFXRate(ctx, it.Currency, it.PeriodStart)
			rates[k] = fr
		}
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("fleet paid effective")
		writeErr(w, http.StatusInternalServerError, "internal", "effective price unavailable")
		return
	}
	writeJSON(w, http.StatusOK, store.FleetPaidEffective(items, days, from, to, func(it store.FleetPaidItem) (float64, string, bool) {
		fr := rates[[2]string{it.Currency, it.PeriodStart}]
		return fr.rate, fr.day, fr.ok
	}))
}

// fleetPaidRate is one looked-up conversion of the effective read.
type fleetPaidRate struct {
	rate float64
	day  string
	ok   bool
}
