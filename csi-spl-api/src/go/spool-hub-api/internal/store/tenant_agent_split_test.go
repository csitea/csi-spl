package store

import (
	"context"
	"errors"
	"testing"
)

// rdb 0109: the workspace vendor split is four whole numbers that sum to
// 100. A fresh tenant is the owner's current split (claude 40, grok 50,
// agy 10, qwen 0). A partial settings write leaves it. A split outside
// 0..100 or off 100 is refused on every driver.
func TestTenantAgentSplit(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ts, ok := st.(TenantSettings)
			if !ok {
				t.Skip("driver keeps no tenant settings")
			}
			tid := newTenant(t, st)
			want := DefaultAgentSplit()

			cfg, err := ts.TenantConfig(ctx, tid)
			if err != nil || cfg.AgentSplit != want {
				t.Fatalf("fresh split %+v: %v", cfg.AgentSplit, err)
			}

			label := "Acme"
			if err := ts.SetTenantConfig(ctx, tid, TenantConfigPatch{DisplayName: &label}); err != nil {
				t.Fatal(err)
			}
			if cfg, err = ts.TenantConfig(ctx, tid); err != nil || cfg.DisplayName != "Acme" || cfg.AgentSplit != want {
				t.Fatalf("name patch moved the split: %+v %v", cfg, err)
			}

			next := AgentSplit{Claude: 30, Grok: 40, Agy: 20, Qwen: 10}
			if err := ts.SetTenantConfig(ctx, tid, TenantConfigPatch{AgentSplit: &next}); err != nil {
				t.Fatal(err)
			}
			if cfg, err = ts.TenantConfig(ctx, tid); err != nil || cfg.AgentSplit != next || cfg.DisplayName != "Acme" {
				t.Fatalf("split round trip %+v: %v", cfg, err)
			}

			renamed := "Acme 2"
			if err := ts.SetTenantConfig(ctx, tid, TenantConfigPatch{DisplayName: &renamed}); err != nil {
				t.Fatal(err)
			}
			if cfg, err = ts.TenantConfig(ctx, tid); err != nil || cfg.AgentSplit != next {
				t.Fatalf("split did not survive a name patch: %+v %v", cfg.AgentSplit, err)
			}

			for _, bad := range []AgentSplit{
				{Claude: 101, Grok: 0, Agy: 0, Qwen: -1},
				{Claude: 40, Grok: 50, Agy: 10, Qwen: 10},
				{Claude: 25, Grok: 25, Agy: 25, Qwen: 24},
				{},
			} {
				b := bad
				err = ts.SetTenantConfig(ctx, tid, TenantConfigPatch{AgentSplit: &b})
				if !errors.Is(err, ErrBadTenantConfig) {
					t.Errorf("stored bad split %+v: %v", bad, err)
				}
			}
			if cfg, err = ts.TenantConfig(ctx, tid); err != nil || cfg.AgentSplit != next {
				t.Fatalf("a refused split stuck: %+v %v", cfg.AgentSplit, err)
			}
		})
	}
}
