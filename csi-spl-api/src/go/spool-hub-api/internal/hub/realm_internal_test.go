package hub

import (
	"context"
	"crypto/ed25519"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// realmSeatsNotPerson (spec 119 T-N8): a seat that is only an agent or a
// time-accountant has no realm; any person seat, or no seat at all (every
// workspace left), keeps it.
func TestRealmSeatsNotPerson(t *testing.T) {
	m := func(roles ...string) []store.Membership {
		out := make([]store.Membership, 0, len(roles))
		for i, r := range roles {
			out = append(out, store.Membership{TenantID: "t" + string(rune('a'+i)), Role: r})
		}
		return out
	}
	cases := []struct {
		name  string
		seats []store.Membership
		want  bool
	}{
		{"no seat: the person left every workspace", nil, false},
		{"a developer", m(rbac.Developer), false},
		{"a pure agent seat", m(rbac.PureAgent), true},
		{"a time-accountant-only seat", m(realmTimeAccountant), true},
		{"agent and time-accountant seats only", m(rbac.PureAgent, realmTimeAccountant), true},
		{"a time-accountant who is also a worker elsewhere", m(realmTimeAccountant, rbac.Tester), false},
		{"a foreman's combined roles (biz_owner)", m(rbac.BizOwner), false},
	}
	for _, tc := range cases {
		if got := realmSeatsNotPerson(tc.seats); got != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

// realmRefuses (T-N7 route half, T-N8): act-as and an agent id are refused
// before any read; the seats decide for a HUM-*.
func TestRealmRefuses(t *testing.T) {
	st := store.NewMemory()
	s, err := New(Options{Store: st, Blob: blob.Dir{Root: t.TempDir()}, TenantHostPattern: "{tenant}.example.test"})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Shutdown()
	ctx := context.Background()
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := st.CreateTenant(ctx, store.Tenant{ID: "trealm", RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	seatAs := func(role, sub string) string {
		now := time.Now()
		email := sub + "@example.com"
		if err := st.PutInvite(ctx, store.Invite{TenantID: "trealm", Email: email, Role: role,
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		hum, err := st.Admit(ctx, store.Identity{Provider: "google", Subject: sub, Email: email}, "trealm", store.AdmitPolicy{}, now)
		if err != nil {
			t.Fatal(err)
		}
		return hum
	}
	dev := seatAs(rbac.Developer, "dev")
	agent := seatAs(rbac.PureAgent, "agent")

	cases := []struct {
		name string
		sess auth.Session
		want bool
	}{
		{"CONTROL: a developer's own session", auth.Session{HumanID: dev, Tenant: "trealm"}, false},
		{"a person with no seat", auth.Session{HumanID: "HUM-424242"}, false},
		{"act-as: the clone session", auth.Session{Provider: auth.ProviderActAs, HumanID: dev, Tenant: "trealm"}, true},
		{"an agent id", auth.Session{HumanID: "AGT-1"}, true},
		{"an empty id", auth.Session{}, true},
		{"an injection", auth.Session{HumanID: "HUM-1; --"}, true},
		{"a pure agent seat", auth.Session{HumanID: agent, Tenant: "trealm"}, true},
	}
	for _, tc := range cases {
		got, err := s.realmRefuses(ctx, tc.sess)
		if err != nil || got != tc.want {
			t.Errorf("%s: refuses=%v err=%v, want %v", tc.name, got, err, tc.want)
		}
	}
}
