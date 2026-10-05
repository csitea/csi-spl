package store

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// rdb 0078 (CLE-35099): a person's per-tenant settings override is kept per
// person AND per tenant; a change in one tenant never moves another; a null
// clears a key so the read falls back to the global; the override wins over
// the global when overlaid onto auth.HumanSettings.
func TestMembershipSettings(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now()
			h := s.(Humans)
			ms := s.(membershipSettingsStore)
			t1, t2 := newTenant(t, s), newTenant(t, s)
			admit := func(tid, email string) string {
				t.Helper()
				if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: email, Role: "developer", InvitedBy: AdmittedOperator,
					ExpiresAt: now.Add(time.Hour)}, now); err != nil {
					t.Fatal(err)
				}
				hum, err := h.Admit(ctx, Identity{Provider: "google", Subject: "s-" + email + tid, Email: email}, tid, AdmitPolicy{}, now)
				if err != nil {
					t.Fatal(err)
				}
				return hum
			}
			a := admit(t1, uid("a")+"@example.com")
			b := admit(t1, uid("b")+"@example.com")
			// a is a member of t2 too: their t2 override must stay independent.
			if err := h.PutInvite(ctx, Invite{TenantID: t2, Email: "a2@example.com", Role: "developer",
				InvitedBy: AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			if _, err := h.Admit(ctx, Identity{Provider: "google", Subject: "s-a" + t1, Email: "a2@example.com"}, t2, AdmitPolicy{}, now); err != nil {
				t.Fatal(err)
			}

			// Never set: the zero override (fall back to the global).
			if got, err := ms.MembershipSettings(ctx, a, t1); err != nil || !reflect.DeepEqual(got, auth.MembershipSettings{}) {
				t.Fatalf("never set: %+v %v", got, err)
			}

			// Set theme + message_order + issues_sort in t1.
			if err := ms.SetMembershipSettings(ctx, a, t1, map[string]any{
				"preferred_theme": "dark",
				"message_order":   "newest-last",
				"issues_sort":     auth.IssuesSort{Col: "priority", Dir: "asc"},
			}); err != nil {
				t.Fatal(err)
			}
			got, err := ms.MembershipSettings(ctx, a, t1)
			if err != nil {
				t.Fatal(err)
			}
			if got.Theme == nil || *got.Theme != "dark" || got.MessageOrder == nil || *got.MessageOrder != "newest-last" {
				t.Fatalf("stored override: %+v", got)
			}
			if got.IssuesSort == nil || got.IssuesSort.Col != "priority" || got.IssuesSort.Dir != "asc" {
				t.Fatalf("issues_sort: %+v", got.IssuesSort)
			}

			// Overlay wins over the global; untouched fields keep the global.
			base := auth.HumanSettings{Theme: "light", Locale: "en", ViewPrefs: map[string]string{"message_order": "newest-first"}}
			over := base.Overlay(got)
			if over.Theme != "dark" || over.Locale != "en" || over.ViewPrefs["message_order"] != "newest-last" {
				t.Fatalf("overlay: %+v", over)
			}

			// Isolation: another member and the SAME person's other tenant are untouched.
			if o, err := ms.MembershipSettings(ctx, b, t1); err != nil || o.Theme != nil {
				t.Fatalf("other member leaked: %+v %v", o, err)
			}
			if o, err := ms.MembershipSettings(ctx, a, t2); err != nil || o.Theme != nil {
				t.Fatalf("other tenant leaked: %+v %v", o, err)
			}

			// A null clears one key; the rest of the override stays.
			if err := ms.SetMembershipSettings(ctx, a, t1, map[string]any{"preferred_theme": nil}); err != nil {
				t.Fatal(err)
			}
			got, err = ms.MembershipSettings(ctx, a, t1)
			if err != nil {
				t.Fatal(err)
			}
			if got.Theme != nil {
				t.Fatalf("theme not cleared: %+v", got.Theme)
			}
			if got.MessageOrder == nil || *got.MessageOrder != "newest-last" {
				t.Fatalf("clearing theme dropped message_order: %+v", got)
			}
			// The cleared key now falls back to the global in the overlay.
			if over := base.Overlay(got); over.Theme != "light" {
				t.Fatalf("cleared key did not fall back: %q", over.Theme)
			}

			// CLE-77908 (owner, topic 07b84fd7): the time zone is per tenant, a
			// null clears it back to the browser's zone, and the rest stays.
			if err := ms.SetMembershipSettings(ctx, a, t1, map[string]any{"time_zone": "Europe/Helsinki"}); err != nil {
				t.Fatal(err)
			}
			if got, err = ms.MembershipSettings(ctx, a, t1); err != nil || got.TimeZone == nil || *got.TimeZone != "Europe/Helsinki" {
				t.Fatalf("time_zone stored: %+v %v", got.TimeZone, err)
			}
			if over := base.Overlay(got); over.TimeZone != "Europe/Helsinki" {
				t.Fatalf("time_zone overlay: %q", over.TimeZone)
			}
			if o, err := ms.MembershipSettings(ctx, b, t1); err != nil || o.TimeZone != nil {
				t.Fatalf("time_zone leaked to another member: %+v %v", o.TimeZone, err)
			}
			if o, err := ms.MembershipSettings(ctx, a, t2); err != nil || o.TimeZone != nil {
				t.Fatalf("time_zone leaked to another tenant: %+v %v", o.TimeZone, err)
			}
			if err := ms.SetMembershipSettings(ctx, a, t1, map[string]any{"time_zone": nil}); err != nil {
				t.Fatal(err)
			}
			if got, err = ms.MembershipSettings(ctx, a, t1); err != nil || got.TimeZone != nil || got.MessageOrder == nil {
				t.Fatalf("time_zone clear: %+v %v", got, err)
			}

			// Spec 078 FR-007 (T005): pane_sizes per view is kept as the WUI
			// sent it, nested views and all; an old flat value reads back flat.
			for _, in := range []string{
				`{"default":{"sidebar":0.18,"topic":0.33},"channel":{"topic":0.4},"docs":{"sidebar":0.25}}`,
				`{"sidebar":0.2,"topic":0.3}`,
			} {
				if err := ms.SetMembershipSettings(ctx, a, t1, map[string]any{"pane_sizes": json.RawMessage(in)}); err != nil {
					t.Fatal(err)
				}
				if got, err = ms.MembershipSettings(ctx, a, t1); err != nil {
					t.Fatal(err)
				}
				var stored, want any
				if json.Unmarshal(got.PaneSizes, &stored) != nil || json.Unmarshal([]byte(in), &want) != nil || !reflect.DeepEqual(stored, want) {
					t.Fatalf("pane_sizes not kept unchanged: sent %s, read %s", in, got.PaneSizes)
				}
				if over := base.Overlay(got); !reflect.DeepEqual(json.RawMessage(over.PaneSizes), got.PaneSizes) {
					t.Fatalf("pane_sizes overlay: %s", over.PaneSizes)
				}
			}
			if err := ms.SetMembershipSettings(ctx, a, t1, map[string]any{"pane_sizes": nil}); err != nil {
				t.Fatal(err)
			}
			if got, err = ms.MembershipSettings(ctx, a, t1); err != nil || got.PaneSizes != nil || got.MessageOrder == nil {
				t.Fatalf("pane_sizes clear: %s %v", got.PaneSizes, err)
			}

			// No membership: write is ErrNotFound.
			if err := ms.SetMembershipSettings(ctx, b, t2, map[string]any{"preferred_theme": "dark"}); !errors.Is(err, ErrNotFound) {
				t.Fatalf("write with no membership: %v", err)
			}

			// CLE-35099: the memberships list carries each tenant's settings, so
			// GET /session overlays with no extra round trip. a's t1 membership
			// now holds message_order + issues_sort (theme was cleared above).
			ml, ok := s.(MembershipLister)
			if !ok {
				t.Skip("no membership lister")
			}
			mems, err := ml.Memberships(ctx, a)
			if err != nil {
				t.Fatal(err)
			}
			var t1Raw []byte
			for _, m := range mems {
				if m.TenantID == t1 {
					t1Raw = m.Settings
				}
			}
			if len(t1Raw) == 0 {
				t.Fatalf("t1 membership carries no settings: %q", t1Raw)
			}
			var carried auth.MembershipSettings
			if err := json.Unmarshal(t1Raw, &carried); err != nil {
				t.Fatalf("decode carried settings: %v", err)
			}
			if carried.MessageOrder == nil || *carried.MessageOrder != "newest-last" || carried.IssuesSort == nil {
				t.Fatalf("carried override missing fields: %+v", carried)
			}
			if carried.Theme != nil {
				t.Fatalf("cleared theme still carried: %v", *carried.Theme)
			}
		})
	}
}
