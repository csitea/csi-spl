package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// POST /v1/perf/samples: the WUI's perceived-performance samples (spec 066
// section 4), fire-and-forget (section 4.0, owner Q4: "if for some reason the
// logging doesn't work, it should not mess with the whole thing").
//
// The handler validates, enqueues into a bounded channel and answers BEFORE
// any database work; ONE writer goroutine inserts the queue, each insert under
// its own perfInsertTimeout, so the ingest holds at most one store connection
// at a time and never one a member route waits on. A full queue, a session
// over its hourly cap or a store error drops the samples and counts them; the
// ingest never answers 5xx because of storage.
//
// Body (text/plain JSON, a CORS-safelisted type: no preflight):
//
//	{"samples": [store.PerfSample, ...], "dropped": <n the tab dropped>}
//
// The tenant comes from the session and at is the hub's receive time: a body
// "tenant_id" or "at" (top level or per sample) is ignored. Any other field
// the contract does not name is refused (spec 4.2: no user id, email, url,
// message id, text ...).
//
// Answers (the choice, from spec 4 table + 4.0): 202 {"hub_ms": <epoch ms>}
// when the samples were queued (hub_ms is M4's clock offset); 204 when they
// were dropped (full queue, session cap, a store without PerfSamples); 400 on
// a body the contract refuses. Neither 202 nor 204 waits on the store.

// Perf ingest limits.
const (
	perfQueueCap          = 256 // queued requests; a full queue drops
	perfInsertTimeout     = 2 * time.Second
	perfSessionCapPerHour = 300         // spec 4 sampling: samples per tab per hour
	perfSessionsMax       = 50000       // tracked sessions; more resets the window
	perfBodyMax           = 256 << 10   // 500 samples are ~100 KB
	perfErrLogEvery       = time.Minute // a drop is logged at most this often
)

var errPerfPanic = errors.New("perf insert panicked")

// perfJob is one request's accepted samples, stamped and checked.
type perfJob struct {
	tenant string
	rows   []store.PerfSample
}

// perfIngest is a Server's queue, writer and counters.
type perfIngest struct {
	s     *Server
	ps    store.PerfSamples // nil = the store keeps none: every POST drops
	queue chan perfJob
	start sync.Once

	mu       sync.Mutex
	winStart time.Time
	perSess  map[string]int // tenant + "/" + session_id -> samples this window
	logged   time.Time

	queued, stored, dropFull, dropCap, dropStore, dropClient atomic.Int64
}

// routePerfIngest mounts POST /v1/perf/samples (spec 066 L2).
func (s *Server) routePerfIngest(mux *http.ServeMux) {
	pi := &perfIngest{s: s, queue: make(chan perfJob, perfQueueCap), perSess: map[string]int{}}
	pi.ps, _ = s.o.Store.(store.PerfSamples)
	mux.HandleFunc("POST /v1/perf/samples", pi.handle)
	mux.HandleFunc("OPTIONS /v1/perf/samples", s.perfPreflight)
}

// perfWireSample is store.PerfSample on the wire, plus the two fields a
// client may send and the hub ignores (the shallower "at" wins).
type perfWireSample struct {
	store.PerfSample
	At       json.RawMessage `json:"at"`
	TenantID json.RawMessage `json:"tenant_id"`
}

type perfWireBody struct {
	Samples  []perfWireSample `json:"samples"`
	Dropped  int              `json:"dropped"`
	At       json.RawMessage  `json:"at"`
	TenantID json.RawMessage  `json:"tenant_id"`
}

func (pi *perfIngest) handle(w http.ResponseWriter, r *http.Request) {
	s := pi.s
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "perf samples need a signed-in member session")
		return
	}
	rows, dropped, why := decodePerfBody(w, r, s.o.Now().UTC())
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_json", why)
		return
	}
	pi.dropClient.Add(int64(dropped))
	if pi.ps == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if rows = pi.underCap(t.ID, rows); len(rows) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	pi.start.Do(func() { go pi.write() })
	select {
	case pi.queue <- perfJob{tenant: t.ID, rows: rows}:
		pi.queued.Add(int64(len(rows)))
		writeJSON(w, http.StatusAccepted, map[string]int64{"hub_ms": s.o.Now().UnixMilli()})
	default:
		pi.dropFull.Add(int64(len(rows)))
		pi.logDrop("queue full")
		w.WriteHeader(http.StatusNoContent)
	}
}

// decodePerfBody is the request's samples stamped with at, or why the body is
// refused. No samples is fine (a tab reporting its drops only).
func decodePerfBody(w http.ResponseWriter, r *http.Request, at time.Time) ([]store.PerfSample, int, string) {
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(http.MaxBytesReader(w, r.Body, perfBodyMax)); err != nil {
		return nil, 0, "body too large"
	}
	var body perfWireBody
	dec := json.NewDecoder(&buf)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		return nil, 0, "body must be {samples: [...], dropped: n}: " + err.Error()
	}
	if len(body.Samples) > store.PerfBatchMax {
		return nil, 0, "at most 500 samples per request"
	}
	if body.Dropped < 0 {
		return nil, 0, "dropped must be >= 0"
	}
	rows := make([]store.PerfSample, 0, len(body.Samples))
	for _, ws := range body.Samples {
		p := ws.PerfSample
		p.At = at
		if why := store.CheckPerfSample(p); why != "" {
			return nil, 0, why
		}
		rows = append(rows, p)
	}
	return rows, body.Dropped, ""
}

// underCap keeps the samples each (tenant, session) may still send this hour
// (spec 4 sampling: 300 per tab per hour) and counts the rest as dropped.
func (pi *perfIngest) underCap(tenant string, rows []store.PerfSample) []store.PerfSample {
	now := pi.s.o.Now()
	pi.mu.Lock()
	defer pi.mu.Unlock()
	if now.Sub(pi.winStart) >= time.Hour || len(pi.perSess) > perfSessionsMax {
		pi.winStart, pi.perSess = now, map[string]int{}
	}
	kept := rows[:0]
	for _, p := range rows {
		k := tenant + "/" + p.SessionID
		if pi.perSess[k] >= perfSessionCapPerHour {
			pi.dropCap.Add(1)
			continue
		}
		pi.perSess[k]++
		kept = append(kept, p)
	}
	return kept
}

// write is the one writer: each queued batch in one insert under its own
// timeout, never the request's context (that answer is long gone).
func (pi *perfIngest) write() {
	for job := range pi.queue {
		ctx, cancel := context.WithTimeout(context.Background(), perfInsertTimeout)
		err := pi.insert(ctx, job)
		cancel()
		if err != nil {
			pi.dropStore.Add(int64(len(job.rows)))
			pi.logDrop("store: " + err.Error())
			continue
		}
		pi.stored.Add(int64(len(job.rows)))
	}
}

// insert recovers a store panic too: a broken insert never takes the hub down.
func (pi *perfIngest) insert(ctx context.Context, job perfJob) (err error) {
	defer func() {
		if recover() != nil {
			err = errPerfPanic
		}
	}()
	return pi.ps.InsertPerfSamples(ctx, job.tenant, job.rows)
}

// logDrop logs a drop with the counters, at most once per perfErrLogEvery.
func (pi *perfIngest) logDrop(why string) {
	now := pi.s.o.Now()
	pi.mu.Lock()
	if !pi.logged.IsZero() && now.Sub(pi.logged) < perfErrLogEvery {
		pi.mu.Unlock()
		return
	}
	pi.logged = now
	pi.mu.Unlock()
	pi.s.o.Log.Warn().Str("why", why).
		Int64("queued", pi.queued.Load()).Int64("stored", pi.stored.Load()).
		Int64("drop_full", pi.dropFull.Load()).Int64("drop_cap", pi.dropCap.Load()).
		Int64("drop_store", pi.dropStore.Load()).Int64("drop_client", pi.dropClient.Load()).
		Msg("wui perf samples dropped")
}

// perfPreflight: a fetch with Content-Type application/json needs one; the
// text/plain beacon does not.
func (s *Server) perfPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
