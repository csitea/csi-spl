package hub_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-2115: GET / PUT /v1/takeover-ladder, the workspace's takeover ladder.
//   - a fresh workspace reads the owner's defaults, every kind unset;
//   - a PUT stores a kind whole, a re-read shows it, null resets it, a kind
//     left out is unchanged; the generic settings show the same keys;
//   - CONTROL: agy or qwen in the secret order is 400 bad_ladder and nothing
//     is written, the good kind of the same PUT included;
//   - the other rules are refused the same way;
//   - any member reads it; only tenant.settings writes it (developer 403).
// Memory store, and Postgres with SPOOL_TEST_PG_DSN.

func ladderKinds(t *testing.T, body map[string]any) map[string]map[string]any {
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

func assertRung(t *testing.T, k map[string]any, order string, max float64, set bool) {
	t.Helper()
	var got []string
	for _, v := range k["order"].([]any) {
		got = append(got, v.(string))
	}
	if strings.Join(got, ",") != order || k["max_failures"] != max || k["set"] != set {
		t.Fatalf("kind %v: order %v max %v set %v, want %s %v %v", k["kind"], got, k["max_failures"], k["set"], order, max, set)
	}
}

func TestTakeoverLadder(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)

	code, body := call(t, e, tid, http.MethodGet, "/v1/takeover-ladder", admin, nil)
	if code != 200 {
		t.Fatalf("fresh: %d %v", code, body)
	}
	ks := ladderKinds(t, body)
	assertRung(t, ks["specs_and_docs"], "agy,claude", 1, false)
	assertRung(t, ks["tests"], "mistral,agy,claude", 2, false)
	assertRung(t, ks["simple_coding"], "mistral,agy,claude", 2, false)
	assertRung(t, ks["complex_coding"], "mistral,agy,claude", 2, false)
	assertRung(t, ks["i18n"], "agy,claude", 1, false)
	assertRung(t, ks["secret"], "claude,mistral", 2, false)
	if v, _ := body["vendors"].([]any); len(v) != 5 || body["max_failures_max"] != float64(10) {
		t.Fatalf("vendors / max: %v %v", body["vendors"], body["max_failures_max"])
	}

	code, body = call(t, e, tid, http.MethodPut, "/v1/takeover-ladder", admin, map[string]any{"kinds": map[string]any{
		"simple_coding": map[string]any{"order": []string{"grok", "mistral", "claude"}, "max_failures": 3},
		"secret":        map[string]any{"order": []string{"mistral", "grok", "claude"}, "max_failures": 1},
	}})
	if code != 200 {
		t.Fatalf("put: %d %v", code, body)
	}
	ks = ladderKinds(t, body)
	assertRung(t, ks["simple_coding"], "grok,mistral,claude", 3, true)
	assertRung(t, ks["secret"], "mistral,grok,claude", 1, true)
	assertRung(t, ks["tests"], "mistral,agy,claude", 2, false)

	// A member without tenant.settings reads it (the engine's and the
	// member's view), and the generic settings carry the same keys.
	code, body = call(t, e, tid, http.MethodGet, "/v1/takeover-ladder", dev, nil)
	if code != 200 {
		t.Fatalf("developer read: %d %v", code, body)
	}
	assertRung(t, ladderKinds(t, body)["simple_coding"], "grok,mistral,claude", 3, true)
	code, body = call(t, e, tid, http.MethodGet, "/v1/tenant/settings", admin, nil)
	if s, _ := body["settings"].(map[string]any); code != 200 || s["takeover.simple_coding.order"] != "grok,mistral,claude" ||
		s["takeover.simple_coding.max_failures"] != float64(3) || s["takeover.i18n.order"] != "agy,claude" {
		t.Fatalf("tenant settings: %d %v", code, body["settings"])
	}

	// CONTROL: agy or qwen in secret is refused, and the good kind of the
	// same PUT is not written either.
	for name, kinds := range map[string]map[string]any{
		"secret agy":  {"secret": map[string]any{"order": []string{"claude", "agy"}, "max_failures": 2}},
		"secret qwen": {"secret": map[string]any{"order": []string{"qwen"}, "max_failures": 2}},
		"mixed": {
			"i18n":   map[string]any{"order": []string{"claude"}, "max_failures": 4},
			"secret": map[string]any{"order": []string{"claude", "mistral", "agy"}, "max_failures": 2},
		},
	} {
		code, body = call(t, e, tid, http.MethodPut, "/v1/takeover-ladder", admin, map[string]any{"kinds": kinds})
		msg, _ := body["detail"].(string)
		if code != http.StatusBadRequest || body["error"] != "bad_ladder" || !strings.Contains(msg, "never takes secret work") {
			t.Errorf("CONTROL %s: %d %v, want 400 bad_ladder naming the data rule", name, code, body)
		}
	}
	code, body = call(t, e, tid, http.MethodGet, "/v1/takeover-ladder", admin, nil)
	if code != 200 {
		t.Fatalf("reread: %d %v", code, body)
	}
	ks = ladderKinds(t, body)
	assertRung(t, ks["secret"], "mistral,grok,claude", 1, true)
	assertRung(t, ks["i18n"], "agy,claude", 1, false)

	// The other rules.
	for name, c := range map[string]struct {
		kinds any
		want  string
	}{
		"unknown vendor": {map[string]any{"tests": map[string]any{"order": []string{"claude", "opus"}, "max_failures": 2}}, "not one of"},
		"twice":          {map[string]any{"tests": map[string]any{"order": []string{"claude", "claude"}, "max_failures": 2}}, "named twice"},
		"empty order":    {map[string]any{"tests": map[string]any{"order": []string{}, "max_failures": 2}}, "at least one vendor"},
		"zero failures":  {map[string]any{"tests": map[string]any{"order": []string{"claude"}, "max_failures": 0}}, "1..10"},
		"11 failures":    {map[string]any{"tests": map[string]any{"order": []string{"claude"}, "max_failures": 11}}, "1..10"},
		"no failures":    {map[string]any{"tests": map[string]any{"order": []string{"claude"}}}, "max_failures"},
		"extra field":    {map[string]any{"tests": map[string]any{"order": []string{"claude"}, "max_failures": 2, "set": true}}, "max_failures"},
		"unknown kind":   {map[string]any{"orchestration": map[string]any{"order": []string{"claude"}, "max_failures": 2}}, "not one of"},
		"empty":          {map[string]any{}, "at least one"},
	} {
		code, body = call(t, e, tid, http.MethodPut, "/v1/takeover-ladder", admin, map[string]any{"kinds": c.kinds})
		msg, _ := body["detail"].(string)
		if code != http.StatusBadRequest || body["error"] != "bad_ladder" || !strings.Contains(msg, c.want) {
			t.Errorf("%s: %d %v, want 400 bad_ladder %q", name, code, body, c.want)
		}
	}

	// null resets the kind; the kind left out keeps its value.
	code, body = call(t, e, tid, http.MethodPut, "/v1/takeover-ladder", admin, map[string]any{"kinds": map[string]any{"simple_coding": nil}})
	if code != 200 {
		t.Fatalf("reset: %d %v", code, body)
	}
	ks = ladderKinds(t, body)
	assertRung(t, ks["simple_coding"], "mistral,agy,claude", 2, false)
	assertRung(t, ks["secret"], "mistral,grok,claude", 1, true)

	// CONTROL: PUT is tenant.settings only.
	code, body = call(t, e, tid, http.MethodPut, "/v1/takeover-ladder", dev, map[string]any{"kinds": map[string]any{"tests": nil}})
	if code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
		t.Fatalf("CONTROL: developer PUT = %d %v, want 403", code, body)
	}
}
