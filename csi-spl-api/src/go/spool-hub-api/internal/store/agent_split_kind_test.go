package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// spec 115 HUB-1: the vendor split per task kind (rdb 0163) as the hub reads
// and writes it. Run on Memory and Postgres. A fresh workspace reads the
// spec 115 section 2 table, every kind unset; a set kind reads back whole
// with its writer; a refused patch writes nothing, not even its good kinds;
// a reset kind reads as the default again; another workspace sees none of it.
// CONTROL: drop the agy rule from CheckSplitKind and Memory stores agy 10 in
// simple_coding (red here); Postgres still refuses it at rdb 0163's CHECK,
// which this test reads as ErrBadSplitKind too.
func TestSplitKinds(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 10, 9, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			sk, ok := st.(SplitKinds)
			if !ok {
				t.Fatalf("%s keeps no agent split per kind", name)
			}
			tid, other := newTenant(t, st), newTenant(t, st)
			read := func(tenant string) map[string]SplitKind {
				t.Helper()
				rows, err := sk.SplitKinds(ctx, tenant)
				if err != nil || len(rows) != len(SplitTaskKinds) {
					t.Fatalf("read %s: %d rows, %v", tenant, len(rows), err)
				}
				out := map[string]SplitKind{}
				for i, k := range rows {
					if k.Kind != SplitTaskKinds[i] {
						t.Fatalf("row %d is %s, want %s", i, k.Kind, SplitTaskKinds[i])
					}
					out[k.Kind] = k
				}
				return out
			}
			want := func(k SplitKind, main, backup string, set bool, w map[string]int) {
				t.Helper()
				if k.Main() != main || k.Backup != backup || k.Set != set || len(k.Weights) != len(AgentKinds) {
					t.Fatalf("%s = %+v, want main %s backup %s set %v", k.Kind, k, main, backup, set)
				}
				for _, v := range AgentKinds {
					if k.Weights[v] != w[v] {
						t.Fatalf("%s: %s=%d, want %d", k.Kind, v, k.Weights[v], w[v])
					}
				}
			}

			got := read(tid)
			for _, d := range DefaultSplitKinds() {
				want(got[d.Kind], d.Main(), d.Backup, false, d.Weights)
			}
			want(got["simple_coding"], "mistral", "claude", false, map[string]int{"mistral": 80, "claude": 20})

			if err := sk.SetSplitKinds(ctx, tid, SplitKindPatch{By: "HUM-1", Set: []SplitKind{
				{Kind: "simple_coding", Weights: map[string]int{"mistral": 60, "claude": 30, "grok": 10}, Backup: "claude"},
				{Kind: "secret", Weights: map[string]int{"claude": 70, "mistral": 30}, Backup: "mistral"},
			}}, now); err != nil {
				t.Fatalf("set: %v", err)
			}
			got = read(tid)
			want(got["simple_coding"], "mistral", "claude", true, map[string]int{"mistral": 60, "claude": 30, "grok": 10})
			want(got["secret"], "claude", "mistral", true, map[string]int{"claude": 70, "mistral": 30})
			if got["simple_coding"].UpdatedBy != "HUM-1" || !got["simple_coding"].UpdatedAt.Equal(now) {
				t.Fatalf("writer: %q %v", got["simple_coding"].UpdatedBy, got["simple_coding"].UpdatedAt)
			}
			want(got["tests"], "claude", "mistral", false, map[string]int{"claude": 70, "mistral": 30})

			for label, p := range map[string]SplitKindPatch{
				"agy in simple_coding (CONTROL)": {Set: []SplitKind{
					{Kind: "i18n", Weights: map[string]int{"agy": 90, "claude": 10}, Backup: "claude"},
					{Kind: "simple_coding", Weights: map[string]int{"mistral": 70, "claude": 20, "agy": 10}, Backup: "claude"}}},
				"agy the tests backup": {Set: []SplitKind{{Kind: "tests", Weights: map[string]int{"claude": 70, "mistral": 30}, Backup: "agy"}}},
				"secret on grok":       {Set: []SplitKind{{Kind: "secret", Weights: map[string]int{"claude": 90, "grok": 10}, Backup: "mistral"}}},
				"sum 99":               {Set: []SplitKind{{Kind: "tests", Weights: map[string]int{"claude": 70, "mistral": 29}, Backup: "mistral"}}},
				"tie":                  {Set: []SplitKind{{Kind: "tests", Weights: map[string]int{"claude": 50, "mistral": 50}, Backup: "mistral"}}},
				"backup is main":       {Set: []SplitKind{{Kind: "tests", Weights: map[string]int{"claude": 70, "mistral": 30}, Backup: "claude"}}},
				"alias kind":           {Reset: []string{"hard"}},
				"named twice":          {Set: []SplitKind{{Kind: "secret", Weights: map[string]int{"claude": 100}, Backup: "mistral"}}, Reset: []string{"secret"}},
				"empty":                {},
			} {
				if err := sk.SetSplitKinds(ctx, tid, p, now); !errors.Is(err, ErrBadSplitKind) {
					t.Errorf("%s: %v, want ErrBadSplitKind", label, err)
				}
			}
			got = read(tid)
			want(got["simple_coding"], "mistral", "claude", true, map[string]int{"mistral": 60, "claude": 30, "grok": 10})
			want(got["i18n"], "agy", "claude", false, map[string]int{"agy": 100})

			for _, k := range read(other) {
				if k.Set {
					t.Fatalf("another workspace reads %s as set", k.Kind)
				}
			}

			if err := sk.SetSplitKinds(ctx, tid, SplitKindPatch{Reset: []string{"simple_coding"}}, now); err != nil {
				t.Fatalf("reset: %v", err)
			}
			got = read(tid)
			want(got["simple_coding"], "mistral", "claude", false, map[string]int{"mistral": 80, "claude": 20})
			want(got["secret"], "claude", "mistral", true, map[string]int{"claude": 70, "mistral": 30})
		})
	}
}
