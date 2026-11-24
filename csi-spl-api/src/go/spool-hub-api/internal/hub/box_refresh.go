package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 071 7.3 steps 4-6 and 7.6.2 (SPL-6239 row T5): the hub half of
// "refresh now". The instance that takes a click announces one request per
// asked box on the store's box sample channel (store.BoxSampleWaker, row
// T4); EVERY instance keeps it in its pending map (request id -> tenant,
// box, deadline) until its deadline. The
// instance that holds that box's role=box socket, with the hello feature
// box_sample, writes it a box_sample frame; a box that says hello on any
// instance inside the deadline gets the frame then (the 5-minute socket
// roll), after it none. The box's box_sample_put is stored only against a
// pending request of that (tenant, box) inside its deadline. The route, its
// limits and the wait (row T6) build on askBoxSample.

// errBoxSampleUnsupported: the store cannot announce a box sample request.
var errBoxSampleUnsupported = errors.New("this hub's store carries no box sample requests")

// boxSampleReq is one pending request: the asked (tenant, box), its
// deadline, and the session it was last written to (one frame per socket,
// whichever of the announce and the hello catch-up gets there first).
type boxSampleReq struct {
	tenant, box string
	deadline    time.Time
	sentTo      *session
}

// boxSamples is the pending map, request id -> its request, and the wake-up
// of this instance's Refresh waits (stored); its own lock.
type boxSamples struct {
	mu     sync.Mutex
	m      map[string]*boxSampleReq
	stored chan struct{}
}

// put keeps request req and drops every request past its deadline.
func (p *boxSamples) put(req string, r *boxSampleReq, now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.m == nil {
		p.m = map[string]*boxSampleReq{}
	}
	for k, v := range p.m {
		if now.After(v.deadline) {
			delete(p.m, k)
		}
	}
	p.m[req] = r
}

// claimSend returns the ids of the pending requests of x's box that x may
// get a frame for: inside their deadline and not yet written to x. It marks
// them sent to x, so the announce and the hello catch-up never write one
// twice to one socket.
func (p *boxSamples) claimSend(x *session, now time.Time) []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	var out []string
	for req, r := range p.m {
		if r.tenant == x.tenant && r.box == x.box && !now.After(r.deadline) && r.sentTo != x {
			r.sentTo = x
			out = append(out, req)
		}
	}
	return out
}

// take drops and reports the pending request req when it was asked of
// (tenant, box) and is inside its deadline; an unknown id, another box's
// or an expired one takes nothing.
func (p *boxSamples) take(tenant, box, req string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	r := p.m[req]
	if r == nil || r.tenant != tenant || r.box != box || now.After(r.deadline) {
		return false
	}
	delete(p.m, req)
	return true
}

// askBoxSample mints a request id for (tenant, box) and announces it to
// every hub instance, this one too; the instance holding the box's socket
// writes the frame. Row T6 calls it once per asked box.
func (s *Server) askBoxSample(ctx context.Context, tenant, box string, deadline time.Time) (string, error) {
	w, ok := s.o.Store.(store.BoxSampleWaker)
	if !ok {
		return "", errBoxSampleUnsupported
	}
	req := uid.New()
	return req, w.AnnounceBoxSample(ctx, store.BoxSampleReq{Tenant: tenant, Box: box, ReqID: req, Deadline: deadline})
}

// onBoxSampleReq is the box sample listener of RunWake: keep the request,
// and write the frame when this instance holds the box's socket. It never
// blocks the listen connection: the write runs on its own goroutine.
func (s *Server) onBoxSampleReq(r store.BoxSampleReq) {
	now := s.o.Now()
	if now.After(r.Deadline) {
		return
	}
	s.samples.put(r.ReqID, &boxSampleReq{tenant: r.Tenant, box: r.Box, deadline: r.Deadline}, now)
	if x := s.heldBox(r.Tenant, r.Box); x != nil {
		go s.sendBoxSample(context.Background(), x)
	}
}

// sendBoxSample writes x its box's pending box_sample frames, once each, when x
// is a role=box socket whose hello carried FeatureBoxSample: an old binary
// is never asked (spec 071 7.6.1). Called on an announce and after a
// role=box hello (the catch-up).
func (s *Server) sendBoxSample(ctx context.Context, x *session) {
	if x.role != wire.RoleBox || !slices.Contains(x.features, wire.FeatureBoxSample) {
		return
	}
	for _, req := range s.samples.claimSend(x, s.o.Now()) {
		if err := x.write(ctx, wire.Frame{Type: wire.TBoxSample, MsgID: req}); err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("box_sample frame not written")
		}
	}
}

// onBoxSamplePut stores a box's answer (spec 071 7.3 step 6): only for a
// request this instance holds for the session's (tenant, box), inside its
// deadline. Box and WriterBox are the session's box, At the hub's clock
// (7.6.1). Fire and forget: a refused sample is logged, never answered.
func (s *Server) onBoxSamplePut(ctx context.Context, x *session, f wire.Frame) {
	bs, ok := s.o.Store.(store.BoxStats)
	if x.role != wire.RoleBox || !ok {
		s.refuseBoxSample(x, f.MsgID, "not a role=box socket, or no box stats store")
		return
	}
	if !s.samples.take(x.tenant, x.box, f.MsgID, s.o.Now()) {
		s.refuseBoxSample(x, f.MsgID, "unknown request id or past its deadline")
		return
	}
	var b store.BoxStat
	dec := json.NewDecoder(bytes.NewReader(f.Lane))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		s.refuseBoxSample(x, f.MsgID, "lane must be one box stat object")
		return
	}
	b.At, b.Box, b.WriterBox = s.o.Now(), x.box, x.box
	if why := store.CheckBoxStat(b); why != "" {
		s.refuseBoxSample(x, f.MsgID, why)
		return
	}
	if err := bs.AppendBoxStat(ctx, x.tenant, b); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("box sample append")
		return
	}
	s.samples.signalStored()
}

// refuseBoxSample logs a box_sample_put the hub does not store, with why.
func (s *Server) refuseBoxSample(x *session, req, why string) {
	s.o.Log.Warn().Str("tenant", x.tenant).Str("box", x.box).Str("req", req).Str("why", why).Msg("box_sample_put refused")
}

// ---- the Refresh route (spec 071 7.3 steps 2-3 and 7, 7.5, 7.6.2; row T6) ----
//
//	POST /v1/tenant/box-stats/refresh   {} = every box the page lists, or {"box": "<id>"}
//	-> {asked_at, wait_ms, boxes: [{box, state, row}]}
//
// tenant.settings (biz_owner, admin; 7.5). The asked set is every pinned box
// of the workspace (Store.ViewBoxes, so a pin whose box announced no agents
// is asked too, W1/W3) minus a revoked pin, box-wui and the boxes the
// box-owner lock hides from the caller; a box whose newest sample is younger
// than MinAge is not asked and reads recent. One request per asked box,
// announced through askBoxSample (row T5); a box that already has a pending
// request on this instance (any instance's announce reaches every one) is
// not asked again but waited on. The hub then reads box_stats every 250 ms,
// and at once when this instance stores a sample, until every asked box has
// a row at or after the click, or the wait cap.
//
// Limits (7.5): one run in flight per workspace on this instance (a click
// meanwhile joins it and gets the same answer, filtered to its own lock
// view); PerHour runs started per rolling hour, the next is 429 with
// Retry-After. A joined click starts nothing, so it is not counted.

// Refresh answer states (spec 071 7.4).
const (
	boxFresh  = "fresh"  // asked, answered within the wait: row at >= the click
	boxRecent = "recent" // not asked: its newest sample is younger than MinAge
	boxStale  = "stale"  // asked, no answer by the cap: its last row, its real age
	boxNever  = "never"  // asked, no answer by the cap, no sample in the retention
)

// boxRefreshPoll is how often the waiting instance reads box_stats (7.3 step 7).
const boxRefreshPoll = 250 * time.Millisecond

// BoxRefreshLimits is the Refresh button's wait and limits (spec 071 7.5,
// 8.7.1); a zero field is its default.
type BoxRefreshLimits struct {
	Wait    time.Duration // the hub's wait cap; 45 s (8.3.4)
	MinAge  time.Duration // a box sampled more recently is not asked; 60 s
	PerHour int           // runs started per workspace per rolling hour; 12
}

func (s *Server) boxRefreshLimits() BoxRefreshLimits {
	l := s.o.BoxRefresh
	if l.Wait <= 0 {
		l.Wait = 45 * time.Second
	}
	if l.MinAge <= 0 {
		l.MinAge = 60 * time.Second
	}
	if l.PerHour <= 0 {
		l.PerHour = 12
	}
	return l
}

// boxRefreshRow is one box of the answer; row is nil for never.
type boxRefreshRow struct {
	Box   string         `json:"box"`
	State string         `json:"state"`
	Row   *store.BoxStat `json:"row"`
}

// boxRefreshAnswer is the route's answer (7.6.2).
type boxRefreshAnswer struct {
	AskedAt time.Time       `json:"asked_at"`
	WaitMS  int64           `json:"wait_ms"`
	Boxes   []boxRefreshRow `json:"boxes"`
}

// boxRefreshRun is one workspace's run in flight; done closes once out is set.
type boxRefreshRun struct {
	done chan struct{}
	out  boxRefreshAnswer
}

// boxRefreshes holds the runs in flight and the hour's run starts, per
// tenant, on this instance; its own lock.
type boxRefreshes struct {
	mu     sync.Mutex
	runs   map[string]*boxRefreshRun
	starts map[string][]time.Time
}

// begin joins the tenant's run in flight (joined), or starts one when the
// rolling hour has room; otherwise run is nil and retry is when it has.
func (g *boxRefreshes) begin(tenant string, now time.Time, perHour int) (run *boxRefreshRun, joined bool, retry time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if r := g.runs[tenant]; r != nil {
		return r, true, 0
	}
	kept := g.starts[tenant][:0]
	for _, at := range g.starts[tenant] {
		if now.Sub(at) < time.Hour {
			kept = append(kept, at)
		}
	}
	if len(kept) >= perHour {
		g.starts[tenant] = kept
		return nil, false, kept[0].Add(time.Hour).Sub(now)
	}
	if g.runs == nil {
		g.runs, g.starts = map[string]*boxRefreshRun{}, map[string][]time.Time{}
	}
	run = &boxRefreshRun{done: make(chan struct{})}
	g.runs[tenant], g.starts[tenant] = run, append(kept, now)
	return run, false, 0
}

// end publishes out to the run's joiners and frees the tenant's slot.
func (g *boxRefreshes) end(tenant string, run *boxRefreshRun, out boxRefreshAnswer) {
	g.mu.Lock()
	if g.runs[tenant] == run {
		delete(g.runs, tenant)
	}
	g.mu.Unlock()
	run.out = out
	close(run.done)
}

// pendingFor reports whether this instance holds a request for (tenant,
// box) inside its deadline.
func (p *boxSamples) pendingFor(tenant, box string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, r := range p.m {
		if r.tenant == tenant && r.box == box && !now.After(r.deadline) {
			return true
		}
	}
	return false
}

// storedCh is closed at the next sample this instance stores.
func (p *boxSamples) storedCh() <-chan struct{} {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stored == nil {
		p.stored = make(chan struct{})
	}
	return p.stored
}

// signalStored wakes every Refresh wait of this instance.
func (p *boxSamples) signalStored() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stored != nil {
		close(p.stored)
		p.stored = nil
	}
}

func (s *Server) routeBoxRefresh(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/tenant/box-stats/refresh", s.handleBoxRefresh)
	mux.HandleFunc("OPTIONS /v1/tenant/box-stats/refresh", s.preflight)
}

// POST /v1/tenant/box-stats/refresh
func (s *Server) handleBoxRefresh(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	bs, isBS := s.o.Store.(store.BoxStats)
	if _, isW := s.o.Store.(store.BoxSampleWaker); !isBS || !isW {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no box stats or carries no box sample requests")
		return
	}
	var body struct {
		Box string `json:"box"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		writeErr(w, http.StatusBadRequest, "bad_json", "the body is {} or {\"box\": \"<id>\"}")
		return
	}
	lv, err := s.lockViewFor(r.Context(), t.ID, a.HumanID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "box refresh unavailable")
		return
	}
	boxes, ae := s.boxRefreshSet(r.Context(), t.ID, body.Box, lv)
	if ae != nil {
		writeErr(w, ae.status, ae.token, ae.detail)
		return
	}
	l := s.boxRefreshLimits()
	run, joined, retry := s.refreshes.begin(t.ID, s.o.Now(), l.PerHour)
	if run == nil {
		w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
		writeErr(w, http.StatusTooManyRequests, "rate_limited", fmt.Sprintf("at most %d box refreshes per hour in this workspace", l.PerHour))
		return
	}
	if !joined {
		// The run outlives a starter that leaves: its joiners wait on it.
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), l.Wait+10*time.Second)
		out := s.runBoxRefresh(ctx, bs, t.ID, boxes, l)
		cancel()
		s.refreshes.end(t.ID, run, out)
	}
	select {
	case <-run.done:
	case <-r.Context().Done():
		return
	}
	out := run.out
	out.Boxes = make([]boxRefreshRow, 0, len(run.out.Boxes))
	for _, b := range run.out.Boxes {
		if !lv.hides(b.Box) && (body.Box == "" || b.Box == body.Box) {
			out.Boxes = append(out.Boxes, b)
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// boxRefreshSet is the boxes a refresh may ask (7.6.2): the workspace's
// pinned boxes, minus a revoked pin, box-wui and what the lock view hides;
// box != "" narrows it to that one, 404 when it is not among them.
func (s *Server) boxRefreshSet(ctx context.Context, tenant, box string, lv lockView) ([]string, *issueErr) {
	if box != "" && !store.FleetNameRe.MatchString(box) {
		return nil, &issueErr{http.StatusBadRequest, "bad_query", "box must be a box id ([a-z0-9-], up to 32)"}
	}
	vbs, err := s.o.Store.ViewBoxes(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("box refresh: view boxes")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "box refresh unavailable"}
	}
	var out []string
	for _, vb := range vbs {
		if vb.Revoked || vb.BoxID == WUIBox || lv.hides(vb.BoxID) || (box != "" && vb.BoxID != box) {
			continue
		}
		out = append(out, vb.BoxID)
	}
	if box != "" && len(out) == 0 {
		return nil, &issueErr{http.StatusNotFound, "not_found", "no pinned box " + box + " in this workspace"}
	}
	return out, nil
}

// runBoxRefresh asks every box of boxes that is not recent, waits for their
// answers up to l.Wait, and labels each box (7.4).
func (s *Server) runBoxRefresh(ctx context.Context, bs store.BoxStats, tenant string, boxes []string, l BoxRefreshLimits) boxRefreshAnswer {
	start, askedAt := time.Now(), s.o.Now()
	newest := s.newestBoxStats(ctx, bs, tenant, boxes, askedAt)
	asked := map[string]bool{}
	for _, b := range boxes {
		if row := newest[b]; row != nil && askedAt.Sub(row.At) < l.MinAge {
			continue // recent: no box is sampled twice inside MinAge
		}
		asked[b] = true
		if s.samples.pendingFor(tenant, b, askedAt) {
			continue // already asked: wait on that request, ask nothing new
		}
		if _, err := s.askBoxSample(ctx, tenant, b, askedAt.Add(l.Wait)); err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", tenant).Str("box", b).Msg("box refresh: request not announced")
		}
	}
	fresh := s.waitBoxSamples(ctx, bs, tenant, asked, askedAt, l.Wait)
	out := boxRefreshAnswer{AskedAt: askedAt.UTC(), Boxes: make([]boxRefreshRow, 0, len(boxes))}
	for _, b := range boxes {
		row := boxRefreshRow{Box: b, State: boxRecent, Row: newest[b]}
		switch {
		case !asked[b]:
		case fresh[b] != nil:
			row.State, row.Row = boxFresh, fresh[b]
		case newest[b] != nil:
			row.State = boxStale
		default:
			row.State = boxNever
		}
		out.Boxes = append(out.Boxes, row)
	}
	out.WaitMS = time.Since(start).Milliseconds()
	return out
}

// waitBoxSamples reads the rows at or after askedAt until every asked box
// has one or wait passes: every boxRefreshPoll, and at once when this
// instance stores a sample. It answers each box's newest such row.
func (s *Server) waitBoxSamples(ctx context.Context, bs store.BoxStats, tenant string, asked map[string]bool, askedAt time.Time, wait time.Duration) map[string]*store.BoxStat {
	fresh := map[string]*store.BoxStat{}
	if len(asked) == 0 {
		return fresh
	}
	capT := time.NewTimer(wait)
	defer capT.Stop()
	tick := time.NewTicker(boxRefreshPoll)
	defer tick.Stop()
	for {
		stored := s.samples.storedCh()
		rows, err := bs.ListBoxStats(ctx, tenant, "", askedAt)
		if err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", tenant).Msg("box refresh: box stats read")
		}
		for i := range rows {
			if b := rows[i].Box; asked[b] && (fresh[b] == nil || rows[i].At.After(fresh[b].At)) {
				fresh[b] = &rows[i]
			}
		}
		if len(fresh) == len(asked) {
			return fresh
		}
		select {
		case <-tick.C:
		case <-stored:
		case <-capT.C:
			return fresh
		case <-ctx.Done():
			return fresh
		}
	}
}

// newestBoxStats is each box's newest sample in the retention, nil = none:
// the last hour for the whole workspace (a box's tick writes every 5 min),
// then the retention for each box the hour did not hold.
func (s *Server) newestBoxStats(ctx context.Context, bs store.BoxStats, tenant string, boxes []string, now time.Time) map[string]*store.BoxStat {
	out := map[string]*store.BoxStat{}
	keep := func(rows []store.BoxStat) {
		for i := range rows {
			if b := rows[i].Box; out[b] == nil || rows[i].At.After(out[b].At) {
				out[b] = &rows[i]
			}
		}
	}
	rows, err := bs.ListBoxStats(ctx, tenant, "", now.Add(-time.Hour))
	if err != nil {
		s.o.Log.Warn().Err(err).Str("tenant", tenant).Msg("box refresh: newest box stats")
	}
	keep(rows)
	for _, b := range boxes {
		if out[b] != nil {
			continue
		}
		rows, err := bs.ListBoxStats(ctx, tenant, b, now.Add(-store.BoxStatsRetention))
		if err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", tenant).Str("box", b).Msg("box refresh: newest box stats")
		}
		keep(rows)
	}
	return out
}
