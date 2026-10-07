package store

import (
	"context"
	"errors"
	"maps"
	"slices"
	"testing"
	"time"
)

// rdb 0118: the fleet load target. A fresh row is the default 50 / 75 with
// no order; a patch sets, a null resets, low >= high or a bad box order is
// refused and leaves the row; another tenant's row is its own. A value the
// Go side refuses is a value the table refuses. Run on Memory and Postgres.
func TestFleetLoadTarget(t *testing.T) {
	ctx := context.Background()
	n := func(v int) *int { return &v }
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fl, ok := st.(FleetLoadTarget)
			if !ok {
				t.Fatalf("%s keeps no fleet load target", name)
			}
			tid, other := newTenant(t, st), newTenant(t, st)
			got, err := fl.FleetLoadOf(ctx, tid)
			if err != nil || got.Low != nil || got.High != nil || got.BoxOrder != nil {
				t.Fatalf("fresh row = %+v, %v; want all unset", got, err)
			}
			if e := got.Effective(); e.Low != 50 || e.High != 75 || len(e.BoxOrder) != 0 {
				t.Fatalf("default in force = %+v, want 50/75 and no order", e)
			}
			got, err = fl.SetFleetLoad(ctx, tid, FleetLoadPatch{LowSet: true, Low: n(40), HighSet: true, High: n(80),
				OrderSet: true, BoxOrder: []string{"box-a", "box-b"}})
			if err != nil || *got.Low != 40 || *got.High != 80 || !slices.Equal(got.BoxOrder, []string{"box-a", "box-b"}) {
				t.Fatalf("set = %+v, %v", got, err)
			}
			for _, bad := range []FleetLoadPatch{
				{HighSet: true, High: n(40)},                   // high == low in force
				{LowSet: true, Low: n(85)},                     // low above high in force
				{LowSet: true, Low: n(0)},                      // below the CHECK
				{HighSet: true, High: n(101)},                  // above the CHECK
				{OrderSet: true, BoxOrder: []string{"Box-s"}},  // not a box id
				{OrderSet: true, BoxOrder: []string{"a", "a"}}, // not distinct
			} {
				if _, err := fl.SetFleetLoad(ctx, tid, bad); !errors.Is(err, ErrBadFleetLoad) {
					t.Errorf("patch %+v: %v, want ErrBadFleetLoad", bad, err)
				}
			}
			if got, _ = fl.FleetLoadOf(ctx, tid); *got.Low != 40 || *got.High != 80 || len(got.BoxOrder) != 2 {
				t.Fatalf("a refused patch changed the row: %+v", got)
			}
			if o, _ := fl.FleetLoadOf(ctx, other); o.Low != nil || o.BoxOrder != nil {
				t.Fatalf("another tenant sees the row: %+v", o)
			}
			got, err = fl.SetFleetLoad(ctx, tid, FleetLoadPatch{LowSet: true, OrderSet: true})
			if err != nil || got.Low != nil || got.BoxOrder != nil || *got.High != 80 {
				t.Fatalf("reset low + order = %+v, %v", got, err)
			}
			if got, _ = fl.FleetLoadOf(ctx, tid); got.Effective().Low != 50 || got.BoxOrder != nil {
				t.Fatalf("after reset = %+v", got)
			}
			if _, err := fl.FleetLoadOf(ctx, "no-such-tenant"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("missing tenant: %v, want ErrNotFound", err)
			}
		})
	}
}

// rdb 0134: a per-box band overrides the fleet band for the boxes it names.
// A patch replaces the whole map, an empty map resets it, a bad entry (not a
// box id, a mark out of range, low >= high) is refused and leaves the row,
// and the fleet band stays the default for every other box.
func TestFleetLoadBoxBands(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fl := st.(FleetLoadTarget)
			tid := newTenant(t, st)
			bands := map[string]BoxBand{"box-s": {Low: 60, High: 90}, "box-t": {Low: 20, High: 40}}
			got, err := fl.SetFleetLoad(ctx, tid, FleetLoadPatch{BoxesSet: true, Boxes: bands})
			if err != nil || !maps.Equal(got.Boxes, bands) || got.Low != nil {
				t.Fatalf("set boxes = %+v, %v", got, err)
			}
			if got, _ = fl.FleetLoadOf(ctx, tid); !maps.Equal(got.Boxes, bands) {
				t.Fatalf("read back = %+v", got.Boxes)
			}
			if e := got.Effective(); e.Low != 50 || e.High != 75 || e.Boxes["box-s"].High != 90 {
				t.Fatalf("in force = %+v", e)
			}
			for _, bad := range []map[string]BoxBand{
				{"Box-s": {Low: 60, High: 90}},  // not a box id
				{"box-s": {Low: 90, High: 90}},  // low == high
				{"box-s": {Low: 0, High: 50}},   // low below 1
				{"box-s": {Low: 50, High: 101}}, // high above 100
			} {
				if _, err := fl.SetFleetLoad(ctx, tid, FleetLoadPatch{BoxesSet: true, Boxes: bad}); !errors.Is(err, ErrBadFleetLoad) {
					t.Errorf("boxes %+v: %v, want ErrBadFleetLoad", bad, err)
				}
			}
			if got, _ = fl.FleetLoadOf(ctx, tid); !maps.Equal(got.Boxes, bands) {
				t.Fatalf("a refused patch changed the boxes: %+v", got.Boxes)
			}
			got, err = fl.SetFleetLoad(ctx, tid, FleetLoadPatch{BoxesSet: true, Boxes: map[string]BoxBand{}})
			if err != nil || got.Boxes != nil {
				t.Fatalf("reset boxes = %+v, %v", got, err)
			}
			if got, _ = fl.FleetLoadOf(ctx, tid); got.Boxes != nil || len(got.Effective().Boxes) != 0 {
				t.Fatalf("after reset = %+v", got)
			}
		})
	}
}

// rdb 0149: the agent kinds switched off, and the timed pauses. A set
// replaces the kinds; every kind off, an unknown kind or a duplicate is
// refused and leaves the row; an empty set resets it. A pause merges per
// kind, a nil one lifts it, a write drops the pauses run out, and a pause
// with an unknown kind, no until or a bad box is refused. Control: the
// load band is untouched by either.
func TestFleetLoadAgentKinds(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fl := st.(FleetLoadTarget)
			tid := newTenant(t, st)
			if e := (FleetLoadStored{}).Effective(); len(e.AgentKindsOff) != 0 || len(e.Paused) != 0 {
				t.Fatalf("default = %+v, want every kind on", e)
			}
			got, err := fl.SetFleetLoad(ctx, tid, FleetLoadPatch{KindsOffSet: true, AgentKindsOff: []string{"grok", "qwen"}})
			if err != nil || !slices.Equal(got.AgentKindsOff, []string{"grok", "qwen"}) || got.Low != nil {
				t.Fatalf("set kinds off = %+v, %v", got, err)
			}
			for _, bad := range [][]string{
				{"claude", "grok", "agy", "qwen"}, // every kind off
				{"gpt"},                           // not a kind
				{"grok", "grok"},                  // not distinct
			} {
				if _, err := fl.SetFleetLoad(ctx, tid, FleetLoadPatch{KindsOffSet: true, AgentKindsOff: bad}); !errors.Is(err, ErrBadFleetLoad) {
					t.Errorf("kinds off %v: %v, want ErrBadFleetLoad", bad, err)
				}
			}
			if got, _ = fl.FleetLoadOf(ctx, tid); !slices.Equal(got.AgentKindsOff, []string{"grok", "qwen"}) {
				t.Fatalf("a refused patch changed the kinds: %+v", got.AgentKindsOff)
			}
			week := &KindPause{Until: now.Add(6 * time.Hour), Reason: "weekly limit", Box: "box-s"}
			old := &KindPause{Until: now.Add(-time.Minute), Reason: "ran out"}
			got, err = fl.SetFleetLoad(ctx, tid, FleetLoadPatch{Now: now.Add(-time.Hour),
				Pauses: map[string]*KindPause{"agy": week, "claude": old}})
			if err != nil || len(got.Paused) != 2 || !got.Paused["agy"].Until.Equal(week.Until) {
				t.Fatalf("pause = %+v, %v", got.Paused, err)
			}
			if got, _ = fl.FleetLoadOf(ctx, tid); got.Paused["agy"].Box != "box-s" || got.Paused["agy"].Reason != "weekly limit" {
				t.Fatalf("pause read back = %+v", got.Paused)
			}
			if live := got.Effective().LivePauses(now); len(live.Paused) != 1 || live.Paused["agy"].Reason == "" {
				t.Fatalf("live pauses at now = %+v, want agy only", live.Paused)
			}
			got, err = fl.SetFleetLoad(ctx, tid, FleetLoadPatch{Now: now, Pauses: map[string]*KindPause{"grok": week}})
			if err != nil || len(got.Paused) != 2 || got.Paused["claude"].Reason != "" {
				t.Fatalf("a write keeps the run-out pause: %+v, %v", got.Paused, err)
			}
			for _, bad := range []map[string]*KindPause{
				{"gpt": week},                               // not a kind
				{"grok": {Reason: "no until"}},              // no until
				{"grok": {Until: week.Until, Box: "Box-S"}}, // not a box id
				{"grok": {Until: week.Until, Reason: string(make([]byte, MaxPauseReason+1))}}, // reason too long
			} {
				if _, err := fl.SetFleetLoad(ctx, tid, FleetLoadPatch{Now: now, Pauses: bad}); !errors.Is(err, ErrBadFleetLoad) {
					t.Errorf("pause %+v: %v, want ErrBadFleetLoad", bad, err)
				}
			}
			got, err = fl.SetFleetLoad(ctx, tid, FleetLoadPatch{Now: now, Pauses: map[string]*KindPause{"grok": nil, "agy": nil},
				KindsOffSet: true})
			if err != nil || got.Paused != nil || got.AgentKindsOff != nil {
				t.Fatalf("lift + reset = %+v, %v", got, err)
			}
			if got, _ = fl.FleetLoadOf(ctx, tid); got.Paused != nil || got.AgentKindsOff != nil || got.Effective().Low != 50 {
				t.Fatalf("after reset = %+v", got)
			}
		})
	}
}
