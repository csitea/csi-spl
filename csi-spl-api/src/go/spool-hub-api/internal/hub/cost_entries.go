package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Cloud infra and HR costs typed on the Expenses page (SPL-4383, rdb 0245;
// owner HUM-10, t1 4f48f878 msg b0ccc0aa). The doors of GET
// /v1/operator/fleet-tokens (fleetLoadCaller: the operator workspace's admin
// or the operator service account; the GET also its product owner,
// operator_read.go; a write never a live act-as clone, operator_write.go):
//
//	GET    /v1/operator/cost-entries?type=cloud|hr&month=YYYY-MM
//	                                        {entries: [store.PricedCostEntry]}:
//	                                        each in USD and EUR too (SPL-5198);
//	                                        an absent filter matches every row
//	POST   /v1/operator/cost-entries        {type, label, amount, currency,
//	                                         period: YYYY-MM, note?} -> 201 the entry
//	DELETE /v1/operator/cost-entries/{id}   -> 204
//
// AI costs are the paid items of fleet_token_paid.go, not these.
//
// costs.write opens all three to a member of the OPERATOR workspace who holds
// it (the two accountant roles, spec 123 16, SPL-5359), never a live act-as
// clone: costEntryGate. The rows are the estate's, so a holder in any other
// workspace gets the operator gate's answer.

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

// costEntryRate is the entries' rates, the paid items' (FleetPaidFXRate);
// none on a store without them.
func (s *Server) costEntryRate() store.CostEntryRate {
	if fx, ok := s.o.Store.(store.FleetPaidStore); ok {
		return fx.FleetPaidFXRate
	}
	return func(context.Context, string, string) (float64, string, bool, error) { return 0, "", false, nil }
}

// costEntryGate is base, or a member of the operator workspace holding
// costs.write who is not a live act-as clone (SPL-5359). A bearer call, a
// member of another workspace and a member without costs.write get base's
// answer.
func (s *Server) costEntryGate(base opCallerGate) opCallerGate {
	return func(w http.ResponseWriter, r *http.Request) (string, *opActor, string, bool) {
		if strings.HasPrefix(strings.TrimSpace(r.Header.Get("Authorization")), "Bearer ") {
			return base(w, r)
		}
		op, err := s.operatorTenant(r.Context())
		if err != nil || op == "" {
			return base(w, r)
		}
		t, hum, ok := s.humanTenant(w, r)
		if !ok {
			return "", nil, "", false
		}
		if hum != "" && t.ID == op {
			a, err := s.access(r.Context(), hum, t.ID)
			if err == nil && a.Can(rbac.CostsWrite) && !s.readerIsActAsClone(r.Context(), t.ID, hum) {
				s.allowOrigin(w, r)
				w.Header().Set("Cache-Control", "no-store")
				return t.ID, &opActor{tenant: t.ID, hum: hum}, hum, true
			}
		}
		return base(w, r)
	}
}

// costEntryCaller is the gate plus the store; who called, false = answered.
func (s *Server) costEntryCaller(w http.ResponseWriter, r *http.Request, gate opCallerGate) (store.CostEntryStore, string, bool) {
	_, _, who, ok := s.costEntryGate(gate)(w, r)
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
	ce, _, ok := s.costEntryCaller(w, r, s.operatorReadCaller)
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
	var priced []store.PricedCostEntry
	if err == nil {
		priced, err = store.PriceCostEntries(r.Context(), entries, s.costEntryRate())
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost entry list")
		writeErr(w, http.StatusInternalServerError, "internal", "cost entries unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": priced})
}

func (s *Server) handleCostEntryCreate(w http.ResponseWriter, r *http.Request) {
	ce, who, ok := s.costEntryCaller(w, r, s.operatorWriteCaller)
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
	ce, who, ok := s.costEntryCaller(w, r, s.operatorWriteCaller)
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
