package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// SPL-1179 hardening: the tenant list is CRITICAL and must survive a failed
// read of the OPTIONAL per-tenant settings override (rdb 0078). The regression
// was the code shipping before the migration: the settings column did not
// exist, the whole Memberships query failed, the tenants list went empty, and
// the WUI switcher showed only the active tenant. Memberships now falls back to
// a settings-less list on undefined_column (SQLSTATE 42703). This proves the
// detection and the fallback query both work, and that the normal list carries
// every tenant with its name and the override.
func TestMembershipsListResilient(t *testing.T) {
	// isUndefinedColumn detects only 42703 (a missing column), not other errors.
	if !isUndefinedColumn(&pgconn.PgError{Code: "42703"}) {
		t.Fatal("42703 must read as undefined_column")
	}
	if isUndefinedColumn(errors.New("boom")) || isUndefinedColumn(&pgconn.PgError{Code: "42P01"}) {
		t.Fatal("a plain error / another SQLSTATE must not read as undefined_column")
	}

	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now()
			h := s.(Humans)
			ml := s.(MembershipLister)
			t1 := newNamedTenant(t, s, "Alpha")
			t2 := newNamedTenant(t, s, "Beta")
			admit := func(tid, email, sub string) string {
				t.Helper()
				if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: email, Role: "developer", InvitedBy: AdmittedOperator,
					ExpiresAt: now.Add(time.Hour)}, now); err != nil {
					t.Fatal(err)
				}
				hum, err := h.Admit(ctx, Identity{Provider: "google", Subject: sub, Email: email}, tid, AdmitPolicy{}, now)
				if err != nil {
					t.Fatal(err)
				}
				return hum
			}
			base := uid("alice")
			alice := admit(t1, base+"@example.com", "sub-"+base)
			admit(t2, base+"2@example.com", "sub-"+base) // same human, second tenant
			if err := s.(membershipSettingsStore).SetMembershipSettings(ctx, alice, t1, map[string]any{"preferred_theme": "dark"}); err != nil {
				t.Fatal(err)
			}

			names := func() (map[string]string, []string) {
				t.Helper()
				mems, err := ml.Memberships(ctx, alice)
				if err != nil {
					t.Fatal(err)
				}
				n, on := map[string]string{}, []string(nil)
				for _, m := range mems {
					n[m.TenantID] = m.DisplayName
					if len(m.Settings) > 0 {
						on = append(on, m.TenantID)
					}
				}
				return n, on
			}

			// The normal list: BOTH tenants, with their names, t1 carrying the override.
			n, on := names()
			if n[t1] != "Alpha" || n[t2] != "Beta" {
				t.Fatalf("tenants list lost a tenant or its name: %+v", n)
			}
			if len(on) != 1 || on[0] != t1 {
				t.Fatalf("override rode the wrong membership(s): %v", on)
			}

			// The Postgres FALLBACK: with the rdb 0078 column GONE (the SPL-1179
			// regression: code shipped before the migration), the list must STILL
			// carry both tenants with their names — the switcher keeps working.
			// t.Fatal runs the restore defer (runtime.Goexit), so the column is
			// always put back for the tests that follow (Go runs them sequentially).
			ps, ok := s.(*Postgres)
			if !ok {
				return
			}
			if _, err := ps.pool.Exec(ctx, `ALTER TABLE tenant_memberships DROP COLUMN settings CASCADE`); err != nil {
				t.Fatal(err)
			}
			defer func() {
				_, _ = ps.pool.Exec(ctx, `ALTER TABLE tenant_memberships ADD COLUMN IF NOT EXISTS settings jsonb NULL`)
				_, _ = ps.pool.Exec(ctx, `ALTER TABLE tenant_memberships DROP CONSTRAINT IF EXISTS tenant_memberships_settings_check`)
				_, _ = ps.pool.Exec(ctx, `ALTER TABLE tenant_memberships ADD CONSTRAINT tenant_memberships_settings_check CHECK (settings IS NULL OR jsonb_typeof(settings) = 'object')`)
			}()
			n, on = names()
			if n[t1] != "Alpha" || n[t2] != "Beta" {
				t.Fatalf("tenant list lost a tenant when the settings column was missing: %+v", n)
			}
			if len(on) != 0 {
				t.Fatalf("override read with no settings column: %v", on)
			}
		})
	}
}

// newNamedTenant is newTenant with a WUI drop-box display name. Memory's
// CreateTenant keeps the whole row; Postgres' INSERT does not carry
// display_name, so set it directly there.
func newNamedTenant(t *testing.T, s Store, name string) string {
	t.Helper()
	id := uid("t-")
	if err := s.CreateTenant(context.Background(), Tenant{ID: id, RootPubKey: pubkey(), DisplayName: name}); err != nil {
		t.Fatal(err)
	}
	if ps, ok := s.(*Postgres); ok {
		// tenants is FORCE RLS (rdb 0014); set the name under the operator scope.
		if err := ps.asOperator(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `UPDATE tenants SET display_name = $2 WHERE tenant_id = $1`, id, name)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	}
	return id
}
