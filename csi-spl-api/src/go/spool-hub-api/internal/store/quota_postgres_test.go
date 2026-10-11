package store

import (
	"context"
	"testing"
	"time"
)

// spec 121 T205 follow-up: the demo counters (admission demo_visit and
// demo_signup, the hub's agent_turn, post_min and post_day) were deleted by
// no sweep; SweepQuota drops them, run as the runtime role under FORCE RLS.

// TestSweepQuotaDemoKinds: per demo kind, a row whose window started before
// the keep goes and a live one stays. RED CONTROL: SweepEmbed, the only
// counter sweep before, leaves every expired demo row. CONTROL: an unnamed
// kind of the same age and another workspace's expired row stay (the
// statement names its kinds and runs in the tenant's own scope); a second
// sweep drops nothing.
func TestSweepQuotaDemoKinds(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Hour)
	a, b := newTenant(t, pg), newTenant(t, pg)
	kinds := append([]string{"agent_turn", "post_min", "post_day"}, DemoAdmitQuotaKinds...)
	if len(kinds) != 5 {
		t.Fatalf("CONTROL: demo kinds = %v, want 5", kinds)
	}
	stale, before := now.Add(-72*time.Hour), now.Add(-48*time.Hour)
	take := func(tenant, kind string, window time.Time) {
		t.Helper()
		if _, ok, err := rt.TakeQuota(ctx, tenant, "k", kind, window, 9); err != nil || !ok {
			t.Fatalf("seed %s %s %v: %v %v", tenant, kind, window, ok, err)
		}
	}
	for _, k := range kinds {
		take(a, k, stale)
		take(a, k, now)
	}
	take(a, "other_kind", stale)
	take(b, "post_day", stale)
	if _, err := rt.SweepEmbed(ctx, now, before, now.Add(-24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	for _, k := range kinds {
		if quotaN(t, pg, a, "k", k, stale) != 1 {
			t.Fatalf("RED CONTROL: SweepEmbed dropped the expired %s row: the test proves nothing", k)
		}
	}
	n, err := rt.SweepQuota(ctx, a, kinds, before)
	if err != nil || n != len(kinds) {
		t.Fatalf("sweep = %d, %v; want %d", n, err, len(kinds))
	}
	for _, k := range kinds {
		if got := quotaN(t, pg, a, "k", k, stale); got != 0 {
			t.Errorf("%s: the expired row stayed (n = %d)", k, got)
		}
		if got := quotaN(t, pg, a, "k", k, now); got != 1 {
			t.Errorf("%s: the live row went (n = %d)", k, got)
		}
	}
	if quotaN(t, pg, a, "k", "other_kind", stale) != 1 {
		t.Error("CONTROL: an unnamed kind was dropped")
	}
	if quotaN(t, pg, b, "k", "post_day", stale) != 1 {
		t.Error("CONTROL: another workspace's row was dropped")
	}
	if again, err := rt.SweepQuota(ctx, a, kinds, before); err != nil || again != 0 {
		t.Errorf("a second sweep = %d, %v; want 0", again, err)
	}
	if none, err := rt.SweepQuota(ctx, a, nil, now.Add(time.Hour)); err != nil || none != 0 {
		t.Errorf("no kinds = %d, %v; want 0", none, err)
	}
}
