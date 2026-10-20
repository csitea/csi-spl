package store

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// Spec 147 R1 (SPL-2675): per-workspace agent caps by vendor. Memory always,
// Postgres with a DSN (hub-pg.tst.sh, PRE_PUSH_TIER=full).

func capOf(n int) *int { return &n }

var capOperator = AgentCapActor{Tenant: "ops", Hum: "HUM-1"}

// setCaps writes caps as the operator, failing the test on an error.
func setCaps(t *testing.T, s Store, tid string, caps map[string]*int, now time.Time) AgentCaps {
	t.Helper()
	c, err := s.(AgentCapStore).SetAgentCaps(context.Background(), tid, caps, capOperator, now)
	if err != nil {
		t.Fatalf("SetAgentCaps: %v", err)
	}
	return c
}

// seat stamps box's presence at at and announces agents at now.
func seat(s Store, tid, box string, at, now time.Time, agents ...string) error {
	ctx := context.Background()
	if err := s.TouchBox(ctx, tid, box, at); err != nil {
		return err
	}
	return s.SetRoster(ctx, tid, box, agents, now)
}

// TestVendorCapGate is spec 147's R1 red control (C1): with claude capped at
// 1, a 2nd claude in SetRoster is ErrVendorCapExceeded. Without the gate it
// seats, and this test fails.
func TestVendorCapGate(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			setCaps(t, s, tid, map[string]*int{"claude": capOf(1), "agy": capOf(2), "grok": capOf(0)}, now)
			if err := seat(s, tid, "box-a", now, now, "c-004"); err != nil {
				t.Fatalf("first claude of cap 1: %v", err)
			}
			err := seat(s, tid, "box-b", now, now, "c-005")
			var capErr *VendorCapError
			if !errors.Is(err, ErrVendorCapExceeded) || !errors.As(err, &capErr) {
				t.Fatalf("2nd claude over cap 1: got %v, want ErrVendorCapExceeded", err)
			}
			if capErr.Vendor != "claude" || capErr.Cap != 1 || capErr.Live != 2 || capErr.Tenant != tid {
				t.Fatalf("cap error detail: %+v", capErr)
			}
			want := "refused: claude agent cap reached for workspace " + tid + ": max 1 live, requested 2 live"
			if capErr.Error() != want {
				t.Fatalf("message %q, want %q", capErr.Error(), want)
			}
			// Nothing was written: box-b holds no agent.
			if r, _ := s.Roster(context.Background(), tid); len(r["box-b"]) != 0 {
				t.Fatalf("refused replace wrote %v", r["box-b"])
			}
			// The same box adding a 2nd claude is refused too.
			if err := s.SetRoster(context.Background(), tid, "box-a", []string{"c-004", "c-005"}, now); !errors.Is(err, ErrVendorCapExceeded) {
				t.Fatalf("2nd claude on the same box: %v", err)
			}
			// agy cap 2: two seat, the third is refused.
			if err := seat(s, tid, "box-b", now, now, "a-004", "a-005"); err != nil {
				t.Fatalf("2 agy of cap 2: %v", err)
			}
			if err := seat(s, tid, "box-c", now, now, "a-006"); !errors.Is(err, ErrVendorCapExceeded) {
				t.Fatalf("3rd agy over cap 2: %v", err)
			}
			// max_live 0 forbids the vendor.
			if err := seat(s, tid, "box-c", now, now, "g-004"); !errors.Is(err, ErrVendorCapExceeded) {
				t.Fatalf("grok with cap 0: %v", err)
			}
			// AC-06: an uncapped vendor (qwen, mistral) seats freely.
			if err := seat(s, tid, "box-c", now, now, "q-004", "q-005", "m-004", "HUM-7"); err != nil {
				t.Fatalf("uncapped vendors: %v", err)
			}
			// A re-announce of a seated set adds nothing: admitted.
			if err := s.SetRoster(context.Background(), tid, "box-a", []string{"c-004"}, now); err != nil {
				t.Fatalf("re-announce: %v", err)
			}
			// Release: box-a drops c-004, then c-005 seats.
			if err := s.SetRoster(context.Background(), tid, "box-a", nil, now); err != nil {
				t.Fatal(err)
			}
			if err := seat(s, tid, "box-b", now, now, "a-004", "a-005", "c-005"); err != nil {
				t.Fatalf("claude after release: %v", err)
			}
			live, err := s.(AgentCapStore).LiveAgents(context.Background(), tid, now)
			if err != nil || live["claude"] != 1 || live["agy"] != 2 || live["qwen"] != 2 || live["mistral"] != 1 || live["grok"] != 0 {
				t.Fatalf("live = %v %v", live, err)
			}
		})
	}
}

// TestVendorCapLoweredKeepsSeated: an operator lowering a cap under the live
// count unseats nobody; only an addition is refused (as 009 D-3).
func TestVendorCapLoweredKeepsSeated(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			if err := seat(s, tid, "box-a", now, now, "c-004", "c-005"); err != nil {
				t.Fatal(err)
			}
			setCaps(t, s, tid, map[string]*int{"claude": capOf(1)}, now)
			if err := s.SetRoster(context.Background(), tid, "box-a", []string{"c-004", "c-005"}, now); err != nil {
				t.Fatalf("re-announce over a lowered cap: %v", err)
			}
			if err := s.SetRoster(context.Background(), tid, "box-a", []string{"c-005"}, now); err != nil {
				t.Fatalf("dropping one: %v", err)
			}
			if err := s.SetRoster(context.Background(), tid, "box-a", []string{"c-005", "c-006"}, now); !errors.Is(err, ErrVendorCapExceeded) {
				t.Fatalf("adding at the cap: %v", err)
			}
		})
	}
}

// TestVendorCapUncapped is control C3: no cap row, no refusal.
func TestVendorCapUncapped(t *testing.T) {
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			for _, b := range []string{"box-a", "box-b", "box-c"} {
				if err := seat(s, tid, b, now, now, "c-004", "c-005", "g-004", "a-004", "m-004", "q-004"); err != nil {
					t.Fatalf("uncapped %s: %v", b, err)
				}
			}
			c, err := s.(AgentCapStore).AgentCaps(context.Background(), tid)
			if err != nil || len(c.Caps) != 0 {
				t.Fatalf("caps of an uncapped workspace: %+v %v", c, err)
			}
		})
	}
}

// TestVendorCapPairCounting is AC-07: a role seat on two boxes is two live
// instances.
func TestVendorCapPairCounting(t *testing.T) {
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			setCaps(t, s, tid, map[string]*int{"claude": capOf(1)}, now)
			if err := seat(s, tid, "box-a", now, now, "c-001"); err != nil {
				t.Fatal(err)
			}
			if err := seat(s, tid, "pc", now, now, "c-001"); !errors.Is(err, ErrVendorCapExceeded) {
				t.Fatalf("c-001 on a 2nd box with claude 1: %v", err)
			}
		})
	}
}

// TestVendorCapStaleBox is control C4: a box whose presence stamp is older
// than CapPresenceTTL holds no seat. Without the presence filter the new
// claude is refused.
func TestVendorCapStaleBox(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			setCaps(t, s, tid, map[string]*int{"claude": capOf(1)}, now)
			old := now.Add(-2 * CapPresenceTTL)
			if err := seat(s, tid, "box-a", old, old, "c-004"); err != nil {
				t.Fatal(err)
			}
			if err := seat(s, tid, "box-b", now, now, "c-005"); err != nil {
				t.Fatalf("claude next to a stale box's claude: %v", err)
			}
			live, err := s.(AgentCapStore).LiveAgents(context.Background(), tid, now)
			if err != nil || live["claude"] != 1 {
				t.Fatalf("live = %v %v", live, err)
			}
			// box-a comes back: it may keep its agent (no addition) ...
			if err := seat(s, tid, "box-a", now, now, "c-004"); err != nil {
				t.Fatalf("stale box back with its own agent: %v", err)
			}
			// ... but a fresh box adds none.
			if err := seat(s, tid, "box-c", now, now, "c-006"); !errors.Is(err, ErrVendorCapExceeded) {
				t.Fatalf("3rd claude: %v", err)
			}
		})
	}
}

// TestAgentCapsStore is AC-01 + FR-008: set, update, delete, validation, the
// audit trail.
func TestAgentCapsStore(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	for name, s := range drivers(t) {
		cs := s.(AgentCapStore)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			c := setCaps(t, s, tid, map[string]*int{"claude": capOf(1), "grok": capOf(1), "agy": capOf(2), "mistral": capOf(1)}, now)
			if len(c.Caps) != 4 || c.Caps["agy"] != 2 || c.UpdatedBy != "HUM-1" || !c.UpdatedAt.Equal(now) {
				t.Fatalf("after set: %+v", c)
			}
			c = setCaps(t, s, tid, map[string]*int{"claude": capOf(3), "grok": nil, "qwen": nil}, now.Add(time.Minute))
			if len(c.Caps) != 3 || c.Caps["claude"] != 3 {
				t.Fatalf("after update + delete: %+v", c)
			}
			if _, ok := c.Caps["grok"]; ok {
				t.Fatalf("grok cap not removed: %+v", c)
			}
			if got, err := cs.AgentCaps(ctx, tid); err != nil || len(got.Caps) != 3 || got.Caps["claude"] != 3 {
				t.Fatalf("read back: %+v %v", got, err)
			}
			if _, err := cs.SetAgentCaps(ctx, tid, map[string]*int{"deepseek": capOf(1)}, capOperator, now); !errors.Is(err, ErrBadCapVendor) {
				t.Fatalf("bad vendor: %v", err)
			}
			if _, err := cs.SetAgentCaps(ctx, tid, map[string]*int{"claude": capOf(-1)}, capOperator, now); !errors.Is(err, ErrBadCapValue) {
				t.Fatalf("negative cap: %v", err)
			}
			if _, err := cs.SetAgentCaps(ctx, uid("t-"), map[string]*int{"claude": capOf(1)}, capOperator, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("absent workspace: %v", err)
			}
			trail, err := s.(OperatorWorkspaces).OperatorAuditOf(ctx, tid, 50)
			if err != nil {
				t.Fatal(err)
			}
			// 4 sets, then claude 1 -> 3 and grok removed; qwen had no cap: no row.
			if len(trail) != 6 {
				t.Fatalf("audit rows = %d: %+v", len(trail), trail)
			}
			last := trail[len(trail)-1]
			if last.Action != AuditDeleteAgentCap || last.Detail["vendor"] != "grok" || last.ActorHum != "HUM-1" || last.ActorTenant != "ops" {
				t.Fatalf("last audit row: %+v", last)
			}
			upd := trail[len(trail)-2]
			if upd.Action != AuditSetAgentCaps || upd.Detail["vendor"] != "claude" {
				t.Fatalf("update audit row: %+v", upd)
			}
			if p, ok := upd.Detail["previous"].(float64); ok && p != 1 {
				t.Fatalf("previous = %v", upd.Detail["previous"])
			} else if p, ok := upd.Detail["previous"].(int); ok && p != 1 {
				t.Fatalf("previous = %v", upd.Detail["previous"])
			}
		})
	}
}

// TestAgentCapsRLSTenantCannotWrite: rdb 0212's tenant_scope is FOR SELECT,
// so a workspace-scoped write is refused by Postgres itself (spec 147 P2).
func TestAgentCapsRLSTenantCannotWrite(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	if _, err := pg.execTenant(ctx, tid, `INSERT INTO tenant_agent_caps (tenant_id, vendor, max_live, updated_by)
		VALUES ($1, 'claude', 9, 'HUM-1')`, tid); err == nil {
		t.Fatal("a tenant-scoped INSERT into tenant_agent_caps was accepted")
	}
	setCaps(t, pg, tid, map[string]*int{"claude": capOf(1)}, time.Now())
	if tag, err := pg.execTenant(ctx, tid, `UPDATE tenant_agent_caps SET max_live = 9 WHERE tenant_id = $1`, tid); err == nil && tag.RowsAffected() != 0 {
		t.Fatal("a tenant-scoped UPDATE changed a cap")
	}
	other := newTenant(t, pg)
	c, err := pg.AgentCaps(ctx, other)
	if err != nil || len(c.Caps) != 0 {
		t.Fatalf("another workspace reads caps: %+v %v", c, err)
	}
}

// TestVendorCapRace is control C5: two boxes race for claude's last seat;
// botSeatGate's tenants row lock lets exactly one in.
func TestVendorCapRace(t *testing.T) {
	pg := pgOnly(t)
	now := time.Now().UTC()
	for i := 0; i < 10; i++ {
		tid := newTenant(t, pg)
		setCaps(t, pg, tid, map[string]*int{"claude": capOf(1)}, now)
		for _, b := range []string{"box-a", "box-b"} { // a hello stamps before it seats (ws.go seatSession)
			if err := pg.TouchBox(context.Background(), tid, b, now); err != nil {
				t.Fatal(err)
			}
		}
		var wg sync.WaitGroup
		errs := make([]error, 2)
		for j, b := range []string{"box-a", "box-b"} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				errs[j] = pg.SetRoster(context.Background(), tid, b, []string{"c-00" + string(rune('4'+j))}, now)
			}()
		}
		wg.Wait()
		ok := 0
		for _, err := range errs {
			switch {
			case err == nil:
				ok++
			case !errors.Is(err, ErrVendorCapExceeded):
				t.Fatalf("race round %d: %v", i, err)
			}
		}
		if ok != 1 {
			t.Fatalf("race round %d: %d of 2 seated (errs %v), want exactly 1", i, ok, errs)
		}
	}
}
