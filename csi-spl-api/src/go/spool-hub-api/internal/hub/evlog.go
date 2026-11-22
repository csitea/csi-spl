package hub

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/evlog"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Source (a) of the backend error log (spec 162 section 10.4.2, SPL-5882):
// the hub writes its own errors into the System log. A handler 5xx, a
// handler panic, a loop panic and any other ERROR line is a sighting: an
// in-memory add under a mutex, never a database call on the request path.
// The evlog-flush loop writes every group touched since the last flush as
// ONE upsert (n = the sightings), and per (person, fingerprint) one row in
// that person's Mine log (Q4 B). A failed write is one ERROR line
// EvlogUnwrittenMsg per group, which the box reader (source b) takes back.

// EvlogUnwrittenMsg is the ERROR line of a group (or a Mine batch) the flush
// could not write. The hook skips it, so it never loops.
const EvlogUnwrittenMsg = "event log write failed"

// The messages logServerError writes; the hook skips them (their sighting
// is logServerError's own: no double).
const (
	httpServerErrMsg = "http 5xx"
	handlerPanicMsg  = "handler panic"
)

// The caps of 10.4.2 and 10.4.5 for the Mine copy, and the flush defaults.
const (
	evlogMinePairsCap  = evlog.CapInProcess // (person, fingerprint) pairs between two flushes
	evlogMinePerHuman  = 20                 // Mine rows per person per flush
	EvlogFlushDefault  = 30 * time.Second   // cnf hub.env SPOOL_HUB_EVLOG_FLUSH_S
	evlogFlushTimeout  = 10 * time.Second   // one flush's store work
	evlogSourceHub     = "hub"              // the Mine row's source
	evlogActorHub      = "hub"              // the System row's actor
	evlogMineOriginPfx = "evlog:"
)

// evlogTraceRe is the trace id of an X-Cloud-Trace-Context header
// (TRACE_ID/SPAN_ID;o=1): 32 hex, nothing else of the header is taken.
var evlogTraceRe = regexp.MustCompile(`^([0-9a-fA-F]{32})(?:/|;|$)`)

// Evlog is one hub's sightings between two flushes. Safe for concurrent use.
type Evlog struct {
	now     func() time.Time
	project atomic.Pointer[string] // the GCP project of the trace field; "" = no trace field

	mu      sync.Mutex // held across groups.Add and the extras below, and across a flush's take
	groups  *evlog.Groups
	meta    map[string]evlogMeta // fingerprint -> the group's extras since the last flush
	mine    map[evlogPair]*evlogMine
	order   []evlogPair
	dropped map[evlogPair]bool // pairs past evlogMinePairsCap, bounded by it
	extra   int                // new pairs once dropped is full itself
}

// evlogMeta is what a System row carries beyond evlog.Group.
type evlogMeta struct {
	originRef string // the route pattern, or the loop name
	human     string // the last sighting's person, "" = none
}

type evlogPair struct{ human, fp string }

// evlogMine is one (person, fingerprint) pair since the last flush.
type evlogMine struct {
	method, route, code string
	status, n           int
	first               time.Time
}

// evlogSight is one sighting with what the System and Mine rows need.
type evlogSight struct {
	evlog.Sighting
	originRef                  string
	human, method, route, code string
	status                     int
}

func newEvlog(now func() time.Time) *Evlog {
	e := &Evlog{now: now}
	e.reset()
	return e
}

// reset empties the sightings; e.mu is held (or e is new).
func (e *Evlog) reset() {
	e.groups = evlog.NewGroups(evlog.CapInProcess)
	e.meta, e.mine, e.order = map[string]evlogMeta{}, map[evlogPair]*evlogMine{}, nil
	e.dropped, e.extra = map[evlogPair]bool{}, 0
}

// evlogs holds each Server's Evlog. It lives here, not as a Server field, so
// row T3 touches server.go only in middleware and logServerError (the
// row's file list); one entry per Server, made on first use.
var evlogs sync.Map // *Server -> *Evlog

// Evlog answers s's sightings, made on first use.
func (s *Server) Evlog() *Evlog {
	if v, ok := evlogs.Load(s); ok {
		return v.(*Evlog)
	}
	v, _ := evlogs.LoadOrStore(s, newEvlog(s.o.Now))
	return v.(*Evlog)
}

// SetTraceProject sets the GCP project the trace field names (cnf hub.env
// SPOOL_HUB_GCP_PROJECT); "" leaves the field off (lde, tests).
func (e *Evlog) SetTraceProject(project string) { e.project.Store(&project) }

// traceField answers Cloud Logging's trace field for r, or "" when the
// project is unset or the header holds no trace id.
func (e *Evlog) traceField(r *http.Request) string {
	p := e.project.Load()
	if p == nil || *p == "" {
		return ""
	}
	m := evlogTraceRe.FindStringSubmatch(r.Header.Get("X-Cloud-Trace-Context"))
	if m == nil {
		return ""
	}
	return "projects/" + *p + "/traces/" + strings.ToLower(m[1])
}

// evlogTraceKey is Cloud Logging's trace field on a JSON line.
const evlogTraceKey = "logging.googleapis.com/trace"

// add records one sighting: its group, the group's extras and, when it has
// a person, the (person, fingerprint) pair of the Mine copy.
func (e *Evlog) add(s evlogSight) {
	if s.At.IsZero() {
		s.At = e.now()
	}
	if s.Level == "" {
		s.Level = evlog.LevelError
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	fp, kept := e.groups.Add(s.Sighting)
	if !kept {
		return
	}
	m := e.meta[fp]
	if s.originRef != "" {
		m.originRef = s.originRef
	}
	if s.human != "" {
		m.human = s.human
	}
	e.meta[fp] = m
	if s.human != "" {
		e.addPair(evlogPair{s.human, fp}, s)
	}
}

// addPair counts s into its pair; past the cap a new pair is counted into
// the overflow row, not kept. e.mu is held.
func (e *Evlog) addPair(p evlogPair, s evlogSight) {
	if c, ok := e.mine[p]; ok {
		c.n++
		if s.At.Before(c.first) {
			c.first = s.At
		}
		return
	}
	if len(e.mine) >= evlogMinePairsCap {
		switch {
		case e.dropped[p]:
		case len(e.dropped) < evlogMinePairsCap:
			e.dropped[p] = true
		default:
			e.extra++
		}
		return
	}
	e.mine[p] = &evlogMine{method: s.method, route: s.route, code: s.code, status: s.status, n: 1, first: s.At}
	e.order = append(e.order, p)
}

// evlogTake is one flush's share of the sightings.
type evlogTake struct {
	groups []evlog.Group
	meta   map[string]evlogMeta
	mine   map[evlogPair]*evlogMine
	order  []evlogPair
}

// take empties e and answers what it held, the pairs not kept folded into
// the evlog.overflow group.
func (e *Evlog) take(now time.Time) evlogTake {
	e.mu.Lock()
	defer e.mu.Unlock()
	t := evlogTake{groups: e.groups.Take(now), meta: e.meta, mine: e.mine, order: e.order}
	if n := len(e.dropped) + e.extra; n > 0 {
		t.groups = foldOverflow(t.groups, n, now)
	}
	e.reset()
	return t
}

// foldOverflow adds n groups not kept to the overflow group of gs, or
// appends one: one evlog.overflow row per flush (10.4.5).
func foldOverflow(gs []evlog.Group, n int, now time.Time) []evlog.Group {
	for i, g := range gs {
		if g.Kind == evlog.KindOverflow {
			o := evlog.OverflowGroup(g.N+n, evlog.CapInProcess, now)
			o.FirstAt = g.FirstAt
			gs[i] = o
			return gs
		}
	}
	return append(gs, evlog.OverflowGroup(n, evlog.CapInProcess, now))
}

// FlushEvlog writes the sightings since the last flush: one upsert per
// group, then the Mine copies. A failed write is one ERROR line
// EvlogUnwrittenMsg per group (or per person's Mine batch), and the
// sightings are dropped from memory either way. Bounded by its own timeout,
// so the shutdown flush can run on a fresh context.
func (s *Server) FlushEvlog(ctx context.Context) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), evlogFlushTimeout)
	defer cancel()
	t := s.Evlog().take(s.o.Now())
	ls, _ := s.o.Store.(store.LogEvents)
	msgs := make(map[string]string, len(t.groups))
	for _, g := range t.groups {
		msgs[g.Fingerprint] = g.Message
		s.writeGroup(ctx, ls, g, t.meta[g.Fingerprint])
	}
	hs, _ := s.o.Store.(store.HumanEvents)
	s.writeMine(ctx, hs, t, msgs)
}

// writeGroup upserts one group, or writes its EvlogUnwrittenMsg line.
func (s *Server) writeGroup(ctx context.Context, ls store.LogEvents, g evlog.Group, m evlogMeta) {
	row := store.LogEvent{At: g.LastAt, Kind: g.Kind, Level: g.Level, Actor: evlogActorHub, Message: g.Message,
		Fingerprint: g.Fingerprint, FirstAt: g.FirstAt, N: g.N, HumanID: m.human}
	if ref := evlog.Redact(m.originRef); ref != "" {
		row.OriginKind, row.OriginRef = store.LogOriginComponent, evlogCut(ref, 120)
	}
	err := errNoLogEvents
	if ls != nil {
		_, err = ls.UpsertSystemErrorGroup(ctx, row)
	}
	if err != nil {
		s.o.Log.Error().Str("fp", g.Fingerprint).Str("kind", g.Kind).Int("n", g.N).
			Time("first_at", g.FirstAt).Time("last_at", g.LastAt).Str("message", g.Message).
			Str("error", evlog.Redact(err.Error())).Msg(EvlogUnwrittenMsg)
	}
}

var (
	errNoLogEvents   = fmt.Errorf("this hub's store keeps no system log")
	errNoHumanEvents = fmt.Errorf("this hub's store keeps no Mine log")
)

// writeMine writes, per person, one Mine row per fingerprint they hit since
// the last flush (10.4.2): at most evlogMinePerHuman, the rest folded into
// the last as " (+<k> more)". A failed write is one EvlogUnwrittenMsg line
// with the person dropped (target mine: it names no group, so the reader
// never counts it as one).
func (s *Server) writeMine(ctx context.Context, hs store.HumanEvents, t evlogTake, msgs map[string]string) {
	byHuman := map[string][]evlogPair{}
	var humans []string
	for _, p := range t.order {
		if _, ok := msgs[p.fp]; !ok {
			continue
		}
		if byHuman[p.human] == nil {
			humans = append(humans, p.human)
		}
		byHuman[p.human] = append(byHuman[p.human], p)
	}
	now := s.o.Now()
	for _, h := range humans {
		rows := mineRows(byHuman[h], t.mine, msgs)
		err := errNoHumanEvents
		if hs != nil {
			_, err = hs.AddHumanEvents(ctx, h, rows, now)
		}
		if err != nil {
			s.o.Log.Error().Str("target", "mine").Int("rows", len(rows)).
				Str("error", evlog.Redact(err.Error())).Msg(EvlogUnwrittenMsg)
		}
	}
}

// mineRows builds one person's Mine rows, first sighting first.
func mineRows(pairs []evlogPair, mine map[evlogPair]*evlogMine, msgs map[string]string) []store.HumanEvent {
	sort.SliceStable(pairs, func(i, j int) bool { return mine[pairs[i]].first.Before(mine[pairs[j]].first) })
	more := 0
	if len(pairs) > evlogMinePerHuman {
		more = len(pairs) - evlogMinePerHuman
		pairs = pairs[:evlogMinePerHuman]
	}
	rows := make([]store.HumanEvent, 0, len(pairs))
	for i, p := range pairs {
		c := mine[p]
		suffix := ""
		if c.n > 1 {
			suffix = " (x" + strconv.Itoa(c.n) + ")"
		}
		if more > 0 && i == len(pairs)-1 {
			suffix += " (+" + strconv.Itoa(more) + " more)"
		}
		first := c.first
		rows = append(rows, store.HumanEvent{
			Source: evlogSourceHub, Method: evlogCut(c.method, 12), Route: evlogCut(evlog.Redact(c.route), 200),
			Status: c.status, Code: evlogCut(c.code, 120), Origin: evlogMineOriginPfx + p.fp,
			Message: evlogCut(msgs[p.fp], 800-utf8.RuneCountInString(suffix)) + suffix, OccurredAt: &first,
		})
	}
	return rows
}

// evlogCut cuts s to at most n runes, no mark (an rdb cap).
func evlogCut(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// RunEvlogFlush flushes every interval until ctx ends (the evlog-flush
// loop; the shutdown flush is the caller's FlushEvlog after the drain). An
// interval <= 0 is EvlogFlushDefault.
func (s *Server) RunEvlogFlush(ctx context.Context, every time.Duration) {
	if every <= 0 {
		every = EvlogFlushDefault
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.FlushEvlog(ctx)
		}
	}
}

// serverErrSighting turns logServerError's 5xx or panic into a sighting
// (10.4.2): the person from the session cookie, never the store.
// The route is the mux pattern; a request no pattern matched is named by
// its method only (the URL path is never taken, 10.6).
func (s *Server) serverErrSighting(r *http.Request, sw *statusWriter, rec any, stack string) {
	route := r.Pattern
	if route == "" {
		route = r.Method + " <unmatched>"
	}
	sg := evlogSight{originRef: route, method: r.Method, route: route, status: sw.status, code: sw.token}
	if s.o.Auth != nil {
		sg.human = s.o.Auth.HumanFromCookie(r)
	}
	if rec != nil {
		sg.Kind, sg.Message, sg.Anchor, sg.code = store.LogKindErrPanic, fmt.Sprintf("panic: %v", rec), evlog.TopFrame(stack), "panic"
	} else {
		sg.Kind, sg.Anchor = store.LogKindErrHTTPServer, route+" "+sw.token
		sg.Message = strconv.Itoa(sw.status) + " " + sw.token + " at " + sw.site
		if sw.err != nil {
			sg.Message += ": " + sw.err.Error()
		}
	}
	s.Evlog().add(sg)
}

// panicStack is the stack of the panicking goroutine, taken in the
// middleware's deferred func (TopFrame skips the frames above panic()).
func panicStack() string { return string(debug.Stack()) }

// ---- loop panics: the sink rides the loops' context --------------------------

type evlogCtxKey struct{}

// WithEvlog answers ctx carrying e, so Supervise counts a loop panic into
// it (spec 162 10.4.2).
func WithEvlog(ctx context.Context, e *Evlog) context.Context {
	return context.WithValue(ctx, evlogCtxKey{}, e)
}

func evlogFrom(ctx context.Context) *Evlog {
	e, _ := ctx.Value(evlogCtxKey{}).(*Evlog)
	return e
}

// loopPanicSighting counts a recovered loop panic: anchored on the loop
// name, no person.
func loopPanicSighting(ctx context.Context, name string, rec any) {
	if e := evlogFrom(ctx); e != nil {
		e.add(evlogSight{Sighting: evlog.Sighting{Kind: store.LogKindErrLoopPanic, Message: fmt.Sprintf("panic: %v", rec), Anchor: name},
			originRef: name})
	}
}

// ---- every other ERROR line: a zerolog hook ----------------------------------

// EvlogHook is the hook on the hub's logger (10.4.2): every line at level
// error or above whose message is not one written above adds one error.log
// sighting, anchored on the function that wrote it. It is made before the
// server (the logger goes into its Options) and attached after.
type EvlogHook struct{ e atomic.Pointer[Evlog] }

// NewEvlogHook answers a hook that counts nothing until Attach.
func NewEvlogHook() *EvlogHook { return &EvlogHook{} }

// Attach points the hook at e.
func (h *EvlogHook) Attach(e *Evlog) { h.e.Store(e) }

// evlogHookSkip are the lines with a sighting of their own, or none.
var evlogHookSkip = map[string]bool{
	httpServerErrMsg: true, handlerPanicMsg: true, LoopPanicMsg: true, EvlogUnwrittenMsg: true,
}

// Run is zerolog.Hook.
func (h *EvlogHook) Run(_ *zerolog.Event, level zerolog.Level, msg string) {
	e := h.e.Load()
	if e == nil || level < zerolog.ErrorLevel || level > zerolog.PanicLevel || evlogHookSkip[msg] {
		return
	}
	fn := callerOutsideZerolog()
	if msg == "" {
		msg = "error at " + fn
	}
	e.add(evlogSight{Sighting: evlog.Sighting{Kind: store.LogKindErrLog, Message: msg, Anchor: fn}})
}

// callerOutsideZerolog is the function that wrote the line: the first frame
// above this hook that is not zerolog's own.
func callerOutsideZerolog() string {
	pcs := make([]uintptr, 16)
	n := runtime.Callers(3, pcs) // runtime.Callers, this func, Run
	frames := runtime.CallersFrames(pcs[:n])
	for {
		f, more := frames.Next()
		if !strings.HasPrefix(f.Function, "github.com/rs/zerolog") {
			return f.Function
		}
		if !more {
			return ""
		}
	}
}
