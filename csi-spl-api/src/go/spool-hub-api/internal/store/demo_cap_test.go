package store

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/077 T008 (FR-006): at most OpenMaxLive (default 9) live demo_user
// seats; the next open admission is ErrDemoFull and writes nothing. A
// re-login, an invite and a seat whose access ended do not count against it.
func TestHumansOpenDemoLiveCap(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			demo := newTenant(t, s)
			open := AdmitPolicy{OpenWorkspace: demo, OpenProviders: []string{"google", "facebook"}}
			tag := uid("")
			ident := func(i int) Identity {
				l := "cap" + string(rune('a'+i)) + "-" + tag
				return Identity{Provider: "google", Subject: uid(l + "-"), Email: l + "@example.com"}
			}
			// Nine visitors (the default cap) are seated.
			var seated []string
			for i := range DefaultDemoMaxLive {
				hum, err := h.Admit(ctx, ident(i), demo, open, now)
				if err != nil {
					t.Fatalf("visitor %d: %v", i+1, err)
				}
				seated = append(seated, hum)
			}
			// Negative: the 10th is demo_full (still a not-admitted refusal).
			tenth := ident(DefaultDemoMaxLive)
			hum, err := h.Admit(ctx, tenth, demo, open, now)
			if !errors.Is(err, ErrDemoFull) || !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("10th visitor: %q %v, want ErrDemoFull", hum, err)
			}
			// Negative: a facebook visitor is counted in the same nine.
			fb := ident(DefaultDemoMaxLive + 1)
			fb.Provider = "facebook"
			if hum, err := h.Admit(ctx, fb, demo, open, now); !errors.Is(err, ErrDemoFull) {
				t.Fatalf("facebook 10th: %q %v, want ErrDemoFull", hum, err)
			}
			// Negative: a smaller configured cap refuses earlier.
			if hum, err := h.Admit(ctx, ident(DefaultDemoMaxLive+2), demo,
				AdmitPolicy{OpenWorkspace: demo, OpenProviders: open.OpenProviders, OpenMaxLive: 3}, now); !errors.Is(err, ErrDemoFull) {
				t.Fatalf("cap 3 with 9 live: %q %v, want ErrDemoFull", hum, err)
			}
			// A seated visitor signing in again never consumes a seat.
			if again, err := h.Admit(ctx, ident(0), demo, open, now); err != nil || again != seated[0] {
				t.Fatalf("re-login at the cap: %q %v", again, err)
			}
			// An invite to the demo workspace is not an open seat: it still wins.
			staff := ident(DefaultDemoMaxLive + 3)
			if err := h.PutInvite(ctx, Invite{TenantID: demo, Email: staff.Email, Role: rbac.Admin,
				InvitedBy: AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			if hs, err := h.Admit(ctx, staff, demo, open, now); err != nil {
				t.Fatalf("invited staff at the demo cap: %q %v", hs, err)
			}
			// A seat whose access ended frees a slot; the refused 10th then gets in.
			past := now.Add(-time.Minute)
			if err := s.(MemberAccess).SetMemberAccessUntil(ctx, demo, seated[1], &past); err != nil {
				t.Fatal(err)
			}
			h10, err := h.Admit(ctx, tenth, demo, open, now)
			if err != nil {
				t.Fatalf("10th after a seat ended: %v", err)
			}
			if r, err := h.MemberRole(ctx, h10, demo); err != nil || r != rbac.DemoUser {
				t.Fatalf("10th seated: role %q %v", r, err)
			}
			// Full again.
			if hum, err := h.Admit(ctx, fb, demo, open, now); !errors.Is(err, ErrDemoFull) {
				t.Fatalf("after refill: %q %v, want ErrDemoFull", hum, err)
			}
		})
	}
}

// The cap holds under concurrent sign-ins (count and insert in one
// transaction under the tenant row lock): 12 visitors racing for 5 seats
// leave exactly 5 seated, the other 7 demo_full.
func TestHumansOpenDemoLiveCapRace(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	const capN, racers = 5, 12
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			demo := newTenant(t, s)
			open := AdmitPolicy{OpenWorkspace: demo, OpenProviders: []string{"google", "facebook"}, OpenMaxLive: capN}
			tag := uid("")
			var wg sync.WaitGroup
			start := make(chan struct{})
			hums := make([]string, racers)
			errs := make([]error, racers)
			for i := range racers {
				wg.Add(1)
				go func() {
					defer wg.Done()
					<-start
					l := "race" + string(rune('a'+i)) + "-" + tag
					hums[i], errs[i] = h.Admit(ctx, Identity{Provider: "google", Subject: uid(l + "-"),
						Email: l + "@example.com"}, demo, open, now)
				}()
			}
			close(start)
			wg.Wait()
			admitted, full := 0, 0
			for i, err := range errs {
				switch {
				case err == nil:
					admitted++
					if r, err := h.MemberRole(ctx, hums[i], demo); err != nil || r != rbac.DemoUser {
						t.Fatalf("racer %d: role %q %v", i, r, err)
					}
				case errors.Is(err, ErrDemoFull):
					full++
				default:
					t.Fatalf("racer %d: %v", i, err)
				}
			}
			if admitted != capN || full != racers-capN {
				t.Fatalf("race: %d admitted, %d demo_full; want %d and %d", admitted, full, capN, racers-capN)
			}
		})
	}
}
