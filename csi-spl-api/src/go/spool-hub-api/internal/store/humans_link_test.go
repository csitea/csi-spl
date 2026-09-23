package store

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"
)

// CLE-3451 defect 2. Before this, Admit keyed only on (provider, subject), so
// registering a password for an address that already had a Google identity
// minted a SECOND, unlinked human - which then matched no invite, found
// bootstrap spent, and ended ErrNotAdmitted -> 403 not_allowed. Linking is an
// account-takeover surface, so every test below also pins what must NOT merge.

type identityUnverifier interface {
	unverifyIdentity(provider, subject string)
}

// A new identity whose PROVIDER-VERIFIED address already belongs to a human
// joins that human, whichever direction it arrives from.
func TestHumansAdmitLinksVerifiedAddress(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			mail := uid("owner-") + "@example.com"
			goog, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("g-"), Email: mail, Name: "FirstName LastName"}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			// The native sign-up the owner was trapped by: same address, new
			// provider. One human, not two.
			pw, err := h.Admit(ctx, Identity{Provider: ProviderNative, Subject: mail, Email: mail}, "", AdmitPolicy{}, now)
			if err != nil || pw != goog {
				t.Fatalf("password identity for a Google address: %q %v, want %q", pw, err, goog)
			}
			// And the other direction: a third provider joins the same human.
			fb, err := h.Admit(ctx, Identity{Provider: "facebook", Subject: uid("f-"), Email: mail}, "", AdmitPolicy{}, now)
			if err != nil || fb != goog {
				t.Fatalf("facebook identity: %q %v, want %q", fb, err, goog)
			}
			// Each is still its own identity: (provider, subject) stays the key.
			if again, err := h.Admit(ctx, Identity{Provider: ProviderNative, Subject: mail, Email: mail}, "", AdmitPolicy{}, now); err != nil || again != goog {
				t.Fatalf("repeat password callback: %q %v", again, err)
			}
			// A linked identity inherits the tenant membership the human has,
			// without an invite of its own - the point of the fix.
			tid := newTenant(t, s)
			if _, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("g-"), Email: mail}, tid,
				AdmitPolicy{BootstrapOwner: true}, now); err != nil {
				t.Fatalf("bootstrap: %v", err)
			}
			got, err := h.Admit(ctx, Identity{Provider: "microsoft", Subject: uid("m-"), Email: mail}, tid, AdmitPolicy{}, now)
			if err != nil || got != goog {
				t.Fatalf("linked identity on the human's own tenant: %q %v, want %q", got, err, goog)
			}
			if r, err := h.MemberRole(ctx, got, tid); err != nil || r != RoleTenantOwner {
				t.Fatalf("linked identity kept the role: %q %v", r, err)
			}
		})
	}
}

// CONTROL: an UNVERIFIED address never merges, on either side. Both halves
// must hold or the link becomes "claim any account by asserting its address".
func TestHumansAdmitRefusesToLinkUnverifiedAddress(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			mail := uid("victim-") + "@example.com"
			victim, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("g-"), Email: mail}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}

			// (a) NEW side unverified. A provider that did not assert the
			// address hands Admit an empty Email (auth FR-004: idp.go /
			// oidc.go refuse the sign-in rather than pass an unverified one).
			// It gets its OWN human, never the victim's.
			anon, err := h.Admit(ctx, Identity{Provider: "facebook", Subject: uid("f-")}, "", AdmitPolicy{}, now)
			if err != nil || anon == victim {
				t.Fatalf("identity with no asserted address linked: %q %v (victim %q)", anon, err, victim)
			}

			// (b) STORED side unverified: a human_identities row that carries
			// the address with email_verified = false is not something to
			// merge onto either.
			unsub := uid("u-")
			unver, err := h.Admit(ctx, Identity{Provider: "linkedin", Subject: unsub, Email: uid("unver-") + "@example.com"}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			u, ok := s.(identityUnverifier)
			if !ok {
				t.Fatalf("%s has no unverifyIdentity hook", name)
			}
			// Point that row at the victim's address, then clear its verified
			// flag: the row now claims the address without having proved it.
			claimed := uid("claim-") + "@example.com"
			if _, err := h.Admit(ctx, Identity{Provider: "linkedin", Subject: unsub, Email: claimed}, "", AdmitPolicy{}, now); err != nil {
				t.Fatal(err)
			}
			u.unverifyIdentity("linkedin", unsub)
			fresh, err := h.Admit(ctx, Identity{Provider: "microsoft", Subject: uid("m-"), Email: claimed}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			if fresh == unver {
				t.Fatalf("linked onto an UNVERIFIED stored address: %q", fresh)
			}
		})
	}
}

// CONTROL: two people with different addresses never collapse into one human,
// however many providers each of them uses.
func TestHumansAdmitKeepsDifferentPeopleApart(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			aMail, bMail := uid("a-")+"@example.com", uid("b-")+"@example.com"
			seen := map[string]string{}
			for _, c := range []struct{ provider, mail string }{
				{"google", aMail}, {ProviderNative, aMail}, {"facebook", aMail},
				{"google", bMail}, {ProviderNative, bMail}, {"microsoft", bMail},
			} {
				hum, err := h.Admit(ctx, Identity{Provider: c.provider, Subject: uid("s-"), Email: c.mail}, "", AdmitPolicy{}, now)
				if err != nil {
					t.Fatal(err)
				}
				if was, ok := seen[c.mail]; ok && was != hum {
					t.Fatalf("%s/%s split into %q and %q", c.provider, c.mail, was, hum)
				}
				seen[c.mail] = hum
			}
			if seen[aMail] == seen[bMail] {
				t.Fatalf("two addresses collapsed into %q", seen[aMail])
			}
		})
	}
}

// CONTROL: the serialisation survives linking. Concurrent FIRST callbacks of
// DIFFERENT providers carrying ONE verified address must settle on one human,
// exactly as concurrent callbacks of one identity already did.
func TestHumansAdmitLinkingIsSerialised(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			mail := uid("race-") + "@example.com"
			const n = 8
			out := make(chan string, n)
			errs := make(chan error, n)
			var wg sync.WaitGroup
			for i := 0; i < n; i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					hum, err := h.Admit(ctx, Identity{Provider: fmt.Sprintf("p%d", i), Subject: uid("s-"), Email: mail},
						"", AdmitPolicy{}, time.Now().UTC())
					out <- hum
					errs <- err
				}(i)
			}
			wg.Wait()
			close(out)
			close(errs)
			for err := range errs {
				if err != nil {
					t.Fatal(err)
				}
			}
			ids := map[string]int{}
			for hum := range out {
				ids[hum]++
			}
			if len(ids) != 1 {
				t.Fatalf("%d concurrent first callbacks of one address minted %d humans: %v", n, len(ids), ids)
			}
		})
	}
}

// CLE-3451 defect 1's lookup: which IdPs carry a verified address.
func TestHumansFederatedAccount(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			mail := uid("fed-") + "@example.com"
			hum, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("g-"), Email: mail}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			if err := h.SetPreferredLocale(ctx, hum, "fi"); err != nil {
				t.Fatal(err)
			}
			provs, loc, err := h.FederatedAccount(ctx, mail)
			if err != nil || len(provs) != 1 || provs[0] != "google" || loc != "fi" {
				t.Fatalf("google only: %v %q %v", provs, loc, err)
			}
			// Case and spacing are normalised the same way Admit normalises them.
			if provs, _, err := h.FederatedAccount(ctx, "  "+uppercase(mail)+" "); err != nil || len(provs) != 1 {
				t.Fatalf("normalisation: %v %v", provs, err)
			}
			// The native identity is NOT a federated one: adding a password
			// must not make the address look like it has two IdPs.
			if _, err := h.Admit(ctx, Identity{Provider: ProviderNative, Subject: mail, Email: mail}, "", AdmitPolicy{}, now); err != nil {
				t.Fatal(err)
			}
			if provs, _, err := h.FederatedAccount(ctx, mail); err != nil || len(provs) != 1 || provs[0] != "google" {
				t.Fatalf("password counted as a provider: %v %v", provs, err)
			}
			// Sorted, so the mail wording does not depend on map order.
			if _, err := h.Admit(ctx, Identity{Provider: "facebook", Subject: uid("f-"), Email: mail}, "", AdmitPolicy{}, now); err != nil {
				t.Fatal(err)
			}
			if provs, _, err := h.FederatedAccount(ctx, mail); err != nil || len(provs) != 2 ||
				provs[0] != "facebook" || provs[1] != "google" {
				t.Fatalf("sorted providers: %v %v", provs, err)
			}
			// CONTROL: an address nobody signs in with is an empty list and a
			// nil error - the forgot route must not be able to tell it apart.
			if provs, loc, err := h.FederatedAccount(ctx, uid("ghost-")+"@example.com"); err != nil || len(provs) != 0 || loc != "" {
				t.Fatalf("unknown address: %v %q %v", provs, loc, err)
			}
			if provs, _, err := h.FederatedAccount(ctx, ""); err != nil || len(provs) != 0 {
				t.Fatalf("empty address: %v %v", provs, err)
			}
			// CONTROL: a disabled human is not offered a sign-in button.
			s.(interface{ disableHuman(string) }).disableHuman(hum)
			if provs, _, err := h.FederatedAccount(ctx, mail); err != nil || len(provs) != 0 {
				t.Fatalf("disabled human listed: %v %v", provs, err)
			}
		})
	}
}

func uppercase(s string) string {
	out := []rune(s)
	for i, r := range out {
		if r >= 'a' && r <= 'z' {
			out[i] = r - 32
		}
	}
	return string(out)
}
