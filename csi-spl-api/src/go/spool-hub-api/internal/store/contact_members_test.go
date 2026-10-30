package store

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 154 B6 (section 2.4, C13b, C13d): who MembersByVerifiedEmail never
// answers, seeded below the store API because no write path makes these
// rows: an identity that carries the address with email_verified false, a
// channel guest's seat, a disabled human (humans.disabled_at, not the
// membership) and a technical human. Each case is next to its twin, a
// verified, enabled member of the same workspace that matches. Memory, and
// Postgres as the runtime login under hub-pg.tst.sh (SPOOL_TEST_PG_DSN and
// SPOOL_TEST_PG_RUNTIME_DSN). The hub's route tests are
// hub/contacts_match_test.go. Fixtures are example.com.

// cmHuman is how a seeded human is marked.
type cmHuman struct{ disabled, technical bool }

// cmFix is one driver: the store, and the seeds.
type cmFix struct {
	st        ContactMembers
	technical bool // the store keeps humans.technical (Postgres only)
	tenant    func(t *testing.T) string
	human     func(t *testing.T, h cmHuman) string
	ident     func(t *testing.T, hum, email string, verified bool)
	seat      func(t *testing.T, tenant, hum, role string)
}

func memCMFix(*testing.T) cmFix {
	m := NewMemory()
	return cmFix{st: m,
		tenant: func(*testing.T) string { return uid("t-c694-") },
		human: func(_ *testing.T, h cmHuman) string {
			hum := "HUM-" + uid("m")
			m.mu.Lock()
			defer m.mu.Unlock()
			m.hum.init()
			m.hum.humans[hum] = &memHuman{disabled: h.disabled}
			return hum
		},
		ident: func(_ *testing.T, hum, email string, verified bool) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.hum.identities[[2]string{"google", uid("s-")}] = &memIdent{human: hum, email: email, verified: verified}
		},
		seat: func(_ *testing.T, tenant, hum, role string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.hum.members[[2]string{tenant, hum}] = memMember{role: role}
		},
	}
}

// pgCMFix seeds as the migrate login and reads as the runtime login, so
// the read runs under the workspace RLS the hub runs under.
func pgCMFix(t *testing.T) cmFix {
	t.Helper()
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx := context.Background()
	return cmFix{st: rt, technical: true,
		tenant: func(t *testing.T) string {
			w := uid("t-c694-")
			if err := pg.CreateTenant(ctx, Tenant{ID: w, RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
			return w
		},
		human: func(t *testing.T, h cmHuman) string {
			var hum string
			if err := pg.pool.QueryRow(ctx, `INSERT INTO humans (display_name, technical, disabled_at)
				VALUES ('FirstName LastName', $1, CASE WHEN $2 THEN now() END) RETURNING human_id`,
				h.technical, h.disabled).Scan(&hum); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { pg.pool.Exec(ctx, `DELETE FROM humans WHERE human_id = $1`, hum) }) //nolint:errcheck
			return hum
		},
		ident: func(t *testing.T, hum, email string, verified bool) {
			if _, err := pg.pool.Exec(ctx, `INSERT INTO human_identities (provider, subject, human_id, email, email_verified)
				VALUES ('google', $1, $2, $3, $4)`, uid("s-"), hum, email, verified); err != nil {
				t.Fatal(err)
			}
		},
		seat: func(t *testing.T, tenant, hum, role string) {
			if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by)
					VALUES ($1, $2, $3, 'operator')`, tenant, hum, role)
				return err
			}); err != nil {
				t.Fatal(err)
			}
		},
	}
}

func eachCMFix(t *testing.T, run func(t *testing.T, f cmFix)) {
	t.Run("memory", func(t *testing.T) { run(t, memCMFix(t)) })
	t.Run("postgres", func(t *testing.T) { run(t, pgCMFix(t)) })
}

// cmMember seeds a human marked h with one identity of a fresh address,
// seated in tenant with role, and answers the address and the human.
func cmMember(t *testing.T, f cmFix, tenant, role string, h cmHuman, verified bool) (string, string) {
	t.Helper()
	hum := f.human(t, h)
	email := uid("c694-") + "@example.com"
	f.ident(t, hum, email, verified)
	f.seat(t, tenant, hum, role)
	return email, hum
}

// cmMatch is one MembersByVerifiedEmail call.
func cmMatch(t *testing.T, f cmFix, tenant string, emails ...string) map[string]string {
	t.Helper()
	got, err := f.st.MembersByVerifiedEmail(context.Background(), tenant, emails)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

// C13b at the store: the address is on an identity of a member, but the
// identity is not verified. Twin: a verified member matches.
func TestContactMembersVerifiedOnly(t *testing.T) {
	eachCMFix(t, func(t *testing.T, f cmFix) {
		w := f.tenant(t)
		unverified, _ := cmMember(t, f, w, rbac.Developer, cmHuman{}, false)
		verified, hum := cmMember(t, f, w, rbac.Developer, cmHuman{}, true)
		got := cmMatch(t, f, w, unverified, verified)
		if m, ok := got[unverified]; ok {
			t.Errorf("C13b: an unverified identity matched %s, want no match", m)
		}
		if got[verified] != hum {
			t.Errorf("C13b twin: verified = %q, want %s", got[verified], hum)
		}
	})
}

// 2.4 "must not be disabled", and a channel guest is no member: a guest's
// seat, a disabled human (humans.disabled_at; C13d's membership suspension
// is the hub test's) and a technical human never match. Twin: a plain
// verified member of the same workspace matches in the same call.
func TestContactMembersNotAMember(t *testing.T) {
	eachCMFix(t, func(t *testing.T, f cmFix) {
		w := f.tenant(t)
		member, hum := cmMember(t, f, w, rbac.Developer, cmHuman{}, true)
		guest, _ := cmMember(t, f, w, rbac.ChannelGuest, cmHuman{}, true)
		disabled, _ := cmMember(t, f, w, rbac.Developer, cmHuman{disabled: true}, true)
		emails := []string{member, guest, disabled}
		cases := map[string]string{guest: "a channel guest", disabled: "a disabled human"}
		if f.technical { // Memory's memHuman has no technical flag (humans_memory.go)
			technical, _ := cmMember(t, f, w, rbac.Developer, cmHuman{technical: true}, true)
			emails = append(emails, technical)
			cases[technical] = "a technical human"
		}
		got := cmMatch(t, f, w, emails...)
		for email, who := range cases {
			if m, ok := got[email]; ok {
				t.Errorf("%s matched %s, want no match", who, m)
			}
		}
		if got[member] != hum {
			t.Errorf("twin: the member = %q, want %s", got[member], hum)
		}
	})
}

// The workspace only (C13c at the store), and no addresses means no read:
// a member of another workspace is absent, read from this one.
func TestContactMembersThisWorkspaceOnly(t *testing.T) {
	eachCMFix(t, func(t *testing.T, f cmFix) {
		w1, w2 := f.tenant(t), f.tenant(t)
		email, hum := cmMember(t, f, w1, rbac.Developer, cmHuman{}, true)
		if got := cmMatch(t, f, w2, email); len(got) != 0 {
			t.Errorf("C13c: read from W2 = %v, want no match", got)
		}
		if got := cmMatch(t, f, w1, email); got[email] != hum {
			t.Errorf("C13c twin: read from W1 = %v, want %s", got, hum)
		}
		if got := cmMatch(t, f, w1); len(got) != 0 {
			t.Errorf("no addresses = %v, want empty", got)
		}
	})
}
