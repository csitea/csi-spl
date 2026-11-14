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
//	GET /v1/operator/zombie-topics?idle_days=<1..3650, default 7>&limit=<1..5000, default 500>&order=<oldest|newest, default oldest>&scope=<all|open, default all>
//	  200 {"as_of", "idle_days", "limit", "order", "scope", "idle_before", "topics": [{task_id, last_at}]}
//	  400 bad_query    idle_days or limit not a whole number in its range, order not oldest or newest, scope not all or open
//	  501 unsupported  the hub's store keeps no topic heads (the memory store)
//
// Who may: the fleet load doors (fleetLoadCaller): the operator workspace's
// admin or the operator service account; one tenant, the operator workspace.
// A topic is listed when (3.2 conditions 1, 2 and 6, store.ZombieTopics):
// its head is not card-archived, its latest line is older than idle_days, it
// is no DM thread and it has no topic_priorities row. Oldest first; order=newest
// lists the young end instead (spec 041 section 7, SPL-5520: the daily archive
// suggestion wants the topics that went quiet yesterday, and a backlog over
// the limit hid them behind a month of older heads). scope=open keeps only the
// topics any desk agent may post in (SPL-5520 R7 W4, store.zombieTopicsOpen):
// no #lobby, member-only, humans-only, AI-off or private-scope topic.

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
	Order      string              `json:"order"`
	Scope      string              `json:"scope"`
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

// GET /v1/operator/zombie-topics?idle_days=&limit=&order=&scope=
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
	order := r.URL.Query().Get("order")
	if order == "" {
		order = "oldest"
	}
	if order != "oldest" && order != "newest" {
		writeErr(w, http.StatusBadRequest, "bad_query", "order must be oldest or newest")
		return
	}
	scope := r.URL.Query().Get("scope")
	if scope == "" {
		scope = "all"
	}
	if scope != "all" && scope != "open" {
		writeErr(w, http.StatusBadRequest, "bad_query", "scope must be all or open")
		return
	}
	zl, ok := s.o.Store.(store.ZombieTopicLister)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no topic heads")
		return
	}
	now := s.o.Now().UTC()
	before := now.Add(-time.Duration(days) * 24 * time.Hour)
	topics, err := zl.ZombieTopics(r.Context(), tenant, before, limit, order == "newest", scope == "open")
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("zombie topics list")
		writeErr(w, http.StatusInternalServerError, "internal", "idle topics unavailable")
		return
	}
	writeJSON(w, http.StatusOK, zombieTopicsJSON{AsOf: now.Format(time.RFC3339), IdleDays: days, Limit: limit, Order: order, Scope: scope,
		IdleBefore: before.Format(time.RFC3339), Topics: topics})
}
