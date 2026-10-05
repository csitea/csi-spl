package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"math"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// The agent context lifecycle (spec 063 sections 11 and 12, rdb 0105): one
// row of numbers per tenant that the box harness reads to decide when a lane
// restarts, a role seat rotates or compacts, and the dedicated log of what
// those steps then did, so an admin can change a number and see whether peak
// context, failed rotations and re-fetches moved.

// LifecycleKey is one config key: its default and its allowed values. A
// number key (Enum nil) holds an int in Min..Max, ZeroOff admitting 0 ("off")
// below Min (lane_checkpoint_min: 0, 10..240); an enum key holds one of Enum
// (seat_fail_action). Default is an int or a string to match.
type LifecycleKey struct {
	Key     string   `json:"key"`
	Default any      `json:"default"`
	Min     int      `json:"min,omitempty"`
	Max     int      `json:"max,omitempty"`
	ZeroOff bool     `json:"zero_off,omitempty"`
	Enum    []string `json:"enum,omitempty"`
}

// LifecycleKeys is the ONLY place the defaults live (spec 063 section 11); a
// stored NULL means this default. Each range is rdb 0105's CHECK on the
// column of the same name (TestLifecycleKeysPinRdbChecks).
var LifecycleKeys = []LifecycleKey{
	{Key: "lane_restart_ctx_k", Default: 400, Min: 100, Max: 950},
	{Key: "lane_restarts_before_split", Default: 2, Min: 1, Max: 5},
	{Key: "seat_restart_ctx_k", Default: 300, Min: 100, Max: 950},
	{Key: "seat_max_age_min", Default: 60, Min: 15, Max: 240},
	{Key: "seat_compact_after_fails", Default: 2, Min: 0, Max: 5},
	{Key: "seat_compact_min_ctx_k", Default: 400, Min: 100, Max: 950},
	{Key: "size_check_every_min", Default: 10, Min: 5, Max: 60},
	{Key: "notes_tail_lines", Default: 40, Min: 0, Max: 200},
	{Key: "seat_fail_action", Default: "compact", Enum: []string{"compact", "respawn"}},
	{Key: "lane_restart_wall_min", Default: 0, Min: 10, Max: 240, ZeroOff: true},
	{Key: "lane_checkpoint_min", Default: 0, Min: 10, Max: 240, ZeroOff: true},
}

// LifecycleKeyByName finds a key of LifecycleKeys.
func LifecycleKeyByName(name string) (LifecycleKey, bool) {
	for _, k := range LifecycleKeys {
		if k.Key == name {
			return k, true
		}
	}
	return LifecycleKey{}, false
}

// Allows reports whether v (an int, or a string for an enum key) is allowed.
func (k LifecycleKey) Allows(v any) bool {
	if k.Enum != nil {
		sv, ok := v.(string)
		return ok && slices.Contains(k.Enum, sv)
	}
	n, ok := v.(int)
	return ok && ((k.ZeroOff && n == 0) || (n >= k.Min && n <= k.Max))
}

// Range is the allowed values as the 400 names them.
func (k LifecycleKey) Range() string {
	if k.Enum != nil {
		return "one of " + strings.Join(k.Enum, ", ")
	}
	if k.ZeroOff {
		return fmt.Sprintf("0 or %d..%d", k.Min, k.Max)
	}
	return fmt.Sprintf("%d..%d", k.Min, k.Max)
}

// LifecycleConfig is a tenant's stored row: Stored holds only the keys set
// (absent = NULL = the default), an int or an enum string each.
type LifecycleConfig struct {
	Stored    map[string]any
	UpdatedBy string
	UpdatedAt time.Time // zero while the tenant has no row
}

// Effective is every key's value in force: the stored one, else the default.
func (c LifecycleConfig) Effective() map[string]any {
	out := make(map[string]any, len(LifecycleKeys))
	for _, k := range LifecycleKeys {
		out[k.Key] = k.Default
		if v, ok := c.Stored[k.Key]; ok {
			out[k.Key] = v
		}
	}
	return out
}

// LifecyclePatch sets (an int, or a string for an enum key) or resets (nil =
// NULL = default) each key it names; a key it does not name is left alone.
type LifecyclePatch map[string]any

// ErrBadLifecycleKey is a patch naming an unknown key or a value out of range.
var ErrBadLifecycleKey = errors.New("bad lifecycle key")

// CheckLifecyclePatch names the first key a patch may not carry ("" = fine),
// with why: the hub's 400 and the store refuse the same as 0105's CHECKs.
// Keys are checked in name order, so with several bad keys the one reported
// is always the alphabetically first, never a map-iteration accident.
func CheckLifecyclePatch(p LifecyclePatch) (key, why string) {
	for _, n := range slices.Sorted(maps.Keys(p)) {
		k, ok := LifecycleKeyByName(n)
		if !ok {
			return n, "is not a lifecycle key"
		}
		if v := p[n]; v != nil && !k.Allows(v) {
			return n, "must be " + k.Range()
		}
	}
	return "", ""
}

// The event vocabulary of spec 063 section 12 (0105's CHECKs).
var (
	LifecycleRoles    = []string{"", "lane", "orch", "master", "failover"}
	LifecycleEventsOK = []string{"restart", "rotate", "rotate_fail", "compact", "handoff",
		"settled", "session_end", "checkpoint", "split", "config_change"}
	LifecycleReasons  = []string{"", "size", "clock", "fail-compact", "done", "checkpoint", "manual"}
	LifecycleOutcomes = []string{"", "ok", "fail"}
)

// Lifecycle limits.
const (
	LifecycleDetailMax    = 200
	LifecycleConfigMax    = 2048 // bytes of the config json
	LifecycleRefetchKeys  = 16
	LifecycleEventsMax    = 200 // rows one list returns at most
	LifecycleRetention    = 90 * 24 * time.Hour
	LifecycleHubWriterBox = "hub" // writer_box of a config_change
)

// LifecycleEvent is one row of agent_lifecycle_events. A nil pointer is NULL
// (not measured).
type LifecycleEvent struct {
	At          time.Time       `json:"at"`
	Fleet       string          `json:"fleet"`
	AgentID     string          `json:"agent_id"`
	AgentBox    string          `json:"agent_box"`
	WriterBox   string          `json:"writer_box"`
	Role        string          `json:"role"`
	Event       string          `json:"event"`
	Reason      string          `json:"reason"`
	RID         string          `json:"rid"`
	CtxBeforeK  *int            `json:"ctx_before_k"`
	CtxAfterK   *int            `json:"ctx_after_k"`
	AgeS        *int            `json:"age_s"`
	Turns       *int            `json:"turns"`
	TokensReadM *float64        `json:"tokens_read_m"`
	HandoffLn   *int            `json:"handoff_lines"`
	HandoffB    *int            `json:"handoff_bytes"`
	NotesLines  *int            `json:"notes_lines"`
	Refetch     map[string]int  `json:"refetch"`
	Config      json.RawMessage `json:"config"`
	Outcome     string          `json:"outcome"`
	Detail      string          `json:"detail"`
}

// CheckLifecycleEvent names the first field an event may not carry ("" =
// fine), the shapes 0105's CHECKs enforce, so a refusal is a 400, not a 500.
func CheckLifecycleEvent(e LifecycleEvent) string {
	in := func(v string, set []string) bool {
		for _, s := range set {
			if v == s {
				return true
			}
		}
		return false
	}
	switch {
	case e.Fleet != "" && !FleetNameRe.MatchString(e.Fleet):
		return "fleet must be a lowercase slug ([a-z0-9-], up to 32)"
	case len(e.AgentID) > 64 || hasControl(e.AgentID):
		return "agent_id must be an agent id of up to 64 bytes"
	case e.AgentBox != "" && !FleetNameRe.MatchString(e.AgentBox):
		return "agent_box must be a desk box id ([a-z0-9-], up to 32)"
	case !in(e.Role, LifecycleRoles):
		return "role must be lane, orch, master or failover"
	case !in(e.Event, LifecycleEventsOK):
		return "event must be one of " + strings.Join(LifecycleEventsOK, ", ")
	case !in(e.Reason, LifecycleReasons):
		return "reason must be size, clock, fail-compact, done, checkpoint or manual"
	case len(e.RID) > 64 || hasControl(e.RID):
		return "rid must be one line of up to 64 bytes"
	case !in(e.Outcome, LifecycleOutcomes):
		return "outcome must be ok or fail"
	case len([]rune(e.Detail)) > LifecycleDetailMax || hasControl(e.Detail):
		return "detail must be one line of up to 200 characters"
	case len(e.Config) > LifecycleConfigMax:
		return "config must be at most 2048 bytes of json"
	case len(e.Refetch) > LifecycleRefetchKeys:
		return "refetch has at most 16 categories"
	}
	for _, p := range []*int{e.CtxBeforeK, e.CtxAfterK, e.AgeS, e.Turns, e.HandoffLn, e.HandoffB, e.NotesLines} {
		if p != nil && *p < 0 {
			return "counts must not be negative"
		}
	}
	if e.TokensReadM != nil && (*e.TokensReadM < 0 || math.IsNaN(*e.TokensReadM) || math.IsInf(*e.TokensReadM, 0)) {
		return "tokens_read_m must not be negative"
	}
	for k, v := range e.Refetch {
		if k == "" || len(k) > 32 || v < 0 {
			return "refetch is {category: count} with non-negative counts"
		}
	}
	if len(e.Config) > 0 {
		var obj map[string]any
		if json.Unmarshal(e.Config, &obj) != nil {
			return "config must be a json object"
		}
	}
	return ""
}

// LifecycleAggregate is one (role, event) group of a window: the numbers the
// admin view and do_spl_context_report show. A nil median is "no sample".
type LifecycleAggregate struct {
	Role            string   `json:"role"`
	Event           string   `json:"event"`
	Count           int      `json:"count"`
	CtxBeforeMedian *float64 `json:"ctx_before_k_median"`
	CtxBeforeP90    *float64 `json:"ctx_before_k_p90"`
	CtxAfterMedian  *float64 `json:"ctx_after_k_median"`
	CtxAfterP90     *float64 `json:"ctx_after_k_p90"`
	Failed          int      `json:"failed"`
	RefetchMean     *float64 `json:"refetch_mean"`
}

// AgentLifecycle is the store half of spec 063 sections 11 and 12. Optional:
// the hub answers 501 on a store without it.
type AgentLifecycle interface {
	// AgentLifecycleConfig reads the tenant's row (no row = every key default).
	AgentLifecycleConfig(ctx context.Context, tenantID string) (LifecycleConfig, error)
	// PatchAgentLifecycleConfig applies p (ErrBadLifecycleKey when
	// CheckLifecyclePatch refuses it), stamps by and now, and appends the
	// config_change event with the old and new effective values of the keys
	// p names, in one transaction. It returns the row before and after.
	PatchAgentLifecycleConfig(ctx context.Context, tenantID string, p LifecyclePatch, by string, now time.Time) (old, cur LifecycleConfig, err error)
	// AppendLifecycleEvent appends one row (the caller has checked it).
	AppendLifecycleEvent(ctx context.Context, tenantID string, e LifecycleEvent) error
	// ListLifecycleEvents is the tenant's events at or after since, newest
	// first, at most limit (capped at LifecycleEventsMax).
	ListLifecycleEvents(ctx context.Context, tenantID string, since time.Time, limit int) ([]LifecycleEvent, error)
	// LifecycleAggregates groups the events at or after since per (role,
	// event), ordered by role then event.
	LifecycleAggregates(ctx context.Context, tenantID string, since time.Time) ([]LifecycleAggregate, error)
	// PruneLifecycleEvents deletes every tenant's events older than before
	// (the hub's retention sweep) and counts them.
	PruneLifecycleEvents(ctx context.Context, before time.Time) (int, error)
}

// configChange is the config_change event of a patch: config carries the
// old and new effective values of the keys it named; detail names them.
func configChange(p LifecyclePatch, old, cur LifecycleConfig, by string, now time.Time) LifecycleEvent {
	oe, ne := old.Effective(), cur.Effective()
	keys := make([]string, 0, len(p))
	ov, nv := map[string]any{}, map[string]any{}
	for k := range p {
		keys = append(keys, k)
		ov[k], nv[k] = oe[k], ne[k]
	}
	slices.Sort(keys)
	raw, _ := json.Marshal(map[string]map[string]any{"old": ov, "new": nv}) //nolint:errchkjson // ints and strings only
	detail := strings.Join(keys, ",")
	if len(detail) > LifecycleDetailMax {
		detail = detail[:LifecycleDetailMax]
	}
	return LifecycleEvent{At: now, AgentID: by, WriterBox: LifecycleHubWriterBox, Event: "config_change",
		Reason: "manual", Config: raw, Outcome: "ok", Detail: detail}
}

// ClampLifecycleLimit is a list limit in 1..LifecycleEventsMax (<= 0 = 50).
func ClampLifecycleLimit(n int) int {
	switch {
	case n <= 0:
		return 50
	case n > LifecycleEventsMax:
		return LifecycleEventsMax
	}
	return n
}

// percentile is percentile_cont over sorted xs (linear interpolation), the
// Postgres aggregate the pg driver uses, so both drivers agree.
func percentile(xs []float64, p float64) *float64 {
	if len(xs) == 0 {
		return nil
	}
	pos := p * float64(len(xs)-1)
	lo := int(math.Floor(pos))
	hi := int(math.Ceil(pos))
	v := xs[lo] + (xs[hi]-xs[lo])*(pos-float64(lo))
	return &v
}

// aggregateLifecycle is the Memory driver's LifecycleAggregates, and the
// reference the pg driver's SQL is tested against.
func aggregateLifecycle(evs []LifecycleEvent) []LifecycleAggregate {
	type acc struct {
		a             LifecycleAggregate
		before, after []float64
		refetch       []float64
	}
	groups := map[[2]string]*acc{}
	for _, e := range evs {
		k := [2]string{e.Role, e.Event}
		g := groups[k]
		if g == nil {
			g = &acc{a: LifecycleAggregate{Role: e.Role, Event: e.Event}}
			groups[k] = g
		}
		g.a.Count++
		if e.Outcome == "fail" {
			g.a.Failed++
		}
		if e.CtxBeforeK != nil {
			g.before = append(g.before, float64(*e.CtxBeforeK))
		}
		if e.CtxAfterK != nil {
			g.after = append(g.after, float64(*e.CtxAfterK))
		}
		if e.Refetch != nil {
			n := 0
			for _, v := range e.Refetch {
				n += v
			}
			g.refetch = append(g.refetch, float64(n))
		}
	}
	out := make([]LifecycleAggregate, 0, len(groups))
	for _, g := range groups {
		sort.Float64s(g.before)
		sort.Float64s(g.after)
		g.a.CtxBeforeMedian, g.a.CtxBeforeP90 = percentile(g.before, 0.5), percentile(g.before, 0.9)
		g.a.CtxAfterMedian, g.a.CtxAfterP90 = percentile(g.after, 0.5), percentile(g.after, 0.9)
		if len(g.refetch) > 0 {
			sum := 0.0
			for _, v := range g.refetch {
				sum += v
			}
			m := sum / float64(len(g.refetch))
			g.a.RefetchMean = &m
		}
		out = append(out, g.a)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Role != out[j].Role {
			return out[i].Role < out[j].Role
		}
		return out[i].Event < out[j].Event
	})
	return out
}

// The Memory driver keeps its lifecycle state beside the store rather than in
// it (memory.go is shared by every lane): one entry per *Memory, under its
// own lock.
type memLifecycle struct {
	cfg    map[string]LifecycleConfig
	events map[string][]LifecycleEvent // per tenant, in append order
}

var (
	memLifecycleMu sync.Mutex
	memLifecycles  = map[*Memory]*memLifecycle{}
)

func (s *Memory) lifecycle() *memLifecycle {
	l := memLifecycles[s]
	if l == nil {
		l = &memLifecycle{cfg: map[string]LifecycleConfig{}, events: map[string][]LifecycleEvent{}}
		memLifecycles[s] = l
	}
	return l
}

func copyLifecycleConfig(c LifecycleConfig) LifecycleConfig {
	st := make(map[string]any, len(c.Stored))
	for k, v := range c.Stored {
		st[k] = v
	}
	c.Stored = st
	return c
}

func (s *Memory) AgentLifecycleConfig(_ context.Context, tenant string) (LifecycleConfig, error) {
	memLifecycleMu.Lock()
	defer memLifecycleMu.Unlock()
	return copyLifecycleConfig(s.lifecycle().cfg[tenant]), nil
}

func (s *Memory) PatchAgentLifecycleConfig(_ context.Context, tenant string, p LifecyclePatch, by string, now time.Time) (LifecycleConfig, LifecycleConfig, error) {
	if k, why := CheckLifecyclePatch(p); k != "" {
		return LifecycleConfig{}, LifecycleConfig{}, fmt.Errorf("%w: %s %s", ErrBadLifecycleKey, k, why)
	}
	memLifecycleMu.Lock()
	defer memLifecycleMu.Unlock()
	l := s.lifecycle()
	old := copyLifecycleConfig(l.cfg[tenant])
	cur := copyLifecycleConfig(old)
	for k, v := range p {
		if v == nil {
			delete(cur.Stored, k)
		} else {
			cur.Stored[k] = v
		}
	}
	cur.UpdatedBy, cur.UpdatedAt = by, now.UTC()
	l.cfg[tenant] = cur
	l.events[tenant] = append(l.events[tenant], configChange(p, old, cur, by, now.UTC()))
	return old, copyLifecycleConfig(cur), nil
}

func (s *Memory) AppendLifecycleEvent(_ context.Context, tenant string, e LifecycleEvent) error {
	memLifecycleMu.Lock()
	defer memLifecycleMu.Unlock()
	l := s.lifecycle()
	e.At = e.At.UTC()
	l.events[tenant] = append(l.events[tenant], e)
	return nil
}

// memLifecycleSince is the tenant's events at or after since, newest first.
func (s *Memory) memLifecycleSince(tenant string, since time.Time) []LifecycleEvent {
	memLifecycleMu.Lock()
	defer memLifecycleMu.Unlock()
	var out []LifecycleEvent
	for _, e := range s.lifecycle().events[tenant] {
		if !e.At.Before(since) {
			out = append(out, e)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out
}

func (s *Memory) ListLifecycleEvents(_ context.Context, tenant string, since time.Time, limit int) ([]LifecycleEvent, error) {
	out := s.memLifecycleSince(tenant, since)
	if n := ClampLifecycleLimit(limit); len(out) > n {
		out = out[:n]
	}
	if out == nil {
		out = []LifecycleEvent{}
	}
	return out, nil
}

func (s *Memory) LifecycleAggregates(_ context.Context, tenant string, since time.Time) ([]LifecycleAggregate, error) {
	return aggregateLifecycle(s.memLifecycleSince(tenant, since)), nil
}

func (s *Memory) PruneLifecycleEvents(_ context.Context, before time.Time) (int, error) {
	memLifecycleMu.Lock()
	defer memLifecycleMu.Unlock()
	n := 0
	l := s.lifecycle()
	for t, evs := range l.events {
		kept := evs[:0]
		for _, e := range evs {
			if e.At.Before(before) {
				n++
				continue
			}
			kept = append(kept, e)
		}
		l.events[t] = kept
	}
	return n, nil
}
