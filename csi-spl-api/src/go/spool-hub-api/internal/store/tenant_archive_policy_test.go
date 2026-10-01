package store

import (
	"context"
	"testing"
)

// CLE-77819 (rdb 0093): tenants.topic_archive_policy "Who can archive topics".
// It rides the settings read (TenantConfig) AND the cached core tenant row
// (GetTenant, the hub's archive hot path), on every driver; "" means the
// default (everyone), and a value outside the three is refused in Go and by the
// postgres CHECK. Run on Memory and Postgres.
func TestTenantArchivePolicy(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ts, ok := st.(TenantSettings)
			if !ok {
				t.Skip("driver keeps no tenant settings")
			}
			tid := newTenant(t, st)

			// A fresh tenant is unset ("") and reads as everyone in force.
			cfg, err := ts.TenantConfig(ctx, tid)
			if err != nil || cfg.TopicArchivePolicy != "" {
				t.Fatalf("fresh policy %q: %v", cfg.TopicArchivePolicy, err)
			}
			if EffectiveArchivePolicy(cfg.TopicArchivePolicy) != ArchivePolicyEveryone {
				t.Fatalf("fresh effective policy is not everyone")
			}

			// Each value round-trips through the settings read and the cached
			// tenant row alike.
			for _, p := range []string{ArchivePolicyAdmins, ArchivePolicyStarter, ArchivePolicyEveryone, ""} {
				pp := p
				if err := ts.SetTenantConfig(ctx, tid, TenantConfigPatch{TopicArchivePolicy: &pp}); err != nil {
					t.Fatalf("set %q: %v", p, err)
				}
				if cfg, err := ts.TenantConfig(ctx, tid); err != nil || cfg.TopicArchivePolicy != p {
					t.Fatalf("TenantConfig %q came back %q: %v", p, cfg.TopicArchivePolicy, err)
				}
				if tn, err := st.GetTenant(ctx, tid); err != nil || tn.TopicArchivePolicy != p {
					t.Fatalf("GetTenant %q came back %q: %v", p, tn.TopicArchivePolicy, err)
				}
			}

			// CONTROL: a value outside the three is refused (Go check; the pg
			// CHECK says the same). A leading/trailing space is trimmed, not a
			// new value, so it is not in this list.
			for _, bad := range []string{"nobody", "ADMINS", "owner", "every1"} {
				bb := bad
				if err := ts.SetTenantConfig(ctx, tid, TenantConfigPatch{TopicArchivePolicy: &bb}); err == nil {
					t.Errorf("stored bad policy %q", bad)
				}
			}
		})
	}
}
