package store

import (
	"context"
	"errors"
	"slices"
	"testing"
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
				{OrderSet: true, BoxOrder: []string{"Sat"}},    // not a box id
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
