package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// the Users page directory lists one tenant's members and pending
// invites only, and revokes a pending invite. CONTROLS: another tenant's rows
// never show, an accepted invite is neither listed nor revocable, a revoked
// invite no longer admits.
func TestMemberDirectory(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		d := s.(MemberDirectory)
		t.Run(name, func(t *testing.T) {
			tid, other := newTenant(t, s), newTenant(t, s)
			adm := admitAs(t, h, tid, rbac.Admin)
			dev := admitAs(t, h, tid, rbac.Developer)
			stranger := admitAs(t, h, other, rbac.Admin)
			pend := uid("p-") + "@example.com"
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: pend, Role: rbac.Tester, InvitedBy: adm,
				ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}
			if err := h.PutInvite(ctx, Invite{TenantID: other, Email: uid("o-") + "@example.com", Role: rbac.Tester,
				InvitedBy: stranger, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
				t.Fatal(err)
			}

			ms, err := d.ListMembers(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			got := map[string]Member{}
			for _, m := range ms {
				got[m.HumanID] = m
			}
			if len(ms) != 2 || got[adm].Role != rbac.Admin || got[dev].Role != rbac.Developer || got[dev].Email == "" || got[dev].Since.IsZero() {
				t.Fatalf("members = %+v", ms)
			}
			if _, leak := got[stranger]; leak {
				t.Fatalf("CONTROL: another tenant's member listed: %+v", ms)
			}
			ins, err := d.ListInvites(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			// admitAs's two invites were accepted: only the pending one shows.
			if len(ins) != 1 || ins[0].Email != pend || ins[0].Role != rbac.Tester || ins[0].InvitedBy != adm || ins[0].CreatedAt.IsZero() {
				t.Fatalf("invites = %+v", ins)
			}
			if err := d.RevokeInvite(ctx, other, pend); !errors.Is(err, ErrNotFound) {
				t.Fatalf("CONTROL: revoke through another tenant: %v", err)
			}
			if err := d.RevokeInvite(ctx, tid, " "+pend+" "); err != nil {
				t.Fatalf("revoke: %v", err)
			}
			if err := d.RevokeInvite(ctx, tid, pend); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second revoke: %v", err)
			}
			if ins, _ := d.ListInvites(ctx, tid); len(ins) != 0 {
				t.Fatalf("revoked invite still listed: %+v", ins)
			}
			if _, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("r-"), Email: pend}, tid, AdmitPolicy{}, now); !errors.Is(err, ErrNotAdmitted) {
				t.Fatalf("CONTROL: a revoked invite admitted: %v", err)
			}
		})
	}
}
