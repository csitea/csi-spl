package store

import (
	"context"
	"testing"
	"time"
)

// 010 FR-016 / T062: only an open invite is mailed; the gap and the cap hold;
// a re-invite resets the count but not the gap; Release undoes one claim.
func TestInviteMailClaim(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	lim := InviteMailLimits{MinGap: 10 * time.Minute, MaxSends: 2}
	for name, s := range drivers(t) {
		h, im := s.(Humans), s.(InviteMails)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			put := func(email string, exp time.Time) {
				t.Helper()
				if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: email, InvitedBy: AdmittedOperator, ExpiresAt: exp}, now); err != nil {
					t.Fatal(err)
				}
			}
			claim := func(email string, at time.Time) InviteMailClaim {
				t.Helper()
				c, err := im.ClaimInviteMail(ctx, tid, email, lim, at)
				if err != nil {
					t.Fatal(err)
				}
				return c
			}

			if c := claim("nobody@example.com", now); c.Outcome != InviteMailNotFound {
				t.Fatalf("unknown invite: %+v", c)
			}
			// CONTROL: expired -> no mail.
			put("late@example.com", now.Add(-time.Second))
			if c := claim("late@example.com", now); c.Outcome != InviteMailExpired {
				t.Fatalf("expired: %+v", c)
			}

			put("Open@Example.com", now.Add(7*24*time.Hour))
			c := claim("open@example.com", now)
			if c.Outcome != InviteMailClaimed || c.Invite.Role != RoleMember || c.PrevMailedAt != nil || c.PrevMailCount != 0 {
				t.Fatalf("first claim: %+v", c)
			}
			// CONTROL: the gap holds.
			if c := claim("open@example.com", now.Add(time.Minute)); c.Outcome != InviteMailRateLimited {
				t.Fatalf("inside the gap: %+v", c)
			}
			// Release undoes the claim: the next send is allowed at once.
			if err := im.ReleaseInviteMail(ctx, c); err != nil {
				t.Fatal(err)
			}
			if c := claim("open@example.com", now.Add(time.Minute)); c.Outcome != InviteMailClaimed || c.PrevMailCount != 0 {
				t.Fatalf("after release: %+v", c)
			}
			if c := claim("open@example.com", now.Add(12*time.Minute)); c.Outcome != InviteMailClaimed || c.PrevMailCount != 1 {
				t.Fatalf("second send after the gap: %+v", c)
			}
			// CONTROL: the cap holds even after the gap.
			if c := claim("open@example.com", now.Add(time.Hour)); c.Outcome != InviteMailRateLimited {
				t.Fatalf("over the cap: %+v", c)
			}
			// A re-invite resets the count but keeps mailed_at: gap still holds.
			put("open@example.com", now.Add(7*24*time.Hour))
			if c := claim("open@example.com", now.Add(13*time.Minute)); c.Outcome != InviteMailRateLimited {
				t.Fatalf("re-invite kept the gap: %+v", c)
			}
			if c := claim("open@example.com", now.Add(time.Hour)); c.Outcome != InviteMailClaimed || c.PrevMailCount != 0 {
				t.Fatalf("re-invite reset the count: %+v", c)
			}

			// CONTROL: accepted -> no mail.
			put("acc@example.com", now.Add(time.Hour))
			if _, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("sub-"), Email: "acc@example.com"}, tid, AdmitPolicy{}, now); err != nil {
				t.Fatal(err)
			}
			if c := claim("acc@example.com", now); c.Outcome != InviteMailAccepted {
				t.Fatalf("accepted: %+v", c)
			}
		})
	}
}
