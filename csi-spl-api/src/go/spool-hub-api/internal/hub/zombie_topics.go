package hub

import (
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The idle topic heads of the operator workspace (spec 166 v0.3 section 3.2,
// build row B5, SPL-4323; owner HUM-10, prd t1 5d1c5023, poll d102c775 Q1 A
// = 7 idle days, Q3 A = at most 500 a night): the candidates the night's
// zombie sweep (row B6, a box action) checks against asks, lanes and issues
// before it archives one. Read only: this route archives nothing.
//
//	GET /v1/operator/zombie-topics?idle_days=<1..3650, default 7>&limit=<1..5000, default 500>
//	  200 {"as_of", "idle_days", "limit", "idle_before", "topics": [{task_id, last_at}]}
//	  400 bad_query    idle_days or limit not a whole number in its range
//	  501 unsupported  the hub's store keeps no topic heads (the memory store)
//
// Who may: the fleet load doors (fleetLoadCaller): the operator workspace's
// admin or the operator service account; one tenant, the operator workspace.
// A topic is listed when (3.2 conditions 1, 2 and 6, store.ZombieTopics):
// its head is not card-archived, its latest line is older than idle_days, it
// is no DM thread and it has no topic_priorities row. Oldest first.

const (
	zombieIdleDaysDefault = 7
	zombieIdleDaysMax     = 3650
	zombieLimitDefault    = 500
	zombieLimitMax        = 5000
)

type zombieTopicsJSON struct {
	AsOf       string              `json:"as_of"`
	IdleDays   int                 `json:"idle_days"`
	Limit      int                 `json:"limit"`
	IdleBefore string              `json:"idle_before"`
	Topics     []store.ZombieTopic `json:"topics"`
}

func (s *Server) routeZombieTopics(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/zombie-topics", s.handleZombieTopics)
	mux.HandleFunc("OPTIONS /v1/operator/zombie-topics", s.operatorWorkspacesPreflight)
}

// zombieQueryInt reads a whole number in 1..hi, def when the key is absent.
func zombieQueryInt(r *http.Request, key string, def, hi int) (int, bool) {
	v := r.URL.Query().Get(key)
	if v == "" {
		return def, true
	}
	n, err := strconv.Atoi(v)
	return n, err == nil && n >= 1 && n <= hi
}

// GET /v1/operator/zombie-topics?idle_days=&limit=
func (s *Server) handleZombieTopics(w http.ResponseWriter, r *http.Request) {
	tenant, _, _, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return
	}
	days, ok := zombieQueryInt(r, "idle_days", zombieIdleDaysDefault, zombieIdleDaysMax)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_query", "idle_days must be a whole number of days, 1..3650")
		return
	}
	limit, ok := zombieQueryInt(r, "limit", zombieLimitDefault, zombieLimitMax)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_query", "limit must be a whole number, 1..5000")
		return
	}
	zl, ok := s.o.Store.(store.ZombieTopicLister)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no topic heads")
		return
	}
	now := s.o.Now().UTC()
	before := now.Add(-time.Duration(days) * 24 * time.Hour)
	topics, err := zl.ZombieTopics(r.Context(), tenant, before, limit)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("zombie topics list")
		writeErr(w, http.StatusInternalServerError, "internal", "idle topics unavailable")
		return
	}
	writeJSON(w, http.StatusOK, zombieTopicsJSON{AsOf: now.Format(time.RFC3339), IdleDays: days, Limit: limit,
		IdleBefore: before.Format(time.RFC3339), Topics: topics})
}
