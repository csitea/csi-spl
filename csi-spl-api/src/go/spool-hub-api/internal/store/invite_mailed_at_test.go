package store

import (
	"context"
	"testing"
	"time"
)

// HUM-10 2026-10-03: the Members page said "not sent" for an invite whose
// mail went out, because a re-invite resets mail_count. ListInvites carries
// mailed_at, which a re-invite keeps. CONTROL: nil before the first send.
func TestListInvitesMailedAtSurvivesReinvite(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	lim := InviteMailLimits{MinGap: 10 * time.Minute, MaxSends: 5}
	for name, s := range drivers(t) {
		h, im, d := s.(Humans), s.(InviteMails), s.(MemberDirectory)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			email := uid("m-") + "@example.com"
			put := func(at time.Time) {
				t.Helper()
				if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: email, InvitedBy: AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, at); err != nil {
					t.Fatal(err)
				}
			}
			one := func() PendingInvite {
				t.Helper()
				ins, err := d.ListInvites(ctx, tid)
				if err != nil || len(ins) != 1 {
					t.Fatalf("invites = %+v, %v", ins, err)
				}
				return ins[0]
			}
			put(now)
			if in := one(); in.MailedAt != nil || in.MailCount != 0 {
				t.Fatalf("CONTROL: never mailed, got mailed_at=%v count=%d", in.MailedAt, in.MailCount)
			}
			sent := now.Add(time.Minute)
			if c, err := im.ClaimInviteMail(ctx, tid, email, lim, sent); err != nil || c.Outcome != InviteMailClaimed {
				t.Fatalf("claim: %+v %v", c, err)
			}
			if in := one(); in.MailedAt == nil || !in.MailedAt.Equal(sent) || in.MailCount != 1 {
				t.Fatalf("after send: mailed_at=%v count=%d", in.MailedAt, in.MailCount)
			}
			put(now.Add(6 * time.Minute))
			if in := one(); in.MailedAt == nil || !in.MailedAt.Equal(sent) || in.MailCount != 0 {
				t.Fatalf("re-invite lost the send: mailed_at=%v count=%d", in.MailedAt, in.MailCount)
			}
		})
	}
}
