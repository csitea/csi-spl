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

// The Cloud infra and HR costs typed on the Expenses page (SPL-4383, rdb 0245;
// owner HUM-10, t1 4f48f878 msg b0ccc0aa). The doors of GET
// /v1/operator/fleet-tokens (fleetLoadCaller: the operator workspace's admin
// or the operator service account):
//
//	GET    /v1/operator/cost-entries?type=cloud|hr&month=YYYY-MM
//	                                        {entries: [store.CostEntry]}; an
//	                                        absent filter matches every row
//	POST   /v1/operator/cost-entries        {type, label, amount, currency,
//	                                         period: YYYY-MM, note?} -> 201 the entry
//	DELETE /v1/operator/cost-entries/{id}   -> 204
//
// AI costs are the paid items of fleet_token_paid.go, not these.

// costEntryBodyMax bounds one entry's body (a 2000-character note and change).
const costEntryBodyMax = 16 << 10

// costEntryEdit is the fields a caller sets; the hub sets id and the stamps.
type costEntryEdit struct {
	Type     string  `json:"type"`
	Label    string  `json:"label"`
	Amount   float64 `json:"amount"`
	Currency string  `json:"currency"`
	Period   string  `json:"period"`
	Note     string  `json:"note"`
}

func (s *Server) routeCostEntries(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/cost-entries", s.handleCostEntryList)
	mux.HandleFunc("POST /v1/operator/cost-entries", s.handleCostEntryCreate)
	mux.HandleFunc("DELETE /v1/operator/cost-entries/{id}", s.handleCostEntryDelete)
	mux.HandleFunc("OPTIONS /v1/operator/cost-entries", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/cost-entries/{id}", s.operatorWorkspacesPreflight)
}

// costEntryCaller is fleetLoadCaller plus the store; who called, false = answered.
func (s *Server) costEntryCaller(w http.ResponseWriter, r *http.Request) (store.CostEntryStore, string, bool) {
	_, _, who, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return nil, "", false
	}
	ce, ok := s.o.Store.(store.CostEntryStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no cost entries")
		return nil, "", false
	}
	return ce, who, true
}

func (s *Server) handleCostEntryList(w http.ResponseWriter, r *http.Request) {
	ce, _, ok := s.costEntryCaller(w, r)
	if !ok {
		return
	}
	typ, month := r.URL.Query().Get("type"), r.URL.Query().Get("month")
	if typ != "" && !slices.Contains(store.CostEntryTypes, typ) {
		writeErr(w, http.StatusBadRequest, "bad_cost_entry", "type must be cloud or hr")
		return
	}
	if month != "" && !store.IsCostMonth(month) {
		writeErr(w, http.StatusBadRequest, "bad_cost_entry", "month must be YYYY-MM")
		return
	}
	entries, err := ce.ListCostEntries(r.Context(), typ, month)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost entry list")
		writeErr(w, http.StatusInternalServerError, "internal", "cost entries unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries})
}

func (s *Server) handleCostEntryCreate(w http.ResponseWriter, r *http.Request) {
	ce, who, ok := s.costEntryCaller(w, r)
	if !ok {
		return
	}
	var e costEntryEdit
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, costEntryBodyMax))
	if err == nil {
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		err = dec.Decode(&e)
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {type, label, amount, currency, period, note}: "+err.Error())
		return
	}
	in := store.CostEntry{Type: e.Type, Label: e.Label, Amount: e.Amount, Currency: e.Currency, Period: e.Period, Note: e.Note, CreatedBy: who}
	if why := store.CheckCostEntry(in); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_cost_entry", why)
		return
	}
	out, err := ce.CreateCostEntry(r.Context(), in)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost entry create")
		writeErr(w, http.StatusInternalServerError, "internal", "cost entry not stored")
		return
	}
	s.o.Log.Info().Str("id", out.ID).Str("type", out.Type).Str("by", who).Msg("cost entry created")
	writeJSON(w, http.StatusCreated, out)
}

func (s *Server) handleCostEntryDelete(w http.ResponseWriter, r *http.Request) {
	ce, who, ok := s.costEntryCaller(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	err := ce.DeleteCostEntry(r.Context(), id)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no cost entry "+id)
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("cost entry delete")
		writeErr(w, http.StatusInternalServerError, "internal", "cost entry not deleted")
		return
	}
	s.o.Log.Info().Str("id", id).Str("by", who).Msg("cost entry deleted")
	w.WriteHeader(http.StatusNoContent)
}
