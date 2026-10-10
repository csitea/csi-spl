package hub

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The box feed of cost tracking (spec 123 sections 4.3 and 4.6, build lane 4):
//
//	POST /v1/operator/cost/day   one source's rows of one UTC day, as a box's
//	                             cost-source factory read them (csi-spl-orc
//	                             spl-cost-source.func.sh), and its coverage.
//
// Operator auth only (operatorAuth: a Google id token of the env's service
// account), like every /v1/operator write. The rows are estate rows
// (tenant_id NULL): fleet tokens (origin transcript) and agent-seconds
// (origin agent_run), counts and never prices. The store UPSERTs them on the
// rdb 0166 natural key, so a re-post of a day is a no-op, and writes the
// day's cost_coverage row. Cost data is the owner's only (HUM-10, msg
// 02803231): the answer and the log carry counts, never a row or an amount.

// costIngestBodyMax bounds one day of one source (store.CostIngestLinesMax
// lines of a few hundred bytes).
const costIngestBodyMax = 4 << 20

type costIngestBody struct {
	Day      string `json:"day"`
	Source   string `json:"source"`
	RunID    string `json:"run_id"`
	Coverage struct {
		State  string `json:"state"`
		Reason string `json:"reason"`
	} `json:"coverage"`
	Lines []store.CostLine `json:"lines"`
}

func (s *Server) routeCostIngest(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/cost/day", s.handleCostIngest)
}

func (s *Server) handleCostIngest(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.operatorAuth(w, r); !ok {
		return
	}
	ci, ok := s.o.Store.(store.CostIngest)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "cost_ingest_off", "this hub's store keeps no cost lines")
		return
	}
	var body costIngestBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, costIngestBodyMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {day, source, run_id, coverage: {state, reason}, lines: [...]}: "+err.Error())
		return
	}
	d := store.CostDay{Day: body.Day, Source: body.Source, RunID: strings.TrimSpace(body.RunID),
		State: body.Coverage.State, Reason: strings.TrimSpace(body.Coverage.Reason), Lines: body.Lines}
	if why := store.CheckCostDay(d); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_cost_day", why)
		return
	}
	res, err := ci.PutCostDay(r.Context(), d)
	if err != nil {
		s.o.Log.Error().Err(err).Str("source", d.Source).Str("day", d.Day).Int("lines", len(d.Lines)).Msg("cost.ingest_failed")
		writeErr(w, http.StatusServiceUnavailable, "internal", "cost day not stored")
		return
	}
	s.o.Log.Info().Str("source", d.Source).Str("day", d.Day).Str("state", d.State).
		Int("lines", len(d.Lines)).Int("written", res.Written).Int("removed", res.Removed).Msg("cost.ingested")
	writeJSON(w, http.StatusOK, map[string]any{"day": d.Day, "source": d.Source, "state": d.State,
		"lines": len(d.Lines), "written": res.Written, "removed": res.Removed})
}
