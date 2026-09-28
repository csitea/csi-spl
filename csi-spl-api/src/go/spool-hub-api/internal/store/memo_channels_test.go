package store

import (
	"context"
	"reflect"
	"testing"
	"time"
)

// SPL-1115: inside a request memo, MemberRole reads the human's channels in
// the same batch and HumanChannels answers from it - the same list the
// database answers. The memo dies with the request: CONTROL, a removal is
// seen by the next request (a fresh memo) and by any read without one.
func TestMemberRoleMemoCarriesHumanChannels(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			hum, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("mc-")}, tid, AdmitPolicy{BootstrapOwner: true}, now)
			if err != nil {
				t.Fatal(err)
			}
			for _, c := range []string{"ops", "qa"} {
				if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: c, Name: c, CreatedBy: hum, CreatedAt: now}); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.AddChannelHumans(ctx, tid, "ops", []string{hum}, hum, now); err != nil {
				t.Fatal(err)
			}
			if err := s.AddChannelHumans(ctx, tid, "qa", []string{hum}, hum, now); err != nil {
				t.Fatal(err)
			}
			want, err := s.HumanChannels(ctx, tid, hum) // no memo: the database
			if err != nil || len(want) < 2 {
				t.Fatalf("channels %v %v", want, err)
			}

			req := WithMemo(ctx)
			if _, err := h.MemberRole(req, hum, tid); err != nil {
				t.Fatal(err)
			}
			got, err := s.HumanChannels(req, tid, hum)
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("memo channels %v %v, database %v", got, err, want)
			}

			if err := s.RemoveChannelHuman(ctx, tid, "qa", hum); err != nil {
				t.Fatal(err)
			}
			fresh, _ := s.HumanChannels(ctx, tid, hum)
			if reflect.DeepEqual(fresh, want) {
				t.Fatalf("removal not stored: %v", fresh)
			}
			next := WithMemo(ctx) // the next request
			if _, err := h.MemberRole(next, hum, tid); err != nil {
				t.Fatal(err)
			}
			if got, _ := s.HumanChannels(next, tid, hum); !reflect.DeepEqual(got, fresh) {
				t.Fatalf("next request's memo %v, database %v", got, fresh)
			}
			// A human the memo did not read goes to the database.
			if got, err := s.HumanChannels(next, tid, "HUM-999999999"); err != nil || len(got) != 0 {
				t.Fatalf("unread human %v %v", got, err)
			}
		})
	}
}
