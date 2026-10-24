package store

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"
)

// Spec 144 T002 (rdb 0219, SPL-3182): the dedicated agents store. Memory
// always; with SPOOL_TEST_PG_DSN (hub-pg.tst.sh, PRE_PUSH_TIER=full) also
// Postgres as the schema owner and as the hub's runtime login
// (SPOOL_TEST_PG_RUNTIME_DSN, DML grants only, under RLS).

// dedicatedDrivers is drivers plus the runtime login when hub-pg.tst.sh
// names it; drivers migrates the database the runtime login then uses.
func dedicatedDrivers(t *testing.T) map[string]Store {
	t.Helper()
	out := drivers(t)
	if dsn := os.Getenv("SPOOL_TEST_PG_RUNTIME_DSN"); dsn != "" && out["postgres"] != nil {
		rt, err := OpenPostgres(context.Background(), dsn)
		if err != nil {
			t.Fatalf("runtime login: %v", err)
		}
		t.Cleanup(rt.Close)
		if by, err := rt.RLSBypassed(context.Background()); err != nil || by {
			t.Fatalf("the runtime login bypasses RLS (%v): it would prove nothing", err)
		}
		out["postgres-runtime"] = rt
	}
	return out
}

// TestDedicatedBindingRoundTrip: a binding set is read back (the second
// control of the brief: on master the store has no such method), the same
// set again is a no-op, another scope is refused, the scope lists it, and
// remove unbinds it.
func TestDedicatedBindingRoundTrip(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	for name, s := range dedicatedDrivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, ds := context.Background(), s.(DedicatedStore)
			tid, topic := newTenant(t, s), uuid4()
			if _, err := ds.GetDedicatedBinding(ctx, tid, "c-901", "box-a"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unbound agent: %v, want ErrNotFound", err)
			}
			b := DedicatedBinding{TenantID: tid, AgentID: "c-901", BoxID: "box-a", ScopeType: ScopeTopic, ScopeID: topic, BoundBy: "HUM-1", BoundAt: now}
			set, err := ds.SetDedicatedBinding(ctx, b)
			if err != nil || set != b {
				t.Fatalf("set: %+v %v, want %+v", set, err, b)
			}
			got, err := ds.GetDedicatedBinding(ctx, tid, "c-901", "box-a")
			if err != nil || got != b {
				t.Fatalf("read back: %+v %v, want %+v", got, err, b)
			}
			again := b
			again.BoundBy, again.BoundAt = "HUM-2", now.Add(time.Hour)
			if got, err := ds.SetDedicatedBinding(ctx, again); err != nil || got != b {
				t.Fatalf("same scope again: %+v %v, want the first row %+v", got, err, b)
			}
			other := b
			other.ScopeType, other.ScopeID = ScopeChannel, "crew"
			if _, err := ds.SetDedicatedBinding(ctx, other); !errors.Is(err, ErrDedicatedRebind) {
				t.Fatalf("rebind to another scope: %v, want ErrDedicatedRebind", err)
			}
			if _, err := ds.GetDedicatedBinding(ctx, tid, "c-901", "box-b"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("same agent, other box: %v, want ErrNotFound", err)
			}
			b2 := b
			b2.AgentID = "c-900"
			if _, err := ds.SetDedicatedBinding(ctx, b2); err != nil {
				t.Fatal(err)
			}
			list, err := ds.ListDedicatedAgentsByScope(ctx, tid, ScopeTopic, topic)
			if err != nil || len(list) != 2 || list[0] != b2 || list[1] != b {
				t.Fatalf("list: %+v %v, want [c-900 c-901]", list, err)
			}
			if list, err := ds.ListDedicatedAgentsByScope(ctx, tid, ScopeChannel, "crew"); err != nil || len(list) != 0 {
				t.Fatalf("list of an unbound scope: %+v %v", list, err)
			}
			if err := ds.RemoveDedicatedBinding(ctx, tid, "c-901", "box-a"); err != nil {
				t.Fatal(err)
			}
			if err := ds.RemoveDedicatedBinding(ctx, tid, "c-901", "box-a"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second remove: %v, want ErrNotFound", err)
			}
			if _, err := ds.GetDedicatedBinding(ctx, tid, "c-901", "box-a"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("after remove: %v, want ErrNotFound", err)
			}
			if _, err := ds.SetDedicatedBinding(ctx, other); err != nil {
				t.Fatalf("bind after remove: %v", err)
			}
			// Another tenant sees none of it.
			if _, err := ds.GetDedicatedBinding(ctx, newTenant(t, s), "c-900", "box-a"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("other tenant: %v, want ErrNotFound", err)
			}
		})
	}
}

// TestDedicatedBindingRefusals: rdb 0219's checks, in both twins, before any write.
func TestDedicatedBindingRefusals(t *testing.T) {
	for name, s := range dedicatedDrivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, ds := context.Background(), s.(DedicatedStore)
			tid := newTenant(t, s)
			ok := DedicatedBinding{TenantID: tid, AgentID: "c-901", BoxID: "box-a", ScopeType: ScopeChannel, ScopeID: "crew", BoundBy: "HUM-1"}
			bad := map[string]func(*DedicatedBinding){
				"scope type":    func(b *DedicatedBinding) { b.ScopeType = "dm" },
				"channel id":    func(b *DedicatedBinding) { b.ScopeID = "Crew!" },
				"topic id":      func(b *DedicatedBinding) { b.ScopeType = ScopeTopic },
				"upper uuid":    func(b *DedicatedBinding) { b.ScopeType, b.ScopeID = ScopeTopic, "ABCDEF01-0000-4000-8000-000000000001" },
				"empty agent":   func(b *DedicatedBinding) { b.AgentID = "" },
				"long box":      func(b *DedicatedBinding) { b.BoxID = string(make([]byte, 65)) },
				"empty boundby": func(b *DedicatedBinding) { b.BoundBy = " " },
			}
			for what, mut := range bad {
				b := ok
				mut(&b)
				if _, err := ds.SetDedicatedBinding(ctx, b); !errors.Is(err, ErrBadDedicatedScope) {
					t.Errorf("%s: %v, want ErrBadDedicatedScope", what, err)
				}
			}
			noTenant := ok
			noTenant.TenantID = ""
			if _, err := ds.SetDedicatedBinding(ctx, noTenant); !errors.Is(err, ErrNoTenant) {
				t.Errorf("no tenant: %v, want ErrNoTenant", err)
			}
			unknown := ok
			unknown.TenantID = uid("t-gone-")
			if _, err := ds.SetDedicatedBinding(ctx, unknown); !errors.Is(err, ErrNotFound) {
				t.Errorf("unknown tenant: %v, want ErrNotFound", err)
			}
			if _, err := ds.IsPrivateScope(ctx, tid, "dm", "x"); !errors.Is(err, ErrBadDedicatedScope) {
				t.Errorf("IsPrivateScope bad type: %v", err)
			}
			if list, _ := ds.ListDedicatedAgentsByScope(ctx, tid, ScopeChannel, "crew"); len(list) != 0 {
				t.Errorf("a refused set wrote %+v", list)
			}
		})
	}
}

// TestPrivateScopeFlags: SetPrivateScope / IsPrivateScope on a channel and
// on a topic; a topic in a private channel is private; unknown = ErrNotFound.
func TestPrivateScopeFlags(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	for name, s := range dedicatedDrivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, ds := context.Background(), s.(DedicatedStore)
			tid := newTenant(t, s)
			for _, ch := range []string{"crew", "open"} {
				if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
					t.Fatal(err)
				}
			}
			flag := func(typ, id string, want bool) {
				t.Helper()
				if got, err := ds.IsPrivateScope(ctx, tid, typ, id); err != nil || got != want {
					t.Fatalf("IsPrivateScope(%s %s) = %v %v, want %v", typ, id, got, err, want)
				}
			}
			flag(ScopeChannel, "crew", false)
			if err := ds.SetPrivateScope(ctx, tid, ScopeChannel, "crew", true, now); err != nil {
				t.Fatal(err)
			}
			flag(ScopeChannel, "crew", true)
			flag(ScopeChannel, "open", false)
			inCrew, plain := uuid4(), uuid4()
			m := msgFor(tid, inCrew, "box-b", now, now, "e-crew")
			m.Channel = "crew"
			p := msgFor(tid, plain, "box-b", now, now, "e-plain")
			p.Channel = "open"
			for _, x := range []Message{m, p} {
				if _, err := s.InsertMessage(ctx, x); err != nil {
					t.Fatal(err)
				}
			}
			flag(ScopeTopic, inCrew, true) // its channel is private
			flag(ScopeTopic, plain, false)
			if err := ds.SetPrivateScope(ctx, tid, ScopeTopic, plain, true, now); err != nil {
				t.Fatal(err)
			}
			flag(ScopeTopic, plain, true)
			if err := ds.SetPrivateScope(ctx, tid, ScopeTopic, plain, false, now); err != nil {
				t.Fatal(err)
			}
			flag(ScopeTopic, plain, false)
			if err := ds.SetPrivateScope(ctx, tid, ScopeChannel, "crew", false, now); err != nil {
				t.Fatal(err)
			}
			flag(ScopeChannel, "crew", false)
			flag(ScopeTopic, inCrew, false)
			if err := ds.SetPrivateScope(ctx, tid, ScopeChannel, "nope", true, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown channel: %v, want ErrNotFound", err)
			}
			if err := ds.SetPrivateScope(ctx, tid, ScopeTopic, uuid4(), true, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown topic: %v, want ErrNotFound", err)
			}
			flag(ScopeTopic, uuid4(), false)
		})
	}
}

// TestBoxTaskEnvelopesPrivateScope is the brief's red control (spec 12.2
// C2): box-a holds a private topic's envelopes; the non-dedicated c-002 on
// box-a, and a tail naming no agent, read none of them (on master both read
// the envelope). The agent dedicated to the topic on box-a reads them, the
// same agent on another box does not, and an agent dedicated elsewhere
// reads no other topic. A topic of a private channel reads like a flagged one.
func TestBoxTaskEnvelopesPrivateScope(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	for name, s := range dedicatedDrivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, ds := context.Background(), s.(DedicatedStore)
			tid := newTenant(t, s)
			for _, ch := range []string{"crew", "open"} {
				if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
					t.Fatal(err)
				}
			}
			priv, plain, inCrew := uuid4(), uuid4(), uuid4()
			for task, ch := range map[string]string{priv: "open", plain: "open", inCrew: "crew"} {
				m := msgFor(tid, task, "box-b", now, now, "e-"+task) // from box-a
				m.Channel = ch
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			if err := ds.SetPrivateScope(ctx, tid, ScopeTopic, priv, true, now); err != nil {
				t.Fatal(err)
			}
			if err := ds.SetPrivateScope(ctx, tid, ScopeChannel, "crew", true, now); err != nil {
				t.Fatal(err)
			}
			bind := func(agent, box, typ, id string) {
				t.Helper()
				if _, err := ds.SetDedicatedBinding(ctx, DedicatedBinding{TenantID: tid, AgentID: agent, BoxID: box, ScopeType: typ, ScopeID: id, BoundBy: "HUM-1"}); err != nil {
					t.Fatal(err)
				}
			}
			bind("c-901", "box-a", ScopeTopic, priv)
			bind("c-902", "box-a", ScopeChannel, "crew")
			bind("c-903", "box-b", ScopeTopic, priv) // c-903 on box-a is not dedicated
			tail := func(agent, task string) int {
				t.Helper()
				envs, err := s.BoxTaskEnvelopes(WithTailAgent(ctx, agent), tid, task, "box-a", now)
				if err != nil {
					t.Fatal(err)
				}
				return len(envs)
			}
			cases := []struct {
				what, agent, task string
				want              int
			}{
				{"C2 non-dedicated c-002, private topic", "c-002", priv, 0},
				{"no agent on ctx, private topic", "", priv, 0},
				{"c-002, topic of a private channel", "c-002", inCrew, 0},
				{"c-002, plain topic", "c-002", plain, 1},
				{"no agent, plain topic", "", plain, 1},
				{"c-901 dedicated to the topic", "c-901", priv, 1},
				{"c-901 outside its topic", "c-901", plain, 0},
				{"c-902 dedicated to the channel", "c-902", inCrew, 1},
				{"c-902 outside its channel", "c-902", priv, 0},
				{"c-903, bound on another box only", "c-903", priv, 0},
			}
			for _, c := range cases {
				if got := tail(c.agent, c.task); got != c.want {
					t.Errorf("%s: %d envelopes, want %d", c.what, got, c.want)
				}
			}
			// Unflagged again, c-002 reads it: the flag, not the topic, hides it.
			if err := ds.SetPrivateScope(ctx, tid, ScopeTopic, priv, false, now); err != nil {
				t.Fatal(err)
			}
			if got := tail("c-002", priv); got != 1 {
				t.Errorf("c-002 after the flag is cleared: %d, want 1", got)
			}
		})
	}
}
