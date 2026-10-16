package hub

import (
	"encoding/json"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The exchange rates of the costs' second currency (SPL-2108, rdb 0200):
//
//	POST /v1/operator/fx/rates     the box feed: {rows: [{day, quote, rate,
//	                               source}]}, rate = quote units per USD,
//	                               source ECB | FED, as do_spl_fx_rates_fetch
//	                               (csi-spl-orc) read the two banks. Operator
//	                               auth only (operatorAuth), like every
//	                               /v1/operator write. An UPSERT per (day,
//	                               quote, source): a re-post is a no-op.
//	GET  /v1/tenant/fx/currencies  any signed-in member: the currencies a
//	                               second currency may be (the quotes the hub
//	                               holds a rate for) and the default, EUR. The
//	                               WUI's personal-settings picker reads it.

// fxRatesBodyMax bounds one post (store.FXRatesMax rows of ~70 bytes).
const fxRatesBodyMax = 2 << 20

type fxRatesBody struct {
	Rows []store.FXRate `json:"rows"`
}

func (s *Server) routeFXRates(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/fx/rates", s.handleFXRatesPut)
	mux.HandleFunc("GET /v1/tenant/fx/currencies", s.handleFXCurrencies)
	mux.HandleFunc("OPTIONS /v1/tenant/fx/currencies", s.preflight)
}

func (s *Server) handleFXRatesPut(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	fx, ok := s.o.Store.(store.FX)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "fx_off", "this hub's store keeps no exchange rates")
		return
	}
	var body fxRatesBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, fxRatesBodyMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {rows: [{day, quote, rate, source}]}: "+err.Error())
		return
	}
	if why := store.CheckFXRates(body.Rows); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_fx_rates", why)
		return
	}
	n, err := fx.PutFXRates(r.Context(), body.Rows)
	if err != nil {
		s.o.Log.Error().Err(err).Int("rows", len(body.Rows)).Msg("fx.rates_failed")
		writeErr(w, http.StatusServiceUnavailable, "internal", "exchange rates not stored")
		return
	}
	s.o.Log.Info().Int("rows", len(body.Rows)).Int("written", n).Msg("fx.rates_stored")
	writeJSON(w, http.StatusOK, map[string]any{"rows": len(body.Rows), "written": n})
}

func (s *Server) handleFXCurrencies(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if _, _, ok := s.humanTenant(w, r); !ok {
		return
	}
	out := map[string]any{"default": store.DefaultSecondCurrency, "currencies": []string{}}
	if fx, ok := s.o.Store.(store.FX); ok {
		cs, err := fx.FXCurrencies(r.Context())
		if err != nil {
			s.o.Log.Error().Err(err).Msg("fx.currencies_failed")
			writeErr(w, http.StatusServiceUnavailable, "unavailable", "the currencies were not read")
			return
		}
		out["currencies"] = cs
	}
	writeJSON(w, http.StatusOK, out)
}
