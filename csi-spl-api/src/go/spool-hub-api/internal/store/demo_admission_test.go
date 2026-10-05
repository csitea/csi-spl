package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// demoAdmitAt admits ident to the rig's demo workspace under p at the given
// instant and answers the error only.
func (r demoStayRig) admitErr(id Identity, p AdmitPolicy, at time.Time) (string, error) {
	return r.s.(Humans).Admit(context.Background(), id, r.demo, p, at)
}

// demoMembers counts the demo workspace's memberships.
func (r demoStayRig) members(t *testing.T) int {
	t.Helper()
	ms, err := r.s.(MemberDirectory).ListMembers(context.Background(), r.demo)
	if err != nil {
		t.Fatal(err)
	}
	return len(ms)
}

// specs/077 Q11, T010: one IdP account starts at most OpenVisitsPerDay
// (default 2) demo stays per UTC day; the next is ErrDemoVisits and writes
// nothing. A re-login inside a stay is no visit, a refused admission
// (demo_full) counts none, another account is not affected, and the next
// UTC day starts afresh.
func TestDemoReturnVisits(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			r := newDemoStayRig(t, s, time.Hour)
			// 01:00 UTC tomorrow: the four stays below share one UTC day.
			base := demoDay(r.t0).Add(25 * time.Hour)
			alice := r.ident("alice")
			r.admit(t, "alice", base) // visit 1
			if _, err := r.admitErr(alice, r.open, base.Add(10*time.Minute)); err != nil {
				t.Fatalf("re-login inside the stay: %v", err)
			}
			r.sweep(t, base.Add(time.Hour+time.Second))
			r.admit(t, "alice", base.Add(2*time.Hour)) // visit 2: the re-login took none
			r.sweep(t, base.Add(3*time.Hour+time.Second))
			// Negative: the third visit of the day.
			hum, err := r.admitErr(alice, r.open, base.Add(4*time.Hour))
			if !errors.Is(err, ErrDemoVisits) || !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("third visit: %q %v, want ErrDemoVisits", hum, err)
			}
			if n := r.members(t); n != 0 {
				t.Fatalf("refused visit left %d memberships", n)
			}
			// CONTROL: another account is admitted at the same instant.
			r.admit(t, "bob", base.Add(4*time.Hour))
			// The next UTC day starts afresh.
			r.sweep(t, base.Add(5*time.Hour+time.Second))
			r.admit(t, "alice", base.Add(24*time.Hour))

			// A demo_full refusal counts no visit: carol, refused twice with
			// the demo full, still gets one visit under a limit of 1.
			one := r.open
			one.OpenVisitsPerDay, one.OpenMaxLive = 1, 1
			day2 := base.Add(24*time.Hour + time.Minute)
			carol := r.ident("carol")
			for range 2 {
				if _, err := r.admitErr(carol, one, day2); !errors.Is(err, ErrDemoFull) {
					t.Fatalf("carol with the demo full: %v, want ErrDemoFull", err)
				}
			}
			r.sweep(t, day2.Add(time.Hour+time.Second)) // alice's day-2 stay ends
			if _, err := r.admitErr(carol, one, day2.Add(2*time.Hour)); err != nil {
				t.Fatalf("carol's first visit after two demo_full: %v", err)
			}
			r.sweep(t, day2.Add(3*time.Hour+time.Second))
			// Negative: a configured limit of 1 refuses the second visit.
			if _, err := r.admitErr(carol, one, day2.Add(4*time.Hour)); !errors.Is(err, ErrDemoVisits) {
				t.Fatalf("carol's second visit under a limit of 1: %v, want ErrDemoVisits", err)
			}
		})
	}
}

// specs/077 3.6, T010: one client IP brings at most OpenSignupsPerIP
// (default 3) accounts to the demo per UTC day; the next new account is
// ErrDemoSignups and writes nothing (not even a visit). An account's second
// visit from that IP takes none, another IP and the next day are not
// affected, and a caller that knows no address is not limited by it.
func TestDemoSignupsPerIP(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			r := newDemoStayRig(t, s, time.Hour)
			base := demoDay(r.t0).Add(25 * time.Hour)
			from := func(n, ip string) Identity {
				id := r.ident(n)
				id.ClientIP = ip
				return id
			}
			const ip, other = "203.0.113.7", "198.51.100.9"
			for _, n := range []string{"a", "b", "c"} {
				if _, err := r.admitErr(from(n, ip), r.open, base); err != nil {
					t.Fatalf("account %s from %s: %v", n, ip, err)
				}
			}
			// Negative: the fourth new account from the address.
			hum, err := r.admitErr(from("d", ip), r.open, base)
			if !errors.Is(err, ErrDemoSignups) || !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("fourth account from %s: %q %v, want ErrDemoSignups", ip, hum, err)
			}
			if n := r.members(t); n != 3 {
				t.Fatalf("refused sign-up: %d memberships, want 3", n)
			}
			// CONTROL: the same account from another address is admitted, so
			// the refusal counted no visit for it (limit 1 below proves it).
			one := r.open
			one.OpenVisitsPerDay = 1
			if _, err := r.admitErr(from("d", other), one, base); err != nil {
				t.Fatalf("account d from %s: %v", other, err)
			}
			// A caller that knows no address is not limited by the IP rule.
			if _, err := r.admitErr(from("e", ""), r.open, base); err != nil {
				t.Fatalf("account e with no address: %v", err)
			}
			// An account's second visit from the same address is no new account.
			r.sweep(t, base.Add(time.Hour+time.Second))
			if hum, err := r.admitErr(from("a", ip), r.open, base.Add(2*time.Hour)); err != nil {
				t.Fatalf("account a's second visit from %s: %q %v", ip, hum, err)
			} else if role, err := s.(Humans).MemberRole(context.Background(), hum, r.demo); err != nil || role != rbac.DemoUser {
				t.Fatalf("account a's second visit: role %q %v", role, err)
			}
			// The next UTC day starts afresh.
			r.sweep(t, base.Add(3*time.Hour+time.Second))
			if _, err := r.admitErr(from("f", ip), r.open, base.Add(24*time.Hour)); err != nil {
				t.Fatalf("a new account from %s the next day: %v", ip, err)
			}
		})
	}
}
