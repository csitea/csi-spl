package store

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"
)

// SPL-1111: ViewRoster's one batch answers exactly what ViewBoxes,
// TenantAvatars and ListMembers answer one by one - boxes with agents and a
// revoked one, members with and without a picture, a live and an expired
// manual status (spec 096) - and CONTROL: another tenant's rows never appear.
func TestViewRosterEqualsTheSingleReaders(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			tid, other := newTenant(t, s), newTenant(t, s)
			for _, b := range []string{"box-a", "box-b"} {
				if err := s.PutPin(ctx, tid, b, pubkey(), false, now, now); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.PutPin(ctx, other, "box-z", pubkey(), false, now, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, tid, "box-a", []string{"CLE-07", "GRK-03"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.RevokePin(ctx, tid, "box-b", now.Add(time.Second), now.Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			boot := AdmitPolicy{BootstrapOwner: true}
			owner, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("ros-")}, tid, boot, now)
			if err != nil {
				t.Fatal(err)
			}
			mail := uid("ros-") + "@example.com"
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: mail, InvitedBy: owner, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			member, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("ros-"), Email: mail}, tid, AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			otherOwner, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("ros-")}, other, boot, now)
			if err != nil {
				t.Fatal(err)
			}
			hums := []string{owner, member}
			if err := h.SetAvatar(ctx, hums[0], strings.Repeat("ab", 32)); err != nil {
				t.Fatal(err)
			}
			if err := h.SetDisplayName(ctx, hums[1], "FirstName LastName"); err != nil {
				t.Fatal(err)
			}

			hs := s.(HumanStatuses)
			for _, st := range []struct {
				tenant, hum string
				until       time.Time
			}{{tid, member, now.Add(time.Hour)}, {tid, owner, now.Add(-time.Minute)}, {other, otherOwner, time.Time{}}} {
				if err := hs.PutHumanStatus(ctx, st.tenant, HumanStatus{HumanID: st.hum, State: "busy", Note: "x", Until: st.until, SetAt: now, SetBy: st.hum}); err != nil {
					t.Fatal(err)
				}
			}

			got, err := s.(RosterReader).ViewRoster(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			var want Roster
			if want.Boxes, err = s.ViewBoxes(ctx, tid); err != nil {
				t.Fatal(err)
			}
			if want.Avatars, err = h.TenantAvatars(ctx, tid); err != nil {
				t.Fatal(err)
			}
			if want.Members, err = s.(MemberDirectory).ListMembers(ctx, tid); err != nil {
				t.Fatal(err)
			}
			if want.Statuses, err = hs.HumanStatuses(ctx, tid, time.Now()); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("one batch:\n %+v\nsingle readers:\n %+v", got, want)
			}
			if len(got.Boxes) != 2 || len(got.Avatars) != 2 || len(got.Members) != 2 {
				t.Fatalf("roster %d boxes %d avatars %d members, want 2 2 2 (never the other tenant's)", len(got.Boxes), len(got.Avatars), len(got.Members))
			}
			if _, ok := got.Statuses[member]; !ok || len(got.Statuses) != 1 {
				t.Fatalf("statuses %+v, want the member's live one only (not expired, not the other tenant's)", got.Statuses)
			}
			for _, b := range got.Boxes {
				if b.BoxID == "box-z" {
					t.Fatal("another tenant's box in the roster")
				}
			}
		})
	}
}
