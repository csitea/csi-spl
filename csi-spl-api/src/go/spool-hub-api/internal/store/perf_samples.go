package store

import (
	"context"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// The perceived-performance samples of the WUI (spec 066 section 4.1, rdb
// 0106): one row per timing a tab measured, in a table nothing else reads or
// writes. No personal data (spec 4.2): the tenant and at come from the hub,
// the session id is a random per-tab uuid, every other field is an enum, a
// number or a version-shaped build token.

// The allowed values; each is rdb 0106's CHECK on the column of the same name
// (TestPerfSamplesPinRdbChecks).
var (
	PerfMetrics  = []string{"load_rail", "load_messages", "send_ack", "deliver_visible", "switch_view", "type_next_paint", "inp", "scroll_jank", "reconnect_live"}
	PerfDevices  = []string{"phone", "desktop"}
	PerfViews    = []string{"topic", "channel", "dm", "flow", "search"} // or "" = NULL
	PerfCaches   = []string{"cold", "warm"}                             // or "" = NULL
	PerfOutcomes = []string{"ok", "fail", "timeout"}
	PerfNets     = []string{"slow-2g", "2g", "3g", "4g"}        // or "" = NULL
	PerfHiddenS  = []string{"30-300", "300-3600", "3600+"}      // or "" = NULL
	perfBuildRe  = regexp.MustCompile(`^[0-9A-Za-z.+-]{0,40}$`) // rdb 0106 build CHECK
	perfUUIDRe   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

// Perf sample limits.
const (
	// PerfSampleRetention is how long raw samples live; the hub's retention
	// sweep prunes older ones. The ONE place the number lives (owner Q6:
	// 30 days, 90 is this line).
	PerfSampleRetention = 30 * 24 * time.Hour
	PerfValueMaxMs      = 600000 // 10 min: a longer "timing" is a stuck tab
	PerfBatchMax        = 500    // rows one insert takes at most
)

// PerfSample is one row of wui_perf_samples. "" is NULL for View, Cache,
// Net and HiddenS; a nil pointer is NULL.
type PerfSample struct {
	At         time.Time `json:"at"`
	SessionID  string    `json:"session_id"`
	Metric     string    `json:"metric"`
	ValueMs    int       `json:"value_ms"`
	Ratio      *float64  `json:"ratio,omitempty"`
	Device     string    `json:"device"`
	View       string    `json:"view,omitempty"`
	Cache      string    `json:"cache,omitempty"`
	Outcome    string    `json:"outcome"`
	Build      string    `json:"build"`
	Net        string    `json:"net,omitempty"`
	ClockErrMs *int      `json:"clock_err_ms,omitempty"`
	HiddenS    string    `json:"hidden_s,omitempty"`
}

// CheckPerfSample names the first field a sample may not carry ("" = fine):
// the Go side of rdb 0106's CHECKs, so the ingest refuses before the insert.
func CheckPerfSample(p PerfSample) string {
	optIn := func(v string, set []string) bool { return v == "" || slices.Contains(set, v) }
	switch {
	case p.At.IsZero():
		return "at is required"
	case !perfUUIDRe.MatchString(p.SessionID):
		return "session_id must be a lowercase uuid"
	case !slices.Contains(PerfMetrics, p.Metric):
		return "metric must be one of " + strings.Join(PerfMetrics, ", ")
	case p.ValueMs < 0 || p.ValueMs > PerfValueMaxMs:
		return "value_ms out of range"
	case p.Ratio != nil && (*p.Ratio < 0 || *p.Ratio > 1):
		return "ratio must be 0..1"
	case !slices.Contains(PerfDevices, p.Device):
		return "device must be one of " + strings.Join(PerfDevices, ", ")
	case !optIn(p.View, PerfViews):
		return "view must be one of " + strings.Join(PerfViews, ", ")
	case !optIn(p.Cache, PerfCaches):
		return "cache must be one of " + strings.Join(PerfCaches, ", ")
	case !slices.Contains(PerfOutcomes, p.Outcome):
		return "outcome must be one of " + strings.Join(PerfOutcomes, ", ")
	case !perfBuildRe.MatchString(p.Build):
		return "build must be a version token"
	case !optIn(p.Net, PerfNets):
		return "net must be one of " + strings.Join(PerfNets, ", ")
	case p.ClockErrMs != nil && (*p.ClockErrMs < 0 || *p.ClockErrMs > PerfValueMaxMs):
		return "clock_err_ms out of range"
	case !optIn(p.HiddenS, PerfHiddenS):
		return "hidden_s must be one of " + strings.Join(PerfHiddenS, ", ")
	}
	return ""
}

// PerfSummaryRow is one (metric, device, view) group of a window: n and the
// p50 / p75 / p95 of value_ms over the ok samples, and the samples that did
// not complete (spec 3: a failed send is counted apart, not as a time).
type PerfSummaryRow struct {
	Metric string   `json:"metric"`
	Device string   `json:"device"`
	View   string   `json:"view"`
	N      int      `json:"n"`
	P50    *float64 `json:"p50"`
	P75    *float64 `json:"p75"`
	P95    *float64 `json:"p95"`
	Failed int      `json:"failed"`
}

// PerfSamples is the store half of spec 066 section 4.1. Optional: the hub
// skips the sweep, and its routes answer as off, on a store without it.
type PerfSamples interface {
	// InsertPerfSamples appends the batch (at most PerfBatchMax rows, each
	// already checked by CheckPerfSample) in one statement.
	InsertPerfSamples(ctx context.Context, tenantID string, batch []PerfSample) error
	// ListPerfSamples is the tenant's samples at or after since, oldest
	// first, at most limit (capped at PerfBatchMax).
	ListPerfSamples(ctx context.Context, tenantID string, since time.Time, limit int) ([]PerfSample, error)
	// PerfSummary groups the tenant's samples at or after since (build ""
	// = every build) per (metric, device, view), ordered by them.
	PerfSummary(ctx context.Context, tenantID string, since time.Time, build string) ([]PerfSummaryRow, error)
	// PrunePerfSamples deletes every tenant's samples older than before (the
	// hub's retention sweep) and counts them.
	PrunePerfSamples(ctx context.Context, before time.Time) (int, error)
}

// ClampPerfLimit is a list limit within 1..PerfBatchMax (0 = the max).
func ClampPerfLimit(limit int) int {
	if limit <= 0 || limit > PerfBatchMax {
		return PerfBatchMax
	}
	return limit
}

// percentileCont is Postgres's percentile_cont over sorted values.
func percentileCont(sorted []int, p float64) *float64 {
	if len(sorted) == 0 {
		return nil
	}
	pos := p * float64(len(sorted)-1)
	lo := int(pos)
	v := float64(sorted[lo])
	if lo+1 < len(sorted) {
		v += (pos - float64(lo)) * float64(sorted[lo+1]-sorted[lo])
	}
	return &v
}

// summarizePerf is the memory PerfSummary: the same groups, order and
// interpolation as the Postgres statement.
func summarizePerf(samples []PerfSample) []PerfSummaryRow {
	type key struct{ m, d, v string }
	vals := map[key][]int{}
	fails := map[key]int{}
	for _, p := range samples {
		k := key{p.Metric, p.Device, p.View}
		if _, ok := vals[k]; !ok {
			vals[k] = nil // a group of failures only still has a row
		}
		if p.Outcome == "ok" {
			vals[k] = append(vals[k], p.ValueMs)
		} else {
			fails[k]++
		}
	}
	out := make([]PerfSummaryRow, 0, len(vals))
	for k, v := range vals {
		slices.Sort(v) // in place: percentileCont reads v as ascending
		out = append(out, PerfSummaryRow{Metric: k.m, Device: k.d, View: k.v, N: len(v),
			P50: percentileCont(v, 0.5), P75: percentileCont(v, 0.75), P95: percentileCont(v, 0.95), Failed: fails[k]})
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Metric != b.Metric {
			return a.Metric < b.Metric
		}
		if a.Device != b.Device {
			return a.Device < b.Device
		}
		return a.View < b.View
	})
	return out
}

// Memory side: a per-store map beside the Memory struct, as the lifecycle
// log keeps its own.
var (
	memPerfMu sync.Mutex
	memPerfs  = map[*Memory]map[string][]PerfSample{}
)

func (s *Memory) perf() map[string][]PerfSample {
	p := memPerfs[s]
	if p == nil {
		p = map[string][]PerfSample{}
		memPerfs[s] = p
	}
	return p
}

func (s *Memory) InsertPerfSamples(_ context.Context, tenant string, batch []PerfSample) error {
	memPerfMu.Lock()
	defer memPerfMu.Unlock()
	p := s.perf()
	for _, e := range batch {
		e.At = e.At.UTC()
		p[tenant] = append(p[tenant], e)
	}
	return nil
}

// memPerfSince is the tenant's samples at or after since (and of build, ""
// = any), oldest first.
func (s *Memory) memPerfSince(tenant string, since time.Time, build string) []PerfSample {
	memPerfMu.Lock()
	defer memPerfMu.Unlock()
	out := []PerfSample{}
	for _, e := range s.perf()[tenant] {
		if !e.At.Before(since) && (build == "" || e.Build == build) {
			out = append(out, e)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	return out
}

func (s *Memory) ListPerfSamples(_ context.Context, tenant string, since time.Time, limit int) ([]PerfSample, error) {
	out := s.memPerfSince(tenant, since, "")
	if n := ClampPerfLimit(limit); len(out) > n {
		out = out[:n]
	}
	return out, nil
}

func (s *Memory) PerfSummary(_ context.Context, tenant string, since time.Time, build string) ([]PerfSummaryRow, error) {
	return summarizePerf(s.memPerfSince(tenant, since, build)), nil
}

func (s *Memory) PrunePerfSamples(_ context.Context, before time.Time) (int, error) {
	memPerfMu.Lock()
	defer memPerfMu.Unlock()
	n := 0
	p := s.perf()
	for t, rows := range p {
		kept := rows[:0]
		for _, e := range rows {
			if e.At.Before(before) {
				n++
				continue
			}
			kept = append(kept, e)
		}
		p[t] = kept
	}
	return n, nil
}
