package hub

import (
	"sort"
	"sync"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/rs/zerolog"
)

// A relay loop and a dropped DB connection (SPL-4490, row 3 of the api top-10
// errors, SPL-4420). Measured on prd: 96 ERROR lines `write unix
// ...s.PGSQL.5432: write: broken pipe` in the relay loops; 92 were one burst
// on 2026-10-22T22:38Z, every loop logging once per workspace, and 4 on
// 2026-10-30T01:22Z were a pooled connection the server had dropped, which
// pgx reused.
//
// So a loop read that failed before anything reached the server
// (pgconn.SafeToRetry: the broken pipe on a dead pooled connection) runs once
// more, on another connection; a read that may have reached the server is
// never retried. And a pass in which a site failed for EVERY call of it logs
// one line for that site, with the workspace count, not one per workspace;
// a pass where only some fail still names each one (loop_log.go's ERROR,
// WARN, recovered INFO).

// retryRead runs read, and once more when its error is safe to retry.
func retryRead[T any](read func() (T, error)) (T, error) {
	v, err := read()
	if err != nil && pgconn.SafeToRetry(err) {
		return read()
	}
	return v, err
}

// relayLoops is a loopLog whose failures inside a pass (begin .. end) are
// held until the pass ends. Outside a pass it logs at once, as loopLog does.
type relayLoops struct {
	loopLog
	pmu   sync.Mutex
	depth int                  // open passes (a test may tick while the loop runs)
	pass  map[string]*sitePass // by site; nil outside a pass
}

// sitePass is one site's calls in the open pass and the failures held.
type sitePass struct {
	calls int
	fails []loopFail
}

type loopFail struct {
	tenant, box string
	err         error
}

// begin opens a pass.
func (r *relayLoops) begin() {
	r.pmu.Lock()
	defer r.pmu.Unlock()
	if r.depth == 0 {
		r.pass = map[string]*sitePass{}
	}
	r.depth++
}

// fail is loopLog.fail, held until the pass ends.
func (r *relayLoops) fail(log *zerolog.Logger, site, tenant, box string, err error) {
	if r.note(site, &loopFail{tenant: tenant, box: box, err: err}) {
		return
	}
	r.loopLog.fail(log, site, tenant, box, err)
}

// ok is loopLog.ok; it counts the call in the open pass.
func (r *relayLoops) ok(log *zerolog.Logger, site, tenant, box string) {
	r.note(site, nil)
	r.loopLog.ok(log, site, tenant, box)
}

// note counts one call of site in the open pass and holds its failure f;
// true when f was held.
func (r *relayLoops) note(site string, f *loopFail) bool {
	r.pmu.Lock()
	defer r.pmu.Unlock()
	if r.pass == nil {
		return false
	}
	p := r.pass[site]
	if p == nil {
		p = &sitePass{}
		r.pass[site] = p
	}
	p.calls++
	if f == nil {
		return false
	}
	p.fails = append(p.fails, *f)
	return true
}

// end closes a pass; the last one logs what it held: one summary line for a
// site that failed on every call (more than one), else each failure.
func (r *relayLoops) end(log *zerolog.Logger) {
	r.pmu.Lock()
	r.depth--
	if r.depth > 0 {
		r.pmu.Unlock()
		return
	}
	pass := r.pass
	r.pass = nil
	r.pmu.Unlock()
	sites := make([]string, 0, len(pass))
	for site := range pass {
		sites = append(sites, site)
	}
	sort.Strings(sites)
	for _, site := range sites {
		p := pass[site]
		if len(p.fails) > 1 && len(p.fails) == p.calls {
			r.summary(log, site, p.fails)
			continue
		}
		for _, f := range p.fails {
			r.loopLog.fail(log, site, f.tenant, f.box, f.err)
		}
	}
}

// summary counts every failure of an all-failed site and logs one line:
// ERROR when any of its calls had been working, WARN while all keep failing.
func (r *relayLoops) summary(log *zerolog.Logger, site string, fails []loopFail) {
	first, most, tenants := false, 0, map[string]bool{}
	for _, f := range fails {
		n := r.loopLog.count(site, f.tenant, f.box)
		first = first || n == 1
		most = max(most, n)
		tenants[f.tenant] = true
	}
	ev := log.Warn()
	if first {
		ev = log.Error()
	}
	ev.Err(fails[0].err).Bool("all_failed", true).Int("workspaces", len(tenants)).
		Int("calls", len(fails)).Int("failures", most).Msg(site)
}

// count counts one failure of a loop call without logging it, and returns
// its failures in a row.
func (l *loopLog) count(site, tenant, box string) int {
	k := [3]string{site, tenant, box}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.failing == nil {
		l.failing = map[[3]string]int{}
	}
	l.failing[k]++
	return l.failing[k]
}
