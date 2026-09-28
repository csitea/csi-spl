package store

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

// SPL-1034 (specs/045 §3.8, rdb 0073): a person's Channels order is kept per
// person AND per tenant; another member's order and another tenant's are
// untouched; [] clears it; the request memo answers it from the membership
// read (no second round trip).
func TestChannelOrder(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now()
			h := s.(Humans)
			co := s.(ChannelOrders)
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

			if got, err := co.ChannelOrder(ctx, t1, a); err != nil || got != nil {
				t.Fatalf("never set: %v %v", got, err)
			}
			want := []string{"ops", "devel", "lobby"}
			if err := co.SetChannelOrder(ctx, t1, a, want); err != nil {
				t.Fatal(err)
			}
			if got, err := co.ChannelOrder(ctx, t1, a); err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("stored: %v %v", got, err)
			}
			// Another member's order is their own (the control).
			if got, err := co.ChannelOrder(ctx, t1, b); err != nil || got != nil {
				t.Fatalf("another member's order changed: %v %v", got, err)
			}
			// Another tenant: no membership there.
			if _, err := co.ChannelOrder(ctx, t2, a); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another tenant: %v", err)
			}
			if err := co.SetChannelOrder(ctx, t2, a, want); !errors.Is(err, ErrNotFound) {
				t.Fatalf("set in another tenant: %v", err)
			}
			// The memo: the membership read answers the order too.
			mctx := WithMemo(ctx)
			if _, err := h.MemberRole(mctx, a, t1); err != nil {
				t.Fatal(err)
			}
			if got, err := co.ChannelOrder(mctx, t1, a); err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("memo read: %v %v", got, err)
			}
			// [] clears.
			if err := co.SetChannelOrder(ctx, t1, a, nil); err != nil {
				t.Fatal(err)
			}
			if got, err := co.ChannelOrder(ctx, t1, a); err != nil || got != nil {
				t.Fatalf("cleared: %v %v", got, err)
			}
		})
	}
}
