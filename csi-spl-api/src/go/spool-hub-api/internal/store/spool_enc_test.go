package store

import (
	"context"
	"testing"
)

// Spec 136 L6a (SPL-1670): the workspace flag spool_enc round trip, on
// memory and, with SPOOL_TEST_PG_DSN, on Postgres. n = 2 stores x (default,
// on, cached read, fresh read, refused value, reset). CONTROL: a second
// workspace never sees the first one's flag.
func TestSpoolEncFlagRoundTrip(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			kv := st.(TenantKV)
			ts := st.(TenantSettings)
			on, other := newTenant(t, st), newTenant(t, st)

			tn, err := st.GetTenant(ctx, on)
			if err != nil || tn.SpoolEnc() {
				t.Fatalf("a fresh workspace is plain: enc=%v err=%v", tn.SpoolEnc(), err)
			}
			if v, ok := tn.Settings.Effective()[SpoolEncKey]; !ok || v != false {
				t.Fatalf("GET settings shows %s=false by default, got %v (registered %v)", SpoolEncKey, v, ok)
			}
			if _, err := kv.SetTenantSettings(ctx, on, TenantSettingsPatch{Set: map[string]any{SpoolEncKey: true}}); err != nil {
				t.Fatalf("set %s: %v", SpoolEncKey, err)
			}
			if tn, _ = st.GetTenant(ctx, on); !tn.SpoolEnc() {
				t.Fatalf("cached row after set: %v", tn.Settings)
			}
			if cfg, err := ts.TenantConfig(ctx, on); err != nil || !cfg.Settings.Bool(SpoolEncKey) {
				t.Fatalf("fresh row after set: %v %v", cfg.Settings, err)
			}
			if tn, _ = st.GetTenant(ctx, other); tn.SpoolEnc() {
				t.Fatalf("CONTROL: the other workspace reads enc")
			}
			if _, err := kv.SetTenantSettings(ctx, on, TenantSettingsPatch{Set: map[string]any{SpoolEncKey: "yes"}}); err == nil {
				t.Fatalf("a non-bool %s was stored", SpoolEncKey)
			}
			if _, err := kv.SetTenantSettings(ctx, on, TenantSettingsPatch{Unset: []string{SpoolEncKey}}); err != nil {
				t.Fatal(err)
			}
			if tn, _ = st.GetTenant(ctx, on); tn.SpoolEnc() {
				t.Fatalf("reset reads plain again (rollback, spec 136 8.4): %v", tn.Settings)
			}
		})
	}
}
