package hub_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// spec 115 HUB-1: GET / PATCH /v1/agent-split, the vendor split per task kind.
//   - a fresh workspace reads the spec 115 section 2 table, every kind unset;
//   - a fixture PATCH updates the row (weights, backup, main, set, by) and a
//     re-read shows it; null resets the kind to the default;
//   - CONTROL: a PATCH with agy > 0 (or agy the backup) in a coding kind is
//     refused 400 bad_split and nothing is written (drop the guard in
//     store.CheckSplitKind and this goes red on Memory; rdb 0163's CHECK
//     still refuses it on Postgres, store/agent_split_kind_test.go);
//   - the other section 2 rules are refused the same way;
//   - a member without tenant.settings is 403.

func splitKinds(t *testing.T, body map[string]any) map[string]map[string]any {
	t.Helper()
	list, ok := body["kinds"].([]any)
	if !ok || len(list) != 6 {
		t.Fatalf("kinds: %v", body["kinds"])
	}
	out := map[string]map[string]any{}
	for _, k := range list {
		m := k.(map[string]any)
		out[m["kind"].(string)] = m
	}
	return out
}

func assertKind(t *testing.T, k map[string]any, main, backup string, set bool, w map[string]float64) {
	t.Helper()
	if k["main"] != main || k["backup"] != backup || k["set"] != set {
		t.Fatalf("kind %v: main %v backup %v set %v, want %s %s %v", k["kind"], k["main"], k["backup"], k["set"], main, backup, set)
	}
	got := k["weights"].(map[string]any)
	if len(got) != 5 {
		t.Fatalf("kind %v: %d vendors, want 5: %v", k["kind"], len(got), got)
	}
	for v, n := range got {
		if n != w[v] {
			t.Fatalf("kind %v: %s=%v, want %v (%v)", k["kind"], v, n, w[v], got)
		}
	}
}

func TestAgentSplitKinds(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)

	code, body := call(t, e, tid, http.MethodGet, "/v1/agent-split", admin, nil)
	if code != 200 {
		t.Fatalf("fresh: %d %v", code, body)
	}
	ks := splitKinds(t, body)
	assertKind(t, ks["specs_and_docs"], "agy", "claude", false, map[string]float64{"agy": 70, "mistral": 20, "claude": 10})
	assertKind(t, ks["tests"], "claude", "mistral", false, map[string]float64{"claude": 70, "mistral": 30})
	assertKind(t, ks["simple_coding"], "mistral", "claude", false, map[string]float64{"mistral": 80, "claude": 20})
	assertKind(t, ks["complex_coding"], "claude", "mistral", false, map[string]float64{"claude": 80, "mistral": 20})
	assertKind(t, ks["i18n"], "agy", "claude", false, map[string]float64{"agy": 100})
	assertKind(t, ks["secret"], "claude", "mistral", false, map[string]float64{"claude": 100})
	if v, _ := body["vendors"].([]any); len(v) != 5 {
		t.Fatalf("vendors: %v", body["vendors"])
	}

	// The fixture PATCH: simple_coding to mistral 60 / claude 30 / grok 10.
	code, body = call(t, e, tid, http.MethodPatch, "/v1/agent-split", admin, map[string]any{
		"kinds": map[string]any{"simple_coding": map[string]any{
			"weights": map[string]int{"mistral": 60, "claude": 30, "grok": 10}, "backup": "claude"}},
	})
	if code != 200 {
		t.Fatalf("patch: %d %v", code, body)
	}
	ks = splitKinds(t, body)
	assertKind(t, ks["simple_coding"], "mistral", "claude", true, map[string]float64{"mistral": 60, "claude": 30, "grok": 10})
	if ks["simple_coding"]["updated_by"] == "" || ks["simple_coding"]["updated_at"] == nil {
		t.Fatalf("patch: no updated_by / updated_at: %v", ks["simple_coding"])
	}
	assertKind(t, ks["tests"], "claude", "mistral", false, map[string]float64{"claude": 70, "mistral": 30})
	code, body = call(t, e, tid, http.MethodGet, "/v1/agent-split", admin, nil)
	if code != 200 {
		t.Fatalf("reread: %d %v", code, body)
	}
	assertKind(t, splitKinds(t, body)["simple_coding"], "mistral", "claude", true, map[string]float64{"mistral": 60, "claude": 30, "grok": 10})

	// CONTROL: agy in a coding kind is refused and nothing is written.
	for name, kinds := range map[string]map[string]any{
		"simple_coding agy 10": {"simple_coding": map[string]any{"weights": map[string]int{"mistral": 70, "claude": 20, "agy": 10}, "backup": "claude"}},
		"tests agy 1":          {"tests": map[string]any{"weights": map[string]int{"claude": 69, "mistral": 30, "agy": 1}, "backup": "mistral"}},
		"complex agy backup":   {"complex_coding": map[string]any{"weights": map[string]int{"claude": 80, "mistral": 20}, "backup": "agy"}},
		// one good kind and one bad: the good one is not written either
		"mixed": {
			"i18n":          map[string]any{"weights": map[string]int{"agy": 90, "claude": 10}, "backup": "claude"},
			"simple_coding": map[string]any{"weights": map[string]int{"mistral": 60, "agy": 40}, "backup": "claude"},
		},
	} {
		code, body = call(t, e, tid, http.MethodPatch, "/v1/agent-split", admin, map[string]any{"kinds": kinds})
		msg, _ := body["detail"].(string)
		if code != http.StatusBadRequest || body["error"] != "bad_split" || !strings.Contains(msg, "agy writes no code") {
			t.Errorf("CONTROL %s: %d %v, want 400 bad_split naming agy", name, code, body)
		}
	}
	code, body = call(t, e, tid, http.MethodGet, "/v1/agent-split", admin, nil)
	if code != 200 {
		t.Fatalf("reread: %d %v", code, body)
	}
	ks = splitKinds(t, body)
	assertKind(t, ks["simple_coding"], "mistral", "claude", true, map[string]float64{"mistral": 60, "claude": 30, "grok": 10})
	assertKind(t, ks["i18n"], "agy", "claude", false, map[string]float64{"agy": 100})

	// The other section 2 rules.
	for name, c := range map[string]struct {
		kinds any
		want  string
	}{
		"sum 99":         {map[string]any{"tests": map[string]any{"weights": map[string]int{"claude": 70, "mistral": 29}, "backup": "mistral"}}, "sum to 99"},
		"tie":            {map[string]any{"complex_coding": map[string]any{"weights": map[string]int{"claude": 50, "mistral": 50}, "backup": "mistral"}}, "tie"},
		"backup is main": {map[string]any{"tests": map[string]any{"weights": map[string]int{"claude": 70, "mistral": 30}, "backup": "claude"}}, "the backup is the main"},
		"no backup":      {map[string]any{"tests": map[string]any{"weights": map[string]int{"claude": 70, "mistral": 30}}}, "backup"},
		"secret grok":    {map[string]any{"secret": map[string]any{"weights": map[string]int{"claude": 90, "grok": 10}, "backup": "mistral"}}, "only claude and mistral"},
		"secret backup":  {map[string]any{"secret": map[string]any{"weights": map[string]int{"claude": 100}, "backup": "agy"}}, "claude or mistral"},
		"alias kind":     {map[string]any{"hard": map[string]any{"weights": map[string]int{"claude": 100}, "backup": "mistral"}}, "not one of"},
		"bad vendor":     {map[string]any{"tests": map[string]any{"weights": map[string]int{"claude": 70, "opus": 30}, "backup": "mistral"}}, "not one of"},
		"range":          {map[string]any{"tests": map[string]any{"weights": map[string]int{"claude": 101, "mistral": -1}, "backup": "mistral"}}, "0..100"},
		"float":          {map[string]any{"tests": map[string]any{"weights": map[string]any{"claude": 70.5, "mistral": 29.5}, "backup": "mistral"}}, "whole number"},
		"extra field":    {map[string]any{"tests": map[string]any{"weights": map[string]int{"claude": 70, "mistral": 30}, "backup": "mistral", "main": "claude"}}, "whole number"},
		"empty":          {map[string]any{}, "at least one"},
	} {
		code, body = call(t, e, tid, http.MethodPatch, "/v1/agent-split", admin, map[string]any{"kinds": c.kinds})
		msg, _ := body["detail"].(string)
		if code != http.StatusBadRequest || body["error"] != "bad_split" || !strings.Contains(msg, c.want) {
			t.Errorf("%s: %d %v, want 400 bad_split %q", name, code, body, c.want)
		}
	}

	// null resets the kind to the default.
	code, body = call(t, e, tid, http.MethodPatch, "/v1/agent-split", admin, map[string]any{"kinds": map[string]any{"simple_coding": nil}})
	if code != 200 {
		t.Fatalf("reset: %d %v", code, body)
	}
	assertKind(t, splitKinds(t, body)["simple_coding"], "mistral", "claude", false, map[string]float64{"mistral": 80, "claude": 20})

	// tenant.settings only.
	dev := seat(t, e, tid, rbac.Developer)
	for _, m := range []string{http.MethodGet, http.MethodPatch} {
		code, body = call(t, e, tid, m, "/v1/agent-split", dev, map[string]any{"kinds": map[string]any{"tests": nil}})
		if code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
			t.Fatalf("CONTROL: developer %s = %d %v, want 403", m, code, body)
		}
	}
}
