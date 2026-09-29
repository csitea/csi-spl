package auth

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestIsIssuesSort(t *testing.T) {
	ok := []IssuesSort{{"priority", "asc"}, {"updated", "desc"}, {"key", "asc"}, {"status", "desc"}}
	for _, v := range ok {
		if !IsIssuesSort(v) {
			t.Errorf("want valid: %+v", v)
		}
	}
	bad := []IssuesSort{{"", "asc"}, {"priority", ""}, {"nope", "asc"}, {"priority", "up"}}
	for _, v := range bad {
		if IsIssuesSort(v) {
			t.Errorf("want invalid: %+v", v)
		}
	}
}

func TestParseIssuesSort(t *testing.T) {
	// present, valid
	v, has, code, _ := parseIssuesSort(json.RawMessage(`{"col":"priority","dir":"asc"}`))
	if code != "" || !has || v == nil || *v != (IssuesSort{"priority", "asc"}) {
		t.Fatalf("valid: %+v has=%v code=%q", v, has, code)
	}
	// absent
	if v, has, code, _ := parseIssuesSort(nil); v != nil || has || code != "" {
		t.Fatalf("absent: %+v has=%v code=%q", v, has, code)
	}
	// null clears
	if v, has, code, _ := parseIssuesSort(json.RawMessage(`null`)); v != nil || !has || code != "" {
		t.Fatalf("null: %+v has=%v code=%q", v, has, code)
	}
	// unknown field refused (shape pinned)
	if _, _, code, _ := parseIssuesSort(json.RawMessage(`{"col":"priority","dir":"asc","x":1}`)); code == "" {
		t.Fatal("unknown field must be refused")
	}
	// bad direction refused
	if _, _, code, _ := parseIssuesSort(json.RawMessage(`{"col":"priority","dir":"up"}`)); code == "" {
		t.Fatal("bad dir must be refused")
	}
}

func TestIsPaneSizes(t *testing.T) {
	if !IsPaneSizes(map[string]float64{"sidebar": 0.2, "topic": 0.3}) {
		t.Error("want valid")
	}
	if !IsPaneSizes(map[string]float64{}) {
		t.Error("empty is valid")
	}
	// unknown key
	if IsPaneSizes(map[string]float64{"threads": 0.2}) {
		t.Error("unknown key must be invalid")
	}
	// out of range
	if IsPaneSizes(map[string]float64{"sidebar": 0.01}) || IsPaneSizes(map[string]float64{"topic": 0.95}) {
		t.Error("out of range must be invalid")
	}
	// sum leaves no room for the third pane
	if IsPaneSizes(map[string]float64{"sidebar": 0.5, "topic": 0.45}) {
		t.Error("sum >= max must be invalid")
	}
}

func TestParsePaneSizes(t *testing.T) {
	v, has, code, _ := parsePaneSizes(json.RawMessage(`{"sidebar":0.22,"topic":0.34}`))
	if code != "" || !has || !reflect.DeepEqual(v, map[string]float64{"sidebar": 0.22, "topic": 0.34}) {
		t.Fatalf("valid: %+v has=%v code=%q", v, has, code)
	}
	if v, has, _, _ := parsePaneSizes(json.RawMessage(`null`)); v != nil || !has {
		t.Fatalf("null clears: %+v has=%v", v, has)
	}
	if v, has, _, _ := parsePaneSizes(json.RawMessage(`{}`)); v != nil || !has {
		t.Fatalf("empty clears: %+v has=%v", v, has)
	}
	if _, _, code, _ := parsePaneSizes(json.RawMessage(`{"threads":0.3}`)); code == "" {
		t.Fatal("unknown divider must be refused")
	}
}

// Overlay: a set override field wins over the global; a nil field keeps it.
func TestOverlay(t *testing.T) {
	dark, nl := "dark", "newest-last"
	diagOn := true
	base := HumanSettings{
		Theme: "light", Locale: "en", SubmitKey: "enter", Diagnostics: false,
		ViewPrefs: map[string]string{"message_order": "newest-first", "issues_view": "list"},
	}
	over := base.Overlay(MembershipSettings{
		Theme: &dark, MessageOrder: &nl, Diagnostics: &diagOn,
		IssuesSort: &IssuesSort{"priority", "asc"},
		PaneSizes:  map[string]float64{"sidebar": 0.2},
	})
	if over.Theme != "dark" {
		t.Errorf("theme override: %q", over.Theme)
	}
	if over.Locale != "en" || over.SubmitKey != "enter" {
		t.Errorf("untouched globals changed: %+v", over)
	}
	if over.ViewPrefs["message_order"] != "newest-last" || over.ViewPrefs["issues_view"] != "list" {
		t.Errorf("view overlay: %+v", over.ViewPrefs)
	}
	if !over.Diagnostics {
		t.Error("diagnostics override not applied")
	}
	if over.IssuesSort == nil || over.PaneSizes["sidebar"] != 0.2 {
		t.Errorf("new settings overlay: %+v %+v", over.IssuesSort, over.PaneSizes)
	}
	// The base's ViewPrefs map must not be mutated by Overlay.
	if base.ViewPrefs["message_order"] != "newest-first" {
		t.Error("Overlay mutated the base ViewPrefs map")
	}
}
