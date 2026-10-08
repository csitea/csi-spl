package store

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"slices"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// The fleet load target (rdb 0118, owner HUM-10 t1 c13e8023): the band a
// box's load should stay in (% of cores, load5 / cpus) and the order the
// boxes take new agent lanes. It is the INSTANCE's setting: the hub reads and
// writes it on the operator workspace's row only (rdb 0116), and only that
// workspace's admin changes it. NULL = the default below, as in rdb 0105.
//
// rdb 0134 (owner HUM-10, t1 29b19f85: "target hw load per box"): a box may
// carry its own band (Boxes), which overrides the fleet band for that box
// only; a box not named takes Low / High.
//
// rdb 0149 (owner HUM-10, t1 41fa1f2d: "a setting to disable certain type of
// ai agents"): AgentKindsOff names the agent kinds no box starts a new lane
// of, never all of them. Paused is a timed off a box reports when a lane of
// that kind hit its usage limit, so every box skips the kind until then.
//
// rdb 0152 (owner HUM-10, t1 338e5258 b3573121: "there will be always some
// 20% extra capacity"): RunnerCPUPct is the % of a box's cores CI runners
// plus agents may use (csi-spl-orc do_apply_gh_runner_cpu_budget); a box's
// band may carry its own, which overrides it for that box only.

// AgentKinds are the agent kinds a box can start a lane of (the launchers
// /claude-spawn, /grok-spawn, /agy-spawn, /qwen-spawn).
var AgentKinds = []string{"claude", "grok", "agy", "qwen"}

// BoxBand is one box's band, % of cores, and its own runner CPU cap
// (rdb 0152; 0 = the fleet's RunnerCPUPct).
type BoxBand struct {
	Low          int `json:"low"`
	High         int `json:"high"`
	RunnerCPUPct int `json:"runner_cpu_pct,omitempty"`
}

// KindPause is one kind's timed pause (rdb 0149).
type KindPause struct {
	Until  time.Time `json:"until"`
	Reason string    `json:"reason"`
	Box    string    `json:"box"` // the box that reported it; empty = the admin
}

// MaxKindPause bounds a pause: a weekly usage limit, plus a day.
const MaxKindPause = 8 * 24 * time.Hour

// MaxPauseReason bounds KindPause.Reason, in characters.
const MaxPauseReason = 200

// FleetLoad is the target in force.
type FleetLoad struct {
	Low      int      `json:"low"`
	High     int      `json:"high"`
	BoxOrder []string `json:"box_order"` // empty = the box's cnf seed order
	// Boxes is the per-box override (rdb 0134); empty = every box on Low / High.
	Boxes map[string]BoxBand `json:"boxes"`
	// AgentKindsOff (rdb 0149): the kinds switched off; empty = every kind on.
	AgentKindsOff []string `json:"agent_kinds_off"`
	// Paused (rdb 0149): the timed pauses as stored, run-out ones included;
	// LivePauses keeps the running ones.
	Paused map[string]KindPause `json:"agent_kinds_paused"`
	// RunnerCPUPct (rdb 0152): the % of a box's cores CI plus agents may use.
	RunnerCPUPct int `json:"runner_cpu_pct"`
}

// FleetLoadStored is what the row holds; nil = unset (the default).
type FleetLoadStored struct {
	Low      *int               `json:"low"`
	High     *int               `json:"high"`
	BoxOrder []string           `json:"box_order"` // nil = unset
	Boxes    map[string]BoxBand `json:"boxes"`     // nil = unset (rdb 0134)
	// AgentKindsOff, Paused: rdb 0149; nil = unset.
	AgentKindsOff []string             `json:"agent_kinds_off"`
	Paused        map[string]KindPause `json:"agent_kinds_paused"`
	RunnerCPUPct  *int                 `json:"runner_cpu_pct"` // nil = unset (rdb 0152)
}

// FleetLoadPatch changes the fields whose Set flag is true; a nil value
// with its flag set resets that field to the default. Boxes replaces the
// whole per-box map; an empty one resets it. AgentKindsOff replaces the
// whole set. Pauses merges per kind: a nil pause lifts that kind's pause.
// Every write that touches the pauses drops the ones run out by Now.
type FleetLoadPatch struct {
	LowSet, HighSet, OrderSet, BoxesSet, KindsOffSet, RunnerCPUSet bool
	Low, High, RunnerCPUPct                                        *int
	BoxOrder                                                       []string
	Boxes                                                          map[string]BoxBand
	AgentKindsOff                                                  []string
	Pauses                                                         map[string]*KindPause
	Now                                                            time.Time // zero = time.Now()
}

// MaxFleetBoxes is the rdb 0118 CHECK on cardinality(fleet_box_order).
const MaxFleetBoxes = 32

// DefaultRunnerCPUPct is the owner's runner CPU cap: 20 % of every box kept free.
const DefaultRunnerCPUPct = 80

// DefaultFleetLoad is the owner's band (50..75 %) with no order of its own,
// every agent kind on and the runner CPU cap at DefaultRunnerCPUPct.
func DefaultFleetLoad() FleetLoad {
	return FleetLoad{Low: 50, High: 75, BoxOrder: []string{}, Boxes: map[string]BoxBand{},
		AgentKindsOff: []string{}, Paused: map[string]KindPause{}, RunnerCPUPct: DefaultRunnerCPUPct}
}

// ErrBadFleetLoad: a mark outside the rdb checks, low >= high, a box order
// that is not distinct box ids, a per-box band that is not a box id with a
// valid band, kinds off that are not distinct kinds or name every kind, or a
// pause that is not a kind with an until, a short reason and a box id, or a
// runner CPU cap outside 1..100.
var ErrBadFleetLoad = errors.New("store: bad fleet load target")

// Effective is the target in force for a stored row.
func (f FleetLoadStored) Effective() FleetLoad {
	out := DefaultFleetLoad()
	if f.Low != nil {
		out.Low = *f.Low
	}
	if f.High != nil {
		out.High = *f.High
	}
	if f.BoxOrder != nil {
		out.BoxOrder = slices.Clone(f.BoxOrder)
	}
	if f.Boxes != nil {
		out.Boxes = maps.Clone(f.Boxes)
	}
	if f.AgentKindsOff != nil {
		out.AgentKindsOff = slices.Clone(f.AgentKindsOff)
	}
	if f.Paused != nil {
		out.Paused = maps.Clone(f.Paused)
	}
	if f.RunnerCPUPct != nil {
		out.RunnerCPUPct = *f.RunnerCPUPct
	}
	return out
}

// LivePauses is f with only the pauses still running at now.
func (f FleetLoad) LivePauses(now time.Time) FleetLoad {
	live := map[string]KindPause{}
	for k, p := range f.Paused {
		if p.Until.After(now) {
			live[k] = p
		}
	}
	f.Paused = live
	return f
}

// apply is f with p applied.
func (f FleetLoadStored) apply(p FleetLoadPatch) FleetLoadStored {
	if p.LowSet {
		f.Low = p.Low
	}
	if p.HighSet {
		f.High = p.High
	}
	if p.OrderSet {
		f.BoxOrder = slices.Clone(p.BoxOrder)
		if len(f.BoxOrder) == 0 {
			f.BoxOrder = nil
		}
	}
	if p.BoxesSet {
		f.Boxes = maps.Clone(p.Boxes)
		if len(f.Boxes) == 0 {
			f.Boxes = nil
		}
	}
	if p.KindsOffSet {
		f.AgentKindsOff = slices.Clone(p.AgentKindsOff)
		if len(f.AgentKindsOff) == 0 {
			f.AgentKindsOff = nil
		}
	}
	if p.RunnerCPUSet {
		f.RunnerCPUPct = p.RunnerCPUPct
	}
	if len(p.Pauses) > 0 {
		f.Paused = mergePauses(f.Paused, p.Pauses, p.Now)
	}
	return f
}

// mergePauses is cur without the pauses run out by now, with each of add
// set, or lifted when nil; nil when none is left.
func mergePauses(cur map[string]KindPause, add map[string]*KindPause, now time.Time) map[string]KindPause {
	if now.IsZero() {
		now = time.Now()
	}
	next := map[string]KindPause{}
	for k, v := range cur {
		if v.Until.After(now) {
			next[k] = v
		}
	}
	for k, v := range add {
		if v == nil {
			delete(next, k)
		} else {
			next[k] = *v
		}
	}
	if len(next) == 0 {
		return nil
	}
	return next
}

// CheckFleetLoad is nil when the stored row is valid: each set mark within
// the rdb 0118 range, low < high on the values in force, and the order
// distinct box ids, at most MaxFleetBoxes; each per-box band a box id with
// both marks in range and low < high, at most MaxFleetBoxes of them; each
// runner CPU cap 1..100 (a box's 0 = the fleet's); the agent kinds as
// checkAgentKinds.
func CheckFleetLoad(f FleetLoadStored) error {
	if f.Low != nil && (*f.Low < 1 || *f.Low > 99) {
		return ErrBadFleetLoad
	}
	if f.High != nil && (*f.High < 2 || *f.High > 100) {
		return ErrBadFleetLoad
	}
	if f.RunnerCPUPct != nil && (*f.RunnerCPUPct < 1 || *f.RunnerCPUPct > 100) {
		return ErrBadFleetLoad
	}
	if e := f.Effective(); e.Low >= e.High {
		return ErrBadFleetLoad
	}
	if len(f.BoxOrder) > MaxFleetBoxes {
		return ErrBadFleetLoad
	}
	seen := map[string]bool{}
	for _, b := range f.BoxOrder {
		if !FleetNameRe.MatchString(b) || seen[b] {
			return ErrBadFleetLoad
		}
		seen[b] = true
	}
	if len(f.Boxes) > MaxFleetBoxes {
		return ErrBadFleetLoad
	}
	for b, band := range f.Boxes {
		if !FleetNameRe.MatchString(b) || band.Low < 1 || band.Low > 99 || band.High < 2 || band.High > 100 || band.Low >= band.High ||
			band.RunnerCPUPct < 0 || band.RunnerCPUPct > 100 {
			return ErrBadFleetLoad
		}
	}
	return checkAgentKinds(f)
}

// checkAgentKinds: the kinds off are distinct known kinds and not every one
// of them; each pause is a known kind with an until, a reason of at most
// MaxPauseReason characters and a box id or no box.
func checkAgentKinds(f FleetLoadStored) error {
	seen := map[string]bool{}
	for _, k := range f.AgentKindsOff {
		if !slices.Contains(AgentKinds, k) || seen[k] {
			return ErrBadFleetLoad
		}
		seen[k] = true
	}
	if len(seen) == len(AgentKinds) {
		return ErrBadFleetLoad
	}
	for k, p := range f.Paused {
		if !slices.Contains(AgentKinds, k) || p.Until.IsZero() || utf8.RuneCountInString(p.Reason) > MaxPauseReason ||
			(p.Box != "" && !FleetNameRe.MatchString(p.Box)) {
			return ErrBadFleetLoad
		}
	}
	return nil
}

// FleetLoadTarget is implemented by Memory and Postgres.
type FleetLoadTarget interface {
	// FleetLoadOf reads the tenant's stored target; ErrNotFound: no tenant.
	FleetLoadOf(ctx context.Context, tenant string) (FleetLoadStored, error)
	// SetFleetLoad applies p and answers the stored row after it;
	// ErrBadFleetLoad leaves the row as it was.
	SetFleetLoad(ctx context.Context, tenant string, p FleetLoadPatch) (FleetLoadStored, error)
}

var (
	_ FleetLoadTarget = (*Memory)(nil)
	_ FleetLoadTarget = (*Postgres)(nil)
)

// ---- Memory -----------------------------------------------------------------

func (s *Memory) FleetLoadOf(_ context.Context, tenant string) (FleetLoadStored, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return FleetLoadStored{}, ErrNotFound
	}
	return s.fleetLoad[tenant], nil
}

func (s *Memory) SetFleetLoad(_ context.Context, tenant string, p FleetLoadPatch) (FleetLoadStored, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return FleetLoadStored{}, ErrNotFound
	}
	next := s.fleetLoad[tenant].apply(p)
	if err := CheckFleetLoad(next); err != nil {
		return FleetLoadStored{}, err
	}
	if s.fleetLoad == nil {
		s.fleetLoad = map[string]FleetLoadStored{}
	}
	s.fleetLoad[tenant] = next
	return next, nil
}

// ---- Postgres ---------------------------------------------------------------

const fleetLoadCols = `fleet_load_low, fleet_load_high, fleet_box_order, fleet_box_bands,
	fleet_agent_kinds_off, fleet_agent_kinds_paused, fleet_runner_cpu_pct`

func scanFleetLoad(row pgx.Row) (FleetLoadStored, error) {
	var f FleetLoadStored
	var low, high, cpu *int16
	var bands, paused []byte
	if err := row.Scan(&low, &high, &f.BoxOrder, &bands, &f.AgentKindsOff, &paused, &cpu); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return FleetLoadStored{}, ErrNotFound
		}
		return FleetLoadStored{}, err
	}
	if low != nil {
		v := int(*low)
		f.Low = &v
	}
	if high != nil {
		v := int(*high)
		f.High = &v
	}
	if cpu != nil {
		v := int(*cpu)
		f.RunnerCPUPct = &v
	}
	if bands != nil {
		if err := json.Unmarshal(bands, &f.Boxes); err != nil {
			return FleetLoadStored{}, err
		}
	}
	if paused != nil {
		if err := json.Unmarshal(paused, &f.Paused); err != nil {
			return FleetLoadStored{}, err
		}
	}
	return f, nil
}

func (s *Postgres) FleetLoadOf(ctx context.Context, tenant string) (FleetLoadStored, error) {
	var f FleetLoadStored
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) (err error) {
		f, err = scanFleetLoad(tx.QueryRow(ctx, `SELECT `+fleetLoadCols+` FROM tenants WHERE tenant_id = $1`, tenant))
		return err
	})
	return f, err
}

func (s *Postgres) SetFleetLoad(ctx context.Context, tenant string, p FleetLoadPatch) (FleetLoadStored, error) {
	var next FleetLoadStored
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		cur, err := scanFleetLoad(tx.QueryRow(ctx, `SELECT `+fleetLoadCols+` FROM tenants WHERE tenant_id = $1 FOR UPDATE`, tenant))
		if err != nil {
			return err
		}
		next = cur.apply(p)
		if err := CheckFleetLoad(next); err != nil {
			return err
		}
		var bands, paused []byte
		if next.Boxes != nil {
			if bands, err = json.Marshal(next.Boxes); err != nil {
				return err
			}
		}
		if next.Paused != nil {
			if paused, err = json.Marshal(next.Paused); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, `UPDATE tenants SET fleet_load_low = $2, fleet_load_high = $3, fleet_box_order = $4,
			fleet_box_bands = $5::jsonb, fleet_agent_kinds_off = $6, fleet_agent_kinds_paused = $7::jsonb,
			fleet_runner_cpu_pct = $8
			WHERE tenant_id = $1`, tenant, next.Low, next.High, next.BoxOrder, bands, next.AgentKindsOff, paused,
			next.RunnerCPUPct)
		return err
	})
	if err != nil {
		return FleetLoadStored{}, err
	}
	return next, nil
}
