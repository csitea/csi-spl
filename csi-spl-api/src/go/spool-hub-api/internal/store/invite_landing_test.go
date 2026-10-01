package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-1230: an invitee who signs in WITHOUT naming a workspace lands in the
// one that invited them. LiveInviteTenants names the live invites of a
// verified address newest first; AuthHooks.InvitedTenant picks the newest;
// registering into it consumes that invite. Memory always; Postgres with a DSN.
func TestInviteLanding(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 1, 8, 0, 0, 0, time.UTC)
	const email = "landing@example.com"
	for name, s := range drivers(t) {
		h := s.(Humans)
		f, ok := s.(InviteFinder)
		if !ok {
			t.Fatalf("%s: store is not an InviteFinder", name)
		}
		t.Run(name, func(t *testing.T) {
			older, newer, lapsed := newTenant(t, s), newTenant(t, s), newTenant(t, s)
			put := func(tid, addr string, at time.Time, ttl time.Duration) {
				t.Helper()
				if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: addr, InvitedBy: AdmittedOperator, ExpiresAt: at.Add(ttl)}, at); err != nil {
					t.Fatal(err)
				}
			}
			put(older, email, now, 48*time.Hour)
			put(newer, strings.ToUpper(email), now.Add(time.Minute), 48*time.Hour) // stored lower-cased
			put(lapsed, email, now.Add(-72*time.Hour), time.Hour)                  // expired: never a landing
			put(older, "someone-else@example.com", now, 48*time.Hour)

			later := now.Add(2 * time.Minute)
			got, err := f.LiveInviteTenants(ctx, " Landing@Example.com ", later)
			if err != nil || strings.Join(got, ",") != newer+","+older {
				t.Fatalf("live invites = %v %v, want [%s %s] newest first, no expired one", got, err, newer, older)
			}
			if got, _ := f.LiveInviteTenants(ctx, "nobody@example.com", later); len(got) != 0 {
				t.Fatalf("an uninvited address got %v", got)
			}

			reg := AuthHooks{H: h, Now: func() time.Time { return later }}
			land, err := reg.InvitedTenant(ctx, email)
			if err != nil || land != newer {
				t.Fatalf("InvitedTenant = %q %v, want %s", land, err, newer)
			}
			// Registering into the landing tenant consumes THAT invite.
			hum, err := reg.Register(ctx, auth.Identity{Provider: "google", Subject: uid("l-"), Email: email}, land)
			if err != nil || hum == "" {
				t.Fatalf("register into %s: %q %v", land, hum, err)
			}
			if r, err := h.MemberRole(ctx, hum, newer); err != nil || r != RoleDefault {
				t.Fatalf("member of %s: %q %v", newer, r, err)
			}
			if got, _ := f.LiveInviteTenants(ctx, email, later); strings.Join(got, ",") != older {
				t.Fatalf("after landing, live invites = %v, want only [%s]", got, older)
			}
		})
	}
}
