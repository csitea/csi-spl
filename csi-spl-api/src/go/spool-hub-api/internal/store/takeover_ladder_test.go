package store

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// SPL-2115: the takeover ladder in tenants.settings. A fresh tenant reads the
// owner's defaults; a patch round-trips through the fresh read
// (TenantConfig) and the cached tenant row (GetTenant, what the engine
// reads); a reset reads the default again; the secret data rule and the
// other checks refuse before anything is written. Memory and Postgres.
func TestTakeoverLadderStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			kv, ok1 := st.(TenantKV)
			ts, ok2 := st.(TenantSettings)
			if !ok1 || !ok2 {
				t.Skip("driver keeps no workspace settings")
			}
			tid := newTenant(t, st)
			ladder := func() map[string]TakeoverRung {
				t.Helper()
				cfg, err := ts.TenantConfig(ctx, tid)
				if err != nil {
					t.Fatal(err)
				}
				tn, err := st.GetTenant(ctx, tid)
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]TakeoverRung{}
				fresh, cached := TakeoverLadderOf(cfg.Settings), TakeoverLadderOf(tn.Settings)
				for i, r := range fresh {
					c := cached[i]
					if r.Kind != c.Kind || strings.Join(r.Order, ",") != strings.Join(c.Order, ",") || r.MaxFailures != c.MaxFailures || r.Set != c.Set {
						t.Fatalf("fresh %+v != cached %+v", r, c)
					}
					out[r.Kind] = r
				}
				return out
			}
			want := func(r TakeoverRung, order string, max int, set bool) {
				t.Helper()
				if strings.Join(r.Order, ",") != order || r.MaxFailures != max || r.Set != set {
					t.Fatalf("%s: %+v, want %s %d %v", r.Kind, r, order, max, set)
				}
			}

			l := ladder()
			want(l["simple_coding"], "mistral,agy,claude", 2, false)
			want(l["specs_and_docs"], "agy,claude", 1, false)
			want(l["secret"], "claude,mistral", 2, false)

			p, err := TakeoverLadderPatch([]TakeoverRung{{Kind: "tests", Order: []string{"claude", "grok"}, MaxFailures: 5}}, nil)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := kv.SetTenantSettings(ctx, tid, p); err != nil {
				t.Fatal(err)
			}
			l = ladder()
			want(l["tests"], "claude,grok", 5, true)
			want(l["complex_coding"], "mistral,agy,claude", 2, false)

			// CONTROL: the data rule, before any write.
			for _, bad := range [][]string{{"claude", "agy"}, {"qwen"}} {
				_, err := TakeoverLadderPatch([]TakeoverRung{{Kind: "secret", Order: bad, MaxFailures: 2}}, nil)
				if !errors.Is(err, ErrBadTenantSetting) || !strings.Contains(err.Error(), "never takes secret work") {
					t.Fatalf("CONTROL secret %v: %v", bad, err)
				}
			}
			// The same rule binds the generic door (PATCH /v1/tenant/settings).
			if _, err := kv.SetTenantSettings(ctx, tid, TenantSettingsPatch{Set: map[string]any{TakeoverOrderKey("secret"): "claude,agy"}}); !errors.Is(err, ErrBadTenantSetting) {
				t.Fatalf("CONTROL generic secret agy: %v", err)
			}
			for name, c := range map[string]TakeoverRung{
				"vendor": {Kind: "tests", Order: []string{"opus"}, MaxFailures: 2},
				"twice":  {Kind: "tests", Order: []string{"claude", "claude"}, MaxFailures: 2},
				"empty":  {Kind: "tests", Order: nil, MaxFailures: 2},
				"zero":   {Kind: "tests", Order: []string{"claude"}, MaxFailures: 0},
				"kind":   {Kind: "orchestration", Order: []string{"claude"}, MaxFailures: 2},
			} {
				if _, err := TakeoverLadderPatch([]TakeoverRung{c}, nil); !errors.Is(err, ErrBadTenantSetting) {
					t.Errorf("%s: %v, want ErrBadTenantSetting", name, err)
				}
			}
			if _, err := TakeoverLadderPatch(nil, nil); err == nil {
				t.Errorf("empty patch accepted")
			}
			want(ladder()["secret"], "claude,mistral", 2, false)

			p, err = TakeoverLadderPatch(nil, []string{"tests"})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := kv.SetTenantSettings(ctx, tid, p); err != nil {
				t.Fatal(err)
			}
			want(ladder()["tests"], "mistral,agy,claude", 2, false)
		})
	}
}
