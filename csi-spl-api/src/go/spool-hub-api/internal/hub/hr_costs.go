package hub

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Human costs per person and component, and the month lock (SPL-5433, rdb
// 0280, spec 123 section 16.2; owner HUM-10, t1 2d974709, polls a82c0089 and
// 2ff12c21):
//
//	GET  /v1/operator/hr-components             {components: [store.HRComponent]}
//	GET  /v1/operator/hr-people                 {people: [store.HRPerson], names: bool}
//	                                            the real names only to a member
//	                                            holding costs.write (the
//	                                            accountants, the admin)
//	POST /v1/operator/hr-people                 {code, name, department,
//	                                             employment_type, birth_year?,
//	                                             left_on?} -> 201 the person
//	GET  /v1/operator/cost-periods/{month}      store.CostPeriod at now
//	POST /v1/operator/cost-periods/{month}/close             -> the state
//	POST /v1/operator/cost-periods/{month}/reopen {reason}   -> the state
//
// The reads and the person write have the cost entries' doors
// (costEntryGate). Close and reopen are the operator admin's alone
// (operatorWriteCaller): an accountant books, the admin unlocks. An hr cost
// line created or deleted in a closed month is 409 month_closed
// (cost_entries.go); a late correction goes into the open month with
// corrects_period.

func (s *Server) routeHRCosts(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/hr-components", s.handleHRComponents)
	mux.HandleFunc("GET /v1/operator/hr-people", s.handleHRPeopleList)
	mux.HandleFunc("POST /v1/operator/hr-people", s.handleHRPersonCreate)
	mux.HandleFunc("GET /v1/operator/cost-periods/{month}", s.handleCostPeriodGet)
	mux.HandleFunc("POST /v1/operator/cost-periods/{month}/close", s.handleCostPeriodClose)
	mux.HandleFunc("POST /v1/operator/cost-periods/{month}/reopen", s.handleCostPeriodReopen)
	mux.HandleFunc("OPTIONS /v1/operator/hr-components", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/hr-people", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/cost-periods/{month}", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/cost-periods/{month}/close", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/cost-periods/{month}/reopen", s.operatorWorkspacesPreflight)
}

func (s *Server) handleCostPeriodClose(w http.ResponseWriter, r *http.Request) {
	s.handleCostPeriodSet(w, r, "close")
}

func (s *Server) handleCostPeriodReopen(w http.ResponseWriter, r *http.Request) {
	s.handleCostPeriodSet(w, r, "reopen")
}

// hrCaller is gate (wrapped by costEntryGate when costs = true) plus the hr
// store; the actor (nil = the service account), false = answered.
func (s *Server) hrCaller(w http.ResponseWriter, r *http.Request, gate opCallerGate, costs bool) (store.HRCostStore, *opActor, string, bool) {
	if costs {
		gate = s.costEntryGate(gate)
	}
	_, actor, who, ok := gate(w, r)
	if !ok {
		return nil, nil, "", false
	}
	hs, ok := s.o.Store.(store.HRCostStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no hr costs")
		return nil, nil, "", false
	}
	return hs, actor, who, true
}

// readsHRNames is whether actor may read the real names: a member of the
// operator workspace holding costs.write (the gates already refused an
// act-as clone). The service account never reads them.
func (s *Server) readsHRNames(r *http.Request, actor *opActor) bool {
	if actor == nil || actor.hum == "" {
		return false
	}
	a, err := s.access(r.Context(), actor.hum, actor.tenant)
	return err == nil && a.Can(rbac.CostsWrite)
}

func (s *Server) handleHRComponents(w http.ResponseWriter, r *http.Request) {
	hs, _, _, ok := s.hrCaller(w, r, s.operatorReadCaller, true)
	if !ok {
		return
	}
	cs, err := hs.ListHRComponents(r.Context())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr components")
		writeErr(w, http.StatusInternalServerError, "internal", "hr components unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"components": cs})
}

func (s *Server) handleHRPeopleList(w http.ResponseWriter, r *http.Request) {
	hs, actor, _, ok := s.hrCaller(w, r, s.operatorReadCaller, true)
	if !ok {
		return
	}
	names := s.readsHRNames(r, actor)
	ps, err := hs.ListHRPeople(r.Context(), names)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("hr people")
		writeErr(w, http.StatusInternalServerError, "internal", "hr people unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"people": ps, "names": names})
}

// hrPersonEdit is the fields a caller sets on a person.
type hrPersonEdit struct {
	Code           string `json:"code"`
	Name           string `json:"name"`
	Department     string `json:"department"`
	EmploymentType string `json:"employment_type"`
	BirthYear      int    `json:"birth_year"`
	LeftOn         string `json:"left_on"`
}

func (s *Server) handleHRPersonCreate(w http.ResponseWriter, r *http.Request) {
	hs, actor, who, ok := s.hrCaller(w, r, s.operatorWriteCaller, true)
	if !ok {
		return
	}
	if !s.readsHRNames(r, actor) {
		writeForbidden(w, rbac.CostsWrite, "only a member holding costs.write enters a person (the name is theirs to read)")
		return
	}
	var e hrPersonEdit
	if !decodeStrict(w, r, &e, "body must be {code, name, department, employment_type, birth_year, left_on}") {
		return
	}
	in := store.HRPerson{Code: e.Code, Name: e.Name, Department: e.Department, EmploymentType: e.EmploymentType, BirthYear: e.BirthYear, LeftOn: e.LeftOn, CreatedBy: who}
	if why := store.CheckHRPerson(in); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_hr_person", why)
		return
	}
	out, err := hs.CreateHRPerson(r.Context(), in)
	switch {
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "code_taken", "a person already has code "+in.Code)
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("hr person create")
		writeErr(w, http.StatusInternalServerError, "internal", "person not stored")
		return
	}
	// never the name in a log line
	s.o.Log.Info().Str("id", out.ID).Str("code", out.Code).Str("by", who).Msg("hr person created")
	writeJSON(w, http.StatusCreated, out)
}

func (s *Server) handleCostPeriodGet(w http.ResponseWriter, r *http.Request) {
	hs, _, _, ok := s.hrCaller(w, r, s.operatorReadCaller, true)
	if !ok {
		return
	}
	month := r.PathValue("month")
	if !store.IsCostMonth(month) {
		writeErr(w, http.StatusBadRequest, "bad_cost_period", "month must be YYYY-MM")
		return
	}
	p, err := hs.CostPeriodState(r.Context(), month, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost period")
		writeErr(w, http.StatusInternalServerError, "internal", "cost period unavailable")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func (s *Server) handleCostPeriodSet(w http.ResponseWriter, r *http.Request, op string) {
	hs, _, who, ok := s.hrCaller(w, r, s.operatorWriteCaller, false)
	if !ok {
		return
	}
	month := r.PathValue("month")
	if !store.IsCostMonth(month) {
		writeErr(w, http.StatusBadRequest, "bad_cost_period", "month must be YYYY-MM")
		return
	}
	var body struct {
		Reason string `json:"reason"`
	}
	if op == "reopen" {
		if !decodeStrict(w, r, &body, "body must be {reason}") {
			return
		}
		if strings.TrimSpace(body.Reason) == "" || len(body.Reason) > 500 {
			writeErr(w, http.StatusBadRequest, "bad_cost_period", "a reopen needs a reason of 1..500 characters")
			return
		}
	}
	p, err := hs.SetCostPeriod(r.Context(), month, op == "close", who, body.Reason, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost period set")
		writeErr(w, http.StatusInternalServerError, "internal", "cost period not changed")
		return
	}
	s.o.Log.Info().Str("month", month).Str("op", op).Str("by", who).Str("reason", body.Reason).Msg("cost period " + op)
	writeJSON(w, http.StatusOK, p)
}

// decodeStrict reads a JSON body of at most costEntryBodyMax into v, unknown
// fields refused; false = answered 400 with usage.
func decodeStrict(w http.ResponseWriter, r *http.Request, v any, usage string) bool {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, costEntryBodyMax))
	if err == nil {
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		err = dec.Decode(v)
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", usage+": "+err.Error())
		return false
	}
	return true
}

// hrMonthClosed answers 409 when e is an hr line whose lock month is closed
// at now; true = answered (or failed, answered 500).
func (s *Server) hrMonthClosed(w http.ResponseWriter, r *http.Request, e store.CostEntry) bool {
	hs, ok := s.o.Store.(store.HRCostStore)
	if e.Type != "hr" || !ok {
		return false
	}
	month := store.CostLockMonth(e)
	p, err := hs.CostPeriodState(r.Context(), month, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost period")
		writeErr(w, http.StatusInternalServerError, "internal", "cost period unavailable")
		return true
	}
	if p.Closed {
		writeErr(w, http.StatusConflict, "month_closed", "the month "+month+" is closed; enter a correction in an open month (corrects_period), or ask the operator admin to reopen it")
		return true
	}
	return false
}

// hrLineRefs answers 400 when e names a person or a component the store does
// not hold; true = answered.
func (s *Server) hrLineRefs(w http.ResponseWriter, r *http.Request, e store.CostEntry) bool {
	hs, ok := s.o.Store.(store.HRCostStore)
	if !ok || (e.PersonID == "" && e.Component == "") {
		return false
	}
	if e.PersonID != "" {
		ps, err := hs.ListHRPeople(r.Context(), false)
		found := false
		for _, p := range ps {
			found = found || p.ID == e.PersonID
		}
		if err != nil || !found {
			writeErr(w, http.StatusBadRequest, "bad_cost_entry", "no person "+e.PersonID)
			return true
		}
	}
	if e.Component != "" {
		cs, err := hs.ListHRComponents(r.Context())
		found := false
		for _, c := range cs {
			found = found || c.Component == e.Component
		}
		if err != nil || !found {
			writeErr(w, http.StatusBadRequest, "bad_cost_entry", "no hr component "+e.Component)
			return true
		}
	}
	return false
}
