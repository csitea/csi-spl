package store

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// CLE-77778 (rdb 0084): who ordered an invite (ordered_by, ordered_via)
// round-trips through PutInvite, shows on the pending invite with the
// orderer's display name, and — once accepted — reads back on the member by
// joining the accepted invite. An invite with no orderer stays blank, never
// guessed. A bad ordered_by is refused.
func TestInviteProvenance(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		d := s.(MemberDirectory)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			// The orderer is a real human of the tenant with a display name.
			orderer := admitAs(t, h, tid, rbac.Admin)
			if err := h.SetDisplayName(ctx, orderer, "Orderer One"); err != nil {
				t.Fatalf("name orderer: %v", err)
			}

			// A pending invite carrying provenance.
			pend := uid("p-") + "@example.com"
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: pend, Role: rbac.Developer,
				InvitedBy: AdmittedOperator, ExpiresAt: now.Add(time.Hour),
				OrderedBy: orderer, OrderedVia: "CLE-34967"}, now); err != nil {
				t.Fatalf("put invite: %v", err)
			}
			ins, err := d.ListInvites(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			if len(ins) != 1 {
				t.Fatalf("invites = %+v", ins)
			}
			if ins[0].OrderedBy != orderer || ins[0].OrderedVia != "CLE-34967" || ins[0].OrderedByName != "Orderer One" {
				t.Fatalf("pending invite provenance = %+v", ins[0])
			}

			// Accept it: the member reads its provenance back through the join.
			hum, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("s-"), Email: pend}, tid, AdmitPolicy{}, now)
			if err != nil {
				t.Fatalf("admit: %v", err)
			}
			ms, err := d.ListMembers(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			var got *Member
			for i := range ms {
				if ms[i].HumanID == hum {
					got = &ms[i]
				}
			}
			if got == nil {
				t.Fatalf("member %s not listed: %+v", hum, ms)
			}
			if got.OrderedBy != orderer || got.OrderedVia != "CLE-34967" || got.OrderedByName != "Orderer One" || got.InvitedOn.IsZero() {
				t.Fatalf("member provenance = %+v", *got)
			}

			// The orderer, admitted with no provenance, stays blank.
			for i := range ms {
				if ms[i].HumanID == orderer {
					if ms[i].OrderedBy != "" || ms[i].OrderedVia != "" || ms[i].OrderedByName != "" {
						t.Fatalf("CONTROL: provenance guessed for a non-invite member: %+v", ms[i])
					}
				}
			}

			// A malformed ordered_by is refused before any write.
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: uid("b-") + "@example.com", Role: rbac.Developer,
				InvitedBy: AdmittedOperator, ExpiresAt: now.Add(time.Hour), OrderedBy: "not-a-hum"}, now); err == nil {
				t.Fatal("CONTROL: a malformed ordered_by was accepted")
			}
		})
	}
}
