package hub_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// labelledPart is a cost_entry part with its localized label (SPL-5546).
type labelledPart struct {
	Source          string `json:"source"`
	ProjectOrVendor string `json:"project_or_vendor"`
	Label           string `json:"label"`
}

// humanLabel is the Human row keyed text's label in month read with query q.
func humanLabel(t *testing.T, r *fleetTokensRig, month, q, text string) (labelledPart, bool) {
	t.Helper()
	code, body := call(t, r.e, r.op, http.MethodGet, "/v1/tenant/costs?month="+month+q, r.admin, nil)
	raw, _ := json.Marshal(body)
	if code != http.StatusOK {
		t.Fatalf("costs%s: %d %s", q, code, raw)
	}
	var b struct {
		Human []labelledPart `json:"human"`
	}
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatal(err)
	}
	for _, p := range b.Human {
		if p.Source == "cost_entry" && p.ProjectOrVendor == text {
			return p, true
		}
	}
	return labelledPart{}, false
}

// SPL-5546 (owner HUM-10, csitea 720fa031: "the labels in this view should
// be in the language of the interface"): an hr entry's text is its master
// (en, the owner's answer to poll 1e669c40) label; the admin sets a
// Bulgarian one with PATCH .../labels; the list carries both and
// master_locale; the month read in ?locale=bg shows the Bulgarian label
// beside the unchanged key, and in fi (no label) falls back to
// the master text (no label field). The master's text is never edited (400),
// an unknown entry is 404, and the operator developer is refused (403).
// RED CONTROL: L2 fails when handleCostRead does not call costLocalizeParts.
func TestCostEntryLabelsRoute(t *testing.T) {
	r := newFleetTokensRig(t)
	month := "2003-11"
	reopenMonth(t, r, month)
	text := "Owner salary " + newTenantID("s")
	code, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, r.admin,
		map[string]any{"type": "hr", "label": text, "amount": 45, "currency": "EUR", "period": month})
	id, _ := got["id"].(string)
	if code != http.StatusCreated || id == "" {
		t.Fatalf("create: %d %v", code, got)
	}
	t.Cleanup(func() { call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil) })
	path := costEntryPath + "/" + id + "/labels"
	if code, got := call(t, r.e, r.op, http.MethodPatch, path, r.admin, map[string]any{"labels": map[string]string{"bg": "Заплата", "en": text}}); code != http.StatusOK {
		t.Fatalf("L1 patch: %d %v", code, got)
	}
	code, got = call(t, r.e, r.op, http.MethodGet, costEntryPath+"?type=hr&month="+month, r.admin, nil)
	if code != http.StatusOK || got["master_locale"] != "en" {
		t.Fatalf("L1 list: %d master_locale %v", code, got["master_locale"])
	}
	var labels map[string]any
	for _, e := range got["entries"].([]any) {
		if m := e.(map[string]any); m["id"] == id {
			labels, _ = m["labels"].(map[string]any)
		}
	}
	if len(labels) != 2 || labels["bg"] != "Заплата" || labels["en"] != text {
		t.Errorf("L1 the entry's labels: %v, want bg + en", labels)
	}
	if p, ok := humanLabel(t, r, month, "&locale=bg", text); !ok || p.Label != "Заплата" {
		t.Errorf("L2 the month read in bg: %v %+v, want label Заплата beside key %q", ok, p, text)
	}
	if p, ok := humanLabel(t, r, month, "&locale=fi", text); !ok || p.Label != "" {
		t.Errorf("L3 the month read in fi (no label): %v %+v, want the master text alone", ok, p)
	}
	for name, c := range map[string]struct {
		who, path string
		body      map[string]any
		want      int
	}{
		"the master's text":      {r.admin, path, map[string]any{"labels": map[string]string{"en": "Other"}}, http.StatusBadRequest},
		"an unknown locale":      {r.admin, path, map[string]any{"labels": map[string]string{"xx": "x"}}, http.StatusBadRequest},
		"an unknown field":       {r.admin, path, map[string]any{"labels": map[string]string{}, "label": "x"}, http.StatusBadRequest},
		"no such entry":          {r.admin, costEntryPath + "/00000000-0000-4000-8000-000000000000/labels", map[string]any{"labels": map[string]string{"en": "x"}}, http.StatusNotFound},
		"the operator developer": {r.dev, path, map[string]any{"labels": map[string]string{"en": "x"}}, http.StatusForbidden},
	} {
		if code, got := call(t, r.e, r.op, http.MethodPatch, c.path, c.who, c.body); code != c.want {
			t.Errorf("L4 %s: %d %v, want %d", name, code, got, c.want)
		}
	}
}

// SPL-5546: GET /v1/operator/hr-components reads in the caller's locale and
// falls back to the seed's English.
func TestHRComponentsLocalized(t *testing.T) {
	r := newFleetTokensRig(t)
	code, got := call(t, r.e, r.op, http.MethodGet, "/v1/operator/hr-components?locale=fi", r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("components: %d %v", code, got)
	}
	for _, c := range got["components"].([]any) {
		if m := c.(map[string]any); m["component"] == "monthly_salary" && m["label"] != "Monthly salary" {
			t.Errorf("monthly_salary in fi with no fi label: %v, want the seed's English", m["label"])
		}
	}
}
