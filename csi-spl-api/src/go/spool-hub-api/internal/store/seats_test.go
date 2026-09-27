package store

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// 009 T002/T003 (spec D-1..D-5): seat occupancy, caps, and the gate that
// refuses only a NEW seat over cap. Memory always, Postgres with a DSN.
func TestSeatsUserCap(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	boot := AdmitPolicy{BootstrapOwner: true}
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			if tn, err := s.GetTenant(ctx, tid); err != nil || tn.SeatsUsers != 0 || tn.SeatsBots != 0 {
				t.Fatalf("default caps 0 (M4 off): %+v %v", tn, err)
			}
			owner := Identity{Provider: "google", Subject: uid("o-"), Email: "owner@example.com"}
			o, err := h.Admit(ctx, owner, tid, boot, now)
			if err != nil {
				t.Fatal(err)
			}
			if err := s.SetSeatCaps(ctx, tid, 2, 0); err != nil {
				t.Fatal(err)
			}
			if err := s.SetSeatCaps(ctx, tid, -1, 0); err == nil {
				t.Fatal("negative cap accepted")
			}
			if err := s.SetSeatCaps(ctx, uid("t-"), 1, 1); !errors.Is(err, ErrNotFound) {
				t.Fatalf("absent tenant caps: %v", err)
			}
			invite := func(email string) {
				if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: email, InvitedBy: o, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
					t.Fatal(err)
				}
			}
			invite("second@example.com")
			invite("third@example.com")
			second := Identity{Provider: "google", Subject: uid("s-"), Email: "second@example.com"}
			third := Identity{Provider: "google", Subject: uid("t-"), Email: "third@example.com"}
			if _, err := h.Admit(ctx, second, tid, boot, now); err != nil {
				t.Fatalf("second seat of 2: %v", err)
			}
			if n, err := s.CountMembers(ctx, tid); err != nil || n != 2 {
				t.Fatalf("members = %d %v", n, err)
			}
			// CONTROL: a new member over cap is refused and writes nothing.
			if _, err := h.Admit(ctx, third, tid, boot, now); !errors.Is(err, ErrSeatQuota) {
				t.Fatalf("third seat over cap 2: %v", err)
			}
			if n, _ := s.CountMembers(ctx, tid); n != 2 {
				t.Fatalf("refusal wrote a membership: %d", n)
			}
			// CONTROL: the same member re-login is a no-op, never a seat.
			if got, err := h.Admit(ctx, owner, tid, boot, now); err != nil || got != o {
				t.Fatalf("owner re-login at cap: %q %v", got, err)
			}
			// The refused invite was not consumed: raising the cap admits it.
			if err := s.SetSeatCaps(ctx, tid, 3, 0); err != nil {
				t.Fatal(err)
			}
			if _, err := h.Admit(ctx, third, tid, boot, now); err != nil {
				t.Fatalf("third after cap raise: %v", err)
			}
			// Lowered cap: a new member is refused; the registrar says not_allowed (D-6).
			if err := s.SetSeatCaps(ctx, tid, 1, 0); err != nil {
				t.Fatal(err)
			}
			invite("fourth@example.com")
			if _, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("f-"), Email: "fourth@example.com"}, tid, boot, now); !errors.Is(err, ErrSeatQuota) {
				t.Fatalf("fourth on lowered cap: %v", err)
			}
			reg := AuthHooks{H: h, Policy: boot}
			if _, err := reg.Register(ctx, auth.Identity{Provider: "google", Subject: uid("f-"), Email: "fourth@example.com"}, tid); !errors.Is(err, auth.ErrNotAllowed) {
				t.Fatalf("registrar over cap: %v", err)
			}
			// Existing members keep working on a lowered cap.
			if got, err := h.Admit(ctx, second, tid, boot, now); err != nil || got == "" {
				t.Fatalf("existing member on lowered cap: %v", err)
			}
			// cap 0 = M4 off: no limit.
			if err := s.SetSeatCaps(ctx, tid, 0, 0); err != nil {
				t.Fatal(err)
			}
			if _, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("f-"), Email: "fourth@example.com"}, tid, boot, now); err != nil {
				t.Fatalf("cap 0 unlimited: %v", err)
			}
		})
	}
}

func TestSeatsBotCap(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			// HUM-* in a roster is not a bot seat; the same id on two boxes is two.
			if err := s.SetRoster(ctx, tid, "box-a", []string{"CLE-1", "HUM-9"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, tid, "box-b", []string{"CLE-1"}, now); err != nil {
				t.Fatal(err)
			}
			if n, err := s.CountBots(ctx, tid); err != nil || n != 2 {
				t.Fatalf("bots = %d %v", n, err)
			}
			if err := s.SetSeatCaps(ctx, tid, 0, 3); err != nil {
				t.Fatal(err)
			}
			// Growing box-a from 1 to 2 bots: total 3 <= 3.
			if err := s.SetRoster(ctx, tid, "box-a", []string{"CLE-1", "CLE-2", "HUM-9"}, now); err != nil {
				t.Fatalf("grow to cap: %v", err)
			}
			// Same set again (re-announce) at cap: ok.
			if err := s.SetRoster(ctx, tid, "box-a", []string{"CLE-1", "CLE-2", "HUM-9"}, now); err != nil {
				t.Fatalf("re-announce at cap: %v", err)
			}
			// CONTROL: re-announce growing past cap → refused, roster unchanged.
			if err := s.SetRoster(ctx, tid, "box-a", []string{"CLE-1", "CLE-2", "CLE-3"}, now); !errors.Is(err, ErrSeatQuota) {
				t.Fatalf("grow past cap: %v", err)
			}
			if r, _ := s.Roster(ctx, tid); strings.Join(r["box-a"], ",") != "CLE-1,CLE-2,HUM-9" {
				t.Fatalf("refusal changed the roster: %v", r["box-a"])
			}
			// A new box's first agent over cap: refused.
			if err := s.SetRoster(ctx, tid, "box-c", []string{"GRK-1"}, now); !errors.Is(err, ErrSeatQuota) {
				t.Fatalf("new box over cap: %v", err)
			}
			// Adding a HUM-* is not a bot seat.
			if err := s.SetRoster(ctx, tid, "box-b", []string{"CLE-1", "HUM-4"}, now); err != nil {
				t.Fatalf("HUM add at cap: %v", err)
			}
			// CONTROL: shrinking is always ok, also on a cap lowered below occupancy.
			if err := s.SetSeatCaps(ctx, tid, 0, 1); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, tid, "box-a", []string{"CLE-1"}, now); err != nil {
				t.Fatalf("shrink over lowered cap: %v", err)
			}
			// Swapping an agent while still over cap is a new seat: refused.
			if err := s.SetRoster(ctx, tid, "box-a", []string{"CLE-5"}, now); !errors.Is(err, ErrSeatQuota) {
				t.Fatalf("swap over cap: %v", err)
			}
			if n, _ := s.CountBots(ctx, tid); n != 2 {
				t.Fatalf("bots after shrink = %d", n)
			}
		})
	}
}

// 009 T005-T007 (D-8): mint, persist, clash retry, hosted NULLs.
func TestSeatsBuyStamp(t *testing.T) {
	ctx := context.Background()
	at := time.Date(2026, 9, 17, 17, 43, 59, 0, time.FixedZone("x", 3*3600))
	id, err := MintProjectID("abc", "xyz", "dev", at)
	if err != nil || id != "abc-xyz-dev-202609171443" {
		t.Fatalf("mint uses the UTC minute: %q %v", id, err)
	}
	if len(id) != 24 || len(id) > ProjectIDMaxLen {
		t.Fatalf("length %d", len(id))
	}
	for _, bad := range [][3]string{{"CSI", "spl", "dev"}, {"cs", "spl", "dev"}, {"csi", "spl", ""}, {"csi", "spl", "dev-x"}} {
		if _, err := MintProjectID(bad[0], bad[1], bad[2], at); err == nil {
			t.Fatalf("mint accepted %v", bad)
		}
	}
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			// Hosted M2: two tenants with NULL project_id coexist.
			h1, h2 := newTenant(t, s), newTenant(t, s)
			for _, h := range []string{h1, h2} {
				if err := s.SetBuyStamp(ctx, h, "", "", "", at); err != nil {
					t.Fatalf("hosted NULL project_id: %v", err)
				}
			}
			if tn, _ := s.GetTenant(ctx, h2); tn.ProjectID != "" || !tn.BoughtAt.Equal(at) {
				t.Fatalf("hosted stamp: %+v", tn)
			}
			// Unique suffix per run so a shared Postgres never clashes across runs.
			org, app := "csi", "spl"
			n, _ := strconv.ParseInt(uid("")[:8], 16, 64)
			when := time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC).Add(time.Duration(n%5_000_000) * time.Minute)
			a, b, c := newTenant(t, s), newTenant(t, s), newTenant(t, s)
			pa, err := StampBuy(ctx, s, a, org, app, "dev", when)
			if err != nil {
				t.Fatal(err)
			}
			want, _ := MintProjectID(org, app, "dev", when)
			if pa != want {
				t.Fatalf("first stamp %q want %q", pa, want)
			}
			// CONTROL: same org+app+env+minute → next minute.
			pb, err := StampBuy(ctx, s, b, org, app, "dev", when)
			next, _ := MintProjectID(org, app, "dev", when.Add(time.Minute))
			if err != nil || pb != next {
				t.Fatalf("collision retry: %q want %q %v", pb, next, err)
			}
			tb, _ := s.GetTenant(ctx, b)
			if tb.ProjectID != pb || tb.Org != org || tb.App != app || !tb.BoughtAt.Equal(when) {
				t.Fatalf("persisted stamp: %+v", tb)
			}
			// Direct clash is ErrConflict and writes nothing.
			if err := s.SetBuyStamp(ctx, c, org, app, pa, when); !errors.Is(err, ErrConflict) {
				t.Fatalf("duplicate project_id: %v", err)
			}
			if tc, _ := s.GetTenant(ctx, c); tc.ProjectID != "" {
				t.Fatalf("clash wrote: %+v", tc)
			}
			// Every minute taken → 2-char nonce.
			for i := 2; i <= StampRetryMinutes; i++ {
				m, _ := MintProjectID(org, app, "dev", when.Add(time.Duration(i)*time.Minute))
				if err := s.SetBuyStamp(ctx, newTenant(t, s), org, app, m, when); err != nil {
					t.Fatal(err)
				}
			}
			pc, err := StampBuy(ctx, s, c, org, app, "dev", when)
			if err != nil || !strings.HasPrefix(pc, pa+"-") || len(pc) != len(pa)+3 || len(pc) > ProjectIDMaxLen {
				t.Fatalf("nonce fallback: %q %v", pc, err)
			}
			if err := s.SetBuyStamp(ctx, uid("t-"), org, app, "", when); !errors.Is(err, ErrNotFound) {
				t.Fatalf("absent tenant stamp: %v", err)
			}
			if err := s.SetBuyStamp(ctx, c, "", "", "abcdef", when); err == nil {
				t.Fatal("project_id without org/app accepted")
			}
			// CreateTenant carries the M4 fields; a held project_id is a conflict.
			if err := s.CreateTenant(ctx, Tenant{ID: uid("t-"), RootPubKey: pubkey(), Org: org, App: app, ProjectID: pa}); !errors.Is(err, ErrConflict) {
				t.Fatalf("create with held project_id: %v", err)
			}
			nid := uid("t-")
			if err := s.CreateTenant(ctx, Tenant{ID: nid, RootPubKey: pubkey(), Org: org, App: app, SeatsUsers: 5, SeatsBots: 7, BoughtAt: when}); err != nil {
				t.Fatal(err)
			}
			if tn, _ := s.GetTenant(ctx, nid); tn.SeatsUsers != 5 || tn.SeatsBots != 7 || tn.Org != org || !tn.BoughtAt.Equal(when) {
				t.Fatalf("create round-trip: %+v", tn)
			}
		})
	}
}
